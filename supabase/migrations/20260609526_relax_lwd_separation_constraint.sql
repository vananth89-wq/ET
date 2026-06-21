-- Migration 526: Relax last_working_date >= separation_date constraint
--
-- DESIGN GAP FIX (identified 2026-06-09):
--
-- The original constraint chk_term_lwd_after_separation enforced LWD >= separation_date.
-- This is incorrect for the garden leave pattern, which is the primary reason HR would
-- amend LWD during approval:
--
--   Garden leave:
--     separation_date = legal end of employment (immutable — employee's contract, e.g. 09 Jul)
--     last_working_date = last day physically at work (HR-negotiated early release, e.g. 30 Jun)
--     LWD < separation_date is VALID: employee stops coming in on LWD, stays on payroll
--     until separation_date, downstream jobs (payroll cutoff, access revocation) fire on LWD.
--
-- Additionally, for SELF submissions where separation_date = notice_expiry_date (employee
-- served exact notice), ANY waiver scenario requires LWD < notice_expiry_date = separation_date.
-- The old constraint made the entire mid-flight LWD waiver feature impossible for SELF path.
--
-- New rule:
--   last_working_date has no minimum relative to separation_date.
--   The only hard floor is that LWD must be a valid date (NOT NULL when set).
--   If LWD < notice_expiry_date → waiver auto-set, waiver_reason required (enforced by RPC).
--   If LWD < separation_date   → garden leave semantics; no additional block.
-- =============================================================================

-- 1. Drop the over-restrictive constraint
ALTER TABLE employee_terminations
  DROP CONSTRAINT IF EXISTS chk_term_lwd_after_separation;

-- 2. Replace update_termination_lwd: remove the separation_date floor
CREATE OR REPLACE FUNCTION update_termination_lwd(
  p_termination_id              uuid,
  p_last_working_date           date,
  p_notice_period_waiver_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_employee_id   uuid;
  v_existing             RECORD;
  v_notice_period_waived boolean;
BEGIN

  -- ── 1. Resolve caller ────────────────────────────────────────────────────
  SELECT employee_id INTO v_caller_employee_id
  FROM   profiles
  WHERE  id = auth.uid();

  IF v_caller_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Caller profile not found.');
  END IF;

  -- ── 2. Load and lock ─────────────────────────────────────────────────────
  SELECT id, employee_id, workflow_status,
         separation_date, notice_expiry_date, last_working_date,
         termination_initiation_type
  INTO   v_existing
  FROM   employee_terminations
  WHERE  id = p_termination_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found.');
  END IF;

  -- ── 3. Guard: approver cannot be the employee being terminated ────────────
  IF v_existing.employee_id = v_caller_employee_id THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'You cannot amend the last working date on your own termination record.'
    );
  END IF;

  -- ── 4. Guard: record must be PENDING ─────────────────────────────────────
  IF v_existing.workflow_status != 'PENDING' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format(
        'Only PENDING terminations can be amended (current status: %s).',
        v_existing.workflow_status
      )
    );
  END IF;

  -- ── 5. Validate LWD is provided ──────────────────────────────────────────
  --   No minimum relative to separation_date or CURRENT_DATE.
  --   LWD < separation_date = garden leave (employee stops working but remains
  --   legally employed until separation_date; downstream jobs fire on LWD).
  --   LWD in the past is valid for retroactive processing and notice buyout.
  IF p_last_working_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'last_working_date is required.');
  END IF;

  -- ── 6. Notice waiver logic ────────────────────────────────────────────────
  --   Waiver triggers when LWD < notice_expiry_date (not separation_date).
  --   notice_expiry_date = submitted_at::date + notice_period_days_snapshot.
  IF v_existing.notice_expiry_date IS NOT NULL
     AND p_last_working_date < v_existing.notice_expiry_date THEN
    IF p_notice_period_waiver_reason IS NULL
       OR TRIM(p_notice_period_waiver_reason) = '' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', format(
          'Last Working Date (%s) is before Notice Expiry (%s). '
          'A Notice Waiver Justification is required.',
          p_last_working_date, v_existing.notice_expiry_date
        )
      );
    END IF;
    IF length(TRIM(p_notice_period_waiver_reason)) < 20 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'Notice Waiver Justification must be at least 20 characters.'
      );
    END IF;
    v_notice_period_waived := true;
  ELSE
    v_notice_period_waived        := false;
    p_notice_period_waiver_reason := NULL;
  END IF;

  -- ── 7. Apply to employee_terminations ────────────────────────────────────
  UPDATE employee_terminations
  SET
    last_working_date             = p_last_working_date,
    notice_period_waived          = v_notice_period_waived,
    notice_period_waiver_reason   = p_notice_period_waiver_reason,
    updated_at                    = now(),
    updated_by                    = auth.uid()
  WHERE id = p_termination_id;

  -- ── 8. Patch workflow_instances.metadata so vw_wf_pending_tasks reflects ──
  --   the updated values immediately on next load.
  --
  --   Background: vw_wf_pending_tasks uses COALESCE(wpc.proposed_data, wi.metadata).
  --   Profile modules go through workflow_pending_changes (wpc) so their edits
  --   surface automatically. Termination is an event table — no wpc row exists —
  --   so the view always falls back to wi.metadata (submission-time snapshot).
  --   We patch wi.metadata directly to keep the read-mode display in sync.
  UPDATE workflow_instances
  SET metadata = metadata || jsonb_build_object(
    'last_working_date',            p_last_working_date::text,
    'notice_period_waived',         v_notice_period_waived,
    'notice_period_waiver_reason',  p_notice_period_waiver_reason
  )
  WHERE record_id   = p_termination_id
    AND module_code = 'termination'
    AND status      = 'in_progress';

  RETURN jsonb_build_object(
    'ok',                          true,
    'termination_id',              p_termination_id,
    'last_working_date',           p_last_working_date,
    'notice_period_waived',        v_notice_period_waived,
    'notice_period_waiver_reason', p_notice_period_waiver_reason
  );

END;
$$;

COMMENT ON FUNCTION update_termination_lwd(uuid, date, text) IS
  'HR approver amendment of last_working_date on a PENDING termination. '
  'LWD < separation_date is valid (garden leave: employee stops working before '
  'legal separation date; downstream jobs fire on LWD). '
  'LWD < notice_expiry_date triggers notice waiver; justification required (min 20 chars). '
  'Caller must not be the employee under termination.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT conname FROM pg_constraint
WHERE  conrelid = 'employee_terminations'::regclass
  AND  conname  = 'chk_term_lwd_after_separation';
-- Should return 0 rows (constraint dropped).
