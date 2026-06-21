-- =============================================================================
-- Migration 323: backfill active dependent sets from legacy employee_dependents
--
-- DESIGN REFERENCE
-- ────────────────
-- docs/set-snapshot-design.md §8.1 (Backfill — Dependents).
--
-- WHAT
-- ────
-- For every employee with active dependents in the legacy table
-- (employee_dependents.is_active=true AND effective_to='9999-12-31'),
-- create ONE active set in employee_dependent_set + one item per active
-- dependent in employee_dependent_item. Items reuse the existing
-- dependent_code so attachments (joined by code) continue to resolve.
--
-- WHAT THIS MIGRATION INTENTIONALLY DOES *NOT* DO
-- ───────────────────────────────────────────────
-- • Does NOT backfill historical sets (amendment-closed rows). The design
--   doc §8.1 sketched a clustering approach but in practice the per-dep
--   timeline can't be cleanly reconstructed into a set timeline — different
--   dependents amend on different dates. Legacy rows preserve the per-dep
--   history; if pre-cutover history rendering is needed, the frontend can
--   continue to read the legacy table until the cleanup phase drops it.
-- • Does NOT rename employee_dependents to _legacy. The legacy RPCs
--   (upsert_dependent, remove_dependent, get_employee_dependents) still
--   reference the original table name; renaming now would break them
--   instantly. The rename + RPC drop happens in the cleanup phase (Phase 6),
--   ≥2 weeks after the new portlet ships and the dual-path UX stabilises.
-- • Does NOT delete legacy data. Both tables co-exist during the
--   migration window. Reads via the new RPCs see the new tables;
--   legacy RPCs continue to work against the legacy table. Frontend
--   chooses which to call.
--
-- IDEMPOTENCY
-- ───────────
-- Two NOT-EXISTS / NOT-IN guards make this re-runnable:
--   1. Only insert an active set for an employee who doesn't already
--      have one (so a partial re-apply skips employees we already converted).
--   2. Only insert an item for (set_id, dependent_code) pairs that don't
--      already exist (so a re-apply on the same set is a no-op).
--
-- ROLLBACK
-- ────────
-- DELETE FROM employee_dependent_item
--   WHERE set_id IN (SELECT id FROM employee_dependent_set);
-- DELETE FROM employee_dependent_set;
-- Legacy data is untouched, so the rollback is total.
-- =============================================================================


DO $$
DECLARE
  v_eligible_employees INTEGER;
  v_sets_before        INTEGER;
  v_sets_after         INTEGER;
  v_items_before       INTEGER;
  v_items_after        INTEGER;
  v_legacy_active_rows INTEGER;
