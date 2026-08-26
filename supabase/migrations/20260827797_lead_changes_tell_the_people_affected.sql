-- =============================================================================
-- Migration 797: naming a project lead tells the people it affects
--
-- THE GAP
-- ═══════
-- Setting projects.manager_id grants a persona. The named person picks up the
-- derived Project Manager role (mig 780), the project appears on their
-- My Projects, they can staff it, and its hours enter their reporting scope.
-- Today all of that happens in silence -- My Projects simply appears in the
-- nav one day.
--
-- The reverse is worse. Hand a project over and the OUTGOING lead's role is
-- revoked by the same trigger: their screen empties and their scope over that
-- team disappears, with nothing to say why. A silent revocation is the one
-- people report as a bug.
--
-- And a lead change is a visibility change for the TEAM. Somebody new can now
-- see their hours on that project. That is not an FYI -- it is the kind of
-- thing people expect to be told, and it is why the members are notified here
-- and were not in 793.
--
-- WHERE THIS HANGS, AND WHY IT IS A TRIGGER
-- ─────────────────────────────────────────
-- The four assignment events (789/793) hang off RPCs. There is no RPC for a
-- lead change: Admin -> Projects writes `UPDATE projects SET manager_id = …`
-- straight to the table through RLS. A trigger is the only hook that catches
-- every writer -- and it keeps catching them if the workflow routing in Q11 is
-- ever built, because it fires when the row actually changes, whatever path
-- got it there.
--
-- Two consequences a trigger carries that an RPC does not, both handled:
--
--   1. IT RUNS INSIDE THE CALLER'S TRANSACTION. An unhandled error here would
--      roll back the project edit. The whole body is wrapped: a notification
--      that fails leaves a WARNING in the log and the save stands.
--
--   2. IT FIRES FOR EVERY WRITER, migrations included. It fires only on a
--      genuine transition (IS DISTINCT FROM), which also stops a double-send
--      when somebody clears the field and re-sets it in two saves.
--
-- WHO IS TOLD
-- ───────────
--   the new lead          always              -> My Projects
--   their line manager    always
--   the outgoing lead     always              -- they lost something
--   their line manager    always
--   current members       when the project is active and has any
--
-- Nobody is told twice, and nobody is told about their own action.
--
-- OUT OF SCOPE, DELIBERATELY
-- ──────────────────────────
-- Deactivating a project also revokes the lead's role, and is also silent.
-- That is a project-closed event rather than a lead change -- it deserves its
-- own message to the whole team, not a lead notification as a side effect --
-- so this trigger watches manager_id only. Noted rather than smuggled in.
--
-- WORDING
-- ───────
-- Editable from the start, through mig 796's renderer. Five template codes
-- under the 'project' category:
--
--   project.lead_assigned_self     project.lead_assigned_other
--   project.lead_removed_self      project.lead_removed_other
--   project.lead_changed_team
--
-- Tokens: {{project}} {{project_start}} {{project_end}} {{lead}} {{lead_code}}
--         {{previous_lead}} {{actor}} {{team_size}} {{budget}} {{detail}}
--
-- {{lead}} reads 'nobody' when the field was cleared, so the removed and team
-- messages stay true sentences without needing a conditional a template cannot
-- express. A missing template falls back to the wording in this function, the
-- same contract 796 set.
--
-- CHANGES
-- ───────
--   notify_project_lead_change(uuid, uuid, uuid)   -- NEW
--   trg_projects_notify_lead()                     -- NEW
--   after_project_lead_notify                      -- NEW trigger
--   5 seeded templates
-- =============================================================================

SET jit = 'off';

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The templates
-- ═══════════════════════════════════════════════════════════════════════════
-- ON CONFLICT DO NOTHING: re-running must not overwrite wording an
-- administrator has edited. Same contract as 796.

