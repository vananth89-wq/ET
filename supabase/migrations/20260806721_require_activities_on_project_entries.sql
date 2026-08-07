-- Migration : 20260806721_require_activities_on_project_entries.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: An entry whose time type has requires_project = true must name at least one
--              activity — project time has to say what the work was. Enforced in the client
--              (day panel + Create modal) and here, so bulk paste and any direct API call are
--              covered too.
--
--              DELIBERATELY INSERT-ONLY. Entries created before this rule existed may have no
--              activities; enforcing on UPDATE would reject the next edit of those rows with a
--              rule that did not exist when they were written. New rows must comply; legacy
--              rows stay editable. Revisit only if the legacy set is backfilled.

CREATE OR REPLACE FUNCTION public.enforce_timesheet_entry_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_planned   integer;
  v_half      boolean;
  v_needs_prj boolean;
  v_other_abs integer;
  v_other_att integer;
  v_blocking  integer;
BEGIN
  -- System-generated rows (holiday sync, leave module) bypass these rules.
  IF NEW.is_system_generated THEN RETURN NEW; END IF;

  v_planned := time_planned_minutes_for_date(NEW.header_id, NEW.entry_date);

  IF NEW.entry_kind = 'leave' THEN
    -- (a) no leave on a day that was never scheduled
    IF v_planned = 0 THEN
      RAISE EXCEPTION 'Leave cannot be recorded on a non-working day or public holiday.'
        USING ERRCODE = 'check_violation';
    END IF;

    -- (b) at most one absence per day
    SELECT count(*) INTO v_other_abs
    FROM   timesheet_entries e
    WHERE  e.header_id  = NEW.header_id
      AND  e.entry_date = NEW.entry_date
      AND  e.entry_kind = 'leave'
      AND  e.id IS DISTINCT FROM NEW.id;
    IF v_other_abs > 0 THEN
      RAISE EXCEPTION 'Only one leave entry is allowed per day.'
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(tt.allows_half_day, false) INTO v_half
    FROM time_types tt WHERE tt.id = NEW.time_type_id;

    IF NOT COALESCE(v_half, false) THEN
      -- (c) a full-day-only leave must cover exactly the planned day
      IF NEW.hours_minutes <> v_planned THEN
        RAISE EXCEPTION 'This leave type must be recorded as a full day (% minutes).', v_planned
          USING ERRCODE = 'check_violation';
      END IF;
      -- (d) and nothing else may share the day
      SELECT count(*) INTO v_other_att
      FROM   timesheet_entries e
      WHERE  e.header_id  = NEW.header_id
        AND  e.entry_date = NEW.entry_date
        AND  e.entry_kind <> 'leave'
        AND  e.id IS DISTINCT FROM NEW.id;
      IF v_other_att > 0 THEN
        RAISE EXCEPTION 'A full-day leave cannot be recorded on a day that already has attendance.'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;

  ELSE
    -- attendance: blocked only by a full-day-only leave already on the day
    SELECT count(*) INTO v_blocking
    FROM   timesheet_entries e
    JOIN   time_types tt ON tt.id = e.time_type_id
    WHERE  e.header_id  = NEW.header_id
      AND  e.entry_date = NEW.entry_date
      AND  e.entry_kind = 'leave'
      AND  COALESCE(tt.allows_half_day, false) = false
      AND  e.id IS DISTINCT FROM NEW.id;
    IF v_blocking > 0 THEN
      RAISE EXCEPTION 'A full-day leave is already recorded for this day.'
        USING ERRCODE = 'check_violation';
    END IF;

    -- (e) project time must name at least one activity. INSERT only — see header.
    IF TG_OP = 'INSERT' THEN
      SELECT COALESCE(tt.requires_project, false) INTO v_needs_prj
      FROM time_types tt WHERE tt.id = NEW.time_type_id;

      IF COALESCE(v_needs_prj, false)
         AND (NEW.activities IS NULL
              OR array_length(NEW.activities, 1) IS NULL
              OR NOT EXISTS (SELECT 1 FROM unnest(NEW.activities) a WHERE btrim(a) <> '')) THEN
        RAISE EXCEPTION 'At least one activity is required for project time.'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_timesheet_entry_rules() FROM PUBLIC;
COMMENT ON FUNCTION public.enforce_timesheet_entry_rules IS
  'Mig 721: half-day leave rules (from 718) plus at-least-one-activity on INSERT for time types with requires_project.';

-- Trigger definition unchanged; recreated for idempotency.
DROP TRIGGER IF EXISTS trg_timesheet_entry_rules ON public.timesheet_entries;
CREATE TRIGGER trg_timesheet_entry_rules
  BEFORE INSERT OR UPDATE ON public.timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION public.enforce_timesheet_entry_rules();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_timesheet_entry_rules') THEN
    RAISE EXCEPTION 'ABORT: trg_timesheet_entry_rules missing.';
  END IF;
  RAISE NOTICE 'Migration 721 verified: activities required on new project entries.';
END $$;
