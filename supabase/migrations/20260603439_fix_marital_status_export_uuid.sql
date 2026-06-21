-- =============================================================================
-- Migration 429 — Fix marital_status export: UUID → ref_id
--
-- PROBLEM: Mig 425 assumed marital_status is stored as ref_id (Pattern A),
-- but resolve_picklist_id() actually stores the picklist_values.id UUID.
-- Result: the current export emits raw UUIDs (e.g. a0d5c3ba-...) instead of
-- human-meaningful codes like M001, M002.
--
-- FIX: Switch to Pattern B — LEFT JOIN picklist_values to export ref_id.
-- This matches how work_country is handled in the same migration.
--
-- Round-trip: exported ref_id (M001) is accepted by upsert_personal_info
-- via resolve_picklist_id (mig 380) which accepts label, ref_id, or UUID.
-- =============================================================================

CREATE OR REPLACE FUNCTION _bulk_export_personal_info(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id AS "Employee Code *",
        TO_CHAR(ep.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(ep.effective_to,  'MM/DD/YYYY') AS "Slice End",
        ep.is_active AS "Slice Is Active",
        ep.first_name AS "First Name *", ep.last_name AS "Last Name *",
        ep.middle_name AS "Middle Name", ep.preferred_name AS "Preferred Name",
        ep.gender AS "Gender",
        TO_CHAR(ep.dob,'MM/DD/YYYY') AS "Date of Birth",
        ep.nationality AS "Nationality (ISO3)",
        ms_pv.ref_id AS "Marital Status",
        ep.id::text AS "id",
        TO_CHAR(ep.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ep.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ep.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_personal ep
      JOIN employees e ON e.id = ep.employee_id
      LEFT JOIN picklist_values ms_pv ON ms_pv.id::text = ep.marital_status
      WHERE (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, ep.effective_from) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id AS "Employee Code *",
        TO_CHAR(ep.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        ep.first_name AS "First Name *", ep.last_name AS "Last Name *",
        ep.middle_name AS "Middle Name", ep.preferred_name AS "Preferred Name",
        ep.gender AS "Gender",
        TO_CHAR(ep.dob,'MM/DD/YYYY') AS "Date of Birth",
        ep.nationality AS "Nationality (ISO3)",
        ms_pv.ref_id AS "Marital Status",
        ep.id::text AS "id",
        TO_CHAR(ep.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ep.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ep.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_personal ep
      JOIN employees e ON e.id = ep.employee_id
      LEFT JOIN picklist_values ms_pv ON ms_pv.id::text = ep.marital_status
      WHERE ep.is_active = true AND ep.effective_to = '9999-12-31'::date
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id) r;
  END IF;
END; $$;

COMMENT ON FUNCTION _bulk_export_personal_info(boolean, text) IS
  'Mig 429: marital_status exported as ref_id (M001…) via LEFT JOIN picklist_values. '
  'Pattern B — UUID stored, ref_id exported — same as work_country. '
  'Round-trip safe: re-import accepts ref_id via resolve_picklist_id (mig 380).';
