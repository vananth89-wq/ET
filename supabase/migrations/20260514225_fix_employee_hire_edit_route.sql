-- =============================================================================
-- Migration 225: Fix employee_hire edit_route
--
-- PROBLEM
-- ───────
-- Migration 217 set edit_route = '/employees/add?mode=edit&id=' which is:
--   1. Wrong path  — actual route is /admin/add-employee
--   2. Wrong param — AddEmployee reads ?edit=<value>, not &id=<value>
--   3. No :id slot — WorkflowReview uses editRoute.replace(':id', recordId)
--                    so the UUID was never substituted into the URL
--
-- This means the Update button in WorkflowReview, even when it appeared,
-- navigated to a broken URL and did not load the employee.
--
-- FIX
-- ───
-- Correct edit_route to: /admin/add-employee?edit=:id&mode=edit
--   • /admin/add-employee  → correct React route (maps to AddEmployee component)
--   • ?edit=:id            → WorkflowReview replaces :id with the employee UUID;
--                            AddEmployee reads searchParams.get('edit')
--   • &mode=edit           → AddEmployee reads mode=edit → isApproverEditMode=true
--                            → shows "Save & Return to Review" button
--                            → allows editing even when employee is locked (Pending)
-- =============================================================================

UPDATE module_codes
SET    edit_route  = '/admin/add-employee?edit=:id&mode=edit',
       description = 'Approval workflow for new employee hire requests submitted by HR Analysts. '
                     'Approver edit-in-flight navigates to AddEmployee with the employee UUID.'
WHERE  code = 'employee_hire';

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT code, label, edit_route
FROM   module_codes
WHERE  code = 'employee_hire';

-- =============================================================================
-- END OF MIGRATION 225
-- =============================================================================
