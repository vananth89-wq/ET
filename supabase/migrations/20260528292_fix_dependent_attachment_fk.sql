-- =============================================================================
-- Migration 292: fix employee_dependent_attachments.dependent_id FK
--
-- PROBLEM
-- ───────
-- upsert_dependent() uses an effective-dating pattern. When the new effective_from
-- ≤ the existing row's effective_from (a full-replacement amend), the function
-- deletes the old employee_dependents row before inserting the new one.
--
-- The FK on employee_dependent_attachments.dependent_id has no ON DELETE action,
-- so PostgreSQL raises:
--
--   update or delete on table "employee_dependents" violates foreign key
--   constraint "employee_dependent_attachments_dependent_id_fkey" on table
--   "employee_dependent_attachments"
--
-- FIX
-- ───
-- Change the FK to ON DELETE SET NULL.
--
-- This is semantically correct: the migration 289 schema comment states that
-- attachments are logically linked by dependent_code (not dependent_id).
-- dependent_id is nullable version-context metadata — when the version row is
-- replaced, the attachment should survive with dependent_id = NULL, continuing
-- to be found via its dependent_code index.
--
-- No data loss: dependent_code + employee_id remain intact on every attachment.
-- =============================================================================

ALTER TABLE employee_dependent_attachments
  DROP CONSTRAINT employee_dependent_attachments_dependent_id_fkey;

ALTER TABLE employee_dependent_attachments
  ADD  CONSTRAINT employee_dependent_attachments_dependent_id_fkey
  FOREIGN KEY (dependent_id)
  REFERENCES employee_dependents(id)
  ON DELETE SET NULL;

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
DECLARE
  v_del_rule text;
BEGIN
  SELECT confdeltype INTO v_del_rule
  FROM   pg_constraint
  WHERE  conname = 'employee_dependent_attachments_dependent_id_fkey';

  ASSERT v_del_rule = 'n',
    'Expected ON DELETE SET NULL (''n'') but got: ' || COALESCE(v_del_rule, 'NULL');
END;
$$;

-- =============================================================================
-- END OF MIGRATION 292
-- =============================================================================
