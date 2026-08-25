-- =============================================================================
-- Migration 793: the notification carries the assignment, and fires on change
--
-- WHAT WAS THERE
-- ══════════════
-- Mig 789 announced an ADD, in one sentence, with no detail beyond the start
-- date. Editing an assignment and ending one said nothing at all -- so somebody
-- could have their allocation halved, their role changed or their assignment
-- ended and find out by noticing the project had gone from their timesheet.
--
-- WHAT IT SAYS NOW
-- ────────────────
-- Every message carries the whole assignment, labelled, so the recipient never
-- has to open the system to know what changed:
--
--     Project:     AMPTJ
--     Employee:    Meera R (100107)
--     Role:        EC Consultant
--     Start date:  01 Feb 2026
--     End date:    31 Dec 2026
--     Percentage:  50%
--
-- One insert into `notifications` is still both the bell and the email -- the
-- AFTER INSERT trigger on that table posts to the send-notification-email edge
-- function (mig 427035, made to actually work in 764). There is no second
-- delivery path here and there should not be.
--
-- FOUR EVENTS
-- ───────────
--   added     somebody was staffed
--   updated   role, percentage or dates changed
--   ended     the assignment was end-dated (hours exist, so it is not deleted)
--   removed   the assignment was deleted outright (no hours were ever booked)
--
-- THE ORDERING THAT MATTERS
-- ─────────────────────────
-- `removed` must be announced BEFORE the row is deleted -- afterwards there is
-- nothing left to describe, and a notification that says "an assignment was
-- removed" without saying which is worse than none. `ended` is announced after
-- the UPDATE, so the message carries the new end date rather than the old one.
--
-- WHO STILL GETS TOLD
-- ───────────────────
-- Unchanged from 789: the person, their line manager (employees.manager_id),
-- and the project lead unless they are the one doing it. Duplicates collapse;
-- anyone without a login is skipped.
--
-- CHANGES
-- ───────
--   1. notify_project_member_change(id, event)  -- NEW, carries the detail
--   2. notify_project_member_added(id)          -- becomes a wrapper, so
--                                                  project_member_add (789) is
--                                                  untouched
--   3. project_member_update()                  -- announces 'updated'
--   4. project_member_remove()                  -- 'removed' before the delete,
--                                                  'ended' after the update
-- =============================================================================

SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. One notifier, four events
-- ═══════════════════════════════════════════════════════════════════════════

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
  v_pers_name   text;
  v_pers_code   text;
  v_role        text;
  v_person_prof uuid;
  v_actor_emp   uuid;
  v_actor       text;
  v_line_prof   uuid;
  v_lead_emp    uuid;
  v_lead_prof   uuid;
  v_detail      text;
  v_verb        text;
  v_title_self  text;
  v_title_other text;
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

  SELECT p.name, p.manager_id INTO v_project, v_lead_emp
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

  -- The block every message carries. Labelled lines rather than a sentence:
  -- the recipient is checking a fact ("what is my end date now"), not reading
  -- prose, and a label they can scan for beats a paragraph they must parse.
  v_detail :=
       format(E'Project:     %s\n', COALESCE(v_project, '—'))
    || format(E'Employee:    %s (%s)\n', COALESCE(v_pers_name, '—'), COALESCE(v_pers_code, '—'))
    || format(E'Role:        %s\n', COALESCE(v_role, 'Not set'))
    || format(E'Start date:  %s\n', to_char(v_m.effective_from, 'DD Mon YYYY'))
    || format(E'End date:    %s\n', COALESCE(to_char(v_m.effective_to, 'DD Mon YYYY'), 'Open-ended'))
    || format(E'Percentage:  %s\n',
              CASE WHEN v_m.allocation_pct IS NULL THEN 'Not set'
                   ELSE trim(trailing '.' from trim(to_char(v_m.allocation_pct, 'FM999D99'))) || '%' END);

  v_verb := CASE p_event
              WHEN 'added'   THEN 'added to'
              WHEN 'updated' THEN 'changed on'
              WHEN 'ended'   THEN 'ended on'
              WHEN 'removed' THEN 'removed from'
            END;

  v_title_self := CASE p_event
    WHEN 'added'   THEN format('You are now on %s',                COALESCE(v_project, 'a project'))
    WHEN 'updated' THEN format('Your assignment on %s has changed', COALESCE(v_project, 'a project'))
    WHEN 'ended'   THEN format('Your assignment on %s has ended',   COALESCE(v_project, 'a project'))
    WHEN 'removed' THEN format('You have been removed from %s',     COALESCE(v_project, 'a project'))
  END;

  v_title_other := CASE p_event
    WHEN 'added'   THEN format('%s has joined %s',            COALESCE(v_pers_name, 'Someone'), COALESCE(v_project, 'a project'))
    WHEN 'updated' THEN format('%s''s assignment on %s changed', COALESCE(v_pers_name, 'Someone'), COALESCE(v_project, 'a project'))
    WHEN 'ended'   THEN format('%s has come off %s',          COALESCE(v_pers_name, 'Someone'), COALESCE(v_project, 'a project'))
    WHEN 'removed' THEN format('%s was removed from %s',      COALESCE(v_pers_name, 'Someone'), COALESCE(v_project, 'a project'))
  END;

  -- ── the person ────────────────────────────────────────────────────────────
  IF v_person_prof IS NOT NULL THEN
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_person_prof,
      v_title_self,
      format(E'%s %s %s by %s.\n\n%s',
             CASE p_event WHEN 'added' THEN 'You were' ELSE 'Your assignment was' END,
             v_verb, COALESCE(v_project, 'the project'),
             COALESCE(v_actor, 'a project lead'), v_detail)
      || CASE WHEN p_event IN ('added', 'updated')
              THEN E'\nRecord your time against it in My Timesheet.' ELSE '' END,
      '/my-timesheet');
    v_sent := v_sent + 1;
    v_targets := v_targets || v_person_prof;
  END IF;

  -- ── their line manager ────────────────────────────────────────────────────
  IF v_line_prof IS NOT NULL AND NOT (v_line_prof = ANY (v_targets)) THEN
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_line_prof,
      v_title_other,
      format(E'%s was %s %s by %s.\n\n%s',
             COALESCE(v_pers_name, 'Someone in your team'), v_verb,
             COALESCE(v_project, 'the project'), COALESCE(v_actor, 'a project lead'), v_detail),
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
      v_title_other,
      format(E'%s was %s %s by %s.\n\n%s',
             COALESCE(v_pers_name, 'Someone'), v_verb,
             COALESCE(v_project, 'your project'), COALESCE(v_actor, 'an administrator'), v_detail),
      '/my-projects');
    v_sent := v_sent + 1;
  END IF;

  RETURN jsonb_build_object('sent', v_sent, 'event', p_event);
END;
$fn$;

