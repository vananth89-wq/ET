-- =============================================================================
-- Migration 799: a lead change reaches the person it happened to, and the
--                managers of the people it affects
--
-- THREE CORRECTIONS TO 797
-- ════════════════════════
--
-- 1. THE ACTOR RULE WAS TOO WIDE
-- ──────────────────────────────
-- 797 seeded the actor into the already-told list before resolving anybody, so
-- no message reached the person who made the change. Assign yourself as
-- Reporting Manager and you were told nothing.
--
-- The rule that function implements is "do not tell the actor". The rule it
-- should implement is:
--
--     do not tell you about SOMEBODY ELSE'S standing when you are the
--     one who changed it -- but a message about YOUR OWN standing always
--     reaches you, whoever pressed the button.
--
-- Migration 793 already works that way. Its actor check sits only on the
-- project lead's copy; the person's own message has no actor test at all, so
-- somebody who staffed themselves would still be told they are on the project.
-- 797 and 793 therefore disagreed about the same question, and 793 had it
-- right. This aligns them.
--
--   project.lead_assigned_self   -> sent even when the actor is the new lead
--   project.lead_removed_self    -> sent even when the actor is the outgoing lead
--   *_other, *_changed_team      -> still skip the actor
--
-- There is a second reason to want the self message. Nothing audits
-- projects.manager_id -- no history table, no trigger (Q9 in the design
-- review). Until that changes the notification is the only record that a
-- change happened and who made it, and suppressing the actor's copy removed it
-- from the one inbox most likely to need it.
--
-- 2. THE MEMBERS' LINE MANAGERS WERE MISSING
-- ──────────────────────────────────────────
-- 797 told the current members and deliberately not their line managers, on
-- the grounds that it multiplies one change into many messages.
--
-- That reasoning does not survive contact with 793, which tells a person's
-- line manager every time they join a project, change percentage, or come off
-- it. A lead change is the same fact in the same relationship -- somebody new
-- can see their report's work -- so hearing about every event except this one
-- is an inconsistency, not a saving. A lead changes once or twice a year per
-- project; six members means six more messages, not a flood.
--
-- 3. THE TEAM MESSAGE DID NOT SAY WHO, OR WHY THEM
-- ────────────────────────────────────────────────
-- It named neither the person who made the change -- every assignment message
-- does -- nor the reason the reader is being told. "They can see the team and
-- the hours booked to this project" leads with what the LEAD gained. The
-- reader's stake is the two words at the end of the new sentence: their hours
-- are among the ones now visible.
--
-- The seeds are re-applied here rather than left to ON CONFLICT DO NOTHING,
-- because the point is to change the default. Any row an administrator has
-- ALREADY edited is left alone -- see the WHERE clause on the update.
--
-- CHANGES
-- ───────
--   notify_project_lead_change()   -- actor rule; members' line managers
--   project.lead_changed_team      -- reworded, if still at its seeded default
--   project.lead_team_manager      -- NEW template
-- =============================================================================

SET jit = 'off';

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The new template, and the reworded one
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO workflow_notification_templates (code, category, title_tmpl, body_tmpl)
VALUES
  ('project.lead_team_manager', 'project',
   '{{project}} is now led by {{lead}}',
   E'{{project}}, which {{employee}} is on, is now led by {{lead}}, changed by {{actor}}.\n\n'
   'That means {{lead}} can see this project''s team and the hours booked to it, '
   'including {{employee}}''s.')
ON CONFLICT (code) DO NOTHING;

-- Re-seed the team message, but ONLY where it still holds exactly the wording
-- 797 shipped. An administrator who has already edited it has said what they
-- want it to say, and a migration must not overrule that.
UPDATE workflow_notification_templates
SET    body_tmpl = E'{{project}} is now led by {{lead}}, changed by {{actor}}.\n\n'
                   'That means {{lead}} can see this project''s team and the hours '
                   'booked to it, including yours.\n\n'
                   'Nothing about your own assignment has changed — your role, '
                   'percentage and dates are the same.',
       updated_at = now()
