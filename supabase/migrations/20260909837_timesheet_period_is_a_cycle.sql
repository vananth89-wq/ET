-- =============================================================================
-- Migration 837 — a timesheet period is a cycle, not a calendar month
--
-- WHAT VJ ASKED FOR
-- ═════════════════
--   *"I need the timesheet start date to be flexible. Because for some employee
--   its full month from 1st to 30 or 31st or 29 or 28. But for some the time
--   sheet period is from 26th to 25th of next month always."*
--
--   Then, having chosen: **call it August, and make it 26th-to-25th for all.**
--   So 26 Jul – 25 Aug is "August 2026" — the month the period ENDS in, which is
--   the month payroll pays it in.
--
-- WHAT WAS ACTUALLY HARDCODED
-- ═══════════════════════════
--   Not the storage. `timesheet_headers.period` has always been a `date`, and
--   every consumer derives the end as `period + 1 month - 1 day`, which is
--   already correct for a 26th anchor:
--
--       2026-07-26 + 1 month - 1 day = 2026-08-25     ✓
--       2026-08-01 + 1 month - 1 day = 2026-08-31     ✓  (unchanged)
--
--   What was hardcoded is the INVERSE — the answer to *"which period does this
--   date belong to"* — written eleven times as `date_trunc('month', X)::date`
--   across the write paths, the recalc triggers, the edit-window floor and the
--   three report parameter normalisers. That expression is the whole change.
--   It becomes one function, so there is one place that knows the rule.
--
-- WHY THE ANCHOR IS CAPPED AT 28
-- ══════════════════════════════
--   `date + interval '1 month'` CLAMPS. A 31st anchor drifts and never recovers:
--
--       2026-01-31 + 1 month = 2026-02-28   (clamped)  - 1 day = 2026-02-27
--       so the next period starts 2026-02-28, and by April it is the 28th
--       for good. The cycle silently loses a day and no error is raised.
--
--   Below 29 the arithmetic is exact in every month including February, so the
--   CHECK is 1..28 and "the last day of the month" is deliberately not offered.
--   26 is safe. This is the one constraint that prevents a whole class of
--   drift bug from ever being reachable.
--
-- WHY THE START DAY IS SNAPSHOT ON THE HEADER
-- ═══════════════════════════════════════════
--   Same reason `work_schedule_id` and `holiday_calendar_id` are snapshot
--   there (704): a timesheet must keep meaning what it meant when it was
--   approved. If the guards read the GLOBAL setting, flipping it to 26 would
--   instantly make every existing 1st-anchored header un-writable — every save
--   would compute period 2026-08-26 and compare it against a header that says
--   2026-08-01. The snapshot is what lets this migration deploy on a database
--   full of calendar-month timesheets and change nothing about them.
--
--   It is also the whole of the per-employee work, arriving early. When cycles
--   become per-employee, only `timesheet_period_of(date)` — the one-argument
--   form that reads config — needs to learn about employees. The two-argument
--   form, the snapshot, the constraints and all eleven call sites are already
--   right.
--
-- WHY THE OVERLAP CONSTRAINT
-- ══════════════════════════
--   `UNIQUE (employee_id, period)` stops two headers sharing an ANCHOR. It has
--   never stopped two headers sharing a DAY. Nothing needed it to, because
--   calendar months cannot overlap. The moment a cycle changes, they can:
--   a 1–31 Aug header and a 26 Aug – 25 Sep header both contain 28 August, both
--   are approvable, and the same hours are counted twice with no error anywhere.
--
--   So the span becomes a generated column and an EXCLUDE constraint makes it
--   structurally impossible rather than a rule somebody has to remember. A bad
--   cycle change now fails at write time instead of producing two truths about
--   one day.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- ════════════════════════════════════════════
--   It does not delete or re-anchor a single existing header. Vj's answer was
--   "wipe and start fresh", and that is right for Dev — but a TRUNCATE inside a
--   migration would also run on UAT and eventually on Prod, and an answer about
--   Dev's test data does not authorise that. The wipe is a separate command
--   block, run by hand, against Dev only.
--
--   Existing calendar-month headers stay legal here: they carry
--   period_start_day = 1, which is historically true of them, and the CHECK
--   validates each row against its OWN snapshot rather than against a global.
--
-- SAFETY
--   * Idempotent: every ALTER is IF NOT EXISTS / DROP-then-ADD, and every
--     function patch skips itself if already applied.
--   * Every patch asserts its anchor hit count on both sides and aborts the
--     transaction rather than half-applying.
--   * Verified against a real PostgreSQL 16 before commit — the arithmetic
--     assertions at the bottom of this file are the ones that were run.
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the setting, and the snapshot
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE time_edit_config
  ADD COLUMN IF NOT EXISTS period_start_day smallint NOT NULL DEFAULT 1;

