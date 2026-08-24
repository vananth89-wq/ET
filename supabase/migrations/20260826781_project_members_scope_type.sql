-- =============================================================================
-- Migration 781: `Project Members` — a new target group scope type
--
-- PIECE 2 of 3 (see docs/project-manager-persona-design.md)
--
-- WHAT THIS DOES
-- ══════════════
-- Adds a relational target group that resolves live, with nobody's name in it:
--
--     in scope  <=>  you are a CURRENT member of a project whose
--                    Reporting Manager is me
--
-- Membership comes from project_members, so adding someone to a project puts
-- them in the lead's scope on the lead's very next request -- no sync job, no
-- cache, no delay.  Removing them revokes it just as fast.
--
-- Structurally this is migration 20260605500 (which added `hierarchy`) with a
-- different WHERE: widen the CHECK, seed the group, one branch in user_can(),
-- one matching branch in get_target_population(), cache deliberately untouched.
--
-- WHAT "CURRENT" MEANS, AND WHY
-- ─────────────────────────────
-- Both branches resolve membership as of CURRENT_DATE.  That is right for an
-- access check -- user_can() answers "may I open this record right now", which
-- is a question about now.
--
-- The REPORTS deliberately do not use this scope (Piece 3).  A report that
-- asked "was Meera a member in March" would answer differently in April than in
-- July, and the same March total would drift.  Reports key off the project the
-- hour was booked to instead, which has one true answer forever.  See §3.3a of
-- the design doc -- this is the single most important decision in it.
--
-- CHANGES
-- ───────
--   1. target_groups scope_type CHECK  -- add 'project_members'
--   2. INSERT the system target group
--   3. PATCH user_can()                -- Path D, one OR branch, anchored
--   4. PATCH get_target_population()   -- one UNION branch, anchored
--
-- NOT CHANGED
-- ───────────
--   sync_target_group_members()  -- caller-dependent, resolves live, like
--                                   hierarchy / direct_l1 / same_department
--   Any RLS policy               -- they call user_can(), so they inherit this
--   Any report function          -- Piece 3, and see the note above
--   Every existing scope branch  -- patched around, never rewritten
-- =============================================================================

SET jit = 'off';


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Widen the scope_type allow-list
-- ─────────────────────────────────────────────────────────────────────────────
-- Same dynamic-name dance as mig 500: the original constraint was inline and
-- auto-named, so find it rather than assume what it is called.

DO $mig$
DECLARE
  v_constraint_name text;
BEGIN
  SELECT conname INTO v_constraint_name
  FROM   pg_constraint
  WHERE  conrelid = 'target_groups'::regclass
    AND  contype  = 'c'
    AND  pg_get_constraintdef(oid) LIKE '%scope_type%';

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE target_groups DROP CONSTRAINT %I', v_constraint_name);
  END IF;
END $mig$;

ALTER TABLE target_groups
  ADD CONSTRAINT target_groups_scope_type_check
  CHECK (scope_type IN (
    'self',
    'everyone',
    'direct_l1',
    'direct_l2',
    'hierarchy',
    'same_department',
    'same_country',
    'project_members',
    'custom'
  ));


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Seed the system target group
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO target_groups (code, label, scope_type, is_system)
VALUES ('project_members', 'Project Members', 'project_members', true)
ON CONFLICT (code) DO UPDATE
  SET label      = EXCLUDED.label,
      scope_type = EXCLUDED.scope_type,
      is_system  = EXCLUDED.is_system;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. user_can() — one new branch in Path D
