-- =============================================================================
-- Migration 360 — Job Relationships: RPCs
--
-- Five SECURITY DEFINER functions:
--
--   fn_close_and_replace_job_relationship_set(…)
--     Internal helper: closes current set, inserts replacement minus
--     removed codes, syncs mirror columns. Used by deactivation fanout.
--
--   upsert_job_relationship_set(p_employee_id, p_effective_from, p_items)
--     Single write entry point. Dual-path: PATH A direct write, PATH B
--     workflow staging. Validates codes, Active status, no self-assign.
--     Syncs mirror columns when effective_from ≤ today.
--
--   get_current_job_relationships(p_employee_id)
--     Returns active set + items as JSONB.
--
--   get_job_relationships_history(p_employee_id)
--     Returns all sets reverse-chronologically.
--
--   get_deactivation_impact(p_employee_id)
--     Returns every OTHER employee where p_employee_id is a matrix manager,
--     used by the deactivation confirmation modal.
--
-- Design spec: docs/job-relationships-design.md §4
-- =============================================================================


-- =============================================================================
-- 1. fn_close_and_replace_job_relationship_set
--    Internal helper — NOT exposed as an API RPC.
--    Called by: upsert_job_relationship_set (same-day amendment), deactivation fanout.
--
--    Behaviour:
--      • Locks the current open set for the employee
--      • If same effective_from (amendment): DELETE old set (cascade deletes items)
--        else: UPDATE old set's effective_to = p_effective_from - 1, is_active = false
--      • INSERT new set with effective_from = p_effective_from
--      • INSERT items = old items EXCLUDING p_remove_codes PLUS any p_new_items
--      • When effective_from ≤ today: sync employees mirror columns
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_close_and_replace_job_relationship_set(
  p_employee_id    uuid,
  p_effective_from date,
  p_remove_codes   text[]    DEFAULT ARRAY[]::text[],
  p_new_items      jsonb     DEFAULT '[]'::jsonb,
  p_actor          uuid      DEFAULT NULL   -- NULL = system/trigger
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_set       employee_job_relationship_set%ROWTYPE;
  v_new_set_id    uuid;
  v_item          RECORD;
  v_new_item      jsonb;
  v_mgr_id        uuid;
  v_code          text;
  -- mirror sync accumulators
  v_pm01          uuid := NULL;
  v_pm02          uuid := NULL;
  v_pm03          uuid := NULL;
  v_om01          uuid := NULL;
  v_om02          uuid := NULL;
  v_om03          uuid := NULL;
BEGIN
  -- Lock the current open set (if any)
  SELECT * INTO v_old_set
  FROM   employee_job_relationship_set
  WHERE  employee_id  = p_employee_id
    AND  is_active    = true
    AND  effective_to = '9999-12-31'::date
  FOR UPDATE;

  -- Close or delete the old set
  IF v_old_set.id IS NOT NULL THEN
    IF v_old_set.effective_from >= p_effective_from THEN
      -- Same-day or back-dated amendment: delete and replace entirely
      DELETE FROM employee_job_relationship_set WHERE id = v_old_set.id;
    ELSE
      UPDATE employee_job_relationship_set
      SET    effective_to = p_effective_from - 1,
             is_active    = false,
             updated_by   = p_actor,
             updated_at   = NOW()
      WHERE  id = v_old_set.id;
    END IF;
  END IF;

  -- Insert new set
  INSERT INTO employee_job_relationship_set
        (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
  VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor, p_actor)
  RETURNING id INTO v_new_set_id;

  -- Carry forward items from old set, excluding p_remove_codes
  IF v_old_set.id IS NOT NULL THEN
    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
    SELECT v_new_set_id, relationship_code, manager_employee_id
    FROM   employee_job_relationship_item
    WHERE  set_id = v_old_set.id
      AND  relationship_code <> ALL(p_remove_codes)
    ON CONFLICT DO NOTHING;
  END IF;

  -- Apply new items (override carry-forward for codes mentioned in p_new_items)
  FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
  LOOP
    v_code   := v_new_item->>'relationship_code';
    v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;

    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
    VALUES (v_new_set_id, v_code, v_mgr_id)
    ON CONFLICT (set_id, relationship_code) DO UPDATE
      SET manager_employee_id = EXCLUDED.manager_employee_id;
  END LOOP;

  -- Mirror sync when effective_from ≤ today
  IF p_effective_from <= CURRENT_DATE THEN
    -- Read what we just inserted
    SELECT
      pm01.manager_employee_id,
      pm02.manager_employee_id,
      pm03.manager_employee_id,
      om01.manager_employee_id,
      om02.manager_employee_id,
      om03.manager_employee_id
    INTO v_pm01, v_pm02, v_pm03, v_om01, v_om02, v_om03
    FROM (SELECT 1) dummy
    LEFT JOIN employee_job_relationship_item pm01 ON pm01.set_id = v_new_set_id AND pm01.relationship_code = 'PM01'
    LEFT JOIN employee_job_relationship_item pm02 ON pm02.set_id = v_new_set_id AND pm02.relationship_code = 'PM02'
    LEFT JOIN employee_job_relationship_item pm03 ON pm03.set_id = v_new_set_id AND pm03.relationship_code = 'PM03'
    LEFT JOIN employee_job_relationship_item om01 ON om01.set_id = v_new_set_id AND om01.relationship_code = 'OM01'
    LEFT JOIN employee_job_relationship_item om02 ON om02.set_id = v_new_set_id AND om02.relationship_code = 'OM02'
    LEFT JOIN employee_job_relationship_item om03 ON om03.set_id = v_new_set_id AND om03.relationship_code = 'OM03';

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
  END IF;

  RETURN jsonb_build_object('ok', true, 'set_id', v_new_set_id);
END;
$$;

COMMENT ON FUNCTION fn_close_and_replace_job_relationship_set(uuid, date, text[], jsonb, uuid) IS
  'Internal helper for job-relationship set-snapshot writes. '
  'Closes the current open set, carries forward non-removed items, '
  'applies new items, and syncs the 6 mirror columns when effective_from ≤ today. '
  'Called by upsert_job_relationship_set and the deactivation fanout trigger.';


-- =============================================================================
-- 2. upsert_job_relationship_set
--    Public API: dual-path (direct write vs workflow staging)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_job_relationship_set(
  p_employee_id    uuid,
  p_effective_from date,
  p_items          jsonb   -- [{relationship_code, manager_employee_id}, ...]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_profile  uuid;
  v_caller_emp_id   uuid;
  v_is_hr           boolean;
  v_employee        employees%ROWTYPE;
  v_item            jsonb;
  v_code            text;
  v_mgr_id          uuid;
  v_seen_codes      text[] := ARRAY[]::text[];
  v_valid_codes     text[];
  v_mgr_active      boolean;
  v_template_id     uuid;
  v_pending_id      uuid;
  v_instance_id     uuid;
  v_result          jsonb;
BEGIN
  -- ── Caller identity ──────────────────────────────────────────────────────
  v_caller_profile := auth.uid();

  SELECT employee_id INTO v_caller_emp_id
  FROM   profiles WHERE id = v_caller_profile;

  -- ── Permission check ─────────────────────────────────────────────────────
  -- PATH A: scoped edit (HR editing any employee, or ESS editing own via workflow)
  -- PATH B: hire-pipeline (Draft/Incomplete/Pending employees, HR-only)
  v_is_hr := user_can('job_relationships', 'edit', NULL);

  IF NOT v_is_hr AND NOT user_can('job_relationships', 'edit', p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to edit job relationships for this employee.');
  END IF;

  -- ── Load employee ─────────────────────────────────────────────────────────
  SELECT * INTO v_employee FROM employees WHERE id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'EMPLOYEE_NOT_FOUND',
      'message', 'Employee not found.');
  END IF;

  -- Hire-pipeline guard: non-HR cannot edit Draft/Incomplete/Pending
  IF v_employee.status IN ('Draft', 'Incomplete', 'Pending') AND NOT v_is_hr THEN
    RETURN jsonb_build_object('ok', false, 'error', 'HIRE_PIPELINE_RESTRICTED',
      'message', 'Job relationships can only be edited by HR during onboarding.');
  END IF;

  -- ── Load valid picklist codes ──────────────────────────────────────────────
  SELECT ARRAY_AGG(pv.ref_id) INTO v_valid_codes
  FROM   picklist_values pv
  JOIN   picklists pl ON pl.id = pv.picklist_id
  WHERE  pl.picklist_id = 'JOB_RELATIONSHIP_TYPE'
    AND  pv.active = true;

  -- ── Validate p_items ───────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_code   := v_item->>'relationship_code';
    v_mgr_id := (v_item->>'manager_employee_id')::uuid;

    -- Code must exist in picklist
    IF v_code IS NULL OR NOT (v_code = ANY(v_valid_codes)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'INVALID_CODE',
        'message', format('relationship_code %L is not a valid active JOB_RELATIONSHIP_TYPE code.', v_code));
    END IF;

    -- No duplicate codes in the input array
    IF v_code = ANY(v_seen_codes) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'DUPLICATE_CODE',
        'message', format('Duplicate relationship_code %L in p_items.', v_code));
    END IF;
    v_seen_codes := v_seen_codes || v_code;

    -- manager_employee_id must be present
    IF v_mgr_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'MISSING_MANAGER',
        'message', format('manager_employee_id is required for code %L.', v_code));
    END IF;

    -- No self-assignment
    IF v_mgr_id = p_employee_id THEN
      RETURN jsonb_build_object('ok', false, 'error', 'SELF_ASSIGNMENT',
        'message', format('Cannot assign employee as their own %L matrix manager.', v_code));
    END IF;

    -- Manager must be Active
    SELECT (status = 'Active') INTO v_mgr_active
    FROM   employees WHERE id = v_mgr_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'MANAGER_NOT_FOUND',
        'message', format('Manager employee %L not found for code %L.', v_mgr_id, v_code));
    END IF;

    IF NOT v_mgr_active THEN
      RETURN jsonb_build_object('ok', false, 'error', 'MANAGER_INACTIVE',
        'message', format('Manager for code %L must have status=Active at assignment time.', v_code));
    END IF;
  END LOOP;

  -- ── PATH B: workflow staging (non-HR or non-Active employee status) ────────
  -- For now, direct-write only (PATH A). Workflow staging (PATH B) is wired in
  -- mig 364 (apply_profile_pending_change). If a workflow template exists for
  -- profile_job_relationships the submit_change_request path is taken.
  SELECT id INTO v_template_id
  FROM   workflow_templates
  WHERE  module_code = 'profile_job_relationships'
    AND  is_active   = true
  LIMIT  1;

  IF v_template_id IS NOT NULL AND NOT v_is_hr THEN
    -- ESS-initiated: stage as a workflow pending change
    SELECT submit_change_request(
      'profile_job_relationships',
      p_employee_id,
      jsonb_build_object(
        'effective_from', p_effective_from,
        'items',          p_items
      ),
      'update',
      NULL
    ) INTO v_result;

    RETURN v_result;
  END IF;

  -- ── PATH A: direct write ───────────────────────────────────────────────────
  -- Remove all codes from the current set (carry-forward handled by fn_close_and_replace
  -- via p_new_items overriding everything: we pass all p_items as p_new_items and
  -- pass ALL 6 codes as p_remove_codes to ensure clean state).
  SELECT fn_close_and_replace_job_relationship_set(
    p_employee_id,
    p_effective_from,
    ARRAY['PM01','PM02','PM03','OM01','OM02','OM03'],   -- remove all existing
    p_items,                                             -- overlay with new
    v_caller_profile
  ) INTO v_result;

  IF NOT (v_result->>'ok')::boolean THEN
    RETURN v_result;
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'workflow',     false,
    'set_id',       v_result->>'set_id',
    'effective_from', p_effective_from
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_job_relationship_set(uuid, date, jsonb) IS
  'Public write entry point for matrix manager assignments. '
  'PATH A: direct write for HR/admin (bypasses workflow). '
  'PATH B: workflow staging for ESS (when a profile_job_relationships workflow template exists). '
  'Validates codes against JOB_RELATIONSHIP_TYPE picklist, rejects Inactive managers, '
  'blocks self-assignment, syncs 6 mirror columns when effective_from ≤ today.';


