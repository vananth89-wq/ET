-- =============================================================================
-- Migration 863 — the reminder job that was only ever described
--
-- WHAT IS MISSING
-- ═══════════════
--   Mig 701 created time_submission_config and its header says, in the present
--   tense, "A pg_cron job reads these rows daily". No such job was ever
--   created. 856, 857 and 858 then built every part a job would need -- the
--   deadline, the working-day fire date, the recipient resolver, the catch-up
--   window -- and still nothing reads them. An administrator can configure a
--   reminder schedule today, see it previewed on screen, and no reminder will
--   ever be sent.
--
--   This is that job.
--
-- WHAT A REMINDER IS
-- ══════════════════
--   For each active rule, for each employee expected to file a timesheet for a
--   period and who has not, on the rule's firing date for THAT employee:
--   one notification to each of the rule's recipients, once.
--
--   Every clause there is load-bearing:
--
--   "expected to file"   -- the compliance report's own population, quoted from
--                           mig 746 rather than reinvented: not deleted, Active,
--                           employed during the period, and with a work schedule.
--                           An employee with no schedule is 'not_configured'
--                           there and is not late; they must not be chased here.
--   "has not"            -- no header, or a header still in to_be_submitted.
--                           Re-checked at send time, not at scheduling time.
--   "for THAT employee"  -- time_reminder_fire_date walks the employee's own
--                           schedule and holiday calendar, so one rule fires on
--                           different dates for different people. A Sun-Thu
--                           employee and a Mon-Fri employee do not share a
--                           "+3 days".
--   "once"              -- time_reminder_log, below. Without it a daily job
--                           sends the same reminder every day of the catch-up
--                           window.
--
-- IDEMPOTENCE, AND WHY NOT config_id
-- ══════════════════════════════════
--   The natural key looks like (employee, period, rule). It is not: rules have
--   no stable identity. upsert_submission_config DELETEs every row and
--   re-inserts with fresh gen_random_uuid() ids, so every time an administrator
--   presses Save on Submission Config, every config_id changes. A log keyed on
--   config_id would go stale on save and re-send everything; a foreign key to
--   it would refuse the save outright.
--
--   So the key is (employee_id, period, offset_days). offset_days is what the
--   rule actually MEANS -- "three working days after the period closes" -- and
--   it survives a save. Re-timing a rule from +3 to +4 is a different reminder
--   and fires again, which is right; deleting and re-adding the same +3 is the
--   same reminder and does not.
--
-- THE CATCH-UP WINDOW
-- ═══════════════════
--   A daily job that only fires on the exact date misses anything that happens
--   while it is down, and a job with no window at all re-sends forever. So a
--   reminder is eligible from its firing date until firing date +
--   reminder_catchup_days (858), and the log makes it at most one send inside
--   that window. Turning on a brand-new rule therefore catches up on open
--   periods rather than either ignoring them or notifying everyone about every
--   period at once.
--
-- IN-APP WITHOUT EMAIL
-- ════════════════════
--   One row in notifications IS the bell item, and an AFTER INSERT trigger
--   emails every row. So a notification_type of 'in_app' cannot be honoured by
--   the sender alone -- the trigger has to agree to stay out of it. It now
--   returns early when the sender has already stamped email_status='skipped',
--   which is the only point at which that is possible.
--
--   'email' is folded into 'both'. Sending mail WITHOUT recording a bell item
--   would need a flag on notifications to hide a row, or a second delivery path;
--   neither exists, and inventing one for a reminder job is the wrong place.
--   The UI drops the option in the same change, so the screen stops offering a
--   setting the system does not have.
--
-- WHO THE MESSAGE IS ADDRESSED TO
-- ═══════════════════════════════
--   Deliberately not decided here. A rule has one template and a list of
--   recipients, and the administrator writing the "+1, copy the manager" rule
--   writes it in the manager's voice using {{employee_name}}. That is the whole
--   reason the wording is editable. Had the job written the words, it would
--   have repeated 861's mistake of telling one person "Your timesheet" about
--   somebody else's.
--
--   The period is named by timesheet_period_label(), not by its anchor -- 838's
--   rule. A reminder for the period starting 26 Aug is about September.
--
-- SAFETY
--   * The job takes p_today so it can be tested on any date, and p_dry_run so
--     it can be inspected without sending or logging anything.
--   * Every send is wrapped: one employee's failure cannot stop the run.
--   * Idempotent migration; the cron job is unscheduled before scheduling.
--   * Verified against a real PostgreSQL 16.
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — a rule carries its own subject line
-- ═══════════════════════════════════════════════════════════════════════════
--
-- notifications.title is NOT NULL and time_submission_config had only
-- message_template. The job could have built a subject itself, but then the
-- half of the message people see first would be the half an administrator
-- cannot change -- which is the thing this whole feature exists to avoid.

