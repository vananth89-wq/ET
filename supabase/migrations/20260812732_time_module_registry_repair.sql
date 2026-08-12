-- Migration : 20260812732_time_module_registry_repair.sql
-- Purpose   : Make every time-management RLS policy actually enforceable.
--
-- ROOT CAUSE
--   user_can(p_module, p_action, p_owner) resolves a grant by MODULE CODE:
--
--     JOIN modules m ON m.id = p.module_id
--     WHERE m.code = p_module AND p.action = p_action
--
--   Migration 706 registered every time-management permission under a single
--   module whose code is 'time_management', while naming the permission codes
--   after the resource ('timesheet.view', 'time_types.edit', ...). Every RLS
--   policy and RPC in the time module passes the RESOURCE name:
--
--     CREATE POLICY "tsh_insert" ON timesheet_headers
--       FOR INSERT TO authenticated
--       WITH CHECK (user_can('timesheet', 'create', employee_id));
--
--   There is no module whose code is 'timesheet', so m.code = p_module never
--   matches and user_can returns false for everyone. The only reason the
--   product worked at all is Path A -- the is_super_admin() UUID allowlist --
--   which returns true before any of this runs. The first non-super-admin to
--   open a timesheet got:
--
--     new row violates row-level security policy for table "timesheet_headers"
--
--   and would have got an empty month even if the INSERT had been allowed,
--   because tsh_select_own fails the same way.
--
-- THE INVARIANT THIS RESTORES
--   Migration 082 seeded the RBP catalogue by DERIVING the permission code
--   from the module code:
--
--     SELECT p.module_code || '.' || p.action AS code, ..., m.id, p.action
--     FROM (VALUES ('expense_reports','view',...), ...) AS p(module_code, action, ...)
--     JOIN modules m ON m.code = p.module_code
--
--   so the design invariant is:
--
--     permissions.code = modules.code || '.' || permissions.action
--
--   That is what makes user_can('expense_reports','view',...) work. Time
--   management is the only area that produced codes LOOKING like the
--   convention without the modules to back them.
--
-- PRECEDENT
--   This exact bug was found and fixed once before, for two other resources:
--   20260602421_fix_satellite_module_ids.sql ("Satellite permissions
--   (bank_accounts.*, dependents.*) were seeded with module_id pointing to the
--   'employee' module as a workaround"). This migration follows its shape:
--   create the module, re-point permissions.module_id, assert none are left.
--
-- WHY THIS IS UI-SAFE
--   Verified against the frontend, not assumed:
--     * PermissionMatrix.tsx builds its rows from a HARDCODED list keyed by
--       permission CODE (EV_GROUPS / ADMIN_GROUPS / the bulk import-export
--       table). It reads `modules` only to label rows. Re-parenting is
--       invisible to it.
--     * get_my_permissions() returns permission CODES and never joins modules.
--   So no grant, no screen and no gate changes meaning because of PART 1-2.
--
-- Depends on : 003 (modules, permissions), 092 (permission_set_items),
--              706/707/708 (the time-management catalogue), 421 (precedent)

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 0 — allow 'approve' as an action
-- ═══════════════════════════════════════════════════════════════════════════
-- permissions.action carries a CHECK that has been extended each time a new
-- verb was needed ('reassign' most recently, in mig 545). PART 3 needs
-- 'approve'.
--
-- WHY THIS IS NOT A HARD-CODED LIST
--   The first attempt at this migration re-stated mig 545's list verbatim plus
--   'approve', and Dev refused it:
--
--     ERROR: check constraint "permissions_action_check" of relation
--            "permissions" is violated by some row
--
--   Some row already carries an action outside that list -- added through the
--   Permission Catalogue screen, or by a migration whose seed drifted. This
--   migration's business is adding one verb, not adjudicating values it did
--   not create, and a deployment must not fail on the difference between a
--   replay and the real thing. So the new constraint is the canonical list
--   PLUS 'approve' PLUS whatever is already in the column, and anything in
--   that third category is named in a WARNING so it is visible in the deploy
--   log rather than silently enshrined.
--
--   NULL actions are untouched: a CHECK is satisfied by NULL, and 19 legacy
--   pre-RBP permission rows have one.

DO $$
DECLARE
  v_canonical text[] := ARRAY['view','create','edit','delete','history','lookup',
                              'view_all_pending','edit_all_pending',
                              'bulk_import','bulk_export',
                              'view_inactive','reassign','approve'];
  v_extra     text[];
  v_allowed   text[];
BEGIN
  SELECT COALESCE(array_agg(DISTINCT action), ARRAY[]::text[])
    INTO v_extra
  FROM   public.permissions
  WHERE  action IS NOT NULL
    AND  action <> ALL (v_canonical);

  IF COALESCE(array_length(v_extra, 1), 0) > 0 THEN
    RAISE WARNING 'MIG 732: permissions.action holds % value(s) outside the canonical '
                  'set: %. Preserved rather than rejected -- this migration only adds '
                  '''approve''. Worth checking whether they are intentional.',
                  array_length(v_extra, 1), array_to_string(v_extra, ', ');
  END IF;

  v_allowed := v_canonical || v_extra;

  EXECUTE 'ALTER TABLE public.permissions DROP CONSTRAINT IF EXISTS permissions_action_check';
  EXECUTE format(
    'ALTER TABLE public.permissions ADD CONSTRAINT permissions_action_check '
    'CHECK (action = ANY (%L::text[]))', v_allowed);

  RAISE NOTICE 'MIG 732: permissions_action_check now admits % value(s).',
               array_length(v_allowed, 1);
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the modules the policies have been asking for all along
-- ═══════════════════════════════════════════════════════════════════════════
-- Placed in a free sort_order band (120+). 'time_management' currently sits at
-- 60, colliding with 'picklists', and these eleven need to stay contiguous.

INSERT INTO public.modules (code, name, active, sort_order)
VALUES
  -- Employee-facing
  ('timesheet',               'Timesheet',                    true, 120),
  -- Manager / admin facing
  ('timesheet_manager',       'Timesheet (Manager)',          true, 121),
  ('timesheet_admin',         'Timesheet (Admin)',            true, 122),
  ('timesheet_reports',       'Timesheet Reports',            true, 123),
  -- Configuration
  ('time_work_schedules',     'Work Schedules',               true, 124),
  ('time_holiday_calendars',  'Holiday Calendars',            true, 125),
  ('time_holidays',           'Holidays',                     true, 126),
  ('time_types',              'Time Types',                   true, 127),
  ('time_color_config',       'Timesheet Color Config',       true, 128),
  ('time_edit_config',        'Timesheet Edit Window',        true, 129),
  ('time_submission_config',  'Timesheet Submission Config',  true, 130)
ON CONFLICT (code) DO UPDATE
  SET name   = EXCLUDED.name,
      active = true;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — re-point the permissions at them
-- ═══════════════════════════════════════════════════════════════════════════
-- permission_set_items stores permission UUIDs, so changing module_id moves
-- nobody's grant. Prefix matching is on 'code.' WITH the dot, so 'timesheet.%'
-- cannot swallow 'timesheet_admin.%'.

DO $$
DECLARE
  r        record;
  v_moved  integer;
  v_total  integer := 0;
BEGIN
  FOR r IN
    SELECT code, id FROM public.modules
    WHERE code IN ('timesheet','timesheet_manager','timesheet_admin','timesheet_reports',
                   'time_work_schedules','time_holiday_calendars','time_holidays',
                   'time_types','time_color_config','time_edit_config',
                   'time_submission_config')
  LOOP
    UPDATE public.permissions
    SET    module_id = r.id
    WHERE  code LIKE r.code || '.%'
      AND  module_id IS DISTINCT FROM r.id;

    GET DIAGNOSTICS v_moved = ROW_COUNT;
    v_total := v_total + v_moved;
    IF v_moved > 0 THEN
      RAISE NOTICE 'MIG 732: re-parented % permission(s) to module %', v_moved, r.code;
    END IF;
  END LOOP;

  RAISE NOTICE 'MIG 732: % permission(s) re-parented in total.', v_total;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — correct four wrong action values
-- ═══════════════════════════════════════════════════════════════════════════
-- These are not tidying. user_can matches on (module, ACTION), so PART 1 is
-- what ARMS them -- until now they were unreachable and therefore harmless:
--
--   timesheet.bulk_export     action 'view'   -> would satisfy
--                             user_can('timesheet','view', <anyone in scope>),
--                             i.e. a bulk-export grant would silently confer
--                             read access to other people's timesheets.
--   timesheet.bulk_import     action 'create' -> would satisfy
--                             user_can('timesheet','create', ...).
--   timesheet_admin.approve   action 'edit'   -> approve would imply edit.
--   timesheet_manager.approve action 'edit'   -> approve would imply edit.
--
-- Every other bulk permission in the catalogue already uses action
-- 'bulk_import' / 'bulk_export' (department.*, employees.*, picklist.*,
-- education.* and ten more) -- the timesheet pair are the outliers, and
-- PermissionMatrix.tsx addresses bulk rows by CODE, not action, so the
-- Import/Export screen is unaffected.

UPDATE public.permissions SET action = 'bulk_import' WHERE code = 'timesheet.bulk_import'     AND action <> 'bulk_import';
UPDATE public.permissions SET action = 'bulk_export' WHERE code = 'timesheet.bulk_export'     AND action <> 'bulk_export';
UPDATE public.permissions SET action = 'approve'     WHERE code = 'timesheet_admin.approve'   AND action <> 'approve';
UPDATE public.permissions SET action = 'approve'     WHERE code = 'timesheet_manager.approve' AND action <> 'approve';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — register timesheet.create
-- ═══════════════════════════════════════════════════════════════════════════
-- tsh_insert has always demanded user_can('timesheet','create', employee_id)
-- but migration 707 registered 'create' codes for five time-management
-- resources and skipped the timesheet itself. Following the expense_reports
-- shape, which is the reference EV module and does carry a 'create'.

INSERT INTO public.permissions (module_id, code, name, description, action, sort_order)
SELECT m.id,
       'timesheet.create',
       'Create Own Timesheet',
       'Open a month for the first time. The monthly header is created '
       'automatically when the employee opens the Timesheet screen, so this '
       'is normally granted wherever Edit Own Timesheet is granted.',
       'create',
       79
FROM   public.modules m
WHERE  m.code = 'timesheet'
ON CONFLICT (code) DO UPDATE
  SET module_id   = EXCLUDED.module_id,
      name        = EXCLUDED.name,
      description = EXCLUDED.description,
      action      = EXCLUDED.action;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — grant it wherever timesheet.edit is already granted
-- ═══════════════════════════════════════════════════════════════════════════
-- Without this the migration is correct and changes nothing: every existing
-- permission set was built before 'timesheet.create' existed, so no set holds
-- it and every ESS user still gets the RLS error. Anyone already trusted to
-- put entries on a timesheet is by definition trusted to have one.
--
-- One-shot backfill of existing sets only. New sets are the Permission
-- Matrix's job.

INSERT INTO public.permission_set_items (permission_set_id, permission_id)
SELECT psi.permission_set_id, pc.id
FROM   public.permission_set_items psi
JOIN   public.permissions pe ON pe.id = psi.permission_id AND pe.code = 'timesheet.edit'
CROSS  JOIN LATERAL (SELECT id FROM public.permissions WHERE code = 'timesheet.create') pc
ON CONFLICT (permission_set_id, permission_id) DO NOTHING;

DO $$
DECLARE v_sets integer;
BEGIN
  SELECT count(*) INTO v_sets
  FROM   permission_set_items psi
  JOIN   permissions p ON p.id = psi.permission_id
  WHERE  p.code = 'timesheet.create';
  RAISE NOTICE 'MIG 732: timesheet.create now held by % permission set(s).', v_sets;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 6 — retire the empty container
-- ═══════════════════════════════════════════════════════════════════════════
-- 'time_management' holds nothing after PART 2. Deactivated rather than
-- deleted: past migrations look it up by code (SELECT id INTO v_module_id
-- FROM modules WHERE code = 'time_management') and a DELETE would make a
-- replay from zero fail on a NOT NULL module_id. Only deactivated if it is
-- genuinely empty, so a re-run after someone re-adds a permission is safe.

UPDATE public.modules m
SET    active = false,
       name   = 'Time Management (retired — see per-resource modules)'
WHERE  m.code = 'time_management'
  AND  m.active
  AND  NOT EXISTS (SELECT 1 FROM public.permissions p WHERE p.module_id = m.id);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 7 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_bad     integer;
  v_detail  text;
  v_missing text;
BEGIN
  -- 7a. The invariant, for every time-management permission.
  SELECT count(*), string_agg(p.code || ' -> ' || m.code || '/' || p.action, ', ')
    INTO v_bad, v_detail
  FROM   permissions p
  JOIN   modules m ON m.id = p.module_id
  WHERE  (p.code LIKE 'timesheet%' OR p.code LIKE 'time\_%')
    AND  p.code <> m.code || '.' || p.action;

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'MIG 732 ABORT: % time permission(s) still break code = module.action: %',
      v_bad, v_detail;
  END IF;

  -- 7b. Every module code the time-management RLS policies and RPCs pass to
  --     user_can() must now exist AND carry the actions those call sites ask
  --     for. Hard-coded from a grep of the call sites, so a future policy that
  --     invents a module code will not be caught here -- but the ones that
  --     broke ESS will never break silently again.
  SELECT string_agg(x.want, ', ')
    INTO v_missing
  FROM (VALUES
    ('timesheet','view'), ('timesheet','create'), ('timesheet','edit'), ('timesheet','delete'),
    ('time_types','view'), ('time_types','create'), ('time_types','edit'), ('time_types','delete'),
    ('time_holidays','view'), ('time_holidays','create'), ('time_holidays','edit'), ('time_holidays','delete'),
    ('time_holiday_calendars','view'), ('time_holiday_calendars','create'),
    ('time_holiday_calendars','edit'), ('time_holiday_calendars','delete'),
    ('time_work_schedules','view'), ('time_work_schedules','create'),
    ('time_work_schedules','edit'), ('time_work_schedules','delete'),
    ('time_color_config','view'), ('time_color_config','edit'),
    ('time_edit_config','view'), ('time_edit_config','edit'),
    ('time_submission_config','view'), ('time_submission_config','create'),
    ('time_submission_config','edit'), ('time_submission_config','delete')
  ) AS v(mod, act)
  CROSS JOIN LATERAL (SELECT v.mod || '.' || v.act AS want) x
  WHERE NOT EXISTS (
    SELECT 1 FROM permissions p JOIN modules m ON m.id = p.module_id
    WHERE m.code = v.mod AND p.action = v.act
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'MIG 732 ABORT: no grantable permission behind user_can(...) for: %', v_missing;
  END IF;

  -- 7c. Nothing in the time module left orphaned.
  SELECT count(*) INTO v_bad
  FROM   permissions
  WHERE  module_id IS NULL
    AND  (code LIKE 'timesheet%' OR code LIKE 'time\_%');
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'MIG 732 ABORT: % time permission(s) left with a NULL module_id.', v_bad;
  END IF;

  -- 7d. Orphans elsewhere are not this migration's to fix, but they are the
  --     same defect (a permission no user_can() call can ever reach) and
  --     nothing else reports them. Warn, do not abort.
  SELECT count(*), string_agg(code, ', ') INTO v_bad, v_detail
  FROM   permissions WHERE module_id IS NULL;
  IF v_bad > 0 THEN
    RAISE WARNING 'MIG 732: % permission(s) outside time management have a NULL '
                  'module_id and are unreachable by user_can(): %', v_bad, v_detail;
  END IF;

  RAISE NOTICE 'MIG 732 verified: time-management permissions are reachable by user_can().';
END $$;

COMMIT;
