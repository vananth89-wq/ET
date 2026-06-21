-- =============================================================================
-- Migration 514 — Remove end_date reference from fn_guard_employee_employment_sync
--
-- PROBLEM
-- ───────
-- mig 487 dropped employees.end_date but fn_guard_employee_employment_sync
-- (created in mig 351) still references NEW.end_date / OLD.end_date.
-- Every UPDATE on an Active/Inactive employee row crashes with:
--   "record new has no field end_date"
-- This breaks resend_hire_invite and any other flow that writes to employees.
--
-- FIX
-- ───
-- Re-create the trigger function without the end_date check line.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_guard_employee_employment_sync()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_bypass              boolean;
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
  -- NOTE: end_date removed (mig 487 dropped the column)
  IF NEW.designation      IS DISTINCT FROM OLD.designation      THEN v_changed_mirror_cols := v_changed_mirror_cols || 'designation';      END IF;
  IF NEW.job_title        IS DISTINCT FROM OLD.job_title        THEN v_changed_mirror_cols := v_changed_mirror_cols || 'job_title';        END IF;
  IF NEW.dept_id          IS DISTINCT FROM OLD.dept_id          THEN v_changed_mirror_cols := v_changed_mirror_cols || 'dept_id';          END IF;
  IF NEW.manager_id       IS DISTINCT FROM OLD.manager_id       THEN v_changed_mirror_cols := v_changed_mirror_cols || 'manager_id';       END IF;
  IF NEW.hire_date        IS DISTINCT FROM OLD.hire_date        THEN v_changed_mirror_cols := v_changed_mirror_cols || 'hire_date';        END IF;
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

COMMENT ON FUNCTION fn_guard_employee_employment_sync() IS
  'Mig 351: initial creation. '
  'Mig 514: removed NEW.end_date / OLD.end_date check — column dropped in mig 487.';

-- =============================================================================
-- VERIFICATION
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public'
      AND routine_name   = 'fn_guard_employee_employment_sync'
  ) THEN
    RAISE EXCEPTION 'ABORT: fn_guard_employee_employment_sync missing.';
  END IF;
  RAISE NOTICE 'Migration 514 verified: fn_guard_employee_employment_sync updated.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 514
-- =============================================================================
