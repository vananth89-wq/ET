-- =============================================================================
-- Migration 342 — Fix missing updated_by in fn_apply_dependent_set_transition
-- =============================================================================
--
-- BUG
-- ───
-- fn_apply_dependent_set_transition (mig 322) inserts into
-- employee_dependent_attachments with uploaded_by + created_by but omits
-- updated_by, which is NOT NULL. This causes:
--
--   null value in column "updated_by" of relation "employee_dependent_attachments"
--   violates not-null constraint
--
-- whenever a dependent is saved (hire wizard Save Draft / Submit for Approval)
-- with an attachment attached.
--
-- FIX
-- ───
-- Add updated_by = p_actor to the INSERT column list and VALUES.
-- No schema change — function-only patch.
-- =============================================================================

DROP FUNCTION IF EXISTS fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID);

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
  v_new_set_id      UUID;
  v_current_set_id  UUID;
  v_curr_eff_from   DATE;
  v_emp_code        TEXT;
  v_max_seq         INTEGER := 0;
  v_item            JSONB;
  v_dep_code        TEXT;
  v_attachment      JSONB;
BEGIN
  -- Advisory lock per employee to serialise concurrent transitions
  PERFORM pg_advisory_xact_lock(hashtext('dep_set:' || p_employee_id::TEXT));

  -- 1. Find and close current active set (if any)
  SELECT id, effective_from
    INTO v_current_set_id, v_curr_eff_from
  FROM employee_dependent_set
  WHERE employee_id    = p_employee_id
    AND is_active      = true
    AND effective_to   = '9999-12-31'::date
  LIMIT 1;

  IF v_current_set_id IS NOT NULL THEN
    IF p_effective_from <= v_curr_eff_from THEN
      -- Same-day or earlier effective date — delete the current set (no
      -- historical record value, and the chk_dep_set_effective_order check
      -- would reject closure with a negative window). Items cascade.
      DELETE FROM employee_dependent_set WHERE id = v_current_set_id;
    ELSE
      UPDATE employee_dependent_set
         SET effective_to = p_effective_from - 1,
             updated_at   = NOW()
       WHERE id = v_current_set_id;
    END IF;
  END IF;

  -- 2. Insert new set
  INSERT INTO employee_dependent_set (
    employee_id, effective_from, effective_to, is_active, created_by
  ) VALUES (
    p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor
  )
  RETURNING id INTO v_new_set_id;

  -- 3. Pre-compute next dependent_code sequence for this employee
  SELECT employee_id INTO v_emp_code
  FROM employees
  WHERE id = p_employee_id;

  IF v_emp_code IS NULL THEN
    RAISE EXCEPTION 'fn_apply_dependent_set_transition: employee % not found', p_employee_id;
  END IF;

  -- Highest existing _DEP_NN sequence across all of this employee's items
  -- (across all sets — keeps codes monotonically unique forever).
  SELECT COALESCE(MAX(
    (regexp_match(i.dependent_code, '_DEP_(\d+)$'))[1]::INTEGER
  ), 0)
    INTO v_max_seq
  FROM employee_dependent_item i
  JOIN employee_dependent_set  s ON s.id = i.set_id
  WHERE s.employee_id = p_employee_id;

  -- Also factor legacy table during transition window so codes don't collide
  -- with anything that still lives in employee_dependents_legacy.
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'employee_dependents_legacy') THEN
    DECLARE
      v_legacy_max INTEGER;
    BEGIN
      EXECUTE format($q$
        SELECT COALESCE(MAX(
          (regexp_match(dependent_code, '_DEP_(\d+)$'))[1]::INTEGER
        ), 0)
        FROM employee_dependents_legacy
        WHERE employee_id = %L
      $q$, p_employee_id) INTO v_legacy_max;
      IF v_legacy_max > v_max_seq THEN
        v_max_seq := v_legacy_max;
      END IF;
    END;
  END IF;

  -- 4. Insert items, generating dependent_code for new entries
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dep_code := NULLIF(v_item->>'dependent_code', '');

    IF v_dep_code IS NULL THEN
      v_max_seq  := v_max_seq + 1;
      v_dep_code := v_emp_code || '_DEP_' || LPAD(v_max_seq::TEXT, 2, '0');
    END IF;

    INSERT INTO employee_dependent_item (
      set_id,
      dependent_code,
      relationship_type,
      dependent_name,
      date_of_birth,
      gender,
      insurance_eligible
    ) VALUES (
      v_new_set_id,
      v_dep_code,
      v_item->>'relationship_type',
      v_item->>'dependent_name',
      (v_item->>'date_of_birth')::date,
      v_item->>'gender',
      COALESCE((v_item->>'insurance_eligible')::boolean, false)
    );

    -- 5. Persist any NEW attachment rows for this dependent_code.
    -- Existing attachments (rows already in employee_dependent_attachments)
    -- continue to live; we only insert files that weren't previously linked.
    IF jsonb_typeof(v_item->'attachments') = 'array' THEN
      FOR v_attachment IN SELECT * FROM jsonb_array_elements(v_item->'attachments') LOOP
        IF NOT EXISTS (
          SELECT 1
          FROM employee_dependent_attachments a
          WHERE a.dependent_code = v_dep_code
            AND a.file_path      = v_attachment->>'file_path'
        ) THEN
          INSERT INTO employee_dependent_attachments (
            dependent_code,
            employee_id,
            document_type,
            file_name,
            original_file_name,
            file_path,
            mime_type,
            file_size,
            is_active,
            uploaded_by,
            created_by,
            updated_by        -- FIX: was missing in mig 322, causing NOT NULL violation
          ) VALUES (
            v_dep_code,
            p_employee_id,
            NULLIF(v_attachment->>'document_type', ''),
            v_attachment->>'file_name',
            COALESCE(v_attachment->>'original_file_name', v_attachment->>'file_name'),
            v_attachment->>'file_path',
            v_attachment->>'mime_type',
            (v_attachment->>'file_size')::bigint,
            true,
            p_actor,
            p_actor,
            p_actor
          );
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) IS
  'Internal: materialises a proposed dependent set against the current state. '
  'Closes (or deletes if same-day) the current open set, inserts a new set + '
  'items, auto-assigns dependent_code to NEW items, persists new attachment '
  'rows. Called from submit_dependent_set (PATH A) and from '
  'apply_profile_pending_change (PATH B, wired in mig 303). '
  'Trusts its caller for access checks. '
  'Mig 322 (original). Mig 342 (fix: added updated_by to attachment INSERT).';
