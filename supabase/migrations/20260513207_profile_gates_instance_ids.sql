-- =============================================================================
-- Migration 207: add instance_ids to get_profile_workflow_gates()
--
-- PROBLEM
-- ───────
-- MyProfile shows a "Workflow Pending Approval" badge per section but has no
-- way to open the WorkflowParticipantsModal (mig 206) — it needs the
-- instance_id for the active workflow_instance on that module.
--
-- FIX
-- ───
-- Extend get_profile_workflow_gates() to return an additional key:
--
--   "instance_ids": {
--     "profile_contact": "uuid-of-active-instance",
--     "profile_address": "uuid-of-another-instance"
--   }
--
-- Only modules with an in_progress or awaiting_clarification instance for
-- this user are included. The frontend reads instanceIds[moduleCode] and
-- passes it straight to WorkflowParticipantsModal.
--
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
    'profile_emergency_contact'
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
  'instance_ids: module_code → instance_id for in_progress/awaiting_clarification instances — '
  'used by MyProfile to open WorkflowParticipantsModal (mig 207). '
  'SECURITY DEFINER to call resolve_workflow_for_submission without RLS overhead.';

REVOKE ALL    ON FUNCTION get_profile_workflow_gates() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_profile_workflow_gates() TO authenticated;

-- =============================================================================
-- END OF MIGRATION 207
-- =============================================================================
