-- Fix upsert_hire_satellites: update internal calls to use 4-arg signatures.
--
-- Root cause:
--   Mig 614 added upsert_employment_info(uuid,jsonb,date) — 3-arg version with a
--   permission guard. Mig 615 added a 4-arg version (uuid,jsonb,date,boolean).
--   Both existed simultaneously → PostgreSQL "is not unique" error on every call.
--   We dropped the 3-arg versions to fix the ambiguity, but upsert_hire_satellites
--   still calls them with 3 args — now errors with "function does not exist",
--   silently caught by EXCEPTION WHEN OTHERS → satellites never written.
--
-- Fix: pass p_propagate => false explicitly so calls resolve to the 4-arg overload.
--   No logic change — just makes the call site explicit. Safe for all existing data.

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
  IF NOT (
    user_can('hire_employee', 'edit', NULL)
    OR user_can('hire_employee', 'edit_all_pending', NULL)
    OR is_super_admin()
  ) THEN
    RAISE EXCEPTION 'upsert_hire_satellites: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── 1. Personal info ───────────────────────────────────────────────────────
  IF (p_data->>'personal_effective_from') IS NOT NULL THEN
    BEGIN
      PERFORM upsert_personal_info(
        p_employee_id,
        p_data->'personal',
        (p_data->>'personal_effective_from')::date,
        false   -- p_propagate: hire wizard never propagates forward
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

  -- ── 3. Employment info ─────────────────────────────────────────────────────
  IF p_data->'employment' IS NOT NULL
     AND (p_data->>'employment_effective_from') IS NOT NULL THEN
    BEGIN
      PERFORM upsert_employment_info(
        p_employee_id,
        p_data->'employment',
        (p_data->>'employment_effective_from')::date,
        false   -- p_propagate: hire wizard never propagates forward
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

  RETURN jsonb_build_object(
    'ok',     jsonb_array_length(v_errors) = 0,
    'errors', v_errors
  );
END;
$$;

REVOKE ALL    ON FUNCTION upsert_hire_satellites(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_hire_satellites(uuid, jsonb) TO authenticated;
