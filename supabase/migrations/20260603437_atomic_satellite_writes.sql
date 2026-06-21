-- =============================================================================
-- Migration 433 — Atomic satellite writes: UPSERT + server-side RPC
-- =============================================================================
--
-- PROBLEM
-- ───────
-- EmployeeEditPanel.tsx saves passports, employee_addresses, emergency_contacts,
-- and identity_records using client-side DELETE + INSERT. The two operations are
-- separate network round-trips with no transaction boundary. Between the DELETE
-- landing and the INSERT landing any concurrent reader (approver review, export,
-- report) sees a missing or empty row — a silent data-integrity hole.
--
-- FIX
-- ───
-- 1. passports          → UNIQUE(employee_id) already exists. Add an UPSERT RPC.
-- 2. employee_addresses → UNIQUE(employee_id) already exists. Add an UPSERT RPC.
-- 3. emergency_contacts → No UNIQUE constraint yet. Add one, then an UPSERT RPC.
--    (The app treats emergency contacts as one-per-employee in the hire pipeline;
--     the existing DELETE-all/INSERT-one pattern already assumes this. The constraint
--     formalises that assumption without dropping existing data.)
-- 4. identity_records   → Genuinely multi-row (no stable unique key per row).
--     Wrap DELETE + bulk INSERT in a single SECURITY DEFINER RPC so Postgres
--     executes both inside one implicit transaction.
--
-- All RPCs are SECURITY DEFINER so the client never touches the tables directly
-- for these write paths. Existing RLS policies are unchanged.
-- =============================================================================


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Add UNIQUE constraint to emergency_contacts
-- ══════════════════════════════════════════════════════════════════════════════
-- Guard: only add if absent (idempotent).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conname = 'uq_emergency_contacts_employee'
      AND  conrelid = 'emergency_contacts'::regclass
  ) THEN
    ALTER TABLE emergency_contacts
      ADD CONSTRAINT uq_emergency_contacts_employee UNIQUE (employee_id);
  END IF;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- 2. upsert_passport(p_employee_id, p_country, p_number, p_issue_date, p_expiry)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION upsert_passport(
  p_employee_id uuid,
  p_country     text    DEFAULT NULL,
  p_number      text    DEFAULT NULL,
  p_issue_date  date    DEFAULT NULL,
  p_expiry      date    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Caller must own this employee or have broad edit rights.
  IF NOT (
    user_can('passport', 'edit', p_employee_id)
    OR user_can('passport', 'edit', NULL)
  ) THEN
    RAISE EXCEPTION 'upsert_passport: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_country IS NULL AND p_number IS NULL AND p_issue_date IS NULL AND p_expiry IS NULL THEN
    -- Caller passed all-null → treat as clear
    DELETE FROM passports WHERE employee_id = p_employee_id;
    RETURN;
  END IF;

  INSERT INTO passports (employee_id, country, passport_number, issue_date, expiry_date)
  VALUES (p_employee_id, p_country, p_number, p_issue_date, p_expiry)
  ON CONFLICT (employee_id) DO UPDATE SET
    country         = EXCLUDED.country,
    passport_number = EXCLUDED.passport_number,
    issue_date      = EXCLUDED.issue_date,
    expiry_date     = EXCLUDED.expiry_date,
    updated_at      = NOW();
END;
$$;

REVOKE ALL    ON FUNCTION upsert_passport(uuid, text, text, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_passport(uuid, text, text, date, date) TO authenticated;

COMMENT ON FUNCTION upsert_passport(uuid, text, text, date, date) IS
  'Atomic upsert for the passports table (UNIQUE on employee_id). '
  'Replaces the client-side DELETE+INSERT pattern in EmployeeEditPanel. '
  'All-null args → deletes the row. Mig 433.';


-- ══════════════════════════════════════════════════════════════════════════════
-- 3. upsert_employee_address(p_employee_id, ...)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION upsert_employee_address(
  p_employee_id uuid,
  p_line1       text    DEFAULT NULL,
  p_line2       text    DEFAULT NULL,
  p_landmark    text    DEFAULT NULL,
  p_city        text    DEFAULT NULL,
  p_district    text    DEFAULT NULL,
  p_state       text    DEFAULT NULL,
  p_pin         text    DEFAULT NULL,
  p_country     text    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    user_can('address', 'edit', p_employee_id)
    OR user_can('address', 'edit', NULL)
  ) THEN
    RAISE EXCEPTION 'upsert_employee_address: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_line1 IS NULL AND p_city IS NULL THEN
    DELETE FROM employee_addresses WHERE employee_id = p_employee_id;
    RETURN;
  END IF;

  INSERT INTO employee_addresses (
    employee_id, line1, line2, landmark, city, district, state, pin, country
  )
  VALUES (
    p_employee_id, p_line1, p_line2, p_landmark, p_city, p_district, p_state, p_pin, p_country
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    line1      = EXCLUDED.line1,
    line2      = EXCLUDED.line2,
    landmark   = EXCLUDED.landmark,
    city       = EXCLUDED.city,
    district   = EXCLUDED.district,
    state      = EXCLUDED.state,
    pin        = EXCLUDED.pin,
    country    = EXCLUDED.country,
    updated_at = NOW();
END;
$$;

REVOKE ALL    ON FUNCTION upsert_employee_address(uuid,text,text,text,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_employee_address(uuid,text,text,text,text,text,text,text,text) TO authenticated;

COMMENT ON FUNCTION upsert_employee_address(uuid,text,text,text,text,text,text,text,text) IS
  'Atomic upsert for employee_addresses (UNIQUE on employee_id). '
  'Replaces the client-side DELETE+INSERT pattern in EmployeeEditPanel. '
  'null line1+city → deletes the row. Mig 433.';


-- ══════════════════════════════════════════════════════════════════════════════
-- 4. upsert_emergency_contact(p_employee_id, ...)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION upsert_emergency_contact(
  p_employee_id  uuid,
  p_name         text    DEFAULT NULL,
  p_relationship text    DEFAULT NULL,
  p_phone        text    DEFAULT NULL,
  p_alt_phone    text    DEFAULT NULL,
  p_email        text    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    user_can('emergency_contacts', 'edit', p_employee_id)
    OR user_can('emergency_contacts', 'edit', NULL)
  ) THEN
    RAISE EXCEPTION 'upsert_emergency_contact: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_name IS NULL AND p_phone IS NULL THEN
    DELETE FROM emergency_contacts WHERE employee_id = p_employee_id;
    RETURN;
  END IF;

  INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
  VALUES (p_employee_id, COALESCE(p_name, ''), p_relationship, p_phone, p_alt_phone, p_email)
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = EXCLUDED.relationship,
    phone        = EXCLUDED.phone,
    alt_phone    = EXCLUDED.alt_phone,
    email        = EXCLUDED.email,
    updated_at   = NOW();
END;
$$;

REVOKE ALL    ON FUNCTION upsert_emergency_contact(uuid,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_emergency_contact(uuid,text,text,text,text,text) TO authenticated;

COMMENT ON FUNCTION upsert_emergency_contact(uuid,text,text,text,text,text) IS
  'Atomic upsert for emergency_contacts (UNIQUE on employee_id added in mig 433). '
  'Replaces the client-side DELETE+INSERT pattern in EmployeeEditPanel. '
  'null name+phone → deletes the row. Mig 433.';


-- ══════════════════════════════════════════════════════════════════════════════
-- 5. replace_identity_records(p_employee_id, p_records jsonb)
-- ══════════════════════════════════════════════════════════════════════════════
-- identity_records is multi-row (one per ID type) with no stable unique key.
-- Wrapping DELETE + INSERT in a single RPC eliminates the partial-write window
-- because Postgres executes the whole function body in one implicit transaction.
--
-- p_records jsonb — array of objects:
--   [{"country":"IN","id_type":"Aadhaar","record_type":"National ID",
--     "id_number":"1234","expiry":"2030-01-01"}, ...]
-- Pass an empty array to clear all records.
CREATE OR REPLACE FUNCTION replace_identity_records(
  p_employee_id uuid,
  p_records     jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec jsonb;
BEGIN
  IF NOT (
    user_can('identity_document', 'edit', p_employee_id)
    OR user_can('identity_document', 'edit', NULL)
  ) THEN
    RAISE EXCEPTION 'replace_identity_records: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Delete all existing records for this employee atomically with the insert.
  DELETE FROM identity_records WHERE employee_id = p_employee_id;

  -- Insert the new set (may be empty — that's a valid clear).
  FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    INSERT INTO identity_records (
      employee_id, country, id_type, record_type, id_number, expiry
    ) VALUES (
      p_employee_id,
      NULLIF(v_rec->>'country',     ''),
      NULLIF(v_rec->>'id_type',     ''),
      NULLIF(v_rec->>'record_type', ''),
      NULLIF(v_rec->>'id_number',   ''),
      CASE WHEN v_rec->>'expiry' IS NOT NULL AND v_rec->>'expiry' != ''
           THEN (v_rec->>'expiry')::date ELSE NULL END
    );
  END LOOP;
END;
$$;

REVOKE ALL    ON FUNCTION replace_identity_records(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION replace_identity_records(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION replace_identity_records(uuid, jsonb) IS
  'Atomically replaces all identity_records rows for an employee. '
  'DELETE + INSERT run in one implicit Postgres transaction — no partial-write window. '
  'p_records = [] clears all records. Mig 433.';


-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_emergency_contacts_employee'
  ) THEN
    RAISE EXCEPTION 'ABORT: uq_emergency_contacts_employee constraint missing.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name = 'upsert_passport') THEN
    RAISE EXCEPTION 'ABORT: upsert_passport missing.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name = 'upsert_employee_address') THEN
    RAISE EXCEPTION 'ABORT: upsert_employee_address missing.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name = 'upsert_emergency_contact') THEN
    RAISE EXCEPTION 'ABORT: upsert_emergency_contact missing.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name = 'replace_identity_records') THEN
    RAISE EXCEPTION 'ABORT: replace_identity_records missing.';
  END IF;

  RAISE NOTICE 'Migration 433 verified: 4 atomic write RPCs in place.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 433
-- =============================================================================
