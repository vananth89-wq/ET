-- =============================================================================
-- Migration 789: tell people when they are put on a project
--
-- WHAT HAPPENS NOW
-- ════════════════
-- project_member_add() inserts a row and returns. The person staffed onto the
-- project finds out by opening their timesheet and noticing a new option, and
-- their line manager finds out never.
--
-- HOW THIS DELIVERS BOTH IN-APP AND EMAIL WITHOUT AN EMAIL PATH
-- ─────────────────────────────────────────────────────────────
-- It writes to `notifications` and stops. There is already an AFTER INSERT
-- trigger on that table (mig 427035, made to actually work in 764) which posts
-- to the send-notification-email edge function. One insert is a bell and an
-- email. Building a second delivery route here would be duplicating a leg that
-- exists and is monitored.
--
-- WHY NOT workflow_notification_queue
-- ───────────────────────────────────
-- Its instance_id is NOT NULL REFERENCES workflow_instances(id), and staffing
-- somebody onto a project has no workflow instance behind it. notify_delegation
-- _created() (mig 428041) hit the same wall for the same reason and solved it
-- the same way: a SECURITY DEFINER function writing straight to `notifications`.
-- This follows that precedent rather than inventing a third pattern.
--
-- WHO GETS TOLD
-- ─────────────
--   the person added        always, if they have a login
--   their line manager      employees.manager_id -- NOT the project's manager
--   the project lead        projects.manager_id, UNLESS they are the one doing
--                           the adding, which is the normal case. Telling
--                           somebody what they just did is noise, and noise is
--                           how people learn to ignore a notification channel.
--
-- Duplicates collapse: if the line manager IS the project lead, they get one
-- message, not two. Anybody without a linked profile is skipped silently --
-- there is nowhere to deliver to, and it is not an error.
--
-- FAILURE
-- ───────
-- A notification must never roll back a successful staffing. But 764's lesson
-- was that swallowing an exception WITHOUT A TRACE turns a total failure into
-- something indistinguishable from a design choice -- 112 rows on Dev sat that
-- way for months. So the call is wrapped, and the outcome is reported back in
-- project_member_add()'s envelope: `notified` counts who was told, and
-- `notify_error` names what went wrong. The lead sees it on the screen where
-- they did the thing.
--
-- CHANGES
-- ───────
--   1. notify_project_member_added(member_id)  -- NEW
--   2. project_member_add()                    -- calls it, reports the outcome
--
-- NOT CHANGED
-- ───────────
--   project_member_remove / _update -- leaving a project is not announced.
--   The notifications table, its trigger, the edge function, any template.
-- =============================================================================

SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The notifier
-- ═══════════════════════════════════════════════════════════════════════════
-- SECURITY DEFINER: `notifications` has no INSERT policy at all -- by design,
-- only definer-rights code writes to it (mig 425011).

CREATE OR REPLACE FUNCTION public.notify_project_member_added(p_member_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_m           project_members%ROWTYPE;
  v_project     text;
  v_person      text;
  v_person_prof uuid;
  v_actor_emp   uuid;
  v_actor       text;
  v_line_prof   uuid;
  v_lead_emp    uuid;
  v_lead_prof   uuid;
  v_when        text;
  v_alloc       text;
  v_sent        int := 0;
  v_targets     uuid[] := '{}';
BEGIN
  SELECT * INTO v_m FROM project_members WHERE id = p_member_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('sent', 0, 'reason', 'member row not found');
  END IF;

  SELECT p.name, p.manager_id INTO v_project, v_lead_emp
  FROM   projects p WHERE p.id = v_m.project_id;

  SELECT e.name INTO v_person FROM employees e WHERE e.id = v_m.employee_id;

  v_actor_emp := get_my_employee_id();
  SELECT e.name INTO v_actor FROM employees e WHERE e.id = v_actor_emp;

  -- Profiles, because a notification is addressed to a login and not everybody
  -- has one. A missing profile is a skip, not a failure.
  SELECT pr.id INTO v_person_prof FROM profiles pr WHERE pr.employee_id = v_m.employee_id;

  SELECT pr.id INTO v_line_prof
  FROM   employees e
  JOIN   profiles  pr ON pr.employee_id = e.manager_id
  WHERE  e.id = v_m.employee_id;

  IF v_lead_emp IS NOT NULL THEN
    SELECT pr.id INTO v_lead_prof FROM profiles pr WHERE pr.employee_id = v_lead_emp;
  END IF;

  v_when  := to_char(v_m.effective_from, 'DD Mon YYYY');
  -- trim the trailing separator: to_char(50, 'FM999D99') is '50.', and "at 50.%
  -- of your time" is the kind of detail that makes a message look machine-made.
  v_alloc := CASE WHEN v_m.allocation_pct IS NULL THEN ''
                  ELSE format(', at %s%% of their time',
                              trim(trailing '.' from trim(to_char(v_m.allocation_pct, 'FM999D99')))) END;

  -- ── the person staffed ────────────────────────────────────────────────────
  IF v_person_prof IS NOT NULL THEN
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_person_prof,
      format('You are now on %s', COALESCE(v_project, 'a project')),
      format('%s added you to %s from %s%s. You can record time against it in My Timesheet.',
             COALESCE(v_actor, 'A project lead'), COALESCE(v_project, 'the project'), v_when,
             replace(v_alloc, 'their time', 'your time')),
      '/my-timesheet');
    v_sent := v_sent + 1;
    v_targets := v_targets || v_person_prof;
  END IF;

  -- ── their line manager (employees.manager_id) ─────────────────────────────
  IF v_line_prof IS NOT NULL AND NOT (v_line_prof = ANY (v_targets)) THEN
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_line_prof,
      format('%s has joined %s', COALESCE(v_person, 'Someone in your team'), COALESCE(v_project, 'a project')),
      format('%s added %s to %s from %s%s.',
             COALESCE(v_actor, 'A project lead'), COALESCE(v_person, 'they'),
             COALESCE(v_project, 'the project'), v_when, v_alloc),
      NULL);
    v_sent := v_sent + 1;
    v_targets := v_targets || v_line_prof;
  END IF;

  -- ── the project lead, unless they did it themselves ───────────────────────
  IF v_lead_prof IS NOT NULL
     AND NOT (v_lead_prof = ANY (v_targets))
     AND v_lead_emp IS DISTINCT FROM v_actor_emp THEN
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_lead_prof,
      format('%s added to %s', COALESCE(v_person, 'Someone'), COALESCE(v_project, 'your project')),
      format('%s added %s to %s from %s%s.',
             COALESCE(v_actor, 'An administrator'), COALESCE(v_person, 'they'),
             COALESCE(v_project, 'the project'), v_when, v_alloc),
      '/my-projects');
    v_sent := v_sent + 1;
  END IF;

  RETURN jsonb_build_object('sent', v_sent);
