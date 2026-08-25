-- =============================================================================
-- Migration 791: Team Allocation gets its own module and four real verbs
--
-- WHAT WAS WRONG WITH ONE VERB
-- ════════════════════════════
-- Staffing was governed by a single non-standard permission,
-- projects_mgmt.manage_members, which the Permission Matrix could only render
-- by ALIASING it into the View column of an indented sub-row. One tick meant
-- see the team, add people, change their dates and end their assignments -- four
-- decisions an administrator had no way to separate.
--
-- It could not simply become four verbs, either: projects_mgmt already spends
-- view/create/edit/delete on the PROJECT RECORD itself. So this is a module of
-- its own.
--
--   project_members.view     see who is on the team
--   project_members.create   add somebody
--   project_members.edit     change role, percentage or dates
--   project_members.delete   end an assignment
--
-- ON "DELETE"
-- ───────────
-- It end-dates when hours exist -- project_members has deliberately never had a
-- DELETE policy. The verb names the INTENT, not the storage. Said plainly here
-- because a permission called delete that does not delete is exactly the kind
-- of thing an auditor asks about.
--
-- NOBODY LOSES ACCESS
-- ───────────────────
-- Every permission set that holds manage_members today receives all four new
-- permissions, and the old verb keeps working. A migration that splits one
-- grant into four and leaves somebody locked out of a screen they had this
-- morning is a bad migration however correct the model is.
--
-- THE BACKSTOP GETS TIGHTER, NOT LOOSER
-- ─────────────────────────────────────
-- The RLS policies on project_members used my_staffable_projects(), which now
-- gates on `view`. Left alone, somebody with view-only could INSERT straight
-- through PostgREST -- weaker than what they replace. So the write policies now
-- ask can_staff_project(project, 'create'|'edit') instead. The RPCs remain the
-- front door; this is the door behind it.
--
-- CHANGES
-- ───────
--   1. modules + permissions          -- project_members, four verbs
--   2. grant migration                -- manage_members holders get all four
--   3. can_staff_project(id, action)  -- one gate, per verb
--   4. the four RPCs                  -- each asks for the verb it performs
--   5. my_staffable_projects[_detail] -- gate on view
--   6. RLS write policies             -- per-verb
--
-- NOT CHANGED
-- ───────────
--   projects_mgmt.edit still short-circuits everything -- the admin door.
--   No report, no timesheet function, no notification.
-- =============================================================================

SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The module and its verbs
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO modules (code, name, active, sort_order)
VALUES ('project_members', 'Team Allocation', true, 26)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order, active = true;

INSERT INTO permissions (code, name, description, module_id, action)
SELECT 'project_members.' || v.act,
       initcap(v.act) || ' Team Allocation',
       v.descr,
       m.id,
       v.act
