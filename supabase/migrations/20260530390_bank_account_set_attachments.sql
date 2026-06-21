-- =============================================================================
-- Migration 384 — bank account set: wire up attachments end-to-end
-- =============================================================================
-- Problem: The frontend (BankAccountsPortlet) was updated to pass p_attachments
-- to submit_bank_account_set, but:
--   1. The RPC didn't accept p_attachments → schema cache error
--   2. fn_apply_bank_account_set_transition never stored attachments
--   3. get_employee_bank_account_set returned hardcoded '[]' for attachments
--   4. employee_bank_attachments had no FK to employee_bank_account_item
--
-- Fix:
--   A. Add bank_account_item_id (nullable) to employee_bank_attachments so
--      set-based items can link their proof-of-account files.
--   B. Recreate fn_apply_bank_account_set_transition with p_attachments param:
--      reads attachments from each item's embedded 'attachments' array and
--      inserts into employee_bank_attachments. Backward-compatible default '[]'.
--   C. Recreate submit_bank_account_set to accept p_attachments and pass through.
--   D. Recreate get_employee_bank_account_set to return real attachments.
--
-- Callers not passing p_attachments (apply_profile_pending_change, bulk ops)
-- are unaffected — the DEFAULT '[]' handles them.
-- =============================================================================

-- ── A. Add bank_account_item_id to employee_bank_attachments ─────────────────

ALTER TABLE employee_bank_attachments
  ADD COLUMN IF NOT EXISTS bank_account_item_id UUID
    REFERENCES employee_bank_account_item(id) ON DELETE CASCADE;

-- Make bank_account_id nullable so set-based attachments don't need a legacy row
ALTER TABLE employee_bank_attachments
  ALTER COLUMN bank_account_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_bank_attachments_item
  ON employee_bank_attachments(bank_account_item_id)
  WHERE bank_account_item_id IS NOT NULL;

-- ── B. fn_apply_bank_account_set_transition — add p_attachments ──────────────

CREATE OR REPLACE FUNCTION fn_apply_bank_account_set_transition(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_actor          UUID,
  p_attachments    JSONB DEFAULT '[]'::jsonb  -- unused directly; attachments come from p_items[].attachments
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_set_id     UUID;
  v_current_set_id UUID;
  v_curr_eff_from  DATE;
  v_item           JSONB;
  v_group_id       UUID;
  v_item_id        UUID;
  v_att            JSONB;
BEGIN
  -- Advisory lock per employee to serialise concurrent transitions
  PERFORM pg_advisory_xact_lock(hashtext('bank_set:' || p_employee_id::TEXT));

  -- 1. Find and close current active set (if any)
  SELECT id, effective_from
    INTO v_current_set_id, v_curr_eff_from
  FROM employee_bank_account_set
  WHERE employee_id = p_employee_id
    AND is_active   = true
    AND effective_to = '9999-12-31'::date
  LIMIT 1;

  IF v_current_set_id IS NOT NULL THEN
    IF p_effective_from <= v_curr_eff_from THEN
      DELETE FROM employee_bank_account_set WHERE id = v_current_set_id;
    ELSE
      UPDATE employee_bank_account_set
         SET effective_to = p_effective_from - 1,
             updated_at   = NOW()
       WHERE id = v_current_set_id;
    END IF;
  END IF;

  -- 2. Insert new set
  INSERT INTO employee_bank_account_set (
    employee_id, effective_from, effective_to, is_active, created_by
  ) VALUES (
    p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor
  )
  RETURNING id INTO v_new_set_id;

  -- 3. Insert items and their attachments
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_group_id := COALESCE(
      NULLIF(v_item->>'bank_account_group_id', '')::uuid,
      gen_random_uuid()
    );

    INSERT INTO employee_bank_account_item (
      set_id,
      bank_account_group_id,
      country_code,
      currency_code,
      bank_name,
      branch_name,
      branch_code,
      account_holder_name,
      account_number,
      ifsc_code,
      iban,
      swift_bic,
      is_primary
    ) VALUES (
      v_new_set_id,
      v_group_id,
      v_item->>'country_code',
      v_item->>'currency_code',
      v_item->>'bank_name',
      NULLIF(v_item->>'branch_name', ''),
      NULLIF(v_item->>'branch_code', ''),
      v_item->>'account_holder_name',
      v_item->>'account_number',
      NULLIF(v_item->>'ifsc_code',  ''),
      NULLIF(v_item->>'iban',       ''),
      NULLIF(v_item->>'swift_bic',  ''),
      COALESCE((v_item->>'is_primary')::boolean, false)
    )
    RETURNING id INTO v_item_id;

    -- Insert attachments embedded in this item
    IF v_item->'attachments' IS NOT NULL AND jsonb_array_length(v_item->'attachments') > 0 THEN
      FOR v_att IN SELECT * FROM jsonb_array_elements(v_item->'attachments') LOOP
        INSERT INTO employee_bank_attachments (
          bank_account_item_id,
          employee_id,
          file_name,
          file_type,
          file_size,
          storage_path,
          uploaded_by
        ) VALUES (
          v_item_id,
          p_employee_id,
          v_att->>'file_name',
          COALESCE(v_att->>'file_type', 'application/octet-stream'),
          COALESCE((v_att->>'file_size')::integer, 0),
          v_att->>'storage_path',
          p_actor
        );
      END LOOP;
    END IF;
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID, JSONB) TO authenticated;

