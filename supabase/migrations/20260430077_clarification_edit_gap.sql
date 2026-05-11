-- =============================================================================
-- Migration 077: Allow employee edits when workflow is awaiting_clarification
--
-- PROBLEM
-- ═══════
-- When an approver returns an expense report for clarification:
--   • workflow_instances.status  → 'awaiting_clarification'
--   • expense_reports.status     → stays 'submitted'  ← key fact
--
-- expense_reports.status is a Postgres enum ('draft','submitted','approved',
-- 'rejected') — 'awaiting_clarification' is NOT a valid enum value there.
-- All write policies checked expense_reports.status = 'draft', which blocked
-- the employee from editing line items, adding attachments, or updating the
-- report header on a returned report.
--
-- FIX
-- ═══
-- Instead of checking expense_reports.status, add a workflow_instances join:
-- allow writes when wi.status = 'awaiting_clarification' for the same record.
-- This is done in:
--   1. line_items_insert  — employee can add new line items
--   2. line_items_update  — employee can edit existing line items
--   3. line_items_delete  — employee can remove line items
--   4. expense_reports_update — employee can update report header
--   5. can_write_module_record — attachments: add Path 3 for clarification
--   6. module_registry — remove 'awaiting_clarification' from writable_statuses
--      (it was an expense_reports status value, which is wrong)
--   7. Update expense.edit description to reflect expanded scope
-- =============================================================================


-- ── 1. line_items_insert ──────────────────────────────────────────────────────

DROP POLICY IF EXISTS line_items_insert ON line_items;

CREATE POLICY line_items_insert ON line_items FOR INSERT
  WITH CHECK (
    has_role('admin')
    OR (
      has_permission('expense.edit')
      AND EXISTS (
        SELECT 1 FROM expense_reports er
        WHERE er.id          = line_items.report_id
          AND er.employee_id = get_my_employee_id()
          AND (
            -- Own draft / rejected
            er.status IN ('draft', 'rejected')
            -- OR workflow returned for clarification
            OR EXISTS (
              SELECT 1 FROM workflow_instances wi
              WHERE wi.record_id   = er.id
                AND wi.module_code = 'expense_reports'
                AND wi.status      = 'awaiting_clarification'
            )
          )
      )
    )
  );


-- ── 2. line_items_update ──────────────────────────────────────────────────────

DROP POLICY IF EXISTS line_items_update ON line_items;

CREATE POLICY line_items_update ON line_items FOR UPDATE
  USING (
    has_role('admin')
    -- Employee: own draft/rejected OR workflow returned for clarification
    OR (
      has_permission('expense.edit')
      AND EXISTS (
        SELECT 1 FROM expense_reports er
        WHERE er.id          = line_items.report_id
          AND er.employee_id = get_my_employee_id()
          AND (
            er.status IN ('draft', 'rejected')
            OR EXISTS (
              SELECT 1 FROM workflow_instances wi
              WHERE wi.record_id   = er.id
                AND wi.module_code = 'expense_reports'
                AND wi.status      = 'awaiting_clarification'
            )
          )
      )
    )
    -- Approver: active workflow assignee
    OR (
      has_permission('expense.edit_approval')
      AND is_workflow_assignee(line_items.report_id, 'expense_reports')
    )
  )
  WITH CHECK (
    has_role('admin')
    OR (
      has_permission('expense.edit')
      AND EXISTS (
        SELECT 1 FROM expense_reports er
        WHERE er.id          = line_items.report_id
          AND er.employee_id = get_my_employee_id()
          AND (
            er.status IN ('draft', 'rejected')
            OR EXISTS (
              SELECT 1 FROM workflow_instances wi
              WHERE wi.record_id   = er.id
                AND wi.module_code = 'expense_reports'
                AND wi.status      = 'awaiting_clarification'
            )
          )
      )
    )
    OR (
      has_permission('expense.edit_approval')
      AND is_workflow_assignee(line_items.report_id, 'expense_reports')
    )
  );


-- ── 3. line_items_delete ──────────────────────────────────────────────────────

DROP POLICY IF EXISTS line_items_delete ON line_items;

CREATE POLICY line_items_delete ON line_items FOR DELETE
  USING (
    has_role('admin')
    OR (
      has_permission('expense.edit')
      AND EXISTS (
        SELECT 1 FROM expense_reports er
        WHERE er.id          = line_items.report_id
          AND er.employee_id = get_my_employee_id()
          AND (
            er.status IN ('draft', 'rejected')
            OR EXISTS (
              SELECT 1 FROM workflow_instances wi
              WHERE wi.record_id   = er.id
                AND wi.module_code = 'expense_reports'
                AND wi.status      = 'awaiting_clarification'
            )
          )
      )
    )
  );


-- ── 4. expense_reports_update ─────────────────────────────────────────────────

DROP POLICY IF EXISTS expense_reports_update ON expense_reports;

