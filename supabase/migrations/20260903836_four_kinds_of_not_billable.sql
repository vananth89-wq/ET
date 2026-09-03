-- =============================================================================
-- Migration 836 — four kinds of "not billable" are four different facts
--
-- WHAT IS WRONG
-- ═════════════
-- `non_billable` currently absorbs four things that have nothing in common
-- except that nobody invoices them:
--
--   * a client project where somebody looked at the hour and said DON'T BILL IT
--   * a project typed Internal or Overhead, where the question is never asked
--   * help given to another project (801) -- no project_id at all, by design
--   * Training and On-Site Visit -- attendance types that carry no project
--
-- A month reading "29% non-billable" therefore says nothing. Most of it may be
-- internal work nobody ever intended to charge for, and the figure reads as
-- waste. Vj, on seeing it: *"Non billable should only consider the hours
-- explicitly marked as non billable and support is against the support time
-- type."* He is right, and the fix is to stop merging them.
--
--     non_billable   the answer was NO             (client project, marked)
--     internal       the question does not apply   (internal project, training)
--     support        given to another project      (801)
--     unclassified   nobody set the project type   (unchanged)
--     billable       unchanged, deliberately
--     absence        unchanged
--
-- THE DENOMINATOR DOES NOT MOVE, AND THAT IS THE POINT
-- ────────────────────────────────────────────────────
--   Billable share is billable ÷ worked, and `worked` is still every one of
--   these buckets. A narrower denominator -- billable over CLIENT-PROJECT time
--   only -- was considered and rejected: on a real month it reads 87% where the
--   present rule reads 71%, and both are legitimate figures answering different
--   questions. Redefining a number Finance quotes, under its existing name, is
--   a cost with no upside here, because the complaint above is fixed by
--   SPLITTING THE BUCKETS and not by changing what they are divided by.
--
--   So this migration must not move billable_minutes by one minute. The
--   billable branches below are copied through untouched for exactly that
--   reason, and the verification asserts they survived.
--
-- WHY SUPPORT MUST BE TESTED BEFORE THE TIME-TYPE ARM
-- ───────────────────────────────────────────────────
--   A support entry carries a time_type_id and no project_id, so under the
--   present CASE it falls into the `time_type_id IS NOT NULL` arm and is
--   reported as non_billable. Its own branch has to come first or it can never
--   be reached.
--
-- THE `ent` CTE HAS TWO ARMS
-- ──────────────────────────
--   Mig 771 made `ent` a UNION ALL: rows the caller can see as an employee, and
--   rows they can see because they MANAGE the project. Both arms need
--   related_project_id or the classifier reads NULL for half the rows and
--   support silently stays non_billable for exactly the people a project lead
--   is looking at. The patch asserts two hits, not one.
--
-- Depends on : 744 (creates the function), 771 (the UNION), 800 (billable_split),
--              801 (related_project_id), 820, 822 (the live CASE)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  -- ── 1. related_project_id, in BOTH arms of the UNION (771) ────────────────
  a_sel CONSTANT text :=
'           e.project_id, e.time_type_id, e.is_system_generated,' || E'\n';
  b_sel CONSTANT text :=
'           e.project_id, e.related_project_id, e.time_type_id, e.is_system_generated,' || E'\n';

  -- ── 2. two more buckets in the split ──────────────────────────────────────
  a_tot CONSTANT text :=
'                 ''unclassified_minutes'', COALESCE(sum(c.hours_minutes) FILTER (WHERE c.cls = ''unclassified''), 0))' || E'\n';
  b_tot CONSTANT text :=
'                 ''unclassified_minutes'', COALESCE(sum(c.hours_minutes) FILTER (WHERE c.cls = ''unclassified''), 0),' || E'\n' ||
'                 -- Mig 836. Two buckets carved out of non_billable, which was' || E'\n' ||
'                 -- absorbing four unrelated facts. The six still sum to' || E'\n' ||
'                 -- recorded_minutes -- nothing was added or dropped, only' || E'\n' ||
'                 -- separated -- so a caller that reads only the original four' || E'\n' ||
'                 -- keys now under-counts rather than seeing wrong numbers.' || E'\n' ||
'                 ''internal_minutes'',     COALESCE(sum(c.hours_minutes) FILTER (WHERE c.cls = ''internal''),     0),' || E'\n' ||
'                 ''support_minutes'',      COALESCE(sum(c.hours_minutes) FILTER (WHERE c.cls = ''support''),      0))' || E'\n';

  -- ── 3. the classification itself ──────────────────────────────────────────
  a_cls CONSTANT text :=
