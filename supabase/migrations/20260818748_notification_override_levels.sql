-- Migration : 20260818748_notification_override_levels.sql
-- Purpose   : Make notification wording configurable at the level each event
--             actually belongs to, for EVERY module, without seeding a template
--             per module per event.
--
--             Two levels, because workflow events genuinely have two scopes:
--
--               STEP-scoped     task assigned, reassigned, SLA warning/breach.
--                               Already has a home: workflow_steps
--                               .notification_template_id (mig 501093).
--
--               INSTANCE-scoped completed, rejected, returned, clarification.
--                               By the time these fire there is NO next step to
--                               read a template from -- completion is a property
--                               of the run, not of any one approver. This had no
--                               home at all, which is why "Request fully
--                               approved" reached an employee who had submitted
--                               a timesheet, not a request.
--
-- The gap this closes : workflow_steps.notification_template_id was only ever
--             read by wf_advance_instance, which resolves the step AFTER the
--             current one. The FIRST step's task is created by wf_submit, which
--             hardcodes 'wf.task_assigned'. So on a single-step workflow -- the
--             most common shape, and exactly what Timesheet v1 is -- the
--             Notification dropdown in the step editor silently did nothing.
--             Mig 504122 recorded that no step had ever set the column; nobody
--             had had the chance to notice.
--
-- Where the fix lives : entirely inside wf_queue_notification. Both wf_submit
--             and wf_advance_instance already funnel through it, so resolution
--             happens once, in one place, and NEITHER of those two functions is
--             touched. That matters: they are shared by termination, hire,
--             expense and every other module, and a migration that rewrites them
--             to fix notification wording is a migration that can break an
--             approval path.
--
-- Resolution order, most specific first:
--             1. step override        workflow_steps.notification_template_id
--                                     (only for 'wf.task_assigned', and only
--                                     when the caller has not already resolved
--                                     it -- wf_advance_instance still does its
--                                     own lookup and wins by passing a
--                                     non-generic code)
--             2. template override    workflow_template_notifications, keyed on
--                                     the instance's template VERSION
--             3. module prefix        the existing CASE (hire uses it; left
--                                     exactly as it was)
--             4. the generic wf.* code
--
--             Every level is opt-in and falls through. With no rows in the new
--             table and no step overrides set, every module behaves byte for
--             byte as it does today.
--
-- Depends on : 427030 (workflow core + templates), 427032 (code,version unique),
--              501093 (workflow_steps.notification_template_id),
--              505133 (wf_notifications RLS convention),
--              519250 (wf_queue_notification + module-prefix resolution),
--              630650 (wf_copy_template)

-- ── 1. Where instance-scoped wording lives ───────────────────────────────────
-- Keyed on template_id, which IS the version row. Cloning a template to v2 and
-- rewording it must not rewrite v1's live notifications.
CREATE TABLE IF NOT EXISTS public.workflow_template_notifications (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id              uuid NOT NULL
                             REFERENCES public.workflow_templates(id) ON DELETE CASCADE,
  -- The GENERIC event code the engine sends, e.g. 'wf.completed'. Stored rather
  -- than enumerated: the engine gains events over time and a CHECK constraint
  -- would turn each one into a migration.
  event_code               text NOT NULL CHECK (event_code LIKE 'wf.%'),
  notification_template_id uuid NOT NULL
                             REFERENCES public.workflow_notification_templates(id),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT workflow_template_notifications_uniq UNIQUE (template_id, event_code)
);

COMMENT ON TABLE public.workflow_template_notifications IS
  'Per-workflow-version wording for INSTANCE-scoped notification events '
  '(completed, rejected, returned, clarification) -- the ones no step can own. '
  'One row per event a template deliberately customises; absent rows fall back '
  'to the generic wf.* template. Step-scoped events use '
  'workflow_steps.notification_template_id instead.';

COMMENT ON COLUMN public.workflow_template_notifications.event_code IS
  'The generic code the engine emits (wf.completed, wf.rejected, ...), NOT the '
  'replacement. The replacement is notification_template_id.';

CREATE INDEX IF NOT EXISTS workflow_template_notifications_template_idx
  ON public.workflow_template_notifications (template_id);

ALTER TABLE public.workflow_template_notifications ENABLE ROW LEVEL SECURITY;

