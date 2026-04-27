-- =============================================================================
-- Role Architecture — Phase D+E: Drop profile_roles and role_type enum
--
-- MUST run after Phase C (has_role() no longer reads profile_roles).
-- Development only — skips the monitor window, drops immediately.
-- =============================================================================


-- ── Phase D: Quick parity check before dropping ───────────────────────────────
-- Every profile that had a profile_roles entry should now have a matching
-- user_roles entry. Rows returned here = gaps (investigate before proceeding).

DO $$
DECLARE
  gap_count integer;
BEGIN
  SELECT COUNT(*) INTO gap_count
  FROM profile_roles pr
  LEFT JOIN user_roles ur
    ON  ur.profile_id = pr.profile_id
    AND ur.is_active  = true
    AND ur.role_id IN (
      SELECT id FROM roles WHERE code = CASE pr.role::text
        WHEN 'admin'     THEN 'admin'
        WHEN 'finance'   THEN 'finance'
        WHEN 'hr'        THEN 'hr'
        WHEN 'manager'   THEN 'manager'
        WHEN 'dept_head' THEN 'dept_head'
        WHEN 'mss'       THEN 'mss'
        WHEN 'employee'  THEN 'ess'
      END
    )
  WHERE ur.id IS NULL;

  IF gap_count > 0 THEN
    RAISE NOTICE '% profile_roles rows have no user_roles match — backfilling now.', gap_count;

    -- Auto-fix: re-run backfill for any gaps
    INSERT INTO user_roles (profile_id, role_id, granted_by, is_active, assignment_source)
    SELECT
      pr.profile_id,
      r.id,
      pr.assigned_by,
      true,
      CASE WHEN r.is_system THEN 'system' ELSE 'manual' END
    FROM profile_roles pr
    JOIN roles r ON r.code = CASE pr.role::text
      WHEN 'admin'     THEN 'admin'
      WHEN 'finance'   THEN 'finance'
      WHEN 'hr'        THEN 'hr'
      WHEN 'manager'   THEN 'manager'
      WHEN 'dept_head' THEN 'dept_head'
      WHEN 'mss'       THEN 'mss'
      WHEN 'employee'  THEN 'ess'
    END
    WHERE r.id IS NOT NULL
    ON CONFLICT (profile_id, role_id) DO NOTHING;

    RAISE NOTICE 'Backfill complete.';
  ELSE
    RAISE NOTICE 'Parity check passed — all profile_roles have matching user_roles rows.';
  END IF;
END;
$$;


-- ── Phase E: Drop legacy sync trigger (from previous migration attempt) ────────
DROP TRIGGER IF EXISTS trg_sync_user_roles_to_profile_roles ON user_roles;
DROP FUNCTION IF EXISTS sync_user_roles_to_profile_roles();
DROP FUNCTION IF EXISTS map_role_code_to_type(text);


-- ── Phase E: Drop profile_roles table ────────────────────────────────────────
-- Policies were already dropped in Phase C (DROP ALL POLICIES block).
-- The table has no dependents after the policy drop.

DROP TABLE IF EXISTS profile_roles CASCADE;


-- ── Phase E: Drop role_type enum ─────────────────────────────────────────────
-- profile_roles was the only table using this enum as a column type.
-- Drop the old enum-signature functions first (Phase C replaced them with
-- text-signature versions; these old ones are the only remaining dependents).

DROP FUNCTION IF EXISTS has_role(role_type);
DROP FUNCTION IF EXISTS has_any_role(role_type[]);

DROP TYPE IF EXISTS role_type CASCADE;


-- ── Final verification ────────────────────────────────────────────────────────

SELECT
  r.code,
  r.name,
  r.role_type,
  r.active,
  r.sort_order,
  COUNT(ur.id) FILTER (WHERE ur.is_active = true) AS active_members
FROM roles r
LEFT JOIN user_roles ur ON ur.role_id = r.id
GROUP BY r.id, r.code, r.name, r.role_type, r.active, r.sort_order
ORDER BY r.sort_order;
