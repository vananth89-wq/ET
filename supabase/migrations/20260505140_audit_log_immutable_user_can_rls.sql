-- =============================================================================
-- Migration 140: audit_log — immutability enforcement + user_can() RLS
--
-- TWO GOALS
-- ─────────
-- 1. Replace has_role('admin') in SELECT / UPDATE / DELETE policies with
--    user_can('sys_audit_log', 'view', NULL) and enforce true immutability.
-- 2. Make the table genuinely append-only by adding BEFORE triggers that
--    RAISE EXCEPTION on any UPDATE or DELETE attempt — even by superusers
--    or SECURITY DEFINER functions. RLS alone is insufficient because
--    SECURITY DEFINER contexts bypass RLS.
--
-- CURRENT PROBLEMS
-- ────────────────
-- The table COMMENT says "Immutable — never UPDATE or DELETE rows" but the
-- RLS policies contradict this:
--   audit_log_update  → USING (has_role('admin'))
--   audit_log_delete  → USING (has_role('admin'))
-- These policies let admins silently tamper with audit history.
--
-- AFTER THIS MIGRATION
-- ────────────────────
--   SELECT  — own rows (user_id = auth.uid()) OR sys_audit_log.view
--   INSERT  — any authenticated user (frontend writes directly; user_id enforced at app layer)
--   UPDATE  — BLOCKED by trigger (RAISE EXCEPTION, not silent NOTHING)
--   DELETE  — BLOCKED by trigger (RAISE EXCEPTION, not silent NOTHING)
--   RLS UPDATE / DELETE policies — dropped (belt-and-suspenders with trigger)
-- =============================================================================


-- ── 1. Create sys_audit_log module ───────────────────────────────────────────

INSERT INTO modules (code, name, active, sort_order)
VALUES ('sys_audit_log', 'System Audit Log', true, 600)
ON CONFLICT (code) DO UPDATE
  SET name       = EXCLUDED.name,
      active     = EXCLUDED.active,
      sort_order = EXCLUDED.sort_order;


-- ── 2. Seed sys_audit_log.view permission ────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'sys_audit_log.view'                                              AS code,
  'View System Audit Log'                                           AS name,
  'Grants read access to the full system audit log'                 AS description,
  m.id                                                              AS module_id,
  'view'                                                            AS action
FROM modules m
WHERE m.code = 'sys_audit_log'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 3. Update RLS policies ────────────────────────────────────────────────────

DROP POLICY IF EXISTS audit_log_select ON audit_log;
DROP POLICY IF EXISTS audit_log_insert ON audit_log;
DROP POLICY IF EXISTS audit_log_update ON audit_log;
DROP POLICY IF EXISTS audit_log_delete ON audit_log;

-- Own rows always visible; admins with sys_audit_log.view see all.
CREATE POLICY audit_log_select ON audit_log FOR SELECT
  USING (
    user_id = auth.uid()
    OR user_can('sys_audit_log', 'view', NULL)
  );

-- INSERT open to any authenticated session.
-- user_id = auth.uid() is enforced at the application layer on insert.
CREATE POLICY audit_log_insert ON audit_log FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

-- No UPDATE or DELETE policies — intentionally omitted.
-- The triggers below enforce immutability at the engine level.


-- ── 4. Immutability triggers ──────────────────────────────────────────────────
-- Triggers fire BEFORE the operation and raise an exception, rolling back
-- the transaction. This cannot be bypassed by RLS-exempt roles or
-- SECURITY DEFINER functions — only a superuser dropping the trigger can override.

CREATE OR REPLACE FUNCTION fn_audit_log_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'audit_log is immutable — % operations are not permitted. '
    'Row id: %',
    TG_OP, OLD.id;
END;
$$;

COMMENT ON FUNCTION fn_audit_log_immutable() IS
  'Prevents any UPDATE or DELETE on audit_log. '
  'Called by trg_audit_log_no_update and trg_audit_log_no_delete.';

DROP TRIGGER IF EXISTS trg_audit_log_no_update ON audit_log;
CREATE TRIGGER trg_audit_log_no_update
  BEFORE UPDATE ON audit_log
  FOR EACH ROW
  EXECUTE FUNCTION fn_audit_log_immutable();

DROP TRIGGER IF EXISTS trg_audit_log_no_delete ON audit_log;
CREATE TRIGGER trg_audit_log_no_delete
  BEFORE DELETE ON audit_log
  FOR EACH ROW
  EXECUTE FUNCTION fn_audit_log_immutable();


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename = 'audit_log'
ORDER BY cmd, policyname;

SELECT trigger_name, event_manipulation, action_timing
FROM information_schema.triggers
WHERE event_object_table = 'audit_log'
ORDER BY trigger_name;

SELECT code, name, action
FROM   permissions
WHERE  code = 'sys_audit_log.view';
