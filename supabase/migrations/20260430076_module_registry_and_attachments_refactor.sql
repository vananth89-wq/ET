-- =============================================================================
-- Migration 076: Module Registry + Attachments Refactor
--
-- WHAT THIS DOES
-- ══════════════
-- 1. module_codes        — reference table; single source of truth for valid
--                          module identifiers. Both workflow_instances and
--                          attachments FK here so a typo fails at INSERT, not
--                          silently inside RLS.
--
-- 2. module_registry     — one row per module, fully describing its visibility
--                          and write rules as DATA (not code). Columns:
--
--   Core shape
--     table_name               Postgres table, e.g. 'expense_reports'
--     owner_column             Column holding the submitting employee_id
--     status_column            Column holding the record lifecycle status
--     draft_status             Status value that means "owner-only visible"
--     permission_prefix        e.g. 'expense' → expense.view_own, expense.view_org
--
--   View control
--     extra_view_permissions   Permissions beyond the standard view_* hierarchy
--                              that also grant view access. e.g. 'expense.edit_approval'
--                              allows Finance/HR/DeptHead to view without needing
--                              view_org specifically.
--
--   Employee write control
--     write_permission         Permission gate for owner edits, e.g. 'expense.edit'
--     writable_statuses        Statuses in which the owner can write,
--                              e.g. {draft, rejected, awaiting_clarification}
--
--   Approver write control
--     approval_write_permission  Permission gate for approver edits,
--                                e.g. 'expense.edit_approval'
--     approval_writable_statuses Statuses in which an approver can write,
--                                e.g. {submitted, under_review, awaiting_clarification}
--                                No ownership check — Finance can attach GL docs
--                                to any report in a reviewable state.
--
-- 3. can_view_module_record(module, record_id)
--                        — single delegating function. Resolves visibility for
--                          any module by reading module_registry. Checks:
--                          admin → draft guard → standard hierarchy
--                          (view_org/team/direct/own) → extra_view_permissions
--                          → active workflow approver.
--                          Zero module table names in this function or any policy.
--
-- 4. can_write_module_record(module, record_id)
--                        — two-path write check:
--                          Path 1: owner + write_permission + writable status
--                          Path 2: approval_write_permission + approval writable status
--                          (no ownership on path 2 — approvers write without owning)
--
-- 5. attachments schema  — line_item_id made nullable; record_id + module_code
--                          added for record-level attachments (time off, etc.).
--                          CHECK ensures at least one parent is always set.
--                          Existing rows backfilled: record_id = li.report_id,
--                          module_code = 'expense_reports'.
--
-- 6. All four attachments RLS policies rebuilt to call the two functions.
--    No module table names appear in any policy.
--
-- 7. attachment_deletions trigger — logs storage paths on delete so the app
--    can async-clean storage (no FK cascade on polymorphic record_id).
--
-- HOW TO EXTEND TO A NEW MODULE (e.g. Time Off)
-- ═══════════════════════════════════════════════
--   INSERT INTO module_codes   VALUES ('time_off', 'Time Off', '...');
--   INSERT INTO module_registry VALUES (
--     'time_off', 'time_off_requests', 'employee_id', 'status', 'draft', 'time_off',
--     ARRAY['time_off.edit_approval'],   -- extra view permissions
--     'time_off.edit',                   -- employee write permission
--     ARRAY['draft', 'awaiting_clarification'],
--     'time_off.edit_approval',          -- approver write permission
--     ARRAY['submitted', 'under_review', 'awaiting_clarification']
--   );
--   Done. All attachment RLS inherits automatically.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — module_codes
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS module_codes (
  code        text PRIMARY KEY,
  label       text NOT NULL,
  description text
);

COMMENT ON TABLE  module_codes IS
  'Canonical module identifiers. FK anchor for workflow_instances.module_code '
  'and attachments.module_code. Add a row here before building a new module.';

