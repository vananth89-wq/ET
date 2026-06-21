-- =============================================================================
-- Migration 251: Gap D — Hire initiator notifications (admin actions + direct-activate)
--
-- PROBLEM
-- ───────
-- After mig 250, most hire notification paths are covered. Two gaps remain:
--
-- Gap D-1: Admin rejection / admin return-to-submitter
--   wf_admin_reject  calls wf_queue_notification('wf.admin_rejected', ...)
--   wf_admin_decline calls wf_queue_notification('wf.admin_declined', ...)
--
--   Mig 250's auto-upgrade tries 'hire.admin_rejected' / 'hire.admin_declined'
--   first — but those templates did not exist — so it falls back to the generic
--   versions, which have no {{name}} or {{employee_id}} placeholders. The HR
--   analyst (initiator) sees "Your request has been rejected" with no indication
--   of which hire record was affected.
--
-- Gap D-2: Direct-activate path
--   An admin can call wf_activate_employee() directly (bypassing wf_approve()).
--   In that case wf_advance_instance never runs, so 'hire.completed' is never
--   queued. The initiator gets no "hire is now active" notification.
--
--   Detection: wf_advance_instance sets instance.status = 'approved' and sends
--   hire.completed BEFORE calling wf_sync_module_status → wf_activate_employee.
--   So when wf_activate_employee runs via the engine path, an approved instance
--   already exists. If no approved instance exists → direct-activate path.
--
-- FIX
-- ───
-- Part 1: Seed hire.admin_rejected + hire.admin_declined templates.
--         Mig 250's auto-upgrade will now find them and use them automatically.
--
-- Part 2: Update wf_activate_employee() to check for an approved workflow
--         instance. If none exists (direct-activate path), insert a notification
--         directly to the activating user (auth.uid()). Engine path is unchanged
--         — the hire.completed notification was already delivered before this
--         function runs.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — Hire-specific admin-action templates
-- ════════════════════════════════════════════════════════════════════════════
--
-- {{name}} and {{employee_id}} are available because mig 250 merges
-- workflow_instances.metadata into every notification payload before delivery.

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES

  -- ── Initiator: admin permanently rejected the hire ────────────────────────
  ('hire.admin_rejected',
   'New hire rejected by admin: {{name}}',
   'An administrator has permanently rejected the new hire request for {{name}} '
   '({{employee_id}}). Reason: {{reason}}. '
   'The employee record has been unlocked and reset so you can correct and '
   'resubmit, or withdraw it.'),

  -- ── Initiator: admin returned the hire for correction ─────────────────────
  ('hire.admin_declined',
   'New hire returned for review: {{name}}',
   'An administrator has returned the new hire request for {{name}} '
   '({{employee_id}}) to you for correction. Reason: {{reason}}. '
   'Please update the record and resubmit when ready.')

ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      updated_at = now();


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — Update wf_activate_employee: notify on direct-activate path
-- ════════════════════════════════════════════════════════════════════════════
--
-- The only change vs mig 218 is the block at the very end of the function:
-- after activation succeeds, check whether the engine already sent hire.completed.
-- If no approved instance exists, the admin activated directly — write a
-- notification to their own profile so they have an audit trail in the bell.
--
-- NOTE: wf_queue_notification cannot be used here because it requires an
-- instance_id. We insert into notifications directly instead.

CREATE OR REPLACE FUNCTION wf_activate_employee(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status        text;
  v_email         text;
  v_name          text;
  v_employee_id   text;   -- human-readable EMP001 etc.
  v_next_attempt  int;
  v_has_instance  boolean;
BEGIN
  -- ── Fetch employee ────────────────────────────────────────────────────────
  SELECT status::text, business_email, name, employee_id
  INTO   v_status, v_email, v_name, v_employee_id
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_activate_employee: employee % not found.', p_employee_id;
  END IF;

  -- ── Step 1: Activate the employee record ──────────────────────────────────
  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 2: Record invite attempt number ──────────────────────────────────
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  -- ── Step 3: Stamp invite_sent_at ─────────────────────────────────────────
  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 4 (NEW): Notify on direct-activate path ──────────────────────────
  --
  -- Engine path:  wf_advance_instance sends hire.completed to submitted_by BEFORE
  --               calling wf_sync_module_status → wf_activate_employee. By the
  --               time we reach here, an approved workflow instance already exists.
  --               → skip (engine already notified the initiator).
  --
  -- Direct path:  Admin called wf_activate_employee without going through the
  --               workflow engine. No workflow instance exists (or none is
  --               'approved' yet). → notify auth.uid() so there is an audit
  --               trail in the notification bell.
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status      = 'approved'
  ) INTO v_has_instance;

  IF NOT v_has_instance THEN
    -- Direct-activate: insert a notification directly since there is no
    -- instance_id to pass to wf_queue_notification.
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      auth.uid(),
      'Employee activated: ' || v_name,
      v_name || ' (' || COALESCE(v_employee_id, '—') || ') has been '
        || 'directly activated. The invite record has been created.',
      '/employees'
    );
  END IF;

  -- NOTE: Auth OTP (signInWithOtp) and link_profile_to_employee must be
  -- called from the frontend after this RPC returns, because they require
  -- the Supabase client SDK / service-role key.
END;
$$;

COMMENT ON FUNCTION wf_activate_employee(uuid) IS
  'Activate a hire-workflow-approved employee: sets status=Active, locked=false, '
  'records invite attempt. '
  'Mig 251: if called outside the workflow engine (no approved instance found), '
  'inserts a direct notification to auth.uid() so there is an audit trail. '
  'Engine path: hire.completed was already delivered by wf_advance_instance — '
  'no duplicate notification. '
  'Frontend must call signInWithOtp + link_profile_to_employee after this returns.';

REVOKE ALL   ON FUNCTION wf_activate_employee(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_activate_employee(uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- Both hire admin templates present
  IF (
    SELECT COUNT(*) FROM workflow_notification_templates
    WHERE  code IN ('hire.admin_rejected', 'hire.admin_declined')
  ) < 2 THEN
    RAISE EXCEPTION 'ABORT: hire admin notification templates not seeded correctly.';
  END IF;

  -- wf_activate_employee still present
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'wf_activate_employee'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_activate_employee not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 251 verified: hire admin templates seeded, wf_activate_employee updated.';
END;
$$;

-- Show all hire.* templates now seeded (should be 8 total after mig 250 + 251)
SELECT code, title_tmpl
FROM   workflow_notification_templates
WHERE  code LIKE 'hire.%'
ORDER  BY code;

-- =============================================================================
-- END OF MIGRATION 251
--
-- After this migration:
--   • Admin rejection of a hire sends 'hire.admin_rejected' — includes {{name}}
--     and {{employee_id}} in title + body so the initiator knows which record.
--   • Admin return-to-submitter sends 'hire.admin_declined' — same context.
--   • wf_activate_employee detects the direct-activate path (no approved workflow
--     instance) and writes a notification to auth.uid() so there is a bell-icon
--     trail. Engine-path activations are unaffected — engine already sent
--     hire.completed to the initiator before reaching wf_activate_employee.
--
-- Remaining notification gap:
--   Direct-activate with a DIFFERENT initiator (Gap E: created_by column).
--   When hire_employee.created_by is added, update the direct-activate block to
--   notify created_by instead of auth.uid().
-- =============================================================================
