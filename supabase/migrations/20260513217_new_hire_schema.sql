-- =============================================================================
-- Migration 217: New Hire Workflow — Schema Setup
--
-- CHANGES
-- ───────
-- 1. Add 'Pending' to employee_status enum
--    (Draft → submit → Pending → approve → Active)
--
-- 2. Add `locked` boolean column to employees
--    true  = submitted for approval, no edits allowed except via Edit-in-Flight
--    false = editable (default, Draft, returned-for-changes, rejected, active)
--
-- 3. Create Postgres sequence for Employee ID generation
--    Format: EMP-XXXX  (EMP-0001, EMP-0042, …)
--    Collision-safe: assigned at DB insert time, never on the frontend.
--    NOTE: existing records keep their current employee_id (manually set).
--          New hires created through the workflow will get auto-generated IDs
--          only when employee_id is left blank by the frontend.
--
-- 4. Register `employee_hire` module in module_codes
--    edit_route = '/employees/add?mode=edit&id='
--    (Pattern A — WorkflowReview navigates to full edit form via Update button)
--
-- 5. Seed new permissions for the New Hire module
--    employee_hire.view_all_pending — see all pending hires (not just own tasks)
--    employee_hire.edit_all_pending — edit any pending hire without a task
--
-- SAFETY
-- ──────
-- All steps are IF NOT EXISTS / IF NOT FOUND safe — idempotent to re-run.
-- Existing employee records and the hire_employee permission codes are untouched.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Add 'Pending' value to employee_status enum
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum
    WHERE  enumtypid = 'employee_status'::regtype
    AND    enumlabel = 'Pending'
  ) THEN
    ALTER TYPE employee_status ADD VALUE 'Pending' AFTER 'Draft';
  END IF;
END;
$$;

COMMENT ON TYPE employee_status IS
  'Draft = started, Pending = submitted for approval, Incomplete = partially filled, Active = live, Inactive = deactivated';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Add `locked` column to employees
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS locked boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN employees.locked IS
  'true = submitted for approval, record is read-only until approved/returned/rejected. false = editable.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Create Employee ID sequence
-- Format: EMP-XXXX  (zero-padded to 4 digits, grows beyond 9999 naturally)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS emp_id_seq
  START WITH 1
  INCREMENT BY 1
  MINVALUE 1
  NO MAXVALUE
  CACHE 1;

COMMENT ON SEQUENCE emp_id_seq IS
  'Auto-increment counter for employee_id values. Use: EMP- || lpad(nextval(''emp_id_seq'')::text, 4, ''0'')';

-- Helper function so the frontend / RPC can call this safely
CREATE OR REPLACE FUNCTION generate_employee_id()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 'EMP-' || lpad(nextval('emp_id_seq')::text, 4, '0');
$$;

COMMENT ON FUNCTION generate_employee_id() IS
  'Returns the next unique employee_id in EMP-XXXX format. Backed by emp_id_seq — collision-safe.';

REVOKE ALL ON FUNCTION generate_employee_id() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION generate_employee_id() TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 4: Register employee_hire in module_codes (Pattern A — edit_route set)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO module_codes (code, label, description, edit_route)
VALUES (
  'employee_hire',
  'New Hire',
  'Approval workflow for new employee hire requests submitted by HR Analysts.',
  '/employees/add?mode=edit&id='
)
ON CONFLICT (code) DO UPDATE
  SET label       = EXCLUDED.label,
      description = EXCLUDED.description,
      edit_route  = EXCLUDED.edit_route;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 5: Register employee_hire in the modules table (permission catalog anchor)
-- Sort order 21 — right after hire_employee (20)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO modules (code, name, active, sort_order)
VALUES ('employee_hire', 'New Hire', true, 21)
ON CONFLICT (code) DO UPDATE
  SET name       = EXCLUDED.name,
      sort_order = EXCLUDED.sort_order;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 6a: Expand permissions_action_check to allow custom action names
--
-- The constraint currently: ('view','create','edit','delete','history','lookup')
-- We need to add 'view_all_pending' and 'edit_all_pending' for the New Hire
-- visibility layer. Pattern mirrors migration 147 (which added 'lookup').
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE permissions DROP CONSTRAINT IF EXISTS permissions_action_check;
ALTER TABLE permissions ADD CONSTRAINT permissions_action_check
  CHECK (action IN ('view', 'create', 'edit', 'delete', 'history', 'lookup',
                    'view_all_pending', 'edit_all_pending'));


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 6b: Seed permission catalog rows for New Hire module
--
-- The existing hire_employee permissions (view/create/edit/delete/history) cover
-- the old direct-save flow and remain unchanged.
-- These two NEW permissions are for the approval-flow visibility layer:
--   view_all_pending — HR Head can see ALL pending hires in the list
--   edit_all_pending — HR Head can edit any pending hire without a task
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'employee_hire.' || vals.action,
  initcap(replace(vals.action, '_', ' ')),
  vals.description,
  m.id,
  vals.action
FROM (
  VALUES
    ('view_all_pending', 'See all pending hire records across all analysts — not just those assigned as workflow tasks'),
    ('edit_all_pending', 'Open and edit any pending hire record for correction, even without an active workflow task')
) AS vals(action, description)
JOIN modules m ON m.code = 'employee_hire'
ON CONFLICT (code) DO UPDATE
  SET description = EXCLUDED.description;
