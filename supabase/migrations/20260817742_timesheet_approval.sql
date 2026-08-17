-- Migration : 20260817742_timesheet_approval.sql
-- Purpose   : Put timesheets through the approval workflow, and give an
--             approver two answers only -- approve, or send back.
--
-- BACKGROUND
--   Migration 730 built submit_timesheet but deliberately stopped short of
--   starting a workflow instance, and said so in its own comment:
--
--       "The instance is NOT started here yet: the approver screens are on
--        hold until what exists has been tested, and a queue nobody can see
--        is the exact problem this migration is fixing. The template id is
--        returned so the caller can be wired to wf_submit in one place when
--        that lands."
--
--   That is what lands here. Migration 739 already added the RLS policies an
--   approver needs and left them dormant with the note "Dormant until the
--   timesheet module is registered in module_codes" -- PART 1 wakes them.
--
-- WHAT THIS DOES
--   1. Registers 'timesheet' in module_codes.
--   2. Normalises the workflow assignment vocabulary from 'timesheet_headers'
--      to 'timesheet' so the Workflow Assignments screen can see it.
--   3. Teaches wf_sync_module_status what a timesheet is.
--   4. Rewrites submit_timesheet to actually start (or resume) the workflow.
--   5. Rewrites withdraw_timesheet to cancel the instance it started.
--   6. Refuses wf_reject for timesheets -- approve or send back, nothing else.
--   7. Adds time_approval_payload(), one read for the whole approval screen.
--
-- WHY REJECT IS REFUSED, IN THE DATABASE AND NOT ONLY IN THE UI
--   A month has a true value. The only question an approver is answering is
--   whether it has been recorded correctly yet, and "no" is fully served by
--   sending it back: the sheet reopens, the employee fixes it, it returns.
--   Rejecting would park the month in a state nothing can clear -- there is no
--   'rejected' value in timesheet_headers.status to hold it, and no screen to
--   get out of it. Hiding the button is not the same as removing the
--   capability: wf_reject is a shared RPC that a stale tab, an admin with
--   workflow.admin, or a direct PostgREST call can still reach. PART 6 makes
--   the refusal a property of the data, not of the markup.
--
-- WHY THE PAYLOAD IS ONE SECURITY DEFINER RPC RATHER THAN MORE RLS
--   The approval screen needs the header, the entries, the employee, their
--   schedule, the holiday calendar, the projects, the time types and the
--   activity names. Migration 739 gave approvers SELECT on two of those eight.
--   Adding six more approver-shaped policies would spread the same predicate
--   across six tables and leave the screen half-rendering the moment one is
--   missed -- an approver outside the management chain would see hours with no
--   project names. One function that answers the whole question once, and
--   refuses once, is smaller and cannot half-fail.
--
-- Depends on : 704 (tables), 730 (submit/withdraw), 739 (approver RLS + the
--              retired permissions), 740 (time_timesheet_access), 741
--              (submit/withdraw gate on user_can, workflow resolved for the
--              sheet's employee)

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — register the module
-- ═══════════════════════════════════════════════════════════════════════════
-- module_codes is the FK anchor for workflow_instances.module_code and the
-- source the Workflow Assignments screen reads to list modules. Without this
-- row wf_submit cannot insert an instance at all.
--
-- approval_write_permission and approval_writable_statuses stay NULL, and so
-- does edit_route. That is the load-bearing part: the Approver Inbox shows its
-- Update button only when a module has an edit route (Pattern A) or an
-- approval write permission (Pattern B). Leaving both NULL means the button
-- cannot appear even if somebody later turns allow_edit on for a step.

INSERT INTO module_codes (
  code, label, description,
  table_name, owner_column, status_column, draft_status,
  permission_prefix, extra_view_permissions,
  write_permission, writable_statuses,
  approval_write_permission, approval_writable_statuses,
  edit_route
) VALUES (
  'timesheet',
  'Timesheet',
  'Monthly employee timesheets submitted for approval',
  'timesheet_headers',
  'employee_id',
  'status',
  'to_be_submitted',
  'timesheet',
  NULL,
  'timesheet.edit',
  ARRAY['to_be_submitted']::text[],
  NULL,               -- approvers never edit a timesheet
  NULL,
  NULL                -- no edit route: nothing to open in edit mode
)
ON CONFLICT (code) DO UPDATE SET
  label                      = EXCLUDED.label,
  description                = EXCLUDED.description,
  table_name                 = EXCLUDED.table_name,
  owner_column               = EXCLUDED.owner_column,
  status_column              = EXCLUDED.status_column,
  draft_status               = EXCLUDED.draft_status,
  permission_prefix          = EXCLUDED.permission_prefix,
  write_permission           = EXCLUDED.write_permission,
  writable_statuses          = EXCLUDED.writable_statuses,
  approval_write_permission  = NULL,
  approval_writable_statuses = NULL,
  edit_route                 = NULL;


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — one vocabulary for the assignment
-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 730 resolved the template with the TABLE name:
--
--     resolve_workflow_for_submission('timesheet_headers', auth.uid())
--
-- workflow_assignments.module_code is plain text with no FK, so that string
-- was accepted -- but the Workflow Assignments screen builds its module list
-- from module_codes, so an administrator had no way to create an assignment
-- under that name. The resolution would therefore always have returned NULL
-- and every timesheet would have auto-approved on submit. PART 4 resolves on
-- 'timesheet'; this moves anything already configured to match.

DO $mig$
DECLARE v_n integer;
BEGIN
  UPDATE workflow_assignments
  SET    module_code = 'timesheet', updated_at = now()
  WHERE  module_code = 'timesheet_headers';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN
    RAISE NOTICE 'MIG 742: moved % workflow assignment(s) from timesheet_headers to timesheet.', v_n;
  END IF;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — wf_sync_module_status learns what a timesheet is
-- ═══════════════════════════════════════════════════════════════════════════
-- Patched in place rather than rewritten. This function carries five modules'
-- worth of behaviour across twenty migrations; re-issuing a full body from a
-- migration file is exactly how the expense and termination branches have been
-- silently reverted before. The anchor is the trailing unknown-module ELSE,
-- and the hit count is asserted so a shifted anchor fails loudly here rather
-- than leaving timesheets unsynced in production.
--
-- The status map, with timesheet_headers.status having only three legal
-- values (to_be_submitted, to_be_approved, approved):
--
--   submitted / in_progress   -> to_be_approved   waiting on someone
--   approved                  -> approved         done, stamp approved_at
--   awaiting_clarification    -> to_be_submitted  sent back; editable again
--   draft / withdrawn / cancelled -> to_be_submitted  pulled back; editable
--   rejected                  -> cannot happen (PART 6), but mapped to
--                                to_be_submitted so a legacy instance rejected
--                                before this migration cannot strand a month.

DO $mig$
DECLARE
  v_src   text;
  v_new   text;
  v_hits  integer;
  v_anchor text :=
'  ELSE'                                                                    || E'\n' ||
'    RAISE NOTICE'                                                          || E'\n' ||
'      ''wf_sync_module_status: unknown module_code %, record unchanged'',';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_sync_module_status';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 742: wf_sync_module_status not found.';
  END IF;

  IF position('p_module_code = ''timesheet''' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 742: wf_sync_module_status already handles timesheet. Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION
      'MIG 742: expected exactly 1 unknown-module ELSE in wf_sync_module_status, found %. '
      'The function has moved -- add the timesheet branch by hand.', v_hits;
  END IF;

  v_new := replace(v_src, v_anchor, $b$  -- ── Timesheet (mig 742) ────────────────────────────────────────────────────
  ELSIF p_module_code = 'timesheet' THEN

    IF p_status = 'approved' THEN
      UPDATE timesheet_headers
      SET    status      = 'approved',
             approved_at = now(),
             updated_at  = now()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('submitted', 'in_progress') THEN
      UPDATE timesheet_headers
      SET    status      = 'to_be_approved',
             approved_at = NULL,
             updated_at  = now()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('awaiting_clarification', 'draft', 'withdrawn', 'cancelled', 'rejected') THEN
      -- Sent back, pulled back, or (legacy only) rejected. Every one of these
      -- means the month is the employee's problem again, so it must be
      -- editable: the write RPCs all gate on status = 'to_be_submitted'.
      -- workflow_instance_id is deliberately NOT cleared for
      -- awaiting_clarification -- the instance is still alive and the Sent
      -- Back tab needs it to resume.
      UPDATE timesheet_headers
      SET    status               = 'to_be_submitted',
             approved_at          = NULL,
             workflow_instance_id = CASE
                                      WHEN p_status = 'awaiting_clarification'
                                      THEN workflow_instance_id
                                      ELSE NULL
                                    END,
             updated_at           = now()
      WHERE  id = p_record_id;

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for timesheet % -- unchanged',
        p_status, p_record_id;
    END IF;

$b$ || v_anchor);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 742: wf_sync_module_status now handles timesheet.';
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — submit_timesheet actually submits
-- ═══════════════════════════════════════════════════════════════════════════
-- Replaced in full rather than patched. Migration 741 patched this function by
-- string replacement over 730's body; a third layer of replace-over-replace
-- would be unreadable and would break the moment either earlier anchor moves.
-- Everything 730 and 741 established is carried forward deliberately:
--
--   * 741: the gate is user_can('timesheet','edit', employee_id) -- permission,
--          not ownership, so a manager who may edit a sheet may file it.
--   * 741: the workflow is resolved for the SHEET'S EMPLOYEE, not the caller.
--   * 730: no workflow assigned -> approve on the spot, because nothing else
--          can ever move it.
--
-- What is new: the instance is started.
--
-- RESUMING AFTER A SEND-BACK
--   A sent-back sheet keeps its instance in 'awaiting_clarification' so the
--   employee can see the approver's message in the Sent Back tab, while the
--   header sits at 'to_be_submitted' so they can fix the hours. Pressing
--   Submit again must resume that instance, not open a second one -- wf_submit
--   refuses a duplicate anyway (mig 564). wf_resubmit enforces its own rule
--   that only the original submitter or an admin may resume; that is inherited
--   on purpose rather than worked around, so the two paths cannot disagree
--   about who is answering the approver.

CREATE OR REPLACE FUNCTION public.submit_timesheet(p_header_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_hdr        record;
  v_tpl        uuid;
  v_tpl_code   text;
  v_count      integer;
  v_instance   uuid;
  v_open       record;
  v_emp_name   text;
  v_profile    uuid;
BEGIN
  SELECT * INTO v_hdr FROM timesheet_headers WHERE id = p_header_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
                              'message', 'That timesheet no longer exists.');
  END IF;

  -- MIG 741: permission, not ownership.
  IF NOT user_can('timesheet', 'edit', v_hdr.employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
                              'message', 'You do not have permission to submit this timesheet.');
  END IF;

  IF v_hdr.status = 'to_be_approved' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_PENDING',
                              'message', 'This timesheet is already waiting for approval. Withdraw it first if you need to change it.');
  END IF;

  SELECT count(*) INTO v_count FROM timesheet_entries WHERE header_id = p_header_id;
  IF v_count = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'EMPTY',
                              'message', 'There is nothing recorded on this timesheet yet.');
  END IF;

  -- ── Resume a sent-back instance rather than starting a second one ────────
  SELECT wi.id, wi.status
  INTO   v_open
  FROM   workflow_instances wi
  WHERE  wi.module_code = 'timesheet'
    AND  wi.record_id   = p_header_id
    AND  wi.status      IN ('in_progress', 'awaiting_clarification')
  ORDER  BY wi.created_at DESC
  LIMIT  1;

  IF FOUND AND v_open.status = 'awaiting_clarification' THEN
    -- Raises with its own message if the caller is not the original submitter.
    PERFORM wf_resubmit(v_open.id, 'Timesheet corrected and resubmitted.');

    UPDATE timesheet_headers
    SET status = 'to_be_approved', submitted_at = now(), approved_at = NULL
    WHERE id = p_header_id;

    RETURN jsonb_build_object('ok', true, 'status', 'to_be_approved', 'workflow', true,
                              'instance_id', v_open.id, 'resumed', true,
                              'message', 'Timesheet resubmitted for approval.');
  END IF;

  IF FOUND AND v_open.status = 'in_progress' THEN
    -- The header said otherwise, but the workflow is the authority.
    UPDATE timesheet_headers
    SET status = 'to_be_approved', submitted_at = COALESCE(submitted_at, now())
    WHERE id = p_header_id;

    RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_PENDING',
                              'message', 'This timesheet is already waiting for approval.');
  END IF;

  -- ── MIG 741: resolve for the sheet's employee, not the caller ────────────
  v_profile := COALESCE((SELECT pr.id FROM profiles pr
                          WHERE pr.employee_id = v_hdr.employee_id
                          LIMIT 1),
                        auth.uid());

  v_tpl := resolve_workflow_for_submission('timesheet', v_profile);

  IF v_tpl IS NULL THEN
    UPDATE timesheet_headers
    SET status = 'approved', submitted_at = now(), approved_at = now()
    WHERE id = p_header_id;

    RETURN jsonb_build_object('ok', true, 'status', 'approved', 'workflow', false,
                              'message', 'Timesheet submitted and approved -- no approval workflow is configured.');
  END IF;

  SELECT code INTO v_tpl_code FROM workflow_templates WHERE id = v_tpl;
  IF v_tpl_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'TEMPLATE_MISSING',
                              'message', 'The approval workflow assigned to timesheets no longer exists. Ask an administrator to check Workflow Assignments.');
  END IF;

  SELECT name INTO v_emp_name FROM employees WHERE id = v_hdr.employee_id;

  -- Metadata is what the approver's task card reads before anything is fetched:
  -- the period and the totals are what makes a queue of timesheets legible.
  v_instance := wf_submit(
    p_template_code       => v_tpl_code,
    p_module_code         => 'timesheet',
    p_record_id           => p_header_id,
    p_metadata            => jsonb_build_object(
                               'employee_id',      v_hdr.employee_id,
                               'employee_name',    v_emp_name,
                               'period',           to_char(v_hdr.period, 'YYYY-MM'),
                               'period_label',     to_char(v_hdr.period, 'FMMonth YYYY'),
                               'planned_minutes',  v_hdr.planned_minutes,
                               'recorded_minutes', v_hdr.recorded_minutes,
                               'external_code',    v_hdr.external_code
                             ),
    p_comment             => NULL,
    p_subject_employee_id => v_hdr.employee_id
  );

  UPDATE timesheet_headers
  SET status               = 'to_be_approved',
      submitted_at         = now(),
      approved_at          = NULL,
      workflow_instance_id = v_instance
  WHERE id = p_header_id;

  RETURN jsonb_build_object('ok', true, 'status', 'to_be_approved', 'workflow', true,
                            'instance_id', v_instance,
                            'message', 'Timesheet submitted for approval.');
