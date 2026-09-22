-- =============================================================================
-- Migration 843 — pasting the same day twice is not twice the work
--
-- WHAT HAPPENS TODAY
-- ══════════════════
--   Copy 6 Sep (AMPTJ 5h, AZAD 3h), paste into 17 Sep: two entries created,
--   8h. Paste again: "2 merged", and 17 Sep now reads 16h. Measured on a real
--   PostgreSQL against the live definition -- 480 minutes to 960, with the
--   activity rows going 300 to 600 and 180 to 360.
--
--   No duplicate ROW appears, which is what makes this worth a migration. The
--   append branch sums into the matching activity by
--   (entry_id, lower(btrim(name)), is_billable), so afterwards the day holds
--   one AMPTJ entry with one activity reading 10h. Expand it and you see a long
--   day, not a mistake. Nothing in the data records that it was pasted twice,
--   and the only thing that said so was a toast reading "2 merged" that is gone
--   by the time anybody looks.
--
-- WHY APPENDING IS STILL RIGHT
-- ════════════════════════════
--   772 introduced it for a real case: Monday has AMPTJ, Tuesday already has
--   AZAD, and pasting Monday onto Tuesday should leave Tuesday holding both.
--   That is not what happened above. The difference is not the gesture, it is
--   whether the paste CREATES anything -- and the function never asked.
--
--   So this asks, once, before any write: does this paste produce a new entry,
--   or a new activity on an existing one? If the answer is no across the whole
--   paste, every hour it would add is an hour already recorded, and it is
--   refused. 775 made this function all-or-nothing; the check belongs with the
--   other pre-flight guards, above the loop, and it writes nothing.
--
-- WHAT IT DELIBERATELY DOES NOT REFUSE
-- ════════════════════════════════════
--   * A BARE DURATION -- no activity rows, no names -- because it carries
--     nothing to compare. 776 made Training 8h merge into Training 2h to read
--     10h, on purpose, and a duration holds no evidence of whether it is a
--     second helping or a second click. Refusing every such merge would undo
--     776 on a guess. These never block a paste.
--
--   * A PARTIAL OVERLAP. Source has activities X and Y, target already has X:
--     Y is new, so the paste proceeds and X still doubles. Refusing here would
--     block a genuine merge, which is the case 772 exists for. Named rather
--     than silently decided.
--
--   The guard is therefore about what can be IDENTIFIED. An activity has a
--   name; a duration does not.
--
-- METHOD
--   In-place patch, anchored on text read from the LIVE definition on Dev --
--   not reassembled from the migration files. Six migrations have edited this
--   function in place since 776 last rewrote it whole (802, 821, 824, 828,
--   829, 837), so the files do not add up to what is running.
--
-- Depends on: 772 (append), 775 (all-or-nothing + the jsonb error contract),
--             776 (bare-duration merge), 824 (the is_billable activity key),
--             829 (the four-column duplicate key this mirrors)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src text; v_new text; v_n integer;

  -- ── anchor 1: one more local ──────────────────────────────────────────────
  a1 CONSTANT text :=
'  v_msg        text;      -- MIG 775' || E'\n' ||
'BEGIN' || E'\n';
  b1 CONSTANT text :=
'  v_msg        text;      -- MIG 775' || E'\n' ||
'  v_dupe       integer;   -- MIG 843' || E'\n' ||
'BEGIN' || E'\n';

  -- ── anchor 2: the guard goes with the other pre-flight checks ────────────
  a2 CONSTANT text :=
'  -- ── Pre-flight: compute total minutes that will land on the target day ────' || E'\n';
  b2 CONSTANT text :=
