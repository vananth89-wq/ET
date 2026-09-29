-- =============================================================================
-- Migration 862 — the matrix managers the engine forgot how to find,
--                 and the CC recipients it kept asking to approve
--
-- WHAT WENT WRONG
-- ═══════════════
--   A timesheet was submitted on behalf of an employee. The TIMESHEET template
--   is eight steps:
--
--       1  Manager           MANAGER            approval
--       2  Subject Employee  SUBJECT_EMPLOYEE   CC
--       3  PM01              JOB_RELATIONSHIP   CC
--       4  PM02              JOB_RELATIONSHIP   CC
--       5  PM03              JOB_RELATIONSHIP   CC
--       6  PM04              JOB_RELATIONSHIP   CC
--       7  PM05              JOB_RELATIONSHIP   CC
--       8  PM06              JOB_RELATIONSHIP   CC
--
--   The action log recorded 7 x step_removed and 1 x cc_notified. Step 1
--   resolved to the initiator and was removed; step 2 notified the employee;
--   steps 3-8 ALL resolved to NULL and were skipped. The employee's PM01, PM03
--   and PM04 are assigned and active. None of them were copied. None of them
--   has been copied on anything since June.
--
-- FAULT 1 — wf_resolve_approver has no JOB_RELATIONSHIP branch
-- ────────────────────────────────────────────────────────────
--   Mig 361 added it. Mig 528 carried it and widened the CHECK constraint that
--   still permits the value today. Mig 590 then rewrote the function with six
--   branches, dropping BOTH 'JOB_RELATIONSHIP' and 'SUBJECT_EMPLOYEE'. Mig 621
--   noticed and restored 'SUBJECT_EMPLOYEE' only.
--
--   So for three months a JOB_RELATIONSHIP step has fallen through to
--   `ELSE v_approver := NULL` -- a value the table explicitly allows, resolving
--   to nobody, skipped without an error. Measured on the live database:
--
--       DEPT_HEAD, MANAGER, ROLE, RULE_BASED, SELF, SPECIFIC_USER,
--       SUBJECT_EMPLOYEE
--
--   Seven branches. The eighth is gone.
--
-- FAULT 2 — the resolver never read relationship_code
-- ───────────────────────────────────────────────────
--   `SELECT approver_type, approver_role, approver_profile_id, template_id,
--   allow_delegation INTO v_step` -- relationship_code is not in that list. The
--   branch could not have worked even if it had survived 590. Restoring the
--   branch alone would have failed on the first call.
--
-- FAULT 3 — the employees mirror stops at PM03
-- ────────────────────────────────────────────
--   Mig 361's branch read `v_submitter_emp.pm01_manager_id` and friends off the
--   six mirror columns on employees (mig 359). Mig 803 added PM04, PM05 and
--   PM06 as relationship types on 31 Aug; 804 syncs project members into all
--   six slots. Nobody added the mirror columns, and the mirror helper (845,
--   22 Sep) still writes six. Restoring 361 verbatim would resolve PM01-PM03
--   and silently drop PM04-PM06 -- a second invisible skip on top of the first.
--
--   So this reads the SOURCE, not the mirror: employee_job_relationship_set
--   joined to _item, honouring is_active, the effective-date window, and
--   removed_on (835). Every code works, including ones added later, and it
--   cannot drift from what the Job Relationships screen shows.
--
-- AND WHOSE relationships?
-- ────────────────────────
--   361 read the SUBMITTER's. 590/621 moved the whole function to the SUBJECT
--   (`COALESCE(subject_profile_id, submitted_by)`) and this branch follows that,
--   deliberately. The timesheet belongs to the employee; the project managers
--   who should see it are the employee's. Reading the submitter's would mean
--   that filing a sheet on someone's behalf copies YOUR project managers
--   instead of theirs -- which is not a CC list anybody configured.
--
-- FAULT 4 — CC recipients are asked to approve
-- ────────────────────────────────────────────
--   Mig 768 ("CC recipients are told, not asked") seeded wf.cc_notified and
--   timesheet.cc_notified, and patched wf_queue_notification to swap
--   'wf.task_assigned' for 'wf.cc_notified' when the payload carries
--   is_cc = true. Its header asserts that "every call site" sets that key.
--   Two do not -- and they are the only two that run on an ordinary submit:
--
--       wf_submit          (564:336)  jsonb_build_object('step_name', ..., 'module_code', ...)
--       wf_advance_instance(675:431)  jsonb_build_object('step_name', ..., 'module_code', ...)
--
--   Only wf_force_advance sets it. So on every normal submission the branch
--   never fires and a CC recipient receives the approver's wording: "A
--   timesheet has been submitted for your approval... before you approve it or
--   send it back for correction." The employee was told to approve their own
--   timesheet. The links were already right -- 769 derives CC status from the
--   task rather than the payload -- so only the words were wrong.
--
--   Both payloads now carry is_cc, which is all 768 ever needed.
--
-- SAFETY
--   * Every patch reads the LIVE definition and asserts its anchor count.
--   * Idempotent: each skips itself once applied; verified by running twice.
--   * Verified against a real PostgreSQL 16, including that PM04 -- which has
--     no mirror column at all -- now resolves.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._mig862_patch(
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
    RAISE EXCEPTION 'MIG 862: %() not found.', p_fn;
  END IF;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'MIG 862: %() is overloaded % ways; this patcher edits one definition and would pick arbitrarily.', p_fn, v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  IF position(p_a IN v_src) = 0 AND position(p_b IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 862: %() already patched, skipping.', p_fn;
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, p_a, ''))) / length(p_a);
  IF v_hits <> p_expect THEN
    RAISE EXCEPTION 'MIG 862: in %(), the anchor matched % times, expected %. Read the live definition before editing this file. Anchor: %',
      p_fn, v_hits, p_expect, left(p_a, 90);
  END IF;

  v_new := replace(v_src, p_a, p_b);
  EXECUTE v_new;
  RAISE NOTICE 'MIG 862: patched %() — % occurrence(s).', p_fn, v_hits;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the resolver reads the column the branch needs
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  PERFORM public._mig862_patch('wf_resolve_approver',
'  SELECT approver_type, approver_role, approver_profile_id,
         template_id, allow_delegation
  INTO   v_step',
'  SELECT approver_type, approver_role, approver_profile_id,
         template_id, allow_delegation,
         -- Mig 862. Never selected, so v_step.relationship_code did not exist
         -- and the JOB_RELATIONSHIP branch could not have run even when it was
         -- present. Restoring the branch without this would fail on first call.
         relationship_code
  INTO   v_step',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the branch itself, reading the source of truth
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The replacement deliberately does NOT reproduce the anchor verbatim: a
-- comment is inserted between ELSE and the assignment. Without that, the anchor
-- would survive inside its own replacement, the "already applied" test could
-- never fire, and every re-run would add another JOB_RELATIONSHIP branch. Mig
-- 838 recorded this trap; running this file three times is what caught it here.

DO $mig$
BEGIN
  PERFORM public._mig862_patch('wf_resolve_approver',
'    ELSE
      v_approver := NULL;
  END CASE;',
'    WHEN ''JOB_RELATIONSHIP'' THEN
      -- Mig 862. Restored after mig 590 dropped it; mig 621 restored only
      -- SUBJECT_EMPLOYEE and left this one resolving to NULL for three months.
      --
      -- Read from employee_job_relationship_set/_item, NOT the six mirror
      -- columns on employees that mig 361 used. The mirror covers PM01-PM03
      -- and OM01-OM03 only; PM04-PM06 were added as relationship types by 803
      -- and have no column, so the mirror cannot answer for them at all. The
      -- source can answer for every code, including any added after this.
      --
      -- The SUBJECT''s relationships, not the submitter''s: the record belongs
      -- to the subject, so the matrix managers who should see it are theirs.
      -- Filing on someone''s behalf must not substitute your own PM chain.
      --
      -- NULL is a legitimate answer -- an unassigned slot, an inactive manager,
      -- a relationship whose removed_on has passed -- and the caller skips the
      -- step. That was always the design; what was wrong is that it was the
      -- ONLY answer.
      SELECT p.id INTO v_approver
      FROM   employee_job_relationship_set  s
      JOIN   employee_job_relationship_item i ON i.set_id = s.id
      JOIN   employees mgr ON mgr.id = i.manager_employee_id
      JOIN   profiles  p   ON p.employee_id = mgr.id
      WHERE  s.employee_id       = v_subject_emp.id
        AND  s.is_active         = true
        AND  CURRENT_DATE BETWEEN s.effective_from AND s.effective_to
        AND  i.relationship_code = v_step.relationship_code
        AND  (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE)
        AND  mgr.status          = ''Active''
        AND  p.is_active         = true
      LIMIT  1;

      -- No delegation on a matrix step (mig 361''s rule): the relationship
      -- names a specific person for a specific reason, and handing it to their
      -- delegate would copy somebody the configuration never mentioned.
      RETURN v_approver;

    ELSE
      -- Mig 862. An approver_type the CHECK permits but this CASE does not
      -- handle resolves to nobody, and the caller skips the step without an
      -- error. That is how JOB_RELATIONSHIP vanished for three months after
      -- 590 removed its branch while 528''s constraint went on allowing it.
      v_approver := NULL;
  END CASE;',
    1);
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — a CC notification says so, so 768's wording can take effect
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  PERFORM public._mig862_patch('wf_advance_instance',
'    jsonb_build_object(
      ''step_name'',   v_next_step.name,
      ''module_code'', v_instance.module_code
    )',
'    jsonb_build_object(
      ''step_name'',   v_next_step.name,
      ''module_code'', v_instance.module_code,
      -- Mig 862. Mig 768 swaps wf.task_assigned for wf.cc_notified when this
      -- key is true, and claimed every call site set it. This one never did,
      -- so CC recipients have been receiving the approver''s wording and being
      -- asked to approve records that were only copied to them.
      ''is_cc'',       coalesce(v_next_step.is_cc, false)
    )',
    1);

  PERFORM public._mig862_patch('wf_submit',
'    jsonb_build_object(''step_name'', v_first_step.name, ''module_code'', p_module_code)',
'    -- Mig 862. See wf_advance_instance: 768''s CC wording is keyed on is_cc,
    -- and a first step that is itself a CC step needs it too.
    jsonb_build_object(''step_name'', v_first_step.name, ''module_code'', p_module_code,
                       ''is_cc'', coalesce(v_first_step.is_cc, false))',
    1);
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig862_patch(text, text, text, integer);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_src text; v_branches text; v_n integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_resolve_approver';

  -- ONCE. A patch whose anchor survives inside its own replacement re-applies
  -- on every run and stacks duplicate branches; only the second CASE arm would
  -- ever execute and the rest would be dead code nobody could see was dead.
  v_n := (length(v_src) - length(replace(v_src, 'WHEN ''JOB_RELATIONSHIP'' THEN', '')))
         / length('WHEN ''JOB_RELATIONSHIP'' THEN');
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'MIG 862 FAILED: the JOB_RELATIONSHIP branch appears % times, expected exactly 1. This patch is not idempotent.', v_n;
  END IF;

  SELECT string_agg(m[1], ', ' ORDER BY m[1]) INTO v_branches
  FROM   regexp_matches(v_src, 'WHEN ''([A-Z_]+)'' THEN', 'g') m;

  IF position('JOB_RELATIONSHIP' IN coalesce(v_branches, '')) = 0 THEN
    RAISE EXCEPTION 'MIG 862 FAILED: wf_resolve_approver still has no JOB_RELATIONSHIP branch. Live branches: %', v_branches;
  END IF;
  IF position('SUBJECT_EMPLOYEE' IN coalesce(v_branches, '')) = 0 THEN
    RAISE EXCEPTION 'MIG 862 FAILED: SUBJECT_EMPLOYEE has been lost. This migration must not repeat 590. Live branches: %', v_branches;
  END IF;
  RAISE NOTICE 'MIG 862: wf_resolve_approver branches are now: %', v_branches;

  IF position('relationship_code' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 862 FAILED: the resolver does not read relationship_code, so every JOB_RELATIONSHIP step would raise.';
  END IF;

  -- The mirror must not be reintroduced. If a later edit brings it back, PM04
  -- to PM06 start disappearing again in a way nothing reports.
  IF position('pm01_manager_id' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 862 FAILED: the resolver reads the employees mirror, which has no PM04-PM06 columns.';
  END IF;

  -- The subject, not the submitter. Getting this backwards is silent and wrong.
  IF position('s.employee_id       = v_subject_emp.id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 862 FAILED: the JOB_RELATIONSHIP branch does not read the SUBJECT employee''s relationships.';
  END IF;

  -- Both CC call sites.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_advance_instance';
  IF position('''is_cc''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 862 FAILED: wf_advance_instance still queues CC notifications without is_cc, so 768''s wording cannot fire.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_submit';
  IF position('''is_cc''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 862 FAILED: wf_submit still queues its first-step notification without is_cc.';
  END IF;

  -- 768's templates must exist, or the swap has nothing to swap to and the
  -- payload key changes nothing.
  IF NOT EXISTS (SELECT 1 FROM workflow_notification_templates WHERE code = 'wf.cc_notified') THEN
    RAISE EXCEPTION 'MIG 862 FAILED: wf.cc_notified does not exist; mig 768 has not been applied and the is_cc payload would have no effect.';
  END IF;
END;
$v$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — what this does NOT fix
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Reported so the next person does not have to rediscover it:
--
--   * The employees mirror (pm01..pm03, om01..om03) is still short of PM04-PM06
--     and still written by sync_job_relationship_mirrors (845). Nothing in the
--     workflow engine reads it any more, but anything else that does is
--     answering for six of nine codes.
--
--   * workflow_step_approvers.approver_type (the co-approver table, mig 200)
--     still permits only MANAGER, ROLE, DEPT_HEAD, SPECIFIC_USER, RULE_BASED
--     and SELF. A co-approver cannot be a JOB_RELATIONSHIP or a
--     SUBJECT_EMPLOYEE, though a primary approver can.
--
--   * Nothing enforces that CC steps come after every approval step. The active
--     templates all comply today, so this is a guard that is not needed yet
--     rather than a defect: a CC that runs before an approval would report a
--     decision nobody has made.
--
-- A NOTE ON READING workflow_steps
-- ════════════════════════════════
--   A query over workflow_steps that does not select workflow_templates.version
--   overlays every version of a template on top of itself, and the result looks
--   like one template with duplicated and out-of-order steps. PERSONAL_INFO_EDIT
--   read that way during this investigation and appeared to have two steps at
--   order 1, two at order 2, and a CC ahead of an approval. It has none of
--   those: version 1 is inactive and version 2 is HR Analyst, HR Head, Employee
--   (CC), Subject Employee (CC) -- one step per order, both CCs last.
--
--   That template is also worth reading for what the pair of CC steps does:
--   SELF resolves to the filer and SUBJECT_EMPLOYEE to the employee, so an
--   HR-filed edit notifies both, and a self-service edit resolves both to the
--   same profile and 675's CC dedup collapses them into one notification.
--   Two recipients or one, decided by who filed, with no branch anywhere.
-- =============================================================================

COMMENT ON FUNCTION wf_resolve_approver(uuid, uuid) IS
  'Mig 862: restored the JOB_RELATIONSHIP branch dropped by mig 590 (621 '
  'restored only SUBJECT_EMPLOYEE), reading employee_job_relationship_set/_item '
  'for the SUBJECT employee rather than the six-column employees mirror, which '
  'has no PM04-PM06. No delegation on a matrix step. Carries 621 '
  '(SUBJECT_EMPLOYEE) and 590 (MANAGER/DEPT_HEAD resolve via subject_profile_id).';

COMMIT;