END $fn$;

REVOKE ALL ON FUNCTION public.submit_timesheet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_timesheet(uuid) TO authenticated;

COMMENT ON FUNCTION public.submit_timesheet IS
  'Mig 742: starts the approval workflow (or resumes a sent-back one). '
  'Carries forward 741 (permission not ownership; workflow resolved for the '
  'sheet''s employee) and 730 (auto-approve when no workflow is assigned).';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — withdraw_timesheet closes what submit opened
-- ═══════════════════════════════════════════════════════════════════════════
-- Without this a withdrawn sheet becomes editable while its approval task
-- stays in somebody's inbox -- they would approve a month that has since
-- changed underneath them.
--
-- The cancellation is done here rather than by calling wf_withdraw because
-- wf_withdraw gates on submitted_by = auth.uid(); with submission on behalf
-- (741) the withdrawer is legitimately often not the submitter. This function
-- has already established the stronger, configurable permission, so it does
-- the work directly and logs the same action_log row wf_withdraw would.

CREATE OR REPLACE FUNCTION public.withdraw_timesheet(p_header_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_hdr      record;
  v_instance uuid;
BEGIN
  SELECT * INTO v_hdr FROM timesheet_headers WHERE id = p_header_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
                              'message', 'That timesheet no longer exists.');
  END IF;

  -- MIG 741: permission, not ownership.
  IF NOT user_can('timesheet', 'edit', v_hdr.employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
                              'message', 'You do not have permission to withdraw this timesheet.');
  END IF;

  IF v_hdr.status <> 'to_be_approved' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_PENDING',
                              'message', 'Only a timesheet waiting for approval can be withdrawn.');
  END IF;

  SELECT wi.id INTO v_instance
  FROM   workflow_instances wi
  WHERE  wi.module_code = 'timesheet'
    AND  wi.record_id   = p_header_id
    AND  wi.status      IN ('in_progress', 'awaiting_clarification')
  ORDER  BY wi.created_at DESC
  LIMIT  1;

  IF v_instance IS NOT NULL THEN
    UPDATE workflow_tasks
    SET    status = 'cancelled', acted_at = now()
    WHERE  instance_id = v_instance
      AND  status      = 'pending';

    UPDATE workflow_instances
    SET    status = 'withdrawn', updated_at = now()
    WHERE  id = v_instance;

    INSERT INTO workflow_action_log (instance_id, actor_id, action, notes)
    VALUES (v_instance, auth.uid(), 'withdrawn', 'Timesheet withdrawn by the submitter.');
  END IF;

  UPDATE timesheet_headers
  SET status               = 'to_be_submitted',
      submitted_at         = NULL,
      approved_at          = NULL,
      workflow_instance_id = NULL
  WHERE id = p_header_id;

  RETURN jsonb_build_object('ok', true, 'status', 'to_be_submitted',
                            'withdrew_workflow', v_instance IS NOT NULL,
                            'message', 'Withdrawn. You can change the timesheet and submit it again.');
