-- =============================================================================
-- Migration 329: bank account set RPCs
--
-- DESIGN REFERENCE
-- ────────────────
-- docs/set-snapshot-design.md §4.2
--
-- WHAT
-- ────
-- Four SECURITY DEFINER RPCs for the bank account set-snapshot tables (mig 328):
--
--   1. get_employee_bank_account_set(p_employee_id, p_as_of)
--      — Read the active set + items for a given date.
--
--   2. get_employee_bank_account_set_history(p_employee_id)
--      — All historical sets, newest-first.
--
--   3. fn_apply_bank_account_set_transition(p_employee_id, p_effective_from,
--      p_items, p_actor)
--      — Internal: closes current set, inserts new set + items, assigns
--        bank_account_group_id to new entries. Called by submit_bank_account_set
--        (Path A) and apply_profile_pending_change (Path B, mig 330).
--
--   4. submit_bank_account_set(p_employee_id, p_effective_from, p_items)
--      — Main write entry point. Enforces 15th-submission cutoff (unless exempt).
--        Snaps effective_from to 1st of month. Dual-path: workflow vs direct.
--
-- BANK-SPECIFIC RULES (vs. dependent set)
-- ────────────────────────────────────────
--   • effective_from: server snaps to 1st of the submitted month.
--   • Submission day cutoff: must be on or before the 15th (unless
--     has_role('bank_exceptions') OR has_role('admin') OR has_role('hr')).
--   • Exactly one item with is_primary = true; zero primaries → error.
--   • Country-specific field validation per item (mirrors upsert_bank_account).
--   • 20th-of-month approver cutoff enforced in apply_profile_pending_change
--     (mig 330), not here.
--
-- proposed_data shape stored in workflow_pending_changes:
--   {
--     "employee_id":    "<uuid>",
--     "effective_from": "YYYY-MM-01",
--     "items": [
--       {
--         "bank_account_group_id": "<uuid>" | null,   -- null = new account
--         "country_code": "IND",
--         "currency_code": "INR",
--         "bank_name": "...",
--         "branch_name": "...",        -- required for IND / LKA
--         "branch_code": "...",        -- required for LKA
--         "account_holder_name": "...",
--         "account_number": "...",
--         "ifsc_code": "...",          -- required for IND
--         "iban": "...",               -- required for PAK / SAU
--         "swift_bic": "...",
--         "is_primary": true | false
--       }, ...
--     ]
--   }
--
-- ROLLBACK
-- ────────
-- DROP FUNCTION submit_bank_account_set(uuid, date, jsonb);
-- DROP FUNCTION fn_apply_bank_account_set_transition(uuid, date, jsonb, uuid);
-- DROP FUNCTION get_employee_bank_account_set(uuid, date);
-- DROP FUNCTION get_employee_bank_account_set_history(uuid);
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_employee_bank_account_set
-- ─────────────────────────────────────────────────────────────────────────────

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
  -- Access guard mirrors the SELECT RLS policy from mig 328
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

  -- Find the active set on p_as_of
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
    RETURN jsonb_build_object(
      'ok',    true,
      'set',   NULL,
      'items', '[]'::jsonb
    );
  END IF;

  -- Build items array (ordered: primary first, then by bank_name)
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
        'attachments',           '[]'::jsonb   -- legacy attachments accessed via employee_bank_accounts
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
GRANT EXECUTE ON FUNCTION get_employee_bank_account_set(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION get_employee_bank_account_set(UUID, DATE) IS
  'Returns the bank account set active on p_as_of for an employee, with items. '
  'Returns { ok: true, set: null, items: [] } when no active set exists. '
  'SECURITY DEFINER: enforces the same RLS guard as mig 328. Mig 329.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_employee_bank_account_set_history
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_employee_bank_account_set_history(UUID);

CREATE OR REPLACE FUNCTION get_employee_bank_account_set_history(
  p_employee_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_sets JSONB;
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'history', p_employee_id)
    OR user_can('bank_accounts', 'view',    p_employee_id)
    OR user_can('bank_accounts', 'edit',    p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employee.view_bank_accounts')
    )
  ) THEN
    RAISE EXCEPTION 'get_employee_bank_account_set_history: access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'set_id',         s.id,
        'effective_from', s.effective_from,
        'effective_to',   s.effective_to,
        'is_active',      s.is_active,
        'created_at',     s.created_at,
        'item_count',     COALESCE(ic.cnt, 0),
        'items',          COALESCE(it.items, '[]'::jsonb)
      )
      ORDER BY s.effective_from DESC
    ),
    '[]'::jsonb
  )
    INTO v_sets
  FROM employee_bank_account_set s
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INTEGER AS cnt
    FROM employee_bank_account_item WHERE set_id = s.id
  ) ic ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id',                    i.id,
        'bank_account_group_id', i.bank_account_group_id,
        'bank_name',             i.bank_name,
        'account_number',        i.account_number,
        'country_code',          i.country_code,
        'is_primary',            i.is_primary
      )
      ORDER BY i.is_primary DESC, i.bank_name
    ) AS items
    FROM employee_bank_account_item i
    WHERE i.set_id = s.id
  ) it ON true
  WHERE s.employee_id = p_employee_id;

  RETURN jsonb_build_object('ok', true, 'sets', v_sets);
