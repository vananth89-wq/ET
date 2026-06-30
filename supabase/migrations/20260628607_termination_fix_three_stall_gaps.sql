-- =============================================================================
-- Migration 607: Fix three stall gaps in the termination module
--
-- ROOT CAUSE ANALYSIS
-- ───────────────────
-- Three independent bugs cause terminations / reversals to stall:
--
-- GAP 1 — admin_force_complete_workflow bails on already-approved instances
--   When workflow_instance.status = 'approved' (all tasks done, advance_instance
--   flipped it) but the downstream record is still PENDING (wf_sync_module_status
--   ran but EF wasn't fired, or ran and failed), the "Fix workflow" button:
--     a) calls admin_force_complete_workflow → bails early, wf_sync NOT called
--     b) frontend fires EF using fallback wf.record_id
--     c) EF calls fn_revert_termination_execution
--     d) fn_revert checks v_reversal.workflow_status <> 'APPROVED' → FAILS
--        because wf_sync_module_status was never called to flip it from PENDING
--
--   Fix: when status = 'approved', call wf_sync_module_status (idempotent —
--   safe to call again) and return module_code + record_id so the EF fires
--   with the correct preconditions already met.
--
-- GAP 2 — fn_pre_insert_termination_slices omits lwd from the skipped response
--   When the Inactive slice already exists (idempotent re-run), the function
--   returns {ok:true, skipped:true} WITHOUT the lwd field. The EF reads
--   `lwd = sliceResult.lwd ?? null` → null → skips fn_finalize. The "Re-run
--   Finalization" admin button therefore does nothing on re-runs.
--
--   Fix: include 'lwd', v_lwd in the skipped jsonb response.
--
-- GAP 3 — get_stalled_workflows UNION 1 misses all-skipped-task instances
--   HAVING requires COUNT(approved|cancelled) > 0. If all tasks are 'skipped'
--   (e.g., admin submitted for themselves — MANAGER step bypassed, no task
--   created, then later a fix causes re-entry), the instance stays invisible.
--
--   Fix: add 'skipped' to the counted terminal statuses in HAVING.
-- =============================================================================


