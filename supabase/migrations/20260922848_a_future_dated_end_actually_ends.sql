-- =============================================================================
-- Migration 848 — a project assignment that ends in the future actually ends
--
-- THE DECISION THIS IMPLEMENTS
-- ════════════════════════════
--   Vj: "I would like to update the future not immediately but only on that
--   day." So a future-dated end records nothing when you set it, and a job
--   applies it on the morning it falls due. The alternative -- writing the
--   future-dated set now and letting date-aware readers ignore it until its
--   day -- was considered and not chosen.
--
--   Today neither happens. trg_pm_jr_sync fires only when the new end date is
--   `<= CURRENT_DATE`, so a future end is dropped, and nothing revisits it.
--   Measured: end a QCC assignment on 31 Dec and on 1 January she still has
--   that manager, permanently.
--
-- WHY THERE WAS NOTHING TO SCHEDULE
-- ═════════════════════════════════
--   461 wrote `_sync_job_relationships_today` for this and its comment claims
--   it was "added to nightly cron". cron.job holds two entries, neither of them
--   this. The function did not appear among those referencing the item table,
--   and it carries the same `MAX(CASE WHEN ... THEN manager_employee_id END)`
--   over a uuid that made 845 necessary -- there is no max(uuid) aggregate, so
--   it could not have run if it had been scheduled. Written in June, never
--   scheduled, never runnable, unnoticed for three months.
--
--   This migration therefore does not reuse it. It also does not compute
--   anything new: it REPLAYS boundaries that have fallen due through
--   sync_project_jr_on_remove, the same function the same-day path uses. One
--   rule, one implementation -- if the shared-manager guard is right there, it
--   is right here, because it IS there.
--
-- SELF-HEALING, NOT "YESTERDAY'S CHANGES"
-- ═══════════════════════════════════════
--   The job does not ask "what ended yesterday". It asks "which ended
--   assignments still hold a live relationship slot", which is a question about
--   the present, so a missed night -- or a month of missed nights, or a
--   migration that runs it once by hand -- converges to the same answer. A job
--   whose correctness depends on having run every day since is a job nobody can
--   verify; this one is verified by running it.
--
-- ENDS ONLY, AND THAT IS NOT AN OVERSIGHT
-- ═══════════════════════════════════════
--   It does not add relationships. It cannot safely: a job-relationship slot
--   can be set by hand as well as by a project, nothing on the row records
--   which, and a job that re-adds every manager a project implies would undo
--   deliberate human removals. Adds already happen when the membership is
--   created -- imperfectly, since a future-dated join is applied at once -- and
--   that asymmetry is left standing rather than papered over with a guess.
--
--   The known consequence, demonstrated: assignment ends 31 Aug, a new project
--   with the same manager starts 01 Oct, the join was booked in advance. The
--   slot is correctly released on 01 Sep and nothing restores it on 01 Oct.
--   September is right; October is not. Fixing it properly needs provenance on
--   the item row -- which project put this manager here -- and that is a schema
--   change with a backfill, not a line in a cron job.
--
-- Depends on: 834 (sync_project_jr_on_remove and its shared-manager guard),
--             835 (removed_on), 844/846 (the timeline and readers it relies on)
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.apply_due_project_jr_ends(p_as_of date DEFAULT CURRENT_DATE)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  r          RECORD;
  v_slots    CONSTANT text[] := ARRAY['PM01','PM02','PM03','PM04','PM05','PM06'];
  v_seen     integer := 0;
  v_applied  integer := 0;
  v_still    integer := 0;
