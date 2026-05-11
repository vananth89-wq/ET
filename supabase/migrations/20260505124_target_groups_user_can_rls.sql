-- =============================================================================
-- Migration 124: Upgrade target_groups & target_group_members RLS to user_can()
--
-- BACKGROUND
-- ──────────
-- The 7 write/delete policies on these two tables still use has_role('admin')
-- directly.  This bypasses the Permission Matrix UI entirely — granting
-- "Target Groups" admin access in the UI has zero effect on enforcement.
--
-- Migration 091 already seeded the sec_target_groups module with a .view
-- permission for UI access-gate. We add sec_target_groups.edit here as the
-- write-gate, then replace all has_role('admin') policies with user_can().
--
-- Note: user_can() is SECURITY DEFINER (runs as superuser), so it can read
-- target_groups/target_group_members internally even after these policies
-- are applied — no circular dependency.
--
-- POLICIES CHANGED
-- ────────────────
--   target_groups       → tg_insert, tg_update, tg_delete
--   target_group_members → tgm_insert, tgm_delete
--
-- POLICIES UNCHANGED
-- ──────────────────
--   target_groups        → tg_select  (USING true — reads needed for matrix UI)
--   target_group_members → tgm_select (USING true — needed by user_can() Path D)
--
-- WHAT IS DROPPED
-- ───────────────
--   Old: has_role('admin')
--   New: user_can('sec_target_groups', 'edit', NULL)
--        (super admin bypass is Path A inside user_can() — migration 113)
-- =============================================================================


-- ── 1. Seed sec_target_groups.edit permission ─────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'sec_target_groups.edit'                                    AS code,
  'Manage Target Groups'                                      AS name,
  'Grants create / update / delete access to Target Groups'  AS description,
  m.id                                                        AS module_id,
  'edit'                                                      AS action
FROM modules m
WHERE m.code = 'sec_target_groups'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. target_groups: replace 3 write/delete policies ────────────────────────

DROP POLICY IF EXISTS tg_insert ON target_groups;
DROP POLICY IF EXISTS tg_update ON target_groups;
DROP POLICY IF EXISTS tg_delete ON target_groups;

CREATE POLICY tg_insert ON target_groups
  FOR INSERT
  WITH CHECK (user_can('sec_target_groups', 'edit', NULL));

CREATE POLICY tg_update ON target_groups
  FOR UPDATE
  USING (user_can('sec_target_groups', 'edit', NULL));

-- Preserve the NOT is_system guard that prevents deletion of system-seeded groups.
CREATE POLICY tg_delete ON target_groups
  FOR DELETE
  USING (user_can('sec_target_groups', 'edit', NULL) AND NOT is_system);


-- ── 3. target_group_members: replace 2 write/delete policies ─────────────────
--
-- These rows are written exclusively by sync_target_group_members() which is
-- SECURITY DEFINER (bypasses RLS). The policies below govern any direct access.

DROP POLICY IF EXISTS tgm_insert ON target_group_members;
DROP POLICY IF EXISTS tgm_delete ON target_group_members;

CREATE POLICY tgm_insert ON target_group_members
  FOR INSERT
  WITH CHECK (user_can('sec_target_groups', 'edit', NULL));

CREATE POLICY tgm_delete ON target_group_members
  FOR DELETE
  USING (user_can('sec_target_groups', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────
-- Expected: no tg_* or tgm_* policies reference has_role; only user_can() used.

SELECT
  tablename,
  policyname,
  cmd,
  qual
FROM pg_policies
WHERE tablename IN ('target_groups', 'target_group_members')
ORDER BY tablename, cmd, policyname;

-- Expected: sec_target_groups.edit is present in permissions table.
SELECT code, name, action
FROM   permissions
WHERE  code IN ('sec_target_groups.view', 'sec_target_groups.edit')
ORDER  BY code;
