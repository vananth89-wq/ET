-- =============================================================================
-- Role Architecture — Phase C: New has_role(), has_any_role(), all RLS policies
--
-- Switches the single source of truth for RLS from profile_roles to
-- user_roles → roles.code.
--
-- MUST run after Phase A+B (user_roles must be populated first).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 1: Core auth functions
-- ─────────────────────────────────────────────────────────────────────────────

-- has_role(text): checks if the current user has a specific role by code.
-- STABLE = Postgres evaluates once per query (not per row) — critical for RLS perf.
-- SECURITY DEFINER = bypasses RLS on user_roles/roles (no circular dependency).
CREATE OR REPLACE FUNCTION has_role(check_role text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles ur
    JOIN   roles r ON r.id = ur.role_id
    WHERE  ur.profile_id = auth.uid()
      AND  r.code        = check_role
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
  );
$$;

-- has_any_role(text[]): checks if the current user has ANY of the given roles.
CREATE OR REPLACE FUNCTION has_any_role(check_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles ur
    JOIN   roles r ON r.id = ur.role_id
    WHERE  ur.profile_id = auth.uid()
      AND  r.code        = ANY(check_roles)
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
  );
$$;

-- get_my_employee_id(): unchanged — still reads from profiles.
CREATE OR REPLACE FUNCTION get_my_employee_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT employee_id FROM profiles WHERE id = auth.uid();
$$;

-- is_my_direct_report(): unchanged.
CREATE OR REPLACE FUNCTION is_my_direct_report(emp_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE  id         = emp_id
      AND  manager_id = get_my_employee_id()
  );
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 2: Updated sync_system_roles() — writes to user_roles (not profile_roles)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sync_system_roles(p_profile_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile   RECORD;
  v_emp       RECORD;
  v_ess_id    uuid;
  v_mss_id    uuid;
  v_dh_id     uuid;
  v_inserted  integer := 0;
  v_removed   integer := 0;
BEGIN
  -- Get role IDs once
  SELECT id INTO v_ess_id FROM roles WHERE code = 'ess';
  SELECT id INTO v_mss_id FROM roles WHERE code = 'mss';
  SELECT id INTO v_dh_id  FROM roles WHERE code = 'dept_head';

  -- Iterate profiles (specific or all)
  FOR v_profile IN
    SELECT p.id, p.employee_id
    FROM   profiles p
    WHERE  (p_profile_id IS NULL OR p.id = p_profile_id)
      AND  p.is_active = true
  LOOP
    IF v_profile.employee_id IS NULL THEN CONTINUE; END IF;

    SELECT * INTO v_emp FROM employees WHERE id = v_profile.employee_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- ── ESS: every active employee gets ESS ──────────────────────────────────
    INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
    VALUES (v_profile.id, v_ess_id, 'system', true, now())
    ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true;
    v_inserted := v_inserted + 1;

    -- ── MSS: employee is someone's manager ───────────────────────────────────
    IF EXISTS (SELECT 1 FROM employees WHERE manager_id = v_emp.id AND deleted_at IS NULL) THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
      VALUES (v_profile.id, v_mss_id, 'system', true, now())
      ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true;
      v_inserted := v_inserted + 1;
    ELSE
      UPDATE user_roles SET is_active = false
      WHERE profile_id = v_profile.id AND role_id = v_mss_id
        AND assignment_source = 'system';
      GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

    -- ── Department Head ───────────────────────────────────────────────────────
    IF EXISTS (
      SELECT 1 FROM department_heads
      WHERE employee_id = v_emp.id AND (to_date IS NULL OR to_date >= CURRENT_DATE)
    ) THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
      VALUES (v_profile.id, v_dh_id, 'system', true, now())
      ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true;
      v_inserted := v_inserted + 1;
    ELSE
      UPDATE user_roles SET is_active = false
      WHERE profile_id = v_profile.id AND role_id = v_dh_id
        AND assignment_source = 'system';
      GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

  END LOOP;

  RETURN jsonb_build_object(
    'synced',  v_inserted,
    'revoked', v_removed
  );
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 3: Drop ALL existing RLS policies (clean slate)
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT schemaname, tablename, policyname
    FROM   pg_policies
    WHERE  schemaname = 'public'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I',
      r.policyname, r.schemaname, r.tablename);
  END LOOP;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 4: Recreate all RLS policies (text-based, no enum casts)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── CURRENCIES ───────────────────────────────────────────────────────────────