COMMENT ON COLUMN module_codes.code IS
  'Snake-case identifier, e.g. expense_reports, time_off. Must be stable — '
  'changing it requires updating all FK references.';

INSERT INTO module_codes (code, label, description) VALUES
  ('expense_reports', 'Expense Reports', 'Employee expense report submissions'),
  ('time_off',        'Time Off',        'Employee leave and absence requests')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE module_codes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS module_codes_select ON module_codes;
CREATE POLICY module_codes_select ON module_codes
  FOR SELECT USING (true);           -- readable by all authenticated users

DROP POLICY IF EXISTS module_codes_admin ON module_codes;
CREATE POLICY module_codes_admin ON module_codes
  FOR ALL USING (has_role('admin')); -- only admins write


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — module_registry
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS module_registry (
  -- Identity
  code              text  PRIMARY KEY REFERENCES module_codes(code),
  -- Core shape
  table_name        text  NOT NULL,
  owner_column      text  NOT NULL,
  status_column     text  NOT NULL,
  draft_status      text,
  permission_prefix text  NOT NULL
);

-- Add new columns idempotently so re-running this migration never fails
-- even if the table was created by an earlier partial run without these columns.
ALTER TABLE module_registry
  ADD COLUMN IF NOT EXISTS extra_view_permissions     text[],   -- beyond view_* hierarchy
  ADD COLUMN IF NOT EXISTS write_permission           text,     -- e.g. 'expense.edit'
  ADD COLUMN IF NOT EXISTS writable_statuses          text[],   -- owner-writable statuses
  ADD COLUMN IF NOT EXISTS approval_write_permission  text,     -- e.g. 'expense.edit_approval'
  ADD COLUMN IF NOT EXISTS approval_writable_statuses text[];   -- approver-writable statuses

COMMENT ON TABLE  module_registry IS
  'One row per module. Describes visibility and write rules as data so '
  'can_view_module_record() and can_write_module_record() need no module-specific '
  'code. Insert a row when adding a new module; no function or policy changes needed.';

COMMENT ON COLUMN module_registry.extra_view_permissions IS
  'Permissions outside the standard view_* naming that also grant SELECT access. '
  'Example: expense.edit_approval lets Finance/HR view attachments without view_org.';

COMMENT ON COLUMN module_registry.writable_statuses IS
  'Record statuses in which the owning employee may write attachments. '
  'Configurable so awaiting_clarification can be added without a migration.';

COMMENT ON COLUMN module_registry.approval_writable_statuses IS
  'Record statuses in which an approver (approval_write_permission holder) may '
  'write attachments. No ownership check — Finance can attach GL docs to any '
  'report in a reviewable state.';

INSERT INTO module_registry (
  code,
  table_name, owner_column, status_column, draft_status, permission_prefix,
  extra_view_permissions,
  write_permission, writable_statuses,
  approval_write_permission, approval_writable_statuses
) VALUES (
  'expense_reports',
  'expense_reports', 'employee_id', 'status', 'draft', 'expense',
  ARRAY['expense.edit_approval'],
  'expense.edit',   ARRAY['draft', 'rejected', 'awaiting_clarification'],
  'expense.edit_approval', ARRAY['submitted', 'under_review', 'awaiting_clarification']
), (
  'time_off',
  'time_off_requests', 'employee_id', 'status', 'draft', 'time_off',
  ARRAY['time_off.edit_approval'],
  'time_off.edit',  ARRAY['draft', 'rejected', 'awaiting_clarification'],
  'time_off.edit_approval', ARRAY['submitted', 'under_review', 'awaiting_clarification']
)
ON CONFLICT (code) DO NOTHING;

ALTER TABLE module_registry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS module_registry_select ON module_registry;
CREATE POLICY module_registry_select ON module_registry
  FOR SELECT USING (true);

