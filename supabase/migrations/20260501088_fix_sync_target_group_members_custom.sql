-- =============================================================================
-- Migration : 20260501088_fix_sync_target_group_members_custom.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-05-01
-- Description:
--   Replaces the stub sync_target_group_members() with a full implementation
--   that handles 'custom' groups by evaluating filter_rules JSONB.
--
--   filter_rules JSON shape:
--     {
--       "operator": "AND" | "OR",
--       "rules": [
--         { "portlet": "employment|personal_info",
--           "field": "dept_id|designation|work_country|work_location|status|
--                     name|employee_id|nationality|gender|marital_status",
--           "values": [{ "value": "<uuid-or-text>", "label": "..." }] }
--       ]
--     }
--
--   Field routing:
--     • employees table      : dept_id, designation, work_country, work_location,
--                              status, name, employee_id
--     • employee_personal    : nationality, gender, marital_status
-- =============================================================================

CREATE OR REPLACE FUNCTION sync_target_group_members()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start        timestamptz := clock_timestamp();
  v_total_rows   int         := 0;
  v_err          text;

  -- group iteration
  v_group        RECORD;
  v_operator     text;
  v_rules        jsonb;
  v_rule         jsonb;
  v_rule_count   int;
  v_i            int;

  -- rule components
  v_field        text;
  v_values       text[];

  -- dynamic SQL
  v_join_personal  boolean;
  v_where_parts    text[];
  v_where_clause   text;
  v_sql            text;

BEGIN
  -- ── Truncate first (cache is always rebuilt in full) ─────────────────────
  TRUNCATE target_group_members;

  -- ────────────────────────────────────────────────────────────────────────
  -- Scope: everyone
  -- ────────────────────────────────────────────────────────────────────────
  INSERT INTO target_group_members (group_id, member_id)
  SELECT tg.id, e.id
  FROM   target_groups tg
  CROSS  JOIN employees e
  WHERE  tg.scope_type = 'everyone'
    AND  e.deleted_at  IS NULL
    AND  e.status      = 'Active'
  ON CONFLICT DO NOTHING;

  -- ────────────────────────────────────────────────────────────────────────
  -- Scope: custom — evaluate filter_rules JSONB per group
  -- ────────────────────────────────────────────────────────────────────────
  FOR v_group IN
    SELECT id, filter_rules
    FROM   target_groups
    WHERE  scope_type   = 'custom'
      AND  filter_rules IS NOT NULL
  LOOP
    v_operator   := v_group.filter_rules->>'operator';       -- 'AND' | 'OR'
    v_rules      := v_group.filter_rules->'rules';
    v_rule_count := jsonb_array_length(v_rules);

    IF v_rule_count = 0 THEN
      CONTINUE;
    END IF;

    v_join_personal := false;
    v_where_parts   := ARRAY[]::text[];

    FOR v_i IN 0 .. v_rule_count - 1 LOOP
      v_rule  := v_rules->v_i;
      v_field := v_rule->>'field';

      -- Extract the values array as a text[]
      SELECT COALESCE(array_agg(elem->>'value'), ARRAY[]::text[])
      INTO   v_values
      FROM   jsonb_array_elements(v_rule->'values') AS elem;

      IF array_length(v_values, 1) IS NULL OR array_length(v_values, 1) = 0 THEN
        CONTINUE;
      END IF;

      -- Route the field to the correct table / column
      IF v_field IN ('nationality', 'gender') THEN
        -- plain-text columns in employee_personal
        v_join_personal := true;
        v_where_parts := array_append(
          v_where_parts,
          format('ep.%I = ANY(%L::text[])', v_field, v_values)
        );

      ELSIF v_field = 'marital_status' THEN
        -- UUID FK column in employee_personal
        v_join_personal := true;
        v_where_parts := array_append(
          v_where_parts,
          format('ep.marital_status = ANY(%L::uuid[])', v_values)
        );

      ELSIF v_field = 'dept_id' THEN
        v_where_parts := array_append(
          v_where_parts,
          format('e.dept_id = ANY(%L::uuid[])', v_values)
        );

      ELSIF v_field IN ('designation', 'work_country', 'work_location') THEN
        -- UUID FK columns in employees
        v_where_parts := array_append(
          v_where_parts,
          format('e.%I = ANY(%L::uuid[])', v_field, v_values)
        );

      ELSIF v_field IN ('status', 'name', 'employee_id') THEN
        -- plain-text columns in employees
        v_where_parts := array_append(
          v_where_parts,
          format('e.%I = ANY(%L::text[])', v_field, v_values)
        );

      END IF;
    END LOOP;

    -- Build WHERE expression joining all rule conditions
    IF array_length(v_where_parts, 1) IS NULL OR array_length(v_where_parts, 1) = 0 THEN
      CONTINUE;
    END IF;

    IF v_operator = 'AND' THEN
      v_where_clause := array_to_string(v_where_parts, ' AND ');
    ELSE
      v_where_clause := '(' || array_to_string(v_where_parts, ' OR ') || ')';
    END IF;

    -- Build the full SELECT
    v_sql := 'SELECT e.id FROM employees e';
    IF v_join_personal THEN
      v_sql := v_sql || ' LEFT JOIN employee_personal ep ON ep.employee_id = e.id';
    END IF;
    v_sql := v_sql
      || ' WHERE e.deleted_at IS NULL'
      || '   AND e.status = ''Active'''
      || '   AND ' || v_where_clause;

    -- Insert matching members
    EXECUTE format(
      'INSERT INTO target_group_members (group_id, member_id)
       SELECT %L::uuid, id FROM (%s) AS _sub
       ON CONFLICT DO NOTHING',
      v_group.id, v_sql
    );
  END LOOP;

  -- ── Row count for logging ─────────────────────────────────────────────────
  SELECT count(*) INTO v_total_rows FROM target_group_members;

  INSERT INTO job_run_log (
    job_code, job_name, started_at, completed_at, status, rows_processed, error_message
  ) VALUES (
    'sync_target_group_members',
    'Sync Target Group Members',
    v_start, clock_timestamp(), 'success', v_total_rows, NULL
  );

EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
  INSERT INTO job_run_log (
    job_code, job_name, started_at, completed_at, status, rows_processed, error_message
  ) VALUES (
    'sync_target_group_members',
    'Sync Target Group Members',
    v_start, clock_timestamp(), 'failed', 0, v_err
  );
  RAISE;
END;
$$;

COMMENT ON FUNCTION sync_target_group_members() IS
  'Rebuilds target_group_members cache. Handles everyone scope and custom scope '
  '(evaluates filter_rules JSONB, routing fields to employees or employee_personal). '
  'Called by pg_cron every 15 min and after Save rules.';

-- =============================================================================
-- END OF MIGRATION 20260501088_fix_sync_target_group_members_custom.sql
-- =============================================================================
