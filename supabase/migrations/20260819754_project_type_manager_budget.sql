-- =============================================================================
-- Migration : 20260819754_project_type_manager_budget.sql
-- Purpose   : Three columns on `projects`. Two unblock the Project Summary
--             report; one unblocks the Project Manager persona entirely.
--
-- WHY THESE THREE, AND WHY NOW
--
--   budget_hours  Every project report opens with "hours against budget", and
--                 there is nowhere to put a budget today. Without it
--                 `Consumed %` has no denominator -- the same hole that made
--                 the Utilisation rate meaningless under a project filter
--                 (mig 752 and design doc s8.1b).
--
--   project_type  Billable utilisation is the number Finance opens the report
--                 for, and it cannot be computed from anything now stored.
--
--   manager_id    SECURITY, not display. Every persona in the RBP engine is
--                 scoped by EMPLOYEE: get_target_population() returns employee
--                 ids and time_report_scope_ids() filters on them. A Project
--                 Manager is scoped by PROJECT -- they need the hours logged
--                 against their project by people who may sit in departments
--                 they cannot see individually. Nothing in the schema can
--                 answer "is this caller the manager of this project", so the
--                 PM scope predicate cannot be written at all. This column is
--                 the minimum that makes it writable.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   It grants nothing. `timesheet.view_project`, the PM scope predicate and the
--   column redaction described in design doc s5 are the largest piece of new
--   security work in the suite and are deliberately NOT folded into a schema
--   change. Adding a column that no policy reads is inert; adding a policy in
--   the same breath as the column it reads is how a scope bug ships unnoticed.
--
-- DECISIONS
--
--   ONE manager per project, held as a column rather than a project_members
--   table. RLS needs exactly one question answered. A members table answers a
--   larger question -- who is assigned, in what role, over what dates -- that
--   nobody has asked for, and remains a purely additive change later.
--
--   manager_id is the project's REPORTING MANAGER: the manager the project
--   reports into, not necessarily whoever runs delivery day to day.
--
--   project_type is NULLABLE WITH NO DEFAULT. The design doc originally said
--   NOT NULL DEFAULT 'billable'; that is wrong for the same reason a fake
--   denominator is wrong. Defaulting every existing project to billable would
--   make "Billable utilisation 100%" appear on day one, computed entirely from
--   a value nobody chose. NULL means "not classified" and is a state the report
--   must show plainly, exactly as budget_hours does -- consistent with s9's
--   rule that `No budget set` is a real status rather than a hidden row.
--
--   ON DELETE SET NULL on manager_id. A project whose manager row disappears
--   loses its manager and therefore grants nobody PM access -- it fails closed.
--   The alternative, RESTRICT, blocks deleting an employee because a project
--   points at them, which turns an HR action into a project-admin puzzle.
--
--   budget_hours is HOURS, not currency. Prowess records time, not cost, and a
--   money budget invites a rate-card conversation this module should not own.
--
-- NOTE ON SCOPE  `projects` is shared with Expenses. These columns are additive
--   and no expense policy reads them. If expense visibility is ever keyed off
--   manager_id that is a separate, deliberate decision -- a timesheet PM scope
--   must not silently become an expense scope.
--
-- Depends on : 20260419001 (projects, employees)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1  Columns
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE projects ADD COLUMN IF NOT EXISTS project_type text;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS manager_id   uuid;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS budget_hours numeric(10,2);

DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'projects_project_type_check') THEN
    ALTER TABLE projects ADD CONSTRAINT projects_project_type_check
      CHECK (project_type IS NULL OR project_type IN ('billable','internal','overhead'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'projects_budget_hours_check') THEN
    ALTER TABLE projects ADD CONSTRAINT projects_budget_hours_check
      CHECK (budget_hours IS NULL OR budget_hours > 0);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'projects_manager_id_fkey') THEN
    ALTER TABLE projects ADD CONSTRAINT projects_manager_id_fkey
      FOREIGN KEY (manager_id) REFERENCES employees(id) ON DELETE SET NULL;
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2  Index
--
-- Partial: the PM scope predicate only ever asks for rows where manager_id
-- matches a caller, so the un-managed rows are dead weight in the index.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_projects_manager
  ON projects (manager_id) WHERE manager_id IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3  Documentation, in the database
--
-- The table comment predates timesheets and still claims projects exist for
-- expense line items alone. Anyone reading the schema to answer "can a PM see
-- this" needs to know the table now carries a security-bearing column.
-- ═══════════════════════════════════════════════════════════════════════════

COMMENT ON TABLE projects IS
  'Projects that expense line items and timesheet entries are recorded against.';

COMMENT ON COLUMN projects.project_type IS
  'billable | internal | overhead. NULL means not classified -- reports must '
  'show that plainly rather than defaulting it, or billable utilisation is '
  'computed from a value nobody chose.';

COMMENT ON COLUMN projects.manager_id IS
  'The project reporting manager, as an employee. SECURITY-BEARING: this is '
  'the only column that can answer "is this caller the manager of this '
  'project", which is what a Project Manager scope predicate needs. One '
  'manager per project by design; a project_members table is additive if '
  'assignment tracking is ever required. NULL grants nobody PM access.';

COMMENT ON COLUMN projects.budget_hours IS
  'Planned hours for the whole project. NULL is a real state -- a project '
  'without a budget shows consumption without a percentage, never a fake '
  'denominator. Hours, not currency: Prowess records time, not cost.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_ok      boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'projects' AND column_name = 'project_type') THEN
    v_missing := v_missing || 'projects.project_type is missing'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'projects' AND column_name = 'manager_id') THEN
    v_missing := v_missing || 'projects.manager_id is missing'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'projects' AND column_name = 'budget_hours') THEN
    v_missing := v_missing || 'projects.budget_hours is missing'::text; END IF;

  -- project_type must stay nullable. A later migration adding NOT NULL DEFAULT
  -- would silently classify every project and make billable utilisation a
  -- fabricated number, so assert the shape rather than trusting the comment.
  SELECT is_nullable = 'YES' INTO v_ok FROM information_schema.columns
   WHERE table_name = 'projects' AND column_name = 'project_type';
  IF NOT COALESCE(v_ok, false) THEN
    v_missing := v_missing || 'project_type must remain nullable -- NULL is "not classified"'::text; END IF;

  SELECT column_default IS NULL INTO v_ok FROM information_schema.columns
   WHERE table_name = 'projects' AND column_name = 'project_type';
  IF NOT COALESCE(v_ok, false) THEN
    v_missing := v_missing || 'project_type must have no default'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'projects_project_type_check') THEN
    v_missing := v_missing || 'the project_type allow-list is missing'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'projects_budget_hours_check') THEN
    v_missing := v_missing || 'budget_hours may be zero or negative'::text; END IF;

  -- The FK must exist AND be ON DELETE SET NULL, so a departing employee never
  -- leaves a project pointing at a row that is gone, and never blocks the
  -- delete either.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'projects_manager_id_fkey' AND contype = 'f' AND confdeltype = 'n') THEN
    v_missing := v_missing || 'manager_id must be a FK to employees with ON DELETE SET NULL'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE tablename = 'projects' AND indexname = 'idx_projects_manager') THEN
    v_missing := v_missing || 'the manager index is missing -- the PM scope predicate would seq scan'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 754 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 754 verified: projects carry a type, a reporting manager and a budget. No policy reads them yet.';
END $mig$;

COMMIT;
