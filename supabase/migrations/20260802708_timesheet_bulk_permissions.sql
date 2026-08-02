-- ─────────────────────────────────────────────────────────────────────────────
-- Migration : 20260802708_timesheet_bulk_permissions.sql
-- Purpose   : Add bulk_import and bulk_export permission codes for Timesheets
--             so the Import/Export section in the Permission Matrix is clickable.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'time_management';

  INSERT INTO permissions (module_id, code, name, description, action, sort_order)
  VALUES
    (v_module_id, 'timesheet.bulk_import', 'Import Timesheets', 'Bulk-import timesheet entries via CSV/Excel.', 'create', 120),
    (v_module_id, 'timesheet.bulk_export', 'Export Timesheets', 'Bulk-export timesheet entries to CSV/Excel.',  'view',   121)

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
    FROM permissions
   WHERE code IN ('timesheet.bulk_import', 'timesheet.bulk_export');

  RAISE NOTICE '708 timesheet bulk permission codes present: %', v_count;

  IF v_count < 2 THEN
    RAISE EXCEPTION '708 FAIL: expected 2 bulk permission codes, got %', v_count;
  END IF;
END $$;
