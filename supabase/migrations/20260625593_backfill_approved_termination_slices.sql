-- =============================================================================
-- Migration 593: backfill — run slice RPCs for approved terminations whose
-- employment slices were never written (EF failed before mig 592).
--
-- Finds any APPROVED termination where the Inactive marker slice is missing,
-- then calls fn_pre_insert_termination_slices + fn_finalize_termination_execution.
-- Safe to run multiple times — both RPCs are idempotent.
-- =============================================================================

DO $$
DECLARE
  v_term       RECORD;
  v_slice_res  jsonb;
  v_fin_res    jsonb;
  v_today      date := current_date;
BEGIN
  FOR v_term IN
    SELECT et.id, et.employee_id, et.last_working_date, et.separation_date
    FROM   employee_terminations et
    WHERE  et.workflow_status = 'APPROVED'
      AND  NOT EXISTS (
             SELECT 1 FROM employee_employment ee
             WHERE  ee.employee_id = et.employee_id
               AND  ee.status      = 'Inactive'
               AND  ee.effective_from = COALESCE(et.last_working_date, et.separation_date) + 1
           )
  LOOP
    RAISE NOTICE 'Processing termination % for employee %', v_term.id, v_term.employee_id;

    v_slice_res := fn_pre_insert_termination_slices(v_term.id);
    RAISE NOTICE '  fn_pre_insert_termination_slices: %', v_slice_res;

    IF (v_slice_res->>'ok')::boolean THEN
      IF COALESCE(v_term.last_working_date, v_term.separation_date) <= v_today THEN
        v_fin_res := fn_finalize_termination_execution(v_term.id);
        RAISE NOTICE '  fn_finalize_termination_execution: %', v_fin_res;
      ELSE
        RAISE NOTICE '  finalize deferred — LWD is future-dated';
      END IF;
    ELSE
      RAISE WARNING '  slice RPC failed: %', v_slice_res->>'error';
    END IF;
  END LOOP;
END;
$$;
