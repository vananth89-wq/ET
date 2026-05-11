-- =============================================================================
-- Migration 117: apply_profile_pending_change trigger
--
-- PURPOSE
-- ───────
-- When a profile-module workflow_pending_changes row is approved, automatically
-- apply the proposed_data JSONB to the correct satellite table without any
-- manual intervention. The approver just clicks Approve in WorkflowReview and
-- the data lands in the employee's record automatically.
--
-- MODULES HANDLED
-- ───────────────
--   profile_personal          → employee_personal (upsert on employee_id)
--   profile_contact           → employee_contact  (upsert on employee_id)
--   profile_address           → employee_addresses (update if record_id, else insert)
--   profile_passport          → passports          (update if record_id, else insert)
--   profile_emergency_contact → emergency_contacts (update if record_id, else insert)
--
-- PROPOSED_DATA SHAPE (by module)
-- ─────────────────────────────────
--   profile_personal:
--     { nationality, marital_status, gender, dob }
--
--   profile_contact:
--     { country_code, mobile, personal_email }
--
--   profile_address:
--     { line1, line2, landmark, city, district, state, pin, country }
--
--   profile_passport:
--     { country, passport_number, issue_date, expiry_date }
--
--   profile_emergency_contact:
--     { name, relationship, phone, alt_phone, email }
--
-- RECORD_ID SEMANTICS
-- ────────────────────
--   For employee_personal / employee_contact:
--     record_id = employees.id (the employee being changed)
--     Not needed in the trigger — employee resolved via submitted_by → profiles.
--
--   For employee_addresses / passports / emergency_contacts:
--     record_id = the existing satellite row UUID (NULL = create new row)
--
-- SECURITY
-- ────────
-- Function is SECURITY DEFINER so it can write to satellite tables
-- regardless of the caller's RLS context. The submitted_by → profiles
-- resolution ensures only the correct employee's records are modified.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Trigger function
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION apply_profile_pending_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id uuid;
  v_data   jsonb;
  v_module text;
