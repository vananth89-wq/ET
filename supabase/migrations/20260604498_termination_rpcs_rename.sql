-- =============================================================================
-- Migration 498 — Termination: Rewrite RPCs for schema rename
--
-- Rewrites all termination RPCs to use the renamed columns from mig 497:
--   termination_date   → separation_date
--   resignation_date   → dropped (merged into separation_date)
--   notice_date        → notice_expiry_date (always computed, never user input)
--   notice_period_days → now also stored as notice_period_days_snapshot
--   last_working_date  → defaults to separation_date if not provided
--
-- RPCs rewritten:
--   1. submit_termination               — full rewrite
--   2. get_employee_terminations        — column renames in SELECT
--   3. get_termination_history          — column renames + ORDER BY fix
--
-- In-flight workflow safety:
--   The workflow instance metadata key is changed from 'termination_date'
--   to 'separation_date'. The ApproverInbox / WorkflowReview UI reads both
--   keys (frontend update in parallel). Approval/rejection does NOT read
--   this metadata key in the RPC — wf_sync_module_status only updates
--   workflow_status — so no dual-read is needed in the RPC itself.
--
-- Predecessor: 20260604497_termination_schema_rename.sql
-- Next:        20260604499_termination_edge_functions.sql (Step 3)
-- =============================================================================


-- =============================================================================
-- 1. submit_termination
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
  v_initiation_type           text;

  -- Payload fields
  v_separation_date           date;
  v_reason_code               text;
  v_last_working_date         date;
  v_waived                    boolean;
  v_waiver_reason             text;
  v_eligible_for_rehire       boolean;
  v_regrettable               boolean;
  v_comments                  text;

  -- Notice period (computed, never from payload)
  v_notice_period_days        integer;
  v_notice_expiry_date        date;
  v_required_lwd              date;

  -- Picklist validation
  v_picklist_code             text;
  v_reason_valid              boolean;

  -- Workflow resolution
  v_template_id               uuid;
  v_template_code             text;
  v_has_workflow              boolean;

  -- Result
  v_termination_id            uuid;
  v_instance_id               uuid;
  v_att                       jsonb;