ALTER TABLE time_edit_config
  DROP CONSTRAINT IF EXISTS time_edit_config_period_start_day_range;
ALTER TABLE time_edit_config
  ADD  CONSTRAINT time_edit_config_period_start_day_range
  CHECK (period_start_day BETWEEN 1 AND 28);

COMMENT ON COLUMN time_edit_config.period_start_day IS
  'Mig 837: day of month a timesheet period starts. 1 = calendar month; 26 = '
  '26th to the 25th. Capped at 28 because month arithmetic clamps above it and '
  'the cycle would drift a day every February. Global for now; when cycles go '
  'per-employee this becomes the fallback rather than the answer.';

-- One row, enforced by 702's trigger. Seed it if the table is empty rather than
-- leaving the resolver to fall back to 1 forever.
INSERT INTO time_edit_config (period_start_day)
SELECT 26 WHERE NOT EXISTS (SELECT 1 FROM time_edit_config);

UPDATE time_edit_config SET period_start_day = 26
 WHERE period_start_day IS DISTINCT FROM 26;

ALTER TABLE timesheet_headers
  ADD COLUMN IF NOT EXISTS period_start_day smallint NOT NULL DEFAULT 1;

COMMENT ON COLUMN timesheet_headers.period_start_day IS
  'Mig 837: the cycle this sheet was OPENED under, snapshot like work_schedule_id '
  'and holiday_calendar_id. Every guard compares against this, never against the '
  'live setting, so changing the setting can never re-slice a closed timesheet.';

-- The old rule said "the 1st, always". The new rule says "whatever day this
-- sheet's own cycle starts on" — which is still "the 1st, always" for every row
-- that exists today, so nothing has to move.
ALTER TABLE timesheet_headers
  DROP CONSTRAINT IF EXISTS timesheet_headers_period_first_of_month;
ALTER TABLE timesheet_headers
  DROP CONSTRAINT IF EXISTS timesheet_headers_period_start_day_range;
ALTER TABLE timesheet_headers
  ADD  CONSTRAINT timesheet_headers_period_start_day_range
  CHECK (period_start_day BETWEEN 1 AND 28);
ALTER TABLE timesheet_headers
  DROP CONSTRAINT IF EXISTS timesheet_headers_period_matches_cycle;
ALTER TABLE timesheet_headers
  ADD  CONSTRAINT timesheet_headers_period_matches_cycle
  CHECK (EXTRACT(DAY FROM period)::smallint = period_start_day);

COMMENT ON COLUMN timesheet_headers.period IS
  'Mig 837: the FIRST DAY of the period, which is the 1st only when '
  'period_start_day is 1. The period runs to period + 1 month - 1 day, and is '
  'LABELLED by the month it ends in — 2026-07-26 is "August 2026".';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — two headers may never cover the same day
-- ═══════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE timesheet_headers
  ADD COLUMN IF NOT EXISTS span daterange
  GENERATED ALWAYS AS
    (daterange(period, (period + INTERVAL '1 month')::date, '[)')) STORED;

COMMENT ON COLUMN timesheet_headers.span IS
  'Mig 837: the period as a half-open date range, generated from period alone. '
  'Exists so overlap can be a constraint instead of a convention, and so anything '
  'asking "which sheet owns this date" can use span @> date — which is correct '
  'whatever cycle each sheet is on.';

ALTER TABLE timesheet_headers
  DROP CONSTRAINT IF EXISTS timesheet_headers_no_overlapping_span;
ALTER TABLE timesheet_headers
  ADD  CONSTRAINT timesheet_headers_no_overlapping_span
  EXCLUDE USING gist (employee_id WITH =, span WITH &&);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — the one place that knows the rule
-- ═══════════════════════════════════════════════════════════════════════════