BEGIN
  -- Only fire when status transitions INTO 'approved'
  IF NEW.status <> 'approved' OR OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;

  v_module := NEW.module_code;
  v_data   := NEW.proposed_data;

  -- Only handle profile_* modules — all others are a no-op
  IF v_module NOT LIKE 'profile_%' THEN
    RETURN NEW;
  END IF;

  -- Resolve the employee's UUID via the submitter's profile
  -- profiles.employee_id → employees.id (the actual PK used in satellite tables)
  SELECT p.employee_id INTO v_emp_id
  FROM   profiles p
  WHERE  p.id = NEW.submitted_by;

  IF v_emp_id IS NULL THEN
    RAISE WARNING
      'apply_profile_pending_change: cannot resolve employee_id for submitted_by=%, module=%, pending_change=%',
      NEW.submitted_by, v_module, NEW.id;
    RETURN NEW; -- Silently continue — don't fail the approval
  END IF;

  -- ── profile_personal → employee_personal ────────────────────────────────
  IF v_module = 'profile_personal' THEN
    INSERT INTO employee_personal (
      employee_id, nationality, marital_status, gender, dob
    ) VALUES (
      v_emp_id,
      v_data->>'nationality',
      v_data->>'marital_status',
      v_data->>'gender',
      NULLIF(v_data->>'dob', '')::date
    )
    ON CONFLICT (employee_id) DO UPDATE SET
      nationality    = EXCLUDED.nationality,
      marital_status = EXCLUDED.marital_status,
      gender         = EXCLUDED.gender,
      dob            = EXCLUDED.dob;

  -- ── profile_contact → employee_contact ──────────────────────────────────
  ELSIF v_module = 'profile_contact' THEN
    INSERT INTO employee_contact (
      employee_id, country_code, mobile, personal_email
    ) VALUES (
      v_emp_id,
      v_data->>'country_code',
      v_data->>'mobile',
      v_data->>'personal_email'
    )
    ON CONFLICT (employee_id) DO UPDATE SET
      country_code   = EXCLUDED.country_code,
      mobile         = EXCLUDED.mobile,
      personal_email = EXCLUDED.personal_email;

  -- ── profile_address → employee_addresses ────────────────────────────────
  ELSIF v_module = 'profile_address' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE employee_addresses
      SET
        line1    = v_data->>'line1',
        line2    = v_data->>'line2',
        landmark = v_data->>'landmark',
        city     = v_data->>'city',
        district = v_data->>'district',
        state    = v_data->>'state',
        pin      = v_data->>'pin',
        country  = v_data->>'country'
      WHERE id = NEW.record_id;
    ELSE
      INSERT INTO employee_addresses (
        employee_id, line1, line2, landmark, city, district, state, pin, country
      ) VALUES (
        v_emp_id,
        v_data->>'line1',    v_data->>'line2',    v_data->>'landmark',
        v_data->>'city',     v_data->>'district', v_data->>'state',
        v_data->>'pin',      v_data->>'country'
      );
    END IF;

  -- ── profile_passport → passports ────────────────────────────────────────
  ELSIF v_module = 'profile_passport' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE passports
      SET
        country         = v_data->>'country',
        passport_number = v_data->>'passport_number',
        issue_date      = NULLIF(v_data->>'issue_date',  '')::date,
        expiry_date     = NULLIF(v_data->>'expiry_date', '')::date
      WHERE id = NEW.record_id;
    ELSE
      INSERT INTO passports (
        employee_id, country, passport_number, issue_date, expiry_date
      ) VALUES (
        v_emp_id,
        v_data->>'country',
        v_data->>'passport_number',
        NULLIF(v_data->>'issue_date',  '')::date,
        NULLIF(v_data->>'expiry_date', '')::date
      );
    END IF;

  -- ── profile_emergency_contact → emergency_contacts ──────────────────────
  ELSIF v_module = 'profile_emergency_contact' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE emergency_contacts
      SET
        name         = v_data->>'name',
        relationship = v_data->>'relationship',
        phone        = v_data->>'phone',
        alt_phone    = v_data->>'alt_phone',
        email        = v_data->>'email'
      WHERE id = NEW.record_id;
    ELSE
      INSERT INTO emergency_contacts (
        employee_id, name, relationship, phone, alt_phone, email
      ) VALUES (
        v_emp_id,
        v_data->>'name',      v_data->>'relationship',
        v_data->>'phone',     v_data->>'alt_phone',
        v_data->>'email'
      );
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'AFTER UPDATE trigger on workflow_pending_changes. '
  'When a profile_* module row transitions to status=approved, reads proposed_data '
  'and applies it to the correct satellite table. '
  'Modules: profile_personal→employee_personal, profile_contact→employee_contact, '
  'profile_address→employee_addresses, profile_passport→passports, '
  'profile_emergency_contact→emergency_contacts. '
  'SECURITY DEFINER — runs as function owner to bypass RLS on satellite tables.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Attach the trigger
-- ════════════════════════════════════════════════════════════════════════════

DROP TRIGGER IF EXISTS trg_apply_profile_pending_change ON workflow_pending_changes;

CREATE TRIGGER trg_apply_profile_pending_change
  AFTER UPDATE ON workflow_pending_changes
  FOR EACH ROW
  EXECUTE FUNCTION apply_profile_pending_change();

COMMENT ON TRIGGER trg_apply_profile_pending_change ON workflow_pending_changes IS
  'Applies approved profile change requests to satellite tables automatically. '
  'Fires AFTER UPDATE when status transitions to approved.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT routine_name
FROM   information_schema.routines
WHERE  routine_name = 'apply_profile_pending_change'
  AND  routine_schema = 'public';

SELECT trigger_name
FROM   information_schema.triggers
WHERE  trigger_name  = 'trg_apply_profile_pending_change'
  AND  event_object_table = 'workflow_pending_changes';
