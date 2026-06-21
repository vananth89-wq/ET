-- =============================================================================
-- Migration 497 — Fix replace_identity_records: reference_data → picklist_values
--
-- Migs 485, 488, 490 all referenced a non-existent table "reference_data".
-- The correct table is picklist_values (id uuid, value text).
-- This causes a runtime error whenever identity records are saved.
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

  -- ── Format validation (mig 485 — reference_data fixed to picklist_values) ─
  FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    v_country   := v_rec->>'country';
    v_id_type   := v_rec->>'id_type';
    v_id_number := NULLIF(trim(v_rec->>'id_number'), '');

    IF v_id_number IS NOT NULL THEN
      SELECT COALESCE(
        (SELECT value FROM picklist_values WHERE id::text = v_country LIMIT 1),
        v_country
      ) INTO v_country;

      SELECT COALESCE(
        (SELECT value FROM picklist_values WHERE id::text = v_id_type LIMIT 1),
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
  'Mig 490: restored mig 485 format validation. '
  'Mig 497: fixed reference_data → picklist_values (table never existed).';

DO $$
BEGIN
  RAISE NOTICE 'Migration 497: replace_identity_records — reference_data typo fixed to picklist_values.';
END;
$$;
