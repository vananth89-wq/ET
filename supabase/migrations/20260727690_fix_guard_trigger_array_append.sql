-- =============================================================================
-- Migration 690 — fn_guard_employee_employment_sync: unambiguous array append
--
-- BUG (pre-existing, latent since mig 351)
-- ────────────────────────────────────────
-- fn_guard_employee_employment_sync uses:
--   v_changed_mirror_cols := v_changed_mirror_cols || 'status';
-- When v_changed_mirror_cols is still empty (ARRAY[]::text[]), Postgres
-- fails to resolve text[] || <unknown-typed literal>. It tries to cast
-- 'status' as a text[] literal and errors with:
--   "malformed array literal: \"status\""
--
-- This has been dormant because the two bypasses (allow_employment_sync
-- session flag OR OLD.status IN Draft/Incomplete/Pending) covered every
-- normal path. A hire save with OLD.status='Active' → NEW.status='Draft'
-- (rare but possible) trips it — status is the only column that changed,
-- so the append happens on the still-empty array and fails.
--
-- FIX
-- ───
-- Replace every `|| '<literal>'` with `array_append(..., '<literal>')`.
-- array_append(text[], text) is unambiguous — no operator resolution needed.
-- Behaviour is identical.
--
-- IDEMPOTENT: CREATE OR REPLACE.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_guard_employee_employment_sync()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_bypass              boolean;
  v_changed_mirror_cols text[] := ARRAY[]::text[];
BEGIN
  -- Session bypass flag (set inside upsert_employment_info / sync job)
  v_bypass := current_setting('prowess.allow_employment_sync', true) = 'true';
  IF v_bypass THEN
    RETURN NEW;
  END IF;

  -- Hire pipeline bypass: allow direct writes for onboarding statuses
  IF OLD.status IN ('Draft', 'Incomplete', 'Pending') THEN
    RETURN NEW;
  END IF;

  -- Active / Inactive: detect which mirror columns changed
  IF NEW.designation      IS DISTINCT FROM OLD.designation      THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'designation');      END IF;
  IF NEW.job_title        IS DISTINCT FROM OLD.job_title        THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'job_title');        END IF;
  IF NEW.dept_id          IS DISTINCT FROM OLD.dept_id          THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'dept_id');          END IF;
  IF NEW.manager_id       IS DISTINCT FROM OLD.manager_id       THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'manager_id');       END IF;
  IF NEW.hire_date        IS DISTINCT FROM OLD.hire_date        THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'hire_date');        END IF;
  IF NEW.work_country     IS DISTINCT FROM OLD.work_country     THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'work_country');     END IF;
  IF NEW.work_location    IS DISTINCT FROM OLD.work_location    THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'work_location');    END IF;
  IF NEW.base_currency_id IS DISTINCT FROM OLD.base_currency_id THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'base_currency_id'); END IF;
  IF NEW.status           IS DISTINCT FROM OLD.status           THEN v_changed_mirror_cols := array_append(v_changed_mirror_cols, 'status');           END IF;

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
  'Mig 514: removed end_date check (column dropped in mig 487). '
  'Mig 690: switched from ambiguous `|| ''col''` to array_append() — the '
  'former failed with "malformed array literal" when v_changed_mirror_cols '
  'was still empty and only one column had changed.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public'
      AND routine_name   = 'fn_guard_employee_employment_sync'
  ) THEN
    RAISE EXCEPTION 'ABORT: fn_guard_employee_employment_sync missing.';
  END IF;
  RAISE NOTICE 'Migration 690 verified: guard trigger now uses array_append().';
END;
$$;
