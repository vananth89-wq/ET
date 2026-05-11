-- =============================================================================
-- Migration 060: ESS invite-reminder job + one-shot ESS backfill RPC
--
-- sync_employee_ess() — runs every 10 min via pg_cron. Does NOT grant ESS
-- (that is handled immediately at activation time by handle_new_user() trigger
-- and the link_profile_to_employee RPC). This job only:
--   1. Marks invite rows that have gone 20 h without acceptance → sets
--      reminder_sent_at so the app poller can fire a fresh signInWithOtp
--   2. Marks invites as 'expired' after 48 h
--   3. Logs every run to job_run_log
--   Uses an advisory lock to prevent concurrent runs.
--
-- backfill_ess_for_active_employees() — one-shot RPC. Run once manually in
-- the SQL Editor to grant ESS to any active employee whose profile exists but
-- predates this migration (i.e. was activated before the trigger/activate
-- button was wired up).
-- =============================================================================


-- ── 1. sync_employee_ess() — reminder + expiry only ─────────────────────────

CREATE OR REPLACE FUNCTION sync_employee_ess()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_lock_key     constant bigint := 20260429060;
  c_remind_hours constant int    := 20;   -- send reminder after 20 h unaccepted
  c_expire_hours constant int    := 48;   -- mark expired after 48 h unaccepted

  v_got_lock   bool;
  v_reminders  int  := 0;
  v_expired    int  := 0;
  v_started_at timestamptz := clock_timestamp();
  v_log_id     uuid;
BEGIN
  -- ── Advisory lock (non-blocking) ─────────────────────────────────────────
  SELECT pg_try_advisory_lock(c_lock_key) INTO v_got_lock;
  IF NOT v_got_lock THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'another sync_employee_ess run is already in progress'
    );
  END IF;

  BEGIN

    -- ── 2. Mark invites needing a reminder (20 h+ unaccepted, not yet reminded)
    UPDATE employee_invites ei
    SET    reminder_sent_at = now(),
           updated_at       = now()
    FROM   employees e
    WHERE  ei.employee_id      = e.id
      AND  ei.status           = 'sent'
      AND  ei.reminder_sent_at IS NULL
      AND  ei.sent_at          < now() - (c_remind_hours || ' hours')::interval
      AND  ei.sent_at          > now() - (c_expire_hours || ' hours')::interval
      AND  e.invite_accepted_at IS NULL;

    GET DIAGNOSTICS v_reminders = ROW_COUNT;

    -- ── 3. Mark invites expired (48 h+ unaccepted) ───────────────────────
    UPDATE employee_invites ei
    SET    status     = 'expired',
           updated_at = now()
    FROM   employees e
    WHERE  ei.employee_id = e.id
      AND  ei.status      = 'sent'
      AND  ei.sent_at     < now() - (c_expire_hours || ' hours')::interval
      AND  e.invite_accepted_at IS NULL;

    GET DIAGNOSTICS v_expired = ROW_COUNT;

    -- ── 4. Log the run ────────────────────────────────────────────────────
    INSERT INTO job_run_log (
      job_code, job_name, triggered_by,
      started_at, completed_at, duration_ms,
      status, rows_processed, summary, created_at
    )
    VALUES (
      'sync_employee_ess',
      'ESS Invite Reminder Job',
      NULL,
      v_started_at,
      clock_timestamp(),
      EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000,
      'success',
      v_reminders + v_expired,
      jsonb_build_object(
        'reminders_marked', v_reminders,
        'invites_expired',  v_expired
      ),
      now()
    )
    RETURNING id INTO v_log_id;

  EXCEPTION WHEN OTHERS THEN
    INSERT INTO job_run_log (
      job_code, job_name, triggered_by,
      started_at, completed_at, duration_ms,
      status, rows_processed, summary, error_message, created_at
    )
    VALUES (
      'sync_employee_ess', 'ESS Invite Reminder Job', NULL,
      v_started_at, clock_timestamp(),
      EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000,
      'error', 0, '{}'::jsonb, SQLERRM, now()
    );
    PERFORM pg_advisory_unlock(c_lock_key);
    RAISE;
  END;

  PERFORM pg_advisory_unlock(c_lock_key);

  RETURN jsonb_build_object(
    'ok',               true,
    'reminders_marked', v_reminders,
    'invites_expired',  v_expired,
    'log_id',           v_log_id
  );