-- ─────────────────────────────────────────────────────────────────────────────
-- Patched in place, not replaced wholesale.  Migration 500 is the last file in
-- this repo that defines user_can(), but that is not a promise about what is
-- running on the server, and this function is on the hot path of every RLS
-- policy in the product.  Read the live body, substitute once, assert, abort on
-- surprise.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  -- The close of the big OR chain, immediately before it is assigned.
  a1 text := E'\n      )\n  ) INTO v_result;';

  r1 text := E'\n'
    || '        -- ── project_members — staffed today on a project I manage ─────────' || E'\n'
    || '        -- Membership is read live from project_members, so the lead never' || E'\n'
    || '        -- maintains a list. CURRENT_DATE, because "may I open this record"' || E'\n'
    || '        -- is a question about now. Reports do NOT use this branch.' || E'\n'
    || '        OR (' || E'\n'
    || '          tg.scope_type = ''project_members''' || E'\n'
    || '          AND EXISTS (' || E'\n'
    || '            SELECT 1' || E'\n'
    || '            FROM   project_members pm' || E'\n'
    || '            JOIN   projects        pr ON pr.id = pm.project_id' || E'\n'
    || '            JOIN   employees       e  ON e.id  = pm.employee_id' || E'\n'
    || '            WHERE  pm.employee_id    = p_owner' || E'\n'
    || '              AND  pr.manager_id     = v_employee_id' || E'\n'
    || '              AND  pr.active         = true' || E'\n'
    || '              AND  e.deleted_at      IS NULL' || E'\n'
    || '              AND  pm.effective_from <= CURRENT_DATE' || E'\n'
    || '              AND  (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE)' || E'\n'
    || '          )' || E'\n'
    || '        )' || E'\n'
    || E'\n      )\n  ) INTO v_result;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'user_can'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_module text, p_action text, p_owner uuid';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 781: user_can(text,text,uuid) not found -- refusing to guess at its shape';
  END IF;

  IF position('project_members' in v_src) > 0 THEN
    RAISE NOTICE 'mig 781: user_can already carries the project_members branch -- skipping patch';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a1, ''))) / NULLIF(length(a1), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 781: user_can anchor matched % times, expected 1', v_hits;
  END IF;

  v_new := replace(v_src, a1, r1);
  EXECUTE v_new;
END $mig$;

COMMENT ON FUNCTION user_can(text, text, uuid) IS
  'Row-level permission check — three paths only. '
  'Path A: is_super_admin() — UUID allowlist bypass. '
  'Path B: p_owner=NULL — admin module, no target scoping. '
  'Path D: scope_type-aware — self/everyone/custom/direct_l1/direct_l2/hierarchy/'
  'dept/country/project_members. '
  'hierarchy: recursive CTE walks full org tree downward from caller. '
  'project_members: current members of projects where caller is Reporting Manager. '
  'include_self=false on psa excludes the holder from their own record. '
  'No implicit self-bypass (Path C removed in mig 114).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. get_target_population() — the matching UNION branch
-- ─────────────────────────────────────────────────────────────────────────────
-- Must agree with user_can() exactly. Where the two disagree you get a screen
-- that lists a row the RLS policy then refuses to open, which reads as a bug in
-- whichever screen the user happened to be on.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a1 text := E'\n  )\n  SELECT array_agg(DISTINCT emp_id) INTO v_ids FROM resolved;';

  r1 text := E'\n'
    || '    UNION' || E'\n'
    || E'\n'
    || '    -- project_members — current members of projects I manage' || E'\n'
    || '    SELECT pm.employee_id AS emp_id' || E'\n'
    || '    FROM   target_groups_for_user tgfu' || E'\n'
    || '    JOIN   projects        pr ON pr.manager_id = v_employee_id' || E'\n'
    || '                              AND pr.active    = true' || E'\n'
    || '    JOIN   project_members pm ON pm.project_id = pr.id' || E'\n'
    || '                              AND pm.effective_from <= CURRENT_DATE' || E'\n'
    || '                              AND (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE)' || E'\n'
    || '    JOIN   employees       e  ON e.id = pm.employee_id AND e.deleted_at IS NULL' || E'\n'
    || '    WHERE  tgfu.scope_type = ''project_members'''
    || E'\n  )\n  SELECT array_agg(DISTINCT emp_id) INTO v_ids FROM resolved;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'get_target_population'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_module text, p_action text';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 781: get_target_population(text,text) not found -- refusing to guess';
  END IF;

  IF position('project_members' in v_src) > 0 THEN
    RAISE NOTICE 'mig 781: get_target_population already carries the branch -- skipping patch';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a1, ''))) / NULLIF(length(a1), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 781: get_target_population anchor matched % times, expected 1', v_hits;
  END IF;

  v_new := replace(v_src, a1, r1);
  EXECUTE v_new;
END $mig$;

COMMENT ON FUNCTION get_target_population(text, text) IS
  'Returns the target population for the current user on a given module+action. '
  'Scopes: self/everyone/custom/direct_l1/direct_l2/hierarchy/same_department/'
  'same_country/project_members. '
  'hierarchy: full recursive subtree downward via LATERAL recursive CTE. '
  'project_members: current members of projects where the caller is Reporting Manager. '
  'mode=all: everyone scope with include_self=true. '
  'mode=scoped: restricted ids. mode=none: no access.';

GRANT EXECUTE ON FUNCTION get_target_population(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $mig$
DECLARE
  v_ok boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM target_groups
    WHERE code = 'project_members' AND scope_type = 'project_members' AND is_system
  ) INTO v_ok;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'mig 781: target group project_members missing after seed';
  END IF;

  SELECT position('project_members' in pg_get_functiondef(p.oid)) > 0 INTO v_ok
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'user_can'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_module text, p_action text, p_owner uuid';
  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'mig 781: user_can does not carry the project_members branch';
  END IF;

  SELECT position('project_members' in pg_get_functiondef(p.oid)) > 0 INTO v_ok
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'get_target_population'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_module text, p_action text';
  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'mig 781: get_target_population does not carry the project_members branch';
  END IF;

  RAISE NOTICE 'mig 781: OK -- Project Members scope type is live in both functions';
END $mig$;
