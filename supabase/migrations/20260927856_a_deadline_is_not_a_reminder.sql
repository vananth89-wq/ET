-- =============================================================================
-- Migration 856 — a deadline is not a reminder
--
-- time_submission_due_date() has always been:
--
--     period end + max(offset_days) of the ACTIVE reminder rows
--
-- which makes the submission deadline a side effect of the nag schedule. Today
-- it reads 25 Aug + 6 = 31 Aug, because the last seeded reminder happens to sit
-- at +6. Nobody chose 31 Aug. It fell out of a message template.
--
-- That is about to cost something real. The scheme we want is
--
--     offset  0  -> employee
--     offset +1  -> employee, manager
--     offset +2  -> employee, manager, HR Analyst
--
-- and configuring it drops max(offset_days) from 6 to 2. Every deadline moves
-- three days earlier, is_overdue and days_past_due recompute for every row of
-- the compliance report, and the set of people who count as late changes --
-- because an admin edited a reminder message. One column cannot answer both
-- "when do we nag" and "when is it late".
--
-- So the deadline gets a setting of its own, seeded from what the deadline is
-- RIGHT NOW, so that deploying this moves no date anywhere. The reminder rows
-- keep their offsets and stop deciding anything but their own firing day.
--
-- Depends on : 702 (time_edit_config), 744 (time_submission_due_date),
--              837 (timesheet_period_end, period_start_day)
-- =============================================================================

BEGIN;

-- ── 1. The setting ───────────────────────────────────────────────────────────

ALTER TABLE time_edit_config
  ADD COLUMN IF NOT EXISTS submission_grace_days smallint;

-- A single-row settings table with no row reads as "all defaults". Before 856
-- that still produced a deadline of period end + 6, because the figure came
-- from the reminder table, which is never empty. Defaulting the new column to 0
-- on an absent row would therefore MOVE the deadline. Materialise the row first
-- so the seed below has something to write to.
INSERT INTO time_edit_config (employee_edit_window_days)
SELECT 30
WHERE  NOT EXISTS (SELECT 1 FROM time_edit_config);

-- Seeded from the CURRENT effective deadline, never from a guess.
-- GREATEST(..., 0) because a schedule whose only active row fires BEFORE period
-- end (the seeded -1 row, if the others were switched off) would otherwise set
-- a deadline earlier than the period it closes.
UPDATE time_edit_config
   SET submission_grace_days =
         GREATEST(0, COALESCE((SELECT max(offset_days)
                               FROM   time_submission_config
                               WHERE  is_active), 0))
 WHERE submission_grace_days IS NULL;

ALTER TABLE time_edit_config ALTER COLUMN submission_grace_days SET DEFAULT 0;
ALTER TABLE time_edit_config ALTER COLUMN submission_grace_days SET NOT NULL;

ALTER TABLE time_edit_config
  DROP CONSTRAINT IF EXISTS time_edit_config_submission_grace_range;
ALTER TABLE time_edit_config
  ADD  CONSTRAINT time_edit_config_submission_grace_range
  CHECK (submission_grace_days BETWEEN 0 AND 31);

COMMENT ON COLUMN time_edit_config.submission_grace_days IS
  'Mig 856: days after period end by which a timesheet must be submitted. This '
  'is the deadline and nothing else -- reminder offsets in '
  'time_submission_config no longer decide it. 0 = due on the last day of the '
  'period. Seeded from the pre-856 effective deadline so the split moved no date.';


-- ── 2. The deadline stops reading the nag schedule ───────────────────────────

DO $mig$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'time_submission_due_date'
    AND  p.prokind = 'f';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 856: time_submission_due_date() not found.';
  END IF;

  IF position('submission_grace_days' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 856: already reads the setting, skipping the rewrite.';
    RETURN;
  END IF;

  -- Predicates, not prose. The body must still be the one this migration was
  -- written against; if Dev has drifted into something else, a blind replace
  -- would silently discard it.
  IF position('max(offset_days)' IN v_src) = 0 THEN
    RAISE EXCEPTION
      'MIG 856: time_submission_due_date() reads neither max(offset_days) nor '
      'submission_grace_days. Live body: %', v_src;
  END IF;

  IF position('timesheet_period_end' IN v_src) = 0 THEN
    RAISE EXCEPTION
      'MIG 856: time_submission_due_date() is not on the 837 cycle -- expected '
      'timesheet_period_end(). Live body: %', v_src;
  END IF;

  CREATE OR REPLACE FUNCTION public.time_submission_due_date(p_period date)
  RETURNS date
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public
  AS $fn$
    SELECT (timesheet_period_end(p_period)
            + COALESCE((SELECT c.submission_grace_days
                        FROM   time_edit_config c
                        LIMIT  1), 0));
  $fn$;
END
$mig$;

COMMENT ON FUNCTION public.time_submission_due_date(date) IS
  'Period end plus time_edit_config.submission_grace_days. The one definition of '
  'a timesheet deadline. Mig 856 took it off max(offset_days) of the reminder '
  'schedule, so editing a reminder no longer moves the deadline.';


-- ── 3. Verification ──────────────────────────────────────────────────────────

DO $mig$
DECLARE
  v_period   date := timesheet_period_of(CURRENT_DATE);
  v_end      date := timesheet_period_end(timesheet_period_of(CURRENT_DATE));
  v_grace    smallint;
  v_actual   date;
  v_pre856   date;
BEGIN
  SELECT c.submission_grace_days INTO v_grace FROM time_edit_config c LIMIT 1;
  IF v_grace IS NULL THEN
    RAISE EXCEPTION 'MIG 856: no time_edit_config row carries a grace value.';
  END IF;

  v_actual := time_submission_due_date(v_period);

  -- Fatal: proves the rewrite computes what the setting says.
  IF v_actual IS DISTINCT FROM (v_end + v_grace) THEN
    RAISE EXCEPTION 'MIG 856: due date % is not period end % plus grace %.',
      v_actual, v_end, v_grace;
  END IF;

  -- Informational: what the old formula would have said. Equal on a first
  -- deploy by construction. Not fatal, because a re-run after an admin has
  -- edited the reminder offsets SHOULD differ -- that divergence is the entire
  -- point of this migration, not a fault in it.
  v_pre856 := v_end + GREATEST(0, COALESCE((SELECT max(offset_days)
                                            FROM time_submission_config
                                            WHERE is_active), 0));
  IF v_pre856 IS DISTINCT FROM v_actual THEN
    RAISE WARNING 'MIG 856: deadline now %; the old reminder-derived formula '
                  'would say %. Expected only if reminder offsets changed '
                  'after the split.', v_actual, v_pre856;
  ELSE
    RAISE NOTICE 'MIG 856: deadline unchanged at % for period % (grace %).',
      v_actual, v_period, v_grace;
  END IF;
END
$mig$;

COMMIT;
