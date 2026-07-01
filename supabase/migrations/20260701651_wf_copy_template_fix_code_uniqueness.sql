-- =============================================================================
-- Migration 651 — wf_copy_template: fix code uniqueness check
--
-- Bug: uniqueness guard only checked workflow_assignments. But workflow_templates
-- has a (code, version) unique constraint, so inserting version 1 with an
-- existing code fails with a DB constraint error before the application-level
-- error could be returned.
--
-- Fix: check workflow_templates for the code first, then workflow_assignments.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_copy_template(
  p_source_id      uuid,
  p_name           text,
  p_code           text,
  p_description    text    DEFAULT NULL,
  p_effective_from date    DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_src_code       text;
  v_active_tpl_id  uuid;
  v_new_tpl_id     uuid;
BEGIN
  -- ── 1. Permission ──────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied: workflow.admin required.');
  END IF;

  -- ── 2. Resolve source code ────────────────────────────────────────────────
  SELECT code INTO v_src_code
  FROM   workflow_templates
  WHERE  id = p_source_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Source template not found.');
  END IF;

  -- ── 3. Find active version for that code ─────────────────────────────────
  SELECT id INTO v_active_tpl_id
  FROM   workflow_templates
  WHERE  code      = v_src_code
    AND  is_active = true
  ORDER  BY version DESC
  LIMIT  1;

  IF v_active_tpl_id IS NULL THEN
    v_active_tpl_id := p_source_id;
  END IF;

  -- ── 4. Guard: new code must not exist in templates OR assignments ─────────
  IF EXISTS (SELECT 1 FROM workflow_templates   WHERE code        = p_code)
  OR EXISTS (SELECT 1 FROM workflow_assignments WHERE module_code = p_code)
  THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Module code "%s" is already in use. Choose a different code.', p_code));
  END IF;

  -- ── 5. Create new template (draft, version 1) ─────────────────────────────
  INSERT INTO workflow_templates (
    name, code, description, version, is_active,
    skip_duplicate_approver, remove_duplicate_approver,
    published_at, parent_version
  )
  SELECT
    p_name,
    p_code,
    COALESCE(p_description, description),
    1,
    false,
    skip_duplicate_approver,
    remove_duplicate_approver,
    NULL,
    NULL
  FROM workflow_templates
  WHERE id = v_active_tpl_id
  RETURNING id INTO v_new_tpl_id;

  -- ── 6. Copy steps verbatim ────────────────────────────────────────────────
  INSERT INTO workflow_steps (
    template_id, step_order, name, approver_type, approver_profile_id,
    approver_role, is_mandatory, is_active, is_cc, approval_mode,
    delegation_allowed
  )
  SELECT
    v_new_tpl_id, step_order, name, approver_type, approver_profile_id,
    approver_role, is_mandatory, is_active, is_cc, approval_mode,
    delegation_allowed
  FROM workflow_steps
  WHERE template_id = v_active_tpl_id
  ORDER BY step_order;

  -- ── 7. Create workflow assignment ─────────────────────────────────────────
  INSERT INTO workflow_assignments (
    module_code, wf_template_id, is_active, effective_from, effective_to
  ) VALUES (
    p_code, v_new_tpl_id, false, p_effective_from, NULL
  );

  RETURN jsonb_build_object('ok', true, 'template_id', v_new_tpl_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION wf_copy_template(uuid, text, text, text, date) TO authenticated;

COMMENT ON FUNCTION wf_copy_template IS
  'Mig 651: copies active template to new module code as draft v1. '
  'Guards against code collision in both workflow_templates and workflow_assignments.';
