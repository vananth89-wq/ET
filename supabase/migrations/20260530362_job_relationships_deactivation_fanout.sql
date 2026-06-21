-- =============================================================================
-- Migration 362 — Job Relationships: Deactivation Fanout + Drift View
--
-- Changes:
--   1. Extend sync_profile_on_employee_status() with a job-relationships fanout:
--      When an employee is deactivated, close the active job-relationship sets
--      of every other employee who has the deactivated person as a matrix manager.
--      Per-employee EXCEPTION blocks — one failure never blocks the status flip.
--      Errors logged to job_run_log.
--   2. Add vw_job_relationships_drift: surfaces employees whose mirror columns
--      diverge from their current active job-relationship set items.
--
-- Design spec: docs/job-relationships-design.md §6
-- =============================================================================


-- =============================================================================
-- 1. Extend sync_profile_on_employee_status() — add job-relationships fanout
--    Full function recreated. Original behaviour (profile.is_active + ESS role)
--    is preserved exactly; the new block runs as an additional pass at the END
--    of the Inactive branch.
-- =============================================================================

CREATE OR REPLACE FUNCTION sync_profile_on_employee_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id  uuid;
  v_ess_role    uuid;
  -- Deactivation fanout
  v_affected    RECORD;
  v_codes_held  text[];
