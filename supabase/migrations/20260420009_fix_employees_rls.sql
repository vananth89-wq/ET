-- ============================================================
-- Fix: employees table RLS - replace broken SECURITY DEFINER
--      function calls with inline subqueries.
--
-- Root cause: SECURITY DEFINER functions lose the JWT context,
-- so auth.uid() returns null inside has_role() and
-- get_my_employee_id(). This means no employee row is ever
-- returned on page refresh (hard reload forces a new DB call).
--
-- Fix: inline subqueries in the USING clause run in the RLS
-- evaluation context where auth.uid() is always correct.
-- ============================================================

-- Step 1: Drop ALL existing SELECT policies on employees
DO $$
DECLARE
  pol RECORD;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE tablename = 'employees' AND schemaname = 'public' AND cmd = 'SELECT'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON employees', pol.policyname);
    RAISE NOTICE 'Dropped employees SELECT policy: %', pol.policyname;
  END LOOP;
END;
$$;

-- Step 2: Create the corrected SELECT policy using inline subqueries.
-- Allows:
--   • admin / manager / finance  → any employee row
--   • regular employee           → only their own row (soft-delete aware)
CREATE POLICY employees_select
  ON employees
  FOR SELECT
  TO authenticated
  USING (
    -- Privileged roles: read any employee
    EXISTS (
      SELECT 1 FROM profile_roles
      WHERE profile_id = auth.uid()
        AND role = ANY(ARRAY['admin','manager','finance']::role_type[])
    )
    OR
    -- Regular employees: read only their own linked record
    (
      deleted_at IS NULL
      AND id = (
        SELECT employee_id FROM profiles WHERE id = auth.uid()
      )
    )
  );

-- Step 3: Fix has_role() — the function body was ignoring its
-- role parameter entirely, returning true for any user with any
-- row in profile_roles. Corrected to check the specific role.
CREATE OR REPLACE FUNCTION has_role(check_role role_type)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profile_roles
    WHERE profile_id = auth.uid()
      AND role = check_role
  );
$$;

-- Step 4: Re-create get_my_employee_id() with explicit search_path
-- (body is already correct; SET search_path is a security best practice)
CREATE OR REPLACE FUNCTION get_my_employee_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT employee_id FROM profiles WHERE id = auth.uid();
$$;

-- ── Verification ─────────────────────────────────────────────────────────────
-- After running, you should see exactly ONE SELECT policy on employees
-- named "employees_select" with inline subqueries (no has_role / get_my_employee_id).
SELECT policyname, cmd,
       left(qual, 120) AS policy_preview
FROM pg_policies
WHERE tablename = 'employees' AND schemaname = 'public'
ORDER BY cmd, policyname;
