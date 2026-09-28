-- =============================================================================
-- Migration 859 — the submission settings get a save path
--
-- 856 moved the deadline to time_edit_config.submission_grace_days and 858 added
-- reminder_catchup_days beside it. Both are currently editable by nobody: there
-- is no field on any screen and no RPC that writes them. A setting only a
-- migration can change is a worse kind of hardcoding than the coupling 856
-- removed, so this closes that.
--
-- Why not extend save_time_edit_config(): that RPC belongs to the Edit Window
-- Config screen and is gated on user_can('time_edit_config', 'edit'). These two
-- settings belong to submission reminders, are edited on the Submission Config
-- screen, and should be gated on the permission that screen already uses --
-- time_submission_config.edit. Sharing the RPC would mean whoever may change an
-- edit window may also change the submission deadline, which is not the same
-- decision and not obviously the same person.
--
-- They live on time_edit_config rather than in a new table because it is the
-- timesheet's single-row settings home and already holds period_start_day. The
-- table is where a setting lives; the RPC is who may change it.
--
-- Depends on : 702 (time_edit_config), 856 (grace), 858 (catchup)
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.save_time_submission_settings(
  p_grace_days   integer,
  p_catchup_days integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE v_rows integer;
BEGIN
  IF NOT user_can('time_submission_config', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to edit submission settings.');
  END IF;

  -- Validated here as well as by the CHECK constraints, so the screen gets a
  -- sentence rather than a constraint name.
  IF p_grace_days IS NULL OR p_grace_days < 0 OR p_grace_days > 31 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_GRACE',
      'message', 'Submission deadline must be between 0 and 31 days after the period ends.');
  END IF;

  IF p_catchup_days IS NULL OR p_catchup_days < 0 OR p_catchup_days > 30 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_CATCHUP',
      'message', 'Catch-up window must be between 0 and 30 days.');
  END IF;

  -- Same reasoning as 856: the row may not exist, and naming a column in the
  -- insert is how 856 first failed. DEFAULT VALUES cannot go stale.
  IF NOT EXISTS (SELECT 1 FROM time_edit_config) THEN
    INSERT INTO time_edit_config DEFAULT VALUES;
  END IF;

  UPDATE time_edit_config
     SET submission_grace_days = p_grace_days::smallint,
         reminder_catchup_days = p_catchup_days::smallint,
         updated_by            = auth.uid(),
         updated_at            = now()
   WHERE id IS NOT NULL;   -- pg_safeupdate: never a bare UPDATE, even on one row

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'rows', v_rows,
                            'submission_grace_days', p_grace_days,
                            'reminder_catchup_days', p_catchup_days);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END
$fn$;

REVOKE ALL ON FUNCTION public.save_time_submission_settings(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_time_submission_settings(integer, integer) TO authenticated;

COMMENT ON FUNCTION public.save_time_submission_settings(integer, integer) IS
  'Mig 859: writes the submission deadline (grace days after period end) and the '
  'reminder catch-up window. Gated on time_submission_config.edit -- the '
  'permission behind the screen these belong to, not time_edit_config.edit.';

-- ── Verification ─────────────────────────────────────────────────────────────

DO $mig$
DECLARE v_missing text;
BEGIN
  SELECT string_agg(c, ', ') INTO v_missing
  FROM   unnest(ARRAY['submission_grace_days','reminder_catchup_days']) c
  WHERE  NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_schema = 'public' AND table_name = 'time_edit_config'
      AND  column_name = c);

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'MIG 859: time_edit_config is missing %. 856 and 858 must be applied first.', v_missing;
  END IF;

  RAISE NOTICE 'MIG 859: save path in place for the submission deadline and catch-up window.';
END
$mig$;

COMMIT;
