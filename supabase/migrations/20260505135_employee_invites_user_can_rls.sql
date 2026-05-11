-- =============================================================================
-- Migration 135: Upgrade employee_invites RLS to user_can()
--
-- SCOPE NOTE
-- ──────────
-- employees, employee_addresses, emergency_contacts, identity_records, and
-- passports were already fully migrated to user_can() in migrations 098 and
-- 109. Only employee_invites remains on the old has_role / has_permission path.
--
-- BACKGROUND
-- ──────────
-- employee_invites has three policies, all gated on:
--   has_role('admin') OR has_permission('hr.manage_employees')
-- has_permission() reads from the dead role_permissions table — no enforcement.
-- No DELETE policy exists (invites are soft-cancelled via status update).
--
-- MAPPING
-- ───────
-- employee_invites → employee_details module (confirmed, no own module needed)
-- employee_details.edit already exists (seeded in migration 098).
-- =============================================================================


-- ── Replace all three employee_invites policies ───────────────────────────────

DROP POLICY IF EXISTS emp_invites_admin_select ON employee_invites;
DROP POLICY IF EXISTS emp_invites_admin_insert ON employee_invites;
DROP POLICY IF EXISTS emp_invites_admin_update ON employee_invites;

CREATE POLICY emp_invites_select ON employee_invites
  FOR SELECT
  USING (user_can('employee_details', 'edit', NULL));

CREATE POLICY emp_invites_insert ON employee_invites
  FOR INSERT
  WITH CHECK (user_can('employee_details', 'edit', NULL));

CREATE POLICY emp_invites_update ON employee_invites
  FOR UPDATE
  USING      (user_can('employee_details', 'edit', NULL))
  WITH CHECK (user_can('employee_details', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename = 'employee_invites'
ORDER BY cmd, policyname;