BEGIN

  -- ── 1. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('termination', 'edit', p_employee_id)
    OR user_can('termination', 'edit', NULL)
    OR get_my_employee_id() = p_employee_id
    OR EXISTS (
         SELECT 1 FROM employees
         WHERE  id         = p_employee_id
           AND  manager_id = get_my_employee_id()
           AND  deleted_at IS NULL
       )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- ── 2. Extract payload ─────────────────────────────────────────────────────
  -- separation_date replaces both termination_date and resignation_date.
  -- notice_expiry_date is NEVER accepted from the payload — always computed.
  v_separation_date   := NULLIF(p_termination_data->>'separation_date', '')::date;
  v_reason_code       := NULLIF(p_termination_data->>'termination_reason_code', '');
  v_last_working_date := NULLIF(p_termination_data->>'last_working_date', '')::date;
  v_waived            := COALESCE((p_termination_data->>'notice_period_waived')::boolean, false);
  v_waiver_reason     := NULLIF(p_termination_data->>'notice_period_waiver_reason', '');
  v_eligible_for_rehire := COALESCE((p_termination_data->>'eligible_for_rehire')::boolean, true);
  v_regrettable         := (p_termination_data->>'regrettable_termination')::boolean;
  v_comments            := NULLIF(p_termination_data->>'comments', '');

  -- ── 3. Required field validation ───────────────────────────────────────────
  IF v_separation_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'separation_date is required.');
  END IF;
  IF v_reason_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_reason_code is required.');
  END IF;
  IF v_comments IS NULL OR length(v_comments) < 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 20 characters.');
  END IF;
  IF v_reason_code = 'OTHER' AND length(v_comments) < 50 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'comments must be at least 50 characters when reason is OTHER.');
  END IF;

  -- ── 4. Derive initiation type ──────────────────────────────────────────────
  BEGIN
    v_initiation_type := derive_termination_initiation_type(p_employee_id, false);
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Access denied: cannot initiate termination for this employee.');
  END;

  -- ── 5. Picklist validation ─────────────────────────────────────────────────
  v_picklist_code := CASE
    WHEN v_initiation_type = 'SELF' THEN 'RESIGNATION_REASON'
    ELSE 'TERMINATION_REASON'
  END;

  SELECT EXISTS (
    SELECT 1
    FROM   picklist_values pv
    JOIN   picklists pl ON pl.id = pv.picklist_id
    WHERE  pl.picklist_id = v_picklist_code
      AND  pv.ref_id      = v_reason_code
      AND  pv.active      = true
  ) INTO v_reason_valid;

  IF NOT v_reason_valid THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('termination_reason_code %s is not valid for picklist %s.',
             v_reason_code, v_picklist_code));
  END IF;

  -- ── 6. Read notice_period_days from employment — ALWAYS from DB, never payload
  --       Uses the slice covering separation_date; falls back to open-ended slice.
  SELECT notice_period_days INTO v_notice_period_days
  FROM   employee_employment
  WHERE  employee_id    = p_employee_id
    AND  effective_from <= v_separation_date
    AND  effective_to   >  v_separation_date
    AND  is_active      = true
  ORDER  BY effective_from DESC
  LIMIT  1;

  IF v_notice_period_days IS NULL THEN
    SELECT notice_period_days INTO v_notice_period_days
    FROM   employee_employment
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
    LIMIT  1;
  END IF;

  IF v_notice_period_days IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No active employment record found covering the separation date.');
  END IF;

  -- ── 7. Compute notice_expiry_date = submission date + notice_period_days ───
  --       This is the single computed deadline — never user-supplied.
  v_notice_expiry_date := CURRENT_DATE + v_notice_period_days;

  -- ── 8. SELF-specific: separation_date must be on or after notice_expiry_date
  IF v_initiation_type = 'SELF' THEN
    IF v_separation_date < v_notice_expiry_date THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('separation_date must be on or after %s (today + %s notice days).',
               v_notice_expiry_date, v_notice_period_days));
    END IF;
  END IF;

  -- ── 9. Default last_working_date to separation_date if not provided ────────
  IF v_last_working_date IS NULL THEN
    v_last_working_date := v_separation_date;
  END IF;

  -- ── 10. Notice period waiver check ─────────────────────────────────────────
  --        required_lwd = notice_expiry_date for all initiation types.
  --        SELF: hard block — employee cannot waive own notice.
  --        HR/MGR: auto-waive with required reason.
  v_required_lwd := v_notice_expiry_date;

  IF v_last_working_date < v_required_lwd THEN
    IF v_initiation_type = 'SELF' THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('last_working_date cannot be before %s (notice expiry date). '
               || 'Employees cannot waive their own notice period.',
               v_required_lwd));
    ELSE
      -- HR / Manager: auto-flag waiver, require reason
      v_waived := true;
      IF v_waiver_reason IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('notice_period_waiver_reason is required: '
                 || 'last_working_date is before notice expiry date (%s).',
                 v_required_lwd));
      END IF;
    END IF;
  END IF;

  -- ── 11. Strip HR-only fields from SELF ────────────────────────────────────
  IF v_initiation_type = 'SELF' THEN
    v_eligible_for_rehire := true;
    v_regrettable         := NULL;
  END IF;

  -- ── 12. Resolve workflow assignment ───────────────────────────────────────
  v_template_id  := resolve_workflow_for_submission('termination', auth.uid());
  v_has_workflow := v_template_id IS NOT NULL;

  IF v_has_workflow THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ── 13. Insert DRAFT row ───────────────────────────────────────────────────
  INSERT INTO employee_terminations (
    employee_id,
    separation_date,
    notice_expiry_date,
    notice_period_days_snapshot,
    last_working_date,
    termination_reason_code,
    termination_initiation_type,
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
    v_separation_date,
    v_notice_expiry_date,
    v_notice_period_days,
    v_last_working_date,
    v_reason_code,
    v_initiation_type,
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

  -- ── 14. Workflow path vs direct-save path ──────────────────────────────────
  IF v_has_workflow THEN
    v_instance_id := wf_submit(
      p_template_code => v_template_code,
      p_module_code   => 'termination',
      p_record_id     => v_termination_id,
      p_metadata      => jsonb_build_object(
        'employee_id',     p_employee_id,
        'separation_date', v_separation_date,   -- new key name
        'initiation_type', v_initiation_type
      )
    );

    UPDATE employee_terminations
    SET    workflow_status      = 'PENDING',
           workflow_instance_id = v_instance_id,
           updated_at           = NOW(),
           updated_by           = auth.uid()
    WHERE  id = v_termination_id;
    -- Note: submitted_at is stamped by trg_termination_submitted_at trigger (mig 497)

  ELSE
    -- No workflow: direct-save → APPROVED
    UPDATE employee_terminations
    SET    workflow_status = 'APPROVED',
           approved_at    = NOW(),
           approved_by    = auth.uid(),
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = v_termination_id;
  END IF;

  -- ── 15. Attachments ────────────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_termination_attachments (
      termination_id, file_name, original_file_name,
      file_path, file_size_bytes, mime_type, uploaded_by
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
    'ok',                   true,
    'termination_id',       v_termination_id,
    'workflow_instance_id', v_instance_id,
    'workflow_status',      CASE WHEN v_has_workflow THEN 'PENDING' ELSE 'APPROVED' END,
    'notice_expiry_date',   v_notice_expiry_date,
    'notice_period_days',   v_notice_period_days
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination(uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination(uuid, jsonb, jsonb) IS
  'Mig 489: initial. Mig 491: MANAGER_INITIATED. Mig 492: workflow resolver. '
  'Mig 498: separation_date replaces termination_date + resignation_date; '
  'notice_expiry_date always computed from employment record; '
  'last_working_date defaults to separation_date; '
  'notice_period_days_snapshot stored on record.';


-- =============================================================================
-- 2. get_employee_terminations — column renames in SELECT
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
      et.separation_date,
      et.notice_expiry_date,
      et.notice_period_days_snapshot,
      et.termination_reason_code,
      et.termination_initiation_type,
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
      et.submitted_at,
      et.created_at,
      et.created_by,
      et.updated_at
    FROM employee_terminations et
    WHERE et.employee_id     = p_employee_id
      AND et.workflow_status <> 'REVERSED'
    ORDER BY et.created_at DESC
    LIMIT 1
  ) t;

  IF v_termination IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'termination', NULL);
  END IF;

  -- Attachments
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

COMMENT ON FUNCTION get_employee_terminations(uuid) IS
  'Mig 489: initial. Mig 498: separation_date / notice_expiry_date column renames.';


-- =============================================================================
-- 3. get_termination_history — column renames + ORDER BY
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

  SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data->>'separation_date') DESC), '[]')
  INTO   v_rows
  FROM (
    SELECT to_jsonb(t) AS row_data
    FROM (
      SELECT
        et.id,
        et.separation_date,
        et.notice_expiry_date,
        et.notice_period_days_snapshot,
        et.termination_reason_code,
        et.termination_initiation_type,
        et.last_working_date,
        et.notice_period_waived,
        et.notice_period_waiver_reason,
        et.eligible_for_rehire,
        et.regrettable_termination,
        et.comments,
        et.workflow_status,
        et.approved_at,
        et.approved_by,
        et.submitted_at,
        et.created_at,
        (
          SELECT to_jsonb(r)
          FROM (
            SELECT etr.id, etr.reversal_reason, etr.workflow_status,
                   etr.approved_at, etr.created_at
            FROM   employee_termination_reversals etr
            WHERE  etr.termination_id = et.id
            ORDER  BY etr.created_at DESC LIMIT 1
          ) r
        ) AS reversal
      FROM employee_terminations et
      WHERE et.employee_id = p_employee_id
        AND (
          p_include_reversed = true
          OR et.workflow_status <> 'REVERSED'
          OR NOT v_has_history
        )
    ) t
  ) sub;

  RETURN jsonb_build_object('ok', true, 'history', v_rows);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION get_termination_history(uuid, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_termination_history(uuid, boolean) TO authenticated;

COMMENT ON FUNCTION get_termination_history(uuid, boolean) IS
  'Mig 489: initial. Mig 498: separation_date / notice_expiry_date column renames.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm submit_termination no longer references old column names
SELECT
  prosrc LIKE '%separation_date%'          AS uses_separation_date,
  prosrc NOT LIKE '%resignation_date%'     AS no_resignation_date,
  prosrc NOT LIKE '%termination_date%'     AS no_termination_date,
  prosrc LIKE '%notice_expiry_date%'       AS uses_notice_expiry_date,
  prosrc LIKE '%notice_period_days_snapshot%' AS stores_snapshot,
  prosrc LIKE '%v_last_working_date := v_separation_date%' AS lwd_defaults_to_separation
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'submit_termination';
-- All columns expected: true

-- =============================================================================
-- END OF MIGRATION 498
-- =============================================================================
