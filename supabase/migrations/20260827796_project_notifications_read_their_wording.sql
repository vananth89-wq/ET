-- =============================================================================
-- Migration 796: project notifications take their wording from the
--                notification templates, so an administrator can edit them
--
-- WHAT WAS ASKED FOR
-- ══════════════════
-- The four assignment notifications (789/793/794) build their wording with
-- format() inside plpgsql. Changing a word therefore needs a migration and a
-- deploy. Admin -> Manage Notifications already edits wording for every
-- workflow notification; project events should be in that screen too.
--
-- WHAT THIS DOES *NOT* DO, AND WHY
-- ────────────────────────────────
-- It does not put project events through workflow_notification_queue.
--
--   workflow_notification_queue.instance_id uuid NOT NULL
--     REFERENCES workflow_instances(id) ON DELETE CASCADE
--
-- A project assignment has no workflow instance and must not be given a fake
-- one -- it would surface in My Requests, the approver inbox, the stalled-
-- workflow report and the analytics RPCs. The alternative, dropping that NOT
-- NULL, removes the guarantee that every queued notification is traceable to
-- the instance it came from, and makes three renderers plus
-- _wf_notification_link() nullable-instance-safe. That is a change to the
-- approval path's invariants in order to serve a caller that is not an
-- approval. Migration 789 declined it for the same reason, citing
-- notify_delegation_created() (mig 428041), which hit the wall first.
--
-- The queue is not what makes wording editable. The TEMPLATES are:
--
--   workflow_notification_templates (code, title_tmpl, body_tmpl, category)
--
-- That table is already admin-editable -- SELECT to any signed-in user,
-- INSERT/UPDATE/DELETE under wf_notification_config.edit -- and it knows
-- nothing about workflows. So project events read from it directly and insert
-- into notifications as they do today. No schema change reaches the workflow
-- path; nothing about approvals moves.
--
-- WHAT AN ADMINISTRATOR CAN NOW CHANGE
-- ────────────────────────────────────
-- Eight rows, in the Manage Notifications screen, filed under a new
-- 'project' category:
--
--   project.member_added_self      project.member_added_other
--   project.member_updated_self    project.member_updated_other
--   project.member_ended_self      project.member_ended_other
--   project.member_removed_self    project.member_removed_other
--
-- _self is the message to the person it happened to; _other is the message
-- about them, sent to their line manager and to the project lead.
--
-- Tokens: {{project}} {{project_end}} {{employee}} {{employee_code}} {{role}}
--         {{start_date}} {{end_date}} {{percentage}} {{actor}} {{detail}}
--
-- {{detail}} is the whole labelled block, pre-formatted. A template can only
-- replace() -- it has no formatting, no conditionals and no defaults -- so the
-- dates, the percentage and the 'Open-ended' / 'Not set' fallbacks are
-- resolved before they reach it. An admin can move the block, or drop it, but
-- cannot reformat what is inside it. Mig 749 made the same call for the same
-- reason: {{recorded_minutes}} renders 4560 where a reader expects 76 h, and a
-- notification must not promise a number it can only print wrong.
--
-- TWO DELIBERATE DIFFERENCES FROM THE WORKFLOW RENDERER
-- ────────────────────────────────────────────────────
--   1. A MISSING TEMPLATE FALLS BACK, it does not go silent.
--      wf_queue_notification() skips with a NOTICE when a code is not found,
--      so deleting a template quietly turns a notification off. Here the
--      hardcoded wording from 793/794 remains in the function as the fallback.
--      Deleting a row changes the words; it never stops the message.
--
--   2. AN UNRESOLVED TOKEN IS REMOVED, not shipped.
--      The three workflow renderers leave {{approver_name}} in the body as
--      literal braces when the token does not exist -- a live hazard 753's
--      header records. render_notification_template() strips any placeholder
--      still standing after substitution, and treats an empty title as no
--      template at all, which falls back.
--
-- ALSO FIXED HERE
-- ───────────────
-- Q8 from the design review. The old third-person body reused the second-
-- person verb, producing "Meera R was changed on AMPTJ" and "Meera R was
-- ended on AMPTJ". The seeded _other templates say
-- "Meera R's assignment on AMPTJ was changed by Hari A." instead.
--
-- CHANGES
-- ───────
--   workflow_notification_templates      -- 'project' added to the category CHECK
--   render_notification_template(text, jsonb)   -- NEW, the shared renderer
--   8 seeded templates
--   notify_project_member_change()       -- consults a template, falls back
-- =============================================================================

