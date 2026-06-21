-- =============================================================================
-- Migration 445 — upsert_passport: fix country key + resolve picklist
--
-- Two bugs in the original upsert_passport (mig 376):
--
--   1. Wrong JSONB key: reads p_row->>'country' but headerToSnake() converts
--      "Country (ISO3)" → "country_iso3". Country has never been written by
--      bulk import because the key never matched.
--
--   2. No picklist resolution: even if the key matched, the raw value (which
--      may be a label, ref_id, or UUID) was stored as-is instead of being
--      resolved to a UUID via resolve_picklist_id('ID_COUNTRY', ...).
--
-- FIX: read 'country_iso3', resolve via resolve_picklist_id('ID_COUNTRY'),
-- return a clear error with valid options if unrecognised — same pattern as
-- upsert_identity_record (mig 400).
--
-- Note: this rewrites the (UUID, JSONB) overload used by the bulk import
-- processor. The (UUID, text, text, date, date) overload added by mig 437
-- for the satellite panel is a different function signature and is unchanged.
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_passport(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_country text;
  v_valid   text;
BEGIN
  IF NOT user_can('passport', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: passport.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'passport_number', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'passport_number is required');
  END IF;

  -- ── country_iso3: resolve label / ref_id / UUID → UUID (optional) ──────────
  -- Column header "Country (ISO3)" → headerToSnake → "country_iso3"
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
        'error', 'Unknown country "' || (p_row->>'country_iso3') || '". Valid values: ' || COALESCE(v_valid, '(none)')
      );
    END IF;
  END IF;

  INSERT INTO passports (
    employee_id, passport_number, country, issue_date, expiry_date
  ) VALUES (
    p_employee_id,
    p_row->>'passport_number',
    v_country,
    NULLIF(p_row->>'issue_date',  '')::date,
    NULLIF(p_row->>'expiry_date', '')::date
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    passport_number = EXCLUDED.passport_number,
    country         = COALESCE(EXCLUDED.country, passports.country),
    issue_date      = COALESCE(EXCLUDED.issue_date,  passports.issue_date),
    expiry_date     = COALESCE(EXCLUDED.expiry_date, passports.expiry_date),
    updated_at      = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_passport(uuid, jsonb) IS
  'Mig 445: fixed country key (country_iso3 not country) and added '
  'resolve_picklist_id(ID_COUNTRY) — accepts ref_id, label, or UUID. '
  'Country was silently ignored in all prior bulk imports due to wrong key.';

GRANT EXECUTE ON FUNCTION upsert_passport(UUID, JSONB) TO authenticated;
