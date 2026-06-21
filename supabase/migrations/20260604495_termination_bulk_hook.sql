-- =============================================================================
-- Migration 494 — Termination Module: Bulk Framework Hook (Phase 5)
--
-- Registers termination as the 17th template in the bulk framework.
-- Uses the dispatch-table architecture from mig 423 — no monolith rewrite.
--
-- Changes:
--   1. _bulk_export_termination(p_include_inactive, p_mode) — private export fn
--   2. bulk_template_registry row — termination (17th, sort_order=170)
--   3. upsert_termination_bulk(p_employee_id, p_termination_data, p_upload_batch_id)
--      Bulk processor RPC. Bypasses workflow per framework rule §13.
--      Sets workflow_status='APPROVED', termination_initiation_type='SYSTEM_INITIATED'.
--      Fires post-approval automation via apply_termination_approval Edge Function
--      (for same-day rows; future-dated handled by process-scheduled-terminations).
--
-- §1 decision #8: bulk permission locked to a tiny admin group.
--   termination.bulk_import and termination.bulk_export already seeded in mig 484.
--
-- Design spec: docs/termination-design.md §14
-- Predecessor: 20260604493
-- Next migration: frontend phases (6–7)
-- =============================================================================


-- =============================================================================
-- 1. _bulk_export_termination — private export function
--    Follows the _bulk_export_* pattern from mig 423.
--    'current' mode: APPROVED terminations only (non-REVERSED), one per employee.
--    'history' mode: all terminations including REVERSED.
-- =============================================================================

