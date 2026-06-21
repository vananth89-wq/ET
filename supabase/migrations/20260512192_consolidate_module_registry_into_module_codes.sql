-- =============================================================================
-- Migration 192: Consolidate module_registry into module_codes
--               + add edit_route column
--
-- BACKGROUND
-- ──────────
-- module_codes  — canonical module identifier list. Every module has a row.
--                 FK anchor for workflow_instances and attachments.
-- module_registry — per-module attachment/write rules. Subset of module_codes.
--                   Only expense_reports and time_off currently registered.
--
-- PROBLEM
-- ───────
-- Two separate tables for module config creates a split:
--   • module_codes  has ALL modules (incl. profile_personal, profile_contact…)
--   • module_registry has attachment rules but can't hold profile modules
--     because status_column is NOT NULL and profile tables have no status column.
--
-- We want to add edit_route (navigation config) to a table that covers ALL
-- modules. module_registry can't — module_codes can.
--
-- SOLUTION
-- ────────
-- 1. Add all module_registry columns to module_codes (nullable — profile modules
--    leave attachment columns NULL; that's fine because the functions guard on them).
-- 2. Add edit_route text column to module_codes.
-- 3. Copy expense_reports and time_off data from module_registry → module_codes.
-- 4. Seed edit_route for expense_reports → '/expense/report/:id'
--    (':id' is replaced at runtime with the record_id UUID).
-- 5. Rewrite can_view_module_record() and can_write_module_record() to read
--    from module_codes instead of module_registry. Guard added: if table_name
--    or status_column is NULL (profile-type modules), return false immediately —
--    these modules are not attachment-managed.
-- 6. Drop module_registry (CASCADE removes FK constraint from module_registry.code).
--
-- WHAT DOES NOT CHANGE
-- ────────────────────
-- • All RLS policies that CALL can_view_module_record() / can_write_module_record()
--   — function signatures unchanged, only internals repointed.
-- • Attachment policies — unchanged.
-- • module_codes SELECT policy — already open to all authenticated (USING true).
-- • module_codes INSERT/UPDATE/DELETE — already gated on is_super_admin().
-- • Profile modules (profile_personal, profile_contact, profile_address,
--   profile_passport, profile_emergency_contact) get edit_route = NULL,
--   meaning Pattern B (inline edit in WorkflowReview) applies when allow_edit.
--
-- EDIT ROUTE PATTERNS
-- ───────────────────
-- Pattern A — edit_route IS NOT NULL → WorkflowReview navigates to that route
--             replacing ':id' with the record_id. Example: expense_reports.
-- Pattern B — edit_route IS NULL     → WorkflowReview shows inline edit of
--             workflow_pending_changes fields. Example: profile modules.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Add module_registry columns to module_codes (all nullable)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE module_codes
  ADD COLUMN IF NOT EXISTS table_name                  text,
  ADD COLUMN IF NOT EXISTS owner_column                text,
  ADD COLUMN IF NOT EXISTS status_column               text,
  ADD COLUMN IF NOT EXISTS draft_status                text,
  ADD COLUMN IF NOT EXISTS permission_prefix           text,
  ADD COLUMN IF NOT EXISTS extra_view_permissions      text[],
  ADD COLUMN IF NOT EXISTS write_permission            text,
  ADD COLUMN IF NOT EXISTS writable_statuses           text[],
  ADD COLUMN IF NOT EXISTS approval_write_permission   text,
  ADD COLUMN IF NOT EXISTS approval_writable_statuses  text[],
  ADD COLUMN IF NOT EXISTS edit_route                  text;

COMMENT ON COLUMN module_codes.table_name IS
  'DB table that holds the module records. NULL for modules without a main record table (e.g. profile modules that use workflow_pending_changes).';
COMMENT ON COLUMN module_codes.owner_column IS
  'Column in table_name that holds the employee_id of the record owner.';
COMMENT ON COLUMN module_codes.status_column IS
  'Column in table_name that holds the record lifecycle status.';
COMMENT ON COLUMN module_codes.draft_status IS
  'Status value that means the record is a draft visible only to the owner.';
COMMENT ON COLUMN module_codes.permission_prefix IS
  'Prefix for standard view_org/view_team/view_direct/view_own permission codes.';
COMMENT ON COLUMN module_codes.extra_view_permissions IS
  'Additional permission codes (outside view_* convention) that also grant SELECT.';
COMMENT ON COLUMN module_codes.write_permission IS
  'Permission code that allows the owner to write the record.';
COMMENT ON COLUMN module_codes.writable_statuses IS
  'Statuses in which the owner may write. NULL = no status restriction.';
COMMENT ON COLUMN module_codes.approval_write_permission IS
  'Permission code that allows an approver to write the record.';
COMMENT ON COLUMN module_codes.approval_writable_statuses IS
  'Statuses in which an approver may write. NULL = no status restriction.';
COMMENT ON COLUMN module_codes.edit_route IS
  'Frontend route template for the record edit page. '
  ':id is replaced at runtime with the record UUID. '
  'NULL = Pattern B (inline edit of workflow_pending_changes in WorkflowReview). '
  'Non-NULL = Pattern A (navigate to the edit form page).';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Copy data from module_registry into module_codes
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE module_codes mc
SET
  table_name                 = mr.table_name,
  owner_column               = mr.owner_column,
  status_column              = mr.status_column,
  draft_status               = mr.draft_status,
  permission_prefix          = mr.permission_prefix,
  extra_view_permissions     = mr.extra_view_permissions,
  write_permission           = mr.write_permission,
  writable_statuses          = mr.writable_statuses,
  approval_write_permission  = mr.approval_write_permission,
  approval_writable_statuses = mr.approval_writable_statuses
FROM module_registry mr
WHERE mc.code = mr.code;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Seed edit_route
-- ─────────────────────────────────────────────────────────────────────────────

-- Pattern A: expense_reports has a dedicated form page
UPDATE module_codes
SET edit_route = '/expense/report/:id'
WHERE code = 'expense_reports';

-- All other modules stay NULL (Pattern B — inline edit, or not yet built).
-- Profile modules (profile_personal, profile_contact, profile_address,
-- profile_passport, profile_emergency_contact) use Pattern B.
-- time_off stays NULL until its edit form is built.


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 4: Rewrite can_view_module_record() — read from module_codes
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION can_view_module_record(
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
  v_reg      module_codes%ROWTYPE;
  v_owner_id uuid;
  v_status   text;
  v_perm     text;
BEGIN
  -- ── Look up module config ─────────────────────────────────────────────────
  SELECT * INTO v_reg FROM module_codes WHERE code = p_module;
  IF NOT FOUND THEN RETURN false; END IF;

  -- ── Guard: modules without a main record table (e.g. profile modules) ────
  -- These modules manage data via workflow_pending_changes, not a status-bearing
  -- record table. Attachment visibility is not applicable → deny.
  IF v_reg.table_name IS NULL OR v_reg.status_column IS NULL THEN
    RETURN false;
  END IF;

  -- ── Fetch owner + status dynamically ─────────────────────────────────────
  EXECUTE format(
    'SELECT %I, %I FROM %I WHERE id = $1',
    v_reg.owner_column, v_reg.status_column, v_reg.table_name
  )
  INTO v_owner_id, v_status
  USING p_record_id;

  IF v_owner_id IS NULL THEN RETURN false; END IF;

  -- ── Admin always wins ─────────────────────────────────────────────────────
  IF has_role('admin') THEN RETURN true; END IF;

  -- ── Draft guard ───────────────────────────────────────────────────────────
  IF v_reg.draft_status IS NOT NULL AND v_status = v_reg.draft_status THEN
    RETURN v_owner_id = get_my_employee_id();
  END IF;

  -- ── Standard permission hierarchy ────────────────────────────────────────
  IF has_permission(v_reg.permission_prefix || '.view_org') THEN
    RETURN true;
  END IF;

  IF has_permission(v_reg.permission_prefix || '.view_team')
     AND is_in_my_org_subtree(v_owner_id)
  THEN
    RETURN true;
  END IF;

  IF has_permission(v_reg.permission_prefix || '.view_direct')
     AND is_my_direct_report(v_owner_id)
  THEN
    RETURN true;
  END IF;

  IF has_permission(v_reg.permission_prefix || '.view_own')
     AND v_owner_id = get_my_employee_id()
  THEN
    RETURN true;
  END IF;

  -- ── Extra view permissions ────────────────────────────────────────────────
  IF v_reg.extra_view_permissions IS NOT NULL THEN
    FOREACH v_perm IN ARRAY v_reg.extra_view_permissions LOOP
      IF has_permission(v_perm) THEN RETURN true; END IF;
    END LOOP;
  END IF;

  -- ── Active workflow approver ──────────────────────────────────────────────
  IF EXISTS (
    SELECT 1
    FROM   workflow_tasks     wt
    JOIN   workflow_instances wi ON wi.id = wt.instance_id
    WHERE  wi.record_id   = p_record_id
      AND  wi.module_code = p_module
      AND  wt.assigned_to = auth.uid()
      AND  wt.status      = 'pending'
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION can_view_module_record(text, uuid) IS
  'Generic visibility check for any module. Reads module_codes (formerly module_registry). '
  'Returns false immediately for modules without table_name/status_column (profile-type modules). '
  'Migration 192: repointed from module_registry → module_codes.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 5: Rewrite can_write_module_record() — read from module_codes
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_reg      module_codes%ROWTYPE;
  v_owner_id uuid;
  v_status   text;
BEGIN
  SELECT * INTO v_reg FROM module_codes WHERE code = p_module;
  IF NOT FOUND THEN RETURN false; END IF;

  -- ── Guard: modules without a main record table ────────────────────────────
  IF v_reg.table_name IS NULL OR v_reg.status_column IS NULL THEN
    RETURN false;
  END IF;

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
  IF v_reg.write_permission IS NOT NULL
     AND v_owner_id = get_my_employee_id()
     AND has_permission(v_reg.write_permission)
     AND is_workflow_awaiting_clarification(p_record_id, p_module)
  THEN RETURN true; END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION can_write_module_record(text, uuid) IS
  'Generic write check for any module. Reads module_codes (formerly module_registry). '
  'Returns false immediately for modules without table_name/status_column (profile-type modules). '
  'Migration 192: repointed from module_registry → module_codes.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 6: Drop module_registry
-- CASCADE removes the FK constraint (module_registry.code → module_codes.code)
-- and the RLS policies on module_registry automatically.
-- ─────────────────────────────────────────────────────────────────────────────

DROP TABLE IF EXISTS module_registry CASCADE;


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. module_registry gone
SELECT COUNT(*) = 0 AS module_registry_dropped
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'module_registry';

-- 2. module_codes has the new columns
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_name = 'module_codes'
  AND  column_name IN (
    'table_name', 'owner_column', 'status_column', 'edit_route',
    'permission_prefix', 'write_permission', 'approval_write_permission'
  )
ORDER BY column_name;

-- 3. Data migrated correctly — expense_reports and time_off should have values
SELECT code, table_name, status_column, edit_route
FROM   module_codes
WHERE  code IN ('expense_reports', 'time_off')
ORDER BY code;

-- 4. Profile modules present with NULL attachment columns and NULL edit_route
SELECT code, table_name, edit_route
FROM   module_codes
WHERE  code LIKE 'profile_%'
ORDER BY code;

-- 5. Functions repointed — confirm they reference module_codes not module_registry
SELECT
  proname,
  prosrc LIKE '%module_codes%'    AS reads_module_codes,
  prosrc NOT LIKE '%module_registry%' AS no_registry_ref
FROM pg_proc
WHERE proname IN ('can_view_module_record', 'can_write_module_record');

-- Expected for both: reads_module_codes = true, no_registry_ref = true

-- =============================================================================
-- END OF MIGRATION 192
--
-- After applying:
--   1. npx supabase gen types typescript … > src/types/database.types.ts
--      (module_registry type removed; module_codes gains new columns)
--   2. WorkflowReview.tsx — fetch edit_route from module_codes
--   3. ReportDetail — add reviewMode=approver param support
--   4. WorkflowOperations — Pattern B inline edit for profile modules
-- =============================================================================
