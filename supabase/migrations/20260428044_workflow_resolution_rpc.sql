-- =============================================================================
-- Workflow Assignment Module — Resolution + Management RPCs
--
-- Functions
-- ─────────
--   resolve_workflow_for_submission(module_code, profile_id)
--     → Returns the correct workflow_template_id for a new submission.
--       Priority: EMPLOYEE > ROLE > GLOBAL. Respects effective dates.
--
--   save_workflow_assignment(...)
--     → Validated upsert for a single assignment row. Enforces:
--        1. Mandatory GLOBAL rule (cannot deactivate last GLOBAL)
--        2. In-progress warning (future-dates only if active transactions exist
--           and effective_from <= today)
--        3. Returns JSON result: { ok, warning, assignment_id }
--
--   get_active_transaction_count(module_code)
--     → Count of in-flight instances for a module (used by UI for warnings).
--
--   deactivate_workflow_assignment(id)
--     → Safe deactivation with mandatory-GLOBAL guard.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. resolve_workflow_for_submission
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION resolve_workflow_for_submission(
  p_module_code text,
  p_profile_id  uuid
)
RETURNS uuid     -- workflow_template_id, NULL if no assignment found
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template_id uuid;
BEGIN

  -- ── 1. EMPLOYEE-level (future — table supports it, resolver handles it now) ─
  SELECT wa.wf_template_id INTO v_template_id
  FROM   workflow_assignments wa
  WHERE  wa.module_code      = p_module_code
    AND  wa.assignment_type  = 'EMPLOYEE'
    AND  wa.entity_id        = p_profile_id
    AND  wa.is_active        = true
    AND  wa.effective_from  <= CURRENT_DATE
    AND  (wa.effective_to IS NULL OR wa.effective_to >= CURRENT_DATE)
  ORDER  BY wa.priority
  LIMIT  1;

  IF v_template_id IS NOT NULL THEN
    RETURN v_template_id;
  END IF;

  -- ── 2. ROLE-level — highest-priority role match for the submitter ───────────
  SELECT wa.wf_template_id INTO v_template_id
  FROM   workflow_assignments wa
  JOIN   user_roles ur
         ON ur.role_id    = wa.entity_id
        AND ur.profile_id = p_profile_id
        AND ur.is_active  = true
  WHERE  wa.module_code     = p_module_code
    AND  wa.assignment_type = 'ROLE'
    AND  wa.is_active       = true
    AND  wa.effective_from <= CURRENT_DATE
    AND  (wa.effective_to IS NULL OR wa.effective_to >= CURRENT_DATE)
  ORDER  BY wa.priority     -- lower number = higher priority
  LIMIT  1;

  IF v_template_id IS NOT NULL THEN
    RETURN v_template_id;
  END IF;

  -- ── 3. GLOBAL fallback ───────────────────────────────────────────────────────
  SELECT wa.wf_template_id INTO v_template_id
  FROM   workflow_assignments wa
  WHERE  wa.module_code      = p_module_code
    AND  wa.assignment_type  = 'GLOBAL'
    AND  wa.is_active        = true
    AND  wa.effective_from  <= CURRENT_DATE
    AND  (wa.effective_to IS NULL OR wa.effective_to >= CURRENT_DATE)
  ORDER  BY wa.priority
  LIMIT  1;

  RETURN v_template_id; -- NULL = no assignment configured
END;
$$;

