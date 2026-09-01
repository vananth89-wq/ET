-- =============================================================================
-- Migration 826 — the approver's copy of the report knows what is chargeable
--
-- THE CONTRACT THIS KEEPS
-- ═══════════════════════
-- `assembleExportData()` exists because two surfaces produce the SAME monthly
-- report from different data: the employee's own timesheet page, which holds
-- rows it loaded itself, and the approval screen, which holds one
-- `time_approval_payload` blob. Its own header says so: what they share has to
-- be the assembly, not the fetching.
--
-- The billable split (migs 820–825) has just been added to that assembly. The
-- employee's page can feed it — it reads `timesheet_entry_activities.is_billable`
-- and `project_billability()` directly. The payload cannot: it carries activity
-- rows as `{name, minutes}` (mig 745) and says nothing about what a project is
-- worth. So without this migration the two documents diverge — the employee
-- files a report showing 2h of 12h as billable and the approver downloads the
-- same month with no split at all, and neither page tells them why.
--
-- An approver is the person being asked to agree that those 2 hours are the
-- chargeable ones. Withholding the figure from the only document they are given
-- is the wrong half to leave out.
--
-- TWO KEYS, BOTH ADDITIVE
-- ───────────────────────
--   activity_rows[].billable  -- true / false / null, straight off the row
--   entries[].project_class   -- billable | non_billable | unclassified | null
--
-- Nothing is renamed and nothing changes shape, so a browser holding the
-- previous bundle reads the payload exactly as it did before — the same
-- reasoning 745 gave for adding `activity_rows` beside `activities` rather than
-- changing it. A key nobody reads yet cannot break anyone.
--
-- WHY project_class AND NOT project_type_id
--   Because the rule then lives in two places and drifts. `project_billability()`
--   (825) is the one statement that decides what P001 means; this delegates to
--   it exactly as `billable_project_ids()` does. The payload carries the ANSWER,
--   not the inputs to it.
--
-- THE REMOVED[] ROWS ARE LEFT ALONE, DELIBERATELY
--   Audit rows carry the legacy `activities` text[] and nothing else — 745's own
--   comment explains that an entry's activity rows cascade-delete with it, so
--   what the split was at the moment of deletion is recorded nowhere. Neither is
--   what its billability was. Their activity_rows already report 0 minutes and
--   will now report an absent `billable`, which the client reads as null: the
--   question was never answered, which is the truth.
--
-- Method: IN-PLACE patch via pg_get_functiondef with counted assertions.
--   The newest writer of the region being touched is 745, not 743 -- 743 CREATEs
--   the function and 745 rewrote the activity_rows expression inside it. Reading
--   the anchor off the CREATE would have missed. (Three deploys were lost to
--   exactly that this week; see prowess-in-place-function-patching.)
--
-- Depends on : 743 (the entry object), 745 (activity_rows), 821 (is_billable),
--              825 (project_billability)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;
BEGIN
  SELECT count(*) INTO v_hits
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_approval_payload';
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 826: time_approval_payload has % overloads, expected 1.', v_hits;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_approval_payload';

  IF position('activity_rows' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 826: mig 745 must run first -- there are no activity rows to annotate.';
  END IF;

  IF position('''project_class''' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 826: the payload already carries billability. Nothing to do.';
    RETURN;
  END IF;

  v_new := v_src;

  -- ── (a) The answer travels with the activity row ──────────────────────────
  --
  -- Only the LIVE builder. The audit one selects a literal 0 for minutes and
  -- has no tea alias to read, which is also why matching on `tea.` rather than
  -- on 'minutes' alone is what keeps this migration off the wrong block.
  SELECT count(*) INTO v_hits
  FROM   regexp_matches(v_new, '''minutes'',[ \t]*tea\.hours_minutes\)', 'g');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 826: the live activity_rows builder matched % times, expected 1.', v_hits;
  END IF;

  v_new := regexp_replace(v_new,
    '(\n)([ \t]*)(''minutes'',[ \t]*tea\.hours_minutes)\)',
    E'\\1\\2\\3,\n\\2''billable'', tea.is_billable)');

  IF position('''billable'', tea.is_billable' IN v_new) = 0 THEN
    RAISE EXCEPTION 'MIG 826: could not add the billable key to activity_rows.';
  END IF;

  -- ── (b) What the entry's project is worth ─────────────────────────────────
  --
  -- Anchored on the project_id/project_name PAIR. `project_name` alone appears
  -- twice -- once for live entries and once for removed ones -- and the removed
  -- block has no project_id key, so the pair is what makes this unambiguous.
  -- Landing it in the audit block would read te.* aliases that do not exist
  -- there, and plpgsql would not notice until an approver opened a month with a
  -- deletion in it.
  SELECT count(*) INTO v_hits
  FROM   regexp_matches(v_new, '''project_id'',[ \t]*te\.project_id,[ \t]*\n[ \t]*''project_name'',[ \t]*pj\.name,', 'g');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 826: the live entry project keys matched % times, expected 1.', v_hits;
  END IF;

  v_new := regexp_replace(v_new,
    '(''project_id'',[ \t]*te\.project_id,[ \t]*\n)([ \t]*)(''project_name'',[ \t]*pj\.name,)',
    E'\\1\\2\\3\n\\2-- MIG 826: the ANSWER, not the inputs to it. project_billability()\n' ||
    E'\\2-- (825) is the one statement that decides which projects are\n' ||
    E'\\2-- chargeable, and the report an approver downloads has to reach\n' ||
    E'\\2-- the same answer as the one the employee filed.\n' ||
    E'\\2''project_class'', (SELECT b.cls FROM project_billability() b\n' ||
    E'\\2                    WHERE  b.id = te.project_id),');

  IF position('''project_class''' IN v_new) = 0 THEN
    RAISE EXCEPTION 'MIG 826: could not add project_class to the entry object.';
  END IF;

  -- ── The rules that must survive ───────────────────────────────────────────
  IF position('''removed''' IN v_new) = 0 THEN
    RAISE EXCEPTION 'MIG 826: the removed[] block (743) was lost.';
  END IF;
  IF position('changed_after_approval' IN v_new) = 0 THEN
    RAISE EXCEPTION 'MIG 826: the change marks (743) were lost.';
  END IF;
  IF position('previous_hours_minutes' IN v_new) = 0 THEN
    RAISE EXCEPTION 'MIG 826: the previous-hours figure (743) was lost.';
  END IF;
  IF (length(v_new) - length(replace(v_new, 'activity_rows', ''))) / length('activity_rows') <> 2 THEN
    RAISE EXCEPTION 'MIG 826: activity_rows no longer appears exactly twice. 745''s shape has moved.';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'MIG 826: the approval payload now carries per-activity billability and the project class.';
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_approval_payload';

  IF position('''billable'', tea.is_billable' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 826 FAILED: activity rows do not carry their answer, so the approver''s copy would print none.';
  END IF;
  IF position('''project_class''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 826 FAILED: entries do not carry the project class.';
  END IF;

  -- Delegated, not re-implemented. A second copy of the P001 test here is how
  -- the approver's report and the employee's come to disagree.
  IF position('project_billability()' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 826 FAILED: the payload decides billability itself instead of asking project_billability().';
  END IF;
  IF position('P001' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 826 FAILED: the payload carries its own copy of the P001 rule.';
  END IF;

  -- And it is the LIVE block that was patched, not the audit one. The audit
  -- rows have no tea alias and no te alias; a te.* reference inside that
  -- subquery resolves at run time and would fail only for a month that happens
  -- to contain a deletion.
  IF position('b.id = te.project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 826 FAILED: project_class does not read te.project_id.';
  END IF;
  IF position('b.id = a.project_id' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 826 FAILED: project_class landed in the removed[] block, which has no live entry to read.';
  END IF;

  RAISE NOTICE 'Migration 826 verified: the approval payload carries billable per activity and the project class per entry, both delegated to project_billability().';
END $mig$;

COMMIT;
