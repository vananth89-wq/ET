-- =============================================================================
-- Migration 827 — the time type supplies the word, not the screen
--
-- THE PROBLEM VJ SPOTTED
-- ══════════════════════
-- A support entry books to no project and names the one it HELPED (801). Shown
-- as a bare project name, the row asserts the hours are that project's — which
-- is precisely the claim 801 exists to deny. So the timesheet began qualifying
-- it, and the first version hardcoded the qualifier in the component:
--
--     `Helping ${projectName}`
--
-- Vj: *"we are hardcoding the word Helping, I am worried what if we have
-- another timetype of same category tomorrow."*
--
-- He is right, and the defence — that `uses_related_project` MEANS "the project
-- named is the one being helped", so the word is safe for any type carrying the
-- flag — is true of the semantics and beside the point. The flag says what the
-- COLUMN means. It says nothing about what an administrator will call the next
-- type that uses it, and "Peer Review for Another Project" or "Knowledge
-- Transfer" would both carry the flag honestly and read wrong as "Helping".
--
-- A word describing a configurable thing belongs with the configuration.
--
-- WHY A LABEL AND NOT THE TYPE'S NAME
--   The name is already there and is already truthful — but it is written to be
--   unambiguous in an admin list, not short. "AZAD (Support to Another Project)"
--   does not fit a calendar cell 176px wide, and truncating it produces
--   "AZAD (Support to An…", which is worse than either. So: a SHORT label, with
--   the type's own name as the fallback when nobody has set one. The fallback is
--   the honest default — if an administrator has not given a short word, show
--   what they did call it rather than inventing one here.
--
-- WHY A NOUN AND NOT A VERB
--   This decided the display format. "Helping" only works in one sentence
--   position; a noun works in parentheses, in a chip, as a column value in the
--   PDF and as a grouping key in a report. Once the word lives in a column an
--   administrator fills in, a verb is awkward to write and reads wrong
--   everywhere but the one place it was written for. So the screens now read
--   `AZAD (Support)` and the column holds `Support`.
--
-- NULLABLE, AND MEANINGFUL ONLY WHERE THE FLAG IS SET
--   Same relationship `is_billable` has to `requires_project` (800/801): the
--   column exists on every row and answers a question only some rows are asked.
--   NULL means "nobody set one", which the screen resolves to the type's name.
--   `upsert_time_type` clears it wherever `uses_related_project` is false, so a
--   type that stops recording help cannot keep a word describing help.
--
-- Depends on : 800 (upsert_time_type's is_billable follow-up), 801
--              (uses_related_project, and the XPS seed)
-- =============================================================================

BEGIN;

-- ── 1. The column ────────────────────────────────────────────────────────────

ALTER TABLE public.time_types
  ADD COLUMN IF NOT EXISTS related_project_label text;

COMMENT ON COLUMN public.time_types.related_project_label IS
  'Mig 827: the short word the timesheet puts after the helped project name -- '
  '"AZAD (Support)". Meaningful only where uses_related_project is true. NULL '
  'means nobody set one, and the screen falls back to this type''s own name. A '
  'NOUN, not a verb: it has to read correctly in parentheses, in a chip, and as '
  'a value in the exported report.';

-- Length is a display constraint, so it is stated as one. 24 characters is
-- about what fits beside a project name in a 176px calendar cell before the
-- whole label starts truncating -- at which point the short label has failed at
-- the only job it has.
DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'time_types_related_label_len') THEN
    ALTER TABLE public.time_types
      ADD CONSTRAINT time_types_related_label_len
      CHECK (related_project_label IS NULL OR char_length(btrim(related_project_label)) BETWEEN 1 AND 24);
  END IF;
END $mig$;


-- ── 2. Seed the type 801 created ─────────────────────────────────────────────
--
-- Matched on the CODE, which 801 set and which an administrator cannot change
-- once hours exist behind the type (TYPE_IN_USE, 802). Guarded on the label
-- being unset, so re-running this can never overwrite a word somebody chose.

UPDATE public.time_types
   SET related_project_label = 'Support'
 WHERE code = 'XPS'
   AND uses_related_project
   AND related_project_label IS NULL;


-- ── 3. upsert_time_type carries it ───────────────────────────────────────────
--
-- Anchored on the block mig 801 left, not on the original return: 801 inserted
-- its uses_related_project UPDATE immediately above that line, and taking the
-- older anchor would put this ABOVE it -- reading a flag that has not been
-- written yet, so the label would be cleared on the very save that turns the
-- flag on. The order of these two statements is the whole correctness argument.

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  a_ret CONSTANT text :=
'   WHERE id = v_id;' || E'\n' ||
'' || E'\n' ||
'  RETURN jsonb_build_object(''ok'', true, ''id'', v_id, ''created'', v_is_new);' || E'\n';

  b_ret CONSTANT text :=
