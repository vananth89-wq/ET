-- =============================================================================
-- Migration 250: Hire-specific notification templates + deep-link
--
-- PROBLEM
-- ───────
-- The workflow engine uses generic template codes (wf.task_assigned, wf.completed,
-- wf.rejected, etc.) for all modules. This means the employee_hire module sends
-- approvers bland generic messages with no mention of the candidate's name and
-- sends notifications to a dead-end link (/workflow/my-requests) rather than
-- the hire review screen.
--
-- FIX
-- ───
-- 1. Update wf_queue_notification() to:
--      a. Merge workflow_instances.metadata into the notification payload so
--         {{name}} and {{employee_id}} placeholders are available in templates.
--      b. Auto-resolve a module-specific template code before falling back to
--         the generic one. Convention: if module_code maps to prefix P, and the
--         generic code is 'wf.<event>', then 'P.<event>' is tried first.
--         Mapping: employee_hire → hire  (extend CASE as modules onboard).
--
-- 2. Update trg_wf_deliver_notification() + wf_deliver_pending_notifications()
--    to add the employee_hire deep-link:
--         employee_hire → /workflow/review/<record_id>
--
-- 3. Seed hire-specific notification templates:
--      hire.task_assigned             — approver: new hire review task
--      hire.completed                 — initiator: hire fully approved
--      hire.rejected                  — initiator: hire rejected
--      hire.clarification_requested   — initiator: approver asked for clarification
--      hire.clarification_submitted   — approver: initiator responded
--      hire.withdrawn                 — approver: hire request withdrawn
--
-- BACKWARD COMPATIBILITY
-- ──────────────────────
-- The auto-resolution is transparent. If a hire-specific template is missing
-- the engine silently falls back to the generic wf.* code. Non-hire modules
-- are completely unaffected.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — Update wf_queue_notification
-- ════════════════════════════════════════════════════════════════════════════
--
-- Changes vs original (mig 030):
--   • Loads instance metadata (name, employee_id, etc.) and merges it into the
--     caller-supplied payload before inserting into the queue.
--   • Attempts to resolve a module-specific template code when the generic code
--     follows the 'wf.<event>' convention. Falls back to generic if the
--     module-specific template does not exist.