ALTER TABLE time_submission_config
  ADD COLUMN IF NOT EXISTS title_template text;

UPDATE time_submission_config
SET    title_template = 'Your {{period}} timesheet is due'
WHERE  title_template IS NULL OR trim(title_template) = '';

ALTER TABLE time_submission_config
  ALTER COLUMN title_template SET DEFAULT 'Your {{period}} timesheet is due';

DO $mig$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'time_submission_config'
               AND column_name = 'title_template'
               AND is_nullable = 'YES') THEN
    ALTER TABLE time_submission_config ALTER COLUMN title_template SET NOT NULL;
  END IF;
END;
$mig$;

COMMENT ON COLUMN time_submission_config.title_template IS
  'Mig 863: the notification subject for this rule. Same tokens as '
  'message_template: {{employee_name}}, {{period}}, {{deadline}}. Editable by '
  'an administrator for the same reason the body is -- a rule that copies the '
  'manager needs a subject written in the manager''s voice.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the record that makes "once" true
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS time_reminder_log (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   uuid        NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  period        date        NOT NULL,
  offset_days   integer     NOT NULL,
  fire_date     date        NOT NULL,
  sent_on       date        NOT NULL,
  recipients    text[]      NOT NULL,
  notified      integer     NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- The key. See the header: offset_days, not config_id, because a rule has no
-- stable id across a Save.
CREATE UNIQUE INDEX IF NOT EXISTS time_reminder_log_once
  ON time_reminder_log (employee_id, period, offset_days);

CREATE INDEX IF NOT EXISTS time_reminder_log_period
  ON time_reminder_log (period, sent_on);

COMMENT ON TABLE time_reminder_log IS
  'Mig 863: one row per reminder actually sent, keyed (employee, period, '
  'offset_days). This is what stops a daily job re-sending the same reminder '
  'on every day of its catch-up window.';

-- No policies on purpose. Only the SECURITY DEFINER job writes here, and
-- nothing reads it from the client yet. A screen over it should come with its
-- own policy rather than inherit a permissive one written in advance.
ALTER TABLE time_reminder_log ENABLE ROW LEVEL SECURITY;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — the email trigger agrees to stay out of an in-app notification
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public._mig863_patch(
  p_fn text, p_a text, p_b text, p_expect integer)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE v_src text; v_hits integer; v_n integer;
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  IF v_n = 0 THEN RAISE EXCEPTION 'MIG 863: %() not found.', p_fn; END IF;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'MIG 863: %() is overloaded % ways; this patcher edits one definition.', p_fn, v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  IF position(p_a IN v_src) = 0 AND position(p_b IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 863: %() already patched, skipping.', p_fn;
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, p_a, ''))) / length(p_a);
  IF v_hits <> p_expect THEN
    RAISE EXCEPTION 'MIG 863: in %(), the anchor matched % times, expected %. Read the live definition before editing this file. Anchor: %',
      p_fn, v_hits, p_expect, left(p_a, 90);
  END IF;

  EXECUTE replace(v_src, p_a, p_b);
  RAISE NOTICE 'MIG 863: patched %() — % occurrence(s).', p_fn, v_hits;
END;
$$;

