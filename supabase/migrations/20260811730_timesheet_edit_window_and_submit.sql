-- Migration : 20260811730_timesheet_edit_window_and_submit.sql
-- Purpose   : Make submission mean something, and make the edit window real.
--
-- Five things, in order of how much they change:
--
--   1. SUBMIT STOPS LYING. handleSubmit() was a bare column UPDATE: status went
--      to 'to_be_approved' and nothing else happened anywhere. No workflow
--      instance, no approver, no notification, no screen. The sheet entered a
--      state it could never leave, and because the UI gated editing on
--      status = 'to_be_submitted', the employee was locked out of their own
--      month. submit_timesheet() now asks resolve_workflow_for_submission()
--      whether a workflow is actually assigned to timesheet_headers. NULL --
--      which is the case today, no template is seeded -- means there is nobody
--      to approve it, so it goes straight to 'approved'. That is honest: an
--      unapproved-forever sheet is worse than an auto-approved one.
--
--   2. THE EDIT WINDOW BECOMES MONTHS, NOT DAYS. A timesheet IS a month, so a
--      30-day rolling boundary cut sheets in half: 1-10 July locked, 11-31 July
--      open, same document, two rules. N whole calendar months back. N = 0 is
--      the current month only.
--
--   3. THE EDIT WINDOW IS ENFORCED. It was read by one admin screen and by
--      nothing else -- a setting with no effect. Rule (i) below is the first
--      time it binds.
--
--   4. STATUS STOPS GATING EDITING. With (1) an approved sheet is the normal
--      resting state, so 'approved' cannot mean read-only or nobody could ever
--      fix anything. The edit window is what closes a month now. Re-submitting
--      an approved sheet is allowed and, with no workflow, simply re-approves.
--
--   5. AND THE WRITE RPCs HAVE TO AGREE. Seven of them carry the identical
--      four-line guard `IF v_header.status <> 'to_be_submitted' THEN return
--      NOT_EDITABLE`. Without PART 5, (4) is a lie the UI tells: every button
--      would be enabled and every save refused. See PART 5 for why they are
--      patched from the catalogue rather than retyped.
--
-- WHY RULE (i) IS ITS OWN TRIGGER
--   enforce_timesheet_entry_rules() is ~200 lines carrying rules (a)-(h).
--   Reproducing it whole to append one rule is how a rule gets silently
--   dropped. A second trigger on the same table is a separate concern, both
--   must pass, and neither can damage the other.
--
-- NOT IN THIS MIGRATION, deliberately
--   * Creating the workflow instance on the WF path. Held until the approver
--     screens are built and what exists has been tested -- the branch is here
--     and returns the template id, but it does not yet start anything.
--   * Manager and HR window enforcement. Both values are stored and editable;
--     no screen lets a manager or HR edit someone else's timesheet, so three
--     role branches in a trigger would ship with no caller to exercise them.
--
-- Depends on : 702 (time_edit_config), 705 (timesheet_entries), 729 (rules a-h),
--              20260428044 (resolve_workflow_for_submission)

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — time_edit_config: days become whole calendar months
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.time_edit_config
  ADD COLUMN IF NOT EXISTS employee_edit_window_months integer,
  ADD COLUMN IF NOT EXISTS manager_edit_window_months  integer,
  ADD COLUMN IF NOT EXISTS hr_edit_window_months       integer;

-- Backfill from whatever days were configured. 30 days reaches back into last
-- month, so it becomes 1. NULL stays NULL: unlimited is unlimited either way.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'time_edit_config'
      AND column_name = 'employee_edit_window_days'
  ) THEN
    UPDATE public.time_edit_config
    SET employee_edit_window_months =
          COALESCE(employee_edit_window_months, GREATEST(0, CEIL(employee_edit_window_days / 30.0)::int)),
        manager_edit_window_months =
          COALESCE(manager_edit_window_months,
                   CASE WHEN manager_edit_window_days IS NULL THEN NULL
                        ELSE GREATEST(0, CEIL(manager_edit_window_days / 30.0)::int) END),
        hr_edit_window_months =
          COALESCE(hr_edit_window_months,
                   CASE WHEN hr_edit_window_days IS NULL THEN NULL
                        ELSE GREATEST(0, CEIL(hr_edit_window_days / 30.0)::int) END)
    WHERE id IS NOT NULL;   -- pg_safeupdate: never a bare UPDATE, even here
  END IF;
