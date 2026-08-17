-- Migration : 20260817743_timesheet_entry_audit.sql
-- Purpose   : Make a deleted entry visible to the approver who has to re-approve
--             the month it disappeared from.
--
-- THE GAP THIS CLOSES
--   Migration 742 made send-back-and-resubmit the ONLY corrective loop for a
--   timesheet: an approver can approve or send back, never reject, never edit.
--   That makes the fidelity of the second look load-bearing.
--
--   time_approval_payload could report an entry ADDED or EDITED after the last
--   approval, because timesheet_entries carries created_at and updated_at. It
--   could not report one DELETED, because a deleted row leaves nothing behind.
--   The screen said so honestly -- deletions_visible: false -- but honest is not
--   the same as safe. An employee sent back to fix two missing days could
--   instead delete four entries, resubmit, and the approver would see a smaller
--   number with no indication that anything had been taken away. Every other
--   change announces itself; only the destructive one was silent.
--
-- WHAT THIS DOES
--   1. timesheet_entry_audit -- append-only, one row per destructive change,
--      carrying the image of the row BEFORE it changed.
--   2. A trigger that writes it. AFTER, not BEFORE, and it can never block the
--      operation it observes: an audit trail that breaks deletes is worse than
--      no audit trail.
--   3. time_approval_payload returns the removals since the last approval, and
--      stamps each surviving entry with what it used to say.
--
-- WHY UPDATES ARE LOGGED TOO
--   The same trigger, one extra branch. It turns "EDITED" -- which only says
--   that something moved -- into "was 3:00, now 5:00", which is the fact an
--   approver actually needs. Volume is not a concern: a month is tens of rows
--   per employee, and only material changes are recorded (a touch that leaves
--   every meaningful column identical writes nothing).
--
-- WHAT IT CANNOT DO
--   Nothing recovers a row deleted before this migration deploys. Sheets already
--   in flight start their audit from today.
--
-- Depends on : 704 (timesheet tables), 726 (activities column), 742 (approval)

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the table
-- ═══════════════════════════════════════════════════════════════════════════
-- Columnised for what the approval screen reads, plus old_row for everything
-- else. Denormalising project_id/time_type_id rather than joining through to a
-- row that no longer exists is the whole point.
--
-- No foreign keys except header_id. An audit row must never be refusable
-- because something it references has since gone; header_id is there for the
-- cascade -- when a month is deleted outright its audit goes with it, because
-- there is no longer a month to approve.

