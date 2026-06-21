-- =============================================================================
-- Migration 488 — Identity records: secondary requires primary
--
-- CONFLICT RESOLVED
-- ─────────────────
-- Mig 485 rewrote replace_identity_records with id_number format validation.
-- This migration also rewrites replace_identity_records to add the
-- secondary-requires-primary guard. Since 488 > 485, this version wins.
-- Both guards are included here so neither is lost.
--
-- RULE (confirmed by product owner)
-- ──────────────────────────────────
-- A secondary identity record cannot exist without a primary record for the
-- same employee. Secondary only makes sense when there are two records.
--
-- WAS THIS EVER ENFORCED? — No. Never existed at any layer.
--
-- CHANGES
-- ───────
-- 1. add_hire_identity_record — guard: secondary requires existing primary.
--
-- 2. replace_identity_records — two guards added before the atomic replace:
--    a. Secondary-requires-primary (mig 488 — new)
--    b. Format validation per id_format_rules table (mig 485 — preserved)
--
-- Frontend mirrors this with:
--   • 'Secondary' option disabled when no primary record exists
--   • Deleting a primary when secondary exists → modal → auto-demote
-- =============================================================================


-- =============================================================================
-- 1. add_hire_identity_record
-- =============================================================================

CREATE OR REPLACE FUNCTION add_hire_identity_record(
  p_employee_id uuid,
  p_country     uuid,
  p_id_type     uuid,
  p_record_type text,
  p_id_number   text,
  p_expiry      date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_id uuid;
BEGIN
  -- ── Access guard (mig 267 — unchanged) ───────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code  = 'employee_hire'
      AND  record_id    = p_employee_id
      AND  submitted_by = auth.uid()
      AND  status       = 'awaiting_clarification'
  ) AND NOT user_can('hire_employee', 'edit', NULL) THEN
    RAISE EXCEPTION 'Not authorised to add identity record for employee %.',
      p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Editable-status guard (mig 267 — unchanged) ──────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE  id     = p_employee_id
      AND  status IN ('Pending', 'Incomplete')
  ) THEN
    RAISE EXCEPTION 'add_hire_identity_record: employee % is not in an editable status.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Secondary-requires-primary guard (mig 488) ────────────────────────────
  IF lower(p_record_type) = 'secondary' THEN
    IF NOT EXISTS (
      SELECT 1 FROM identity_records
      WHERE  employee_id       = p_employee_id
        AND  lower(record_type) = 'primary'
    ) THEN
      RAISE EXCEPTION
        'A secondary ID record cannot be added without a primary record. '
        'Please add a primary identity record first.'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- ── Insert ────────────────────────────────────────────────────────────────
  INSERT INTO identity_records (employee_id, country, id_type, record_type, id_number, expiry)
  VALUES (p_employee_id, p_country, p_id_type, p_record_type, p_id_number, p_expiry)
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

COMMENT ON FUNCTION add_hire_identity_record(uuid, uuid, uuid, text, text, date) IS
  'SECURITY DEFINER wrapper for inserting an identity_records row. '
  'Mig 267: initial — bypasses RLS, enforces hire_employee.edit guard. '
  'Mig 488: added secondary-requires-primary guard.';

REVOKE ALL     ON FUNCTION add_hire_identity_record(uuid, uuid, uuid, text, text, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION add_hire_identity_record(uuid, uuid, uuid, text, text, date) TO authenticated;


-- =============================================================================
-- 2. replace_identity_records — merges mig 485 (format validation) +
--                                       mig 488 (secondary-requires-primary)
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
  -- ── Permission guard (mig 470 — unchanged) ────────────────────────────────
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
  -- Checked against the incoming payload (not the DB) because this is an
  -- atomic replace-all operation.
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

  -- ── Format validation (mig 485 — preserved) ───────────────────────────────
  -- Validates id_number against id_format_rules before writing anything.
  -- No-op if no rule exists for a given country/type (pass-through).
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

  -- ── Atomic replace (mig 470 — unchanged) ─────────────────────────────────
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
  'Mig 470: permission guard (super admin | identity_document.edit | hire_employee.edit on Draft/Pending). '
  'Mig 485: format validation via id_format_rules + validate_id_number(). '
  'Mig 488: secondary-requires-primary guard on submitted payload.';

DO $$
BEGIN
  RAISE NOTICE 'Migration 488: replace_identity_records — secondary-requires-primary guard '
               'merged with mig 485 format validation. add_hire_identity_record guard added.';
END;
$$;
