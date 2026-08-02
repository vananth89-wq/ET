-- =============================================================================
-- Migration 702 — Time Management: edit window config (single-row settings)
--
-- Creates time_edit_config: one row, enforced by a constraint.
-- Stores configurable backdating windows per role.
-- NULL for manager/hr = no restriction.
-- =============================================================================

CREATE TABLE time_edit_config (
  id                         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_edit_window_days  integer     NOT NULL DEFAULT 30 CHECK (employee_edit_window_days > 0),
  manager_edit_window_days   integer     CHECK (manager_edit_window_days IS NULL OR manager_edit_window_days > 0),
  hr_edit_window_days        integer     CHECK (hr_edit_window_days IS NULL OR hr_edit_window_days > 0),
  updated_by                 uuid        REFERENCES profiles(id),
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  -- Enforce single-row: only id = the well-known sentinel is allowed
  CONSTRAINT time_edit_config_single_row CHECK (id = id)  -- placeholder; enforced by trigger below
);

COMMENT ON TABLE  time_edit_config IS 'Single-row settings table for timesheet edit windows per role. NULL = no time restriction.';
COMMENT ON COLUMN time_edit_config.employee_edit_window_days IS 'How many days back an employee can edit their own entries.';
COMMENT ON COLUMN time_edit_config.manager_edit_window_days  IS 'How many days back a manager can edit. NULL = unlimited.';
COMMENT ON COLUMN time_edit_config.hr_edit_window_days       IS 'How many days back HR can edit. NULL = unlimited.';

-- Single-row enforcement trigger
CREATE OR REPLACE FUNCTION _time_edit_config_single_row()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT count(*) FROM time_edit_config) >= 1 THEN
    RAISE EXCEPTION 'time_edit_config must contain exactly one row. Use UPDATE, not INSERT.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_time_edit_config_single_row
  BEFORE INSERT ON time_edit_config
  FOR EACH ROW EXECUTE FUNCTION _time_edit_config_single_row();

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE time_edit_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tec_select" ON time_edit_config
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "tec_update" ON time_edit_config
  FOR UPDATE TO authenticated
  USING     (user_can('time_edit_config', 'edit', NULL))
  WITH CHECK (user_can('time_edit_config', 'edit', NULL));

-- INSERT only from this migration (seed row)
CREATE POLICY "tec_insert_seed" ON time_edit_config
  FOR INSERT TO authenticated WITH CHECK (false); -- blocked for all; use SECURITY DEFINER fn

-- ── RPC: save_time_edit_config ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION save_time_edit_config(
  p_employee_days  integer,
  p_manager_days   integer DEFAULT NULL,
  p_hr_days        integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('time_edit_config', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to edit the edit window config.');
  END IF;

  IF p_employee_days IS NULL OR p_employee_days <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_VALUE',
      'message', 'employee_edit_window_days must be a positive integer.');
  END IF;

  UPDATE time_edit_config SET
    employee_edit_window_days = p_employee_days,
    manager_edit_window_days  = p_manager_days,
    hr_edit_window_days       = p_hr_days,
    updated_by                = auth.uid(),
    updated_at                = now();

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION save_time_edit_config(integer, integer, integer) TO authenticated;

COMMENT ON FUNCTION save_time_edit_config IS 'Mig 702: Update the single-row edit window config.';

-- ── Seed: default row ────────────────────────────────────────────────────────
-- Bypass the INSERT trigger via direct INSERT as superuser (migration context).

INSERT INTO time_edit_config (employee_edit_window_days, manager_edit_window_days, hr_edit_window_days)
VALUES (30, NULL, NULL);

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM time_edit_config;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'ABORT: expected 1 row in time_edit_config, found %.', v_count;
  END IF;
  RAISE NOTICE 'Migration 702 verified: time_edit_config created with seed row (employee=30, manager=NULL, hr=NULL).';
END $$;