CREATE TABLE IF NOT EXISTS timesheet_entry_audit (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  header_id      uuid        NOT NULL REFERENCES timesheet_headers(id) ON DELETE CASCADE,
  entry_id       uuid        NOT NULL,
  action         text        NOT NULL CHECK (action IN ('deleted', 'updated')),

  -- the values as they stood BEFORE this change
  entry_date     date        NOT NULL,
  entry_kind     text        NOT NULL,
  hours_minutes  integer     NOT NULL,
  project_id     uuid,
  time_type_id   uuid,
  activities     text[],
  notes          text,
  old_row        jsonb       NOT NULL,

  actor_id       uuid,
  created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE timesheet_entry_audit IS
  'Mig 743: append-only prior images of timesheet entries that were deleted or '
  'materially changed. Exists so an approver re-approving a month can see what '
  'was taken away, which the entries table alone cannot show. Never updated, '
  'never deleted except by the header cascade.';

COMMENT ON COLUMN timesheet_entry_audit.entry_id IS
  'The entry this describes. Deliberately not a foreign key -- for action = '
  'deleted the row it names no longer exists.';
COMMENT ON COLUMN timesheet_entry_audit.hours_minutes IS
  'Minutes as they were BEFORE the change, not after.';
COMMENT ON COLUMN timesheet_entry_audit.old_row IS
  'Whole prior row as jsonb, so a column added to timesheet_entries later is '
  'still recoverable from history written before it existed.';

CREATE INDEX IF NOT EXISTS idx_ts_entry_audit_header
  ON timesheet_entry_audit (header_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ts_entry_audit_entry
  ON timesheet_entry_audit (entry_id, created_at);

-- Nothing reads this table directly. time_approval_payload (SECURITY DEFINER)
-- is the only door, and it applies the same gate as the rest of the month --
-- one predicate in one place, as PART 7 of mig 742 argued. RLS on with no
-- permissive policy makes that structural rather than a convention.
ALTER TABLE timesheet_entry_audit ENABLE ROW LEVEL SECURITY;

COMMENT ON INDEX idx_ts_entry_audit_header IS
  'Mig 743: the only access pattern -- everything that happened to one month, newest first.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the trigger
-- ═══════════════════════════════════════════════════════════════════════════
-- SECURITY DEFINER so the INSERT is not itself subject to the RLS this
-- migration just enabled; without it every delete would fail, which is the
-- textbook way an audit trail takes down the feature it was meant to protect.
--
-- The exception handler is not defensive padding. If writing history ever
-- fails -- a disk full, a constraint added later, anything -- the correct
-- outcome is that the employee's edit still succeeds and the failure is logged,
-- not that the timesheet becomes unusable.

CREATE OR REPLACE FUNCTION public.time_audit_timesheet_entry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_action text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    -- The month itself is being deleted and the cascade is taking its entries
    -- with it. There is nothing left to approve, the audit rows would cascade
    -- away in the same statement, and the foreign key to a header that no
    -- longer exists would reject the write anyway. Skip deliberately rather
    -- than leave the exception handler below to swallow a predictable failure
    -- and log two warnings for every legitimate header delete.
    IF NOT EXISTS (SELECT 1 FROM timesheet_headers WHERE id = OLD.header_id) THEN
      RETURN NULL;
    END IF;
    v_action := 'deleted';
  ELSE
    -- Only material change. updated_at moving on its own says nothing an
    -- approver could act on, and logging it would bury the changes that matter.
    IF NEW.hours_minutes IS NOT DISTINCT FROM OLD.hours_minutes
       AND NEW.entry_date   IS NOT DISTINCT FROM OLD.entry_date
       AND NEW.entry_kind   IS NOT DISTINCT FROM OLD.entry_kind
       AND NEW.project_id   IS NOT DISTINCT FROM OLD.project_id
       AND NEW.time_type_id IS NOT DISTINCT FROM OLD.time_type_id
       AND NEW.activities   IS NOT DISTINCT FROM OLD.activities
       AND NEW.notes        IS NOT DISTINCT FROM OLD.notes
    THEN
      RETURN NULL;
    END IF;
    v_action := 'updated';
  END IF;

  BEGIN
    INSERT INTO timesheet_entry_audit (
      header_id, entry_id, action, entry_date, entry_kind, hours_minutes,
      project_id, time_type_id, activities, notes, old_row, actor_id
    ) VALUES (
      OLD.header_id, OLD.id, v_action, OLD.entry_date, OLD.entry_kind, OLD.hours_minutes,
      OLD.project_id, OLD.time_type_id, OLD.activities, OLD.notes, to_jsonb(OLD), auth.uid()
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'time_audit_timesheet_entry: could not record % of entry % -- %',
                  v_action, OLD.id, SQLERRM;
  END;

  RETURN NULL;   -- AFTER trigger; return value is ignored
END $fn$;

COMMENT ON FUNCTION public.time_audit_timesheet_entry() IS
  'Mig 743: writes the prior image of a deleted or materially changed timesheet '
  'entry. SECURITY DEFINER so RLS on the audit table cannot break the edit. '
  'Never raises -- a failed audit write warns and lets the operation stand.';

DROP TRIGGER IF EXISTS trg_timesheet_entry_audit ON public.timesheet_entries;
CREATE TRIGGER trg_timesheet_entry_audit
  AFTER UPDATE OR DELETE ON public.timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION public.time_audit_timesheet_entry();


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — the payload tells the truth now
-- ═══════════════════════════════════════════════════════════════════════════
-- Two additions and one correction:
--
--   removed[]              entries deleted since the last approval, with what
--                          they said and who removed them.
--   previous_hours_minutes on a surviving entry, the value the approver last
--                          signed off -- the EARLIEST audit row in this cycle,
--                          not the latest. An entry that went 3h -> 4h -> 5h
--                          should read "was 3:00": what changed since approval,
--                          not since the last keystroke.
--   deletions_visible      now true.
--
-- Replaced in full rather than patched: mig 742 wrote this function four hours
-- ago and its whole body is here, so a second layer of string replacement would
-- be harder to read than the thing it edits.

CREATE OR REPLACE FUNCTION public.time_approval_payload(p_header_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_hdr       record;
  v_may       boolean;
  v_last_appr timestamptz;
  v_result    jsonb;
BEGIN
  SELECT * INTO v_hdr FROM timesheet_headers WHERE id = p_header_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND');
  END IF;

  v_may := time_is_timesheet_approver(p_header_id)
        OR user_can('timesheet', 'view', v_hdr.employee_id);

  IF NOT v_may THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT max(wal.created_at) INTO v_last_appr
  FROM   workflow_action_log wal
  JOIN   workflow_instances  wi ON wi.id = wal.instance_id
  WHERE  wi.module_code = 'timesheet'
    AND  wi.record_id   = p_header_id
    AND  wal.action     = 'approved';

  v_last_appr := COALESCE(v_last_appr, v_hdr.approved_at);

  SELECT jsonb_build_object(
    'ok', true,

    'header', jsonb_build_object(
      'id',                   v_hdr.id,
      'employee_id',          v_hdr.employee_id,
      'period',               v_hdr.period,
      'external_code',        v_hdr.external_code,
      'status',               v_hdr.status,
      'planned_minutes',      v_hdr.planned_minutes,
      'recorded_minutes',     v_hdr.recorded_minutes,
      'submitted_at',         v_hdr.submitted_at,
      'approved_at',          v_hdr.approved_at,
      'workflow_instance_id', v_hdr.workflow_instance_id,
      'department_name',      v_hdr.department_name,
      'country_code',         v_hdr.country_code,
      'last_approved_at',     v_last_appr
    ),

    'employee', (
      SELECT jsonb_build_object(
               'id',            e.id,
               'name',          e.name,
               'employee_code', e.employee_id,
               'job_title',     e.job_title,
               'manager_name',  (SELECT m.name FROM employees m WHERE m.id = e.manager_id))
      FROM employees e WHERE e.id = v_hdr.employee_id
    ),

    'holiday_calendar', (
      SELECT jsonb_build_object('id', hc.id, 'name', hc.name)
      FROM time_holiday_calendars hc WHERE hc.id = v_hdr.holiday_calendar_id
    ),

    'schedule', (
      SELECT jsonb_build_object(
               'id', ws.id, 'name', ws.name, 'code', ws.code,
               'max_daily_minutes', ws.max_daily_minutes,
               'start_day_of_week', ws.start_day_of_week,
               'lines', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'day_number', l.day_number,
                          'planned_minutes', l.planned_minutes)
                        ORDER BY l.day_number)
                 FROM time_work_schedule_lines l
                 WHERE l.work_schedule_id = ws.id), '[]'::jsonb))
      FROM time_work_schedules ws WHERE ws.id = v_hdr.work_schedule_id
    ),

    'holidays', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'date', ce.entry_date,
               'name', COALESCE(th.holiday_name, 'Public holiday'))
             ORDER BY ce.entry_date)
      FROM      time_calendar_entries ce
      LEFT JOIN time_holidays th ON th.id = ce.holiday_id
      WHERE ce.calendar_id = v_hdr.holiday_calendar_id
        AND ce.entry_date >= v_hdr.period
        AND ce.entry_date <  (v_hdr.period + INTERVAL '1 month')::date
    ), '[]'::jsonb),

    'entries', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id',            te.id,
               'entry_date',    te.entry_date,
               'entry_kind',    te.entry_kind,
               'hours_minutes', te.hours_minutes,
               'notes',         te.notes,
               'activities',    COALESCE(te.activities, ARRAY[]::text[]),
               'project_id',    te.project_id,
               'project_name',  pj.name,
               'time_type_id',  te.time_type_id,
               'time_type_name', tt.name,
               'is_system_generated', te.is_system_generated,
               'created_at',    te.created_at,
               'updated_at',    te.updated_at,
               'changed_after_approval',
                 CASE WHEN v_last_appr IS NULL THEN NULL
                      WHEN te.created_at > v_last_appr THEN 'ADDED'
                      WHEN te.updated_at > v_last_appr THEN 'EDITED'
                      ELSE NULL END,
               -- MIG 743: what this entry said when it was last approved.
               'previous_hours_minutes',
                 CASE WHEN v_last_appr IS NULL THEN NULL ELSE (
                   SELECT a.hours_minutes
                   FROM   timesheet_entry_audit a
                   WHERE  a.entry_id   = te.id
                     AND  a.action     = 'updated'
                     AND  a.created_at > v_last_appr
                   ORDER  BY a.created_at ASC
                   LIMIT  1) END)
             ORDER BY te.entry_date, pj.name NULLS LAST, tt.name NULLS LAST)
      FROM      timesheet_entries te
      LEFT JOIN projects   pj ON pj.id = te.project_id
      LEFT JOIN time_types tt ON tt.id = te.time_type_id
      WHERE     te.header_id = p_header_id
    ), '[]'::jsonb),

    -- MIG 743: what is no longer here. Only since the last approval — an entry
    -- created and deleted between approvals was never signed off and is noise.
    'removed', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id',            a.id,
               'entry_id',      a.entry_id,
               'entry_date',    a.entry_date,
               'entry_kind',    a.entry_kind,
               'hours_minutes', a.hours_minutes,
               'notes',         a.notes,
               'activities',    COALESCE(a.activities, ARRAY[]::text[]),
               'project_name',  pj.name,
               'time_type_name', tt.name,
               'removed_at',    a.created_at,
               'removed_by',    (SELECT e.name FROM profiles p
                                 LEFT JOIN employees e ON e.id = p.employee_id
                                 WHERE p.id = a.actor_id))
             ORDER BY a.entry_date, a.created_at)
      FROM      timesheet_entry_audit a
      LEFT JOIN projects   pj ON pj.id = a.project_id
      LEFT JOIN time_types tt ON tt.id = a.time_type_id
      WHERE     a.header_id = p_header_id
        AND     a.action    = 'deleted'
        AND     v_last_appr IS NOT NULL
        AND     a.created_at > v_last_appr
    ), '[]'::jsonb),

    'deletions_visible', true
  ) INTO v_result;

  RETURN v_result;
