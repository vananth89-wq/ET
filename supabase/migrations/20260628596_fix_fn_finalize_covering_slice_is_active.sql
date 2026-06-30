-- =============================================================================
-- Migration 596: fn_finalize_termination_execution — fix covering slice query
--
-- Bug: when a direct report has a newer employment slice that starts AFTER
-- the terminated employee's LWD, the slice that actually covers the LWD is
-- a closed (is_active = false) historical slice. The old query had
-- AND is_active = true which excluded that slice → NOT FOUND → reassignment
-- silently skipped.
--
-- Example: Rajiv R
--   LWD  = 2026-06-18
--   Slice 2026-06-01 → 2026-06-27  (is_active = false — superseded)
--   Slice 2026-06-28 → 9999-12-31  (is_active = true  — current)
--   Old query missed the Jun-01 slice; reassignment was skipped.
--
-- Fix:
--   1. Remove is_active filter from the covering slice lookup.
--   2. Future-slice propagation already uses effective_from > v_lwd (correct).
--   3. The mirror UPDATE on employees.manager_id is also retained.
--
-- Also resets scheduled_executed = false for terminations where finalize ran
-- but produced no DR reassignments due to this bug, so the EF can re-trigger.
-- (Idempotency guard is scheduled_executed = true, so we must clear it.)
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_finalize_termination_execution(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $body$
DECLARE
  v_term              employee_terminations%ROWTYPE;
  v_reassignment      jsonb;
  v_dr_emp_id         uuid;
  v_dr_name           text;
  v_new_mgr_id        uuid;
  v_covering_ee       employee_employment%ROWTYPE;
  v_first_future_from date;
  v_new_slice_to      date;
  v_lwd               date;
  v_eff_from          date;
  v_dr_errors         jsonb := '[]'::jsonb;
BEGIN

  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Termination record not found: %', p_termination_id;
  END IF;

  IF v_term.workflow_status <> 'APPROVED' THEN
    RAISE EXCEPTION 'Termination is not APPROVED (status: %)', v_term.workflow_status;
  END IF;

  IF v_term.scheduled_executed THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already executed');
  END IF;

  v_lwd      := v_term.last_working_date;
  v_eff_from := v_lwd + 1;

  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- ── STEP 1: Deactivate terminated employee ────────────────────────────────

  UPDATE employees
  SET    status     = 'Inactive',
         updated_at = now()
  WHERE  id = v_term.employee_id;

  -- Close only the slice active ON the LWD.
  UPDATE employee_employment
  SET    effective_to = v_lwd,
         is_active    = false,
         inactive_at  = now(),
         inactive_by  = auth.uid(),
         updated_by   = auth.uid()
  WHERE  employee_id    = v_term.employee_id
    AND  effective_from <= v_lwd
    AND  effective_to   = '9999-12-31'::date
    AND  is_active      = true;

  -- Delete spurious future records that start after the inactive marker (LWD+1).
  DELETE FROM employee_employment
  WHERE  employee_id    = v_term.employee_id
    AND  effective_from > v_eff_from
    AND  is_active      = true;

  -- ── STEP 2: Apply direct report reassignments ─────────────────────────────

  FOR v_reassignment IN
    SELECT jsonb_array_elements(
      COALESCE(v_term.direct_report_reassignments, '[]'::jsonb)
    )
  LOOP
    v_dr_emp_id  := (v_reassignment->>'employee_id')::uuid;
    v_dr_name    := COALESCE(v_reassignment->>'employee_name', v_dr_emp_id::text);
    v_new_mgr_id := (v_reassignment->>'new_manager_id')::uuid;

    CONTINUE WHEN v_new_mgr_id IS NULL;

    BEGIN

      -- Find the employment slice covering the LWD for this DR.
      -- NOTE: do NOT filter by is_active — the covering slice may already be
      -- closed (is_active = false) if the DR had a subsequent employment change
      -- that created a newer slice starting after the LWD.
      SELECT * INTO v_covering_ee
      FROM   employee_employment
      WHERE  employee_id    = v_dr_emp_id
        AND  effective_from <= v_lwd
        AND  effective_to   >= v_lwd
      ORDER  BY effective_from DESC
      LIMIT  1;

      IF NOT FOUND THEN
        -- No slice covers the LWD — DR may have already left. Skip.
        NULL;
      ELSE

        -- Find the first future slice (starts after LWD).
        SELECT effective_from INTO v_first_future_from
        FROM   employee_employment
        WHERE  employee_id    = v_dr_emp_id
          AND  effective_from > v_lwd
        ORDER  BY effective_from ASC
        LIMIT  1;

        IF v_first_future_from IS NOT NULL THEN
          v_new_slice_to := v_first_future_from - 1;
        ELSE
          v_new_slice_to := '9999-12-31'::date;
        END IF;

        -- Close the covering slice at LWD (only if still open-ended)
        UPDATE employee_employment
        SET    effective_to = v_lwd,
               is_active    = false,
               inactive_at  = now(),
               inactive_by  = auth.uid(),
               updated_by   = auth.uid()
        WHERE  id            = v_covering_ee.id
          AND  effective_to  = '9999-12-31'::date;

        -- Insert in-between slice: LWD+1 to (first_future - 1) or 9999-12-31
        -- Only insert if it won't overlap an existing slice.
        IF NOT EXISTS (
          SELECT 1 FROM employee_employment
          WHERE  employee_id    = v_dr_emp_id
            AND  effective_from = v_eff_from
        ) THEN
          INSERT INTO employee_employment (
            employee_id, designation, job_title, dept_id, manager_id,
            hire_date, end_date, work_country, work_location,
            base_currency_id, notice_period_days, status,
            effective_from, effective_to, is_active, created_by, updated_by
          ) VALUES (
            v_dr_emp_id,
            v_covering_ee.designation,      v_covering_ee.job_title,
            v_covering_ee.dept_id,          v_new_mgr_id,
            v_covering_ee.hire_date,        v_covering_ee.end_date,
            v_covering_ee.work_country,     v_covering_ee.work_location,
            v_covering_ee.base_currency_id, v_covering_ee.notice_period_days,
            'Active'::employee_status,
            v_eff_from, v_new_slice_to, true,
            auth.uid(), auth.uid()
          );
        END IF;

        -- Propagate new manager to ALL existing future slices
        UPDATE employee_employment
        SET    manager_id = v_new_mgr_id,
               updated_by = auth.uid()
        WHERE  employee_id    = v_dr_emp_id
          AND  effective_from > v_lwd;

        -- Keep employees.manager_id mirror in sync
        UPDATE employees
        SET    manager_id = v_new_mgr_id,
               updated_at = now()
        WHERE  id = v_dr_emp_id;

      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_dr_errors := v_dr_errors || jsonb_build_object(
        'employee_id',   v_dr_emp_id,
        'employee_name', v_dr_name,
        'error',         SQLERRM
      );
    END;

  END LOOP;

  -- ── STEP 3: Stamp execution ───────────────────────────────────────────────
  UPDATE employee_terminations
  SET    scheduled_executed    = true,
         scheduled_executed_at = now(),
         updated_by            = auth.uid()
  WHERE  id = p_termination_id;

  IF jsonb_array_length(v_dr_errors) > 0 THEN
    RETURN jsonb_build_object(
      'ok',        false,
      'error',     'Reassignment failed for ' || jsonb_array_length(v_dr_errors) || ' direct report(s)',
      'dr_errors', v_dr_errors
    );
  END IF;

  RETURN jsonb_build_object('ok', true);

END;
$body$;

COMMENT ON FUNCTION fn_finalize_termination_execution(uuid) IS
  'Mig 596: covering slice lookup no longer filters by is_active — handles DRs '
  'with a newer employment slice starting after the terminated employee''s LWD. '
  'Also guards INSERT with NOT EXISTS to avoid duplicate effective_from conflicts.';

REVOKE ALL     ON FUNCTION fn_finalize_termination_execution(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_finalize_termination_execution(uuid) TO authenticated;

-- ── Reset scheduled_executed for terminations where finalize already ran ──────
-- but the DR reassignment was silently skipped due to the is_active bug.
-- Only resets if the terminated employee IS inactive (step 1 succeeded) but
-- any direct report still points to the terminated employee as manager.
UPDATE employee_terminations et
SET    scheduled_executed    = false,
       scheduled_executed_at = NULL
WHERE  et.workflow_status    = 'APPROVED'
  AND  et.scheduled_executed = true
  AND  EXISTS (
         SELECT 1 FROM employees term_emp
         WHERE  term_emp.id     = et.employee_id
           AND  term_emp.status = 'Inactive'
       )
  AND  EXISTS (
         SELECT 1 FROM employees dr
         WHERE  dr.manager_id = et.employee_id
       );
