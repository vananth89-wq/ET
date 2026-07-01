-- =============================================================================
-- Mig 650: fix termination LWD off-by-one — redeploy corrected functions
--
-- Bug: every path that decides whether to finalize a termination used
-- `last_working_date <= CURRENT_DATE`, which fires ON the LWD itself.
-- An employee with LWD = today is Active all day; finalization must happen
-- the day AFTER (i.e. LWD < today, not <=).
--
-- The source files for migs 584, 600, 625, 627, 630 were edited in place in
-- the repo, but those migrations are already tracked in schema_migrations and
-- will NOT be re-applied by `db push`. This migration re-deploys the two
-- affected functions with the corrected `< CURRENT_DATE` check.
-- =============================================================================

-- ── 1. submit_termination (canonical: mig 600) ───────────────────────────────

CREATE OR REPLACE FUNCTION submit_termination(
  p_employee_id      uuid,
  p_termination_data jsonb,
  p_attachments      jsonb DEFAULT '[]',
  p_comment          text  DEFAULT NULL,
  p_reassignments    jsonb DEFAULT '[]'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Initiation
  v_initiation_type           text;
  v_employee_name             text;

  -- Payload fields
  v_separation_date           date;
  v_reason_code               text;
  v_last_working_date         date;
  v_waived                    boolean;
  v_waiver_reason             text;
  v_eligible_for_rehire       boolean;
  v_regrettable               boolean;
  v_comments                  text;

  -- Notice period
  v_notice_period_days        int;
  v_notice_expiry_date        date;

  -- Workflow
  v_template_id               uuid;
  v_template_code             text;
  v_termination_id            uuid;
  v_instance_id               uuid;

  -- Post-approval execution
  v_slice_result              jsonb;
  v_finalize_result           jsonb;
BEGIN

  -- ── 1. Derive initiation type ──────────────────────────────────────────────
  v_initiation_type := derive_termination_initiation_type(p_employee_id);

  -- ── 1b. Fetch employee name for metadata ───────────────────────────────────
  SELECT name INTO v_employee_name FROM employees WHERE id = p_employee_id;

  -- ── 2. Permission gate ─────────────────────────────────────────────────────
  IF v_initiation_type = 'SELF' THEN
    IF NOT (
      user_can('termination', 'edit', p_employee_id)
      OR user_can('termination', 'edit', NULL)
      OR get_my_employee_id() = p_employee_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
    END IF;
  ELSE
    IF NOT (
      user_can('termination', 'edit', p_employee_id)
      OR user_can('termination', 'edit', NULL)
      OR get_my_employee_id() = p_employee_id
      OR EXISTS (
           SELECT 1 FROM employees
           WHERE  id         = p_employee_id
             AND  manager_id = get_my_employee_id()
         )
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
    END IF;
  END IF;

  -- ── 3. Extract payload ─────────────────────────────────────────────────────
  v_separation_date     := (p_termination_data->>'separation_date')::date;
  v_reason_code         :=  p_termination_data->>'termination_reason_code';
  v_last_working_date   := COALESCE(
                             (p_termination_data->>'last_working_date')::date,
                             v_separation_date
                           );
  v_waived              := COALESCE((p_termination_data->>'notice_period_waived')::boolean, false);
  v_waiver_reason       :=  p_termination_data->>'notice_period_waiver_reason';
  v_eligible_for_rehire := COALESCE((p_termination_data->>'eligible_for_rehire')::boolean, true);
  v_regrettable         := (p_termination_data->>'regrettable_termination')::boolean;
  v_comments            :=  p_termination_data->>'comments';

  -- ── 4. Validation ──────────────────────────────────────────────────────────
  IF v_separation_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'separation_date is required.');
  END IF;
  IF v_reason_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_reason_code is required.');
  END IF;

  -- ── 5. Notice period snapshot (from employee_employment) ──────────────────
  SELECT COALESCE(ee.notice_period_days, 30)
  INTO   v_notice_period_days
  FROM   employee_employment ee
  WHERE  ee.employee_id  = p_employee_id
    AND  ee.effective_to = '9999-12-31'::date
    AND  ee.is_active    = true
  ORDER  BY ee.effective_from DESC
  LIMIT  1;

  v_notice_period_days := COALESCE(v_notice_period_days, 30);
  v_notice_expiry_date := v_separation_date + (v_notice_period_days || ' days')::interval;

  -- ── 6. Duplicate guard ─────────────────────────────────────────────────────
  -- REVERSED is treated as terminal alongside WITHDRAWN and REJECTED.
  IF EXISTS (
    SELECT 1 FROM employee_terminations
    WHERE  employee_id     = p_employee_id
      AND  workflow_status NOT IN ('WITHDRAWN', 'REJECTED', 'REVERSED')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'An active termination already exists for this employee.');
  END IF;

  -- ── 7. Resolve workflow template ───────────────────────────────────────────
  v_template_id := resolve_workflow_for_submission('termination', auth.uid());

  IF v_template_id IS NOT NULL THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ── 8. Insert DRAFT row ────────────────────────────────────────────────────
  INSERT INTO employee_terminations (
    employee_id,
    separation_date,
    notice_expiry_date,
    notice_period_days_snapshot,
    last_working_date,
    termination_reason_code,
    termination_initiation_type,
    notice_period_waived,
    notice_period_waiver_reason,
    eligible_for_rehire,
    regrettable_termination,
    comments,
    direct_report_reassignments,
    workflow_status,
    created_by,
    updated_by
  ) VALUES (
    p_employee_id,
    v_separation_date,
    v_notice_expiry_date,
    v_notice_period_days,
    v_last_working_date,
    v_reason_code,
    v_initiation_type,
    v_waived,
    v_waiver_reason,
    v_eligible_for_rehire,
    v_regrettable,
    v_comments,
    COALESCE(p_reassignments, '[]'::jsonb),
    'DRAFT',
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_termination_id;

  -- ── 9. Direct-save path (no workflow configured) ───────────────────────────
  IF v_template_id IS NULL THEN
    -- Mark approved
    UPDATE employee_terminations
    SET    workflow_status = 'APPROVED', updated_at = now()
    WHERE  id = v_termination_id;

    -- Phase 1: insert employment slices (always)
    v_slice_result := fn_pre_insert_termination_slices(v_termination_id);

    -- Phase 2: finalize immediately only if LWD strictly before today
    -- < not <=: employee is Active on their LWD, Inactive the day after
    IF v_last_working_date < CURRENT_DATE THEN
      v_finalize_result := fn_finalize_termination_execution(v_termination_id);
    END IF;

    RETURN jsonb_build_object(
      'ok',             true,
      'termination_id', v_termination_id,
      'workflow',       false,
      'slices',         v_slice_result,
      'finalize',       v_finalize_result
    );
  END IF;

  -- ── 10. Launch workflow ────────────────────────────────────────────────────
  v_instance_id := wf_submit(
    p_template_code       => v_template_code,
    p_module_code         => 'termination',
    p_record_id           => v_termination_id,
    p_metadata            => jsonb_build_object(
                               'employee_id',       p_employee_id,
                               'employee_name',     v_employee_name,
                               'separation_date',   v_separation_date,
                               'reason_code',       v_reason_code,
                               'last_working_date', v_last_working_date,
                               'initiation_type',   v_initiation_type
                             ),
    p_comment             => p_comment,
    p_subject_employee_id => p_employee_id
  );

  UPDATE employee_terminations
  SET    workflow_instance_id = v_instance_id,
         workflow_status      = 'PENDING',
         updated_at           = now()
  WHERE  id = v_termination_id;

  RETURN jsonb_build_object(
    'ok',             true,
    'termination_id', v_termination_id,
    'instance_id',    v_instance_id,
    'workflow',       true
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) IS
  'Mig 650: LWD finalization condition changed to < CURRENT_DATE (was <=). '
  'Employee is Active on LWD; finalization runs the day after. '
  'Otherwise identical to mig 600.';

-- ── 2. wf_sync_module_status (canonical: mig 630) ───────────────────────────

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id    uuid;
  v_termination_id uuid;
  v_rows_affected  integer;
  v_lwd            date;
BEGIN

  -- ── Expense Reports ────────────────────────────────────────────────────────
  IF p_module_code = 'expense_reports' THEN

    IF p_status = 'approved' THEN
      SELECT employee_id INTO v_employee_id
      FROM   profiles WHERE id = auth.uid();
    END IF;

    UPDATE expense_reports
    SET
      status      = p_status::expense_status,
      approved_at = CASE WHEN p_status = 'approved' THEN now()         ELSE approved_at END,
      approved_by = CASE WHEN p_status = 'approved' THEN v_employee_id ELSE approved_by END,
      updated_at  = now()
    WHERE id = p_record_id;

  -- ── Profile change modules ─────────────────────────────────────────────────
  ELSIF p_module_code LIKE 'profile_%' THEN

    UPDATE workflow_pending_changes
    SET
      status =
        CASE p_status
          WHEN 'submitted'              THEN 'pending'
          WHEN 'in_progress'            THEN 'pending'
          WHEN 'awaiting_clarification' THEN 'pending'
          WHEN 'draft'                  THEN 'withdrawn'
          WHEN 'cancelled'              THEN 'withdrawn'
          WHEN 'approved'               THEN 'approved'
          WHEN 'rejected'               THEN 'rejected'
          WHEN 'withdrawn'              THEN 'withdrawn'
          ELSE status
        END,
      resolved_at =
        CASE
          WHEN p_status IN ('approved', 'rejected', 'draft', 'withdrawn', 'cancelled')
          THEN now()
          ELSE NULL
        END
    WHERE id = p_record_id;

  -- ── Employee Hire ──────────────────────────────────────────────────────────
  ELSIF p_module_code = 'employee_hire' THEN

    IF p_status IN ('submitted', 'in_progress') THEN
      UPDATE employees
      SET    status     = 'Pending',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'approved' THEN
      RAISE LOG 'wf_sync_module_status: activating employee % (hire approved)', p_record_id;

      UPDATE employees
      SET    status     = 'Active',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

      GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
      RAISE LOG 'wf_sync_module_status: employee % activation UPDATE affected % row(s)',
                p_record_id, v_rows_affected;

      IF v_rows_affected = 0 THEN
        RAISE WARNING 'wf_sync_module_status: employee % NOT found or UPDATE matched 0 rows — status may be stuck at Draft',
                      p_record_id;
      END IF;

    ELSIF p_status = 'rejected' THEN
      UPDATE employees
      SET    status     = 'Rejected',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'awaiting_clarification' THEN
      UPDATE employees
      SET    status     = 'Incomplete',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'draft' THEN
      UPDATE employees
      SET    deleted_at = now(),
             updated_at = now()
      WHERE  id      = p_record_id
        AND  status != 'Active';

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for employee_hire — record unchanged',
        p_status;
    END IF;

  -- ── Primary Termination ────────────────────────────────────────────────────
  ELSIF p_module_code = 'termination' THEN

    IF p_status = 'approved' THEN
      UPDATE employee_terminations
      SET    workflow_status = 'APPROVED',
             approved_at    = now(),
             approved_by    = auth.uid(),
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = p_record_id;

      BEGIN
        PERFORM fn_pre_insert_termination_slices(p_record_id);
        RAISE LOG 'wf_sync_module_status: fn_pre_insert completed for termination %', p_record_id;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'wf_sync_module_status: fn_pre_insert failed for % — % (Re-run button will appear)',
                      p_record_id, SQLERRM;
      END;

      SELECT COALESCE(last_working_date, separation_date)
      INTO   v_lwd
      FROM   employee_terminations
      WHERE  id = p_record_id;

      -- < not <=: employee is Active on LWD; finalize the day after
      IF v_lwd IS NOT NULL AND v_lwd < CURRENT_DATE THEN
        BEGIN
          PERFORM fn_finalize_termination_execution(p_record_id);
          RAISE LOG 'wf_sync_module_status: fn_finalize completed for termination %', p_record_id;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'wf_sync_module_status: fn_finalize failed for % — % (Re-run button will appear)',
                        p_record_id, SQLERRM;
        END;
      END IF;

    ELSIF p_status = 'rejected' THEN
      UPDATE employee_terminations
      SET    workflow_status = 'REJECTED',
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('draft', 'withdrawn', 'cancelled') THEN
      UPDATE employee_terminations
      SET    workflow_status      = 'WITHDRAWN',
             workflow_instance_id = NULL,
             updated_at           = now(),
             updated_by           = auth.uid()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('submitted', 'in_progress', 'awaiting_clarification') THEN
      NULL;

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for termination record % — unchanged',
        p_status, p_record_id;
    END IF;

  -- ── Termination Reversal ───────────────────────────────────────────────────
  ELSIF p_module_code = 'termination_reversal' THEN

    IF p_status = 'approved' THEN
      UPDATE employee_termination_reversals
      SET    workflow_status = 'APPROVED',
             approved_at    = now(),
             approved_by    = auth.uid(),
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = p_record_id;

      UPDATE employee_terminations
      SET    workflow_status = 'REVERSED',
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = (
        SELECT termination_id
        FROM   employee_termination_reversals
        WHERE  id = p_record_id
      );

      -- Revert employment slices
      BEGIN
        PERFORM fn_revert_termination_execution(p_record_id);
        RAISE LOG 'wf_sync_module_status: fn_revert completed for reversal %', p_record_id;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'wf_sync_module_status: fn_revert failed for % — % (EF will retry)',
                      p_record_id, SQLERRM;
      END;

    ELSIF p_status = 'rejected' THEN
      UPDATE employee_termination_reversals
      SET    workflow_status = 'REJECTED',
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('draft', 'withdrawn', 'cancelled') THEN
      UPDATE employee_termination_reversals
      SET    workflow_status      = 'WITHDRAWN',
             workflow_instance_id = NULL,
             updated_at           = now(),
             updated_by           = auth.uid()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('submitted', 'in_progress', 'awaiting_clarification') THEN
      NULL;

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for termination_reversal record % — unchanged',
        p_status, p_record_id;
    END IF;

  -- ── Unknown module ─────────────────────────────────────────────────────────
  ELSE
    RAISE NOTICE
      'wf_sync_module_status: unknown module_code %, record unchanged',
      p_module_code;
  END IF;

END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Mig 650: LWD finalization condition changed to < CURRENT_DATE (was <=) in the '
  'termination branch. Employee is Active on their LWD; finalization runs the day after. '
  'Otherwise identical to mig 630 (which added fn_revert to the termination_reversal branch).';