DO $mig$
BEGIN
  PERFORM public._mig863_patch('trg_email_notification',
'BEGIN
  SELECT value INTO v_functions_url  FROM app_config WHERE key = ''supabase_functions_url'';',
'BEGIN
  -- Mig 863. An in-app-only notification is a real row -- it is the bell item --
  -- that must not also be emailed. The sender says so by inserting with
  -- email_status = ''skipped''; this is the only place that can honour it,
  -- because this trigger fires on every insert and sends unconditionally.
  -- Nothing else sets ''skipped'' on insert, so no existing notification path
  -- changes behaviour.
  IF NEW.email_status = ''skipped'' THEN
    RETURN NEW;
  END IF;

  SELECT value INTO v_functions_url  FROM app_config WHERE key = ''supabase_functions_url'';',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — an administrator's rule carries its subject through Save
-- ═══════════════════════════════════════════════════════════════════════════

-- Two anchors, each starting at a non-space character. 858 created this
-- function from inside a DO block, so its stored body carries that block's
-- indentation -- which is not visible in the migration file and is not
-- something to guess at. Anchoring on text that begins mid-line makes the
-- patch indifferent to it.

DO $mig$
BEGIN
  -- The column list.
  PERFORM public._mig863_patch('upsert_submission_config',
'(offset_days, message_template, notification_type, is_active, sort_order,',
'(offset_days, message_template, title_template, notification_type, is_active, sort_order,',
    1);

  -- ...and the matching value, beside the template it belongs with.
  --
  -- The `/* mig 863 */` is not decoration. Without it the replacement would
  -- still contain `trim(v_row->>'message_template'),` verbatim, the anchor
  -- would survive its own replacement, the "already applied" test could never
  -- fire, and every re-run would add another value to an INSERT whose column
  -- list only grew once. 862 hit exactly this; the comment is what makes the
  -- anchor genuinely disappear.
  PERFORM public._mig863_patch('upsert_submission_config',
'trim(v_row->>''message_template''),',
'trim(v_row->>''message_template'') /* mig 863 */,
        -- An older client that sends no subject keeps the column default
        -- rather than writing an empty one.
        COALESCE(NULLIF(trim(v_row->>''title_template''), ''''),
                 ''Your {{period}} timesheet is due''),',
    1);
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig863_patch(text, text, text, integer);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — rendering
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.time_render_reminder(
  p_template      text,
  p_employee_name text,
  p_period        date)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT replace(replace(replace(
           COALESCE(p_template, ''),
           '{{employee_name}}', COALESCE(p_employee_name, '')),
           -- 838: a period is named for the month it ENDS in. The period
           -- anchored 26 Aug is the September timesheet, and a reminder that
           -- calls it August is chasing a month nobody recognises.
           '{{period}}',        to_char(timesheet_period_label(p_period), 'FMMonth YYYY')),
           '{{deadline}}',      to_char(time_submission_due_date(p_period), 'FMDD Mon YYYY'));
$fn$;

COMMENT ON FUNCTION public.time_render_reminder(text, text, date) IS
  'Mig 863: substitutes {{employee_name}}, {{period}} and {{deadline}} in a '
  'submission reminder template. The period renders as its LABEL (838), never '
  'its anchor.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 6 — the job
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.time_send_submission_reminders(
  p_today   date    DEFAULT NULL,
  p_dry_run boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_today     date    := COALESCE(p_today, CURRENT_DATE);
  v_catchup   integer;
  v_start_day smallint;
  v_periods   date[];
  v_rule      record;
  v_target    record;
  v_rcpt      record;
  v_fire      date;
  v_title     text;
  v_body      text;
  v_link      text;
  v_label     text;
  v_email     text;
  v_n         integer;
  v_sent      integer := 0;
  v_people    integer := 0;
  v_errors    integer := 0;
  v_preview   jsonb   := '[]'::jsonb;
BEGIN
  SELECT COALESCE(reminder_catchup_days, 3), COALESCE(period_start_day, 1)
  INTO   v_catchup, v_start_day
  FROM   time_edit_config LIMIT 1;

  v_catchup   := COALESCE(v_catchup, 3);
  v_start_day := COALESCE(v_start_day, 1);

  -- Which periods can still be in play today? A rule fires some working days
  -- after a period closes and stays eligible for the catch-up window, so the
  -- current period and the three before it cover any sane offset. Older than
  -- that and the window has closed regardless of the rule.
  SELECT array_agg(p ORDER BY p DESC) INTO v_periods
  FROM   generate_series(0, 3) i,
         LATERAL (SELECT timesheet_period_of(
                           (date_trunc('month', v_today) - (i || ' month')::interval)::date
                           + (v_start_day - 1), v_start_day)) g(p);

  FOR v_rule IN
    SELECT offset_days, title_template, message_template, notification_type,
           recipients, sort_order
    FROM   time_submission_config
    WHERE  is_active
    ORDER  BY sort_order, offset_days
  LOOP
    FOR v_target IN
      -- The compliance population, quoted from mig 746 rather than reinvented.
      -- NOT timesheet_report_compliance() itself: that is permission-gated on
      -- the CALLER and scoped to what the caller may see, and under pg_cron
      -- there is no caller at all -- it would return PERMISSION_DENIED, or an
      -- empty population, and the job would quietly do nothing for ever.
      SELECT e.id AS employee_id, e.name AS employee_name, p.period
      FROM   employees e
      CROSS  JOIN unnest(v_periods) AS p(period)
      JOIN   LATERAL (
               SELECT x.work_schedule_id
               FROM   employee_employment x
               WHERE  x.employee_id     = e.id
                 AND  x.effective_from <= timesheet_period_end(p.period)
                 AND  x.effective_to   >= p.period
               ORDER  BY x.effective_from DESC
               LIMIT  1
             ) ee ON true
      LEFT   JOIN timesheet_headers h
             ON h.employee_id = e.id AND h.period = p.period
      WHERE  e.deleted_at IS NULL
        AND  e.status = 'Active'
        AND  ee.work_schedule_id IS NOT NULL      -- 'not_configured' is not late
        AND  (h.id IS NULL OR h.status = 'to_be_submitted')
        AND  NOT EXISTS (
               SELECT 1 FROM time_reminder_log l
               WHERE  l.employee_id = e.id
                 AND  l.period      = p.period
                 AND  l.offset_days = v_rule.offset_days)
    LOOP
      BEGIN
        -- This employee's own working days, not the calendar's.
        v_fire := time_reminder_fire_date(v_target.employee_id, v_target.period,
                                          v_rule.offset_days);

        CONTINUE WHEN v_fire IS NULL;
        CONTINUE WHEN v_today < v_fire OR v_today > v_fire + v_catchup;

        v_label := to_char(timesheet_period_label(v_target.period), 'YYYY-MM');
        v_title := time_render_reminder(v_rule.title_template,
                                        v_target.employee_name, v_target.period);
        v_body  := time_render_reminder(v_rule.message_template,
                                        v_target.employee_name, v_target.period);

        -- 'email' folded into 'both': see the header. Only 'in_app' suppresses.
        v_email := CASE WHEN v_rule.notification_type = 'in_app'
                        THEN 'skipped' ELSE 'pending' END;

        IF p_dry_run THEN
          v_preview := v_preview || jsonb_build_object(
            'employee', v_target.employee_name, 'period', v_label,
            'offset_days', v_rule.offset_days, 'fires_on', v_fire,
            'title', v_title, 'recipients', v_rule.recipients);
          v_sent := v_sent + 1;
          CONTINUE;
        END IF;

        -- Claim the send BEFORE writing any notification. If two runs overlap,
        -- the loser's insert conflicts and it sends nothing, rather than both
        -- sending and one of them then failing to log it.
        INSERT INTO time_reminder_log
          (employee_id, period, offset_days, fire_date, sent_on, recipients)
        VALUES
          (v_target.employee_id, v_target.period, v_rule.offset_days,
           v_fire, v_today, v_rule.recipients)
        ON CONFLICT (employee_id, period, offset_days) DO NOTHING;

        IF NOT FOUND THEN
          CONTINUE;
        END IF;

        v_n := 0;
        FOR v_rcpt IN
          SELECT * FROM time_reminder_recipients(v_target.employee_id, v_rule.recipients)
        LOOP
          -- The employee goes to their own screen; anyone copied goes to the
          -- employee's timesheet, never to an approval screen (769's rule).
          v_link := CASE WHEN v_rcpt.token = 'employee'
                         THEN '/my-timesheet?period=' || v_label
                         ELSE '/timesheet/' || v_target.employee_id || '?period=' || v_label
                    END;

          INSERT INTO notifications (profile_id, title, body, link, email_status)
          VALUES (v_rcpt.profile_id, v_title, v_body, v_link, v_email);

          v_n := v_n + 1;
        END LOOP;

        UPDATE time_reminder_log
        SET    notified = v_n
        WHERE  employee_id = v_target.employee_id
          AND  period      = v_target.period
          AND  offset_days = v_rule.offset_days;

        v_sent   := v_sent + 1;
        v_people := v_people + v_n;

      EXCEPTION WHEN OTHERS THEN
        -- One employee's bad data must not stop everyone else's reminder.
        v_errors := v_errors + 1;
        RAISE WARNING 'time_send_submission_reminders: employee % period % offset % — %',
          v_target.employee_id, v_target.period, v_rule.offset_days, SQLERRM;
      END;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true, 'today', v_today, 'dry_run', p_dry_run,
    'periods_considered', to_jsonb(v_periods),
    'catchup_days', v_catchup,
    'reminders', v_sent, 'notifications', v_people, 'errors', v_errors,
    'preview', CASE WHEN p_dry_run THEN v_preview ELSE NULL END);
END;
$fn$;

REVOKE ALL     ON FUNCTION public.time_send_submission_reminders(date, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.time_send_submission_reminders(date, boolean) TO authenticated;

COMMENT ON FUNCTION public.time_send_submission_reminders(date, boolean) IS
  'Mig 863: the daily submission-reminder job mig 701 described and never '
  'created. Reuses 746''s compliance population, 857''s per-employee working-day '
  'fire date, 858''s recipients and catch-up window, and 856''s deadline. '
  'p_today makes it testable on any date; p_dry_run inspects without sending.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 7 — daily
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 1:25am. Deliberately not on the hour or half hour: every other daily job in
-- this database runs at :05, :15, :17, :30 or :40 for the same reason.

DO $mig$
BEGIN
  PERFORM cron.unschedule('time-submission-reminders');
EXCEPTION WHEN OTHERS THEN
  NULL;   -- not scheduled yet, or pg_cron absent
END;
$mig$;

DO $mig$
BEGIN
  PERFORM cron.schedule('time-submission-reminders', '25 1 * * *',
                        $cron$SELECT public.time_send_submission_reminders();$cron$);
  RAISE NOTICE 'MIG 863: scheduled time-submission-reminders at 01:25 daily.';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'MIG 863: pg_cron not available — the job exists but is not scheduled (%)', SQLERRM;
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 8 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_src text; v_r jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'time_submission_config' AND column_name = 'title_template') THEN
    RAISE EXCEPTION 'MIG 863 FAILED: title_template was not added.';
  END IF;
  IF EXISTS (SELECT 1 FROM time_submission_config
             WHERE title_template IS NULL OR trim(title_template) = '') THEN
    RAISE EXCEPTION 'MIG 863 FAILED: a rule has no subject, and notifications.title is NOT NULL.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE tablename = 'time_reminder_log' AND indexname = 'time_reminder_log_once') THEN
    RAISE EXCEPTION 'MIG 863 FAILED: the uniqueness that makes "once" true is missing.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p WHERE p.proname = 'trg_email_notification';
  IF position('NEW.email_status = ''skipped''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 863 FAILED: the email trigger ignores a pre-set skipped, so in_app would still email.';
  END IF;
  IF position('send-notification-email' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 863 FAILED: the email trigger no longer sends anything at all.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p WHERE p.proname = 'upsert_submission_config';
  IF position('title_template' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 863 FAILED: Save on Submission Config would discard the subject.';
  END IF;
  -- EXACTLY twice: once in the column list, once in the VALUES. A patch whose
  -- anchor survives its own replacement adds a third, a fourth, and an INSERT
  -- with more values than columns — which only shows up the next time an
  -- administrator presses Save.
  IF (length(v_src) - length(replace(v_src, 'title_template', '')))
     / length('title_template') <> 2 THEN
    RAISE EXCEPTION 'MIG 863 FAILED: title_template appears % times in upsert_submission_config, expected 2 (column list + value). This patch is not idempotent.',
      (length(v_src) - length(replace(v_src, 'title_template', ''))) / length('title_template');
  END IF;

  -- 838 must hold here too: a reminder that names the wrong month is useless.
  IF time_render_reminder('{{period}}', NULL, DATE '2026-08-26') <> 'September 2026' THEN
    RAISE EXCEPTION 'MIG 863 FAILED: {{period}} rendered %, not September 2026 — the anchor is being used instead of the label.',
      time_render_reminder('{{period}}', NULL, DATE '2026-08-26');
  END IF;

  -- A dry run must be genuinely dry.
  SELECT time_send_submission_reminders(CURRENT_DATE, true) INTO v_r;
  IF (v_r->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'MIG 863 FAILED: a dry run did not complete: %', v_r;
  END IF;
  IF EXISTS (SELECT 1 FROM time_reminder_log WHERE created_at > now() - interval '1 minute') THEN
    RAISE EXCEPTION 'MIG 863 FAILED: a dry run wrote to time_reminder_log.';
  END IF;
  RAISE NOTICE 'MIG 863: dry run ok — %', v_r - 'preview';
END;
$v$;

COMMIT;
