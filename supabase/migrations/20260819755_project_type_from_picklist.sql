-- =============================================================================
-- Migration : 20260819755_project_type_from_picklist.sql
-- Purpose   : Move projects.project_type off a hard-coded CHECK list and onto
--             the picklist system, so Reference Data owns the values.
--
-- WHY
--   754 shipped project_type as text with a CHECK allow-list. That makes the
--   set of project types a schema fact: adding "Capex" or "Pre-sales" needs a
--   migration, a deploy and a developer. Every other classification in Prowess
--   -- designation, currency, dependent relationship -- is a picklist an admin
--   edits in Reference Data, and this one is no different in kind.
--
-- SHAPE  Follows line_items.category_id, the existing precedent: the column is
--   a uuid FK to picklist_values, not a copy of the label. Renaming "Billable"
--   to "Client billable" in Reference Data then relabels every project at once
--   instead of orphaning them.
--
-- A PLAIN FK IS NOT ENOUGH.  picklist_values holds every value of every
--   picklist, so a bare FK would happily accept a CURRENCY row in
--   project_type_id. The trigger below pins it to the PROJECT_TYPE list. It is
--   SECURITY DEFINER because it must see the picklist rows to validate even
--   when RLS would hide them from the caller -- a guard that cannot read the
--   reference data would reject valid values.
--
-- THE OLD COLUMN IS KEPT, NOT DROPPED.
--   projects.project_type is now dead, but the frontend live in production at
--   the moment this migration runs still SELECTs it, and PostgREST 400s the
--   whole request when a selected column is missing -- that would take out the
--   entire Project Management screen, not just one field. So this migration is
--   safe to deploy AHEAD of the frontend, which is the order that works:
--
--     1. this migration          (old UI keeps working, project_type intact)
--     2. the frontend that reads project_type_id
--     3. a later migration drops projects.project_type
--
--   Dropping it here would invert the dependency and guarantee a broken window.
--
-- Depends on : 20260419001 (picklists, picklist_values, projects), 754
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1  Seed the picklist
--
-- ref_id carries the STABLE code. Reports must key off ref_id, never `value`:
-- the label is admin-editable by design, so matching on it would make
-- "billable utilisation" break the day somebody fixes a typo.
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO picklists (picklist_id, name)
VALUES ('PROJECT_TYPE', 'Project Type')
ON CONFLICT (picklist_id) DO NOTHING;

INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT p.id, v.label, v.ref, true
FROM   picklists p
CROSS  JOIN (VALUES ('Billable','BILLABLE'),
                    ('Internal','INTERNAL'),
                    ('Overhead','OVERHEAD')) AS v(label, ref)
WHERE  p.picklist_id = 'PROJECT_TYPE'
  AND  NOT EXISTS (SELECT 1 FROM picklist_values pv
                   WHERE pv.picklist_id = p.id AND pv.ref_id = v.ref);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2  The column
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE projects ADD COLUMN IF NOT EXISTS project_type_id uuid;

DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'projects_project_type_id_fkey') THEN
    ALTER TABLE projects ADD CONSTRAINT projects_project_type_id_fkey
      FOREIGN KEY (project_type_id) REFERENCES picklist_values(id) ON DELETE SET NULL;
  END IF;
END $mig$;

CREATE INDEX IF NOT EXISTS idx_projects_project_type
  ON projects (project_type_id) WHERE project_type_id IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3  Pin the FK to the right picklist
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION projects_project_type_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NEW.project_type_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM   picklist_values pv
    JOIN   picklists       p ON p.id = pv.picklist_id
    WHERE  pv.id = NEW.project_type_id
      AND  p.picklist_id = 'PROJECT_TYPE'
  ) THEN
    RAISE EXCEPTION
      'projects.project_type_id must reference a value of the PROJECT_TYPE picklist'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$fn$;

COMMENT ON FUNCTION projects_project_type_guard() IS
  'Keeps project_type_id inside the PROJECT_TYPE picklist. A bare FK to '
  'picklist_values would accept a value from any list.';

DROP TRIGGER IF EXISTS trg_projects_project_type_guard ON projects;
CREATE TRIGGER trg_projects_project_type_guard
  BEFORE INSERT OR UPDATE OF project_type_id ON projects
  FOR EACH ROW EXECUTE FUNCTION projects_project_type_guard();

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4  Retire the hard-coded column, without removing it yet
-- ═══════════════════════════════════════════════════════════════════════════

COMMENT ON COLUMN projects.project_type IS
  'DEPRECATED as of 20260819755 -- superseded by project_type_id, which points '
  'at the PROJECT_TYPE picklist. Retained only so the frontend deployed at the '
  'time of this migration keeps working; a later migration drops it once no '
  'client selects it. Do not read or write this column.';

COMMENT ON COLUMN projects.project_type_id IS
  'Project classification, as a value of the PROJECT_TYPE picklist. NULL means '
  'not classified -- reports must show that plainly rather than assuming '
  'billable. Match on picklist_values.ref_id (BILLABLE / INTERNAL / OVERHEAD), '
  'never on the label, which admins may rename.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_n       integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM picklists WHERE picklist_id = 'PROJECT_TYPE') THEN
    v_missing := v_missing || 'the PROJECT_TYPE picklist is missing'::text; END IF;

  SELECT count(*) INTO v_n
  FROM   picklist_values pv JOIN picklists p ON p.id = pv.picklist_id
  WHERE  p.picklist_id = 'PROJECT_TYPE' AND pv.ref_id IN ('BILLABLE','INTERNAL','OVERHEAD');
  IF v_n <> 3 THEN
    v_missing := v_missing || format('expected 3 seeded PROJECT_TYPE values, found %s', v_n); END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'projects' AND column_name = 'project_type_id') THEN
    v_missing := v_missing || 'projects.project_type_id is missing'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'projects_project_type_id_fkey' AND contype = 'f' AND confdeltype = 'n') THEN
    v_missing := v_missing || 'project_type_id must be a FK to picklist_values with ON DELETE SET NULL'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgname = 'trg_projects_project_type_guard' AND NOT tgisinternal) THEN
    v_missing := v_missing || 'the PROJECT_TYPE guard trigger is missing -- any picklist value would be accepted'::text; END IF;

  -- The old column must SURVIVE this migration. Dropping it takes out the
  -- Project Management screen of whatever frontend is live right now.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'projects' AND column_name = 'project_type') THEN
    v_missing := v_missing || 'projects.project_type was dropped too early -- the live frontend still selects it'::text; END IF;

  -- 754 must survive intact.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'projects_manager_id_fkey' AND contype = 'f' AND confdeltype = 'n') THEN
    v_missing := v_missing || 'mig 754: the manager FK was lost'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'projects_budget_hours_check') THEN
    v_missing := v_missing || 'mig 754: the budget_hours check was lost'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 755 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 755 verified: Reference Data owns the project types. Deploy the frontend AFTER this.';
END $mig$;

COMMIT;
