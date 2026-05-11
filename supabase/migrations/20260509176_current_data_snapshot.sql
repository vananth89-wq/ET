-- =============================================================================
-- Migration 176: current_data snapshot for workflow_pending_changes
--
-- PROBLEM
-- ───────
-- workflow_pending_changes stores proposed_data (what the employee wants to
-- change to) but nothing about what the values were before. Approvers in the
-- Workflow Inbox could not tell what changed — they only saw the new value.
--
-- FIX
-- ───
-- 1. Add a nullable current_data jsonb column to workflow_pending_changes.
--    Nullable so all existing rows are unaffected (they show no strikethrough,
--    same as before).
--
-- 2. Update submit_change_request to snapshot current values before saving.
--    Uses the safe approach: read the ENTIRE row from the relevant satellite
--    table as a JSONB blob via to_jsonb(), then filter it to only the keys
--    that appear in p_proposed_data. This avoids hard-coding column names —
--    if a key in proposed_data doesn't exist in the table, it's simply
--    omitted from current_data (no crash, no wrong data).
--
-- 3. Recreate vw_wf_pending_tasks to expose current_data so the Approver
--    Inbox UI can read it alongside metadata (proposed_data).
--
-- TABLE MAP (module_code → satellite table)
-- ─────────────────────────────────────────
--   profile_personal          → employee_personal  (nationality, marital_status, gender, dob)
--   profile_contact           → employee_contact   (country_code, mobile, personal_email)
--   profile_address           → employee_addresses (line1, line2, landmark, city, district, state, pin, country)
--   profile_passport          → passports          (country, passport_number, issue_date, expiry_date)
--   profile_identification    → identity_records   (country, id_type, record_type, id_number, expiry)
--   profile_emergency_contact → emergency_contacts (name, relationship, phone, alt_phone, email)
--   profile_employment        → (no satellite table — skipped, no-op)
--   all others                → current_data = NULL (no-op)
--
-- UI IMPACT
-- ─────────
-- ApproverInbox.tsx ProfileEnrichment component already reads task.currentData.
-- useWorkflowTasks already maps r.current_data. No further UI changes needed.
-- =============================================================================


-- ── 1. Add current_data column ────────────────────────────────────────────────

ALTER TABLE workflow_pending_changes
  ADD COLUMN IF NOT EXISTS current_data jsonb;

COMMENT ON COLUMN workflow_pending_changes.current_data IS
  'Snapshot of the employee''s current field values at the time of submission, '
  'filtered to only the keys present in proposed_data. NULL for rows submitted '
  'before migration 176, or for modules with no satellite table. '
  'Used by the Approver Inbox to render a before/after diff.';


-- ── 2. Replace submit_change_request ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION submit_change_request(
  p_module_code   text,
  p_record_id     uuid    DEFAULT NULL,
  p_proposed_data jsonb   DEFAULT '{}',
  p_action        text    DEFAULT 'update'
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
  v_current_row   jsonb   := NULL;   -- full satellite row as jsonb
  v_current_data  jsonb   := NULL;   -- filtered to proposed_data keys only
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

  IF p_action NOT IN ('create', 'update', 'delete') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'action must be create, update, or delete.');
  END IF;

  -- ── Must be linked to an employee ───────────────────────────────────────────
  v_emp_id := get_my_employee_id();

  -- ── Resolve workflow ────────────────────────────────────────────────────────
  v_template_id := resolve_workflow_for_submission(p_module_code, auth.uid());

  IF v_template_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
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

  -- ── Snapshot current values (SAFE approach) ─────────────────────────────────
  -- Read the entire satellite row as jsonb via to_jsonb() — no hard-coded
  -- column names. Then filter to only the keys present in p_proposed_data.
  -- If a proposed key doesn't exist in the table, it's silently omitted.
  -- v_emp_id is NULL (non-employee caller) → skip snapshot gracefully.

  IF v_emp_id IS NOT NULL AND p_action = 'update' THEN

    CASE p_module_code

      WHEN 'profile_personal' THEN
        SELECT to_jsonb(ep.*)
        INTO   v_current_row
        FROM   employee_personal ep
        WHERE  ep.employee_id = v_emp_id;

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
        -- profile_employment and any future modules: leave v_current_row NULL
        NULL;

    END CASE;

    -- Filter: keep only the keys that appear in proposed_data.
    -- Strips system columns (id, employee_id, created_at, updated_at) automatically
    -- since they won't be keys in proposed_data.
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
    v_current_data,           -- NULL for create/delete or when no satellite row found
    auth.uid()
  )
  RETURNING id INTO v_pending_id;

  -- ── Submit to workflow engine ────────────────────────────────────────────────
  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => p_module_code,
    p_record_id     => v_pending_id,
    p_metadata      => COALESCE(p_proposed_data, '{}')
  );

  -- ── Link instance back to pending change ─────────────────────────────────────
  UPDATE workflow_pending_changes
  SET    instance_id = v_instance_id
  WHERE  id = v_pending_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'pending_change_id', v_pending_id,
    'instance_id',       v_instance_id
  );

