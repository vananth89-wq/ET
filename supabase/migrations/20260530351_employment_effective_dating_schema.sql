-- =============================================================================
-- Migration 351 — Convert employee_employment to effective-dated timeline
-- =============================================================================
--
-- BACKGROUND
-- ──────────
-- employee_employment is currently a 1:1 flat satellite keyed by employee_id
-- (PK), holding only probation_end_date. All 10 employment fields live on
-- employees master and are destructively overwritten on every change.
--
-- CHANGE
-- ──────
-- Expand employee_employment in place to be a multi-row effective-dated
-- timeline following the same bi-temporal pattern as employee_personal
-- (mig 315), employee_dependents (mig 289), and employee_bank_accounts
-- (mig 273):
--
--   • New UUID surrogate PK (id) — employee_id becomes a plain FK
--   • 10 domain fields: designation, job_title, dept_id, manager_id,
--     hire_date, end_date, work_country, work_location, base_currency_id,
--     status
--   • effective_from / effective_to (sentinel '9999-12-31' = open-ended)
--   • is_active flag
--   • Audit columns: created_by, updated_by, inactive_at, inactive_by
--   • Partial UNIQUE index: one open-ended active row per employee
--
-- MIRROR CACHE POLICY
-- ───────────────────
-- All 10 fields remain on employees as a denormalized mirror cache for
-- backward compat (RLS policies, target_groups, org chart etc. read
-- employees.* directly). Source of truth is the satellite. Mirror is updated
-- by upsert_employment_info() and the nightly sync job. A guard trigger
-- blocks ad-hoc direct writes to the 10 mirror columns on employees for
-- Active employees.
--
-- NO BACKFILL HERE
-- ────────────────
-- Data seeding happens in mig 355 (Phase 5). This migration is schema-only.
--
-- REFERENCES
-- ──────────
-- Design spec: docs/employment-effective-dating-design.md
-- Template:    mig 315 (employee_personal)
-- =============================================================================


-- =============================================================================
-- 1. Add new columns to employee_employment
-- =============================================================================

ALTER TABLE employee_employment
  -- Surrogate PK (will become PK after step 4)
  ADD COLUMN IF NOT EXISTS id               uuid        NOT NULL DEFAULT gen_random_uuid(),

  -- 10 effective-dated domain fields
  ADD COLUMN IF NOT EXISTS designation      text,
  ADD COLUMN IF NOT EXISTS job_title        text,
  ADD COLUMN IF NOT EXISTS dept_id          uuid        REFERENCES departments(id)  ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS manager_id       uuid        REFERENCES employees(id)    ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS hire_date        date,
  ADD COLUMN IF NOT EXISTS end_date         date,
  ADD COLUMN IF NOT EXISTS work_country     text,
  ADD COLUMN IF NOT EXISTS work_location    text,
  ADD COLUMN IF NOT EXISTS base_currency_id uuid        REFERENCES currencies(id)   ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS status           employee_status,

  -- Effective-dating
  ADD COLUMN IF NOT EXISTS effective_from   date,
  ADD COLUMN IF NOT EXISTS effective_to     date        NOT NULL DEFAULT '9999-12-31',
  ADD COLUMN IF NOT EXISTS is_active        boolean     NOT NULL DEFAULT true,

  -- Audit
  ADD COLUMN IF NOT EXISTS created_by       uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_by       uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS inactive_at      timestamptz,
  ADD COLUMN IF NOT EXISTS inactive_by      uuid        REFERENCES profiles(id) ON DELETE SET NULL;


-- =============================================================================
-- 2. Seed effective_from for existing rows (safety before NOT NULL)
-- =============================================================================
-- Backfill is done in mig 355; here we just ensure no NULLs block the
-- NOT NULL constraint for the existing probation_end_date rows.

UPDATE employee_employment ee
SET    effective_from = COALESCE(
         e.hire_date,
         ee.created_at::date,
         '2000-01-01'::date
       )
FROM   employees e
WHERE  e.id = ee.employee_id
  AND  ee.effective_from IS NULL;

UPDATE employee_employment
SET    effective_from = '2000-01-01'::date
WHERE  effective_from IS NULL;


-- =============================================================================
-- 3. Enforce NOT NULL on effective_from
-- =============================================================================

ALTER TABLE employee_employment
  ALTER COLUMN effective_from SET NOT NULL;


-- =============================================================================
-- 4. Swap primary key: employee_id → id
-- =============================================================================

ALTER TABLE employee_employment
  DROP CONSTRAINT IF EXISTS employee_employment_pkey;

ALTER TABLE employee_employment
  ADD PRIMARY KEY (id);


-- =============================================================================
-- 5. Indexes  (prefix: idx_ee_*)
-- =============================================================================

-- One open-ended active row per employee
CREATE UNIQUE INDEX IF NOT EXISTS idx_ee_one_active_row
  ON employee_employment (employee_id)
  WHERE effective_to = '9999-12-31'::date
    AND is_active    = true;

-- General FK lookup
CREATE INDEX IF NOT EXISTS idx_ee_employee_id
  ON employee_employment (employee_id);

