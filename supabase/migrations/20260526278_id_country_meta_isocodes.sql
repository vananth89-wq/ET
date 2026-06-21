-- =============================================================================
-- Migration 278 — Populate meta.isoCode on ID_COUNTRY picklist values
-- =============================================================================
--
-- PROBLEM
-- ───────
-- Migration 003 seeded ID_COUNTRY rows with value + ref_id only.
-- Migration 006 defined the meta_fields schema (isoCode, currencyId) on the
-- picklist definition, but did NOT populate meta on individual rows.
--
-- EFFECT
-- ──────
-- get_bank_picklist() filters BANK rows via:
--   ID_COUNTRY.meta->>'isoCode' = p_country_iso_code
-- Since meta was NULL on all rows, the RPC always returned [].
--
-- FIX
-- ───
-- Set meta.isoCode (alpha-3 ISO 3166-1) on every seeded ID_COUNTRY row using
-- its ref_id as the lookup key.  Merge with any existing meta so admin-entered
-- currencyId values are preserved.
-- =============================================================================

-- In PostgreSQL UPDATE...FROM, the target table alias cannot be referenced
-- inside the FROM clause's JOIN ON. Move the picklists join to WHERE instead.
UPDATE picklist_values pv
SET    meta = COALESCE(pv.meta, '{}'::jsonb) || jsonb_build_object('isoCode', v.iso_code)
FROM (VALUES
  ('G001', 'IND'),   -- India
  ('G002', 'SAU'),   -- Saudi Arabia
  ('G003', 'ARE'),   -- United Arab Emirates
  ('G004', 'MYS'),   -- Malaysia
  ('G005', 'SGP'),   -- Singapore
  ('G006', 'USA'),   -- United States
  ('G007', 'GBR'),   -- United Kingdom
  ('G008', 'QAT'),   -- Qatar
  ('G009', 'KWT'),   -- Kuwait
  ('G010', 'BHR'),   -- Bahrain
  ('G011', 'OMN'),   -- Oman
  ('G012', 'PAK'),   -- Pakistan
  ('G013', 'LKA'),   -- Sri Lanka
  ('G014', 'BGD'),   -- Bangladesh
  ('G015', 'NPL')    -- Nepal
) AS v(ref_id, iso_code)
WHERE pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'ID_COUNTRY')
  AND pv.ref_id      = v.ref_id;

-- Verify
SELECT pv.ref_id, pv.value, pv.meta->>'isoCode' AS iso_code
FROM   picklist_values pv
JOIN   picklists pl ON pl.id = pv.picklist_id
WHERE  pl.picklist_id = 'ID_COUNTRY'
ORDER  BY pv.ref_id;
