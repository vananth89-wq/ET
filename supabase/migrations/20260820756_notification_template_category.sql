-- Migration : 20260820756_notification_template_category.sql
-- Purpose   : Make a notification template's category a stored, editable fact
--             instead of something inferred from substrings of its code.
--
-- What it replaces :
--             NotificationConfig.getCategory() decides the Task / SLA /
--             Approval / Returned / Admin / General filing by grepping the code
--             for 'sla', 'task', 'reject', 'complet' and friends. Two failures
--             follow from that, and both are live on Dev today:
--
--               false negative  timesheet.hr_review is an approval task
--                               assignment. It contains none of the magic
--                               words, so it files under General.
--
--               false positive  wf.task_removed contains 'task', so it files as
--                               a Task assignment -- but it tells an approver a
--                               task was taken AWAY from them. The substring
--                               cannot tell the difference, and no naming
--                               convention fixes it: the information simply is
--                               not in the code.
--
--             The second one is the argument for a column rather than a better
--             regex. A code is an identifier; what a message MEANS is a
--             separate fact and has to be stored separately.
--
-- Backfill : reproduces getCategory() EXACTLY, including its order of
--             evaluation, which matters -- 'sla' is tested before 'task', so
--             wf.sla_reminder is SLA and not Task; 'escalat' is tested before
--             'clarif' etc. Every existing row therefore keeps the category the
--             UI already shows it with. Nothing moves on the day this deploys;
--             the change is that from now on a human can override it.
--
-- Not done here : timesheet.hr_review is deliberately left as General. Setting
--             it to Task from this migration would prove nothing about whether
--             the new control works -- same reasoning as 753 leaving the step
--             binding to the UI.
--
-- Permission : none added. The column lives on a table already governed by
--             wf_notification_config.edit, and this is wording metadata, not a
--             binding.
--
-- Depends on : 427030 (the table), 519250 / 604 (the codes being categorised)

-- ── 1. The column ────────────────────────────────────────────────────────────
ALTER TABLE public.workflow_notification_templates
  ADD COLUMN IF NOT EXISTS category text;

-- Nullable during backfill, constrained after. The CHECK deliberately does NOT
-- carry a DEFAULT: a template created without a category should be caught by
-- the NOT NULL below, not silently filed as General by the database.
DO $ck$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conname = 'workflow_notification_templates_category_chk'
  ) THEN
    ALTER TABLE public.workflow_notification_templates
      ADD CONSTRAINT workflow_notification_templates_category_chk
      CHECK (category IN ('task','sla','approval','returned','admin','general'));
  END IF;
END
$ck$;


-- ── 2. Backfill, mirroring getCategory() branch for branch ───────────────────
-- Written as a single CASE in the same order as the TypeScript. If that
-- function is ever changed, this migration is the record of what it said on
-- 20 Aug 2026 -- which is the point: after this, the function stops being the
-- source of truth for existing rows.
UPDATE public.workflow_notification_templates
SET    category =
         CASE
           WHEN code LIKE '%sla%'                                    THEN 'sla'
           WHEN code LIKE '%task%'      OR code LIKE '%reassign%'    THEN 'task'
           WHEN code LIKE '%force%'     OR code LIKE '%admin%'
             OR code LIKE '%escalat%'                                THEN 'admin'
           WHEN code LIKE '%reject%'    OR code LIKE '%return%'
             OR code LIKE '%withdraw%'  OR code LIKE '%declin%'
             OR code LIKE '%clarif%'                                 THEN 'returned'
           WHEN code LIKE '%complet%'   OR code LIKE '%approv%'
             OR code LIKE '%advanced%'  OR code LIKE '%submit%'
             OR code LIKE '%resubmit%'                               THEN 'approval'
           ELSE 'general'
         END
WHERE  category IS NULL;

ALTER TABLE public.workflow_notification_templates
  ALTER COLUMN category SET NOT NULL;

COMMENT ON COLUMN public.workflow_notification_templates.category IS
  'How this template files in the Notifications list and its filter tabs. '
  'Backfilled on 20 Aug 2026 from the substring rules the UI used until then, '
  'so no row moved on deploy. Editable from that screen since: a code is an '
  'identifier, and what a message means is a separate fact.';


-- ── Assertions ───────────────────────────────────────────────────────────────
-- The failure worth catching is a row landing outside the six values, or the
-- backfill silently matching nothing because the LIKE patterns were mistyped --
-- which would look like success and quietly file the whole table as General.
DO $chk$
DECLARE
  v_null    int;
  v_general int;
  v_total   int;
BEGIN
  SELECT count(*) INTO v_total FROM workflow_notification_templates;

  SELECT count(*) INTO v_null
  FROM   workflow_notification_templates
  WHERE  category IS NULL;

  IF v_null > 0 THEN
    RAISE EXCEPTION 'mig 756 assert: % template(s) left without a category', v_null;
  END IF;

  SELECT count(*) INTO v_general
  FROM   workflow_notification_templates
  WHERE  category = 'general';

  -- On any environment carrying the standard wf.* set, General is a small
  -- minority. If nearly everything landed there the CASE did not match.
  IF v_total > 5 AND v_general > (v_total * 0.6) THEN
    RAISE EXCEPTION
      'mig 756 assert: % of % templates filed as general — backfill did not match',
      v_general, v_total;
  END IF;

  RAISE NOTICE 'mig 756: % template(s) categorised, % general', v_total, v_general;
END
$chk$;