END $fn$;

REVOKE ALL ON FUNCTION public.withdraw_timesheet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.withdraw_timesheet(uuid) TO authenticated;

COMMENT ON FUNCTION public.withdraw_timesheet IS
  'Mig 742: cancels the approval instance it pulls the sheet back from, so no '
  'approver is left holding a task for a month that has become editable again.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 6 — a timesheet cannot be rejected
-- ═══════════════════════════════════════════════════════════════════════════
-- Patched in place, immediately after wf_reject loads the instance, so the
-- guard sees the module code and runs before anything is written.

DO $mig$
DECLARE
  v_src   text;
  v_new   text;
  v_hits  integer;
  v_anchor text :=
'  IF v_instance.status NOT IN (''in_progress'', ''awaiting_clarification'') THEN'    || E'\n' ||
'    RAISE EXCEPTION ''wf_reject: workflow instance is not active (status: %)'', v_instance.status;' || E'\n' ||
'  END IF;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_reject';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 742: wf_reject not found.';
  END IF;

  IF position('MIG 742' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 742: wf_reject already refuses timesheets. Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION
      'MIG 742: expected exactly 1 active-instance guard in wf_reject, found %.', v_hits;
  END IF;

  v_new := replace(v_src, v_anchor, v_anchor || E'\n\n' || $g$  -- MIG 742: a timesheet is never rejected, only sent back. A month has a
  -- true value; the only question is whether it has been recorded correctly
  -- yet, and "not yet" is what send-back is for. There is no 'rejected' value
  -- in timesheet_headers.status to hold the outcome and no screen to clear it,
  -- so rejecting would strand the month. The approval UI hides the button;
  -- this makes it impossible rather than merely absent.
  IF v_instance.module_code = 'timesheet' THEN
    RAISE EXCEPTION
      'A timesheet cannot be rejected. Send it back for correction instead -- the month reopens for editing and returns for approval.'
      USING ERRCODE = 'check_violation';
  END IF;$g$);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 742: wf_reject now refuses timesheets.';
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 7 — one read for the whole approval screen
-- ═══════════════════════════════════════════════════════════════════════════
-- Returns everything the inbox panel and the full review need, and refuses as
-- a whole rather than per-table. Two ways in:
--
--   * assigned a workflow task on this sheet (mig 739's helper), which is what
--     makes an approver outside the management chain able to review it; or
--   * user_can('timesheet','view', employee_id), the ordinary manager path.
--
-- changed_after_approval is the value this screen exists for on a re-approval:
-- an entry created or updated after the last approved_at is one the approver
-- has not seen. Deletions are invisible -- timesheet_entries has no audit
-- trail, so an entry removed after approval leaves no row to report. That is a
-- real gap and is called out rather than papered over; closing it needs a
-- delete trigger writing to an audit table, which is not this migration.

CREATE OR REPLACE FUNCTION public.time_approval_payload(p_header_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_hdr       record;
  v_may       boolean;
  v_last_appr timestamptz;
  v_result    jsonb;
BEGIN
  SELECT * INTO v_hdr FROM timesheet_headers WHERE id = p_header_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND');
  END IF;

  v_may := time_is_timesheet_approver(p_header_id)
        OR user_can('timesheet', 'view', v_hdr.employee_id);

  IF NOT v_may THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- The moment this sheet was last approved, if it ever was. Anything touched
  -- after it is a change the current approver has not signed off.
  SELECT max(wal.created_at) INTO v_last_appr
  FROM   workflow_action_log wal
  JOIN   workflow_instances  wi ON wi.id = wal.instance_id
  WHERE  wi.module_code = 'timesheet'
    AND  wi.record_id   = p_header_id
    AND  wal.action     = 'approved';

  v_last_appr := COALESCE(v_last_appr, v_hdr.approved_at);

  SELECT jsonb_build_object(
    'ok', true,

    'header', jsonb_build_object(
      'id',                   v_hdr.id,
      'employee_id',          v_hdr.employee_id,
      'period',               v_hdr.period,
      'external_code',        v_hdr.external_code,
      'status',               v_hdr.status,
      'planned_minutes',      v_hdr.planned_minutes,
      'recorded_minutes',     v_hdr.recorded_minutes,
      'submitted_at',         v_hdr.submitted_at,
      'approved_at',          v_hdr.approved_at,
      'workflow_instance_id', v_hdr.workflow_instance_id,
      'department_name',      v_hdr.department_name,
      'country_code',         v_hdr.country_code,
      'last_approved_at',     v_last_appr
    ),

    -- employees.employee_id is the human-readable code, not a FK. The manager
    -- is resolved here so the screen's header strip needs no second read.
    'employee', (
      SELECT jsonb_build_object(
               'id',            e.id,
               'name',          e.name,
               'employee_code', e.employee_id,
               'job_title',     e.job_title,
               'manager_name',  (SELECT m.name FROM employees m WHERE m.id = e.manager_id))
      FROM employees e WHERE e.id = v_hdr.employee_id
    ),

    'holiday_calendar', (
      SELECT jsonb_build_object('id', hc.id, 'name', hc.name)
      FROM time_holiday_calendars hc WHERE hc.id = v_hdr.holiday_calendar_id
    ),

    'schedule', (
      SELECT jsonb_build_object(
               'id', ws.id, 'name', ws.name, 'code', ws.code,
               'max_daily_minutes', ws.max_daily_minutes,
               'start_day_of_week', ws.start_day_of_week,
               'lines', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'day_number', l.day_number,
                          'planned_minutes', l.planned_minutes)
                        ORDER BY l.day_number)
                 FROM time_work_schedule_lines l
                 WHERE l.work_schedule_id = ws.id), '[]'::jsonb))
      FROM time_work_schedules ws WHERE ws.id = v_hdr.work_schedule_id
    ),

    -- The name lives on time_holidays; time_calendar_entries only points at it.
    'holidays', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'date', ce.entry_date,
               'name', COALESCE(th.holiday_name, 'Public holiday'))
             ORDER BY ce.entry_date)
      FROM      time_calendar_entries ce
      LEFT JOIN time_holidays th ON th.id = ce.holiday_id
      WHERE ce.calendar_id = v_hdr.holiday_calendar_id
        AND ce.entry_date >= v_hdr.period
        AND ce.entry_date <  (v_hdr.period + INTERVAL '1 month')::date
    ), '[]'::jsonb),

    'entries', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id',            te.id,
               'entry_date',    te.entry_date,
               'entry_kind',    te.entry_kind,
               'hours_minutes', te.hours_minutes,
               'notes',         te.notes,
               'activities',    COALESCE(te.activities, ARRAY[]::text[]),
               'project_id',    te.project_id,
               'project_name',  pj.name,
               'time_type_id',  te.time_type_id,
               'time_type_name', tt.name,
               'is_system_generated', te.is_system_generated,
               'created_at',    te.created_at,
               'updated_at',    te.updated_at,
               'changed_after_approval',
                 CASE WHEN v_last_appr IS NULL THEN NULL
                      WHEN te.created_at > v_last_appr THEN 'ADDED'
                      WHEN te.updated_at > v_last_appr THEN 'EDITED'
                      ELSE NULL END)
             ORDER BY te.entry_date, pj.name NULLS LAST, tt.name NULLS LAST)
      FROM      timesheet_entries te
      LEFT JOIN projects   pj ON pj.id = te.project_id
      LEFT JOIN time_types tt ON tt.id = te.time_type_id
      WHERE     te.header_id = p_header_id
    ), '[]'::jsonb),

    'deletions_visible', false
  ) INTO v_result;

  RETURN v_result;
