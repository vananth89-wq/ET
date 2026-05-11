-- =============================================================================
-- Migration 118: Decouple module_code from workflow_templates
--
-- DESIGN CHANGE
-- ─────────────
-- Previously, workflow_templates.module_code tied each template to exactly one
-- module at creation time. This prevented a single template from being reused
-- across multiple modules.
--
-- The correct design: module_code belongs only on workflow_assignments, which
-- is the join between a module and a template. Templates are now module-agnostic
-- reusable building blocks.
--
-- CHANGES
-- ───────
-- 1. workflow_templates.module_code → make nullable, NULL all existing rows.
--    The column is retained (not dropped) to avoid breaking existing FK
--    references and to allow a future soft re-use if needed.
--
-- 2. wf_submit() — remove the module_code mismatch guard.
--    The check `v_template.module_code != p_module_code` is no longer valid
--    since templates no longer carry a module. The module is passed in as
--    p_module_code by the caller and stored on workflow_instances — that is
--    the correct place for it.
--
-- 3. save_workflow_assignment() — remove the template-module match validation.
--    The line `AND module_code = p_module_code` in the template lookup blocked
--    assigning any template to a module other than its creation module.
--
-- SAFE FOR EXISTING DATA
-- ──────────────────────
-- workflow_instances.module_code is unchanged — instances are still scoped
-- to a module (set by p_module_code in wf_submit). Only the template itself
-- loses its module binding.
-- workflow_assignments.module_code is unchanged — still the authoritative link.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Make workflow_templates.module_code nullable + clear existing values
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE workflow_templates
  ALTER COLUMN module_code DROP NOT NULL;

-- Clear the module_code from all existing templates — they are now
-- module-agnostic and will be linked to modules via workflow_assignments.
UPDATE workflow_templates
SET    module_code = NULL;

COMMENT ON COLUMN workflow_templates.module_code IS
  'DEPRECATED — no longer used. Templates are module-agnostic. '
  'The module link is stored on workflow_assignments.module_code only.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Replace wf_submit — remove module_code mismatch guard
--
-- Only the validation block changes (lines ~920-934 of the original).
-- All other logic (step resolution, instance creation, notifications) is
-- identical to migration 030 / any subsequent patches.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_submit(
  p_template_code text,
  p_module_code   text,
  p_record_id     uuid,
  p_metadata      jsonb DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template    RECORD;
  v_first_step  RECORD;
  v_instance_id uuid;
  v_approver_id uuid;
  v_step        RECORD;
BEGIN
  -- ── Validate template (module_code check REMOVED) ─────────────────────────
  -- Templates are now module-agnostic; any active template can be used for
  -- any module. The module is tracked on workflow_instances, not the template.
  SELECT id, version, is_active
  INTO   v_template
  FROM   workflow_templates
  WHERE  code      = p_template_code
    AND  is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_submit: template % not found or inactive', p_template_code;
  END IF;

  -- ── Guard: no active workflow already running for this record ─────────────
  IF EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code = p_module_code
      AND  record_id   = p_record_id
      AND  status      = 'in_progress'
  ) THEN
    RAISE EXCEPTION 'wf_submit: an active workflow already exists for this record';
  END IF;

  -- ── Find first step (skip auto-skip steps) ────────────────────────────────
  SELECT ws.*
  INTO   v_first_step
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_template.id
    AND  ws.is_active   = true
    AND  NOT wf_evaluate_skip_step(ws.id, p_metadata)
  ORDER  BY ws.step_order
  LIMIT  1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_submit: no active steps found in template %', p_template_code;
  END IF;

  -- ── Create instance ───────────────────────────────────────────────────────
  INSERT INTO workflow_instances
    (template_id, template_version, module_code, record_id,
     submitted_by, current_step, status, metadata)
  VALUES
    (v_template.id, v_template.version, p_module_code, p_record_id,
     auth.uid(), v_first_step.step_order, 'in_progress', p_metadata)
  RETURNING id INTO v_instance_id;

  -- ── Resolve approver for step 1 ───────────────────────────────────────────
  v_approver_id := wf_resolve_approver(v_first_step.id, auth.uid());

  -- ── Create task for step 1 ────────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, status)
  VALUES
    (v_instance_id, v_first_step.id, v_first_step.step_order, v_approver_id, 'pending');

  -- ── Notify approver ───────────────────────────────────────────────────────
  PERFORM wf_notify(
    p_instance_id => v_instance_id,
    p_event       => 'submitted',
    p_step_id     => v_first_step.id,
    p_recipient   => v_approver_id
  );

  RETURN v_instance_id;
