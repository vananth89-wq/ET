-- ─────────────────────────────────────────────────────────────────────────────
-- Migration : 20260802707_timesheet_create_permissions.sql
-- Purpose   : Add missing 'create' action permission codes for time management
--             resources that support it. RLS INSERT policies already check
--             user_can(..., 'create', NULL) — this migration registers the codes
--             so they can be granted in the Permission Matrix.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'time_management';

  INSERT INTO permissions (module_id, code, name, description, action, sort_order)
  VALUES
    (v_module_id, 'time_work_schedules.create',    'Create Work Schedules',    'Add new work schedule definitions.',                          'create', 10),
    (v_module_id, 'time_holiday_calendars.create', 'Create Holiday Calendars', 'Add new holiday calendar definitions.',                       'create', 20),
    (v_module_id, 'time_holidays.create',          'Create Holidays',          'Add new holiday entries to a calendar.',                      'create', 30),
    (v_module_id, 'time_types.create',             'Create Time Types',        'Add new time type definitions.',                              'create', 40),
    (v_module_id, 'time_submission_config.create', 'Create Submission Config', 'Add new submission reminder configuration rows.',             'create', 70)

  ON CONFLICT (code) DO UPDATE SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    action      = EXCLUDED.action,
    sort_order  = EXCLUDED.sort_order;
END $$;

-- ── Verification ──────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM permissions p
    JOIN modules m ON m.id = p.module_id
   WHERE m.code = 'time_management' AND p.action = 'create';

  RAISE NOTICE '707 time_management create permissions: %', v_count;

  IF v_count < 5 THEN
    RAISE EXCEPTION '707 FAIL: expected ≥5 create permissions, got %', v_count;
  END IF;
END $$;
