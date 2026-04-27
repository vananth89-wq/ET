-- =============================================================================
-- Employee Table Split
--
-- Move personal / contact / employment detail fields out of the employees
-- core table into three dedicated satellite tables.  This enables RLS at the
-- field-group level: HR/Admin can access everything, managers can access
-- employment details of their reports but not personal records, etc.
--
-- New tables (all 1-to-1 with employees, PK = employee_id):
--   employee_personal    → nationality, marital_status, photo_url
--   employee_contact     → country_code, mobile, personal_email
--   employee_employment  → probation_end_date
--
-- Core employees table retains:
--   id, employee_id, name, business_email, designation, job_title,
--   dept_id, manager_id, hire_date, end_date, work_country, work_location,
--   base_currency_id, status, deleted_at, created_at, updated_at
-- =============================================================================


-- ── 1. Create satellite tables ────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS employee_personal (
  employee_id    uuid        NOT NULL PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
  nationality    text,
  marital_status text,
  photo_url      text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE employee_personal IS 'Personal information split from employees core table. 1-to-1 with employees.';

CREATE TABLE IF NOT EXISTS employee_contact (
  employee_id    uuid        NOT NULL PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
  country_code   text,
  mobile         text,
  personal_email text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE employee_contact IS 'Phone and personal email split from employees core table. 1-to-1 with employees.';

CREATE TABLE IF NOT EXISTS employee_employment (
  employee_id       uuid NOT NULL PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
  probation_end_date date,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE employee_employment IS 'Employment detail split from employees core table. 1-to-1 with employees.';


-- ── 2. Migrate existing data ──────────────────────────────────────────────────
--
-- Guarded by a column-existence check so re-runs are safe after the DROP
-- COLUMN step has already executed on a previous (partial) run.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_name = 'employees' AND column_name = 'nationality'
  ) THEN
    INSERT INTO employee_personal (employee_id, nationality, marital_status, photo_url)
    SELECT id, nationality, marital_status, photo_url
    FROM   employees
    WHERE  nationality IS NOT NULL
       OR  marital_status IS NOT NULL
       OR  photo_url IS NOT NULL
    ON CONFLICT (employee_id) DO NOTHING;

    INSERT INTO employee_contact (employee_id, country_code, mobile, personal_email)
    SELECT id, country_code, mobile, personal_email
    FROM   employees
    WHERE  country_code IS NOT NULL
       OR  mobile IS NOT NULL
       OR  personal_email IS NOT NULL
    ON CONFLICT (employee_id) DO NOTHING;

    INSERT INTO employee_employment (employee_id, probation_end_date)
    SELECT id, probation_end_date
    FROM   employees
    WHERE  probation_end_date IS NOT NULL
    ON CONFLICT (employee_id) DO NOTHING;

    RAISE NOTICE 'Data migrated from employees to satellite tables.';
  ELSE
    RAISE NOTICE 'Columns already dropped from employees — skipping data migration.';
  END IF;
END $$;


-- ── 3. Drop moved columns from employees core table ───────────────────────────

ALTER TABLE employees
  DROP COLUMN IF EXISTS nationality,
  DROP COLUMN IF EXISTS marital_status,
  DROP COLUMN IF EXISTS photo_url,
  DROP COLUMN IF EXISTS country_code,
  DROP COLUMN IF EXISTS mobile,
  DROP COLUMN IF EXISTS personal_email,
  DROP COLUMN IF EXISTS probation_end_date;


-- ── 4. Enable RLS on new tables ───────────────────────────────────────────────

ALTER TABLE employee_personal   ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_contact    ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_employment ENABLE ROW LEVEL SECURITY;


-- ── 5. RLS policies ───────────────────────────────────────────────────────────
--
-- Pattern for every satellite table:
--   SELECT  → own row + view_own_<portlet>  OR  admin/HR with employee.edit
--   INSERT  → own row + edit_own_<portlet>  OR  employee.edit  (admin creates rows)
--   UPDATE  → own row + edit_own_<portlet>  OR  employee.edit
--   DELETE  → employee.edit (soft-delete only — row removed when employee is)
--
-- "own row" is resolved via profiles.employee_id = employee_id.
-- DROP IF EXISTS guards make this block safe to re-run.

DROP POLICY IF EXISTS ep_select  ON employee_personal;
DROP POLICY IF EXISTS ep_insert  ON employee_personal;
DROP POLICY IF EXISTS ep_update  ON employee_personal;
DROP POLICY IF EXISTS ep_delete  ON employee_personal;
DROP POLICY IF EXISTS ec_select  ON employee_contact;
DROP POLICY IF EXISTS ec_insert  ON employee_contact;
DROP POLICY IF EXISTS ec_update  ON employee_contact;
DROP POLICY IF EXISTS ec_delete  ON employee_contact;
DROP POLICY IF EXISTS eem_select ON employee_employment;
DROP POLICY IF EXISTS eem_insert ON employee_employment;
DROP POLICY IF EXISTS eem_update ON employee_employment;
DROP POLICY IF EXISTS eem_delete ON employee_employment;

-- ── employee_personal ─────────────────────────────────────────────────────────

CREATE POLICY ep_select ON employee_personal FOR SELECT
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_personal')
    )
  );

