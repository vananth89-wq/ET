-- Migration : 20260817745_approval_payload_activity_minutes.sql
-- Purpose   : Give time_approval_payload() the two facts an approver-side copy
--             of the employee's PDF report cannot be built without.
--
--             1. ACTIVITY MINUTES. The payload has always returned
--                timesheet_entries.activities -- the legacy text[] from mig 726,
--                which is names and nothing else. The split lives in
--                timesheet_entry_activities (mig 727: activity_name,
--                hours_minutes, display_order), which this function never read.
--                So the approval screen could name an entry's activities but
--                never say how its hours divided between them, and a report
--                built from this payload would print every activity at zero.
--
--             2. content_changed_at. The header stamp is what catches a
--                DELETION: no row survives to be marked changed_after_approval,
--                so a payload showing no marks is not a payload showing no
--                changes. The report prints that distinction; the payload could
--                not supply it.
--
-- Compatible : ADDITIVE ONLY. `activities` keeps its exact current shape and
--              meaning -- a text[] of names. The split arrives beside it as a
--              new `activity_rows` key. Changing `activities` in place would
--              have been cleaner to read and would have broken every
--              already-loaded browser tab the moment this deployed, because the
--              detail tab maps it as strings. A key nobody reads yet cannot
--              break anyone.
--
-- Depends on : 726 (activities text[]), 727 (timesheet_entry_activities),
--              731 (content_changed_at), 742 (time_approval_payload), 743
--              (removed[] and the audit table). 744 is the report registry and
--              does not touch this function.
--
-- Method     : IN-PLACE patch via pg_get_functiondef, with asserted hit counts.
--              Deliberately NOT a CREATE OR REPLACE pasted from a copy of 743 --
--              that is exactly how the in-place patches in 730 and 732-743 get
--              silently reverted by the next migration that thinks it holds the
--              whole function.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  -- Anchors. Each is asserted to appear EXACTLY once before anything is
  -- replaced; a zero-hit or two-hit anchor aborts the whole migration rather
  -- than half-applying it.
  a_hdr CONSTANT text := '      ''last_approved_at'',     v_last_appr';
  a_ent CONSTANT text := '               ''activities'',    COALESCE(te.activities, ARRAY[]::text[]),';
  a_rem CONSTANT text := '               ''activities'',    COALESCE(a.activities, ARRAY[]::text[]),';

  n_hdr CONSTANT text :=
    '      -- MIG 745: the stamp that catches a DELETION.' || chr(10) ||
    '      ''content_changed_at'',   v_hdr.content_changed_at,' || chr(10) ||
    '      ''last_approved_at'',     v_last_appr';

  n_ent CONSTANT text :=
    '               ''activities'',    COALESCE(te.activities, ARRAY[]::text[]),' || chr(10) ||
    '               -- MIG 745: the same activities, WITH their minutes. An entry' || chr(10) ||
    '               -- written before mig 727 has names in the legacy text[] and' || chr(10) ||
    '               -- no split; it falls back to minutes 0 rather than inventing' || chr(10) ||
    '               -- a measurement nobody took -- the same rule the employee''''s' || chr(10) ||
    '               -- PDF already applies to those rows.' || chr(10) ||
    '               ''activity_rows'', COALESCE(' || chr(10) ||
    '                 (SELECT jsonb_agg(jsonb_build_object(' || chr(10) ||
    '                           ''name'',    tea.activity_name,' || chr(10) ||
    '                           ''minutes'', tea.hours_minutes)' || chr(10) ||
    '                         ORDER BY tea.display_order, tea.activity_name)' || chr(10) ||
    '                  FROM   timesheet_entry_activities tea' || chr(10) ||
    '                  WHERE  tea.entry_id = te.id),' || chr(10) ||
    '                 (SELECT COALESCE(jsonb_agg(jsonb_build_object(' || chr(10) ||
    '                           ''name'', x, ''minutes'', 0)), ''[]''::jsonb)' || chr(10) ||
    '                  FROM   unnest(COALESCE(te.activities, ARRAY[]::text[])) AS x)),';

  n_rem CONSTANT text :=
    '               ''activities'',    COALESCE(a.activities, ARRAY[]::text[]),' || chr(10) ||
    '               -- MIG 745: same shape as a live entry so the client needs' || chr(10) ||
    '               -- one type, but the minutes are ALWAYS 0 and that is not a' || chr(10) ||
    '               -- bug: an entry''''s activity rows cascade-delete with it, and' || chr(10) ||
    '               -- the audit row captured only the legacy text[] names. What' || chr(10) ||
    '               -- the split was at the moment of deletion is recorded' || chr(10) ||
    '               -- nowhere.' || chr(10) ||
    '               ''activity_rows'', (SELECT COALESCE(jsonb_agg(jsonb_build_object(' || chr(10) ||
    '                                     ''name'', x, ''minutes'', 0)), ''[]''::jsonb)' || chr(10) ||
    '                                  FROM unnest(COALESCE(a.activities, ARRAY[]::text[])) AS x),';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'time_approval_payload'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_header_id uuid';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 745: public.time_approval_payload(uuid) not found';
  END IF;

  -- Idempotent: re-running a deployed migration must not fail the pipeline.
  IF position('activity_rows' IN v_src) > 0 THEN
    RAISE NOTICE 'mig 745: activity_rows already present, nothing to do';
    RETURN;
  END IF;

  v_new := v_src;

  v_hits := (length(v_new) - length(replace(v_new, a_hdr, ''))) / length(a_hdr);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 745: header anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_hdr, n_hdr);

  v_hits := (length(v_new) - length(replace(v_new, a_ent, ''))) / length(a_ent);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 745: entries anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_ent, n_ent);

  v_hits := (length(v_new) - length(replace(v_new, a_rem, ''))) / length(a_rem);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 745: removed anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_rem, n_rem);

  EXECUTE v_new;
  RAISE NOTICE 'mig 745: time_approval_payload patched';
END
$mig$;

-- ── Assertions ───────────────────────────────────────────────────────────────
-- This is a string replacement on a function the migration does not own. If any
-- part of it silently no-oped, the approval screen would keep working and the
-- report would quietly print zeros -- the worst available failure mode: wrong
-- numbers on a document somebody signs.
DO $chk$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'time_approval_payload'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_header_id uuid';

  IF position('timesheet_entry_activities tea' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 745 assert: entries never gained the activity-row subquery';
  END IF;
  IF position('v_hdr.content_changed_at' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 745 assert: header never gained content_changed_at';
  END IF;
  -- Twice: once under entries, once under removed.
  IF (length(v_src) - length(replace(v_src, 'activity_rows', '')))
     / length('activity_rows') <> 2 THEN
    RAISE EXCEPTION 'mig 745 assert: expected activity_rows exactly twice';
  END IF;
  -- The legacy key MUST survive. Anything reading it today keeps working, and
  -- that is the whole basis for calling this migration additive.
  IF position('COALESCE(te.activities, ARRAY[]::text[])' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 745 assert: the legacy activities key was lost';
  END IF;

  RAISE NOTICE 'mig 745: assertions passed';
END
$chk$;
