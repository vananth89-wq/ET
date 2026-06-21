-- =============================================================================
-- Migration 424 — contact_info bulk export + schema: add Business Email
--
-- employee_contact.business_email was added in mig 410 but was never included
-- in the export function or schema_definition.
--
-- Changes:
--   1. Replace _bulk_export_contact_info to add Business Email column
--      (between Employee Code and Personal Email — business email first as it
--       is the primary contact identifier)
--   2. Update contact_info schema_definition to add "Business Email" column
--
-- Note: business_email is NOT in the import (employees.business_email is the
-- source of truth and identity key — changing it via contact_info import would
-- be unsafe). It is exported for reference only (include_with_system_metadata).
--
-- Predecessor: mig 423 (dispatch table), mig 410 (column added)
-- =============================================================================

-- 1. Fix _bulk_export_contact_info
CREATE OR REPLACE FUNCTION _bulk_export_contact_info(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT
      e.employee_id      AS "Employee Code *",
      ec.business_email  AS "Business Email",
      ec.personal_email  AS "Personal Email",
      ec.country_code    AS "Country Code",
      ec.mobile          AS "Mobile",
      TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM employee_contact ec JOIN employees e ON e.id=ec.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id) r;
$$;

GRANT EXECUTE ON FUNCTION _bulk_export_contact_info(BOOLEAN, TEXT) TO authenticated;

-- 2. Update schema_definition
--    Business Email is export-only (reference copy of employees.business_email).
--    It is included with system metadata — not user_fillable on import.
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *', 'data_type','code_employee','mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Personal Email',  'data_type','text',         'mandatory',false,'user_fillable',true),  2),
    (jsonb_build_object('name','Country Code',    'data_type','text',         'mandatory',false,'user_fillable',true),  3),
    (jsonb_build_object('name','Mobile',          'data_type','text',         'mandatory',false,'user_fillable',true),  4),
    (jsonb_build_object('name','Business Email',  'data_type','text',         'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5),
    (jsonb_build_object('name','Created At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6),
    (jsonb_build_object('name','Updated At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='contact_info';

-- =============================================================================
-- END OF MIGRATION 424
-- =============================================================================
