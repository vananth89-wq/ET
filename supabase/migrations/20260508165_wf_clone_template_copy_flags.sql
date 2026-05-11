-- =============================================================================
-- Migration 165: Fix wf_clone_template — copy remove/skip duplicate flags
--
-- WHAT THIS MIGRATION DOES
-- ─────────────────────────
-- wf_clone_template (mig 032) uses an explicit column list that was written
-- before migrations 163 and 164 added:
--   workflow_templates.remove_duplicate_approver (mig 163)
--   workflow_templates.skip_duplicate_approver   (mig 164)
--
-- As a result, cloning a template silently resets both flags to their DEFAULT
-- (false), even if the source template had them enabled. The clone would behave
-- differently from the original without any warning.
--
-- This migration rewrites wf_clone_template to copy both flags from the source.
-- All other behaviour is unchanged.
--
-- FUNCTION CHANGES
-- ────────────────
-- wf_clone_template : INSERT now includes remove_duplicate_approver and
--                     skip_duplicate_approver, copied from v_src
-- =============================================================================


CREATE OR REPLACE FUNCTION wf_clone_template(p_template_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_src      RECORD;
  v_new_id   uuid;
  v_new_ver  integer;
BEGIN
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_clone_template: permission denied';
  END IF;

  SELECT * INTO v_src FROM workflow_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_clone_template: template % not found', p_template_id;
  END IF;

  -- Next version number for this code family
  SELECT COALESCE(MAX(version), 0) + 1
  INTO   v_new_ver
  FROM   workflow_templates
  WHERE  code = v_src.code;

  -- Insert draft clone (inactive) — copy all configuration flags from source
  INSERT INTO workflow_templates (
    code, name, description, module_code,
    is_active, version, parent_version,
    effective_from,
    remove_duplicate_approver,   -- mig 163
    skip_duplicate_approver      -- mig 164
  )
  VALUES (
    v_src.code, v_src.name, v_src.description, v_src.module_code,
    false, v_new_ver, v_src.version,
    v_src.effective_from,
    v_src.remove_duplicate_approver,
    v_src.skip_duplicate_approver
  )
  RETURNING id INTO v_new_id;

  -- Copy all steps from source template
  INSERT INTO workflow_steps (
    template_id, step_order, name,
    approver_type, approver_role, approver_profile_id,
    sla_hours, reminder_after_hours, escalation_after_hours,
    allow_delegation, is_mandatory, is_active
  )
  SELECT
    v_new_id, step_order, name,
    approver_type, approver_role, approver_profile_id,
    sla_hours, reminder_after_hours, escalation_after_hours,
    allow_delegation, is_mandatory, is_active
  FROM   workflow_steps
  WHERE  template_id = p_template_id
  ORDER  BY step_order;

  RETURN v_new_id;
END;
$$;

COMMENT ON FUNCTION wf_clone_template(uuid) IS
  'Forks a template into a new draft version (is_active=false). '
  'All steps are copied. Configuration flags (remove_duplicate_approver, '
  'skip_duplicate_approver) are copied from the source (mig 165). '
  'Returns the new template id. Use wf_publish_template() to activate the clone.';


-- ════════════════════════════════════════════════════════════════════════════
-- Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname, prosrc
FROM   pg_proc
WHERE  proname = 'wf_clone_template';

-- =============================================================================
-- END OF MIGRATION 165
-- =============================================================================
