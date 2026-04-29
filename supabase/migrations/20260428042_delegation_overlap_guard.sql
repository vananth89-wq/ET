-- =============================================================================
-- Delegation overlap guard
--
-- Prevents a delegator from having two active delegations that:
--   • target the same template scope (NULL = all templates), AND
--   • have overlapping date ranges
--
-- This makes wf_resolve_approver deterministic — it can never find more than
-- one matching active delegation for a given delegator + template + date.
--
-- Implementation: PostgreSQL EXCLUDE constraint using the btree_gist extension
-- (available on Supabase by default). The constraint uses:
--   • delegator_id  = equality
--   • template_id   = equality (NULLs treated as equal via IS NOT DISTINCT FROM)
--   • daterange     = overlaps (&&)
--   • is_active     = only enforced when both rows are active
--
-- Because EXCLUDE cannot use IS NOT DISTINCT FROM natively for NULLs, we use
-- a generated column trick: coalesce template_id to a sentinel UUID so that
-- NULL = NULL comparisons work correctly in the exclusion constraint.
-- =============================================================================

-- Prerequisite: btree_gist (already enabled on Supabase)
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Sentinel UUID used in place of NULL template_id for the exclusion index.
-- Must be a fixed value that can never be a real template id.
-- We use the nil UUID (all zeros).
DO $$
BEGIN
  -- Add the coalesced template column used by the exclusion index
  ALTER TABLE workflow_delegations
    ADD COLUMN IF NOT EXISTS template_id_coalesced uuid
      GENERATED ALWAYS AS (
        COALESCE(template_id, '00000000-0000-0000-0000-000000000000'::uuid)
      ) STORED;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'template_id_coalesced column may already exist: %', SQLERRM;
END;
$$;

-- Exclusion constraint: no two ACTIVE delegations for the same
-- delegator + template scope may have overlapping date ranges.
ALTER TABLE workflow_delegations
  DROP CONSTRAINT IF EXISTS wf_delegations_no_overlap;

ALTER TABLE workflow_delegations
  ADD CONSTRAINT wf_delegations_no_overlap
  EXCLUDE USING gist (
    delegator_id           WITH =,
    template_id_coalesced  WITH =,
    daterange(from_date, to_date, '[]') WITH &&
  )
  WHERE (is_active = true);

COMMENT ON CONSTRAINT wf_delegations_no_overlap ON workflow_delegations IS
  'Prevents two active delegations for the same delegator and template scope '
  'from having overlapping date ranges. Ensures wf_resolve_approver always '
  'finds at most one matching delegation. Uses btree_gist for mixed-type exclusion.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT conname, contype
FROM   pg_constraint
WHERE  conrelid = 'workflow_delegations'::regclass
  AND  conname  = 'wf_delegations_no_overlap';
