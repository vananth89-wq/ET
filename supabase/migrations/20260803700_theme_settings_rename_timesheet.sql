-- =============================================================================
-- Migration 700 — Rename "Timesheet" → "My Timesheet" in theme_settings
--
-- Follow-up to mig 699 which added the entry. The default label is now
-- "My Timesheet" (consistent with "My Profile", "My Requests", "My Expense
-- Reports"). This mig updates any saved row whose id='timesheet' entry
-- still has the old label.
--
-- Idempotent: uses jsonb array manipulation to update the label only if
-- the entry exists AND still has the old label.
-- =============================================================================

DO $$
DECLARE
  v_json      jsonb;
  v_new_json  jsonb;
  v_key       text;
BEGIN
  FOREACH v_key IN ARRAY ARRAY['suggested_tasks', 'most_used_apps']
  LOOP
    SELECT value::jsonb INTO v_json
    FROM   public.theme_settings
    WHERE  key = v_key;

    IF NOT FOUND THEN CONTINUE; END IF;

    -- Rebuild the array — replace label on the timesheet entry only
    SELECT jsonb_agg(
             CASE
               WHEN elem->>'id' = 'timesheet' AND elem->>'label' = 'Timesheet'
                 THEN jsonb_set(elem, '{label}', to_jsonb('My Timesheet'::text))
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
      RAISE NOTICE 'Migration 700: renamed Timesheet → My Timesheet in %', v_key;
    END IF;
  END LOOP;
END $$;
