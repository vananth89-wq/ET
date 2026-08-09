-- ═══════════════════════════════════════════════════════════════════════════
-- Time Management backend health check — READ ONLY, safe on any environment.
-- Paste into the Supabase SQL editor. Every row should read PASS.
-- Re-run after any migration touching the time_* schema, and on UAT/Prod
-- before and after promotion.
-- ═══════════════════════════════════════════════════════════════════════════
WITH checks AS (

-- ── A. Table shapes ────────────────────────────────────────────────────────
SELECT 1 AS seq, 'A1 time_holidays is the POOL (no calendar_id)' AS "check",
  CASE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='time_holidays' AND column_name='calendar_id')
  THEN 'PASS' ELSE 'FAIL — mig 709 has not applied; the timesheet will silently see no holidays' END AS status
UNION ALL SELECT 2, 'A2 time_holidays has no holiday_date/year/country',
  CASE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='time_holidays'
          AND column_name IN ('holiday_date','holiday_year','country_code'))
  THEN 'PASS' ELSE 'FAIL — mig 710 columns not dropped' END
UNION ALL SELECT 3, 'A3 time_calendar_entries(calendar_id, entry_date, holiday_id)',
  CASE WHEN (SELECT count(*) FROM information_schema.columns
              WHERE table_schema='public' AND table_name='time_calendar_entries'
                AND column_name IN ('calendar_id','entry_date','holiday_id')) = 3
  THEN 'PASS' ELSE 'FAIL — mig 710 table missing or wrong shape' END
UNION ALL SELECT 4, 'A4 one holiday per date per calendar (unique)',
  CASE WHEN EXISTS (SELECT 1 FROM pg_constraint
        WHERE conname='time_calendar_entries_unique_date') THEN 'PASS'
  ELSE 'FAIL — duplicate dates possible in one calendar' END

-- ── B. RPCs the admin screens call ─────────────────────────────────────────
UNION ALL SELECT 5, 'B1 upsert_holiday is the POOL version',
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname='upsert_holiday')
        AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='upsert_holiday'
              AND prosrc LIKE '%calendar_id and holiday_date are required%')
  THEN 'PASS' ELSE 'FAIL — the mig 698 version is installed; Add Holiday will error' END
UNION ALL SELECT 6, 'B2 upsert_calendar_entry + delete_calendar_entry exist',
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname='upsert_calendar_entry')
        AND EXISTS (SELECT 1 FROM pg_proc WHERE proname='delete_calendar_entry')
  THEN 'PASS' ELSE 'FAIL — Holiday Calendars screen cannot save' END

-- ── C. Planned-minutes engine ──────────────────────────────────────────────
UNION ALL SELECT 7, 'C1 all 6 planned-minutes functions exist',
  CASE WHEN (SELECT count(DISTINCT proname) FROM pg_proc WHERE proname IN
        ('time_planned_minutes_for_date','time_recalc_planned_minutes',
         'time_apply_planned_recalc','time_holiday_calendar_changed',
         'time_work_schedule_changed','time_employment_assignment_changed')) = 6
  THEN 'PASS' ELSE 'FAIL — migs 722/723/724 incomplete' END
UNION ALL SELECT 8, 'C2 no function reads time_holidays.calendar_id',
  CASE WHEN NOT EXISTS (SELECT 1 FROM pg_proc
        WHERE proname IN ('time_planned_minutes_for_date','time_holiday_calendar_changed')
          AND prosrc ~ 'time_holidays[[:space:]]+[a-z]*[[:space:]]*,?.*calendar_id')
  THEN 'PASS' ELSE 'FAIL — still querying the pool table by calendar' END
UNION ALL SELECT 9, 'C3 snapshot wins over employment (mig 723 precedence)',
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname='time_planned_minutes_for_date'
          AND prosrc LIKE '%COALESCE(h.holiday_calendar_id%')
  THEN 'PASS' ELSE 'FAIL — employment overrides history; transfers rewrite closed months' END

-- ── D. Triggers ────────────────────────────────────────────────────────────
UNION ALL SELECT 10, 'D1 recalc trigger is on time_calendar_entries',
  CASE WHEN EXISTS (SELECT 1 FROM pg_trigger
        WHERE tgname='trg_time_calendar_entries_recalc' AND NOT tgisinternal)
  THEN 'PASS' ELSE 'FAIL — holiday edits will not recompute planned_minutes' END