BEGIN
  -- Defensive: skip the whole migration if the legacy table is absent
  -- (e.g. a fresh-install deployment that never ran mig 289).
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'employee_dependents'
  ) THEN
    RAISE NOTICE 'mig 323: employee_dependents table not present — nothing to backfill';
    RETURN;
  END IF;

  -- ── Snapshot pre-backfill counts for the verification block ────────────
  SELECT COUNT(DISTINCT employee_id)
    INTO v_eligible_employees
  FROM employee_dependents
  WHERE is_active = true
    AND effective_to = '9999-12-31'::date;

  SELECT COUNT(*) INTO v_sets_before  FROM employee_dependent_set;
  SELECT COUNT(*) INTO v_items_before FROM employee_dependent_item;

  SELECT COUNT(*)
    INTO v_legacy_active_rows
  FROM employee_dependents
  WHERE is_active = true
    AND effective_to = '9999-12-31'::date;

  RAISE NOTICE
    'mig 323 (pre): % eligible employees, % legacy active rows, % existing sets, % existing items',
    v_eligible_employees, v_legacy_active_rows, v_sets_before, v_items_before;

  -- ── 1. Create one active set per eligible employee ─────────────────────
  INSERT INTO employee_dependent_set (
    employee_id,
    effective_from,
    effective_to,
    is_active,
    created_by,
    created_at,
    updated_at
  )
  SELECT
    d.employee_id,
    MIN(d.effective_from),                      -- earliest-known active = set's effective_from
    '9999-12-31'::date,
    true,
    NULL,                                       -- backfilled by system, not a profile
    NOW(),
    NOW()
  FROM employee_dependents d
  WHERE d.is_active   = true
    AND d.effective_to = '9999-12-31'::date
    AND NOT EXISTS (
      -- Idempotency guard: skip employees who already have a set
      SELECT 1
      FROM employee_dependent_set s
      WHERE s.employee_id   = d.employee_id
        AND s.is_active     = true
        AND s.effective_to  = '9999-12-31'::date
    )
  GROUP BY d.employee_id;

  -- ── 2. Insert items for each active legacy dependent ──────────────────
  -- Joins each legacy active row to its employee's brand-new active set,
  -- preserving the dependent_code so attachments (keyed by code) continue
  -- to resolve through both old and new RPCs.
  INSERT INTO employee_dependent_item (
    set_id,
    dependent_code,
    relationship_type,
    dependent_name,
    date_of_birth,
    gender,
    insurance_eligible,
    created_at
  )
  SELECT
    s.id,
    d.dependent_code,
    d.relationship_type,
    d.dependent_name,
    d.date_of_birth,
    d.gender,
    COALESCE(d.insurance_eligible, false),
    NOW()
  FROM employee_dependents d
  JOIN employee_dependent_set s
    ON s.employee_id   = d.employee_id
   AND s.is_active     = true
   AND s.effective_to  = '9999-12-31'::date
  WHERE d.is_active    = true
    AND d.effective_to = '9999-12-31'::date
    AND NOT EXISTS (
      -- Idempotency guard: skip (set_id, dependent_code) already present
      SELECT 1
      FROM employee_dependent_item i
      WHERE i.set_id         = s.id
        AND i.dependent_code = d.dependent_code
    );

  -- ── Post-backfill counts ───────────────────────────────────────────────
  SELECT COUNT(*) INTO v_sets_after  FROM employee_dependent_set;
  SELECT COUNT(*) INTO v_items_after FROM employee_dependent_item;

  RAISE NOTICE
    'mig 323 (post): % sets (+%), % items (+%)',
    v_sets_after,  (v_sets_after  - v_sets_before),
    v_items_after, (v_items_after - v_items_before);

  -- ── Invariant checks ───────────────────────────────────────────────────
  -- Every eligible employee should now have exactly one active set.
  DECLARE
    v_missing_sets INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO v_missing_sets
    FROM (
      SELECT DISTINCT employee_id
      FROM employee_dependents
      WHERE is_active = true AND effective_to = '9999-12-31'::date
    ) eligible
    WHERE NOT EXISTS (
      SELECT 1
      FROM employee_dependent_set s
      WHERE s.employee_id  = eligible.employee_id
        AND s.is_active    = true
        AND s.effective_to = '9999-12-31'::date
    );

    IF v_missing_sets > 0 THEN
      RAISE EXCEPTION
        'mig 323: % eligible employees still lack an active set after backfill',
        v_missing_sets;
    END IF;
  END;

  -- Every active legacy row should be mirrored as an item in its employee's set.
  DECLARE
    v_missing_items INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO v_missing_items
    FROM employee_dependents d
    WHERE d.is_active    = true
      AND d.effective_to = '9999-12-31'::date
      AND NOT EXISTS (
        SELECT 1
        FROM employee_dependent_item i
        JOIN employee_dependent_set s
          ON s.id          = i.set_id
         AND s.employee_id = d.employee_id
         AND s.is_active   = true
         AND s.effective_to = '9999-12-31'::date
        WHERE i.dependent_code = d.dependent_code
      );

    IF v_missing_items > 0 THEN
      RAISE EXCEPTION
        'mig 323: % active legacy dependents have no matching set item after backfill',
        v_missing_items;
    END IF;
  END;

  -- No employee should have more than one active set (the partial unique
  -- index uq_dep_set_active_per_employee guarantees this, but we double-check
  -- in case the index was somehow dropped).
  DECLARE
    v_duplicate_sets INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO v_duplicate_sets
    FROM (
      SELECT employee_id, COUNT(*) AS c
      FROM employee_dependent_set
      WHERE is_active = true AND effective_to = '9999-12-31'::date
      GROUP BY employee_id
      HAVING COUNT(*) > 1
    ) dup;

    IF v_duplicate_sets > 0 THEN
      RAISE EXCEPTION
        'mig 323: % employees ended up with more than one active set',
        v_duplicate_sets;
    END IF;
  END;

  RAISE NOTICE
    'mig 323: backfill complete — % active sets, % items now mirror legacy state',
    v_sets_after, v_items_after;
END
$$;
