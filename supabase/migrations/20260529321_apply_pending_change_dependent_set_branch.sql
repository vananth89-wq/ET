-- =============================================================================
-- Migration 321: wire profile_dependents apply path to dependent-set transition
--
-- DESIGN REFERENCE
-- ────────────────
-- docs/set-snapshot-design.md §4.3 (Trigger update).
--
-- CONTEXT
-- ───────
-- After mig 319, apply_profile_pending_change leaves the profile_dependents
-- branch as a no-op:
--     ELSIF v_module = 'profile_dependents' THEN
--       NULL;  -- "Handled by the dependents module's own apply branch"
-- That branch is now wired here, routing approved set-update submissions to
-- fn_apply_dependent_set_transition (mig 302) so the proposed_data
-- materialises as a new employee_dependent_set + items.
--
-- WHAT CHANGES
-- ────────────
-- Only the profile_dependents branch is modified. Every other branch
-- (profile_personal → upsert_personal_info, profile_contact, profile_address,
--  profile_passport, profile_identification, profile_emergency_contact,
--  profile_bank no-op) is copied verbatim from mig 319.
--
-- ROUTING LOGIC FOR profile_dependents
-- ────────────────────────────────────
--   • proposed_data.items + proposed_data.effective_from must be present
--     (set in submit_dependent_set, mig 302).
--   • If items is missing or not an array → log a warning (this would be a
--     pre-set-snapshot row sitting in workflow_pending_changes; current
--     behaviour was no-op, we preserve that for safety).
--   • Otherwise: call fn_apply_dependent_set_transition(
--       employee_id, effective_from, items, approved_by
--     ). Approved_by = the user whose update flipped status to 'approved',
--     read from the same submitted_by lookup the personal branch uses.
--
-- ROLLBACK
-- ────────
-- Re-apply mig 319 to restore the profile_dependents branch to no-op.
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

    -- Extract effective_from from proposed_data; default to today if absent
    -- (backward compatibility: submissions before mig 305 won't have this key)
    v_eff_from := COALESCE(
      NULLIF(v_data->>'effective_from', '')::date,
      CURRENT_DATE
    );

    -- Call the RPC — handles close-then-insert and employees sync
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
        v_data->>'name',
        v_data->>'relationship',
        v_data->>'phone',
        v_data->>'email'
      );
    END IF;

  -- ── profile_bank → no-op (handled by the bank module's own apply path) ──
  ELSIF v_module = 'profile_bank' THEN
    NULL;

  -- ── profile_dependents → fn_apply_dependent_set_transition ──────────────
  -- MIG 321: replaces the no-op left in mig 319. proposed_data must carry the
  -- shape produced by submit_dependent_set (mig 302):
  --   { employee_id, effective_from, items: [...] }
  -- If the shape is missing (legacy pre-set-snapshot rows somehow flipped to
  -- approved post-cutover), we warn and skip rather than crash the trigger.
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
      -- Resolve employee_id from proposed_data if present, otherwise fall back
      -- to the submitter-derived v_emp_id. This handles admin-initiated
      -- submissions where the actor and the target employee differ.
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

  -- Note: wf_sync_module_status() already updated workflow_pending_changes.status
  -- to 'approved' and set resolved_at — that UPDATE is what fired this trigger.
  -- No redundant UPDATE needed here.

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
  'Routes proposed_data to the correct satellite table or set-snapshot RPC based '
  'on module_code. '
  'Mig 309/319: profile_personal calls upsert_personal_info(). '
  'Mig 321: profile_dependents calls fn_apply_dependent_set_transition() with '
  'proposed_data.items + proposed_data.effective_from (shape from submit_dependent_set, '
  'mig 302). Pre-set-snapshot rows are warned and skipped.';

-- Re-attach the trigger (defensive — already attached in mig 319, but a
-- re-CREATE OR REPLACE FUNCTION does not implicitly re-attach if the trigger
-- referenced a different function signature; here the signature is unchanged
-- so the existing trigger keeps pointing at this function. We re-attach for
-- belt-and-braces.).
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
  v_fn_exists      BOOLEAN;
  v_trigger_exists BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname = 'apply_profile_pending_change'
  ) INTO v_fn_exists;

  SELECT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_apply_profile_pending_change'
      AND tgrelid = 'workflow_pending_changes'::regclass
      AND NOT tgisinternal
  ) INTO v_trigger_exists;

  IF NOT v_fn_exists THEN
    RAISE EXCEPTION 'mig 321: apply_profile_pending_change function missing after apply';
  END IF;
  IF NOT v_trigger_exists THEN
    RAISE EXCEPTION 'mig 321: trg_apply_profile_pending_change trigger missing after apply';
  END IF;

  RAISE NOTICE 'mig 321: apply_profile_pending_change rewired (profile_dependents → fn_apply_dependent_set_transition)';
END
$$;
