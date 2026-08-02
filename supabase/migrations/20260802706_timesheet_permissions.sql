-- ─────────────────────────────────────────────────────────────────────────────
-- Migration : 20260802706_timesheet_permissions.sql
-- Module    : Time Management
-- Purpose   : Insert module record + all permission codes for time management
--             so that user_can() checks and ProtectedRoute gates work.
-- Depends   : modules table, permissions table (from security migrations)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Module row ─────────────────────────────────────────────────────────────

INSERT INTO modules (code, name, sort_order, active)
VALUES (
  'time_management',
  'Time Management',
  60,
  true
)
ON CONFLICT (code) DO UPDATE SET
  name       = EXCLUDED.name,
  sort_order = EXCLUDED.sort_order,
  active     = EXCLUDED.active;

-- ── 2. Permission codes ───────────────────────────────────────────────────────

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'time_management';

  INSERT INTO permissions (module_id, code, name, description, action, sort_order)
  VALUES
    -- Work Schedules
    (v_module_id, 'time_work_schedules.view',   'View Work Schedules',        'Read work schedule definitions.',                               'view',   10),
    (v_module_id, 'time_work_schedules.edit',   'Edit Work Schedules',        'Create and update work schedules.',                             'edit',   11),
    (v_module_id, 'time_work_schedules.delete', 'Delete Work Schedules',      'Delete work schedule records.',                                 'delete', 12),

    -- Holiday Calendars
    (v_module_id, 'time_holiday_calendars.view',   'View Holiday Calendars',   'Read holiday calendar definitions.',                           'view',   20),
    (v_module_id, 'time_holiday_calendars.edit',   'Edit Holiday Calendars',   'Create and update holiday calendars.',                         'edit',   21),
    (v_module_id, 'time_holiday_calendars.delete', 'Delete Holiday Calendars', 'Delete holiday calendar records.',                             'delete', 22),

    -- Holidays
    (v_module_id, 'time_holidays.view',   'View Holidays',   'Read holiday entries within calendars.',                                         'view',   30),
    (v_module_id, 'time_holidays.edit',   'Edit Holidays',   'Create and update holiday entries.',                                             'edit',   31),
    (v_module_id, 'time_holidays.delete', 'Delete Holidays', 'Delete holiday entries.',                                                        'delete', 32),

    -- Time Types
    (v_module_id, 'time_types.view',   'View Time Types',   'Read time type definitions.',                                                     'view',   40),
    (v_module_id, 'time_types.edit',   'Edit Time Types',   'Create and update time types.',                                                   'edit',   41),
    (v_module_id, 'time_types.delete', 'Delete Time Types', 'Delete time type records.',                                                       'delete', 42),

    -- Color Config
    (v_module_id, 'time_color_config.view', 'View Color Config', 'Read timesheet color palette.',                                              'view',   50),
    (v_module_id, 'time_color_config.edit', 'Edit Color Config', 'Update timesheet color palette.',                                            'edit',   51),

    -- Edit Window Config
    (v_module_id, 'time_edit_config.view', 'View Edit Window Config', 'Read timesheet edit window settings.',                                  'view',   60),
    (v_module_id, 'time_edit_config.edit', 'Edit Edit Window Config', 'Update timesheet edit window settings.',                                'edit',   61),

    -- Submission Config
    (v_module_id, 'time_submission_config.view',   'View Submission Config',   'Read timesheet submission reminder configuration.',            'view',   70),
    (v_module_id, 'time_submission_config.edit',   'Edit Submission Config',   'Update timesheet submission reminder configuration.',          'edit',   71),
    (v_module_id, 'time_submission_config.delete', 'Delete Submission Config', 'Delete timesheet submission reminder rows.',                   'delete', 72),

    -- Timesheet (employee self-service)
    (v_module_id, 'timesheet.view',   'View Own Timesheet',   'Employee can view their own timesheets.',                                       'view',   80),
    (v_module_id, 'timesheet.edit',   'Edit Own Timesheet',   'Employee can add/edit entries on their own timesheets.',                        'edit',   81),
    (v_module_id, 'timesheet.delete', 'Delete Own Timesheet', 'Employee can remove entries within the edit window.',                           'delete', 82),

    -- Timesheet Admin
    (v_module_id, 'timesheet_admin.view',    'View All Timesheets (Admin)',   'Admin can read any employee timesheet.',         'view',   90),
    (v_module_id, 'timesheet_admin.edit',    'Edit All Timesheets (Admin)',   'Admin can edit any employee timesheet.',         'edit',   91),
    (v_module_id, 'timesheet_admin.approve', 'Approve Timesheets (Admin)',    'Admin can approve timesheets directly.',         'edit',   92),

    -- Manager review
    (v_module_id, 'timesheet_manager.view',    'View Team Timesheets',    'Manager can read timesheets for their direct reports.',  'view',   100),
    (v_module_id, 'timesheet_manager.edit',    'Edit Team Timesheets',    'Manager can edit timesheets for their direct reports.',  'edit',   101),
    (v_module_id, 'timesheet_manager.approve', 'Approve Team Timesheets', 'Manager can approve timesheets for their direct reports.', 'edit', 102),

    -- Reporting
    (v_module_id, 'timesheet_reports.view', 'View Timesheet Reports', 'Access timesheet reporting and analytics pages.',                       'view',   110)

  ON CONFLICT (code) DO UPDATE SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    action      = EXCLUDED.action,
    sort_order  = EXCLUDED.sort_order;
END $$;

-- ── 3. Verification ───────────────────────────────────────────────────────────

DO $$
DECLARE
  v_module_ok  boolean;
  v_perm_count integer;
BEGIN
  SELECT EXISTS(SELECT 1 FROM modules WHERE code = 'time_management') INTO v_module_ok;
  SELECT COUNT(*) INTO v_perm_count
    FROM permissions p
    JOIN modules m ON m.id = p.module_id
   WHERE m.code = 'time_management';

  RAISE NOTICE '706 time_management module present: %', v_module_ok;
  RAISE NOTICE '706 time_management permissions inserted: %', v_perm_count;

  IF NOT v_module_ok THEN
    RAISE EXCEPTION '706 FAIL: time_management module row missing';
  END IF;
  IF v_perm_count < 28 THEN
    RAISE EXCEPTION '706 FAIL: expected ≥28 permission rows, got %', v_perm_count;
  END IF;
END $$;
