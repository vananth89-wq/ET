-- =============================================================================
-- Fix Notification Deep Links
--
-- Previously ALL non-expense notifications linked to /workflow/my-requests
-- (the submitter's view). Approvers clicking "New approval task" were sent
-- to the wrong page.
--
-- Fix: compare target_profile against wi.submitted_by:
--   • target = submitter  → /workflow/my-requests
--   • target = approver   → /workflow/inbox
--   • expense_reports     → /expense/report/:id  (unchanged)
--
-- Rewrites both trg_wf_deliver_notification() and
-- wf_deliver_pending_notifications() with the corrected CASE logic.
-- =============================================================================

-- ── Helper: resolve deep link ─────────────────────────────────────────────────
--
-- Given a queue row's instance_id and target_profile, return the correct link.

CREATE OR REPLACE FUNCTION _wf_notification_link(
  p_instance_id   uuid,
  p_target_profile uuid
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_module    text;
  v_record_id uuid;
  v_submitted_by uuid;
BEGIN
  SELECT wi.module_code, wi.record_id, wi.submitted_by
  INTO   v_module, v_record_id, v_submitted_by
  FROM   workflow_instances wi
  WHERE  wi.id = p_instance_id;

  IF NOT FOUND THEN
    RETURN '/workflow/my-requests';
  END IF;

  -- Expense reports always get a direct deep-link to the report
  IF v_module = 'expense_reports' THEN
    RETURN '/expense/report/' || v_record_id::text;
  END IF;

  -- Approvers → Workflow Inbox; Submitters → My Requests
  IF p_target_profile IS DISTINCT FROM v_submitted_by THEN
    RETURN '/workflow/inbox';
  ELSE
    RETURN '/workflow/my-requests';
  END IF;
END;
$$;

COMMENT ON FUNCTION _wf_notification_link(uuid, uuid) IS
  'Returns the correct deep-link for a workflow notification based on whether '
  'the recipient is the submitter (my-requests) or an approver (inbox).';


-- ── 1. Rewrite trigger delivery function ─────────────────────────────────────

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
  FOR v_key, v_val IN
    SELECT key, value FROM jsonb_each_text(NEW.payload)
  LOOP
    v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
    v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
  END LOOP;

  -- Resolve correct deep-link (approver → inbox, submitter → my-requests)
  v_link := _wf_notification_link(NEW.instance_id, NEW.target_profile);

  -- Deliver to the in-app notifications table
  INSERT INTO notifications (profile_id, title, body, link)
  VALUES (NEW.target_profile, v_title, v_body, v_link);

  -- Mark queue row as sent
  UPDATE workflow_notification_queue
  SET    status       = 'sent',
         processed_at = now()
  WHERE  id = NEW.id;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
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
  'then inserts into the notifications table. Routes approvers to /workflow/inbox '
  'and submitters to /workflow/my-requests. Called by trigger on INSERT.';


-- ── 2. Rewrite manual replay helper ──────────────────────────────────────────

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

      v_link := _wf_notification_link(v_row.instance_id, v_row.target_profile);

      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (v_row.target_profile, v_title, v_body, v_link);

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
  'Safe to call repeatedly — only touches status=''pending'' rows.';
