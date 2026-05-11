-- =============================================================================
-- Migration 116: Option A — EMPLOYEE assignments use employees.id not profiles.id
--
-- CHANGE
-- ──────
-- workflow_assignments.entity_id for EMPLOYEE type now stores employees.id
-- (the UUID primary key of the employees table) instead of profiles.id
-- (the auth user UUID).
--
-- WHY
-- ───
-- Using employees.id gives a direct FK-like relationship to the employees
-- table, making name lookups a single query with no profiles join.
-- The resolution RPC translates back via profiles at query time:
--   employees.id → profiles.employee_id → profiles.id = auth.uid()
-- A status = 'Active' guard ensures inactive/draft employees never match,
-- providing the same safety as the old profiles.id approach.
--
-- GUARDS
-- ──────
-- 1. status = 'Active' in the resolution subquery — Draft/Incomplete/Inactive
--    employees return NULL → assignment silently falls through to ROLE/GLOBAL.
-- 2. The revoke_ess_on_deactivation trigger (migration 059) already revokes
--    login access when status → Inactive, adding a second layer.
-- =============================================================================

-- Update the schema comment to reflect the new semantics
COMMENT ON COLUMN workflow_assignments.entity_id IS
  'NULL for GLOBAL. roles.id for ROLE. employees.id (PK) for EMPLOYEE.';

-- =============================================================================
-- Replace resolve_workflow_for_submission
-- Only the EMPLOYEE block changes — ROLE and GLOBAL are untouched.
-- =============================================================================

CREATE OR REPLACE FUNCTION resolve_workflow_for_submission(
  p_module_code text,
  p_profile_id  uuid
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template_id uuid;
BEGIN

  -- ── 1. EMPLOYEE-level override ───────────────────────────────────────────────
  -- entity_id stores employees.id (PK). Translate p_profile_id → employees.id
  -- via profiles, guarding on status = 'Active' to exclude Draft/Inactive/
  -- Incomplete employees. If the subquery returns NULL (any non-Active state),
  -- the WHERE condition is UNKNOWN and this block falls through gracefully.
  SELECT wa.wf_template_id INTO v_template_id
  FROM   workflow_assignments wa
  WHERE  wa.module_code      = p_module_code
    AND  wa.assignment_type  = 'EMPLOYEE'
    AND  wa.entity_id        = (
           SELECT e.id
           FROM   employees e
           JOIN   profiles  p ON p.employee_id = e.id
           WHERE  p.id       = p_profile_id
             AND  e.status   = 'Active'
         )
    AND  wa.is_active       = true
    AND  wa.effective_from <= CURRENT_DATE
    AND  (wa.effective_to IS NULL OR wa.effective_to >= CURRENT_DATE)
  ORDER  BY wa.priority
  LIMIT  1;

  IF v_template_id IS NOT NULL THEN
    RETURN v_template_id;
  END IF;

  -- ── 2. ROLE-level — highest-priority role match for the submitter ───────────
  SELECT wa.wf_template_id INTO v_template_id
  FROM   workflow_assignments wa
  JOIN   user_roles ur
         ON ur.role_id    = wa.entity_id
        AND ur.profile_id = p_profile_id
        AND ur.is_active  = true
  WHERE  wa.module_code     = p_module_code
    AND  wa.assignment_type = 'ROLE'
    AND  wa.is_active       = true
    AND  wa.effective_from <= CURRENT_DATE
    AND  (wa.effective_to IS NULL OR wa.effective_to >= CURRENT_DATE)
  ORDER  BY wa.priority
  LIMIT  1;

  IF v_template_id IS NOT NULL THEN
    RETURN v_template_id;
  END IF;

  -- ── 3. GLOBAL fallback ───────────────────────────────────────────────────────
  SELECT wa.wf_template_id INTO v_template_id
  FROM   workflow_assignments wa
  WHERE  wa.module_code      = p_module_code
    AND  wa.assignment_type  = 'GLOBAL'
    AND  wa.is_active        = true
    AND  wa.effective_from  <= CURRENT_DATE
    AND  (wa.effective_to IS NULL OR wa.effective_to >= CURRENT_DATE)
  ORDER  BY wa.priority
  LIMIT  1;

  RETURN v_template_id; -- NULL = no assignment configured for this module

END;
$$;

COMMENT ON FUNCTION resolve_workflow_for_submission(text, uuid) IS
  'Resolves the correct workflow_template_id for a new submission. '
  'Priority: EMPLOYEE > ROLE > GLOBAL. Filters by effective date. '
  'EMPLOYEE: entity_id = employees.id; translates p_profile_id via profiles '
  'with status=Active guard. Returns NULL if no active assignment configured.';