INSERT INTO workflow_notification_templates (code, category, title_tmpl, body_tmpl)
VALUES
  ('project.lead_assigned_self', 'project',
   'You are now the lead on {{project}}',
   E'{{actor}} made you the Reporting Manager on {{project}}.\n\n{{detail}}\n'
   'You can staff the project and see the hours booked to it from My Projects. '
   'This does not give you access to the people on it beyond that.'),

  ('project.lead_assigned_other', 'project',
   '{{lead}} now leads {{project}}',
   E'{{lead}} was made Reporting Manager on {{project}} by {{actor}}.\n\n{{detail}}'),

  ('project.lead_removed_self', 'project',
   'You no longer lead {{project}}',
   E'The Reporting Manager on {{project}} is now {{lead}}. The change was made by {{actor}}.\n\n'
   'The project has left your My Projects, and you no longer see its team or the hours booked to it.'),

  ('project.lead_removed_other', 'project',
   '{{previous_lead}} no longer leads {{project}}',
   E'{{previous_lead}} is no longer the Reporting Manager on {{project}}. '
   'The Reporting Manager is now {{lead}}, changed by {{actor}}.'),

  ('project.lead_changed_team', 'project',
   '{{project}} is now led by {{lead}}',
   E'{{lead}} is now the Reporting Manager on {{project}}. They can see the team and '
   'the hours booked to this project.\n\nYour own assignment is unchanged.')
ON CONFLICT (code) DO NOTHING;


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. The notifier
-- ═══════════════════════════════════════════════════════════════════════════

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
  v_tpl        jsonb;
  v_prof       uuid;
  v_actor_prof uuid;
  v_targets    uuid[] := '{}';
  v_sent       int := 0;
  v_used_tpl   boolean := false;
  r            record;

  -- fallback wording, used when a template is missing or renders empty
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

  -- Nobody is told about their own action. Seeding the actor into v_targets
  -- makes that ONE rule enforced by the same dedup that stops double-sends,
  -- rather than a condition repeated at five call sites -- where an early
  -- draft of this function got it wrong, suppressing a lead's LINE MANAGER
  -- along with the lead when the lead did the handover themselves.
  SELECT pr.id INTO v_actor_prof FROM profiles pr WHERE pr.employee_id = v_actor_emp;
  IF v_actor_prof IS NOT NULL THEN
    v_targets := v_targets || v_actor_prof;
  END IF;

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

  -- ── the incoming lead ─────────────────────────────────────────────────────
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

    -- their line manager
    SELECT pr.id INTO v_prof
    FROM   employees e JOIN profiles pr ON pr.employee_id = e.manager_id
    WHERE  e.id = p_new_lead;
    IF v_prof IS NOT NULL AND NOT (v_prof = ANY (v_targets)) THEN
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

  -- ── the outgoing lead ─────────────────────────────────────────────────────
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
    IF v_prof IS NOT NULL AND NOT (v_prof = ANY (v_targets)) THEN
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

  -- ── the team ──────────────────────────────────────────────────────────────
  -- Because the incoming lead can now see their hours on this project. Current
  -- members only: somebody who has already rolled off is not mailed about a
  -- project they left, even though the new lead can see their past hours.
  -- Members only, never their line managers -- that is the multiplier that
  -- would turn one lead change into thirty messages.
  IF v_active THEN
    f_title := format('%s is now led by %s', COALESCE(v_project, 'a project'), COALESCE(v_new_name, 'nobody'));
    f_body  := format(E'%s is now the Reporting Manager on %s. They can see the team and the '
                      'hours booked to this project.\n\nYour own assignment is unchanged.',
                      COALESCE(v_new_name, 'Nobody'), COALESCE(v_project, 'a project'));
    v_tpl := render_notification_template('project.lead_changed_team', v_payload);
    IF v_tpl IS NOT NULL THEN
      f_title := v_tpl->>'title'; f_body := v_tpl->>'body'; v_used_tpl := true;
    END IF;

    FOR r IN
      SELECT DISTINCT pr.id AS prof
      FROM   project_members pm
      JOIN   profiles pr ON pr.employee_id = pm.employee_id
      WHERE  pm.project_id = p_project_id
        AND  pm.effective_from <= CURRENT_DATE
        AND  (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE)
    LOOP
      IF NOT (r.prof = ANY (v_targets)) THEN
        INSERT INTO notifications (profile_id, title, body, link)
        VALUES (r.prof, f_title, f_body, '/my-timesheet');
        v_sent := v_sent + 1; v_targets := v_targets || r.prof;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('sent', v_sent, 'team_size', v_team, 'templated', v_used_tpl);
