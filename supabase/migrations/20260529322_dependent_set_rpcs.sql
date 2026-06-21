-- =============================================================================
-- Migration 302: dependent set RPCs
--
-- DESIGN REFERENCE
-- ────────────────
-- See docs/set-snapshot-design.md, Section 4.1.
--
-- WHAT
-- ────
-- Four new SECURITY DEFINER RPCs that operate on the set-snapshot tables
-- created in mig 301:
--
--   1. get_employee_dependent_set(p_employee_id, p_as_of)
--      — read the set active on a given date plus its items + attachments
--
--   2. get_employee_dependent_set_history(p_employee_id)
--      — every historical set, newest-first, with items
--
--   3. submit_dependent_set(p_employee_id, p_effective_from, p_items)
--      — main write entry point. Dual-path (workflow vs direct).
--        Snaps effective_from to 1st of month.
--
--   4. fn_apply_dependent_set_transition(p_employee_id, p_effective_from,
--      p_items, p_actor)
--      — internal: closes current set, inserts new set + items, assigns
--        dependent_code to NEW items, persists per-item attachment rows.
--        Called directly (PATH A) or from apply_profile_pending_change (PATH B,
--        wired up in mig 303).
--
-- WHAT THIS MIGRATION DOES *NOT* DO
-- ─────────────────────────────────
-- • Does not touch the legacy upsert_dependent / remove_dependent /
--   get_employee_dependents RPCs (they stay alive until cleanup mig)
-- • Does not modify apply_profile_pending_change (mig 303 does that)
-- • Does not backfill data (mig 304)
--
-- IMPLICIT CONTRACTS
-- ──────────────────
-- • proposed_data shape (Section 5.2):
--     { employee_id, effective_from, items: [ { dependent_code?, relationship_type,
--                                               dependent_name, date_of_birth,
--                                               gender, insurance_eligible,
--                                               attachments?: [...] }, ... ] }
-- • NEW items have dependent_code = null and get an auto-assigned code
--   ({EMP_CODE}_DEP_NN, mirroring the legacy fn_generate_dependent_code format)
--   in fn_apply_dependent_set_transition
-- • record_id in workflow_instances / workflow_pending_changes = p_employee_id
--   (UUID, no column type change required — see design doc §5.1)
--
-- ROLLBACK
-- ────────
-- DROP FUNCTION submit_dependent_set(uuid, date, jsonb);
-- DROP FUNCTION fn_apply_dependent_set_transition(uuid, date, jsonb, uuid);
-- DROP FUNCTION get_employee_dependent_set(uuid, date);
-- DROP FUNCTION get_employee_dependent_set_history(uuid);
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_employee_dependent_set
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_employee_dependent_set(UUID, DATE);

