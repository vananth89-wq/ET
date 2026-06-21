-- =============================================================================
-- Migration 431 — contact_info: add Business Email to export and schema
--
-- business_email is export-only (read-only in bulk context):
--   • employees.business_email is the source of truth and identity key.
--   • employee_contact.business_email is a denormalized copy (mig 410).
--   • upsert_contact_info does NOT write it — business email is managed
--     via the invite/profile flow, not bulk import.
--
-- Changes:
--   1. schema_definition: add Business Email (user_fillable=false) so it
--      appears in export but the import processor ignores it.
--   2. _bulk_export_contact_info: add ec.business_email to SELECT.
-- =============================================================================

-- ── 1. Schema definition ──────────────────────────────────────────────────────
UPDATE bulk_template_registry
SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *', 'data_type','code_employee','mandatory',true, 'user_fillable',true),  1),
    -- user_fillable=true so it appears in export CSV; import processor ignores it
    -- (upsert_contact_info only reads personal_email/mobile/country_code).
    (jsonb_build_object('name','Business Email',  'data_type','text',         'mandatory',false,'user_fillable',true,
                        'description','Read-only — managed via profile/invite flow. Ignored on import.'), 2),
    (jsonb_build_object('name','Personal Email',  'data_type','text',         'mandatory',false,'user_fillable',true),  3),
    (jsonb_build_object('name','Country Code',    'data_type','text',         'mandatory',false,'user_fillable',true),  4),
    (jsonb_build_object('name','Mobile',          'data_type','text',         'mandatory',false,'user_fillable',true),  5),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *'),
  'row_processor', 'per_row'
), updated_at = NOW()
WHERE template_code = 'contact_info';

-- ── 2. Export function ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_contact_info(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT
      e.employee_id                                AS "Employee Code *",
      ec.business_email                            AS "Business Email",
      ec.personal_email                            AS "Personal Email",
      ec.country_code                              AS "Country Code",
      ec.mobile                                    AS "Mobile",
      TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM employee_contact ec
    JOIN employees e ON e.id = ec.employee_id
    WHERE (p_include_inactive OR e.status <> 'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id) r;
$$;

GRANT EXECUTE ON FUNCTION _bulk_export_contact_info(BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION _bulk_export_contact_info(boolean, text) IS
  'Mig 431: adds business_email to contact_info export (read-only denorm from mig 410). '
  'Import ignores it (user_fillable=false in schema_definition). '
  'Dispatched via mig 423 stable dispatcher.';

-- =============================================================================
-- END OF MIGRATION 431
-- =============================================================================
