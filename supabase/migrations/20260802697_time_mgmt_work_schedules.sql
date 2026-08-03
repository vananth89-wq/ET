-- =============================================================================
-- Migration 697 — Time Management: work schedule tables (idempotent)
-- =============================================================================

-- ── 1. Header table ──────────────────────────────────────────────────────────

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

-- ── 2. Lines table ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS time_work_schedule_lines (
  id                uuid     PRIMARY KEY DEFAULT gen_random_uuid(),
  work_schedule_id  uuid     NOT NULL REFERENCES time_work_schedules(id) ON DELETE CASCADE,
  day_number        smallint NOT NULL CHECK (day_number BETWEEN 1 AND 7),
  planned_minutes   integer  NOT NULL CHECK (planned_minutes >= 0),
  CONSTRAINT time_work_schedule_lines_unique UNIQUE (work_schedule_id, day_number)
);

-- ── 3. Indexes ───────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_time_work_schedule_lines_schedule
  ON time_work_schedule_lines (work_schedule_id, day_number);

-- ── 4. RLS ───────────────────────────────────────────────────────────────────

ALTER TABLE time_work_schedules      ENABLE ROW LEVEL SECURITY;
ALTER TABLE time_work_schedule_lines ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "tws_select" ON time_work_schedules FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "tws_insert" ON time_work_schedules FOR INSERT TO authenticated
    WITH CHECK (user_can('time_work_schedules', 'create', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "tws_update" ON time_work_schedules FOR UPDATE TO authenticated
    USING (user_can('time_work_schedules', 'edit', NULL))
    WITH CHECK (user_can('time_work_schedules', 'edit', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "tws_delete" ON time_work_schedules FOR DELETE TO authenticated
    USING (user_can('time_work_schedules', 'delete', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "twsl_select" ON time_work_schedule_lines FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "twsl_insert" ON time_work_schedule_lines FOR INSERT TO authenticated
    WITH CHECK (user_can('time_work_schedules', 'create', NULL) OR user_can('time_work_schedules', 'edit', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "twsl_update" ON time_work_schedule_lines FOR UPDATE TO authenticated
    USING (user_can('time_work_schedules', 'edit', NULL))
    WITH CHECK (user_can('time_work_schedules', 'edit', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "twsl_delete" ON time_work_schedule_lines FOR DELETE TO authenticated
    USING (user_can('time_work_schedules', 'edit', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 5. RPC: upsert_work_schedule ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_work_schedule(p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id            uuid;
  v_is_new        boolean;
  v_line          jsonb;
  v_day_num       smallint;
  v_minutes       integer;
  v_lines_count   integer;
BEGIN
  v_id := (p_data->>'id')::uuid;
  IF v_id IS NOT NULL THEN
    IF NOT user_can('time_work_schedules', 'edit', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to edit work schedules.');
    END IF;
    v_is_new := false;
  ELSE
    IF NOT user_can('time_work_schedules', 'create', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to create work schedules.');
    END IF;
    v_id := gen_random_uuid();
    v_is_new := true;
  END IF;

  SELECT jsonb_array_length(p_data->'lines') INTO v_lines_count;
  IF v_lines_count IS NULL OR v_lines_count <> 7 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_LINES',
      'message', 'Work schedule must have exactly 7 day lines.');
  END IF;

  INSERT INTO time_work_schedules (id, name, code, start_day_of_week, is_active, created_by)
  VALUES (
    v_id,
    trim(p_data->>'name'),
    upper(trim(p_data->>'code')),
    (p_data->>'start_day_of_week')::smallint,
    COALESCE((p_data->>'is_active')::boolean, true),
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    name              = trim(EXCLUDED.name),
    code              = upper(trim(EXCLUDED.code)),
    start_day_of_week = EXCLUDED.start_day_of_week,
    is_active         = EXCLUDED.is_active,
    updated_at        = now();

  DELETE FROM time_work_schedule_lines WHERE work_schedule_id = v_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_data->'lines')
  LOOP
    v_day_num := (v_line->>'day_number')::smallint;
    v_minutes := (v_line->>'planned_minutes')::integer;

    IF v_day_num NOT BETWEEN 1 AND 7 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'INVALID_DAY',
        'message', format('day_number %s is not between 1 and 7.', v_day_num));
    END IF;
    IF v_minutes < 0 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'INVALID_MINUTES',
        'message', format('planned_minutes cannot be negative for day %s.', v_day_num));
    END IF;

    INSERT INTO time_work_schedule_lines (work_schedule_id, day_number, planned_minutes)
    VALUES (v_id, v_day_num, v_minutes);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'created', v_is_new);

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'DUPLICATE_CODE',
    'message', 'A work schedule with this code already exists.');
WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_work_schedule(jsonb) TO authenticated;
