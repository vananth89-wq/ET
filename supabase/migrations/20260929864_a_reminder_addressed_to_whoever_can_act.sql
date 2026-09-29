-- =============================================================================
-- Migration 864 — a reminder addressed to whoever can act on it
--
-- WHAT IS WRONG
-- ═════════════
--   701 seeded three reminder rules, all written in the second person to the
--   employee:
--
--     -1  Hi {{employee_name}}, your timesheet for {{period}} is due tomorrow...
--     +3  Hi {{employee_name}}, your timesheet for {{period}} is 3 days overdue...
--     +6  URGENT: {{employee_name}}, your timesheet for {{period}} is 6 days overdue...
--
--   That was right while a reminder went to the employee alone. 858 made the
--   recipients configurable and the later rules now also copy the manager, the
--   HR Analyst and the HR Head -- and every one of them is told that THEIR
--   timesheet is overdue, about somebody else's month.
--
--   This is the same fault 861 fixed in the approval notification: one set of
--   words, several recipients, and only one of them addressed. There it was
--   code; here it is content, which is why 863 made the wording editable.
--   Shipping it wrong by default is still shipping it wrong.
--
--   And by the time a sheet is three or six working days late, the person who
--   can do something about it is the manager. So +3 and +6 lead with the fact
--   and the ask, and name the employee rather than addressing them.
--
-- TWO SMALLER INACCURACIES, WHILE HERE
-- ════════════════════════════════════
--   "due tomorrow" (-1) and "3 days overdue" / "6 days overdue" state intervals
--   the rule cannot actually compute. A rule fires N WORKING days from the
--   period end, while the deadline is the period end plus submission_grace_days
--   -- so on Dev, with a grace day, the +3 rule fires three working days after
--   the period ends and two working days after the deadline. "-1" fires the
--   working day before the period ends, which with a grace day is two days
--   before the deadline, not "tomorrow".
--
--   Rather than compute a phrase nobody asked for, the text now names
--   {{deadline}} and says nothing about how long ago it was. A date is right on
--   every calendar, in every schedule, under any grace setting.
--
-- WHAT IS AND IS NOT OVERWRITTEN
-- ══════════════════════════════
--   Two independent guards, because these are two separate decisions an
--   administrator may have made:
--
--     wording     -- replaced ONLY where message_template is still byte-identical
--                    to what 701 seeded. Edit it on the screen and this migration
--                    leaves that rule entirely alone, here and in every later
--                    environment.
--     recipients  -- set ONLY where they are still the default {employee}. An
--                    environment that has already chosen who gets copied keeps
--                    that choice, even if its wording is untouched.
--
--   Neither guard is a marker or a version flag: each asks whether the value is
--   still the one that shipped. A rule someone has changed is a rule someone
--   has an opinion about.
--
--   Not touched at all: offset_days, notification_type, is_active, sort_order.
--   Nothing is inserted and nothing is deleted -- an environment that removed a
--   rule keeps it removed.
--
-- WHY A MIGRATION AND NOT THE SCREEN
-- ══════════════════════════════════
--   Typing it into Dev's Submission Config fixes Dev. UAT and Prod would each
--   come up with 701's wording and wait for somebody to remember. Seeded here,
--   the corrected default travels with the code and stays editable afterwards,
--   which is the same reason the schedule itself lives in a table.
--
-- SAFETY
--   * Every UPDATE is guarded by an equality on the shipped value, so a second
--     run matches nothing. Verified by running three times.
--   * Reports per rule whether it was updated or deliberately left alone.
--   * Verified against a real PostgreSQL 16, including a customised environment.
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_old_m1 CONSTANT text := 'Hi {{employee_name}}, your timesheet for {{period}} is due tomorrow. Please submit before end of day.';
  v_old_m2 CONSTANT text := 'Hi {{employee_name}}, your timesheet for {{period}} is 3 days overdue. Please submit immediately.';
  v_old_m3 CONSTANT text := 'URGENT: {{employee_name}}, your timesheet for {{period}} is 6 days overdue. HR has been notified.';
  v_n integer; v_words integer := 0; v_rcpts integer := 0;
