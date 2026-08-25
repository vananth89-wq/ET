-- =============================================================================
-- Migration 788: you cannot strand somebody's hours by editing a date
--
-- THE PROBLEM
-- ═══════════
-- Hashim books 16-20 August while the project runs to the 30th. Somebody then
-- moves the project's end date to the 15th. His entries survive -- nothing
-- deletes them -- but they are now outside every window the system believes in:
-- the dropdown will not offer that project for those dates, so he cannot even
-- edit them, and no one is told any of this happened.
--
-- WHY NOT JUST DELETE THE ENTRIES
-- ───────────────────────────────
-- Because they are true. He worked those hours and the project really did run
-- to the 30th when he booked them. An administrative edit happened afterwards.
-- Deleting them would also invalidate an approved timesheet -- the exact thing
-- project_member_remove() end-dates rather than deletes to avoid -- and would
-- silently change last month's project totals, which §3.3a of the design doc
-- exists to prevent. The cost would land on an employee who did nothing wrong
-- and may not even be able to act, since an approved period is locked to them.
--
-- So: make the invalid state unreachable instead of cleaning it up afterwards.
-- The person making the edit is told, at the moment they make it, exactly what
-- stands in the way.
--
-- THE RULE, AND THE SUBTLETY IN IT
-- ────────────────────────────────
-- Block only what this edit NEWLY strands: entries that fall outside the new
-- window AND inside the old one.
--
-- Not "any entry outside the new window" -- that would be a trap. Hashim's
-- project is already in the bad state today, so a blanket rule would refuse
-- every future edit to it, including the edit that fixes it. Moving a date the
-- RIGHT way strands nothing and must always be allowed.
--
-- TWO LAYERS, ON PURPOSE
-- ──────────────────────
--   TRIGGERS   the guarantee. They hold however the row is written -- the admin
--              Projects screen writes to `projects` directly, and RLS lets a
--              lead UPDATE project_members.
--   FUNCTION   the sentence. project_member_update() runs the same check first
--              and returns a readable envelope, because a trigger exception
--              reaches the client as a Postgres error and the friendly text
--              gets lost. Same pattern as the overlap check in 774: the message
--              comes first, the constraint stands behind it.
--
-- CHANGES
-- ───────
--   1. entries_stranded_by()            -- NEW. The shared question.
--   2. trg_projects_guard_dates()       -- trigger on projects
--   3. trg_project_members_guard_dates()-- trigger on project_members
--   4. project_member_update()          -- the readable version, patched in
--
-- NOT CHANGED
-- ───────────
--   Nothing deletes or rewrites an entry. No report changes. Deactivating a
--   project is untouched -- closing a project is a legitimate act that strands
--   nothing, since entries and reports both survive it.
-- =============================================================================

SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The shared question
-- ═══════════════════════════════════════════════════════════════════════════
-- SECURITY DEFINER because the caller is often an administrator who holds
-- projects_mgmt.edit and nothing else -- they cannot SELECT employees, so a
-- plain function would report "0 entries by nobody" and wave the edit through.

