-- Migration 524: update_termination RPC
--
-- Allows the original submitter to amend a PENDING termination record after
-- an approver has sent it back (awaiting_clarification). Called from the
-- inline edit form in WorkflowReview before the submitter calls wf_resubmit.
--
-- Amend-able fields (SELF path):
--   separation_date          — must still satisfy notice period
--   termination_reason_code  — any active RESIGNATION_REASON code
--   comments                 — min 20 chars (50 if reason = OTHER)
--
-- Invariants preserved:
--   • notice_expiry_date = original submitted_at::date + notice_period_days
--     (uses submitted_at already stored, NOT CURRENT_DATE — the window was
--      established at submission time and must not shrink on amendment)
--   • notice_period_days_snapshot re-read from employment satellite using the
--     new separation_date (in case a different employment slice applies)
--   • last_working_date remains equal to separation_date (SELF cannot override)
--   • submitted_at is never touched (trigger guards it, but RPC also skips it)
--   • Only PENDING records belonging to the calling user may be amended
-- =============================================================================

CREATE OR REPLACE FUNCTION update_termination(
  p_termination_id   uuid,
  p_termination_data jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id          uuid;
  v_caller_employee_id   uuid;
  v_existing             RECORD;
  v_separation_date      date;
  v_reason_code          text;
  v_comments             text;
  v_notice_period_days   integer;
  v_notice_expiry_date   date;
  v_min_comment_len      integer;
BEGIN

  -- ── 1. Resolve caller's employee_id ───────────────────────────────────────
  SELECT employee_id INTO v_caller_employee_id
  FROM   profiles
  WHERE  id = auth.uid();

  IF v_caller_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Caller profile not found.');
  END IF;

  -- ── 2. Load and lock the termination record ───────────────────────────────
  SELECT id, employee_id, workflow_status, workflow_instance_id,
         submitted_by, submitted_at, termination_initiation_type,
         notice_period_days_snapshot
  INTO   v_existing
  FROM   employee_terminations
  WHERE  id = p_termination_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found.');
  END IF;

  -- ── 3. Guard: must be PENDING ─────────────────────────────────────────────
  IF v_existing.workflow_status != 'PENDING' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format(
        'Only PENDING terminations can be amended (current status: %s).',
        v_existing.workflow_status
      )
    );
  END IF;

  -- ── 4. Guard: only the original submitter (SELF path) ─────────────────────
  --   update_termination is only for SELF-initiated records being amended after
  --   send-back. HR/manager amendments are handled via the HR form directly.
  IF v_existing.termination_initiation_type != 'SELF' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Only SELF-initiated terminations can be amended via this path.'
    );
  END IF;

  IF v_existing.employee_id != v_caller_employee_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'You can only amend your own termination request.');
  END IF;

  -- ── 5. Extract and validate fields ────────────────────────────────────────
  v_separation_date := NULLIF(p_termination_data->>'separation_date', '')::date;
  v_reason_code     := NULLIF(p_termination_data->>'termination_reason_code', '');
  v_comments        := NULLIF(TRIM(p_termination_data->>'comments'), '');

  IF v_separation_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'separation_date is required.');
  END IF;

  IF v_reason_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_reason_code is required.');
  END IF;

  IF v_comments IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments is required.');
  END IF;

  -- ── 6. Re-read notice_period_days from employment satellite ───────────────
  --   Use new separation_date in case a different effective slice applies.
  SELECT notice_period_days INTO v_notice_period_days
  FROM   employee_employment
  WHERE  employee_id   = v_existing.employee_id
    AND  effective_from <= v_separation_date
    AND  effective_to   >  v_separation_date
  ORDER BY effective_from DESC
  LIMIT 1;

  IF v_notice_period_days IS NULL THEN
    -- Fall back to open-ended slice
    SELECT notice_period_days INTO v_notice_period_days
    FROM   employee_employment
    WHERE  employee_id  = v_existing.employee_id
      AND  effective_to IS NULL
    ORDER BY effective_from DESC
    LIMIT 1;
  END IF;

  IF v_notice_period_days IS NULL THEN
    v_notice_period_days := 30; -- system default
  END IF;

  -- ── 7. Recompute notice_expiry_date using ORIGINAL submitted_at ───────────
  --   CRITICAL: use submitted_at::date, not CURRENT_DATE.
  --   The notice window was established when the employee submitted.
  --   Using today would shrink the window if the approver takes days to review.
  v_notice_expiry_date := v_existing.submitted_at::date + v_notice_period_days;

  -- ── 8. Validate separation_date >= notice_expiry_date ────────────────────
  IF v_separation_date < v_notice_expiry_date THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format(
        'separation_date must be on or after %s (submission date + %s notice days).',
        v_notice_expiry_date, v_notice_period_days
      )
    );
  END IF;

  -- ── 9. Validate comments length ───────────────────────────────────────────
  v_min_comment_len := CASE WHEN v_reason_code = 'OTHER' THEN 50 ELSE 20 END;

  IF length(v_comments) < v_min_comment_len THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format('Comments must be at least %s characters.', v_min_comment_len)
    );
  END IF;

  -- ── 10. Apply the amendment ───────────────────────────────────────────────
  UPDATE employee_terminations
  SET
    separation_date              = v_separation_date,
    last_working_date            = v_separation_date,   -- SELF: LWD always = separation_date
    notice_expiry_date           = v_notice_expiry_date,
    notice_period_days_snapshot  = v_notice_period_days,
    termination_reason_code      = v_reason_code,
    comments                     = v_comments,
    updated_at                   = now(),
    updated_by                   = auth.uid()
    -- submitted_at intentionally NOT updated (point-in-time audit record)
    -- workflow_status intentionally NOT changed (stays PENDING)
  WHERE id = p_termination_id;

  RETURN jsonb_build_object(
    'ok',                       true,
    'termination_id',           p_termination_id,
    'separation_date',          v_separation_date,
    'notice_expiry_date',       v_notice_expiry_date,
    'notice_period_days',       v_notice_period_days
  );

END;
$$;

COMMENT ON FUNCTION update_termination(uuid, jsonb) IS
  'Amends a PENDING SELF-initiated termination after approver send-back. '
  'Recomputes notice_expiry_date using original submitted_at (not today). '
  'Does not change workflow_status or submitted_at. '
  'Caller must follow up with wf_resubmit to return the instance to in_progress.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT proname, pronargs
FROM   pg_proc
WHERE  proname = 'update_termination';
