-- =============================================================================
-- Migration 143: Audit triggers — user_roles, permission_set_assignments,
--                                 permission_set_items
--
-- DESIGN
-- ══════
-- Three SECURITY DEFINER trigger functions write to audit_log whenever role
-- assignments or permission-set contents change.  SECURITY DEFINER is used so
-- that auth.uid() is available inside the trigger even though the trigger runs
-- in the security context of the calling user (which may itself be a SECURITY
-- DEFINER function like sync_system_roles).
--
-- entity_id mapping
-- ─────────────────
-- user_roles                — no standalone id column; entity_id = profile_id
--                             (the user whose role changed); role_id in metadata
-- permission_set_assignments — has an id uuid PK; entity_id = id
-- permission_set_items       — no standalone id; entity_id = permission_set_id;
--                             permission_id in metadata
--
-- audit_log columns used
-- ───────────────────────
--   action       text  — namespaced verb  e.g. 'user_role.assigned'
--   entity_type  text  — table name       e.g. 'user_roles'
--   entity_id    uuid
--   user_id      uuid  — auth.uid() at time of change
--   metadata     jsonb — full row snapshot
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. user_roles audit trigger
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_audit_user_roles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action  text;
  v_row     jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'user_role.assigned';
    v_row    := to_jsonb(NEW);
  ELSIF TG_OP = 'UPDATE' THEN
    v_action := 'user_role.updated';
    v_row    := to_jsonb(NEW);
  ELSE
    v_action := 'user_role.removed';
    v_row    := to_jsonb(OLD);
  END IF;

  INSERT INTO audit_log (user_id, action, entity_type, entity_id, metadata)
  VALUES (
    auth.uid(),
    v_action,
    'user_roles',
    (v_row->>'profile_id')::uuid,   -- entity = the user whose role changed
    v_row
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION trg_audit_user_roles() IS
  'Writes an audit_log row for every INSERT, UPDATE, or DELETE on user_roles. '
  'entity_id = profile_id; full row snapshot in metadata.';

DROP TRIGGER IF EXISTS audit_user_roles ON user_roles;
CREATE TRIGGER audit_user_roles
  AFTER INSERT OR UPDATE OR DELETE ON user_roles
  FOR EACH ROW EXECUTE FUNCTION trg_audit_user_roles();


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. permission_set_assignments audit trigger
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_audit_psa()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action  text;
  v_row     jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'permission_set_assignment.created';
    v_row    := to_jsonb(NEW);
  ELSE
    v_action := 'permission_set_assignment.removed';
    v_row    := to_jsonb(OLD);
  END IF;

  INSERT INTO audit_log (user_id, action, entity_type, entity_id, metadata)
  VALUES (
    auth.uid(),
    v_action,
    'permission_set_assignments',
    (v_row->>'id')::uuid,
    v_row
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION trg_audit_psa() IS
  'Writes an audit_log row for every INSERT or DELETE on permission_set_assignments.';

DROP TRIGGER IF EXISTS audit_permission_set_assignments ON permission_set_assignments;
CREATE TRIGGER audit_permission_set_assignments
  AFTER INSERT OR DELETE ON permission_set_assignments
  FOR EACH ROW EXECUTE FUNCTION trg_audit_psa();


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. permission_set_items audit trigger
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_audit_psi()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action  text;
  v_row     jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'permission_set_item.added';
    v_row    := to_jsonb(NEW);
  ELSE
    v_action := 'permission_set_item.removed';
    v_row    := to_jsonb(OLD);
  END IF;

  -- permission_set_items has no standalone id column.
  -- Use permission_set_id as entity_id; permission_id captured in metadata.
  INSERT INTO audit_log (user_id, action, entity_type, entity_id, metadata)
  VALUES (
    auth.uid(),
    v_action,
    'permission_set_items',
    (v_row->>'permission_set_id')::uuid,
    v_row
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION trg_audit_psi() IS
  'Writes an audit_log row for every INSERT or DELETE on permission_set_items. '
  'entity_id = permission_set_id (no standalone id column on this table); '
  'permission_id is captured in the metadata jsonb.';

DROP TRIGGER IF EXISTS audit_permission_set_items ON permission_set_items;
CREATE TRIGGER audit_permission_set_items
  AFTER INSERT OR DELETE ON permission_set_items
  FOR EACH ROW EXECUTE FUNCTION trg_audit_psi();


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  trigger_name,
  event_object_table AS "table",
  action_timing      AS timing,
  string_agg(event_manipulation, ' OR ' ORDER BY event_manipulation) AS events
FROM information_schema.triggers
WHERE trigger_name IN (
  'audit_user_roles',
  'audit_permission_set_assignments',
  'audit_permission_set_items'
)
GROUP BY trigger_name, event_object_table, action_timing
ORDER BY event_object_table;

-- =============================================================================
-- END OF MIGRATION 143
-- =============================================================================