FROM   modules m
CROSS  JOIN (VALUES
  ('view',   'See who is on a project team'),
  ('create', 'Add somebody to a project team'),
  ('edit',   'Change a team member''s role, percentage or dates'),
  ('delete', 'End a team assignment (end-dated when hours exist)')
) AS v(act, descr)
WHERE  m.code = 'project_members'
ON CONFLICT (code) DO NOTHING;


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Carry the existing grants across
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_n int;
BEGIN
  INSERT INTO permission_set_items (permission_set_id, permission_id)
  SELECT DISTINCT psi.permission_set_id, np.id
  FROM   permission_set_items psi
  JOIN   permissions op ON op.id = psi.permission_id
  CROSS  JOIN permissions np
  WHERE  op.code = 'projects_mgmt.manage_members'
    AND  np.code IN ('project_members.view', 'project_members.create',
                     'project_members.edit', 'project_members.delete')
    AND  NOT EXISTS (SELECT 1 FROM permission_set_items x
                     WHERE x.permission_set_id = psi.permission_set_id
                       AND x.permission_id     = np.id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'mig 791: % grant(s) carried across from manage_members.', v_n;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. One gate, asked per verb
-- ═══════════════════════════════════════════════════════════════════════════
-- The one-argument form is DROPPED rather than kept beside this: two overloads
-- where one has a default makes every single-argument call a resolution puzzle,
-- and every existing caller lands on this function with p_action defaulting to
-- the safest of the four.

DROP FUNCTION IF EXISTS public.can_staff_project(uuid);

CREATE OR REPLACE FUNCTION public.can_staff_project(
  p_project_id uuid,
  p_action     text DEFAULT 'edit'
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_me uuid;
BEGIN
  IF p_project_id IS NULL THEN RETURN false; END IF;
  IF is_super_admin() THEN RETURN true; END IF;

  -- The admin door: whoever may edit projects may also staff them, on any
  -- project, active or closed. Unchanged since mig 774.
  IF user_can('projects_mgmt', 'edit', NULL) THEN RETURN true; END IF;

  IF p_action NOT IN ('view', 'create', 'edit', 'delete') THEN
    RAISE EXCEPTION 'can_staff_project: unknown action %', p_action;
  END IF;

  -- The lead door: the verb, AND this project naming them as Reporting
  -- Manager, AND the project still being active (mig 784).
  IF NOT (user_can('project_members', p_action, NULL)
          OR user_can('projects_mgmt', 'manage_members', NULL)) THEN
    RETURN false;
  END IF;

  v_me := get_my_employee_id();
  IF v_me IS NULL THEN RETURN false; END IF;

  RETURN EXISTS (
    SELECT 1 FROM projects p
    WHERE  p.id = p_project_id AND p.manager_id = v_me AND p.active = true
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.can_staff_project(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_staff_project(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.can_staff_project(uuid, text) IS
  'Mig 791: may this caller perform p_action on this project''s team. Super '
  'admin, or projects_mgmt.edit (the admin door, any project), or the matching '
  'project_members verb plus being the active project''s Reporting Manager. '
  'projects_mgmt.manage_members is still honoured while grants migrate.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Each RPC asks for the verb it performs
-- ═══════════════════════════════════════════════════════════════════════════
-- Patched in place from the LIVE bodies: 788, 789 and 790 have all edited these,
-- and a body retyped from the migration files would silently revert them.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;
  v_fn   text;
  v_verb text;
  v_pair text[][] := ARRAY[
    ARRAY['my_project_members',     'view'],
    ARRAY['project_member_add',     'create'],
    ARRAY['project_member_update',  'edit'],
    ARRAY['project_member_remove',  'delete']
  ];
  i int;
  a_txt text;
  r_txt text;
BEGIN
  FOR i IN 1 .. array_length(v_pair, 1) LOOP
    v_fn   := v_pair[i][1];
    v_verb := v_pair[i][2];

    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'mig 791: %() not found', v_fn;
    END IF;

    IF position('can_staff_project(' || quote_literal(v_verb) in v_src) > 0
       OR position(', ''' || v_verb || '''' in v_src) > 0 THEN
      RAISE NOTICE 'mig 791: %() already asks for %', v_fn, v_verb;
      CONTINUE;
    END IF;

    -- Every one of them opens with the same call, on either p_project_id or
    -- the row it just loaded.
    IF position('can_staff_project(p_project_id)' in v_src) > 0 THEN
      a_txt := 'can_staff_project(p_project_id)';
      r_txt := 'can_staff_project(p_project_id, ' || quote_literal(v_verb) || ')';
    ELSIF position('can_staff_project(v_row.project_id)' in v_src) > 0 THEN
      a_txt := 'can_staff_project(v_row.project_id)';
      r_txt := 'can_staff_project(v_row.project_id, ' || quote_literal(v_verb) || ')';
    ELSE
      RAISE EXCEPTION 'mig 791: %() does not call can_staff_project the way this expects', v_fn;
    END IF;

    v_hits := (length(v_src) - length(replace(v_src, a_txt, ''))) / NULLIF(length(a_txt), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 791: %() gate anchor matched % times, expected 1', v_fn, v_hits;
    END IF;

    v_new := replace(v_src, a_txt, r_txt);
    EXECUTE v_new;
    RAISE NOTICE 'mig 791: %() now asks for %', v_fn, v_verb;
  END LOOP;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Seeing the project list is a `view` question
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;
  v_fn   text;
  a_txt  text := 'IF NOT user_can(''projects_mgmt'', ''manage_members'', NULL) THEN';
  r_txt  text := 'IF NOT (user_can(''project_members'', ''view'', NULL)' || E'\n'
              || '          OR user_can(''projects_mgmt'', ''manage_members'', NULL)) THEN';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['my_staffable_projects', 'my_staffable_projects_detail'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'mig 791: %() not found', v_fn;
    END IF;

    IF position('project_members'', ''view''' in v_src) > 0 THEN
      RAISE NOTICE 'mig 791: %() already gates on the view verb', v_fn;
      CONTINUE;
    END IF;

    v_hits := (length(v_src) - length(replace(v_src, a_txt, ''))) / NULLIF(length(a_txt), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 791: %() gate anchor matched % times, expected 1', v_fn, v_hits;
    END IF;

    v_new := replace(v_src, a_txt, r_txt);
    EXECUTE v_new;
  END LOOP;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 6. The backstop, per verb
-- ═══════════════════════════════════════════════════════════════════════════
-- USING *and* WITH CHECK on the update, both -- with USING alone a lead could
-- take a row on their own project and rewrite project_id to somebody else's.
-- Mig 773 said so; it stays true here.

DROP POLICY IF EXISTS project_members_insert ON public.project_members;
CREATE POLICY project_members_insert ON public.project_members FOR INSERT
  WITH CHECK (
    is_super_admin()
    OR can_staff_project(project_id, 'create')
  );

DROP POLICY IF EXISTS project_members_update ON public.project_members;
CREATE POLICY project_members_update ON public.project_members FOR UPDATE
  USING (
    is_super_admin()
    OR can_staff_project(project_id, 'edit')
    OR can_staff_project(project_id, 'delete')
  )
  WITH CHECK (
    is_super_admin()
    OR can_staff_project(project_id, 'edit')
    OR can_staff_project(project_id, 'delete')
  );

-- Select keeps its wider shape: a project admin, a lead who may view the team,
-- or the employee reading their OWN assignments. That last arm is why an
-- ordinary employee can see which projects they are on.
DROP POLICY IF EXISTS project_members_select ON public.project_members;
CREATE POLICY project_members_select ON public.project_members FOR SELECT
  USING (
    is_super_admin()
    OR user_can('projects_mgmt', 'view', NULL)
    OR project_id IN (SELECT project_id FROM my_staffable_projects())
    OR employee_id = get_my_employee_id()
  );


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM permissions WHERE code LIKE 'project_members.%';
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'mig 791: expected 4 project_members permissions, found %', v_n;
  END IF;

  -- Nobody may be left holding the old verb without the new ones.
  SELECT count(*) INTO v_n
  FROM   permission_set_items psi
  JOIN   permissions op ON op.id = psi.permission_id AND op.code = 'projects_mgmt.manage_members'
  WHERE  NOT EXISTS (
    SELECT 1 FROM permission_set_items x
    JOIN   permissions np ON np.id = x.permission_id
    WHERE  x.permission_set_id = psi.permission_set_id AND np.code = 'project_members.create');
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig 791: % permission set(s) kept the old verb without the new ones', v_n;
  END IF;

  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'can_staff_project') <> 1 THEN
    RAISE EXCEPTION 'mig 791: can_staff_project has more than one overload';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_remove'
      AND pg_get_functiondef(p.oid) LIKE '%''delete''%') THEN
    RAISE EXCEPTION 'mig 791: project_member_remove does not ask for delete';
  END IF;

  RAISE NOTICE 'mig 791: OK -- Team Allocation has four verbs';
END $mig$;
