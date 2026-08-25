-- =============================================================================
-- Migration 786: planned end dates, and a dropdown that knows which month
--                you are filling in
--
-- TWO THINGS, AND ONE OF THEM IS A BUG FIX
-- ════════════════════════════════════════
--
-- A. END DATES YOU CAN SET
--    effective_to has existed since mig 773, but the only thing that ever
--    wrote it was project_member_remove(), which stamps CURRENT_DATE. So
--    "Meera comes off AMPTJ on 31 December" was unsayable -- you had to
--    remember to click Remove on the day. Mig 785 explicitly refused to set
--    effective_to, and that was right while ending was a one-button action.
--    With planned end dates it stops being right.
--
-- B. THE DROPDOWN ASKED THE WRONG DATE  ← the bug
--    my_timesheet_projects() resolved membership as of CURRENT_DATE:
--
--      Meera is on AMPTJ Jan-Mar. In June she opens her MARCH timesheet to fix
--      an entry. The dropdown asks "is she on AMPTJ today" -- no. She keeps the
--      project only because the `booked` arm remembers what she has already
--      logged. Had she been a member in March without booking yet, the project
--      would be missing from the exact period she needs it for, with nothing on
--      screen to explain why.
--
--    Membership must be resolved AS OF THE PERIOD BEING RECORDED. A stint
--    counts when it overlaps the period at all.
--
-- THE SYMMETRY WORTH NOTICING
-- ───────────────────────────
-- Design doc §3.3a argues the REPORTS must not resolve membership by period --
-- they key off the project the hour was booked to, so a total can never drift.
-- This migration argues the DROPDOWN must. That is not a contradiction; the two
-- ask different questions:
--
--   report    "is this hour booked to a project I manage?"   no dates, stable
--   dropdown  "was this person on the project that week?"    period-relative
--
-- The report is about an hour that already exists. The dropdown is about a week
-- somebody is still filling in.
--
-- DEPLOY-ORDER SAFETY
-- ───────────────────
-- The DB and the frontend ship on separate workflows, so for a window the old
-- bundle may call the old signature. my_timesheet_projects(uuid) is therefore
-- KEPT, as a thin wrapper resolving "today" -- exactly its pre-786 behaviour.
-- Dropping it would mean an empty dropdown for anyone on the old bundle, and
-- project is a mandatory field: that is not a cosmetic window, it is people
-- unable to record their time.
--
-- CHANGES
-- ───────
--   1. project_member_update()   -- gains p_effective_to + p_clear_effective_to.
--                                   One UPDATE now, against a range validated
--                                   as a whole.
--   2. my_timesheet_projects(uuid, date, date)  -- NEW, period-aware.
--      my_timesheet_projects(uuid)              -- legacy wrapper, "today".
--
-- STILL NOT DONE, DELIBERATELY
-- ────────────────────────────
-- No enforcement. And note the `booked` arm is date-blind on purpose -- it is
-- what stops an old timesheet losing the project its entries are on. The cost
-- is that an ex-member can still be OFFERED a project they have left. Harmless
-- while nothing enforces membership; a prerequisite to fix before anything does.
-- =============================================================================

SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. project_member_update -- the whole date range, validated at once
-- ═══════════════════════════════════════════════════════════════════════════
-- DROP first: adding a defaulted parameter creates an OVERLOAD, and a call
-- passing three arguments would then be ambiguous between the two. One
-- signature only.

DROP FUNCTION IF EXISTS public.project_member_update(uuid, numeric, boolean, date);

