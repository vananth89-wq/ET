-- =============================================================================
-- Migration 305 — Convert employee_personal to effective-dated
-- =============================================================================
--
-- BACKGROUND
-- ──────────
-- employee_personal is currently a 1:1 flat satellite table keyed by employee_id
-- (the PK). Direct upserts overwrite history — no timeline, no future-dating,
-- no point-in-time reporting.
--
-- CHANGE
-- ──────
-- Convert to a multi-row effective-dated table following the same bi-temporal
-- pattern used by employee_bank_accounts (mig 273) and employee_dependents
-- (mig 289):
--
--   • New UUID PK (id) — employee_id becomes a plain FK
--   • effective_from / effective_to = '9999-12-31' open-ended sentinel
--   • is_active flag (false + effective_to = '9999-12-31' = removed row)
--   • Audit columns: created_by, updated_by, inactive_at, inactive_by
--   • Name field added: name (synced from/to employees.name),
--     middle_name, preferred_name (net-new, not on employees)
--   • Partial UNIQUE index enforces one open-ended row per employee
--
-- EXISTING ROWS
-- ─────────────
-- Each existing row is migrated:
--   name            ← copied from employees.name
--   effective_from          ← COALESCE(hire_date, created_at::date, '2000-01-01')
--   effective_to            ← '9999-12-31' (already open-ended)
--   is_active               ← true
--
-- RLS
-- ───
-- Dual-path pattern from mig 220 / mig 296 — unchanged module: personal_info.
-- history action seeded for audit trail access.
--
-- AUDIT TRIGGER
-- ─────────────
-- trg_write_audit_log() already reads (v_row->>'id')::uuid for record_id.
-- Adding the id column makes it work correctly — no trigger changes needed.
-- =============================================================================


-- =============================================================================
-- 1. Add new columns
-- =============================================================================

ALTER TABLE employee_personal
  ADD COLUMN IF NOT EXISTS id             uuid        NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS name           text,        -- synced from/to employees.name
  ADD COLUMN IF NOT EXISTS middle_name    text,        -- net-new, not on employees
  ADD COLUMN IF NOT EXISTS preferred_name text,        -- net-new, not on employees
  ADD COLUMN IF NOT EXISTS effective_from date,
  ADD COLUMN IF NOT EXISTS effective_to   date        NOT NULL DEFAULT '9999-12-31',
  ADD COLUMN IF NOT EXISTS is_active      boolean     NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS created_by     uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by     uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS inactive_at    timestamptz,
  ADD COLUMN IF NOT EXISTS inactive_by    uuid        REFERENCES profiles(id) ON DELETE SET NULL;


-- =============================================================================
-- 2. Backfill existing rows
-- =============================================================================

-- Copy name from employees; derive effective_from
UPDATE employee_personal ep
SET
  name           = e.name,
  effective_from = COALESCE(
    e.hire_date,
    ep.created_at::date,
    '2000-01-01'::date
  )
FROM employees e
WHERE e.id = ep.employee_id;

-- Safety: if any row still has NULL effective_from (orphaned employee), use sentinel
UPDATE employee_personal
SET    effective_from = '2000-01-01'::date
WHERE  effective_from IS NULL;


-- =============================================================================
-- 3. Enforce NOT NULL on effective_from after backfill
-- =============================================================================

ALTER TABLE employee_personal
  ALTER COLUMN effective_from SET NOT NULL;


-- =============================================================================
-- 4. Swap primary key: employee_id → id
-- =============================================================================

-- Drop the existing employee_id primary key constraint
ALTER TABLE employee_personal
  DROP CONSTRAINT IF EXISTS employee_personal_pkey;

-- Promote id to PK
ALTER TABLE employee_personal
  ADD PRIMARY KEY (id);


-- =============================================================================
-- 5. Indexes
-- =============================================================================

-- Partial UNIQUE: at most one open-ended active row per employee
CREATE UNIQUE INDEX IF NOT EXISTS idx_ep_one_active_row
  ON employee_personal (employee_id)
  WHERE effective_to = '9999-12-31'::date
    AND is_active    = true;

-- General lookup
CREATE INDEX IF NOT EXISTS idx_ep_employee_id
  ON employee_personal (employee_id);

-- Timeline range queries
CREATE INDEX IF NOT EXISTS idx_ep_employee_timeline
  ON employee_personal (employee_id, effective_from, effective_to);

