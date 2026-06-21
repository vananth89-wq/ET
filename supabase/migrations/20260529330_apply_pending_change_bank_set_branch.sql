-- =============================================================================
-- Migration 330: wire profile_bank apply path to bank-account-set transition
--
-- DESIGN REFERENCE
-- ────────────────
-- docs/set-snapshot-design.md §4.3 (Trigger update)
--
-- CONTEXT
-- ───────
-- After mig 321, apply_profile_pending_change has:
--     ELSIF v_module = 'profile_bank' THEN
--       NULL;  -- "handled by the bank module's own apply branch"
-- That branch is wired here, routing approved set-update submissions to
-- fn_apply_bank_account_set_transition (mig 329) so the proposed_data
-- materialises as a new employee_bank_account_set + items.
--
-- WHAT CHANGES
-- ────────────
-- Only the profile_bank branch is modified. Every other branch is copied
-- verbatim from mig 321 (the last full replace of apply_profile_pending_change).
--
-- ROUTING LOGIC FOR profile_bank
-- ───────────────────────────────
--   • proposed_data must carry the shape from submit_bank_account_set (mig 329):
--       { employee_id, effective_from, items: [...] }
--   • 20th-of-month approver cutoff enforced here (auth.uid() = the approver).
--     bank_exceptions / admin / hr are exempt.
--   • If items is missing → warn and skip (pre-set-snapshot rows preserved as-is).
--
-- ROLLBACK
-- ────────
-- Re-apply mig 321 to restore profile_bank branch to no-op.
-- =============================================================================


CREATE OR REPLACE FUNCTION apply_profile_pending_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_module    text;
  v_data      jsonb;
  v_emp_id    uuid;
  v_result    jsonb;
  v_eff_from  date;
  v_items     jsonb;
  v_set_id    uuid;
