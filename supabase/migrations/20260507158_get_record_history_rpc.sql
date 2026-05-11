-- =============================================================================
-- Migration 158: get_record_history() SECURITY DEFINER RPC
--
-- PURPOSE
-- ───────
-- Provides contextual audit history for individual records without requiring
-- users to hold sys_audit_log.view. Access is enforced inside the function
-- using the same rules as each domain's own RLS policies.
--
-- DESIGN
-- ──────
-- audit_log is SECURITY DEFINER-written and RLS-protected. The existing
-- SELECT policy grants:
--   • user_id = auth.uid()            — own actions only
--   • sys_audit_log.view              — full admin access
--   • sec_role_assignments.view       — role change history
--
-- For contextual history (e.g. "who changed this employee profile"), the
-- relevant audit rows have user_id = the actor (e.g. an HR admin), not the
-- viewer. Those rows are invisible to the viewer under the current RLS.
--
-- This function bypasses RLS on audit_log (SECURITY DEFINER) but enforces
-- domain-level access control internally — the caller must be able to VIEW
-- the record in question before they can see its history.
--
-- DOMAIN ACCESS RULES
-- ───────────────────
--   sys_audit_log.view   → bypasses all domain checks (central admin)
--   expense_report        → own report OR user_can('expense_reports','view',id)
--   profile / employee    → own profile OR user_can('hr_employees','view',NULL)
--   workflow_instance     → submitter OR assigned approver OR wf_manage.view
--   workflow_pending_ch.  → submitter OR assigned approver OR wf_manage.view
--   user_roles /
--   permission_set_*      → sec_role_assignments.view OR sec_permission_matrix.view
--   (unknown entity)      → denied — extend CASE as new domains are audited
--
-- RETURNS
-- ───────
-- Ordered newest-first:
--   id, action, changed_by (uuid), changed_at, metadata, actor_name (full_name)
-- =============================================================================


CREATE OR REPLACE FUNCTION get_record_history(
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS TABLE (
  id          uuid,
  action      text,
  changed_by  uuid,
  changed_at  timestamptz,
  metadata    jsonb,
  actor_name  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid        uuid    := auth.uid();
  v_has_access boolean := false;
BEGIN

  -- ── Auth guard ─────────────────────────────────────────────────────────────
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- ── sys_audit_log.view bypasses all domain checks ──────────────────────────
  IF user_can('sys_audit_log', 'view', NULL) THEN
    v_has_access := true;

  ELSE
    CASE p_entity_type

      -- Expense reports: own report OR expense view permission (Path D)
      WHEN 'expense_report', 'expense_reports' THEN
        SELECT EXISTS (
          SELECT 1 FROM expense_reports er
          WHERE  er.id = p_entity_id
            AND  (er.submitted_by = v_uid
                  OR user_can('expense_reports', 'view', p_entity_id))
        ) INTO v_has_access;

      -- Profiles / employees: own profile OR HR employee view
      WHEN 'profile', 'profiles', 'employee', 'employees' THEN
        v_has_access := (p_entity_id = v_uid)
                     OR user_can('hr_employees', 'view', NULL);

      -- Workflow instances: submitter OR assigned approver OR wf_manage.view
      WHEN 'workflow_instance', 'workflow_instances' THEN
        SELECT EXISTS (
          SELECT 1 FROM workflow_instances wi
          WHERE  wi.id = p_entity_id
            AND  (wi.submitted_by = v_uid
                  OR user_can('wf_manage', 'view', NULL)
                  OR EXISTS (
                    SELECT 1 FROM workflow_tasks wt
                    WHERE  wt.instance_id = wi.id
                      AND  wt.assigned_to  = v_uid
                  ))
        ) INTO v_has_access;

      -- Pending changes: same visibility pattern as workflow instances
      WHEN 'workflow_pending_change', 'workflow_pending_changes' THEN
        SELECT EXISTS (
          SELECT 1 FROM workflow_pending_changes wpc
          WHERE  wpc.id = p_entity_id
            AND  (wpc.submitted_by = v_uid
                  OR user_can('wf_manage', 'view', NULL)
                  OR EXISTS (
                    SELECT 1 FROM workflow_tasks wt
                    WHERE  wt.instance_id = wpc.instance_id
                      AND  wt.assigned_to  = v_uid
                  ))
        ) INTO v_has_access;

      -- Security tables: role assignment or permission matrix admins
      WHEN 'user_roles', 'permission_set_assignments', 'permission_set_items' THEN
        v_has_access := user_can('sec_role_assignments',  'view', NULL)
                     OR user_can('sec_permission_matrix', 'view', NULL);

      -- Unknown entity type — deny by default.
      -- Extend this CASE as new domains are added to audit_log.
      ELSE
        v_has_access := false;

    END CASE;
  END IF;

  -- ── Access denied ──────────────────────────────────────────────────────────
  IF NOT v_has_access THEN
    RAISE EXCEPTION 'Access denied to audit history for % / %',
      p_entity_type, p_entity_id
      USING ERRCODE = '42501';
  END IF;

  -- ── Return history newest-first ────────────────────────────────────────────
  RETURN QUERY
  SELECT
    al.id,
    al.action,
    al.user_id                        AS changed_by,
    al.created_at                     AS changed_at,
    al.metadata,
    COALESCE(p.full_name, 'System')   AS actor_name
  FROM  audit_log al
  LEFT  JOIN profiles p ON p.id = al.user_id
  WHERE al.entity_type = p_entity_type
    AND al.entity_id   = p_entity_id
  ORDER BY al.created_at DESC;

END;
$$;

-- Grant execute to authenticated users only — anon cannot call this.
REVOKE ALL    ON FUNCTION get_record_history(text, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_record_history(text, uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT routine_name, routine_type, security_type
FROM   information_schema.routines
WHERE  routine_name = 'get_record_history'
  AND  routine_schema = 'public';

-- =============================================================================
-- END OF MIGRATION 158
-- =============================================================================