END $$;

-- A fresh install has no row at all; the trigger below treats "no config" as
-- "no restriction", so this is only about giving the admin screen something.
INSERT INTO public.time_edit_config (employee_edit_window_months)
SELECT 1
WHERE NOT EXISTS (SELECT 1 FROM public.time_edit_config);

UPDATE public.time_edit_config
SET employee_edit_window_months = 1
WHERE employee_edit_window_months IS NULL;

ALTER TABLE public.time_edit_config
  ALTER COLUMN employee_edit_window_months SET NOT NULL,
  ALTER COLUMN employee_edit_window_months SET DEFAULT 1;

-- 0 is meaningful and must be allowed: "the current month only".
ALTER TABLE public.time_edit_config
  DROP CONSTRAINT IF EXISTS time_edit_config_employee_months_chk,
  DROP CONSTRAINT IF EXISTS time_edit_config_manager_months_chk,
  DROP CONSTRAINT IF EXISTS time_edit_config_hr_months_chk;

ALTER TABLE public.time_edit_config
  ADD CONSTRAINT time_edit_config_employee_months_chk CHECK (employee_edit_window_months >= 0),
  ADD CONSTRAINT time_edit_config_manager_months_chk  CHECK (manager_edit_window_months IS NULL OR manager_edit_window_months >= 0),
  ADD CONSTRAINT time_edit_config_hr_months_chk       CHECK (hr_edit_window_months IS NULL OR hr_edit_window_months >= 0);

ALTER TABLE public.time_edit_config
  DROP COLUMN IF EXISTS employee_edit_window_days,
  DROP COLUMN IF EXISTS manager_edit_window_days,
  DROP COLUMN IF EXISTS hr_edit_window_days;

COMMENT ON COLUMN public.time_edit_config.employee_edit_window_months IS
  'Whole calendar months back an employee may still change. 0 = the current month only.';
COMMENT ON COLUMN public.time_edit_config.manager_edit_window_months IS
  'Stored and editable; NOT yet enforced -- no screen lets a manager edit another timesheet. NULL = unlimited.';
COMMENT ON COLUMN public.time_edit_config.hr_edit_window_months IS
  'Stored and editable; NOT yet enforced -- see manager column. NULL = unlimited.';

-- Parameter NAMES change, so CREATE OR REPLACE is not enough.
DROP FUNCTION IF EXISTS public.save_time_edit_config(integer, integer, integer);