BEGIN
  -- Only fire on status → 'approved'
  IF NEW.status != 'approved' OR OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;

  v_module := NEW.module_code;
  v_data   := NEW.proposed_data;

  -- Resolve employee_id from the submitter's profile
  SELECT p.employee_id
  INTO   v_emp_id
  FROM   profiles p
  WHERE  p.id = NEW.submitted_by;

  IF v_emp_id IS NULL THEN
    RAISE WARNING
      'apply_profile_pending_change: cannot resolve employee_id for submitted_by=%, module=%, pending_change=%',
      NEW.submitted_by, v_module, NEW.id;
    RETURN NEW;
  END IF;

  -- ── profile_personal → upsert_personal_info ──────────────────────────────
  IF v_module = 'profile_personal' THEN
    v_eff_from := COALESCE(
      NULLIF(v_data->>'effective_from', '')::date,
      CURRENT_DATE
    );
    v_result := upsert_personal_info(v_emp_id, v_data, v_eff_from);
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING
        'apply_profile_pending_change: upsert_personal_info failed for employee=%, error=%',
        v_emp_id, v_result->>'error';
    END IF;

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
        address_type = COALESCE(v_data->>'address_type', address_type),
        line1        = COALESCE(v_data->>'line1',        line1),
        line2        = COALESCE(v_data->>'line2',        line2),
        city         = COALESCE(v_data->>'city',         city),
        state        = COALESCE(v_data->>'state',        state),
        country      = COALESCE(v_data->>'country',      country),
        pincode      = COALESCE(v_data->>'pincode',      pincode),
        updated_at   = now()
      WHERE id = NEW.record_id
        AND employee_id = v_emp_id;
    ELSE
      INSERT INTO employee_addresses (
        employee_id, address_type, line1, line2, city, state, country, pincode
      ) VALUES (
        v_emp_id,
        v_data->>'address_type',
        v_data->>'line1',
        v_data->>'line2',
        v_data->>'city',
        v_data->>'state',
        v_data->>'country',
        v_data->>'pincode'
      );
    END IF;

  -- ── profile_passport → passports ────────────────────────────────────────
  ELSIF v_module = 'profile_passport' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE passports
      SET
        passport_number  = COALESCE(v_data->>'passport_number',  passport_number),
        country_of_issue = COALESCE(v_data->>'country_of_issue', country_of_issue),
        issue_date       = COALESCE(NULLIF(v_data->>'issue_date','')::date,  issue_date),
        expiry_date      = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date),
        updated_at       = now()
      WHERE id = NEW.record_id
        AND employee_id = v_emp_id;
    ELSE
      INSERT INTO passports (
        employee_id, passport_number, country_of_issue, issue_date, expiry_date
      ) VALUES (
        v_emp_id,
        v_data->>'passport_number',
        v_data->>'country_of_issue',
        NULLIF(v_data->>'issue_date',  '')::date,
        NULLIF(v_data->>'expiry_date', '')::date
      );
    END IF;

  -- ── profile_identification → identity_records ────────────────────────────
  ELSIF v_module = 'profile_identification' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE identity_records
      SET
        id_type     = COALESCE(v_data->>'id_type',     id_type),
        id_number   = COALESCE(v_data->>'id_number',   id_number),
        expiry_date = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date),
        updated_at  = now()
      WHERE id = NEW.record_id
        AND employee_id = v_emp_id;
    ELSE
      INSERT INTO identity_records (
        employee_id, id_type, id_number, expiry_date
      ) VALUES (
        v_emp_id,
        v_data->>'id_type',
        v_data->>'id_number',
        NULLIF(v_data->>'expiry_date', '')::date
      );
    END IF;

  -- ── profile_emergency_contact → emergency_contacts ───────────────────────
  ELSIF v_module = 'profile_emergency_contact' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE emergency_contacts
      SET
        name         = COALESCE(v_data->>'name',         name),
        relationship = COALESCE(v_data->>'relationship', relationship),
        phone        = COALESCE(v_data->>'phone',        phone),
        email        = COALESCE(v_data->>'email',        email),
        updated_at   = now()
      WHERE id = NEW.record_id
        AND employee_id = v_emp_id;
    ELSE
      INSERT INTO emergency_contacts (
        employee_id, name, relationship, phone, email
      ) VALUES (
        v_emp_id,
        v_data->>'relationship',
        v_data->>'name',
        v_data->>'phone',
        v_data->>'email'
      );
    END IF;

  -- ── profile_bank → fn_apply_bank_account_set_transition ─────────────────
  -- MIG 330: replaces the no-op left in mig 321.
  -- proposed_data shape (from submit_bank_account_set, mig 329):
  --   { employee_id, effective_from, items: [...] }
  -- 20th-of-month cutoff applied here: auth.uid() = the approver at approval time.
  ELSIF v_module = 'profile_bank' THEN
    v_items := v_data->'items';
    IF jsonb_typeof(v_items) <> 'array' THEN
      RAISE WARNING
        'apply_profile_pending_change: profile_bank pending_change=% has no '
        'items[] in proposed_data; skipping. Row may predate the set-snapshot '
        'model (mig 328/329) and cannot be applied automatically.',
        NEW.id;
    ELSE
      -- 20th-of-month approver cutoff (auth.uid() = the approving user)
      IF EXTRACT(DAY FROM CURRENT_DATE) > 20
         AND NOT (has_role('bank_exceptions') OR has_role('admin') OR has_role('hr'))
      THEN
        RAISE EXCEPTION
          'Bank account set changes cannot be approved after the 20th of the month. '
          'Today is the %s. Only bank_exceptions, admin, or hr roles may approve after this date.',
          TO_CHAR(CURRENT_DATE, 'DDth');
      END IF;

      v_eff_from := COALESCE(
        NULLIF(v_data->>'effective_from', '')::date,
        date_trunc('month', CURRENT_DATE)::date
      );

      DECLARE
        v_target_emp uuid;
      BEGIN
        v_target_emp := COALESCE(
          NULLIF(v_data->>'employee_id', '')::uuid,
          v_emp_id
        );

        BEGIN
          v_set_id := fn_apply_bank_account_set_transition(
            p_employee_id    => v_target_emp,
            p_effective_from => v_eff_from,
            p_items          => v_items,
            p_actor          => NEW.submitted_by
          );

          RAISE NOTICE
            'apply_profile_pending_change: applied bank account set transition '
            'pending_change=% set_id=% employee=%',
            NEW.id, v_set_id, v_target_emp;

        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING
            'apply_profile_pending_change: fn_apply_bank_account_set_transition '
            'failed for pending_change=% employee=% error=%',
            NEW.id, v_target_emp, SQLERRM;
        END;
      END;
    END IF;

  -- ── profile_dependents → fn_apply_dependent_set_transition ──────────────
  ELSIF v_module = 'profile_dependents' THEN
    v_items := v_data->'items';
    IF jsonb_typeof(v_items) <> 'array' THEN
      RAISE WARNING
        'apply_profile_pending_change: profile_dependents pending_change=% '
        'has no items[] in proposed_data; skipping. This row predates the '
        'set-snapshot model (mig 320/302) and cannot be applied automatically.',
        NEW.id;
    ELSE
      v_eff_from := COALESCE(
        NULLIF(v_data->>'effective_from', '')::date,
        CURRENT_DATE
      );
      DECLARE
        v_target_emp uuid;
      BEGIN
        v_target_emp := COALESCE(
          NULLIF(v_data->>'employee_id', '')::uuid,
          v_emp_id
        );
        BEGIN
          v_set_id := fn_apply_dependent_set_transition(
            p_employee_id    => v_target_emp,
            p_effective_from => v_eff_from,
            p_items          => v_items,
            p_actor          => NEW.submitted_by
          );
          RAISE NOTICE
            'apply_profile_pending_change: applied dependent set transition '
            'pending_change=% set_id=% employee=%',
            NEW.id, v_set_id, v_target_emp;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING
            'apply_profile_pending_change: fn_apply_dependent_set_transition '
            'failed for pending_change=% employee=% error=%',
            NEW.id, v_target_emp, SQLERRM;
        END;
      END;
    END IF;

  ELSE
    RAISE NOTICE
      'apply_profile_pending_change: unhandled module_code=% for pending_change=%',
      v_module, NEW.id;
  END IF;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING
    'apply_profile_pending_change: unhandled exception for pending_change=%, error=%',
    NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'AFTER UPDATE trigger on workflow_pending_changes. Fires when status → ''approved''. '
  'Routes proposed_data to the correct satellite table or set-snapshot RPC. '
  'Mig 321: profile_dependents → fn_apply_dependent_set_transition(). '
  'Mig 330: profile_bank → fn_apply_bank_account_set_transition() with 20th-of-month '
  'approver cutoff (bank_exceptions/admin/hr exempt).';

-- Trigger already attached in mig 321; re-attach defensively.
DROP TRIGGER IF EXISTS trg_apply_profile_pending_change ON workflow_pending_changes;
CREATE TRIGGER trg_apply_profile_pending_change
  AFTER UPDATE OF status ON workflow_pending_changes
  FOR EACH ROW
  EXECUTE FUNCTION apply_profile_pending_change();


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname = 'apply_profile_pending_change';

  IF v_src NOT LIKE '%fn_apply_bank_account_set_transition%' THEN
    RAISE EXCEPTION 'mig 330: profile_bank branch not found in apply_profile_pending_change';
  END IF;

  RAISE NOTICE 'mig 330: apply_profile_pending_change rewired (profile_bank → fn_apply_bank_account_set_transition + 20th cutoff)';
END
$$;
