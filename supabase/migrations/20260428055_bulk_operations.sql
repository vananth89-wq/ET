-- =============================================================================
-- Migration 055: Bulk Operation RPCs
--
-- Admin-only functions for the Operations screen bulk action bar.
-- Each function iterates over an array of task IDs and delegates to the
-- existing single-task RPC, collecting per-task outcomes.
--
-- Functions:
--   wf_bulk_approve(p_task_ids, p_notes)                — approve multiple tasks
--   wf_bulk_decline(p_task_ids, p_reason)               — decline multiple tasks
--   wf_bulk_reassign(p_task_ids, p_new_profile_id, p_reason) — reassign multiple tasks
--
-- All functions return a JSONB summary:
--   { succeeded: [...task_ids], failed: [{task_id, error}...] }
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. wf_bulk_approve
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_bulk_approve(
  p_task_ids uuid[],
  p_notes    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task_id   uuid;
  v_succeeded uuid[]  := ARRAY[]::uuid[];
  v_failed    jsonb[] := ARRAY[]::jsonb[];
  v_err       text;
BEGIN
  -- ── Access check ──────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_bulk_approve: insufficient permissions';
  END IF;

  IF array_length(p_task_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'wf_bulk_approve: p_task_ids must not be empty';
  END IF;

  FOREACH v_task_id IN ARRAY p_task_ids
  LOOP
    BEGIN
      PERFORM wf_approve(v_task_id, p_notes);
      v_succeeded := v_succeeded || v_task_id;
    EXCEPTION WHEN OTHERS THEN
      v_err    := SQLERRM;
      v_failed := v_failed || jsonb_build_object('task_id', v_task_id, 'error', v_err);
      RAISE NOTICE 'wf_bulk_approve: task % failed — %', v_task_id, v_err;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'succeeded', to_jsonb(v_succeeded),
    'failed',    to_jsonb(v_failed)
  );
END;
$$;

COMMENT ON FUNCTION wf_bulk_approve(uuid[], text) IS
  'Approves multiple workflow tasks in one call. Returns a JSONB summary of '
  'succeeded and failed task IDs. Requires workflow.admin permission.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. wf_bulk_decline
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_bulk_decline(
  p_task_ids uuid[],
  p_reason   text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task_id   uuid;
  v_succeeded uuid[]  := ARRAY[]::uuid[];
  v_failed    jsonb[] := ARRAY[]::jsonb[];
  v_err       text;
BEGIN
  -- ── Access check ──────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_bulk_decline: insufficient permissions';
  END IF;

  IF array_length(p_task_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'wf_bulk_decline: p_task_ids must not be empty';
  END IF;

  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'wf_bulk_decline: a decline reason is required';
  END IF;

  FOREACH v_task_id IN ARRAY p_task_ids
  LOOP
    BEGIN
      PERFORM wf_reject(v_task_id, p_reason);
      v_succeeded := v_succeeded || v_task_id;
    EXCEPTION WHEN OTHERS THEN
      v_err    := SQLERRM;
      v_failed := v_failed || jsonb_build_object('task_id', v_task_id, 'error', v_err);
      RAISE NOTICE 'wf_bulk_decline: task % failed — %', v_task_id, v_err;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'succeeded', to_jsonb(v_succeeded),
    'failed',    to_jsonb(v_failed)
  );
END;
$$;

COMMENT ON FUNCTION wf_bulk_decline(uuid[], text) IS
  'Rejects multiple workflow tasks in one call with a shared reason. Returns a '
  'JSONB summary of succeeded and failed task IDs. Requires workflow.admin permission.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. wf_bulk_reassign
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_bulk_reassign(
  p_task_ids       uuid[],
  p_new_profile_id uuid,
  p_reason         text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task_id   uuid;
  v_succeeded uuid[]  := ARRAY[]::uuid[];
  v_failed    jsonb[] := ARRAY[]::jsonb[];
  v_err       text;
BEGIN
  -- ── Access check ──────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_bulk_reassign: insufficient permissions';
  END IF;

  IF array_length(p_task_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'wf_bulk_reassign: p_task_ids must not be empty';
  END IF;

  IF p_new_profile_id IS NULL THEN
    RAISE EXCEPTION 'wf_bulk_reassign: p_new_profile_id is required';
  END IF;

  -- Verify the target profile exists
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_new_profile_id) THEN
    RAISE EXCEPTION 'wf_bulk_reassign: profile % not found', p_new_profile_id;
  END IF;

  FOREACH v_task_id IN ARRAY p_task_ids
  LOOP
    BEGIN
      PERFORM wf_reassign(v_task_id, p_new_profile_id, p_reason);
      v_succeeded := v_succeeded || v_task_id;
    EXCEPTION WHEN OTHERS THEN
      v_err    := SQLERRM;
      v_failed := v_failed || jsonb_build_object('task_id', v_task_id, 'error', v_err);
      RAISE NOTICE 'wf_bulk_reassign: task % failed — %', v_task_id, v_err;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'succeeded', to_jsonb(v_succeeded),
    'failed',    to_jsonb(v_failed)
  );
END;
$$;

COMMENT ON FUNCTION wf_bulk_reassign(uuid[], uuid, text) IS
  'Reassigns multiple workflow tasks to a new approver in one call. Returns a '
  'JSONB summary of succeeded and failed task IDs. Requires workflow.admin permission.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname, pronargs
FROM   pg_proc
WHERE  proname IN ('wf_bulk_approve', 'wf_bulk_decline', 'wf_bulk_reassign')
ORDER  BY proname;
