-- =============================================================================
-- Migration 200: Multi-approver step support — schema
--
-- WHY
-- ───
-- The workflow engine currently supports exactly one approver per step.
-- Some business processes require multiple sign-offs at the same step:
--   • ALL_OF — every named approver must approve before the step advances.
--     Example: dual-control — HR Manager + Finance Director must both sign.
--   • ANY_OF — the first approver to act completes the step.
--     Example: any available approver from a pool can handle the request.
--
-- BACKWARD COMPATIBILITY
-- ──────────────────────
-- approval_mode defaults to NULL. All existing single-approver steps are
-- unaffected — the engine reads workflow_step_approvers only when
-- approval_mode IS NOT NULL.
--
-- SCHEMA CHANGES
-- ──────────────
-- 1. workflow_steps.approval_mode — nullable text enum
--    NULL    = single approver (default, existing behaviour)
--    'ALL_OF' = all co-approvers must approve before step advances
--    'ANY_OF' = first co-approver to approve completes the step
--
-- 2. workflow_step_approvers — junction table
--    One row per co-approver in a multi-approver step.
--    Mirrors the approver_type/role/profile columns on workflow_steps.
--    Not consulted for single-approver steps (approval_mode IS NULL).
-- =============================================================================


-- ── 1. approval_mode column ───────────────────────────────────────────────────

ALTER TABLE workflow_steps
  ADD COLUMN IF NOT EXISTS approval_mode text
    CHECK (approval_mode IN ('ANY_OF', 'ALL_OF'));

COMMENT ON COLUMN workflow_steps.approval_mode IS
  'Multi-approver completion rule. NULL = single approver (default). '
  'ALL_OF = every co-approver in workflow_step_approvers must approve. '
  'ANY_OF = first co-approver to approve completes the step (others cancelled).';


-- ── 2. workflow_step_approvers junction table ─────────────────────────────────

CREATE TABLE IF NOT EXISTS workflow_step_approvers (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  step_id             uuid        NOT NULL
                      REFERENCES workflow_steps(id) ON DELETE CASCADE,
  approver_type       text        NOT NULL
                      CHECK (approver_type IN (
                        'MANAGER', 'ROLE', 'DEPT_HEAD', 'SPECIFIC_USER', 'RULE_BASED', 'SELF'
                      )),
  approver_role       text,       -- when approver_type IN ('ROLE', 'RULE_BASED')
  approver_profile_id uuid        REFERENCES profiles(id),  -- when approver_type = 'SPECIFIC_USER'
  sort_order          integer     NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),

  -- Role / rule-based require a role code
  CONSTRAINT wsa_role_required
    CHECK (approver_type NOT IN ('ROLE', 'RULE_BASED') OR approver_role IS NOT NULL),
  -- Specific-user requires a profile
  CONSTRAINT wsa_user_required
    CHECK (approver_type != 'SPECIFIC_USER' OR approver_profile_id IS NOT NULL)
);

COMMENT ON TABLE workflow_step_approvers IS
  'Co-approvers for a multi-approver step (approval_mode IS NOT NULL). '
  'Each row defines one approver slot; the engine creates one workflow_task per '
  'resolved approver when the step is activated.';

COMMENT ON COLUMN workflow_step_approvers.sort_order IS
  'Display order in the UI. Also controls task creation order for ALL_OF steps.';


-- ── 3. RLS ────────────────────────────────────────────────────────────────────

ALTER TABLE workflow_step_approvers ENABLE ROW LEVEL SECURITY;

-- Workflow admins / template managers: full access
CREATE POLICY wsa_manage ON workflow_step_approvers
  FOR ALL
  USING (user_can('wf_templates', 'manage', NULL));

-- Regular users: read-only (for routing-chain display in submit modal via RPC)
-- The RPC (get_workflow_participants) is SECURITY DEFINER, so this policy only
-- matters if someone queries the table directly with workflow.admin permission.
CREATE POLICY wsa_select ON workflow_step_approvers
  FOR SELECT
  USING (user_can('wf_templates', 'view', NULL));

GRANT SELECT ON workflow_step_approvers TO authenticated;


-- ── 4. Index ──────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS wsa_step_id_idx
  ON workflow_step_approvers (step_id, sort_order);


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT column_name, data_type, is_nullable, column_default
FROM   information_schema.columns
WHERE  table_name  = 'workflow_steps'
  AND  column_name = 'approval_mode';

SELECT table_name
FROM   information_schema.tables
WHERE  table_name = 'workflow_step_approvers';

-- =============================================================================
-- END OF MIGRATION 200
--
-- After applying:
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
-- =============================================================================
