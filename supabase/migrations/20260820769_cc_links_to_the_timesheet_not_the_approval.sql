-- Migration : 20260820769_cc_links_to_the_timesheet_not_the_approval.sql
-- Purpose   : Send a CC recipient to the record they are being shown, not to the
--             screen for deciding on it.
--
-- 765 gave approvers a deep link to /workflow/review/<record_id>. That was right
-- for approvers and wrong for the people copied alongside them: CC recipients
-- are "distinct from the submitter", so they inherited the approver's link and
-- land on a page offering Approve and Send Back — controls a notify-only step
-- exists precisely to withhold. 768 stopped the WORDS inviting them to act; this
-- stops the LINK doing it.
--
-- WHERE A CC RECIPIENT SHOULD LAND
--   On a timesheet, at the timesheet: /timesheet/<employee_id>?period=YYYY-MM.
--   That route is MyTimesheet viewing somebody else's month. It carries no
--   approval controls, and it deliberately has no permission on the route
--   itself — MyTimesheet asks time_timesheet_access for THAT employee and
--   refuses in place, because access is per-employee and a route guard can only
--   ask the flat "do you hold it at all". So a CC recipient without access gets
--   a clear refusal about this employee rather than a screen full of buttons
--   that will not work.
--
--   Both values come from the instance metadata submit_timesheet writes (742):
--   employee_id is the employees.id the route expects, and period is already
--   'YYYY-MM', which is exactly what MyTimesheet's parsePeriod() accepts.
--
--   Other modules keep '/workflow/inbox' for CC. There is no generic read-only
--   record view to send them to, and inventing a destination that renders the
--   wrong thing is worse than a list. When one exists, extend the CASE here.
--
-- BEING BOTH AT ONCE
--   One person can be CC on one step and a real approver on another. Treating
--   them as CC would then hide work they actually have to do. So this only
--   treats somebody as CC when they have a CC task on the instance AND no
--   PENDING non-CC task of their own. Real work wins.
--
-- Depends on : 765 (the approver deep link this refines), 768 (the CC wording),
--              742 (timesheet metadata), 501093 (is_cc)

