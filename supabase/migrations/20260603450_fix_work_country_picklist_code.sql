-- =============================================================================
-- Migration 450 — Fix work_country data_type: WORK_COUNTRY → ID_COUNTRY
--
-- The employment and employees templates had:
--   data_type: 'picklist:WORK_COUNTRY'
--
-- But the picklist is seeded as picklist_id = 'ID_COUNTRY' (shared with
-- passport and identification country fields). No picklist named WORK_COUNTRY
-- exists, so buildPicklistCaches() built an empty cache, causing the processor
-- to reject every ref_id (G001, G002, etc.) with "Invalid work country".
--
-- Fix: change data_type to 'picklist:ID_COUNTRY' in both templates.
-- =============================================================================

-- ── employment template ───────────────────────────────────────────────────────
UPDATE bulk_template_registry
SET schema_definition = jsonb_set(
  schema_definition,
  '{columns}',
  (
    SELECT jsonb_agg(
      CASE
        WHEN col->>'name' = 'Work Country (ISO3)'
        THEN col || jsonb_build_object('data_type', 'picklist:ID_COUNTRY')
        ELSE col
      END
    )
    FROM jsonb_array_elements(schema_definition->'columns') AS col
  )
), updated_at = NOW()
WHERE template_code = 'employment';

-- ── employees (master) template ───────────────────────────────────────────────
UPDATE bulk_template_registry
SET schema_definition = jsonb_set(
  schema_definition,
  '{columns}',
  (
    SELECT jsonb_agg(
      CASE
        WHEN col->>'name' = 'Work Country (ISO3)'
        THEN col || jsonb_build_object('data_type', 'picklist:ID_COUNTRY')
        ELSE col
      END
    )
    FROM jsonb_array_elements(schema_definition->'columns') AS col
  )
), updated_at = NOW()
WHERE template_code = 'employees';

-- =============================================================================
-- END OF MIGRATION 450
-- =============================================================================
