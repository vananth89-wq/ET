-- =============================================================================
-- Migration 544 — Simple hard-delete RPCs for non-effective-dated tables
-- =============================================================================
--
-- Covers: contact_info, address, passport, emergency_contacts,
--         identity_documents, termination
--
-- All are straight hard-deletes (no timeline to stitch).
-- Each RPC:
--   1. Checks user_can(module, 'delete', employee_id) OR is_super_admin()
--   2. Verifies the record belongs to p_employee_id (ownership guard)
--   3. Hard-deletes
--   4. Returns { ok: bool, error?: text }
--
-- Note on single-record tables (contact, address, passport):
--   After delete the section is simply empty — no minimum-record constraint
--   since these fields are optional for an employee.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. delete_contact_info
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_contact_info(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (user_can('contact_info', 'delete', p_employee_id) OR is_super_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: contact_info.delete required.');
  END IF;

  DELETE FROM employee_contact WHERE employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No contact info record found for this employee.');
  END IF;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_contact_info(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. delete_address
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_address(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (user_can('address', 'delete', p_employee_id) OR is_super_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: address.delete required.');
  END IF;

  DELETE FROM employee_addresses WHERE employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No address record found for this employee.');
  END IF;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_address(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. delete_passport
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_passport(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (user_can('passport', 'delete', p_employee_id) OR is_super_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: passport.delete required.');
  END IF;

  DELETE FROM passports WHERE employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No passport record found for this employee.');
  END IF;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_passport(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. delete_emergency_contact
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_emergency_contact(
  p_record_id   uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (user_can('emergency_contacts', 'delete', p_employee_id) OR is_super_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: emergency_contacts.delete required.');
  END IF;

  DELETE FROM emergency_contacts
  WHERE  id          = p_record_id
    AND  employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Emergency contact record not found.');
  END IF;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_emergency_contact(uuid, uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. delete_identity_record
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_identity_record(
  p_record_id   uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (user_can('identity_documents', 'delete', p_employee_id) OR is_super_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: identity_documents.delete required.');
  END IF;

  DELETE FROM identity_records
  WHERE  id          = p_record_id
    AND  employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Identity record not found.');
  END IF;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_identity_record(uuid, uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. delete_termination_record
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_termination_record(
  p_record_id   uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (user_can('termination', 'delete', p_employee_id) OR is_super_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.delete required.');
  END IF;

  -- Ownership guard
  IF NOT EXISTS (
    SELECT 1 FROM employee_terminations
    WHERE id = p_record_id AND employee_id = p_employee_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found.');
  END IF;

  DELETE FROM employee_terminations
  WHERE  id          = p_record_id
    AND  employee_id = p_employee_id;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_termination_record(uuid, uuid) TO authenticated;

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'delete_contact_info'),        'delete_contact_info missing';
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'delete_address'),              'delete_address missing';
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'delete_passport'),             'delete_passport missing';
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'delete_emergency_contact'),    'delete_emergency_contact missing';
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'delete_identity_record'),      'delete_identity_record missing';
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'delete_termination_record'),   'delete_termination_record missing';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 544
-- =============================================================================
