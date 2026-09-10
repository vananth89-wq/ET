-- =============================================================================
-- Migration 842 — a permission for the timesheet detail report
--
-- WHAT THE REPORT IS
-- ══════════════════
--   Vj's original item 3: a timesheet summary AND detail report. The three
--   reports that exist aggregate -- Compliance counts submissions, Utilisation
--   groups hours, Project Summary groups projects. None of them answers the
--   question somebody actually asks about a person: *what did she do in
--   September?* Today the only way to see one employee's month in full is to
--   be their approver, or to ask them to export it.
--
--   So the report is a DRILL-DOWN: pick an employee and a period, and read the
--   whole sheet -- the summary panel, the billable split, every day, every
--   activity. It is the approver's own view without the approve button.
--
-- WHY THIS MIGRATION IS ONLY A PERMISSION
-- ═══════════════════════════════════════
--   Because the data path already exists and is already gated correctly.
--   `time_approval_payload` (742) returns the whole sheet, and since 743 its
--   gate has been:
--
--       time_is_timesheet_approver(header) OR user_can('timesheet','view', employee)
--
--   ...which is exactly the rule this report needs. `timesheet_headers` carries
--   the same rule in RLS (`tsh_select_own`, 704). Writing a second RPC would be
--   a second gate over the same rows, and the way two gates on one fact end is
--   that one of them is quietly wrong.
--
-- AND WHAT THIS PERMISSION IS HONESTLY FOR
-- ════════════════════════════════════════
--   The registry says a view's permission "gates this view AND the RPC behind
--   it ... because PostgREST is reachable with a token and no UI". For the
--   other three that is literally true: each RPC checks its own report grant.
--
--   It is NOT true here, and pretending otherwise would be worse than saying
--   so. `time_approval_payload` checks `timesheet.view` on the EMPLOYEE, not
--   this grant. So:
--
--       timesheet_reports.view_detail   opens the screen
--       timesheet.view (per employee)   decides whose sheets it can show
--
--   The second is the real boundary, it is enforced server-side, and it was
--   enforced before this migration existed -- anyone holding it can already
--   read the same payload through the approval screen. This grant controls
--   whether the report appears in the catalog, and that is all it controls.
--   Granting it to somebody with no timesheet.view population gives them a
--   screen that can show them nothing, which is the correct outcome.
--
-- Depends on: 745 (the module and the action check), 766 (the pattern this
--             follows), 742/743 (the payload and its gate)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — let the action exist
-- ═══════════════════════════════════════════════════════════════════════════
-- 766 rebuilt this CHECK by reading what the table actually holds and adding
-- to it, rather than asserting a list. Same here, for the same reason: a
-- database carrying an action this migration did not create must not fail on a
-- difference it has no business adjudicating.

DO $mig$
DECLARE
  v_extra   text[];
  v_allowed text[];
  v_canonical CONSTANT text[] := ARRAY[
    'view','create','edit','delete','history','lookup',
    'view_all_pending','edit_all_pending',
    'bulk_import','bulk_export',
    'view_inactive','reassign','approve',
    'view_compliance','view_utilisation','view_projects',
    'view_detail',                                  -- mig 842
    'view_capacity','view_analytics'];
BEGIN
  SELECT COALESCE(array_agg(DISTINCT action), ARRAY[]::text[])
    INTO v_extra
  FROM   public.permissions
  WHERE  action IS NOT NULL
    AND  action <> ALL (v_canonical);

  IF COALESCE(array_length(v_extra, 1), 0) > 0 THEN
    RAISE WARNING 'MIG 842: permissions.action holds % value(s) outside the canonical set: %. Preserved rather than rejected.',
                  array_length(v_extra, 1), array_to_string(v_extra, ', ');
  END IF;

  v_allowed := v_canonical || v_extra;

  EXECUTE 'ALTER TABLE public.permissions DROP CONSTRAINT IF EXISTS permissions_action_check';
  EXECUTE format(
    'ALTER TABLE public.permissions ADD CONSTRAINT permissions_action_check '
    'CHECK (action = ANY (%L::text[]))', v_allowed);
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the permission, seeded with its screen
-- ═══════════════════════════════════════════════════════════════════════════
-- 739 spent an entire migration removing permissions an administrator could
-- grant that did nothing. So this one arrives with the screen it opens, not
-- before it.

INSERT INTO public.permissions (module_id, code, name, description, action, sort_order)
SELECT m.id,
       'timesheet_reports.view_detail',
       'Timesheet Detail Report',
       'Open the Detail report -- one employee''s period in full: the summary, '
       'the billable split, every day and every activity. WHOSE sheets can be '
       'opened is decided by the Timesheet view target population and enforced '
       'by the database, not by this grant; this one decides whether the report '
       'appears at all.',
       'view_detail',
       40
FROM   public.modules m
WHERE  m.code = 'timesheet_reports'
ON CONFLICT (code) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_src text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.permissions
                  WHERE code = 'timesheet_reports.view_detail') THEN
    RAISE EXCEPTION 'MIG 842 FAILED: the permission was not created. Does the timesheet_reports module exist? 745 creates it.';
  END IF;

  -- The screen leans entirely on this function and its gate. If either is
  -- missing, the report would open onto nothing and this migration has seeded a
  -- grant that does nothing -- exactly what 739 was written to clean up.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_approval_payload';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 842 FAILED: time_approval_payload does not exist, so the detail report has nothing to read.';
  END IF;
  IF position('user_can(''timesheet'', ''view''' IN v_src) = 0
 AND position('user_can(''timesheet'',''view''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 842 FAILED: time_approval_payload no longer gates on timesheet.view for the employee. That gate IS this report''s access control -- do not ship the screen until it is back.';
  END IF;

  RAISE NOTICE 'MIG 842 OK: the detail report has a permission, and the payload it reads still checks timesheet.view per employee.';
END;
$v$;

COMMIT;
