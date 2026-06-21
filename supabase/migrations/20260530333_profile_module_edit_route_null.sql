-- Migration 333: Null out edit_route for all profile_* modules
--
-- Problem: profile_* modules had their edit_route set to the ESS self-service
-- path (e.g. /profile/personal). When an approver clicked "Update" in the
-- Workflow Inbox, the frontend navigated to that route — which shows the
-- APPROVER's own profile, not the employee whose change is being reviewed.
--
-- Root cause: Pattern A (navigate to edit form) is wrong for profile change
-- approvals. Approvers must use Pattern B (inline edit in the inbox panel),
-- where they see the proposed values and can tweak them before approving.
--
-- Fix: set edit_route = NULL for all profile_* module codes. The frontend
-- already falls back to enterApproverEditMode (Pattern B) when edit_route
-- is null. An additional frontend guard (same release) ignores any non-null
-- edit_route for profile modules as a belt-and-suspenders defence.

UPDATE module_codes
SET    edit_route = NULL
WHERE  code IN (
  'profile_personal',
  'profile_contact',
  'profile_employment',
  'profile_address',
  'profile_passport',
  'profile_identification',
  'profile_emergency_contact',
  'profile_bank',
  'profile_dependents'
);

-- Verify
DO $$
DECLARE v_remaining INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_remaining
  FROM   module_codes
  WHERE  code LIKE 'profile_%'
    AND  edit_route IS NOT NULL;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'mig 333: % profile_* module(s) still have a non-null edit_route', v_remaining;
  END IF;

  RAISE NOTICE 'mig 333: all profile_* edit_route values cleared successfully';
END $$;
