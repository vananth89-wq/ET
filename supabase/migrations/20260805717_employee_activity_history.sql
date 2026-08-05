-- =============================================================================
-- Migration 717 — Employee Activity History for Timesheet smart suggestions
--
-- Stores per-employee activity names with usage stats and favorites.
-- Filtering is done client-side; RPCs handle read, toggle, and upsert.
-- =============================================================================

-- ── Table ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS employee_activity_history (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     uuid        NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  activity_name   text        NOT NULL CHECK (char_length(trim(activity_name)) > 0),
  usage_count     integer     NOT NULL DEFAULT 1 CHECK (usage_count >= 0),
  last_used_at    timestamptz NOT NULL DEFAULT now(),
  is_favorite     boolean     NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT eah_unique_employee_activity UNIQUE (employee_id, activity_name)
);

COMMENT ON TABLE employee_activity_history IS
  'Per-employee activity name history for timesheet smart suggestions. '
  'Filtering is client-side; this table is the source of truth.';

CREATE INDEX IF NOT EXISTS idx_eah_employee ON employee_activity_history (employee_id);
CREATE INDEX IF NOT EXISTS idx_eah_employee_fav ON employee_activity_history (employee_id, is_favorite) WHERE is_favorite = true;

-- updated_at trigger
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_eah_updated_at') THEN
    EXECUTE $trig$
      CREATE TRIGGER trg_eah_updated_at
        BEFORE UPDATE ON employee_activity_history
        FOR EACH ROW EXECUTE FUNCTION _set_updated_at();
    $trig$;
  END IF;
END $$;

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE employee_activity_history ENABLE ROW LEVEL SECURITY;

-- Employees can only see/edit their own activity history
DO $$ BEGIN
CREATE POLICY "eah_select" ON employee_activity_history
  FOR SELECT TO authenticated
  USING (employee_id = (
    SELECT id FROM employees WHERE id = auth.uid()
    UNION SELECT e.id FROM employees e
      JOIN profiles p ON p.id = auth.uid() AND p.id = e.id
    LIMIT 1
  ));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
CREATE POLICY "eah_insert" ON employee_activity_history
  FOR INSERT TO authenticated
  WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
CREATE POLICY "eah_update" ON employee_activity_history
  FOR UPDATE TO authenticated
  USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── RPC: get_employee_activities ─────────────────────────────────────────────
-- Returns all activity history for an employee (client does the filtering).

CREATE OR REPLACE FUNCTION get_employee_activities(p_employee_id uuid)
RETURNS TABLE (
  id            uuid,
  activity_name text,
  usage_count   integer,
  last_used_at  timestamptz,
  is_favorite   boolean,
  created_at    timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id, activity_name, usage_count, last_used_at, is_favorite, created_at
  FROM employee_activity_history
  WHERE employee_id = p_employee_id
  ORDER BY is_favorite DESC, last_used_at DESC;
$$;

GRANT EXECUTE ON FUNCTION get_employee_activities(uuid) TO authenticated;
COMMENT ON FUNCTION get_employee_activities IS 'Mig 717: Return all activity history for an employee.';

-- ── RPC: toggle_activity_favorite ────────────────────────────────────────────
-- Toggles is_favorite. Enforces max 10 favorites.

CREATE OR REPLACE FUNCTION toggle_activity_favorite(
  p_employee_id   uuid,
  p_activity_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current  boolean;
  v_fav_count integer;
  v_new_val   boolean;
BEGIN
  SELECT is_favorite INTO v_current
  FROM employee_activity_history
  WHERE employee_id = p_employee_id AND activity_name = p_activity_name;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Activity not found.');
  END IF;

  -- If currently not favorite, check cap before adding
  IF NOT v_current THEN
    SELECT COUNT(*) INTO v_fav_count
    FROM employee_activity_history
    WHERE employee_id = p_employee_id AND is_favorite = true;

    IF v_fav_count >= 10 THEN
      RETURN jsonb_build_object('ok', false, 'cap', true,
        'message', 'You can have up to 10 favourite activities.');
    END IF;
  END IF;

  v_new_val := NOT v_current;

  UPDATE employee_activity_history
  SET is_favorite = v_new_val
  WHERE employee_id = p_employee_id AND activity_name = p_activity_name;

  RETURN jsonb_build_object('ok', true, 'is_favorite', v_new_val);
END;
$$;

GRANT EXECUTE ON FUNCTION toggle_activity_favorite(uuid, text) TO authenticated;
COMMENT ON FUNCTION toggle_activity_favorite IS 'Mig 717: Toggle favorite for an activity; max 10 favorites enforced.';

-- ── RPC: record_activity_usages ──────────────────────────────────────────────
-- Upserts an array of activity names for an employee (called after save).

CREATE OR REPLACE FUNCTION record_activity_usages(
  p_employee_id    uuid,
  p_activity_names text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY p_activity_names LOOP
    v_name := trim(v_name);
    CONTINUE WHEN v_name = '';

    INSERT INTO employee_activity_history (employee_id, activity_name, usage_count, last_used_at)
    VALUES (p_employee_id, v_name, 1, now())
    ON CONFLICT (employee_id, activity_name) DO UPDATE SET
      usage_count  = employee_activity_history.usage_count + 1,
      last_used_at = now();
  END LOOP;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION record_activity_usages(uuid, text[]) TO authenticated;
COMMENT ON FUNCTION record_activity_usages IS 'Mig 717: Upsert activity usage for an employee (batch).';

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'employee_activity_history') THEN
    RAISE EXCEPTION 'ABORT: employee_activity_history table not found.';
  END IF;
  RAISE NOTICE 'Migration 717 verified: employee_activity_history table + 3 RPCs created.';
END $$;
