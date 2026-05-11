-- =============================================================================
-- Migration 093: workflow_steps — CC flag + notification template link
--
-- Adds two columns to workflow_steps:
--   is_cc                    boolean  — when true this step is notify-only;
--                                        no approval action, SLA, or skip
--   notification_template_id uuid     — optional override; NULL = system default
--
-- Also updates wf_add_step() to accept the new parameters.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. New columns
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE workflow_steps
  ADD COLUMN IF NOT EXISTS is_cc                    boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS notification_template_id uuid
    REFERENCES workflow_notification_templates (id) ON DELETE SET NULL;

COMMENT ON COLUMN workflow_steps.is_cc IS
  'When true this step is CC / notify-only. '
  'No approval action is required; SLA, escalation, and skip conditions do not apply.';

COMMENT ON COLUMN workflow_steps.notification_template_id IS
  'Optional notification template override for this step. '
  'NULL = use the system-default template (wf.task_assigned).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Update wf_add_step() to accept new params
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION wf_add_step(
  p_template_id              uuid,
  p_step_order               integer,
  p_name                     text,
  p_approver_type            text,
  p_approver_role            text    DEFAULT NULL,
  p_approver_profile_id      uuid    DEFAULT NULL,
  p_sla_hours                integer DEFAULT NULL,
  p_reminder_hours           integer DEFAULT NULL,
  p_escalation_hours         integer DEFAULT NULL,
  p_allow_delegation         boolean DEFAULT true,
  p_is_mandatory             boolean DEFAULT true,
  p_is_cc                    boolean DEFAULT false,
  p_notification_template_id uuid    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tpl     RECORD;
  v_step_id uuid;
BEGIN
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_add_step: permission denied';
  END IF;

  SELECT id, is_active INTO v_tpl FROM workflow_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_add_step: template % not found', p_template_id;
  END IF;

  -- Shift existing steps down if inserting mid-sequence
  UPDATE workflow_steps
  SET    step_order = step_order + 1
  WHERE  template_id = p_template_id
    AND  step_order  >= p_step_order;

  INSERT INTO workflow_steps (
    template_id, step_order, name, approver_type,
    approver_role, approver_profile_id,
    sla_hours, reminder_after_hours, escalation_after_hours,
    allow_delegation, is_mandatory,
    is_cc, notification_template_id
  ) VALUES (
    p_template_id, p_step_order, p_name, p_approver_type,
    p_approver_role, p_approver_profile_id,
    p_sla_hours, p_reminder_hours, p_escalation_hours,
    p_allow_delegation, p_is_mandatory,
    p_is_cc, p_notification_template_id
  )
  RETURNING id INTO v_step_id;

  RETURN v_step_id;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'new columns' AS check, column_name, data_type, column_default
FROM   information_schema.columns
WHERE  table_name = 'workflow_steps'
  AND  column_name IN ('is_cc', 'notification_template_id')
ORDER  BY ordinal_position;

-- =============================================================================
-- END OF MIGRATION 093
-- =============================================================================
