-- =============================================================================
-- Migration 448 — emergency_contact: make Relationship and Phone mandatory
--
-- Column names kept WITHOUT * so exported headers stay clean.
-- mandatory: true drives the validator's required check independently of
-- the column name convention.
--
-- Also updates upsert_emergency_contact to enforce phone at the DB level.
-- =============================================================================

UPDATE bulk_template_registry
SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *',  'data_type','code_employee',             'mandatory',true, 'user_fillable',true), 1),
    (jsonb_build_object('name','Contact Name *',   'data_type','text',                      'mandatory',true, 'user_fillable',true), 2),
    (jsonb_build_object('name','Relationship',     'data_type','picklist:RELATIONSHIP_TYPE','mandatory',true, 'user_fillable',true), 3),
    (jsonb_build_object('name','Phone',            'data_type','text',                      'mandatory',true, 'user_fillable',true), 4),
    (jsonb_build_object('name','Alt Phone',        'data_type','text',                      'mandatory',false,'user_fillable',true), 5),
    (jsonb_build_object('name','Email',            'data_type','text',                      'mandatory',false,'user_fillable',true), 6),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *'),
  'row_processor', 'per_row'
), updated_at = NOW()
WHERE template_code = 'emergency_contact';

-- Also enforce phone as required in the upsert RPC
CREATE OR REPLACE FUNCTION upsert_emergency_contact(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_relationship text;
  v_valid        text;
BEGIN
  IF NOT user_can('emergency_contacts', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: emergency_contact.bulk_import required');
  END IF;

  IF NULLIF(trim(p_row->>'contact_name'), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Contact Name is required');
  END IF;

  IF NULLIF(trim(p_row->>'phone'), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Phone is required');
  END IF;

  -- ── relationship: resolve label / ref_id / UUID → UUID ─────────────────────
  IF NULLIF(trim(p_row->>'relationship'), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Relationship is required');
  END IF;

  v_relationship := resolve_picklist_id('RELATIONSHIP_TYPE', trim(p_row->>'relationship'));
  IF v_relationship IS NULL THEN
    SELECT string_agg(pv.value || ' (' || pv.ref_id || ')', ', ' ORDER BY pv.value)
    INTO   v_valid
    FROM   picklist_values pv
    JOIN   picklists pl ON pl.id = pv.picklist_id
    WHERE  pl.picklist_id = 'RELATIONSHIP_TYPE' AND pv.active = true;
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Unknown Relationship "' || trim(p_row->>'relationship') || '". Valid values: ' || COALESCE(v_valid, '(none)')
    );
  END IF;

  INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
  VALUES (
    p_employee_id,
    trim(p_row->>'contact_name'),
    v_relationship,
    trim(p_row->>'phone'),
    NULLIF(trim(p_row->>'alt_phone'), ''),
    NULLIF(trim(p_row->>'email'),     '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = EXCLUDED.relationship,
    phone        = EXCLUDED.phone,
    alt_phone    = COALESCE(NULLIF(EXCLUDED.alt_phone, ''), emergency_contacts.alt_phone),
    email        = COALESCE(NULLIF(EXCLUDED.email,     ''), emergency_contacts.email),
    updated_at   = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_emergency_contact(uuid, jsonb) IS
  'Mig 448: Relationship and Phone now mandatory. contact_name key (mig 447). '
  'Relationship always overwritten on update (not COALESCE) since it is required.';

GRANT EXECUTE ON FUNCTION upsert_emergency_contact(UUID, JSONB) TO authenticated;
