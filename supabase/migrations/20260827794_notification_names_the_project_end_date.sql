-- =============================================================================
-- Migration 794: the notification says when the PROJECT ends — and stops
--                pretending its columns line up
--
-- THE FIELD
-- ═════════
-- The detail block carried the assignment's own start and end dates but never
-- said what they sit inside. "End date: 30 Sep 2026" reads very differently
-- depending on whether the project runs to December or stops in October, and
-- the recipient had no way to tell which from the message.
--
-- It matters more since mig 792, where an assignment may not outlive its
-- project: the project's end date is the CEILING on the one above it, so
-- quoting the ceiling is what makes the number above it mean something.
--
-- THE ALIGNMENT THAT NEVER WORKED
-- ───────────────────────────────
-- Mig 793 padded every label to a fixed width so the values would form a
-- column. In the email they never did, and could not:
--
--   supabase/functions/send-notification-email escapes the body, converts \n to
--   <br>, and drops it inside a <p> in -apple-system / Segoe UI / Roboto —
--   a PROPORTIONAL font. HTML then collapses every run of spaces to one. The
--   padding was invisible in the mail and merely odd in the bell.
--
-- So the padding goes. One space after each label, which is what actually
-- renders, in both places. Real column alignment needs the edge function to
-- render structured detail as a table rather than escaped text — a change to
-- that function, not to this one, and worth doing on its own.
--
--     Project: AMPTJ
--     Project ends: 31 Dec 2026     ← new
--     Employee: Meera R (100107)
--     Role: EC Consultant
--     Start date: 01 Feb 2026
--     End date: 30 Sep 2026
--     Percentage: 50%
--
-- CHANGES
-- ───────
--   notify_project_member_change()  -- one more field, and honest spacing
-- =============================================================================

SET jit = 'off';

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a_dec text := E'  v_project     text;\n';
  r_dec text := E'  v_project     text;\n  v_pend        date;\n';

  a_sel text := E'  SELECT p.name, p.manager_id INTO v_project, v_lead_emp\n'
             || E'  FROM   projects p WHERE p.id = v_m.project_id;';
  r_sel text := E'  SELECT p.name, p.manager_id, p.end_date INTO v_project, v_lead_emp, v_pend\n'
             || E'  FROM   projects p WHERE p.id = v_m.project_id;';

  a_det text :=
       E'  v_detail :=\n'
    || E'       format(E''Project:     %s\\n'', COALESCE(v_project, ''—''))\n'
    || E'    || format(E''Employee:    %s (%s)\\n'', COALESCE(v_pers_name, ''—''), COALESCE(v_pers_code, ''—''))\n'
    || E'    || format(E''Role:        %s\\n'', COALESCE(v_role, ''Not set''))\n'
    || E'    || format(E''Start date:  %s\\n'', to_char(v_m.effective_from, ''DD Mon YYYY''))\n'
    || E'    || format(E''End date:    %s\\n'', COALESCE(to_char(v_m.effective_to, ''DD Mon YYYY''), ''Open-ended''))\n'
    || E'    || format(E''Percentage:  %s\\n'',';

  r_det text :=
       E'  -- One space after each label. The email renders this in a proportional\n'
    || E'  -- font with runs of spaces collapsed, so padded columns are invisible\n'
    || E'  -- there and merely odd in the bell. See the mig 794 header.\n'
    || E'  v_detail :=\n'
    || E'       format(E''Project: %s\\n'', COALESCE(v_project, ''—''))\n'
    || E'    || format(E''Project ends: %s\\n'', COALESCE(to_char(v_pend, ''DD Mon YYYY''), ''—''))\n'
    || E'    || format(E''Employee: %s (%s)\\n'', COALESCE(v_pers_name, ''—''), COALESCE(v_pers_code, ''—''))\n'
    || E'    || format(E''Role: %s\\n'', COALESCE(v_role, ''Not set''))\n'
    || E'    || format(E''Start date: %s\\n'', to_char(v_m.effective_from, ''DD Mon YYYY''))\n'
    || E'    || format(E''End date: %s\\n'', COALESCE(to_char(v_m.effective_to, ''DD Mon YYYY''), ''Open-ended''))\n'
    || E'    || format(E''Percentage: %s\\n'',';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'notify_project_member_change';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 794: notify_project_member_change not found';
  END IF;

  IF position('Project ends:' in v_src) > 0 THEN
    RAISE NOTICE 'mig 794: the notification already names the project end date -- skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_dec, ''))) / NULLIF(length(a_dec), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 794: DECLARE anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a_dec, r_dec);

  v_hits := (length(v_new) - length(replace(v_new, a_sel, ''))) / NULLIF(length(a_sel), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 794: project SELECT anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_sel, r_sel);

  v_hits := (length(v_new) - length(replace(v_new, a_det, ''))) / NULLIF(length(a_det), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 794: detail-block anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_det, r_det);

  EXECUTE v_new;
END $mig$;

COMMENT ON FUNCTION public.notify_project_member_change(uuid, text) IS
  'Mig 793/794: announces added / updated / ended / removed on a project '
  'assignment, carrying project, project end date, employee, role, both '
  'assignment dates and percentage, one field per line. Writes to '
  'notifications, which already carries the email leg. ''removed'' must be '
  'called BEFORE the row is deleted.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'notify_project_member_change';

  IF position('Project ends:' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 794: the project end date did not make it into the message';
  END IF;

  -- No padded labels: they render as one space anyway, and leaving them in
  -- would keep implying a column that never appears.
  IF position(E'Percentage:  %s' in v_src) > 0
     OR position(E'Employee:    %s' in v_src) > 0 THEN
    RAISE EXCEPTION 'mig 794: padded labels survived -- the email collapses them';
  END IF;

  RAISE NOTICE 'mig 794: OK -- the message says when the project ends';
END $mig$;
