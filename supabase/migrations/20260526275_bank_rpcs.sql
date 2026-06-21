-- =============================================================================
-- Migration 275: Employee Bank Accounts — RPCs
--
-- FUNCTIONS
-- ─────────
--   1. upsert_bank_account          — Add new account or amend existing.
--                                     Direct-write if no workflow assigned.
--                                     Submits via workflow if assigned.
--                                     Enforces 15th-of-month date cutoff
--                                     (bypass: bank_exceptions role, new hire flag).
--
--   2. get_employee_bank_accounts   — Fetch all bank accounts for an employee
--                                     (active only, or with full history).
--                                     Includes attached file metadata.
--
--   3. get_bank_picklist            — Return banks filtered by country ISO code.
--
--   4. apply_profile_pending_change — UPDATED to add profile_bank ELSIF branch.
--                                     Rewrites the trigger function from mig 117
--                                     to apply approved bank account changes.
--
-- EFFECTIVE DATING LOGIC (upsert_bank_account)
-- ─────────────────────────────────────────────
--   "Add New Account" → p_bank_account_group_id = NULL
--     • New group UUID generated automatically.
--     • No existing records closed.
--
--   "Amend Existing Account" → p_bank_account_group_id = existing group UUID
--     • The current active record in that group (effective_to = '9999-12-31')
--       is closed: effective_to = p_effective_from - 1 day.
--     • New record inserted with same group_id and effective_to = '9999-12-31'.
--     • is_primary inherited from the previous version unless explicitly set.
--
-- DATE CUTOFF RULES (enforced at RPC layer)
-- ──────────────────────────────────────────
--   Standard employees (ESS):
--     Submission blocked after the 15th of the current month.
--     p_effective_from must be the 1st of a future (or current) month.
--
--   Approver side:
--     Separate check in the frontend: blocked after 20th.
--     The 20th check is NOT enforced here — it is enforced in WorkflowReview.tsx
--     because the RPC is called by the SUBMITTER (or initiator during hire).
--
--   Exemptions (no date rules applied):
--     • p_is_new_hire = true       — hire flow, effective_from = hire date
--     • has_role('bank_exceptions') — can submit any time
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_bank_picklist(p_country_iso_code)
--    Returns banks filtered by the given alpha-3 ISO code (IND/LKA/PAK/SAU).
--    The BANK picklist has parent_value_id → ID_COUNTRY row where
--    ID_COUNTRY.meta->>'isoCode' = p_country_iso_code.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_bank_picklist(
  p_country_iso_code text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',      pv.id,
      'value',   pv.value,
      'ref_id',  pv.ref_id
    ) ORDER BY pv.value
  )
  INTO v_result
  FROM   picklist_values pv
  JOIN   picklists       pl ON pl.id = pv.picklist_id
  JOIN   picklist_values parent_pv ON parent_pv.id = pv.parent_value_id
  JOIN   picklists       parent_pl ON parent_pl.id = parent_pv.picklist_id
  WHERE  pl.picklist_id        = 'BANK'
    AND  pv.active             = true
    AND  parent_pl.picklist_id = 'ID_COUNTRY'
    AND  (parent_pv.meta->>'isoCode') = upper(p_country_iso_code);

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION get_bank_picklist(text) IS
  'Returns active banks for the given alpha-3 country ISO code (e.g. IND, LKA, PAK, SAU). '
  'Filters the BANK picklist by parent ID_COUNTRY row meta.isoCode. '
  'Returns [] for unknown country codes — no error. Mig 275.';