CREATE OR REPLACE FUNCTION _bulk_export_termination(
  p_include_inactive BOOLEAN,
  p_mode             TEXT
)
RETURNS SETOF JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('termination', 'bulk_export', NULL) THEN
    RAISE EXCEPTION 'Access denied: termination.bulk_export required'
      USING ERRCODE = '42501';
  END IF;

  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id                                          AS "Employee Code *",
        e.name                                                 AS "Employee Name",
        TO_CHAR(et.termination_date,     'MM/DD/YYYY')        AS "Termination Date *",
        et.termination_reason_code                             AS "Termination Reason Code *",
        et.termination_initiation_type                         AS "Initiation Type",
        TO_CHAR(et.resignation_date,     'MM/DD/YYYY')        AS "Resignation Date",
        TO_CHAR(et.notice_date,          'MM/DD/YYYY')        AS "Notice Date",
        TO_CHAR(et.last_working_date,    'MM/DD/YYYY')        AS "Last Working Date",
        CASE WHEN et.notice_period_waived THEN 'Yes' ELSE 'No' END AS "Notice Period Waived",
        et.notice_period_waiver_reason                         AS "Notice Period Waiver Reason",
        CASE WHEN et.eligible_for_rehire THEN 'Yes' ELSE 'No' END AS "Eligible For Rehire",
        CASE WHEN et.regrettable_termination THEN 'Yes'
             WHEN et.regrettable_termination IS NULL THEN ''
             ELSE 'No' END                                     AS "Regrettable Termination",
        et.comments                                            AS "Comments *",
        et.workflow_status                                     AS "Workflow Status",
        TO_CHAR(et.approved_at,          'MM/DD/YYYY HH24:MI') AS "Approved At",
        et.final_settlement_processed::text                    AS "Final Settlement Processed",
        TO_CHAR(et.final_settlement_date,'MM/DD/YYYY')        AS "Final Settlement Date",
        et.id::text                                            AS "id",
        TO_CHAR(et.created_at,           'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(et.updated_at,           'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_terminations et
      JOIN employees e ON e.id = et.employee_id
      WHERE (p_include_inactive OR e.status <> 'Inactive')
      ORDER BY e.employee_id, et.termination_date DESC
    ) r;
  ELSE
    -- Current: most recent non-REVERSED APPROVED termination per employee
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT DISTINCT ON (e.id)
        e.employee_id                                          AS "Employee Code *",
        e.name                                                 AS "Employee Name",
        TO_CHAR(et.termination_date,     'MM/DD/YYYY')        AS "Termination Date *",
        et.termination_reason_code                             AS "Termination Reason Code *",
        et.termination_initiation_type                         AS "Initiation Type",
        TO_CHAR(et.resignation_date,     'MM/DD/YYYY')        AS "Resignation Date",
        TO_CHAR(et.notice_date,          'MM/DD/YYYY')        AS "Notice Date",
        TO_CHAR(et.last_working_date,    'MM/DD/YYYY')        AS "Last Working Date",
        CASE WHEN et.notice_period_waived THEN 'Yes' ELSE 'No' END AS "Notice Period Waived",
        et.notice_period_waiver_reason                         AS "Notice Period Waiver Reason",
        CASE WHEN et.eligible_for_rehire THEN 'Yes' ELSE 'No' END AS "Eligible For Rehire",
        CASE WHEN et.regrettable_termination THEN 'Yes'
             WHEN et.regrettable_termination IS NULL THEN ''
             ELSE 'No' END                                     AS "Regrettable Termination",
        et.comments                                            AS "Comments *",
        et.workflow_status                                     AS "Workflow Status",
        TO_CHAR(et.approved_at,          'MM/DD/YYYY HH24:MI') AS "Approved At",
        et.final_settlement_processed::text                    AS "Final Settlement Processed",
        TO_CHAR(et.final_settlement_date,'MM/DD/YYYY')        AS "Final Settlement Date",
        et.id::text                                            AS "id",
        TO_CHAR(et.created_at,           'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(et.updated_at,           'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_terminations et
      JOIN employees e ON e.id = et.employee_id
      WHERE et.workflow_status = 'APPROVED'
        AND (p_include_inactive OR e.status <> 'Inactive')
      ORDER BY e.id, et.termination_date DESC
    ) r;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION _bulk_export_termination(BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION _bulk_export_termination(boolean, text) IS
  'Mig 494: private export function for the termination bulk template. '
  'current mode: most recent APPROVED termination per employee. '
  'history mode: all terminations including REVERSED.';


-- =============================================================================
-- 2. bulk_template_registry seed — termination (17th template, sort_order=170)
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code,
  display_label,
  description,
  icon,
  sort_order,
  permission_import,
  permission_export,
  processor_rpc,
  exporter_query,
  history_exporter_query,
  schema_definition,
  natural_key
)
VALUES (
  'termination',
  'Termination',
  'Process employee terminations in bulk. Bypasses workflow — restricted to admin group.',
  'ti-user-minus',
  170,
  'termination.bulk_import',
  'termination.bulk_export',
  'upsert_termination_bulk',

  -- exporter_query (current — APPROVED, non-REVERSED)
  $exq$
    SELECT DISTINCT ON (e.id)
      e.employee_id                                    AS "Employee Code *",
      TO_CHAR(et.termination_date,  'MM/DD/YYYY')     AS "Termination Date *",
      et.termination_reason_code                       AS "Termination Reason Code *",
      TO_CHAR(et.last_working_date, 'MM/DD/YYYY')     AS "Last Working Date",
      CASE WHEN et.notice_period_waived THEN 'Yes' ELSE 'No' END AS "Notice Period Waived",
      et.notice_period_waiver_reason                   AS "Notice Period Waiver Reason",
      CASE WHEN et.eligible_for_rehire THEN 'Yes' ELSE 'No' END AS "Eligible For Rehire",
      CASE WHEN et.regrettable_termination THEN 'Yes'
           WHEN et.regrettable_termination IS NULL THEN ''
           ELSE 'No' END                               AS "Regrettable Termination",
      et.comments                                      AS "Comments *"
    FROM employee_terminations et
    JOIN employees e ON e.id = et.employee_id
    WHERE et.workflow_status = 'APPROVED'
    ORDER BY e.id, et.termination_date DESC
  $exq$,

  -- history_exporter_query
  $hxq$
    SELECT
      e.employee_id                                    AS "Employee Code *",
      TO_CHAR(et.termination_date,  'MM/DD/YYYY')     AS "Termination Date *",
      et.termination_reason_code                       AS "Termination Reason Code *",
      et.termination_initiation_type                   AS "Initiation Type",
      TO_CHAR(et.last_working_date, 'MM/DD/YYYY')     AS "Last Working Date",
      CASE WHEN et.notice_period_waived THEN 'Yes' ELSE 'No' END AS "Notice Period Waived",
      et.notice_period_waiver_reason                   AS "Notice Period Waiver Reason",
      CASE WHEN et.eligible_for_rehire THEN 'Yes' ELSE 'No' END AS "Eligible For Rehire",
      CASE WHEN et.regrettable_termination THEN 'Yes'
           WHEN et.regrettable_termination IS NULL THEN ''
           ELSE 'No' END                               AS "Regrettable Termination",
      et.comments                                      AS "Comments *",
      et.workflow_status                               AS "Workflow Status"
    FROM employee_terminations et
    JOIN employees e ON e.id = et.employee_id
    ORDER BY e.employee_id, et.termination_date DESC
  $hxq$,

  -- schema_definition
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *',           'data_type','code_employee',               'mandatory',true, 'user_fillable',true,  'description','Existing employee code e.g. EMP001'),
      jsonb_build_object('name','Termination Date *',        'data_type','date_mmddyyyy',               'mandatory',true, 'user_fillable',true,  'description','Date of separation MM/DD/YYYY'),
      jsonb_build_object('name','Termination Reason Code *', 'data_type','code_picklist:TERMINATION_REASON','mandatory',true,'user_fillable',true,'description','Picklist ref_id e.g. PERFORMANCE, MISCONDUCT, OTHER'),
      jsonb_build_object('name','Last Working Date',         'data_type','date_mmddyyyy',               'mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Notice Period Waived',      'data_type','enum:Yes,No',                 'mandatory',false,'user_fillable',true,  'description','Yes or No'),
      jsonb_build_object('name','Notice Period Waiver Reason','data_type','text',                       'mandatory',false,'user_fillable',true,  'description','Required when Notice Period Waived = Yes'),
      jsonb_build_object('name','Eligible For Rehire',       'data_type','enum:Yes,No',                 'mandatory',false,'user_fillable',true,  'description','Default Yes'),
      jsonb_build_object('name','Regrettable Termination',   'data_type','enum:Yes,No',                 'mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Comments *',                'data_type','text',                       'mandatory',true, 'user_fillable',true,  'description','Minimum 20 characters; 50 when reason = OTHER')
    ),
    'notes', 'Bulk termination bypasses the approval workflow. '
             'Rows are stamped SYSTEM_INITIATED and immediately APPROVED. '
             'Permission termination.bulk_import is restricted to the admin group.'
  ),

  ARRAY['Employee Code *']
)
ON CONFLICT (template_code) DO UPDATE SET
  display_label         = EXCLUDED.display_label,
  description           = EXCLUDED.description,
  sort_order            = EXCLUDED.sort_order,
  permission_import     = EXCLUDED.permission_import,
  permission_export     = EXCLUDED.permission_export,
  processor_rpc         = EXCLUDED.processor_rpc,
  exporter_query        = EXCLUDED.exporter_query,
  history_exporter_query = EXCLUDED.history_exporter_query,
  schema_definition     = EXCLUDED.schema_definition,
  natural_key           = EXCLUDED.natural_key,
  updated_at            = NOW();


