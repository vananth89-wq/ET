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
-- PART 0 — widen permissions_action_check FIRST
-- ═══════════════════════════════════════════════════════════════════════════
-- `permissions.action` is an enumerated allow-list, not free text. Every
-- migration that introduces a verb has had to widen it first -- 147 for
-- 'lookup', 217 for 'view_all_pending', 359 for the bulk verbs, 570 for
-- 'reassign', 732 for 'approve'. This one adds four report verbs and must do
-- the same. Omitting it is why the first attempt at this migration failed on
-- Dev with SQLSTATE 23514 at the very first INSERT.
--
-- The mechanism is lifted verbatim from 732, including its reasoning: the new
-- constraint is the canonical list PLUS the new verbs PLUS whatever is already
-- in the column, so a replay against a database carrying a value this migration
-- did not create cannot fail on a difference it has no business adjudicating.
-- Anything in that third category is named in a WARNING rather than silently
-- enshrined. NULL actions are untouched -- a CHECK is satisfied by NULL, and
-- legacy pre-RBP rows have one.
--
-- All four report verbs go in, including the two whose reports are not built.
-- A CHECK value is not a grantable permission: it is invisible to an
-- administrator and does nothing until a row uses it. That is a different thing
-- from seeding a permission an admin can grant that has no screen behind it,
-- which PART 1 deliberately does not do.

DO $mig$
DECLARE
  v_canonical text[] := ARRAY['view','create','edit','delete','history','lookup',
                              'view_all_pending','edit_all_pending',
                              'bulk_import','bulk_export',
                              'view_inactive','reassign','approve',
                              'view_compliance','view_utilisation',
                              'view_capacity','view_analytics'];
  v_extra     text[];
  v_allowed   text[];
BEGIN
  SELECT COALESCE(array_agg(DISTINCT action), ARRAY[]::text[])
    INTO v_extra
  FROM   public.permissions
  WHERE  action IS NOT NULL
    AND  action <> ALL (v_canonical);

  IF COALESCE(array_length(v_extra, 1), 0) > 0 THEN
    RAISE WARNING 'MIG 745: permissions.action holds % value(s) outside the canonical '
                  'set: %. Preserved rather than rejected -- this migration only adds '
                  'the four report verbs. Worth checking whether they are intentional.',
                  array_length(v_extra, 1), array_to_string(v_extra, ', ');
  END IF;

  v_allowed := v_canonical || v_extra;

  EXECUTE 'ALTER TABLE public.permissions DROP CONSTRAINT IF EXISTS permissions_action_check';
  EXECUTE format(
    'ALTER TABLE public.permissions ADD CONSTRAINT permissions_action_check '
    'CHECK (action = ANY (%L::text[]))', v_allowed);

  RAISE NOTICE 'MIG 745: permissions_action_check now admits % value(s).',
               array_length(v_allowed, 1);
END $mig$;


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
-- PART 2 — retire the umbrella, carrying any grant forward
-- ═══════════════════════════════════════════════════════════════════════════
-- This part originally ABORTED if the umbrella turned out to be granted, on the
-- reasoning that "held by nobody" was what made the split free. That guard
-- fired on the first real deploy -- because granting it was the only way to
-- test the reports before this migration existed. The assumption was true when
-- written and false when run.
--
-- Aborting is the right default when a migration cannot know what the operator
-- wants. Here it can. `timesheet_reports.view` opened the timesheet report, and
-- the timesheet report is exactly these two views, so granting both replacements
-- to every holder preserves the access they have rather than widening or
-- narrowing it. That is a translation, not a judgement call, and demanding a
-- human un-tick a box in the UI before a deploy will run is a worse answer than
-- doing the obvious thing and saying so in the log.
--
-- If an administrator wants only one of the two afterwards, that is one click in
-- the Permission Matrix -- which is now, for the first time, a choice they can
-- express.

DO $mig$
DECLARE
  v_perm_id  uuid;
  v_new_ids  uuid[];
  v_sets     integer := 0;
  v_roles    integer := 0;