CREATE OR REPLACE FUNCTION public.save_time_edit_config(
  p_employee_months integer,
  p_manager_months  integer DEFAULT NULL,
  p_hr_months       integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT user_can('time_edit_config', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
                              'message', 'You do not have permission to change the edit window.');
  END IF;

  IF p_employee_months IS NULL OR p_employee_months < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID',
                              'message', 'The employee window must be 0 or more months.');
  END IF;

  SELECT id INTO v_id FROM time_edit_config LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO time_edit_config (employee_edit_window_months, manager_edit_window_months,
                                  hr_edit_window_months, updated_by, updated_at)
    VALUES (p_employee_months, p_manager_months, p_hr_months, auth.uid(), now());
  ELSE
    UPDATE time_edit_config
    SET employee_edit_window_months = p_employee_months,
        manager_edit_window_months  = p_manager_months,
        hr_edit_window_months       = p_hr_months,
        updated_by = auth.uid(),
        updated_at = now()
    WHERE id = v_id;
  END IF;

  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE ALL ON FUNCTION public.save_time_edit_config(integer, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_time_edit_config(integer, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.save_time_edit_config IS
  'Mig 730: single-row edit window config, now in whole calendar months.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — Rule (i): the edit window actually binds
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.time_employee_edit_floor()
RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- The first day of the earliest month an employee may still change. NULL when
  -- there is no config row at all, which the caller reads as "no restriction".
  SELECT (date_trunc('month', CURRENT_DATE)
          - (COALESCE(employee_edit_window_months, 0) || ' months')::interval)::date
  FROM time_edit_config
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.time_employee_edit_floor() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_employee_edit_floor() TO authenticated;

COMMENT ON FUNCTION public.time_employee_edit_floor IS
  'Mig 730: earliest editable month for an employee, as a date. Client and trigger share it so they cannot disagree.';


CREATE OR REPLACE FUNCTION public.enforce_timesheet_edit_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_date  date;
  v_hdr   uuid;
  v_sys   boolean;
  v_owner uuid;
  v_floor date;
BEGIN
  -- Plain IF, not a CASE expression. `v_row := CASE TG_OP WHEN 'DELETE' THEN
  -- OLD ELSE NEW END` parses happily and then fails at runtime -- plpgsql will
  -- not resolve a record through a CASE. Pull the three fields instead.
  IF TG_OP = 'DELETE' THEN
    v_date := OLD.entry_date; v_hdr := OLD.header_id; v_sys := OLD.is_system_generated;
  ELSE
    v_date := NEW.entry_date; v_hdr := NEW.header_id; v_sys := NEW.is_system_generated;
  END IF;

  -- The holiday sync and the leave module write history freely; they are exempt
  -- at the top of enforce_timesheet_entry_rules() for the same reason.
  IF v_sys THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  SELECT h.employee_id INTO v_owner
  FROM timesheet_headers h WHERE h.id = v_hdr;

  -- Only the OWNER is held to the employee window. A manager or HR acting on
  -- someone else's sheet has their own setting in time_edit_config, but nothing
  -- in the app calls those paths yet -- enforcing them here would be three
  -- branches no test could reach. Wire them when the screens exist.
  IF v_owner IS DISTINCT FROM get_my_employee_id() THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  v_floor := time_employee_edit_floor();
  IF v_floor IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  IF v_date < v_floor THEN
    RAISE EXCEPTION
      '% is closed for editing. The earliest month you can still change is %.',
      to_char(v_date, 'FMMonth YYYY'), to_char(v_floor, 'FMMonth YYYY')
      USING ERRCODE = 'check_violation';
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;

-- INSERT, UPDATE **and DELETE**. Rules (e)-(h) are INSERT-only so that rows
-- written before a rule existed stay editable; this one is the opposite by
-- design -- closing a month has to stop changes to what is already there, and
-- a closed month you can still delete from is not closed.
DROP TRIGGER IF EXISTS trg_timesheet_entry_edit_window ON public.timesheet_entries;
REVOKE ALL ON FUNCTION public.enforce_timesheet_edit_window() FROM PUBLIC;

CREATE TRIGGER trg_timesheet_entry_edit_window
  BEFORE INSERT OR UPDATE OR DELETE ON public.timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION public.enforce_timesheet_edit_window();

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — submit / withdraw
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.submit_timesheet(p_header_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_hdr   record;
  v_tpl   uuid;
  v_count integer;
BEGIN
  SELECT * INTO v_hdr FROM timesheet_headers WHERE id = p_header_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
                              'message', 'That timesheet no longer exists.');
  END IF;

  IF v_hdr.employee_id IS DISTINCT FROM get_my_employee_id() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_YOURS',
                              'message', 'You can only submit your own timesheet.');
  END IF;

  -- Already waiting on someone: withdraw first, otherwise a second submit would
  -- silently restart an approval that may be half-done.
  IF v_hdr.status = 'to_be_approved' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_PENDING',
                              'message', 'This timesheet is already waiting for approval. Withdraw it first if you need to change it.');
  END IF;

  SELECT count(*) INTO v_count FROM timesheet_entries WHERE header_id = p_header_id;
  IF v_count = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'EMPTY',
                              'message', 'There is nothing recorded on this timesheet yet.');
  END IF;

  -- Is anybody actually going to look at this? NULL means no workflow is
  -- assigned to timesheet_headers, so there is no approver, no queue and no
  -- screen -- and parking the sheet in 'Pending Approval' would be a promise
  -- the system cannot keep.
  v_tpl := resolve_workflow_for_submission('timesheet_headers', auth.uid());

  IF v_tpl IS NULL THEN
    UPDATE timesheet_headers
    SET status = 'approved', submitted_at = now(), approved_at = now()
    WHERE id = p_header_id;

    RETURN jsonb_build_object('ok', true, 'status', 'approved', 'workflow', false,
                              'message', 'Timesheet submitted and approved -- no approval workflow is configured.');
  END IF;

  -- WF path. The instance is NOT started here yet: the approver screens are on
  -- hold until what exists has been tested, and a queue nobody can see is the
  -- exact problem this migration is fixing. The template id is returned so the
  -- caller can be wired to wf_submit in one place when that lands.
  UPDATE timesheet_headers
  SET status = 'to_be_approved', submitted_at = now(), approved_at = NULL
  WHERE id = p_header_id;

  RETURN jsonb_build_object('ok', true, 'status', 'to_be_approved', 'workflow', true,
                            'template_id', v_tpl,
                            'message', 'Timesheet submitted for approval.');