SET jit = 'off';

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. A category for project events
-- ═══════════════════════════════════════════════════════════════════════════
-- Widening a CHECK is additive: every existing row still satisfies it. Without
-- this the seeds below fail the NOT NULL that mig 756 deliberately left
-- without a DEFAULT.

DO $mig$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint
             WHERE conname = 'workflow_notification_templates_category_chk') THEN
    ALTER TABLE public.workflow_notification_templates
      DROP CONSTRAINT workflow_notification_templates_category_chk;
  END IF;

  ALTER TABLE public.workflow_notification_templates
    ADD CONSTRAINT workflow_notification_templates_category_chk
    CHECK (category IN ('task','sla','approval','returned','admin','general','project'));
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. The renderer
-- ═══════════════════════════════════════════════════════════════════════════
-- Substitution and nothing else. No instance, no queue, no workflow. This is
-- the piece the workflow renderers should have shared: the {{key}} loop is
-- currently copy-pasted into trg_wf_deliver_notification(),
-- wf_deliver_pending_notifications() and wf_flush_notification_queue(), and
-- the copies have already drifted -- only the first resolves {{module_label}},
-- so a template drained by cron renders raw braces. Nothing here changes those
-- three; they can be retrofitted onto this later, one at a time.

CREATE OR REPLACE FUNCTION public.render_notification_template(
  p_code    text,
  p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_title text;
  v_body  text;
  v_key   text;
  v_val   text;
BEGIN
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    RETURN NULL;
  END IF;

  SELECT t.title_tmpl, t.body_tmpl INTO v_title, v_body
  FROM   workflow_notification_templates t
  WHERE  t.code = p_code;

  IF NOT FOUND THEN
    RETURN NULL;                       -- the caller decides what to do instead
  END IF;

  FOR v_key, v_val IN
    SELECT key, value FROM jsonb_each_text(COALESCE(p_payload, '{}'::jsonb))
  LOOP
    v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
    v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
  END LOOP;

  -- A placeholder still standing is a token the author expected and the caller
  -- never passed. Shipping it renders "{{approver_name}}" in somebody's inbox,
  -- which is how the workflow templates behave today and is worse than saying
  -- nothing. Remove it rather than pass it on.
  v_title := regexp_replace(v_title, '\{\{[A-Za-z0-9_.]+\}\}', '', 'g');
  v_body  := regexp_replace(v_body,  '\{\{[A-Za-z0-9_.]+\}\}', '', 'g');

  -- An empty title is not a message. Treated as no template, so the caller
  -- falls back to wording that is known to work.
  IF btrim(COALESCE(v_title, '')) = '' THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object('title', v_title, 'body', COALESCE(v_body, ''));
END;
$fn$;

REVOKE ALL ON FUNCTION public.render_notification_template(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.render_notification_template(text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.render_notification_template(text, jsonb) IS
  'Mig 796: resolve a notification template by code and substitute {{tokens}} '
  'from a jsonb payload. Returns {title, body}, or NULL when the code is '
  'unknown or the rendered title is empty -- the caller falls back rather than '
  'going silent. Unresolved placeholders are stripped, never shipped.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. The eight templates
-- ═══════════════════════════════════════════════════════════════════════════
-- Seeded to reproduce today's wording exactly, EXCEPT the _other bodies, which
-- fix Q8. ON CONFLICT DO NOTHING, not DO UPDATE: re-running this migration
-- must not overwrite wording an administrator has since edited. That is the
-- opposite of how the workflow seeds behave, and deliberate -- these rows are
-- meant to be edited, so the seed is a starting point rather than the truth.

INSERT INTO workflow_notification_templates (code, category, title_tmpl, body_tmpl)
VALUES
  ('project.member_added_self', 'project',
   'You are now on {{project}}',
   E'You were added to {{project}} by {{actor}}.\n\n{{detail}}\nRecord your time against it in My Timesheet.'),

  ('project.member_added_other', 'project',
   '{{employee}} has joined {{project}}',
   E'{{employee}} was added to {{project}} by {{actor}}.\n\n{{detail}}'),

  ('project.member_updated_self', 'project',
   'Your assignment on {{project}} has changed',
   E'Your assignment was changed on {{project}} by {{actor}}.\n\n{{detail}}\nRecord your time against it in My Timesheet.'),

  ('project.member_updated_other', 'project',
   '{{employee}}''s assignment on {{project}} changed',
   E'{{employee}}''s assignment on {{project}} was changed by {{actor}}.\n\n{{detail}}'),

  ('project.member_ended_self', 'project',
   'Your assignment on {{project}} has ended',
   E'Your assignment was ended on {{project}} by {{actor}}.\n\n{{detail}}'),

  ('project.member_ended_other', 'project',
   '{{employee}} has come off {{project}}',
   E'{{employee}}''s assignment on {{project}} was ended by {{actor}}.\n\n{{detail}}'),

  ('project.member_removed_self', 'project',
   'You have been removed from {{project}}',
   E'Your assignment was removed from {{project}} by {{actor}}.\n\n{{detail}}'),

  ('project.member_removed_other', 'project',
   '{{employee}} was removed from {{project}}',
   E'{{employee}} was removed from {{project}} by {{actor}}.\n\n{{detail}}')
ON CONFLICT (code) DO NOTHING;


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. The notifier consults a template
-- ═══════════════════════════════════════════════════════════════════════════
-- Rewritten whole rather than patched in place. The house rule against
-- retyping a body exists because a body copied from an EARLIER migration file
-- silently reverts every patch since -- the defect behind 734/736/737. Here
-- the rewrite is deliberate and the pre-state is asserted first: if Dev does
-- not carry exactly 793-as-patched-by-794, this refuses rather than reverting
-- something it did not know about.

DO $mig$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'notify_project_member_change';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 796: notify_project_member_change not found -- 793 has not run';
  END IF;

  IF position('render_notification_template' in v_src) > 0 THEN
    RAISE NOTICE 'mig 796: the notifier already reads templates -- skipping the rewrite';
    RETURN;
  END IF;

  -- 794 must have landed: the project end date is in the block and the padded
  -- labels are gone. Either failing means the live body is not what this
  -- rewrite was written against.
  IF position('Project ends:' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 796: live body predates 794 -- refusing to rewrite it';
  END IF;
  IF position(E'Percentage:  %s' in v_src) > 0 THEN
    RAISE EXCEPTION 'mig 796: live body still carries padded labels -- refusing to rewrite it';
  END IF;
  IF position('notify_project_member_change: unknown event' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 796: live body is not the 793 notifier -- refusing to rewrite it';
  END IF;
END $mig$;


CREATE OR REPLACE FUNCTION public.notify_project_member_change(
  p_member_id uuid,
  p_event     text DEFAULT 'added'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_m           project_members%ROWTYPE;
  v_project     text;
  v_pend        date;
  v_pers_name   text;
  v_pers_code   text;
  v_role        text;
  v_person_prof uuid;
  v_actor_emp   uuid;
  v_actor       text;
  v_line_prof   uuid;
  v_lead_emp    uuid;
  v_lead_prof   uuid;
  v_pct         text;
  v_detail      text;
  v_verb        text;
  v_title_self  text;
  v_title_other text;
  v_body_self   text;
  v_body_other  text;
  v_payload     jsonb;
  v_tpl_self    jsonb;
  v_tpl_other   jsonb;
  v_used_tpl    boolean := false;
  v_sent        int := 0;
  v_targets     uuid[] := '{}';
BEGIN
  IF p_event NOT IN ('added', 'updated', 'ended', 'removed') THEN
    RAISE EXCEPTION 'notify_project_member_change: unknown event %', p_event;
  END IF;

  SELECT * INTO v_m FROM project_members WHERE id = p_member_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('sent', 0, 'reason', 'member row not found');
  END IF;

  SELECT p.name, p.manager_id, p.end_date INTO v_project, v_lead_emp, v_pend
  FROM   projects p WHERE p.id = v_m.project_id;

  SELECT e.name, e.employee_id INTO v_pers_name, v_pers_code
  FROM   employees e WHERE e.id = v_m.employee_id;

  SELECT pv.value INTO v_role FROM picklist_values pv WHERE pv.id = v_m.role_id;

  v_actor_emp := get_my_employee_id();
  SELECT e.name INTO v_actor FROM employees e WHERE e.id = v_actor_emp;

  SELECT pr.id INTO v_person_prof FROM profiles pr WHERE pr.employee_id = v_m.employee_id;

  SELECT pr.id INTO v_line_prof
  FROM   employees e
  JOIN   profiles  pr ON pr.employee_id = e.manager_id
  WHERE  e.id = v_m.employee_id;

  IF v_lead_emp IS NOT NULL THEN
    SELECT pr.id INTO v_lead_prof FROM profiles pr WHERE pr.employee_id = v_lead_emp;
  END IF;

  v_pct := CASE WHEN v_m.allocation_pct IS NULL THEN 'Not set'
                ELSE trim(trailing '.' from trim(to_char(v_m.allocation_pct, 'FM999D99'))) || '%' END;

  -- One space after each label. The email renders this in a proportional font
  -- with runs of spaces collapsed, so padded columns are invisible there and
  -- merely odd in the bell. See the mig 794 header.
  v_detail :=
       format(E'Project: %s\n', COALESCE(v_project, '—'))
    || format(E'Project ends: %s\n', COALESCE(to_char(v_pend, 'DD Mon YYYY'), '—'))
    || format(E'Employee: %s (%s)\n', COALESCE(v_pers_name, '—'), COALESCE(v_pers_code, '—'))
    || format(E'Role: %s\n', COALESCE(v_role, 'Not set'))
    || format(E'Start date: %s\n', to_char(v_m.effective_from, 'DD Mon YYYY'))
    || format(E'End date: %s\n', COALESCE(to_char(v_m.effective_to, 'DD Mon YYYY'), 'Open-ended'))
    || format(E'Percentage: %s\n', v_pct);

  v_verb := CASE p_event
              WHEN 'added'   THEN 'added to'
              WHEN 'updated' THEN 'changed on'
              WHEN 'ended'   THEN 'ended on'
              WHEN 'removed' THEN 'removed from'
            END;

  -- ── the fallback wording, unchanged from 793/794 ──────────────────────────
  -- Kept in the function on purpose. A deleted or emptied template changes the
  -- words; it must never be able to switch the message off.
  v_title_self := CASE p_event
    WHEN 'added'   THEN format('You are now on %s',                 COALESCE(v_project, 'a project'))
    WHEN 'updated' THEN format('Your assignment on %s has changed',  COALESCE(v_project, 'a project'))
    WHEN 'ended'   THEN format('Your assignment on %s has ended',    COALESCE(v_project, 'a project'))
    WHEN 'removed' THEN format('You have been removed from %s',      COALESCE(v_project, 'a project'))
  END;

  v_title_other := CASE p_event
    WHEN 'added'   THEN format('%s has joined %s',              COALESCE(v_pers_name, 'Someone'), COALESCE(v_project, 'a project'))
    WHEN 'updated' THEN format('%s''s assignment on %s changed', COALESCE(v_pers_name, 'Someone'), COALESCE(v_project, 'a project'))
    WHEN 'ended'   THEN format('%s has come off %s',            COALESCE(v_pers_name, 'Someone'), COALESCE(v_project, 'a project'))
    WHEN 'removed' THEN format('%s was removed from %s',        COALESCE(v_pers_name, 'Someone'), COALESCE(v_project, 'a project'))
  END;

  v_body_self :=
    format(E'%s %s %s by %s.\n\n%s',
           CASE p_event WHEN 'added' THEN 'You were' ELSE 'Your assignment was' END,
           v_verb, COALESCE(v_project, 'the project'),
           COALESCE(v_actor, 'a project lead'), v_detail)
    || CASE WHEN p_event IN ('added', 'updated')
            THEN E'\nRecord your time against it in My Timesheet.' ELSE '' END;

  v_body_other :=
    format(E'%s was %s %s by %s.\n\n%s',
           COALESCE(v_pers_name, 'Someone'), v_verb,
           COALESCE(v_project, 'the project'), COALESCE(v_actor, 'a project lead'), v_detail);

  -- ── the editable wording, when a template exists ──────────────────────────
  v_payload := jsonb_build_object(
    'project',       COALESCE(v_project, 'a project'),
    'project_end',   COALESCE(to_char(v_pend, 'DD Mon YYYY'), '—'),
    'employee',      COALESCE(v_pers_name, 'Someone'),
    'employee_code', COALESCE(v_pers_code, '—'),
    'role',          COALESCE(v_role, 'Not set'),
    'start_date',    to_char(v_m.effective_from, 'DD Mon YYYY'),
    'end_date',      COALESCE(to_char(v_m.effective_to, 'DD Mon YYYY'), 'Open-ended'),
    'percentage',    v_pct,
    'actor',         COALESCE(v_actor, 'a project lead'),
    'detail',        v_detail);

  v_tpl_self  := render_notification_template('project.member_' || p_event || '_self',  v_payload);
  v_tpl_other := render_notification_template('project.member_' || p_event || '_other', v_payload);

  IF v_tpl_self IS NOT NULL THEN
    v_title_self := v_tpl_self->>'title';
    v_body_self  := v_tpl_self->>'body';
    v_used_tpl   := true;
  END IF;

  IF v_tpl_other IS NOT NULL THEN
    v_title_other := v_tpl_other->>'title';
    v_body_other  := v_tpl_other->>'body';
    v_used_tpl    := true;
  END IF;

  -- ── the person ────────────────────────────────────────────────────────────
  IF v_person_prof IS NOT NULL THEN
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (v_person_prof, v_title_self, v_body_self, '/my-timesheet');
    v_sent := v_sent + 1;
    v_targets := v_targets || v_person_prof;
  END IF;

  -- ── their line manager ────────────────────────────────────────────────────
  IF v_line_prof IS NOT NULL AND NOT (v_line_prof = ANY (v_targets)) THEN
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (v_line_prof, v_title_other, v_body_other, NULL);
    v_sent := v_sent + 1;
    v_targets := v_targets || v_line_prof;
  END IF;

  -- ── the project lead, unless they did it themselves ───────────────────────
  IF v_lead_prof IS NOT NULL
     AND NOT (v_lead_prof = ANY (v_targets))
     AND v_lead_emp IS DISTINCT FROM v_actor_emp THEN
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (v_lead_prof, v_title_other, v_body_other, '/my-projects');
    v_sent := v_sent + 1;
  END IF;

  RETURN jsonb_build_object('sent', v_sent, 'event', p_event, 'templated', v_used_tpl);
END;
$fn$;

REVOKE ALL ON FUNCTION public.notify_project_member_change(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.notify_project_member_change(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.notify_project_member_change(uuid, text) IS
  'Mig 793/794/796: announces added / updated / ended / removed on a project '
  'assignment to the person, their line manager and the project lead. Wording '
  'comes from the project.member_<event>_self / _other templates, editable in '
  'Manage Notifications; a missing or empty template falls back to the wording '
  'built into this function rather than going silent. ''removed'' must be '
  'called BEFORE the row is deleted.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src  text;
  v_n    int;
  v_r    jsonb;
BEGIN
  -- 1. the category is open to project events
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conname = 'workflow_notification_templates_category_chk'
      AND  pg_get_constraintdef(oid) LIKE '%project%') THEN
    RAISE EXCEPTION 'mig 796: the category CHECK does not admit project events';
  END IF;

  -- 2. eight templates, all of them project-category
  SELECT count(*) INTO v_n FROM workflow_notification_templates
  WHERE code LIKE 'project.member_%';
  IF v_n <> 8 THEN
    RAISE EXCEPTION 'mig 796: expected 8 project.member_* templates, found %', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM workflow_notification_templates
  WHERE code LIKE 'project.member_%' AND category <> 'project';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig 796: % project template(s) filed under another category', v_n;
  END IF;

  -- 3. the renderer substitutes, and strips what it cannot
  v_r := render_notification_template('project.member_added_self',
           jsonb_build_object('project', 'AMPTJ', 'actor', 'Hari A', 'detail', 'X'));
  IF v_r IS NULL THEN
    RAISE EXCEPTION 'mig 796: the renderer found no template for a code it seeded';
  END IF;
  IF v_r->>'title' <> 'You are now on AMPTJ' THEN
    RAISE EXCEPTION 'mig 796: token substitution produced %', v_r->>'title';
  END IF;
  IF position('{{' in (v_r->>'body')) > 0 THEN
    RAISE EXCEPTION 'mig 796: an unresolved placeholder survived into the body';
  END IF;

  -- 4. an unknown code returns NULL rather than raising, so callers fall back
  IF render_notification_template('project.no_such_template_exists', '{}'::jsonb) IS NOT NULL THEN
    RAISE EXCEPTION 'mig 796: an unknown template code did not return NULL';
  END IF;

  -- 5. the notifier reads templates AND still carries its fallback wording.
  --    Losing either is a defect: the first makes the screen inert, the second
  --    lets a deleted row switch notifications off.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'notify_project_member_change';

  IF position('render_notification_template' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 796: the notifier does not consult a template';
  END IF;
  IF position('You are now on %s' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 796: the notifier lost its fallback wording';
  END IF;
  IF position('Project ends:' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 796: the rewrite dropped the project end date';
  END IF;

  -- 6. nothing about the workflow path moved
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'workflow_notification_queue'
               AND column_name = 'instance_id' AND is_nullable = 'YES') THEN
    RAISE EXCEPTION 'mig 796: workflow_notification_queue.instance_id became nullable';
  END IF;

  RAISE NOTICE 'mig 796: OK -- project wording is editable, and falls back when it is not';
END $mig$;