-- Keep old 4-arg signature working for apply_profile_pending_change + bulk ops
-- (they call without p_attachments). PostgreSQL will route by arity.
-- Old signature already exists at (UUID, DATE, JSONB, UUID) — no action needed
-- because CREATE OR REPLACE above adds a new overload with DEFAULT.
-- But to be safe, explicitly drop the old 4-arg version so there's no ambiguity:
DROP FUNCTION IF EXISTS fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID);

COMMENT ON FUNCTION fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID, JSONB) IS
  'Mig 384: added p_attachments param (default empty). Stores per-item attachments '
  'into employee_bank_attachments.bank_account_item_id after inserting each item. '
  'Backward-compatible: callers omitting p_attachments get the default empty array.';


-- ── C. submit_bank_account_set — add p_attachments param ─────────────────────

CREATE OR REPLACE FUNCTION submit_bank_account_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_attachments    JSONB DEFAULT '[]'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor              UUID := auth.uid();
  v_item_count         INTEGER;
  v_item               JSONB;
  v_primary_count      INTEGER := 0;
  v_added_count        INTEGER := 0;
  v_removed_count      INTEGER := 0;
  v_template_id        UUID;
  v_template_code      TEXT;
  v_pending_id         UUID;
  v_instance_id        UUID;
  v_new_set_id         UUID;
  v_change_summary     TEXT;
  v_group_id           UUID;
  v_seen_groups        UUID[] := '{}';
  v_is_hire_pipeline   BOOLEAN := false;
