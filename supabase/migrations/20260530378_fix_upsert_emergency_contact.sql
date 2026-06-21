-- =============================================================================
-- Migration 378 — Fix upsert_emergency_contact: use ON CONFLICT
--
-- emergency_contacts has UNIQUE (employee_id) from mig 235
-- (emergency_contacts_employee_id_key). The original wrapper used an
-- UPDATE/INSERT pattern unnecessarily. Simplify to ON CONFLICT.
-- No schema changes — function replacement only.
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
BEGIN
  IF NOT user_can('emergency_contacts', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: emergency_contact.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'name', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name is required');
  END IF;

  INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
  VALUES (
    p_employee_id,
    p_row->>'name',
    NULLIF(p_row->>'relationship', ''),
    NULLIF(p_row->>'phone',        ''),
    NULLIF(p_row->>'alt_phone',    ''),
    NULLIF(p_row->>'email',        '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = COALESCE(NULLIF(EXCLUDED.relationship, ''), emergency_contacts.relationship),
    phone        = COALESCE(NULLIF(EXCLUDED.phone,        ''), emergency_contacts.phone),
    alt_phone    = COALESCE(NULLIF(EXCLUDED.alt_phone,    ''), emergency_contacts.alt_phone),
    email        = COALESCE(NULLIF(EXCLUDED.email,        ''), emergency_contacts.email),
    updated_at   = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- =============================================================================
-- END OF MIGRATION 378
-- =============================================================================