REVOKE ALL     ON FUNCTION get_bank_picklist(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_bank_picklist(text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_employee_bank_accounts(p_employee_id, p_include_history)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_employee_bank_accounts(
  p_employee_id     uuid,
  p_include_history boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    user_can('bank_accounts', 'view', p_employee_id)
    OR user_can('bank_accounts', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employee.view_bank_accounts')
    )
  ) THEN
    RAISE EXCEPTION 'get_employee_bank_accounts: access denied for employee %', p_employee_id;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',                    eba.id,
      'bank_account_group_id', eba.bank_account_group_id,
      'country_code',          eba.country_code,
      'currency_code',         eba.currency_code,
      'bank_name',             eba.bank_name,
      'branch_name',           eba.branch_name,
      'branch_code',           eba.branch_code,
      'account_holder_name',   eba.account_holder_name,
      'account_number',        eba.account_number,
      'ifsc_code',             eba.ifsc_code,
      'iban',                  eba.iban,
      'swift_bic',             eba.swift_bic,
      'is_primary',            eba.is_primary,
      'effective_from',        eba.effective_from,
      'effective_to',          eba.effective_to,
      'is_active',             (eba.effective_to = '9999-12-31'::date),
      'created_at',            eba.created_at,
      'attachments', (
        SELECT COALESCE(jsonb_agg(
          jsonb_build_object(
            'id',           a.id,
            'file_name',    a.file_name,
            'file_type',    a.file_type,
            'file_size',    a.file_size,
            'storage_path', a.storage_path,
            'uploaded_at',  a.uploaded_at
          ) ORDER BY a.uploaded_at
        ), '[]'::jsonb)
        FROM employee_bank_attachments a
        WHERE a.bank_account_id = eba.id
          AND a.is_active = true
      )
    )
    ORDER BY eba.is_primary DESC, eba.effective_from DESC, eba.bank_name
  )
  INTO v_result
  FROM employee_bank_accounts eba
  WHERE eba.employee_id = p_employee_id
    AND (p_include_history OR eba.effective_to = '9999-12-31'::date);

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION get_employee_bank_accounts(uuid, boolean) IS
  'Returns bank accounts for an employee. Pass p_include_history=true for full '
  'effective-dated history. Each record includes its active attachments. '
  'Access-guarded: caller must have view or edit bank_accounts permission scoped '
  'to the target employee. Mig 275.';

