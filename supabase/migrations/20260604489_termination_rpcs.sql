-- =============================================================================
-- Migration 489 — Termination Module: RPCs (Phase 2)
--
-- Functions:
--   1. derive_termination_initiation_type(p_employee_id, p_is_bulk)
--   2. submit_termination(p_employee_id, p_termination_data, p_attachments)
--   3. submit_termination_reversal(p_termination_id, p_reversal_data, p_attachments)
--   4. withdraw_termination(p_termination_id)
--   5. withdraw_termination_reversal(p_reversal_id)
--   6. get_employee_terminations(p_employee_id)
--   7. get_termination_history(p_employee_id, p_include_reversed)
--   8. get_termination_deactivation_impact(p_employee_id)
--
-- Workflow template codes (seeded in Phase 3 / mig 490):
--   'termination_self'     — SELF path (MANAGER → HR_APPROVER → FINAL_APPROVER)
--   'termination_hr'       — HR/Admin path (HR_MANAGER → FINAL_APPROVER)
--   'termination_reversal' — Reversal path (HR_MANAGER → FINAL_APPROVER)
--
-- NOTE: submit_termination calls wf_submit which requires workflow templates.
-- Read RPCs (6-8) and withdraw RPCs (4-5) are independently testable now.
-- submit_termination / submit_termination_reversal require Phase 3 to be applied first.
--
-- Design spec: docs/termination-design.md §3
-- Predecessor: 20260604484 (picklists + permissions)
-- Next migration: 20260604490 (workflow integration — Phase 3)
-- =============================================================================


-- =============================================================================
-- 1. derive_termination_initiation_type
--    §3.5 — helper used by submit_termination and upsert_termination_bulk
-- =============================================================================