-- =============================================================================
-- 3. upsert_termination_bulk — processor RPC called by bulk-import-processor
--    §3.6 — bypasses workflow, SYSTEM_INITIATED, upload_batch_id stamped.
--    Validates reason code against TERMINATION_REASON picklist only
--    (bulk is always HR-context, never SELF).
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_termination_bulk(
  p_employee_id      uuid,
  p_termination_data jsonb,
  p_upload_batch_id  uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_termination_date    date;
  v_reason_code         text;
  v_last_working_date   date;
  v_waived              boolean;
  v_waiver_reason       text;
  v_eligible_for_rehire boolean;
  v_regrettable         boolean;
  v_comments            text;
  v_reason_valid        boolean;
  v_termination_id      uuid;
BEGIN

  -- ── 1. Permission: termination.bulk_import (locked to admin group) ────────
  IF NOT user_can('termination', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.bulk_import required');
  END IF;

  -- ── 2. Extract payload ────────────────────────────────────────────────────
  -- Bulk processor uses headerToSnake() on column headers:
  --   "Termination Date *"        → termination_date
  --   "Termination Reason Code *" → termination_reason_code
  --   "Last Working Date"         → last_working_date
  --   "Notice Period Waived"      → notice_period_waived
  --   "Notice Period Waiver Reason" → notice_period_waiver_reason
  --   "Eligible For Rehire"       → eligible_for_rehire
  --   "Regrettable Termination"   → regrettable_termination
  --   "Comments *"                → comments

  v_termination_date    := NULLIF(p_termination_data->>'termination_date', '')::date;
  v_reason_code         := NULLIF(p_termination_data->>'termination_reason_code', '');
  v_last_working_date   := NULLIF(p_termination_data->>'last_working_date', '')::date;
  v_waived              := COALESCE(
    CASE UPPER(NULLIF(p_termination_data->>'notice_period_waived',''))
      WHEN 'YES' THEN true WHEN 'NO' THEN false
      ELSE (p_termination_data->>'notice_period_waived')::boolean
    END, false);
  v_waiver_reason       := NULLIF(p_termination_data->>'notice_period_waiver_reason', '');
  v_eligible_for_rehire := COALESCE(
    CASE UPPER(NULLIF(p_termination_data->>'eligible_for_rehire',''))
      WHEN 'YES' THEN true WHEN 'NO' THEN false
      ELSE (p_termination_data->>'eligible_for_rehire')::boolean
    END, true);
  v_regrettable         :=
    CASE UPPER(NULLIF(p_termination_data->>'regrettable_termination',''))
      WHEN 'YES' THEN true WHEN 'NO' THEN false
      ELSE NULL
    END;
  v_comments            := NULLIF(p_termination_data->>'comments', '');

  -- ── 3. Validation ─────────────────────────────────────────────────────────
  IF v_termination_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_date is required.');
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
  IF v_waived AND v_waiver_reason IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'notice_period_waiver_reason is required when notice_period_waived is Yes.');
  END IF;

  -- Bulk always uses TERMINATION_REASON (never SELF path)
  SELECT EXISTS (
    SELECT 1 FROM picklist_values pv
    JOIN picklists pl ON pl.id = pv.picklist_id
    WHERE pl.picklist_id = 'TERMINATION_REASON'
      AND pv.ref_id      = v_reason_code
      AND pv.active      = true
  ) INTO v_reason_valid;

  IF NOT v_reason_valid THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('termination_reason_code %s is not valid in TERMINATION_REASON picklist.', v_reason_code));
  END IF;

  -- Validate employee exists and is Active
  IF NOT EXISTS (
    SELECT 1 FROM employees WHERE id = p_employee_id AND status = 'Active' AND deleted_at IS NULL
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Employee not found or not Active.');
  END IF;

  -- ── 4. Insert directly as APPROVED / SYSTEM_INITIATED (bypasses workflow) ─
  INSERT INTO employee_terminations (
    employee_id,
    termination_date,
    termination_reason_code,
    termination_initiation_type,
    last_working_date,
    notice_period_waived,
    notice_period_waiver_reason,
    eligible_for_rehire,
    regrettable_termination,
    comments,
    workflow_status,
    approved_at,
    approved_by,
    upload_batch_id,
    created_by,
    updated_by
  ) VALUES (
    p_employee_id,
    v_termination_date,
    v_reason_code,
    'SYSTEM_INITIATED',
    v_last_working_date,
    v_waived,
    v_waiver_reason,
    v_eligible_for_rehire,
    v_regrettable,
    v_comments,
    'APPROVED',
    NOW(),
    auth.uid(),
    p_upload_batch_id,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_termination_id;

  -- ── 5. Post-approval automation ───────────────────────────────────────────
  -- For same-day / past-dated rows: the process-scheduled-terminations daily
  -- cron will pick this up (scheduled_executed=false, workflow_status=APPROVED,
  -- termination_date <= CURRENT_DATE).
  -- The bulk-import-processor can also POST to apply-termination-approval
  -- directly after calling this RPC for immediate execution on same-day rows.

  RETURN jsonb_build_object(
    'ok',             true,
    'termination_id', v_termination_id,
    'workflow_status', 'APPROVED'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION upsert_termination_bulk(uuid, jsonb, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_termination_bulk(uuid, jsonb, uuid) TO authenticated;

COMMENT ON FUNCTION upsert_termination_bulk(uuid, jsonb, uuid) IS
  'Mig 494: bulk processor for termination template. '
  'Bypasses workflow per framework rule §13. '
  'Inserts APPROVED + SYSTEM_INITIATED rows; upload_batch_id stamped for traceability. '
  'Post-approval automation handled by process-scheduled-terminations daily cron.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm 17th template registered
SELECT template_code, display_label, sort_order, processor_rpc
FROM   bulk_template_registry
WHERE  template_code = 'termination';

-- Confirm _bulk_export_termination exists
SELECT proname FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = '_bulk_export_termination';

-- Confirm upsert_termination_bulk exists
SELECT proname FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'upsert_termination_bulk';

-- Confirm total template count is now 17
SELECT COUNT(*) AS template_count FROM bulk_template_registry;

-- =============================================================================
-- END OF MIGRATION 494
-- =============================================================================
