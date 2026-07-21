-- =============================================================================
-- Migration 682: Employee ID Sequence — peek/consume split + admin management
--
-- Fixes a long-standing bug where every Add Employee form load (and every
-- resetForm() call after save/cancel/discard) burned a sequence number by
-- calling generate_employee_id(), which internally calls nextval(). Users
-- were seeing large gaps in EMP-XXXX numbering.
--
-- Fix: peek-on-view / consume-on-save.
--
--   * peek_next_employee_id()      — reads last_value/is_called, returns the
--                                    next id WITHOUT advancing the sequence.
--                                    Safe for previews.
--   * get_emp_id_seq_status()      — returns full status JSON for the admin
--                                    Manage Sequence page.
--   * admin_set_emp_id_seq(bigint) — permission-gated manual override to jump
--                                    the sequence forward (forward-only for
--                                    safety — going backward could collide
--                                    with existing employee_ids).
--
-- Also:
--   * setval() resets sequence so next nextval() returns 100101 (jump past
--     current ~500 range to distinguish new hires from legacy).
--   * Two new permissions gate the admin page:
--       manage_emp_sequence.view / manage_emp_sequence.edit
--     (module: 'employee' — same module as employees.view/edit)
-- =============================================================================


-- ── 1. Reset emp_id_seq so next nextval returns 100101 ────────────────────────
SELECT setval('emp_id_seq', 100100, true);


-- ── 2. peek_next_employee_id — read without consuming ────────────────────────
CREATE OR REPLACE FUNCTION peek_next_employee_id()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_last   bigint;
  v_called boolean;
  v_next   bigint;
BEGIN
  SELECT last_value, is_called INTO v_last, v_called FROM emp_id_seq;
  v_next := CASE WHEN v_called THEN v_last + 1 ELSE v_last END;
  RETURN 'EMP-' || lpad(v_next::text, 4, '0');
END $$;

COMMENT ON FUNCTION peek_next_employee_id() IS
  'Returns the next employee_id (EMP-XXXX) WITHOUT advancing emp_id_seq. Use for previews only. Actual consumption must call generate_employee_id() at save time.';

REVOKE ALL ON FUNCTION peek_next_employee_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION peek_next_employee_id() TO authenticated;


-- ── 3. get_emp_id_seq_status — full status for admin panel ───────────────────
CREATE OR REPLACE FUNCTION get_emp_id_seq_status()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_last         bigint;
  v_called       boolean;
  v_next         bigint;
  v_seq_count    integer;
  v_legacy_count integer;
BEGIN
  SELECT last_value, is_called INTO v_last, v_called FROM emp_id_seq;
  v_next := CASE WHEN v_called THEN v_last + 1 ELSE v_last END;

  SELECT count(*) INTO v_seq_count
    FROM employees
   WHERE employee_id ~ '^EMP-\d+$';

  SELECT count(*) INTO v_legacy_count
    FROM employees
   WHERE employee_id ~ '^EMP\d+$';

  RETURN json_build_object(
    'last_value',                    v_last,
    'is_called',                     v_called,
    'next_value',                    v_next,
    'next_formatted',                'EMP-' || lpad(v_next::text, 4, '0'),
    'employees_with_seq_format',     v_seq_count,
    'employees_with_legacy_format',  v_legacy_count
  );
END $$;

COMMENT ON FUNCTION get_emp_id_seq_status() IS
  'Full status JSON for the Manage Sequence admin panel — current + next values plus counts of employees in the seq vs legacy id formats.';

REVOKE ALL ON FUNCTION get_emp_id_seq_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_emp_id_seq_status() TO authenticated;


-- ── 4. admin_set_emp_id_seq — manual override, permission-gated ──────────────
CREATE OR REPLACE FUNCTION admin_set_emp_id_seq(p_new_next_value bigint)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller         uuid;
  v_current_last   bigint;
  v_current_called boolean;
  v_current_next   bigint;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Permission check: caller must have manage_emp_sequence.edit OR be a super admin.
  -- user_can/is_super_admin both resolve caller via auth.uid() internally.
  IF NOT is_super_admin() AND NOT user_can('manage_emp_sequence', 'edit', NULL) THEN
    RAISE EXCEPTION 'Permission denied: manage_emp_sequence.edit required';
  END IF;

  IF p_new_next_value < 1 THEN
    RAISE EXCEPTION 'Sequence value must be positive';
  END IF;

  SELECT last_value, is_called INTO v_current_last, v_current_called FROM emp_id_seq;
  v_current_next := CASE WHEN v_current_called THEN v_current_last + 1 ELSE v_current_last END;

  IF p_new_next_value <= v_current_next THEN
    RAISE EXCEPTION 'New next value % must be greater than current next value % (sequences cannot go backwards safely — that could cause collisions with existing employee IDs)',
      p_new_next_value, v_current_next;
  END IF;

  -- setval with is_called=true so next nextval returns p_new_next_value
  PERFORM setval('emp_id_seq', p_new_next_value - 1, true);

  RETURN json_build_object(
    'success',             true,
    'previous_next_value', v_current_next,
    'new_next_value',      p_new_next_value,
    'new_next_formatted',  'EMP-' || lpad(p_new_next_value::text, 4, '0')
  );
END $$;

COMMENT ON FUNCTION admin_set_emp_id_seq(bigint) IS
  'Manual, forward-only override of emp_id_seq. Requires manage_emp_sequence.edit (or super admin). Refuses to move the sequence backward to avoid employee_id collisions.';

REVOKE ALL ON FUNCTION admin_set_emp_id_seq(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_set_emp_id_seq(bigint) TO authenticated;


-- ── 5. New permissions ───────────────────────────────────────────────────────
-- Module: 'employee' — same as employees.view/edit (single canonical employee module).
DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'employee' LIMIT 1;

  IF v_module_id IS NULL THEN
    RAISE EXCEPTION 'Could not find employee module — expected modules.code = ''employee''';
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description, sort_order)
  VALUES
    ('manage_emp_sequence.view', v_module_id, 'view',
     'View Employee ID Sequence',
     'See the current and next employee ID sequence values on the Manage Sequence admin page.',
     200),
    ('manage_emp_sequence.edit', v_module_id, 'edit',
     'Edit Employee ID Sequence',
     'Manually advance the employee ID sequence (forward-only for safety) on the Manage Sequence admin page.',
     201)
  ON CONFLICT (code) DO NOTHING;
END $$;


-- ── Verification ─────────────────────────────────────────────────────────────
SELECT peek_next_employee_id() AS next_id;

SELECT code, action, name
  FROM permissions
 WHERE code LIKE 'manage_emp_sequence.%'
 ORDER BY code;

-- =============================================================================
-- END OF MIGRATION 682
-- =============================================================================
