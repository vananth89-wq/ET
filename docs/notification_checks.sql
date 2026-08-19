-- ═══════════════════════════════════════════════════════════════════════════
--  Notification checks — read-only. Paste into the Supabase SQL editor.
--  Nothing here writes. Run the queries one at a time.
--
--  Q1 and Q2 check the CONFIGURATION and can be run right now.
--  Q3 and Q4 check what a real run actually SENT, so run them after a submit.
--  Q5 catches the failure mode that is invisible until an email lands: a
--  placeholder that does not exist, which renders as literal {{braces}}.
-- ═══════════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────────
-- Q1. What wording does each event resolve to today?
--
-- Mirrors the order wf_queue_notification uses (mig 748): step first, then
-- template, then the generic wf.* code. The step column is evaluated at step 1,
-- which is where wf_submit creates the first task; a multi-step workflow
-- resolves against whichever step is current when the event fires.
-- ───────────────────────────────────────────────────────────────────────────
WITH tpl AS (
  SELECT DISTINCT wa.wf_template_id AS template_id
  FROM   workflow_assignments wa
  WHERE  wa.module_code = 'timesheet'
),
ev(event_code) AS (
  VALUES ('wf.task_assigned'), ('wf.completed'), ('wf.rejected'),
         ('wf.returned_to_previous_step'), ('wf.clarification_requested'),
         ('wf.clarification_submitted'), ('wf.withdrawn'),
         ('wf.sla_reminder'), ('wf.sla_escalation')
)
SELECT
  wt.code || ' v' || wt.version                       AS workflow,
  ev.event_code,
  CASE WHEN step_n.code IS NOT NULL THEN '1 · step'
       WHEN tmpl_n.code IS NOT NULL THEN '2 · template'
       ELSE                              '4 · system default'
  END                                                 AS resolved_at,
  COALESCE(step_n.code, tmpl_n.code, ev.event_code)   AS template_code,
  COALESCE(step_n.title_tmpl, tmpl_n.title_tmpl,
           '(generic workflow wording)')              AS subject_line
FROM       tpl
JOIN       workflow_templates wt ON wt.id = tpl.template_id
CROSS JOIN ev
LEFT JOIN  workflow_steps ws
       ON  ws.template_id = tpl.template_id
       AND ws.step_order  = 1
       AND ev.event_code  = 'wf.task_assigned'
LEFT JOIN  workflow_notification_templates step_n ON step_n.id = ws.notification_template_id
LEFT JOIN  workflow_template_notifications wtn
       ON  wtn.template_id = tpl.template_id
       AND wtn.event_code  = ev.event_code
LEFT JOIN  workflow_notification_templates tmpl_n ON tmpl_n.id = wtn.notification_template_id
ORDER BY   workflow, ev.event_code;


-- ───────────────────────────────────────────────────────────────────────────
-- Q2. Which steps have their own notification bound?
--
-- Before binding anything in the UI this returns "(none)" for every step.
-- After binding, the step you edited should name timesheet.hr_review — that is
-- the dropdown proving it wrote.
-- ───────────────────────────────────────────────────────────────────────────
SELECT
  wt.code || ' v' || wt.version                     AS workflow,
  ws.step_order,
  ws.name                                           AS step,
  COALESCE(n.code, '(none)')                        AS notification,
  COALESCE(n.title_tmpl, '—')                       AS subject_line
FROM       workflow_steps ws
JOIN       workflow_templates wt ON wt.id = ws.template_id
LEFT JOIN  workflow_notification_templates n ON n.id = ws.notification_template_id
WHERE      ws.template_id IN (SELECT wf_template_id FROM workflow_assignments
                              WHERE module_code = 'timesheet')
ORDER BY   workflow, ws.step_order;