CREATE OR REPLACE FUNCTION get_employee_dependent_set(
  p_employee_id UUID,
  p_as_of       DATE DEFAULT CURRENT_DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_set_row   employee_dependent_set%ROWTYPE;
  v_items     JSONB;
BEGIN
  -- Access guard mirrors the SELECT RLS policy from mig 301
  IF NOT (
    is_super_admin()
    OR user_can('dependents', 'view', p_employee_id)
    OR (
      user_can('dependents', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = p_employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'Access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  -- Find the set whose effective range contains p_as_of
  SELECT *
    INTO v_set_row
  FROM employee_dependent_set
  WHERE employee_id    = p_employee_id
    AND is_active      = true
    AND effective_from <= p_as_of
    AND effective_to   >= p_as_of
  ORDER BY effective_from DESC
  LIMIT 1;

  IF v_set_row.id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',    true,
      'set',   NULL,
      'items', '[]'::jsonb
    );
  END IF;

  -- Build items array, joining attachments by dependent_code (stable identity)
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',                  i.id,
        'dependent_code',      i.dependent_code,
        'relationship_type',   i.relationship_type,
        'dependent_name',      i.dependent_name,
        'date_of_birth',       i.date_of_birth,
        'gender',              i.gender,
        'insurance_eligible',  i.insurance_eligible,
        'attachments', COALESCE(
          (
            SELECT jsonb_agg(jsonb_build_object(
              'id',                 a.id,
              'document_type',      a.document_type,
              'file_name',          a.file_name,
              'original_file_name', a.original_file_name,
              'file_path',          a.file_path,
              'mime_type',          a.mime_type,
              'file_size',          a.file_size,
              'uploaded_at',        a.uploaded_at
            ) ORDER BY a.uploaded_at)
            FROM employee_dependent_attachments a
            WHERE a.dependent_code = i.dependent_code
              AND a.is_active IS NOT FALSE
          ),
          '[]'::jsonb
        )
      )
      ORDER BY i.dependent_code
    ),
    '[]'::jsonb
  )
    INTO v_items
  FROM employee_dependent_item i
  WHERE i.set_id = v_set_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'set', jsonb_build_object(
      'id',             v_set_row.id,
      'employee_id',    v_set_row.employee_id,
      'effective_from', v_set_row.effective_from,
      'effective_to',   v_set_row.effective_to,
      'is_active',      v_set_row.is_active,
      'created_at',     v_set_row.created_at
    ),
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION get_employee_dependent_set(UUID, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_employee_dependent_set(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION get_employee_dependent_set(UUID, DATE) IS
  'Returns the dependent set active on p_as_of for an employee, with items '
  'and per-item attachments (joined by stable dependent_code). '
  'SECURITY DEFINER: enforces the same Path A + Path B HR-guard as the RLS '
  'policy on employee_dependent_set. Mig 302.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_employee_dependent_set_history
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_employee_dependent_set_history(UUID);

CREATE OR REPLACE FUNCTION get_employee_dependent_set_history(
  p_employee_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_sets JSONB;
BEGIN
  -- Reuse the SELECT guard — history requires either view or the dedicated
  -- dependents.history permission.
  IF NOT (
    is_super_admin()
    OR user_can('dependents', 'history', p_employee_id)
    OR user_can('dependents', 'view',    p_employee_id)
    OR (
      user_can('dependents', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = p_employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'Access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'set_id',         s.id,
        'effective_from', s.effective_from,
        'effective_to',   s.effective_to,
        'is_active',      s.is_active,
        'created_at',     s.created_at,
        'item_count',     COALESCE(item_counts.cnt, 0),
        'items',          COALESCE(items.items, '[]'::jsonb)
      )
      ORDER BY s.effective_from DESC
    ),
    '[]'::jsonb
  )
    INTO v_sets
  FROM employee_dependent_set s
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INTEGER AS cnt
    FROM employee_dependent_item
    WHERE set_id = s.id
  ) item_counts ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id',                 i.id,
        'dependent_code',     i.dependent_code,
        'relationship_type',  i.relationship_type,
        'dependent_name',     i.dependent_name,
        'date_of_birth',      i.date_of_birth,
        'gender',             i.gender,
        'insurance_eligible', i.insurance_eligible
      )
      ORDER BY i.dependent_code
    ) AS items
    FROM employee_dependent_item i
    WHERE i.set_id = s.id
  ) items ON true
  WHERE s.employee_id = p_employee_id;

  RETURN jsonb_build_object('ok', true, 'sets', v_sets);
END;
$$;

REVOKE ALL ON FUNCTION get_employee_dependent_set_history(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_employee_dependent_set_history(UUID) TO authenticated;

COMMENT ON FUNCTION get_employee_dependent_set_history(UUID) IS
  'Returns every dependent set for the employee in reverse chronological '
  'order, with items and item counts but WITHOUT attachments (use '
  'get_employee_dependent_set for attachment payloads). Mig 302.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. fn_apply_dependent_set_transition (internal)
--
-- Idempotent transition that materialises a proposed set against the current
-- state. Trusts its caller for access checks — only called from
-- submit_dependent_set (PATH A) and apply_profile_pending_change (PATH B).
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID);

