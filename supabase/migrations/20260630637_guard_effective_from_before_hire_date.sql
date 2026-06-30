-- =============================================================================
-- Migration 635: prevent effective_from before hire_date on employment and
-- personal satellite tables
--
-- A CHECK constraint cannot reference another table, so we use BEFORE INSERT/UPDATE
-- triggers on employee_employment and employee_personal that compare
-- NEW.effective_from against employees.hire_date for the same employee.
--
-- Both triggers raise an exception (rolling back the statement) if
-- NEW.effective_from < hire_date.
-- =============================================================================

-- ── 1. Guard function ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_guard_effective_from_before_hire()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_hire_date date;
BEGIN
  SELECT hire_date INTO v_hire_date
  FROM   employees
  WHERE  id = NEW.employee_id;

  IF v_hire_date IS NOT NULL AND NEW.effective_from < v_hire_date THEN
    RAISE EXCEPTION
      'effective_from (%) cannot be before the employee hire date (%) for employee %',
      NEW.effective_from, v_hire_date, NEW.employee_id
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

-- ── 2. Trigger on employee_employment ────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_guard_employment_effective_from ON employee_employment;

CREATE TRIGGER trg_guard_employment_effective_from
  BEFORE INSERT OR UPDATE OF effective_from
  ON employee_employment
  FOR EACH ROW
  EXECUTE FUNCTION fn_guard_effective_from_before_hire();

-- ── 3. Trigger on employee_personal ──────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_guard_personal_effective_from ON employee_personal;

CREATE TRIGGER trg_guard_personal_effective_from
  BEFORE INSERT OR UPDATE OF effective_from
  ON employee_personal
  FOR EACH ROW
  EXECUTE FUNCTION fn_guard_effective_from_before_hire();

COMMENT ON FUNCTION fn_guard_effective_from_before_hire() IS
  'Mig 635: raises check_violation if effective_from < employees.hire_date. '
  'Applied to employee_employment and employee_personal via BEFORE INSERT/UPDATE triggers.';