END;
$$;

REVOKE ALL ON FUNCTION get_employee_bank_account_set_history(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_employee_bank_account_set_history(UUID) TO authenticated;

COMMENT ON FUNCTION get_employee_bank_account_set_history(UUID) IS
  'Returns every bank account set for the employee in reverse chronological order. '
  'Items included (condensed — no full field list; use get_employee_bank_account_set '
  'for the full payload). Mig 329.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. fn_apply_bank_account_set_transition (internal)
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID);

CREATE OR REPLACE FUNCTION fn_apply_bank_account_set_transition(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_actor          UUID
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
      -- Same-day or earlier → delete current set (items cascade)
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

  -- 3. Insert items, generating bank_account_group_id for new entries
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
    );
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID) IS
  'Internal: materialises a proposed bank account set. Closes (or deletes if '
  'same-day) the current open set, inserts a new set + items, auto-assigns '
  'bank_account_group_id to new accounts. Trusts caller for access checks. '
  'Called from submit_bank_account_set (Path A) and apply_profile_pending_change '
  '(Path B, mig 330). Mig 329.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. submit_bank_account_set (main write entry point)
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS submit_bank_account_set(UUID, DATE, JSONB);

CREATE OR REPLACE FUNCTION submit_bank_account_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor               UUID := auth.uid();
  v_effective_snap      DATE;
  v_is_exempt           BOOLEAN;
  v_item_count          INTEGER;
  v_primary_count       INTEGER;
  v_template_id         UUID;
  v_template_code       TEXT;
  v_workflow_pending_id UUID;
  v_instance_id         UUID;
  v_employee_name       TEXT;
  v_set_id              UUID;
  v_current_set_id      UUID;
  v_current_codes       UUID[];
  v_proposed_codes      UUID[];
  v_added_count         INTEGER;
  v_removed_count       INTEGER;
  v_change_summary      TEXT;
  v_item                JSONB;
  v_seen_groups         UUID[] := ARRAY[]::UUID[];
  v_group_id            UUID;