REVOKE ALL     ON FUNCTION get_employee_bank_accounts(uuid, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_bank_accounts(uuid, boolean) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. upsert_bank_account(...)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_bank_account(
  -- ── Required parameters (no defaults — must always be supplied) ──────────
  p_employee_id             uuid,
  p_country_code            text,
  p_currency_code           text,
  p_bank_name               text,
  p_account_holder_name     text,
  p_account_number          text,
  p_effective_from          date,
  -- ── Optional parameters (defaults — must come after all required) ────────
  p_bank_account_group_id   uuid       DEFAULT NULL,   -- NULL = new account
  p_branch_name             text       DEFAULT NULL,
  p_branch_code             text       DEFAULT NULL,
  p_ifsc_code               text       DEFAULT NULL,
  p_iban                    text       DEFAULT NULL,
  p_swift_bic               text       DEFAULT NULL,
  p_is_primary              boolean    DEFAULT false,
  p_is_new_hire             boolean    DEFAULT false,
  p_attachments             jsonb      DEFAULT '[]'::jsonb  -- [{file_name,file_type,file_size,storage_path}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id          uuid    := auth.uid();
  v_group_id           uuid;
  v_new_account_id     uuid;
  v_today              date    := current_date;
  v_day_of_month       int     := EXTRACT(DAY FROM v_today)::int;
  v_month_first        date;
  v_prev_active        employee_bank_accounts%ROWTYPE;
  v_template_id        uuid;
  v_template_code      text;
  v_pending_id         uuid;
  v_instance_id        uuid;
  v_is_bank_exception  boolean;
  v_attachment         jsonb;
BEGIN

  -- ── 1. Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    user_can('bank_accounts', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employee.edit_bank_accounts')
    )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: you do not have permission to edit bank accounts for this employee.');
  END IF;

  -- ── 2. Input validation ──────────────────────────────────────────────────────
  IF p_country_code IS NULL OR trim(p_country_code) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Country is required.');
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
  -- effective_from must be 1st of month
  IF EXTRACT(DAY FROM p_effective_from) != 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Effective from date must be the 1st of the month.');
  END IF;

  -- Country-specific mandatory fields
  IF p_country_code = 'IND' AND (p_ifsc_code IS NULL OR trim(p_ifsc_code) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'IFSC code is required for India.');
  END IF;
  IF p_country_code = 'LKA' AND (p_branch_code IS NULL OR trim(p_branch_code) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Branch code is required for Sri Lanka.');
  END IF;
  IF p_country_code IN ('PAK', 'SAU') AND (p_iban IS NULL OR trim(p_iban) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'IBAN is required for ' || p_country_code || '.');
  END IF;

  -- Attachment is mandatory
  IF p_attachments IS NULL OR jsonb_array_length(p_attachments) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'At least one proof-of-account attachment is required.');
  END IF;

  -- ── 3. Date cutoff check (skipped for new hires and bank_exceptions role) ────
  v_is_bank_exception := has_role('bank_exceptions') OR has_role('admin') OR has_role('hr');

  IF NOT p_is_new_hire AND NOT v_is_bank_exception THEN
    -- ESS submission: blocked after the 15th of the current month
    IF v_day_of_month > 15 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', format(
          'Bank account changes can only be submitted on or before the 15th of the month. '
          'Today is the %sth. Please resubmit from the 1st of next month.',
          v_day_of_month
        )
      );
    END IF;
    -- effective_from must not be in the past
    v_month_first := date_trunc('month', v_today)::date;
    IF p_effective_from < v_month_first THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Effective from date cannot be in the past.');
    END IF;
  END IF;

  -- ── 4. Resolve group_id ───────────────────────────────────────────────────────
  IF p_bank_account_group_id IS NOT NULL THEN
    -- Amendment: verify the group belongs to this employee
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
    -- New account: generate a fresh group UUID
    v_group_id := gen_random_uuid();
  END IF;

  -- ── 5. Check for workflow assignment ──────────────────────────────────────────
  v_template_id := resolve_workflow_for_submission('profile_bank', v_caller_id);

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH A: No workflow → direct write
  -- ════════════════════════════════════════════════════════════════════════════
  IF v_template_id IS NULL THEN

    -- Close the previous active version if this is an amendment
    IF v_prev_active.id IS NOT NULL THEN
      -- Inherit is_primary from previous version if caller didn't explicitly set it
      -- (p_is_primary = false default means caller didn't override; use prev value)
      -- We always use the explicitly passed p_is_primary in the new row;
      -- if closing, keep the closed row's is_primary as-is (historical record).
      UPDATE employee_bank_accounts
      SET    effective_to = p_effective_from - interval '1 day',
             updated_at   = now(),
             updated_by   = v_caller_id
      WHERE  id = v_prev_active.id;
    END IF;

    -- Insert the new version
    INSERT INTO employee_bank_accounts (
      employee_id, bank_account_group_id, country_code, currency_code,
      bank_name, branch_name, branch_code, account_holder_name,
      account_number, ifsc_code, iban, swift_bic,
      is_primary, effective_from, effective_to,
      created_by, updated_by
    ) VALUES (
      p_employee_id, v_group_id, upper(p_country_code), p_currency_code,
      p_bank_name, p_branch_name, p_branch_code, p_account_holder_name,
      p_account_number, p_ifsc_code, p_iban, p_swift_bic,
      p_is_primary, p_effective_from, '9999-12-31'::date,
      v_caller_id, v_caller_id
    )
    RETURNING id INTO v_new_account_id;

    -- Insert attachments
    FOR v_attachment IN SELECT * FROM jsonb_array_elements(p_attachments) LOOP
      INSERT INTO employee_bank_attachments (
        bank_account_id, employee_id, file_name, file_type, file_size,
        storage_path, uploaded_by
      ) VALUES (
        v_new_account_id,
        p_employee_id,
        v_attachment->>'file_name',
        v_attachment->>'file_type',
        (v_attachment->>'file_size')::integer,
        v_attachment->>'storage_path',
        v_caller_id
      );
    END LOOP;

    RETURN jsonb_build_object(
      'ok',               true,
      'bank_account_id',  v_new_account_id,
      'bank_account_group_id', v_group_id,
      'workflow',         false
    );

  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH B: Workflow assigned → submit via pending change
  -- ════════════════════════════════════════════════════════════════════════════

  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_template_id;

  -- Stash all fields in proposed_data so apply_profile_pending_change
  -- can reconstruct the bank account row when the workflow is approved.
  INSERT INTO workflow_pending_changes (
    module_code, record_id, action, proposed_data, submitted_by
  ) VALUES (
    'profile_bank',
    -- record_id = existing bank account id (amendment) or NULL (new)
    CASE WHEN v_prev_active.id IS NOT NULL THEN v_prev_active.id ELSE NULL END,
    CASE WHEN p_bank_account_group_id IS NOT NULL THEN 'update' ELSE 'create' END,
    jsonb_build_object(
      'employee_id',              p_employee_id,
      'bank_account_group_id',    v_group_id,
      'country_code',             upper(p_country_code),
      'currency_code',            p_currency_code,
      'bank_name',                p_bank_name,
      'branch_name',              p_branch_name,
      'branch_code',              p_branch_code,
      'account_holder_name',      p_account_holder_name,
      'account_number',           p_account_number,
      'ifsc_code',                p_ifsc_code,
      'iban',                     p_iban,
      'swift_bic',                p_swift_bic,
      'is_primary',               p_is_primary,
      'effective_from',           p_effective_from,
      'prev_active_id',           v_prev_active.id,   -- NULL for new accounts
      'attachments',              p_attachments
    ),
    v_caller_id
  )
  RETURNING id INTO v_pending_id;

  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => 'profile_bank',
    p_record_id     => v_pending_id,
    p_metadata      => jsonb_build_object(
      'employee_id',    p_employee_id,
      'bank_name',      p_bank_name,
      'country_code',   p_country_code,
      'account_number', right(p_account_number, 4)  -- last 4 digits only in metadata
    )
  );

  UPDATE workflow_pending_changes
  SET    instance_id = v_instance_id
  WHERE  id = v_pending_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'pending_change_id', v_pending_id,
    'instance_id',       v_instance_id,
    'bank_account_group_id', v_group_id,
    'workflow',          true
  );

