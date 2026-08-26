-- =============================================================================
-- Migration 798: one module code for projects
--
-- THE DECISION
-- ════════════
-- Migration 223 registered two: project_create and project_edit. Only one of
-- them can ever be wired.
--
--   workflow_instances.record_id uuid NOT NULL
--
-- The engine cannot hold an approval for a row that does not exist, so a
-- create workflow needs the row inserted first in a draft state and the
-- instance pointed at it -- which is exactly what employee_hire does with
-- 'Pending' + locked = true. `projects` has no draft state, so project_create
-- has never been implementable and has never been used: zero workflow
-- instances, zero assignments, zero attachments.
--
-- Keeping a module code that can only ever mislead is worse than not having
-- it. The Assignments screen offers it, an administrator can attach a workflow
-- to it in good faith, and nothing happens.
--
-- WHY project_edit IS THE ONE THAT STAYS
-- ──────────────────────────────────────
--   * It is the one that can be wired -- an edit has a record to point at.
--   * Its edit_route is already right: '/admin/projects/' + id, so an approver
--     lands on the project. project_create's is '/admin/projects/new', which
--     cannot show a project that does not exist.
--   * It needs no new FK anchor. module_codes.code is a primary key referenced
--     by workflow_instances, attachments and module_registry, and its own
--     comment says it "must be stable" -- so inventing a third code to replace
--     two unused ones buys nothing.
--   * If projects ever gain a draft state, creating becomes activating a
--     draft, which is an edit. The name still holds.
--
-- WHAT THIS DOES NOT DO
-- ─────────────────────
-- It does not make approval work. Admin -> Projects still saves straight to
-- the table; attaching a workflow to project_edit today gates nothing. That is
-- Q11 in the design review, and it is a separate piece of work in the screen,
-- not in the registry. This migration only stops the registry from offering a
-- door that was never going to open.
--
-- It also does not touch notifications. Migrations 796 and 797 fire from
-- triggers and RPCs on the tables, never from the workflow engine; they are
-- unaffected either way.
--
-- CHANGES
-- ───────
--   module_codes  -- project_create removed, guarded on it being unused
-- =============================================================================

SET jit = 'off';

DO $mig$
DECLARE
  v_n     int;
  v_where text := '';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM module_codes WHERE code = 'project_create') THEN
    RAISE NOTICE 'mig 798: project_create is already gone -- skipping';
    RETURN;
  END IF;

  -- Refuse rather than cascade. If anything in this database ever did use the
  -- code, deleting it here would either fail on a foreign key or, worse,
  -- succeed against an expectation this migration was written without.
  SELECT count(*) INTO v_n FROM workflow_instances WHERE module_code = 'project_create';
  IF v_n > 0 THEN v_where := v_where || format('%s workflow instance(s); ', v_n); END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'attachments') THEN
    EXECUTE 'SELECT count(*) FROM attachments WHERE module_code = ''project_create'''
      INTO v_n;
    IF v_n > 0 THEN v_where := v_where || format('%s attachment(s); ', v_n); END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'module_registry') THEN
    EXECUTE 'SELECT count(*) FROM module_registry WHERE code = ''project_create'''
      INTO v_n;
    IF v_n > 0 THEN v_where := v_where || format('%s module_registry row(s); ', v_n); END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'workflow_assignments') THEN
    EXECUTE 'SELECT count(*) FROM workflow_assignments WHERE module_code = ''project_create'''
      INTO v_n;
    IF v_n > 0 THEN v_where := v_where || format('%s workflow assignment(s); ', v_n); END IF;
  END IF;

  IF v_where <> '' THEN
    RAISE EXCEPTION 'mig 798: project_create is in use (%) -- refusing to remove it', v_where;
  END IF;

  DELETE FROM module_codes WHERE code = 'project_create';
  RAISE NOTICE 'mig 798: project_create removed -- project_edit is the one code for projects';
END $mig$;


COMMENT ON TABLE module_codes IS
  'Canonical module identifiers. FK anchor for workflow_instances.module_code '
  'and attachments.module_code. Add a row here before building a new module. '
  'Mig 798: projects carry ONE code, project_edit. A create cannot be gated '
  'while workflow_instances.record_id is NOT NULL and projects has no draft '
  'state -- see the mig 798 header before adding project_create back.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM module_codes WHERE code = 'project_create';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig 798: project_create is still registered';
  END IF;

  -- The one that stays must still be there, with the route that makes an
  -- approver land on the project rather than on a blank form.
  SELECT count(*) INTO v_n FROM module_codes
  WHERE code = 'project_edit' AND edit_route = '/admin/projects/';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 798: project_edit is missing or its edit_route changed';
  END IF;

  RAISE NOTICE 'mig 798: OK -- one module code for projects, and it is the one that can work';
END $mig$;
