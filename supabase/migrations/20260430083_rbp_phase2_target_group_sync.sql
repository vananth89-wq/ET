-- =============================================================================
-- Migration 083: RBP Phase 2 — Target Group Member Cache + pg_cron
--
-- WHAT THIS DOES
-- ══════════════
-- 1. sync_target_group_members()
--    Rebuilds the target_group_members cache in a single truncate-and-insert
--    pass.  Called by pg_cron every 15 min and can be triggered manually.
--
--    Cache strategy per scope_type:
--    ┌─────────────────┬──────────────────────────────────────────────────┐
--    │ everyone        │ Populated here — all active employees.           │
--    │                 │ user_can() Path D: tgm.member_id = p_owner ✓    │
--    ├─────────────────┼──────────────────────────────────────────────────┤
--    │ self            │ NOT cached. Handled entirely by Path C           │
--    │                 │ (self short-circuit before Path D runs).         │
--    │                 │ Caching would create a security hole: any user   │
--    │                 │ in Path D could match another employee's record. │
--    ├─────────────────┼──────────────────────────────────────────────────┤
--    │ direct_l1       │ NOT cached. user_can() Path D does a LIVE        │
--    │ direct_l2       │ employees.manager_id check instead.              │
--    │                 │ A flat cache cannot carry per-manager context.   │
--    ├─────────────────┼──────────────────────────────────────────────────┤
--    │ same_department │ NOT cached. user_can() does a LIVE dept_id check.│
--    │ same_country    │ NOT cached. user_can() does a LIVE country check.│
--    ├─────────────────┼──────────────────────────────────────────────────┤
--    │ custom          │ Reserved. Extend this function to populate based │
--    │                 │ on filter_rules jsonb when needed.               │
--    └─────────────────┴──────────────────────────────────────────────────┘
--
-- 2. pg_cron: every 15 minutes.
-- 3. Initial backfill on migration run.
-- 4. Logs each run to job_run_log.
--
-- WHY NOT CACHE direct_l1/direct_l2?
-- ═══════════════════════════════════
-- A single flat (group_id, member_id) row cannot encode "member E is a direct
-- report of manager M specifically".  Caching ALL subordinates would allow
-- every manager to see every non-root employee's records — equivalent to
-- 'everyone'.  The live employees.manager_id lookup is fast (indexed, tiny
-- table) and produces the correct manager-scoped result.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. sync_target_group_members()
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sync_target_group_members()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start   timestamptz := clock_timestamp();
  v_rows    int         := 0;
  v_err     text;
BEGIN
  -- ── Truncate first (cache is always rebuilt in full) ──────────────────────
  TRUNCATE target_group_members;

  -- ── everyone → all active, non-deleted employees ─────────────────────────
  -- This is the only scope type that uses the pre-computed cache.
  -- All other scopes (direct_l1, direct_l2, same_department, same_country)
  -- are resolved by LIVE queries inside user_can() Path D.
  INSERT INTO target_group_members (group_id, member_id)
  SELECT tg.id, e.id
  FROM   target_groups tg
  CROSS  JOIN employees e
  WHERE  tg.scope_type = 'everyone'
    AND  e.deleted_at  IS NULL
    AND  e.status      = 'Active'
  ON CONFLICT DO NOTHING;

  -- ── custom → stub; extend here when filter_rules logic is needed ──────────
  -- INSERT INTO target_group_members (group_id, member_id)
  -- ... parse tg.filter_rules jsonb per group ...

  -- ── Row count for logging ─────────────────────────────────────────────────
  SELECT count(*) INTO v_rows FROM target_group_members;

  -- ── Write success record to job_run_log ───────────────────────────────────
  INSERT INTO job_run_log (
    job_code, job_name, started_at, completed_at, status, rows_processed, error_message
  )
  VALUES (
    'sync_target_group_members',
    'Sync Target Group Members',
    v_start,
    clock_timestamp(),
    'success',
    v_rows,
    NULL
  );

EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;

  INSERT INTO job_run_log (
    job_code, job_name, started_at, completed_at, status, rows_processed, error_message
  )
  VALUES (
    'sync_target_group_members',
    'Sync Target Group Members',
    v_start,
    clock_timestamp(),
    'failed',
    0,
    v_err
  );

  RAISE;
END;
$$;

COMMENT ON FUNCTION sync_target_group_members() IS
  'Rebuilds target_group_members cache. Only populates ''everyone'' scope; '
  'direct_l1/direct_l2/same_department/same_country use live employee lookups '
  'in user_can() instead. Called by pg_cron every 15 min.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. pg_cron schedule (idempotent — unschedule first)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT cron.unschedule('sync_target_group_members')
WHERE  EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'sync_target_group_members'
);

SELECT cron.schedule(
  'sync_target_group_members',
  '*/15 * * * *',
  'SELECT sync_target_group_members()'
);


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Initial backfill
-- ─────────────────────────────────────────────────────────────────────────────

SELECT sync_target_group_members();


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'target_group_members after initial sync' AS check,
  tg.code,
  tg.scope_type,
  count(tgm.member_id) AS member_count
FROM   target_groups             tg
LEFT   JOIN target_group_members tgm ON tgm.group_id = tg.id
GROUP  BY tg.code, tg.scope_type
ORDER  BY tg.code;

-- Expect: everyone → N rows (all active employees), all other groups → 0

SELECT 'pg_cron job registered' AS check,
  jobname, schedule, command
FROM   cron.job
WHERE  jobname = 'sync_target_group_members';
