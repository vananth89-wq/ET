-- =============================================================================
-- Migration 822 — the billable share counts activities, not entries
--
-- 821 put the flag on the activity row, which is the only unit that knows the
-- answer: a twelve-hour day on a billable project is ten hours of exploring a
-- ticket and two hours of the fix, and only the two are chargeable. Nothing
-- reads that flag yet. Until this migration, the utilisation split still asked
-- the question of the whole ENTRY, so all twelve hours were billable.
--
-- WHAT CHANGES
-- ════════════
--   1. The unit becomes the activity row where one exists, and the entry where
--      none does. Activity minutes are the source of truth and the parent is a
--      mirror of them (mig 727), so the four buckets still sum to
--      recorded_minutes -- which the verification asserts rather than trusts.
--
--   2. The no-project fallback stops consulting time_types.is_billable and
--      simply reads non-billable.
--
-- WHY (2), AND WHY IT IS NOT A RETREAT FROM 800
--   Billable means somebody is paying, and at Prowess a payer means a project.
--   An hour with no project attached has nobody to charge, so is_billable on a
--   time type had exactly one correct value for every type that will ever
--   exist. A setting with one right answer is not a setting; it is a way for an
--   administrator to make the number wrong.
--
--   The column is left in place, unread. It costs nothing, and if a retainer
--   ever gets billed without a project behind it, the fallback has somewhere to
--   go. Dropping it would be a second migration to undo a first, and the
--   deciding fact -- "do you ever invoice hours not attached to a project?" --
--   was answered no, not never.
--
-- THE JOIN IS LEFT, DELIBERATELY
--   An entry with no activity rows -- a legacy single-name entry, or a bare
--   duration on a non-project type -- must still contribute its own minutes
--   exactly once. LEFT JOIN with COALESCE does that; an inner join would drop
--   those hours out of the split while leaving them in recorded_minutes, and
--   the buckets would silently stop reconciling.
--
-- WHAT STAYS TRUE
--   recorded_minutes is untouched. This migration reclassifies and re-grains;
--   it must not re-total, and the verification says so.
--
-- HISTORY IS BACKFILLED, AND THE VALUE IS CHOSEN SO THAT NOTHING MOVES
--   821 added the column as NULL on every existing row. Read literally, that
--   would make every hour ever recorded non-billable the moment this migration
--   lands -- the billable share for last quarter would change because of a
--   column that did not exist when last quarter was worked.
--
--   So rows already on a billable project are backfilled to true. That is not a
--   guess: before per-activity flags existed, an hour on a billable project WAS
--   billable, in both reports, by the only rule there was. true is the value
--   that leaves every past number exactly as it was, which is the only
--   defensible thing to write into history.
--
--   Rows on other projects stay NULL and read as non-billable, which is also
--   what they were. Only entries recorded from now on carry a real answer.
--
-- Depends on : 800, 820 (the split), 821 (the flag), 727 (activity rows)
-- =============================================================================

BEGIN;

-- ── 0. Bring history with the meaning ────────────────────────────────────────
--
-- Before this migration an hour on a billable project was billable. Writing
-- true here is what makes that continue to be true of hours already recorded.
-- 821 refuses NULL on a billable project, so every row this touches predates it.

UPDATE public.timesheet_entry_activities a
   SET is_billable = true
  FROM public.timesheet_entries e
  JOIN public.projects p         ON p.id  = e.project_id
  JOIN public.picklist_values pv ON pv.id = p.project_type_id
 WHERE a.entry_id      = e.id
   AND a.is_billable IS NULL
   AND pv.ref_id       = 'P001';

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  -- The unit. COALESCE, so an entry with no activity rows still counts once.
  a_unit CONSTANT text :=
'          SELECT en.hours_minutes,' || E'\n';
  b_unit CONSTANT text :=