CREATE OR REPLACE FUNCTION public.entries_stranded_by(
  p_project_id  uuid,
  p_employee_id uuid,          -- NULL = every employee on the project
  p_old_from    date,
  p_old_to      date,
  p_new_from    date,
  p_new_to      date
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  WITH hit AS (
    SELECT e.entry_date, e.hours_minutes, h.employee_id
    FROM   timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  e.project_id = p_project_id
      AND  (p_employee_id IS NULL OR h.employee_id = p_employee_id)
      -- outside the window this edit would create ...
      AND  NOT (daterange(COALESCE(p_new_from, '-infinity'::date),
                          COALESCE(p_new_to,   'infinity'::date), '[]') @> e.entry_date)
      -- ... but inside the one it replaces. Anything already outside BOTH was
      -- stranded by some earlier edit and is not this edit's doing.
      AND  daterange(COALESCE(p_old_from, '-infinity'::date),
                     COALESCE(p_old_to,   'infinity'::date), '[]') @> e.entry_date
  )
  SELECT jsonb_build_object(
    'n',     COUNT(*),
    'hours', ROUND(COALESCE(SUM(hours_minutes), 0) / 60.0, 2),
    'first', MIN(entry_date),
    'last',  MAX(entry_date),
    'who',   COALESCE((SELECT jsonb_agg(nm ORDER BY nm)
                       FROM (SELECT DISTINCT em.name AS nm
                             FROM hit JOIN employees em ON em.id = hit.employee_id
                             LIMIT 6) q), '[]'::jsonb)
  )
  FROM hit;
$fn$;

REVOKE ALL ON FUNCTION public.entries_stranded_by(uuid, uuid, date, date, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.entries_stranded_by(uuid, uuid, date, date, date, date) TO authenticated;

COMMENT ON FUNCTION public.entries_stranded_by(uuid, uuid, date, date, date, date) IS
  'Mig 788: entries that a date change would newly strand -- outside the new '
  'window AND inside the old one. Anything already outside both predates this '
  'edit and is deliberately not counted, so a project already in a bad state '
  'can still be corrected. Returns {n, hours, first, last, who[]}.';


-- A sentence a human can act on, built once and used by all three call sites.
CREATE OR REPLACE FUNCTION public.stranded_message(p_what text, p_hit jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT p_what
      || ': ' || (p_hit->>'n') || ' timesheet '
      || CASE WHEN (p_hit->>'n')::int = 1 THEN 'entry' ELSE 'entries' END
      || ' (' || (p_hit->>'hours') || ' h) fall outside it — '
      || CASE WHEN (p_hit->>'first') = (p_hit->>'last')
              THEN 'on ' || (p_hit->>'first')
              ELSE 'between ' || (p_hit->>'first') || ' and ' || (p_hit->>'last') END
      || CASE WHEN jsonb_array_length(p_hit->'who') = 0 THEN ''
              ELSE ', by ' || (SELECT string_agg(v, ', ')
                               FROM (SELECT jsonb_array_elements_text(p_hit->'who') AS v LIMIT 5) s)
                   || CASE WHEN jsonb_array_length(p_hit->'who') > 5 THEN ' and others' ELSE '' END END
      || '. Move the date to cover them, or remove those entries first.';
$fn$;

COMMENT ON FUNCTION public.stranded_message(text, jsonb) IS
  'Mig 788: renders entries_stranded_by() as one actionable sentence -- how '
  'many, how many hours, which dates, whose. Shared so the trigger and the '
  'RPC never drift into saying different things about the same rule.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. projects.start_date / end_date
-- ═══════════════════════════════════════════════════════════════════════════
-- A trigger and not a check inside an RPC, because the admin Projects screen
-- writes to this table directly. A rule that only one code path honours is not
-- a rule.

CREATE OR REPLACE FUNCTION public.trg_projects_guard_dates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_hit jsonb;
BEGIN
  IF NEW.start_date IS NOT DISTINCT FROM OLD.start_date
     AND NEW.end_date IS NOT DISTINCT FROM OLD.end_date THEN
    RETURN NEW;
  END IF;

  v_hit := entries_stranded_by(OLD.id, NULL,
                               OLD.start_date, OLD.end_date,
                               NEW.start_date, NEW.end_date);

  IF (v_hit->>'n')::int > 0 THEN
    RAISE EXCEPTION '%', stranded_message(
      'Cannot change the dates of ' || COALESCE(OLD.name, 'this project'), v_hit);
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS before_projects_guard_dates ON projects;

CREATE TRIGGER before_projects_guard_dates
BEFORE UPDATE OF start_date, end_date
ON projects
FOR EACH ROW
EXECUTE FUNCTION trg_projects_guard_dates();


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. project_members.effective_from / effective_to
-- ═══════════════════════════════════════════════════════════════════════════
-- Covers project_member_update(), project_member_remove() -- which end-dates at
-- today and could strand a future-dated entry -- and any direct UPDATE a lead
-- makes through the RLS policy.

CREATE OR REPLACE FUNCTION public.trg_project_members_guard_dates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_hit  jsonb;
  v_name text;
BEGIN
  IF NEW.effective_from IS NOT DISTINCT FROM OLD.effective_from
     AND NEW.effective_to IS NOT DISTINCT FROM OLD.effective_to THEN
    RETURN NEW;
  END IF;

  v_hit := entries_stranded_by(OLD.project_id, OLD.employee_id,
                               OLD.effective_from, OLD.effective_to,
                               NEW.effective_from, NEW.effective_to);

  IF (v_hit->>'n')::int > 0 THEN
    SELECT name INTO v_name FROM employees WHERE id = OLD.employee_id;
    RAISE EXCEPTION '%', stranded_message(
      'Cannot change ' || COALESCE(v_name, 'that person') || '''s dates on this project', v_hit);
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS before_project_members_guard_dates ON project_members;

CREATE TRIGGER before_project_members_guard_dates
BEFORE UPDATE OF effective_from, effective_to
ON project_members
FOR EACH ROW
EXECUTE FUNCTION trg_project_members_guard_dates();


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. The same check, said in words
-- ═══════════════════════════════════════════════════════════════════════════
-- The trigger above is the guarantee, but it reaches the browser as a Postgres
-- error and the frontend falls back to a generic message. Running the check
-- inside project_member_update() first means the lead reads the sentence in the
-- envelope, on the screen, where the fix is.
--
-- Patched in place rather than retyped: 786 is the last file in this repo that
-- defines this function, which is not a promise about what is running.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a1 text := E'  UPDATE project_members\n  SET    allocation_pct = v_alloc,';

  r1 text := E'  -- Mig 788: refuse a date change that would newly strand hours.\n'
          || E'  -- The trigger enforces this whatever writes the row; here it is only so\n'
          || E'  -- the lead reads a sentence instead of a Postgres error.\n'
          || E'  v_hit := entries_stranded_by(v_row.project_id, v_row.employee_id,\n'
          || E'                               v_row.effective_from, v_row.effective_to,\n'
          || E'                               v_from, v_to);\n'
          || E'  IF (v_hit->>''n'')::int > 0 THEN\n'
          || E'    RETURN jsonb_build_object(''ok'', false, ''error'', ''WOULD_STRAND_ENTRIES'',\n'
          || E'      ''message'', stranded_message(''Those dates cannot be applied'', v_hit),\n'
          || E'      ''detail'', v_hit);\n'
          || E'  END IF;\n'
          || E'\n'
          || E'  UPDATE project_members\n  SET    allocation_pct = v_alloc,';

  a2 text := E'  v_alloc numeric;\n';
  r2 text := E'  v_alloc numeric;\n  v_hit   jsonb;\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_update';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 788: project_member_update not found';
  END IF;

  IF position('entries_stranded_by' in v_src) > 0 THEN
    RAISE NOTICE 'mig 788: project_member_update already carries the guard -- skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a2, ''))) / NULLIF(length(a2), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 788: declare anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a2, r2);

  v_hits := (length(v_new) - length(replace(v_new, a1, ''))) / NULLIF(length(a1), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 788: update anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a1, r1);

  EXECUTE v_new;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'before_projects_guard_dates') THEN
    RAISE EXCEPTION 'mig 788: projects trigger missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'before_project_members_guard_dates') THEN
    RAISE EXCEPTION 'mig 788: project_members trigger missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_update'
      AND pg_get_functiondef(p.oid) LIKE '%entries_stranded_by%'
  ) THEN
    RAISE EXCEPTION 'mig 788: project_member_update did not take the readable check';
  END IF;

  RAISE NOTICE 'mig 788: OK -- dates cannot strand hours';
END $mig$;
