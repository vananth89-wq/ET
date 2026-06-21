-- =============================================================================
-- Migration 478 — Fix fn_apply_dependent_set_transition attachment INSERT
--
-- PROBLEM
-- ───────
-- Mig 477 rewrote fn_apply_dependent_set_transition based on a pre-475 snapshot,
-- introducing three bugs in the attachment INSERT block:
--
--   1. Table name typo: 'employee_dependent_attachment' (singular) instead of
--      'employee_dependent_attachments' (plural) → runtime relation-not-found error.
--
--   2. Missing uploaded_by / created_by / updated_by → NOT NULL constraint violation.
--
--   3. COALESCE(file_size, 0) → violates CHECK (file_size > 0) when size is absent.
--
--   4. COALESCE(file_path, '') → stores empty string instead of NULL for unuploaded files.
--
--   5. document_type not wrapped in NULLIF → stores '' instead of NULL.
--
--   6. Missing duplicate guard (IF NOT EXISTS ... WHERE file_path = ...) →
--      re-inserting the same attachment on every save.
--
--   7. Missing stale DELETE → removed attachments are never actually deleted from DB.
--
-- FIX
-- ───
-- Re-deploy fn_apply_dependent_set_transition with the corrected attachment block,
-- matching the pattern established in mig 475 (which works correctly).
-- All other logic (case detection, set INSERT, item INSERT) is unchanged from mig 477.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_apply_dependent_set_transition(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_actor          UUID
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case            text;
  v_target_id       UUID;
  v_target_eff_from DATE;
  v_inherited_end   DATE;
  v_new_set_id      UUID;
  v_emp_code        TEXT;
  v_max_seq         INTEGER := 0;
  v_item            JSONB;
  v_dep_code        TEXT;
  v_attachment      JSONB;
  v_hire_date       DATE;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('dep_set:' || p_employee_id::TEXT));

  -- ── Hire-date guard — exact hire_date comparison (mig 477) ────────────────
  SELECT hire_date INTO v_hire_date
  FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire date (%).',
      p_effective_from, v_hire_date;
  END IF;

  -- ── Case detection ─────────────────────────────────────────────────────────
  SELECT id INTO v_target_id FROM employee_dependent_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend'; v_inherited_end := v_target_eff_from - 1;
    ELSE v_target_id := NULL; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to   != '9999-12-31'::date
      AND effective_to   >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id AND is_active = true
      AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Get employee code for dependent_code generation ───────────────────────
  SELECT employee_id INTO v_emp_code FROM employees WHERE id = p_employee_id;

  SELECT COALESCE(MAX(
    CASE WHEN dependent_code ~ ('^' || v_emp_code || '_DEP_(\d+)$')
         THEN (regexp_match(dependent_code, '_DEP_(\d+)$'))[1]::int
         ELSE 0 END
  ), 0) INTO v_max_seq
  FROM employee_dependent_item
  WHERE set_id IN (SELECT id FROM employee_dependent_set WHERE employee_id = p_employee_id);

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    DELETE FROM employee_dependent_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;
  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSIF v_case = 'split' THEN
    UPDATE employee_dependent_set SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target_id;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSE
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_dependent_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_dependent_set
        SET effective_to = p_effective_from - 1, is_active = false, updated_at = NOW()
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items ───────────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dep_code := NULLIF(v_item->>'dependent_code', '');
    IF v_dep_code IS NULL THEN
      v_max_seq  := v_max_seq + 1;
      v_dep_code := v_emp_code || '_DEP_' || lpad(v_max_seq::text, 2, '0');
    END IF;

    INSERT INTO employee_dependent_item (
      set_id, dependent_code, relationship_type, dependent_name,
      date_of_birth, gender, insurance_eligible
    ) VALUES (
      v_new_set_id, v_dep_code,
      v_item->>'relationship_type', v_item->>'dependent_name',
      (v_item->>'date_of_birth')::date, v_item->>'gender',
      COALESCE((v_item->>'insurance_eligible')::boolean, false)
    );

    -- ── Attachments (mig 478: all 7 issues fixed) ─────────────────────────
    IF jsonb_typeof(v_item->'attachments') = 'array' THEN
      FOR v_attachment IN SELECT * FROM jsonb_array_elements(v_item->'attachments') LOOP
        -- Duplicate guard: skip if this file_path already recorded
        IF NOT EXISTS (
          SELECT 1 FROM employee_dependent_attachments a
          WHERE a.dependent_code = v_dep_code
            AND a.file_path = v_attachment->>'file_path'
        ) THEN
          INSERT INTO employee_dependent_attachments (
            dependent_code, employee_id, document_type,
            file_name, original_file_name, file_path,
            mime_type, file_size, is_active,
            uploaded_by, created_by, updated_by
          ) VALUES (
            v_dep_code, p_employee_id,
            NULLIF(v_attachment->>'document_type', ''),        -- '' → NULL
            v_attachment->>'file_name',
            COALESCE(v_attachment->>'original_file_name', v_attachment->>'file_name'),
            v_attachment->>'file_path',                        -- NULL stays NULL
            v_attachment->>'mime_type',
            (v_attachment->>'file_size')::bigint,              -- no COALESCE 0 (CHECK > 0)
            true,
            p_actor, p_actor, p_actor                          -- uploaded_by, created_by, updated_by
          );
        END IF;
      END LOOP;

      -- Stale DELETE: remove attachments no longer in the submitted list
      DELETE FROM employee_dependent_attachments
      WHERE dependent_code = v_dep_code
        AND (
          NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_item->'attachments') att
            WHERE (att->>'file_path') IS NOT NULL AND (att->>'file_path') <> ''
          )
          OR file_path NOT IN (
            SELECT att->>'file_path'
            FROM jsonb_array_elements(v_item->'attachments') att
            WHERE (att->>'file_path') IS NOT NULL AND (att->>'file_path') <> ''
          )
        );
    END IF;
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

REVOKE ALL    ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) IS
  'Mig 477: hire-date guard uses exact hire_date (not 1st-of-month). '
  'Mig 478: fixed attachment INSERT — correct table name (plural), '
  'uploaded_by/created_by/updated_by = p_actor, no COALESCE(file_size,0), '
  'NULLIF(document_type), duplicate guard, stale DELETE restored.';

DO $$
BEGIN
  RAISE NOTICE 'Migration 478: fn_apply_dependent_set_transition attachment INSERT fixed.';
END;
$$;
