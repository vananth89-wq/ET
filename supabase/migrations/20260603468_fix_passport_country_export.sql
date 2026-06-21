-- =============================================================================
-- Migration 444 — Fix passport country export: UUID → ref_id
--
-- Mig 425 replaced COALESCE(picklist_label('ID_COUNTRY', p.country), p.country)
-- with p.country directly, assuming it was stored as ISO3. It's not — the bulk
-- import processor stores whatever is passed in, and existing data contains UUIDs.
--
-- FIX: LEFT JOIN picklist_values to get ref_id (same Pattern B as other templates).
-- Round-trip safe: exported ref_id accepted by upsert_passport on re-import.
-- =============================================================================

CREATE OR REPLACE FUNCTION _bulk_export_passport(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      p.passport_number      AS "Passport Number *",
      pv_ctry.ref_id         AS "Country (ISO3)",
      TO_CHAR(p.issue_date, 'MM/DD/YYYY') AS "Issue Date",
      TO_CHAR(p.expiry_date,'MM/DD/YYYY') AS "Expiry Date",
      p.id::text AS "id",
      TO_CHAR(p.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(p.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM passports p
    JOIN employees e ON e.id = p.employee_id
    LEFT JOIN picklist_values pv_ctry ON pv_ctry.id::text = p.country
    WHERE (p_include_inactive OR e.status <> 'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id) r;
$$;

GRANT EXECUTE ON FUNCTION _bulk_export_passport(BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION _bulk_export_passport(boolean, text) IS
  'Mig 444: country exported as ref_id via LEFT JOIN picklist_values. '
  'Mig 425 incorrectly assumed country was stored as ISO3 text (Pattern A). '
  'It is UUID (Pattern B) — same fix applied to other templates in mig 440.';