CREATE OR REPLACE FUNCTION fn_apply_dependent_set_transition(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_actor          UUID
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_set_id      UUID;
  v_current_set_id  UUID;
  v_curr_eff_from   DATE;
  v_emp_code        TEXT;
  v_max_seq         INTEGER := 0;
  v_item            JSONB;
  v_dep_code        TEXT;
  v_attachment      JSONB;
BEGIN
  -- Advisory lock per employee to serialise concurrent transitions
  PERFORM pg_advisory_xact_lock(hashtext('dep_set:' || p_employee_id::TEXT));

  -- 1. Find and close current active set (if any)
  SELECT id, effective_from
    INTO v_current_set_id, v_curr_eff_from
  FROM employee_dependent_set
  WHERE employee_id    = p_employee_id
    AND is_active      = true
    AND effective_to   = '9999-12-31'::date
  LIMIT 1;

  IF v_current_set_id IS NOT NULL THEN
    IF p_effective_from <= v_curr_eff_from THEN
      -- Same-day or earlier effective date — delete the current set (no
      -- historical record value, and the chk_dep_set_effective_order check
      -- would reject closure with a negative window). Items cascade.
      DELETE FROM employee_dependent_set WHERE id = v_current_set_id;
    ELSE
      UPDATE employee_dependent_set
         SET effective_to = p_effective_from - 1,
             updated_at   = NOW()
       WHERE id = v_current_set_id;
    END IF;
  END IF;

  -- 2. Insert new set
  INSERT INTO employee_dependent_set (
    employee_id, effective_from, effective_to, is_active, created_by
  ) VALUES (
    p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor
  )
  RETURNING id INTO v_new_set_id;

  -- 3. Pre-compute next dependent_code sequence for this employee
  SELECT employee_id INTO v_emp_code
  FROM employees
  WHERE id = p_employee_id;

  IF v_emp_code IS NULL THEN
    RAISE EXCEPTION 'fn_apply_dependent_set_transition: employee % not found', p_employee_id;
  END IF;

  -- Highest existing _DEP_NN sequence across all of this employee's items
  -- (across all sets — keeps codes monotonically unique forever).
  SELECT COALESCE(MAX(
    (regexp_match(i.dependent_code, '_DEP_(\d+)$'))[1]::INTEGER
  ), 0)
    INTO v_max_seq
  FROM employee_dependent_item i
  JOIN employee_dependent_set  s ON s.id = i.set_id
  WHERE s.employee_id = p_employee_id;

  -- Also factor legacy table during transition window so codes don't collide
  -- with anything that still lives in employee_dependents.
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'employee_dependents') THEN
    DECLARE
      v_legacy_max INTEGER;
    BEGIN
      EXECUTE format($q$
        SELECT COALESCE(MAX(
          (regexp_match(dependent_code, '_DEP_(\d+)$'))[1]::INTEGER
        ), 0)
        FROM employee_dependents
        WHERE employee_id = %L
      $q$, p_employee_id) INTO v_legacy_max;
      IF v_legacy_max > v_max_seq THEN
        v_max_seq := v_legacy_max;
      END IF;
    END;
  END IF;

  -- 4. Insert items, generating dependent_code for new entries
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dep_code := NULLIF(v_item->>'dependent_code', '');

    IF v_dep_code IS NULL THEN
      v_max_seq  := v_max_seq + 1;
      v_dep_code := v_emp_code || '_DEP_' || LPAD(v_max_seq::TEXT, 2, '0');
    END IF;

    INSERT INTO employee_dependent_item (
      set_id,
      dependent_code,
      relationship_type,
      dependent_name,
      date_of_birth,
      gender,
      insurance_eligible
    ) VALUES (
      v_new_set_id,
      v_dep_code,
      v_item->>'relationship_type',
      v_item->>'dependent_name',
      (v_item->>'date_of_birth')::date,
      v_item->>'gender',
      COALESCE((v_item->>'insurance_eligible')::boolean, false)
    );

    -- 5. Persist any NEW attachment rows for this dependent_code.
    -- Existing attachments (rows already in employee_dependent_attachments)
    -- continue to live; we only insert files that weren't previously linked.
    IF jsonb_typeof(v_item->'attachments') = 'array' THEN
      FOR v_attachment IN SELECT * FROM jsonb_array_elements(v_item->'attachments') LOOP
        IF NOT EXISTS (
          SELECT 1
          FROM employee_dependent_attachments a
          WHERE a.dependent_code = v_dep_code
            AND a.file_path     = v_attachment->>'file_path'
        ) THEN
          INSERT INTO employee_dependent_attachments (
            dependent_code,
            employee_id,
            document_type,
            file_name,
            original_file_name,
            file_path,
            mime_type,
            file_size,
            is_active,
            uploaded_by,
            created_by
          ) VALUES (
            v_dep_code,
            p_employee_id,
            NULLIF(v_attachment->>'document_type', ''),
            v_attachment->>'file_name',
            COALESCE(v_attachment->>'original_file_name', v_attachment->>'file_name'),
            v_attachment->>'file_path',
            v_attachment->>'mime_type',
            (v_attachment->>'file_size')::bigint,
            true,
            p_actor,
            p_actor
          );
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) FROM PUBLIC;
-- Internal use only — granted to authenticated for SECURITY DEFINER invocation
-- from submit_dependent_set and the apply_profile_pending_change trigger.
GRANT EXECUTE ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) IS
  'Internal: materialises a proposed dependent set against the current state. '
  'Closes (or deletes if same-day) the current open set, inserts a new set + '
  'items, auto-assigns dependent_code to NEW items, persists new attachment '
  'rows. Called from submit_dependent_set (PATH A) and from '
  'apply_profile_pending_change (PATH B, wired in mig 303). '
  'Trusts its caller for access checks. Mig 302.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. submit_dependent_set (main write entry point)
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS submit_dependent_set(UUID, DATE, JSONB);

