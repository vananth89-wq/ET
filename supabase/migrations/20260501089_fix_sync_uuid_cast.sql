-- =============================================================================
-- Migration : 20260501089_fix_sync_uuid_cast.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-05-01
-- Description:
--   Fixes sync_target_group_members() — replaces ::uuid[] casts with ::text[]
--   throughout the dynamic SQL generation.
--
--   Root cause: UUID FK values (dept_id, designation, work_country, etc.) are
--   stored as TEXT in several columns. ANY('{uuid}'::uuid[]) fails to match
--   TEXT columns even though IN ('uuid') works fine. Using ::text[] for all
--   comparisons is safe — PostgreSQL implicit-casts UUID values to text when
--   reading from UUID-typed columns, so UUID = TEXT comparison always works.
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

  v_group        RECORD;
  v_operator     text;
  v_rules        jsonb;
  v_rule         jsonb;
  v_rule_count   int;
  v_i            int;

  v_field        text;
  v_values       text[];

  v_join_personal  boolean;
  v_where_parts    text[];
  v_where_clause   text;
  v_sql            text;

BEGIN
  -- ── Truncate first (cache always rebuilt in full) ─────────────────────────
  TRUNCATE target_group_members;

  -- ── Scope: everyone ───────────────────────────────────────────────────────
  INSERT INTO target_group_members (group_id, member_id)
  SELECT tg.id, e.id
  FROM   target_groups tg
  CROSS  JOIN employees e
  WHERE  tg.scope_type = 'everyone'
    AND  e.deleted_at  IS NULL
    AND  e.status      = 'Active'
  ON CONFLICT DO NOTHING;

  -- ── Scope: custom — evaluate filter_rules JSONB per group ─────────────────
  FOR v_group IN
    SELECT id, filter_rules
    FROM   target_groups
    WHERE  scope_type   = 'custom'
      AND  filter_rules IS NOT NULL
  LOOP
    v_operator   := v_group.filter_rules->>'operator';
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

      SELECT COALESCE(array_agg(elem->>'value'), ARRAY[]::text[])
      INTO   v_values
      FROM   jsonb_array_elements(v_rule->'values') AS elem;

      IF array_length(v_values, 1) IS NULL OR array_length(v_values, 1) = 0 THEN
        CONTINUE;
      END IF;

      -- Route field to correct table/column.
      -- Use ::text[] for ALL comparisons — avoids type-mismatch failures when
      -- UUID values are stored as TEXT columns (marital_status, designation, etc.)
      IF v_field IN ('nationality', 'gender') THEN
        v_join_personal := true;
        v_where_parts := array_append(v_where_parts,
          format('ep.%I = ANY(%L::text[])', v_field, v_values));

      ELSIF v_field = 'marital_status' THEN
        v_join_personal := true;
        v_where_parts := array_append(v_where_parts,
          format('ep.marital_status::text = ANY(%L::text[])', v_values));

      ELSIF v_field = 'dept_id' THEN
        v_where_parts := array_append(v_where_parts,
          format('e.dept_id::text = ANY(%L::text[])', v_values));

      ELSIF v_field IN ('designation', 'work_country', 'work_location') THEN
        v_where_parts := array_append(v_where_parts,
          format('e.%I::text = ANY(%L::text[])', v_field, v_values));

      ELSIF v_field IN ('status', 'name', 'employee_id') THEN
        v_where_parts := array_append(v_where_parts,
          format('e.%I = ANY(%L::text[])', v_field, v_values));

      END IF;
    END LOOP;

    IF array_length(v_where_parts, 1) IS NULL OR array_length(v_where_parts, 1) = 0 THEN
      CONTINUE;
    END IF;

    IF v_operator = 'AND' THEN
      v_where_clause := array_to_string(v_where_parts, ' AND ');
    ELSE
      v_where_clause := '(' || array_to_string(v_where_parts, ' OR ') || ')';
    END IF;

    v_sql := 'SELECT e.id FROM employees e';
    IF v_join_personal THEN
      v_sql := v_sql || ' LEFT JOIN employee_personal ep ON ep.employee_id = e.id';
    END IF;
    v_sql := v_sql
      || ' WHERE e.deleted_at IS NULL'
      || '   AND e.status = ''Active'''
      || '   AND ' || v_where_clause;

    EXECUTE format(
      'INSERT INTO target_group_members (group_id, member_id)
       SELECT %L::uuid, id FROM (%s) AS _sub
       ON CONFLICT DO NOTHING',
      v_group.id, v_sql
    );
  END LOOP;

  SELECT count(*) INTO v_total_rows FROM target_group_members;

  INSERT INTO job_run_log (
    job_code, job_name, started_at, completed_at, status, rows_processed, error_message
  ) VALUES (
    'sync_target_group_members', 'Sync Target Group Members',
    v_start, clock_timestamp(), 'success', v_total_rows, NULL
  );

EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
  INSERT INTO job_run_log (
    job_code, job_name, started_at, completed_at, status, rows_processed, error_message
  ) VALUES (
    'sync_target_group_members', 'Sync Target Group Members',
    v_start, clock_timestamp(), 'failed', 0, v_err
  );
  RAISE;
END;
$$;

-- =============================================================================
-- END OF MIGRATION 20260501089_fix_sync_uuid_cast.sql
-- =============================================================================
