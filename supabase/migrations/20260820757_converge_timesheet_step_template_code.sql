-- Migration : 20260820757_converge_timesheet_step_template_code.sql
-- Purpose   : Make every environment agree on ONE code for the step-level
--             timesheet notification. Right now they would not.
--
-- How the split happened :
--   753 was committed and pushed once, creating 'timesheet.hr_review' on Dev.
--   Its CONTENT was then edited -- renaming the code to
--   'timesheet.hr_task_assigned' so that NotificationConfig.getCategory() would
--   file it under Task instead of General -- and pushed again.
--
--   `supabase db push` keys on the migration VERSION, not its contents. Version
--   20260819753 was already recorded as applied, so the second push skipped the
--   file and reported success. Dev therefore still has 'timesheet.hr_review'.
--   UAT and Prod have never run 753 at all, so when they do they will run the
--   CURRENT file and create 'timesheet.hr_task_assigned'.
--
--   Migration replay stayed green throughout, because it rebuilds from an empty
--   shadow database where the current file does run. The two CI workflows were
--   both telling the truth about different things.
--
-- Why converge on 'timesheet.hr_review' :
--   The rename existed only to satisfy a substring rule. 756 makes category a
--   stored column, so a code no longer has to contain the word 'task' to file
--   as one -- and 'hr_review' says what the message is for, which is what a code
--   should do. It is also what Dev already has, so this migration is a no-op
--   there and does its work only where 753 has yet to run.
--
-- Safe on every environment, in any order :
--   Dev            hr_review exists, hr_task_assigned does not  -> nothing to do
--   UAT / Prod     753 runs first and creates hr_task_assigned  -> renamed here
--   Fresh replay   same as UAT
--   Re-run         idempotent -- the UPDATE matches nothing the second time
--
-- Renaming is safe for bindings. workflow_steps.notification_template_id and
-- workflow_template_notifications.notification_template_id both reference the
-- row by id; nothing in the schema joins on code except wf_queue_notification's
-- final lookup, which reads the code off the row it just resolved.
--
-- Depends on : 753 (creates one or the other), 756 (removes the reason for the
--              rename)

DO $conv$
DECLARE
  v_old_id uuid;
  v_new_id uuid;
BEGIN
  SELECT id INTO v_old_id FROM workflow_notification_templates
  WHERE  code = 'timesheet.hr_task_assigned';

  SELECT id INTO v_new_id FROM workflow_notification_templates
  WHERE  code = 'timesheet.hr_review';

  IF v_old_id IS NULL THEN
    RAISE NOTICE
      'mig 757: nothing to converge — timesheet.hr_task_assigned is not present '
      '(expected on Dev, where 753 ran before the rename)';

  ELSIF v_new_id IS NULL THEN
    -- The ordinary case on UAT and Prod: 753 created the renamed code, and this
    -- puts it back to the name Dev carries.
    UPDATE workflow_notification_templates
    SET    code       = 'timesheet.hr_review',
           updated_at = now()
    WHERE  id = v_old_id;

    RAISE NOTICE 'mig 757: renamed timesheet.hr_task_assigned -> timesheet.hr_review';

  ELSE
    -- Both exist. Only reachable if someone created one by hand. Do not guess
    -- which one is bound; leave both and say so loudly, because silently
    -- deleting a template an approval step may point at is worse than a warning.
    RAISE WARNING
      'mig 757: BOTH timesheet.hr_review and timesheet.hr_task_assigned exist. '
      'Left as-is — check which one steps are bound to and delete the other by hand.';
  END IF;
END
$conv$;


-- ── Assertion ────────────────────────────────────────────────────────────────
-- The state this migration exists to prevent is an environment carrying the
-- renamed code. Anything else -- one row, the right name, or neither because
-- 753 has not run -- is fine.
DO $chk$
DECLARE
  v_stale int;
  v_good  int;
BEGIN
  SELECT count(*) INTO v_stale FROM workflow_notification_templates
  WHERE  code = 'timesheet.hr_task_assigned';

  SELECT count(*) INTO v_good FROM workflow_notification_templates
  WHERE  code = 'timesheet.hr_review';

  IF v_stale > 0 AND v_good = 0 THEN
    RAISE EXCEPTION 'mig 757 assert: timesheet.hr_task_assigned survived the rename';
  END IF;

  RAISE NOTICE 'mig 757: converged — hr_review present: %, stale code present: %',
               v_good > 0, v_stale > 0;
END
$chk$;
