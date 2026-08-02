-- =============================================================================
-- Migration 697 — submit_change_request: block duplicate submissions
--
-- BUG
-- ═══
-- Employee submits profile change → workflow_pending_changes row #1 + instance #1
-- Approver sends back for clarification → instance #1 status = 'awaiting_clarification'
-- Employee opens the section from MyProfile and clicks Save again with new data
--   → savePersonal / saveContact / etc. calls submit_change_request
--   → submit_change_request UNCONDITIONALLY INSERTs a new pending row #2 + instance #2
-- Approver clicks their notification link → still tied to instance #1 → sees OLD data
--
-- The sanctioned resubmit path (SentBackDetailPanel → wf_resubmit) correctly
-- OVERWRITES the same wpc row's proposed_data. But MyProfile's Save bypasses
-- it, and useProfileWorkflowGates's client-side pendingCounts check can be
-- stale (no realtime subscription) — a window/tab race lets duplicates through.
--
-- FIX
-- ═══
-- Add a DB-side guard at the top of submit_change_request: if there's already
-- an active pending change (status pending/needs_update) for the same
-- (module_code, record_id, submitted_by) with the workflow_instance still
-- open (in_progress or awaiting_clarification), refuse the insert and return
-- an error directing the user to the Sent Back inbox.
--
-- This affects ALL workflow-gated modules that call submit_change_request:
--   profile_personal, profile_contact, profile_employment, profile_address,
--   profile_passport, profile_identification, profile_emergency_contact,
--   profile_bank, profile_dependents, profile_job_relationships,
--   profile_education, and any future ones.
--
-- Existing duplicate rows on Dev/UAT are NOT touched by this migration —
-- data cleanup is a separate task per instance.
--
-- Body copied verbatim from mig 570 with only the guard block added at
-- the top of the function.
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_change_request(
  p_module_code          text,
  p_record_id            uuid    DEFAULT NULL,
  p_proposed_data        jsonb   DEFAULT '{}',
  p_action               text    DEFAULT 'update',
  p_comment              text    DEFAULT NULL,
  p_subject_employee_id  uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id        uuid;
  v_template_id   uuid;
  v_template_code text;
  v_pending_id    uuid;
  v_instance_id   uuid;
  v_current_row   jsonb   := NULL;
  v_current_data  jsonb   := NULL;
  v_key           text;
BEGIN
  IF p_module_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'module_code is required.');
  END IF;

  IF p_module_code = 'expense_reports' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Use submit_expense() for expense_reports, not submit_change_request().'
    );
  END IF;

  -- ── MIG 697 GUARD: block duplicate submissions ─────────────────────────────
  -- If an active pending change already exists for the same
  -- (module_code, record_id, submitted_by) and its instance is still open
  -- (in_progress or awaiting_clarification), refuse and point the user to
  -- the Sent Back inbox where they can properly update via wf_resubmit.
  IF EXISTS (
    SELECT 1
    FROM   workflow_pending_changes wpc
    JOIN   workflow_instances       wi ON wi.id = wpc.instance_id
    WHERE  wpc.module_code   = p_module_code
      AND  wpc.record_id     IS NOT DISTINCT FROM p_record_id
      AND  wpc.submitted_by  = auth.uid()
      AND  wpc.status        IN ('pending', 'needs_update')
      AND  wi.status         IN ('in_progress', 'awaiting_clarification')
  ) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'DUPLICATE_PENDING_CHANGE',
      'message',
      'An active change request already exists for this record. '
      || 'Please update and resubmit it from the Sent Back inbox '
      || 'instead of creating a new one.'
    );
  END IF;

  -- ── Resolve employee_id for snapshot: subject if supplied, else caller ───
  IF p_subject_employee_id IS NOT NULL THEN
    v_emp_id := p_subject_employee_id;
  ELSE
    SELECT p.employee_id INTO v_emp_id
    FROM   profiles p
    WHERE  p.id = auth.uid();
  END IF;

  v_template_id := resolve_workflow_for_submission(p_module_code, auth.uid());

  IF v_template_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', format(
        'No active workflow assignment found for module "%s". '
        'Ask your administrator to configure one in Workflow → Assignments.',
        p_module_code
      )
    );
  END IF;

  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_template_id;

  -- ── Snapshot current data for diff display ────────────────────────────────
  IF v_emp_id IS NOT NULL AND p_action = 'update' THEN
    CASE p_module_code
      WHEN 'profile_personal' THEN
        SELECT to_jsonb(ep.*) INTO v_current_row
        FROM   employee_personal ep
        WHERE  ep.employee_id  = v_emp_id
          AND  ep.effective_to = '9999-12-31'::date
          AND  ep.is_active    = true;

      WHEN 'profile_employment' THEN
        SELECT to_jsonb(ee.*) INTO v_current_row
        FROM   employee_employment ee
        WHERE  ee.employee_id  = v_emp_id
          AND  ee.effective_to = '9999-12-31'::date
          AND  ee.is_active    = true;

      WHEN 'profile_job_relationships' THEN
        SELECT jsonb_build_object(
          'set_id',         s.id,
          'effective_from', s.effective_from,
          'items',          COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'relationship_code',    i.relationship_code,
              'manager_employee_id',  i.manager_employee_id
            ))
            FROM employee_job_relationship_item i
            WHERE i.set_id = s.id
          ), '[]'::jsonb)
        )
        INTO v_current_row
        FROM employee_job_relationship_set s
        WHERE s.employee_id  = v_emp_id
          AND s.is_active    = true
          AND s.effective_to = '9999-12-31'::date;

      WHEN 'profile_education' THEN
        IF p_record_id IS NOT NULL THEN
          SELECT to_jsonb(ee.*) INTO v_current_row
          FROM   employee_education ee
          WHERE  ee.id        = p_record_id
            AND  ee.is_active = true;
        END IF;

      WHEN 'profile_contact' THEN
        SELECT to_jsonb(ec.*) INTO v_current_row
        FROM   employee_contact ec
        WHERE  ec.employee_id = v_emp_id;

      WHEN 'profile_address' THEN
        SELECT to_jsonb(ea.*) INTO v_current_row
        FROM   employee_addresses ea
        WHERE  ea.employee_id = v_emp_id;

      WHEN 'profile_passport' THEN
        SELECT to_jsonb(pp.*) INTO v_current_row
        FROM   passports pp
        WHERE  pp.employee_id = v_emp_id;

      WHEN 'profile_identification' THEN
        SELECT to_jsonb(ir.*) INTO v_current_row
        FROM   identity_records ir
        WHERE  ir.employee_id = v_emp_id;

      WHEN 'profile_emergency_contact' THEN
        SELECT to_jsonb(emg.*) INTO v_current_row
        FROM   emergency_contacts emg
        WHERE  emg.employee_id = v_emp_id
        ORDER  BY emg.created_at
        LIMIT  1;

      ELSE
        NULL;
    END CASE;

    IF v_current_row IS NOT NULL THEN
      v_current_data := '{}'::jsonb;
      FOR v_key IN SELECT jsonb_object_keys(p_proposed_data) LOOP
        IF v_current_row ? v_key THEN
          v_current_data := v_current_data || jsonb_build_object(v_key, v_current_row->v_key);
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- ── Create the pending change record ──────────────────────────────────────
  INSERT INTO workflow_pending_changes (
    module_code, record_id, action, proposed_data, current_data, submitted_by
  ) VALUES (
    p_module_code,
    p_record_id,
    p_action,
    COALESCE(p_proposed_data, '{}'),
    v_current_data,
    auth.uid()
  )
  RETURNING id INTO v_pending_id;

  v_instance_id := wf_submit(
    p_template_code       => v_template_code,
    p_module_code         => p_module_code,
    p_record_id           => v_pending_id,
    p_metadata            => COALESCE(p_proposed_data, '{}'),
    p_comment             => NULLIF(trim(COALESCE(p_comment, '')), ''),
    p_subject_employee_id => p_subject_employee_id
  );

  UPDATE workflow_pending_changes
  SET    instance_id = v_instance_id
  WHERE  id = v_pending_id;

  RETURN jsonb_build_object(
    'ok',          true,
    'pending_id',  v_pending_id,
    'instance_id', v_instance_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_change_request(text, uuid, jsonb, text, text, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_change_request(text, uuid, jsonb, text, text, uuid) TO authenticated;

COMMENT ON FUNCTION submit_change_request(text, uuid, jsonb, text, text, uuid) IS
  'Stages a profile field change for workflow approval. '
  'Mig 481: fixed workflow resolution via resolve_workflow_for_submission. '
  'Mig 570: p_subject_employee_id — HR-on-behalf-of support. '
  'Mig 697: guard against duplicate pending changes (send-back race). '
  'Callers with an active pending change must use wf_resubmit instead.';
