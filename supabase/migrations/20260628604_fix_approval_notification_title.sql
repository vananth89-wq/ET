-- =============================================================================
-- Fix approval task notification title
--
-- Previously: "New approval task: HR Manager"  (shows step/role name)
-- Now:        "New approval task: Termination" (shows module/process name)
--
-- The payload already carries module_code. We add a {{module_label}} token
-- by enriching the payload inside _wf_notification_link (already reads the
-- instance) — actually cleaner to resolve it in the delivery function directly.
--
-- Approach:
--   1. Update wf.task_assigned title_tmpl to use {{module_label}}
--   2. In trg_wf_deliver_notification / wf_deliver_pending_notifications,
--      after placeholder substitution, resolve {{module_label}} from
--      module_code via a deterministic CASE map.
--
-- Module code → human label map (extend as new modules are added):
--   termination      → Termination
--   employee_hire    → New Hire
--   personal_info    → Personal Info
--   address          → Address Change
--   passport         → Passport
--   identification   → Identification
--   emergency_contact→ Emergency Contact
--   bank_accounts    → Bank Account
--   dependents       → Dependents
--   job_relationships→ Job Relationships
--   education        → Education
--   expense_reports  → Expense Report
-- =============================================================================

-- ── 1. Update the task_assigned title template ────────────────────────────────

UPDATE workflow_notification_templates
SET    title_tmpl  = 'New approval task: {{module_label}}',
       updated_at  = now()
WHERE  code = 'wf.task_assigned';

-- ── 2. Helper: module_code → human label ─────────────────────────────────────

CREATE OR REPLACE FUNCTION _wf_module_label(p_module_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_module_code
    WHEN 'termination'        THEN 'Termination'
    WHEN 'employee_hire'      THEN 'New Hire'
    WHEN 'personal_info'      THEN 'Personal Info'
    WHEN 'address'            THEN 'Address Change'
    WHEN 'passport'           THEN 'Passport'
    WHEN 'identification'     THEN 'Identification'
    WHEN 'emergency_contact'  THEN 'Emergency Contact'
    WHEN 'bank_accounts'      THEN 'Bank Account'
    WHEN 'dependents'         THEN 'Dependents'
    WHEN 'job_relationships'  THEN 'Job Relationships'
    WHEN 'education'          THEN 'Education'
    WHEN 'expense_reports'    THEN 'Expense Report'
    ELSE initcap(replace(p_module_code, '_', ' '))  -- safe fallback
  END;
$$;

COMMENT ON FUNCTION _wf_module_label(text) IS
  'Maps workflow module_code to a human-readable label for notification titles.';


-- ── 3. Rewrite delivery function with module_label substitution ───────────────

CREATE OR REPLACE FUNCTION trg_wf_deliver_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tmpl       RECORD;
  v_title      text;
  v_body       text;
  v_key        text;
  v_val        text;
  v_link       text;
  v_module     text;
BEGIN
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

  -- Replace {{key}} placeholders from payload
  FOR v_key, v_val IN
    SELECT key, value FROM jsonb_each_text(NEW.payload)
  LOOP
    v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
    v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
  END LOOP;

  -- Resolve {{module_label}} from module_code on the instance
  SELECT wi.module_code INTO v_module
  FROM   workflow_instances wi
  WHERE  wi.id = NEW.instance_id;

  v_title := replace(v_title, '{{module_label}}', _wf_module_label(COALESCE(v_module, '')));
  v_body  := replace(v_body,  '{{module_label}}', _wf_module_label(COALESCE(v_module, '')));

  -- Resolve deep-link (approver → inbox, submitter → my-requests)
  v_link := _wf_notification_link(NEW.instance_id, NEW.target_profile);

  INSERT INTO notifications (profile_id, title, body, link)
  VALUES (NEW.target_profile, v_title, v_body, v_link);

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


-- ── 4. Same fix in the manual replay helper ───────────────────────────────────

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
  v_module text;
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

      SELECT wi.module_code INTO v_module
      FROM   workflow_instances wi
      WHERE  wi.id = v_row.instance_id;

      v_title := replace(v_title, '{{module_label}}', _wf_module_label(COALESCE(v_module, '')));
      v_body  := replace(v_body,  '{{module_label}}', _wf_module_label(COALESCE(v_module, '')));

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
