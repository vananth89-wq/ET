-- =============================================================================
-- Migration 400 — Identification bulk: resolve id_type & country to labels
--
-- PROBLEM
-- ───────
-- The identification bulk export emits raw UUID text for id_type and country
-- because the exporter_query selects ir.id_type / ir.country directly.
-- Importers who round-trip the CSV see UUIDs in "ID Type *" and "Country (ISO3)"
-- instead of human-readable values.
--
-- FIX
-- ───
-- 1. exporter_query updated to call picklist_label() for both columns.
--    Falls back to raw value if UUID is orphaned (COALESCE).
--    Also fixes passport template's country column the same way.
--
-- 2. upsert_identity_record rewritten to accept label, ref_id, or raw UUID
--    for id_type (via resolve_picklist_id). Country handled the same way
--    (stored as UUID, resolved on import, exported as label).
--
-- 3. schema_definition data_type updated: 'text' → 'picklist:ID_TYPE' and
--    'code_country_iso' → 'picklist:ID_COUNTRY' so template generator can
--    enumerate valid values. Same fix applied to passport's country column.
--
-- Picklist codes (from identity_review_option_b migration comment):
--   id_type  → ID_TYPE
--   country  → ID_COUNTRY  (shared with passport)
-- =============================================================================


-- =============================================================================
-- PART 1 — upsert_identity_record: resolve label/ref_id → UUID on import
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_identity_record(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id_type  text;
  v_country  text;
  v_valid    text;
BEGIN
  IF NOT user_can('identification', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: identification.bulk_import required');
  END IF;

  -- ── id_type: resolve label / ref_id / UUID → UUID ──────────────────────────
  IF NULLIF(p_row->>'id_type', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_type is required');
  END IF;

  v_id_type := resolve_picklist_id('ID_TYPE', trim(p_row->>'id_type'));
  IF v_id_type IS NULL THEN
    SELECT string_agg(pv.value || ' (' || pv.ref_id || ')', ', ' ORDER BY pv.value)
    INTO   v_valid
    FROM   picklist_values pv
    JOIN   picklists pl ON pl.id = pv.picklist_id
    WHERE  pl.picklist_id = 'ID_TYPE' AND pv.active = true;
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Unknown ID Type "' || (p_row->>'id_type') || '". Valid values: ' || COALESCE(v_valid, '(none)')
    );
  END IF;

  -- ── id_number ───────────────────────────────────────────────────────────────
  IF NULLIF(p_row->>'id_number', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_number is required');
  END IF;

  -- ── country: resolve label / ref_id / UUID → UUID (optional) ───────────────
  v_country := NULL;
  IF NULLIF(p_row->>'country', '') IS NOT NULL THEN
    v_country := resolve_picklist_id('ID_COUNTRY', trim(p_row->>'country'));
    IF v_country IS NULL THEN
      SELECT string_agg(pv.value || ' (' || pv.ref_id || ')', ', ' ORDER BY pv.value)
      INTO   v_valid
      FROM   picklist_values pv
      JOIN   picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'ID_COUNTRY' AND pv.active = true;
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'Unknown Country "' || (p_row->>'country') || '". Valid values: ' || COALESCE(v_valid, '(none)')
      );
    END IF;
  END IF;

  INSERT INTO identity_records (
    employee_id, id_type, id_number, country, expiry
  ) VALUES (
    p_employee_id,
    v_id_type,
    p_row->>'id_number',
    v_country,
    NULLIF(p_row->>'expiry', '')::date
  )
  ON CONFLICT (employee_id, id_type, id_number) DO UPDATE SET
    country    = COALESCE(EXCLUDED.country, identity_records.country),
    expiry     = COALESCE(EXCLUDED.expiry,  identity_records.expiry),
    updated_at = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_identity_record IS
  'Bulk-import processor for identification template. '
  'Accepts label, ref_id, or raw UUID for id_type and country (ID_TYPE / ID_COUNTRY picklists). '
  'Upserts identity_records on (employee_id, id_type, id_number). Bypasses workflow.';

GRANT EXECUTE ON FUNCTION upsert_identity_record(UUID, JSONB) TO authenticated;


-- =============================================================================
-- PART 2 — Update exporter_query and schema_definition in bulk_template_registry
-- =============================================================================

-- ── identification template ──────────────────────────────────────────────────
UPDATE bulk_template_registry
SET
  exporter_query = $exq$
    SELECT
      e.employee_id                                                AS "Employee Code *",
      COALESCE(picklist_label('ID_TYPE',    ir.id_type),    ir.id_type)    AS "ID Type *",
      ir.id_number                                                 AS "ID Number *",
      COALESCE(picklist_label('ID_COUNTRY', ir.country),   ir.country)    AS "Country (ISO3)",
      TO_CHAR(ir.expiry, 'MM/DD/YYYY')                             AS "Expiry Date"
    FROM identity_records ir
    JOIN employees e ON e.id = ir.employee_id
    ORDER BY e.employee_id, ir.id_type
  $exq$,
  schema_definition = jsonb_set(
    jsonb_set(
      schema_definition,
      '{columns}',
      (
        SELECT jsonb_agg(
          CASE
            WHEN col->>'name' = 'ID Type *'
              THEN col || jsonb_build_object('data_type', 'picklist:ID_TYPE', 'description', 'ID type label or ref_id, e.g. Aadhaar, PAN, NI, SSN')
            WHEN col->>'name' = 'Country (ISO3)'
              THEN col || jsonb_build_object('data_type', 'picklist:ID_COUNTRY', 'description', 'Country label or ISO3 ref_id, e.g. India, IND')
            ELSE col
          END
        )
        FROM jsonb_array_elements(schema_definition->'columns') AS col
      )
    ),
    '{columns}',   -- no-op second path just to keep jsonb_set chaining valid
    (
      SELECT jsonb_agg(
        CASE
          WHEN col->>'name' = 'ID Type *'
            THEN col || jsonb_build_object('data_type', 'picklist:ID_TYPE', 'description', 'ID type label or ref_id, e.g. Aadhaar, PAN, NI, SSN')
          WHEN col->>'name' = 'Country (ISO3)'
            THEN col || jsonb_build_object('data_type', 'picklist:ID_COUNTRY', 'description', 'Country label or ISO3 ref_id, e.g. India, IND')
          ELSE col
        END
      )
      FROM jsonb_array_elements(schema_definition->'columns') AS col
    )
  ),
  updated_at = NOW()
WHERE template_code = 'identification';

-- ── passport template — fix country column export (same ID_COUNTRY picklist) ─
UPDATE bulk_template_registry
SET
  exporter_query = $exq$
    SELECT
      e.employee_id                                                AS "Employee Code *",
      p.passport_number                                            AS "Passport Number *",
      COALESCE(picklist_label('ID_COUNTRY', p.country), p.country) AS "Country (ISO3)",
      TO_CHAR(p.issue_date,  'MM/DD/YYYY')                         AS "Issue Date",
      TO_CHAR(p.expiry_date, 'MM/DD/YYYY')                         AS "Expiry Date"
    FROM passports p
    JOIN employees e ON e.id = p.employee_id
    ORDER BY e.employee_id
  $exq$,
  schema_definition = jsonb_set(
    schema_definition,
    '{columns}',
    (
      SELECT jsonb_agg(
        CASE
          WHEN col->>'name' = 'Country (ISO3)'
            THEN col || jsonb_build_object('data_type', 'picklist:ID_COUNTRY', 'description', 'Country label or ISO3 ref_id, e.g. India, IND')
          ELSE col
        END
      )
      FROM jsonb_array_elements(schema_definition->'columns') AS col
    )
  ),
  updated_at = NOW()
WHERE template_code = 'passport';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Check identification schema_definition columns show updated data_types
SELECT col->>'name' AS col_name, col->>'data_type' AS data_type
FROM   bulk_template_registry,
       jsonb_array_elements(schema_definition->'columns') AS col
WHERE  template_code = 'identification';

-- Check passport schema_definition
SELECT col->>'name' AS col_name, col->>'data_type' AS data_type
FROM   bulk_template_registry,
       jsonb_array_elements(schema_definition->'columns') AS col
WHERE  template_code = 'passport';

-- =============================================================================
-- END OF MIGRATION 400
-- =============================================================================
