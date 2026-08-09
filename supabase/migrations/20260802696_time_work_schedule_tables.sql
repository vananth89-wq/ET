-- Migration : 20260802696_time_work_schedule_tables.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: Create time_work_schedules and time_work_schedule_lines EARLY ENOUGH
--              for the migrations that depend on them.
--
-- THE PROBLEM
--   These two tables are created by exactly one file in this repository:
--   20260803001_time_work_schedules_repair.sql. Migrations run in filename order,
--   and 20260803001 sorts AFTER 20260802703, which is the first migration that
--   needs them. On a clean replay the whole Time Management chain then falls over
--   in sequence:
--
--     703  -> relation "time_work_schedules" does not exist
--     704  -> relation "time_work_schedules" does not exist
--     705  -> relation "timesheet_headers" does not exist      (704 never ran)
--     710  -> function _set_updated_at() does not exist         (704/705 define it)
--     715, 716, 717, 718, 719, 721, 722, 723, 724, 726  -> all cascade
--
--   Fourteen failures from one ordering mistake. 20260803001 calls itself a
--   "repair" because the tables "were already created on remote" -- they were
--   made by hand, so nothing ever noticed the file was in the wrong place.
--
-- WHY THIS FILE RATHER THAN RENAMING 20260803001
--   Renaming an ALREADY-APPLIED migration breaks deployment. Measured with the
--   pinned CLI (2.113.0) against a real ledger on 2026-08-09:
--
--     * Adding a NEW file with an early version  -> `db push --include-all`
--       applies only that file, records it in the right place, re-runs nothing.
--       Clean.
--     * RENAMING a file that the ledger already contains -> `db push` HARD-FAILS
--       with LegacyDbPushMissingLocalError before applying anything, and stays
--       failed until someone runs `supabase migration repair --status reverted`
--       against every environment. Dev, UAT and eventually Prod would each need
--       manual intervention, and no deploy could land in between.
--
--   So 20260803001 is left exactly where it is. It remains fully idempotent
--   (CREATE TABLE IF NOT EXISTS, policies guarded by EXCEPTION duplicate_object,
--   CREATE OR REPLACE for the RPC), so once this file has run it simply finds its
--   work already done and continues to create the RLS policies and
--   upsert_work_schedule() as it always has.
--
-- SCOPE
--   Tables and index only -- the minimum that unblocks the chain. RLS, policies
--   and the RPC deliberately stay in 20260803001: duplicating them here would be
--   two definitions of the same thing, and nothing queries these tables in the
--   gap between the two files.
--
-- EFFECT ON EXISTING ENVIRONMENTS
--   None. Dev and UAT already have both tables, so every statement here is a
--   no-op. This file exists so that migrations alone can build a database from
--   zero, which is the only thing that was ever broken.

CREATE TABLE IF NOT EXISTS time_work_schedules (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text        NOT NULL,
  code               text        NOT NULL,
  start_day_of_week  smallint    NOT NULL CHECK (start_day_of_week BETWEEN 0 AND 6),
  is_active          boolean     NOT NULL DEFAULT true,
  created_by         uuid        REFERENCES profiles(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_work_schedules_code_key UNIQUE (code)
);

CREATE TABLE IF NOT EXISTS time_work_schedule_lines (
  id                uuid     PRIMARY KEY DEFAULT gen_random_uuid(),
  work_schedule_id  uuid     NOT NULL REFERENCES time_work_schedules(id) ON DELETE CASCADE,
  day_number        smallint NOT NULL CHECK (day_number BETWEEN 1 AND 7),
  planned_minutes   integer  NOT NULL CHECK (planned_minutes >= 0),
  CONSTRAINT time_work_schedule_lines_unique UNIQUE (work_schedule_id, day_number)
);

CREATE INDEX IF NOT EXISTS idx_time_work_schedule_lines_schedule
  ON time_work_schedule_lines (work_schedule_id);

COMMENT ON TABLE time_work_schedules IS
  'Working-time patterns. Created by mig 20260802696 so the Time Management chain '
  'can replay from zero; 20260803001 remains the owner of its RLS policies and RPC.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'time_work_schedules') THEN
    RAISE EXCEPTION 'ABORT: time_work_schedules not created.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'time_work_schedule_lines') THEN
    RAISE EXCEPTION 'ABORT: time_work_schedule_lines not created.';
  END IF;
  RAISE NOTICE 'Migration 696 verified: work schedule tables exist before the migrations that need them.';
END $$;
