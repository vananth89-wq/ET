-- =============================================================================
-- Migration 363 — Job Relationships: Notification Templates + Queuer
--
-- 1. Seed two workflow_notification_templates:
--      job_relationship.assigned  — fired to a NEWLY assigned matrix manager
--      job_relationship.removed   — fired to a REMOVED matrix manager
--
-- 2. fn_queue_job_relationship_notifications(p_employee_id, p_new_set_id,
--      p_old_set_id, p_actor)
--    Computes the diff between two sets (or seed vs. empty) and queues
--    per-item notifications via INSERT INTO notifications.
--    Called by upsert_job_relationship_set AFTER a successful PATH A write
--    (direct writes by HR/admin). Skipped for fanout deactivations (those
--    clear assignments silently per locked decision).
--
-- Design spec: docs/job-relationships-design.md §9
-- =============================================================================


-- =============================================================================
-- 1. Notification templates
-- =============================================================================

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES

  -- ── Newly assigned matrix manager ─────────────────────────────────────────
  ('job_relationship.assigned',
   'You have been assigned as {{relationship_label}} for {{employee_name}}',
   'You have been assigned as the {{relationship_label}} for {{employee_name}} '
   '({{employee_code}}), effective {{effective_from}}. '
   'You may now appear as a matrix approver in workflows for this employee.'),

  -- ── Removed matrix manager ────────────────────────────────────────────────
  ('job_relationship.removed',
   'Your {{relationship_label}} assignment for {{employee_name}} has been removed',
   'You are no longer the {{relationship_label}} for {{employee_name}} '
   '({{employee_code}}), effective {{effective_from}}. '
   'This was changed by {{actor_name}}.')

ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      updated_at = now();