END $fn$;

REVOKE ALL ON FUNCTION public.time_approval_payload(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_approval_payload(uuid) TO authenticated;

COMMENT ON FUNCTION public.time_approval_payload(uuid) IS
  'Mig 742: everything the timesheet approval screens render, in one read, '
  'gated once. Open to a workflow approver on the sheet (mig 739) or to anyone '
  'with timesheet.view over the employee. deletions_visible is false and says '
  'so: timesheet_entries has no delete audit trail, so an entry removed after '
  'approval cannot be reported.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 8 — assertions
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_src text; v_n integer;
BEGIN
  -- 1. the module exists and cannot be edited by approvers
  PERFORM 1 FROM module_codes
   WHERE code = 'timesheet'
     AND table_name = 'timesheet_headers'
     AND approval_write_permission IS NULL
     AND edit_route IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIG 742 ASSERT: module_codes row for timesheet is missing or grants approver edit.';
  END IF;

  -- 2. mig 739's dormant helper still resolves (it reads module_codes.table_name,
  --    which the PART 1 row now satisfies) and the payload RPC compiles
  PERFORM time_is_timesheet_approver('00000000-0000-0000-0000-000000000000'::uuid);
  PERFORM time_approval_payload('00000000-0000-0000-0000-000000000000'::uuid);

  -- 3. sync knows the module
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'wf_sync_module_status';
  IF position('p_module_code = ''timesheet''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 742 ASSERT: wf_sync_module_status has no timesheet branch.';
  END IF;

  -- 4. reject is closed
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'wf_reject';
  IF position('A timesheet cannot be rejected' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 742 ASSERT: wf_reject does not refuse timesheets.';
  END IF;

  -- 5. submit really starts a workflow now
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'submit_timesheet';
  IF position('wf_submit(' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 742 ASSERT: submit_timesheet still does not call wf_submit.';
  END IF;
  IF position('user_can(''timesheet'', ''edit'', v_hdr.employee_id)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 742 ASSERT: submit_timesheet lost the mig 741 permission gate.';
  END IF;
  IF position('resolve_workflow_for_submission(''timesheet'', v_profile)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 742 ASSERT: submit_timesheet lost the mig 741 employee-resolved workflow.';
  END IF;

  -- 6. withdraw cancels the instance
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'withdraw_timesheet';
  IF position('workflow_instances' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 742 ASSERT: withdraw_timesheet does not cancel the instance.';
  END IF;

  -- 7. nothing left pointing at the old assignment vocabulary
  SELECT count(*) INTO v_n FROM workflow_assignments WHERE module_code = 'timesheet_headers';
  IF v_n > 0 THEN
    RAISE EXCEPTION 'MIG 742 ASSERT: % workflow assignment(s) still use timesheet_headers.', v_n;
  END IF;

  RAISE NOTICE 'MIG 742: all assertions passed.';
END $mig$;

COMMIT;
