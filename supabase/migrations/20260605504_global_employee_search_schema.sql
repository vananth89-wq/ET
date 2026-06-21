-- =============================================================================
-- Migration 501: Global Employee Search — Schema foundations
--
-- 1. pg_trgm extension (idempotent)
-- 2. employees.searchable_text — STORED generated column
-- 3. GIN trigram index on searchable_text
-- 4. New module: employee_search
-- 5. New permissions: employee_search.view, employee_search.view_inactive
-- 6. workflow_instances.initiated_by_actor_id — "on behalf of" actor stamp
--
-- Key corrections vs design doc:
--   - employees table uses 'name' (not full_name) and 'employee_id' (not employee_code)
--   - 'business_email' is the primary email column (personal_email is secondary)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. pg_trgm extension
-- ─────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Generated searchable_text column on employees
--    Combines employee_id (code), name, and business_email for trigram search.
--    STORED = computed once on write, indexed directly.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS searchable_text TEXT
    GENERATED ALWAYS AS (
      COALESCE(employee_id,     '') || ' ' ||
      COALESCE(name,            '') || ' ' ||
      COALESCE(business_email,  '')
    ) STORED;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. GIN trigram index — powers ILIKE and similarity() in search_employees
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS ix_employees_searchable_trgm
  ON employees USING gin (searchable_text gin_trgm_ops);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Module: employee_search
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO modules (code, name, active, sort_order)
VALUES (
  'employee_search',
  'Employee Search',
  true,
  (SELECT COALESCE(MAX(sort_order), 0) + 10 FROM modules)
)
ON CONFLICT (code) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5a. Expand permissions_action_check to allow 'view_inactive'
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE permissions DROP CONSTRAINT IF EXISTS permissions_action_check;
ALTER TABLE permissions ADD CONSTRAINT permissions_action_check
  CHECK (action IN ('view', 'create', 'edit', 'delete', 'history', 'lookup',
                    'view_all_pending', 'edit_all_pending',
                    'bulk_import', 'bulk_export',
                    'view_inactive'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 5b. Permissions: employee_search.view + employee_search.view_inactive
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'employee_search';

  IF v_module_id IS NULL THEN
    RAISE EXCEPTION 'employee_search module not found — cannot seed permissions';
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    (
      'employee_search.view',
      v_module_id,
      'view',
      'Employee Search — Search',
      'Display the employee search box in the header and navigate to other employees'' profiles.'
    ),
    (
      'employee_search.view_inactive',
      v_module_id,
      'view_inactive',
      'Employee Search — Include Inactive',
      'Search for and view inactive employees (shown with an amber "Inactive" banner).'
    )
  ON CONFLICT (code) DO NOTHING;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. workflow_instances.initiated_by_actor_id
--    Populated by wf_submit (mig 503) when subject_employee ≠ actor.
--    NULL for self-service submissions.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE workflow_instances
  ADD COLUMN IF NOT EXISTS initiated_by_actor_id UUID
    REFERENCES profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN workflow_instances.initiated_by_actor_id IS
  'Profile ID of the user who submitted this workflow on behalf of another '
  'employee. NULL for self-service submissions (subject = actor). '
  'Populated by wf_submit when p_subject_employee_id is supplied and '
  'differs from the submitter''s own employee_id. '
  'Used to render "Submitted by [actor] on behalf of [subject]" in '
  'ApproverInbox and the subject''s workflow view (decision #22).';

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- searchable_text column exists
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_name = 'employees' AND column_name = 'searchable_text'
  ), 'employees.searchable_text column missing';

  -- GIN index exists
  ASSERT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE  tablename = 'employees' AND indexname = 'ix_employees_searchable_trgm'
  ), 'ix_employees_searchable_trgm index missing';

  -- permissions seeded
  ASSERT EXISTS (SELECT 1 FROM permissions WHERE code = 'employee_search.view'),
    'employee_search.view permission missing';
  ASSERT EXISTS (SELECT 1 FROM permissions WHERE code = 'employee_search.view_inactive'),
    'employee_search.view_inactive permission missing';

  -- workflow_instances column exists
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_name = 'workflow_instances' AND column_name = 'initiated_by_actor_id'
  ), 'workflow_instances.initiated_by_actor_id column missing';

  RAISE NOTICE 'Mig 501 verification passed.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 501
-- =============================================================================