BEGIN

  -- ── -1 · still the employee's own reminder ────────────────────────────────
  -- Recipients unchanged: this one is addressed to the employee because the
  -- employee is the only one who needs it before the deadline. Only the
  -- uncomputable "tomorrow" becomes the actual date.
  UPDATE time_submission_config
  SET    title_template   = 'Your {{period}} timesheet is due',
         message_template = 'Your {{period}} timesheet has not been submitted yet. '
                            'It is due on {{deadline}} — please submit it before then.'
  WHERE  offset_days = -1 AND message_template = v_old_m1;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_words := v_words + v_n;
  RAISE NOTICE 'MIG 864: rule -1 wording — % row(s) updated%', v_n,
    CASE WHEN v_n = 0 THEN ' (already edited here, left alone)' ELSE '' END;

  -- ── +3 · the manager is who can act ───────────────────────────────────────
  UPDATE time_submission_config
  SET    title_template   = 'Action needed: {{employee_name}}''s {{period}} timesheet is not submitted',
         message_template = '{{employee_name}} has not submitted the {{period}} timesheet. '
                            'It was due on {{deadline}}. Please follow up so the period can '
                            'be closed. {{employee_name}} is copied on this message.'
  WHERE  offset_days = 3 AND message_template = v_old_m2;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_words := v_words + v_n;
  RAISE NOTICE 'MIG 864: rule +3 wording — % row(s) updated%', v_n,
    CASE WHEN v_n = 0 THEN ' (already edited here, left alone)' ELSE '' END;

  -- ── +6 · an escalation is only an escalation if it says who is watching ───
  -- "HR is now copied" is the whole difference between this and +3 once both
  -- are written manager-first. Without it the second message is just the first
  -- one repeated louder, and people learn to ignore both.
  UPDATE time_submission_config
  SET    title_template   = 'Escalation: {{employee_name}}''s {{period}} timesheet is still not submitted',
         message_template = '{{employee_name}}''s {{period}} timesheet is still not submitted. '
                            'It was due on {{deadline}} and HR is now copied on this message. '
                            'Please ensure it is submitted and approved without further delay.'
  WHERE  offset_days = 6 AND message_template = v_old_m3;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_words := v_words + v_n;
  RAISE NOTICE 'MIG 864: rule +6 wording — % row(s) updated%', v_n,
    CASE WHEN v_n = 0 THEN ' (already edited here, left alone)' ELSE '' END;

  -- ── recipients, only where nobody has chosen yet ──────────────────────────
  -- A separate guard from the wording. On Dev the recipients were set by hand
  -- before this migration existed and are NOT the default, so these two
  -- statements will correctly do nothing there while still seeding a fresh
  -- environment. Manager-first words delivered to the employee alone would read
  -- strangely, so the two halves ship together or not at all.
  UPDATE time_submission_config
  SET    recipients = ARRAY['employee', 'manager', 'role:hr']
  WHERE  offset_days = 3 AND recipients = ARRAY['employee'];
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_rcpts := v_rcpts + v_n;

  UPDATE time_submission_config
  SET    recipients = ARRAY['employee', 'manager', 'role:hr', 'role:hr_head']
  WHERE  offset_days = 6 AND recipients = ARRAY['employee'];
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_rcpts := v_rcpts + v_n;

  RAISE NOTICE 'MIG 864: recipients seeded on % rule(s) that were still at the default.', v_rcpts;
  RAISE NOTICE 'MIG 864: % of 3 rules reworded.', v_words;
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_bad text;
BEGIN
  -- No rule that reaches anyone besides the employee may address the reader in
  -- the second person. This is the actual defect, stated as a rule rather than
  -- as three fixed strings, so a future edit that reintroduces it fails here.
  SELECT string_agg(format('offset %s', offset_days), ', ')
  INTO   v_bad
  FROM   time_submission_config
  WHERE  is_active
    AND  recipients <> ARRAY['employee']
    AND  (message_template ILIKE '%your timesheet%'
       OR title_template   ILIKE '%your %timesheet%');
  IF v_bad IS NOT NULL THEN
    RAISE WARNING 'MIG 864: rule(s) % are copied to people other than the employee but still say "your timesheet". Reword them on Submission Config — this migration will not overwrite text somebody has edited.', v_bad;
  END IF;

  -- The tokens must still be the three that exist. A typo'd token renders as
  -- literal braces in somebody's inbox and there is no other check for it.
  SELECT string_agg(format('offset %s', offset_days), ', ')
  INTO   v_bad
  FROM   time_submission_config,
         LATERAL regexp_matches(coalesce(title_template, '') || ' ' || message_template,
                                '\{\{([a-z_]+)\}\}', 'g') m
  WHERE  m[1] NOT IN ('employee_name', 'period', 'deadline');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'MIG 864 FAILED: rule(s) % use a token that does not exist. Only {{employee_name}}, {{period}} and {{deadline}} are substituted.', v_bad;
  END IF;

  IF EXISTS (SELECT 1 FROM time_submission_config
             WHERE title_template IS NULL OR trim(title_template) = ''
                OR trim(message_template) = '') THEN
    RAISE EXCEPTION 'MIG 864 FAILED: a rule has an empty subject or body.';
  END IF;
END;
$v$;

COMMIT;