CREATE POLICY currencies_select ON currencies FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY currencies_insert ON currencies FOR INSERT
  WITH CHECK (has_any_role(ARRAY['finance', 'admin']));

CREATE POLICY currencies_update ON currencies FOR UPDATE
  USING      (has_any_role(ARRAY['finance', 'admin']))
  WITH CHECK (has_any_role(ARRAY['finance', 'admin']));

CREATE POLICY currencies_delete ON currencies FOR DELETE
  USING (has_role('admin'));

-- ── EXCHANGE RATES ────────────────────────────────────────────────────────────
CREATE POLICY exchange_rates_select ON exchange_rates FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY exchange_rates_insert ON exchange_rates FOR INSERT
  WITH CHECK (has_any_role(ARRAY['finance', 'admin']));

CREATE POLICY exchange_rates_update ON exchange_rates FOR UPDATE
  USING      (has_any_role(ARRAY['finance', 'admin']))
  WITH CHECK (has_any_role(ARRAY['finance', 'admin']));

CREATE POLICY exchange_rates_delete ON exchange_rates FOR DELETE
  USING (has_role('admin'));

-- ── PICKLISTS ─────────────────────────────────────────────────────────────────
CREATE POLICY picklists_select ON picklists FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY picklists_insert ON picklists FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY picklists_update ON picklists FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY picklists_delete ON picklists FOR DELETE
  USING (has_role('admin'));

-- ── PICKLIST VALUES ───────────────────────────────────────────────────────────
CREATE POLICY picklist_values_select ON picklist_values FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY picklist_values_insert ON picklist_values FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY picklist_values_update ON picklist_values FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY picklist_values_delete ON picklist_values FOR DELETE
  USING (has_role('admin'));

-- ── PROJECTS ──────────────────────────────────────────────────────────────────
CREATE POLICY projects_select ON projects FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY projects_insert ON projects FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY projects_update ON projects FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY projects_delete ON projects FOR DELETE
  USING (has_role('admin'));

-- ── DEPARTMENTS ───────────────────────────────────────────────────────────────
CREATE POLICY departments_select ON departments FOR SELECT
  USING (auth.uid() IS NOT NULL AND deleted_at IS NULL);

CREATE POLICY departments_insert ON departments FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY departments_update ON departments FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY departments_delete ON departments FOR DELETE
  USING (has_role('admin'));

-- ── DEPARTMENT HEADS ──────────────────────────────────────────────────────────
CREATE POLICY department_heads_select ON department_heads FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY department_heads_insert ON department_heads FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY department_heads_update ON department_heads FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY department_heads_delete ON department_heads FOR DELETE
  USING (has_role('admin'));

-- ── EMPLOYEES ─────────────────────────────────────────────────────────────────
-- Admins: all rows (including deleted).
-- Everyone else: active rows only (needed for org chart, expense reports etc.)
CREATE POLICY employees_select ON employees FOR SELECT
  USING (
    has_role('admin')
    OR (deleted_at IS NULL AND auth.uid() IS NOT NULL)
  );

