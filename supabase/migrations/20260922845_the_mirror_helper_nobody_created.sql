-- =============================================================================
-- Migration 845 — the mirror helper two functions call and nobody created
--
-- WHAT IS WRONG
-- ═════════════
--   `sync_job_relationship_mirrors(uuid, uuid)` does not exist on Dev.
--
--     select ... from pg_proc where proname = 'sync_job_relationship_mirrors';
--     -> no rows
--
--   Two functions call it:
--
--     fn_apply_job_relationship_set_transition  -- the WORKFLOW-APPROVED path
--     wf_activate_employee                      -- mig 463, onboarding
--
--   Neither catches the failure, so both raise
--   `function sync_job_relationship_mirrors(uuid, uuid) does not exist` and the
--   whole transaction rolls back. In the transition function the call sits
--   behind `IF p_effective_from <= CURRENT_DATE AND <this is the latest set>`,
--   which is the ordinary case for an approved change -- so approving a job
--   relationship request has been failing since June. Nobody reported it
--   because nobody exercised that path; the direct HR edit goes through
--   fn_close_and_replace_job_relationship_set, which mirrors inline.
--
-- WHY IT IS MISSING
-- ═════════════════
--   Migration 461 creates it, at the top level of the file, and
--   supabase_migrations.schema_migrations lists 20260603461 as applied. Nothing
--   ever drops it. Two explanations fit:
--
--     * 461 aborted partway, leaving some objects created and others not --
--       the 710 pattern that the migration-replay check was written for; or
--     * 461 was edited after it had already been pushed, so the file now
--       describes objects the database was never asked to create.
--
--   Both are recorded failure modes in this repo. Which one it was does not
--   change the repair, but it does change the lesson: a migration file is not
--   evidence that its contents ran.
--
-- WHAT THIS MIGRATION CREATES
-- ═══════════════════════════
--   461's function with TWO changes, one of them mandatory.
--
--   THE MANDATORY ONE: 461's body reads
--   `MAX(CASE WHEN relationship_code = 'PM01' THEN manager_employee_id END)`.
--   There is no max(uuid) aggregate. That statement cannot run. CREATE FUNCTION
--   does not resolve names inside a plpgsql body, so 461's text creates
--   cleanly and raises `function max(uuid) does not exist` on first call --
--   meaning even a database where 461 DID apply has an outage here, just with a
--   different error. Six scalar subqueries replace it, the shape
--   admin_update_job_relationship_set already uses for these six columns.
--
--   THE SECOND: it skips items that have been removed. 835 added `removed_on` three months after 461 was written,
--   so 461's text reads soft-deleted assignments as live -- creating it
--   verbatim would mean mirroring a manager who is no longer one, and then
--   fixing it again in the next migration.
--
--   The comparison is against CURRENT_DATE, not `removed_on IS NULL`. An
--   assignment ended with a FUTURE date is still in force today and must still
--   be mirrored; blanking it early would tell the org chart somebody's manager
--   changed before they did. (835's own inline mirror uses the blunt
--   `removed_on IS NULL`. That is safe where it sits -- it only ever runs on
--   the active set at the moment of a change -- but it is not the general
--   rule, and 846 will align it.)
--
-- Depends on: 461 (the definition this restores), 835 (removed_on),
--             454/456 (fn_apply_job_relationship_set_transition), 463
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.sync_job_relationship_mirrors(
  p_employee_id uuid,
  p_set_id      uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pm01 uuid; v_pm02 uuid; v_pm03 uuid;
  v_om01 uuid; v_om02 uuid; v_om03 uuid;
BEGIN
  -- Read the 6 relationship codes from the given set.
  --
  -- NOT 461's `MAX(CASE WHEN ... THEN manager_employee_id END)`. There is no
  -- max(uuid) aggregate in PostgreSQL, so that statement raises
  -- `function max(uuid) does not exist` the first time it runs. CREATE FUNCTION
  -- does not resolve names inside a plpgsql body, so 461's text creates
  -- cleanly and fails only on the first call -- which is why restoring it
  -- verbatim would have restored the outage under a different message. Found
  -- by CALLING it in this migration's own verification.
  --
  -- Six scalar subqueries instead: the shape admin_update_job_relationship_set
  -- already uses for the same six columns.
  --
  -- MIG 845: `removed_on` did not exist when 461 wrote this. An assignment
  -- ended on or before today is not a current manager and must not be
  -- mirrored; one ended with a future date still is, until that date arrives.
  SELECT
    (SELECT i.manager_employee_id FROM employee_job_relationship_item i
      WHERE i.set_id = p_set_id AND i.relationship_code = 'PM01'
        AND (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE) LIMIT 1),
    (SELECT i.manager_employee_id FROM employee_job_relationship_item i
      WHERE i.set_id = p_set_id AND i.relationship_code = 'PM02'
        AND (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE) LIMIT 1),
    (SELECT i.manager_employee_id FROM employee_job_relationship_item i
      WHERE i.set_id = p_set_id AND i.relationship_code = 'PM03'
        AND (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE) LIMIT 1),
    (SELECT i.manager_employee_id FROM employee_job_relationship_item i
      WHERE i.set_id = p_set_id AND i.relationship_code = 'OM01'
        AND (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE) LIMIT 1),
    (SELECT i.manager_employee_id FROM employee_job_relationship_item i
      WHERE i.set_id = p_set_id AND i.relationship_code = 'OM02'
        AND (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE) LIMIT 1),
    (SELECT i.manager_employee_id FROM employee_job_relationship_item i
      WHERE i.set_id = p_set_id AND i.relationship_code = 'OM03'
        AND (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE) LIMIT 1)
  INTO v_pm01, v_pm02, v_pm03, v_om01, v_om02, v_om03;

  PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

  UPDATE employees
  SET    pm01_manager_id = v_pm01,
         pm02_manager_id = v_pm02,
         pm03_manager_id = v_pm03,
         om01_manager_id = v_om01,
         om02_manager_id = v_om02,
         om03_manager_id = v_om03,
         updated_at      = NOW()
  WHERE  id = p_employee_id;

  PERFORM set_config('prowess.allow_job_relationships_sync', 'false', true);
END;
$fn$;

REVOKE ALL     ON FUNCTION public.sync_job_relationship_mirrors(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.sync_job_relationship_mirrors(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.sync_job_relationship_mirrors(uuid, uuid) IS
  'Mig 461: reads PM01-OM03 from one set and writes the six mirror columns on '
  'employees. Mig 845: recreated -- 461 is recorded as applied but the function '
  'was absent, so every caller raised. Skips assignments already ended as of '
  'today (mig 835 removed_on).';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_n integer; v_src text; v_fn text;
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'sync_job_relationship_mirrors'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_employee_id uuid, p_set_id uuid';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'MIG 845 FAILED: expected one sync_job_relationship_mirrors(uuid, uuid), found %.', v_n;
  END IF;

  -- AW8: a plpgsql body is not parsed when the function is created, so
  -- "it deployed" proves nothing. CALL it. With NULLs the SELECT returns NULLs
  -- and the UPDATE matches no row, but every column name has to resolve.
  PERFORM sync_job_relationship_mirrors(NULL::uuid, NULL::uuid);

  -- And the callers must now be able to find it. A function that exists under
  -- a signature nobody calls is the same outage with a longer name.
  FOR v_fn IN SELECT unnest(ARRAY['fn_apply_job_relationship_set_transition',
                                  'wf_activate_employee'])
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn
    LIMIT  1;

    IF v_src IS NULL THEN
      RAISE WARNING 'MIG 845: %() is not present on this database -- nothing to check.', v_fn;
    ELSIF position('sync_job_relationship_mirrors' IN v_src) = 0 THEN
      RAISE WARNING 'MIG 845: %() no longer calls sync_job_relationship_mirrors. Harmless, but this migration exists for it.', v_fn;
    ELSE
      RAISE NOTICE 'MIG 845: %() can now resolve its mirror call.', v_fn;
    END IF;
  END LOOP;

  RAISE NOTICE 'MIG 845 OK: the mirror helper exists and runs.';
END $v$;

COMMIT;
