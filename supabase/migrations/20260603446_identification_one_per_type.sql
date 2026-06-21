-- =============================================================================
-- Migration 446 — identification: one record per employee per ID type
--
-- BUSINESS RULE: A person cannot have two records of the same ID type
-- (e.g. one Aadhaar, one PAN — not two Aadhaar numbers).
--
-- CHANGE: Natural key moves from (employee_id, id_type, id_number)
--         to (employee_id, id_type).
--
-- This makes id_number updatable via bulk import — re-importing a row
-- for the same employee+type updates the existing record instead of
-- creating a duplicate.
--
-- Steps:
--   1. Deduplicate existing data — keep the row with the most data
--      (prefer rows with record_type='primary', then most recent created_at)
--   2. Drop old unique index on (employee_id, id_type, id_number)
--   3. Create new unique index on (employee_id, id_type)
--   4. Rewrite upsert_identity_record to conflict on (employee_id, id_type)
--   5. Update schema_definition natural_key
-- =============================================================================

-- ── 1. Deduplicate: keep the "best" row per (employee_id, id_type) ────────────
-- "Best" = primary over secondary, then most fields filled, then newest
DELETE FROM identity_records
WHERE id NOT IN (
  SELECT DISTINCT ON (employee_id, id_type) id
  FROM identity_records
  ORDER BY
    employee_id,
    id_type,
    CASE WHEN lower(record_type) = 'primary' THEN 0 ELSE 1 END,
    (CASE WHEN id_number   IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN country     IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN expiry      IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN record_type IS NOT NULL THEN 1 ELSE 0 END) DESC,
    created_at DESC
);

-- ── 2. Drop old unique index ───────────────────────────────────────────────────
DROP INDEX IF EXISTS uq_identity_records_emp_type_num;

-- ── 3. New unique index on (employee_id, id_type) ─────────────────────────────
CREATE UNIQUE INDEX uq_identity_records_emp_type
  ON identity_records (employee_id, id_type);

-- ── 4. Rewrite upsert_identity_record ─────────────────────────────────────────
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

  IF NULLIF(p_row->>'id_number', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_number is required');
  END IF;

  -- ── country: resolve label / ref_id / UUID → UUID (optional) ───────────────
  v_country := NULL;
  IF NULLIF(trim(p_row->>'country_iso3'), '') IS NOT NULL THEN
    v_country := resolve_picklist_id('ID_COUNTRY', trim(p_row->>'country_iso3'));
    IF v_country IS NULL THEN
      SELECT string_agg(pv.value || ' (' || pv.ref_id || ')', ', ' ORDER BY pv.value)
      INTO   v_valid
      FROM   picklist_values pv
      JOIN   picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'ID_COUNTRY' AND pv.active = true;
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'Unknown Country "' || (p_row->>'country_iso3') || '". Valid values: ' || COALESCE(v_valid, '(none)')
      );
    END IF;
  END IF;

  -- ── Upsert on (employee_id, id_type) — one record per type ─────────────────
  INSERT INTO identity_records (
    employee_id, id_type, id_number, record_type, country, expiry
  ) VALUES (
    p_employee_id,
    v_id_type,
    p_row->>'id_number',
    NULLIF(p_row->>'record_type', ''),
    v_country,
    NULLIF(p_row->>'expiry_date', '')::date
  )
  ON CONFLICT (employee_id, id_type) DO UPDATE SET
    id_number   = EXCLUDED.id_number,
    record_type = COALESCE(NULLIF(EXCLUDED.record_type, ''), identity_records.record_type),
    country     = COALESCE(EXCLUDED.country,              identity_records.country),
    expiry      = COALESCE(EXCLUDED.expiry,               identity_records.expiry),
    updated_at  = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_identity_record(uuid, jsonb) IS
  'Mig 446: upserts on (employee_id, id_type) — one record per ID type per employee. '
  'id_number is now updatable. Accepts ref_id, label, or UUID for id_type and country.';

GRANT EXECUTE ON FUNCTION upsert_identity_record(UUID, JSONB) TO authenticated;

-- ── 5. Update schema natural_key ──────────────────────────────────────────────
UPDATE bulk_template_registry
SET schema_definition = jsonb_set(
  schema_definition,
  '{natural_key}',
  '["Employee Code *", "ID Type *"]'::jsonb
), updated_at = NOW()
WHERE template_code = 'identification';

-- =============================================================================
-- END OF MIGRATION 446
-- =============================================================================