END;
$$;

COMMENT ON FUNCTION sync_employee_ess() IS
  'Runs every 10 min via pg_cron. '
  'Marks invite rows for reminder at 20 h and expires them at 48 h. '
  'Does NOT grant ESS — that is handled at activation time by '
  'handle_new_user() trigger and link_profile_to_employee RPC.';


-- ── 2. backfill_ess_for_active_employees() — run once manually ───────────────
--
-- Grants the ESS role to any active employee whose profile already exists but
-- predates the activation-time ESS grant (i.e. employees set Active before
-- migration 059/060 was applied). Safe to run multiple times — uses ON CONFLICT
-- DO NOTHING.

CREATE OR REPLACE FUNCTION backfill_ess_for_active_employees()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ess_role   uuid;
  v_granted    int := 0;
  rec          RECORD;
BEGIN
  IF NOT (has_role('admin') OR has_permission('security.manage_roles')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient permissions');
  END IF;

  SELECT id INTO v_ess_role FROM roles WHERE code = 'ess' LIMIT 1;

  IF v_ess_role IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ESS role not found');
  END IF;

  FOR rec IN
    SELECT p.id AS profile_id
    FROM   employees e
    JOIN   profiles  p ON p.employee_id = e.id
    WHERE  e.status = 'Active'
      AND  e.status = 'Active'
      AND  NOT EXISTS (
        SELECT 1 FROM user_roles ur
        WHERE  ur.profile_id = p.id
          AND  ur.role_id    = v_ess_role
      )
  LOOP
    INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
    VALUES (rec.profile_id, v_ess_role, 'backfill', now(), now())
    ON CONFLICT (profile_id, role_id) DO NOTHING;

    IF FOUND THEN
      v_granted := v_granted + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'ess_granted', v_granted);
END;
$$;

COMMENT ON FUNCTION backfill_ess_for_active_employees() IS
  'One-shot backfill. Grants ESS to every active employee whose profile exists '
  'but did not receive ESS at activation time (pre-migration employees). '
  'Safe to run multiple times. Call once manually after applying migration 060: '
  'SELECT backfill_ess_for_active_employees();';


-- ── 3. Schedule sync_employee_ess with pg_cron ───────────────────────────────
--
-- Requires pg_cron extension (Database → Extensions → pg_cron).

SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'sync_employee_ess'
  AND  EXISTS (SELECT 1 FROM cron.job LIMIT 1);

SELECT cron.schedule(
  'sync_employee_ess',
  '*/10 * * * *',
  $$SELECT sync_employee_ess()$$
);


-- ── 4. Helper view: invites needing a reminder email ─────────────────────────

CREATE OR REPLACE VIEW pending_invite_reminders AS
SELECT
  e.id              AS employee_id,
  e.business_email,
  e.name            AS employee_name,
  ei.id             AS invite_id,
  ei.sent_at,
  ei.reminder_sent_at,
  ei.attempt_no
FROM   employee_invites ei
JOIN   employees        e ON e.id = ei.employee_id
WHERE  ei.status            = 'sent'
  AND  ei.reminder_sent_at  IS NOT NULL
  AND  e.invite_accepted_at IS NULL;

COMMENT ON VIEW pending_invite_reminders IS
  'Employees whose invite was sent > 20 h ago and is still unaccepted. '
  'The sync job stamps reminder_sent_at; the app poller reads this view '
  'to fire a fresh signInWithOtp and then clears reminder_sent_at.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname FROM pg_proc
WHERE  proname IN ('sync_employee_ess', 'backfill_ess_for_active_employees');

SELECT viewname FROM pg_views WHERE viewname = 'pending_invite_reminders';