BEGIN
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_items must be a JSONB array';
  END IF;

  v_item_count := jsonb_array_length(p_items);

  SELECT EXISTS (
    SELECT 1 FROM employees WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire_pipeline;

  -- ── Empty-set guard ───────────────────────────────────────────────────────
  IF v_item_count = 0 THEN
    IF v_is_hire_pipeline THEN
      RETURN jsonb_build_object('ok', true, 'workflow', false, 'noop', true);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM employee_bank_account_set
      WHERE employee_id = p_employee_id AND is_active = true AND effective_to = '9999-12-31'::date
    ) THEN
      RETURN jsonb_build_object('ok', true, 'workflow', false, 'noop', true);
    END IF;
  END IF;

  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'edit',   p_employee_id)
    OR user_can('bank_accounts', 'create', p_employee_id)
    OR (v_is_hire_pipeline AND user_can('bank_accounts', 'edit', NULL) AND user_can('hire_employee', 'edit', NULL))
  ) THEN
    RAISE EXCEPTION 'Access denied for bank set submission on employee %', p_employee_id USING ERRCODE = '42501';
  END IF;

  -- ── Submission cutoff (ESS only, not hire pipeline) ───────────────────────
  IF NOT v_is_hire_pipeline AND EXTRACT(DAY FROM CURRENT_DATE) > 15
    AND NOT is_super_admin() AND NOT user_can('bank_accounts', 'edit', NULL)
  THEN
    RAISE EXCEPTION 'Bank account changes may only be submitted between the 1st and 15th of the month.';
  END IF;

  IF p_effective_from IS NULL THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_effective_from is required';
  END IF;
  p_effective_from := date_trunc('month', p_effective_from)::date;

  -- ── Per-item validation ───────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NOT (v_item ? 'bank_name' AND v_item ? 'account_holder_name'
            AND v_item ? 'account_number' AND v_item ? 'country_code' AND v_item ? 'currency_code') THEN
      RAISE EXCEPTION 'submit_bank_account_set: each item must include bank_name, account_holder_name, account_number, country_code, currency_code';
    END IF;
    IF (v_item->>'is_primary')::boolean THEN v_primary_count := v_primary_count + 1; END IF;
    IF (v_item->>'bank_account_group_id') IS NULL THEN v_added_count := v_added_count + 1; END IF;
    v_group_id := NULLIF(v_item->>'bank_account_group_id', '')::uuid;
    IF v_group_id IS NOT NULL THEN
      IF v_group_id = ANY(v_seen_groups) THEN
        RAISE EXCEPTION 'submit_bank_account_set: duplicate bank_account_group_id % in proposed set', v_group_id;
      END IF;
      v_seen_groups := array_append(v_seen_groups, v_group_id);
    END IF;
  END LOOP;

  IF v_item_count > 0 AND v_primary_count <> 1 THEN
    RAISE EXCEPTION 'submit_bank_account_set: exactly one item must have is_primary = true (found %)', v_primary_count;
  END IF;

  SELECT COUNT(*) INTO v_removed_count
  FROM employee_bank_account_item bai
  JOIN employee_bank_account_set  bas ON bas.id = bai.set_id
  WHERE bas.employee_id = p_employee_id AND bas.is_active = true AND bas.effective_to = '9999-12-31'::date
    AND bai.bank_account_group_id <> ALL(
      SELECT COALESCE((j->>'bank_account_group_id')::uuid, gen_random_uuid())
      FROM jsonb_array_elements(p_items) j
    );

  v_change_summary := format('%s added, %s removed, %s accounts in proposed set', v_added_count, v_removed_count, v_item_count);

  -- ── Resolve workflow (hire pipeline → PATH A) ─────────────────────────────
  IF v_is_hire_pipeline THEN
    v_template_id := NULL;
  ELSE
    v_template_id := resolve_workflow_for_submission('profile_bank', v_actor);
  END IF;

  IF v_template_id IS NOT NULL THEN
    SELECT code INTO v_template_code FROM workflow_templates WHERE id = v_template_id;
    -- Workflow path: store items + attachments in pending_changes for later apply
    INSERT INTO workflow_pending_changes (module_code, record_id, status, submitted_by, proposed_data, created_at)
    VALUES ('profile_bank', p_employee_id, 'pending', v_actor,
      jsonb_build_object(
        'employee_id',    p_employee_id,
        'effective_from', p_effective_from,
        'items',          p_items,
        'attachments',    p_attachments
      ), NOW())
    RETURNING id INTO v_pending_id;

    PERFORM wf_submit(
      p_template_code => v_template_code, p_module_code => 'profile_bank',
      p_record_id => p_employee_id,
      p_metadata => jsonb_build_object('employee_id', p_employee_id, 'pending_change_id', v_pending_id, 'change_summary', v_change_summary)
    );

    SELECT id INTO v_instance_id FROM workflow_instances
    WHERE module_code = 'profile_bank' AND record_id = p_employee_id
      AND status NOT IN ('approved', 'rejected', 'withdrawn')
    ORDER BY created_at DESC LIMIT 1;

    UPDATE workflow_pending_changes SET instance_id = v_instance_id WHERE id = v_pending_id;

    RETURN jsonb_build_object('ok', true, 'workflow', true, 'instance_id', v_instance_id,
      'pending_change_id', v_pending_id, 'effective_from', p_effective_from, 'change_summary', v_change_summary);
  ELSE
    -- PATH A: direct write — pass items (with embedded attachments) through
    v_new_set_id := fn_apply_bank_account_set_transition(p_employee_id, p_effective_from, p_items, v_actor);
    RETURN jsonb_build_object('ok', true, 'workflow', false, 'set_id', v_new_set_id,
      'effective_from', p_effective_from, 'change_summary', v_change_summary);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB, JSONB) TO authenticated;

