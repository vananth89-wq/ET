-- =============================================================================
-- Migration 243: stub has_permission() + clean up _wf_instance_visible
--
-- BACKGROUND
-- ──────────
-- has_permission() was defined in migration 008 and read from role_permissions.
-- role_permissions was dropped in migration 146.  Since then has_permission()
-- throws "relation role_permissions does not exist" if its body is actually
-- reached.  In practice it was never reached because every caller short-circuits
-- via an earlier condition (submitted_by = auth.uid(), assigned_to = auth.uid(),
-- has_role('admin'), etc.) before PostgreSQL evaluates has_permission().
--
-- Two migrations (135, 191) explicitly documented it as dead.  This migration
-- makes that state official:
--
--   1. has_permission() is replaced with a stub that returns FALSE.
--      Callers that short-circuit continue to work identically.
--      Callers that previously would have thrown now get FALSE instead,
--      which is the correct denial behaviour.
--
--   2. _wf_instance_visible drops the four dead OR clauses so the function
--      matches what it actually does.
--
-- WHAT IS NOT CHANGED
-- ───────────────────
-- All workflow RPCs (wf_approve, wf_admin_reject, wf_clone_template, etc.)
-- that use  has_role('admin') OR has_permission('workflow.admin')  are left
-- untouched.  Once has_permission() returns FALSE the effective logic becomes
--   has_role('admin') OR false  ≡  has_role('admin')
-- which is already the correct enforcement — workflow admin actions are admin-only.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Replace has_permission() with a no-op stub
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION has_permission(check_permission text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- role_permissions was dropped in migration 146.
  -- All enforcement now goes through user_can().
  -- This stub prevents "relation does not exist" errors in legacy callers
  -- that were not yet updated to user_can().
  SELECT false;
$$;

COMMENT ON FUNCTION has_permission(text) IS
  'DEPRECATED STUB — always returns false. '
  'role_permissions was dropped in migration 146; all permission enforcement '
  'moved to user_can(). Callers should be migrated to user_can() over time.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Clean up _wf_instance_visible — remove the dead has_permission() OR clauses
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _wf_instance_visible(p_instance_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    -- submitter can always see their own instance
    EXISTS (
      SELECT 1 FROM workflow_instances
      WHERE id = p_instance_id AND submitted_by = auth.uid()
    )
    OR
    -- current or historical assigned approver
    EXISTS (
      SELECT 1 FROM workflow_tasks
      WHERE instance_id = p_instance_id AND assigned_to = auth.uid()
    );
$$;

COMMENT ON FUNCTION _wf_instance_visible(uuid) IS
  'Returns true if the calling user may read this workflow instance: '
  'either they submitted it, or they hold (or held) an assigned approver task. '
  'Broad admin/manager visibility is handled at the application layer via user_can().';


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_stub_ok boolean;
BEGIN
  -- has_permission() should now return false for any code
  SELECT has_permission('anything') INTO v_stub_ok;
  IF v_stub_ok IS NOT FALSE THEN
    RAISE EXCEPTION 'ABORT: has_permission() stub did not return false.';
  END IF;
  RAISE NOTICE 'has_permission() stub confirmed: returns false.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 243
--
-- After this migration:
--   has_permission()            → always false (no throws, no role_permissions)
--   _wf_instance_visible()      → submitter OR assigned_to only
--   All workflow RPCs            → unchanged; has_role('admin') gates correctly
--   user_can()                   → unchanged; single source of truth for RBP
-- =============================================================================