CREATE OR REPLACE FUNCTION public._wf_notification_link(
  p_instance_id    uuid,
  p_target_profile uuid
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_module       text;
  v_record_id    uuid;
  v_submitted_by uuid;
  v_metadata     jsonb;
  v_is_cc        boolean;
  v_emp          text;
  v_period       text;

  -- Mirrors FULL_REVIEW_MODULES in src/workflow/screens/ApproverInbox.tsx.
  c_full_review CONSTANT text[] := ARRAY[
    'expense_reports',
    'employee_hire',
    'profile_employment',
    'termination',
    'termination_reversal',
    'timesheet'
  ];
BEGIN
  SELECT wi.module_code, wi.record_id, wi.submitted_by, wi.metadata
  INTO   v_module, v_record_id, v_submitted_by, v_metadata
  FROM   workflow_instances wi
  WHERE  wi.id = p_instance_id;

  IF NOT FOUND THEN
    RETURN '/workflow/my-requests';
  END IF;

  -- Expense keeps its own screen.
  IF v_module = 'expense_reports' THEN
    RETURN '/expense/report/' || v_record_id::text;
  END IF;

  -- ── Submitter ─────────────────────────────────────────────────────────────
  IF p_target_profile IS NOT DISTINCT FROM v_submitted_by THEN
    RETURN '/workflow/my-requests';
  END IF;

  -- ── CC, but only if they have nothing of their own to act on ──────────────
  SELECT EXISTS (
           SELECT 1 FROM workflow_tasks t
           WHERE  t.instance_id = p_instance_id
             AND  t.assigned_to = p_target_profile
             AND  t.is_cc IS TRUE
         )
         AND NOT EXISTS (
           SELECT 1 FROM workflow_tasks t
           WHERE  t.instance_id = p_instance_id
             AND  t.assigned_to = p_target_profile
             AND  t.is_cc IS NOT TRUE
             AND  t.status = 'pending'
         )
  INTO   v_is_cc;

  IF v_is_cc THEN
    IF v_module = 'timesheet' THEN
      v_emp    := v_metadata ->> 'employee_id';
      v_period := v_metadata ->> 'period';

      -- Guarded rather than assumed: a link built from a missing id is a broken
      -- page, and the inbox is a poor destination but an honest one.
      IF v_emp IS NOT NULL AND v_emp <> '' THEN
        RETURN '/timesheet/' || v_emp
               || CASE WHEN v_period ~ '^\d{4}-\d{2}$'
                       THEN '?period=' || v_period
                       ELSE '' END;
      END IF;
    END IF;

    RETURN '/workflow/inbox';
  END IF;

  -- ── Approver ──────────────────────────────────────────────────────────────
  IF v_record_id IS NOT NULL AND v_module = ANY (c_full_review) THEN
    RETURN '/workflow/review/' || v_record_id::text;
  END IF;

  RETURN '/workflow/inbox';
END;
$fn$;

COMMENT ON FUNCTION public._wf_notification_link(uuid, uuid) IS
  'Deep link for a workflow notification. Submitters go to /workflow/my-requests. '
  'CC recipients go to the record read-only — for timesheet, '
  '/timesheet/<employee_id>?period=YYYY-MM — never to a screen with approval '
  'controls; other modules fall back to the inbox until they have such a view. '
  'Approvers go to /workflow/review/<record_id> for modules with a full-review '
  'screen (list mirrors FULL_REVIEW_MODULES in ApproverInbox.tsx). Somebody who '
  'is both CC and a pending approver is treated as an approver.';


-- ── Assertions ───────────────────────────────────────────────────────────────
-- A wrong link raises nothing anywhere: the email sends and the button renders.
-- The only way to know is to run the function against real rows.
DO $chk$
DECLARE
  r        record;
  v_link   text;
  v_cc     int := 0;
  v_appr   int := 0;
BEGIN
  -- CC on a timesheet must never resolve to the approval screen.
  FOR r IN
    SELECT DISTINCT wi.id, wi.metadata, t.assigned_to
    FROM   workflow_instances wi
    JOIN   workflow_tasks t ON t.instance_id = wi.id
    WHERE  wi.module_code = 'timesheet'
      AND  t.is_cc IS TRUE
      AND  t.assigned_to IS DISTINCT FROM wi.submitted_by
    LIMIT  5
  LOOP
    v_link := _wf_notification_link(r.id, r.assigned_to);

    IF v_link LIKE '/workflow/review/%' THEN
      RAISE EXCEPTION
        'mig 769 assert: a CC recipient still resolves to the approval screen (%)', v_link;
    END IF;

    IF (r.metadata ->> 'employee_id') IS NOT NULL
       AND v_link NOT LIKE '/timesheet/%'
       AND NOT EXISTS (SELECT 1 FROM workflow_tasks t2
                       WHERE t2.instance_id = r.id AND t2.assigned_to = r.assigned_to
                         AND t2.is_cc IS NOT TRUE AND t2.status = 'pending') THEN
      RAISE EXCEPTION
        'mig 769 assert: CC on a timesheet with employee_id in metadata resolved to %, '
        'expected the timesheet', v_link;
    END IF;

    v_cc := v_cc + 1;
  END LOOP;

  -- And a real approver must still land on the record.
  FOR r IN
    SELECT wi.id, wi.record_id, t.assigned_to
    FROM   workflow_instances wi
    JOIN   workflow_tasks t ON t.instance_id = wi.id
    WHERE  wi.module_code = 'timesheet'
      AND  t.is_cc IS NOT TRUE
      AND  t.assigned_to IS DISTINCT FROM wi.submitted_by
      AND  wi.record_id IS NOT NULL
    LIMIT  3
  LOOP
    v_link := _wf_notification_link(r.id, r.assigned_to);
    IF v_link <> '/workflow/review/' || r.record_id::text THEN
      RAISE EXCEPTION
        'mig 769 assert: approver link resolved to %, expected the record', v_link;
    END IF;
    v_appr := v_appr + 1;
  END LOOP;

  RAISE NOTICE 'mig 769: % CC and % approver link(s) verified', v_cc, v_appr;

  IF v_cc = 0 THEN
    RAISE NOTICE
      'mig 769: no timesheet CC task on this database — the CC branch changed '
      'but was not exercised here';
  END IF;
END
$chk$;
