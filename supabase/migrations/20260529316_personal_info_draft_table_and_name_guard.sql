-- =============================================================================
-- Migration 306 — employee_personal_draft + employees name guard trigger
-- =============================================================================
--
-- BACKGROUND
-- ──────────
-- Now that employee_personal is the source of truth for employees.name,
-- two things are needed:
--
--   1. A staging table (employee_personal_draft) to hold personal info collected
--      during the hire pipeline (Draft / Incomplete / Pending). The timeline in
--      employee_personal begins only at activation — provisional hire data must
--      live somewhere else. On activation, the draft row seeds the first
--      employee_personal slice and is then deleted.
--
--   2. A BEFORE UPDATE trigger on employees that blocks direct writes to
--      first_name / last_name for Active employees, preventing drift between
--      the denormalized cache and employee_personal source of truth.
--      The trigger allows writes only when:
--        a) employee status is not 'Active' (hire pipeline)  — OR —
--        b) the session flag prowess.allow_name_sync = 'true' is set
--           (set by upsert_personal_info and activate_personal_info_records)
--
-- BOUNDARY
-- ────────
-- Before activation: employees table owns the name (hire pipeline writes here).
-- After activation:  employee_personal owns the name (trigger is armed).
--                    All post-activation name changes go through upsert_personal_info().
-- =============================================================================


-- =============================================================================
-- 1. employee_personal_draft — staging table for hire pipeline
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_personal_draft (
  employee_id     uuid        PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
  name            text,        -- mirrors employees.name; seeds employee_personal on activation
  middle_name     text,        -- net-new
  preferred_name  text,        -- net-new
  nationality     text,
  marital_status  text,
  gender          text,
  dob             date,
  photo_url       text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid        REFERENCES profiles(id) ON DELETE SET NULL
);

CREATE TRIGGER employee_personal_draft_updated_at
  BEFORE UPDATE ON employee_personal_draft
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE employee_personal_draft IS
  'Staging table for personal information collected during the hire pipeline '
  '(employee status = Draft / Incomplete / Pending). '
  'On activation (Pending → Active), the activation function reads this row '
  'to seed the first employee_personal effective-dated slice, then deletes it. '
  'No RLS needed beyond what the hire pipeline checks — HR writes via SECURITY DEFINER RPCs. '
  'Mig 306: initial creation.';

-- RLS: HR roles only (anyone with hire_employee.edit can write during pipeline)
ALTER TABLE employee_personal_draft ENABLE ROW LEVEL SECURITY;

CREATE POLICY "epd_select" ON employee_personal_draft
  FOR SELECT USING (
    user_can('personal_info', 'view', employee_id)
    OR (
      user_can('personal_info',  'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
    )
  );

CREATE POLICY "epd_insert" ON employee_personal_draft
  FOR INSERT WITH CHECK (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
    )
  );

CREATE POLICY "epd_update" ON employee_personal_draft
  FOR UPDATE
  USING (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
    )
  )
  WITH CHECK (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
    )
  );

CREATE POLICY "epd_delete" ON employee_personal_draft
  FOR DELETE USING (
    user_can('hire_employee', 'edit', NULL)
  );


-- =============================================================================
-- 2. employees name guard trigger
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_guard_employee_name_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only intercept rows where name is actually changing
  IF NEW.name IS NOT DISTINCT FROM OLD.name THEN
    RETURN NEW;  -- No name change — pass through unconditionally
  END IF;

  -- Only enforce the guard for Active employees.
  -- During the hire pipeline (Draft / Incomplete / Pending / Rejected / Inactive)
  -- direct writes to employees.name are permitted because employee_personal
  -- has no timeline row yet (or is deactivated).
  IF OLD.status != 'Active' THEN
    RETURN NEW;
  END IF;

  -- Allow if the sync system has set the session-level flag.
  -- upsert_personal_info() and activate_personal_info_records() set this flag
  -- via SET LOCAL before updating employees — it auto-resets at transaction end.
  IF current_setting('prowess.allow_name_sync', true) = 'true' THEN
    RETURN NEW;
  END IF;

  -- Block: Active employee, name is changing, no sync flag — reject
  RAISE EXCEPTION
    'Direct name updates on Active employees are blocked. '
    'employee_personal is the source of truth for employees.name. '
    'Use upsert_personal_info() to change an employee''s name — '
    'it manages the effective-dated timeline and syncs employees automatically. '
    'Employee id: %', OLD.id
    USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION fn_guard_employee_name_sync() IS
  'BEFORE UPDATE trigger on employees. Blocks direct writes to name '
  'for Active employees to prevent drift from employee_personal source of truth. '
  'Allows writes when: (a) employee is not Active (hire pipeline / inactive), or '
  '(b) session variable prowess.allow_name_sync = ''true'' is set by the sync system. '
  'Mig 306: initial creation.';

DROP TRIGGER IF EXISTS trg_guard_employee_name_sync ON employees;

CREATE TRIGGER trg_guard_employee_name_sync
  BEFORE UPDATE ON employees
  FOR EACH ROW
  EXECUTE FUNCTION fn_guard_employee_name_sync();
