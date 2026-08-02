-- =============================================================================
-- Migration 701 — Time Management: submission reminder config
--
-- Creates time_submission_config: admin-configurable table of reminder
-- offsets relative to month-end. A pg_cron job reads these rows daily.
-- =============================================================================

CREATE TABLE time_submission_config (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  offset_days       integer     NOT NULL,
  message_template  text        NOT NULL,
  notification_type text        NOT NULL CHECK (notification_type IN ('in_app', 'email', 'both')),
  is_active         boolean     NOT NULL DEFAULT true,
  sort_order        smallint    NOT NULL DEFAULT 0,
  created_by        uuid        REFERENCES profiles(id),
  created_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  time_submission_config IS 'Submission reminder schedule. offset_days is relative to last day of month: negative = before, positive = after.';
COMMENT ON COLUMN time_submission_config.message_template IS 'Supports {{employee_name}}, {{period}}, {{deadline}} tokens.';
COMMENT ON COLUMN time_submission_config.offset_days IS 'e.g. -1 = day before month end, +3 = 3 days after month end.';

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE time_submission_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tsc_select" ON time_submission_config
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "tsc_insert" ON time_submission_config
  FOR INSERT TO authenticated
  WITH CHECK (user_can('time_submission_config', 'edit', NULL));

CREATE POLICY "tsc_update" ON time_submission_config
  FOR UPDATE TO authenticated
  USING     (user_can('time_submission_config', 'edit', NULL))
  WITH CHECK (user_can('time_submission_config', 'edit', NULL));

CREATE POLICY "tsc_delete" ON time_submission_config
  FOR DELETE TO authenticated
  USING (user_can('time_submission_config', 'edit', NULL));

-- ── RPC: upsert_submission_config ────────────────────────────────────────────
-- Full replace: accepts an array of rows, clears existing, inserts new.

CREATE OR REPLACE FUNCTION upsert_submission_config(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row    jsonb;
  v_count  integer := 0;
BEGIN
  IF NOT user_can('time_submission_config', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to edit submission config.');
  END IF;

  DELETE FROM time_submission_config;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    IF (v_row->>'notification_type') NOT IN ('in_app', 'email', 'both') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'INVALID_NOTIFICATION_TYPE',
        'message', format('notification_type must be in_app, email, or both. Got: %L', v_row->>'notification_type'));
    END IF;

    INSERT INTO time_submission_config
      (offset_days, message_template, notification_type, is_active, sort_order, created_by)
    VALUES (
      (v_row->>'offset_days')::integer,
      trim(v_row->>'message_template'),
      v_row->>'notification_type',
      COALESCE((v_row->>'is_active')::boolean, true),
      COALESCE((v_row->>'sort_order')::smallint, v_count::smallint),
      auth.uid()
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'rows_saved', v_count);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_submission_config(jsonb) TO authenticated;

COMMENT ON FUNCTION upsert_submission_config IS 'Mig 701: Full-replace upsert for submission reminder rows.';

-- ── Seed: default reminder schedule ──────────────────────────────────────────

INSERT INTO time_submission_config (offset_days, message_template, notification_type, is_active, sort_order)
VALUES
  (-1, 'Hi {{employee_name}}, your timesheet for {{period}} is due tomorrow. Please submit before end of day.', 'both', true, 0),
  (3,  'Hi {{employee_name}}, your timesheet for {{period}} is 3 days overdue. Please submit immediately.', 'both', true, 1),
  (6,  'URGENT: {{employee_name}}, your timesheet for {{period}} is 6 days overdue. HR has been notified.', 'both', true, 2);

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'time_submission_config') THEN
    RAISE EXCEPTION 'ABORT: time_submission_config table not found.';
  END IF;
  RAISE NOTICE 'Migration 701 verified: time_submission_config created with 3 seed rows.';
END $$;