END;
$fn$;

REVOKE ALL ON FUNCTION public.notify_project_lead_change(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.notify_project_lead_change(uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.notify_project_lead_change(uuid, uuid, uuid) IS
  'Mig 797: announces a change of Reporting Manager to the incoming lead, the '
  'outgoing lead, both their line managers, and the project''s current members '
  '-- the last because the new lead can now see their hours. Nobody is told '
  'twice and nobody is told about their own action. Wording comes from the '
  'project.lead_* templates, falling back to the wording built in here.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. The trigger
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.trg_projects_notify_lead()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_old uuid;
BEGIN
  v_old := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.manager_id END;

  -- Only a genuine transition. Guards against an UPDATE that names the column
  -- without changing it, and against a migration that rewrites the row wholesale.
  IF v_old IS NOT DISTINCT FROM NEW.manager_id THEN
    RETURN NEW;
  END IF;

  -- A project created or held inactive grants nothing, so there is nothing to
  -- announce. It will announce when it is activated with a lead in place.
  IF NEW.active IS NOT true THEN
    RETURN NEW;
  END IF;

  -- The whole point of the wrapper: this runs inside the caller's transaction,
  -- and a notification must never be able to roll back a project edit.
  BEGIN
    PERFORM notify_project_lead_change(NEW.id, v_old, NEW.manager_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_project_lead_change failed for project %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS after_project_lead_notify ON projects;

CREATE TRIGGER after_project_lead_notify
AFTER INSERT OR UPDATE OF manager_id ON projects
FOR EACH ROW
EXECUTE FUNCTION trg_projects_notify_lead();

COMMENT ON FUNCTION public.trg_projects_notify_lead() IS
  'Mig 797: fires notify_project_lead_change on a real change of manager_id. '
  'A trigger rather than an RPC because Admin -> Projects writes to the table '
  'directly, and because it keeps working if the workflow routing in Q11 is '
  'ever built. Contained: a failed notification warns and lets the save stand.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_n int; v_src text;
BEGIN
  SELECT count(*) INTO v_n FROM workflow_notification_templates
  WHERE code LIKE 'project.lead_%';
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'mig 797: expected 5 project.lead_* templates, found %', v_n;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE  c.relname = 'projects' AND t.tgname = 'after_project_lead_notify') THEN
    RAISE EXCEPTION 'mig 797: the trigger is not on projects';
  END IF;

  -- It must be narrowed to manager_id. A trigger firing on every column would
  -- re-run this work on every rename and every budget edit.
  SELECT pg_get_triggerdef(t.oid) INTO v_src
  FROM   pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  WHERE  c.relname = 'projects' AND t.tgname = 'after_project_lead_notify';
  IF position('UPDATE OF manager_id' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 797: the trigger is not narrowed to manager_id -- %', v_src;
  END IF;

  -- The containment is the load-bearing part. Without it a notification
  -- failure rolls back somebody's project edit.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'trg_projects_notify_lead';
  IF position('EXCEPTION WHEN OTHERS' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 797: the trigger does not contain a notification failure';
  END IF;
  IF position('IS NOT DISTINCT FROM NEW.manager_id' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 797: the trigger does not check for a genuine transition';
  END IF;

  -- Reads templates, and keeps its fallback.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'notify_project_lead_change';
  IF position('render_notification_template' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 797: the notifier does not consult a template';
  END IF;
  IF position('You are now the lead on %s' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 797: the notifier has no fallback wording';
  END IF;

  RAISE NOTICE 'mig 797: OK -- a lead change tells the people it affects';
END $mig$;
