-- =============================================================================
-- Migration 861 — an approval that already finished is not still pending
--
-- WHAT WENT WRONG
-- ═══════════════
--   A timesheet was submitted on behalf of an employee whose manager IS the
--   submitter. Afterwards:
--
--       timesheet_headers   status = 'to_be_approved', approved_at = NULL
--       workflow_instances  status = 'approved',       completed_at = set
--       Approver Inbox      empty
--       My Requests         "Approved"
--
--   Three surfaces, two answers. The employee's own screen says it is waiting
--   on an approval that has already happened, and there is nothing anywhere for
--   anyone to act on to resolve it. The sheet is also stuck: submit_timesheet
--   refuses a second submit while status = 'to_be_approved', and withdraw only
--   works against a live instance -- and this one is finished.
--
-- WHY
-- ═══
--   wf_submit() does not merely create an instance and hand back its id. It
--   calls wf_advance_instance(), which recurses: every step it can resolve, it
--   resolves. When each step evaporates -- the approver IS the initiator
--   (step_removed), a job relationship is unset so wf_resolve_approver returns
--   NULL (skipped), a step is cc-only (cc_notified) -- the instance runs off
--   the end and completes. On the way out it calls wf_sync_module_status(),
--   which writes 'approved' onto this very header. All of that happens INSIDE
--   the wf_submit() call, before control returns to submit_timesheet.
--
--   And then submit_timesheet ran, unconditionally:
--
--       UPDATE timesheet_headers
--       SET status = 'to_be_approved', submitted_at = now(), approved_at = NULL, ...
--
--   It assumed wf_submit leaves the sheet pending. That is true whenever a task
--   gets created, which is the ordinary case and why this was never seen. It is
--   false whenever the workflow finishes inside the call -- and then this
--   statement overwrites the approval the workflow just made and clears the
--   timestamp that recorded it. The row on Dev is this statement's fingerprint
--   exactly: submitted_at and the instance's completed_at are the SAME instant,
--   because they are the same transaction.
--
--   NOTE: a workflow that resolves to nobody is CORRECT here, not a control
--   failure. A manager raising a request does not approve it a second time, and
--   an unset job relationship is a valid configuration. The workflow behaved as
--   designed. The defect is entirely in what the caller did with the result.
--
-- THE FIX
-- ═══════
--   Ask the instance. submit_timesheet already applies this rule twenty lines
--   earlier -- "The header said otherwise, but the workflow is the authority" --
--   when an in_progress instance overrules a header that claims to be editable.
--   The same rule, applied after wf_submit rather than before it, is the whole
--   change.
--
--   A live instance (in_progress / awaiting_clarification) means pending, which
--   is the behaviour that was always intended and is unchanged. An instance
--   that says 'approved' means approved. Anything else -- a state this path has
--   no way to reach today -- leaves the header exactly as wf_sync_module_status
--   wrote it rather than forcing a value over it, because whatever else the
--   workflow concluded, this function is not the place that decides it.
--
--   Both write sites get it: the fresh-submit path, and the resume path after
--   wf_resubmit, which has the same shape and the same hole. The returned
--   status and message are derived from what was actually written instead of
--   asserted in advance, so the screen cannot report "submitted for approval"
--   about a sheet that is approved.
--
--   What is NOT changed: the v_tpl IS NULL branch (no workflow assigned at all)
--   still auto-approves with its own wording. It has no instance to consult and
--   is not what this is about.
--
-- SAFETY
--   * Reads the LIVE definition and asserts every anchor count.
--   * Idempotent: each patch skips itself once applied, tested by running twice.
--   * Verified against a real PostgreSQL 16 for the completing case, the
--     ordinary pending case, and the resume branch in both.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._mig861_patch(
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
    RAISE EXCEPTION 'MIG 861: %() not found.', p_fn;
  END IF;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'MIG 861: %() is overloaded % ways; this patcher edits one definition and would pick arbitrarily.', p_fn, v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  IF position(p_a IN v_src) = 0 AND position(p_b IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 861: %() already patched, skipping.', p_fn;
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, p_a, ''))) / length(p_a);
  IF v_hits <> p_expect THEN
    RAISE EXCEPTION 'MIG 861: in %(), the anchor matched % times, expected %. Read the live definition before editing this file. Anchor: %',
      p_fn, v_hits, p_expect, left(p_a, 90);
  END IF;

  v_new := replace(v_src, p_a, p_b);
  EXECUTE v_new;
  RAISE NOTICE 'MIG 861: patched %() — % occurrence(s).', p_fn, v_hits;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — two variables: what the workflow says, and what was written
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The anchor runs INTO the BEGIN deliberately (838's lesson). `  v_profile
-- uuid;` on its own survives inside its own replacement, so the "already
-- applied" test could never fire and a second run would declare the new
-- variables twice.

DO $mig$
BEGIN
  PERFORM public._mig861_patch('submit_timesheet',
'  v_profile    uuid;
BEGIN',
'  v_profile    uuid;
  -- Mig 861. What the workflow instance says once wf_submit / wf_resubmit has
  -- returned, and what this function actually wrote as a result.
  v_wf_status  text;
  v_final      text;
BEGIN',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the fresh-submit path stops overwriting a completed approval
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  PERFORM public._mig861_patch('submit_timesheet',
'  UPDATE timesheet_headers
  SET status               = ''to_be_approved'',
      submitted_at         = now(),
      approved_at          = NULL,
      workflow_instance_id = v_instance
  WHERE id = p_header_id;

  RETURN jsonb_build_object(''ok'', true, ''status'', ''to_be_approved'', ''workflow'', true,
                            ''instance_id'', v_instance,
                            ''message'', ''Timesheet submitted for approval.'');',
'  -- Mig 861. wf_submit above did not just create an instance; it advanced it
  -- as far as it could go. If every step resolved to nobody, that instance is
  -- already ''approved'' and wf_sync_module_status has already written
  -- ''approved'' onto this header. The statement that used to stand here undid
  -- that: it forced ''to_be_approved'' and cleared approved_at, leaving a sheet
  -- waiting on an approval that had finished and an inbox with nothing in it.
  --
  -- The instance is the authority -- the same rule this function applies above,
  -- where an in_progress instance overrules the header. So ask it.
  SELECT wi.status INTO v_wf_status
  FROM   workflow_instances wi WHERE wi.id = v_instance;

  UPDATE timesheet_headers h
  SET status               = CASE
        WHEN v_wf_status IN (''in_progress'', ''awaiting_clarification'') THEN ''to_be_approved''
        WHEN v_wf_status = ''approved''                                  THEN ''approved''
        ELSE h.status END,
      submitted_at         = now(),
      -- COALESCE, not now(): if the workflow stamped its own completion time,
      -- that is when it was approved and this function must not restate it.
      approved_at          = CASE
        WHEN v_wf_status IN (''in_progress'', ''awaiting_clarification'') THEN NULL
        WHEN v_wf_status = ''approved''                                  THEN COALESCE(h.approved_at, now())
        ELSE h.approved_at END,
      workflow_instance_id = v_instance
  WHERE h.id = p_header_id
  RETURNING h.status INTO v_final;

  RETURN jsonb_build_object(''ok'', true, ''status'', v_final, ''workflow'', true,
                            ''instance_id'', v_instance,
                            ''message'', CASE v_final
                              WHEN ''approved''       THEN ''Timesheet submitted and approved -- the approval workflow completed with no one left to approve.''
                              WHEN ''to_be_approved'' THEN ''Timesheet submitted for approval.''
                              ELSE ''Timesheet submitted. The approval workflow finished as: '' || coalesce(v_wf_status, ''unknown'') || ''.''
                            END);',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — the resume path has the same hole, and gets the same fix
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A sent-back sheet resumes an existing instance. wf_resubmit puts it back in
-- flight and advances it, and it can run to completion for exactly the same
-- reasons. This branch then forced 'to_be_approved' and cleared approved_at
-- just as unconditionally.

DO $mig$
BEGIN
  PERFORM public._mig861_patch('submit_timesheet',
'    UPDATE timesheet_headers
    SET status = ''to_be_approved'', submitted_at = now(), approved_at = NULL
    WHERE id = p_header_id;

    RETURN jsonb_build_object(''ok'', true, ''status'', ''to_be_approved'', ''workflow'', true,
                              ''instance_id'', v_open.id, ''resumed'', true,
                              ''message'', ''Timesheet resubmitted for approval.'');',
'    -- Mig 861. Same as the fresh-submit path below: wf_resubmit advances the
    -- instance and it can finish inside that call, so re-read it rather than
    -- assuming v_open.status is still what it was before the resume.
    SELECT wi.status INTO v_wf_status
    FROM   workflow_instances wi WHERE wi.id = v_open.id;

    UPDATE timesheet_headers h
    SET status       = CASE
          WHEN v_wf_status IN (''in_progress'', ''awaiting_clarification'') THEN ''to_be_approved''
          WHEN v_wf_status = ''approved''                                  THEN ''approved''
          ELSE h.status END,
        submitted_at = now(),
        approved_at  = CASE
          WHEN v_wf_status IN (''in_progress'', ''awaiting_clarification'') THEN NULL
          WHEN v_wf_status = ''approved''                                  THEN COALESCE(h.approved_at, now())
          ELSE h.approved_at END
    WHERE h.id = p_header_id
    RETURNING h.status INTO v_final;

    RETURN jsonb_build_object(''ok'', true, ''status'', v_final, ''workflow'', true,
                              ''instance_id'', v_open.id, ''resumed'', true,
                              ''message'', CASE v_final
                                WHEN ''approved''       THEN ''Timesheet resubmitted and approved -- the approval workflow completed with no one left to approve.''
                                WHEN ''to_be_approved'' THEN ''Timesheet resubmitted for approval.''
                                ELSE ''Timesheet resubmitted. The approval workflow finished as: '' || coalesce(v_wf_status, ''unknown'') || ''.''
                              END);',
    1);
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig861_patch(text, text, text, integer);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — the sheets already stuck by this
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Fixing the function does nothing for a sheet that has ALREADY been written
-- into the contradiction, and those sheets cannot be rescued from the UI: the
-- submit path refuses a header that reads 'to_be_approved', and the withdraw
-- path needs a live instance, which this one no longer has. Without this the
-- fix ships and the reported sheet stays broken.
--
-- The condition is unambiguous: the header points at an instance, that instance
-- is approved, and the header still says it is waiting. There is no legitimate
-- way to be in that state -- wf_sync_module_status writes 'approved' onto the
-- header as part of completing the instance, so the only thing that can have
-- separated them afterwards is the statement PART 2 just removed.
--
-- approved_at is restored from the best evidence available, in order: whatever
-- survived, the instance's own completion time, then the submission time -- all
-- three are the same instant in the rows this created, because it all happened
-- in one transaction.

DO $mig$
DECLARE v_fixed integer; v_left integer;
BEGIN
  WITH repaired AS (
    UPDATE timesheet_headers h
    SET    status      = 'approved',
           approved_at = COALESCE(h.approved_at, wi.completed_at, h.submitted_at)
    FROM   workflow_instances wi
    WHERE  wi.id          = h.workflow_instance_id
      AND  wi.module_code = 'timesheet'
      AND  wi.status      = 'approved'
      AND  h.status       = 'to_be_approved'
    RETURNING h.id
  )
  SELECT count(*) INTO v_fixed FROM repaired;

  RAISE NOTICE 'MIG 861: reconciled % timesheet header(s) that were waiting on an approval that had already completed.', v_fixed;

  SELECT count(*) INTO v_left
  FROM   timesheet_headers h
  JOIN   workflow_instances wi ON wi.id = h.workflow_instance_id
  WHERE  wi.module_code = 'timesheet'
    AND  wi.status      = 'approved'
    AND  h.status       = 'to_be_approved';

  IF v_left > 0 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: % header(s) still contradict their own completed workflow.', v_left;
  END IF;
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_src text; v_n integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'submit_timesheet';

  IF position('v_wf_status  text;' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: submit_timesheet has no v_wf_status, so PART 1 did not apply.';
  END IF;

  -- Neither of the two unconditional statements may survive. Spelled out in
  -- full so this cannot be satisfied by the in_progress short-circuit branch,
  -- which legitimately keeps its own `SET status = 'to_be_approved'` and must
  -- still be there.
  IF position('SET status               = ''to_be_approved'',
      submitted_at         = now(),
      approved_at          = NULL,' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: the fresh-submit path still forces to_be_approved and clears approved_at.';
  END IF;
  IF position('SET status = ''to_be_approved'', submitted_at = now(), approved_at = NULL' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: the resume path still forces to_be_approved and clears approved_at.';
  END IF;

  -- ...and the branch that is SUPPOSED to keep forcing it still does.
  IF position('SET status = ''to_be_approved'', submitted_at = COALESCE(submitted_at, now())' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: the in_progress reconciliation branch has been damaged.';
  END IF;

  v_n := (length(v_src) - length(replace(v_src, 'RETURNING h.status INTO v_final', '')))
         / length('RETURNING h.status INTO v_final');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: expected both write sites to report what they wrote; found %.', v_n;
  END IF;

  v_n := (length(v_src) - length(replace(v_src, 'SELECT wi.status INTO v_wf_status', '')))
         / length('SELECT wi.status INTO v_wf_status');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: expected both write sites to read the instance status; found %.', v_n;
  END IF;

  -- The no-workflow-at-all branch is deliberately untouched: it has no instance
  -- to consult and its own wording is correct.
  IF position('no approval workflow is configured' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: the unassigned-workflow branch has been lost.';
  END IF;

  -- 838 must still hold. This function is patched in place by successive
  -- migrations and a bad anchor elsewhere would silently revert it.
  IF position('timesheet_period_label(v_hdr.period)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 861 FAILED: 838''s period label is gone from the metadata; the live definition is not what this migration read.';
  END IF;
END;
$v$;

COMMENT ON FUNCTION public.submit_timesheet IS
  'Mig 861: after wf_submit / wf_resubmit the workflow instance decides whether '
  'this header is pending or approved -- a workflow that completes inside the '
  'submit call (every step resolving to nobody) is a real approval and is no '
  'longer overwritten with to_be_approved. Carries 838 (period named by its '
  'label), 742 (starts or resumes the approval workflow), 741 (permission not '
  'ownership) and 730 (auto-approve when no workflow is assigned).';

COMMIT;
