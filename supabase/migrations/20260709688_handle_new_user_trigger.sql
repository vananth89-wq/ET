-- ─────────────────────────────────────────────────────────────────────────────
-- Bootstrap the handle_new_user trigger on auth.users
--
-- WHY
-- ═══
-- Dev is missing the trigger that fires when a new auth.users row is created.
-- Result: invites succeed at Supabase Auth level (auth.users row created,
-- email sent) but no profile row gets auto-created, so link_profile_to_employee
-- fails with "profile row not yet created" for every invited user.
--
-- The function itself lives in the public schema (came over via schema copy),
-- but the TRIGGER on auth.users was skipped because our pg_dump used -n public
-- and auth.users triggers live outside the public schema.
--
-- This migration is idempotent: CREATE OR REPLACE on the function,
-- DROP TRIGGER IF EXISTS + CREATE TRIGGER for the binding.
--
-- Copied verbatim from UAT (project okpnubnswpgybpzgwgtr) on 2026-07-22.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Function (recreated defensively even if it already exists) ────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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
    AND  deleted_at IS NULL
  LIMIT  1;

  IF v_emp_id IS NOT NULL THEN
    UPDATE public.profiles
    SET    employee_id = v_emp_id,
           updated_at  = now()
    WHERE  id = NEW.id AND employee_id IS NULL;

    -- Stamp invite_accepted_at if an invite was sent
    UPDATE public.employees
    SET    invite_accepted_at = now(),
           updated_at         = now()
    WHERE  id = v_emp_id
      AND  invite_sent_at IS NOT NULL
      AND  invite_accepted_at IS NULL;

    -- Mark latest invite row as accepted
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
$$;

-- ── 2. Trigger binding on auth.users ─────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_on_auth_user_created ON auth.users;

CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- ── 3. Verification ──────────────────────────────────────────────────────────
DO $$
DECLARE v_trigger_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_on_auth_user_created'
      AND tgrelid = 'auth.users'::regclass
  ) INTO v_trigger_exists;

  IF v_trigger_exists THEN
    RAISE NOTICE 'handle_new_user trigger installed on auth.users';
  ELSE
    RAISE EXCEPTION 'Trigger installation failed';
  END IF;
END $$;
