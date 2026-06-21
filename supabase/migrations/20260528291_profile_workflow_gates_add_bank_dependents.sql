-- =============================================================================
-- Migration 291: add profile_bank and profile_dependents to
--                get_profile_workflow_gates()
--
-- PROBLEM
-- ───────
-- Migrations 289/290 introduced the profile_bank and profile_dependents
-- workflow modules but the gate-check RPC (last updated in mig 207) still
-- only covers the original 7 profile sections.
--
-- As a result:
--   • MyProfile never shows the "Workflow Pending Approval" banner for bank or
--     dependents changes.
--   • The "View approval progress" link never appears for those sections.
--   • pendingCounts['profile_bank'] and pendingCounts['profile_dependents']
--     are always undefined on the frontend.
--
-- FIX
-- ───
-- Add 'profile_bank' and 'profile_dependents' to the v_module_codes array in
-- all three query blocks (gate check loop, pending counts, instance_ids).
-- No schema changes — purely a function replacement.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_profile_workflow_gates()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id   uuid   := auth.uid();
  v_module_codes text[] := ARRAY[
    'profile_personal',
    'profile_contact',
    'profile_employment',
    'profile_address',
    'profile_passport',
    'profile_identification',
    'profile_emergency_contact',
    'profile_bank',
    'profile_dependents'
  ];
  v_code         text;
  v_template_id  uuid;
  v_gated        text[] := '{}';
  v_pending      jsonb  := '{}'::jsonb;
  v_instance_ids jsonb  := '{}'::jsonb;
BEGIN
  -- ── 1. Gate check per module ────────────────────────────────────────────────
  FOREACH v_code IN ARRAY v_module_codes LOOP
    v_template_id := resolve_workflow_for_submission(v_code, v_profile_id);
    IF v_template_id IS NOT NULL THEN
      v_gated := array_append(v_gated, v_code);
    END IF;
  END LOOP;

  -- ── 2. Pending change counts (scoped to this user) ──────────────────────────
  SELECT COALESCE(jsonb_object_agg(module_code, cnt), '{}')
  INTO   v_pending
  FROM (
    SELECT module_code, COUNT(*)::int AS cnt
    FROM   workflow_pending_changes
    WHERE  module_code  = ANY(v_module_codes)
      AND  status       = 'pending'
      AND  submitted_by = v_profile_id
    GROUP  BY module_code
  ) sub;

  -- ── 3. Active instance IDs per module ───────────────────────────────────────
  -- Returns the most-recently-created in_progress / awaiting_clarification
  -- instance for this user per module code. Used by MyProfile to open
  -- WorkflowParticipantsModal with the correct instance.
  SELECT COALESCE(jsonb_object_agg(module_code, instance_id), '{}')
  INTO   v_instance_ids
  FROM (
    SELECT DISTINCT ON (module_code)
           module_code,
           id AS instance_id
    FROM   workflow_instances
    WHERE  submitted_by = v_profile_id
      AND  module_code  = ANY(v_module_codes)
      AND  status       IN ('in_progress', 'awaiting_clarification')
    ORDER  BY module_code, created_at DESC
  ) sub;

  RETURN jsonb_build_object(
    'gated_modules',  to_jsonb(v_gated),
    'pending_counts', v_pending,
    'instance_ids',   v_instance_ids
  );
END;
$$;

COMMENT ON FUNCTION get_profile_workflow_gates() IS
  'Returns gated profile module codes, per-module pending change counts, '
  'and instance_ids for active workflow instances per module. '
  'Covers: profile_personal, profile_contact, profile_employment, '
  'profile_address, profile_passport, profile_identification, '
  'profile_emergency_contact, profile_bank, profile_dependents. '
  'instance_ids: module_code → instance_id for in_progress/awaiting_clarification instances — '
  'used by MyProfile to open WorkflowParticipantsModal (mig 207). '
  'SECURITY DEFINER to call resolve_workflow_for_submission without RLS overhead. '
  'profile_bank and profile_dependents added in mig 291.';

REVOKE ALL     ON FUNCTION get_profile_workflow_gates() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_profile_workflow_gates() TO authenticated;

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  ASSERT (
    SELECT COUNT(*) FROM pg_proc
    WHERE  proname = 'get_profile_workflow_gates'
  ) = 1,
  'get_profile_workflow_gates function not found after migration 291';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 291
-- =============================================================================
