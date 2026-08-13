-- Migration : 20260812737_paste_day_respects_allows_future.sql
-- Purpose   : Let Copy Day paste into a future day when every entry on the
--             source day is a type that may be dated forward.
--
-- WHY THIS CHANGES
--   735 blanket-refused a future target, and said so in its own comment:
--
--     Copy Day stays strictly retrospective whatever a time type's
--     advance-dating flag says: it carries whichever types the source day held
--     and cannot know that every one of them allows it.
--
--   The second half of that sentence is simply untrue -- the function has the
--   source day right there and can ask. I wrote the narrow rule because I had
--   read a superseded draft of 729 that gated allows_future to absence types,
--   which made "a day of attendance can never go forward" look like a tautology
--   rather than a choice. It is a choice, and with Training and On-Site Visit
--   both carrying the flag it is the wrong one: you can add Training for next
--   Tuesday through the day panel, but not copy a day containing it forward.
--
-- THE RULE
--   A future target is allowed only when EVERY attendance entry on the source
--   day belongs to a type with allows_future. One that does not blocks the whole
--   paste, and the refusal names it -- a partial copy would silently drop work
--   the employee asked to carry over, which is worse than refusing.
--
--   Leave and holidays are already excluded from the copy, so they cannot block
--   it. System rows likewise.
--
-- Depends on : 729 (the flag), 735 (the function), 736 (the same rule in the
--              day panel)

BEGIN;

DO $$
DECLARE
  v_src   text;
  v_new   text;
  v_decl  text := '  v_bad     text;';
  v_blk   text := '  IF p_to_date > CURRENT_DATE THEN'                                     || E'\n' ||
                  '    RETURN jsonb_build_object(''ok'', false, ''error'', ''FUTURE_DATE'','          || E'\n' ||
                  '      ''message'', ''Attendance cannot be pasted into a future day.'');' || E'\n' ||
                  '  END IF;';
  v_hits  integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 737: paste_timesheet_day not found. Apply 735 first.';
  END IF;

  IF position('allows_future' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 737: paste_timesheet_day already honours allows_future. Nothing to do.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_decl, ''))) / length(v_decl);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 737: expected exactly 1 v_bad declaration, found %.', v_hits;
  END IF;
  v_new := replace(v_src, v_decl, v_decl || E'\n' || '  v_noadv   text;');

  v_hits := (length(v_new) - length(replace(v_new, v_blk, ''))) / length(v_blk);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 737: expected exactly 1 blanket future block in paste_timesheet_day, '
                    'found %. Resolve by hand rather than guessing.', v_hits;
  END IF;

  v_new := replace(v_new, v_blk,
    '  -- A future target is allowed when EVERY type on the source day may be'      || E'\n' ||
    '  -- dated forward. 735 refused outright on the grounds that the function'     || E'\n' ||
    '  -- "cannot know that every one of them allows it" -- which was wrong: the'   || E'\n' ||
    '  -- source day is right here. All-or-nothing on purpose; a partial copy'      || E'\n' ||
    '  -- would drop work the employee asked to carry over without saying so.'      || E'\n' ||
    '  IF p_to_date > CURRENT_DATE THEN'                                            || E'\n' ||
    '    SELECT string_agg(DISTINCT tt.name, '', '') INTO v_noadv'                  || E'\n' ||
    '    FROM   timesheet_entries e'                                                || E'\n' ||
    '    JOIN   time_types tt ON tt.id = e.time_type_id'                            || E'\n' ||
    '    WHERE  e.header_id  = p_header_id'                                         || E'\n' ||
    '      AND  e.entry_date = p_from_date'                                         || E'\n' ||
    '      AND  e.entry_kind NOT IN (''leave'', ''holiday'')'                       || E'\n' ||
    '      AND  NOT COALESCE(e.is_system_generated, false)'                         || E'\n' ||
    '      AND  NOT COALESCE(tt.allows_future, false);'                             || E'\n' ||
    ''                                                                              || E'\n' ||
    '    IF v_noadv IS NOT NULL THEN'                                               || E'\n' ||
    '      RETURN jsonb_build_object(''ok'', false, ''error'', ''FUTURE_DATE'','    || E'\n' ||
    '        ''message'', format(''%s cannot be recorded in advance, so %s cannot be copied to a future day.'','  || E'\n' ||
    '                            v_noadv, to_char(p_from_date, ''FMDD FMMonth'')));'|| E'\n' ||
    '    END IF;'                                                                   || E'\n' ||
    '  END IF;');

  EXECUTE v_new;
  RAISE NOTICE 'MIG 737: paste_timesheet_day now allows a future paste when every source type permits it.';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification — the same list-everything shape as 736 PART 3
-- ═══════════════════════════════════════════════════════════════════════════
-- ADD TO THIS LIST when a migration adds a rule to paste_timesheet_day.

DO $$
DECLARE
  v_src     text;
  v_missing text[] := '{}';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF position('allows_future' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 737: future paste gated per time type'; END IF;
  IF position('FROM   timesheet_entry_activities a' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 735: activity rows copied from the database'; END IF;
  IF position('TARGET_NOT_EMPTY' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 735: paste only into an empty day'; END IF;
  IF position('LEGACY_NEEDS_SPLIT' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 735: multi-name legacy source refused'; END IF;
  IF position('NOTHING_TO_COPY' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 735: empty source refused'; END IF;
  IF position('v_header.status = ''to_be_approved''' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 730: pending approval refused, approved allowed'; END IF;
  IF position('v_header.status <> ''to_be_submitted''' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: the pre-730 status guard is back'; END IF;
  IF position('''message'', SQLERRM' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: SQLERRM returned as the user-facing message'; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 737 ABORT: paste_timesheet_day is missing rules it should carry:\n  - %',
      array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 737 verified: paste_timesheet_day carries all seven checked rules.';
END $$;

COMMIT;