CREATE POLICY ep_insert ON employee_personal FOR INSERT
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_personal')
    )
  );

CREATE POLICY ep_update ON employee_personal FOR UPDATE
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_personal')
    )
  )
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_personal')
    )
  );

CREATE POLICY ep_delete ON employee_personal FOR DELETE
  USING (has_permission('employee.edit'));


-- ── employee_contact ──────────────────────────────────────────────────────────

CREATE POLICY ec_select ON employee_contact FOR SELECT
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_contact')
    )
  );

CREATE POLICY ec_insert ON employee_contact FOR INSERT
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_contact')
    )
  );

CREATE POLICY ec_update ON employee_contact FOR UPDATE
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_contact')
    )
  )
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_contact')
    )
  );

CREATE POLICY ec_delete ON employee_contact FOR DELETE
  USING (has_permission('employee.edit'));


-- ── employee_employment ───────────────────────────────────────────────────────

CREATE POLICY eem_select ON employee_employment FOR SELECT
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_employment')
    )
  );

CREATE POLICY eem_insert ON employee_employment FOR INSERT
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_employment')
    )
  );

CREATE POLICY eem_update ON employee_employment FOR UPDATE
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_employment')
    )
  )
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_employment')
    )
  );

CREATE POLICY eem_delete ON employee_employment FOR DELETE
  USING (has_permission('employee.edit'));


-- ── 6. updated_at triggers ────────────────────────────────────────────────────
--
-- Uses touch_updated_at() defined in 20260422003_role_arch_phase0_schema.sql.
-- (moddatetime extension is not required.)

DROP TRIGGER IF EXISTS employee_personal_updated_at   ON employee_personal;
DROP TRIGGER IF EXISTS employee_contact_updated_at    ON employee_contact;
DROP TRIGGER IF EXISTS employee_employment_updated_at ON employee_employment;

CREATE TRIGGER employee_personal_updated_at
  BEFORE UPDATE ON employee_personal
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER employee_contact_updated_at
  BEFORE UPDATE ON employee_contact
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER employee_employment_updated_at
  BEFORE UPDATE ON employee_employment
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- ── 7. Verification ───────────────────────────────────────────────────────────

-- Confirm new tables populated correctly
SELECT
  e.employee_id,
  e.name,
  ep.nationality,
  ep.marital_status,
  ec.mobile,
  ec.personal_email,
  eem.probation_end_date
FROM       employees        e
LEFT JOIN  employee_personal   ep  ON ep.employee_id  = e.id
LEFT JOIN  employee_contact    ec  ON ec.employee_id  = e.id
LEFT JOIN  employee_employment eem ON eem.employee_id = e.id
WHERE  e.deleted_at IS NULL
ORDER  BY e.name
LIMIT  20;

-- Confirm dropped columns are gone
SELECT column_name
FROM   information_schema.columns
WHERE  table_name = 'employees'
ORDER  BY ordinal_position;