END $$;

REVOKE ALL ON FUNCTION public.submit_timesheet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_timesheet(uuid) TO authenticated;

COMMENT ON FUNCTION public.submit_timesheet IS
  'Mig 730: submit. Auto-approves when no workflow is assigned to timesheet_headers, because nothing else can.';


CREATE OR REPLACE FUNCTION public.withdraw_timesheet(p_header_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_hdr record;
BEGIN
  SELECT * INTO v_hdr FROM timesheet_headers WHERE id = p_header_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
                              'message', 'That timesheet no longer exists.');
  END IF;

  IF v_hdr.employee_id IS DISTINCT FROM get_my_employee_id() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_YOURS',
                              'message', 'You can only withdraw your own timesheet.');
  END IF;

  IF v_hdr.status <> 'to_be_approved' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_PENDING',
                              'message', 'Only a timesheet waiting for approval can be withdrawn.');
  END IF;

  UPDATE timesheet_headers
  SET status = 'to_be_submitted', submitted_at = NULL
  WHERE id = p_header_id;

  RETURN jsonb_build_object('ok', true, 'status', 'to_be_submitted',
                            'message', 'Withdrawn. You can change the timesheet and submit it again.');
END $$;

REVOKE ALL ON FUNCTION public.withdraw_timesheet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.withdraw_timesheet(uuid) TO authenticated;

COMMENT ON FUNCTION public.withdraw_timesheet IS
  'Mig 730: pull a pending timesheet back to editable. Owner only.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — release the sheets already stranded
-- ═══════════════════════════════════════════════════════════════════════════
-- Anything sitting in 'to_be_approved' today was put there by the old bare
-- UPDATE. There is no workflow assigned to timesheet_headers, so nothing is
-- waiting on it and nothing can ever move it. Approve them, dated from when
-- they were submitted rather than from now, so the record stays true.