CREATE OR REPLACE FUNCTION wf_queue_notification(
  p_instance_id    uuid,
  p_template_code  text,
  p_target_profile uuid,
  p_payload        jsonb DEFAULT '{}'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance       RECORD;
  v_module_prefix  text;
  v_event_suffix   text;
  v_specific_code  text;
  v_final_code     text;
  v_merged_payload jsonb;
BEGIN
  -- ── Load instance (module_code + metadata for payload enrichment) ────────────
  SELECT module_code, metadata
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  -- ── Merge instance metadata into the caller's payload ───────────────────────
  -- Instance metadata (e.g. {"name":"John Doe","employee_id":"EMP001"}) is merged
  -- first so that caller-supplied keys always win on collision.
  v_merged_payload := COALESCE(v_instance.metadata, '{}'::jsonb) || p_payload;

  -- ── Auto-resolve module-specific template code ───────────────────────────────
  -- Only attempted when the generic code follows the 'wf.<event>' convention.
  -- Extend the CASE block as new modules adopt module-specific templates.
  v_module_prefix := CASE v_instance.module_code
    WHEN 'employee_hire' THEN 'hire'
    -- WHEN 'leave_requests' THEN 'leave'   -- add when leave module is onboarded
    ELSE NULL
  END;

  v_final_code := p_template_code;   -- default: use the generic code as-is

  IF v_module_prefix IS NOT NULL AND p_template_code LIKE 'wf.%' THEN
    -- Strip the 'wf.' prefix (3 chars) to get the event suffix
    v_event_suffix  := substring(p_template_code FROM 4);
    v_specific_code := v_module_prefix || '.' || v_event_suffix;

    IF EXISTS (
      SELECT 1 FROM workflow_notification_templates WHERE code = v_specific_code
    ) THEN
      v_final_code := v_specific_code;
    END IF;
  END IF;

  -- ── Guard: silently skip if the resolved template doesn't exist ──────────────
  IF NOT EXISTS (
    SELECT 1 FROM workflow_notification_templates WHERE code = v_final_code
  ) THEN
    RAISE NOTICE 'wf_queue_notification: template % not found — skipping', v_final_code;
    RETURN;
  END IF;

  -- ── Enqueue ──────────────────────────────────────────────────────────────────
  INSERT INTO workflow_notification_queue
    (instance_id, template_code, target_profile, payload)
  VALUES
    (p_instance_id, v_final_code, p_target_profile, v_merged_payload);
END;
$$;

COMMENT ON FUNCTION wf_queue_notification(uuid, text, uuid, jsonb) IS
  'Writes a row to workflow_notification_queue. '
  'Before queuing, merges workflow_instances.metadata into the payload so '
  'module-level context ({{name}}, {{employee_id}}) is available in templates. '
  'Transparently upgrades generic wf.<event> codes to module-specific '
  '<prefix>.<event> codes when they exist (e.g. hire.task_assigned). '
  'Falls back to the generic code if the specific template is missing. '
  'Mig 250.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — Update deep-link resolution in delivery functions
-- ════════════════════════════════════════════════════════════════════════════
--
-- trg_wf_deliver_notification() and wf_deliver_pending_notifications() both
-- build a deep-link by CASE on module_code. Add employee_hire here so that
-- approvers land on the hire review screen, not the generic my-requests page.

CREATE OR REPLACE FUNCTION trg_wf_deliver_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tmpl   RECORD;
  v_title  text;
  v_body   text;
  v_key    text;
  v_val    text;
  v_link   text;
BEGIN
  -- Look up template
  SELECT title_tmpl, body_tmpl
  INTO   v_tmpl
  FROM   workflow_notification_templates
  WHERE  code = NEW.template_code;

  IF NOT FOUND THEN
    UPDATE workflow_notification_queue
    SET    status        = 'failed',
           error_message = 'notification template not found: ' || NEW.template_code,
           processed_at  = now()
    WHERE  id = NEW.id;
    RETURN NEW;
  END IF;

  v_title := v_tmpl.title_tmpl;
  v_body  := v_tmpl.body_tmpl;

  -- Replace every {{key}} placeholder with the matching payload value.
  -- Unknown placeholders are left as-is (no error).
  FOR v_key, v_val IN
    SELECT key, value FROM jsonb_each_text(NEW.payload)
  LOOP
    v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
    v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
  END LOOP;

  -- Build a sensible deep-link from the instance's module_code + record_id.
  -- Extend this CASE as new modules are onboarded.
  SELECT CASE wi.module_code
    WHEN 'expense_reports' THEN '/expense/report/'     || wi.record_id::text
    WHEN 'employee_hire'   THEN '/workflow/review/'    || wi.record_id::text
    ELSE '/workflow/my-requests'
  END
  INTO   v_link
  FROM   workflow_instances wi
  WHERE  wi.id = NEW.instance_id;

  -- Deliver to the in-app notifications table
  INSERT INTO notifications (profile_id, title, body, link)
  VALUES (NEW.target_profile, v_title, v_body, COALESCE(v_link, '/workflow/my-requests'));

  -- Mark queue row as sent
  UPDATE workflow_notification_queue
  SET    status       = 'sent',
         processed_at = now()
  WHERE  id = NEW.id;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- Never let a notification failure break the calling workflow transaction.
  UPDATE workflow_notification_queue
  SET    status        = 'failed',
         error_message = SQLERRM,
         processed_at  = now()
  WHERE  id = NEW.id;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION trg_wf_deliver_notification() IS
  'Renders a workflow_notification_queue row using its template and payload, '
  'then inserts into the notifications table. Called by trigger on INSERT. '
  'Deep-links: expense_reports → /expense/report/<id>; '
  'employee_hire → /workflow/review/<id>. Mig 250.';


-- ── wf_deliver_pending_notifications — same deep-link update ─────────────────

CREATE OR REPLACE FUNCTION wf_deliver_pending_notifications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row    RECORD;
  v_tmpl   RECORD;
  v_title  text;
  v_body   text;
  v_key    text;
  v_val    text;
  v_link   text;
  v_count  integer := 0;
BEGIN
  FOR v_row IN
    SELECT * FROM workflow_notification_queue
    WHERE  status = 'pending'
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      SELECT title_tmpl, body_tmpl
      INTO   v_tmpl
      FROM   workflow_notification_templates
      WHERE  code = v_row.template_code;

      IF NOT FOUND THEN
        UPDATE workflow_notification_queue
        SET    status = 'failed',
               error_message = 'template not found: ' || v_row.template_code,
               processed_at  = now()
        WHERE  id = v_row.id;
        CONTINUE;
      END IF;

      v_title := v_tmpl.title_tmpl;
      v_body  := v_tmpl.body_tmpl;

      FOR v_key, v_val IN
        SELECT key, value FROM jsonb_each_text(v_row.payload)
      LOOP
        v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
        v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
      END LOOP;

      SELECT CASE wi.module_code
        WHEN 'expense_reports' THEN '/expense/report/'  || wi.record_id::text
        WHEN 'employee_hire'   THEN '/workflow/review/' || wi.record_id::text
        ELSE '/workflow/my-requests'
      END
      INTO   v_link
      FROM   workflow_instances wi
      WHERE  wi.id = v_row.instance_id;

      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (v_row.target_profile, v_title, v_body,
              COALESCE(v_link, '/workflow/my-requests'));

      UPDATE workflow_notification_queue
      SET    status = 'sent', processed_at = now()
      WHERE  id = v_row.id;

      v_count := v_count + 1;

    EXCEPTION WHEN OTHERS THEN
      UPDATE workflow_notification_queue
      SET    status        = 'failed',
             error_message = SQLERRM,
             processed_at  = now()
      WHERE  id = v_row.id;
    END;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION wf_deliver_pending_notifications() IS
  'Processes all pending rows in workflow_notification_queue. '
  'Returns the number of notifications successfully delivered. '
  'Safe to call repeatedly — only touches status=''pending'' rows. '
  'Deep-links updated in mig 250.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — Seed hire-specific notification templates
-- ════════════════════════════════════════════════════════════════════════════
--
-- These templates override the generic wf.* codes for the employee_hire module.
-- Placeholders available in every hire notification (merged from instance metadata):
--   {{name}}        — candidate's full name  (e.g. "John Doe")
--   {{employee_id}} — human-readable ID      (e.g. "EMP001")
--
-- Additional per-event placeholders (supplied by the engine):
--   hire.task_assigned           : {{step_name}}
--   hire.clarification_requested : {{message}}
--   hire.clarification_submitted : {{response}}

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES

  -- ── Approver: new task assigned ────────────────────────────────────────────
  ('hire.task_assigned',
   'New hire review: {{name}}',
   'You have been assigned to review a new hire request for {{name}} ({{employee_id}}). '
   'Step: {{step_name}}. Please review all sections and approve, reject, or request clarification.'),

  -- ── Initiator: all approvers approved — hire complete ─────────────────────
  ('hire.completed',
   'New hire approved: {{name}}',
   'The new hire request for {{name}} ({{employee_id}}) has been approved by all required '
   'approvers and the employee record is now active.'),

  -- ── Initiator: hire rejected at any step ──────────────────────────────────
  ('hire.rejected',
   'New hire rejected: {{name}}',
   'The new hire request for {{name}} ({{employee_id}}) has been rejected. '
   'Reason: {{reason}}. Please review the feedback and resubmit if appropriate.'),

  -- ── Initiator: approver sent back for clarification ───────────────────────
  ('hire.clarification_requested',
   'Clarification needed for hire of {{name}}',
   'An approver has requested clarification before proceeding with the new hire request '
   'for {{name}} ({{employee_id}}). Message: {{message}}. '
   'Please update the request and resubmit.'),

  -- ── Approver: initiator has resubmitted after clarification ───────────────
  ('hire.clarification_submitted',
   'Hire request for {{name}} back in your inbox',
   'The initiator has responded to your clarification request regarding {{name}} '
   '({{employee_id}}) and the request is back in your inbox. Response: {{response}}'),

  -- ── Approver: initiator withdrew the hire request ─────────────────────────
  ('hire.withdrawn',
   'New hire request for {{name}} withdrawn',
   'The new hire request for {{name}} ({{employee_id}}) has been withdrawn by the initiator. '
   'No further action is required.')

ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      updated_at = now();


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- Check all 6 hire templates exist
  IF (
    SELECT COUNT(*) FROM workflow_notification_templates
    WHERE  code IN (
      'hire.task_assigned',
      'hire.completed',
      'hire.rejected',
      'hire.clarification_requested',
      'hire.clarification_submitted',
      'hire.withdrawn'
    )
  ) < 6 THEN
    RAISE EXCEPTION 'ABORT: not all hire notification templates seeded correctly.';
  END IF;

  -- Check wf_queue_notification exists
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE  proname = 'wf_queue_notification'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_queue_notification function not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 250 verified: hire templates seeded, functions updated.';
END;
$$;

-- Confirm hire templates seeded
SELECT code, title_tmpl
FROM   workflow_notification_templates
WHERE  code LIKE 'hire.%'
ORDER  BY code;

-- =============================================================================
-- END OF MIGRATION 250
--
-- After this migration:
--   • Hire workflow notifications include the candidate's name + employee_id.
--   • Notification links for employee_hire land on /workflow/review/<record_id>.
--   • No frontend changes required — the engine queues notifications and the
--     delivery trigger renders them automatically.
--   • To add module-specific templates for another module, add a CASE branch
--     in wf_queue_notification() and seed '<prefix>.*' templates.
-- =============================================================================