BEGIN
  SELECT id INTO v_perm_id FROM public.permissions WHERE code = 'timesheet_reports.view';

  IF v_perm_id IS NULL THEN
    RAISE NOTICE 'MIG 745: timesheet_reports.view is already gone. Nothing to retire.';
    RETURN;
  END IF;

  SELECT array_agg(id) INTO v_new_ids
  FROM   public.permissions
  WHERE  code IN ('timesheet_reports.view_compliance', 'timesheet_reports.view_utilisation');

  IF COALESCE(array_length(v_new_ids, 1), 0) <> 2 THEN
    RAISE EXCEPTION 'MIG 745: expected both replacement permissions to exist before retiring the umbrella, found %.',
                    COALESCE(array_length(v_new_ids, 1), 0);
  END IF;

  -- ── Permission sets ──────────────────────────────────────────────────────
  INSERT INTO public.permission_set_items (permission_set_id, permission_id)
  SELECT psi.permission_set_id, n.id
  FROM   public.permission_set_items psi
  CROSS  JOIN unnest(v_new_ids) AS n(id)
  WHERE  psi.permission_id = v_perm_id
  ON CONFLICT (permission_set_id, permission_id) DO NOTHING;

  GET DIAGNOSTICS v_sets = ROW_COUNT;

  -- ── Legacy role grants, if that table is still around ────────────────────
  IF to_regclass('public.role_permissions') IS NOT NULL THEN
    EXECUTE $q$
      INSERT INTO public.role_permissions (role_id, permission_id)
      SELECT rp.role_id, n.id
      FROM   public.role_permissions rp
      CROSS  JOIN unnest($1) AS n(id)
      WHERE  rp.permission_id = $2
        AND  NOT EXISTS (SELECT 1 FROM public.role_permissions x
                          WHERE x.role_id = rp.role_id AND x.permission_id = n.id)
    $q$ USING v_new_ids, v_perm_id;
    GET DIAGNOSTICS v_roles = ROW_COUNT;

    EXECUTE 'DELETE FROM public.role_permissions WHERE permission_id = $1' USING v_perm_id;
  END IF;

  IF v_sets > 0 OR v_roles > 0 THEN
    RAISE NOTICE 'MIG 745: carried the umbrella grant forward -- % permission-set row(s) and % role row(s) '
                 'now hold BOTH view_compliance and view_utilisation. Nobody lost access; nobody gained a '
                 'report they could not already open.', v_sets, v_roles;
  ELSE
    RAISE NOTICE 'MIG 745: timesheet_reports.view was granted to nobody.';
  END IF;

  -- permission_set_items cascades on the FK; role_permissions was cleared above.
  DELETE FROM public.permissions WHERE id = v_perm_id;
  RAISE NOTICE 'MIG 745: retired timesheet_reports.view.';
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

  -- Every permission set that held the umbrella must now hold both replacements.
  -- Checked as "no set holds exactly one of them", which also catches a partial
  -- carry-forward, not just a missing one.
  IF EXISTS (
    SELECT psi.permission_set_id
    FROM   public.permission_set_items psi
    JOIN   public.permissions p ON p.id = psi.permission_id
    WHERE  p.code IN ('timesheet_reports.view_compliance','timesheet_reports.view_utilisation')
    GROUP  BY psi.permission_set_id
    HAVING count(*) = 1
       AND EXISTS (SELECT 1 FROM public.permission_sets ps WHERE ps.id = psi.permission_set_id)
  ) AND (SELECT count(*) FROM public.permission_set_items psi2
         JOIN public.permissions p2 ON p2.id = psi2.permission_id
         WHERE p2.code LIKE 'timesheet_reports.%') > 0 THEN
    RAISE NOTICE 'MIG 745: at least one permission set holds one report permission but not the other. '
                 'That is legitimate if an administrator chose it -- flagged, not failed.';
  END IF;

  -- PART 0. Without it the INSERTs above cannot land, so a failure here means
  -- the constraint was widened and then narrowed again by something else.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'permissions_action_check'
      AND pg_get_constraintdef(oid) LIKE '%view_compliance%'
      AND pg_get_constraintdef(oid) LIKE '%view_utilisation%'
  ) THEN
    v_missing := v_missing || 'permissions_action_check does not admit the report verbs'::text; END IF;

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
