-- Migration : 20260818751_copy_template_carries_everything.sql
-- Purpose   : Make wf_copy_template copy what a workflow actually IS.
--
-- Found while adding notification overrides to the clone: the step INSERT names
-- its columns explicitly and lists TEN of the EIGHTEEN on workflow_steps. The
-- eight it omits are not incidental — they are most of what an administrator
-- configures on the step editor screen:
--
--     sla_hours               the deadline
--     reminder_after_hours    the chase
--     escalation_after_hours  the auto-escalation
--     allow_delegation        whether an approver may hand off
--     allow_edit              whether an approver may edit the record
--     relationship_code       which relationship a RELATIONSHIP approver follows
--     notification_template_id the step's own notification override
--
-- So cloning the Timesheet workflow — 48h SLA, 24h reminder, 72h escalation,
-- delegation on — produced a copy with NO deadline, NO reminder and NO
-- escalation. Nothing reported it. The copy looks right on the steps list,
-- because the columns that show there are the ones that were copied.
--
-- Also copied now: workflow_template_notifications (mig 748), so a clone keeps
-- its wording instead of silently reverting to the generic "Request fully
-- approved".
--
-- Method : FULL CREATE OR REPLACE, rebuilt from 652 — NOT an in-place patch.
--   This function has been replaced wholesale three times (650 -> 651 -> 652);
--   an in-place patch would be reverted without a word by the next rewrite. A
--   first attempt at this did try to patch it in place, anchored on
--   `RETURN v_new_template_id`, which does not exist: the function returns jsonb
--   and names its variable v_new_tpl_id. The assertion caught it and refused,
--   which is the only reason it is not silently broken now.
--
--   Everything from 652 is preserved verbatim — the workflow.admin check, the
--   active-version resolution, the code-in-use guard, the GLOBAL assignment
--   insert and the exception handler. The ONLY changes are the two INSERT
--   column lists.
--
-- Depends on : 652 (the function this rebuilds), 748 (workflow_template_notifications)

CREATE OR REPLACE FUNCTION wf_copy_template(
  p_source_id      uuid,
  p_name           text,
  p_code           text,
  p_description    text    DEFAULT NULL,
  p_effective_from date    DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_src_code       text;
  v_active_tpl_id  uuid;
  v_new_tpl_id     uuid;
BEGIN
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied: workflow.admin required.');
  END IF;

  SELECT code INTO v_src_code FROM workflow_templates WHERE id = p_source_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Source template not found.');
  END IF;

  SELECT id INTO v_active_tpl_id
  FROM   workflow_templates
  WHERE  code = v_src_code AND is_active = true
  ORDER  BY version DESC LIMIT 1;

  IF v_active_tpl_id IS NULL THEN
    v_active_tpl_id := p_source_id;
  END IF;

  IF EXISTS (SELECT 1 FROM workflow_templates   WHERE code        = p_code)
  OR EXISTS (SELECT 1 FROM workflow_assignments WHERE module_code = p_code)
  THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Module code "%s" is already in use. Choose a different code.', p_code));
  END IF;

  INSERT INTO workflow_templates (
    name, code, description, version, is_active,
    skip_duplicate_approver, remove_duplicate_approver, published_at, parent_version
  )
  SELECT p_name, p_code, COALESCE(p_description, description),
         1, false, skip_duplicate_approver, remove_duplicate_approver, NULL, NULL
  FROM   workflow_templates WHERE id = v_active_tpl_id
  RETURNING id INTO v_new_tpl_id;

  -- MIG 751: every configured column, not the ten that happened to be listed.
  -- A step whose SLA and escalation did not survive the copy is a step that will
  -- sit in someone's inbox indefinitely without ever chasing anyone.
  INSERT INTO workflow_steps (
    template_id, step_order, name, approver_type, approver_profile_id,
    approver_role, is_mandatory, is_active, is_cc, approval_mode,
    sla_hours, reminder_after_hours, escalation_after_hours,
    allow_delegation, allow_edit, relationship_code, notification_template_id
  )
  SELECT v_new_tpl_id, step_order, name, approver_type, approver_profile_id,
         approver_role, is_mandatory, is_active, is_cc, approval_mode,
         sla_hours, reminder_after_hours, escalation_after_hours,
         allow_delegation, allow_edit, relationship_code, notification_template_id
  FROM   workflow_steps WHERE template_id = v_active_tpl_id
  ORDER  BY step_order;

  -- MIG 751: instance-scoped notification wording (748). Without this a clone
  -- reverts to the generic text, which reads as a regression nobody made.
  INSERT INTO workflow_template_notifications (
    template_id, event_code, notification_template_id
  )
  SELECT v_new_tpl_id, event_code, notification_template_id
  FROM   workflow_template_notifications
  WHERE  template_id = v_active_tpl_id
  ON CONFLICT (template_id, event_code) DO NOTHING;

  INSERT INTO workflow_assignments (
    module_code, wf_template_id, assignment_type, entity_id,
    is_active, effective_from, effective_to
  ) VALUES (
    p_code, v_new_tpl_id, 'GLOBAL', NULL, false, p_effective_from, NULL
  );

  RETURN jsonb_build_object('ok', true, 'template_id', v_new_tpl_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION wf_copy_template(uuid, text, text, text, date) TO authenticated;

COMMENT ON FUNCTION wf_copy_template IS
  'Mig 751: copies every configured step column — SLA, reminder, escalation, '
  'delegation, edit, relationship_code and the step notification override — plus '
  'the instance-scoped notification wording from workflow_template_notifications. '
  '652 copied ten of eighteen step columns, so a clone silently lost its '
  'deadlines and its escalation.';

-- ── Assertions ───────────────────────────────────────────────────────────────
-- The failure mode being guarded is a COLUMN GOING MISSING AGAIN, which produces
-- a clone that looks correct on screen and behaves differently in production.
DO $chk$
DECLARE
  v_src  text;
  c      text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_copy_template';

  FOREACH c IN ARRAY ARRAY[
    'sla_hours', 'reminder_after_hours', 'escalation_after_hours',
    'allow_delegation', 'allow_edit', 'relationship_code',
    'notification_template_id', 'workflow_template_notifications'
  ] LOOP
    IF position(c IN v_src) = 0 THEN
      RAISE EXCEPTION 'mig 751 assert: wf_copy_template does not carry %', c;
    END IF;
  END LOOP;

  -- 652's behaviour must be intact, not merely the new columns present.
  IF position('workflow.admin required' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 751 assert: the permission check from 652 was lost';
  END IF;
  IF position('is already in use' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 751 assert: the code-in-use guard from 652 was lost';
  END IF;
  IF position('''GLOBAL''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 751 assert: the GLOBAL assignment insert from 652 was lost';
  END IF;

  RAISE NOTICE 'mig 751: wf_copy_template now carries all step columns and the wording';
END
$chk$;
