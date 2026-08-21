-- Migration : 20260820765_approver_deep_link_to_the_record.sql
-- Purpose   : Send an approver straight to the thing they have to decide on,
--             instead of to the queue it is sitting in.
--
-- WHAT IT DOES TODAY
--   _wf_notification_link (mig 595) resolves an approver's deep link to the bare
--   '/workflow/inbox'. So "HR review: Vijey Ananth — August 2026 timesheet"
--   arrives with a button that opens a LIST. On a quiet week that is one extra
--   click; on a busy one the approver has to find the row the email was about,
--   which is precisely the work the email had already done for them.
--
--   Expense was special-cased in 595 and already deep-links to its report. That
--   exception is the argument: someone hit this once, fixed the module in front
--   of them, and left the general case as it was.
--
-- WHERE AN APPROVER SHOULD LAND
--   ApproverInbox.tsx opens a task's full view at
--       /workflow/review/{record_id}
--   for every module in its FULL_REVIEW_MODULES set. WorkflowReview is generic —
--   it reads module_codes.edit_route to decide what to render — so the route
--   works for any module in that set, and for timesheet record_id IS the
--   timesheet header (submit_timesheet passes p_record_id => p_header_id).
--
--   The list below MIRRORS FULL_REVIEW_MODULES in
--   src/workflow/screens/ApproverInbox.tsx. Two places, deliberately: a module
--   that has no full-review screen must not be deep-linked into one from an
--   email, and the frontend is the authority on which those are. **Add a module
--   to one, add it to the other.** Anything not listed keeps today's behaviour
--   and lands on the inbox, which is correct rather than merely safe.
--
-- SUBMITTERS ARE UNCHANGED. They keep '/workflow/my-requests': a submitter is
--   usually being told the outcome, not asked to act, and their list is short
--   and their own. The one case worth revisiting later is a sent-back timesheet,
--   where the employee does have to act — but that is a separate decision and
--   this migration does not quietly make it.
--
-- Depends on : 595 (the function), 742 (timesheet registered, record_id = header)

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

  -- MIG 765: mirrors FULL_REVIEW_MODULES in ApproverInbox.tsx.
  c_full_review CONSTANT text[] := ARRAY[
    'expense_reports',
    'employee_hire',
    'profile_employment',
    'termination',
    'termination_reversal',
    'timesheet'
  ];
BEGIN
  SELECT wi.module_code, wi.record_id, wi.submitted_by
  INTO   v_module, v_record_id, v_submitted_by
  FROM   workflow_instances wi
  WHERE  wi.id = p_instance_id;

  IF NOT FOUND THEN
    RETURN '/workflow/my-requests';
  END IF;

  -- Expense keeps its own screen — not the generic review view.
  IF v_module = 'expense_reports' THEN
    RETURN '/expense/report/' || v_record_id::text;
  END IF;

  -- Approver
  IF p_target_profile IS DISTINCT FROM v_submitted_by THEN
    -- MIG 765: straight to the record when it has a full-review screen.
    -- record_id must exist — an instance without one cannot be deep-linked, and
    -- '/workflow/review/' with nothing after it is a broken page, not a fallback.
    IF v_record_id IS NOT NULL AND v_module = ANY (c_full_review) THEN
      RETURN '/workflow/review/' || v_record_id::text;
    END IF;
    RETURN '/workflow/inbox';
  END IF;

  -- Submitter
  RETURN '/workflow/my-requests';
END;
$fn$;

COMMENT ON FUNCTION public._wf_notification_link(uuid, uuid) IS
  'Deep link for a workflow notification. Approvers go to the record itself '
  '(/workflow/review/<record_id>) for modules that have a full-review screen, '
  'and to /workflow/inbox otherwise; submitters go to /workflow/my-requests. '
  'The module list mirrors FULL_REVIEW_MODULES in ApproverInbox.tsx — update '
  'both together.';


-- ── Assertions ───────────────────────────────────────────────────────────────
-- A wrong link is not an error anywhere: the email sends, the button renders,
-- and the approver simply lands somewhere unhelpful. So check the behaviour
-- against real instances rather than trusting the edit.
DO $chk$
DECLARE
  v_inst   record;
  v_link   text;
  v_tested int := 0;
BEGIN
  -- A timesheet instance, seen by its approver, must now resolve to the record.
  FOR v_inst IN
    SELECT wi.id, wi.record_id, wt.assigned_to
    FROM   workflow_instances wi
    JOIN   workflow_tasks wt ON wt.instance_id = wi.id
    WHERE  wi.module_code = 'timesheet'
      AND  wt.assigned_to IS DISTINCT FROM wi.submitted_by
      AND  wi.record_id IS NOT NULL
    LIMIT  3
  LOOP
    v_link := _wf_notification_link(v_inst.id, v_inst.assigned_to);
    IF v_link <> '/workflow/review/' || v_inst.record_id::text THEN
      RAISE EXCEPTION
        'mig 765 assert: timesheet approver link resolved to %, expected the record', v_link;
    END IF;
    v_tested := v_tested + 1;
  END LOOP;

  IF v_tested = 0 THEN
    RAISE NOTICE
      'mig 765: no timesheet instance with a distinct approver on this database — '
      'link logic changed but not exercised here';
  ELSE
    RAISE NOTICE 'mig 765: approver deep-link verified against % timesheet instance(s)', v_tested;
  END IF;

  -- And a submitter must NOT have moved.
  SELECT wi.id, wi.submitted_by INTO v_inst
  FROM   workflow_instances wi
  WHERE  wi.submitted_by IS NOT NULL
  LIMIT  1;

  IF FOUND THEN
    v_link := _wf_notification_link(v_inst.id, v_inst.submitted_by);
    IF v_link NOT IN ('/workflow/my-requests') AND v_link NOT LIKE '/expense/report/%' THEN
      RAISE EXCEPTION
        'mig 765 assert: submitter link changed to % — this migration must not touch them', v_link;
    END IF;
  END IF;
END
$chk$;