-- ───────────────────────────────────────────────────────────────────────────
-- Q3. What did the engine actually queue for timesheets?
--
-- template_code here is the code AFTER resolution, so it is the direct answer
-- to "did my override win". status 'pending' that never turns 'sent' means the
-- queue trigger or the Edge Function is the problem, not the wording.
-- ───────────────────────────────────────────────────────────────────────────
SELECT
  q.created_at,
  q.template_code,
  q.status,
  q.error_message,
  e.name                                            AS sent_to,
  e.business_email,
  wi.metadata ->> 'period_label'                    AS period,
  wi.metadata ->> 'employee_name'                   AS timesheet_of
FROM       workflow_notification_queue q
JOIN       workflow_instances wi ON wi.id = q.instance_id
LEFT JOIN  profiles  p ON p.id = q.target_profile
LEFT JOIN  employees e ON e.id = p.employee_id
WHERE      wi.module_code = 'timesheet'
ORDER BY   q.created_at DESC
LIMIT      25;


-- ───────────────────────────────────────────────────────────────────────────
-- Q4. The rendered text that reached the recipient.
--
-- This is the one that settles arguments: the substituted title and body as
-- stored, not the template. Any {{placeholder}} still visible here is a
-- variable that does not exist — see Q5.
-- ───────────────────────────────────────────────────────────────────────────
SELECT
  n.created_at,
  e.name                                            AS recipient,
  n.title,
  n.body,
  n.link,
  n.is_read
FROM       notifications n
LEFT JOIN  profiles  p ON p.id = n.profile_id
LEFT JOIN  employees e ON e.id = p.employee_id
WHERE      n.created_at > now() - interval '2 days'
ORDER BY   n.created_at DESC
LIMIT      25;


-- ───────────────────────────────────────────────────────────────────────────
-- Q5. Does every placeholder used actually exist?
--
-- The failure this catches is silent at configuration time and embarrassing at
-- delivery time: {{approver_name}} is not in the metadata submit_timesheet
-- writes, so it renders as the literal characters {{approver_name}} in an email
-- an approver reads. Compares the placeholders in every template bound to a
-- timesheet workflow against the keys real timesheet instances carry.
--
-- 'message' is expected to show as supplied-by-action: it is added to the
-- payload by the clarification call, not by the instance metadata.
-- ───────────────────────────────────────────────────────────────────────────
WITH bound AS (
  SELECT DISTINCT n.code,
         n.title_tmpl || ' ' || COALESCE(n.body_tmpl, '') AS txt
  FROM   workflow_template_notifications wtn
  JOIN   workflow_notification_templates n ON n.id = wtn.notification_template_id
  JOIN   workflow_assignments wa
         ON  wa.wf_template_id = wtn.template_id
         AND wa.module_code    = 'timesheet'
  UNION
  SELECT DISTINCT n.code,
         n.title_tmpl || ' ' || COALESCE(n.body_tmpl, '')
  FROM   workflow_steps ws
  JOIN   workflow_notification_templates n ON n.id = ws.notification_template_id
  JOIN   workflow_assignments wa
         ON  wa.wf_template_id = ws.template_id
         AND wa.module_code    = 'timesheet'
),
ph AS (
  SELECT code, (regexp_matches(txt, '\{\{\s*([a-zA-Z_]+)\s*\}\}', 'g'))[1] AS placeholder
  FROM   bound
),
mkeys AS (
  SELECT DISTINCT jsonb_object_keys(wi.metadata) AS k
  FROM   workflow_instances wi
  WHERE  wi.module_code = 'timesheet'
    AND  wi.metadata IS NOT NULL
)
SELECT DISTINCT
  ph.code                                           AS template_code,
  ph.placeholder,
  CASE
    WHEN ph.placeholder IN (SELECT k FROM mkeys) THEN 'ok'
    WHEN ph.placeholder = 'message'              THEN 'ok — supplied by the action'
    ELSE 'MISSING — renders as literal braces'
  END                                               AS status
FROM     ph
ORDER BY status DESC, template_code, placeholder;