'          -- mig 822. The activity row is the unit where one exists; the entry' || E'\n' ||
'          -- is the unit where none does. Activity minutes are the source of' || E'\n' ||
'          -- truth and the parent mirrors them (727), so the buckets still sum' || E'\n' ||
'          -- to recorded_minutes.' || E'\n' ||
'          SELECT COALESCE(a.hours_minutes, en.hours_minutes) AS hours_minutes,' || E'\n';

  -- The classification.
  a_cls CONSTANT text :=
'                 CASE' || E'\n' ||
'                   WHEN tt.category = ''absence'' THEN ''absence''' || E'\n' ||
'                   WHEN en.project_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN pv.ref_id = ''P001'' THEN ''billable''' || E'\n' ||
'                             WHEN pv.ref_id IS NULL    THEN ''unclassified''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   WHEN en.time_type_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN COALESCE(tt.is_billable, false) THEN ''billable''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   ELSE ''unclassified''' || E'\n' ||
'                 END AS cls' || E'\n';

  b_cls CONSTANT text :=
'                 -- mig 822. On a billable project the ACTIVITY decides. NULL' || E'\n' ||
'                 -- means the question never applied to that row, and an hour' || E'\n' ||
'                 -- nobody was asked about is not an hour anybody agreed to' || E'\n' ||
'                 -- pay for -- so IS TRUE, not COALESCE to some default.' || E'\n' ||
'                 --' || E'\n' ||
'                 -- The no-project fallback no longer consults' || E'\n' ||
'                 -- time_types.is_billable. A payer means a project, so an hour' || E'\n' ||
'                 -- with no project has nobody to charge and the flag had one' || E'\n' ||
'                 -- correct value for every type that will ever exist. The' || E'\n' ||
'                 -- column stays, unread, in case a retainer ever appears.' || E'\n' ||
'                 CASE' || E'\n' ||
'                   WHEN tt.category = ''absence'' THEN ''absence''' || E'\n' ||
'                   WHEN en.project_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN pv.ref_id IS NULL   THEN ''unclassified''' || E'\n' ||
'                             WHEN pv.ref_id <> ''P001'' THEN ''non_billable''' || E'\n' ||
'                             -- No activity row means nobody was ever offered' || E'\n' ||
'                             -- the question for these minutes, so the older' || E'\n' ||
'                             -- rule stands and the PROJECT answers. Legacy' || E'\n' ||
'                             -- and bare-duration entries only: 721 requires' || E'\n' ||
'                             -- an activity on anything recorded since.' || E'\n' ||
'                             WHEN a.id IS NULL          THEN ''billable''' || E'\n' ||
'                             WHEN a.is_billable IS TRUE THEN ''billable''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   WHEN en.time_type_id IS NOT NULL THEN ''non_billable''' || E'\n' ||
'                   ELSE ''unclassified''' || E'\n' ||
'                 END AS cls' || E'\n';

  -- The join.
  a_join CONSTANT text :=
'          LEFT   JOIN picklist_values pv ON pv.id = pr.project_type_id' || E'\n';
  b_join CONSTANT text :=
