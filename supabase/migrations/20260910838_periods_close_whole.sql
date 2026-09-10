-- =============================================================================
-- Migration 838 — a period is closed as a whole, and called by its own name
--
-- WHAT WENT WRONG
-- ═══════════════
--   Immediately after 837 deployed, a delete on Dev was refused with:
--
--       July 2026 is closed for editing.
--       The earliest month you can still change is July 2026.
--
--   Both halves name the same month. The message is not merely confusing — it
--   is reporting a rule that has stopped making sense, and it took two separate
--   faults to produce it.
--
-- FAULT 1 — the guard compares a DAY against a PERIOD boundary
-- ────────────────────────────────────────────────────────────
--   enforce_timesheet_edit_window() (730) tests `entry_date < floor`. While
--   every floor was the 1st of a month that was equivalent to "this entry is in
--   a closed month", because no entry could fall between the 1st and the floor.
--   837 moved the floor to the 26th, and the equivalence broke:
--
--       floor          = 2026-07-26
--       entry 15 Jul   -> refused
--       entry 28 Jul   -> allowed
--
--   ...both in the SAME timesheet. Half a sheet closed and half open is not a
--   rule anybody wrote; it is an artefact. Worse, the client asks a DIFFERENT
--   question — `win.start < editFloor`, the period's anchor against the floor —
--   so the screen greys out a whole period the database would still accept
--   writes into. Two definitions of "closed", disagreeing.
--
--   The fix is to compare the ENTRY'S PERIOD against the floor. Not computed —
--   the header already knows it, in the column the entry hangs off. At start
--   day 1 the result is identical for every date, which is why nothing about a
--   calendar-month database changes; and it now matches the client exactly,
--   because both are asking the same question of the same two anchors.
--
-- FAULT 2 — the message names two different things "July 2026"
-- ────────────────────────────────────────────────────────────
--   `to_char(v_date, 'FMMonth YYYY')` on one side and `to_char(v_floor, ...)`
--   on the other. Once a period is not a calendar month, a month name no longer
--   identifies a period, and a floor that lands mid-month is not a month at all.
--   Both are now named by DATE, and the period also carries the name it is
--   filed under, so the sentence cannot contradict itself.
--
-- AND THE SAME MISTAKE IN THE NOTIFICATION
-- ════════════════════════════════════════
--   submit_timesheet() builds the metadata every timesheet notification renders
--   from, and it labelled the period with its ANCHOR:
--
--       'period',       to_char(v_hdr.period, 'YYYY-MM')      -> 2026-07
--       'period_label', to_char(v_hdr.period, 'FMMonth YYYY') -> July 2026
--
--   ...for the period that is CALLED August. Every approval request, approval
--   and send-back email would have named the wrong month, as would the row in
--   the Approver Inbox. Both now go through timesheet_period_label(), which is
--   the one definition of what a period is called.
--
-- WHY 837 MISSED ALL THREE
-- ════════════════════════
--   837's sweep looked for the STRING `date_trunc('month', X)`. These three
--   sites encode the same assumption without containing that string: one
--   compares a raw date to a floor that used to always be a month start, and
--   two format a period as a month name. A textual search finds textual copies;
--   it does not find the concept. The same class of miss — searching for the
--   expression rather than the idea — is what put a retired function in 837's
--   patch list and failed its first deploy.
--
-- SAFETY
--   * Both patches read the LIVE definition and assert their anchor counts.
--   * Idempotent: each skips itself once applied.
--   * Verified against a real PostgreSQL 16, including that the new rule agrees
--     with the old one on every date of a calendar-month cycle.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._mig838_patch(
  p_fn text, p_a text, p_b text, p_expect integer)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE v_src text; v_new text; v_hits integer; v_n integer;
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'MIG 838: %() not found.', p_fn;
  END IF;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'MIG 838: %() is overloaded % ways; this patcher edits one definition and would pick arbitrarily.', p_fn, v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  IF position(p_a IN v_src) = 0 AND position(p_b IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 838: %() already patched, skipping.', p_fn;
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, p_a, ''))) / length(p_a);
  IF v_hits <> p_expect THEN
    RAISE EXCEPTION 'MIG 838: in %(), the anchor matched % times, expected %. Read the live definition before editing this file. Anchor: %',
      p_fn, v_hits, p_expect, left(p_a, 90);
  END IF;

  v_new := replace(v_src, p_a, p_b);
  EXECUTE v_new;
  RAISE NOTICE 'MIG 838: patched %() — % occurrence(s).', p_fn, v_hits;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — a period is open or closed as a whole
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  -- The header's own period, alongside the owner it already reads. Not derived
  -- from the entry date: the entry hangs off this header, so this IS its period
  -- by definition, and deriving it again would be a second opinion that could
  -- disagree with the row it is attached to.
  -- The anchor runs INTO the BEGIN deliberately. `  v_floor date;` on its own
  -- survives inside its own replacement, so the "already applied" test could
  -- never fire and a second run would declare v_period twice. Anchoring across
  -- the boundary makes the anchor genuinely disappear once patched.
  PERFORM public._mig838_patch('enforce_timesheet_edit_window',
'  v_floor date;
BEGIN',
'  v_floor date;
  -- Mig 838. The period this entry belongs to, read from its own header.
  v_period date;
BEGIN',
    1);

  PERFORM public._mig838_patch('enforce_timesheet_edit_window',
'  SELECT h.employee_id INTO v_owner
  FROM timesheet_headers h WHERE h.id = v_hdr;',
'  SELECT h.employee_id, h.period INTO v_owner, v_period
  FROM timesheet_headers h WHERE h.id = v_hdr;',
    1);

  PERFORM public._mig838_patch('enforce_timesheet_edit_window',
'  IF v_date < v_floor THEN
    RAISE EXCEPTION
      ''% is closed for editing. The earliest month you can still change is %.'',
      to_char(v_date, ''FMMonth YYYY''), to_char(v_floor, ''FMMonth YYYY'')
      USING ERRCODE = ''check_violation'';
  END IF;',
'  -- Mig 838. THE PERIOD, not the day. `v_date < v_floor` was equivalent while
  -- every floor was the 1st of a month; with a floor on the 26th it closed the
  -- first three weeks of a timesheet and left the last one open. It also asked
  -- a different question from the screen, which compares the period''s anchor —
  -- so a sheet could read closed and still accept writes.
  IF v_period < v_floor THEN
    RAISE EXCEPTION
      ''The % timesheet (% to %) is closed for editing. The earliest period you can still change starts %.'',
      to_char(timesheet_period_label(v_period), ''FMMonth YYYY''),
      to_char(v_period, ''FMDD Mon YYYY''),
      to_char(timesheet_period_end(v_period), ''FMDD Mon YYYY''),
      to_char(v_floor, ''FMDD Mon YYYY'')
      USING ERRCODE = ''check_violation'';
  END IF;',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the notification names the period the employee filed
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  PERFORM public._mig838_patch('submit_timesheet',
'                               ''period'',           to_char(v_hdr.period, ''YYYY-MM''),
                               ''period_label'',     to_char(v_hdr.period, ''FMMonth YYYY''),',
'                               -- Mig 838. The LABEL, not the anchor. On a
                               -- 26-to-25 cycle the anchor 2026-07-26 renders
                               -- as "July 2026" for the period everyone calls
                               -- August, and this metadata is what every
                               -- approval, approved and sent-back notification
                               -- renders {{period_label}} from.
                               ''period'',           to_char(timesheet_period_label(v_hdr.period), ''YYYY-MM''),
                               ''period_label'',     to_char(timesheet_period_label(v_hdr.period), ''FMMonth YYYY''),',
    1);
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig838_patch(text, text, text, integer);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'enforce_timesheet_edit_window';

  IF position('v_period < v_floor' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 838 FAILED: the edit window still closes individual days rather than whole periods.';
  END IF;
  IF position('h.employee_id, h.period INTO v_owner, v_period' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 838 FAILED: the guard never reads the header''s period, so v_period is always NULL and NOTHING would ever be refused.';
  END IF;
  IF position('The earliest month you can still change' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 838 FAILED: the message still calls a mid-month floor a month.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'submit_timesheet';

  IF position('to_char(v_hdr.period, ''FMMonth YYYY'')' IN v_src) > 0
  OR position('to_char(v_hdr.period, ''YYYY-MM'')' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 838 FAILED: a notification still labels the period by its anchor, so it would name the wrong month.';
  END IF;
  IF position('timesheet_period_label(v_hdr.period)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 838 FAILED: submit_timesheet does not use the period label.';
  END IF;

  -- The rule must be unchanged for a calendar-month cycle. If this ever fails,
  -- an entire database of month timesheets has quietly changed what "closed"
  -- means.
  IF EXISTS (
    SELECT 1
    FROM generate_series(DATE '2025-01-01', DATE '2027-12-31', INTERVAL '1 day') d,
         generate_series(DATE '2025-01-01', DATE '2027-12-01', INTERVAL '1 month') f
    WHERE (d::date < f::date)                              -- the old rule, at start day 1
      IS DISTINCT FROM
          (timesheet_period_of(d::date, 1::smallint) < f::date))  -- the new one
  THEN
    RAISE EXCEPTION 'MIG 838 FAILED: on a calendar-month cycle the new rule disagrees with the old one. Existing timesheets would change what closed means.';
  END IF;

  RAISE NOTICE 'MIG 838 OK: periods close whole, and are named by the month they end in.';
END;
$v$;

COMMIT;