REVOKE ALL ON FUNCTION public.notify_project_member_change(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.notify_project_member_change(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.notify_project_member_change(uuid, text) IS
  'Mig 793: announces added / updated / ended / removed on a project assignment, '
  'carrying the full detail block. Writes to notifications, which already carries '
  'the email leg. ''removed'' must be called BEFORE the row is deleted.';


-- The 789 signature, kept so project_member_add needs no further surgery.
CREATE OR REPLACE FUNCTION public.notify_project_member_added(p_member_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT public.notify_project_member_change(p_member_id, 'added');
$fn$;

REVOKE ALL ON FUNCTION public.notify_project_member_added(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.notify_project_member_added(uuid) TO authenticated;

COMMENT ON FUNCTION public.notify_project_member_added(uuid) IS
  'Wrapper over notify_project_member_change(id, ''added'') since mig 793. Kept '
  'so the call inside project_member_add did not need re-patching.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Editing announces itself
-- ═══════════════════════════════════════════════════════════════════════════
-- After the UPDATE, so the message carries what it now says rather than what it
-- used to. Wrapped and reported, for the reason 764 taught: a silently
-- swallowed notification failure is indistinguishable from a design choice.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a1 text := E'  RETURN jsonb_build_object(''ok'', true, ''id'', p_id,';
  r1 text := E'  BEGIN\n'
          || E'    v_notify := notify_project_member_change(p_id, ''updated'');\n'
          || E'  EXCEPTION WHEN OTHERS THEN\n'
          || E'    v_notify := jsonb_build_object(''sent'', 0, ''error'', SQLERRM);\n'
          || E'  END;\n'
          || E'\n'
          || E'  RETURN jsonb_build_object(''ok'', true, ''id'', p_id,\n'
          || E'    ''notified'', COALESCE((v_notify->>''sent'')::int, 0),\n'
          || E'    ''notify_error'', v_notify->>''error'',';

  a2 text := E'  v_hit   jsonb;\n';
  r2 text := E'  v_hit   jsonb;\n  v_notify jsonb;\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_update';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 793: project_member_update not found';
  END IF;

  IF position('notify_project_member_change' in v_src) > 0 THEN
    RAISE NOTICE 'mig 793: project_member_update already announces itself -- skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a2, ''))) / NULLIF(length(a2), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 793: update DECLARE anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a2, r2);

  v_hits := (length(v_new) - length(replace(v_new, a1, ''))) / NULLIF(length(a1), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 793: update RETURN anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a1, r1);

  EXECUTE v_new;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Ending and removing announce themselves
-- ═══════════════════════════════════════════════════════════════════════════
-- Two call sites in one function, and the ORDER is the whole point:
--
--   removed -> notify FIRST. After the DELETE there is no row to describe, and
--              "an assignment was removed" without saying which is worse than
--              silence.
--   ended   -> notify AFTER the UPDATE, so the end date in the message is the
--              new one.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a_del text := E'    DELETE FROM project_members WHERE id = p_id;\n'
             || E'    RETURN jsonb_build_object(''ok'', true, ''action'', ''deleted'');';
  r_del text := E'    -- Announced BEFORE the delete: afterwards there is nothing to describe.\n'
             || E'    BEGIN\n'
             || E'      v_notify := notify_project_member_change(p_id, ''removed'');\n'
             || E'    EXCEPTION WHEN OTHERS THEN\n'
             || E'      v_notify := jsonb_build_object(''sent'', 0, ''error'', SQLERRM);\n'
             || E'    END;\n'
             || E'\n'
             || E'    DELETE FROM project_members WHERE id = p_id;\n'
             || E'    RETURN jsonb_build_object(''ok'', true, ''action'', ''deleted'',\n'
             || E'      ''notified'', COALESCE((v_notify->>''sent'')::int, 0),\n'
             || E'      ''notify_error'', v_notify->>''error'');';

  a_end text := E'  RETURN jsonb_build_object(''ok'', true, ''action'', ''ended'', ''effective_to'', v_end);';
  r_end text := E'  -- Announced AFTER the update, so the end date quoted is the new one.\n'
             || E'  BEGIN\n'
             || E'    v_notify := notify_project_member_change(p_id, ''ended'');\n'
             || E'  EXCEPTION WHEN OTHERS THEN\n'
             || E'    v_notify := jsonb_build_object(''sent'', 0, ''error'', SQLERRM);\n'
             || E'  END;\n'
             || E'\n'
             || E'  RETURN jsonb_build_object(''ok'', true, ''action'', ''ended'', ''effective_to'', v_end,\n'
             || E'    ''notified'', COALESCE((v_notify->>''sent'')::int, 0),\n'
             || E'    ''notify_error'', v_notify->>''error'');';

  a_dec text := E'  v_end       date;\n';
  r_dec text := E'  v_end       date;\n  v_notify    jsonb;\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_remove';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 793: project_member_remove not found';
  END IF;

  IF position('notify_project_member_change' in v_src) > 0 THEN
    RAISE NOTICE 'mig 793: project_member_remove already announces itself -- skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_dec, ''))) / NULLIF(length(a_dec), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 793: remove DECLARE anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a_dec, r_dec);

  v_hits := (length(v_new) - length(replace(v_new, a_del, ''))) / NULLIF(length(a_del), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 793: remove DELETE anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_del, r_del);

  v_hits := (length(v_new) - length(replace(v_new, a_end, ''))) / NULLIF(length(a_end), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 793: remove END anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_end, r_end);

  EXECUTE v_new;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['project_member_update', 'project_member_remove'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_fn
        AND pg_get_functiondef(p.oid) LIKE '%notify_project_member_change%') THEN
      RAISE EXCEPTION 'mig 793: %() does not announce its change', v_fn;
    END IF;
  END LOOP;

  -- The removal must be announced before the row goes, or it says nothing useful.
  IF (SELECT position('notify_project_member_change(p_id, ''removed'')' in pg_get_functiondef(p.oid))
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'project_member_remove')
     > (SELECT position('DELETE FROM project_members' in pg_get_functiondef(p.oid))
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'project_member_remove')
  THEN
    RAISE EXCEPTION 'mig 793: the removal is announced after the DELETE -- nothing left to describe';
  END IF;

  RAISE NOTICE 'mig 793: OK -- every assignment change is announced, with its detail';
END $mig$;