DROP POLICY IF EXISTS module_registry_admin ON module_registry;
CREATE POLICY module_registry_admin ON module_registry
  FOR ALL USING (has_role('admin'));


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — FK on workflow_instances.module_code → module_codes
-- ─────────────────────────────────────────────────────────────────────────────
-- NOT VALID first (skips scanning existing rows on live DB), then VALIDATE.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE  table_name      = 'workflow_instances'
      AND  constraint_name = 'fk_wi_module_code'
  ) THEN
    ALTER TABLE workflow_instances
      ADD CONSTRAINT fk_wi_module_code
      FOREIGN KEY (module_code) REFERENCES module_codes(code)
      NOT VALID;
  END IF;
END $$;

ALTER TABLE workflow_instances VALIDATE CONSTRAINT fk_wi_module_code;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 — Refactor attachments schema
-- ─────────────────────────────────────────────────────────────────────────────

-- 4a. Make line_item_id nullable — stays set for expense receipts at line-item
--     granularity, but is no longer the only valid parent for an attachment.
ALTER TABLE attachments
  ALTER COLUMN line_item_id DROP NOT NULL;

-- 4b. Add record_id + module_code for record-level attachments
ALTER TABLE attachments
  ADD COLUMN IF NOT EXISTS record_id   uuid,
  ADD COLUMN IF NOT EXISTS module_code text REFERENCES module_codes(code);

-- 4c. Integrity constraints
--     • At least one parent must always be set
--     • module_code is required whenever record_id is set
--     Drop first so re-running this migration is safe.
ALTER TABLE attachments
  DROP CONSTRAINT IF EXISTS chk_attachment_has_parent,
  DROP CONSTRAINT IF EXISTS chk_attachment_module_code_with_record;

ALTER TABLE attachments
  ADD CONSTRAINT chk_attachment_has_parent
    CHECK (line_item_id IS NOT NULL OR record_id IS NOT NULL),
  ADD CONSTRAINT chk_attachment_module_code_with_record
    CHECK (record_id IS NULL OR module_code IS NOT NULL);

-- 4d. Backfill: every existing expense attachment gets
--     record_id = the expense report id, module_code = 'expense_reports'
UPDATE attachments a
SET    record_id   = li.report_id,
       module_code = 'expense_reports'
FROM   line_items li
WHERE  li.id = a.line_item_id
  AND  a.record_id IS NULL;

-- 4e. Performance indexes for RLS joins
CREATE INDEX IF NOT EXISTS idx_attachments_module_record
  ON attachments (module_code, record_id)
  WHERE record_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_attachments_line_item
  ON attachments (line_item_id)
  WHERE line_item_id IS NOT NULL;

COMMENT ON COLUMN attachments.line_item_id IS
  'Set for expense line-item receipts (sub-record granularity). '
  'NULL for record-level attachments such as time off doctor notes.';

COMMENT ON COLUMN attachments.record_id IS
  'Parent module record ID. Always set — backfilled from line_items.report_id '
  'for existing expense attachments. Used by RLS for module-agnostic visibility.';

COMMENT ON COLUMN attachments.module_code IS
  'Module owning this attachment. FK → module_codes. '
  'Required when record_id is set.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5 — can_view_module_record(module_code, record_id)
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
  v_reg      module_registry%ROWTYPE;
  v_owner_id uuid;
  v_status   text;
  v_perm     text;
