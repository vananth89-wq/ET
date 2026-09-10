-- =============================================================================
-- Migration 841 — the approver is told who asked for the help
--
-- WHAT IS MISSING
-- ═══════════════
--   829 added "Requested by" to a cross-project support entry, and the reason
--   it exists is worth restating, because it is the whole point of this
--   migration too. Vj, asking for it:
--
--       "Else I can randomly assign to any project and it becomes difficult.
--        With this the Project lead can actually question the employee why he
--        took help from others."
--
--   The project lead. The APPROVER. And the approver's copy of the report is
--   the one place that field never reached: `buildApprovalExport` sets
--   `requester: null` with a comment saying why, so the help block prints
--   "Testing · 6h" against AZAD with no indication of who on AZAD asked for it.
--
--   836 taught this payload WHICH project was helped. 830 records WHO asked.
--   The two have simply never met in `time_approval_payload`, so the employee's
--   own PDF names the requester and the approver's does not -- the one reader
--   who can act on it seeing strictly less than the one who cannot.
--
-- THE NAME, NOT THE ID
-- ════════════════════
--   `related_project_id` is an id because 836 said a later reader would want to
--   name the project, and ids are what survive a rename. The requester is
--   different: the payload is a snapshot for a document, the document prints a
--   person's name, and handing it an id would make the PDF perform a lookup the
--   payload is already sitting on top of. Every other person in this payload --
--   the employee, the manager -- is carried the same way.
--
--   It resolves through employees.id, so a requester who has since left the
--   project, or the company, still has a name here. That matters: the whole
--   value of the field is being able to ask somebody about a decision months
--   later, and a NULL where a person used to be answers nothing.
--
-- Depends on: 829/830 (help_requested_by), 836 (related_project_id in the
--             payload), 743 (the entries object this patches)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer; v_n integer;

  -- Anchored on the line 836 added, read from the LIVE definition on Dev rather
  -- than from the migration files -- three deploys in a row failed this week on
  -- anchors reconstructed from the files, twice on whitespace alone.
  a CONSTANT text :=
'               ''related_project_id'', te.related_project_id,' || E'\n';
  b CONSTANT text :=
'               ''related_project_id'', te.related_project_id,' || E'\n' ||
'               -- MIG 841: and WHO asked for it. 836 put the project here and' || E'\n' ||
'               -- 830 records the person; they had never met, so the approver''''s' || E'\n' ||
'               -- copy printed the help block with no requester -- the one' || E'\n' ||
'               -- reader who can question it seeing less than the one who' || E'\n' ||
'               -- cannot. Resolved to a NAME because this payload feeds a' || E'\n' ||
'               -- document, and through employees.id so somebody who has since' || E'\n' ||
'               -- left the project still has one.' || E'\n' ||
'               ''requester'', (SELECT e841.name FROM employees e841' || E'\n' ||
'                                WHERE  e841.id = te.help_requested_by),' || E'\n';
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_approval_payload';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'MIG 841: expected exactly one time_approval_payload, found %.', v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_approval_payload';

  IF position('''requester''' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 841: already applied, skipping.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a, ''))) / length(a);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 841: the related_project_id line matched % times, expected 1. Read the live definition before editing this file.', v_hits;
  END IF;

  v_new := replace(v_src, a, b);
  EXECUTE v_new;
  RAISE NOTICE 'MIG 841: the approval payload now carries the requester.';
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_approval_payload';

  IF position('''requester''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 841 FAILED: the payload does not carry the requester.';
  END IF;
  IF position('help_requested_by' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 841 FAILED: the requester is not resolved from help_requested_by, so it cannot be the person 830 recorded.';
  END IF;
  -- 836's field must survive: this patch inserts BESIDE it, and a replace that
  -- swallowed it would leave the approver unable to name the project either.
  IF position('''related_project_id''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 841 FAILED: related_project_id was lost.';
  END IF;

  RAISE NOTICE 'MIG 841 OK: the approver can see who asked.';
END;
$v$;

COMMIT;
