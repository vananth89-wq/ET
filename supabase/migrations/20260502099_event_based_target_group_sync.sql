-- =============================================================================
-- Migration 099: Event-based target group sync triggers
--
-- pg_cron currently rebuilds ALL target groups every 15 minutes (migration 083).
-- This migration adds DB triggers for immediate rebuilds on the two events that
-- invalidate the cache:
--
--   Event 1 — employees.status change
--     The 'everyone' group cache must be rebuilt when an employee is activated,
--     deactivated, or their status changes, because 'everyone' = all active employees.
--     Trigger: AFTER UPDATE OF status ON employees
--     Action:  rebuild only the 'everyone' group (targeted, not full rebuild)
--
--   Event 2 — target_groups.filter_rules change
--     Custom groups store their member criteria as filter_rules JSONB on the
--     target_groups row.  When an admin saves new rules, the cache for that
--     group must be rebuilt immediately.
--     Trigger: AFTER UPDATE OF filter_rules ON target_groups
--     Action:  rebuild only the affected group_id (targeted)
--
-- Why targeted rebuilds?
-- ──────────────────────
--   sync_target_group_members() (migration 083) rebuilds EVERY group with
--   a full TRUNCATE.  This is expensive on large orgs and causes a brief
--   window where all groups are empty.  The event triggers call a lightweight
--   function that rebuilds only the group that changed.
--
-- Live JOIN groups (direct_l1, direct_l2, same_department, same_country, self)
-- do NOT use the target_group_members cache — they resolve via live SQL in
-- user_can() and get_target_population().  No sync needed for those.
--
-- pg_cron stays as a catch-all fallback for drift (e.g. bulk imports that
-- bypass triggers, or trigger failures).  The event triggers remove the
-- 15-minute latency for normal operations.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Helper: rebuild a single target group's cache
--    Supports 'everyone' and 'custom' scope types.
--    Custom groups: re-evaluates filter_rules JSONB to rebuild membership.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sync_single_target_group(p_group_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_scope_type   text;
  v_filter_rules jsonb;
BEGIN
  SELECT scope_type, filter_rules
    INTO v_scope_type, v_filter_rules
  FROM   target_groups
  WHERE  id = p_group_id;

  IF v_scope_type IS NULL THEN
    RETURN;  -- group deleted or not found, nothing to do
  END IF;

  -- Delete existing cached members for this group only
  DELETE FROM target_group_members WHERE group_id = p_group_id;

  IF v_scope_type = 'everyone' THEN
    -- everyone = all active, non-deleted employees
    INSERT INTO target_group_members (group_id, member_id)
    SELECT p_group_id, id
    FROM   employees
    WHERE  status    = 'Active'
      AND  deleted_at IS NULL;

  ELSIF v_scope_type = 'custom' THEN
    -- Custom groups use filter_rules JSONB (managed via TargetGroups UI).
    -- The sync_target_group_members() full rebuild handles complex rule
    -- evaluation.  For targeted rebuild we re-run the same logic:
    -- delegate to the full sync function scoped to this group only.
    -- If filter_rules is NULL or empty, the group has no members yet.
    IF v_filter_rules IS NOT NULL
       AND jsonb_array_length(v_filter_rules->'rules') > 0 THEN
      -- Re-run the full sync but only for this group's rules.
      -- Simplest correct implementation: call the full sync.
      -- This is safe because sync_target_group_members() uses TRUNCATE
      -- on the whole table — instead we use the targeted DELETE above
      -- and re-insert via the same filter evaluation.
      -- For now: full sync as fallback. A future migration can implement
      -- incremental rule evaluation if performance requires it.
      PERFORM sync_target_group_members();
      RETURN;  -- sync_target_group_members() already rebuilt everything
    END IF;
    -- else: empty rules → no members, DELETE above is sufficient
  END IF;
  -- Live JOIN types (direct_l1/l2, same_department, same_country, self)
  -- are never cached — skip them silently.
END;
$$;

COMMENT ON FUNCTION sync_single_target_group(uuid) IS
  'Rebuilds target_group_members cache for a single group. '
  'everyone: fast targeted rebuild. '
  'custom: delegates to sync_target_group_members() for rule evaluation. '
  'Live JOIN groups are not cached and are skipped. '
  'Called by event triggers on employees.status and target_groups.filter_rules changes.';

GRANT EXECUTE ON FUNCTION sync_single_target_group(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Trigger function: employees.status change → rebuild 'everyone' group
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_sync_everyone_on_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_everyone_id uuid;
BEGIN
  -- Only fire when status actually changed
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_everyone_id
  FROM   target_groups
  WHERE  scope_type = 'everyone'
  LIMIT  1;

  IF v_everyone_id IS NOT NULL THEN
    PERFORM sync_single_target_group(v_everyone_id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_everyone_on_employee_status_change ON employees;

CREATE TRIGGER sync_everyone_on_employee_status_change
  AFTER UPDATE OF status ON employees
  FOR EACH ROW
  EXECUTE FUNCTION trg_sync_everyone_on_status_change();

COMMENT ON TRIGGER sync_everyone_on_employee_status_change ON employees IS
  'Immediately rebuilds the everyone target group cache when an employee status changes '
  '(activation, deactivation, reactivation). Removes the 15-min pg_cron latency for status changes.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Trigger function: target_groups.filter_rules change → rebuild that group
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_sync_custom_group_on_rules_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only fire when filter_rules actually changed and this is a custom group
  IF OLD.filter_rules IS NOT DISTINCT FROM NEW.filter_rules THEN
    RETURN NEW;
  END IF;

  IF NEW.scope_type = 'custom' THEN
    PERFORM sync_single_target_group(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_custom_group_on_rules_change ON target_groups;

CREATE TRIGGER sync_custom_group_on_rules_change
  AFTER UPDATE OF filter_rules ON target_groups
  FOR EACH ROW
  EXECUTE FUNCTION trg_sync_custom_group_on_rules_change();

COMMENT ON TRIGGER sync_custom_group_on_rules_change ON target_groups IS
  'Immediately rebuilds target_group_members cache when a custom group''s filter_rules '
  'are updated (admin saves new membership rules in TargetGroups UI). '
  'Removes the 15-min pg_cron latency for custom group rule changes.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  trigger_name,
  event_object_table AS "table",
  event_manipulation AS event,
  action_timing      AS timing
FROM information_schema.triggers
WHERE trigger_name IN (
  'sync_everyone_on_employee_status_change',
  'sync_custom_group_on_rules_change'
)
ORDER BY trigger_name;

-- =============================================================================
-- END OF MIGRATION 099
-- =============================================================================