BEGIN
  -- ── Look up module shape ───────────────────────────────────────────────────
  SELECT * INTO v_reg FROM module_registry WHERE code = p_module;
  IF NOT FOUND THEN RETURN false; END IF;  -- Unknown module → deny

  -- ── Fetch owner + status dynamically ──────────────────────────────────────
  -- Table/column names come from admin-controlled module_registry — safe for
  -- format(). User-supplied value only appears as $1 bind parameter.
  EXECUTE format(
    'SELECT %I, %I FROM %I WHERE id = $1',
    v_reg.owner_column, v_reg.status_column, v_reg.table_name
  )
  INTO v_owner_id, v_status
  USING p_record_id;

  IF v_owner_id IS NULL THEN RETURN false; END IF;  -- Record not found

  -- ── Admin always wins ──────────────────────────────────────────────────────
  IF has_role('admin') THEN RETURN true; END IF;

  -- ── Draft guard ────────────────────────────────────────────────────────────
  -- Only the owner sees their own drafts. All hierarchy checks below are
  -- short-circuited, which satisfies the "submitted+" requirement on
  -- view_direct / view_team / view_org without hardcoding status != 'draft'.
  IF v_reg.draft_status IS NOT NULL AND v_status = v_reg.draft_status THEN
    RETURN v_owner_id = get_my_employee_id();
  END IF;

  -- ── Standard permission hierarchy (via permission_prefix convention) ───────
  -- view_org: sees everything org-wide (Finance, HR, Dept Head, Admin)
  IF has_permission(v_reg.permission_prefix || '.view_org') THEN
    RETURN true;
  END IF;

  -- view_team: sees own org subtree (Manager Self Service, Dept Head)
  IF has_permission(v_reg.permission_prefix || '.view_team')
     AND is_in_my_org_subtree(v_owner_id)
  THEN
    RETURN true;
  END IF;

  -- view_direct: sees 1-level direct reports only (Manager Self Service)
  IF has_permission(v_reg.permission_prefix || '.view_direct')
     AND is_my_direct_report(v_owner_id)
  THEN
    RETURN true;
  END IF;

  -- view_own: sees own records only (Employee Self Service)
  IF has_permission(v_reg.permission_prefix || '.view_own')
     AND v_owner_id = get_my_employee_id()
  THEN
    RETURN true;
  END IF;

  -- ── Extra view permissions ─────────────────────────────────────────────────
  -- Permissions outside the view_* convention that also grant SELECT access.
  -- Example: expense.edit_approval allows Finance/HR to view attachments
  -- even though their primary permission is edit_approval, not view_org.
  -- (In practice Finance also has view_org, but this handles edge cases where
  -- a role has edit_approval without an explicit view permission.)
  IF v_reg.extra_view_permissions IS NOT NULL THEN
    FOREACH v_perm IN ARRAY v_reg.extra_view_permissions LOOP
      IF has_permission(v_perm) THEN RETURN true; END IF;
    END LOOP;
  END IF;

  -- ── Active workflow approver (fully module-agnostic) ───────────────────────
  -- Task assignment is the permission. No expense-specific code here.
  -- Works for every module registered in module_registry automatically.
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
  'Generic visibility check for any registered module. Reads module_registry '
  'to resolve admin, draft guard, standard hierarchy (view_org/team/direct/own), '
  'extra_view_permissions, and active workflow approver — without naming any '
  'module table. Extend by inserting a row in module_registry.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6 — can_write_module_record(module_code, record_id)
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
  v_reg      module_registry%ROWTYPE;
  v_owner_id uuid;
  v_status   text;