CREATE POLICY expense_reports_update ON expense_reports FOR UPDATE
  USING (
    has_role('admin')
    -- Employee: own draft/rejected OR workflow returned for clarification
    OR (
      has_permission('expense.edit')
      AND employee_id = get_my_employee_id()
      AND (
        status IN ('draft', 'rejected')
        OR EXISTS (
          SELECT 1 FROM workflow_instances wi
          WHERE wi.record_id   = expense_reports.id
            AND wi.module_code = 'expense_reports'
            AND wi.status      = 'awaiting_clarification'
        )
      )
    )
    -- Org-wide approver
    OR (
      has_permission('expense.view_org')
      AND has_permission('expense.edit_approval')
      AND status IN ('submitted', 'approved', 'rejected')
    )
    -- Team/department approver
    OR (
      has_permission('expense.view_team')
      AND has_permission('expense.edit_approval')
      AND status IN ('submitted', 'approved', 'rejected')
      AND (is_my_direct_report(employee_id) OR is_in_my_department(employee_id))
    )
  )
  WITH CHECK (
    has_role('admin')
    OR (
      has_permission('expense.edit')
      AND employee_id = get_my_employee_id()
      AND (
        status IN ('draft', 'rejected')
        OR EXISTS (
          SELECT 1 FROM workflow_instances wi
          WHERE wi.record_id   = expense_reports.id
            AND wi.module_code = 'expense_reports'
            AND wi.status      = 'awaiting_clarification'
        )
      )
    )
    OR (
      has_permission('expense.view_org')
      AND has_permission('expense.edit_approval')
      AND status IN ('submitted', 'approved', 'rejected')
    )
    OR (
      has_permission('expense.view_team')
      AND has_permission('expense.edit_approval')
      AND status IN ('submitted', 'approved', 'rejected')
      AND (is_my_direct_report(employee_id) OR is_in_my_department(employee_id))
    )
  );


-- ── 5. Fix can_write_module_record — add Path 3 for clarification ─────────────
-- expense_reports.status stays 'submitted' during clarification, so
-- writable_statuses never matches. Add a third path that checks
-- workflow_instances.status = 'awaiting_clarification' directly.
-- This is module-agnostic — works for any module using workflow_instances.

CREATE OR REPLACE FUNCTION can_write_module_record(
  p_module    text,
  p_record_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, extensions
AS $$
DECLARE
  v_reg      module_registry%ROWTYPE;
  v_owner_id uuid;
  v_status   text;
BEGIN
  SELECT * INTO v_reg FROM module_registry WHERE code = p_module;
  IF NOT FOUND THEN RETURN false; END IF;

  EXECUTE format(
    'SELECT %I, %I FROM %I WHERE id = $1',
    v_reg.owner_column, v_reg.status_column, v_reg.table_name
  )
  INTO v_owner_id, v_status
  USING p_record_id;

  IF v_owner_id IS NULL THEN RETURN false; END IF;

  IF has_role('admin') THEN RETURN true; END IF;

  -- ── Path 1: Owner write (draft / rejected) ────────────────────────────────
  IF v_reg.write_permission IS NOT NULL
     AND v_owner_id = get_my_employee_id()
     AND has_permission(v_reg.write_permission)
     AND (
       v_reg.writable_statuses IS NULL
       OR v_status = ANY(v_reg.writable_statuses)
     )
  THEN RETURN true; END IF;

  -- ── Path 2: Approver write (submitted / under_review) ────────────────────
  IF v_reg.approval_write_permission IS NOT NULL
     AND has_permission(v_reg.approval_write_permission)
     AND (
       v_reg.approval_writable_statuses IS NULL
       OR v_status = ANY(v_reg.approval_writable_statuses)
     )
  THEN RETURN true; END IF;

  -- ── Path 3: Owner responding to clarification request ────────────────────
  -- The module record's own status does not change when returned for
  -- clarification — only workflow_instances.status = 'awaiting_clarification'.
  -- So we check workflow_instances directly. Module-agnostic.
  IF v_reg.write_permission IS NOT NULL
     AND v_owner_id = get_my_employee_id()
     AND has_permission(v_reg.write_permission)
     AND EXISTS (
       SELECT 1 FROM workflow_instances wi
       WHERE  wi.record_id   = p_record_id
         AND  wi.module_code = p_module
         AND  wi.status      = 'awaiting_clarification'
     )
  THEN RETURN true; END IF;

  RETURN false;
END;
$$;


-- ── 6. Fix module_registry writable_statuses ──────────────────────────────────
-- Remove 'awaiting_clarification' — it was wrong (that's a workflow_instances
-- status, not an expense_reports status). Clarification writes are now
-- handled by Path 3 in can_write_module_record via workflow_instances join.

UPDATE module_registry
SET    writable_statuses = ARRAY['draft', 'rejected']
WHERE  code = 'expense_reports';

UPDATE module_registry
SET    writable_statuses = ARRAY['draft', 'rejected']
WHERE  code = 'time_off';


-- ── 7. Update expense.edit permission description ─────────────────────────────

UPDATE permissions
SET    description = 'Edit own draft, rejected, or returned (awaiting clarification) expense reports'
WHERE  code = 'expense.edit';
