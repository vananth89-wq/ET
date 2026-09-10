-- =============================================================================
-- Migration 840 — retire projects.project_type, the column 755 could not drop
--
-- WHY IT WAS LEFT
-- ═══════════════
--   754 added `projects.project_type text` with a CHECK allow-list of
--   'billable' / 'internal' / 'overhead'. 755 moved the classification onto the
--   picklist as `project_type_id uuid`, and deliberately KEPT the old column,
--   writing down exactly why:
--
--       "projects.project_type is now dead, but the frontend live in production
--        at the moment this migration runs still SELECTs it, and PostgREST 400s
--        the whole request when a selected column is missing -- that would take
--        out the entire Project Management screen, not just one field."
--
--   It named the order that works: this migration, then the frontend, then a
--   later migration drops the column. The frontend landed. The third step never
--   did, so the column has sat there for three weeks holding a stale copy of a
--   fact that now lives somewhere else.
--
-- WHY IT LOOKED ALIVE
-- ═══════════════════
--   A grep for `project_type` finds `MyProjects/index.tsx`, which renders
--   `p.project_type` — and that reading is what kept this migration from being
--   written earlier. It is wrong. MyProjects reads
--   `my_staffable_projects_detail`, whose RETURNS TABLE has an output column
--   NAMED project_type but selects `pv.value` — the picklist label, reached
--   through project_type_id. A name collision, and it made a dead column look
--   like a live one to every search anyone ran.
--
--   The real test is not whether the NAME appears. It is whether anything reads
--   the COLUMN, and a qualified reference is what that looks like. The
--   assertion below matches `<alias>.project_type` and ignores the bare word,
--   which is why it can tell the output column apart from the real one.
--
-- WHY NOW
-- ═══════
--   839 made project_type_id the only thing that decides whether hours are
--   chargeable. Leaving a second, older, differently-shaped answer beside it is
--   how the two come to disagree — and this one cannot be kept in step, because
--   nothing writes it any more. It is not dead code; it is stale DATA, which is
--   worse, because the next person to find it has no way to tell.
--
-- SAFETY
--   * Refuses if any function still reads the column.
--   * Refuses if any row would lose information — a project with the old text
--     set and no project_type_id would be a project whose classification only
--     exists in the column being dropped.
--   * The drop is irreversible, which is why both checks come first.
--
-- Depends on: 754 (the column), 755 (project_type_id), 839 (the flag)
-- =============================================================================

BEGIN;

DO $v$
DECLARE
  v_fn   text;
  v_bad  bigint;
  -- A QUALIFIED reference: alias-dot-column, not followed by _id. The bare word
  -- appears as an output column name in my_staffable_projects_detail and must
  -- not count.
  v_ref  CONSTANT text := '\.project_type($|[^_[:alnum:]])';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'projects'
                    AND column_name = 'project_type') THEN
    RAISE NOTICE 'MIG 840: projects.project_type is already gone, nothing to do.';
    RETURN;
  END IF;

  -- ── 1. does anything still read it? ──────────────────────────────────────
  FOR v_fn IN
    SELECT p.proname
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.prokind = 'f'
      AND  pg_get_functiondef(p.oid) ~ v_ref
  LOOP
    RAISE EXCEPTION 'MIG 840: %() still reads projects.project_type. Move it onto project_type_id before dropping the column.', v_fn;
  END LOOP;

  -- Views and generated columns are real dependencies; Postgres would refuse
  -- the drop for those anyway, but failing here says WHICH one.
  FOR v_fn IN
    SELECT DISTINCT c.relname
    FROM   pg_depend d
    JOIN   pg_rewrite r  ON r.oid = d.objid
    JOIN   pg_class   c  ON c.oid = r.ev_class
    JOIN   pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
    WHERE  d.refobjid = 'public.projects'::regclass
      AND  a.attname  = 'project_type'
      AND  c.relkind IN ('v', 'm')
  LOOP
    RAISE EXCEPTION 'MIG 840: view %s depends on projects.project_type.', v_fn;
  END LOOP;

  -- ── 2. would any project lose its only classification? ───────────────────
  SELECT count(*) INTO v_bad
  FROM   projects
  WHERE  project_type IS NOT NULL AND project_type_id IS NULL;

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'MIG 840: % project(s) carry the old text type and no project_type_id. Dropping the column would erase the only record of what they are — backfill project_type_id first.', v_bad;
  END IF;

  RAISE NOTICE 'MIG 840: nothing reads the column and no project depends on it.';
END;
$v$;

ALTER TABLE projects DROP CONSTRAINT IF EXISTS projects_project_type_check;
ALTER TABLE projects DROP COLUMN IF EXISTS project_type;

DO $v$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'projects'
                AND column_name = 'project_type') THEN
    RAISE EXCEPTION 'MIG 840 FAILED: the column is still there.';
  END IF;

  -- The replacement must still be present and still doing its job, or this
  -- migration has removed the only classification rather than the older of two.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'projects'
                    AND column_name = 'project_type_id') THEN
    RAISE EXCEPTION 'MIG 840 FAILED: project_type_id is missing. Do not drop the old column on a database that never got 755.';
  END IF;

  PERFORM project_billability();

  RAISE NOTICE 'MIG 840 OK: one column decides a project''s type, and it is the one an administrator can see.';
END;
$v$;

COMMIT;