CREATE OR REPLACE FUNCTION submit_dependent_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor                UUID := auth.uid();
  v_effective_snap       DATE;
  v_item_count           INTEGER;
  v_template_id          UUID;
  v_template_code        TEXT;
  v_workflow_pending_id  UUID;
  v_instance_id          UUID;
  v_employee_name        TEXT;
  v_set_id               UUID;
  v_current_set_id       UUID;
  v_current_codes        TEXT[];
  v_proposed_codes       TEXT[];
  v_added_count          INTEGER;
  v_removed_count        INTEGER;
  v_change_summary       TEXT;
  v_item                 JSONB;
  v_seen_codes           TEXT[] := ARRAY[]::TEXT[];
  v_code                 TEXT;
BEGIN
  -- ── Snap effective_from to 1st of month (Section 4.1 §3 of design doc) ──
  v_effective_snap := date_trunc('month', p_effective_from)::date;

  -- ── Validate shape ─────────────────────────────────────────────────────
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'submit_dependent_set: p_items must be a JSONB array';
  END IF;

  v_item_count := jsonb_array_length(p_items);

  -- ── Access guard ───────────────────────────────────────────────────────
  IF NOT (
    is_super_admin()
    OR user_can('dependents', 'edit',   p_employee_id)
    OR user_can('dependents', 'create', p_employee_id)
    OR user_can('dependents', 'delete', p_employee_id)
    OR (
      -- Hire-pipeline path (admin/HR editing draft/pending employee)
      user_can('dependents', 'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = p_employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'Access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  -- ── Per-item validation + duplicate-code detection ────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NOT (v_item ? 'relationship_type'
            AND v_item ? 'dependent_name'
            AND v_item ? 'date_of_birth'
            AND v_item ? 'gender') THEN
      RAISE EXCEPTION 'submit_dependent_set: each item must include relationship_type, dependent_name, date_of_birth, gender';
    END IF;

    IF v_item->>'gender' NOT IN ('Male', 'Female') THEN
      RAISE EXCEPTION 'submit_dependent_set: gender must be Male or Female';
    END IF;

    IF (v_item->>'date_of_birth')::date > CURRENT_DATE THEN
      RAISE EXCEPTION 'submit_dependent_set: date_of_birth cannot be in the future';
    END IF;

    v_code := NULLIF(v_item->>'dependent_code', '');
    IF v_code IS NOT NULL THEN
      IF v_code = ANY(v_seen_codes) THEN
        RAISE EXCEPTION 'submit_dependent_set: duplicate dependent_code % within proposed set', v_code;
      END IF;
      v_seen_codes := array_append(v_seen_codes, v_code);
    END IF;
  END LOOP;

  -- ── Lookup employee name for workflow metadata ────────────────────────
  SELECT name INTO v_employee_name FROM employees WHERE id = p_employee_id;

  -- ── Compute add/remove counts for the change summary ──────────────────
  SELECT id INTO v_current_set_id
  FROM employee_dependent_set
  WHERE employee_id = p_employee_id
    AND is_active = true
    AND effective_to = '9999-12-31'::date
  LIMIT 1;

  v_current_codes := ARRAY[]::TEXT[];
  IF v_current_set_id IS NOT NULL THEN
    SELECT COALESCE(array_agg(dependent_code), ARRAY[]::TEXT[])
      INTO v_current_codes
    FROM employee_dependent_item WHERE set_id = v_current_set_id;
  END IF;

  v_proposed_codes := COALESCE(
    ARRAY(
      SELECT (item->>'dependent_code')
      FROM jsonb_array_elements(p_items) AS item
      WHERE NULLIF(item->>'dependent_code', '') IS NOT NULL
    ),
    ARRAY[]::TEXT[]
  );

  v_added_count := (
    SELECT COUNT(*)::INTEGER
    FROM jsonb_array_elements(p_items) AS item
    WHERE NULLIF(item->>'dependent_code', '') IS NULL
  );

  v_removed_count := (
    SELECT COUNT(*)::INTEGER
    FROM unnest(v_current_codes) AS c
    WHERE c <> ALL(v_proposed_codes)
  );

  v_change_summary := format(
    '%s added, %s removed, %s items in proposed set',
    v_added_count, v_removed_count, v_item_count
  );

  -- ── Resolve workflow assignment ───────────────────────────────────────
  v_template_id := resolve_workflow_for_submission('profile_dependents', v_actor);

  IF v_template_id IS NOT NULL THEN
    -- ── PATH B — stage to workflow_pending_changes + wf_submit ─────────
    SELECT code INTO v_template_code FROM workflow_templates WHERE id = v_template_id;

    INSERT INTO workflow_pending_changes (
      module_code, record_id, status, submitted_by, proposed_data, created_at
    ) VALUES (
      'profile_dependents',
      p_employee_id,
      'pending',
      v_actor,
      jsonb_build_object(
        'employee_id',    p_employee_id,
        'effective_from', v_effective_snap,
        'items',          p_items
      ),
      NOW()
    )
    RETURNING id INTO v_workflow_pending_id;

    BEGIN
      v_instance_id := wf_submit(
        p_template_code => v_template_code,
        p_module_code   => 'profile_dependents',
        p_record_id     => p_employee_id,
        p_metadata      => jsonb_build_object(
          'name',              v_employee_name,
          'employee_id',       p_employee_id,
          'submission_type',   'set_update',
          'item_count',        v_item_count,
          'added_count',       v_added_count,
          'removed_count',     v_removed_count,
          'change_summary',    v_change_summary,
          'pending_change_id', v_workflow_pending_id,
          'effective_from',    v_effective_snap
        ),
        p_comment       => NULL
      );
    EXCEPTION WHEN OTHERS THEN
      -- Roll back staging if wf_submit failed (typical: no active template,
      -- assignment misconfigured, or a workflow_steps row missing)
      DELETE FROM workflow_pending_changes WHERE id = v_workflow_pending_id;
      RAISE;
    END;

    RETURN jsonb_build_object(
      'ok',                true,
      'workflow',          true,
      'instance_id',       v_instance_id,
      'pending_change_id', v_workflow_pending_id,
      'effective_from',    v_effective_snap,
      'change_summary',    v_change_summary
    );
  ELSE
    -- ── PATH A — direct write ─────────────────────────────────────────
    v_set_id := fn_apply_dependent_set_transition(
      p_employee_id    => p_employee_id,
      p_effective_from => v_effective_snap,
      p_items          => p_items,
      p_actor          => v_actor
    );

    RETURN jsonb_build_object(
      'ok',             true,
      'workflow',       false,
      'set_id',         v_set_id,
      'effective_from', v_effective_snap,
      'change_summary', v_change_summary
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION submit_dependent_set(UUID, DATE, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_dependent_set(UUID, DATE, JSONB) TO authenticated;

COMMENT ON FUNCTION submit_dependent_set(UUID, DATE, JSONB) IS
  'Main write entry point for set-snapshot dependents. Dual-path: '
  'stages to workflow_pending_changes + wf_submit when a workflow is '
  'assigned (PATH B), otherwise calls fn_apply_dependent_set_transition '
  'directly (PATH A). Snaps effective_from to 1st of month. Returns '
  'jsonb { ok, workflow, instance_id|set_id, effective_from, change_summary }. '
  'Mig 302.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_fn_count INTEGER;
BEGIN
  SELECT COUNT(*)
    INTO v_fn_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname IN (
      'get_employee_dependent_set',
      'get_employee_dependent_set_history',
      'fn_apply_dependent_set_transition',
      'submit_dependent_set'
    );

  IF v_fn_count < 4 THEN
    RAISE EXCEPTION 'mig 302: expected 4 dependent set RPCs, found %', v_fn_count;
  END IF;

  RAISE NOTICE 'mig 302: 4 dependent set RPCs created';
END
$$;
