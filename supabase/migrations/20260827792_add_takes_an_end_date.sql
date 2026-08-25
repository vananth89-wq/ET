-- =============================================================================
-- Migration 792: an assignment gets an end date at the moment it is created
--
-- WHY THIS EXISTS
-- ═══════════════
-- The new form makes End date mandatory and defaults it to the project's own
-- end date. project_member_add() has no way to accept one -- it writes
-- effective_to NULL and always has -- so the screen would show a date it could
-- not save, and every new assignment would silently be open-ended.
--
-- Fixing it in the API rather than the screen also means the default holds for
-- anything else that ever adds a member, and for an older bundle still calling
-- the four-argument form during a deploy.
--
-- THE RULE IT ADDS
-- ────────────────
--   an assignment may not outlive its project.
--
-- We logged "an allocation can run past the end of its project, and nothing
-- warns you" as a known gap. Defaulting the date closes it for the common case;
-- refusing a longer one closes it properly. Shortening stays free -- somebody
-- rolling off early is ordinary, and mig 788 already stops that stranding hours.
--
-- CHANGES
-- ───────
--   project_member_add()     -- + p_effective_to, defaulting to the project's
--                               end date, with ordering and outlives checks
--   project_member_update()  -- the same outlives check, so the rule cannot be
--                               walked around by adding and then editing
--
-- NOT CHANGED
-- ───────────
--   The permission verbs (791), the guards (788), the notification (789).
--   effective_to may still be cleared on update -- see the note there.
-- =============================================================================

SET jit = 'off';

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  -- pg_get_functiondef normalises the signature onto one line and spells
  -- defaults with their cast, so the anchors match that, not the source file.
  a_sig text := 'p_role_id uuid DEFAULT NULL::uuid)';
  r_sig text := 'p_role_id uuid DEFAULT NULL::uuid, p_effective_to date DEFAULT NULL::date)';

  a_dec text := E'DECLARE\n  v_id uuid;';
  r_dec text := E'DECLARE\n  v_id uuid;\n  v_to  date;\n  v_pend date;';

  a_ins text := 'INSERT INTO project_members (project_id, employee_id, effective_from, allocation_pct, role_id, added_by)';
  r_ins text := E'  -- Mig 792: an assignment ends when the project does, unless the lead\n'
             || E'  -- shortens it. NULL from an older client resolves the same way.\n'
             || E'  SELECT p.end_date INTO v_pend FROM projects p WHERE p.id = p_project_id;\n'
             || E'  v_to := COALESCE(p_effective_to, v_pend);\n'
             || E'\n'
             || E'  IF v_to IS NOT NULL AND v_to < p_effective_from THEN\n'
             || E'    RETURN jsonb_build_object(''ok'', false, ''error'', ''DATES_CROSSED'',\n'
             || E'      ''message'', ''The end date cannot be before the start date.'');\n'
             || E'  END IF;\n'
             || E'\n'
             || E'  IF v_pend IS NOT NULL AND v_to IS NOT NULL AND v_to > v_pend THEN\n'
             || E'    RETURN jsonb_build_object(''ok'', false, ''error'', ''OUTLIVES_PROJECT'',\n'
             || E'      ''message'', format(''The assignment cannot run past the project, which ends %s.'',\n'
             || E'                          to_char(v_pend, ''DD Mon YYYY'')));\n'
             || E'  END IF;\n'
             || E'\n'
             || E'  INSERT INTO project_members (project_id, employee_id, effective_from, effective_to, allocation_pct, role_id, added_by)';

  a_val text := 'VALUES (p_project_id, p_employee_id, p_effective_from, p_allocation_pct, p_role_id, get_my_employee_id())';
  r_val text := 'VALUES (p_project_id, p_employee_id, p_effective_from, v_to, p_allocation_pct, p_role_id, get_my_employee_id())';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_add';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 792: project_member_add not found';
  END IF;

  IF position('p_effective_to' in v_src) > 0 THEN
    RAISE NOTICE 'mig 792: project_member_add already takes an end date -- skipping';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_sig, ''))) / NULLIF(length(a_sig), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 792: add signature anchor matched % times, expected 1', v_hits;
    END IF;
    v_new := replace(v_src, a_sig, r_sig);

    v_hits := (length(v_new) - length(replace(v_new, a_dec, ''))) / NULLIF(length(a_dec), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 792: add DECLARE anchor matched % times, expected 1', v_hits;
    END IF;
    v_new := replace(v_new, a_dec, r_dec);

    v_hits := (length(v_new) - length(replace(v_new, a_ins, ''))) / NULLIF(length(a_ins), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 792: add INSERT anchor matched % times, expected 1', v_hits;
    END IF;
    v_new := replace(v_new, a_ins, r_ins);

    v_hits := (length(v_new) - length(replace(v_new, a_val, ''))) / NULLIF(length(a_val), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 792: add VALUES anchor matched % times, expected 1', v_hits;
    END IF;
    v_new := replace(v_new, a_val, r_val);

    DROP FUNCTION IF EXISTS public.project_member_add(uuid, uuid, date, numeric, uuid);
    EXECUTE v_new;
    EXECUTE 'REVOKE ALL ON FUNCTION public.project_member_add(uuid, uuid, date, numeric, uuid, date) FROM PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.project_member_add(uuid, uuid, date, numeric, uuid, date) TO authenticated';
  END IF;
END $mig$;


-- ── the same rule on the way through update ──────────────────────────────────
-- Otherwise it is one extra click to walk around: add inside the project, then
-- edit the end date past it.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a_chk text := E'  IF v_to IS NOT NULL AND v_to < v_from THEN';
  r_chk text := E'  -- Mig 792: an assignment may not outlive its project.\n'
             || E'  IF v_to IS NOT NULL THEN\n'
             || E'    DECLARE v_pend date;\n'
             || E'    BEGIN\n'
             || E'      SELECT p.end_date INTO v_pend FROM projects p WHERE p.id = v_row.project_id;\n'
             || E'      IF v_pend IS NOT NULL AND v_to > v_pend THEN\n'
             || E'        RETURN jsonb_build_object(''ok'', false, ''error'', ''OUTLIVES_PROJECT'',\n'
             || E'          ''message'', format(''The assignment cannot run past the project, which ends %s.'',\n'
             || E'                              to_char(v_pend, ''DD Mon YYYY'')));\n'
             || E'      END IF;\n'
             || E'    END;\n'
             || E'  END IF;\n'
             || E'\n'
             || E'  IF v_to IS NOT NULL AND v_to < v_from THEN';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_update';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 792: project_member_update not found';
  END IF;

  IF position('OUTLIVES_PROJECT' in v_src) > 0 THEN
    RAISE NOTICE 'mig 792: project_member_update already carries the rule -- skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_chk, ''))) / NULLIF(length(a_chk), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 792: update ordering-check anchor matched % times, expected 1', v_hits;
  END IF;

  v_new := replace(v_src, a_chk, r_chk);
  EXECUTE v_new;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_add'
      AND pg_get_function_identity_arguments(p.oid) LIKE '%p_effective_to date%') THEN
    RAISE EXCEPTION 'mig 792: project_member_add does not take an end date';
  END IF;

  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'project_member_add') <> 1 THEN
    RAISE EXCEPTION 'mig 792: project_member_add has more than one overload';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_update'
      AND pg_get_functiondef(p.oid) LIKE '%OUTLIVES_PROJECT%') THEN
    RAISE EXCEPTION 'mig 792: project_member_update does not carry the outlives rule';
  END IF;

  RAISE NOTICE 'mig 792: OK -- assignments end with their project unless shortened';
END $mig$;
