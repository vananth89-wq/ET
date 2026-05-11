-- =============================================================================
-- Migration 137: Upgrade picklists & picklist_values RLS to user_can()
--
-- BACKGROUND
-- ──────────
-- Both tables use has_permission('reference.*') which reads from the dead
-- role_permissions table. Granular codes (view/create/edit/delete) are
-- collapsed into two Permission Matrix toggles:
--   reference.view — read access to picklists and their values
--   reference.edit — full write access to both tables
--
-- The `reference` module already exists. Both permissions are new.
-- =============================================================================


-- ── 1. Seed reference.view and reference.edit permissions ────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT p.code, p.name, p.description, m.id, p.action
FROM (VALUES
  ('reference.view', 'View Reference Data',   'Grants read access to picklists and picklist values',        'view'),
  ('reference.edit', 'Manage Reference Data', 'Grants create / update / delete on picklists and values',    'edit')
) AS p(code, name, description, action)
JOIN modules m ON m.code = 'reference'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. picklists ──────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS picklists_select ON picklists;
DROP POLICY IF EXISTS picklists_insert ON picklists;
DROP POLICY IF EXISTS picklists_update ON picklists;
DROP POLICY IF EXISTS picklists_delete ON picklists;

CREATE POLICY picklists_select ON picklists FOR SELECT
  USING (user_can('reference', 'view', NULL));

CREATE POLICY picklists_insert ON picklists FOR INSERT
  WITH CHECK (user_can('reference', 'edit', NULL));

CREATE POLICY picklists_update ON picklists FOR UPDATE
  USING      (user_can('reference', 'edit', NULL))
  WITH CHECK (user_can('reference', 'edit', NULL));

CREATE POLICY picklists_delete ON picklists FOR DELETE
  USING (user_can('reference', 'edit', NULL));


-- ── 3. picklist_values ────────────────────────────────────────────────────────

DROP POLICY IF EXISTS picklist_values_select ON picklist_values;
DROP POLICY IF EXISTS picklist_values_insert ON picklist_values;
DROP POLICY IF EXISTS picklist_values_update ON picklist_values;
DROP POLICY IF EXISTS picklist_values_delete ON picklist_values;

CREATE POLICY picklist_values_select ON picklist_values FOR SELECT
  USING (user_can('reference', 'view', NULL));

CREATE POLICY picklist_values_insert ON picklist_values FOR INSERT
  WITH CHECK (user_can('reference', 'edit', NULL));

CREATE POLICY picklist_values_update ON picklist_values FOR UPDATE
  USING      (user_can('reference', 'edit', NULL))
  WITH CHECK (user_can('reference', 'edit', NULL));

CREATE POLICY picklist_values_delete ON picklist_values FOR DELETE
  USING (user_can('reference', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('picklists', 'picklist_values')
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('reference.view', 'reference.edit')
ORDER  BY code;
