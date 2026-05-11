-- =============================================================================
-- Migration 175: get_profile_workflow_gates() — user-aware profile gate check
--
-- PROBLEM
-- ───────
-- useProfileWorkflowGates (the client hook) was querying workflow_assignments
-- directly with a broad filter: "does ANY active assignment exist for this
-- module code?" This created two bugs:
--
--   Bug 1 — User-scope mismatch:
--     The direct query returns true for ROLE or EMPLOYEE assignments even if
--     the current user doesn't match the assignment's scope. The UI then shows
--     the WorkflowSubmitModal, but resolve_workflow_for_submission (called by
--     submit_change_request) returns NULL for that user → submission fails with
--     "No active workflow assignment found". Alternatively, for a GLOBAL
--     assignment the user IS covered, but the hook could miss it due to date
--     edge cases in the PostgREST .or() filter.
--
--   Bug 2 — Stale data:
--     The hook ran once on mount. If an admin assigned or removed a workflow
--     while the user had My Profile open, the gates were stale.
--
-- FIX
-- ───
-- Replace the two direct client queries with a single SECURITY DEFINER RPC.
-- The RPC calls resolve_workflow_for_submission() for each profile module code
-- — exactly the same resolver used by submit_change_request — so the hook
-- always returns what the submission layer will actually find.
-- Pending counts are fetched in the same call, scoped to auth.uid().
--
-- CALLER IMPACT
-- ─────────────
-- useProfileWorkflowGates.ts updated to call this RPC instead of the two
-- direct table queries. The hook exposes a refetch() function so MyProfile
-- can refresh gates when the user enters edit mode.
-- =============================================================================


CREATE OR REPLACE FUNCTION get_profile_workflow_gates()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id  uuid   := auth.uid();
  v_module_codes text[] := ARRAY[
    'profile_personal',
    'profile_contact',
    'profile_employment',
    'profile_address',
    'profile_passport',
    'profile_identification',
    'profile_emergency_contact'
  ];
  v_code        text;
  v_template_id uuid;
  v_gated       text[]           := '{}';
  v_pending     jsonb            := '{}'::jsonb;
BEGIN
  -- ── 1. For each profile section, check if a workflow resolves for this user ──
  -- Uses the same resolver (EMPLOYEE > ROLE > GLOBAL) as submit_change_request,
  -- so the UI gate is always consistent with what the submission layer will find.
  FOREACH v_code IN ARRAY v_module_codes LOOP
    v_template_id := resolve_workflow_for_submission(v_code, v_profile_id);
    IF v_template_id IS NOT NULL THEN
      v_gated := array_append(v_gated, v_code);
    END IF;
  END LOOP;

  -- ── 2. Pending counts — how many 'pending' workflow_pending_changes rows
  --        does THIS user have per module?  (RLS on wpc already scopes to
  --        submitted_by = auth.uid(), so this is an extra belt-and-suspenders
  --        filter to avoid leaking counts if RLS policy ever changes.)
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

  RETURN jsonb_build_object(
    'gated_modules',  to_jsonb(v_gated),
    'pending_counts', v_pending
  );
END;
$$;

COMMENT ON FUNCTION get_profile_workflow_gates() IS
  'Returns gated profile module codes (where resolve_workflow_for_submission '
  'finds an active template for the caller) plus per-module pending change counts. '
  'SECURITY DEFINER so it can call resolve_workflow_for_submission and read '
  'workflow_pending_changes without triggering extra RLS stacks. '
  'Called by useProfileWorkflowGates hook on mount and on edit-mode entry.';

REVOKE ALL    ON FUNCTION get_profile_workflow_gates() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_profile_workflow_gates() TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT proname, prosecdef, provolatile
FROM   pg_proc
WHERE  proname = 'get_profile_workflow_gates';

-- Expected: proname=get_profile_workflow_gates, prosecdef=true, provolatile=s (STABLE)

-- =============================================================================
-- END OF MIGRATION 175
--
-- Type regen: NOT needed (no new table columns or public-facing type changes).
-- After applying: refresh My Profile → edit any gated section → WorkflowSubmitModal
-- should open. Test with GLOBAL and ROLE assignments.
-- =============================================================================
