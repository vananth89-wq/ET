-- Migration : 20260813738_daily_hours_cap.sql
-- Purpose   : Put a ceiling on the hours that can be recorded against one day,
--             and a softer line above which a day is merely unusual.
--
-- WHY
--   Prowess is duration-only -- there is no clock-in, no clock-out, nothing
--   physical bounding an entry. Today a typo of "80" instead of "8" is accepted
--   by every layer: the trigger, all three write RPCs, the recalc, the report.
--   The red "over planned" signal shipped alongside this says only "more than
--   scheduled", which is also what an honest 10-hour day says.
--
-- TWO THRESHOLDS, because one number cannot both permit real long days and
-- refuse nonsense:
--
--   HARD  16h (960 min) per day, refused. A data-integrity rule, not policy.
--         24h is the physical bound and catches almost nothing; 16h catches
--         every realistic fat-finger and still sits above any defensible day.
--         Per work schedule, so the first shift pattern that is not GEN can
--         differ, with a system default when the column is null.
--
--   SOFT  planned + 4h, allowed and reported back. Genuinely long days happen;
--         the point is that nobody is surprised by them later.
--
--   LEAVE COUNTS toward both. The cap is about hours recorded against a date,
--   whatever their kind -- a half day of leave plus a full day of work is 12
--   hours against one date however it is labelled.
--
-- WHERE THE RULE LIVES
--   In the trigger. Not in the RPCs. There are three write paths into
--   timesheet_entries -- save_timesheet_entry, bulk_create_timesheet_entries,
--   paste_timesheet_day -- and migrations 734 and 736 exist because a rule
--   written into one of them drifted out of the others. The RPCs get the check
--   too, but only so they can produce a message worth reading; the trigger is
--   what makes the rule TRUE.
--
-- THE RULE THAT MATTERS MOST
--   A save is refused only when it INCREASES a day that would be over the cap.
--   Days recorded before this migration, or after a schedule's cap is lowered,
--   stay editable and reducible. Without this the first thing a cap does is
--   trap someone in a day they cannot correct.
--
-- COPY DAY gets the cap almost free: paste_timesheet_day already refuses a
--   target holding any row at all, so a pasted day's total IS the source day's
--   total. The one gap is a legacy SOURCE day already over the cap, which would
--   otherwise fail inside the trigger mid-paste and surface as UNEXPECTED_ERROR.
--   PART 5 checks the source by name instead.
--
-- Depends on : 726 (rules a-g), 727 (activities), 729/736 (allows_future),
--              730/734 (status guard), 733 (append), 735/737 (paste)

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 0 — where the number lives
-- ═══════════════════════════════════════════════════════════════════════════
-- On the schedule, beside the daily plan, because that is where "what a normal
-- day looks like" is already described. A single global setting would be wrong
-- for the first roster that is not GEN, and there is no org-settings table this
-- belongs in more naturally.
--
-- NULL means "use the system default" rather than "no limit". A schedule with
-- no opinion should still be protected from an 80-hour Tuesday.

ALTER TABLE public.time_work_schedules
  ADD COLUMN IF NOT EXISTS max_daily_minutes integer;

DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'time_work_schedules_max_daily_minutes_check') THEN
    ALTER TABLE public.time_work_schedules
      ADD CONSTRAINT time_work_schedules_max_daily_minutes_check
      CHECK (max_daily_minutes IS NULL OR (max_daily_minutes > 0 AND max_daily_minutes <= 1440));
  END IF;
END $mig$;

COMMENT ON COLUMN public.time_work_schedules.max_daily_minutes IS
  'Hard ceiling on minutes recorded against one day, all entry kinds included. '
  'NULL uses the system default of 960 (16h) -- see time_daily_cap_minutes_for_date.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 0b — let the admin form actually set it
