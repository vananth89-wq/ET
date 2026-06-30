-- =============================================================================
-- Migration 636: fix hire-date guard to use employee_employment.hire_date
--
-- BUG IN MIG 635
-- ──────────────
-- fn_guard_effective_from_before_hire() queries employees.hire_date.
-- But the UI-displayed hire date comes from employee_employment.hire_date
-- (the satellite table). employees.hire_date may be NULL or out of sync,
-- so the trigger did not fire for Mohan Raj.
--
-- FIX
-- ───
-- Rewrite fn_guard_effective_from_before_hire to use the minimum hire_date
-- from employee_employment (most recent active slice) as the authoritative
-- value, falling back to employees.hire_date if employment has no record.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_guard_effective_from_before_hire()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_hire_date date;
BEGIN
  -- Prefer employee_employment.hire_date (the source of truth shown in the UI).
  -- Fall back to employees.hire_date if no employment slice exists yet
  -- (e.g., during the hire pipeline before the first employment row is created).
  SELECT COALESCE(
    (SELECT MIN(hire_date)
     FROM   employee_employment
     WHERE  employee_id = NEW.employee_id
       AND  hire_date IS NOT NULL),
    (SELECT hire_date FROM employees WHERE id = NEW.employee_id)
  ) INTO v_hire_date;

  IF v_hire_date IS NOT NULL AND NEW.effective_from < v_hire_date THEN
    RAISE EXCEPTION
      'effective_from (%) cannot be before the employee hire date (%) for employee %',
      NEW.effective_from, v_hire_date, NEW.employee_id
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

-- Triggers already exist from mig 635 — they will pick up the updated function.

COMMENT ON FUNCTION fn_guard_effective_from_before_hire() IS
  'Mig 635 (updated mig 636): raises check_violation if effective_from < hire_date. '
  'Prefers employee_employment.hire_date (MIN across all slices) as the authoritative '
  'value; falls back to employees.hire_date. Applied via BEFORE INSERT/UPDATE triggers '
  'on employee_employment and employee_personal.';
