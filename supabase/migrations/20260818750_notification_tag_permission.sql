-- Migration : 20260818750_notification_tag_permission.sql
-- Purpose   : Correct the write permission on workflow_template_notifications.
--
-- 748 gave the table `wf_notifications.edit`, on the reasoning that it is about
-- notifications. That is the wrong half of the sentence. This codebase already
-- draws the line elsewhere, and consistently:
--
--   AUTHOR the wording   workflow_notification_templates   wf_notifications.edit
--   BIND it to a step    workflow_steps.notification_...   wf_templates.edit   (505128)
--   Clone a template     wf_copy_template                  workflow.admin      (652)
--
-- workflow_template_notifications is a BINDING, not wording -- the same act as
-- setting the dropdown on a step, one level up. It must carry the same
-- permission, `wf_templates.edit`.
--
-- Why this matters more than tidiness : the admin screen for these rows belongs
-- inside the workflow template editor, which is gated on wf_templates.edit. Left
-- as it was, an administrator with wf_templates.edit but not wf_notifications
-- .edit would see the control, choose a notification, and have the write
-- silently refused by RLS. That is the exact defect 748 existed to fix -- a
-- control that does nothing -- reintroduced one table over.
--
-- SELECT stays open. Reading which notification a workflow uses tells you
-- nothing you could not learn by receiving one.
--
-- Depends on : 748 (the table), 505128 (the wf_templates.edit convention)

DO $perm$
BEGIN
  DROP POLICY IF EXISTS wf_tmpl_notif_insert ON public.workflow_template_notifications;
  DROP POLICY IF EXISTS wf_tmpl_notif_update ON public.workflow_template_notifications;
  DROP POLICY IF EXISTS wf_tmpl_notif_delete ON public.workflow_template_notifications;

  CREATE POLICY wf_tmpl_notif_insert ON public.workflow_template_notifications
    FOR INSERT WITH CHECK (user_can('wf_templates', 'edit', NULL));

  CREATE POLICY wf_tmpl_notif_update ON public.workflow_template_notifications
    FOR UPDATE USING      (user_can('wf_templates', 'edit', NULL))
               WITH CHECK (user_can('wf_templates', 'edit', NULL));

  CREATE POLICY wf_tmpl_notif_delete ON public.workflow_template_notifications
    FOR DELETE USING (user_can('wf_templates', 'edit', NULL));
END
$perm$;

COMMENT ON TABLE public.workflow_template_notifications IS
  'Per-workflow-version wording for INSTANCE-scoped notification events '
  '(completed, rejected, returned, clarification) -- the ones no step can own. '
  'Written under wf_templates.edit, the same permission that governs a step and '
  'its own notification override: this is a binding, not wording. The wording '
  'itself lives in workflow_notification_templates under wf_notifications.edit.';

-- ── Assertion ────────────────────────────────────────────────────────────────
DO $chk$
DECLARE
  v_wrong int;
BEGIN
  SELECT count(*) INTO v_wrong
  FROM   pg_policies
  WHERE  schemaname = 'public'
    AND  tablename  = 'workflow_template_notifications'
    AND  cmd <> 'SELECT'
    AND  coalesce(qual, '') || coalesce(with_check, '') LIKE '%wf_notifications%';

  IF v_wrong > 0 THEN
    RAISE EXCEPTION
      'mig 750 assert: % write policy(ies) still reference wf_notifications', v_wrong;
  END IF;

  SELECT count(*) INTO v_wrong
  FROM   pg_policies
  WHERE  schemaname = 'public'
    AND  tablename  = 'workflow_template_notifications'
    AND  cmd <> 'SELECT'
    AND  coalesce(qual, '') || coalesce(with_check, '') LIKE '%wf_templates%';

  IF v_wrong <> 3 THEN
    RAISE EXCEPTION
      'mig 750 assert: expected 3 write policies on wf_templates.edit, found %', v_wrong;
  END IF;

  RAISE NOTICE 'mig 750: write policies now require wf_templates.edit';
END
$chk$;
