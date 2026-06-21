-- =============================================================================
-- Migration 490 — Restore format validation in replace_identity_records
--
-- WHAT HAPPENED
-- ─────────────
-- Mig 485 added id_number format validation to replace_identity_records
-- (using id_format_rules table + validate_id_number helper).
--
-- Mig 488 rewrote replace_identity_records to add the secondary-requires-primary
-- guard. It was based on mig 470 (not 485), so it silently dropped the format
-- validation when it was deployed.
--
-- The DB now has the secondary-requires-primary guard (488) but no format
-- validation (485 overwritten). This migration restores both.
--
-- RESULT: replace_identity_records enforces all three guards in order:
--   1. Permission (mig 470)
--   2. Secondary-requires-primary (mig 488)
--   3. Format validation (mig 485 — restored here)
--   4. Atomic replace (mig 470)
-- =============================================================================

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
  -- ── Permission guard (mig 470) ────────────────────────────────────────────
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

  -- ── Secondary-requires-primary guard (mig 488) ────────────────────────────
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_records) r
    WHERE lower(r->>'record_type') = 'secondary'
  ) AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_records) r
    WHERE lower(r->>'record_type') = 'primary'
  ) THEN
    RAISE EXCEPTION
      'Cannot save: a secondary identity record requires at least one primary record. '
      'Please ensure a primary record is included.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- ── Format validation (mig 485 — restored) ────────────────────────────────
  FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    v_country   := v_rec->>'country';
    v_id_type   := v_rec->>'id_type';
    v_id_number := NULLIF(trim(v_rec->>'id_number'), '');

    IF v_id_number IS NOT NULL THEN
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

  -- ── Atomic replace (mig 470) ──────────────────────────────────────────────
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
  'Mig 470: permission guard. '
  'Mig 485: format validation via id_format_rules + validate_id_number(). '
  'Mig 488: secondary-requires-primary guard. '
  'Mig 490: restored mig 485 format validation lost when 488 overwrote 485.';

DO $$
BEGIN
  RAISE NOTICE 'Migration 490: replace_identity_records — format validation (485) restored alongside secondary-requires-primary guard (488).';
END;
$$;
