-- Migration : 20260818749_timesheet_notification_wording.sql
-- Purpose   : Give the timesheet its own notification wording, using the
--             override mechanism from 748. No engine change; this is data.
--
-- Why the generic text was wrong :
--   "New approval task: Timesheet / You have a new task waiting for your
--   approval" tells an approver nothing they could act on -- not whose month,
--   not which month, not whether it is worth opening now.
--   "Request fully approved" reaches an employee who did not submit a request;
--   they filed a timesheet, and the word "request" is from a different module's
--   vocabulary.
--
-- Placeholders : resolved from workflow_instances.metadata, which
--   submit_timesheet (mig 742) fills with employee_id, employee_name, period,
--   period_label, planned_minutes, recorded_minutes and external_code.
--   wf_queue_notification merges that into the payload before substitution.
--
--   ONLY period_label, employee_name and external_code are used below.
--   planned_minutes / recorded_minutes are deliberately NOT used: they are raw
--   integers, so {{recorded_minutes}} renders "4560" where a reader expects
--   "76 h". A template cannot format them, so a notification must not promise
--   a number it can only print wrong.
--
--   approver_name and approved_on do NOT exist in the metadata. An earlier
--   draft of this wording used both; they would have rendered as the literal
--   text "{{approver_name}}", which is worse than not mentioning the approver.
--
-- Tagging : rows go in workflow_template_notifications, keyed on the workflow
--   template VERSION, resolved by module_code rather than a hardcoded template
--   code so this does not depend on what the template happens to be named.
--   EVERY version carrying module_code = 'timesheet' is tagged, so a month
--   already in flight on an older version gets the new wording too.
--
-- Depends on : 748 (workflow_template_notifications + resolution),
--              742 (timesheet registered, metadata populated)

-- ── 1. The wording ───────────────────────────────────────────────────────────
INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES
  ('timesheet.task_assigned',
   '{{employee_name}} — {{period_label}} timesheet to approve',
   'A timesheet has been submitted for your approval. Open it to see the month '
   'day by day, including anything recorded beyond plan, before you approve it '
   'or send it back for correction.'),

  ('timesheet.completed',
   'Your {{period_label}} timesheet has been approved',
   'No further action is needed. You can still open the month to view it, and '
   'any change you make from now on will be visible to your approver.'),

  ('timesheet.clarification_requested',
   'Your {{period_label}} timesheet was sent back',
   'An approver has asked for a correction before it can be approved. '
   'Message: {{message}}. The month is open for editing again — submit it once '
   'you have made the change.')
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl;


-- ── 2. Tag them to every timesheet workflow version ──────────────────────────
INSERT INTO workflow_template_notifications
  (template_id, event_code, notification_template_id)
SELECT t.id, m.event_code, n.id
FROM   workflow_templates t
JOIN   (VALUES
          ('wf.task_assigned',          'timesheet.task_assigned'),
          ('wf.completed',              'timesheet.completed'),
          ('wf.clarification_requested','timesheet.clarification_requested')
       ) AS m(event_code, tmpl_code) ON true
JOIN   workflow_notification_templates n ON n.code = m.tmpl_code
WHERE  t.module_code = 'timesheet'
ON CONFLICT (template_id, event_code) DO UPDATE
  SET notification_template_id = EXCLUDED.notification_template_id,
      updated_at               = now();


-- ── Assertions ───────────────────────────────────────────────────────────────
-- The tag rows depend on a timesheet workflow template EXISTING. If none does,
-- the INSERT above quietly writes nothing and the wording never reaches anyone,
-- which would look exactly like success.
DO $chk$
DECLARE
  v_versions int;
  v_tags     int;
BEGIN
  SELECT count(*) INTO v_versions
  FROM   workflow_templates WHERE module_code = 'timesheet';

  IF v_versions = 0 THEN
    RAISE EXCEPTION
      'mig 749 assert: no workflow_templates row with module_code = timesheet — '
      'the wording was written but could not be tagged to anything';
  END IF;

  SELECT count(*) INTO v_tags
  FROM   workflow_template_notifications wtn
  JOIN   workflow_templates t ON t.id = wtn.template_id
  WHERE  t.module_code = 'timesheet';

  IF v_tags <> v_versions * 3 THEN
    RAISE EXCEPTION
      'mig 749 assert: expected % tags (% versions x 3 events), found %',
      v_versions * 3, v_versions, v_tags;
  END IF;

  RAISE NOTICE 'mig 749: % timesheet workflow version(s) tagged, % rows',
    v_versions, v_tags;
END
$chk$;
