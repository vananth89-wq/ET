-- =============================================================================
-- Migration 078: Fix infinite recursion in clarification write policies
--
-- ROOT CAUSE (same pattern as migration 064)
-- ══════════════════════════════════════════
-- Migration 077 added inline EXISTS subqueries that join workflow_instances
-- directly inside the RLS policies for line_items and expense_reports:
--
--   line_items_insert / _update / _delete  → queries workflow_instances
--   expense_reports_update                 → queries workflow_instances
--   can_write_module_record                → queries workflow_instances
--
-- When Postgres evaluates these policies it must apply RLS on workflow_instances
-- (workflow_instances_select), which in turn calls has_permission() helpers
-- that may re-enter the same policy stack — producing the
-- "infinite recursion detected in policy for relation workflow_instances" error.
--
-- FIX
-- ═══
-- Replace every inline workflow_instances subquery with a new
-- SECURITY DEFINER helper: is_workflow_awaiting_clarification(record_id, module)
-- This mirrors the existing is_workflow_assignee() pattern from migration 064.
-- SECURITY DEFINER means the function runs as its owner and bypasses RLS on
-- workflow_instances, breaking the recursion cycle.
-- =============================================================================


-- ── 1. SECURITY DEFINER helper ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION is_workflow_awaiting_clarification(
  p_record_id   uuid,
  p_module_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_instances wi
    WHERE  wi.record_id   = p_record_id
      AND  wi.module_code = p_module_code
      AND  wi.status      = 'awaiting_clarification'
  );
$$;

COMMENT ON FUNCTION is_workflow_awaiting_clarification(uuid, text) IS
  'Returns true if the most recent workflow instance for the given record is
   awaiting_clarification. SECURITY DEFINER so it bypasses RLS on
   workflow_instances, preventing circular policy recursion (same pattern as
   is_workflow_assignee from migration 064).';


-- ── 2. line_items_insert ──────────────────────────────────────────────────────

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
            er.status IN ('draft', 'rejected')
            OR is_workflow_awaiting_clarification(er.id, 'expense_reports')
          )
      )
    )
  );


-- ── 3. line_items_update ──────────────────────────────────────────────────────

DROP POLICY IF EXISTS line_items_update ON line_items;

CREATE POLICY line_items_update ON line_items FOR UPDATE
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
            OR is_workflow_awaiting_clarification(er.id, 'expense_reports')
          )
      )
    )
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
            OR is_workflow_awaiting_clarification(er.id, 'expense_reports')
          )
      )
    )
    OR (
      has_permission('expense.edit_approval')
      AND is_workflow_assignee(line_items.report_id, 'expense_reports')
    )
  );


-- ── 4. line_items_delete ──────────────────────────────────────────────────────

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
            OR is_workflow_awaiting_clarification(er.id, 'expense_reports')
          )
      )
    )
  );


-- ── 5. expense_reports_update ─────────────────────────────────────────────────

DROP POLICY IF EXISTS expense_reports_update ON expense_reports;

CREATE POLICY expense_reports_update ON expense_reports FOR UPDATE
  USING (
    has_role('admin')
    OR (
      has_permission('expense.edit')
      AND employee_id = get_my_employee_id()
      AND (
        status IN ('draft', 'rejected')
        OR is_workflow_awaiting_clarification(id, 'expense_reports')
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
  )
  WITH CHECK (
    has_role('admin')
    OR (
      has_permission('expense.edit')
      AND employee_id = get_my_employee_id()
      AND (
        status IN ('draft', 'rejected')
        OR is_workflow_awaiting_clarification(id, 'expense_reports')
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


-- ── 6. Rebuild can_write_module_record — Path 3 uses the helper ───────────────

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
  -- Uses SECURITY DEFINER helper to avoid RLS recursion on workflow_instances.
  IF v_reg.write_permission IS NOT NULL
     AND v_owner_id = get_my_employee_id()
     AND has_permission(v_reg.write_permission)
     AND is_workflow_awaiting_clarification(p_record_id, p_module)
  THEN RETURN true; END IF;

  RETURN false;
END;
$$;
