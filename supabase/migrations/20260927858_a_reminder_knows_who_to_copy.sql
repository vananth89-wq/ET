-- =============================================================================
-- Migration 858 — a reminder knows who to copy
--
-- A reminder rule has an offset, a message and a channel, and the recipient is
-- implicit: the employee. The escalation Vj asked for is the first time a rule
-- must reach more than one person --
--
--     offset  0   employee
--     offset +1   employee + manager
--     offset +2   employee + manager + HR Analyst
--
-- -- so recipients become data on the rule, editable on the Submission Config
-- screen like everything else there. Nothing about this escalation is written
-- into code: an admin can add a fourth rule that copies the department head
-- tomorrow without a deploy.
--
-- Tokens, not people. Two kinds:
--   employee | manager | dept_head   relationships, resolved per employee
--   role:<code>                      everyone holding that role, read LIVE
--                                    from the roles table
--
-- role: is deliberately not a foreign key. Roles are data -- 'hr' (HR Analyst),
-- 'hr_head', 'project_manager' and 'bank_exceptions' are all custom roles
-- created in the app, and more will be. A CHECK validates the SHAPE of the
-- token; whether a code resolves to anyone is a question for the resolver at
-- send time, which is also where an admin should find out, not at save time.
--
-- ─── The landmine this migration mostly exists to avoid ─────────────────────
-- upsert_submission_config() is a FULL REPLACE: it deletes every row and
-- re-inserts from a jsonb payload, naming five columns. Add a sixth and every
-- Save on that screen silently resets it to the default. The column and the
-- RPC have to land together, and the frontend in the same release -- a payload
-- with no 'recipients' key falls back to {employee}, which is correct for a
-- fresh rule and destructive for a configured one.
--
-- ─── A bug inherited and fixed in passing ───────────────────────────────────
-- 701's RPC deletes every row and THEN validates inside the insert loop,
-- returning early on a bad one. An early RETURN is not an exception, so the
-- DELETE stands: one bad value wipes the whole reminder schedule and the screen
-- shows only ok:false. Adding a second validated field would have made that far
-- easier to trigger, so the RPC is restructured to validate the entire payload
-- before deleting anything.
--
-- Depends on : 701 (config + RPC), 856 (grace), 857 (working-day fire dates)
-- =============================================================================

BEGIN;

-- ── 1. Recipients on the rule ────────────────────────────────────────────────

ALTER TABLE time_submission_config
  ADD COLUMN IF NOT EXISTS recipients text[];

UPDATE time_submission_config
   SET recipients = ARRAY['employee']
 WHERE recipients IS NULL;

ALTER TABLE time_submission_config ALTER COLUMN recipients SET DEFAULT ARRAY['employee'];
ALTER TABLE time_submission_config ALTER COLUMN recipients SET NOT NULL;

