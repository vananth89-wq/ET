-- =============================================================================
-- Migration 699 — Add "Timesheet" to Suggested Tasks + Most Used Apps
--
-- The DEFAULT_SUGGESTED_TASKS and DEFAULT_MOST_USED_APPS arrays in
-- ThemeManager (src/components/admin/ThemeManager/index.tsx) already include
-- Timesheet as of the previous frontend commit. But installations that
-- already saved a config (Dev, UAT) have the pre-Timesheet list in
-- theme_settings, and the saved value overrides defaults on load — so the
-- new item never appears until the config is reset.
--
-- This migration is idempotent:
--   • If the saved value doesn't have Timesheet, append it.
--   • If it does, no-op.
--   • If the row doesn't exist at all, no-op (fresh install picks up defaults).
--
-- Applies to keys: 'suggested_tasks' and 'most_used_apps'.
-- Values are stored as TEXT (JSON strings) in theme_settings.value.
-- Timesheet is added with visible=false so nothing appears on the landing
-- page unless an admin explicitly toggles it on.
-- =============================================================================

DO $$
DECLARE
  v_json           jsonb;
  v_timesheet_pill jsonb := jsonb_build_object(
    'id',      'timesheet',
    'label',   'Timesheet',
    'path',    '/timesheet',
    'visible', false,
    'order',   8
  );
  v_timesheet_app  jsonb := jsonb_build_object(
    'id',      'timesheet',
    'label',   'Timesheet',
    'icon',    'fa-clock',
    'path',    '/timesheet',
    'visible', false,
    'order',   7
  );
BEGIN
  -- ── 1. Suggested Tasks ────────────────────────────────────────────────────
  SELECT value::jsonb INTO v_json
  FROM   public.theme_settings
  WHERE  key = 'suggested_tasks';

  IF FOUND AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_json) e WHERE e->>'id' = 'timesheet'
  ) THEN
    UPDATE public.theme_settings
    SET    value      = (v_json || jsonb_build_array(v_timesheet_pill))::text,
           updated_at = now()
    WHERE  key = 'suggested_tasks';
    RAISE NOTICE 'Migration 699: appended Timesheet to suggested_tasks';
  END IF;

  -- ── 2. Most Used Apps ─────────────────────────────────────────────────────
  SELECT value::jsonb INTO v_json
  FROM   public.theme_settings
  WHERE  key = 'most_used_apps';

  IF FOUND AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_json) e WHERE e->>'id' = 'timesheet'
  ) THEN
    UPDATE public.theme_settings
    SET    value      = (v_json || jsonb_build_array(v_timesheet_app))::text,
           updated_at = now()
    WHERE  key = 'most_used_apps';
    RAISE NOTICE 'Migration 699: appended Timesheet to most_used_apps';
  END IF;
END $$;
