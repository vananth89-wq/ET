-- =============================================================================
-- Migration 359 — Job Relationships (Matrix Managers): Schema, Picklist, Permissions
--
-- Introduces SuccessFactors-style matrix-manager assignments per employee.
-- Up to 6 codes (PM01–OM03) per employee, effective-dated via the set-snapshot
-- pattern (matches dependents / bank / employment models).
--
-- Changes:
--   1. Create employee_job_relationship_set (effective-dated parent)
--   2. Create employee_job_relationship_item (per-code children)
--   3. Add 6 mirror columns to employees (pm01_manager_id … om03_manager_id)
--   4. Guard trigger: blocks ad-hoc UPDATEs to mirror columns
--   5. Seed JOB_RELATIONSHIP_TYPE picklist (6 codes)
--   6. Register job_relationships module
--   7. Seed 5 permissions (view, edit, history, bulk_import, bulk_export)
--   8. RLS policies on both satellite tables
--
-- Design spec: docs/job-relationships-design.md §3, §10
-- Next migration: 20260530360 (RPCs)
-- =============================================================================


-- =============================================================================
-- 1. employee_job_relationship_set — effective-dated parent
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_job_relationship_set (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     UUID        NOT NULL REFERENCES employees(id)  ON DELETE CASCADE,
  effective_from  DATE        NOT NULL,
  effective_to    DATE        NOT NULL DEFAULT '9999-12-31'::date,
  is_active       BOOLEAN     NOT NULL DEFAULT true,
  created_by      UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  updated_by      UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_ejrs_effective_order CHECK (effective_to >= effective_from)
);

-- One open active set per employee (partial unique index)
CREATE UNIQUE INDEX IF NOT EXISTS idx_ejrs_one_active
  ON employee_job_relationship_set (employee_id)
  WHERE is_active = true AND effective_to = '9999-12-31'::date;

CREATE INDEX IF NOT EXISTS idx_ejrs_employee_timeline
  ON employee_job_relationship_set (employee_id, effective_from, effective_to);


