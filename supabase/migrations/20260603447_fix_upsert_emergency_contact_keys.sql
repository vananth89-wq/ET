-- =============================================================================
-- Migration 447 — Fix upsert_emergency_contact: wrong JSONB key names
--
-- PROBLEM: headerToSnake() in the bulk processor converts CSV column headers
-- to snake_case keys before passing p_row to the RPC. The RPC was written
-- with the wrong key names:
--
--   CSV column        headerToSnake()    RPC was reading
--   ─────────────────────────────────────────────────────
--   "Contact Name *"  contact_name       name        ← WRONG → "name is required"
--   "Phone"           phone              phone       ✓
--   "Alt Phone"       alt_phone          alt_phone   ✓
--   "Email"           email              email       ✓
--   "Relationship"    relationship       relationship ✓
--
-- FIX: read contact_name instead of name.
-- Also trim phone/alt_phone on insert to clean up any whitespace from prior
-- imports (the export previously added a leading tab for Excel compatibility).
-- =============================================================================

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

  -- headerToSnake("Contact Name *") → contact_name
  IF NULLIF(trim(p_row->>'contact_name'), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Contact Name is required');
  END IF;

  -- ── relationship: resolve label / ref_id / UUID → UUID (optional) ──────────
  v_relationship := NULL;
  IF NULLIF(trim(p_row->>'relationship'), '') IS NOT NULL THEN
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
  END IF;

  INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
  VALUES (
    p_employee_id,
    trim(p_row->>'contact_name'),
    v_relationship,
    NULLIF(trim(p_row->>'phone'),     ''),
    NULLIF(trim(p_row->>'alt_phone'), ''),
    NULLIF(trim(p_row->>'email'),     '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = COALESCE(EXCLUDED.relationship,               emergency_contacts.relationship),
    phone        = COALESCE(NULLIF(EXCLUDED.phone,     ''),      emergency_contacts.phone),
    alt_phone    = COALESCE(NULLIF(EXCLUDED.alt_phone, ''),      emergency_contacts.alt_phone),
    email        = COALESCE(NULLIF(EXCLUDED.email,     ''),      emergency_contacts.email),
    updated_at   = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_emergency_contact(uuid, jsonb) IS
  'Mig 447: fixed JSONB key from "name" → "contact_name" to match '
  'headerToSnake("Contact Name *"). Added trim() on all text fields. '
  'Accepts ref_id, label, or UUID for relationship.';

GRANT EXECUTE ON FUNCTION upsert_emergency_contact(UUID, JSONB) TO authenticated;
