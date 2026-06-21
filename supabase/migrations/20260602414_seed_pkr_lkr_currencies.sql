-- =============================================================================
-- Migration 414 — Seed PKR & LKR; wire meta.currencyId for Pakistan & Sri Lanka
-- =============================================================================
--
-- PROBLEM
-- ───────
-- Migration 003 seeded the currencies table with 15 currencies (INR → BHD)
-- and the CURRENCY picklist with C001–C015. Pakistani Rupee (PKR) and Sri
-- Lankan Rupee (LKR) were never added.
--
-- As a result, ID_COUNTRY rows G012 (Pakistan) and G013 (Sri Lanka) have no
-- meta.currencyId, so the AddEmployee / EmployeeEditPanel auto-currency lookup
-- silently returns nothing (or shows Indian Rupee if an old value is cached).
-- The LOCATION picklist entries (L024–L027) and isoCode meta already exist.
--
-- FIX
-- ───
-- 1. Insert PKR / LKR into the currencies table.
-- 2. Insert C016 / C017 into the CURRENCY picklist_values.
-- 3. Merge meta.currencyId onto G012 / G013 ID_COUNTRY picklist rows.
-- =============================================================================

-- ── Step 1: Add currencies ───────────────────────────────────────────────────
INSERT INTO currencies (code, name, symbol, active)
VALUES
  ('PKR', 'Pakistani Rupee',  '₨',  true),
  ('LKR', 'Sri Lankan Rupee', 'Rs', true)
ON CONFLICT (code) DO NOTHING;

-- ── Step 2: Add to CURRENCY picklist ─────────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.value, v.ref_id, true
FROM picklists pl,
(VALUES
  ('C016', 'Pakistani Rupee'),
  ('C017', 'Sri Lankan Rupee')
) AS v(ref_id, value)
WHERE pl.picklist_id = 'CURRENCY'
ON CONFLICT DO NOTHING;

-- ── Step 3: Wire meta.currencyId on G012/G013 ID_COUNTRY rows ────────────────
-- currencyId stores the picklist_values.id (UUID) of the CURRENCY entry,
-- matching the pattern used by all other countries.
UPDATE picklist_values pv
SET    meta = COALESCE(pv.meta, '{}'::jsonb)
            || jsonb_build_object(
                 'currencyId',
                 (SELECT cv.id::text
                  FROM   picklist_values cv
                  JOIN   picklists cp ON cp.id = cv.picklist_id
                  WHERE  cp.picklist_id = 'CURRENCY'
                    AND  cv.ref_id = map.currency_ref_id)
               )
FROM (VALUES
  ('G012', 'C016'),   -- Pakistan → Pakistani Rupee
  ('G013', 'C017')    -- Sri Lanka → Sri Lankan Rupee
) AS map(country_ref_id, currency_ref_id)
JOIN picklists pl ON pl.picklist_id = 'ID_COUNTRY'
WHERE pv.picklist_id = pl.id
  AND pv.ref_id      = map.country_ref_id;

-- ── Verify ───────────────────────────────────────────────────────────────────
SELECT pv.ref_id, pv.value,
       pv.meta->>'isoCode'    AS iso_code,
       pv.meta->>'currencyId' AS currency_pl_id,
       cv.value               AS currency_name
FROM   picklist_values pv
JOIN   picklists pl  ON pl.id  = pv.picklist_id AND pl.picklist_id = 'ID_COUNTRY'
LEFT JOIN picklist_values cv ON cv.id = (pv.meta->>'currencyId')::uuid
WHERE  pv.ref_id IN ('G012','G013')
ORDER  BY pv.ref_id;

-- =============================================================================
-- END OF MIGRATION 20260602414_seed_pkr_lkr_currencies.sql
-- =============================================================================
