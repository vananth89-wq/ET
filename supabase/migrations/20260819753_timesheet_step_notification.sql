-- Migration : 20260819753_timesheet_step_notification.sql
-- Purpose   : Author the wording for the STEP that approves a timesheet, so the
--             Notification dropdown in the step editor has a real option to
--             select and the precedence chain from 748 can be exercised
--             end to end.
--
-- Why this is a separate template from timesheet.task_assigned (749) :
--             They answer different questions. 749's wording is what the
--             workflow says by default when ANY step of a timesheet approval
--             lands in someone's queue. This one is what a SPECIFIC step says.
--             On today's single-step Timesheet v1 they address the same person,
--             which is exactly what makes it a good test: the two are visibly
--             different, so whichever arrives tells you unambiguously which
--             level resolved.
--
-- Why the code carries 'task' :
--             NotificationConfig.getCategory() derives the Task / SLA /
--             Approval / Returned / Admin / General chips from substrings of
--             the code -- there is no category column. A code without one of
--             those substrings lands in General, which is wrong for an
--             assignment message and makes it invisible under the Task filter.
--             'timesheet.hr_task_assigned' sorts under Task, next to the
--             template it is meant to be compared with.
--
-- Placeholders : same constraint as 749 -- only what submit_timesheet (mig 742)
--             puts in workflow_instances.metadata is substitutable. This uses
--             employee_name and period_label only. planned_minutes and
--             recorded_minutes are again avoided: they are raw integers and
--             would render "4560" where a reader expects "76 h".
--
--             NOTE the token list shown on the Notifications screen is the
--             GENERIC workflow vocabulary -- approver_name, submitter_name,
--             record_label, reason. None of those exist in timesheet instance
--             metadata, so a timesheet template that uses one renders the
--             literal braces. docs/notification_checks.sql Q5 catches exactly
--             this.
--
-- DELIBERATELY NOT BOUND to any step. The binding is
--             workflow_steps.notification_template_id, and setting it from a
--             migration would defeat the point -- the thing worth proving is
--             that the dropdown in the step editor writes it and that
--             wf_queue_notification then reads it. A migration that quietly did
--             the binding would make a broken dropdown look like a working one.
--             Bind it in the UI: Workflow -> Templates -> TIMESHEET -> Edit
--             step 1 -> Notification -> timesheet.hr_task_assigned.
--
-- Precedence this exercises (wf_queue_notification, patched by 748) :
--             1. step      workflow_steps.notification_template_id
--                          -- only for wf.task_assigned, only at the CURRENT step
--             2. template  workflow_template_notifications  (749 wrote these)
--             3. module    the '<module>.' prefix convention (519250)
--             4. generic   the raw wf.* code
--             Step is checked first and the template lookup is skipped once the
--             step has answered, so binding this template makes it BEAT
--             timesheet.task_assigned on the assignment message. Nothing else
--             changes: completed and clarification still resolve at level 2.
--
-- Depends on : 748 (resolution order), 749 (the template-level wording it is
--              meant to be compared against), 501093
--              (workflow_steps.notification_template_id)

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES
  ('timesheet.hr_task_assigned',
   'HR review: {{employee_name}} — {{period_label}} timesheet',
   'A timesheet is waiting on HR. Open the month to see it day by day, '
   'including anything recorded beyond plan, then approve it or send it back '
   'with a note saying what needs changing.')
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl;


-- ── Assertion ────────────────────────────────────────────────────────────────
-- Data-only migration, so the only thing that can go wrong is the row not
-- landing. Worth catching here rather than in a dropdown that renders one
-- option short.
DO $chk$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM   workflow_notification_templates
  WHERE  code = 'timesheet.hr_task_assigned';

  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 753 assert: timesheet.hr_task_assigned not present after insert';
  END IF;

  RAISE NOTICE
    'mig 753: timesheet.hr_task_assigned authored — bind it to a step in the UI '
    'to test step-level precedence';
END
$chk$;