CREATE OR REPLACE FUNCTION public.project_member_update(
  p_id                 uuid,
  p_allocation_pct     numeric DEFAULT NULL,
  p_clear_allocation   boolean DEFAULT false,
  p_effective_from     date    DEFAULT NULL,
  p_effective_to       date    DEFAULT NULL,
  p_clear_effective_to boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row   project_members%ROWTYPE;
  v_from  date;
  v_to    date;
  v_alloc numeric;
BEGIN
  SELECT * INTO v_row FROM project_members WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
      'message', 'That assignment no longer exists. Refresh the page.');
  END IF;

  IF NOT can_staff_project(v_row.project_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You can only change assignments on projects where you are the Reporting Manager.');
  END IF;

  -- Resolve the FINAL state first, then validate that, then write once. The
  -- previous version validated and wrote each field separately, which meant a
  -- start date could be checked against an end date that the same call was
  -- about to change.
  v_from := COALESCE(p_effective_from, v_row.effective_from);

  IF p_clear_effective_to THEN
    v_to := NULL;
  ELSE
    v_to := COALESCE(p_effective_to, v_row.effective_to);
  END IF;

  IF p_clear_allocation THEN
    v_alloc := NULL;
  ELSIF p_allocation_pct IS NOT NULL THEN
    -- The table CHECK is (allocation_pct > 0 AND <= 100). Reaching it would
    -- raise a constraint violation the user cannot read, so the sentence comes
    -- first and the constraint stays behind it as the real guarantee.
    IF p_allocation_pct <= 0 OR p_allocation_pct > 100 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'BAD_ALLOCATION',
        'message', 'Allocation must be between 1 and 100 percent.');
    END IF;
    v_alloc := p_allocation_pct;
  ELSE
    v_alloc := v_row.allocation_pct;
  END IF;

  IF v_to IS NOT NULL AND v_to < v_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'DATES_CROSSED',
      'message', 'The end date cannot be before the start date.');
  END IF;

  -- Same courtesy as project_member_add: catch the overlap and say it in words.
  -- The gist exclusion constraint is still what makes it true.
  IF EXISTS (
    SELECT 1 FROM project_members pm
    WHERE  pm.project_id  = v_row.project_id
      AND  pm.employee_id = v_row.employee_id
      AND  pm.id         <> v_row.id
      AND  daterange(pm.effective_from, COALESCE(pm.effective_to, 'infinity'::date), '[]')
           && daterange(v_from, COALESCE(v_to, 'infinity'::date), '[]')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'OVERLAPS',
      'message', 'Those dates would overlap another spell this person had on the project.');
  END IF;

  UPDATE project_members
  SET    allocation_pct = v_alloc,
         effective_from = v_from,
         effective_to   = v_to,
         updated_at     = now()
  WHERE  id = p_id;

  RETURN jsonb_build_object('ok', true, 'id', p_id,
    'effective_from', v_from, 'effective_to', v_to, 'allocation_pct', v_alloc);
END;
$fn$;