EXCEPTION WHEN OTHERS THEN
  DELETE FROM workflow_pending_changes WHERE id = v_pending_id;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION submit_change_request(text, uuid, jsonb, text) IS
  'Generic workflow submission for non-expense modules. '
  'Snapshots current satellite-table values into current_data before saving, '
  'using to_jsonb() on the full row then filtering to proposed_data keys — '
  'no hard-coded column names. current_data is NULL for create/delete actions '
  'or modules with no satellite table (e.g. profile_employment). '
  'Returns { ok, pending_change_id, instance_id } on success.';


-- ── 3. Recreate vw_wf_pending_tasks with current_data ────────────────────────

DROP VIEW IF EXISTS vw_wf_pending_tasks;

CREATE VIEW vw_wf_pending_tasks AS
SELECT
  wt.id                  AS task_id,
  wi.id                  AS instance_id,
  wt.assigned_to,
  ws.name                AS step_name,
  wt.step_order,
  tpl.code               AS template_code,
  tpl.name               AS template_name,
  wi.module_code,
  wi.record_id,
  wi.metadata,
  wpc.current_data,                         -- before/after diff for profile modules
  wi.submitted_by,
  e_sub.name             AS submitted_by_name,
  e_sub.business_email   AS submitted_by_email,
  wt.due_at,
  wt.created_at          AS task_created_at,
  CASE
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now() THEN 'overdue'
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now() + interval '4 hours' THEN 'due_soon'
    ELSE 'on_track'
  END                    AS sla_status
FROM       workflow_tasks      wt
JOIN       workflow_instances  wi    ON wi.id         = wt.instance_id
JOIN       workflow_steps      ws    ON ws.id         = wt.step_id
JOIN       workflow_templates  tpl   ON tpl.id        = wi.template_id
JOIN       profiles            sub   ON sub.id        = wi.submitted_by
LEFT JOIN  employees           e_sub ON e_sub.id      = sub.employee_id
-- pending_change.id = wi.record_id for all profile_* and other non-expense modules
LEFT JOIN  workflow_pending_changes wpc ON wpc.id     = wi.record_id
WHERE      wt.status  = 'pending'
  AND      wi.status  = 'in_progress'
  AND      wt.assigned_to = auth.uid();

COMMENT ON VIEW vw_wf_pending_tasks IS
  'Tasks pending action by the current user. current_data joins workflow_pending_changes '
  'to expose the before-snapshot for profile modules (NULL for expense_reports and '
  'rows submitted before migration 176). Used to drive the Approver Inbox.';


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Column exists and is nullable
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_name  = 'workflow_pending_changes'
  AND  column_name = 'current_data';

-- Expected: column_name=current_data, data_type=jsonb, is_nullable=YES

-- 2. View includes current_data
SELECT column_name
FROM   information_schema.columns
WHERE  table_name = 'vw_wf_pending_tasks'
  AND  column_name = 'current_data';

-- Expected: 1 row returned

-- 3. Function updated
SELECT proname, prosecdef
FROM   pg_proc
WHERE  proname = 'submit_change_request';

-- Expected: prosecdef = true

-- =============================================================================
-- END OF MIGRATION 176
--
-- Type regen: REQUIRED after applying — vw_wf_pending_tasks gains current_data.
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr > src/types/database.types.ts
-- After applying:
--   1. Run the verification queries above.
--   2. Submit a new personal info change from My Profile.
--   3. Open the Approver Inbox — Date of Birth (or any changed field) should
--      show the new value with the old value struck through below it.
--   4. Fields not in proposed_data should show no change.
-- =============================================================================
