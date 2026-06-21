-- =============================================================================
-- Migration 195: Auto-migrate workflow_assignments on template publish
--
-- PROBLEM
-- ───────
-- When an admin publishes a new template version (v2), any existing
-- workflow_assignments still reference the old version's template id (v1).
-- Because the Manage Assignments UI only lists active templates in its
-- dropdown, those assignments appear broken — the selector shows
-- "— select workflow —" even though a valid assignment record exists.
--
-- ROOT CAUSE
-- ──────────
-- wf_publish_template (mig 032) deactivates the old version and activates
-- the new one, but does NOT update workflow_assignments. The assignments are
-- left pointing at a template id that is now inactive and excluded from
-- dropdown queries.
--
-- SOLUTION (Option A — auto-migrate)
-- ───────────────────────────────────
-- After activating the new version, wf_publish_template now updates every
-- workflow_assignments row whose wf_template_id belongs to any older version
-- of the same template code family to point to the new template id.
--
-- WHY THIS IS SAFE
-- ────────────────
-- 1. In-flight workflow_instances are NOT affected — they store template_id
--    directly on the instance row (snapshotted at submission time), not via
--    workflow_assignments.
-- 2. The wa_no_overlap exclusion constraint is on (module_code, assignment_type,
--    entity_id_coalesced, daterange). We only update wf_template_id, so no
--    overlap violation is possible.
-- 3. The wa_audit_trigger fires automatically for each updated row, recording
--    old_template_id → new_template_id in workflow_assignment_audit. Zero extra
--    audit code is needed.
-- 4. Only active assignments are migrated (is_active = true). Inactive /
--    historically deactivated assignments are intentionally left as-is so the
--    audit trail remains accurate.
--
-- BEHAVIOUR CHANGE
-- ────────────────
-- Before: publish v2 → old assignments go "dark" (no template selected in UI)
-- After:  publish v2 → old assignments silently forward to v2, audit logged
-- =============================================================================


CREATE OR REPLACE FUNCTION wf_publish_template(p_template_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tpl           RECORD;
  v_migrated_count integer;
BEGIN
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_publish_template: permission denied';
  END IF;

  SELECT id, code, is_active, version
  INTO   v_tpl
  FROM   workflow_templates
  WHERE  id = p_template_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_publish_template: template % not found', p_template_id;
  END IF;

  IF v_tpl.is_active THEN
    RAISE EXCEPTION 'wf_publish_template: version % is already active', v_tpl.version;
  END IF;

  -- ── Step 1: deactivate current active version for this code (if any) ──────
  UPDATE workflow_templates
  SET    is_active   = false,
         updated_at  = now()
  WHERE  code        = v_tpl.code
    AND  is_active   = true;

  -- ── Step 2: activate the new version ──────────────────────────────────────
  UPDATE workflow_templates
  SET    is_active     = true,
         published_at  = now(),
         updated_at    = now()
  WHERE  id = p_template_id;

  -- ── Step 3: migrate active assignments from any older version ─────────────
  -- Find all active workflow_assignments that reference any template in the
  -- same code family (excluding the newly activated one) and forward them.
  -- The wa_audit_trigger fires automatically per row, recording the change.
  UPDATE workflow_assignments wa
  SET    wf_template_id = p_template_id,
         updated_at     = now()
  WHERE  wa.is_active = true
    AND  wa.wf_template_id IN (
           SELECT id
           FROM   workflow_templates
           WHERE  code = v_tpl.code
             AND  id   <> p_template_id
         );

  GET DIAGNOSTICS v_migrated_count = ROW_COUNT;

  -- Raise a notice so callers can surface the migration count if desired
  IF v_migrated_count > 0 THEN
    RAISE NOTICE 'wf_publish_template: migrated % assignment(s) from older version(s) of template code "%" to version %.',
                 v_migrated_count, v_tpl.code, v_tpl.version;
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_publish_template(uuid) IS
  'Promotes a draft template version to active, deactivating the previous active '
  'version for the same code. '
  'Auto-migrates all active workflow_assignments pointing to any older version of '
  'the same template code to the newly activated version (mig 195). '
  'Each migrated assignment is recorded in workflow_assignment_audit via trigger. '
  'In-flight workflow instances are unaffected — they snapshot template_id at '
  'submission time.';


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Function exists with migration marker in its body
SELECT
  proname,
  prosrc LIKE '%migrated_count%'           AS has_auto_migrate,
  prosrc LIKE '%older version(s)%'         AS has_notice
FROM pg_proc
WHERE proname = 'wf_publish_template';

-- 2. Current state: any assignments still pointing at inactive templates?
--    (Run after apply — should return 0 rows if you just published a new version)
SELECT wa.id, wa.module_code, wa.assignment_type, wt.code, wt.version, wt.is_active
FROM   workflow_assignments wa
JOIN   workflow_templates   wt ON wt.id = wa.wf_template_id
WHERE  wa.is_active  = true
  AND  wt.is_active  = false;

-- =============================================================================
-- END OF MIGRATION 195
--
-- After applying:
--   npx supabase db push
--
-- To fix the existing broken assignment (Personal Info Edit v1 → v2):
--   Call wf_publish_template() again with the v2 template id, OR
--   run the manual one-time backfill below:
--
--   UPDATE workflow_assignments wa
--   SET    wf_template_id = (
--            SELECT id FROM workflow_templates
--            WHERE  code      = wt_old.code
--              AND  is_active = true
--          ),
--          updated_at = now()
--   FROM   workflow_templates wt_old
--   WHERE  wa.wf_template_id = wt_old.id
--     AND  wa.is_active      = true
--     AND  wt_old.is_active  = false;
-- =============================================================================
