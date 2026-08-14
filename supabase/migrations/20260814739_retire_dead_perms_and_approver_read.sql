-- Migration : 20260814739_retire_dead_perms_and_approver_read.sql
-- Purpose   : Two things, both about the gap between a permission existing and
--             a permission meaning something.
--
--               1. Retire five permission rows nothing reads and nobody holds.
--               2. Let a workflow approver READ the timesheet they were asked
--                  to approve, which today they cannot.
--
-- WHY THEY ARE ONE MIGRATION
--   They are the same defect from both ends. Section N of the test plan records
--   what happens when a permission is filed under a name nothing checks: every
--   timesheet RLS policy asked for a module called `timesheet` while the rows
--   sat under `time_management`, and the product worked for four months only
--   because the people using it were super-admins, who bypass the check. Below,
--   half the vocabulary is checked by nothing, and the half that IS checked
--   cannot see the approver it is refusing.
--
-- WHAT IS REMOVED, AND WHAT DELIBERATELY IS NOT
--   Removed -- named by no function, no policy and no frontend file, and
--   granted through no permission set:
--     timesheet_manager.view / edit / approve
--     timesheet_admin.edit / approve
--
--   KEPT: timesheet_admin.view. It is granted to nobody, which is why it looked
--   dead, but App.tsx gates the "Timesheet Admin" nav item AND the
--   /admin/time/timesheets route on it, and TimesheetAdmin.tsx exists. Deleting
--   it would have made a working screen unreachable. The real defect there is
--   the opposite one and is fixed on the client alongside this migration:
--   PermissionMatrix.tsx never offered the module, so there was no way to grant
--   it, leaving the screen reachable only by super-admins.
--
--   KEPT: timesheet_reports.view. Also ungranted and unread -- but unlike the
--   five above, PermissionMatrix DOES offer it, so an administrator can grant
--   it today and reasonably expect something to happen. That is a promise to
--   honour or withdraw deliberately, not to clean up in passing.
--
-- Depends on : 732 (which created these modules), 726-738

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — retire what nothing reads
-- ═══════════════════════════════════════════════════════════════════════════
-- Every claim in the header is re-checked here against the live database rather
-- than trusted. A permission that turns out to be granted, or named inside a
-- function or a policy, aborts the migration: deleting it would revoke access
-- silently, which is worse than leaving a dead row in place.

DO $mig$
DECLARE
  v_dead    text[] := ARRAY[
    'timesheet_manager.view', 'timesheet_manager.edit', 'timesheet_manager.approve',
    'timesheet_admin.edit',   'timesheet_admin.approve'
  ];
  v_granted text;
  v_named   text;
  v_removed integer;
BEGIN
  -- (a) held by nobody
  SELECT string_agg(DISTINCT m.code || '.' || p.action, ', ') INTO v_granted
  FROM   permissions p
  JOIN   modules m ON m.id = p.module_id
  JOIN   permission_set_items psi ON psi.permission_id = p.id
  WHERE  m.code || '.' || p.action = ANY (v_dead);

  IF v_granted IS NOT NULL THEN
    RAISE EXCEPTION 'MIG 739 ABORT: granted to somebody and would be revoked silently: %.', v_granted;
  END IF;

  -- (b) named by no function and no policy. prokind/lanname filtered because
  --     pg_get_functiondef raises on an aggregate -- see mig 734 PART 2.
  SELECT string_agg(DISTINCT src, ', ') INTO v_named
  FROM (
    SELECT 'function ' || p.proname AS src
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    JOIN   pg_language  l ON l.oid = p.prolang
    WHERE  n.nspname = 'public' AND p.prokind = 'f'
      AND  l.lanname IN ('plpgsql', 'sql')
      AND  (pg_get_functiondef(p.oid) LIKE '%timesheet_manager%'
            OR pg_get_functiondef(p.oid) LIKE '%timesheet_admin%')
    UNION ALL
    SELECT 'policy ' || tablename || '.' || policyname
    FROM   pg_policies
    WHERE  COALESCE(qual, '') || COALESCE(with_check, '') LIKE '%timesheet_manager%'
       OR  COALESCE(qual, '') || COALESCE(with_check, '') LIKE '%timesheet_admin%'
  ) s;

  IF v_named IS NOT NULL THEN
    RAISE EXCEPTION 'MIG 739 ABORT: still referenced by %. Resolve by hand.', v_named;
  END IF;

  DELETE FROM permissions p
  USING  modules m
  WHERE  m.id = p.module_id
    AND  m.code || '.' || p.action = ANY (v_dead);
  GET DIAGNOSTICS v_removed = ROW_COUNT;

  RAISE NOTICE 'MIG 739: removed % dead permission row(s).', v_removed;