-- Same permission that governs the templates themselves (mig 505133). Anyone who
-- may write the wording may say where it is used.
DO $rls$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public'
                   AND tablename  = 'workflow_template_notifications'
                   AND policyname = 'wf_tmpl_notif_select') THEN
    CREATE POLICY wf_tmpl_notif_select ON public.workflow_template_notifications
      FOR SELECT USING (true);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public'
                   AND tablename  = 'workflow_template_notifications'
                   AND policyname = 'wf_tmpl_notif_insert') THEN
    CREATE POLICY wf_tmpl_notif_insert ON public.workflow_template_notifications
      FOR INSERT WITH CHECK (user_can('wf_notifications', 'edit', NULL));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public'
                   AND tablename  = 'workflow_template_notifications'
                   AND policyname = 'wf_tmpl_notif_update') THEN
    CREATE POLICY wf_tmpl_notif_update ON public.workflow_template_notifications
      FOR UPDATE USING      (user_can('wf_notifications', 'edit', NULL))
                 WITH CHECK (user_can('wf_notifications', 'edit', NULL));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public'
                   AND tablename  = 'workflow_template_notifications'
                   AND policyname = 'wf_tmpl_notif_delete') THEN
    CREATE POLICY wf_tmpl_notif_delete ON public.workflow_template_notifications
      FOR DELETE USING (user_can('wf_notifications', 'edit', NULL));
  END IF;
END
$rls$;


-- ── 2. Resolve, in one place ─────────────────────────────────────────────────
-- IN-PLACE patch of wf_queue_notification: the module-prefix block from mig
-- 519250 is left exactly as written and the two new lookups are inserted ahead
-- of it. Asserted hit count, so a silent no-op aborts the deploy.
DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a_anchor CONSTANT text :=
    '  v_final_code := p_template_code;   -- default: use the generic code as-is';

  n_anchor CONSTANT text :=
    '  v_final_code := p_template_code;   -- default: use the generic code as-is' || chr(10) ||
    '' || chr(10) ||
    '  -- ── MIG 748: explicit overrides, most specific first ──────────────────────' || chr(10) ||
    '  -- Both run BEFORE the module-prefix convention below, because a template a' || chr(10) ||
    '  -- human chose beats a naming rule the engine inferred.' || chr(10) ||
    '' || chr(10) ||
    '  -- (1) STEP-scoped. Only for the assignment message, and only while the code' || chr(10) ||
    '  --     is still generic: wf_advance_instance does this lookup itself and' || chr(10) ||
    '  --     passes the resolved code in, so re-resolving here would overwrite a' || chr(10) ||
    '  --     more specific decision with the same answer at best.' || chr(10) ||
    '  --     This is what makes the Notification dropdown in the step editor work on' || chr(10) ||
    '  --     step 1, whose task is created by wf_submit -- a hardcoded' || chr(10) ||
    '  --     ''wf.task_assigned'' that never read the column at all.' || chr(10) ||
    '  IF p_template_code = ''wf.task_assigned'' THEN' || chr(10) ||
    '    SELECT wnt.code INTO v_step_code' || chr(10) ||
    '    FROM   workflow_instances wi' || chr(10) ||
    '    JOIN   workflow_steps ws' || chr(10) ||
    '           ON  ws.template_id = wi.template_id' || chr(10) ||
    '           AND ws.step_order  = wi.current_step' || chr(10) ||
    '    JOIN   workflow_notification_templates wnt' || chr(10) ||
    '           ON wnt.id = ws.notification_template_id' || chr(10) ||
    '    WHERE  wi.id = p_instance_id;' || chr(10) ||
    '' || chr(10) ||
    '    IF v_step_code IS NOT NULL THEN' || chr(10) ||
    '      v_final_code := v_step_code;' || chr(10) ||
    '    END IF;' || chr(10) ||
    '  END IF;' || chr(10) ||
    '' || chr(10) ||
    '  -- (2) INSTANCE-scoped. Keyed on the template VERSION of the instance, so v2 can' || chr(10) ||
    '  --     be reworded without touching what live v1 instances send.' || chr(10) ||
    '  IF v_final_code = p_template_code THEN' || chr(10) ||
    '    SELECT wnt.code INTO v_tmpl_code' || chr(10) ||
    '    FROM   workflow_instances wi' || chr(10) ||
    '    JOIN   workflow_template_notifications wtn' || chr(10) ||
    '           ON  wtn.template_id = wi.template_id' || chr(10) ||
    '           AND wtn.event_code  = p_template_code' || chr(10) ||
    '    JOIN   workflow_notification_templates wnt' || chr(10) ||
    '           ON wnt.id = wtn.notification_template_id' || chr(10) ||
    '    WHERE  wi.id = p_instance_id;' || chr(10) ||
    '' || chr(10) ||
    '    IF v_tmpl_code IS NOT NULL THEN' || chr(10) ||
    '      v_final_code := v_tmpl_code;' || chr(10) ||
    '    END IF;' || chr(10) ||
    '  END IF;';

  a_decl CONSTANT text := '  v_final_code     text;';
  n_decl CONSTANT text := '  v_final_code     text;' || chr(10) ||
                          '  v_step_code      text;   -- MIG 748' || chr(10) ||
                          '  v_tmpl_code      text;   -- MIG 748';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'wf_queue_notification'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_instance_id uuid, p_template_code text, p_target_profile uuid, p_payload jsonb';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 748: wf_queue_notification(uuid,text,uuid,jsonb) not found';
  END IF;

  IF position('MIG 748' IN v_src) > 0 THEN
    RAISE NOTICE 'mig 748: overrides already present, nothing to do';
    RETURN;
  END IF;

  v_new := v_src;

  v_hits := (length(v_new) - length(replace(v_new, a_decl, ''))) / length(a_decl);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 748: declaration anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_decl, n_decl);

  v_hits := (length(v_new) - length(replace(v_new, a_anchor, ''))) / length(a_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 748: resolution anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_anchor, n_anchor);

  EXECUTE v_new;
  RAISE NOTICE 'mig 748: wf_queue_notification now resolves step and template overrides';
