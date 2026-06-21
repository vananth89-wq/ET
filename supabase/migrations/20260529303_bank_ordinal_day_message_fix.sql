-- =============================================================================
-- Migration 303: Fix ordinal-day typos in bank cutoff messages
--
-- Spec gap (point 5 from validation audit, 2026-05-29):
--   Mig 299 wrote `%sth` as a placeholder for the day-of-month in two error
--   messages. Because format() and RAISE use different placeholder syntaxes,
--   the same string produces two different bugs:
--
--     • format() at mig 299:113  → `%s` consumes the arg, `th` is literal
--       Result: "Today is the 21th." (and "1th", "2th", "3th", "22th", etc.)
--
--     • RAISE     at mig 299:444 → `%` consumes the arg, `sth` is literal
--       Result: "Today is the 21sth." (broken on every day it ever fires)
--
-- Fix: use Postgres's built-in ordinal-day formatter — `to_char(date, 'FMDDth')`
-- which produces '1st', '2nd', '3rd', '11th', '21st', '22nd', '31st', etc.
-- handling all edge cases (the 11th/12th/13th -> "th" rule, no leading zero).
--
-- Applied to both call sites:
--   1. upsert_bank_account → 15th-cutoff error message
--   2. apply_profile_pending_change → 20th-cutoff RAISE EXCEPTION
--
-- Everything else from mig 302 is preserved verbatim.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. upsert_bank_account — replace `%sth` with `to_char(v_today, 'FMDDth')`
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION upsert_bank_account(
  p_employee_id             uuid,
  p_bank_account_group_id   uuid        DEFAULT NULL,
  p_country_code            text        DEFAULT NULL,
  p_currency_code           text        DEFAULT NULL,
  p_bank_name               text        DEFAULT NULL,
  p_branch_name             text        DEFAULT NULL,
  p_branch_code             text        DEFAULT NULL,
  p_account_holder_name     text        DEFAULT NULL,
  p_account_number          text        DEFAULT NULL,
  p_ifsc_code               text        DEFAULT NULL,
  p_iban                    text        DEFAULT NULL,
  p_swift_bic               text        DEFAULT NULL,
  p_is_primary              boolean     DEFAULT false,
  p_effective_from          date        DEFAULT NULL,
  p_attachments             jsonb       DEFAULT '[]'::jsonb,
  p_is_new_hire             boolean     DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id         uuid   := auth.uid();
  v_today             date   := CURRENT_DATE;
  v_day_of_month      int    := EXTRACT(DAY FROM v_today);
  v_month_first       date   := date_trunc('month', v_today)::date;
  v_is_bank_exception boolean;
  v_prev_active       employee_bank_accounts%ROWTYPE;
  v_group_id          uuid;
  v_template_id       uuid;
  v_new_id            uuid;
BEGIN
  -- ── 1. Basic field presence ───────────────────────────────────────────────
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_id is required.');
  END IF;
  IF p_country_code IS NULL OR trim(p_country_code) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Country is required.');
  END IF;
  IF p_currency_code IS NULL OR trim(p_currency_code) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Currency is required.');
  END IF;
  IF p_bank_name IS NULL OR trim(p_bank_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Bank name is required.');
  END IF;
  IF p_account_holder_name IS NULL OR trim(p_account_holder_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Account holder name is required.');
  END IF;
  IF p_account_number IS NULL OR trim(p_account_number) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Account number is required.');
  END IF;
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Effective from date is required.');
  END IF;

  -- ── 2. Country-specific mandatory fields ─────────────────────────────────
  IF p_country_code IN ('IND', 'LKA')
     AND (p_branch_name IS NULL OR trim(p_branch_name) = '') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Branch name is required for ' || p_country_code || '.'
    );
  END IF;
  IF p_country_code = 'IND' AND (p_ifsc_code IS NULL OR trim(p_ifsc_code) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'IFSC code is required for India.');
  END IF;
  IF p_country_code = 'LKA' AND (p_branch_code IS NULL OR trim(p_branch_code) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Branch code is required for Sri Lanka.');
  END IF;
  IF p_country_code IN ('PAK', 'SAU') AND (p_iban IS NULL OR trim(p_iban) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'IBAN is required for ' || p_country_code || '.');
  END IF;

  -- ── 3. Attachment is mandatory ────────────────────────────────────────────
  IF p_attachments IS NULL OR jsonb_array_length(p_attachments) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'At least one proof-of-account attachment is required.');
  END IF;

  -- ── 4. Date cutoff checks (skipped for new hires and exempt roles) ─────────
  v_is_bank_exception := has_role('bank_exceptions') OR has_role('admin') OR has_role('hr');

  IF NOT p_is_new_hire AND NOT v_is_bank_exception THEN
    IF v_day_of_month > 15 THEN
      -- CHANGED (mig 303): use to_char(.., 'FMDDth') for correct ordinal day
      -- ("21st" instead of mig 299's "21th").
      RETURN jsonb_build_object(
        'ok', false,
        'error', format(
          'Bank account changes can only be submitted on or before the 15th of the month. '
          'Today is the %s. Please resubmit from the 1st of next month.',
          to_char(v_today, 'FMDDth')
        )
      );
    END IF;

    IF p_effective_from <> v_month_first THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', format(
          'Effective from date must be the 1st of the current month (%s). '
          'Please select %s and resubmit.',
          to_char(v_month_first, 'DD Mon YYYY'),
          to_char(v_month_first, 'DD Mon YYYY')
        )
      );
    END IF;
  END IF;

  -- ── 5. Resolve group_id ───────────────────────────────────────────────────
  IF p_bank_account_group_id IS NOT NULL THEN
    SELECT * INTO v_prev_active
    FROM   employee_bank_accounts
    WHERE  bank_account_group_id = p_bank_account_group_id
      AND  employee_id           = p_employee_id
      AND  effective_to          = '9999-12-31'::date
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'No active record found for the given bank_account_group_id.'
      );
    END IF;
    v_group_id := p_bank_account_group_id;
  ELSE
    v_group_id := gen_random_uuid();
  END IF;

  -- ── 6. Check for workflow assignment ──────────────────────────────────────
  v_template_id := resolve_workflow_for_submission('profile_bank', v_caller_id);

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH A: No workflow → direct write
  -- ════════════════════════════════════════════════════════════════════════════
  IF v_template_id IS NULL THEN

    -- Mig 302 close-out guard
    IF v_prev_active.id IS NOT NULL THEN
      IF v_prev_active.effective_from >= p_effective_from THEN
        DELETE FROM employee_bank_accounts WHERE id = v_prev_active.id;
      ELSE
        UPDATE employee_bank_accounts
        SET    effective_to = p_effective_from - interval '1 day',
               updated_at   = now(),
               updated_by   = v_caller_id
        WHERE  id = v_prev_active.id;
      END IF;
    END IF;

    INSERT INTO employee_bank_accounts (
      employee_id, bank_account_group_id, country_code, currency_code,
      bank_name, branch_name, branch_code, account_holder_name,
      account_number, ifsc_code, iban, swift_bic,
      is_primary, effective_from, effective_to,
      created_by, updated_by
    ) VALUES (
      p_employee_id, v_group_id, p_country_code, p_currency_code,
      p_bank_name, p_branch_name, p_branch_code, p_account_holder_name,
      p_account_number, p_ifsc_code, p_iban, p_swift_bic,
      p_is_primary, p_effective_from, '9999-12-31'::date,
      v_caller_id, v_caller_id
    )
    RETURNING id INTO v_new_id;

    IF p_attachments IS NOT NULL AND jsonb_array_length(p_attachments) > 0 THEN
      INSERT INTO employee_bank_attachments (
        bank_account_id, employee_id, file_name, file_type, file_size,
        storage_path, uploaded_by
      )
      SELECT
        v_new_id,
        p_employee_id,
        att->>'file_name',
        att->>'file_type',
        (att->>'file_size')::integer,
        att->>'storage_path',
        v_caller_id
      FROM jsonb_array_elements(p_attachments) AS att;
    END IF;

    RETURN jsonb_build_object('ok', true, 'bank_account_id', v_new_id, 'workflow_pending', false);

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH B: Workflow assigned → stage proposed_data in workflow_pending_changes
  -- ════════════════════════════════════════════════════════════════════════════
  ELSE

    DECLARE
      v_proposed jsonb := jsonb_build_object(
        'employee_id',            p_employee_id,
        'bank_account_group_id',  v_group_id,
        'country_code',           p_country_code,
        'currency_code',          p_currency_code,
        'bank_name',              p_bank_name,
        'branch_name',            p_branch_name,
        'branch_code',            p_branch_code,
        'account_holder_name',    p_account_holder_name,
        'account_number',         p_account_number,
        'ifsc_code',              p_ifsc_code,
        'iban',                   p_iban,
        'swift_bic',              p_swift_bic,
        'is_primary',             p_is_primary,
        'effective_from',         p_effective_from,
        'prev_active_id',         v_prev_active.id,
        'attachments',            p_attachments
      );
      v_wpc_id  uuid;
      v_inst_id uuid;
    BEGIN
      INSERT INTO workflow_pending_changes (
        submitted_by, module_code, record_id, proposed_data, status
      ) VALUES (
        v_caller_id,
        'profile_bank',
        p_employee_id,
        v_proposed,
        'pending'
      )
      RETURNING id INTO v_wpc_id;

      INSERT INTO workflow_instances (
        template_id, submitted_by, module_code, record_id, pending_change_id, status
      ) VALUES (
        v_template_id,
        v_caller_id,
        'profile_bank',
        p_employee_id,
        v_wpc_id,
        'in_progress'
      )
      RETURNING id INTO v_inst_id;

      PERFORM seed_workflow_tasks(v_inst_id);

      RETURN jsonb_build_object('ok', true, 'workflow_pending', true, 'instance_id', v_inst_id);
    END;
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. apply_profile_pending_change — fix RAISE EXCEPTION ordinal day
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION apply_profile_pending_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id              uuid;
  v_data                jsonb;
  v_module              text;
  v_new_id              uuid;
  v_attachment          jsonb;
  v_day_of_month        int  := EXTRACT(DAY FROM CURRENT_DATE);
  v_prev_effective_from date;