-- =============================================================================
-- 2. employee_job_relationship_item — children of one snapshot
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_job_relationship_item (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  set_id              UUID        NOT NULL REFERENCES employee_job_relationship_set(id) ON DELETE CASCADE,
  relationship_code   TEXT        NOT NULL,
  manager_employee_id UUID        NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 1:1 per code per set
CREATE UNIQUE INDEX IF NOT EXISTS idx_ejri_one_code_per_set
  ON employee_job_relationship_item (set_id, relationship_code);

-- Reverse-lookup for deactivation fanout ("who has Alice as a matrix manager?")
CREATE INDEX IF NOT EXISTS idx_ejri_manager_lookup
  ON employee_job_relationship_item (manager_employee_id);


-- =============================================================================
-- 3. employees — 6 mirror columns
-- =============================================================================

ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS pm01_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pm02_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pm03_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS om01_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS om02_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS om03_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL;

-- Self-assignment guards (no-op if already exist — Postgres will error on duplicate names)
DO $$
BEGIN
  ALTER TABLE employees ADD CONSTRAINT chk_pm01_not_self
    CHECK (pm01_manager_id IS NULL OR pm01_manager_id <> id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  ALTER TABLE employees ADD CONSTRAINT chk_pm02_not_self
    CHECK (pm02_manager_id IS NULL OR pm02_manager_id <> id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  ALTER TABLE employees ADD CONSTRAINT chk_pm03_not_self
    CHECK (pm03_manager_id IS NULL OR pm03_manager_id <> id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  ALTER TABLE employees ADD CONSTRAINT chk_om01_not_self
    CHECK (om01_manager_id IS NULL OR om01_manager_id <> id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  ALTER TABLE employees ADD CONSTRAINT chk_om02_not_self
    CHECK (om02_manager_id IS NULL OR om02_manager_id <> id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  ALTER TABLE employees ADD CONSTRAINT chk_om03_not_self
    CHECK (om03_manager_id IS NULL OR om03_manager_id <> id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Partial indexes for the workflow hot-path (only a fraction of rows have these set)
CREATE INDEX IF NOT EXISTS idx_emp_pm01 ON employees(pm01_manager_id) WHERE pm01_manager_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_emp_pm02 ON employees(pm02_manager_id) WHERE pm02_manager_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_emp_pm03 ON employees(pm03_manager_id) WHERE pm03_manager_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_emp_om01 ON employees(om01_manager_id) WHERE om01_manager_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_emp_om02 ON employees(om02_manager_id) WHERE om02_manager_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_emp_om03 ON employees(om03_manager_id) WHERE om03_manager_id IS NOT NULL;


-- =============================================================================
-- 4. Guard trigger: block ad-hoc UPDATEs to job-relationship mirror columns
--    Only the RPC (which sets prowess.allow_job_relationships_sync=true) and
--    the deactivation trigger fanout may write these columns.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_guard_employee_job_relationships_sync()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Allow writes from the sync RPC and the deactivation fanout
  IF current_setting('prowess.allow_job_relationships_sync', true) = 'true' THEN
    RETURN NEW;
  END IF;

  -- Block any direct update to the mirror columns
  IF (
    NEW.pm01_manager_id IS DISTINCT FROM OLD.pm01_manager_id OR
    NEW.pm02_manager_id IS DISTINCT FROM OLD.pm02_manager_id OR
    NEW.pm03_manager_id IS DISTINCT FROM OLD.pm03_manager_id OR
    NEW.om01_manager_id IS DISTINCT FROM OLD.om01_manager_id OR
    NEW.om02_manager_id IS DISTINCT FROM OLD.om02_manager_id OR
    NEW.om03_manager_id IS DISTINCT FROM OLD.om03_manager_id
  ) THEN
    RAISE EXCEPTION
      'Direct update to job-relationship mirror columns is not permitted. '
      'Use upsert_job_relationship_set() instead.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_employee_job_relationships_sync ON employees;

CREATE TRIGGER trg_guard_employee_job_relationships_sync
  BEFORE UPDATE ON employees
  FOR EACH ROW
  EXECUTE FUNCTION fn_guard_employee_job_relationships_sync();

COMMENT ON FUNCTION fn_guard_employee_job_relationships_sync() IS
  'Blocks direct UPDATEs to pm01–om03_manager_id mirror columns on employees. '
  'Only upsert_job_relationship_set() and the deactivation fanout may write them '
  '(they set prowess.allow_job_relationships_sync=true for the transaction).';


-- =============================================================================
-- 5. Seed JOB_RELATIONSHIP_TYPE picklist
-- =============================================================================

INSERT INTO picklists (picklist_id, name, system, meta_fields)
VALUES (
  'JOB_RELATIONSHIP_TYPE',
  'Job Relationship Type',
  true,
  '[]'::jsonb
)
ON CONFLICT (picklist_id) DO NOTHING;

-- Seed the 6 fixed codes (idempotent via ON CONFLICT DO NOTHING on ref_id per picklist)
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT
  pl.id,
  v.label,
  v.ref_id,
  true
FROM (VALUES
  ('PM01', 'Project Manager'),
  ('PM02', 'Programme Manager'),
  ('PM03', 'Practice Manager'),
  ('OM01', 'Operations Manager'),
  ('OM02', 'Operations Lead'),
  ('OM03', 'Operations Coordinator')
) AS v(ref_id, label)
JOIN picklists pl ON pl.picklist_id = 'JOB_RELATIONSHIP_TYPE'
ON CONFLICT DO NOTHING;


-- =============================================================================
-- 6. Register job_relationships module
-- =============================================================================

INSERT INTO modules (code, name, active, sort_order)
VALUES (
  'job_relationships',
  'Job Relationships',
  true,
  (SELECT COALESCE(MAX(sort_order), 0) + 10 FROM modules)
)
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- 7. Expand permissions_action_check to allow bulk_import / bulk_export
--    (extends the constraint last modified by mig 217)
-- =============================================================================

ALTER TABLE permissions DROP CONSTRAINT IF EXISTS permissions_action_check;
ALTER TABLE permissions ADD CONSTRAINT permissions_action_check
  CHECK (action IN ('view', 'create', 'edit', 'delete', 'history', 'lookup',
                    'view_all_pending', 'edit_all_pending',
                    'bulk_import', 'bulk_export'));


-- =============================================================================
-- 8. Seed 5 permissions
-- =============================================================================

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'job_relationships';

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'job_relationships module not found — skipping permission seed';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    ('job_relationships.view',        v_module_id, 'view',        'Job Relationships — View',
     'See an employee''s current matrix manager assignments.'),
    ('job_relationships.create',      v_module_id, 'create',      'Job Relationships — Assign New',
     'Assign a manager to a previously unassigned relationship code.'),
    ('job_relationships.edit',        v_module_id, 'edit',        'Job Relationships — Edit',
     'Change an existing matrix manager assignment to a different person.'),
    ('job_relationships.delete',      v_module_id, 'delete',      'Job Relationships — Remove',
     'Clear (remove) an existing matrix manager assignment.'),
    ('job_relationships.history',     v_module_id, 'history',     'Job Relationships — History',
     'View the full timeline of past matrix manager assignments.'),
    ('job_relationships.bulk_import', v_module_id, 'bulk_import', 'Job Relationships — Bulk Import',
     'Upload CSV files to create/update matrix-manager assignments in bulk. Bypasses workflow.'),
    ('job_relationships.bulk_export', v_module_id, 'bulk_export', 'Job Relationships — Bulk Export',
     'Download current state and full timeline of matrix-manager assignments as CSV.')
  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- 9. RLS policies — employee_job_relationship_set
-- =============================================================================

ALTER TABLE employee_job_relationship_set ENABLE ROW LEVEL SECURITY;

-- SELECT: viewer, HR/admin, or hire-pipeline access
DROP POLICY IF EXISTS ejr_select ON employee_job_relationship_set;
CREATE POLICY ejr_select ON employee_job_relationship_set
  FOR SELECT USING (
    user_can('job_relationships', 'view', employee_id)
    OR (
      user_can('job_relationships', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = employee_job_relationship_set.employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  );

-- INSERT: edit permission
DROP POLICY IF EXISTS ejr_insert ON employee_job_relationship_set;
CREATE POLICY ejr_insert ON employee_job_relationship_set
  FOR INSERT WITH CHECK (
    user_can('job_relationships', 'edit', employee_id)
    OR user_can('job_relationships', 'edit', NULL)
  );

-- UPDATE: edit permission
DROP POLICY IF EXISTS ejr_update ON employee_job_relationship_set;
CREATE POLICY ejr_update ON employee_job_relationship_set
  FOR UPDATE USING (
    user_can('job_relationships', 'edit', employee_id)
    OR user_can('job_relationships', 'edit', NULL)
  );

-- DELETE: edit permission (deactivation fanout path)
DROP POLICY IF EXISTS ejr_delete ON employee_job_relationship_set;
CREATE POLICY ejr_delete ON employee_job_relationship_set
  FOR DELETE USING (
    user_can('job_relationships', 'edit', employee_id)
    OR user_can('job_relationships', 'edit', NULL)
  );


-- =============================================================================
-- 10. RLS policies — employee_job_relationship_item
-- =============================================================================

ALTER TABLE employee_job_relationship_item ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ejri_select ON employee_job_relationship_item;
CREATE POLICY ejri_select ON employee_job_relationship_item
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM employee_job_relationship_set s
      WHERE s.id = employee_job_relationship_item.set_id
        AND (
          user_can('job_relationships', 'view', s.employee_id)
          OR user_can('job_relationships', 'view', NULL)
        )
    )
  );

DROP POLICY IF EXISTS ejri_insert ON employee_job_relationship_item;
CREATE POLICY ejri_insert ON employee_job_relationship_item
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM employee_job_relationship_set s
      WHERE s.id = employee_job_relationship_item.set_id
        AND (
          user_can('job_relationships', 'edit', s.employee_id)
          OR user_can('job_relationships', 'edit', NULL)
        )
    )
  );

DROP POLICY IF EXISTS ejri_update ON employee_job_relationship_item;
CREATE POLICY ejri_update ON employee_job_relationship_item
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM employee_job_relationship_set s
      WHERE s.id = employee_job_relationship_item.set_id
        AND (
          user_can('job_relationships', 'edit', s.employee_id)
          OR user_can('job_relationships', 'edit', NULL)
        )
    )
  );

DROP POLICY IF EXISTS ejri_delete ON employee_job_relationship_item;
CREATE POLICY ejri_delete ON employee_job_relationship_item
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM employee_job_relationship_set s
      WHERE s.id = employee_job_relationship_item.set_id
        AND (
          user_can('job_relationships', 'edit', s.employee_id)
          OR user_can('job_relationships', 'edit', NULL)
        )
    )
  );


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT COUNT(*) AS jr_set_tables
FROM   pg_class c
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  n.nspname = 'public'
  AND  c.relname IN ('employee_job_relationship_set', 'employee_job_relationship_item');

SELECT COUNT(*) AS jr_mirror_cols
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'employees'
  AND  column_name  IN ('pm01_manager_id','pm02_manager_id','pm03_manager_id',
                        'om01_manager_id','om02_manager_id','om03_manager_id');

SELECT ref_id, value
FROM   picklist_values pv
JOIN   picklists pl ON pl.id = pv.picklist_id
WHERE  pl.picklist_id = 'JOB_RELATIONSHIP_TYPE'
ORDER  BY ref_id;

SELECT code FROM permissions
WHERE  code LIKE 'job_relationships.%'
ORDER  BY code;

-- =============================================================================
-- END OF MIGRATION 359
-- =============================================================================