END;
$fn$;

REVOKE ALL ON FUNCTION public.notify_project_member_added(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.notify_project_member_added(uuid) TO authenticated;

COMMENT ON FUNCTION public.notify_project_member_added(uuid) IS
  'Mig 789: tells the person staffed, their line manager (employees.manager_id) '
  'and the project lead (projects.manager_id, unless they are the actor) that a '
  'project assignment was made. Writes to notifications, which already carries '
  'the email leg via its AFTER INSERT trigger. Recipients without a linked '
  'profile are skipped; duplicates collapse. Returns {sent}.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Call it from the add, and say what happened
-- ═══════════════════════════════════════════════════════════════════════════
-- Inside project_member_add() rather than as a second call from the screen --
-- the delegation precedent calls its notifier from the frontend, which means a
-- notification is skipped whenever anything else adds a member. Here it cannot
-- be skipped.
--
-- Patched in place. 774 is the last file in this repo that defines this
-- function, which is not a promise about what is running on the server.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a1 text := E'  RETURN jsonb_build_object(''ok'', true, ''id'', v_id);';

  r1 text := E'  -- Mig 789: in-app + email to the person, their line manager and the\n'
          || E'  -- project lead. Wrapped, because a notification must never roll back a\n'
          || E'  -- staffing that succeeded -- and reported, because 764 showed that a\n'
          || E'  -- silently swallowed failure looks exactly like a design choice.\n'
          || E'  BEGIN\n'
          || E'    v_notify := notify_project_member_added(v_id);\n'
          || E'  EXCEPTION WHEN OTHERS THEN\n'
          || E'    v_notify := jsonb_build_object(''sent'', 0, ''error'', SQLERRM);\n'
          || E'  END;\n'
          || E'\n'
          || E'  RETURN jsonb_build_object(''ok'', true, ''id'', v_id,\n'
          || E'    ''notified'', COALESCE((v_notify->>''sent'')::int, 0),\n'
          || E'    ''notify_error'', v_notify->>''error'');';

  a2 text := E'  v_id uuid;\n';
  r2 text := E'  v_id uuid;\n  v_notify jsonb;\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_add';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 789: project_member_add not found';
  END IF;

  IF position('notify_project_member_added' in v_src) > 0 THEN
    RAISE NOTICE 'mig 789: project_member_add already notifies -- skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a2, ''))) / NULLIF(length(a2), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 789: declare anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a2, r2);

  v_hits := (length(v_new) - length(replace(v_new, a1, ''))) / NULLIF(length(a1), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 789: return anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a1, r1);

  EXECUTE v_new;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_add'
      AND pg_get_functiondef(p.oid) LIKE '%notify_project_member_added%'
  ) THEN
    RAISE EXCEPTION 'mig 789: project_member_add does not notify';
  END IF;

  -- The email leg this relies on must actually be attached, or "and email" is
  -- a claim rather than a fact.
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'notifications' AND NOT t.tgisinternal
  ) THEN
    RAISE WARNING 'mig 789: no trigger on notifications -- in-app will work, email will not';
  END IF;

  RAISE NOTICE 'mig 789: OK -- project assignments are announced';
END $mig$;
