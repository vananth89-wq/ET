-- =============================================================================
-- Migration : 20260818745_report_permissions_split.sql
-- Purpose   : One permission per report, instead of one permission for all of them.
--
-- WHY NOW AND NOT LATER
--   `timesheet_reports.view` is held by nobody. Migration 739 established that
--   deliberately and it is still true, which makes this split FREE today: no
--   backfill, nobody's access changes, no judgement call about who keeps what.
--
--   The moment one person holds it, splitting becomes a migration that must
--   choose between over-granting -- give every holder all of them, and a
--   payroll clerk silently acquires the billable analysis -- or breaking
--   people. Neither is a decision worth making retroactively.
--
-- WHY NOT AN UMBRELLA `.view` PLUS SUB-ACTIONS
--   Two grants for one capability is an administrator footgun: grant the
--   report, the user still sees nothing, and the reason is invisible. And an
--   umbrella that also grants everything means report five silently widens
--   everyone who already holds it.
--
--   So `timesheet_reports.view` is RETIRED, not kept as a gate. The section is
--   already gated one level up by `reports_admin.view`, which App.tsx puts on
--   the /admin/reports route. A second section gate underneath it adds nothing
--   but a way to be locked out for a reason nobody can see.
--
--   This honours 739's reasoning rather than reversing it. 739 kept
--   `timesheet_reports.view` because "PermissionMatrix DOES offer it, so an
--   administrator can grant it today and reasonably expect something to
--   happen." The promise was that granting it does something. Two specific
--   permissions in the same band, each of which opens a named report, keeps
--   that promise better than one vague one did.
--
-- WHY ONLY TWO NEW PERMISSIONS
--   Workforce Capacity and the Executive Dashboard are designed but not built.
--   Seeding `view_capacity` and `view_analytics` now would create exactly what
--   739 spent a migration cleaning up: permissions an administrator can grant
--   that do nothing at all. They arrive with their screens.
--
-- Depends on : 732 (created the module), 739 (retired the dead siblings),
--              744 (the two RPCs this repoints)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the two new permissions
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO public.permissions (module_id, code, name, description, action, sort_order)
SELECT m.id,
       'timesheet_reports.view_compliance',
       'Timesheet Compliance Report',
       'Open the Compliance report -- who has and has not submitted, per month, '
       'including employees who logged nothing at all. Which employees appear is '
       'still decided by the Timesheet view target population, not by this.',
       'view_compliance',
       10
FROM   public.modules m
WHERE  m.code = 'timesheet_reports'
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.permissions (module_id, code, name, description, action, sort_order)
SELECT m.id,
       'timesheet_reports.view_utilisation',
       'Timesheet Utilisation Report',
       'Open the Utilisation report -- where recorded hours went, by employee, '
       'project and activity. Which employees appear is still decided by the '
       'Timesheet view target population, not by this.',
       'view_utilisation',
       20
FROM   public.modules m
WHERE  m.code = 'timesheet_reports'
ON CONFLICT (code) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — retire the umbrella, but ONLY if it is still held by nobody
-- ═══════════════════════════════════════════════════════════════════════════
-- The whole argument for doing this now is that the permission is ungranted.
-- If that has stopped being true between writing this and running it, the
-- argument is void and so is the migration -- abort and say what to do, rather
-- than quietly removing somebody's access.

DO $mig$
DECLARE
  v_perm_id uuid;
  v_sets    integer := 0;
  v_roles   integer := 0;
BEGIN
  SELECT id INTO v_perm_id FROM public.permissions WHERE code = 'timesheet_reports.view';

  IF v_perm_id IS NULL THEN
    RAISE NOTICE 'MIG 745: timesheet_reports.view is already gone. Nothing to retire.';
    RETURN;
  END IF;

  SELECT count(*) INTO v_sets
  FROM   public.permission_set_items WHERE permission_id = v_perm_id;

  IF to_regclass('public.role_permissions') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.role_permissions WHERE permission_id = $1'
      INTO v_roles USING v_perm_id;
  END IF;

  IF v_sets > 0 OR v_roles > 0 THEN
    RAISE EXCEPTION E'MIG 745 ABORT: timesheet_reports.view is granted (% permission set item(s), % role grant(s)).\n'
      '  This migration assumes it is held by nobody -- that assumption is what made the split free.\n'
      '  Grant timesheet_reports.view_compliance and/or .view_utilisation to those holders first,\n'
      '  then re-run.', v_sets, v_roles;
  END IF;

  DELETE FROM public.permissions WHERE id = v_perm_id;
  RAISE NOTICE 'MIG 745: retired timesheet_reports.view (was granted to nobody).';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — each RPC checks its own action
-- ═══════════════════════════════════════════════════════════════════════════
-- Hiding a tab is cosmetic. Both of these are reachable through PostgREST by
-- anyone holding a token, which is the same reason 742 made a rejected
-- timesheet a property of the data rather than of the markup.
--
-- Patched in place with an asserted hit count rather than rewritten from the
-- file, so the two-phase pagination rework (Phase A) does not have to be
-- rebased onto a copy of these functions that this migration froze.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;
  v_old  text := '  IF NOT user_can(''timesheet_reports'', ''view'', NULL) THEN';
  r      record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('timesheet_report_compliance',  'view_compliance'),
      ('timesheet_report_utilisation', 'view_utilisation')
    ) AS t(fn, action)
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = r.fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'MIG 745: % not found. Migration 744 must run first.', r.fn;
    END IF;

    IF position('''' || r.action || '''' IN v_src) > 0 THEN
      RAISE NOTICE 'MIG 745: % already checks %. Nothing to do.', r.fn, r.action;
      CONTINUE;
    END IF;

    v_hits := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 745: expected exactly 1 permission gate in %, found %.', r.fn, v_hits;
    END IF;

    v_new := replace(v_src, v_old,
      '  IF NOT user_can(''timesheet_reports'', ''' || r.action || ''', NULL) THEN');

    EXECUTE v_new;
    RAISE NOTICE 'MIG 745: % now checks timesheet_reports.%.', r.fn, r.action;
  END LOOP;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_src     text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE code = 'timesheet_reports.view_compliance') THEN
    v_missing := v_missing || 'timesheet_reports.view_compliance was not created'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE code = 'timesheet_reports.view_utilisation') THEN
    v_missing := v_missing || 'timesheet_reports.view_utilisation was not created'::text; END IF;

  -- Both must hang off the module, or the Reports band in PermissionMatrix
  -- (which filters on code LIKE 'timesheet_reports.%') shows them while
  -- get_my_permissions, which joins through module_id, does not.
  IF EXISTS (
    SELECT 1 FROM public.permissions p
    LEFT JOIN public.modules m ON m.id = p.module_id
    WHERE p.code LIKE 'timesheet_reports.%'
      AND (m.code IS DISTINCT FROM 'timesheet_reports')
  ) THEN
    v_missing := v_missing || 'a timesheet_reports.* permission is not attached to its module'::text; END IF;

  IF EXISTS (SELECT 1 FROM public.permissions WHERE code = 'timesheet_reports.view') THEN
    v_missing := v_missing || 'the umbrella timesheet_reports.view survived'::text; END IF;

  FOR v_src IN
    SELECT pg_get_functiondef(p.oid) FROM pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('timesheet_report_compliance','timesheet_report_utilisation')
  LOOP
    IF position('''timesheet_reports'', ''view''' IN v_src) > 0 THEN
      v_missing := v_missing || 'an RPC still checks the retired umbrella permission'::text; END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 745 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 745 verified: one permission per report; each RPC checks its own.';
END $mig$;

COMMIT;
