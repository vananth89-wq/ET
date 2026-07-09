DO $$
DECLARE
  v_auth_id uuid;
  v_emp_id  uuid;
BEGIN
  SELECT id INTO v_auth_id
    FROM auth.users
   WHERE email = 'vijey@prowessinfotech.co.in' LIMIT 1;

  -- 1. Profile first (no employee_id yet)
  INSERT INTO profiles (id, employee_id, is_active)
  VALUES (v_auth_id, NULL, true);

  -- 2. Super admin grant early (so RLS/trigger checks pass)
  INSERT INTO super_admins (profile_id, granted_at, granted_by)
  VALUES (v_auth_id, now(), 'bootstrap');

  -- 3. Employee (pass created_by explicitly)
  INSERT INTO employees (id, employee_id, name, business_email, status, locked, created_by)
  VALUES (gen_random_uuid(), 'EMP001', 'Vijey Ananth', 'vijey@prowessinfotech.co.in', 'Active', false, v_auth_id)
  RETURNING id INTO v_emp_id;

  -- 4. Link profile to employee
  UPDATE profiles SET employee_id = v_emp_id WHERE id = v_auth_id;

  RAISE NOTICE 'auth=% employee=%', v_auth_id, v_emp_id;
END $$;