EXCEPTION WHEN OTHERS THEN
  -- Roll back any partial writes
  DELETE FROM workflow_pending_changes WHERE id = v_pending_id;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_bank_account(uuid, text, text, text, text, text, date, uuid, text, text, text, text, text, boolean, boolean, jsonb) IS
  'Add a new bank account (p_bank_account_group_id = NULL) or amend an existing one '
  '(p_bank_account_group_id = group UUID). Enforces 15th-of-month submission cutoff '
  'for standard employees; bypassed by bank_exceptions / admin / hr roles and the new-hire flag. '
  'Writes directly if no workflow is assigned for profile_bank; otherwise submits '
  'via workflow_pending_changes and wf_submit. Attachments array is mandatory. '
  'Mig 275: initial creation.';

REVOKE ALL     ON FUNCTION upsert_bank_account(uuid, text, text, text, text, text, date, uuid, text, text, text, text, text, boolean, boolean, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_bank_account(uuid, text, text, text, text, text, date, uuid, text, text, text, text, text, boolean, boolean, jsonb) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Update apply_profile_pending_change to handle profile_bank
--    Adds an ELSIF branch after the existing emergency_contacts branch.
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_new_id uuid;
  v_attachment jsonb;
BEGIN
  -- Only fire when status transitions INTO 'approved'
  IF NEW.status <> 'approved' OR OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;

  v_module := NEW.module_code;
  v_data   := NEW.proposed_data;

  -- Only handle profile_* modules
  IF v_module NOT LIKE 'profile_%' THEN
    RETURN NEW;
  END IF;

  -- Resolve the employee's UUID via the submitter's profile
  SELECT p.employee_id INTO v_emp_id
  FROM   profiles p
  WHERE  p.id = NEW.submitted_by;

  IF v_emp_id IS NULL THEN
    RAISE WARNING
      'apply_profile_pending_change: cannot resolve employee_id for submitted_by=%, module=%, pending_change=%',
      NEW.submitted_by, v_module, NEW.id;
    RETURN NEW;
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

  -- ── profile_bank → employee_bank_accounts ───────────────────────────────
  --    proposed_data shape:
  --      { employee_id, bank_account_group_id, country_code, currency_code,
  --        bank_name, branch_name, branch_code, account_holder_name,
  --        account_number, ifsc_code, iban, swift_bic, is_primary,
  --        effective_from, prev_active_id (nullable), attachments[] }
  ELSIF v_module = 'profile_bank' THEN

    -- Close the previous active version if amending
    IF (v_data->>'prev_active_id') IS NOT NULL THEN
      UPDATE employee_bank_accounts
      SET    effective_to = (v_data->>'effective_from')::date - interval '1 day',
             updated_at   = now(),
             updated_by   = NEW.submitted_by
      WHERE  id = (v_data->>'prev_active_id')::uuid;
    END IF;

    -- Insert the new bank account version
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

    -- Insert attachments from proposed_data
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

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'AFTER UPDATE trigger on workflow_pending_changes. '
  'Fires when status transitions to ''approved'' for any profile_* module. '
  'Applies proposed_data to the correct satellite table. '
  'Modules: profile_personal → employee_personal, profile_contact → employee_contact, '
  'profile_address → employee_addresses, profile_passport → passports, '
  'profile_emergency_contact → emergency_contacts. '
  'Mig 117: initial creation. Mig 275: added profile_bank → employee_bank_accounts.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Verification
-- ─────────────────────────────────────────────────────────────────────────────

SELECT proname, prosecdef
FROM   pg_proc
WHERE  proname IN (
  'upsert_bank_account',
  'get_employee_bank_accounts',
  'get_bank_picklist',
  'apply_profile_pending_change'
)
ORDER BY proname;

-- =============================================================================
-- END OF MIGRATION 275
-- =============================================================================
