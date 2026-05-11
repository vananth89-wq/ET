-- =============================================================================
-- Migration 059: Employee invite schema
--
-- Adds invite tracking columns to employees, creates employee_invites audit
-- table, patches handle_new_user() to stamp invite_accepted_at, adds an ESS
-- deactivation trigger when an employee becomes Inactive, and creates a
-- reconcile_employee_profiles() RPC to back-fill existing profiles.
-- =============================================================================


-- ── 1. New columns on employees ──────────────────────────────────────────────

ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS invite_sent_at     timestamptz DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS invite_accepted_at timestamptz DEFAULT NULL;

COMMENT ON COLUMN employees.invite_sent_at     IS 'When the welcome / activation email was last sent.';
COMMENT ON COLUMN employees.invite_accepted_at IS 'When the employee first signed in and accepted the invite.';


-- ── 2. employee_invites audit table ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS employee_invites (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     uuid        NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  attempt_no      int         NOT NULL DEFAULT 1,
  sent_at         timestamptz NOT NULL DEFAULT now(),
  status          text        NOT NULL DEFAULT 'sent'
                              CHECK (status IN ('sent','accepted','expired','failed')),
  error_message   text,
  reminder_sent_at timestamptz DEFAULT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_employee_invites_employee_id
  ON employee_invites (employee_id);

CREATE INDEX IF NOT EXISTS idx_employee_invites_status
  ON employee_invites (status);

COMMENT ON TABLE employee_invites IS
  'Audit log of every welcome/invite email sent to an employee. '
  'One row per attempt. status: sent→accepted when the employee first signs in.';


-- ── 3. Patch handle_new_user() to stamp invite_accepted_at ───────────────────
--
-- When a new auth user is created whose email matches an employee with
-- invite_sent_at IS NOT NULL, stamp invite_accepted_at and mark the latest
-- employee_invites row as accepted.

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  v_emp_id   uuid;
  v_ess_role uuid;
BEGIN
  -- Create bare profile
  INSERT INTO public.profiles (id, is_active, created_at, updated_at)
  VALUES (NEW.id, true, NOW(), NOW())
  ON CONFLICT (id) DO NOTHING;

  -- Auto-link to employee if business_email matches
  SELECT id INTO v_emp_id
  FROM   public.employees
  WHERE  lower(business_email) = lower(NEW.email)
    AND  status = 'Active'
  LIMIT  1;

  IF v_emp_id IS NOT NULL THEN
    -- Link profile → employee
    UPDATE public.profiles
    SET    employee_id = v_emp_id,
           updated_at  = now()
    WHERE  id = NEW.id AND employee_id IS NULL;

    -- Stamp invite_accepted_at on employees if an invite was sent
    UPDATE public.employees
    SET    invite_accepted_at = now(),
           updated_at         = now()
    WHERE  id = v_emp_id
      AND  invite_sent_at IS NOT NULL
      AND  invite_accepted_at IS NULL;

    -- Mark the most recent employee_invites row as accepted
    UPDATE public.employee_invites
    SET    status     = 'accepted',
           updated_at = now()
    WHERE  id = (
      SELECT id FROM public.employee_invites
      WHERE  employee_id = v_emp_id
        AND  status = 'sent'
      ORDER  BY sent_at DESC
      LIMIT  1
    );

    -- Grant ESS automatically
    SELECT id INTO v_ess_role FROM public.roles WHERE code = 'ess' LIMIT 1;
    IF v_ess_role IS NOT NULL THEN
      INSERT INTO public.user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
      VALUES (NEW.id, v_ess_role, 'auto', now(), now())
      ON CONFLICT (profile_id, role_id) DO NOTHING;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_new_user() IS
  'Fires on auth.users INSERT. Creates a bare profile, auto-links to employee '
  'record if business_email matches, stamps invite_accepted_at, marks invite row '
  'as accepted, and grants ESS automatically.';


-- ── 4. ESS deactivation trigger ──────────────────────────────────────────────
--
-- When employees.status changes to 'Inactive' (or active becomes false),
-- revoke the ESS user_role for that employee's linked profile.

CREATE OR REPLACE FUNCTION revoke_ess_on_deactivation()
RETURNS TRIGGER AS $$
DECLARE
  v_profile_id uuid;
  v_ess_role   uuid;
BEGIN
  -- Only act if the employee is being deactivated
  IF (NEW.status = 'Inactive')
  AND (OLD.status IS DISTINCT FROM 'Inactive')
  THEN
    -- Find the linked profile
    SELECT id INTO v_profile_id
    FROM   public.profiles
    WHERE  employee_id = NEW.id
    LIMIT  1;

    IF v_profile_id IS NOT NULL THEN
      -- Find the ESS role
      SELECT id INTO v_ess_role FROM public.roles WHERE code = 'ess' LIMIT 1;

      IF v_ess_role IS NOT NULL THEN
        DELETE FROM public.user_roles
        WHERE  profile_id = v_profile_id
          AND  role_id    = v_ess_role;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trg_revoke_ess_on_deactivation ON employees;
CREATE TRIGGER trg_revoke_ess_on_deactivation
  AFTER UPDATE ON employees
  FOR EACH ROW
  EXECUTE FUNCTION revoke_ess_on_deactivation();

COMMENT ON FUNCTION revoke_ess_on_deactivation() IS
  'Fires AFTER UPDATE on employees. Revokes the ESS user_role for the linked '
  'profile whenever the employee is deactivated (status=Inactive or active=false).';


-- ── 5. reconcile_employee_profiles() RPC ─────────────────────────────────────
--
-- Back-fills existing auth users whose email matches an employees.business_email
-- but whose profiles.employee_id is still NULL.
-- Also grants ESS to newly linked profiles.
-- Returns a summary JSONB with counts.

CREATE OR REPLACE FUNCTION reconcile_employee_profiles()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_linked  int := 0;
  v_ess     int := 0;
  v_ess_role uuid;
  rec       RECORD;
BEGIN
  -- Permission check
  IF NOT (has_role('admin') OR has_permission('security.manage_roles')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient permissions');
  END IF;

  SELECT id INTO v_ess_role FROM roles WHERE code = 'ess' LIMIT 1;

  -- Find profiles that have no employee_id but whose auth email matches an active employee
  FOR rec IN
    SELECT
      p.id          AS profile_id,
      e.id          AS employee_id,
      u.email       AS email
    FROM   profiles       p
    JOIN   auth.users     u ON u.id = p.id
    JOIN   employees      e ON lower(e.business_email) = lower(u.email)
                            AND e.status = 'Active'
    WHERE  p.employee_id IS NULL
  LOOP
    -- Link the profile
    UPDATE profiles
    SET    employee_id = rec.employee_id,
           updated_at  = now()
    WHERE  id = rec.profile_id;

    v_linked := v_linked + 1;

    -- Grant ESS if not already present
    IF v_ess_role IS NOT NULL THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
      VALUES (rec.profile_id, v_ess_role, 'reconcile', now(), now())
      ON CONFLICT (profile_id, role_id) DO NOTHING;

      IF FOUND THEN
        v_ess := v_ess + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',            true,
    'linked',        v_linked,
    'ess_granted',   v_ess
  );
END;
$$;

COMMENT ON FUNCTION reconcile_employee_profiles() IS
  'Back-fills profiles.employee_id for existing auth users whose email matches '
  'an active employee record. Also grants ESS to newly linked profiles. '
  'Returns {ok, linked, ess_granted} JSONB.';


-- ── 6. RLS policies for employee_invites ─────────────────────────────────────

ALTER TABLE employee_invites ENABLE ROW LEVEL SECURITY;

-- Admins / HR managers can see all invite rows
DROP POLICY IF EXISTS emp_invites_admin_select ON employee_invites;
CREATE POLICY emp_invites_admin_select ON employee_invites
  FOR SELECT
  USING (has_role('admin') OR has_permission('hr.manage_employees'));

-- Admins / HR managers can insert invite rows
DROP POLICY IF EXISTS emp_invites_admin_insert ON employee_invites;
CREATE POLICY emp_invites_admin_insert ON employee_invites
  FOR INSERT
  WITH CHECK (has_role('admin') OR has_permission('hr.manage_employees'));

-- Admins / HR managers can update invite rows (status, reminder_sent_at, etc.)
DROP POLICY IF EXISTS emp_invites_admin_update ON employee_invites;
CREATE POLICY emp_invites_admin_update ON employee_invites
  FOR UPDATE
  USING (has_role('admin') OR has_permission('hr.manage_employees'));


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT column_name
FROM   information_schema.columns
WHERE  table_name = 'employees'
  AND  column_name IN ('invite_sent_at', 'invite_accepted_at');

SELECT table_name FROM information_schema.tables
WHERE  table_name = 'employee_invites';

SELECT proname FROM pg_proc
WHERE  proname IN ('handle_new_user', 'revoke_ess_on_deactivation', 'reconcile_employee_profiles');
