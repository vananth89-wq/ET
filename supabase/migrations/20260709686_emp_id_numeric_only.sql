-- ─────────────────────────────────────────────────────────────────────────────
-- Switch employee_id format from 'EMP-XXXXXX' to pure numeric ('XXXXXX')
--
-- WHY
-- ═══
-- Business decision — employee IDs should be just the number, no prefix.
--
-- SCOPE
-- ═════
-- 1. Backfill: strip 'EMP-' prefix from all existing employee_id values.
--    Legacy format 'EMP001' → strip 'EMP' AND leading zeros.
-- 2. Update the 4 sequence-related RPCs to return pure numbers.
-- 3. Vijey's bootstrap ID becomes '100103' (was 'EMP001').
-- 4. Sequence advanced so next value = 100104.
-- ─────────────────────────────────────────────────────────────────────────────


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Backfill existing employee_ids
-- ═════════════════════════════════════════════════════════════════════════════

-- Set Vijey specifically to 100103 (was EMP001)
UPDATE employees
   SET employee_id = '100103'
 WHERE employee_id = 'EMP001';

-- Strip 'EMP-' prefix from all remaining employees (EMP-100101 → 100101, etc.)
UPDATE employees
   SET employee_id = substring(employee_id from 5)
 WHERE employee_id ~ '^EMP-\d+$';

-- Strip 'EMP' + leading zeros from any lingering legacy format (EMP0043 → 43)
UPDATE employees
   SET employee_id = regexp_replace(employee_id, '^EMP0*', '')
 WHERE employee_id ~ '^EMP\d+$';


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Advance sequence so next value = 100104
--    (100101 taken by Kyamuddin, 100102 by Mohammed, 100103 now Vijey)
-- ═════════════════════════════════════════════════════════════════════════════

SELECT setval('emp_id_seq', 100103, true);


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Update RPCs — return pure numeric strings
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION generate_employee_id()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN nextval('emp_id_seq')::text;
END $$;


CREATE OR REPLACE FUNCTION peek_next_employee_id()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_last bigint;
  v_called boolean;
  v_next bigint;
BEGIN
  SELECT last_value, is_called INTO v_last, v_called FROM emp_id_seq;
  v_next := CASE WHEN v_called THEN v_last + 1 ELSE v_last END;
  RETURN v_next::text;
END $$;


CREATE OR REPLACE FUNCTION get_emp_id_seq_status()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_last bigint;
  v_called boolean;
  v_next bigint;
  v_total integer;
BEGIN
  SELECT last_value, is_called INTO v_last, v_called FROM emp_id_seq;
  v_next := CASE WHEN v_called THEN v_last + 1 ELSE v_last END;
  SELECT count(*) INTO v_total FROM employees WHERE deleted_at IS NULL;
  RETURN json_build_object(
    'last_value', v_last,
    'is_called', v_called,
    'next_value', v_next,
    'next_formatted', v_next::text,
    'employees_with_seq_format', v_total,
    'employees_with_legacy_format', 0
  );
END $$;


CREATE OR REPLACE FUNCTION admin_set_emp_id_seq(p_new_next_value bigint)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_last bigint;
  v_current_called boolean;
  v_current_next bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT is_super_admin() AND NOT user_can('manage_emp_sequence', 'edit', NULL) THEN
    RAISE EXCEPTION 'Permission denied: manage_emp_sequence.edit required';
  END IF;

  IF p_new_next_value < 1 THEN
    RAISE EXCEPTION 'Sequence value must be positive';
  END IF;

  SELECT last_value, is_called INTO v_current_last, v_current_called FROM emp_id_seq;
  v_current_next := CASE WHEN v_current_called THEN v_current_last + 1 ELSE v_current_last END;

  IF p_new_next_value <= v_current_next THEN
    RAISE EXCEPTION 'New next value % must be greater than current next value % (sequences cannot go backwards safely — that could cause collisions with existing employee IDs)', p_new_next_value, v_current_next;
  END IF;

  PERFORM setval('emp_id_seq', p_new_next_value - 1, true);

  RETURN json_build_object(
    'success', true,
    'previous_next_value', v_current_next,
    'new_next_value', p_new_next_value,
    'new_next_formatted', p_new_next_value::text
  );
END $$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Verification
-- ═════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_next text;
  v_legacy_count integer;
BEGIN
  SELECT peek_next_employee_id() INTO v_next;
  SELECT count(*) INTO v_legacy_count FROM employees WHERE employee_id ~ '[^0-9]';
  RAISE NOTICE 'Employee ID format switched to numeric-only. Next ID = %. Non-numeric IDs remaining: %',
    v_next, v_legacy_count;
END $$;
