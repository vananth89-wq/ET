-- =============================================================================
-- Migration 355 — Backfill employee_employment from employees master
-- =============================================================================
--
-- WHAT
-- ────
-- Seeds the first effective-dated slice in employee_employment for EVERY
-- employee (all statuses) by copying the 10 employment fields from
-- employees master. This establishes the satellite as the complete source
-- of truth from day one.
--
-- ALGORITHM (design spec §10)
-- ────────────────────────────
-- For each employee in employees:
--   1. Skip if employee_employment already has an active open-ended row
--      (idempotency — re-runnable without duplication).
--   2. Copy 10 fields from employees + probation_end_date from existing
--      employee_employment row (if any).
--   3. effective_from = COALESCE(hire_date, created_at::date, '2000-01-01').
--   4. status in the satellite = employees.status (source of truth for current state).
--
-- VALIDATION
-- ──────────
-- After backfill, inside the same transaction:
--   a) Every employee has at least one active open-ended slice.
--   b) Every employee with hire_date NOT NULL has matching effective_from = hire_date.
--   c) No employee has more than one open-ended active slice (index enforces, but verified).
--   d) Every Active employee's satellite status = 'Active'.
-- Transaction aborts on validation failure — no partial state.
--
-- GUARD
-- ─────
-- The guard trigger (mig 351) fires BEFORE UPDATE on employees. This migration
-- writes to employee_employment directly (INSERT only on the satellite) and does
-- NOT update employees — so the guard is not involved.
--
-- IDEMPOTENCY
-- ───────────
-- The NOT EXISTS check in step 1 makes this safe to re-run. The unique index
-- idx_ee_one_active_row would also block a duplicate insert, but the guard is
-- at the application level here for clarity.
-- =============================================================================

DO $$
DECLARE
  -- Counters
  v_total_employees   int := 0;
  v_skipped           int := 0;
  v_inserted          int := 0;

  -- Validation
  v_missing           int;
  v_hire_date_mismatch int;
  v_duplicate_open    int;
  v_status_mismatch   int;

  -- Per-employee
  r                   RECORD;
  v_probation_end_date date;
BEGIN

  -- ── 1. Backfill loop ──────────────────────────────────────────────────────

  FOR r IN
    SELECT
      e.id,
      e.designation,
      e.job_title,
      e.dept_id,
      e.manager_id,
      e.hire_date,
      e.end_date,
      e.work_country,
      e.work_location,
      e.base_currency_id,
      e.status,
      e.created_at,
      COALESCE(
        e.hire_date,
        e.created_at::date,
        '2000-01-01'::date
      ) AS effective_from
    FROM employees e
    WHERE e.deleted_at IS NULL
    ORDER BY e.created_at
  LOOP
    v_total_employees := v_total_employees + 1;

    -- Skip if already has an active open-ended slice (idempotency)
    IF EXISTS (
      SELECT 1
      FROM   employee_employment
      WHERE  employee_id  = r.id
        AND  effective_to = '9999-12-31'::date
        AND  is_active    = true
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Get probation_end_date from existing employee_employment row (if any)
    SELECT probation_end_date
    INTO   v_probation_end_date
    FROM   employee_employment
    WHERE  employee_id = r.id
    LIMIT  1;

    -- Insert the initial slice
    INSERT INTO employee_employment (
      employee_id,
      designation,
      job_title,
      dept_id,
      manager_id,
      hire_date,
      end_date,
      work_country,
      work_location,
      base_currency_id,
      status,
      probation_end_date,
      effective_from,
      effective_to,
      is_active,
      created_by,
      updated_by
    ) VALUES (
      r.id,
      r.designation,
      r.job_title,
      r.dept_id,
      r.manager_id,
      r.hire_date,
      r.end_date,
      r.work_country,
      r.work_location,
      r.base_currency_id,
      r.status,
      v_probation_end_date,
      r.effective_from,
      '9999-12-31'::date,
      true,
      NULL,   -- system-backfilled, no user
      NULL
    );

    v_inserted := v_inserted + 1;
  END LOOP;

  RAISE NOTICE 'mig 355 backfill: total=%, skipped=%, inserted=%',
    v_total_employees, v_skipped, v_inserted;

  -- ── 2. Validation ─────────────────────────────────────────────────────────

  -- a) Every non-deleted employee must have an active open-ended slice
  SELECT COUNT(*)
  INTO   v_missing
  FROM   employees e
  WHERE  e.deleted_at IS NULL
    AND  NOT EXISTS (
      SELECT 1
      FROM   employee_employment ee
      WHERE  ee.employee_id  = e.id
        AND  ee.effective_to = '9999-12-31'::date
        AND  ee.is_active    = true
    );

  IF v_missing > 0 THEN
    RAISE EXCEPTION
      'mig 355 validation FAILED: % employees have no active open-ended employment slice.',
      v_missing;
  END IF;

  -- b) Every employee with hire_date should have effective_from = hire_date
  SELECT COUNT(*)
  INTO   v_hire_date_mismatch
  FROM   employees e
  JOIN   employee_employment ee
    ON   ee.employee_id  = e.id
    AND  ee.effective_to = '9999-12-31'::date
    AND  ee.is_active    = true
  WHERE  e.hire_date IS NOT NULL
    AND  ee.effective_from != e.hire_date
    AND  e.deleted_at IS NULL;

  IF v_hire_date_mismatch > 0 THEN
    RAISE EXCEPTION
      'mig 355 validation FAILED: % employees have effective_from != hire_date.',
      v_hire_date_mismatch;
  END IF;

  -- c) No employee has more than one open-ended active slice
  SELECT COUNT(*)
  INTO   v_duplicate_open
  FROM (
    SELECT employee_id
    FROM   employee_employment
    WHERE  effective_to = '9999-12-31'::date
      AND  is_active    = true
    GROUP  BY employee_id
    HAVING COUNT(*) > 1
  ) dups;

  IF v_duplicate_open > 0 THEN
    RAISE EXCEPTION
      'mig 355 validation FAILED: % employees have multiple open-ended active slices.',
      v_duplicate_open;
  END IF;

  -- d) Every Active employee's satellite status = 'Active'
  SELECT COUNT(*)
  INTO   v_status_mismatch
  FROM   employees e
  JOIN   employee_employment ee
    ON   ee.employee_id  = e.id
    AND  ee.effective_to = '9999-12-31'::date
    AND  ee.is_active    = true
  WHERE  e.status = 'Active'
    AND  ee.status != 'Active'
    AND  e.deleted_at IS NULL;

  IF v_status_mismatch > 0 THEN
    RAISE EXCEPTION
      'mig 355 validation FAILED: % Active employees have mismatched satellite status.',
      v_status_mismatch;
  END IF;

  RAISE NOTICE 'mig 355 validation PASSED: all % checks clean.', 4;

END;
$$;