END $mig$;

-- The module row goes only once it holds nothing. timesheet_admin survives
-- because .view survives; timesheet_manager should now be empty.
DELETE FROM public.modules m
WHERE  m.code = 'timesheet_manager'
  AND  NOT EXISTS (SELECT 1 FROM public.permissions p WHERE p.module_id = m.id);

DO $mig$
BEGIN
  IF EXISTS (SELECT 1 FROM modules WHERE code = 'timesheet_manager') THEN
    RAISE EXCEPTION 'MIG 739 ABORT: timesheet_manager still holds permissions and was not removed.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM permissions p JOIN modules m ON m.id = p.module_id
                 WHERE m.code = 'timesheet_admin' AND p.action = 'view') THEN
    RAISE EXCEPTION 'MIG 739 ABORT: timesheet_admin.view was removed. App.tsx gates a route on it.';
  END IF;
  RAISE NOTICE 'MIG 739: timesheet_manager retired; timesheet_admin.view kept.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — an approver can read what they were asked to approve
-- ═══════════════════════════════════════════════════════════════════════════
-- Today the only SELECT policy on either timesheet table is owner-scoped:
--
--     user_can('timesheet','view', employee_id)
--
-- which resolves through target groups -- the reporting tree, a department, a
-- country, a custom list. None of those can express "this person was asked to
-- approve THIS sheet", so an approver outside the employee's reporting line
-- receives a task they cannot open. A target group never fixes that: a project
-- manager approving a timesheet is not anybody's line manager.
--
-- Policies are OR'd, so this is purely additive; the owner-scoped policy is
-- untouched and still governs everyone else.
--
-- ON PERSISTENCE. The helper matches ANY task ever assigned to the caller for
-- the record, not only a pending one, so access survives the approval. That
-- diverges from employees_select, which gates the hire flow on
-- wt.status = 'pending', and the cases are not alike: a draft employee record
-- should stop being visible once the hire is decided, whereas an approver who
-- cannot re-open the month they signed off is a bad audit story. Read-only
-- either way -- this grants SELECT and nothing else.
--
-- THROUGH A SECURITY DEFINER HELPER, AND THAT IS NOT A STYLE CHOICE.
--   An RLS policy's subquery executes with the CALLER's privileges. The first
--   version of this policy joined workflow_tasks, workflow_instances and
--   module_codes inline, and every read of the timesheet page died with
--   "permission denied for table workflow_instances" -- including the employee
--   reading their OWN sheet, because policies are OR'd but all of them are
--   evaluated. A policy naming a table the role cannot read does not fail
--   closed, it fails loudly, for everyone. Caught on a replayed schema; it
--   would have taken the page down on deploy.
--
--   SECURITY DEFINER means the caller needs EXECUTE on the function and no
--   grants on the workflow tables at all. That is exactly why the existing
--   is_workflow_assignee() is SECURITY DEFINER; this is its registry-driven
--   sibling.
--
-- RESOLVED THROUGH THE REGISTRY, NOT A LITERAL.
--   workflow_instances.module_code is a foreign key onto module_codes, a
--   registry carrying table_name, owner_column, permission_prefix, edit_route
--   and more -- and timesheets are NOT registered in it yet. submit_timesheet
--   passes 'timesheet_headers' to resolve_workflow_for_submission, which is the
--   only evidence of the intended code anywhere, and it is evidence, not a
--   decision: registering the module properly means answering half a dozen
--   questions this migration has no business answering.
--
--   So nothing here names a code. The helper asks the registry which code
--   belongs to the timesheet_headers TABLE. Today that matches nothing, because
--   nothing is registered, and the policy is dormant -- as correct as it can
--   be. The day someone registers the module under whatever name they choose,
--   this starts working with no migration to chase. A literal would have been
--   silently wrong if the chosen code turned out to be 'timesheet', and nobody
--   would find out until an approver could not open a sheet.
--
-- ALSO DORMANT because submit_timesheet does not call wf_submit yet -- "the
-- instance is NOT started here yet: the approver screens are on hold" -- so no
-- workflow_instances row exists for a timesheet today. The rule is written now
-- so it is in place before the queue it governs, rather than discovered missing
-- on the day approvers first log in.