-- =============================================================================
-- 2. fn_queue_job_relationship_notifications
--    Diffs old set vs new set and sends assigned / removed per changed code.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_queue_job_relationship_notifications(
  p_employee_id  uuid,    -- the employee whose JR set changed
  p_new_set_id   uuid,    -- newly inserted set
  p_old_set_id   uuid,    -- the set that was closed (NULL = first-ever set)
  p_actor        uuid     -- profile_id of the person who made the change
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee        RECORD;
  v_actor_name      text;
  v_picklist_id     uuid;
  v_item            RECORD;
  v_old_mgr_id      uuid;
  v_new_mgr_id      uuid;
  v_label           text;
  v_effective_from  date;
  v_mgr_profile_id  uuid;
  v_title           text;
  v_body            text;
  v_tmpl_assigned   workflow_notification_templates%ROWTYPE;
  v_tmpl_removed    workflow_notification_templates%ROWTYPE;
BEGIN
  -- Load employee info
  SELECT name, employee_id AS employee_code
  INTO   v_employee
  FROM   employees WHERE id = p_employee_id;

  IF NOT FOUND THEN RETURN; END IF;

  -- Load actor name (via linked employee record)
  SELECT COALESCE(e.name, 'System')
  INTO   v_actor_name
  FROM   profiles p
  LEFT JOIN employees e ON e.id = p.employee_id
  WHERE  p.id = p_actor;

  IF NOT FOUND THEN v_actor_name := 'System'; END IF;

  -- Picklist id for label lookup
  SELECT id INTO v_picklist_id FROM picklists WHERE picklist_id = 'JOB_RELATIONSHIP_TYPE';

  -- New set's effective_from
  SELECT effective_from INTO v_effective_from
  FROM   employee_job_relationship_set WHERE id = p_new_set_id;

  -- Notification templates
  SELECT * INTO v_tmpl_assigned FROM workflow_notification_templates WHERE code = 'job_relationship.assigned';
  SELECT * INTO v_tmpl_removed  FROM workflow_notification_templates WHERE code = 'job_relationship.removed';

  -- Iterate over all 6 codes and compare old vs new manager
  FOR v_item IN
    SELECT pv.ref_id AS code, pv.value AS label
    FROM   picklist_values pv
    WHERE  pv.picklist_id = v_picklist_id
      AND  pv.active = true
    ORDER  BY pv.ref_id
  LOOP
    -- Old manager for this code (NULL if first set or code wasn't assigned)
    SELECT manager_employee_id INTO v_old_mgr_id
    FROM   employee_job_relationship_item
    WHERE  set_id = p_old_set_id AND relationship_code = v_item.code;

    -- New manager for this code (NULL if code removed in new set)
    SELECT manager_employee_id INTO v_new_mgr_id
    FROM   employee_job_relationship_item
    WHERE  set_id = p_new_set_id AND relationship_code = v_item.code;

    -- No change — skip
    IF v_old_mgr_id IS NOT DISTINCT FROM v_new_mgr_id THEN
      CONTINUE;
    END IF;

    -- ── Manager removed ──────────────────────────────────────────────────────
    IF v_old_mgr_id IS NOT NULL AND v_old_mgr_id IS DISTINCT FROM v_new_mgr_id THEN
      -- Resolve old manager's profile
      SELECT id INTO v_mgr_profile_id
      FROM   profiles WHERE employee_id = v_old_mgr_id AND is_active = true LIMIT 1;

      IF v_mgr_profile_id IS NOT NULL AND v_tmpl_removed.id IS NOT NULL THEN
        v_title := replace(replace(replace(v_tmpl_removed.title_tmpl,
          '{{relationship_label}}', v_item.label),
          '{{employee_name}}',     v_employee.name),
          '{{employee_code}}',     v_employee.employee_code);

        v_body := replace(replace(replace(replace(replace(v_tmpl_removed.body_tmpl,
          '{{relationship_label}}', v_item.label),
          '{{employee_name}}',     v_employee.name),
          '{{employee_code}}',     v_employee.employee_code),
          '{{effective_from}}',    to_char(v_effective_from, 'DD Mon YYYY')),
          '{{actor_name}}',        v_actor_name);

        INSERT INTO notifications (profile_id, title, body)
        VALUES (v_mgr_profile_id, v_title, v_body);
      END IF;
    END IF;

    -- ── Manager assigned (new or replaced) ───────────────────────────────────
    IF v_new_mgr_id IS NOT NULL THEN
      SELECT id INTO v_mgr_profile_id
      FROM   profiles WHERE employee_id = v_new_mgr_id AND is_active = true LIMIT 1;

      IF v_mgr_profile_id IS NOT NULL AND v_tmpl_assigned.id IS NOT NULL THEN
        v_title := replace(replace(v_tmpl_assigned.title_tmpl,
          '{{relationship_label}}', v_item.label),
          '{{employee_name}}',     v_employee.name);

        v_body := replace(replace(replace(replace(v_tmpl_assigned.body_tmpl,
          '{{relationship_label}}', v_item.label),
          '{{employee_name}}',     v_employee.name),
          '{{employee_code}}',     v_employee.employee_code),
          '{{effective_from}}',    to_char(v_effective_from, 'DD Mon YYYY'));

        INSERT INTO notifications (profile_id, title, body)
        VALUES (v_mgr_profile_id, v_title, v_body);
      END IF;
    END IF;

  END LOOP;
END;
$$;

COMMENT ON FUNCTION fn_queue_job_relationship_notifications(uuid, uuid, uuid, uuid) IS
  'Diffs two job-relationship sets and queues assigned/removed notifications '
  'to the affected matrix managers. '
  'Called by upsert_job_relationship_set after a successful PATH A (direct write). '
  'Deactivation-fanout writes are NOT notified (locked decision in design spec §9).';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT code, length(title_tmpl) AS title_len, length(body_tmpl) AS body_len
FROM   workflow_notification_templates
WHERE  code IN ('job_relationship.assigned', 'job_relationship.removed')
ORDER  BY code;

SELECT proname
FROM   pg_proc
WHERE  proname = 'fn_queue_job_relationship_notifications';

-- =============================================================================
-- END OF MIGRATION 363
-- =============================================================================