BEGIN
  IF NEW.status <> 'approved' OR OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;

  v_module := NEW.module_code;
  v_data   := NEW.proposed_data;

  IF v_module NOT LIKE 'profile_%' THEN
    RETURN NEW;
  END IF;

  SELECT p.employee_id INTO v_emp_id
  FROM   profiles p
  WHERE  p.id = NEW.submitted_by;

  IF v_emp_id IS NULL THEN
    RAISE WARNING
      'apply_profile_pending_change: cannot resolve employee_id for submitted_by=%, module=%, pending_change=%',
      NEW.submitted_by, v_module, NEW.id;
    RETURN NEW;
  END IF;

  -- ── profile_personal → employee_personal ──────────────────────────────────
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

  -- ── profile_contact → employee_contact ────────────────────────────────────
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

  -- ── profile_address → employee_addresses ──────────────────────────────────
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

  -- ── profile_passport → passports ──────────────────────────────────────────
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

  -- ── profile_emergency_contact → emergency_contacts ────────────────────────
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

  -- ── profile_bank → employee_bank_accounts ─────────────────────────────────
  ELSIF v_module = 'profile_bank' THEN

    -- 20th-day approver block
    IF v_day_of_month > 20
       AND NOT (has_role('bank_exceptions') OR has_role('admin') OR has_role('hr'))
    THEN
      -- CHANGED (mig 303): use to_char(.., 'FMDDth') for correct ordinal day.
      -- Mig 299 wrote `%sth` in a RAISE format string; RAISE uses `%` (not
      -- `%s`) for substitution, so it produced literal "21sth"/"22sth"/etc.
      RAISE EXCEPTION
        'Bank account changes cannot be approved after the 20th of the month '
        '(payroll cut-off). Today is the %. '
        'Only bank_exceptions, admin, or hr roles may approve after this date.',
        to_char(CURRENT_DATE, 'FMDDth')
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Mig 302 close-out guard
    IF (v_data->>'prev_active_id') IS NOT NULL THEN
      SELECT effective_from INTO v_prev_effective_from
      FROM   employee_bank_accounts
      WHERE  id = (v_data->>'prev_active_id')::uuid;

      IF v_prev_effective_from IS NOT NULL
         AND v_prev_effective_from >= (v_data->>'effective_from')::date THEN
        DELETE FROM employee_bank_accounts
        WHERE  id = (v_data->>'prev_active_id')::uuid;
      ELSE
        UPDATE employee_bank_accounts
        SET    effective_to = (v_data->>'effective_from')::date - interval '1 day',
               updated_at   = now(),
               updated_by   = NEW.submitted_by
        WHERE  id = (v_data->>'prev_active_id')::uuid;
      END IF;
    END IF;

    INSERT INTO employee_bank_accounts (
      employee_id, bank_account_group_id, country_code, currency_code,
      bank_name, branch_name, branch_code, account_holder_name,
      account_number, ifsc_code, iban, swift_bic,
      is_primary, effective_from, effective_to,
      created_by, updated_by
    ) VALUES (
      (v_data->>'employee_id')::uuid,
      (v_data->>'bank_account_group_id')::uuid,
      v_data->>'country_code',
      v_data->>'currency_code',
      v_data->>'bank_name',
      v_data->>'branch_name',
      v_data->>'branch_code',
      v_data->>'account_holder_name',
      v_data->>'account_number',
      v_data->>'ifsc_code',
      v_data->>'iban',
      v_data->>'swift_bic',
      COALESCE((v_data->>'is_primary')::boolean, false),
      (v_data->>'effective_from')::date,
      '9999-12-31'::date,
      NEW.submitted_by,
      NEW.submitted_by
    )
    RETURNING id INTO v_new_id;

    IF v_data->'attachments' IS NOT NULL THEN
      FOR v_attachment IN SELECT * FROM jsonb_array_elements(v_data->'attachments') LOOP
        INSERT INTO employee_bank_attachments (
          bank_account_id, employee_id, file_name, file_type, file_size,
          storage_path, uploaded_by
        ) VALUES (
          v_new_id,
          (v_data->>'employee_id')::uuid,
          v_attachment->>'file_name',
          v_attachment->>'file_type',
          (v_attachment->>'file_size')::integer,
          v_attachment->>'storage_path',
          NEW.submitted_by
        );
      END LOOP;
    END IF;

  END IF;

  RETURN NEW;