BEGIN
  -- No-op if status didn't change
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- Resolve the linked profile
  SELECT id INTO v_profile_id
  FROM   profiles
  WHERE  employee_id = NEW.id
  LIMIT  1;

  -- ── Deactivation: any status → Inactive ──────────────────────────────────
  IF NEW.status = 'Inactive' AND OLD.status IS DISTINCT FROM 'Inactive' THEN

    IF v_profile_id IS NOT NULL THEN
      -- 1. Mark profile inactive
      UPDATE profiles
      SET    is_active  = false,
             updated_at = now()
      WHERE  id = v_profile_id;

      -- 2. Revoke ALL roles
      DELETE FROM user_roles
      WHERE  profile_id = v_profile_id;
    END IF;

    -- ── Job-relationships deactivation fanout ─────────────────────────────
    -- Set the bypass flag so we can update mirror columns of OTHER employees.
    PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

    FOR v_affected IN
      SELECT
        e.id AS employee_id,
        ARRAY_REMOVE(ARRAY[
          CASE WHEN e.pm01_manager_id = NEW.id THEN 'PM01' END,
          CASE WHEN e.pm02_manager_id = NEW.id THEN 'PM02' END,
          CASE WHEN e.pm03_manager_id = NEW.id THEN 'PM03' END,
          CASE WHEN e.om01_manager_id = NEW.id THEN 'OM01' END,
          CASE WHEN e.om02_manager_id = NEW.id THEN 'OM02' END,
          CASE WHEN e.om03_manager_id = NEW.id THEN 'OM03' END
        ], NULL) AS codes_held
      FROM employees e
      WHERE NEW.id IN (
        e.pm01_manager_id, e.pm02_manager_id, e.pm03_manager_id,
        e.om01_manager_id, e.om02_manager_id, e.om03_manager_id
      )
    LOOP
      BEGIN
        -- Remove the deactivated person's codes from this affected employee's set.
        -- fn_close_and_replace_job_relationship_set carries forward all OTHER codes.
        PERFORM fn_close_and_replace_job_relationship_set(
          p_employee_id    => v_affected.employee_id,
          p_effective_from => CURRENT_DATE,
          p_remove_codes   => v_affected.codes_held,
          p_new_items      => '[]'::jsonb,
          p_actor          => NULL   -- system trigger; no profile actor
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
          'job_relationships fanout failed for employee=%, codes=%, error=%',
          v_affected.employee_id, v_affected.codes_held, SQLERRM;

        INSERT INTO job_run_log (job_code, status, message, run_at)
        VALUES (
          'job_relationships_deactivation_fanout',
          'error',
          format(
            'emp=%s codes=%s err=%s',
            v_affected.employee_id,
            v_affected.codes_held,
            SQLERRM
          ),
          NOW()
        );
      END;
    END LOOP;

  END IF;

  -- ── Reactivation: Inactive → Active ──────────────────────────────────────
  IF NEW.status = 'Active' AND OLD.status = 'Inactive' THEN

    IF v_profile_id IS NOT NULL THEN
      -- 1. Re-enable profile
      UPDATE profiles
      SET    is_active  = true,
             updated_at = now()
      WHERE  id = v_profile_id;

      -- 2. Re-grant ESS role only
      SELECT id INTO v_ess_role FROM roles WHERE code = 'ess' LIMIT 1;

      IF v_ess_role IS NOT NULL THEN
        INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
        VALUES (v_profile_id, v_ess_role, 'system_reactivation', now(), now())
        ON CONFLICT (profile_id, role_id) DO NOTHING;
      END IF;
    END IF;

    -- NOTE: Job relationships are NOT auto-restored on reactivation (locked decision).
    -- HR must re-assign manually via the portlet.

  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION sync_profile_on_employee_status() IS
  'Fires AFTER UPDATE on employees when status changes. '
  'Deactivation (→ Inactive): sets profiles.is_active=false, deletes ALL user_roles, '
  'then runs the job-relationships deactivation fanout (closes sets that referenced '
  'the deactivated employee as a matrix manager). Per-employee EXCEPTION blocks mean '
  'one fanout failure never blocks the status flip. '
  'Reactivation (Inactive → Active): sets profiles.is_active=true, re-grants ESS only. '
  'Job relationships are NOT auto-restored on reactivation — HR re-assigns manually. '
  'Mig 148 original + mig 362 job-relationships fanout extension.';


-- Trigger already exists from mig 148 — recreate to pick up new function body
DROP TRIGGER IF EXISTS trg_sync_profile_on_employee_status ON employees;

CREATE TRIGGER trg_sync_profile_on_employee_status
  AFTER UPDATE ON employees
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION sync_profile_on_employee_status();


-- =============================================================================
-- 2. vw_job_relationships_drift
--    Surfaces any employee whose 6 mirror columns differ from their current
--    active set's items. Ops uses this for reconciliation / self-healing.
-- =============================================================================

CREATE OR REPLACE VIEW vw_job_relationships_drift AS
-- One row per employee whose mirror columns diverge from their active set items.
-- Uses conditional LEFT JOINs (one per code) — avoids aggregation over UUID.
SELECT
  e.id            AS employee_id,
  e.employee_id   AS employee_code,
  e.name,

  -- Mirror values (from employees table)
  e.pm01_manager_id  AS mirror_pm01,
  e.pm02_manager_id  AS mirror_pm02,
  e.pm03_manager_id  AS mirror_pm03,
  e.om01_manager_id  AS mirror_om01,
  e.om02_manager_id  AS mirror_om02,
  e.om03_manager_id  AS mirror_om03,

  -- Satellite values (from active set items — at most 1 row per code per set)
  pm01.manager_employee_id  AS sat_pm01,
  pm02.manager_employee_id  AS sat_pm02,
  pm03.manager_employee_id  AS sat_pm03,
  om01.manager_employee_id  AS sat_om01,
  om02.manager_employee_id  AS sat_om02,
  om03.manager_employee_id  AS sat_om03,

  s.effective_from  AS set_effective_from,
  s.id              AS set_id

FROM employees e
LEFT JOIN employee_job_relationship_set s
  ON  s.employee_id  = e.id
  AND s.is_active    = true
  AND s.effective_to = '9999-12-31'::date
LEFT JOIN employee_job_relationship_item pm01 ON pm01.set_id = s.id AND pm01.relationship_code = 'PM01'
LEFT JOIN employee_job_relationship_item pm02 ON pm02.set_id = s.id AND pm02.relationship_code = 'PM02'
LEFT JOIN employee_job_relationship_item pm03 ON pm03.set_id = s.id AND pm03.relationship_code = 'PM03'
LEFT JOIN employee_job_relationship_item om01 ON om01.set_id = s.id AND om01.relationship_code = 'OM01'
LEFT JOIN employee_job_relationship_item om02 ON om02.set_id = s.id AND om02.relationship_code = 'OM02'
LEFT JOIN employee_job_relationship_item om03 ON om03.set_id = s.id AND om03.relationship_code = 'OM03'

WHERE
  e.pm01_manager_id IS DISTINCT FROM pm01.manager_employee_id OR
  e.pm02_manager_id IS DISTINCT FROM pm02.manager_employee_id OR
  e.pm03_manager_id IS DISTINCT FROM pm03.manager_employee_id OR
  e.om01_manager_id IS DISTINCT FROM om01.manager_employee_id OR
  e.om02_manager_id IS DISTINCT FROM om02.manager_employee_id OR
  e.om03_manager_id IS DISTINCT FROM om03.manager_employee_id;

COMMENT ON VIEW vw_job_relationships_drift IS
  'Surfaces employees whose pm01–om03 mirror columns on employees diverge from their '
  'current active employee_job_relationship_set items. '
  'Zero rows = clean state. Used by ops for reconciliation after fanout failures.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm trigger still exists
SELECT tgname, tgenabled
FROM   pg_trigger
WHERE  tgrelid = 'employees'::regclass
  AND  tgname  = 'trg_sync_profile_on_employee_status';

-- Confirm drift view exists
SELECT COUNT(*) AS drift_view_exists
FROM   pg_views
WHERE  schemaname = 'public'
  AND  viewname   = 'vw_job_relationships_drift';

-- Should be 0 on a fresh DB (no drift yet)
SELECT COUNT(*) AS current_drift_count FROM vw_job_relationships_drift;

-- =============================================================================
-- END OF MIGRATION 362
-- =============================================================================
