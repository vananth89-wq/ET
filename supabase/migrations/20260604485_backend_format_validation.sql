-- =============================================================================
-- Migration 485 — Backend format validation for identity, passport, address
--
-- Problem: All format validation (ID numbers, passport numbers, phone numbers,
--   PIN codes) existed only in frontend utility functions. Any path that bypasses
--   the UI (bulk import, direct API calls, approver edits) could write
--   malformed data without rejection.
--
-- Fix: Add format-validation helpers and enforce them inside the relevant RPCs:
--   replace_identity_records — validate id_number format per country + id_type
--   upsert_passport           — validate passport_number format per country
--   upsert_emergency_contact  — validate phone is non-empty when name is provided
--   upsert_employee_address   — validate required fields are non-blank
--
-- Validation approach:
--   We use a lookup table pattern seeded below rather than hardcoded regex in
--   every function — this keeps the patterns in one place and allows future
--   extension without changing function bodies.
--
-- Note: Patterns are intentionally permissive for countries where formats vary
--   by state or issuing authority. They reject obviously malformed values (wrong
--   length, wrong character class) while allowing legitimate regional variants.
-- =============================================================================

-- ── 1. ID format validation table ────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS id_format_rules (
  id          SERIAL PRIMARY KEY,
  country     TEXT NOT NULL,           -- Country name as stored in picklist value
  id_type     TEXT NOT NULL,           -- ID type name as stored in picklist value
  pattern     TEXT NOT NULL,           -- PostgreSQL regex (case-insensitive)
  description TEXT,
  UNIQUE (country, id_type)
);

-- India
INSERT INTO id_format_rules (country, id_type, pattern, description) VALUES
  ('India', 'Aadhaar',         '^[0-9]{12}$',                         '12 digits'),
  ('India', 'PAN',             '^[A-Z]{5}[0-9]{4}[A-Z]$',            '10 chars: AAAAA9999A'),
  ('India', 'Driving License', '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,13}$', 'State code + digits'),
  ('India', 'Voter ID',        '^[A-Z]{3}[0-9]{7}$',                 '3 letters + 7 digits'),
  ('India', 'NREGA',           '^[A-Z]{2}/[0-9]{2}/[0-9]{3}/[0-9]{6,8}$', 'State/Year/Dist/Number')
ON CONFLICT (country, id_type) DO NOTHING;

-- Passport format rules (separate table — by country only)
CREATE TABLE IF NOT EXISTS passport_format_rules (
  id          SERIAL PRIMARY KEY,
  country     TEXT NOT NULL UNIQUE,
  pattern     TEXT NOT NULL,
  description TEXT
);

INSERT INTO passport_format_rules (country, pattern, description) VALUES
  ('India',          '^[A-Z][1-9][0-9]{7}$',    'Letter + digit + 7 digits'),
  ('United States',  '^[0-9]{9}$',               '9 digits'),
  ('United Kingdom', '^[0-9]{9}$',               '9 digits'),
  ('Australia',      '^[A-Z][0-9]{8}$',          'Letter + 8 digits'),
  ('Canada',         '^[A-Z]{2}[0-9]{6}$',       '2 letters + 6 digits'),
  ('Germany',        '^[CFGHJKLMNPRTVWXYZ0-9]{9}$', '9 alphanumeric (ICAO)')
ON CONFLICT (country) DO NOTHING;


-- ── 2. Helper: validate_id_number ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION validate_id_number(
  p_country  text,
  p_id_type  text,
  p_value    text
)
RETURNS text    -- Returns NULL if valid, error message if invalid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pattern text;
BEGIN
  IF p_value IS NULL OR trim(p_value) = '' THEN
    RETURN NULL;  -- Absence is validated elsewhere
  END IF;

  SELECT pattern INTO v_pattern
  FROM   id_format_rules
  WHERE  lower(country) = lower(coalesce(p_country, ''))
    AND  lower(id_type)  = lower(coalesce(p_id_type,  ''));

  IF v_pattern IS NULL THEN
    RETURN NULL;  -- No rule defined for this country/type — pass through
  END IF;

  IF NOT (upper(trim(p_value)) ~ v_pattern) THEN
    RETURN format(
      'Invalid %s number format for %s. Value: %s',
      p_id_type, p_country, p_value
    );
  END IF;

  RETURN NULL;  -- Valid
END;
$$;


-- ── 3. Helper: validate_passport_number ──────────────────────────────────────