-- ═══════════════════════════════════════════════════════════════════════════
-- A column no screen can write is a column that stays null forever. Patched in
-- place from the live body for the usual reason: upsert_work_schedule may carry
-- changes that no file holds.
--
-- Absent from the payload means "leave it alone" on update, so an older client
-- posting without the key cannot silently reset a configured cap; an explicit
-- JSON null clears it back to the default.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;
  v_ins  text := '  INSERT INTO time_work_schedules (id, name, code, start_day_of_week, is_active, created_by)';
  v_val  text := '  VALUES (v_id, trim(p_data->>''name''), upper(trim(p_data->>''code'')), (p_data->>''start_day_of_week'')::smallint, COALESCE((p_data->>''is_active'')::boolean, true), auth.uid())';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_work_schedule';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 738: upsert_work_schedule not found.';
  END IF;

  IF position('max_daily_minutes' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 738: upsert_work_schedule already carries max_daily_minutes. Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_ins, ''))) / length(v_ins);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 INSERT column list in upsert_work_schedule, found %.', v_hits;
  END IF;
  v_new := replace(v_src, v_ins,
    '  INSERT INTO time_work_schedules (id, name, code, start_day_of_week, is_active, max_daily_minutes, created_by)');

  v_hits := (length(v_new) - length(replace(v_new, v_val, ''))) / length(v_val);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 VALUES list in upsert_work_schedule, found %.', v_hits;
  END IF;
  v_new := replace(v_new, v_val,
    '  VALUES (v_id, trim(p_data->>''name''), upper(trim(p_data->>''code'')), (p_data->>''start_day_of_week'')::smallint, COALESCE((p_data->>''is_active'')::boolean, true), NULLIF(p_data->>''max_daily_minutes'','''')::integer, auth.uid())');

  v_new := replace(v_new,
    'start_day_of_week=EXCLUDED.start_day_of_week, is_active=EXCLUDED.is_active, updated_at=now();',
    'start_day_of_week=EXCLUDED.start_day_of_week, is_active=EXCLUDED.is_active, '
    || 'max_daily_minutes = CASE WHEN p_data ? ''max_daily_minutes'' '
    || 'THEN NULLIF(p_data->>''max_daily_minutes'','''')::integer '
    || 'ELSE time_work_schedules.max_daily_minutes END, updated_at=now();');

  EXECUTE v_new;
  RAISE NOTICE 'MIG 738: upsert_work_schedule writes max_daily_minutes.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — one function per threshold, so nothing can disagree about the number
-- ═══════════════════════════════════════════════════════════════════════════
-- Shaped after time_planned_minutes_for_date, including how it resolves the
-- schedule: the header's own work_schedule_id when it has one, otherwise the
-- employee's current employment row. Four callers read these; none of them
-- should carry its own copy of 960 or of "+ 4 hours".

CREATE OR REPLACE FUNCTION public.time_daily_cap_minutes_for_date(
  p_header_id uuid,
  p_date      date
) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
  SELECT COALESCE((
    SELECT ws.max_daily_minutes
    FROM   timesheet_headers h
    JOIN   time_work_schedules ws ON ws.id = COALESCE(h.work_schedule_id, (
             SELECT ee.work_schedule_id FROM employee_employment ee
              WHERE ee.employee_id = h.employee_id
                AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
                AND ee.work_schedule_id IS NOT NULL
              LIMIT 1))
    WHERE  h.id = p_header_id
  ), 960);   -- 16h. The default, not a fallback for a broken lookup: a schedule
             -- with no opinion still gets a ceiling.
$fn$;

