-- ── Fix lpad truncation bug in employee ID generation functions ─────────────
--
-- Postgres's lpad(str, N, pad) TRUNCATES the string when it's longer than N.
-- So lpad('100101', 4, '0') returns '1001' (chops off the 6-char string to 4).
-- This breaks employee IDs for any sequence value ≥ 10000.
--
-- Fix: use a CASE to only pad values shorter than 4 digits; longer values
-- render as-is. Maintains backwards compatibility (EMP-0001 through EMP-9999
-- still zero-pad) while allowing EMP-100101, EMP-999999, etc. to render fully.
--
-- Affected functions:
--   1. generate_employee_id()     — created in mig 20260513217
--   2. peek_next_employee_id()    — created in mig 20260709682
--   3. get_emp_id_seq_status()    — created in mig 20260709682
--   4. admin_set_emp_id_seq()     — created in mig 20260709682

-- ── 1. generate_employee_id (mig 217 fix) ───────────────────────────────────
CREATE OR REPLACE FUNCTION generate_employee_id()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_next bigint;
BEGIN
  v_next := nextval('emp_id_seq');
  RETURN 'EMP-' || CASE
    WHEN v_next < 10000 THEN lpad(v_next::text, 4, '0')
    ELSE v_next::text
  END;
END $$;

-- ── 2. peek_next_employee_id ────────────────────────────────────────────────
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
  RETURN 'EMP-' || CASE
    WHEN v_next < 10000 THEN lpad(v_next::text, 4, '0')
    ELSE v_next::text
  END;
END $$;

-- ── 3. get_emp_id_seq_status ────────────────────────────────────────────────
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
  v_next_formatted text;
  v_seq_count integer;
  v_legacy_count integer;
BEGIN
  SELECT last_value, is_called INTO v_last, v_called FROM emp_id_seq;
  v_next := CASE WHEN v_called THEN v_last + 1 ELSE v_last END;
  v_next_formatted := 'EMP-' || CASE
    WHEN v_next < 10000 THEN lpad(v_next::text, 4, '0')
    ELSE v_next::text
  END;
  SELECT count(*) INTO v_seq_count   FROM employees WHERE employee_id ~ '^EMP-\d+$';
  SELECT count(*) INTO v_legacy_count FROM employees WHERE employee_id ~ '^EMP\d+$';
  RETURN json_build_object(
    'last_value', v_last,
    'is_called', v_called,
    'next_value', v_next,
    'next_formatted', v_next_formatted,
    'employees_with_seq_format', v_seq_count,
    'employees_with_legacy_format', v_legacy_count
  );
END $$;

-- ── 4. admin_set_emp_id_seq ─────────────────────────────────────────────────
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
  v_formatted text;
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

  v_formatted := 'EMP-' || CASE
    WHEN p_new_next_value < 10000 THEN lpad(p_new_next_value::text, 4, '0')
    ELSE p_new_next_value::text
  END;

  RETURN json_build_object(
    'success', true,
    'previous_next_value', v_current_next,
    'new_next_value', p_new_next_value,
    'new_next_formatted', v_formatted
  );
END $$;