CREATE OR REPLACE FUNCTION public.time_is_timesheet_approver(p_header_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_tasks     wt
    JOIN   workflow_instances wi ON wi.id   = wt.instance_id
    JOIN   module_codes       mc ON mc.code = wi.module_code
    WHERE  wi.record_id   = p_header_id
      AND  mc.table_name  = 'timesheet_headers'
      AND  wt.assigned_to = auth.uid()
  );
$fn$;

REVOKE ALL ON FUNCTION public.time_is_timesheet_approver(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_is_timesheet_approver(uuid) TO authenticated;

COMMENT ON FUNCTION public.time_is_timesheet_approver(uuid) IS
  'MIG 739 - was the caller assigned a workflow task on this timesheet? '
  'SECURITY DEFINER because RLS subqueries run as the caller and authenticated '
  'has no grants on the workflow tables. The module code is resolved from '
  'module_codes by table_name, so it follows whatever the timesheet module is '
  'eventually registered as.';

DROP POLICY IF EXISTS tsh_select_approver ON public.timesheet_headers;
CREATE POLICY tsh_select_approver ON public.timesheet_headers
  FOR SELECT
  USING (time_is_timesheet_approver(id));

DROP POLICY IF EXISTS tse_select_approver ON public.timesheet_entries;
CREATE POLICY tse_select_approver ON public.timesheet_entries
  FOR SELECT
  USING (time_is_timesheet_approver(header_id));

COMMENT ON POLICY tsh_select_approver ON public.timesheet_headers IS
  'MIG 739 - read access for whoever was assigned a workflow task on this sheet. '
  'Additive to tsh_select_own; SELECT only; survives completion of the task. '
  'Dormant until the timesheet module is registered in module_codes.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — assert the shape of what was just changed
-- ═══════════════════════════════════════════════════════════════════════════
-- Note the ::text casts. text[] || 'literal' resolves to array || array and
-- dies with "malformed array literal" instead of reporting anything useful --
-- the trap recorded in mig 738 and in the test plan's footer.

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_n       integer;
BEGIN
  SELECT count(*) INTO v_n
  FROM   permissions p JOIN modules m ON m.id = p.module_id
  WHERE  m.code = 'timesheet_manager'
     OR  m.code || '.' || p.action IN ('timesheet_admin.edit', 'timesheet_admin.approve');
  IF v_n > 0 THEN
    v_missing := v_missing || 'mig 739: dead permission rows still present'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM permissions p JOIN modules m ON m.id = p.module_id
                 WHERE m.code = 'timesheet_admin' AND p.action = 'view') THEN
    v_missing := v_missing || 'mig 739: timesheet_admin.view must survive - App.tsx gates a route on it'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename = 'timesheet_headers' AND policyname = 'tsh_select_approver') THEN
    v_missing := v_missing || 'mig 739: approver read policy on timesheet_headers'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename = 'timesheet_entries' AND policyname = 'tse_select_approver') THEN
    v_missing := v_missing || 'mig 739: approver read policy on timesheet_entries'::text; END IF;

  -- The helper must be SECURITY DEFINER or every timesheet read breaks.
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'time_is_timesheet_approver'
                   AND p.prosecdef) THEN
    v_missing := v_missing || 'mig 739: approver helper missing or not SECURITY DEFINER'::text; END IF;

  -- An additive change that replaced the owner-scoped policy would hand every
  -- timesheet to nobody at all.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename = 'timesheet_headers' AND policyname = 'tsh_select_own') THEN
    v_missing := v_missing || 'REGRESSION: the owner-scoped select policy is gone'::text; END IF;

  IF position('time_daily_cap_minutes_for_date' IN (
        SELECT pg_get_functiondef(p.oid) FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'enforce_timesheet_entry_rules')) = 0 THEN
    v_missing := v_missing || 'mig 738 rule (i): the daily cap is enforced in the trigger'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 739 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 739 verified: dead rows gone, timesheet_admin.view kept, approver read in place.';
END $mig$;

COMMIT;