UNION ALL SELECT 11, 'D2 old pool-table trigger removed',
  CASE WHEN NOT EXISTS (SELECT 1 FROM pg_trigger
        WHERE tgname='trg_time_holidays_recalc' AND NOT tgisinternal)
  THEN 'PASS' ELSE 'FAIL — mig 722 trigger still bound to the wrong table' END
UNION ALL SELECT 12, 'D3 schedule + assignment triggers present',
  CASE WHEN (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN
        ('trg_time_schedule_lines_recalc','trg_time_work_schedules_recalc',
         'trg_employment_assignment_recalc')) = 3
  THEN 'PASS' ELSE 'FAIL — schedule or transfer changes will not recompute' END
UNION ALL SELECT 13, 'D4 entry rules trigger live (half-day + activities)',
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname='enforce_timesheet_entry_rules')
        AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_timesheet_entry_rules' AND NOT tgisinternal)
  THEN 'PASS' ELSE 'FAIL — migs 718/721 rules are NOT enforced' END

-- ── E. Data consistency ────────────────────────────────────────────────────
UNION ALL SELECT 14, 'E1 every open header has a schedule snapshot',
  CASE WHEN NOT EXISTS (SELECT 1 FROM timesheet_headers
        WHERE work_schedule_id IS NULL
          AND period >= (date_trunc('month', CURRENT_DATE) - INTERVAL '6 months')::date)
  THEN 'PASS' ELSE 'FAIL — planned_minutes will compute as 0 for those months' END
UNION ALL SELECT 15, 'E2 every open header has a calendar snapshot',
  CASE WHEN NOT EXISTS (SELECT 1 FROM timesheet_headers
        WHERE holiday_calendar_id IS NULL
          AND period >= (date_trunc('month', CURRENT_DATE) - INTERVAL '6 months')::date)
  THEN 'PASS' ELSE 'WARN — falls back to employment, but the snapshot should be filled' END
UNION ALL SELECT 16, 'E3 planned_minutes agrees with schedule + calendar',
  COALESCE((SELECT CASE WHEN count(*) = 0 THEN 'PASS'
              ELSE 'FAIL — ' || count(*) || ' header(s) stale' END
     FROM timesheet_headers h
    WHERE h.period >= (date_trunc('month', CURRENT_DATE) - INTERVAL '6 months')::date
      AND h.planned_minutes IS DISTINCT FROM (
            SELECT COALESCE(SUM(time_planned_minutes_for_date(h.id, d::date)), 0)
              FROM generate_series(h.period,
                                   (h.period + INTERVAL '1 month' - INTERVAL '1 day')::date,
                                   INTERVAL '1 day') AS d)), 'PASS')
UNION ALL SELECT 17, 'E4 recorded_minutes agrees with the entries',
  COALESCE((SELECT CASE WHEN count(*) = 0 THEN 'PASS'
              ELSE 'FAIL — ' || count(*) || ' header(s) out of sync' END
     FROM timesheet_headers h
    WHERE h.recorded_minutes IS DISTINCT FROM
          COALESCE((SELECT SUM(e.hours_minutes) FROM timesheet_entries e
                     WHERE e.header_id = h.id), 0)), 'PASS')
UNION ALL SELECT 18, 'E5 no holiday stored as an attendance row',
  CASE WHEN NOT EXISTS (SELECT 1 FROM timesheet_entries WHERE entry_kind='holiday')
  THEN 'PASS' ELSE 'WARN — holidays should be derived, never stored' END
UNION ALL SELECT 19, 'E6 no calendar entry points at a missing holiday',
  CASE WHEN NOT EXISTS (SELECT 1 FROM time_calendar_entries ce
        WHERE NOT EXISTS (SELECT 1 FROM time_holidays h WHERE h.id = ce.holiday_id))
  THEN 'PASS' ELSE 'FAIL — orphaned calendar entries' END
UNION ALL SELECT 20, 'E7 no leave on a zero-planned day',
  COALESCE((SELECT CASE WHEN count(*) = 0 THEN 'PASS'
              ELSE 'WARN — ' || count(*) || ' leave row(s) on a non-working day' END
     FROM timesheet_entries e
    WHERE e.entry_kind = 'leave'
      AND time_planned_minutes_for_date(e.header_id, e.entry_date) = 0), 'PASS')
)
SELECT seq, "check", status FROM checks ORDER BY seq;
