-- Migration 474: fn_apply_dependent_set_transition — definitive complete version
--
-- Combines ALL features that were progressively added then accidentally dropped:
--   • Mig 322/342: original implementation + updated_by fix
--   • Mig 454:     correction/prepend/split/amendment case detection
--   • Mig 456/471: hire-date guard
--   • Mig 466/471: attachment reconciliation (insert new + delete removed)
--   • Mig 471:     updated_by = p_actor in attachment INSERT
--
-- Root cause of past regressions: each migration read an older baseline and
-- silently dropped features added by intermediate migrations. This migration
-- is the single source of truth going forward.
-- See: docs/db-functions/fn_apply_dependent_set_transition.md

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
  -- Advisory lock per employee to serialise concurrent transitions
  PERFORM pg_advisory_xact_lock(hashtext('dep_set:' || p_employee_id::TEXT));

  -- ── Hire-date guard ────────────────────────────────────────────────────────
  SELECT hire_date INTO v_hire_date FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire date (%).',
      p_effective_from, v_hire_date;
  END IF;

  -- ── Case detection ─────────────────────────────────────────────────────────

  -- Correction: exact effective_from match on any existing set → update in place
  SELECT id INTO v_target_id FROM employee_dependent_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  -- Prepend: before the first set → insert with end = first_set.start - 1
  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend';
      v_inherited_end := v_target_eff_from - 1;
    END IF;
  END IF;

  -- Split: inside a closed historical slice → trim it + insert new slice
  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  -- Amendment / gap-fill: default case
  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id
      AND is_active = true AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment';
    v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────

  IF v_case = 'correction' THEN
    -- Items deleted; attachments keyed by dependent_code survive and are reconciled below
    DELETE FROM employee_dependent_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_dependent_set
    SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target_id;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSE -- amendment / gap-fill
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_dependent_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_dependent_set
        SET effective_to = p_effective_from - 1, updated_at = NOW()
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Build emp_code + dep_code sequence ─────────────────────────────────────
  SELECT employee_id INTO v_emp_code FROM employees WHERE id = p_employee_id;
  IF v_emp_code IS NULL THEN
    RAISE EXCEPTION 'fn_apply_dependent_set_transition: employee % not found', p_employee_id;
  END IF;

  -- Highest existing _DEP_NN across all sets (exclude the correction set we just cleared)
  SELECT COALESCE(MAX((regexp_match(i.dependent_code, '_DEP_(\d+)$'))[1]::INTEGER), 0)
  INTO v_max_seq
  FROM employee_dependent_item i
  JOIN employee_dependent_set  s ON s.id = i.set_id
  WHERE s.employee_id = p_employee_id
    AND i.set_id != v_new_set_id;  -- don't count items just deleted for correction

  -- ── Insert items ───────────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dep_code := NULLIF(v_item->>'dependent_code', '');
    IF v_dep_code IS NULL THEN
      v_max_seq  := v_max_seq + 1;
      v_dep_code := v_emp_code || '_DEP_' || LPAD(v_max_seq::TEXT, 2, '0');
    END IF;

    INSERT INTO employee_dependent_item (
      set_id, dependent_code, relationship_type, dependent_name,
      date_of_birth, gender, insurance_eligible
    ) VALUES (
      v_new_set_id, v_dep_code,
      v_item->>'relationship_type',
      v_item->>'dependent_name',
      (v_item->>'date_of_birth')::date,
      v_item->>'gender',
      COALESCE((v_item->>'insurance_eligible')::boolean, false)
    );

    -- ── Reconcile attachments (full desired-state sync) ──────────────────────
    IF jsonb_typeof(v_item->'attachments') = 'array' THEN

      -- 5a. Insert new attachment rows not already present
      FOR v_attachment IN SELECT * FROM jsonb_array_elements(v_item->'attachments') LOOP
        IF NOT EXISTS (
          SELECT 1 FROM employee_dependent_attachments a
          WHERE a.dependent_code = v_dep_code
            AND a.file_path      = v_attachment->>'file_path'
        ) THEN
          INSERT INTO employee_dependent_attachments (
            dependent_code, employee_id, document_type,
            file_name, original_file_name, file_path,
            mime_type, file_size, is_active,
            uploaded_by, created_by, updated_by
          ) VALUES (
            v_dep_code, p_employee_id,
            NULLIF(v_attachment->>'document_type', ''),
            v_attachment->>'file_name',
            COALESCE(v_attachment->>'original_file_name', v_attachment->>'file_name'),
            v_attachment->>'file_path',
            v_attachment->>'mime_type',
            (v_attachment->>'file_size')::bigint,
            true,
            p_actor, p_actor, p_actor
          );
        END IF;
      END LOOP;

      -- 5b. Delete attachments the user removed (absent from submitted list)
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
GRANT EXECUTE ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) IS
  'Mig 474: definitive version. Features: advisory lock, hire-date guard, '
  'correction/prepend/split/amendment case detection, dep_code generation, '
  'per-item attachment reconciliation (insert new + delete removed, updated_by = p_actor). '
  'Do NOT rewrite without reading docs/db-functions/fn_apply_dependent_set_transition.md first.';