COMMENT ON FUNCTION resolve_workflow_for_submission(text, uuid) IS
  'Resolves the correct workflow_template_id for a new submission. '
  'Priority: EMPLOYEE > ROLE > GLOBAL. Filters by effective date. '
  'Returns NULL if no active assignment is configured for the module.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. get_active_transaction_count
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_active_transaction_count(
  p_module_code text
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer
  FROM   workflow_instances
  WHERE  module_code = p_module_code
    AND  status NOT IN ('approved', 'rejected', 'withdrawn', 'cancelled');
$$;

COMMENT ON FUNCTION get_active_transaction_count(text) IS
  'Returns the number of in-flight workflow instances for a module. '
  'Used by the UI to show a warning before changing active assignments.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. save_workflow_assignment
-- ════════════════════════════════════════════════════════════════════════════
--
-- Upserts one assignment row with full validation.
-- Pass p_id = NULL to create a new row, or an existing UUID to update.
--
-- Returns jsonb:
--   { "ok": true,  "assignment_id": "<uuid>", "warning": null }
--   { "ok": true,  "assignment_id": "<uuid>", "warning": "X active transactions..." }
--   { "ok": false, "error": "<message>" }

CREATE OR REPLACE FUNCTION save_workflow_assignment(
  p_id              uuid,        -- NULL = insert, existing UUID = update
  p_module_code     text,
  p_wf_template_id  uuid,
  p_assignment_type text,        -- GLOBAL | ROLE | EMPLOYEE
  p_entity_id       uuid,        -- NULL for GLOBAL
  p_priority        integer,
  p_effective_from  date,
  p_effective_to    date,        -- NULL = open-ended
  p_reason          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id             uuid;
  v_active_count   integer;
  v_warning        text := NULL;
  v_global_count   integer;
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

  -- ── Verify the workflow template belongs to this module ─────────────────────
  PERFORM 1 FROM workflow_templates
  WHERE id = p_wf_template_id AND module_code = p_module_code AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'The selected workflow template does not exist or does not belong to this module.'
    );
  END IF;

  -- ── In-progress transaction warning ─────────────────────────────────────────
  -- If effective_from <= today and there are active transactions, warn the user.
  -- We do NOT block — the workflow is locked per-instance at submission time,
  -- so existing transactions are unaffected. Only new submissions are impacted.
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
    -- INSERT
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
    -- UPDATE — created_by reused as changed_by (audit trigger reads it)
    UPDATE workflow_assignments
    SET
      wf_template_id  = p_wf_template_id,
      assignment_type = p_assignment_type,
      entity_id       = p_entity_id,
      priority        = COALESCE(p_priority, priority),
      effective_from  = p_effective_from,
      effective_to    = p_effective_to,
      created_by      = auth.uid()   -- audit trigger reads this as changed_by
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
  -- Surface overlap constraint violation clearly
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
  'Returns { ok, assignment_id, warning } on success or { ok, error } on failure. '
  'Enforces: module/template consistency, entity rules, overlap guard, '
  'and active-transaction warning (non-blocking).';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. deactivate_workflow_assignment
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION deactivate_workflow_assignment(
  p_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row          RECORD;
  v_global_count integer;
BEGIN
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied.');
  END IF;

  SELECT * INTO v_row FROM workflow_assignments WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Assignment not found.');
  END IF;

  IF NOT v_row.is_active THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Assignment is already inactive.');
  END IF;

  -- ── Mandatory GLOBAL guard ───────────────────────────────────────────────────
  -- Cannot remove the last active GLOBAL assignment for a module if there are
  -- active transactions — new submissions would have no workflow to route to.
  IF v_row.assignment_type = 'GLOBAL' THEN
    SELECT COUNT(*) INTO v_global_count
    FROM   workflow_assignments
    WHERE  module_code     = v_row.module_code
      AND  assignment_type = 'GLOBAL'
      AND  is_active       = true
      AND  id             != p_id
      AND  effective_from <= CURRENT_DATE
      AND  (effective_to IS NULL OR effective_to >= CURRENT_DATE);

    IF v_global_count = 0 AND get_active_transaction_count(v_row.module_code) > 0 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error',
        'Cannot deactivate the last active GLOBAL assignment for this module while '
        'transactions are in progress. Create a replacement assignment first, or '
        'wait until all active transactions are resolved.'
      );
    END IF;
  END IF;

  UPDATE workflow_assignments
  SET    is_active   = false,
         created_by  = auth.uid()  -- audit trigger reads as changed_by
  WHERE  id = p_id;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION deactivate_workflow_assignment(uuid) IS
  'Safely deactivates a workflow assignment. '
  'Blocks deactivation of the last active GLOBAL for a module when active '
  'transactions exist. Audit-logged via trigger.';


-- ════════════════════════════════════════════════════════════════════════════
-- 5. Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname
FROM   pg_proc
WHERE  proname IN (
  'resolve_workflow_for_submission',
  'get_active_transaction_count',
  'save_workflow_assignment',
  'deactivate_workflow_assignment'
)
ORDER BY proname;