-- is_active filter (current-row queries)
CREATE INDEX IF NOT EXISTS idx_ep_is_active
  ON employee_personal (employee_id, is_active)
  WHERE effective_to = '9999-12-31'::date;


-- =============================================================================
-- 6. Add effective_to CHECK constraint
-- =============================================================================

ALTER TABLE employee_personal
  DROP CONSTRAINT IF EXISTS chk_ep_effective_order;

ALTER TABLE employee_personal
  ADD CONSTRAINT chk_ep_effective_order
  CHECK (effective_to >= effective_from);


-- =============================================================================
-- 7. Recreate RLS policies — dual-path pattern (mig 220 / mig 296)
-- =============================================================================

DROP POLICY IF EXISTS ep_select ON employee_personal;
DROP POLICY IF EXISTS ep_insert ON employee_personal;
DROP POLICY IF EXISTS ep_update ON employee_personal;
DROP POLICY IF EXISTS ep_delete ON employee_personal;

-- Legacy policy names from mig 095 / 109 (belt-and-suspenders drop)
DROP POLICY IF EXISTS "personal_info_select" ON employee_personal;
DROP POLICY IF EXISTS "personal_info_insert" ON employee_personal;
DROP POLICY IF EXISTS "personal_info_update" ON employee_personal;
DROP POLICY IF EXISTS "personal_info_delete" ON employee_personal;

-- SELECT
CREATE POLICY ep_select ON employee_personal
  FOR SELECT USING (
    -- Path A: active employee — target-group scoped (handles ESS self via Path C)
    user_can('personal_info', 'view', employee_id)
    -- Path B: hire pipeline — new hire not yet in target_group_members cache
    OR (
      user_can('personal_info',  'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

-- INSERT
CREATE POLICY ep_insert ON employee_personal
  FOR INSERT WITH CHECK (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

-- UPDATE
CREATE POLICY ep_update ON employee_personal
  FOR UPDATE
  USING (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

-- DELETE — soft-delete preferred; hard delete restricted to edit permission
CREATE POLICY ep_delete ON employee_personal
  FOR DELETE USING (
    user_can('personal_info', 'edit', employee_id)
  );


-- =============================================================================
-- 8. Seed personal_info.history permission
-- =============================================================================

-- personal_info module already exists (seeded in earlier migrations).
-- Add 'history' action if not already present.
DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id
  FROM   modules
  WHERE  code = 'personal_info';

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'personal_info module not found — skipping history permission seed';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES (
    'personal_info.history',
    v_module_id,
    'history',
    'Personal Info — History',
    'View the full effective-dated change history for an employee''s personal information.'
  )
  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- 9. Comments
-- =============================================================================

COMMENT ON TABLE employee_personal IS
  'Effective-dated personal information for employees. '
  'One open-ended active row per employee (effective_to = ''9999-12-31'', is_active = true). '
  'Historical rows preserved when amended. '
  'Follows the same bi-temporal pattern as employee_bank_accounts (mig 273) '
  'and employee_dependents (mig 289). '
  'Mig 305: converted from 1:1 flat table.';

COMMENT ON COLUMN employee_personal.id IS
  'Surrogate UUID primary key. Replaces the old employee_id PK from mig 020.';

COMMENT ON COLUMN employee_personal.effective_from IS
  'Date from which this version of personal information became true.';

COMMENT ON COLUMN employee_personal.effective_to IS
  'Open-ended sentinel: ''9999-12-31'' = currently active row. '
  'Set to effective_from_of_next_row - 1 when a new slice is inserted.';

COMMENT ON COLUMN employee_personal.is_active IS
  'false + effective_to = ''9999-12-31'' = terminal removal record (soft-deleted). '
  'false + effective_to < ''9999-12-31'' = closed historical row.';

COMMENT ON COLUMN employee_personal.name IS
  'Full display name. Kept in sync with employees.name via upsert_personal_info(). '
  'employees.name is the denormalized cache for system-wide JOINs (workflow, notifications, audit).';

COMMENT ON COLUMN employee_personal.middle_name IS
  'Middle name — net-new field (not on employees table).';

COMMENT ON COLUMN employee_personal.preferred_name IS
  'Preferred/display name — net-new field (not on employees table).';