-- =============================================================================
-- 3. get_current_job_relationships
-- =============================================================================

CREATE OR REPLACE FUNCTION get_current_job_relationships(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_set    employee_job_relationship_set%ROWTYPE;
  v_items  jsonb;
BEGIN
  -- Access guard
  IF NOT user_can('job_relationships', 'view', p_employee_id)
    AND NOT user_can('job_relationships', 'view', NULL)
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT * INTO v_set
  FROM   employee_job_relationship_set
  WHERE  employee_id  = p_employee_id
    AND  is_active    = true
    AND  effective_to = '9999-12-31'::date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'set', NULL, 'items', '[]'::jsonb);
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',                   i.id,
      'relationship_code',    i.relationship_code,
      'manager_employee_id',  i.manager_employee_id,
      'manager_name',         e.name,
      'manager_employee_code', e.employee_id,
      'created_at',           i.created_at
    ) ORDER BY pv.ref_id
  ) INTO v_items
  FROM   employee_job_relationship_item i
  JOIN   employees e  ON e.id = i.manager_employee_id
  LEFT JOIN picklist_values pv
    ON pv.ref_id = i.relationship_code
   AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'JOB_RELATIONSHIP_TYPE')
  WHERE  i.set_id = v_set.id;

  RETURN jsonb_build_object(
    'ok',   true,
    'set',  jsonb_build_object(
              'id',             v_set.id,
              'effective_from', v_set.effective_from,
              'effective_to',   v_set.effective_to,
              'is_active',      v_set.is_active,
              'created_at',     v_set.created_at
            ),
    'items', COALESCE(v_items, '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION get_current_job_relationships(uuid) IS
  'Returns the active job relationship set + items for an employee. '
  'Returns {ok:true, set:null, items:[]} when no set exists. '
  'Access guard: job_relationships.view scoped or global.';


-- =============================================================================
-- 4. get_job_relationships_history
-- =============================================================================

CREATE OR REPLACE FUNCTION get_job_relationships_history(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sets jsonb;
BEGIN
  -- Access guard: history or view permission
  IF NOT user_can('job_relationships', 'history', p_employee_id)
    AND NOT user_can('job_relationships', 'view',    p_employee_id)
    AND NOT user_can('job_relationships', 'history', NULL)
    AND NOT user_can('job_relationships', 'view',    NULL)
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',             s.id,
      'effective_from', s.effective_from,
      'effective_to',   s.effective_to,
      'is_active',      s.is_active,
      'created_at',     s.created_at,
      'items', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id',                  i.id,
            'relationship_code',   i.relationship_code,
            'manager_employee_id', i.manager_employee_id,
            'manager_name',        e.name,
            'manager_employee_code', e.employee_id
          ) ORDER BY pv.ref_id
        )
        FROM   employee_job_relationship_item i
        JOIN   employees e ON e.id = i.manager_employee_id
        LEFT JOIN picklist_values pv
          ON pv.ref_id = i.relationship_code
         AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'JOB_RELATIONSHIP_TYPE')
        WHERE  i.set_id = s.id
      )
    )
    ORDER BY s.effective_from DESC
  ) INTO v_sets
  FROM employee_job_relationship_set s
  WHERE s.employee_id = p_employee_id;

  RETURN jsonb_build_object(
    'ok',   true,
    'sets', COALESCE(v_sets, '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION get_job_relationships_history(uuid) IS
  'Returns all job relationship sets for an employee, newest-first. '
  'Each set includes its items with resolved manager name and employee code. '
  'Access guard: job_relationships.history or .view (scoped or global).';


-- =============================================================================
-- 5. get_deactivation_impact
--    Returns every OTHER employee where p_employee_id is currently a matrix manager.
--    Used by the deactivation confirmation modal.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_deactivation_impact(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_affected jsonb;
  v_total    int;
BEGIN
  -- Requires HR-level edit access (only HR sees the deactivation modal)
  IF NOT user_can('job_relationships', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- Find all employees where p_employee_id is a current matrix manager
  -- by looking at the mirror columns (fast path — avoids joining through satellite)
  SELECT
    COUNT(*)::int,
    jsonb_agg(
      jsonb_build_object(
        'employee_id',   e.id,
        'employee_code', e.employee_id,
        'name',          e.name,
        'codes_held',    ARRAY_REMOVE(ARRAY[
          CASE WHEN e.pm01_manager_id = p_employee_id THEN 'PM01' END,
          CASE WHEN e.pm02_manager_id = p_employee_id THEN 'PM02' END,
          CASE WHEN e.pm03_manager_id = p_employee_id THEN 'PM03' END,
          CASE WHEN e.om01_manager_id = p_employee_id THEN 'OM01' END,
          CASE WHEN e.om02_manager_id = p_employee_id THEN 'OM02' END,
          CASE WHEN e.om03_manager_id = p_employee_id THEN 'OM03' END
        ], NULL)
      )
      ORDER BY e.name
    )
  INTO v_total, v_affected
  FROM employees e
  WHERE p_employee_id IN (
    e.pm01_manager_id, e.pm02_manager_id, e.pm03_manager_id,
    e.om01_manager_id, e.om02_manager_id, e.om03_manager_id
  );

  RETURN jsonb_build_object(
    'ok',                true,
    'affected_employees', COALESCE(v_affected, '[]'::jsonb),
    'total',             COALESCE(v_total, 0)
  );
END;
$$;

COMMENT ON FUNCTION get_deactivation_impact(uuid) IS
  'Returns every employee where p_employee_id is currently a matrix manager '
  '(reads from employees mirror columns for performance). '
  'Powers the deactivation-time UX warning modal in EmployeeEditPanel. '
  'Access guard: job_relationships.edit global (HR only).';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT proname
FROM   pg_proc
WHERE  proname IN (
  'fn_close_and_replace_job_relationship_set',
  'upsert_job_relationship_set',
  'get_current_job_relationships',
  'get_job_relationships_history',
  'get_deactivation_impact'
)
ORDER  BY proname;

-- =============================================================================
-- END OF MIGRATION 360
-- =============================================================================