-- Timeline range queries
CREATE INDEX IF NOT EXISTS idx_ee_employee_timeline
  ON employee_employment (employee_id, effective_from, effective_to);

-- Current-row filter
CREATE INDEX IF NOT EXISTS idx_ee_is_active
  ON employee_employment (employee_id, is_active)
  WHERE effective_to = '9999-12-31'::date;

-- "Who reports to X today" queries without touching employees.manager_id
CREATE INDEX IF NOT EXISTS idx_ee_manager_active
  ON employee_employment (manager_id)
  WHERE effective_to = '9999-12-31'::date
    AND is_active    = true;


-- =============================================================================
-- 6. CHECK constraint on date order
-- =============================================================================

ALTER TABLE employee_employment
  DROP CONSTRAINT IF EXISTS chk_ee_effective_order;

ALTER TABLE employee_employment
  ADD CONSTRAINT chk_ee_effective_order
  CHECK (effective_to >= effective_from);


-- =============================================================================
-- 7. Recreate RLS policies — dual-path pattern
--    (mirrors mig 220 shape + module: employment)
-- =============================================================================

DROP POLICY IF EXISTS eem_select ON employee_employment;
DROP POLICY IF EXISTS eem_insert ON employee_employment;
DROP POLICY IF EXISTS eem_update ON employee_employment;
DROP POLICY IF EXISTS eem_delete ON employee_employment;