'  -- ── MIG 843: would this paste create anything at all? ────────────────────' || E'\n' ||
'  -- A source entry counts as creating something when the target has no entry' || E'\n' ||
'  -- matching it on the four columns 829 settled, when it is a bare duration' || E'\n' ||
'  -- (nothing to compare -- 776 merges those on purpose), or when it carries an' || E'\n' ||
'  -- activity the matching target entry does not already hold. If nothing in' || E'\n' ||
'  -- the whole paste creates anything, every hour it would add is an hour that' || E'\n' ||
'  -- is already recorded, and the only thing it can do is inflate the day.' || E'\n' ||
'  SELECT count(*) INTO v_dupe' || E'\n' ||
'  FROM   timesheet_entries s' || E'\n' ||
'  LEFT   JOIN LATERAL (' || E'\n' ||
'           SELECT t.id' || E'\n' ||
'           FROM   timesheet_entries t' || E'\n' ||
'           WHERE  t.header_id          = p_header_id' || E'\n' ||
'             AND  t.entry_date         = p_to_date' || E'\n' ||
'             AND  t.time_type_id       IS NOT DISTINCT FROM s.time_type_id' || E'\n' ||
'             AND  t.project_id         IS NOT DISTINCT FROM s.project_id' || E'\n' ||
'             AND  t.related_project_id IS NOT DISTINCT FROM s.related_project_id' || E'\n' ||
'             AND  t.help_requested_by  IS NOT DISTINCT FROM s.help_requested_by' || E'\n' ||
'           LIMIT  1) tgt ON true' || E'\n' ||
'  WHERE  s.header_id  = p_header_id' || E'\n' ||
'    AND  s.entry_date = p_from_date' || E'\n' ||
'    AND  s.entry_kind NOT IN (''leave'', ''holiday'')' || E'\n' ||
'    AND  NOT COALESCE(s.is_system_generated, false)' || E'\n' ||
'    AND  (p_entry_ids IS NULL OR s.id = ANY(p_entry_ids))' || E'\n' ||
'    AND  (' || E'\n' ||
'          -- nothing on the target to merge into: this paste creates an entry' || E'\n' ||
'          tgt.id IS NULL' || E'\n' ||
'          -- a duration with no activities says nothing either way (mig 776)' || E'\n' ||
'       OR (NOT EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = s.id)' || E'\n' ||
'           AND COALESCE(array_length(s.activities, 1), 0) = 0)' || E'\n' ||
'          -- an activity the target entry does not already hold' || E'\n' ||
'       OR EXISTS (' || E'\n' ||
'            SELECT 1 FROM timesheet_entry_activities a' || E'\n' ||
'            WHERE  a.entry_id = s.id' || E'\n' ||
'              AND  NOT EXISTS (' || E'\n' ||
'                     SELECT 1 FROM timesheet_entry_activities ta' || E'\n' ||
'                     WHERE  ta.entry_id = tgt.id' || E'\n' ||
'                       AND  lower(btrim(ta.activity_name)) = lower(btrim(a.activity_name))' || E'\n' ||
'                       AND  ta.is_billable IS NOT DISTINCT FROM a.is_billable))' || E'\n' ||
'          -- same question for a legacy single name' || E'\n' ||
'       OR (COALESCE(array_length(s.activities, 1), 0) = 1' || E'\n' ||
'           AND NOT EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = s.id)' || E'\n' ||
'           AND NOT EXISTS (' || E'\n' ||
'                 SELECT 1 FROM timesheet_entry_activities ta' || E'\n' ||
'                 WHERE  ta.entry_id = tgt.id' || E'\n' ||
'                   AND  lower(btrim(ta.activity_name)) = lower(btrim(s.activities[1]))))' || E'\n' ||
'    );' || E'\n' ||
'' || E'\n' ||
'  IF v_dupe = 0 THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''DUPLICATE_PASTE'',' || E'\n' ||
'      ''message'', format(''%s is already on %s -- every activity in it is recorded there. ''' || E'\n' ||
'                        ''Pasting again would only add the same hours twice. Open %s to change them.'',' || E'\n' ||
'                        to_char(p_from_date, ''FMDD FMMonth''),' || E'\n' ||
'                        to_char(p_to_date,   ''FMDD FMMonth''),' || E'\n' ||
'                        to_char(p_to_date,   ''FMDD FMMonth'')));' || E'\n' ||
'  END IF;' || E'\n' ||
'' || E'\n' ||
'  -- ── Pre-flight: compute total minutes that will land on the target day ────' || E'\n';
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'MIG 843: expected exactly one paste_timesheet_day, found %.', v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF position('DUPLICATE_PASTE' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 843: already applied, skipping.';
    RETURN;
  END IF;

  v_n := (length(v_src) - length(replace(v_src, a1, ''))) / length(a1);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'MIG 843: the DECLARE anchor matched % times, expected 1. Read the live definition before editing this file.', v_n;
  END IF;
  v_n := (length(v_src) - length(replace(v_src, a2, ''))) / length(a2);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'MIG 843: the pre-flight anchor matched % times, expected 1. Read the live definition before editing this file.', v_n;
  END IF;

  v_new := replace(replace(v_src, a1, b1), a2, b2);
  EXECUTE v_new;
  RAISE NOTICE 'MIG 843: a paste that creates nothing is now refused.';
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_src text; v_probe integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF position('DUPLICATE_PASTE' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 843 FAILED: the guard is not in the function.';
  END IF;

  -- The things this patch sits between must both survive. A replace that
  -- swallowed either would turn a duplicate guard into a lost daily cap.
  IF position('DAILY_CAP' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 843 FAILED: the daily cap check was lost.';
  END IF;
  IF position('LEGACY_NEEDS_SPLIT' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 843 FAILED: the legacy guard was lost.';
  END IF;

  -- AW8's lesson: a plpgsql body is NOT parsed when the function is replaced,
  -- so "it deployed" proves nothing about the statement just inserted. Run the
  -- guard's own query here, standalone, against the real tables -- every column
  -- it names has to resolve or this migration stops now rather than at the
  -- first person who presses paste.
  SELECT count(*) INTO v_probe
  FROM   timesheet_entries s
  LEFT   JOIN LATERAL (
           SELECT t.id
           FROM   timesheet_entries t
           WHERE  t.header_id          = NULL::uuid
             AND  t.entry_date         = NULL::date
             AND  t.time_type_id       IS NOT DISTINCT FROM s.time_type_id
             AND  t.project_id         IS NOT DISTINCT FROM s.project_id
             AND  t.related_project_id IS NOT DISTINCT FROM s.related_project_id
             AND  t.help_requested_by  IS NOT DISTINCT FROM s.help_requested_by
           LIMIT  1) tgt ON true
  WHERE  s.header_id  = NULL::uuid
    AND  s.entry_kind NOT IN ('leave', 'holiday')
    AND  NOT COALESCE(s.is_system_generated, false)
    AND  (
          tgt.id IS NULL
       OR (NOT EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = s.id)
           AND COALESCE(array_length(s.activities, 1), 0) = 0)
       OR EXISTS (
            SELECT 1 FROM timesheet_entry_activities a
            WHERE  a.entry_id = s.id
              AND  NOT EXISTS (
                     SELECT 1 FROM timesheet_entry_activities ta
                     WHERE  ta.entry_id = tgt.id
                       AND  lower(btrim(ta.activity_name)) = lower(btrim(a.activity_name))
                       AND  ta.is_billable IS NOT DISTINCT FROM a.is_billable))
       OR (COALESCE(array_length(s.activities, 1), 0) = 1
           AND NOT EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = s.id)
           AND NOT EXISTS (
                 SELECT 1 FROM timesheet_entry_activities ta
                 WHERE  ta.entry_id = tgt.id
                   AND  lower(btrim(ta.activity_name)) = lower(btrim(s.activities[1]))))
    );

  RAISE NOTICE 'MIG 843 OK: the guard is in place and every column it reads resolves.';
END;
$v$;

COMMIT;