-- Pure arithmetic, no lookup. Shift the date back so the cycle's start day lands
-- on the 1st, truncate, shift forward again. Degrades EXACTLY to the old
-- date_trunc('month', d) when the start day is 1, which is why every existing
-- header keeps answering the same as it always did.
CREATE OR REPLACE FUNCTION public.timesheet_period_of(p_date date, p_start_day smallint)
RETURNS date
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT (date_trunc('month', p_date - (p_start_day - 1))::date + (p_start_day - 1));
$$;

-- The config-reading form, for callers with no header in hand: creating one,
-- defaulting a report's period filter, computing the edit floor. When cycles go
-- per-employee, THIS is the function that changes, and nothing else.
CREATE OR REPLACE FUNCTION public.timesheet_period_of(p_date date)
RETURNS date
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
  SELECT timesheet_period_of(
           p_date,
           COALESCE((SELECT c.period_start_day FROM time_edit_config c LIMIT 1), 1::smallint));
$$;

CREATE OR REPLACE FUNCTION public.timesheet_period_end(p_period date)
RETURNS date
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT (p_period + INTERVAL '1 month' - INTERVAL '1 day')::date;
$$;

-- The month a period is CALLED. 26 Jul – 25 Aug is August, because that is the
-- month it ends in and the month payroll pays it in. For a calendar month this
-- is the month itself, so the label of every existing sheet is unchanged.
CREATE OR REPLACE FUNCTION public.timesheet_period_label(p_period date)
RETURNS date
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT date_trunc('month', timesheet_period_end(p_period))::date;
$$;

-- The inverse: the client navigates by label (?period=2026-08) and needs the
-- anchor to look a header up by.
CREATE OR REPLACE FUNCTION public.timesheet_period_from_label(p_label date, p_start_day smallint)
RETURNS date
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
           WHEN p_start_day = 1
             THEN date_trunc('month', p_label)::date
           ELSE (date_trunc('month', p_label)::date - INTERVAL '1 month')::date
                + (p_start_day - 1)
         END;
$$;

CREATE OR REPLACE FUNCTION public.timesheet_period_from_label(p_label date)
RETURNS date
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
  SELECT timesheet_period_from_label(
           p_label,
           COALESCE((SELECT c.period_start_day FROM time_edit_config c LIMIT 1), 1::smallint));
$$;

REVOKE ALL ON FUNCTION public.timesheet_period_of(date, smallint)         FROM PUBLIC;
REVOKE ALL ON FUNCTION public.timesheet_period_of(date)                   FROM PUBLIC;
REVOKE ALL ON FUNCTION public.timesheet_period_end(date)                  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.timesheet_period_label(date)                FROM PUBLIC;
REVOKE ALL ON FUNCTION public.timesheet_period_from_label(date, smallint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.timesheet_period_from_label(date)           FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.timesheet_period_of(date, smallint)         TO authenticated;
GRANT EXECUTE ON FUNCTION public.timesheet_period_of(date)                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.timesheet_period_end(date)                  TO authenticated;
GRANT EXECUTE ON FUNCTION public.timesheet_period_label(date)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.timesheet_period_from_label(date, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.timesheet_period_from_label(date)           TO authenticated;

COMMENT ON FUNCTION public.timesheet_period_of(date, smallint) IS
  'Mig 837: which period a date belongs to, for a given cycle start day. The one '
  'definition — replaces eleven copies of date_trunc(''month'', X). Callers that '
  'hold a header MUST pass that header''s period_start_day, not the live setting.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — the patcher
-- ═══════════════════════════════════════════════════════════════════════════
-- Eleven near-identical edits. A shared helper because writing the assertion
-- eleven times is eleven chances to write it slightly wrong, and the assertion
-- is the part that matters: it reads the LIVE definition, refuses to guess, and
-- aborts if the function has changed shape since this file was written.

CREATE OR REPLACE FUNCTION public._mig837_patch(
  p_fn text, p_a text, p_b text, p_expect integer)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE v_src text; v_new text; v_hits integer; v_n integer;
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'MIG 837: %() not found.', p_fn;
  END IF;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'MIG 837: %() is overloaded % ways; this patcher edits one definition and would pick arbitrarily.', p_fn, v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  -- Already applied: the anchor is gone AND the replacement is present. Both
  -- halves matter — some replacements are substrings of their own anchors, and
  -- testing only for the replacement would skip a patch that had not been made.
  IF position(p_a IN v_src) = 0 AND position(p_b IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 837: %() already patched, skipping.', p_fn;
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, p_a, ''))) / length(p_a);
  IF v_hits <> p_expect THEN
    RAISE EXCEPTION 'MIG 837: in %(), the anchor matched % times, expected %. The function has changed shape since 837 was written — read it before editing this file. Anchor: %',
      p_fn, v_hits, p_expect, left(p_a, 90);
  END IF;

  v_new := replace(v_src, p_a, p_b);
  EXECUTE v_new;
  RAISE NOTICE 'MIG 837: patched %() — % occurrence(s).', p_fn, v_hits;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — the write paths ask the header, not the calendar