REVOKE ALL ON FUNCTION public.time_daily_cap_minutes_for_date(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_daily_cap_minutes_for_date(uuid, date) TO authenticated;

/**
 * The soft line: planned + 4h.
 *
 * Zero on a day with no plan. A weekend has no target to be four hours beyond,
 * and every hour on it is already flagged as over-schedule by the calendar, the
 * day chip and the summary table -- warning about it a second time would be
 * noise. The HARD cap still applies to those days.
 */
CREATE OR REPLACE FUNCTION public.time_daily_soft_minutes_for_date(
  p_header_id uuid,
  p_date      date
) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
  SELECT CASE
    WHEN time_planned_minutes_for_date(p_header_id, p_date) > 0
      THEN time_planned_minutes_for_date(p_header_id, p_date) + 240
    ELSE 0
  END;
$fn$;

REVOKE ALL ON FUNCTION public.time_daily_soft_minutes_for_date(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_daily_soft_minutes_for_date(uuid, date) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — rule (i) in the trigger: the rule itself
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;
  v_decl text := '  v_future    boolean;';
  v_tail text := '  RETURN NEW;' || E'\n' || 'END;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'enforce_timesheet_entry_rules';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 738: enforce_timesheet_entry_rules not found.';
  END IF;

  IF position('time_daily_cap_minutes_for_date' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 738: the trigger already carries rule (i). Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_decl, ''))) / length(v_decl);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 v_future declaration in the trigger, found %.', v_hits;
  END IF;
  v_new := replace(v_src, v_decl, v_decl || E'\n' ||
    '  v_cap       integer;' || E'\n' ||
    '  v_day_prior integer;' || E'\n' ||
    '  v_day_new   integer;');

  v_hits := (length(v_new) - length(replace(v_new, v_tail, ''))) / length(v_tail);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 "RETURN NEW; END;" tail in the trigger, found %.', v_hits;
  END IF;

  v_new := replace(v_new, v_tail, $rule$  -- (i) MIG 738 -- a day has a ceiling.
  --     Every entry kind counts, leave included: the question is how many hours
  --     are recorded against this DATE, not what they are called.
  --
  --     INSERT and UPDATE both, unlike rules (e)-(h) -- those are INSERT-only so
  --     that rows written before them stay editable. That reasoning does not
  --     transfer: an edit is exactly how a 6h day becomes a 60h day, and the
  --     increase-only test below already protects existing rows without
  --     needing the rule switched off for them.
  --
  --     A save is refused only when it INCREASES a day that ends up over the
  --     cap. A day already over it -- recorded before this rule, or left over
  --     after a schedule's cap was lowered -- can still be edited and reduced.
  --     Refusing every write to such a day would trap someone in it.
  v_cap := time_daily_cap_minutes_for_date(NEW.header_id, NEW.entry_date);

  SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_day_prior
  FROM   timesheet_entries e
  WHERE  e.header_id  = NEW.header_id
    AND  e.entry_date = NEW.entry_date;

  -- BEFORE trigger: on INSERT the new row is not in that sum yet; on UPDATE the
  -- old value still is, so it comes back out.
  v_day_new := v_day_prior
             - CASE WHEN TG_OP = 'UPDATE' THEN COALESCE(OLD.hours_minutes, 0) ELSE 0 END
             + COALESCE(NEW.hours_minutes, 0);

  IF v_day_new > v_cap AND v_day_new > v_day_prior THEN
    -- Built as one string rather than four RAISE placeholders: '%h' reads as a
    -- placeholder followed by the letter h, which is fine, but '%m' next to it
    -- is a trap and produced '16h 50sm' the first time this was written.
    RAISE EXCEPTION 'This would put % on %, over the % daily limit.',
      (v_day_new / 60) || 'h ' || lpad((v_day_new % 60)::text, 2, '0') || 'm',
      to_char(NEW.entry_date, 'FMDD FMMonth'),
      (v_cap / 60) || 'h'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;$rule$);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 738: enforce_timesheet_entry_rules now carries rule (i).';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — the day panel: save_timesheet_entry
-- ═══════════════════════════════════════════════════════════════════════════
-- The trigger already refuses; this exists so the refusal names the day, the
-- arithmetic and the limit. An employee cannot see the day's running total from
-- the entry form, so "over the limit" without the numbers is not actionable.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;
  v_anchor text :=