WHERE  code = 'project.lead_changed_team'
  AND  body_tmpl = E'{{lead}} is now the Reporting Manager on {{project}}. They can see the team and '
                   'the hours booked to this project.\n\nYour own assignment is unchanged.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. The notifier
-- ═══════════════════════════════════════════════════════════════════════════
-- Rewritten whole. The pre-state is asserted first: if the live body is not
-- 797's, this refuses rather than reverting something it does not know about.

DO $mig$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'notify_project_lead_change';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 799: notify_project_lead_change not found -- 797 has not run';
  END IF;

  IF position('v_self_ok' in v_src) > 0 THEN
    RAISE NOTICE 'mig 799: the notifier already carries the corrected actor rule -- skipping';
    RETURN;
  END IF;

  IF position('project.lead_assigned_self' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 799: live body is not the 797 notifier -- refusing to rewrite it';
  END IF;
END $mig$;


CREATE OR REPLACE FUNCTION public.notify_project_lead_change(
  p_project_id uuid,
  p_old_lead   uuid,
  p_new_lead   uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_project    text;
  v_start      date;
  v_end        date;
  v_budget     numeric;
  v_active     boolean;
  v_new_name   text;
  v_new_code   text;
  v_old_name   text;
  v_actor_emp  uuid;
  v_actor      text;
  v_team       int;
  v_detail     text;
  v_payload    jsonb;
  v_mgr_payload jsonb;
  v_tpl        jsonb;
  v_prof       uuid;
  v_actor_prof uuid;
  v_targets    uuid[] := '{}';
  v_sent       int := 0;
  v_used_tpl   boolean := false;
  v_self_ok    boolean;
  r            record;
  f_title text;
  f_body  text;
BEGIN
  IF p_old_lead IS NOT DISTINCT FROM p_new_lead THEN
    RETURN jsonb_build_object('sent', 0, 'reason', 'no change');
  END IF;

  SELECT p.name, p.start_date, p.end_date, p.budget_hours, p.active
    INTO v_project, v_start, v_end, v_budget, v_active
  FROM   projects p WHERE p.id = p_project_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sent', 0, 'reason', 'project not found');
  END IF;

  SELECT e.name, e.employee_id INTO v_new_name, v_new_code
  FROM   employees e WHERE e.id = p_new_lead;

  SELECT e.name INTO v_old_name FROM employees e WHERE e.id = p_old_lead;

  v_actor_emp := get_my_employee_id();
  SELECT e.name INTO v_actor FROM employees e WHERE e.id = v_actor_emp;
  SELECT pr.id INTO v_actor_prof FROM profiles pr WHERE pr.employee_id = v_actor_emp;

  -- MIG 799. The actor is NOT seeded into v_targets any more. v_targets now
  -- means only "already told", and the actor rule is applied per message:
  --
  --   a message about the recipient's OWN standing  -> always sent
  --   a message about somebody else's               -> skipped for the actor
  --
  -- 797 conflated the two and silenced somebody who made themselves the lead.
  -- v_self_ok is the guard used by the two _other/_team branches.
  v_self_ok := true;

  SELECT count(*) INTO v_team
  FROM   project_members pm
  WHERE  pm.project_id = p_project_id
    AND  pm.effective_from <= CURRENT_DATE
    AND  (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE);

  v_detail :=
       format(E'Project: %s\n', COALESCE(v_project, '—'))
    || format(E'Runs: %s to %s\n', COALESCE(to_char(v_start, 'DD Mon YYYY'), '—'),
                                   COALESCE(to_char(v_end,   'DD Mon YYYY'), '—'))
    || format(E'Team: %s current member%s\n', v_team, CASE WHEN v_team = 1 THEN '' ELSE 's' END)
    || format(E'Budget: %s\n', CASE WHEN v_budget IS NULL THEN 'Not set'
                                    ELSE trim(trailing '.' from trim(to_char(v_budget, 'FM999999D99'))) || ' h' END)
    || format(E'Previous lead: %s\n', COALESCE(v_old_name, 'None'));

  v_payload := jsonb_build_object(
    'project',       COALESCE(v_project, 'a project'),
    'project_start', COALESCE(to_char(v_start, 'DD Mon YYYY'), '—'),
    'project_end',   COALESCE(to_char(v_end,   'DD Mon YYYY'), '—'),
    'lead',          COALESCE(v_new_name, 'nobody'),
    'lead_code',     COALESCE(v_new_code, '—'),
    'previous_lead', COALESCE(v_old_name, 'nobody'),
    'actor',         COALESCE(v_actor, 'an administrator'),
    'team_size',     v_team::text,
    'budget',        CASE WHEN v_budget IS NULL THEN 'Not set'
                          ELSE trim(trailing '.' from trim(to_char(v_budget, 'FM999999D99'))) || ' h' END,
    'detail',        v_detail);

  -- ── the incoming lead — about THEM, so the actor rule does not apply ──────
  IF p_new_lead IS NOT NULL THEN
    SELECT pr.id INTO v_prof FROM profiles pr WHERE pr.employee_id = p_new_lead;
    IF v_prof IS NOT NULL AND NOT (v_prof = ANY (v_targets)) THEN
      f_title := format('You are now the lead on %s', COALESCE(v_project, 'a project'));
      f_body  := format(E'%s made you the Reporting Manager on %s.\n\n%s\nYou can staff the '
                        'project and see the hours booked to it from My Projects.',
                        COALESCE(v_actor, 'An administrator'), COALESCE(v_project, 'a project'), v_detail);
      v_tpl := render_notification_template('project.lead_assigned_self', v_payload);
      IF v_tpl IS NOT NULL THEN
        f_title := v_tpl->>'title'; f_body := v_tpl->>'body'; v_used_tpl := true;
      END IF;
      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (v_prof, f_title, f_body, '/my-projects');
      v_sent := v_sent + 1; v_targets := v_targets || v_prof;
    END IF;

    SELECT pr.id INTO v_prof
    FROM   employees e JOIN profiles pr ON pr.employee_id = e.manager_id
    WHERE  e.id = p_new_lead;
    IF v_prof IS NOT NULL AND NOT (v_prof = ANY (v_targets))
       AND v_prof IS DISTINCT FROM v_actor_prof THEN
      f_title := format('%s now leads %s', COALESCE(v_new_name, 'Someone'), COALESCE(v_project, 'a project'));
      f_body  := format(E'%s was made Reporting Manager on %s by %s.\n\n%s',
                        COALESCE(v_new_name, 'Someone'), COALESCE(v_project, 'a project'),
                        COALESCE(v_actor, 'an administrator'), v_detail);
      v_tpl := render_notification_template('project.lead_assigned_other', v_payload);
      IF v_tpl IS NOT NULL THEN
        f_title := v_tpl->>'title'; f_body := v_tpl->>'body'; v_used_tpl := true;
      END IF;
      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (v_prof, f_title, f_body, NULL);
      v_sent := v_sent + 1; v_targets := v_targets || v_prof;
    END IF;
  END IF;

  -- ── the outgoing lead — also about THEM ──────────────────────────────────
  IF p_old_lead IS NOT NULL THEN
    SELECT pr.id INTO v_prof FROM profiles pr WHERE pr.employee_id = p_old_lead;
    IF v_prof IS NOT NULL AND NOT (v_prof = ANY (v_targets)) THEN
      f_title := format('You no longer lead %s', COALESCE(v_project, 'a project'));
      f_body  := format(E'The Reporting Manager on %s is now %s. The change was made by %s.\n\n'
                        'The project has left your My Projects, and you no longer see its team '
                        'or the hours booked to it.',
                        COALESCE(v_project, 'a project'), COALESCE(v_new_name, 'nobody'),
                        COALESCE(v_actor, 'an administrator'));
      v_tpl := render_notification_template('project.lead_removed_self', v_payload);
      IF v_tpl IS NOT NULL THEN
        f_title := v_tpl->>'title'; f_body := v_tpl->>'body'; v_used_tpl := true;
      END IF;
      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (v_prof, f_title, f_body, NULL);
      v_sent := v_sent + 1; v_targets := v_targets || v_prof;
    END IF;

    SELECT pr.id INTO v_prof
    FROM   employees e JOIN profiles pr ON pr.employee_id = e.manager_id
    WHERE  e.id = p_old_lead;
    IF v_prof IS NOT NULL AND NOT (v_prof = ANY (v_targets))
       AND v_prof IS DISTINCT FROM v_actor_prof THEN
      f_title := format('%s no longer leads %s', COALESCE(v_old_name, 'Someone'), COALESCE(v_project, 'a project'));
      f_body  := format('%s is no longer the Reporting Manager on %s. The Reporting Manager is now %s, changed by %s.',
                        COALESCE(v_old_name, 'Someone'), COALESCE(v_project, 'a project'),
                        COALESCE(v_new_name, 'nobody'), COALESCE(v_actor, 'an administrator'));
      v_tpl := render_notification_template('project.lead_removed_other', v_payload);
      IF v_tpl IS NOT NULL THEN
        f_title := v_tpl->>'title'; f_body := v_tpl->>'body'; v_used_tpl := true;
      END IF;
      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (v_prof, f_title, f_body, NULL);
      v_sent := v_sent + 1; v_targets := v_targets || v_prof;
    END IF;
  END IF;

  -- ── the team, and since 799 their line managers ──────────────────────────
  -- Members hear because somebody new can see their hours. Their line managers
  -- hear for the same reason 793 tells them about every other event in that
  -- person's project life -- leaving this one out was an inconsistency.
  IF v_active THEN
    FOR r IN
      SELECT pm.employee_id,
             e.name                                              AS emp_name,
             (SELECT pr.id FROM profiles pr WHERE pr.employee_id = pm.employee_id)  AS prof,
             (SELECT pr.id FROM profiles pr WHERE pr.employee_id = e.manager_id)    AS mgr_prof
      FROM   project_members pm
      JOIN   employees e ON e.id = pm.employee_id
      WHERE  pm.project_id = p_project_id
        AND  pm.effective_from <= CURRENT_DATE
        AND  (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE)
    LOOP
      -- the member
      IF r.prof IS NOT NULL AND NOT (r.prof = ANY (v_targets))
         AND r.prof IS DISTINCT FROM v_actor_prof THEN
        f_title := format('%s is now led by %s', COALESCE(v_project, 'a project'), COALESCE(v_new_name, 'nobody'));
        f_body  := format(E'%s is now led by %s, changed by %s.\n\nThat means %s can see this '
                          'project''s team and the hours booked to it, including yours.\n\n'
                          'Nothing about your own assignment has changed.',
                          COALESCE(v_project, 'a project'), COALESCE(v_new_name, 'nobody'),
                          COALESCE(v_actor, 'an administrator'), COALESCE(v_new_name, 'The new lead'));
        v_tpl := render_notification_template('project.lead_changed_team', v_payload);
        IF v_tpl IS NOT NULL THEN
          f_title := v_tpl->>'title'; f_body := v_tpl->>'body'; v_used_tpl := true;
        END IF;
        INSERT INTO notifications (profile_id, title, body, link)
        VALUES (r.prof, f_title, f_body, '/my-timesheet');
        v_sent := v_sent + 1; v_targets := v_targets || r.prof;
      END IF;

      -- their line manager. Their own payload, because the message names the
      -- report rather than addressing them.
      IF r.mgr_prof IS NOT NULL AND NOT (r.mgr_prof = ANY (v_targets))
         AND r.mgr_prof IS DISTINCT FROM v_actor_prof THEN
        v_mgr_payload := v_payload || jsonb_build_object('employee', COALESCE(r.emp_name, 'Someone in your team'));
        f_title := format('%s is now led by %s', COALESCE(v_project, 'a project'), COALESCE(v_new_name, 'nobody'));
        f_body  := format(E'%s, which %s is on, is now led by %s, changed by %s.\n\nThat means %s '
                          'can see this project''s team and the hours booked to it, including %s''s.',
                          COALESCE(v_project, 'a project'), COALESCE(r.emp_name, 'someone in your team'),
                          COALESCE(v_new_name, 'nobody'), COALESCE(v_actor, 'an administrator'),
                          COALESCE(v_new_name, 'the new lead'), COALESCE(r.emp_name, 'their'));
        v_tpl := render_notification_template('project.lead_team_manager', v_mgr_payload);
        IF v_tpl IS NOT NULL THEN
          f_title := v_tpl->>'title'; f_body := v_tpl->>'body'; v_used_tpl := true;
        END IF;
        INSERT INTO notifications (profile_id, title, body, link)
        VALUES (r.mgr_prof, f_title, f_body, NULL);
        v_sent := v_sent + 1; v_targets := v_targets || r.mgr_prof;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('sent', v_sent, 'team_size', v_team,
                            'templated', v_used_tpl, 'self_rule', v_self_ok);
END;
$fn$;

REVOKE ALL ON FUNCTION public.notify_project_lead_change(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.notify_project_lead_change(uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.notify_project_lead_change(uuid, uuid, uuid) IS
  'Mig 797/799: announces a change of Reporting Manager to the incoming lead, '
  'the outgoing lead, both their line managers, the project''s current members '
  'and those members'' line managers. A message about the recipient''s OWN '
  'standing is sent even when they made the change; a message about somebody '
  'else is not. Wording from the project.lead_* templates, falling back to the '
  'wording built in here.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_src text; v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM workflow_notification_templates WHERE code LIKE 'project.lead_%';
  IF v_n <> 6 THEN
    RAISE EXCEPTION 'mig 799: expected 6 project.lead_* templates, found %', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM workflow_notification_templates
  WHERE code = 'project.lead_changed_team' AND body_tmpl LIKE '%including yours%';
  IF v_n <> 1 THEN
    RAISE NOTICE 'mig 799: the team template was not re-seeded -- an administrator has edited it, '
                 'which this migration deliberately leaves alone';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'notify_project_lead_change';

  -- The actor must no longer be seeded into the already-told list. That single
  -- line is what silenced somebody who made themselves the lead.
  IF position('v_targets := v_targets || v_actor_prof' in v_src) > 0 THEN
    RAISE EXCEPTION 'mig 799: the actor is still seeded into v_targets';
  END IF;

  -- ...but the two _self branches must have NO actor test, and the _other and
  -- team branches must have one. Four IS DISTINCT FROM v_actor_prof guards:
  -- incoming manager, outgoing manager, member, member's manager.
  v_n := (length(v_src) - length(replace(v_src, 'IS DISTINCT FROM v_actor_prof', '')))
         / length('IS DISTINCT FROM v_actor_prof');
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'mig 799: expected 4 actor guards on the about-somebody-else messages, found %', v_n;
  END IF;

  IF position('project.lead_team_manager' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 799: the members'' line managers are not notified';
  END IF;

  IF position('You are now the lead on %s' in v_src) = 0
     OR position('You no longer lead %s' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 799: the notifier lost its fallback wording';
  END IF;

  RAISE NOTICE 'mig 799: OK -- your own standing always reaches you, and the team''s managers hear too';
END $mig$;
