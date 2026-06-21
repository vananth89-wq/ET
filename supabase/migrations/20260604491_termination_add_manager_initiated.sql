-- =============================================================================
-- Migration 491 — Termination: add MANAGER_INITIATED initiation type
--
-- The design doc §2.1 originally specified 4 initiation types. A 5th —
-- MANAGER_INITIATED — is added per product requirement: a direct line manager
-- (employees.manager_id = caller's employee_id) can initiate a termination for
-- their direct report.
--
-- Changes:
--   1. Drop and recreate the CHECK constraint on employee_terminations to add
--      'MANAGER_INITIATED' as a valid value.
--   2. Replace derive_termination_initiation_type to detect MANAGER_INITIATED
--      (caller is the subject employee's direct line manager).
--   3. Update submit_termination to route MANAGER_INITIATED to the
--      'termination_manager' workflow template (seeded + configurable in
--      Phase 3 / mig 490).
--
-- Routing:
--   SELF               → 'termination_self'     (MANAGER → HR_APPROVER → FINAL_APPROVER)
--   MANAGER_INITIATED  → 'termination_manager'  (admin-configured)
--   HR_INITIATED       → 'termination_hr'        (HR_MANAGER → FINAL_APPROVER)
--   ADMIN_INITIATED    → 'termination_hr'        (HR_MANAGER → FINAL_APPROVER)
--   SYSTEM_INITIATED   → bypasses workflow (bulk path)
--
-- Predecessor: 20260604489 (termination RPCs)
-- =============================================================================


-- =============================================================================
-- 1. Replace CHECK constraint on termination_initiation_type
--    PostgreSQL doesn't support ALTER CHECK directly — drop and re-add.
-- =============================================================================

ALTER TABLE employee_terminations
  DROP CONSTRAINT IF EXISTS employee_terminations_termination_initiation_type_check;

ALTER TABLE employee_terminations
  ADD CONSTRAINT employee_terminations_termination_initiation_type_check
    CHECK (termination_initiation_type IN (
      'SELF',
      'MANAGER_INITIATED',
      'HR_INITIATED',
      'ADMIN_INITIATED',
      'SYSTEM_INITIATED'
    ));


-- =============================================================================
-- 2. Replace derive_termination_initiation_type — add MANAGER_INITIATED branch
-- =============================================================================

CREATE OR REPLACE FUNCTION derive_termination_initiation_type(
  p_employee_id uuid,
  p_is_bulk     boolean DEFAULT false
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_employee_id uuid;
BEGIN
  -- Bulk import → always SYSTEM_INITIATED (§1 decision #10)
  IF p_is_bulk THEN
    RETURN 'SYSTEM_INITIATED';
  END IF;

  v_my_employee_id := get_my_employee_id();

  -- Caller is the subject employee → SELF regardless of role (§1 decision #10)
  IF v_my_employee_id = p_employee_id THEN
    RETURN 'SELF';
  END IF;

  -- Caller is the subject's direct line manager → MANAGER_INITIATED
  IF v_my_employee_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM employees
       WHERE  id         = p_employee_id
         AND  manager_id = v_my_employee_id
         AND  deleted_at IS NULL
     )
  THEN
    RETURN 'MANAGER_INITIATED';
  END IF;

  -- HR role → HR_INITIATED
  IF user_can('termination', 'edit', NULL)
     AND EXISTS (
       SELECT 1 FROM profiles p
       JOIN user_roles ur ON ur.profile_id = p.id
       JOIN roles r       ON r.id = ur.role_id
       WHERE p.id = auth.uid()
         AND r.name ILIKE '%HR%'
     )
  THEN
    RETURN 'HR_INITIATED';
  END IF;

  -- Admin / super-admin with org-wide edit → ADMIN_INITIATED
  IF user_can('termination', 'edit', NULL) THEN
    RETURN 'ADMIN_INITIATED';
  END IF;

  RAISE EXCEPTION 'Insufficient privilege to initiate termination for this employee.'
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

REVOKE ALL     ON FUNCTION derive_termination_initiation_type(uuid, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION derive_termination_initiation_type(uuid, boolean) TO authenticated;

COMMENT ON FUNCTION derive_termination_initiation_type(uuid, boolean) IS
  'Mig 489: initial. '
  'Mig 491: added MANAGER_INITIATED — caller is subject''s direct line manager.';


-- =============================================================================
-- 3. Replace submit_termination — add MANAGER_INITIATED to template routing
--    and RESIGNATION_REASON vs TERMINATION_REASON picklist selection
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_termination(
  p_employee_id      uuid,
  p_termination_data jsonb,
  p_attachments      jsonb DEFAULT '[]'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_initiation_type       text;
  v_template_code         text;

  v_termination_date      date;
  v_reason_code           text;
  v_resignation_date      date;
  v_notice_date           date;
  v_last_working_date     date;
  v_waived                boolean;
  v_waiver_reason         text;
  v_eligible_for_rehire   boolean;
  v_regrettable           boolean;
  v_comments              text;

  v_notice_period_days    integer;
  v_required_lwd          date;

  v_picklist_code         text;
  v_reason_valid          boolean;

  v_termination_id        uuid;
  v_instance_id           uuid;

  v_att                   jsonb;
BEGIN

  -- ── 1. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('termination', 'edit', p_employee_id)
    OR user_can('termination', 'edit', NULL)
    OR get_my_employee_id() = p_employee_id
    OR EXISTS (                                        -- direct manager
         SELECT 1 FROM employees
         WHERE  id         = p_employee_id
           AND  manager_id = get_my_employee_id()
           AND  deleted_at IS NULL
       )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- ── 2. Extract payload ─────────────────────────────────────────────────────
  v_termination_date    := NULLIF(p_termination_data->>'termination_date', '')::date;
  v_reason_code         := NULLIF(p_termination_data->>'termination_reason_code', '');
  v_resignation_date    := NULLIF(p_termination_data->>'resignation_date', '')::date;
  v_notice_date         := NULLIF(p_termination_data->>'notice_date', '')::date;
  v_last_working_date   := NULLIF(p_termination_data->>'last_working_date', '')::date;
  v_waived              := COALESCE((p_termination_data->>'notice_period_waived')::boolean, false);
  v_waiver_reason       := NULLIF(p_termination_data->>'notice_period_waiver_reason', '');
  v_eligible_for_rehire := COALESCE((p_termination_data->>'eligible_for_rehire')::boolean, true);
  v_regrettable         := (p_termination_data->>'regrettable_termination')::boolean;
  v_comments            := NULLIF(p_termination_data->>'comments', '');

  -- ── 3. Required field validation ───────────────────────────────────────────
  IF v_termination_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_date is required.');
  END IF;
  IF v_reason_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_reason_code is required.');
  END IF;
  IF v_comments IS NULL OR length(v_comments) < 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 20 characters.');
  END IF;
  IF v_reason_code = 'OTHER' AND length(v_comments) < 50 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 50 characters when reason is OTHER.');
  END IF;

  -- ── 4. Derive initiation type ──────────────────────────────────────────────
  BEGIN
    v_initiation_type := derive_termination_initiation_type(p_employee_id, false);
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: cannot initiate termination.');
  END;

  -- ── 5. Picklist validation (§1 decision #11) ───────────────────────────────
  -- SELF → RESIGNATION_REASON; all other types → TERMINATION_REASON
  v_picklist_code := CASE
    WHEN v_initiation_type = 'SELF' THEN 'RESIGNATION_REASON'
    ELSE 'TERMINATION_REASON'
  END;

  SELECT EXISTS (
    SELECT 1 FROM picklist_values pv
    JOIN picklists pl ON pl.id = pv.picklist_id
    WHERE pl.picklist_id = v_picklist_code
      AND pv.ref_id      = v_reason_code
      AND pv.active      = true
  ) INTO v_reason_valid;

  IF NOT v_reason_valid THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('termination_reason_code %s is not valid for picklist %s.',
             v_reason_code, v_picklist_code));
  END IF;

  -- ── 6. SELF-specific validations ───────────────────────────────────────────
  IF v_initiation_type = 'SELF' THEN
    IF v_resignation_date IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'resignation_date is required for self-service termination.');
    END IF;
    IF v_last_working_date IS NOT NULL AND v_last_working_date < v_resignation_date THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'last_working_date must be on or after resignation_date.');
    END IF;
  END IF;

  -- ── 7. Read notice_period_days from employment slice ──────────────────────
  SELECT notice_period_days INTO v_notice_period_days
  FROM   employee_employment
  WHERE  employee_id   = p_employee_id
    AND  effective_from <= v_termination_date
    AND  effective_to   >  v_termination_date
    AND  is_active      = true
  ORDER  BY effective_from DESC
  LIMIT  1;

  IF v_notice_period_days IS NULL THEN
    SELECT notice_period_days INTO v_notice_period_days
    FROM   employee_employment
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
    LIMIT 1;
  END IF;

  IF v_notice_period_days IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No active employment record found covering the termination date.');
  END IF;

  -- ── 8. Notice period enforcement ──────────────────────────────────────────
  IF v_initiation_type = 'SELF' AND v_last_working_date IS NOT NULL THEN
    v_required_lwd := v_resignation_date + v_notice_period_days;
    IF v_last_working_date < v_required_lwd THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('last_working_date must be on or after %s (resignation_date + %s notice days).',
               v_required_lwd, v_notice_period_days));
    END IF;
  ELSIF v_initiation_type <> 'SELF' AND v_last_working_date IS NOT NULL THEN
    v_required_lwd := v_termination_date + v_notice_period_days;
    IF v_last_working_date < v_required_lwd THEN
      v_waived := true;
      IF v_waiver_reason IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('notice_period_waiver_reason is required: last_working_date is before %s.',
                 v_required_lwd));
      END IF;
    END IF;
  END IF;

  -- ── 9. Strip HR-only fields from SELF submissions ─────────────────────────
  IF v_initiation_type = 'SELF' THEN
    v_eligible_for_rehire := true;
    v_regrettable         := NULL;
  END IF;

  -- ── 10. Insert DRAFT row ───────────────────────────────────────────────────
  INSERT INTO employee_terminations (
    employee_id, termination_date, termination_reason_code,
    termination_initiation_type, resignation_date, notice_date, last_working_date,
    notice_period_waived, notice_period_waiver_reason,
    eligible_for_rehire, regrettable_termination, comments,
    workflow_status, created_by, updated_by
  ) VALUES (
    p_employee_id, v_termination_date, v_reason_code,
    v_initiation_type, v_resignation_date, v_notice_date, v_last_working_date,
    v_waived, v_waiver_reason,
    v_eligible_for_rehire, v_regrettable, v_comments,
    'DRAFT', auth.uid(), auth.uid()
  )
  RETURNING id INTO v_termination_id;

  -- ── 11. Workflow template routing ─────────────────────────────────────────
  v_template_code := CASE v_initiation_type
    WHEN 'SELF'               THEN 'termination_self'
    WHEN 'MANAGER_INITIATED'  THEN 'termination_manager'
    ELSE                           'termination_hr'   -- HR_INITIATED, ADMIN_INITIATED
  END;

  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => 'termination',
    p_record_id     => v_termination_id,
    p_metadata      => jsonb_build_object(
      'employee_id',     p_employee_id,
      'termination_date', v_termination_date,
      'initiation_type', v_initiation_type
    )
  );

  -- ── 12. Flip to PENDING ────────────────────────────────────────────────────
  UPDATE employee_terminations
  SET    workflow_status      = 'PENDING',
         workflow_instance_id = v_instance_id,
         updated_at           = NOW(),
         updated_by           = auth.uid()
  WHERE  id = v_termination_id;

  -- ── 13. Attachments ────────────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_termination_attachments (
      termination_id, file_name, original_file_name,
      file_path, file_size_bytes, mime_type, uploaded_by
    ) VALUES (
      v_termination_id,
      v_att->>'file_name',
      COALESCE(v_att->>'original_file_name', v_att->>'file_name'),
      v_att->>'file_path',
      (v_att->>'file_size_bytes')::integer,
      v_att->>'mime_type',
      auth.uid()
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                   true,
    'termination_id',       v_termination_id,
    'workflow_instance_id', v_instance_id,
    'workflow_status',      'PENDING'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination(uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination(uuid, jsonb, jsonb) IS
  'Mig 489: initial. '
  'Mig 491: MANAGER_INITIATED type added; permission check extended for direct managers; '
  'routing to termination_manager template.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm constraint allows all 5 types
SELECT conname, pg_get_constraintdef(oid)
FROM   pg_constraint
WHERE  conrelid = 'employee_terminations'::regclass
  AND  conname  = 'employee_terminations_termination_initiation_type_check';

-- =============================================================================
-- END OF MIGRATION 491
-- =============================================================================
