-- =============================================================================
-- Migration : 20260420006_picklists_extend.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-04-20
-- Description: Extends the picklists table with three UI-configuration columns
--              that were previously kept only in frontend localStorage:
--
--   parent_picklist_id  — hierarchy link (e.g. ID_TYPE is a child of ID_COUNTRY)
--   system              — marks built-in picklists that users cannot delete
--   meta_fields         — JSONB array describing extra key/value columns per value
--                         e.g. [{"key":"isoCode","label":"ISO Code","type":"text"}]
--
--              Also seeds those values for all built-in picklist rows.
-- =============================================================================

-- ── 1. Add columns ────────────────────────────────────────────────────────────

ALTER TABLE picklists
  ADD COLUMN IF NOT EXISTS parent_picklist_id  UUID     REFERENCES picklists(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS system              BOOLEAN  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS meta_fields         JSONB    NOT NULL DEFAULT '[]';

-- ── 2. Seed system flag + meta_fields for built-in picklists ─────────────────
--      Uses a CTE so each UPDATE can reference the sibling row by picklist_id.

WITH rows AS (
  SELECT id, picklist_id FROM picklists
)
UPDATE picklists p
SET
  system      = true,
  meta_fields = CASE r.picklist_id
    WHEN 'CURRENCY' THEN '[
      {"key":"code",   "label":"ISO Code", "type":"text"},
      {"key":"symbol", "label":"Symbol",   "type":"text"}
    ]'::jsonb
    WHEN 'ID_COUNTRY' THEN '[
      {"key":"isoCode",    "label":"ISO Code",          "type":"text"},
      {"key":"currencyId", "label":"Default Currency",  "type":"select","sourcePicklistId":"CURRENCY"}
    ]'::jsonb
    ELSE '[]'::jsonb
  END
FROM rows r
WHERE p.id = r.id
  AND r.picklist_id IN (
    'DESIGNATION','NATIONALITY','MARITAL_STATUS','RELATIONSHIP_TYPE',
    'ID_COUNTRY','ID_TYPE','LOCATION','CURRENCY','Expense_Category'
  );

-- ── 3. Seed parent_picklist_id for child picklists ───────────────────────────

-- ID_TYPE  → parent = ID_COUNTRY
UPDATE picklists child
SET    parent_picklist_id = parent.id
FROM   picklists parent
WHERE  child.picklist_id  = 'ID_TYPE'
  AND  parent.picklist_id = 'ID_COUNTRY';

-- LOCATION → parent = ID_COUNTRY
UPDATE picklists child
SET    parent_picklist_id = parent.id
FROM   picklists parent
WHERE  child.picklist_id  = 'LOCATION'
  AND  parent.picklist_id = 'ID_COUNTRY';

-- =============================================================================
-- END OF MIGRATION 20260420006_picklists_extend.sql
-- =============================================================================