DO $$
DECLARE v_n integer;
BEGIN
  IF EXISTS (SELECT 1 FROM workflow_assignments
             WHERE module_code = 'timesheet_headers' AND is_active) THEN
    RAISE NOTICE 'MIG 730: a timesheet workflow IS assigned -- leaving pending sheets alone.';
    RETURN;
  END IF;

  UPDATE timesheet_headers
  SET status = 'approved', approved_at = COALESCE(submitted_at, now())
  WHERE status = 'to_be_approved';
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RAISE NOTICE 'MIG 730: released % stranded timesheet(s) to approved.', v_n;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — the write RPCs stop treating 'approved' as read-only
-- ═══════════════════════════════════════════════════════════════════════════
-- save_timesheet_entry, bulk_create_timesheet_entries, delete_timesheet_entries
-- and their siblings each carry the SAME four lines:
--
--   IF v_header.status <> 'to_be_submitted' THEN
--     RETURN jsonb_build_object('ok', false, 'error', 'NOT_EDITABLE',
--       'message', 'This timesheet is no longer editable.');
--   END IF;
--
-- With PART 3, 'approved' is where a submitted month RESTS -- so that guard now
-- locks every month the moment it is filed, which is the exact bug this
-- migration exists to remove. What should block a write is somebody actively
-- being asked to approve it; the calendar boundary is rule (i)'s job and it
-- runs on every INSERT, UPDATE and DELETE regardless of which RPC called.
--
-- WHY THIS IS A CATALOGUE PATCH AND NOT SEVEN CREATE OR REPLACEs
--   Those functions are 60-250 lines each and live across five earlier
--   migrations. Pasting seven whole bodies in here to change one line apiece is
--   the same failure mode as folding rule (i) into enforce_timesheet_entry_rules
--   -- one stale copy and a rule silently disappears, and the diff would be
--   ~700 lines in which the four that matter are invisible. pg_get_functiondef
--   returns the LIVE definition as re-executable SQL, so replacing one exact
--   substring in it changes precisely that substring and nothing else, whatever
--   each body happens to contain today. CREATE OR REPLACE keeps the oid, so
--   grants, comments and dependencies survive.
--
--   It is guarded: an unexpected match count aborts the migration rather than
--   half-applying, and the pattern is specific enough that only these RPCs can
--   match -- `v_header` is their own local variable name.

DO $mig$
DECLARE
  r      record;
  v_new  text;
  v_n    integer := 0;
  v_hits integer;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_functiondef(p.oid) AS src
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.prokind = 'f'
      AND  pg_get_functiondef(p.oid) LIKE '%v_header.status <> ''to_be_submitted''%'
    ORDER  BY p.proname
  LOOP
    -- Exactly one guard per function is expected. Two would mean a body shape
    -- nobody here has seen, and guessing at it is how this goes wrong quietly.
    v_hits := (length(r.src) - length(replace(r.src, 'v_header.status <> ''to_be_submitted''', '')))
              / length('v_header.status <> ''to_be_submitted''');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 730: % has % status guards, expected exactly 1. Aborting.', r.proname, v_hits;
    END IF;

    v_new := replace(r.src,
      'v_header.status <> ''to_be_submitted''',
      'v_header.status = ''to_be_approved''');

    v_new := replace(v_new,
      'This timesheet is no longer editable.',
      'This timesheet is waiting for approval. Withdraw it first if you need to change it.');

    EXECUTE v_new;
    v_n := v_n + 1;
    RAISE NOTICE 'MIG 730: relaxed the status gate in %', r.proname;
  END LOOP;

  -- Zero matches has two very different causes and only one of them is fine.
  --   * Already applied -- the replay harness runs every migration twice, and
  --     on the second pass the guards are all in their new form. Nothing to do.
  --   * The guard was reworded upstream since this migration was written, so
  --     PARTS 3-4 have just made every approved month permanently read-only and
  --     nothing here noticed. That must not reach an environment.
  -- Telling them apart means asking whether the NEW condition is present.
  IF v_n = 0 THEN
    SELECT count(*) INTO v_hits
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.prokind = 'f'
      AND  pg_get_functiondef(p.oid) LIKE '%v_header.status = ''to_be_approved''%';

    IF v_hits > 0 THEN
      RAISE NOTICE 'MIG 730: write RPCs already relaxed (% found) -- nothing to do.', v_hits;
    ELSE
      RAISE EXCEPTION 'MIG 730: no timesheet write RPC carries either the old or the new '
                      'status guard. PARTS 3-4 would leave approved months uneditable. Aborting.';
    END IF;
  ELSE
    RAISE NOTICE 'MIG 730: % write RPC(s) now allow editing an approved month; only pending blocks.', v_n;
  END IF;
END $mig$;

-- Belt and braces: nothing may still be gated on the old condition.
DO $$
DECLARE v_left integer;
BEGIN
  SELECT count(*) INTO v_left
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.prokind = 'f'
    AND  pg_get_functiondef(p.oid) LIKE '%v_header.status <> ''to_be_submitted''%';
  IF v_left > 0 THEN
    RAISE EXCEPTION 'MIG 730: % function(s) still carry the old status guard.', v_left;
  END IF;
END $$;


COMMIT;
