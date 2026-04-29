-- =============================================================================
-- Workflow Notification Delivery
--
-- Wires the workflow_notification_queue to the existing notifications table
-- via an AFTER INSERT trigger. As soon as wf_queue_notification() writes a
-- row, the trigger fires, renders the template, and delivers the notification
-- immediately — no background job or pg_cron needed.
--
-- Template rendering: {{key}} placeholders in title_tmpl / body_tmpl are
-- replaced with matching keys from the queue row's payload jsonb.
--
-- Changes:
--   1. trg_wf_deliver_notification() — render + deliver function
--   2. after_wf_notification_queue_insert — trigger on workflow_notification_queue
--   3. wf_deliver_pending_notifications() — manual replay for any 'pending'
--      rows that predate the trigger (e.g. from a previous run attempt)
-- =============================================================================


-- ── 1. Delivery function ──────────────────────────────────────────────────────
--
-- Called for every new row in workflow_notification_queue.
-- Renders the template, inserts into notifications, marks queue row 'sent'.
-- On any error, marks the queue row 'failed' with the error message so it
-- can be inspected and replayed without losing the original data.

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
    WHEN 'expense_reports' THEN '/expense/report/' || wi.record_id::text
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
  'then inserts into the notifications table. Called by trigger on INSERT.';


-- ── 2. Attach trigger ─────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS after_wf_notification_queue_insert
  ON workflow_notification_queue;

CREATE TRIGGER after_wf_notification_queue_insert
AFTER INSERT ON workflow_notification_queue
FOR EACH ROW
EXECUTE FUNCTION trg_wf_deliver_notification();


-- ── 3. Manual replay helper ───────────────────────────────────────────────────
--
-- Processes any 'pending' rows that already exist (e.g. inserted before this
-- trigger was created, or rows that failed and were manually reset to 'pending').
-- Safe to call multiple times — only touches rows with status = 'pending'.

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
        WHEN 'expense_reports' THEN '/expense/report/' || wi.record_id::text
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
  'Safe to call repeatedly — only touches status=''pending'' rows.';


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT trigger_name, event_object_table, action_timing, event_manipulation
FROM   information_schema.triggers
WHERE  trigger_name = 'after_wf_notification_queue_insert';

SELECT proname FROM pg_proc
WHERE  proname IN ('trg_wf_deliver_notification', 'wf_deliver_pending_notifications');