END $fn$;

REVOKE ALL ON FUNCTION public.time_approval_payload(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_approval_payload(uuid) TO authenticated;

COMMENT ON FUNCTION public.time_approval_payload(uuid) IS
  'Mig 743: everything the timesheet approval screens render, in one read, gated '
  'once — now including entries removed since the last approval and what each '
  'surviving entry used to say. Open to a workflow approver on the sheet (739) '
  'or to anyone with timesheet.view over the employee.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — assertions
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_src text;
BEGIN
  PERFORM 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'timesheet_entry_audit';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIG 743 ASSERT: timesheet_entry_audit was not created.';
  END IF;

  PERFORM 1 FROM pg_trigger
   WHERE tgname = 'trg_timesheet_entry_audit'
     AND tgrelid = 'public.timesheet_entries'::regclass
     AND NOT tgisinternal;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIG 743 ASSERT: the audit trigger is not attached to timesheet_entries.';
  END IF;

  -- The trigger must be able to write past its own RLS, or every delete breaks.
  PERFORM 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'time_audit_timesheet_entry' AND p.prosecdef;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIG 743 ASSERT: the audit trigger function is not SECURITY DEFINER.';
  END IF;

  PERFORM 1 FROM pg_tables
   WHERE schemaname = 'public' AND tablename = 'timesheet_entry_audit' AND rowsecurity;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIG 743 ASSERT: RLS is not enabled on timesheet_entry_audit.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'time_approval_payload';
  IF position('''deletions_visible'', true' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 743 ASSERT: time_approval_payload still reports deletions as invisible.';
  END IF;
  IF position('previous_hours_minutes' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 743 ASSERT: time_approval_payload does not carry prior values.';
  END IF;

  RAISE NOTICE 'MIG 743: all assertions passed.';
END $mig$;

COMMIT;