END;
$$;

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb) IS
  'Submits a new workflow instance for a record. '
  'Validates the template by code (module_code check removed — templates are now '
  'module-agnostic). Stores module_code on workflow_instances for scoping. '
  'Creates the first task and notifies the step-1 approver.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Replace save_workflow_assignment — remove template-module validation
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION save_workflow_assignment(
  p_id              uuid,
  p_module_code     text,
  p_wf_template_id  uuid,
  p_assignment_type text,
  p_entity_id       uuid,
  p_priority        integer,
  p_effective_from  date,
  p_effective_to    date,
  p_reason          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id           uuid;
  v_active_count integer;
  v_warning      text := NULL;
BEGIN
  -- ── Permission check ────────────────────────────────────────────────────────
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied: workflow.admin required.');
  END IF;

  -- ── Basic validations ───────────────────────────────────────────────────────
  IF p_module_code IS NULL OR p_wf_template_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'module_code and wf_template_id are required.');
  END IF;

  IF p_assignment_type NOT IN ('GLOBAL','ROLE','EMPLOYEE') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'assignment_type must be GLOBAL, ROLE, or EMPLOYEE.');
  END IF;

  IF p_assignment_type = 'GLOBAL' AND p_entity_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'GLOBAL assignments must not have an entity_id.');
  END IF;

  IF p_assignment_type != 'GLOBAL' AND p_entity_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ROLE and EMPLOYEE assignments require an entity_id.');
  END IF;

  IF p_effective_to IS NOT NULL AND p_effective_to < p_effective_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_to must be on or after effective_from.');
  END IF;

  -- ── Verify the template exists and is active ─────────────────────────────
  -- module_code check REMOVED — templates are now module-agnostic.
  -- Any active template can be assigned to any module.
  PERFORM 1 FROM workflow_templates
  WHERE id = p_wf_template_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'The selected workflow template does not exist or is not active.'
    );
  END IF;

  -- ── In-progress transaction warning ─────────────────────────────────────────
  IF p_effective_from <= CURRENT_DATE THEN
    v_active_count := get_active_transaction_count(p_module_code);
    IF v_active_count > 0 THEN
      v_warning := format(
        '%s transaction(s) are currently in approval for this module. '
        'They are unaffected — workflow is locked at submission time. '
        'Only new submissions from today will use this assignment.',
        v_active_count
      );
    END IF;
  END IF;

  -- ── Upsert ───────────────────────────────────────────────────────────────────
  IF p_id IS NULL THEN
    INSERT INTO workflow_assignments (
      module_code, wf_template_id, assignment_type, entity_id,
      priority, effective_from, effective_to, is_active, created_by
    )
    VALUES (
      p_module_code, p_wf_template_id, p_assignment_type, p_entity_id,
      COALESCE(p_priority, 0), p_effective_from, p_effective_to, true, auth.uid()
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE workflow_assignments
    SET
      wf_template_id  = p_wf_template_id,
      assignment_type = p_assignment_type,
      entity_id       = p_entity_id,
      priority        = COALESCE(p_priority, priority),
      effective_from  = p_effective_from,
      effective_to    = p_effective_to,
      created_by      = auth.uid()
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Assignment not found.');
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',            true,
    'assignment_id', v_id,
    'warning',       v_warning
  );

EXCEPTION WHEN OTHERS THEN
  IF SQLERRM ILIKE '%wa_no_overlap%' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error',
      'An active assignment already exists for this module, type, and entity '
      'covering that date range. Adjust the dates or deactivate the existing one first.'
    );
  END IF;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION save_workflow_assignment(uuid,text,uuid,text,uuid,integer,date,date,text) IS
  'Validated upsert for workflow_assignments. '
  'Templates are module-agnostic — any active template can be assigned to any module. '
  'Returns { ok, assignment_id, warning } on success or { ok, error } on failure. '
  'Enforces: entity rules, overlap guard, active-transaction warning (non-blocking).';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. Verification
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm module_code is now nullable on workflow_templates
SELECT column_name, is_nullable
FROM   information_schema.columns
WHERE  table_name   = 'workflow_templates'
  AND  column_name  = 'module_code'
  AND  table_schema = 'public';

-- Confirm no templates still have a module_code set
SELECT COUNT(*) AS templates_with_module_code
FROM   workflow_templates
WHERE  module_code IS NOT NULL;

SELECT proname
FROM   pg_proc
WHERE  proname IN ('wf_submit', 'save_workflow_assignment')
ORDER  BY proname;
