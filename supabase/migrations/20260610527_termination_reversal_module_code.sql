-- =============================================================================
-- Migration 527 — Register 'termination_reversal' as a separate module code
--
-- PROBLEM
-- ───────
-- Mig 492 changed submit_termination_reversal to call
-- resolve_workflow_for_submission('termination', auth.uid()) — the same
-- module_code as primary termination. This means:
--   • No separate entry in module_codes for reversals
--   • Admin cannot attach a different workflow template to reversals
--   • Both primary termination AND reversal share the same approver chain
--
-- FIX
-- ───
-- 1. Register 'termination_reversal' in module_codes so it appears in the
--    Workflow → Assignments UI as a distinct configurable module.
--
-- 2. Update submit_termination_reversal to resolve via
--    resolve_workflow_for_submission('termination_reversal', ...) so it
--    uses the reversal-specific assignment when one is configured.
--    (Falls back to direct-save / APPROVED if no assignment exists —
--    same behaviour as all other modules with no assignment.)
--
-- NOTE on module_code in wf_submit / workflow_instances
-- ──────────────────────────────────────────────────────
-- We keep p_module_code = 'termination' in wf_submit so that
-- wf_sync_module_status still routes to the termination branch (which
-- already handles employee_termination_reversals by table-existence check).
-- Only the RESOLUTION lookup key changes to 'termination_reversal'.
--
-- Predecessor: 20260609526
-- =============================================================================


-- =============================================================================
-- 1. Register 'termination_reversal' in module_codes
-- =============================================================================

INSERT INTO module_codes (code, label, description, edit_route)
VALUES (
  'termination_reversal',
  'Termination Reversal',
  'Approval workflow for reversing an approved employee termination.',
  NULL
)
ON CONFLICT (code) DO UPDATE
  SET label       = EXCLUDED.label,
      description = EXCLUDED.description,
      edit_route  = EXCLUDED.edit_route;


-- =============================================================================
-- 2. Update submit_termination_reversal to resolve via 'termination_reversal'
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_termination_reversal(
  p_termination_id  uuid,
  p_reversal_data   jsonb,
  p_attachments     jsonb DEFAULT '[]'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_termination     employee_terminations%ROWTYPE;
  v_reversal_reason text;
  v_comments        text;
  v_reversal_id     uuid;
  v_instance_id     uuid;
  v_template_id     uuid;
  v_template_code   text;
  v_has_workflow    boolean;
  v_att             jsonb;
BEGIN

  -- ── 1. Load and validate original termination ──────────────────────────────
  SELECT * INTO v_termination
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found.');
  END IF;

  IF v_termination.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Only APPROVED terminations can be reversed. Current status: '
      || v_termination.workflow_status || '.');
  END IF;

  -- ── 2. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('termination', 'edit', v_termination.employee_id)
    OR user_can('termination', 'edit', NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- ── 3. Validate payload ────────────────────────────────────────────────────
  v_reversal_reason := NULLIF(p_reversal_data->>'reversal_reason', '');
  v_comments        := NULLIF(p_reversal_data->>'comments', '');

  IF v_reversal_reason IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reversal_reason is required.');
  END IF;
  IF v_comments IS NULL OR length(v_comments) < 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 20 characters.');
  END IF;

  -- ── 4. Resolve workflow assignment ────────────────────────────────────────
  -- Resolves against 'termination_reversal' module — configured separately
  -- from primary termination in Workflow → Assignments admin UI.
  v_template_id  := resolve_workflow_for_submission('termination_reversal', auth.uid());
  v_has_workflow := v_template_id IS NOT NULL;

  IF v_has_workflow THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ── 5. Insert DRAFT reversal row ──────────────────────────────────────────
  INSERT INTO employee_termination_reversals (
    termination_id, reversal_reason, comments,
    workflow_status, created_by, updated_by
  ) VALUES (
    p_termination_id, v_reversal_reason, v_comments,
    'DRAFT', auth.uid(), auth.uid()
  )
  RETURNING id INTO v_reversal_id;

  -- ── 6. Workflow path vs direct-save path ──────────────────────────────────
  IF v_has_workflow THEN
    -- module_code stays 'termination' so wf_sync_module_status routes correctly
    -- (it detects reversal vs termination by checking which table owns the record_id)
    v_instance_id := wf_submit(
      p_template_code => v_template_code,
      p_module_code   => 'termination',
      p_record_id     => v_reversal_id,
      p_metadata      => jsonb_build_object(
        'employee_id',     v_termination.employee_id,
        'termination_id',  p_termination_id,
        'reversal_reason', v_reversal_reason
      )
    );

    UPDATE employee_termination_reversals
    SET    workflow_status      = 'PENDING',
           workflow_instance_id = v_instance_id,
           updated_at           = NOW(),
           updated_by           = auth.uid()
    WHERE  id = v_reversal_id;

  ELSE
    -- No workflow assigned to 'termination_reversal' → direct-save: auto-APPROVED.
    -- apply-termination-reversal Edge Function handles slice reopening + status flip.
    UPDATE employee_termination_reversals
    SET    workflow_status = 'APPROVED',
           approved_at    = NOW(),
           approved_by    = auth.uid(),
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = v_reversal_id;

    UPDATE employee_terminations
    SET    workflow_status = 'REVERSED',
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = p_termination_id;
  END IF;

  -- ── 7. Attachments ────────────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_termination_attachments (
      reversal_id, file_name, original_file_name,
      file_path, file_size_bytes, mime_type, uploaded_by
    ) VALUES (
      v_reversal_id,
      v_att->>'file_name',
      COALESCE(v_att->>'original_file_name', v_att->>'file_name'),
      v_att->>'file_path',
      (v_att->>'file_size_bytes')::integer,
      v_att->>'mime_type',
      auth.uid()
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                   true,
    'reversal_id',          v_reversal_id,
    'workflow_instance_id', v_instance_id,
    'workflow_status',      CASE WHEN v_has_workflow THEN 'PENDING' ELSE 'APPROVED' END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination_reversal(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination_reversal(uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination_reversal(uuid, jsonb, jsonb) IS
  'Mig 489: initial version (hardcoded template_code=termination_reversal). '
  'Mig 492: changed to resolve_workflow_for_submission(''termination''). '
  'Mig 527: now resolves via ''termination_reversal'' module code — separately '
  'configurable in Workflow → Assignments from the primary termination workflow. '
  'p_module_code stays ''termination'' in wf_submit so wf_sync_module_status '
  'continues to route correctly via its table-existence check.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm 'termination_reversal' is now in module_codes
SELECT code, label FROM module_codes WHERE code IN ('termination', 'termination_reversal');
-- Expect: 2 rows

-- Confirm RPC now resolves via termination_reversal
SELECT prosrc LIKE '%termination_reversal%' AS uses_reversal_module
FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND p.proname = 'submit_termination_reversal';
-- Expect: true

-- =============================================================================
-- END OF MIGRATION 527
-- =============================================================================
