-- Migration : 20260814741_submit_withdraw_on_behalf.sql
-- Purpose   : Let anyone who may EDIT a timesheet submit and withdraw it, not
--             only the employee it belongs to — and make the workflow that
--             governs it belong to the employee rather than to whoever pressed
--             the button.
--
-- WHY
--   Every write path into timesheet_entries asks the same question:
--
--       user_can('timesheet', 'edit', v_header.employee_id)
--
--   save_timesheet_entry, bulk_create_timesheet_entries, paste_timesheet_day
--   and the RLS policies all agree on it. submit_timesheet and
--   withdraw_timesheet did not: they asked a different question entirely --
--
--       v_hdr.employee_id IS DISTINCT FROM get_my_employee_id()  ->  NOT_YOURS
--
--   -- which is ownership, not permission, and cannot be configured. A manager
--   granted timesheet.edit over their reports could add hours to a sheet, edit
--   them, delete them and copy days across it, and then not file it. The two
--   rules were never reconciled because until now nothing but the employee's
--   own browser ever called these.
--
--   Bringing them onto user_can also means the answer is administrable: an
--   administrator who does NOT want managers filing on behalf simply withholds
--   timesheet.edit, and the same grant that already governs every other write
--   governs these too. Nothing here decides policy.
--
-- THE BUG UNDERNEATH, which is the reason this is not a one-line change
--   submit_timesheet resolved the approval workflow like this:
--
--       resolve_workflow_for_submission('timesheet_headers', auth.uid())
--
--   auth.uid() is the CALLER. That was harmless while the caller was always the
--   owner, and wrong the moment anybody else submits: a manager filing a
--   report's sheet would have resolved THEIR OWN workflow assignment -- a
--   different template, a different approver chain, or none at all, in which
--   case the sheet would have been auto-approved on the spot because "no
--   workflow is configured". The workflow that governs a timesheet belongs to
--   whose timesheet it is. Resolved from the header's employee now.
--
-- Depends on : 730 (the edit window and these two functions), 740

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — submit_timesheet
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src   text;
  v_new   text;
  v_hits  integer;
  v_guard text :=
'  IF v_hdr.employee_id IS DISTINCT FROM get_my_employee_id() THEN'          || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''NOT_YOURS'','     || E'\n' ||
'                              ''message'', ''You can only submit your own timesheet.'');' || E'\n' ||
'  END IF;';
  v_res   text := '  v_tpl := resolve_workflow_for_submission(''timesheet_headers'', auth.uid());';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'submit_timesheet';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 741: submit_timesheet not found.';
  END IF;

  IF position('user_can(''timesheet'', ''edit'', v_hdr.employee_id)' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 741: submit_timesheet already gates on user_can. Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_guard, ''))) / length(v_guard);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 741: expected exactly 1 ownership guard in submit_timesheet, found %.', v_hits;
  END IF;

  v_new := replace(v_src, v_guard, $g$  -- MIG 741: permission, not ownership. The same question every other
  -- write path asks, so a manager who may edit a sheet may also file it,
  -- and an administrator who does not want that withholds timesheet.edit.
  IF NOT user_can('timesheet', 'edit', v_hdr.employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
                              'message', 'You do not have permission to submit this timesheet.');
  END IF;$g$);

  v_hits := (length(v_new) - length(replace(v_new, v_res, ''))) / length(v_res);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 741: expected exactly 1 workflow resolution in submit_timesheet, found %.', v_hits;
  END IF;

  v_new := replace(v_new, v_res, $r$  -- MIG 741: resolve the workflow for the SHEET'S EMPLOYEE, not for whoever
  -- pressed the button. auth.uid() was harmless while the caller was always
  -- the owner; with submission on behalf it would have picked the manager's
  -- own assignment -- a different approver chain, or none, in which case the
  -- sheet would have been auto-approved on the spot.
  --
  -- No profile row means nobody can sign in as that employee, which is not a
  -- reason to refuse the filing: fall back to the caller so behaviour matches
  -- what it was before this migration rather than becoming a new failure.
  v_tpl := resolve_workflow_for_submission(
             'timesheet_headers',
             COALESCE((SELECT pr.id FROM profiles pr
                        WHERE pr.employee_id = v_hdr.employee_id
                        LIMIT 1),
                      auth.uid()));$r$);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 741: submit_timesheet gates on user_can and resolves the employee''s workflow.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — withdraw_timesheet
-- ═══════════════════════════════════════════════════════════════════════════
-- Withdrawing is the way back out of Pending Approval. Leaving it owner-only
-- while submission is permission-based would let a manager file a sheet and
-- then be unable to unfile it.

DO $mig$
DECLARE
  v_src   text;
  v_new   text;
  v_hits  integer;
  v_guard text :=
'  IF v_hdr.employee_id IS DISTINCT FROM get_my_employee_id() THEN'          || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''NOT_YOURS'','     || E'\n' ||
'                              ''message'', ''You can only withdraw your own timesheet.'');' || E'\n' ||
'  END IF;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'withdraw_timesheet';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 741: withdraw_timesheet not found.';
  END IF;

  IF position('user_can(''timesheet'', ''edit'', v_hdr.employee_id)' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 741: withdraw_timesheet already gates on user_can. Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_guard, ''))) / length(v_guard);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 741: expected exactly 1 ownership guard in withdraw_timesheet, found %.', v_hits;
  END IF;

  v_new := replace(v_src, v_guard, $g$  -- MIG 741: permission, not ownership -- see submit_timesheet.
  IF NOT user_can('timesheet', 'edit', v_hdr.employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
                              'message', 'You do not have permission to withdraw this timesheet.');
  END IF;$g$);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 741: withdraw_timesheet gates on user_can.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — assert it, including what must NOT have come back
-- ═══════════════════════════════════════════════════════════════════════════
-- ::text casts — see mig 738 and the test plan footer.

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_src     text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'submit_timesheet';

  IF position('user_can(''timesheet'', ''edit'', v_hdr.employee_id)' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 741: submit_timesheet gates on user_can'::text; END IF;
  IF position('pr.employee_id = v_hdr.employee_id' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 741: submit resolves the EMPLOYEE''S workflow'::text; END IF;
  IF position('resolve_workflow_for_submission(''timesheet_headers'', auth.uid())' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: the workflow is resolved for the caller again'::text; END IF;
  IF position('NOT_YOURS' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: the ownership guard is back in submit_timesheet'::text; END IF;
  -- 730's rule: a sheet already awaiting an approver cannot be re-submitted.
  IF position('ALREADY_PENDING' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 730: re-submitting a pending sheet is refused'::text; END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'withdraw_timesheet';

  IF position('user_can(''timesheet'', ''edit'', v_hdr.employee_id)' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 741: withdraw_timesheet gates on user_can'::text; END IF;
  IF position('NOT_YOURS' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: the ownership guard is back in withdraw_timesheet'::text; END IF;
  IF position('NOT_PENDING' IN v_src) = 0 THEN
    v_missing := v_missing || 'only a pending sheet can be withdrawn'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 741 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 741 verified: submit and withdraw follow timesheet.edit, and the workflow follows the employee.';
END $mig$;

COMMIT;
