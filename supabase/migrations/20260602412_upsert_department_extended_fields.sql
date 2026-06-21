-- =============================================================================
-- Migration 410 — upsert_department: fix p_row keys + add extended fields
--
-- BUG: The original upsert_department (mig 376) read p_row->>'dept_id' and
-- p_row->>'name', but the edge function passes headerToSnake(col.name) keys:
--   "Department Code *" → "department_code"
--   "Department Name *" → "department_name"
-- So bulk department import has been silently erroring since mig 376.
--
-- This migration also adds support for the new fields introduced by mig 408's
-- schema_definition update:
--   "Parent Department Code" → "parent_department_code" (resolves to UUID)
--   "Head Employee Code"     → "head_employee_code"     (resolves to UUID)
--   "Start Date"             → "start_date"             (MM/DD/YYYY → DATE)
--   "End Date"               → "end_date"               (MM/DD/YYYY → DATE)
--
-- Predecessor: mig 408 (export + schema_definition for department)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_department(
  p_row JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dept_code         TEXT;
  v_name              TEXT;
  v_parent_dept_id    UUID;
  v_head_employee_id  UUID;
  v_start_date        DATE;
  v_end_date          DATE;
BEGIN
  IF NOT user_can('department', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: department.bulk_import required');
  END IF;

  -- headerToSnake("Department Code *") = "department_code"
  -- headerToSnake("Department Name *") = "department_name"
  v_dept_code := NULLIF(TRIM(p_row->>'department_code'), '');
  v_name      := NULLIF(TRIM(p_row->>'department_name'), '');

  IF v_dept_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '"Department Code *" is required');
  END IF;
  IF v_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', '"Department Name *" is required');
  END IF;

  -- ── Resolve Parent Department Code → UUID ──────────────────────────────────
  -- headerToSnake("Parent Department Code") = "parent_department_code"
  IF NULLIF(TRIM(p_row->>'parent_department_code'), '') IS NOT NULL THEN
    SELECT id INTO v_parent_dept_id
    FROM   departments
    WHERE  dept_id    = TRIM(p_row->>'parent_department_code')
      AND  deleted_at IS NULL;

    IF v_parent_dept_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Parent department not found: %s', p_row->>'parent_department_code'));
    END IF;
  END IF;

  -- ── Resolve Head Employee Code → UUID ─────────────────────────────────────
  -- headerToSnake("Head Employee Code") = "head_employee_code"
  IF NULLIF(TRIM(p_row->>'head_employee_code'), '') IS NOT NULL THEN
    SELECT id INTO v_head_employee_id
    FROM   employees
    WHERE  employee_id = TRIM(p_row->>'head_employee_code');

    IF v_head_employee_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Head employee not found: %s', p_row->>'head_employee_code'));
    END IF;
  END IF;

  -- ── Parse dates (MM/DD/YYYY) ───────────────────────────────────────────────
  -- headerToSnake("Start Date") = "start_date"
  -- headerToSnake("End Date")   = "end_date"
  BEGIN
    IF NULLIF(TRIM(p_row->>'start_date'), '') IS NOT NULL THEN
      v_start_date := TO_DATE(p_row->>'start_date', 'MM/DD/YYYY');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Invalid Start Date: %s (expected MM/DD/YYYY)', p_row->>'start_date'));
  END;

  BEGIN
    IF NULLIF(TRIM(p_row->>'end_date'), '') IS NOT NULL THEN
      v_end_date := TO_DATE(p_row->>'end_date', 'MM/DD/YYYY');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Invalid End Date: %s (expected MM/DD/YYYY)', p_row->>'end_date'));
  END;

  -- ── Upsert ─────────────────────────────────────────────────────────────────
  INSERT INTO departments (
    dept_id,
    name,
    parent_dept_id,
    head_employee_id,
    start_date,
    end_date
  )
  VALUES (
    v_dept_code,
    v_name,
    v_parent_dept_id,
    v_head_employee_id,
    v_start_date,
    v_end_date
  )
  ON CONFLICT (dept_id) DO UPDATE SET
    name             = EXCLUDED.name,
    -- Only overwrite FKs/dates if the import row supplied a value
    -- (blank = leave existing value unchanged)
    parent_dept_id   = CASE WHEN v_parent_dept_id   IS NOT NULL
                            THEN EXCLUDED.parent_dept_id
                            ELSE departments.parent_dept_id   END,
    head_employee_id = CASE WHEN v_head_employee_id IS NOT NULL
                            THEN EXCLUDED.head_employee_id
                            ELSE departments.head_employee_id END,
    start_date       = CASE WHEN v_start_date IS NOT NULL
                            THEN EXCLUDED.start_date
                            ELSE departments.start_date       END,
    end_date         = CASE WHEN v_end_date IS NOT NULL
                            THEN EXCLUDED.end_date
                            ELSE departments.end_date         END,
    updated_at       = NOW()
  WHERE departments.deleted_at IS NULL;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_department IS
  'Bulk-import processor for department template (mig 410).
   Reads p_row keys in headerToSnake format:
     department_code, department_name, parent_department_code,
     head_employee_code, start_date (MM/DD/YYYY), end_date (MM/DD/YYYY).
   Upserts on dept_id; blank optional fields leave existing DB values unchanged.';

GRANT EXECUTE ON FUNCTION upsert_department(JSONB) TO authenticated;


-- =============================================================================
-- Re-apply schema_definition for department template
--
-- Mig 408's UPDATE may have run 0 rows if the template_code didn't match at
-- the time (e.g. the registry row wasn't yet seeded). This block is idempotent
-- and ensures the correct full schema — including system metadata columns — is
-- in place regardless of migration order.
-- =============================================================================

UPDATE bulk_template_registry
SET schema_definition = jsonb_build_object(
  'columns', (
    SELECT jsonb_agg(col ORDER BY ord)
    FROM (
      VALUES
        (jsonb_build_object('name','Department Code *',      'data_type','text',           'mandatory',true, 'user_fillable',true),  1),
        (jsonb_build_object('name','Department Name *',      'data_type','text',           'mandatory',true, 'user_fillable',true),  2),
        (jsonb_build_object('name','Parent Department Code', 'data_type','code_department','mandatory',false,'user_fillable',true),  3),
        (jsonb_build_object('name','Head Employee Code',     'data_type','code_employee',  'mandatory',false,'user_fillable',true),  4),
        (jsonb_build_object('name','Start Date',             'data_type','date_mmddyyyy',  'mandatory',false,'user_fillable',true),  5),
        (jsonb_build_object('name','End Date',               'data_type','date_mmddyyyy',  'mandatory',false,'user_fillable',true),  6),
        (jsonb_build_object('name','id',         'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7),
        (jsonb_build_object('name','Created At', 'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8),
        (jsonb_build_object('name','Updated At', 'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9)
    ) AS t(col, ord)
  ),
  'row_processor', 'per_row',
  'natural_key',   jsonb_build_array('Department Code *')
),
updated_at = NOW()
WHERE template_code = 'department';

-- Verify the update landed (will show 0 rows if template_code not found)
DO $$
DECLARE v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM bulk_template_registry
  WHERE template_code = 'department'
    AND jsonb_array_length(schema_definition->'columns') = 9;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'department schema_definition not updated — template_code not found or column count wrong';
  END IF;
END $$;

-- =============================================================================
-- END OF MIGRATION 410
-- =============================================================================