CREATE POLICY employees_insert ON employees FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY employees_update ON employees FOR UPDATE
  USING      (id = get_my_employee_id() OR has_role('admin'))
  WITH CHECK (id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY employees_delete ON employees FOR DELETE
  USING (has_role('admin'));

-- ── EMPLOYEE SUB-TABLES (addresses, emergency contacts, identity, passports) ──
CREATE POLICY employee_addresses_select ON employee_addresses FOR SELECT
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY employee_addresses_insert ON employee_addresses FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY employee_addresses_update ON employee_addresses FOR UPDATE
  USING      (employee_id = get_my_employee_id() OR has_role('admin'))
  WITH CHECK (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY employee_addresses_delete ON employee_addresses FOR DELETE
  USING (has_role('admin'));

CREATE POLICY emergency_contacts_select ON emergency_contacts FOR SELECT
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY emergency_contacts_insert ON emergency_contacts FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY emergency_contacts_update ON emergency_contacts FOR UPDATE
  USING      (employee_id = get_my_employee_id() OR has_role('admin'))
  WITH CHECK (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY emergency_contacts_delete ON emergency_contacts FOR DELETE
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY identity_records_select ON identity_records FOR SELECT
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY identity_records_insert ON identity_records FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY identity_records_update ON identity_records FOR UPDATE
  USING      (employee_id = get_my_employee_id() OR has_role('admin'))
  WITH CHECK (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY identity_records_delete ON identity_records FOR DELETE
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY passports_select ON passports FOR SELECT
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY passports_insert ON passports FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY passports_update ON passports FOR UPDATE
  USING      (employee_id = get_my_employee_id() OR has_role('admin'))
  WITH CHECK (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY passports_delete ON passports FOR DELETE
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

-- ── PROFILES ──────────────────────────────────────────────────────────────────
CREATE POLICY profiles_select ON profiles FOR SELECT
  USING (id = auth.uid() OR has_role('admin'));

CREATE POLICY profiles_update ON profiles FOR UPDATE
  USING      (id = auth.uid() OR has_role('admin'))
  WITH CHECK (id = auth.uid() OR has_role('admin'));

CREATE POLICY profiles_delete ON profiles FOR DELETE
  USING (has_role('admin'));

-- ── ROLES (the named roles table) ─────────────────────────────────────────────
-- All authenticated users can read roles (needed for dropdowns and UI).
-- Only admins can mutate.
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;

CREATE POLICY roles_select ON roles FOR SELECT
  USING (auth.uid() IS NOT NULL AND active = true);

CREATE POLICY roles_insert ON roles FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY roles_update ON roles FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY roles_delete ON roles FOR DELETE
  USING (has_role('admin') AND is_system = false);

-- ── USER_ROLES ────────────────────────────────────────────────────────────────
-- Users can read their own roles (AuthContext).
-- Admins can read all (Role Assignments screen).
-- Note: has_role() uses SECURITY DEFINER so it bypasses these policies
-- internally — no circular dependency.
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_roles_select ON user_roles FOR SELECT
  USING (profile_id = auth.uid() OR has_role('admin'));

CREATE POLICY user_roles_insert ON user_roles FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY user_roles_update ON user_roles FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY user_roles_delete ON user_roles FOR DELETE
  USING (has_role('admin'));

-- ── MODULES & PERMISSIONS ────────────────────────────────────────────────────
ALTER TABLE modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY modules_select ON modules FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY modules_insert ON modules FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY modules_update ON modules FOR UPDATE
  USING (has_role('admin')) WITH CHECK (has_role('admin'));

CREATE POLICY modules_delete ON modules FOR DELETE
  USING (has_role('admin'));

CREATE POLICY permissions_select ON permissions FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY permissions_insert ON permissions FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY permissions_update ON permissions FOR UPDATE
  USING (has_role('admin')) WITH CHECK (has_role('admin'));

CREATE POLICY permissions_delete ON permissions FOR DELETE
  USING (has_role('admin'));

CREATE POLICY role_permissions_select ON role_permissions FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY role_permissions_insert ON role_permissions FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY role_permissions_delete ON role_permissions FOR DELETE
  USING (has_role('admin'));

-- ── EXPENSE REPORTS ───────────────────────────────────────────────────────────
CREATE POLICY expense_reports_select ON expense_reports FOR SELECT
  USING (
    deleted_at IS NULL AND (
      has_role('admin')
      OR (has_role('finance') AND status != 'draft')
      OR (has_role('manager') AND status != 'draft' AND is_my_direct_report(employee_id))
      OR (has_role('dept_head') AND status != 'draft' AND is_my_direct_report(employee_id))
      OR employee_id = get_my_employee_id()
    )
  );

CREATE POLICY expense_reports_insert ON expense_reports FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id());

CREATE POLICY expense_reports_update ON expense_reports FOR UPDATE
  USING (
    has_role('admin')
    OR (has_any_role(ARRAY['finance', 'manager', 'dept_head']) AND status IN ('submitted', 'approved', 'rejected'))
    OR (employee_id = get_my_employee_id() AND status IN ('draft', 'rejected'))
  )
  WITH CHECK (
    has_role('admin')
    OR (has_any_role(ARRAY['finance', 'manager', 'dept_head']) AND status IN ('submitted', 'approved', 'rejected'))
    OR (employee_id = get_my_employee_id() AND status IN ('draft', 'rejected'))
  );

CREATE POLICY expense_reports_delete ON expense_reports FOR DELETE
  USING (has_role('admin'));

-- ── LINE ITEMS ────────────────────────────────────────────────────────────────
CREATE POLICY line_items_select ON line_items FOR SELECT
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id = line_items.report_id
        AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_role('finance') AND er.status != 'draft')
          OR (has_any_role(ARRAY['manager', 'dept_head']) AND er.status != 'draft' AND is_my_direct_report(er.employee_id))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );

CREATE POLICY line_items_insert ON line_items FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id         = line_items.report_id
        AND er.status     = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY line_items_update ON line_items FOR UPDATE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id          = line_items.report_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  )
  WITH CHECK (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id          = line_items.report_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY line_items_delete ON line_items FOR DELETE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id          = line_items.report_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

-- ── ATTACHMENTS ───────────────────────────────────────────────────────────────
CREATE POLICY attachments_select ON attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id = attachments.line_item_id
        AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_role('finance') AND er.status != 'draft')
          OR (has_any_role(ARRAY['manager', 'dept_head']) AND er.status != 'draft' AND is_my_direct_report(er.employee_id))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );

CREATE POLICY attachments_insert ON attachments FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id        = attachments.line_item_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY attachments_update ON attachments FOR UPDATE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id        = attachments.line_item_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  )
  WITH CHECK (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id        = attachments.line_item_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY attachments_delete ON attachments FOR DELETE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id        = attachments.line_item_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

-- ── WORKFLOW INSTANCES ────────────────────────────────────────────────────────
CREATE POLICY workflow_instances_select ON workflow_instances FOR SELECT
  USING (has_any_role(ARRAY['manager', 'dept_head', 'finance', 'admin']));

CREATE POLICY workflow_instances_insert ON workflow_instances FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY workflow_instances_update ON workflow_instances FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY workflow_instances_delete ON workflow_instances FOR DELETE
  USING (has_role('admin'));

-- ── AUDIT LOG ─────────────────────────────────────────────────────────────────
CREATE POLICY audit_log_select ON audit_log FOR SELECT
  USING (user_id = auth.uid() OR has_role('admin'));

CREATE POLICY audit_log_insert ON audit_log FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY audit_log_update ON audit_log FOR UPDATE
  USING      (user_id = auth.uid() OR has_role('admin'))
  WITH CHECK (user_id = auth.uid() OR has_role('admin'));

CREATE POLICY audit_log_delete ON audit_log FOR DELETE
  USING (user_id = auth.uid() OR has_role('admin'));

-- ── NOTIFICATIONS ─────────────────────────────────────────────────────────────
CREATE POLICY notifications_select ON notifications FOR SELECT
  USING (user_id = auth.uid() OR has_role('admin'));

CREATE POLICY notifications_insert ON notifications FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY notifications_update ON notifications FOR UPDATE
  USING      (user_id = auth.uid() OR has_role('admin'))
  WITH CHECK (user_id = auth.uid() OR has_role('admin'));

CREATE POLICY notifications_delete ON notifications FOR DELETE
  USING (user_id = auth.uid() OR has_role('admin'));


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 5: Verification — confirm has_role() works via new path
-- ─────────────────────────────────────────────────────────────────────────────
-- Run this after applying the migration while connected as a real user:
--   SELECT has_role('admin');   -- should return true for admin users
--   SELECT has_any_role(ARRAY['finance','admin']);