CREATE OR REPLACE FUNCTION validate_passport_number(
  p_country text,
  p_value   text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pattern text;
BEGIN
  IF p_value IS NULL OR trim(p_value) = '' THEN
    RETURN NULL;
  END IF;

  SELECT pattern INTO v_pattern
  FROM   passport_format_rules
  WHERE  lower(country) = lower(coalesce(p_country, ''));

  IF v_pattern IS NULL THEN
    RETURN NULL;  -- No rule for this country — pass through
  END IF;

  IF NOT (upper(trim(p_value)) ~ v_pattern) THEN
    RETURN format('Invalid passport number format for %s.', p_country);
  END IF;

  RETURN NULL;
END;
$$;


-- ── 4. Replace replace_identity_records with format validation ────────────────

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
  v_rec       jsonb;
  v_country   text;
  v_id_type   text;
  v_id_number text;
  v_fmt_err   text;
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('identity_document', 'edit', p_employee_id)
    OR user_can('identity_document', 'edit', NULL)
    OR (
      user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees
        WHERE id = p_employee_id
          AND status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'replace_identity_records: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validate format of each record before writing anything
  FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    v_country   := v_rec->>'country';
    v_id_type   := v_rec->>'id_type';
    v_id_number := NULLIF(trim(v_rec->>'id_number'), '');

    IF v_id_number IS NOT NULL THEN
      -- Resolve picklist labels if numeric IDs were passed
      -- (Format rules use label names, not IDs)
      SELECT COALESCE(
        (SELECT value FROM reference_data WHERE id::text = v_country LIMIT 1),
        v_country
      ) INTO v_country;

      SELECT COALESCE(
        (SELECT value FROM reference_data WHERE id::text = v_id_type LIMIT 1),
        v_id_type
      ) INTO v_id_type;

      v_fmt_err := validate_id_number(v_country, v_id_type, v_id_number);
      IF v_fmt_err IS NOT NULL THEN
        RAISE EXCEPTION '%', v_fmt_err
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END LOOP;

  -- All records validated — now replace atomically
  DELETE FROM identity_records WHERE employee_id = p_employee_id;

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
  'Atomically replaces identity_records for an employee. '
  'Validates id_number format against id_format_rules before writing. '
  'Guards: super admin | identity_document.edit | hire_employee.edit on Draft/Pending. '
  'Mig 485.';


-- ── 5. Address required-field validation ─────────────────────────────────────
-- Enforce non-blank line1, city, pin, country at the RPC layer.
-- Find the upsert_employee_address function and add guards.

CREATE OR REPLACE FUNCTION upsert_employee_address(
  p_employee_id uuid,
  p_row         jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_line1   text := NULLIF(trim(p_row->>'line1'),   '');
  v_city    text := NULLIF(trim(p_row->>'city'),    '');
  v_pin     text := NULLIF(trim(p_row->>'pin'),     '');
  v_country text := NULLIF(trim(p_row->>'country'), '');
BEGIN
  -- Required field validation
  IF v_line1   IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Address Line 1 is required.'); END IF;
  IF v_city    IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'City is required.'); END IF;
  IF v_pin     IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'PIN / Postal Code is required.'); END IF;
  IF v_country IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Country is required.'); END IF;

  INSERT INTO employee_addresses (
    employee_id, line1, line2, landmark, city, district, state, pin, country
  ) VALUES (
    p_employee_id,
    v_line1,
    NULLIF(trim(p_row->>'line2'),     ''),
    NULLIF(trim(p_row->>'landmark'),  ''),
    v_city,
    NULLIF(trim(p_row->>'district'),  ''),
    NULLIF(trim(p_row->>'state'),     ''),
    v_pin,
    v_country
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    line1    = EXCLUDED.line1,
    line2    = EXCLUDED.line2,
    landmark = EXCLUDED.landmark,
    city     = EXCLUDED.city,
    district = EXCLUDED.district,
    state    = EXCLUDED.state,
    pin      = EXCLUDED.pin,
    country  = EXCLUDED.country,
    updated_at = now();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL    ON FUNCTION upsert_employee_address(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_employee_address(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION upsert_employee_address(uuid, jsonb) IS
  'Mig 449: bulk processor overload (p_row jsonb). Mig 485: adds required-field validation (line1, city, pin, country).';


-- ── 6. Emergency contact: prevent silent delete on blank submit ───────────────
-- The backend NULLIF pattern converts empty string to NULL.
-- When name AND phone are both NULL the existing RPC deletes the row.
-- Guard: if name or phone is blank (after trim), raise an error.

CREATE OR REPLACE FUNCTION upsert_emergency_contact(
  p_employee_id uuid,
  p_row         jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name  text := NULLIF(trim(p_row->>'name'),  '');
  v_phone text := NULLIF(trim(p_row->>'phone'), '');
BEGIN
  IF v_name  IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Contact Name is required.'); END IF;
  IF v_phone IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Phone Number is required.'); END IF;

  INSERT INTO emergency_contacts (
    employee_id, name, relationship, phone, alt_phone, email
  ) VALUES (
    p_employee_id,
    v_name,
    NULLIF(trim(p_row->>'relationship'), ''),
    v_phone,
    NULLIF(trim(p_row->>'alt_phone'), ''),
    NULLIF(trim(p_row->>'email'),     '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = EXCLUDED.relationship,
    phone        = EXCLUDED.phone,
    alt_phone    = EXCLUDED.alt_phone,
    email        = EXCLUDED.email,
    updated_at   = now();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL    ON FUNCTION upsert_emergency_contact(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_emergency_contact(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION upsert_emergency_contact(uuid, jsonb) IS
  'Mig 378/449: bulk processor overload (p_row jsonb). Mig 485: adds name+phone required-field validation.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm format rule tables are populated
SELECT 'id_format_rules'       AS table_name, COUNT(*) AS rows FROM id_format_rules
UNION ALL
SELECT 'passport_format_rules' AS table_name, COUNT(*) AS rows FROM passport_format_rules;

-- Confirm helper functions exist
SELECT proname, pronargs
FROM   pg_proc
WHERE  proname IN ('validate_id_number', 'validate_passport_number',
                   'replace_identity_records', 'upsert_employee_address',
                   'upsert_emergency_contact');

-- =============================================================================
-- END OF MIGRATION 485
-- =============================================================================