BEGIN
  -- ── Look up module shape ───────────────────────────────────────────────────
  SELECT * INTO v_reg FROM module_registry WHERE code = p_module;
  IF NOT FOUND THEN RETURN false; END IF;

  -- ── Fetch owner + status ───────────────────────────────────────────────────
  EXECUTE format(
    'SELECT %I, %I FROM %I WHERE id = $1',
    v_reg.owner_column, v_reg.status_column, v_reg.table_name
  )
  INTO v_owner_id, v_status
  USING p_record_id;

  IF v_owner_id IS NULL THEN RETURN false; END IF;

  -- ── Admin always wins ──────────────────────────────────────────────────────
  IF has_role('admin') THEN RETURN true; END IF;

  -- ── Path 1: Owner write ────────────────────────────────────────────────────
  -- Employee editing their own record (e.g. adding receipts to a draft expense).
  -- Requires: ownership + write_permission (e.g. expense.edit)
  --           + record is in a writable status (draft/rejected/awaiting_clarification).
  -- writable_statuses is configured in module_registry — no hardcoding here.
  IF v_reg.write_permission IS NOT NULL
     AND v_owner_id = get_my_employee_id()
     AND has_permission(v_reg.write_permission)
     AND (
       v_reg.writable_statuses IS NULL
       OR v_status = ANY(v_reg.writable_statuses)
     )
  THEN
    RETURN true;
  END IF;

  -- ── Path 2: Approver write ─────────────────────────────────────────────────
  -- Finance/HR/DeptHead attaching GL docs or adjustment notes during review.
  -- No ownership check — approvers write without owning the record.
  -- Requires: approval_write_permission (e.g. expense.edit_approval)
  --           + record is in an approval-writable status (submitted/under_review/etc.)
  IF v_reg.approval_write_permission IS NOT NULL
     AND has_permission(v_reg.approval_write_permission)
     AND (
       v_reg.approval_writable_statuses IS NULL
       OR v_status = ANY(v_reg.approval_writable_statuses)
     )
  THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION can_write_module_record(text, uuid) IS
  'Generic write-permission check for any registered module. '
  'Path 1 (owner): ownership + write_permission + writable status. '
  'Path 2 (approver): approval_write_permission + approval writable status, '
  'no ownership required (Finance can attach GL docs to any report in review). '
  'All status lists are configured in module_registry — no hardcoded values.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 7 — Rebuild all attachments RLS policies
-- ─────────────────────────────────────────────────────────────────────────────
-- Drop every previous version across all prior migrations
-- (002, 005, 007, 014, 075 — quoted and unquoted names)

DROP POLICY IF EXISTS attachments_select ON attachments;
DROP POLICY IF EXISTS attachments_insert ON attachments;
DROP POLICY IF EXISTS attachments_update ON attachments;
DROP POLICY IF EXISTS attachments_delete ON attachments;
DROP POLICY IF EXISTS "attachments_select" ON attachments;
DROP POLICY IF EXISTS "attachments_insert" ON attachments;
DROP POLICY IF EXISTS "attachments_update" ON attachments;
DROP POLICY IF EXISTS "attachments_delete" ON attachments;

-- Two paths per policy:
--   A) line_item_id set  → expense receipt (sub-record) → resolve via li.report_id
--   B) record_id set     → record-level attachment (time off, etc.) → direct lookup
--
-- Both paths delegate to can_view_module_record / can_write_module_record.
-- No module table names (expense_reports, time_off_requests, etc.) appear below.

-- ── SELECT ────────────────────────────────────────────────────────────────────
CREATE POLICY attachments_select ON attachments FOR SELECT
  USING (
    (
      line_item_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM line_items li
        WHERE  li.id = attachments.line_item_id
          AND  can_view_module_record('expense_reports', li.report_id)
      )
    )
    OR
    (
      record_id    IS NOT NULL
      AND module_code IS NOT NULL
      AND can_view_module_record(attachments.module_code, attachments.record_id)
    )
  );

-- ── INSERT ────────────────────────────────────────────────────────────────────
CREATE POLICY attachments_insert ON attachments FOR INSERT
  WITH CHECK (
    (
      line_item_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM line_items li
        WHERE  li.id = attachments.line_item_id
          AND  can_write_module_record('expense_reports', li.report_id)
      )
    )
    OR
    (
      record_id    IS NOT NULL
      AND module_code IS NOT NULL
      AND can_write_module_record(attachments.module_code, attachments.record_id)
    )
  );

