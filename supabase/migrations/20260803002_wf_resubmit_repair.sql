-- =============================================================================
-- Migration 803002 — Repair: remove broken 698 entry from schema_migrations
-- and re-apply the wf_resubmit fix (CREATE OR REPLACE is idempotent).
-- =============================================================================

-- Remove the broken/partial schema_migrations entry for 698

-- Re-apply the wf_resubmit fix (safe to re-run — CREATE OR REPLACE)
CREATE OR REPLACE FUNCTION wf_resubmit(
  p_instance_id   uuid,
  p_response      text  DEFAULT NULL,
  p_proposed_data jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance        RECORD;
  v_step1           RECORD;
  v_approver_id     uuid;
  v_due_at          timestamptz;
  v_new_task_id     uuid;
  v_submitter_name  text;
BEGIN
  SELECT id, submitted_by, status, current_step, template_id, module_code,
         record_id, metadata
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resubmit: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status != 'awaiting_clarification' THEN
    RAISE EXCEPTION 'wf_resubmit: instance is not awaiting clarification (status: %)',
                    v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    SELECT COALESCE(e.name, au.email, 'another user')
    INTO   v_submitter_name
    FROM   profiles p
    LEFT JOIN employees  e  ON e.id  = p.employee_id
    LEFT JOIN auth.users au ON au.id = p.id
    WHERE  p.id = v_instance.submitted_by;

    RAISE EXCEPTION
      'This record was submitted for approval by %. Only that person (or an admin) can resubmit it after it has been sent back for corrections.',
      COALESCE(v_submitter_name, 'another user')
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_proposed_data IS NOT NULL THEN
    UPDATE workflow_pending_changes
    SET    proposed_data = p_proposed_data,
           status        = 'pending',
           updated_at    = now()
    WHERE  instance_id   = p_instance_id
      AND  status        IN ('pending', 'needs_update');

    UPDATE workflow_instances
    SET    metadata   = metadata || p_proposed_data,
           updated_at = now()
    WHERE  id = p_instance_id;

    v_instance.metadata := v_instance.metadata || p_proposed_data;
  END IF;

  SELECT ws.id, ws.step_order, ws.name, ws.sla_hours
  INTO   v_step1
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_instance.template_id
    AND  ws.step_order  = 1
    AND  ws.is_active   = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resubmit: step 1 not found for template %',
                    v_instance.template_id;
  END IF;

  v_approver_id := wf_resolve_approver(v_step1.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'wf_resubmit: could not resolve an approver for step 1';
  END IF;

  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  UPDATE workflow_instances
  SET    status       = 'in_progress',
         current_step = 1,
         updated_at   = now()
  WHERE  id = p_instance_id;

  PERFORM wf_sync_module_status(
    v_instance.module_code,
    v_instance.record_id,
    'submitted'
  );

  v_due_at := CASE
    WHEN v_step1.sla_hours IS NOT NULL
    THEN now() + (v_step1.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (p_instance_id, v_step1.id, v_step1.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES (
    p_instance_id, v_new_task_id, auth.uid(),
    'resubmitted', 1,
    COALESCE(p_response, 'Submitter resubmitted after clarification.')
  );

  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.clarification_submitted',
    v_approver_id,
    jsonb_build_object(
      'response',  COALESCE(p_response, ''),
      'step_name', v_step1.name
    )
  );
END;
$$;

REVOKE ALL     ON FUNCTION wf_resubmit(uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION wf_resubmit(uuid, text, jsonb) TO authenticated;

COMMENT ON FUNCTION wf_resubmit(uuid, text, jsonb) IS
  'Mig 698 (via 803002): restored proposed_data + metadata UPDATEs dropped in mig 188.';