BEGIN
  -- ── Snap effective_from to 1st of month ──────────────────────────────────
  v_effective_snap := date_trunc('month', p_effective_from)::date;

  -- ── Validate shape ────────────────────────────────────────────────────────
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_items must be a JSONB array';
  END IF;

  v_item_count := jsonb_array_length(p_items);

  IF v_item_count = 0 THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_items must contain at least one item';
  END IF;

  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'edit',   p_employee_id)
    OR user_can('bank_accounts', 'create', p_employee_id)
    OR (
      user_can('bank_accounts', 'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = p_employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'submit_bank_account_set: access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  -- ── Bank exception / date cutoff check ──────────────────────────────────
  v_is_exempt := has_role('bank_exceptions') OR has_role('admin') OR has_role('hr');

  IF NOT v_is_exempt THEN
    -- Must submit by 15th of the current month
    IF EXTRACT(DAY FROM CURRENT_DATE) > 15 THEN
      RAISE EXCEPTION
        'Bank account changes must be submitted by the 15th of the month. '
        'Today is the %s — submission window has closed for this month.',
        TO_CHAR(CURRENT_DATE, 'DDth');
    END IF;

    -- effective_from must be 1st of the current month
    IF v_effective_snap <> date_trunc('month', CURRENT_DATE)::date THEN
      RAISE EXCEPTION
        'Bank account changes must take effect on the 1st of the current month (%). '
        'Submitted effective_from % is not valid.',
        TO_CHAR(date_trunc('month', CURRENT_DATE)::date, 'YYYY-MM-DD'),
        TO_CHAR(v_effective_snap, 'YYYY-MM-DD');
    END IF;
  END IF;

  -- ── Per-item validation ────────────────────────────────────────────────────
  v_primary_count := 0;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NOT (v_item ? 'country_code'
            AND v_item ? 'currency_code'
            AND v_item ? 'bank_name'
            AND v_item ? 'account_holder_name'
            AND v_item ? 'account_number') THEN
      RAISE EXCEPTION
        'submit_bank_account_set: each item must include country_code, currency_code, '
        'bank_name, account_holder_name, account_number';
    END IF;

    -- Country-specific field checks
    IF v_item->>'country_code' = 'IND' AND NULLIF(v_item->>'ifsc_code', '') IS NULL THEN
      RAISE EXCEPTION 'submit_bank_account_set: ifsc_code required for IND accounts';
    END IF;
    IF v_item->>'country_code' IN ('PAK', 'SAU') AND NULLIF(v_item->>'iban', '') IS NULL THEN
      RAISE EXCEPTION 'submit_bank_account_set: iban required for PAK/SAU accounts';
    END IF;
    IF v_item->>'country_code' = 'LKA' AND NULLIF(v_item->>'branch_code', '') IS NULL THEN
      RAISE EXCEPTION 'submit_bank_account_set: branch_code required for LKA accounts';
    END IF;

    IF COALESCE((v_item->>'is_primary')::boolean, false) THEN
      v_primary_count := v_primary_count + 1;
    END IF;

    -- Duplicate group_id check
    v_group_id := NULLIF(v_item->>'bank_account_group_id', '')::uuid;
    IF v_group_id IS NOT NULL THEN
      IF v_group_id = ANY(v_seen_groups) THEN
        RAISE EXCEPTION 'submit_bank_account_set: duplicate bank_account_group_id % in proposed set', v_group_id;
      END IF;
      v_seen_groups := array_append(v_seen_groups, v_group_id);
    END IF;
  END LOOP;

  IF v_primary_count <> 1 THEN
    RAISE EXCEPTION
      'submit_bank_account_set: exactly one item must have is_primary=true (found %)',
      v_primary_count;
  END IF;

  -- ── Compute change summary ────────────────────────────────────────────────
  SELECT name INTO v_employee_name FROM employees WHERE id = p_employee_id;

  SELECT id INTO v_current_set_id
  FROM employee_bank_account_set
  WHERE employee_id  = p_employee_id
    AND is_active    = true
    AND effective_to = '9999-12-31'::date
  LIMIT 1;

  v_current_codes := ARRAY[]::UUID[];
  IF v_current_set_id IS NOT NULL THEN
    SELECT COALESCE(array_agg(bank_account_group_id), ARRAY[]::UUID[])
      INTO v_current_codes
    FROM employee_bank_account_item WHERE set_id = v_current_set_id;
  END IF;

  v_proposed_codes := COALESCE(
    ARRAY(
      SELECT (item->>'bank_account_group_id')::uuid
      FROM jsonb_array_elements(p_items) AS item
      WHERE NULLIF(item->>'bank_account_group_id', '') IS NOT NULL
    ),
    ARRAY[]::UUID[]
  );

  v_added_count := (
    SELECT COUNT(*)::INTEGER
    FROM jsonb_array_elements(p_items) AS item
    WHERE NULLIF(item->>'bank_account_group_id', '') IS NULL
  );

  v_removed_count := (
    SELECT COUNT(*)::INTEGER
    FROM unnest(v_current_codes) AS c
    WHERE c <> ALL(v_proposed_codes)
  );

  v_change_summary := format(
    '%s added, %s removed, %s accounts in proposed set',
    v_added_count, v_removed_count, v_item_count
  );

  -- ── Resolve workflow assignment ────────────────────────────────────────────
  v_template_id := resolve_workflow_for_submission('profile_bank', v_actor);

  IF v_template_id IS NOT NULL THEN
    -- PATH B — stage to workflow_pending_changes + wf_submit
    SELECT code INTO v_template_code FROM workflow_templates WHERE id = v_template_id;

    INSERT INTO workflow_pending_changes (
      module_code, record_id, status, submitted_by, proposed_data, created_at
    ) VALUES (
      'profile_bank',
      p_employee_id,
      'pending',
      v_actor,
      jsonb_build_object(
        'employee_id',    p_employee_id,
        'effective_from', v_effective_snap,
        'items',          p_items
      ),
      NOW()
    )
    RETURNING id INTO v_workflow_pending_id;

    BEGIN
      v_instance_id := wf_submit(
        p_template_code => v_template_code,
        p_module_code   => 'profile_bank',
        p_record_id     => p_employee_id,
        p_metadata      => jsonb_build_object(
          'name',              v_employee_name,
          'employee_id',       p_employee_id,
          'submission_type',   'set_update',
          'item_count',        v_item_count,
          'added_count',       v_added_count,
          'removed_count',     v_removed_count,
          'change_summary',    v_change_summary,
          'pending_change_id', v_workflow_pending_id,
          'effective_from',    v_effective_snap
        ),
        p_comment => NULL
      );
    EXCEPTION WHEN OTHERS THEN
      DELETE FROM workflow_pending_changes WHERE id = v_workflow_pending_id;
      RAISE;
    END;

    RETURN jsonb_build_object(
      'ok',                true,
      'workflow',          true,
      'instance_id',       v_instance_id,
      'pending_change_id', v_workflow_pending_id,
      'effective_from',    v_effective_snap,
      'change_summary',    v_change_summary
    );

  ELSE
    -- PATH A — direct write (hire pipeline or no workflow assigned)
    v_set_id := fn_apply_bank_account_set_transition(
      p_employee_id    => p_employee_id,
      p_effective_from => v_effective_snap,
      p_items          => p_items,
      p_actor          => v_actor
    );

    RETURN jsonb_build_object(
      'ok',             true,
      'workflow',       false,
      'set_id',         v_set_id,
      'effective_from', v_effective_snap,
      'change_summary', v_change_summary
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB) TO authenticated;

COMMENT ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB) IS
  'Main write entry point for set-snapshot bank accounts. Enforces 15th-of-month '
  'submission cutoff and 1st-of-month effective_from (both waived for bank_exceptions/'
  'admin/hr roles). Validates exactly one is_primary item. Dual-path: workflow (PATH B) '
  'or direct apply (PATH A). Returns { ok, workflow, instance_id|set_id, '
  'effective_from, change_summary }. Mig 329.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_fn_count INTEGER;
BEGIN
  SELECT COUNT(*)
    INTO v_fn_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname IN (
      'get_employee_bank_account_set',
      'get_employee_bank_account_set_history',
      'fn_apply_bank_account_set_transition',
      'submit_bank_account_set'
    );

  IF v_fn_count < 4 THEN
    RAISE EXCEPTION 'mig 329: expected 4 bank account set RPCs, found %', v_fn_count;
  END IF;

  RAISE NOTICE 'mig 329: 4 bank account set RPCs created';
END
$$;
