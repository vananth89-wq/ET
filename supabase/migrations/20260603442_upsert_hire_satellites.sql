-- =============================================================================
-- Migration 439 — upsert_hire_satellites(p_employee_id, p_data jsonb)
-- =============================================================================
--
-- PROBLEM
-- ───────
-- saveExtendedData() in AddEmployee.tsx calls 7 satellite RPCs sequentially
-- from the client. Each call is individually atomic, but the overall chain has
-- no wrapping transaction. A network failure mid-chain leaves a partial save
-- with some sections written and others not — the record is inconsistent and
-- the error messages per-section are the only indication of what happened.
--
-- FIX
-- ───
-- A single SECURITY DEFINER function that calls all 7 satellite writes in one
-- PL/pgSQL body. This eliminates the network-failure partial-write risk that
-- existed when the client made 7 sequential round-trips.
--
-- NOTE ON ATOMICITY: each section is wrapped in BEGIN...EXCEPTION...END to
-- support per-section error reporting. A section failure does NOT roll back
-- other sections — errors are collected and returned as { ok, errors[] }.
-- This is intentional: the UI gets fine-grained feedback per section.
-- For strict all-or-nothing, remove the per-section exception blocks.
--
-- The function accepts a JSONB payload matching the structure that
-- saveExtendedData() already assembles, so the frontend refactor is minimal.
--
-- PAYLOAD SHAPE
-- ─────────────
-- {
--   "personal":             { jsonb — forwarded to upsert_personal_info()        },
--   "personal_effective_from": "YYYY-MM-DD",
--   "contact":              { country_code, mobile, personal_email, business_email },
--   "employment":           { jsonb — forwarded to upsert_employment_info()       },
--   "employment_effective_from": "YYYY-MM-DD",
--   "passport":             { country, number, issue_date, expiry }  — optional,
--   "address":              { line1, line2, landmark, city, district, state, pin, country },
--   "emergency":            { name, relationship, phone, alt_phone, email },
--   "identity_records":     [ { country, id_type, record_type, id_number, expiry }, ... ]
-- }
--
-- Any key absent or null → that satellite's upsert/replace is still called with
-- null args (which clears the row for single-row tables, or is a no-op for RPCs
-- that guard on empty inputs).
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_hire_satellites(
  p_employee_id uuid,
  p_data        jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contact        jsonb;
  v_passport       jsonb;
  v_address        jsonb;
  v_emergency      jsonb;
  v_identity_recs  jsonb;
  v_errors         jsonb := '[]'::jsonb;
  v_err_msg        text;
BEGIN
  -- ── Permission gate ────────────────────────────────────────────────────────
  -- Caller must be the hire analyst, HR Head, or super admin.
  -- Delegates to individual RPC permission checks, but guard up-front for clarity.
  IF NOT (
    user_can('hire_employee', 'edit', NULL)
    OR user_can('hire_employee', 'edit_all_pending', NULL)
    OR is_super_admin()
  ) THEN
    RAISE EXCEPTION 'upsert_hire_satellites: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── 1. Personal info ───────────────────────────────────────────────────────
  -- Skip when personal_effective_from is NULL (hire date not yet entered).
  -- The frontend passes NULL until the Employment section fills hire_date so we
  -- never write employee_personal with today's date as a bogus effective_from.
  IF (p_data->>'personal_effective_from') IS NOT NULL THEN
    BEGIN
      PERFORM upsert_personal_info(
        p_employee_id,
        p_data->'personal',
        (p_data->>'personal_effective_from')::date
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
      v_errors := v_errors || jsonb_build_object('section', 'personal', 'error', v_err_msg);
    END;
  END IF;

  -- ── 2. Contact (direct upsert — no separate RPC) ──────────────────────────
  v_contact := p_data->'contact';
  IF v_contact IS NOT NULL THEN
    BEGIN
      INSERT INTO employee_contact (
        employee_id, country_code, mobile, personal_email, business_email
      ) VALUES (
        p_employee_id,
        NULLIF(v_contact->>'country_code', ''),
        NULLIF(v_contact->>'mobile',        ''),
        NULLIF(v_contact->>'personal_email',''),
        NULLIF(v_contact->>'business_email','')
      )
      ON CONFLICT (employee_id) DO UPDATE SET
        country_code   = EXCLUDED.country_code,
        mobile         = EXCLUDED.mobile,
        personal_email = EXCLUDED.personal_email,
        business_email = EXCLUDED.business_email,
        updated_at     = NOW();
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
      v_errors := v_errors || jsonb_build_object('section', 'contact', 'error', v_err_msg);
    END;
  END IF;

  -- ── 3. Employment info ────────────────────────────────────────────────────
  -- Skip when employment_effective_from is NULL — hire date not yet entered.
  IF p_data->'employment' IS NOT NULL
     AND (p_data->>'employment_effective_from') IS NOT NULL THEN
    BEGIN
      PERFORM upsert_employment_info(
        p_employee_id,
        p_data->'employment',
        (p_data->>'employment_effective_from')::date
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
      v_errors := v_errors || jsonb_build_object('section', 'employment', 'error', v_err_msg);
    END;
  END IF;

  -- ── 4. Passport ────────────────────────────────────────────────────────────
  v_passport := COALESCE(p_data->'passport', 'null'::jsonb);
  BEGIN
    PERFORM upsert_passport(
      p_employee_id,
      NULLIF(v_passport->>'country',    ''),
      NULLIF(v_passport->>'number',     ''),
      CASE WHEN v_passport->>'issue_date' IS NOT NULL AND v_passport->>'issue_date' != ''
           THEN (v_passport->>'issue_date')::date ELSE NULL END,
      CASE WHEN v_passport->>'expiry' IS NOT NULL AND v_passport->>'expiry' != ''
           THEN (v_passport->>'expiry')::date ELSE NULL END
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    v_errors := v_errors || jsonb_build_object('section', 'passport', 'error', v_err_msg);
  END;

  -- ── 5. Address ─────────────────────────────────────────────────────────────
  v_address := COALESCE(p_data->'address', 'null'::jsonb);
  BEGIN
    PERFORM upsert_employee_address(
      p_employee_id,
      NULLIF(v_address->>'line1',    ''),
      NULLIF(v_address->>'line2',    ''),
      NULLIF(v_address->>'landmark', ''),
      NULLIF(v_address->>'city',     ''),
      NULLIF(v_address->>'district', ''),
      NULLIF(v_address->>'state',    ''),
      NULLIF(v_address->>'pin',      ''),
      NULLIF(v_address->>'country',  '')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    v_errors := v_errors || jsonb_build_object('section', 'address', 'error', v_err_msg);
  END;

  -- ── 6. Emergency contact ───────────────────────────────────────────────────
  v_emergency := COALESCE(p_data->'emergency', 'null'::jsonb);
  BEGIN
    PERFORM upsert_emergency_contact(
      p_employee_id,
      NULLIF(v_emergency->>'name',         ''),
      NULLIF(v_emergency->>'relationship', ''),
      NULLIF(v_emergency->>'phone',        ''),
      NULLIF(v_emergency->>'alt_phone',    ''),
      NULLIF(v_emergency->>'email',        '')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    v_errors := v_errors || jsonb_build_object('section', 'emergency', 'error', v_err_msg);
  END;

  -- ── 7. Identity records ────────────────────────────────────────────────────
  v_identity_recs := COALESCE(p_data->'identity_records', '[]'::jsonb);
  BEGIN
    PERFORM replace_identity_records(p_employee_id, v_identity_recs);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    v_errors := v_errors || jsonb_build_object('section', 'identity', 'error', v_err_msg);
  END;

  -- ── Return result ──────────────────────────────────────────────────────────
  -- ok = true even with section errors so the caller can surface them
  -- individually — same behaviour as the old sequential chain.
  -- If a caller wants strict all-or-nothing, wrap in a transaction at call site.
  RETURN jsonb_build_object(
    'ok',     jsonb_array_length(v_errors) = 0,
    'errors', v_errors
  );
END;
$$;

REVOKE ALL    ON FUNCTION upsert_hire_satellites(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_hire_satellites(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION upsert_hire_satellites(uuid, jsonb) IS
  'Single-transaction wrapper for all 7 satellite writes in the hire wizard. '
  'Calls upsert_personal_info, employee_contact upsert, upsert_employment_info, '
  'upsert_passport, upsert_employee_address, upsert_emergency_contact, '
  'replace_identity_records — all within one PL/pgSQL body (one implicit txn). '
  'Returns { ok: bool, errors: [{section, error}] }. '
  'Replaces the 7-call sequential chain in saveExtendedData(). Mig 439.';

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'upsert_hire_satellites'
  ) THEN
    RAISE EXCEPTION 'ABORT: upsert_hire_satellites missing after migration 439.';
  END IF;
  RAISE NOTICE 'Migration 439 verified: upsert_hire_satellites present.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 439
-- =============================================================================
