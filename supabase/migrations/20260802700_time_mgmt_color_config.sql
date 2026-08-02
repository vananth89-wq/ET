-- =============================================================================
-- Migration 700 — Time Management: color configuration table
--
-- Creates time_color_config with a fixed set of entity_key rows.
-- This is a key-value map; admin can update hex values, not add/remove keys.
-- Seeded with sensible defaults on create.
-- =============================================================================

CREATE TABLE time_color_config (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_key  text        NOT NULL,
  color_hex   char(7)     NOT NULL CHECK (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  label       text        NOT NULL,
  updated_by  uuid        REFERENCES profiles(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_color_config_key UNIQUE (entity_key)
);

COMMENT ON TABLE  time_color_config IS 'Admin-configurable color palette for timesheet visual states. Fixed key set; values are editable.';
COMMENT ON COLUMN time_color_config.entity_key IS 'Fixed keys: day_underworked, day_overworked, day_holiday, day_leave_full, day_leave_partial, day_non_working, status_draft, status_pending, status_approved, entry_project, entry_time_type.';

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE time_color_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tcc_select" ON time_color_config
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "tcc_update" ON time_color_config
  FOR UPDATE TO authenticated
  USING     (user_can('time_color_config', 'edit', NULL))
  WITH CHECK (user_can('time_color_config', 'edit', NULL));

-- No INSERT or DELETE policies — keys are fixed; only UPDATE is allowed via admin.

-- ── RPC: upsert_time_color_config ────────────────────────────────────────────
-- Accepts array of { entity_key, color_hex } and bulk-updates matching rows.

CREATE OR REPLACE FUNCTION upsert_time_color_config(p_configs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row     jsonb;
  v_key     text;
  v_hex     text;
  v_updated integer := 0;
BEGIN
  IF NOT user_can('time_color_config', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to edit color configuration.');
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_configs)
  LOOP
    v_key := v_row->>'entity_key';
    v_hex := v_row->>'color_hex';

    IF v_hex !~ '^#[0-9A-Fa-f]{6}$' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'INVALID_HEX',
        'message', format('color_hex %L for key %L is not a valid 6-digit hex color.', v_hex, v_key));
    END IF;

    UPDATE time_color_config
    SET color_hex = v_hex, updated_by = auth.uid(), updated_at = now()
    WHERE entity_key = v_key;

    IF FOUND THEN v_updated := v_updated + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'updated', v_updated);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_time_color_config(jsonb) TO authenticated;

COMMENT ON FUNCTION upsert_time_color_config IS 'Mig 700: Bulk-update time color config values. Keys must already exist (INSERT not supported).';

-- ── Seed: default colors ─────────────────────────────────────────────────────

INSERT INTO time_color_config (entity_key, color_hex, label) VALUES
  ('day_underworked',   '#FEF3C7', 'Underworked Day'),
  ('day_overworked',    '#FEE2E2', 'Overworked Day'),
  ('day_holiday',       '#DBEAFE', 'Public Holiday'),
  ('day_leave_full',    '#E0E7FF', 'Full-Day Leave'),
  ('day_leave_partial', '#EDE9FE', 'Partial-Day Leave'),
  ('day_non_working',   '#F3F4F6', 'Non-Working Day'),
  ('status_draft',      '#F59E0B', 'Status: To Be Submitted'),
  ('status_pending',    '#3B82F6', 'Status: To Be Approved'),
  ('status_approved',   '#10B981', 'Status: Approved'),
  ('entry_project',     '#2563EB', 'Project Entry Pill'),
  ('entry_time_type',   '#7C3AED', 'Time Type Entry Pill')
ON CONFLICT (entity_key) DO NOTHING;

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM time_color_config;
  IF v_count <> 11 THEN
    RAISE EXCEPTION 'ABORT: expected 11 color config rows, found %.', v_count;
  END IF;
  RAISE NOTICE 'Migration 700 verified: time_color_config created with 11 seeded rows.';
END $$;