-- ── UPDATE ────────────────────────────────────────────────────────────────────
CREATE POLICY attachments_update ON attachments FOR UPDATE
  USING (
    (
      line_item_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM line_items li
        WHERE  li.id = attachments.line_item_id
          AND  can_write_module_record('expense_reports', li.report_id)
      )
    )
    OR
    (
      record_id    IS NOT NULL
      AND module_code IS NOT NULL
      AND can_write_module_record(attachments.module_code, attachments.record_id)
    )
  )
  WITH CHECK (
    (
      line_item_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM line_items li
        WHERE  li.id = attachments.line_item_id
          AND  can_write_module_record('expense_reports', li.report_id)
      )
    )
    OR
    (
      record_id    IS NOT NULL
      AND module_code IS NOT NULL
      AND can_write_module_record(attachments.module_code, attachments.record_id)
    )
  );

-- ── DELETE ────────────────────────────────────────────────────────────────────
CREATE POLICY attachments_delete ON attachments FOR DELETE
  USING (
    (
      line_item_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM line_items li
        WHERE  li.id = attachments.line_item_id
          AND  can_write_module_record('expense_reports', li.report_id)
      )
    )
    OR
    (
      record_id    IS NOT NULL
      AND module_code IS NOT NULL
      AND can_write_module_record(attachments.module_code, attachments.record_id)
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 8 — Orphan cleanup: attachment_deletions log + trigger
-- ─────────────────────────────────────────────────────────────────────────────
-- line_item_id has ON DELETE CASCADE (original schema) — expense attachments
-- auto-delete when a line item is deleted. ✓
--
-- record_id has no FK (polymorphic) — no cascade. Without this trigger,
-- deleting a time off request leaves orphaned storage files with no way to
-- find them. The trigger logs the storage_path; the application reads this
-- table and calls Supabase Storage remove(), then deletes the log row.

CREATE TABLE IF NOT EXISTS attachment_deletions (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  storage_path text        NOT NULL,
  module_code  text,
  record_id    uuid,
  deleted_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE attachment_deletions IS
  'Append-only log of deleted attachments whose storage files need async cleanup. '
  'Application polls this table, calls supabase.storage.remove(storage_path) '
  'for each row, then deletes the log row. Required because Postgres cannot '
  'call Supabase Storage directly, and record_id has no FK cascade.';

CREATE OR REPLACE FUNCTION trg_log_attachment_deletion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO attachment_deletions (storage_path, module_code, record_id)
  VALUES (OLD.storage_path, OLD.module_code, OLD.record_id);
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_attachment_deletion ON attachments;
CREATE TRIGGER trg_attachment_deletion
  AFTER DELETE ON attachments
  FOR EACH ROW
  EXECUTE FUNCTION trg_log_attachment_deletion();


-- ─────────────────────────────────────────────────────────────────────────────
-- PERMISSION IMPACT SUMMARY
-- ─────────────────────────────────────────────────────────────────────────────
--
-- EXPENSE ATTACHMENTS — who sees / who writes
--
-- VIEW (can_view_module_record):
--   expense.view_org     → Finance, HR, Dept Head, Admin    → sees all org
--   expense.view_team    → Manager Self Service, Dept Head  → sees own subtree
--   expense.view_direct  → Manager Self Service             → sees 1-level reports
--   expense.view_own     → Employee Self Service            → sees own records
--   expense.edit_approval→ Finance, HR, Dept Head           → extra_view_permissions
--   (pending task)       → any assigned approver            → workflow approver clause
--
-- WRITE (can_write_module_record):
--   Path 1 (owner):
--     expense.edit       → Employee Self Service            → draft/rejected/awaiting
--   Path 2 (approver):
--     expense.edit_approval → Dept Head, Finance, HR       → submitted/under_review/awaiting
--
-- Draft guard: ALL manager/org permissions are short-circuited when
--              status = 'draft'. Only the owner sees their own drafts.
--
-- To change writable statuses (e.g. add 'returned'):
--   UPDATE module_registry
--   SET    writable_statuses = array_append(writable_statuses, 'returned')
--   WHERE  code = 'expense_reports';
--   — No migration, no function change, no policy change needed.
-- =============================================================================
