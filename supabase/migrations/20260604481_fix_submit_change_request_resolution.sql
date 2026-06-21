-- =============================================================================
-- Migration 481 — Fix submit_change_request workflow resolution
--
-- BUG: Mig 364 rewrote submit_change_request and replaced the correct
-- resolution path (resolve_workflow_for_submission → workflow_assignments)
-- with a direct query on workflow_templates.module_code. Since workflow
-- templates don't carry a module_code column — that relationship lives in
-- workflow_assignments — the lookup always returned NULL, blocking every
-- submit_change_request call regardless of how the admin UI was configured.
--
-- FIX: Restore the resolution block from mig 046–354:
--   v_template_id := resolve_workflow_for_submission(p_module_code, auth.uid())
-- Everything else (CASE snapshot branches, INSERT, wf_submit call) is
-- identical to mig 397.
--
-- Affected migrations:
--   364 (introduced regression), 397 (inherited it)
-- Working baseline: mig 354 (resolution block) + mig 397 (CASE branches)
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_change_request(
  p_module_code   text,
  p_record_id     uuid    DEFAULT NULL,
  p_proposed_data jsonb   DEFAULT '{}',
  p_action        text    DEFAULT 'update',
  p_comment       text    DEFAULT NULL
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
  -- ── Basic validation ────────────────────────────────────────────────────────
  IF p_module_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'module_code is required.');
  END IF;

  IF p_module_code = 'expense_reports' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Use submit_expense() for expense_reports, not submit_change_request().'
    );
  END IF;

  -- ── Resolve caller's employee_id ────────────────────────────────────────────
  SELECT p.employee_id
  INTO   v_emp_id
  FROM   profiles p
  WHERE  p.id = auth.uid();

  -- ── Resolve workflow via assignment table (RESTORED from mig 046–354) ────────
  -- Mig 364 broke this by querying workflow_templates.module_code directly,
  -- which bypassed workflow_assignments entirely. workflow_templates has no
  -- module_code column — the assignment relationship lives in workflow_assignments.
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

  -- ── Snapshot current data for diff display ──────────────────────────────────
  IF v_emp_id IS NOT NULL AND p_action = 'update' THEN

    CASE p_module_code

      WHEN 'profile_personal' THEN
        SELECT to_jsonb(ep.*)
        INTO   v_current_row
        FROM   employee_personal ep
        WHERE  ep.employee_id  = v_emp_id
          AND  ep.effective_to = '9999-12-31'::date
          AND  ep.is_active    = true;

      WHEN 'profile_employment' THEN
        SELECT to_jsonb(ee.*)
        INTO   v_current_row
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
          SELECT to_jsonb(ee.*)
          INTO   v_current_row
          FROM   employee_education ee
          WHERE  ee.id        = p_record_id
            AND  ee.is_active = true;
        END IF;

      WHEN 'profile_contact' THEN
        SELECT to_jsonb(ec.*)
        INTO   v_current_row
        FROM   employee_contact ec
        WHERE  ec.employee_id = v_emp_id;

      WHEN 'profile_address' THEN
        SELECT to_jsonb(ea.*)
        INTO   v_current_row
        FROM   employee_addresses ea
        WHERE  ea.employee_id = v_emp_id;

      WHEN 'profile_passport' THEN
        SELECT to_jsonb(pp.*)
        INTO   v_current_row
        FROM   passports pp
        WHERE  pp.employee_id = v_emp_id;

      WHEN 'profile_identification' THEN
        SELECT to_jsonb(ir.*)
        INTO   v_current_row
        FROM   identity_records ir
        WHERE  ir.employee_id = v_emp_id;

      WHEN 'profile_emergency_contact' THEN
        SELECT to_jsonb(emg.*)
        INTO   v_current_row
        FROM   emergency_contacts emg
        WHERE  emg.employee_id = v_emp_id
        ORDER  BY emg.created_at
        LIMIT  1;

      ELSE
        NULL;

    END CASE;

    -- Filter snapshot to only keys present in proposed_data
    IF v_current_row IS NOT NULL THEN
      v_current_data := '{}'::jsonb;
      FOR v_key IN SELECT jsonb_object_keys(p_proposed_data) LOOP
        IF v_current_row ? v_key THEN
          v_current_data := v_current_data || jsonb_build_object(v_key, v_current_row->v_key);
        END IF;
      END LOOP;
    END IF;

  END IF;

  -- ── Create the pending change record ────────────────────────────────────────
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

  -- ── Submit to workflow engine ────────────────────────────────────────────────
  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => p_module_code,
    p_record_id     => v_pending_id,
    p_metadata      => COALESCE(p_proposed_data, '{}'),
    p_comment       => NULLIF(trim(COALESCE(p_comment, '')), '')
  );

  -- ── Link instance back to pending change ─────────────────────────────────────
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

COMMENT ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) IS
  'Stages a profile field change for workflow approval. '
  'Resolves the active workflow assignment via resolve_workflow_for_submission() '
  '(queries workflow_assignments, not workflow_templates directly). '
  'Snapshots the current satellite row into current_data (filtered to proposed_data keys). '
  'Mig 354: added profile_employment snapshot branch. '
  'Mig 364: added profile_job_relationships snapshot branch (also introduced resolution regression). '
  'Mig 397: added profile_education snapshot branch. '
  'Mig 481: restored correct resolve_workflow_for_submission() resolution (fixes mig 364 regression).';

REVOKE ALL     ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) TO authenticated;


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm the function body now references resolve_workflow_for_submission
-- and NOT a direct workflow_templates.module_code query
SELECT
  proname,
  prosrc LIKE '%resolve_workflow_for_submission%' AS uses_correct_resolver,
  prosrc LIKE '%t.module_code = p_module_code%'   AS has_broken_resolver
FROM pg_proc
WHERE proname = 'submit_change_request';

-- =============================================================================
-- END OF MIGRATION 481
-- =============================================================================