END
$mig$;


-- ── 3. A clone must carry its wording ────────────────────────────────────────
-- wf_copy_template copies steps. Without this it would copy the steps and drop
-- the instance-scoped wording, so v2 would silently revert to "Request fully
-- approved" the first time anyone cloned a template to make a small change.
DO $cp$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;
  a_tail CONSTANT text := '  RETURN v_new_template_id;';
  n_tail CONSTANT text :=
    '  -- MIG 748: carry instance-scoped notification wording to the new version.' || chr(10) ||
    '  INSERT INTO workflow_template_notifications' || chr(10) ||
    '    (template_id, event_code, notification_template_id)' || chr(10) ||
    '  SELECT v_new_template_id, wtn.event_code, wtn.notification_template_id' || chr(10) ||
    '  FROM   workflow_template_notifications wtn' || chr(10) ||
    '  WHERE  wtn.template_id = p_template_id' || chr(10) ||
    '  ON CONFLICT (template_id, event_code) DO NOTHING;' || chr(10) ||
    '' || chr(10) ||
    '  RETURN v_new_template_id;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_copy_template';

  IF v_src IS NULL THEN
    RAISE NOTICE 'mig 748: wf_copy_template not found — skipping clone patch';
    RETURN;
  END IF;

  IF position('MIG 748' IN v_src) > 0 THEN
    RAISE NOTICE 'mig 748: wf_copy_template already patched';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_tail, ''))) / length(a_tail);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 748: wf_copy_template return anchor matched % times, expected 1', v_hits;
  END IF;

  v_new := replace(v_src, a_tail, n_tail);
  EXECUTE v_new;
  RAISE NOTICE 'mig 748: wf_copy_template now carries notification overrides';
END
$cp$;


-- ── Assertions ───────────────────────────────────────────────────────────────
-- Two in-place patches on functions this migration does not own. A silent no-op
-- would leave the admin UI offering settings that do nothing -- which is the
-- exact defect being fixed, so failing to fix it quietly would be worse than
-- not trying.
DO $chk$
DECLARE
  v_src text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public'
                   AND table_name   = 'workflow_template_notifications') THEN
    RAISE EXCEPTION 'mig 748 assert: workflow_template_notifications was not created';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_queue_notification';

  IF position('workflow_template_notifications' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 748 assert: wf_queue_notification never gained the template override';
  END IF;
  IF position('ws.notification_template_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 748 assert: wf_queue_notification never gained the step override';
  END IF;
  -- The convention that hire depends on must survive untouched.
  IF position('v_module_prefix' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 748 assert: the module-prefix resolution was lost';
  END IF;

  RAISE NOTICE 'mig 748: assertions passed';
END
$chk$;