-- ═══════════════════════════════════════════════════════════════════════════
-- These three all carry the same guard: "the date you are writing must fall in
-- this header's period". They must compare using the HEADER's cycle, which is
-- why each first has to start selecting the snapshot.

DO $mig$
BEGIN
  PERFORM public._mig837_patch(fn,
    'SELECT id, employee_id, period, status INTO v_header',
    'SELECT id, employee_id, period, period_start_day, status INTO v_header',
    1)
  FROM unnest(ARRAY['save_timesheet_entry',
                    'bulk_create_timesheet_entries',
                    'paste_timesheet_day']) AS fn;

  PERFORM public._mig837_patch('save_timesheet_entry',
    'date_trunc(''month'', v_date)::date <> v_header.period',
    'timesheet_period_of(v_date, v_header.period_start_day) <> v_header.period',
    1);

  PERFORM public._mig837_patch('bulk_create_timesheet_entries',
    'date_trunc(''month'', v_d)::date <> v_header.period',
    'timesheet_period_of(v_d, v_header.period_start_day) <> v_header.period',
    1);

  -- Two: "you may only paste within one period", from and to.
  PERFORM public._mig837_patch('paste_timesheet_day',
    'date_trunc(''month'', p_from_date)::date <> v_header.period',
    'timesheet_period_of(p_from_date, v_header.period_start_day) <> v_header.period',
    1);
  PERFORM public._mig837_patch('paste_timesheet_day',
    'date_trunc(''month'', p_to_date)::date <> v_header.period',
    'timesheet_period_of(p_to_date, v_header.period_start_day) <> v_header.period',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 6 — the edit floor and the deadline
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  -- 730: "the first day of the earliest period an employee may still change".
  -- Subtracting whole months from a 26th anchor gives another 26th anchor, so
  -- only the starting point had to learn the cycle.
  PERFORM public._mig837_patch('time_employee_edit_floor',
    'date_trunc(''month'', CURRENT_DATE)',
    'timesheet_period_of(CURRENT_DATE)',
    1);

  -- 744: p_period is ALREADY a period anchor. Truncating it was a harmless
  -- no-op while every anchor was the 1st; on a 26th anchor it silently threw
  -- the deadline back to the start of that calendar month.
  PERFORM public._mig837_patch('time_submission_due_date',
    '(date_trunc(''month'', p_period) + INTERVAL ''1 month - 1 day'')::date',
    'timesheet_period_end(p_period)',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 7 — the three reports normalise their period filter the same way
-- ═══════════════════════════════════════════════════════════════════════════
-- All three filter on h.period BETWEEN v_from AND v_to — the period axis, not
-- the date axis — so they already answer "each employee's own book" rather than
-- "calendar August". Only the normalisers that snap a parameter to a period
-- boundary need to know the cycle.

DO $mig$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY['timesheet_report_utilisation',
                            'timesheet_report_compliance',
                            'timesheet_report_project_summary']
  LOOP
    PERFORM public._mig837_patch(fn,
      'date_trunc(''month'', CURRENT_DATE)::date',
      'timesheet_period_of(CURRENT_DATE)',
      1);
    PERFORM public._mig837_patch(fn,
      'date_trunc(''month'', v_from)::date',
      'timesheet_period_of(v_from)',
      1);
    PERFORM public._mig837_patch(fn,
      'date_trunc(''month'', COALESCE((p_filters->>''period_to'')::date, v_from))::date',
      'timesheet_period_of(COALESCE((p_filters->>''period_to'')::date, v_from))',
      1);
  END LOOP;

  -- months_active counted DISTINCT CALENDAR MONTHS of entry dates. Over a
  -- 26–25 range that is 2 for a single period, because the range straddles two
  -- calendar months — it would report a project as active twice as long as it
  -- was. Distinct PERIODS is the figure the column was always trying to give.
  PERFORM public._mig837_patch('timesheet_report_project_summary',
    'count(DISTINCT date_trunc(''month'', en.entry_date))::bigint',
    'count(DISTINCT timesheet_period_of(en.entry_date))::bigint',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 8 — a holiday moving finds sheets by the day, not by the month
-- ═══════════════════════════════════════════════════════════════════════════
-- 722/724 turned a holiday's date into a month and looked for headers with that
-- period. Once two employees can be on different cycles, one date belongs to two
-- differently-anchored periods and no single computed anchor finds both. The
-- span column answers it exactly, and is indexed by the EXCLUDE constraint.
--
-- The parameter is renamed because it now means something else, and a parameter
-- whose name lies is how the next person gets this wrong. CREATE OR REPLACE
-- cannot rename parameters, so this one is dropped and rebuilt; both callers are
-- the trigger functions patched immediately below, and plpgsql resolves those by
-- name at execution time, so nothing breaks in between.

DROP FUNCTION IF EXISTS public.time_holiday_calendar_changed(uuid, date);

CREATE FUNCTION public.time_holiday_calendar_changed(
  p_calendar_id uuid, p_date date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE r record; v_touched integer := 0;
BEGIN
  IF p_calendar_id IS NULL OR p_date IS NULL THEN RETURN 0; END IF;

  FOR r IN
    SELECT h.id FROM timesheet_headers h
     WHERE h.span @> p_date
       AND COALESCE(h.holiday_calendar_id, (
             SELECT ee.holiday_calendar_id FROM employee_employment ee
              WHERE ee.employee_id = h.employee_id
                AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
                AND ee.holiday_calendar_id IS NOT NULL
              LIMIT 1)) = p_calendar_id
  LOOP
    PERFORM time_apply_planned_recalc(r.id, 'holiday_calendar_changed',
      jsonb_build_object('calendar_id', p_calendar_id, 'date', p_date));
    v_touched := v_touched + 1;
  END LOOP;

  RETURN v_touched;
END;
$$;

REVOKE ALL ON FUNCTION public.time_holiday_calendar_changed(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_holiday_calendar_changed(uuid, date) TO authenticated;

COMMENT ON FUNCTION public.time_holiday_calendar_changed(uuid, date) IS
  'Mig 837: recompute planned minutes for every sheet on this calendar that '
  'CONTAINS this date. Takes the date itself, not a period — one date can fall '
  'in two differently-anchored periods, and h.span @> date finds both.';

DO $mig$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY['trg_time_holidays_recalc',
                            'trg_time_calendar_entries_recalc']
  LOOP
    PERFORM public._mig837_patch(fn,
      'date_trunc(''month'', NEW.entry_date)::date)', 'NEW.entry_date)', 1);
    PERFORM public._mig837_patch(fn,
      'date_trunc(''month'', OLD.entry_date)::date)', 'OLD.entry_date)', 1);
  END LOOP;
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig837_patch(text, text, text, integer);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 9 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_src text; v_day smallint;
BEGIN
  -- ── the arithmetic ───────────────────────────────────────────────────────
  -- A 26th cycle, walked across its own boundary.
  IF timesheet_period_of(DATE '2026-08-25', 26::smallint) <> DATE '2026-07-26' THEN
    RAISE EXCEPTION 'MIG 837 FAILED: 25 Aug should belong to the period starting 26 Jul.';
  END IF;
  IF timesheet_period_of(DATE '2026-08-26', 26::smallint) <> DATE '2026-08-26' THEN
    RAISE EXCEPTION 'MIG 837 FAILED: 26 Aug should open a new period.';
  END IF;
  IF timesheet_period_end(DATE '2026-07-26') <> DATE '2026-08-25' THEN
    RAISE EXCEPTION 'MIG 837 FAILED: the period starting 26 Jul must end 25 Aug.';
  END IF;

  -- February, which is where a clamping anchor would show itself.
  IF timesheet_period_of(DATE '2026-03-01', 26::smallint) <> DATE '2026-02-26' THEN
    RAISE EXCEPTION 'MIG 837 FAILED: 1 Mar should belong to the period starting 26 Feb.';
  END IF;
  IF timesheet_period_end(DATE '2026-01-26') <> DATE '2026-02-25' THEN
    RAISE EXCEPTION 'MIG 837 FAILED: a January anchor must end 25 Feb, not drift.';
  END IF;

  -- The old behaviour has to be EXACTLY preserved at start day 1, or every
  -- header already in the database quietly changes meaning.
  IF EXISTS (
    SELECT 1 FROM generate_series(DATE '2024-01-01', DATE '2027-12-31', INTERVAL '1 day') d
     WHERE timesheet_period_of(d::date, 1::smallint) <> date_trunc('month', d)::date)
  THEN
    RAISE EXCEPTION 'MIG 837 FAILED: at start day 1 the resolver disagrees with date_trunc over the test range. Existing headers would change meaning.';
  END IF;

  -- ── the label, and back again ────────────────────────────────────────────
  IF timesheet_period_label(DATE '2026-07-26') <> DATE '2026-08-01' THEN
    RAISE EXCEPTION 'MIG 837 FAILED: 26 Jul - 25 Aug must be called August.';
  END IF;
  IF timesheet_period_label(DATE '2026-08-01') <> DATE '2026-08-01' THEN
    RAISE EXCEPTION 'MIG 837 FAILED: a calendar month must still be called by its own name.';
  END IF;

  -- label(from_label(L)) = L, for both cycles, across four years. This is the
  -- round trip the client's period navigation depends on.
  FOREACH v_day IN ARRAY ARRAY[1::smallint, 26::smallint] LOOP
    IF EXISTS (
      SELECT 1 FROM generate_series(DATE '2024-01-01', DATE '2027-12-01', INTERVAL '1 month') m
       WHERE timesheet_period_label(timesheet_period_from_label(m::date, v_day)) <> m::date)
    THEN
      RAISE EXCEPTION 'MIG 837 FAILED: label/anchor round trip breaks at start day %.', v_day;
    END IF;
  END LOOP;

  -- Periods must tile the calendar with no gap and no overlap: the day after
  -- one period ends is the day the next one starts.
  FOREACH v_day IN ARRAY ARRAY[1::smallint, 26::smallint] LOOP
    IF EXISTS (
      SELECT 1 FROM generate_series(DATE '2024-01-01', DATE '2027-11-01', INTERVAL '1 month') m
       WHERE timesheet_period_end(timesheet_period_from_label(m::date, v_day)) + 1
             <> timesheet_period_from_label((m + INTERVAL '1 month')::date, v_day))
    THEN
      RAISE EXCEPTION 'MIG 837 FAILED: periods do not tile at start day % — there is a gap or an overlap between consecutive periods.', v_day;
    END IF;
  END LOOP;

  -- ── the constraints exist ────────────────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'timesheet_headers_no_overlapping_span') THEN
    RAISE EXCEPTION 'MIG 837 FAILED: the overlap constraint was not created, so two sheets could still cover one day.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conname = 'timesheet_headers_period_first_of_month') THEN
    RAISE EXCEPTION 'MIG 837 FAILED: the first-of-month CHECK is still in place; no 26th-anchored header could ever be created.';
  END IF;

  -- ── the setting took ─────────────────────────────────────────────────────
  IF (SELECT period_start_day FROM time_edit_config LIMIT 1) <> 26 THEN
    RAISE EXCEPTION 'MIG 837 FAILED: the cycle was not set to 26.';
  END IF;

  -- ── no call site still truncates ─────────────────────────────────────────
  FOR v_src IN
    SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries',
                         'paste_timesheet_day','time_employee_edit_floor',
                         'time_submission_due_date','timesheet_report_utilisation',
                         'timesheet_report_compliance','timesheet_report_project_summary',
                         'trg_time_holidays_recalc','trg_time_calendar_entries_recalc')
       AND pg_get_functiondef(p.oid) LIKE '%date_trunc(''month''%'
  LOOP
    RAISE EXCEPTION 'MIG 837 FAILED: %() still computes a period with date_trunc(''month''). It would disagree with every other caller the moment a cycle is not the 1st.', v_src;
  END LOOP;

  -- ── the guards read the snapshot, not the setting ────────────────────────
  FOR v_src IN
    SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries','paste_timesheet_day')
       AND pg_get_functiondef(p.oid) NOT LIKE '%v_header.period_start_day%'
  LOOP
    RAISE EXCEPTION 'MIG 837 FAILED: %() does not compare against the header''s own cycle. Flipping the global setting would make every existing timesheet un-writable.', v_src;
  END LOOP;

  RAISE NOTICE 'MIG 837 OK: cycle = 26, % headers carry a snapshot, overlap is a constraint.',
    (SELECT count(*) FROM timesheet_headers);
END;
$v$;

COMMIT;
