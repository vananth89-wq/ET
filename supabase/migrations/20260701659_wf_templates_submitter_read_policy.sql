-- Migration 659 — workflow_templates: submitter read policy for vw_wf_my_requests
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM
-- ───────
-- vw_wf_my_requests (mig 592) has security_invoker = true and:
--   JOIN workflow_templates tpl ON tpl.id = wi.template_id
-- This INNER JOIN fires the wf_templates_select RLS policy (mig 153):
--   user_can('wf_templates', 'view', NULL)
-- Regular employees who submit workflow requests (self-service profile changes,
-- hire initiation, etc.) do NOT have wf_templates.view. With security_invoker
-- = true the JOIN produces no rows → "My Requests" shows 0 items for everyone
-- who is not a Workflow Admin.
--
-- Mig 658 added wf_templates_assignee_read for approvers (vw_wf_pending_tasks).
-- This migration adds the symmetric policy for submitters (vw_wf_my_requests).
--
-- FIX
-- ───
-- 1. SECURITY DEFINER helper is_wf_template_submitter(p_template_id):
--    Checks workflow_instances for a row where submitted_by = auth.uid()
--    without triggering RLS recursion.
-- 2. New SELECT policy wf_templates_submitter_read on workflow_templates:
--    USING (is_wf_template_submitter(id))
--    PostgreSQL ORs all SELECT policies — admin path (wf_templates_select)
--    and assignee path (wf_templates_assignee_read, mig 658) are unchanged.

-- ── 1. SECURITY DEFINER helper ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION is_wf_template_submitter(p_template_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_instances wi
    WHERE  wi.template_id  = p_template_id
      AND  wi.submitted_by = auth.uid()
  );
$$;

COMMENT ON FUNCTION is_wf_template_submitter(uuid) IS
  'Returns true if auth.uid() has submitted a workflow instance that uses '
  'the given template. SECURITY DEFINER — bypasses RLS on workflow_instances '
  'to avoid recursive policy evaluation. Used by wf_templates_submitter_read '
  'SELECT policy (mig 659). Counterpart to is_wf_template_assignee (mig 658).';


-- ── 2. New SELECT policy: submitter can read their template ───────────────────

CREATE POLICY "wf_templates_submitter_read" ON workflow_templates
  FOR SELECT
  USING (is_wf_template_submitter(workflow_templates.id));

COMMENT ON POLICY "wf_templates_submitter_read" ON workflow_templates IS
  'Allows a user to read a workflow template when they have submitted an '
  'instance using it. Enables vw_wf_my_requests (security_invoker=true) to '
  'JOIN workflow_templates without dropping rows. Mig 659. '
  'Complements wf_templates_select (admin) and wf_templates_assignee_read (mig 658).';


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT policyname, cmd
FROM   pg_policies
WHERE  tablename  = 'workflow_templates'
  AND  schemaname = 'public'
ORDER  BY policyname;

-- Expected: three SELECT policies:
--   wf_templates_assignee_read  | SELECT   (mig 658)
--   wf_templates_select         | SELECT   (mig 153, admin only)
--   wf_templates_submitter_read | SELECT   (mig 659)