-- ── FIX 1: admin_force_complete_workflow ─────────────────────────────────────
-- For already-approved instances with PENDING downstream: call wf_sync and
-- return module_code + record_id (don't bail early).

CREATE OR REPLACE FUNCTION admin_force_complete_workflow(
  p_instance_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance    RECORD;
  v_pending_cnt int;
BEGIN
  -- ── 1. Super-admin guard ─────────────────────────────────────────────────
  IF NOT is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Super-admin access required.');
  END IF;

  -- ── 2. Load instance ──────────────────────────────────────────────────────
  SELECT id, status, module_code, record_id, submitted_by, current_step
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Workflow instance not found.');
  END IF;

  -- ── 3. Already-approved path ──────────────────────────────────────────────
  -- The instance is approved but the downstream record may still be PENDING
  -- (EF was never fired or failed). Call wf_sync_module_status (idempotent)
  -- and return module_code + record_id so the frontend fires the EF.
  IF v_instance.status = 'approved' THEN
    PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'approved');

    INSERT INTO workflow_action_log
      (instance_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, auth.uid(), 'completed', v_instance.current_step,
       'Re-synced by super-admin (instance was approved but downstream record was PENDING)');

    RETURN jsonb_build_object(
      'ok',          true,
      'resynced',    true,
      'module_code', v_instance.module_code,
      'record_id',   v_instance.record_id
    );
  END IF;

  -- ── 4. Guard against non-actionable statuses ──────────────────────────────
  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Instance is in status "%s" — cannot force-complete.', v_instance.status));
  END IF;

  -- ── 5. Check no pending tasks remain ─────────────────────────────────────
  SELECT COUNT(*) INTO v_pending_cnt
  FROM   workflow_tasks
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  IF v_pending_cnt > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('%s task(s) still pending — cannot force-complete a live workflow.', v_pending_cnt));
  END IF;

  -- ── 6. Mark instance approved ─────────────────────────────────────────────
  UPDATE workflow_instances
  SET    status       = 'approved',
         completed_at = now(),
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- ── 7. Log the admin action ───────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, step_order, notes)
  VALUES
    (p_instance_id, auth.uid(), 'completed', v_instance.current_step,
     'Force-completed by super-admin (wf_advance_instance had stalled)');

  -- ── 8. Sync module record status ─────────────────────────────────────────
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'approved');

  RETURN jsonb_build_object(
    'ok',          true,
    'module_code', v_instance.module_code,
    'record_id',   v_instance.record_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION admin_force_complete_workflow(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION admin_force_complete_workflow(uuid) TO authenticated;

COMMENT ON FUNCTION admin_force_complete_workflow(uuid) IS
  'Mig 607 (Fix 1): already-approved instances no longer bail early — '
  'wf_sync_module_status is called (idempotent) so downstream record is flipped '
  'from PENDING to APPROVED/REVERSED before the frontend fires the EF. '
  'Returns module_code + record_id in all ok=true paths.';


-- ── FIX 2: fn_pre_insert_termination_slices — return lwd when skipped ────────
-- The EF reads `lwd = sliceResult.lwd ?? null` and skips finalize if null.
-- When idempotency guard fires, we must still return lwd so finalize runs.

CREATE OR REPLACE FUNCTION fn_pre_insert_termination_slices(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_term        RECORD;
  v_open_slice  RECORD;
  v_lwd         date;
  v_next_day    date;
BEGIN
  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination not found');
  END IF;

  IF v_term.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Termination is not APPROVED (status: %s)', v_term.workflow_status));
  END IF;

  v_lwd := COALESCE(v_term.last_working_date, v_term.separation_date);
  IF v_lwd IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No execution date: last_working_date and separation_date are both null');
  END IF;

  v_next_day := v_lwd + 1;

  -- Idempotency: Inactive slice already exists — still return lwd so the EF
  -- can proceed to Phase 2 (fn_finalize_termination_execution).
  IF EXISTS (
    SELECT 1 FROM employee_employment
    WHERE  employee_id    = v_term.employee_id
      AND  effective_from = v_next_day
      AND  status         = 'Inactive'
  ) THEN
    RETURN jsonb_build_object(
      'ok',      true,
      'skipped', true,
      'reason',  'Inactive slice already exists',
      'lwd',     v_lwd          -- ← critical: EF needs this to call finalize
    );
  END IF;

  -- Find current open-ended Active slice
  SELECT * INTO v_open_slice
  FROM   employee_employment
  WHERE  employee_id  = v_term.employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No open-ended active employment slice found for employee');
  END IF;

  -- Close the active slice at LWD
  UPDATE employee_employment
  SET    effective_to = v_lwd,
         is_active    = false,
         updated_at   = now()
  WHERE  id = v_open_slice.id;

  -- Insert Inactive marker slice from LWD+1 → open-ended
  INSERT INTO employee_employment (
    employee_id, effective_from, effective_to, is_active,
    status, employment_type_id, department_id, designation,
    job_title, manager_id, work_location_id, cost_center_id,
    allow_employment_sync, created_at, updated_at
  )
  SELECT
    v_term.employee_id,
    v_next_day,
    '9999-12-31'::date,
    true,
    'Inactive'::employee_status,
    v_open_slice.employment_type_id,
    v_open_slice.department_id,
    v_open_slice.designation,
    v_open_slice.job_title,
    v_open_slice.manager_id,
    v_open_slice.work_location_id,
    v_open_slice.cost_center_id,
    true,
    now(),
    now();

  RETURN jsonb_build_object('ok', true, 'lwd', v_lwd);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION fn_pre_insert_termination_slices(uuid) TO authenticated;

COMMENT ON FUNCTION fn_pre_insert_termination_slices(uuid) IS
  'Mig 607 (Fix 2): idempotent skipped response now includes lwd so that '
  'apply-termination-approval EF proceeds to Phase 2 (fn_finalize) on re-runs. '
  'Previously: skipped response had no lwd → EF skipped finalize entirely.';


-- ── FIX 3: get_stalled_workflows — count skipped tasks in UNION 1 ────────────
-- HAVING previously required at least one approved|cancelled task. All-skipped
-- instances (MANAGER step bypassed, zero approved tasks) were invisible.

CREATE OR REPLACE FUNCTION get_stalled_workflows()
RETURNS TABLE (
  instance_id   uuid,
  module_code   text,
  record_id     uuid,
  template_name text,
  subject_name  text,
  submitted_at  timestamptz,
  last_acted_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  -- ── UNION 1: in_progress with no pending tasks (advance_instance stalled) ──
  SELECT
    wi.id                                         AS instance_id,
    wi.module_code,
    wi.record_id,
    wt.name                                       AS template_name,
    COALESCE(subj_emp.name, sub_emp.name)         AS subject_name,
    wi.created_at                                 AS submitted_at,
    MAX(task.acted_at)                            AS last_acted_at
  FROM workflow_instances wi
  JOIN workflow_templates  wt       ON wt.id  = wi.template_id
  JOIN profiles            sub_p    ON sub_p.id = wi.submitted_by
  JOIN employees           sub_emp  ON sub_emp.id = sub_p.employee_id
  LEFT JOIN profiles       subj_p   ON subj_p.id  = wi.subject_profile_id
                                   AND wi.subject_profile_id IS DISTINCT FROM wi.submitted_by
  LEFT JOIN employees      subj_emp ON subj_emp.id = subj_p.employee_id
  LEFT JOIN workflow_tasks task     ON task.instance_id = wi.id
  WHERE wi.status = 'in_progress'
    AND is_super_admin()
  GROUP BY wi.id, wt.name, subj_emp.name, sub_emp.name
  HAVING COUNT(*) FILTER (WHERE task.status = 'pending') = 0
     AND COUNT(*) FILTER (WHERE task.status IN ('approved', 'cancelled', 'skipped')) > 0

  UNION ALL

  -- ── UNION 2: approved instance but downstream record still PENDING ──────────
  -- Covers: EF fired and failed silently, or wf_sync ran but EF never fired.
  -- Applies to both primary terminations and reversals (both use module_code
  -- 'termination'; the record_id distinguishes which table owns the record).
  SELECT
    wi.id                                         AS instance_id,
    wi.module_code,
    wi.record_id,
    wt.name                                       AS template_name,
    COALESCE(subj_emp.name, sub_emp.name)         AS subject_name,
    wi.created_at                                 AS submitted_at,
    MAX(task.acted_at)                            AS last_acted_at
  FROM workflow_instances wi
  JOIN workflow_templates  wt       ON wt.id  = wi.template_id
  JOIN profiles            sub_p    ON sub_p.id = wi.submitted_by
  JOIN employees           sub_emp  ON sub_emp.id = sub_p.employee_id
  LEFT JOIN profiles       subj_p   ON subj_p.id  = wi.subject_profile_id
                                   AND wi.subject_profile_id IS DISTINCT FROM wi.submitted_by
  LEFT JOIN employees      subj_emp ON subj_emp.id = subj_p.employee_id
  LEFT JOIN workflow_tasks task     ON task.instance_id = wi.id
  WHERE wi.status = 'approved'
    AND wi.module_code = 'termination'
    AND is_super_admin()
    AND (
      EXISTS (
        SELECT 1 FROM employee_terminations et
        WHERE et.id              = wi.record_id
          AND et.workflow_status = 'PENDING'
      )
      OR EXISTS (
        SELECT 1 FROM employee_termination_reversals etr
        WHERE etr.id              = wi.record_id
          AND etr.workflow_status = 'PENDING'
      )
    )
  GROUP BY wi.id, wt.name, subj_emp.name, sub_emp.name

  ORDER BY submitted_at;
$$;

REVOKE ALL     ON FUNCTION get_stalled_workflows() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_stalled_workflows() TO authenticated;

COMMENT ON FUNCTION get_stalled_workflows() IS
  'Mig 607 (Fix 3): UNION 1 HAVING now includes skipped tasks so all-skipped '
  'instances are surfaced. UNION 2 (from mig 606) retained unchanged — catches '
  'approved instances with downstream PENDING records.';