BEGIN
  FOR r IN
    SELECT pm.employee_id, pm.project_id, p.manager_id,
           (pm.effective_to + 1) AS boundary
    FROM   project_members pm
    JOIN   projects p ON p.id = pm.project_id
    WHERE  pm.effective_to IS NOT NULL
      -- the day AFTER the last day has arrived
      AND  pm.effective_to < p_as_of
      AND  p.manager_id IS NOT NULL
      -- ...and that manager still occupies a live slot in the set in force.
      -- This is what makes the job idempotent and self-healing: once the slot
      -- is released the row stops matching, and a boundary missed for a month
      -- still matches until it is dealt with.
      AND  EXISTS (
        SELECT 1
        FROM   employee_job_relationship_set  s
        JOIN   employee_job_relationship_item i ON i.set_id = s.id
        WHERE  s.employee_id       = pm.employee_id
          AND  p_as_of BETWEEN s.effective_from AND s.effective_to
          AND  i.relationship_code = ANY(v_slots)
          AND  i.manager_employee_id = p.manager_id
          AND  (i.removed_on IS NULL OR i.removed_on > p_as_of))
    -- Earliest boundary first. Two projects sharing a manager settle correctly
    -- this way: the earlier end finds the later project still covering and
    -- leaves the slot alone; the later end then finds nothing covering and
    -- releases it.
    ORDER BY pm.effective_to, pm.employee_id
  LOOP
    v_seen := v_seen + 1;

    -- The SAME function the same-day path calls, with the same boundary date,
    -- so the shared-manager guard is not reimplemented here.
    PERFORM sync_project_jr_on_remove(r.employee_id, r.project_id, r.boundary);

    IF EXISTS (
      SELECT 1
      FROM   employee_job_relationship_set  s
      JOIN   employee_job_relationship_item i ON i.set_id = s.id
      WHERE  s.employee_id       = r.employee_id
        AND  p_as_of BETWEEN s.effective_from AND s.effective_to
        AND  i.relationship_code = ANY(v_slots)
        AND  i.manager_employee_id = r.manager_id
        AND  (i.removed_on IS NULL OR i.removed_on > p_as_of))
    THEN
      -- Still held. Either another project justifies it -- the guard did its
      -- job -- or sync_project_jr_on_remove failed and swallowed the error,
      -- which it does unconditionally. Counted rather than assumed, so a run
      -- where these two numbers diverge from expectation is visible.
      v_still := v_still + 1;
    ELSE
      v_applied := v_applied + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',        true,
    'as_of',     p_as_of,
    'due',       v_seen,
    'released',  v_applied,
    'retained',  v_still
  );
END;
$fn$;

REVOKE ALL     ON FUNCTION public.apply_due_project_jr_ends(date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.apply_due_project_jr_ends(date) TO authenticated;

COMMENT ON FUNCTION public.apply_due_project_jr_ends(date) IS
  'Mig 848: releases job-relationship slots whose project assignment has ended, '
  'for boundaries that have fallen due. Idempotent and safe to run at any time: '
  'it asks which ended assignments still hold a slot, not what changed '
  'yesterday. Ends only -- see the migration header for why it does not add.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Schedule it
-- ═══════════════════════════════════════════════════════════════════════════
-- 01:40, after expire-employee-email-changes at 02:17? No -- before it, and
-- clear of hire_activation_retry's five-minute cadence. Nothing here depends on
-- either; the separation is only so a slow night is legible in the logs.
DO $sch$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'MIG 848: pg_cron is not installed, so the job is created but NOT scheduled. Schedule apply_due_project_jr_ends() by hand or a future-dated end will never take effect.';
    RETURN;
  END IF;

  PERFORM cron.unschedule('job-relationship-due-ends')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'job-relationship-due-ends');

  PERFORM cron.schedule('job-relationship-due-ends', '40 1 * * *',
                        'SELECT public.apply_due_project_jr_ends();');

  RAISE NOTICE 'MIG 848: scheduled job-relationship-due-ends at 01:40 daily.';
END $sch$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_res jsonb; v_jobs bigint;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'apply_due_project_jr_ends')
  THEN
    RAISE EXCEPTION 'MIG 848 FAILED: the function was not created.';
  END IF;

  -- AW8: run it. A job that only exists is the thing 461 already tried.
  -- Against today's data this also APPLIES any end already overdue, which is
  -- the point -- the backlog is cleared by the migration that introduces the
  -- job, not left for its first night.
  v_res := apply_due_project_jr_ends();

  IF NOT (v_res->>'ok')::boolean THEN
    RAISE EXCEPTION 'MIG 848 FAILED: the first run did not report ok: %', v_res;
  END IF;

  RAISE NOTICE 'MIG 848 OK: % due, % released, % retained by the shared-manager guard.',
    v_res->>'due', v_res->>'released', v_res->>'retained';

  -- Dynamic, because SQL resolves every relation in a statement whether or not
  -- the branch is taken: a plain `EXISTS(pg_extension) AND EXISTS(cron.job)`
  -- fails with "relation cron.job does not exist" on a database without
  -- pg_cron -- which is exactly the database the guard is written for. Caught
  -- by running this migration on a fixture that has no pg_cron.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE $q$ SELECT count(*) FROM cron.job WHERE jobname = 'job-relationship-due-ends' $q$
      INTO v_jobs;
    IF v_jobs = 0 THEN
      RAISE EXCEPTION 'MIG 848 FAILED: pg_cron is present but the job is not scheduled.';
    END IF;
  END IF;
END $v$;

COMMIT;