REVOKE ALL ON FUNCTION public.project_member_update(uuid, numeric, boolean, date, date, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.project_member_update(uuid, numeric, boolean, date, date, boolean) TO authenticated;

COMMENT ON FUNCTION public.project_member_update(uuid, numeric, boolean, date, date, boolean) IS
  'Mig 786: change allocation, start date or end date of an assignment. NULL '
  'means leave alone, so clearing either nullable field needs its own flag. '
  'The final range is validated as a whole, then written in one UPDATE. '
  'Cannot move a member between projects -- that is an end-and-re-add, which '
  'leaves an honest history. Gated on can_staff_project().';


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. my_timesheet_projects -- as of the period, not as of today
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.my_timesheet_projects(
  p_employee_id  uuid,
  p_period_start date,
  p_period_end   date
)
RETURNS TABLE (
  id          uuid,
  name        text,
  active      boolean,
  start_date  date,
  end_date    date,
  is_member   boolean,
  has_entries boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_me uuid;
BEGIN
  IF p_employee_id IS NULL OR p_period_start IS NULL OR p_period_end IS NULL THEN
    RETURN;
  END IF;

  v_me := get_my_employee_id();

  -- Your own sheet, or one you are entitled to see. SECURITY DEFINER means the
  -- gate has to be explicit -- there is no RLS behind this to catch a mistake.
  --
  -- IS NOT DISTINCT FROM, not `=`. For a login with no employee behind it v_me
  -- is NULL, `p_employee_id = v_me` is NULL, and NULL OR false is NULL, so
  -- `IF NOT (...)` is NULL -- which plpgsql treats as false and falls straight
  -- through the gate. (Caught by test T8 on mig 783.)
  IF NOT (is_super_admin()
          OR p_employee_id IS NOT DISTINCT FROM v_me
          OR COALESCE(user_can('timesheet', 'view', p_employee_id), false)
          OR COALESCE(user_can('timesheet', 'edit', p_employee_id), false)) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH mem AS (
    -- Overlaps the period at all. Somebody who joined mid-month was on the
    -- project that month, and their timesheet for it must offer it.
    SELECT pm.project_id
    FROM   project_members pm
    WHERE  pm.employee_id    = p_employee_id
      AND  pm.effective_from <= p_period_end
      AND  (pm.effective_to IS NULL OR pm.effective_to >= p_period_start)
  ),
  booked AS (
    -- Deliberately date-blind, and deliberately not limited to this period:
    -- an entry that exists must always be able to name its own project, or
    -- editing an old timesheet would silently lose it.
    SELECT DISTINCT e.project_id
    FROM   timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  h.employee_id  = p_employee_id
      AND  e.project_id   IS NOT NULL
  ),
  keep AS (
    SELECT project_id FROM mem
    UNION
    SELECT project_id FROM booked
  )
  SELECT p.id, p.name, p.active, p.start_date, p.end_date,
         EXISTS (SELECT 1 FROM mem    m WHERE m.project_id = p.id),
         EXISTS (SELECT 1 FROM booked b WHERE b.project_id = p.id)
  FROM   projects p
  WHERE  p.active = true
    AND  (
           p.id IN (SELECT project_id FROM keep)
           -- Nothing to narrow to: fall back to every active project, which is
           -- exactly the pre-783 dropdown. Narrowing must never be the reason
           -- somebody cannot record their time.
           OR NOT EXISTS (SELECT 1 FROM keep)
         )
  ORDER  BY p.name;
END;
$fn$;

REVOKE ALL ON FUNCTION public.my_timesheet_projects(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_timesheet_projects(uuid, date, date) TO authenticated;

COMMENT ON FUNCTION public.my_timesheet_projects(uuid, date, date) IS
  'Mig 786: the projects offered in this employee''s timesheet dropdown for the '
  'period being recorded -- memberships overlapping that period, plus anything '
  'they have already booked to, falling back to all active projects when both '
  'are empty so nobody is locked out. Offers only; the database still accepts '
  'any project id. Enforcement is a separate switch.';


-- The pre-786 signature, kept as a wrapper. The frontend ships on a different
-- workflow from the database, so for a window the old bundle is still calling
-- this. It resolves "today", which is precisely what it did before -- the bug
-- stays reachable for that window rather than the dropdown going empty, and an
-- empty dropdown is not cosmetic when project is a mandatory field.
CREATE OR REPLACE FUNCTION public.my_timesheet_projects(p_employee_id uuid)
RETURNS TABLE (
  id          uuid,
  name        text,
  active      boolean,
  start_date  date,
  end_date    date,
  is_member   boolean,
  has_entries boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT * FROM public.my_timesheet_projects(p_employee_id, CURRENT_DATE, CURRENT_DATE);
$fn$;

REVOKE ALL ON FUNCTION public.my_timesheet_projects(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_timesheet_projects(uuid) TO authenticated;

COMMENT ON FUNCTION public.my_timesheet_projects(uuid) IS
  'Legacy one-argument form, kept only so a frontend bundle deployed before '
  'mig 786 keeps working. Resolves membership as of today, which is the bug '
  'the three-argument form fixes. Do not call it from new code.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_update'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_id uuid, p_allocation_pct numeric, p_clear_allocation boolean, '
            'p_effective_from date, p_effective_to date, p_clear_effective_to boolean'
  ) THEN
    RAISE EXCEPTION 'mig 786: project_member_update missing or wrong signature';
  END IF;

  -- Exactly one, or a three-argument call becomes ambiguous.
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'project_member_update') <> 1 THEN
    RAISE EXCEPTION 'mig 786: more than one project_member_update overload survives';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'my_timesheet_projects'
      AND pg_get_function_identity_arguments(p.oid) = 'p_employee_id uuid, p_period_start date, p_period_end date'
  ) THEN
    RAISE EXCEPTION 'mig 786: period-aware my_timesheet_projects missing';
  END IF;

  -- The legacy arity must survive, or an old bundle empties its dropdown.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'my_timesheet_projects'
      AND pg_get_function_identity_arguments(p.oid) = 'p_employee_id uuid'
  ) THEN
    RAISE EXCEPTION 'mig 786: legacy my_timesheet_projects(uuid) was dropped';
  END IF;

  RAISE NOTICE 'mig 786: OK -- end dates settable, dropdown resolves by period';
END $mig$;
