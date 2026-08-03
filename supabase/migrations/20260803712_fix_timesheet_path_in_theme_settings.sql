-- =============================================================================
-- Migration 712 — Fix Timesheet path in theme_settings
--
-- Migrations 699/700 added the Timesheet entry with path '/timesheet'
-- but the actual route is '/my-timesheet'.
-- This migration corrects the path in both suggested_tasks and most_used_apps.
-- Idempotent — only updates if the wrong path is present.
-- =============================================================================

DO $$
DECLARE
  v_json     jsonb;
  v_new_json jsonb;
  v_key      text;
BEGIN
  FOREACH v_key IN ARRAY ARRAY['suggested_tasks', 'most_used_apps']
  LOOP
    SELECT value::jsonb INTO v_json
    FROM   public.theme_settings
    WHERE  key = v_key;

    IF NOT FOUND THEN CONTINUE; END IF;

    -- Rebuild array — fix path on the timesheet entry only
    SELECT jsonb_agg(
             CASE
               WHEN elem->>'id' = 'timesheet' AND elem->>'path' = '/timesheet'
                 THEN jsonb_set(elem, '{path}', to_jsonb('/my-timesheet'::text))
               ELSE elem
             END
             ORDER BY (elem->>'order')::int NULLS LAST
           )
    INTO   v_new_json
    FROM   jsonb_array_elements(v_json) elem;

    IF v_new_json IS NOT NULL AND v_new_json::text <> v_json::text THEN
      UPDATE public.theme_settings
      SET    value      = v_new_json::text,
             updated_at = now()
      WHERE  key = v_key;
      RAISE NOTICE 'Migration 712: fixed Timesheet path /timesheet → /my-timesheet in %', v_key;
    END IF;
  END LOOP;
END $$;
