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
--   template VERSION, resolved through workflow_assignments -- the same route
--   submit_timesheet takes. NOT through workflow_templates.module_code, which
--   mig 504118 decoupled from routing on purpose.
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


-- ── 2. Tag them to whichever workflow timesheets actually use ────────────────
-- Resolved through workflow_assignments, NOT workflow_templates.module_code.
-- Mig 504118 decoupled a template from the module it serves precisely so one
-- template can be reused; the routing lives in the assignment. An earlier draft
-- of this migration matched on workflow_templates.module_code = 'timesheet' and
-- found nothing, because that column says what the template was authored for,
-- not what submits through it. submit_timesheet resolves the same way, via
-- resolve_workflow_for_submission('timesheet', ...).
--
-- Every template referenced by a timesheet assignment is tagged, active or not:
-- an assignment switched back on later should not come back wordless.
INSERT INTO workflow_template_notifications
  (template_id, event_code, notification_template_id)
SELECT DISTINCT wa.wf_template_id, m.event_code, n.id
FROM   workflow_assignments wa
JOIN   (VALUES
          ('wf.task_assigned',          'timesheet.task_assigned'),
          ('wf.completed',              'timesheet.completed'),
          ('wf.clarification_requested','timesheet.clarification_requested')
       ) AS m(event_code, tmpl_code) ON true
JOIN   workflow_notification_templates n ON n.code = m.tmpl_code
WHERE  wa.module_code = 'timesheet'
ON CONFLICT (template_id, event_code) DO UPDATE
  SET notification_template_id = EXCLUDED.notification_template_id,
      updated_at               = now();


-- ── Assertions ───────────────────────────────────────────────────────────────
-- Deployable to an environment where nobody has configured timesheet approval
-- yet -- UAT and Prod will hit exactly that. So "no assignment" is a NOTICE, not
-- a failure: the wording is written and waits to be tagged.
--
-- What IS a failure is an assignment existing and the tags not landing, because
-- that means this query is wrong again and the wording would silently never
-- reach anyone -- which looks identical to success from the deploy log.
DO $chk$
DECLARE
  v_words int;
  v_tpls  int;
  v_tags  int;
BEGIN
  SELECT count(*) INTO v_words
  FROM   workflow_notification_templates
  WHERE  code LIKE 'timesheet.%';

  IF v_words <> 3 THEN
    RAISE EXCEPTION 'mig 749 assert: expected 3 timesheet.* templates, found %', v_words;
  END IF;

  SELECT count(DISTINCT wa.wf_template_id) INTO v_tpls
  FROM   workflow_assignments wa
  WHERE  wa.module_code = 'timesheet';

  IF v_tpls = 0 THEN
    RAISE NOTICE
      'mig 749: wording written, but no workflow is assigned to timesheets yet — '
      'tag the events once an assignment exists';
    RETURN;
  END IF;

  SELECT count(*) INTO v_tags
  FROM   workflow_template_notifications wtn
  WHERE  wtn.template_id IN (SELECT wf_template_id FROM workflow_assignments
                             WHERE module_code = 'timesheet')
    AND  wtn.event_code IN ('wf.task_assigned','wf.completed','wf.clarification_requested');

  IF v_tags <> v_tpls * 3 THEN
    RAISE EXCEPTION
      'mig 749 assert: expected % tags (% template(s) x 3 events), found %',
      v_tpls * 3, v_tpls, v_tags;
  END IF;

  RAISE NOTICE 'mig 749: % workflow template(s) tagged, % rows', v_tpls, v_tags;
END
$chk$;