-- Drop old 3-arg version so there's no ambiguity in schema cache
DROP FUNCTION IF EXISTS submit_bank_account_set(UUID, DATE, JSONB);

COMMENT ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB, JSONB) IS
  'Mig 384: added p_attachments param (default empty, backward-compatible). '
  'Attachments are embedded in p_items[].attachments and stored via '
  'fn_apply_bank_account_set_transition → employee_bank_attachments.bank_account_item_id.';


-- ── D. get_employee_bank_account_set — return real attachments ────────────────

DROP FUNCTION IF EXISTS get_employee_bank_account_set(UUID, DATE);

CREATE OR REPLACE FUNCTION get_employee_bank_account_set(
  p_employee_id UUID,
  p_as_of       DATE DEFAULT CURRENT_DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_set_row employee_bank_account_set%ROWTYPE;
  v_items   JSONB;
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'view', p_employee_id)
    OR user_can('bank_accounts', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employee.view_bank_accounts')
    )
    OR (
      user_can('bank_accounts', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = p_employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'get_employee_bank_account_set: access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO v_set_row
  FROM employee_bank_account_set
  WHERE employee_id    = p_employee_id
    AND is_active      = true
    AND effective_from <= p_as_of
    AND effective_to   >= p_as_of
  ORDER BY effective_from DESC
  LIMIT 1;

  IF v_set_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'set', NULL, 'items', '[]'::jsonb);
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',                    i.id,
        'bank_account_group_id', i.bank_account_group_id,
        'country_code',          i.country_code,
        'currency_code',         i.currency_code,
        'bank_name',             i.bank_name,
        'branch_name',           i.branch_name,
        'branch_code',           i.branch_code,
        'account_holder_name',   i.account_holder_name,
        'account_number',        i.account_number,
        'ifsc_code',             i.ifsc_code,
        'iban',                  i.iban,
        'swift_bic',             i.swift_bic,
        'is_primary',            i.is_primary,
        'attachments', (
          SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
              'file_name',    a.file_name,
              'file_type',    a.file_type,
              'file_size',    a.file_size,
              'storage_path', a.storage_path
            )
            ORDER BY a.uploaded_at
          ), '[]'::jsonb)
          FROM employee_bank_attachments a
          WHERE a.bank_account_item_id = i.id
            AND a.is_active = true
        )
      )
      ORDER BY i.is_primary DESC, i.bank_name
    ),
    '[]'::jsonb
  )
    INTO v_items
  FROM employee_bank_account_item i
  WHERE i.set_id = v_set_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'set', jsonb_build_object(
      'id',             v_set_row.id,
      'employee_id',    v_set_row.employee_id,
      'effective_from', v_set_row.effective_from,
      'effective_to',   v_set_row.effective_to,
      'is_active',      v_set_row.is_active,
      'created_at',     v_set_row.created_at
    ),
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION get_employee_bank_account_set(UUID, DATE) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_bank_account_set(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION get_employee_bank_account_set(UUID, DATE) IS
  'Mig 384: attachments subquery now reads employee_bank_attachments by '
  'bank_account_item_id instead of returning hardcoded [].';

-- ── Verify ───────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'employee_bank_attachments'
      AND column_name = 'bank_account_item_id'
  ) THEN
    RAISE EXCEPTION 'mig 384: bank_account_item_id column missing from employee_bank_attachments';
  END IF;
  RAISE NOTICE 'mig 384: bank account set attachments wired up successfully';
END;
$$;