CREATE OR REPLACE FUNCTION derive_termination_initiation_type(
  p_employee_id uuid,
  p_is_bulk     boolean DEFAULT false
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_employee_id uuid;
BEGIN
  -- Bulk import → always SYSTEM_INITIATED
  IF p_is_bulk THEN
    RETURN 'SYSTEM_INITIATED';
  END IF;

  -- Caller is the subject employee → SELF (regardless of role)
  v_my_employee_id := get_my_employee_id();
  IF v_my_employee_id = p_employee_id THEN
    RETURN 'SELF';
  END IF;

  -- HR role → HR_INITIATED
  IF user_can('termination', 'edit', NULL)
     AND EXISTS (
       SELECT 1 FROM profiles p
       JOIN user_roles ur ON ur.profile_id = p.id
       JOIN roles r       ON r.id = ur.role_id
       WHERE p.id = auth.uid()
         AND r.name ILIKE '%HR%'
     )
  THEN
    RETURN 'HR_INITIATED';
  END IF;

  -- Admin/super-admin → ADMIN_INITIATED
  IF user_can('termination', 'edit', NULL) THEN
    RETURN 'ADMIN_INITIATED';
  END IF;

  RAISE EXCEPTION 'Insufficient privilege to initiate termination for this employee.'
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

REVOKE ALL     ON FUNCTION derive_termination_initiation_type(uuid, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION derive_termination_initiation_type(uuid, boolean) TO authenticated;


-- =============================================================================
-- 2. submit_termination
--    §3.1 — main submission RPC
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_termination(
  p_employee_id      uuid,
  p_termination_data jsonb,
  p_attachments      jsonb DEFAULT '[]'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Initiation
  v_initiation_type       text;
  v_template_code         text;

  -- Payload fields
  v_termination_date      date;
  v_reason_code           text;
  v_resignation_date      date;
  v_notice_date           date;
  v_last_working_date     date;
  v_waived                boolean;
  v_waiver_reason         text;
  v_eligible_for_rehire   boolean;
  v_regrettable           boolean;
  v_comments              text;

  -- Notice period
  v_notice_period_days    integer;
  v_required_lwd          date;

  -- Picklist validation
  v_picklist_code         text;
  v_reason_valid          boolean;

  -- Workflow
  v_termination_id        uuid;
  v_instance_id           uuid;

  -- Attachment
  v_att                   jsonb;
BEGIN

  -- ── 1. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('termination', 'edit', p_employee_id)
    OR user_can('termination', 'edit', NULL)
    OR get_my_employee_id() = p_employee_id   -- self-service
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- ── 2. Extract payload ─────────────────────────────────────────────────────
  v_termination_date    := NULLIF(p_termination_data->>'termination_date', '')::date;
  v_reason_code         := NULLIF(p_termination_data->>'termination_reason_code', '');
  v_resignation_date    := NULLIF(p_termination_data->>'resignation_date', '')::date;
  v_notice_date         := NULLIF(p_termination_data->>'notice_date', '')::date;
  v_last_working_date   := NULLIF(p_termination_data->>'last_working_date', '')::date;
  v_waived              := COALESCE((p_termination_data->>'notice_period_waived')::boolean, false);
  v_waiver_reason       := NULLIF(p_termination_data->>'notice_period_waiver_reason', '');
  v_eligible_for_rehire := COALESCE((p_termination_data->>'eligible_for_rehire')::boolean, true);
  v_regrettable         := (p_termination_data->>'regrettable_termination')::boolean;
  v_comments            := NULLIF(p_termination_data->>'comments', '');

  -- ── 3. Required field validation ───────────────────────────────────────────
  IF v_termination_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_date is required.');
  END IF;
  IF v_reason_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_reason_code is required.');
  END IF;
  IF v_comments IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments is required.');
  END IF;
  IF length(v_comments) < 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 20 characters.');
  END IF;
  IF v_reason_code = 'OTHER' AND length(v_comments) < 50 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 50 characters when reason is OTHER.');
  END IF;

  -- ── 4. Derive initiation type ──────────────────────────────────────────────
  BEGIN
    v_initiation_type := derive_termination_initiation_type(p_employee_id, false);
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: cannot initiate termination.');
  END;

  -- ── 5. Picklist validation (§1 decision #11) ───────────────────────────────
  -- SELF → RESIGNATION_REASON; HR/Admin → TERMINATION_REASON
  v_picklist_code := CASE
    WHEN v_initiation_type = 'SELF' THEN 'RESIGNATION_REASON'
    ELSE 'TERMINATION_REASON'
  END;

  SELECT EXISTS (
    SELECT 1 FROM picklist_values pv
    JOIN picklists pl ON pl.id = pv.picklist_id
    WHERE pl.picklist_id = v_picklist_code
      AND pv.ref_id      = v_reason_code
      AND pv.active      = true
  ) INTO v_reason_valid;

  IF NOT v_reason_valid THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format('termination_reason_code %s is not valid for picklist %s.',
                      v_reason_code, v_picklist_code)
    );
  END IF;

  -- ── 6. SELF-specific validations ───────────────────────────────────────────
  IF v_initiation_type = 'SELF' THEN
    IF v_resignation_date IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'resignation_date is required for self-service termination.');
    END IF;
    IF v_last_working_date IS NOT NULL AND v_last_working_date < v_resignation_date THEN
      RETURN jsonb_build_object('ok', false, 'error', 'last_working_date must be on or after resignation_date.');
    END IF;
  END IF;

  -- ── 7. Read notice_period_days from the employment slice covering termination_date ──
  SELECT notice_period_days INTO v_notice_period_days
  FROM   employee_employment
  WHERE  employee_id   = p_employee_id
    AND  effective_from <= v_termination_date
    AND  effective_to   >  v_termination_date
    AND  is_active      = true
  ORDER  BY effective_from DESC
  LIMIT  1;

  IF v_notice_period_days IS NULL THEN
    -- Fallback: try the open-ended current slice
    SELECT notice_period_days INTO v_notice_period_days
    FROM   employee_employment
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
    LIMIT 1;
  END IF;

  IF v_notice_period_days IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'No active employment record found covering the termination date.');
  END IF;

  -- ── 8. Notice period validation (§1 decisions #12) ────────────────────────
  IF v_initiation_type = 'SELF' AND v_last_working_date IS NOT NULL THEN
    -- Self-service: hard block if LWD is before resignation_date + notice_period_days
    v_required_lwd := v_resignation_date + v_notice_period_days;
    IF v_last_working_date < v_required_lwd THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', format(
          'last_working_date must be on or after %s (resignation_date + %s notice days).',
          v_required_lwd, v_notice_period_days
        )
      );
    END IF;
  ELSIF v_initiation_type <> 'SELF' AND v_last_working_date IS NOT NULL THEN
    -- HR/Admin: auto-waive if LWD < termination_date + notice_period_days
    v_required_lwd := v_termination_date + v_notice_period_days;
    IF v_last_working_date < v_required_lwd THEN
      v_waived := true;
      IF v_waiver_reason IS NULL THEN
        RETURN jsonb_build_object(
          'ok', false,
          'error', format(
            'notice_period_waiver_reason is required: last_working_date is before %s (termination_date + %s notice days).',
            v_required_lwd, v_notice_period_days
          )
        );
      END IF;
    END IF;
  END IF;

  -- ── 9. Strip HR-only fields from SELF submissions ─────────────────────────
  IF v_initiation_type = 'SELF' THEN
    v_eligible_for_rehire := true;   -- force default
    v_regrettable         := NULL;   -- not applicable
  END IF;

  -- ── 10. Insert DRAFT termination row ──────────────────────────────────────
  INSERT INTO employee_terminations (
    employee_id,
    termination_date,
    termination_reason_code,
    termination_initiation_type,
    resignation_date,
    notice_date,
    last_working_date,
    notice_period_waived,
    notice_period_waiver_reason,
    eligible_for_rehire,
    regrettable_termination,
    comments,
    workflow_status,
    created_by,
    updated_by
  ) VALUES (
    p_employee_id,
    v_termination_date,
    v_reason_code,
    v_initiation_type,
    v_resignation_date,
    v_notice_date,
    v_last_working_date,
    v_waived,
    v_waiver_reason,
    v_eligible_for_rehire,
    v_regrettable,
    v_comments,
    'DRAFT',
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_termination_id;

  -- ── 11. Submit to workflow ─────────────────────────────────────────────────
  v_template_code := CASE v_initiation_type
    WHEN 'SELF' THEN 'termination_self'
    ELSE 'termination_hr'
  END;

  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => 'termination',
    p_record_id     => v_termination_id,
    p_metadata      => jsonb_build_object(
      'employee_id',          p_employee_id,
      'termination_date',     v_termination_date,
      'initiation_type',      v_initiation_type
    )
  );

  -- ── 12. Flip workflow_status to PENDING and store instance_id ─────────────
  UPDATE employee_terminations
  SET    workflow_status      = 'PENDING',
         workflow_instance_id = v_instance_id,
         updated_at           = NOW(),
         updated_by           = auth.uid()
  WHERE  id = v_termination_id;

  -- ── 13. Insert attachments ─────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_termination_attachments (
      termination_id,
      file_name,
      original_file_name,
      file_path,
      file_size_bytes,
      mime_type,
      uploaded_by
    ) VALUES (
      v_termination_id,
      v_att->>'file_name',
      COALESCE(v_att->>'original_file_name', v_att->>'file_name'),
      v_att->>'file_path',
      (v_att->>'file_size_bytes')::integer,
      v_att->>'mime_type',
      auth.uid()
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                  true,
    'termination_id',      v_termination_id,
    'workflow_instance_id', v_instance_id,
    'workflow_status',     'PENDING'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination(uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination(uuid, jsonb, jsonb) IS
  'Mig 489: submit a termination transaction. Derives initiation type, validates picklist '
  'and notice period, inserts DRAFT row, calls wf_submit, flips to PENDING. '
  'Requires workflow templates from Phase 3 (mig 490) before testing the submit path.';


-- =============================================================================
-- 3. submit_termination_reversal
--    §3.2 — original termination must be APPROVED
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
  v_att             jsonb;
BEGIN

  -- ── 1. Load and validate the parent termination ────────────────────────────
  SELECT * INTO v_termination
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found.');
  END IF;

  IF v_termination.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'Only APPROVED terminations can be reversed. Current status: '
               || v_termination.workflow_status || '.');
  END IF;

  -- ── 2. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('termination', 'edit', v_termination.employee_id)
    OR user_can('termination', 'edit', NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- ── 3. Extract and validate payload ───────────────────────────────────────
  v_reversal_reason := NULLIF(p_reversal_data->>'reversal_reason', '');
  v_comments        := NULLIF(p_reversal_data->>'comments', '');

  IF v_reversal_reason IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reversal_reason is required.');
  END IF;
  IF v_comments IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments is required.');
  END IF;
  IF length(v_comments) < 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 20 characters.');
  END IF;

  -- ── 4. Insert DRAFT reversal row ───────────────────────────────────────────
  INSERT INTO employee_termination_reversals (
    termination_id,
    reversal_reason,
    comments,
    workflow_status,
    created_by,
    updated_by
  ) VALUES (
    p_termination_id,
    v_reversal_reason,
    v_comments,
    'DRAFT',
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_reversal_id;

  -- ── 5. Submit to workflow ─────────────────────────────────────────────────
  v_instance_id := wf_submit(
    p_template_code => 'termination_reversal',
    p_module_code   => 'termination',
    p_record_id     => v_reversal_id,
    p_metadata      => jsonb_build_object(
      'employee_id',     v_termination.employee_id,
      'termination_id',  p_termination_id,
      'reversal_reason', v_reversal_reason
    )
  );

  -- ── 6. Flip to PENDING ─────────────────────────────────────────────────────
  UPDATE employee_termination_reversals
  SET    workflow_status      = 'PENDING',
         workflow_instance_id = v_instance_id,
         updated_at           = NOW(),
         updated_by           = auth.uid()
  WHERE  id = v_reversal_id;

  -- ── 7. Insert attachments ──────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_termination_attachments (
      reversal_id,
      file_name,
      original_file_name,
      file_path,
      file_size_bytes,
      mime_type,
      uploaded_by
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
    'ok',                  true,
    'reversal_id',         v_reversal_id,
    'workflow_instance_id', v_instance_id,
    'workflow_status',     'PENDING'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination_reversal(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination_reversal(uuid, jsonb, jsonb) TO authenticated;


-- =============================================================================
-- 4. withdraw_termination
--    §3.3 — only while workflow_status = 'PENDING'
-- =============================================================================

CREATE OR REPLACE FUNCTION withdraw_termination(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_termination employee_terminations%ROWTYPE;
BEGIN
  SELECT * INTO v_termination
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found.');
  END IF;

  IF v_termination.workflow_status <> 'PENDING' THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'Only PENDING terminations can be withdrawn. '
               || 'APPROVED terminations require a Reversal. Current status: '
               || v_termination.workflow_status || '.');
  END IF;

  IF NOT (
    user_can('termination', 'edit', v_termination.employee_id)
    OR user_can('termination', 'edit', NULL)
    OR get_my_employee_id() = v_termination.employee_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  -- Call wf_withdraw (Phase 3 will add wf_sync_module_status branch for 'termination')
  PERFORM wf_withdraw(v_termination.workflow_instance_id);

  -- Flip status here too — ensures correctness even before Phase 3 sync branch is added
  UPDATE employee_terminations
  SET    workflow_status      = 'WITHDRAWN',
         workflow_instance_id = NULL,
         updated_at           = NOW(),
         updated_by           = auth.uid()
  WHERE  id = p_termination_id;

  RETURN jsonb_build_object('ok', true, 'workflow_status', 'WITHDRAWN');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION withdraw_termination(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION withdraw_termination(uuid) TO authenticated;


-- =============================================================================
-- 5. withdraw_termination_reversal
--    §3.3 — only while reversal workflow_status = 'PENDING'
-- =============================================================================

CREATE OR REPLACE FUNCTION withdraw_termination_reversal(
  p_reversal_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reversal    employee_termination_reversals%ROWTYPE;
  v_employee_id uuid;
BEGIN
  SELECT * INTO v_reversal
  FROM   employee_termination_reversals
  WHERE  id = p_reversal_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reversal record not found.');
  END IF;

  IF v_reversal.workflow_status <> 'PENDING' THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'Only PENDING reversals can be withdrawn. Current status: '
               || v_reversal.workflow_status || '.');
  END IF;

  SELECT employee_id INTO v_employee_id
  FROM   employee_terminations
  WHERE  id = v_reversal.termination_id;

  IF NOT (
    user_can('termination', 'edit', v_employee_id)
    OR user_can('termination', 'edit', NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  PERFORM wf_withdraw(v_reversal.workflow_instance_id);

  UPDATE employee_termination_reversals
  SET    workflow_status      = 'WITHDRAWN',
         workflow_instance_id = NULL,
         updated_at           = NOW(),
         updated_by           = auth.uid()
  WHERE  id = p_reversal_id;

  RETURN jsonb_build_object('ok', true, 'workflow_status', 'WITHDRAWN');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION withdraw_termination_reversal(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION withdraw_termination_reversal(uuid) TO authenticated;


-- =============================================================================
-- 6. get_employee_terminations
--    §3.4 — latest termination + active reversal (if any) + attachments
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_terminations(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_termination jsonb;
  v_reversal    jsonb;
  v_attachments jsonb;
BEGIN
  IF NOT (
    user_can('termination', 'view', p_employee_id)
    OR user_can('termination', 'view', NULL)
    OR get_my_employee_id() = p_employee_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.view required.');
  END IF;

  -- Latest non-REVERSED termination
  SELECT to_jsonb(t) INTO v_termination
  FROM (
    SELECT
      et.id,
      et.employee_id,
      et.termination_date,
      et.termination_reason_code,
      et.termination_initiation_type,
      et.resignation_date,
      et.notice_date,
      et.last_working_date,
      et.notice_period_waived,
      et.notice_period_waiver_reason,
      et.eligible_for_rehire,
      et.regrettable_termination,
      et.comments,
      et.workflow_status,
      et.workflow_instance_id,
      et.approved_at,
      et.approved_by,
      et.final_settlement_processed,
      et.final_settlement_date,
      et.created_at,
      et.created_by,
      et.updated_at
    FROM employee_terminations et
    WHERE et.employee_id   = p_employee_id
      AND et.workflow_status <> 'REVERSED'
    ORDER BY et.created_at DESC
    LIMIT 1
  ) t;

  IF v_termination IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'termination', NULL);
  END IF;

  -- Attachments for this termination
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                 a.id,
      'file_name',          a.file_name,
      'original_file_name', a.original_file_name,
      'file_path',          a.file_path,
      'file_size_bytes',    a.file_size_bytes,
      'mime_type',          a.mime_type,
      'uploaded_at',        a.uploaded_at
    ) ORDER BY a.uploaded_at
  ), '[]') INTO v_attachments
  FROM employee_termination_attachments a
  WHERE a.termination_id = (v_termination->>'id')::uuid
    AND a.is_active = true;

  -- Active reversal (PENDING or DRAFT) if any
  SELECT to_jsonb(r) INTO v_reversal
  FROM (
    SELECT
      etr.id,
      etr.termination_id,
      etr.reversal_reason,
      etr.comments,
      etr.workflow_status,
      etr.workflow_instance_id,
      etr.approved_at,
      etr.created_at,
      etr.created_by
    FROM employee_termination_reversals etr
    WHERE etr.termination_id  = (v_termination->>'id')::uuid
      AND etr.workflow_status IN ('DRAFT', 'PENDING', 'APPROVED')
    ORDER BY etr.created_at DESC
    LIMIT 1
  ) r;

  RETURN jsonb_build_object(
    'ok',          true,
    'termination', v_termination || jsonb_build_object('attachments', v_attachments),
    'reversal',    v_reversal
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION get_employee_terminations(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_terminations(uuid) TO authenticated;


-- =============================================================================
-- 7. get_termination_history
--    §3.4 — all terminations including REVERSED, gated by termination.history
-- =============================================================================

CREATE OR REPLACE FUNCTION get_termination_history(
  p_employee_id      uuid,
  p_include_reversed boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_has_history boolean;
  v_rows        jsonb;
BEGIN
  -- history perm required for REVERSED records; view perm sufficient otherwise
  v_has_history := (
    user_can('termination', 'history', p_employee_id)
    OR user_can('termination', 'history', NULL)
  );

  IF NOT v_has_history
     AND NOT (
       user_can('termination', 'view', p_employee_id)
       OR user_can('termination', 'view', NULL)
       OR get_my_employee_id() = p_employee_id
     )
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.view required.');
  END IF;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data->>'termination_date') DESC), '[]')
  INTO v_rows
  FROM (
    SELECT to_jsonb(t) AS row_data
    FROM (
      SELECT
        et.id,
        et.termination_date,
        et.termination_reason_code,
        et.termination_initiation_type,
        et.resignation_date,
        et.last_working_date,
        et.notice_period_waived,
        et.eligible_for_rehire,
        et.regrettable_termination,
        et.comments,
        et.workflow_status,
        et.approved_at,
        et.approved_by,
        et.created_at,
        -- Attach latest reversal if any
        (
          SELECT to_jsonb(r)
          FROM (
            SELECT etr.id, etr.reversal_reason, etr.workflow_status,
                   etr.approved_at, etr.created_at
            FROM employee_termination_reversals etr
            WHERE etr.termination_id = et.id
            ORDER BY etr.created_at DESC LIMIT 1
          ) r
        ) AS reversal
      FROM employee_terminations et
      WHERE et.employee_id = p_employee_id
        AND (
          p_include_reversed = true
          OR et.workflow_status <> 'REVERSED'
          OR NOT v_has_history   -- non-history viewers never see REVERSED
        )
    ) t
  ) sub;

  RETURN jsonb_build_object('ok', true, 'terminations', v_rows);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION get_termination_history(uuid, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_termination_history(uuid, boolean) TO authenticated;


-- =============================================================================
-- 8. get_termination_deactivation_impact
--    §3.4 — extends get_deactivation_impact with direct_reports count
-- =============================================================================

CREATE OR REPLACE FUNCTION get_termination_deactivation_impact(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jr_impact       jsonb;
  v_direct_reports  jsonb;
  v_direct_count    int;
BEGIN
  IF NOT (
    user_can('termination', 'edit', p_employee_id)
    OR user_can('termination', 'edit', NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- JR matrix impact (reuse existing function — §1 decision #2)
  v_jr_impact := get_deactivation_impact(p_employee_id);

  -- Direct reports (line manager relationship via employees.manager_id mirror)
  SELECT
    COUNT(*)::int,
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'employee_id',   e.id,
        'employee_code', e.employee_id,
        'name',          e.name
      ) ORDER BY e.name
    ), '[]'::jsonb)
  INTO v_direct_count, v_direct_reports
  FROM employees e
  WHERE e.manager_id = p_employee_id
    AND e.status     = 'Active'
    AND e.deleted_at IS NULL;

  RETURN jsonb_build_object(
    'ok',                  true,
    'direct_reports',      v_direct_reports,
    'direct_report_count', v_direct_count,
    'jr_assignments',      COALESCE(v_jr_impact->'affected_employees', '[]'::jsonb),
    'jr_assignment_count', COALESCE(v_jr_impact->'total', 0)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION get_termination_deactivation_impact(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_termination_deactivation_impact(uuid) TO authenticated;

COMMENT ON FUNCTION get_termination_deactivation_impact(uuid) IS
  'Mig 489: extends get_deactivation_impact (JR matrix managers) with direct_reports '
  '(employees.manager_id). Used by TerminationImpactModal before submission.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT proname, pronargs
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname IN (
    'derive_termination_initiation_type',
    'submit_termination',
    'submit_termination_reversal',
    'withdraw_termination',
    'withdraw_termination_reversal',
    'get_employee_terminations',
    'get_termination_history',
    'get_termination_deactivation_impact'
  )
ORDER BY proname;
-- Expect: 8 rows

-- =============================================================================
-- END OF MIGRATION 489
-- =============================================================================
