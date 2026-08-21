-- Migration : 20260820768_cc_recipients_are_told_not_asked.sql
-- Purpose   : Stop sending a CC recipient the approver's instructions.
--
-- WHAT HAPPENS TODAY
--   Every call site queues a CC notification as 'wf.task_assigned' with
--   'is_cc', true in the payload. The payload only feeds {{token}} substitution
--   -- it has never influenced which template is chosen -- and no CC-specific
--   template exists anywhere. So a person copied for information receives the
--   approver's words. On timesheet, since the step binding landed, that reads:
--
--     "A timesheet is waiting on HR ... then approve it or send it back with a
--      note saying what needs changing."
--
--   They cannot. A CC step is defined in the step editor as "Notifies only --
--   no approval action, SLA, or skip conditions". The message asks them to do
--   the one thing the step design forbids, and it is the only message they get.
--
-- THE FIX: is_cc changes the EVENT, not the template
--   A CC notification is a different event that happens to share a moment with
--   'wf.task_assigned'. Naming it as one lets every level of 748's chain
--   customise it -- step, template version, module prefix, generic -- with no
--   new mechanism and no new table.
--
--   Placed AFTER 748's step-override block and BEFORE its template block, so:
--     * a step that has its own notification bound still wins. An admin who
--       picked a template for that CC step meant it, and this must not overrule
--       them.
--     * otherwise the code becomes 'wf.cc_notified' and the remaining chain
--       resolves normally -- template override, then '<module>.cc_notified',
--       then the generic seeded below.
--
--   Patched IN PLACE. wf_queue_notification carries 748's patch and nothing in
--   the repo holds its true definition; a CREATE OR REPLACE from a file would
--   revert it -- the 734/736/737 defect. Anchor hits are asserted, and a body
--   already carrying MIG 768 is skipped.
--
-- WHY THIS MATTERS BEYOND TIMESHEET
--   Vj: "this is not fixed, admin can add or remove any time." Exactly -- CC
--   steps are configuration. Whoever adds one tomorrow, on any module, gets
--   correct wording without a migration, because the generic template below is
--   the floor and the admin screen can override it per workflow.
--
-- Depends on : 748 (the resolution chain and its anchors), 756 (category column),
--              501093 (is_cc)

-- ── 1. The wording ───────────────────────────────────────────────────────────
-- Generic first: the floor for every module, including ones that do not exist
-- yet. Only tokens that genuinely resolve everywhere -- {{module_label}} is
-- substituted at delivery by mig 604, not from the payload.
INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl, category)
VALUES
  ('wf.cc_notified',
   'Copied for information: {{module_label}}',
   'You have been copied on this request. Nothing is needed from you — it is '
   'with its approvers. Open it if you want to see where it has got to.',
   'general'),

  -- Timesheet has a CC step today, so it gets wording that names the month and
  -- whose it is, the same courtesy the approver's message gets.
  ('timesheet.cc_notified',
   '{{employee_name}} — {{period_label}} timesheet sent for approval',
   'You are copied for information. The timesheet is with its approver and '
   'nothing is needed from you. Open the month to see it day by day, including '
   'anything recorded beyond plan.',
   'general')
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      category   = EXCLUDED.category;


-- ── 2. Resolve it ────────────────────────────────────────────────────────────
DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  -- 748's own comment line. Unique, and it marks exactly the seam between the
  -- step lookup and the template lookup.
  a_anchor CONSTANT text :=
    '  -- (2) INSTANCE-scoped. Keyed on the template VERSION of the instance, so v2 can';

  n_block CONSTANT text :=
    '  -- ── MIG 768: a CC recipient is being TOLD, not asked ─────────────────────' || chr(10) ||
    '  -- Runs only when the step above said nothing: an explicit step binding is a' || chr(10) ||
    '  -- human decision and outranks this. Rewrites BOTH p_template_code and' || chr(10) ||
    '  -- v_final_code so the template lookup below, the module-prefix CASE after it' || chr(10) ||
    '  -- and the generic fallback all key on the CC event rather than on the' || chr(10) ||
    '  -- assignment it happens to coincide with.' || chr(10) ||
    '  IF v_final_code = p_template_code' || chr(10) ||
    '     AND p_template_code = ''wf.task_assigned''' || chr(10) ||
    '     AND coalesce(p_payload->>''is_cc'', ''false'') = ''true''' || chr(10) ||
    '     AND EXISTS (SELECT 1 FROM workflow_notification_templates' || chr(10) ||
    '                 WHERE code = ''wf.cc_notified'') THEN' || chr(10) ||
    '    p_template_code := ''wf.cc_notified'';' || chr(10) ||
    '    v_final_code    := ''wf.cc_notified'';' || chr(10) ||
    '  END IF;' || chr(10) ||
    '' || chr(10);
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'wf_queue_notification'
    AND  pg_get_function_identity_arguments(p.oid) =
         'p_instance_id uuid, p_template_code text, p_target_profile uuid, p_payload jsonb';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 768: wf_queue_notification(uuid,text,uuid,jsonb) not found';
  END IF;

  IF position('MIG 768' IN v_src) > 0 THEN
    RAISE NOTICE 'mig 768: CC resolution already present, nothing to do';
    RETURN;
  END IF;

  IF position('MIG 748' IN v_src) = 0 THEN
    RAISE EXCEPTION
      'mig 768: wf_queue_notification does not carry 748''s override chain — '
      'this patch has nothing to attach to. Apply 748 first.';
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_anchor, ''))) / length(a_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 768: anchor matched % times, expected 1', v_hits;
  END IF;

  v_new := replace(v_src, a_anchor, n_block || a_anchor);
  EXECUTE v_new;

  RAISE NOTICE 'mig 768: CC notifications now resolve through wf.cc_notified';
END
$mig$;


-- ── Assertions ───────────────────────────────────────────────────────────────
-- A silent no-op here leaves CC recipients being told to approve things, which
-- is the defect. And a patch that landed but left 748 behind would be worse
-- than not patching.
DO $chk$
DECLARE
  v_src text;
  v_n   int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'wf_queue_notification';

  IF position('MIG 768' IN v_src) = 0 THEN
    RAISE EXCEPTION 'mig 768 assert: the CC block is not in the function body';
  END IF;

  IF position('MIG 748' IN v_src) = 0 THEN
    RAISE EXCEPTION
      'mig 768 assert: 748''s override chain is gone — the patch replaced it '
      'instead of extending it';
  END IF;

  -- Order matters: the CC rewrite must sit AFTER the step lookup, or a step
  -- binding on a CC step would be ignored.
  IF position('MIG 768' IN v_src) < position('(1) STEP-scoped' IN v_src) THEN
    RAISE EXCEPTION
      'mig 768 assert: the CC block landed before the step override — an admin''s '
      'explicit step binding would be overruled';
  END IF;

  SELECT count(*) INTO v_n
  FROM   workflow_notification_templates
  WHERE  code IN ('wf.cc_notified', 'timesheet.cc_notified');

  IF v_n <> 2 THEN
    RAISE EXCEPTION 'mig 768 assert: expected 2 cc_notified templates, found %', v_n;
  END IF;

  RAISE NOTICE 'mig 768: CC wording in place and resolved after the step override';
END
$chk$;
