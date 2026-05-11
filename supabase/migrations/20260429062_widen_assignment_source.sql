-- =============================================================================
-- Migration 062: Widen user_roles.assignment_source check constraint
--
-- The original constraint only allowed ('manual', 'system').
-- Migrations 058–061 introduced additional sources:
--   'invite'    — sent via Activate Employee button (signInWithOtp)
--   'auto'      — granted by handle_new_user() trigger on first sign-in
--   'reconcile' — back-filled by reconcile_employee_profiles()
--   'backfill'  — granted by backfill_ess_for_active_employees()
--   'sync_job'  — granted by sync_employee_ess() pg-cron job
-- =============================================================================

ALTER TABLE user_roles
  DROP CONSTRAINT IF EXISTS user_roles_assignment_source_check;

ALTER TABLE user_roles
  ADD CONSTRAINT user_roles_assignment_source_check
  CHECK (assignment_source IN (
    'manual',
    'system',
    'invite',
    'auto',
    'reconcile',
    'backfill',
    'sync_job'
  ));

COMMENT ON COLUMN user_roles.assignment_source IS
  'How the role was granted: '
  'manual = admin assigned it in Role Assignments UI. '
  'system = auto-sync via sync_system_roles(). '
  'invite = granted at Activate Employee time. '
  'auto = granted by handle_new_user() trigger on first sign-in. '
  'reconcile = back-filled by reconcile_employee_profiles(). '
  'backfill = granted by backfill_ess_for_active_employees(). '
  'sync_job = granted by sync_employee_ess() pg-cron job.';

-- Verification
SELECT conname, pg_get_constraintdef(oid)
FROM   pg_constraint
WHERE  conname = 'user_roles_assignment_source_check';