-- A CHECK may not contain a subquery, and validating "every element matches"
-- needs unnest(). An IMMUTABLE function may contain one and a CHECK may call it.
CREATE OR REPLACE FUNCTION public.time_reminder_tokens_valid(p_tokens text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT p_tokens IS NOT NULL
     AND COALESCE(array_length(p_tokens, 1), 0) >= 1
     AND NOT EXISTS (
           SELECT 1 FROM unnest(p_tokens) t
           WHERE  t IS NULL
              OR  t !~ '^(employee|manager|dept_head|role:[a-z0-9_]+)$');
$fn$;

COMMENT ON FUNCTION public.time_reminder_tokens_valid(text[]) IS
  'Mig 858: shape check for recipient tokens. Deliberately does not ask whether '
  'a role code exists -- roles are data, and an admin should learn that a code '
  'resolves to nobody from the send log, not from a rejected Save.';

ALTER TABLE time_submission_config
  DROP CONSTRAINT IF EXISTS time_submission_config_recipients_shape;
ALTER TABLE time_submission_config
  ADD  CONSTRAINT time_submission_config_recipients_shape
  CHECK (time_reminder_tokens_valid(recipients));

COMMENT ON COLUMN time_submission_config.recipients IS
  'Mig 858: who this reminder reaches. Tokens, never ids. employee | manager | '
  'dept_head resolve per employee; role:<code> means everyone holding that role, '
  'read live from the roles table so a role created tomorrow needs no deploy. '
  'The first element is the addressee; the rest are copies.';


-- ── 2. How late a reminder may still be sent ─────────────────────────────────

ALTER TABLE time_edit_config
  ADD COLUMN IF NOT EXISTS reminder_catchup_days smallint NOT NULL DEFAULT 3;

ALTER TABLE time_edit_config
  DROP CONSTRAINT IF EXISTS time_edit_config_reminder_catchup_range;
ALTER TABLE time_edit_config
  ADD  CONSTRAINT time_edit_config_reminder_catchup_range
  CHECK (reminder_catchup_days BETWEEN 0 AND 30);

COMMENT ON COLUMN time_edit_config.reminder_catchup_days IS
  'Mig 858: how many days after its firing date a reminder may still be sent, '
  'once. Covers a missed cron run and an admin adding or re-dating a rule '
  'mid-period. 0 means fire only on the exact day. Bounded on purpose: without '
  'a window, adding a rule would notify everyone for every open period at once.';


-- ── 3. Resolving the tokens ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.time_reminder_recipients(
  p_employee_id uuid,
  p_recipients  text[])
RETURNS TABLE (profile_id uuid, employee_id uuid, token text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  WITH want AS (
    SELECT DISTINCT t AS token FROM unnest(COALESCE(p_recipients, '{}'::text[])) t
  ),
  resolved AS (
    -- the employee themselves
    SELECT p.id AS profile_id, e.id AS employee_id, 'employee'::text AS token
    FROM   employees e
    JOIN   profiles  p ON p.employee_id = e.id
    WHERE  e.id = p_employee_id
      AND  e.deleted_at IS NULL
      AND  p.is_active
      AND  EXISTS (SELECT 1 FROM want w WHERE w.token = 'employee')

    UNION ALL

    -- their line manager
    SELECT p.id, m.id, 'manager'
    FROM   employees e
    JOIN   employees m ON m.id = e.manager_id
    JOIN   profiles  p ON p.employee_id = m.id
    WHERE  e.id = p_employee_id
      AND  m.deleted_at IS NULL
      AND  p.is_active
      AND  EXISTS (SELECT 1 FROM want w WHERE w.token = 'manager')

    UNION ALL

    -- the current head of their department. to_date IS NULL = current, and the
    -- from_date order matters: a department that has had two heads has two rows.
    SELECT p.id, h.employee_id, 'dept_head'
    FROM   employee_employment ee
    JOIN   department_heads    h ON h.department_id = ee.dept_id
                                AND h.to_date IS NULL
    JOIN   employees           he ON he.id = h.employee_id
    JOIN   profiles            p  ON p.employee_id = h.employee_id
    WHERE  ee.employee_id = p_employee_id
      AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
      AND  he.deleted_at IS NULL
      AND  p.is_active
      AND  EXISTS (SELECT 1 FROM want w WHERE w.token = 'dept_head')

    UNION ALL

    -- everyone holding a named role, resolved live
    SELECT p.id, p.employee_id, 'role:' || r.code
    FROM   want      w
    JOIN   roles     r  ON 'role:' || r.code = w.token
    JOIN   user_roles ur ON ur.role_id = r.id
                        AND ur.is_active
                        AND (ur.expires_at IS NULL OR ur.expires_at > now())
    JOIN   profiles  p  ON p.id = ur.profile_id
    WHERE  p.is_active
  )
  -- One person copied twice is one recipient. DISTINCT ON keeps the first token
  -- that produced them, so a manager who also holds role:hr is reported as the
  -- manager -- the more specific reason they are on the message.
  SELECT DISTINCT ON (r.profile_id) r.profile_id, r.employee_id, r.token
  FROM   resolved r
  ORDER  BY r.profile_id,
            CASE r.token WHEN 'employee' THEN 0 WHEN 'manager' THEN 1
                         WHEN 'dept_head' THEN 2 ELSE 3 END;
$fn$;

COMMENT ON FUNCTION public.time_reminder_recipients(uuid, text[]) IS
  'Mig 858: turns a rule''s recipient tokens into profiles, for one employee. '
  'Skips inactive profiles and deleted employees. A person matched twice is '
  'returned once, labelled with the most specific token that found them. An '
  'unknown role code simply resolves to nobody.';


-- ── 4. The full-replace RPC learns the new column ────────────────────────────

DO $mig$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_submission_config'
    AND  p.prokind = 'f';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 858: upsert_submission_config() not found -- the Submission '
                    'Config screen saves through it and would wipe recipients.';
  END IF;

  IF position('recipients' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 858: upsert_submission_config() already carries recipients, skipping.';
    RETURN;
  END IF;

  IF position('DELETE FROM time_submission_config' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 858: upsert_submission_config() is no longer the full-replace '
                    'shape this migration was written against. Live body: %', v_src;
  END IF;

  CREATE OR REPLACE FUNCTION public.upsert_submission_config(p_rows jsonb)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
  AS $fn$
  DECLARE
    v_row   jsonb;
    v_count integer := 0;
    v_recip text[];
    v_tok   text;
  BEGIN
    IF NOT user_can('time_submission_config', 'edit', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to edit submission config.');
    END IF;

    -- PASS 1 -- validate everything before destroying anything.
    --
    -- 701 deleted first and validated inside the insert loop, returning early on
    -- a bad row. An early RETURN is not an exception, so the DELETE stood: one
    -- bad notification_type emptied the entire reminder schedule and handed the
    -- screen an error as the only trace. Adding a second validated field would
    -- have made that easier to hit, so it is fixed here rather than inherited.
    FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
    LOOP
      IF (v_row->>'notification_type') NOT IN ('in_app', 'email', 'both') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'INVALID_NOTIFICATION_TYPE',
          'message', format('notification_type must be in_app, email, or both. Got: %L',
                            v_row->>'notification_type'));
      END IF;

      IF v_row ? 'recipients' THEN
        SELECT COALESCE(array_agg(x), '{}'::text[]) INTO v_recip
        FROM   jsonb_array_elements_text(v_row->'recipients') x;
      ELSE
        v_recip := ARRAY['employee'];
      END IF;
      IF COALESCE(array_length(v_recip, 1), 0) = 0 THEN
        v_recip := ARRAY['employee'];
      END IF;

      -- Checked here as well as by the CHECK constraint, so the screen gets a
      -- sentence it can show rather than a constraint name.
      FOREACH v_tok IN ARRAY v_recip LOOP
        IF v_tok !~ '^(employee|manager|dept_head|role:[a-z0-9_]+)$' THEN
          RETURN jsonb_build_object('ok', false, 'error', 'INVALID_RECIPIENT',
            'message', format('Unknown recipient %L. Use employee, manager, dept_head '
                              'or role:<code>.', v_tok));
        END IF;
      END LOOP;
    END LOOP;

    -- PASS 2 -- the payload is known good, so replacing is safe.
    DELETE FROM time_submission_config WHERE true;

    FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
    LOOP
      -- Absent key means an older client. {employee} is right for a new rule and
      -- lossy for a configured one, which is why the UI ships with this migration.
      IF v_row ? 'recipients' THEN
        SELECT COALESCE(array_agg(x), '{}'::text[]) INTO v_recip
        FROM   jsonb_array_elements_text(v_row->'recipients') x;
      ELSE
        v_recip := ARRAY['employee'];
      END IF;
      IF COALESCE(array_length(v_recip, 1), 0) = 0 THEN
        v_recip := ARRAY['employee'];
      END IF;

      INSERT INTO time_submission_config
        (offset_days, message_template, notification_type, is_active, sort_order,
         recipients, created_by)
      VALUES (
        (v_row->>'offset_days')::integer,
        trim(v_row->>'message_template'),
        v_row->>'notification_type',
        COALESCE((v_row->>'is_active')::boolean, true),
        COALESCE((v_row->>'sort_order')::smallint, v_count::smallint),
        v_recip,
        auth.uid()
      );
      v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'rows_saved', v_count);

  -- Kept from 701 so the screen still gets a message rather than a 500. Narrowed
  -- from the original bare WHEN OTHERS only in that the message is now always
  -- carried; swallowing errors silently is what this codebase has banned.
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
  END;
  $fn$;
END
$mig$;

GRANT EXECUTE ON FUNCTION public.upsert_submission_config(jsonb) TO authenticated;


-- ── 5. Verification ──────────────────────────────────────────────────────────

DO $mig$
DECLARE v_bad integer; v_src text;
BEGIN
  SELECT count(*) INTO v_bad FROM time_submission_config
   WHERE recipients IS NULL OR array_length(recipients, 1) IS NULL;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'MIG 858: % reminder rows have no recipients.', v_bad;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_submission_config';
  IF position('recipients' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 858: upsert_submission_config() still does not carry recipients '
                    '-- the next Save would wipe every CC list.';
  END IF;

  RAISE NOTICE 'MIG 858: % rules carry recipients; the save path preserves them.',
    (SELECT count(*) FROM time_submission_config);
END
$mig$;

COMMIT;