'   WHERE id = v_id;' || E'\n' ||
'' || E'\n' ||
'  -- related_project_label (mig 827). AFTER the UPDATE above, which is what' || E'\n' ||
'  -- decides uses_related_project on this very save -- reading it before would' || E'\n' ||
'  -- clear the word on the same request that switches the flag on.' || E'\n' ||
'  --' || E'\n' ||
'  -- Blanked wherever the type does not record help, so a type that stops' || E'\n' ||
'  -- doing so cannot keep a word describing it. NULLIF on the trimmed value:' || E'\n' ||
'  -- an empty box means "no short label", not a label that is the empty string.' || E'\n' ||
'  UPDATE time_types' || E'\n' ||
'     SET related_project_label = CASE WHEN uses_related_project' || E'\n' ||
'                                      THEN NULLIF(btrim(COALESCE(p_data->>''related_project_label'', '''')), '''')' || E'\n' ||
'                                      ELSE NULL END' || E'\n' ||
'   WHERE id = v_id;' || E'\n' ||
'' || E'\n' ||
'  RETURN jsonb_build_object(''ok'', true, ''id'', v_id, ''created'', v_is_new);' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_time_type';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 827: upsert_time_type not found.';
  END IF;
  IF position('uses_related_project' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 827: mig 801 must run first -- the anchor is the block it adds.';
  END IF;

  IF position('related_project_label' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 827: upsert_time_type already carries the label. Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_ret, ''))) / length(a_ret);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 827: the anchor matched % times in upsert_time_type, expected 1. 801''s block has moved.', v_hits;
    END IF;
    v_new := replace(v_src, a_ret, b_ret);
    EXECUTE v_new;
    RAISE NOTICE 'MIG 827: upsert_time_type now carries related_project_label.';
  END IF;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  v_pos_flag integer;
  v_pos_lbl  integer;
  n integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'time_types'
                   AND column_name = 'related_project_label') THEN
    RAISE EXCEPTION 'MIG 827 FAILED: the column was not added.';
  END IF;

  -- Nullable, deliberately. A NOT NULL DEFAULT would put a word describing help
  -- on every attendance type in the system and leave no way to say "unset".
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'time_types'
               AND column_name = 'related_project_label' AND is_nullable = 'NO') THEN
    RAISE EXCEPTION 'MIG 827 FAILED: the column is NOT NULL. There would be no way to mean "no short label set".';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'time_types_related_label_len') THEN
    RAISE EXCEPTION 'MIG 827 FAILED: the length constraint is missing, so a label too long for the cell it is written for can be saved.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_time_type';

  IF position('related_project_label' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 827 FAILED: upsert_time_type does not carry the label, so the admin screen could never save one.';
  END IF;

  -- ORDER, not presence. Both statements exist either way; writing the label
  -- before the flag it is gated on is the one arrangement that is silently
  -- wrong -- the word would be cleared on the same save that turns the flag on,
  -- and only for that save, which is exactly the bug nobody reproduces.
  v_pos_flag := position('SET uses_related_project' IN v_src);
  v_pos_lbl  := position('SET related_project_label' IN v_src);
  IF v_pos_flag = 0 OR v_pos_lbl = 0 THEN
    RAISE EXCEPTION 'MIG 827 FAILED: one of the two follow-up updates is missing.';
  END IF;
  IF v_pos_lbl < v_pos_flag THEN
    RAISE EXCEPTION 'MIG 827 FAILED: the label is written before the flag it is gated on.';
  END IF;

  -- The rules 800 and 801 left must both still be there.
  IF position('SET is_billable' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 827 FAILED: mig 800''s is_billable follow-up was lost.';
  END IF;

  -- XPS carries a word, so the feature reads correctly the moment this deploys
  -- rather than falling back to a name too long for the cell.
  SELECT count(*) INTO n
  FROM   time_types
  WHERE  code = 'XPS' AND uses_related_project AND related_project_label IS NOT NULL;
  IF n <> 1 THEN
    RAISE NOTICE 'MIG 827: XPS has no short label (found % rows). The screen will fall back to the type name, which is correct but long.', n;
  END IF;

  -- And no type that does not record help is carrying a word about it.
  SELECT count(*) INTO n
  FROM   time_types
  WHERE  related_project_label IS NOT NULL AND NOT COALESCE(uses_related_project, false);
  IF n > 0 THEN
    RAISE EXCEPTION 'MIG 827 FAILED: % type(s) carry a help label without recording help.', n;
  END IF;

  RAISE NOTICE 'Migration 827 verified: the label lives on the time type, upsert writes it after the flag it depends on, and nothing that does not record help carries one.';
END $mig$;

COMMIT;