END;
$$;


-- =============================================================================
-- Sanity check the ordinal formatter
-- =============================================================================
DO $$
DECLARE
  v_samples text[] := ARRAY[
    to_char(date '2026-05-01', 'FMDDth'),
    to_char(date '2026-05-02', 'FMDDth'),
    to_char(date '2026-05-03', 'FMDDth'),
    to_char(date '2026-05-11', 'FMDDth'),
    to_char(date '2026-05-21', 'FMDDth'),
    to_char(date '2026-05-22', 'FMDDth'),
    to_char(date '2026-05-23', 'FMDDth'),
    to_char(date '2026-05-31', 'FMDDth')
  ];
BEGIN
  ASSERT v_samples[1] = '1st',  format('expected 1st,  got %s', v_samples[1]);
  ASSERT v_samples[2] = '2nd',  format('expected 2nd,  got %s', v_samples[2]);
  ASSERT v_samples[3] = '3rd',  format('expected 3rd,  got %s', v_samples[3]);
  ASSERT v_samples[4] = '11th', format('expected 11th, got %s', v_samples[4]);
  ASSERT v_samples[5] = '21st', format('expected 21st, got %s', v_samples[5]);
  ASSERT v_samples[6] = '22nd', format('expected 22nd, got %s', v_samples[6]);
  ASSERT v_samples[7] = '23rd', format('expected 23rd, got %s', v_samples[7]);
  ASSERT v_samples[8] = '31st', format('expected 31st, got %s', v_samples[8]);

  RAISE NOTICE 'Migration 303 verified: ordinal day formatter works as expected.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 303
--
-- Post-migration:
--   npx supabase db push
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
--   (Function signatures unchanged — types regen is convention only.)
-- =============================================================================