'  IF v_total IS NULL OR v_total <= 0 THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''INVALID_DURATION'',' || E'\n' ||
'      ''message'', ''Duration must be greater than 0.'');' || E'\n' ||
'  END IF;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'save_timesheet_entry';

  IF position('DAILY_CAP' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 738: save_timesheet_entry already checks the daily cap. Nothing to do.';
    RETURN;
  END IF;

  -- declarations
  v_hits := (length(v_src) - length(replace(v_src, '  v_n        integer := 0;', ''))) / length('  v_n        integer := 0;');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 v_n declaration in save_timesheet_entry, found %.', v_hits;
  END IF;
  v_new := replace(v_src, '  v_n        integer := 0;',
    '  v_n        integer := 0;' || E'\n' ||
    '  v_cap      integer;' || E'\n' ||
    '  v_soft     integer;' || E'\n' ||
    '  v_day_prior integer;' || E'\n' ||
    '  v_day_new  integer;' || E'\n' ||
    '  v_warn     text;');

  v_hits := (length(v_new) - length(replace(v_new, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 INVALID_DURATION block in save_timesheet_entry, found %.', v_hits;
  END IF;

  v_new := replace(v_new, v_anchor, v_anchor || E'\n' || E'\n' || $cap$  -- ═════════════════════════════════════════════════════════════════════════
  -- MIG 738 — the day's ceiling
  --
  -- Checked here as well as in the trigger so the refusal can carry the
  -- arithmetic. The entry form shows one entry; the employee cannot see that
  -- the day already holds 12 hours, so "over the limit" alone reads as the
  -- system being obstinate.
  --
  -- The day sum EXCLUDES the row being edited and includes everything else,
  -- leave and other projects alike. On an append the duplicate row is still in
  -- the sum and v_total is what is being added to it, which is the right
  -- arithmetic for both paths.
  -- ═════════════════════════════════════════════════════════════════════════
  v_cap  := time_daily_cap_minutes_for_date(p_header_id, v_date);
  v_soft := time_daily_soft_minutes_for_date(p_header_id, v_date);

  SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_day_prior
  FROM   timesheet_entries e
  WHERE  e.header_id = p_header_id AND e.entry_date = v_date;

  v_day_new := v_total + COALESCE((
    SELECT sum(e.hours_minutes) FROM timesheet_entries e
    WHERE  e.header_id = p_header_id AND e.entry_date = v_date
      AND  (p_entry_id IS NULL OR e.id <> p_entry_id)), 0);

  IF v_day_new > v_cap AND v_day_new > v_day_prior THEN
    RETURN jsonb_build_object('ok', false, 'error', 'DAILY_CAP',
      'message', format('%s already holds %sh %sm. Adding this would make %sh %sm, over the %sh daily limit.',
                        to_char(v_date, 'FMDD FMMonth'),
                        v_day_prior / 60, lpad((v_day_prior % 60)::text, 2, '0'),
                        v_day_new / 60,   lpad((v_day_new % 60)::text, 2, '0'),
                        v_cap / 60));
  END IF;

  -- The soft line. Not a refusal — a long day is a fact, and this is how the
  -- employee hears about it at the moment they record it rather than when a
  -- manager reads the report.
  IF v_soft > 0 AND v_day_new > v_soft THEN
    v_warn := format('%s now holds %sh %sm, more than 4 hours beyond the %sh scheduled.',
                     to_char(v_date, 'FMDD FMMonth'),
                     v_day_new / 60, lpad((v_day_new % 60)::text, 2, '0'),
                     time_planned_minutes_for_date(p_header_id, v_date) / 60);
  END IF;$cap$);

  -- both success returns carry the warning; null when there is none
  v_new := replace(v_new,
    'RETURN jsonb_build_object(''ok'', true, ''appended'', true, ''entry_id'', v_id,',
    'RETURN jsonb_build_object(''ok'', true, ''warning'', v_warn, ''appended'', true, ''entry_id'', v_id,');
  v_new := replace(v_new,
    'RETURN jsonb_build_object(''ok'', true, ''appended'', false, ''entry_id'', v_id,',
    'RETURN jsonb_build_object(''ok'', true, ''warning'', v_warn, ''appended'', false, ''entry_id'', v_id,');

  EXECUTE v_new;
  RAISE NOTICE 'MIG 738: save_timesheet_entry checks the daily cap and reports long days.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — the Create modal: bulk_create_timesheet_entries
-- ═══════════════════════════════════════════════════════════════════════════
-- All-or-nothing, like every other refusal in this function: the dates that
-- would breach come back in a `dates` array, the modal already renders that as
-- a list with a "Deselect these N dates" button, and nothing is written.
-- Creating 9 of 12 and silently skipping 3 is the failure mode 733 was written
-- to remove from this codebase, not one to reintroduce.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;
  v_lookup text :=
'    SELECT e.id, e.is_system_generated INTO v_existing, v_sysgen' || E'\n' ||
'    FROM   timesheet_entries e' || E'\n' ||
'    WHERE  e.header_id    =  p_header_id' || E'\n' ||
'      AND  e.entry_date   =  v_d';
  v_write text := '  -- ── Write: creates first, then appends ───────────────────────────────────';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'bulk_create_timesheet_entries';

  IF position('DAILY_CAP' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 738: bulk_create_timesheet_entries already checks the daily cap. Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, '  v_leave_min integer;', ''))) / length('  v_leave_min integer;');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 v_leave_min declaration in bulk_create, found %.', v_hits;
  END IF;
  v_new := replace(v_src, '  v_leave_min integer;',
    '  v_leave_min integer;' || E'\n' ||
    '  v_overcap   date[] := ''{}'';' || E'\n' ||
    '  v_warned    date[] := ''{}'';' || E'\n' ||
    '  v_cap       integer;' || E'\n' ||
    '  v_soft      integer;' || E'\n' ||
    '  v_day_min   integer;');

  v_hits := (length(v_new) - length(replace(v_new, v_lookup, ''))) / length(v_lookup);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 duplicate lookup in bulk_create, found %.', v_hits;
  END IF;

  v_new := replace(v_new, v_lookup, $cap$    -- MIG 738: the day's ceiling, per selected date. Same arithmetic as the
    -- day panel — what the day holds now, plus what this would add.
    v_cap  := time_daily_cap_minutes_for_date(p_header_id, v_d);
    v_soft := time_daily_soft_minutes_for_date(p_header_id, v_d);

    SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_day_min
    FROM   timesheet_entries e
    WHERE  e.header_id = p_header_id AND e.entry_date = v_d;

    IF v_day_min + v_mins > v_cap THEN
      v_overcap := v_overcap || v_d;
      CONTINUE;
    END IF;

    IF v_soft > 0 AND v_day_min + v_mins > v_soft THEN
      v_warned := v_warned || v_d;
    END IF;

$cap$ || v_lookup);

  -- The refusal goes LAST, after ALREADY_EXISTS. When a date both duplicates an
  -- existing (type, project) and would breach the cap, "already recorded" is the
  -- more useful sentence — it points at a row the employee can open.
  v_hits := (length(v_new) - length(replace(v_new, v_write, ''))) / length(v_write);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 write marker in bulk_create, found %.', v_hits;
  END IF;

  v_new := replace(v_new, v_write, $ref$  IF array_length(v_overcap, 1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'DAILY_CAP',
      'dates', to_jsonb(v_overcap),
      'message', format('Adding %sh %sm would take one or more of the selected dates over the daily limit.',
                        v_mins / 60, lpad((v_mins % 60)::text, 2, '0')));
  END IF;

$ref$ || v_write);

  -- Success carries the days that went long. Not an error: they were created.
  v_new := replace(v_new,
    '    ''dates'', to_jsonb(v_dates)' || E'\n' || '  );',
    '    ''dates'', to_jsonb(v_dates),' || E'\n' ||
    '    ''warned_dates'', to_jsonb(v_warned)' || E'\n' || '  );');

  EXECUTE v_new;
  RAISE NOTICE 'MIG 738: bulk_create_timesheet_entries refuses over-cap dates and reports long days.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — Copy Day: paste_timesheet_day
-- ═══════════════════════════════════════════════════════════════════════════
-- Copy Day cannot normally breach the cap: 735 refuses a target holding any row
-- at all, so the pasted day's total is the source day's total, and a source
-- within the cap produces a target within it.
--
-- The exception is a SOURCE day already over the cap — recorded before this
-- migration, or left over after a schedule's cap was lowered. Rule (i) permits
-- that day to keep existing but would refuse the INSERTs that copy it, mid-loop,
-- and 735 deliberately does not return SQLERRM. Without this the employee would
-- get an unexplained failure. Say it plainly instead, before anything is written.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;
  v_anchor text :=
'  IF v_rows = 0 THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''NOTHING_TO_COPY'',' || E'\n' ||
'      ''message'', ''That day has no attendance to copy.'');' || E'\n' ||
'  END IF;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF position('SOURCE_OVER_CAP' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 738: paste_timesheet_day already checks the source against the cap. Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 738: expected exactly 1 NOTHING_TO_COPY block in paste_timesheet_day, found %.', v_hits;
  END IF;

  v_new := replace(v_src, v_anchor, v_anchor || E'\n' || E'\n' || $cap$  -- MIG 738: a source day that is itself over the target day's cap cannot be
  -- copied. Only the rows Copy Day would actually carry are counted — leave,
  -- holidays and system rows are excluded from the paste, so counting them here
  -- would refuse a copy that never breached anything.
  DECLARE
    v_src_min integer;
    v_cap     integer;
  BEGIN
    SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_src_min
    FROM   timesheet_entries e
    WHERE  e.header_id  = p_header_id
      AND  e.entry_date = p_from_date
      AND  e.entry_kind NOT IN ('leave', 'holiday')
      AND  NOT COALESCE(e.is_system_generated, false);

    v_cap := time_daily_cap_minutes_for_date(p_header_id, p_to_date);

    IF v_src_min > v_cap THEN
      RETURN jsonb_build_object('ok', false, 'error', 'SOURCE_OVER_CAP',
        'message', format('%s holds %sh %sm, over the %sh daily limit, so it cannot be copied.',
                          to_char(p_from_date, 'FMDD FMMonth'),
                          v_src_min / 60, lpad((v_src_min % 60)::text, 2, '0'),
                          v_cap / 60));
    END IF;
  END;$cap$);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 738: paste_timesheet_day refuses a source day that is over the cap.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 6 — assert EVERY rule these functions should carry
-- ═══════════════════════════════════════════════════════════════════════════
-- Extending 736's list rather than starting a new one. The defect this guards
-- against is not any single missing rule: it is that a CREATE OR REPLACE built
-- from an older file silently drops every in-place patch since, and each fix so
-- far asserted only its own contribution.
--
-- ADD TO THESE LISTS when a migration adds a rule.
--
-- NOTE THE ::text CASTS. Without them `v_missing || 'some text'` resolves to
-- array || array, Postgres tries to parse the message AS an array literal, and
-- the block dies with "malformed array literal" instead of reporting what is
-- missing. Migrations 734, 736 and 737 carry the same pattern uncast; it has
-- never fired there because every append is on a failure path, so the bug is
-- latent rather than harmless -- the one time those blocks are needed they
-- would report the wrong thing. Worth a follow-up to correct them in place.

DO $mig$
DECLARE
  v_src     text;
  v_missing text[] := '{}';
BEGIN
  -- ── save_timesheet_entry ────────────────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'save_timesheet_entry';

  IF position('DAILY_CAP' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 738: daily cap refused in the day panel'::text; END IF;
  IF position('v_header.status = ''to_be_approved''' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 730/734: approved months editable, pending ones not'::text; END IF;
  IF position('allows_future' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 729/736: allows_future honoured per time type'::text; END IF;
  IF position('ON CONFLICT (entry_id, lower(btrim(activity_name)))' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 733: same-name activity rows summed on append'::text; END IF;
  IF position('LEGACY_NEEDS_SPLIT' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 733: legacy entry refused rather than guessed at'::text; END IF;
  IF position('ALREADY_EXISTS' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 733: duplicate (day, type, project) named, not leaked'::text; END IF;
  IF position('ACTIVITY_REQUIRED' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 727/728: project time must be itemised'::text; END IF;
  IF position('OUTSIDE_PERIOD' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 728: entry must fall inside the header period'::text; END IF;
  IF position('SYSTEM_ROW' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 728: system-generated rows not editable here'::text; END IF;
  IF position('v_header.status <> ''to_be_submitted''' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: the pre-730 status guard is back'::text; END IF;
  IF position('''message'', SQLERRM' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: SQLERRM returned as the user-facing message'::text; END IF;

  -- ── bulk_create_timesheet_entries ───────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'bulk_create_timesheet_entries';

  IF position('DAILY_CAP' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 738: daily cap refused in the Create modal'::text; END IF;
  IF position('warned_dates' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 738: long days reported back from Create'::text; END IF;
  IF position('allows_future' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 729: allows_future honoured per time type'::text; END IF;
  IF position('DAY_FULLY_ABSENT' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 726 (f)/(g): day occupancy'::text; END IF;

  -- ── paste_timesheet_day ─────────────────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF position('SOURCE_OVER_CAP' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 738: an over-cap source day cannot be copied'::text; END IF;
  IF position('TARGET_NOT_EMPTY' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 735: paste only into an empty day'::text; END IF;
  IF position('allows_future' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 737: future paste gated per time type'::text; END IF;

  -- ── the trigger ─────────────────────────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'enforce_timesheet_entry_rules';

  IF position('time_daily_cap_minutes_for_date' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 738 rule (i): the cap is enforced in the trigger'::text; END IF;
  IF position('allows_future' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 729 rule (h): advance dating gated per time type'::text; END IF;

  -- ── upsert_work_schedule ────────────────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'upsert_work_schedule';

  IF position('max_daily_minutes' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 738: the admin form can set the cap'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 738 ABORT: rules are missing:\n  - %',
      array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 738 verified: the cap is enforced in the trigger and named by all three RPCs.';
END $mig$;

COMMIT;