-- SELECT
CREATE POLICY eem_select ON employee_employment
  FOR SELECT USING (
    -- Path A: active employee — target-group scoped
    user_can('employment', 'view', employee_id)
    -- Path B: hire pipeline — new hire not yet in target_group_members cache
    OR (
      user_can('employment',    'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

-- INSERT
CREATE POLICY eem_insert ON employee_employment
  FOR INSERT WITH CHECK (
    user_can('employment', 'edit', employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

-- UPDATE
CREATE POLICY eem_update ON employee_employment
  FOR UPDATE
  USING (
    user_can('employment', 'edit', employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('employment', 'edit', employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

-- DELETE — hard delete restricted to edit; hire-pipeline allowed during Draft/Incomplete/Pending
CREATE POLICY eem_delete ON employee_employment
  FOR DELETE USING (
    user_can('employment', 'edit', employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


-- =============================================================================
-- 8. Guard trigger on employees — block ad-hoc writes to the 10 mirror columns
-- =============================================================================
--
-- Allows writes only when:
--   a) prowess.allow_employment_sync session variable = 'true'  (set by RPC/sync job), OR
--   b) The employee is still in onboarding status (Draft/Incomplete/Pending)
--      so the hire wizard can continue direct-writing mid-flow.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_guard_employee_employment_sync()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_bypass boolean;
  v_col    text;
  v_changed_mirror_cols text[] := ARRAY[]::text[];
BEGIN
  -- Check bypass flag (set inside upsert_employment_info / sync job)
  v_bypass := current_setting('prowess.allow_employment_sync', true) = 'true';

  IF v_bypass THEN
    RETURN NEW;
  END IF;

  -- Hire pipeline bypass: allow direct writes while employee is in onboarding statuses
  IF OLD.status IN ('Draft', 'Incomplete', 'Pending') THEN
    RETURN NEW;
  END IF;

  -- For Active (and Inactive) employees, detect which mirror columns changed
  IF NEW.designation      IS DISTINCT FROM OLD.designation      THEN v_changed_mirror_cols := v_changed_mirror_cols || 'designation';      END IF;
  IF NEW.job_title        IS DISTINCT FROM OLD.job_title        THEN v_changed_mirror_cols := v_changed_mirror_cols || 'job_title';        END IF;
  IF NEW.dept_id          IS DISTINCT FROM OLD.dept_id          THEN v_changed_mirror_cols := v_changed_mirror_cols || 'dept_id';          END IF;
  IF NEW.manager_id       IS DISTINCT FROM OLD.manager_id       THEN v_changed_mirror_cols := v_changed_mirror_cols || 'manager_id';       END IF;
  IF NEW.hire_date        IS DISTINCT FROM OLD.hire_date        THEN v_changed_mirror_cols := v_changed_mirror_cols || 'hire_date';        END IF;
  IF NEW.end_date         IS DISTINCT FROM OLD.end_date         THEN v_changed_mirror_cols := v_changed_mirror_cols || 'end_date';         END IF;
  IF NEW.work_country     IS DISTINCT FROM OLD.work_country     THEN v_changed_mirror_cols := v_changed_mirror_cols || 'work_country';     END IF;
  IF NEW.work_location    IS DISTINCT FROM OLD.work_location    THEN v_changed_mirror_cols := v_changed_mirror_cols || 'work_location';    END IF;
  IF NEW.base_currency_id IS DISTINCT FROM OLD.base_currency_id THEN v_changed_mirror_cols := v_changed_mirror_cols || 'base_currency_id'; END IF;
  IF NEW.status           IS DISTINCT FROM OLD.status           THEN v_changed_mirror_cols := v_changed_mirror_cols || 'status';           END IF;

  IF array_length(v_changed_mirror_cols, 1) > 0 THEN
    RAISE EXCEPTION
      'Direct UPDATE of employment mirror columns [%] on employee % is not allowed for Active/Inactive employees. '
      'Use upsert_employment_info() or set prowess.allow_employment_sync = true.',
      array_to_string(v_changed_mirror_cols, ', '),
      OLD.id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_employee_employment_sync ON employees;

CREATE TRIGGER trg_guard_employee_employment_sync
  BEFORE UPDATE ON employees
  FOR EACH ROW
  EXECUTE FUNCTION fn_guard_employee_employment_sync();


-- =============================================================================
-- 9. Seed employment.history permission
-- =============================================================================

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id
  FROM   modules
  WHERE  code = 'employment';

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'employment module not found — skipping history permission seed';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES (
    'employment.history',
    v_module_id,
    'history',
    'Employment — History',
    'View the full effective-dated change history for an employee''s employment information.'
  )
  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- 10. Drift view — surfaces mirror/satellite divergence for ops reconciliation
-- =============================================================================

CREATE OR REPLACE VIEW vw_employment_drift AS
SELECT
  e.id            AS employee_id,
  e.employee_id   AS employee_code,
  e.name,
  e.status        AS mirror_status,
  ee.status       AS sat_status,
  e.designation   AS mirror_designation,
  ee.designation  AS sat_designation,
  e.job_title     AS mirror_job_title,
  ee.job_title    AS sat_job_title,
  e.dept_id       AS mirror_dept_id,
  ee.dept_id      AS sat_dept_id,
  e.manager_id    AS mirror_manager_id,
  ee.manager_id   AS sat_manager_id,
  e.hire_date     AS mirror_hire_date,
  ee.hire_date    AS sat_hire_date,
  e.end_date      AS mirror_end_date,
  ee.end_date     AS sat_end_date,
  e.work_country  AS mirror_work_country,
  ee.work_country AS sat_work_country,
  e.work_location AS mirror_work_location,
  ee.work_location AS sat_work_location,
  e.base_currency_id AS mirror_base_currency_id,
  ee.base_currency_id AS sat_base_currency_id
FROM employees e
JOIN employee_employment ee
  ON  ee.employee_id = e.id
  AND ee.effective_to = '9999-12-31'::date
  AND ee.is_active    = true
WHERE
  e.status          IS DISTINCT FROM ee.status
  OR e.designation  IS DISTINCT FROM ee.designation
  OR e.job_title    IS DISTINCT FROM ee.job_title
  OR e.dept_id      IS DISTINCT FROM ee.dept_id
  OR e.manager_id   IS DISTINCT FROM ee.manager_id
  OR e.hire_date    IS DISTINCT FROM ee.hire_date
  OR e.end_date     IS DISTINCT FROM ee.end_date
  OR e.work_country IS DISTINCT FROM ee.work_country
  OR e.work_location IS DISTINCT FROM ee.work_location
  OR e.base_currency_id IS DISTINCT FROM ee.base_currency_id;


-- =============================================================================
-- 11. Comments
-- =============================================================================

COMMENT ON TABLE employee_employment IS
  'Effective-dated employment information for employees. '
  'One open-ended active row per employee (effective_to = ''9999-12-31'', is_active = true). '
  'Historical rows preserved when amended. '
  'Mirror cache of all 10 domain fields kept on employees for backward compat. '
  'Source of truth is this satellite; employees.* mirror is managed by '
  'upsert_employment_info() and the nightly activate_effective_dated_records() job. '
  'Mig 351: expanded from 1:1 flat table.';

COMMENT ON COLUMN employee_employment.id IS
  'Surrogate UUID primary key. Replaces the old employee_id PK from mig 020.';

COMMENT ON COLUMN employee_employment.effective_from IS
  'Date from which this version of employment data became true.';

COMMENT ON COLUMN employee_employment.effective_to IS
  'Open-ended sentinel: ''9999-12-31'' = currently active row. '
  'Set to effective_from_of_next_row - 1 when a new slice is inserted.';

COMMENT ON COLUMN employee_employment.is_active IS
  'false + effective_to = ''9999-12-31'' = terminal removal (soft-deleted). '
  'false + effective_to < ''9999-12-31'' = closed historical row.';

COMMENT ON COLUMN employee_employment.status IS
  'Employment lifecycle status (mirrors employees.status). '
  'Same-day transitions (Draft → Pending → Active) update this in place. '
  'Different-day transitions (Active → Inactive on end_date) create a new slice.';

COMMENT ON COLUMN employee_employment.base_currency_id IS
  'Auto-derived from work_country by upsert_employment_info(). '
  'Never accepted as a user input — always computed server-side.';

COMMENT ON COLUMN employee_employment.job_title IS
  'Free-form display title. Auto-populated from DESIGNATION picklist label when blank. '
  'User may override. 30+ frontend paths read employees.job_title — kept for compat.';
