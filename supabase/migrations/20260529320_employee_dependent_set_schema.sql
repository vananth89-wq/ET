-- =============================================================================
-- Migration 301: employee_dependent_set + employee_dependent_item schema
--
-- DESIGN REFERENCE
-- ────────────────
-- See docs/set-snapshot-design.md, Section 3.1.
--
-- WHAT
-- ────
-- Introduce the parent-child set-snapshot tables for employee dependents,
-- modelled after SAP SuccessFactors Employee Central.
--
--   employee_dependent_set   — effective-dated parent ("the dependent
--                              configuration as of date X"). One row per
--                              change event per employee.
--   employee_dependent_item  — children of one snapshot. Keyed by a stable
--                              dependent_code that survives snapshot
--                              transitions; that lets us track "this is
--                              Mithinaa across time" even though her row
--                              lives in a different parent.
--
-- WHY
-- ───
-- One workflow per change session instead of one per dependent.
-- Approver sees a full diff (adds + amends + removes) instead of N
-- independent tasks. Point-in-time queries become trivial.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
-- ─────────────────────────────────
-- • Does not touch employee_dependents (legacy table stays intact)
-- • Does not move attachments (mig 305 will repoint
--   employee_dependent_attachments)
-- • Does not write any RPCs (mig 302 introduces submit_dependent_set etc.)
-- • Does not backfill historical data (mig 304 handles backfill)
--
-- ROLLBACK
-- ────────
-- DROP TABLE employee_dependent_item, employee_dependent_set CASCADE;
-- (No external references yet — both tables are net-new.)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Parent table — the effective-dated container
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS employee_dependent_set (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    effective_from  DATE NOT NULL,
    effective_to    DATE NOT NULL DEFAULT '9999-12-31'::date,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_by      UUID REFERENCES profiles(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_dep_set_effective_order
      CHECK (effective_to >= effective_from)
);

COMMENT ON TABLE employee_dependent_set IS
  'Effective-dated parent of an employee''s dependent configuration. '
  'One active row per employee at any given time (uq_dep_set_active_per_employee).';
COMMENT ON COLUMN employee_dependent_set.effective_to IS
  'Sentinel ''9999-12-31'' means open-ended (currently active set).';
COMMENT ON COLUMN employee_dependent_set.is_active IS
  'Hard-deactivate flag. Closed-by-amendment historical sets keep is_active=true; '
  'is_active=false would mean the entire set was retracted.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Child table — one row per dependent inside one snapshot
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS employee_dependent_item (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    set_id              UUID NOT NULL REFERENCES employee_dependent_set(id) ON DELETE CASCADE,

    -- Stable identity across snapshots (e.g. EMP-0042_DEP_01).
    -- The same dependent in three different snapshots shares dependent_code;
    -- the row id differs because each snapshot rebuilds its items.
    dependent_code      TEXT NOT NULL,

    relationship_type   TEXT NOT NULL,          -- ref_id from DEPENDENT_RELATIONSHIP_TYPE picklist
    dependent_name      TEXT NOT NULL,
    date_of_birth       DATE NOT NULL,
    gender              TEXT NOT NULL CHECK (gender IN ('Male', 'Female')),
    insurance_eligible  BOOLEAN NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE employee_dependent_item IS
  'Children of one employee_dependent_set snapshot. dependent_code is the '
  'stable identity that survives snapshot transitions; FK to attachments '
  '(employee_dependent_attachments.dependent_code) uses this column.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────────────────────────────────────

-- Exactly one OPEN (effective_to=9999-12-31, is_active=true) set per employee.
-- This is the DB-level enforcement of "one in-flight active set per employee".
CREATE UNIQUE INDEX IF NOT EXISTS uq_dep_set_active_per_employee
  ON employee_dependent_set (employee_id)
  WHERE is_active = true AND effective_to = '9999-12-31'::date;

-- A dependent_code can only appear ONCE inside a given snapshot.
-- (Across snapshots, the same dependent_code is reused — that's how identity
-- is preserved over time.)
CREATE UNIQUE INDEX IF NOT EXISTS uq_dep_item_code_per_set
  ON employee_dependent_item (set_id, dependent_code);

-- Lookups by dependent_code (e.g. "give me every snapshot Mithinaa appeared in")
CREATE INDEX IF NOT EXISTS idx_dep_item_code
  ON employee_dependent_item (dependent_code);

-- History reads ordered newest-first
CREATE INDEX IF NOT EXISTS idx_dep_set_employee_eff_desc
  ON employee_dependent_set (employee_id, effective_from DESC);

-- set_id lookup for items
CREATE INDEX IF NOT EXISTS idx_dep_item_set_id
  ON employee_dependent_item (set_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- updated_at trigger on the parent (item rows are immutable; no updated_at)
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_dep_set_updated_at ON employee_dependent_set;
CREATE TRIGGER trg_dep_set_updated_at
  BEFORE UPDATE ON employee_dependent_set
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- Row-Level Security
--
-- Pattern mirrors the bank/dependents personal-info RLS layout from mig 296.
--   • Read paths (SELECT): Path A (target-group scope) OR Path B (HR-guard
--     for the hire pipeline)
--   • Write paths (INSERT/UPDATE/DELETE): denied at the policy level. All
--     legitimate writes flow through SECURITY DEFINER RPCs introduced in
--     mig 302 (submit_dependent_set, fn_apply_dependent_set_transition).
--     This keeps the RLS surface small and forces every write through the
--     vetted business-rule path.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE employee_dependent_set  ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_dependent_item ENABLE ROW LEVEL SECURITY;

-- ── employee_dependent_set ───────────────────────────────────────────────

DROP POLICY IF EXISTS dep_set_select ON employee_dependent_set;
CREATE POLICY dep_set_select
  ON employee_dependent_set
  FOR SELECT
  TO authenticated
  USING (
    is_super_admin()
    OR user_can('dependents', 'view', employee_id)
    OR (
      -- Path B: hire-pipeline HR-guard
      user_can('dependents', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = employee_dependent_set.employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  );

DROP POLICY IF EXISTS dep_set_insert ON employee_dependent_set;
CREATE POLICY dep_set_insert
  ON employee_dependent_set
  FOR INSERT
  TO authenticated
  WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS dep_set_update ON employee_dependent_set;
CREATE POLICY dep_set_update
  ON employee_dependent_set
  FOR UPDATE
  TO authenticated
  USING      (is_super_admin())
  WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS dep_set_delete ON employee_dependent_set;
CREATE POLICY dep_set_delete
  ON employee_dependent_set
  FOR DELETE
  TO authenticated
  USING (is_super_admin());

-- ── employee_dependent_item ──────────────────────────────────────────────

DROP POLICY IF EXISTS dep_item_select ON employee_dependent_item;
CREATE POLICY dep_item_select
  ON employee_dependent_item
  FOR SELECT
  TO authenticated
  USING (
    is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM employee_dependent_set s
      WHERE s.id = employee_dependent_item.set_id
        AND (
          user_can('dependents', 'view', s.employee_id)
          OR (
            user_can('dependents', 'view', NULL)
            AND user_can('hire_employee', 'view', NULL)
            AND EXISTS (
              SELECT 1 FROM employees e
              WHERE e.id = s.employee_id
                AND e.status IN ('Draft', 'Incomplete', 'Pending')
            )
          )
        )
    )
  );

DROP POLICY IF EXISTS dep_item_insert ON employee_dependent_item;
CREATE POLICY dep_item_insert
  ON employee_dependent_item
  FOR INSERT
  TO authenticated
  WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS dep_item_update ON employee_dependent_item;
CREATE POLICY dep_item_update
  ON employee_dependent_item
  FOR UPDATE
  TO authenticated
  USING      (is_super_admin())
  WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS dep_item_delete ON employee_dependent_item;
CREATE POLICY dep_item_delete
  ON employee_dependent_item
  FOR DELETE
  TO authenticated
  USING (is_super_admin());

-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_set_table_exists  BOOLEAN;
  v_item_table_exists BOOLEAN;
  v_idx_count         INTEGER;
  v_policy_count      INTEGER;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'employee_dependent_set'
  ) INTO v_set_table_exists;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'employee_dependent_item'
  ) INTO v_item_table_exists;

  IF NOT (v_set_table_exists AND v_item_table_exists) THEN
    RAISE EXCEPTION 'mig 301: expected both employee_dependent_set and employee_dependent_item to exist';
  END IF;

  SELECT COUNT(*) INTO v_idx_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename IN ('employee_dependent_set', 'employee_dependent_item')
    AND indexname IN (
      'uq_dep_set_active_per_employee',
      'uq_dep_item_code_per_set',
      'idx_dep_item_code',
      'idx_dep_set_employee_eff_desc',
      'idx_dep_item_set_id'
    );

  IF v_idx_count < 5 THEN
    RAISE EXCEPTION 'mig 301: expected 5 supporting indexes, found %', v_idx_count;
  END IF;

  SELECT COUNT(*) INTO v_policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('employee_dependent_set', 'employee_dependent_item');

  IF v_policy_count < 8 THEN
    RAISE EXCEPTION 'mig 301: expected 8 RLS policies (4 per table), found %', v_policy_count;
  END IF;

  RAISE NOTICE 'mig 301: employee_dependent_set + employee_dependent_item created with % indexes and % policies', v_idx_count, v_policy_count;
END
$$;
