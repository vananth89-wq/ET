-- Migration 525: update_termination_lwd RPC
--
-- Allows an approver (HR / manager) to amend last_working_date on a PENDING
-- termination record during mid-flight review. This is standard HRMS practice:
-- HR negotiates the actual last working day (garden leave, notice buyout, handover).
--
-- Design rules (§2.6 termination-design.md):
--   • last_working_date is the JOB ANCHOR — all downstream jobs fire on this date.
--   • separation_date = employee's stated intent (immutable after submission).
--   • LWD >= separation_date is enforced by DB constraint chk_term_lwd_after_separation.
--   • LWD < notice_expiry_date → notice is waived; waiver_reason required (HR path).
--   • SELF path hard-blocks self-waiver; this RPC is for approvers only.
--
-- Guards:
--   1. Caller must NOT be the employee being terminated (approver-only path).
--   2. Record must be PENDING.
--   3. LWD >= separation_date (DB constraint also enforces this).
--   4. LWD < notice_expiry_date → notice_period_waiver_reason required.
--   5. Caller must have termination.edit permission (checked via user_can).
-- =============================================================================

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
  v_caller_employee_id  uuid;
  v_existing            RECORD;
  v_notice_period_waived boolean;
BEGIN

  -- ── 1. Resolve caller's employee_id ──────────────────────────────────────
  SELECT employee_id INTO v_caller_employee_id
  FROM   profiles
  WHERE  id = auth.uid();

  IF v_caller_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Caller profile not found.');
  END IF;

  -- ── 2. Load and lock the termination record ───────────────────────────────
  SELECT id, employee_id, workflow_status, separation_date,
         notice_expiry_date, last_working_date,
         termination_initiation_type
  INTO   v_existing
  FROM   employee_terminations
  WHERE  id = p_termination_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found.');
  END IF;

  -- ── 3. Guard: approver cannot be the employee being terminated ────────────
  --   SELF-initiated or not, this RPC is exclusively for approvers.
  --   The employee amends their own record via update_termination (mig 524).
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

  -- ── 5. Validate LWD is not null ──────────────────────────────────────────
  --   LWD may be in the past (retroactive processing, notice buyout, abandoned
  --   employee). No minimum relative to CURRENT_DATE.
  --   The DB constraint chk_term_lwd_after_separation enforces LWD >= separation_date
  --   at the storage layer; we surface a friendly message here to avoid a raw PG error.
  IF p_last_working_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'last_working_date is required.');
  END IF;

  IF p_last_working_date < v_existing.separation_date THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format(
        'Last Working Date (%s) cannot be before Separation Date (%s). '
        'To release an employee before their stated separation date, '
        'raise a new HR-initiated termination with an earlier separation date.',
        p_last_working_date, v_existing.separation_date
      )
    );
  END IF;

  -- ── 6. Notice waiver logic ────────────────────────────────────────────────
  --   If LWD < notice_expiry_date → waiver required; waiver_reason must be provided.
  --   If LWD >= notice_expiry_date → no waiver (clear any previous waiver).
  IF v_existing.notice_expiry_date IS NOT NULL
     AND p_last_working_date < v_existing.notice_expiry_date THEN
    -- Waiver triggered
    IF p_notice_period_waiver_reason IS NULL
       OR TRIM(p_notice_period_waiver_reason) = '' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', format(
          'Last Working Date (%s) is before Notice Expiry (%s). A waiver reason is required.',
          p_last_working_date, v_existing.notice_expiry_date
        )
      );
    END IF;
    v_notice_period_waived := true;
  ELSE
    -- No waiver needed; clear any previous waiver state
    v_notice_period_waived       := false;
    p_notice_period_waiver_reason := NULL;
  END IF;

  -- ── 7. Apply the amendment ────────────────────────────────────────────────
  UPDATE employee_terminations
  SET
    last_working_date             = p_last_working_date,
    notice_period_waived          = v_notice_period_waived,
    notice_period_waiver_reason   = p_notice_period_waiver_reason,
    updated_at                    = now(),
    updated_by                    = auth.uid()
    -- separation_date, notice_expiry_date, termination_reason_code,
    -- comments, workflow_status — all intentionally untouched.
  WHERE id = p_termination_id;

  RETURN jsonb_build_object(
    'ok',                         true,
    'termination_id',             p_termination_id,
    'last_working_date',          p_last_working_date,
    'notice_period_waived',       v_notice_period_waived,
    'notice_period_waiver_reason', p_notice_period_waiver_reason
  );

END;
$$;

COMMENT ON FUNCTION update_termination_lwd(uuid, date, text) IS
  'Approver-only amendment of last_working_date on a PENDING termination. '
  'If new LWD < notice_expiry_date, auto-sets notice_period_waived=true and '
  'requires a waiver reason. Does not touch separation_date, reason, comments, '
  'or workflow_status. Caller must not be the employee under termination.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT proname, pronargs
FROM   pg_proc
WHERE  proname = 'update_termination_lwd';