'          LEFT   JOIN picklist_values pv ON pv.id = pr.project_type_id' || E'\n' ||
'          -- LEFT, deliberately: an entry with no activity rows must still' || E'\n' ||
'          -- contribute its own minutes once. An inner join would drop those' || E'\n' ||
'          -- hours from the split while leaving them in recorded_minutes, and' || E'\n' ||
'          -- the buckets would stop reconciling with nothing to show for it.' || E'\n' ||
'          LEFT   JOIN timesheet_entry_activities a ON a.entry_id = en.id' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 822: timesheet_report_utilisation not found.';
  END IF;
  IF position('billable_split' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822: mig 800 must run first.';
  END IF;
  IF position('mig 820. The PROJECT decides' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822: mig 820 must run first -- the anchor is the classification it leaves.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='timesheet_entry_activities'
                   AND column_name='is_billable') THEN
    RAISE EXCEPTION 'MIG 822: mig 821 must run first -- there is no flag to read.';
  END IF;

  IF position('mig 822. On a billable project the ACTIVITY decides' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 822: the split already counts activities. Nothing to do.';
  ELSE
    v_new := v_src;

    v_hits := (length(v_new) - length(replace(v_new, a_unit, ''))) / length(a_unit);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 822: the unit anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_unit, b_unit);

    v_hits := (length(v_new) - length(replace(v_new, a_cls, ''))) / length(a_cls);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 822: the classification anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_cls, b_cls);

    v_hits := (length(v_new) - length(replace(v_new, a_join, ''))) / length(a_join);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 822: the join anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_join, b_join);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 822: the billable share now counts activity rows.';
  END IF;
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
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF position('a.is_billable IS TRUE' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: the split does not read the activity flag.';
  END IF;

  -- IS TRUE, not COALESCE. An hour nobody was asked about is not billable, and
  -- writing it as a coalesced default invites somebody to change the default.
  IF position('COALESCE(a.is_billable' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: the flag is read through COALESCE. NULL means never asked, which is not a value to default.';
  END IF;

  IF position('LEFT   JOIN timesheet_entry_activities a ON a.entry_id = en.id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: activity rows are not joined, or not joined LEFT.';
  END IF;
  IF position('COALESCE(a.hours_minutes, en.hours_minutes)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: an entry with no activity rows would contribute nothing.';
  END IF;

  -- The fallback no longer reads the time-type flag.
  IF position('COALESCE(tt.is_billable, false)' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: the no-project fallback still consults time_types.is_billable.';
  END IF;
  IF position('WHEN en.time_type_id IS NOT NULL THEN ''non_billable''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: the no-project fallback is not plainly non-billable.';
  END IF;

  -- Order is still absence, project, time type. 820's whole point.
  IF position('WHEN tt.category = ''absence'' THEN ''absence''' IN v_src)
     > position('WHEN en.project_id IS NOT NULL THEN' IN v_src) THEN
    RAISE EXCEPTION 'MIG 822 FAILED: absence is no longer asked before the project.';
  END IF;
  IF position('WHEN en.project_id IS NOT NULL THEN' IN v_src)
     > position('WHEN en.time_type_id IS NOT NULL THEN' IN v_src) THEN
    RAISE EXCEPTION 'MIG 822 FAILED: the time type is asked before the project again (820).';
  END IF;

  -- An untyped project is still unclassified, never assumed billable.
  IF position('WHEN pv.ref_id IS NULL   THEN ''unclassified''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: an untyped project is no longer unclassified.';
  END IF;

  -- An entry with no activity rows keeps the older rule. Without this, every
  -- legacy and bare-duration entry on a billable project silently becomes
  -- non-billable and past totals move.
  IF position('WHEN a.id IS NULL          THEN ''billable''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: an entry with no activity rows would drop out of billable. The project must still answer for it.';
  END IF;

  -- Re-grains and reclassifies. Does not re-total.
  IF position('''recorded_minutes'', (SELECT COALESCE(sum(hours_minutes), 0) FROM ent)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: recorded_minutes was altered.';
  END IF;
  IF position('time_report_managed_project_ids' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 822 FAILED: the function lost the PM predicate (771).';
  END IF;

  -- No activity row on a billable project may be left unanswered. Anything
  -- still NULL there would silently read as non-billable, which is the history
  -- loss the backfill exists to prevent.
  IF EXISTS (
    SELECT 1
    FROM   public.timesheet_entry_activities a
    JOIN   public.timesheet_entries e ON e.id = a.entry_id
    JOIN   public.projects p          ON p.id = e.project_id
    JOIN   public.picklist_values pv  ON pv.id = p.project_type_id
    WHERE  a.is_billable IS NULL AND pv.ref_id = 'P001') THEN
    RAISE EXCEPTION 'MIG 822 FAILED: activity rows on billable projects are still unanswered. The backfill did not cover them.';
  END IF;

  RAISE NOTICE 'Migration 822 verified: the split counts activity rows, reads the flag as IS TRUE, keeps entries without rows, and no longer consults the time-type flag.';
END $mig$;

COMMIT;
