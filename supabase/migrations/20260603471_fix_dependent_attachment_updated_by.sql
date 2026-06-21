-- Migration 468: Fix null updated_by on employee_dependent_attachments
-- Mig 466 rewrote fn_apply_dependent_set_transition but omitted updated_by
-- from the INSERT into employee_dependent_attachments, causing a NOT NULL error
-- when attaching documents to dependents in the hire wizard.
-- This migration re-deploys the function with updated_by = p_actor.

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
  v_hire_date       DATE;
BEGIN
  -- Advisory lock per employee to serialise concurrent transitions
  PERFORM pg_advisory_xact_lock(hashtext('dep_set:' || p_employee_id::TEXT));

  -- Hire-date guard
  SELECT hire_date INTO v_hire_date FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire date (%).',
      p_effective_from, v_hire_date;
  END IF;

  -- 1. Find and close current active set (if any)
  SELECT id, effective_from
    INTO v_current_set_id, v_curr_eff_from
  FROM employee_dependent_set
  WHERE employee_id  = p_employee_id
    AND is_active    = true
    AND effective_to = '9999-12-31'::date
  LIMIT 1;

  IF v_current_set_id IS NOT NULL THEN
    IF p_effective_from <= v_curr_eff_from THEN
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
  SELECT employee_id INTO v_emp_code FROM employees WHERE id = p_employee_id;

  IF v_emp_code IS NULL THEN
    RAISE EXCEPTION 'fn_apply_dependent_set_transition: employee % not found', p_employee_id;
  END IF;

  SELECT COALESCE(MAX(
    (regexp_match(i.dependent_code, '_DEP_(\d+)$'))[1]::INTEGER
  ), 0)
    INTO v_max_seq
  FROM employee_dependent_item i
  JOIN employee_dependent_set  s ON s.id = i.set_id
  WHERE s.employee_id = p_employee_id;

  -- 4. Insert items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dep_code := NULLIF(v_item->>'dependent_code', '');

    IF v_dep_code IS NULL THEN
      v_max_seq  := v_max_seq + 1;
      v_dep_code := v_emp_code || '_DEP_' || LPAD(v_max_seq::TEXT, 2, '0');
    END IF;

    INSERT INTO employee_dependent_item (
      set_id, dependent_code, relationship_type,
      dependent_name, date_of_birth, gender, insurance_eligible
    ) VALUES (
      v_new_set_id, v_dep_code,
      v_item->>'relationship_type',
      v_item->>'dependent_name',
      (v_item->>'date_of_birth')::date,
      v_item->>'gender',
      COALESCE((v_item->>'insurance_eligible')::boolean, false)
    );

    -- 5. Reconcile attachments
    IF jsonb_typeof(v_item->'attachments') = 'array' THEN

      -- 5a. Insert new attachments
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
            p_actor, p_actor, p_actor   -- uploaded_by, created_by, updated_by
          );
        END IF;
      END LOOP;

      -- 5b. Delete removed attachments
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

REVOKE ALL ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) IS
  'Mig 468: fix null updated_by on employee_dependent_attachments INSERT.';
