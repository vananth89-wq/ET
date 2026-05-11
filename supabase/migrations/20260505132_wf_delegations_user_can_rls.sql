-- =============================================================================
-- Migration 132: Upgrade workflow_delegations RLS to user_can()
--
-- BACKGROUND
-- ──────────
-- workflow_delegations currently has 5 active policies:
--   wf_delegations_admin       (migration 030) — FOR ALL, has_role('admin')
--   wf_delegations_select      (migration 057) — has_role + has_permission + parties
--   wf_delegations_own         (migration 057) — INSERT, delegator + has_role + has_perm
--   wf_delegations_self_update (migration 057) — delegator + has_role + has_perm
--   wf_delegations_self_delete (migration 057) — delegator + has_role + has_perm
--
-- wf_delegations_admin (FOR ALL) was never explicitly dropped by migration 057,
-- so it coexists with the four specific policies — Postgres ORs all of them.
--
-- SELF-SERVICE PATTERN PRESERVED
-- ───────────────────────────────
-- Delegators retain the right to create, edit and cancel their own delegations
-- without needing wf_delegations.edit. Only admin-level cross-user operations
-- require the permission matrix grant.
--
-- POLICIES AFTER THIS MIGRATION
-- ──────────────────────────────
--   SELECT  — parties to the delegation OR wf_delegations.view
--   INSERT  — delegator creating own OR wf_delegations.edit
--   UPDATE  — delegator editing own   OR wf_delegations.edit
--   DELETE  — delegator cancelling own OR wf_delegations.edit
-- =============================================================================


-- ── 1. Seed wf_delegations.edit permission ────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_delegations.edit'                                              AS code,
  'Manage Delegations'                                               AS name,
  'Grants admin-level create / update / delete on any delegation'   AS description,
  m.id                                                               AS module_id,
  'edit'                                                             AS action
FROM modules m
WHERE m.code = 'wf_delegations'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. Drop all existing policies ────────────────────────────────────────────

DROP POLICY IF EXISTS wf_delegations_admin       ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_select      ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_own         ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_self_update ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_self_delete ON workflow_delegations;


-- ── 3. Recreate with user_can() ───────────────────────────────────────────────

-- SELECT: both parties always see their own rows; admin sees all.
CREATE POLICY wf_delegations_select ON workflow_delegations FOR SELECT
  USING (
    delegator_id = auth.uid()
    OR delegate_id  = auth.uid()
    OR user_can('wf_delegations', 'view', NULL)
  );

-- INSERT: users create their own delegations; admins create for anyone.
CREATE POLICY wf_delegations_insert ON workflow_delegations FOR INSERT
  WITH CHECK (
    delegator_id = auth.uid()
    OR user_can('wf_delegations', 'edit', NULL)
  );

-- UPDATE: delegator edits own; admins edit any.
CREATE POLICY wf_delegations_update ON workflow_delegations FOR UPDATE
  USING (
    delegator_id = auth.uid()
    OR user_can('wf_delegations', 'edit', NULL)
  )
  WITH CHECK (
    delegator_id = auth.uid()
    OR user_can('wf_delegations', 'edit', NULL)
  );

-- DELETE: delegator cancels own; admins delete any.
CREATE POLICY wf_delegations_delete ON workflow_delegations FOR DELETE
  USING (
    delegator_id = auth.uid()
    OR user_can('wf_delegations', 'edit', NULL)
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename = 'workflow_delegations'
ORDER BY cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('wf_delegations.view', 'wf_delegations.edit')
ORDER  BY code;
