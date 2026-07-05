-- Migration 658 — workflow_templates: approver assignee SELECT policy
-- ─────────────────────────────────────────────────────────────────────
-- ROOT CAUSE
-- ──────────
-- mig 592 added security_invoker = true to vw_wf_pending_tasks, which means
-- RLS on every joined table fires as the querying user.
--
-- workflow_templates SELECT (mig 153) is gated on:
--   user_can('wf_templates', 'view', NULL)
-- This is a Workflow Admin permission. Regular approvers (e.g. HR Analysts)
-- do not have it. The view has:
--   JOIN workflow_templates tpl ON tpl.id = wi.template_id
-- With security_invoker = true, this INNER JOIN silently drops all task rows
-- for users who cannot read workflow_templates → inbox shows 0 tasks.
--
-- NOTE: mig 169 fixed the identical problem for workflow_steps by adding
-- a second SELECT policy (wf_steps_assignee_read). This migration applies
-- the same pattern to workflow_templates.
--
-- FIX
-- ───
-- 1. SECURITY DEFINER helper is_wf_template_assignee(p_template_id):
--    Checks workflow_tasks + workflow_instances without triggering their RLS
--    policies (same rationale as is_wf_task_assignee, mig 174).
-- 2. New SELECT policy wf_templates_assignee_read on workflow_templates:
--    USING (is_wf_template_assignee(id))
--    PostgreSQL evaluates multiple SELECT policies with OR — a row is visible
--    if ANY policy permits it. The existing wf_templates_select (admin path)
--    is unchanged.

-- ── 1. SECURITY DEFINER helper ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION is_wf_template_assignee(p_template_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_tasks    wt
    JOIN   workflow_instances wi ON wi.id = wt.instance_id
    WHERE  wi.template_id = p_template_id
      AND  wt.assigned_to = auth.uid()
  );
$$;

COMMENT ON FUNCTION is_wf_template_assignee(uuid) IS
  'Returns true if auth.uid() has any pending task on an instance that uses '
  'the given workflow template. SECURITY DEFINER — bypasses RLS on '
  'workflow_tasks / workflow_instances to avoid recursive policy evaluation. '
  'Used by wf_templates_assignee_read SELECT policy (mig 658).';


-- ── 2. New SELECT policy: approver can read their assigned template ───────────

CREATE POLICY "wf_templates_assignee_read" ON workflow_templates
  FOR SELECT
  USING (is_wf_template_assignee(workflow_templates.id));

COMMENT ON POLICY "wf_templates_assignee_read" ON workflow_templates IS
  'Allows an approver to read a workflow template when they have a pending '
  'task on an instance that uses it. Complements wf_templates_select (admin). '
  'Mig 658. Mirrors the wf_steps_assignee_read pattern from mig 169.';


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT policyname, cmd, qual
FROM   pg_policies
WHERE  tablename  = 'workflow_templates'
  AND  schemaname = 'public'
ORDER  BY policyname;

-- Expected: two SELECT policies:
--   wf_templates_assignee_read  | SELECT | is_wf_template_assignee(id)
--   wf_templates_select         | SELECT | user_can('wf_templates','view',NULL)
