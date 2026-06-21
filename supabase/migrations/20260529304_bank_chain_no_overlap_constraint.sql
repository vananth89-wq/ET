-- =============================================================================
-- Migration 304: Prevent overlapping effective-date ranges within a bank chain
--
-- Edge case flagged in mig 302:
--   Mig 302's DELETE-vs-UPDATE close-out fixes chk_bank_effective_order
--   violations for same-day/backdated amendments — but if a chain already has
--   older CLOSED history rows, a backdated amend can produce date-range
--   OVERLAP between the new row and an existing closed row. No schema-level
--   guard exists today.
--
-- Worked example (the gap mig 302 leaves open):
--   X (closed):  effective_from = 2026-01-01, effective_to = 2026-03-31
--   Y (active):  effective_from = 2026-04-01, effective_to = 9999-12-31
--   Admin amends with p_effective_from = 2026-03-01.
--   Mig 302 DELETE branch fires (Y.effective_from = 2026-04-01 >= 2026-03-01),
--   removes Y, inserts new row [2026-03-01, 9999-12-31] — which now overlaps
--   X's [2026-01-01, 2026-03-31] on March 1-31. No constraint complains.
--
-- Fix: EXCLUDE USING gist on (employee_id, bank_account_group_id, daterange).
--   • employee_id WITH =          — only flag overlaps within the same employee
--   • bank_account_group_id WITH = — only flag overlaps within the same chain
--     (parallel accounts in different chains may legitimately overlap in time)
--   • daterange(...) WITH &&      — overlap operator on inclusive date ranges
--
-- Requires btree_gist extension for uuid `=` in gist indexes. Already standard
-- on Supabase but `CREATE EXTENSION IF NOT EXISTS` is defensive.
--
-- Pre-flight: counts existing overlaps. If any are found the migration aborts
-- with a diagnostic that lists the row pairs, so the operator can clean up
-- before retrying.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Extension
-- ─────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Pre-flight: refuse to add the constraint if existing rows overlap
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_overlap_count int;
  v_sample        text;
BEGIN
  SELECT count(*)
    INTO v_overlap_count
    FROM employee_bank_accounts a
    JOIN employee_bank_accounts b
      ON a.employee_id           = b.employee_id
     AND a.bank_account_group_id = b.bank_account_group_id
     AND a.id < b.id
     AND daterange(a.effective_from, a.effective_to, '[]')
         && daterange(b.effective_from, b.effective_to, '[]');

  IF v_overlap_count > 0 THEN
    -- Build a sample diagnostic (first 5 offending pairs) for the abort message
    SELECT string_agg(line, E'\n')
      INTO v_sample
      FROM (
        SELECT format(
          '  • employee=%s group=%s — row %s [%s..%s] overlaps row %s [%s..%s]',
          a.employee_id, a.bank_account_group_id,
          a.id, a.effective_from, a.effective_to,
          b.id, b.effective_from, b.effective_to
        ) AS line
        FROM employee_bank_accounts a
        JOIN employee_bank_accounts b
          ON a.employee_id           = b.employee_id
         AND a.bank_account_group_id = b.bank_account_group_id
         AND a.id < b.id
         AND daterange(a.effective_from, a.effective_to, '[]')
             && daterange(b.effective_from, b.effective_to, '[]')
        LIMIT 5
      ) s;

    RAISE EXCEPTION
      E'Migration 304 aborted: % overlapping date ranges found within bank account chains.\nSample:\n%',
      v_overlap_count, v_sample;
  END IF;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. EXCLUDE constraint
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE employee_bank_accounts
  ADD CONSTRAINT no_bank_chain_overlap
  EXCLUDE USING gist (
    employee_id           WITH =,
    bank_account_group_id WITH =,
    daterange(effective_from, effective_to, '[]') WITH &&
  );

COMMENT ON CONSTRAINT no_bank_chain_overlap
  ON employee_bank_accounts IS
  'No two rows in the same (employee_id, bank_account_group_id) chain may have '
  'overlapping [effective_from, effective_to] ranges. Parallel accounts in '
  'different chains may legitimately overlap. Mig 304.';


-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  ASSERT (
    SELECT count(*)
      FROM pg_constraint
     WHERE conname = 'no_bank_chain_overlap'
       AND conrelid = 'employee_bank_accounts'::regclass
  ) = 1, 'no_bank_chain_overlap not found after migration 304';

  RAISE NOTICE 'Migration 304 verified: no_bank_chain_overlap exclude constraint in place.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 304
--
-- Behavioral notes:
--   • Mig 302's DELETE close-out branch still works for the common case
--     (no closed history in the chain) — no overlap to produce.
--   • Backdated amendments that cross closed history rows will now fail with
--     a constraint violation. The upsert_bank_account EXCEPTION WHEN OTHERS
--     block surfaces SQLERRM to the user. A friendlier RPC-level pre-check
--     could be layered on later — out of scope for this migration.
--   • ESS users are unaffected: mig 299's "effective_from = current month 1st"
--     rule means they never backdate.
--
-- Post-migration:
--   npx supabase db push
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
-- =============================================================================