'                   WHEN en.project_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN pv.ref_id IS NULL   THEN ''unclassified''' || E'\n' ||
'                             WHEN pv.ref_id <> ''P001'' THEN ''non_billable''' || E'\n';
  b_cls CONSTANT text :=
'                   WHEN en.project_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN pv.ref_id IS NULL   THEN ''unclassified''' || E'\n' ||
'                             -- Mig 836. Internal and Overhead, not' || E'\n' ||
'                             -- non_billable. Nobody was asked about these' || E'\n' ||
'                             -- hours and nobody could have been: the billable' || E'\n' ||
'                             -- question is only put on a P001 project. Calling' || E'\n' ||
'                             -- them non-billable reports a decision that was' || E'\n' ||
'                             -- never made.' || E'\n' ||
'                             WHEN pv.ref_id <> ''P001'' THEN ''internal''' || E'\n';

  a_arm CONSTANT text :=
'                   WHEN en.time_type_id IS NOT NULL THEN ''non_billable''' || E'\n';
  b_arm CONSTANT text :=
'                   -- Mig 836. BEFORE the time-type arm, or it can never be' || E'\n' ||
'                   -- reached: a support entry carries a time_type_id and, by' || E'\n' ||
'                   -- 801''s design, no project_id at all.' || E'\n' ||
'                   WHEN en.related_project_id IS NOT NULL THEN ''support''' || E'\n' ||
'                   -- Training, On-Site Visit: attendance with no project.' || E'\n' ||
'                   -- Never chargeable, never declined -- the same fact as an' || E'\n' ||
'                   -- internal project, so the same bucket.' || E'\n' ||
'                   WHEN en.time_type_id IS NOT NULL THEN ''internal''' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 836: timesheet_report_utilisation not found. 744 must run first.';
  END IF;

  IF position('''support''' IN v_src) > 0 AND position('internal_minutes' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 836: already applied, skipping.';
    RETURN;
  END IF;

  v_new := v_src;

  -- ── 1 ─────────────────────────────────────────────────────────────────────
  v_hits := (length(v_new) - length(replace(v_new, a_sel, ''))) / length(a_sel);
  IF v_hits <> 2 THEN
    RAISE EXCEPTION 'MIG 836: the ent select list matched % times, expected 2 (771 made it a UNION). The CTE has changed shape.', v_hits;
  END IF;
  v_new := replace(v_new, a_sel, b_sel);

  -- ── 2 ─────────────────────────────────────────────────────────────────────
  v_hits := (length(v_new) - length(replace(v_new, a_tot, ''))) / length(a_tot);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 836: the billable_split object matched % times, expected 1.', v_hits;
  END IF;
  v_new := replace(v_new, a_tot, b_tot);

  -- ── 3 ─────────────────────────────────────────────────────────────────────
  v_hits := (length(v_new) - length(replace(v_new, a_cls, ''))) / length(a_cls);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 836: the project branch of the classifier matched % times, expected 1. 822''s CASE has moved.', v_hits;
  END IF;
  v_new := replace(v_new, a_cls, b_cls);

  v_hits := (length(v_new) - length(replace(v_new, a_arm, ''))) / length(a_arm);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 836: the time-type arm matched % times, expected 1.', v_hits;
  END IF;
  v_new := replace(v_new, a_arm, b_arm);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 836: timesheet_report_utilisation now separates internal and support from non_billable.';
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- The approver's payload has to be able to tell them apart too
--
-- 826 sends `project_class` per entry, which is NULL for cross-project help AND
-- NULL for Training -- correctly, since neither has a booked project. That was
-- enough while both were non_billable. It stops being enough now: with no way
-- to separate them, the approver's copy files every support hour under
-- `internal` while the employee's own sheet calls it `support`, and the two
-- disagree about a month neither of them got wrong.
--
-- One key, on the same anchor 826 used -- the project_id / project_name PAIR,
-- because the entry object is built twice and only the live block has them.
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_approval_payload';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 836: time_approval_payload not found.';
  END IF;

  IF position('''related_project_id''' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 836: the payload already carries related_project_id, skipping.';
    RETURN;
  END IF;

  v_new := v_src;

  SELECT count(*) INTO v_hits
  FROM   regexp_matches(v_new, '''project_id'',[ \t]*te\.project_id,[ \t]*\n[ \t]*''project_name'',[ \t]*pj\.name,', 'g');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 836: the live entry project keys matched % times, expected 1.', v_hits;
  END IF;

  v_new := regexp_replace(v_new,
    '(''project_id'',[ \t]*te\.project_id,[ \t]*\n)([ \t]*)(''project_name'',[ \t]*pj\.name,)',
    E'\\1\\2\\3\n\\2-- MIG 836: which project was HELPED. project_class is NULL for\n' ||
    E'\\2-- help and NULL for Training alike, so it cannot separate them --\n' ||
    E'\\2-- and since 836 they are two different buckets. The id, not a\n' ||
    E'\\2-- boolean: a later reader will want to name the project.\n' ||
    E'\\2''related_project_id'', te.related_project_id,');

  IF position('''related_project_id''' IN v_new) = 0 THEN
    RAISE EXCEPTION 'MIG 836: could not add related_project_id to the entry object.';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'MIG 836: time_approval_payload now carries related_project_id.';
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  n     bigint;
  n_int bigint;
  n_sup bigint;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  -- The two new buckets exist and are reported.
  IF position('internal_minutes' IN v_src) = 0 OR position('support_minutes' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 836 FAILED: the split does not report the new buckets.';
  END IF;

  -- Support is reachable. Without related_project_id in the CTE this branch
  -- compiles and never fires, which is the failure that looks like success.
  IF position('en.related_project_id IS NOT NULL THEN ''support''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 836 FAILED: support has no branch.';
  END IF;
  IF position('e.related_project_id, e.time_type_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 836 FAILED: the ent CTE does not carry related_project_id, so the support branch can never fire.';
  END IF;

  -- ORDER IS THE WHOLE CORRECTNESS ARGUMENT. Support must be tested before the
  -- time-type arm; a support entry has a time_type_id and no project_id, so
  -- the other order silently keeps every support hour in `internal`.
  IF position('''support''' IN v_src) > position('WHEN en.time_type_id IS NOT NULL THEN ''internal''' IN v_src) THEN
    RAISE EXCEPTION 'MIG 836 FAILED: the support branch sits after the time-type arm and can never be reached.';
  END IF;

  -- BILLABLE MUST NOT HAVE MOVED. This migration separates what was already
  -- not billable; if it touched either billable branch it has changed a number
  -- Finance quotes, which it is explicitly not allowed to do.
  IF position('WHEN a.id IS NULL          THEN ''billable''' IN v_src) = 0
     OR position('WHEN a.is_billable IS TRUE THEN ''billable''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 836 FAILED: a billable branch was altered. The share must be identical before and after.';
  END IF;

  -- And nothing typed P001 leaked into the new buckets.
  IF position('WHEN pv.ref_id <> ''P001'' THEN ''internal''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 836 FAILED: non-P001 projects are not classified internal.';
  END IF;

  -- What actually moves, on this database's real rows. Reported rather than
  -- asserted: a Dev with no internal projects and no support hours is a
  -- perfectly good state, but a silent zero here would hide a broken join.
  SELECT count(*) INTO n_int
  FROM   timesheet_entries e
  LEFT   JOIN projects pr        ON pr.id = e.project_id
  LEFT   JOIN picklist_values pv ON pv.id = pr.project_type_id
  LEFT   JOIN time_types tt      ON tt.id = e.time_type_id
  WHERE  COALESCE(tt.category, '') <> 'absence'
    AND  ((e.project_id IS NOT NULL AND pv.ref_id IS NOT NULL AND pv.ref_id <> 'P001')
          OR (e.project_id IS NULL AND e.related_project_id IS NULL AND e.time_type_id IS NOT NULL));

  SELECT count(*) INTO n_sup
  FROM   timesheet_entries e
  LEFT   JOIN time_types tt ON tt.id = e.time_type_id
  WHERE  COALESCE(tt.category, '') <> 'absence'
    AND  e.project_id IS NULL AND e.related_project_id IS NOT NULL;

  -- The approver's copy has to be able to draw the same distinction.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'time_approval_payload';
  IF position('''related_project_id'', te.related_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 836 FAILED: the approval payload cannot tell help from Training, so the approver''s copy will disagree with the sheet it was made from.';
  END IF;

  SELECT count(*) INTO n FROM timesheet_entries;

  RAISE NOTICE 'Migration 836 verified: of % entries, % move from non_billable to internal and % to support. Billable is untouched.',
               n, n_int, n_sup;
END $mig$;

COMMIT;
