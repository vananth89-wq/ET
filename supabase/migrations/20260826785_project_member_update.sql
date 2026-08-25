-- =============================================================================
-- Migration 785: let a lead correct an assignment they already made
--
-- WHY
-- ═══
-- The My Projects table has shown an Allocation column since mig 774 and it has
-- never once had a value in it. project_member_add() accepts p_allocation_pct
-- and p_effective_from, but there is no way to change either afterwards -- so a
-- lead who adds somebody (which the screen does with the defaults) can never
-- fill it in. A column that structurally cannot hold data is worse than no
-- column: it reads as broken software.
--
-- The same gap covers the start date. Membership is nearly always recorded
-- after the fact -- somebody joined three weeks ago and the lead is catching up
-- -- and with add-only the row is stamped today and stays wrong forever.
--
-- WHAT THIS ADDS
-- ──────────────
--   project_member_update(id, allocation, clear_allocation, effective_from)
--
-- One call, both fields, each optional. NULL means "leave it alone", which is
-- why clearing an allocation needs its own explicit flag rather than passing
-- NULL and hoping.
--
-- WHAT IT DELIBERATELY WILL NOT DO
-- ────────────────────────────────
--   * Move a member to another project. project_id is not a parameter. That is
--     an end-and-re-add, and the two-step leaves an honest history.
--   * Set effective_to. Ending an assignment is project_member_remove(), which
--     already decides between delete and end-date by whether hours exist.
--   * Touch a row on a project the caller does not manage -- can_staff_project()
--     is the first thing it asks, same as every other call in this API.
--
-- NOT CHANGED
-- ───────────
--   project_member_add / _remove, can_staff_project, my_project_members,
--   the exclusion constraint, every RLS policy.
-- =============================================================================

SET jit = 'off';

CREATE OR REPLACE FUNCTION public.project_member_update(
  p_id               uuid,
  p_allocation_pct   numeric DEFAULT NULL,
  p_clear_allocation boolean DEFAULT false,
  p_effective_from   date    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row project_members%ROWTYPE;
  v_from date;
BEGIN
  SELECT * INTO v_row FROM project_members WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
      'message', 'That assignment no longer exists. Refresh the page.');
  END IF;

  IF NOT can_staff_project(v_row.project_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You can only change assignments on projects where you are the Reporting Manager.');
  END IF;

  -- Allocation ---------------------------------------------------------------
  -- The table CHECK is (allocation_pct > 0 AND <= 100). Reaching it would raise
  -- a constraint violation the user cannot read, so the sentence comes first
  -- and the constraint stays behind it as the real guarantee.
  IF p_clear_allocation THEN
    UPDATE project_members SET allocation_pct = NULL, updated_at = now() WHERE id = p_id;
  ELSIF p_allocation_pct IS NOT NULL THEN
    IF p_allocation_pct <= 0 OR p_allocation_pct > 100 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'BAD_ALLOCATION',
        'message', 'Allocation must be between 1 and 100 percent.');
    END IF;
    UPDATE project_members SET allocation_pct = p_allocation_pct, updated_at = now() WHERE id = p_id;
  END IF;

  -- Start date ---------------------------------------------------------------
  IF p_effective_from IS NOT NULL AND p_effective_from IS DISTINCT FROM v_row.effective_from THEN
    v_from := p_effective_from;

    IF v_row.effective_to IS NOT NULL AND v_from > v_row.effective_to THEN
      RETURN jsonb_build_object('ok', false, 'error', 'DATES_CROSSED',
        'message', 'The start date cannot be after the date the assignment ended.');
    END IF;

    -- Same courtesy as project_member_add: catch the overlap and say it in
    -- words. The gist exclusion constraint is still what makes it true.
    IF EXISTS (
      SELECT 1 FROM project_members pm
      WHERE  pm.project_id  = v_row.project_id
        AND  pm.employee_id = v_row.employee_id
        AND  pm.id         <> v_row.id
        AND  daterange(pm.effective_from, COALESCE(pm.effective_to, 'infinity'::date), '[]')
             && daterange(v_from, COALESCE(v_row.effective_to, 'infinity'::date), '[]')
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'OVERLAPS',
        'message', 'That start date would overlap another spell this person had on the project.');
    END IF;

    UPDATE project_members
    SET    effective_from = v_from, updated_at = now()
    WHERE  id = p_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id);
END;
$fn$;

REVOKE ALL ON FUNCTION public.project_member_update(uuid, numeric, boolean, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.project_member_update(uuid, numeric, boolean, date) TO authenticated;

COMMENT ON FUNCTION public.project_member_update(uuid, numeric, boolean, date) IS
  'Mig 785: change the allocation or the start date of an existing assignment. '
  'NULL means leave alone, so clearing an allocation needs p_clear_allocation. '
  'Cannot move a member between projects and cannot set effective_to -- ending '
  'an assignment is project_member_remove(). Gated on can_staff_project().';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_update'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_id uuid, p_allocation_pct numeric, p_clear_allocation boolean, p_effective_from date'
  ) THEN
    RAISE EXCEPTION 'mig 785: project_member_update missing or wrong signature';
  END IF;

  -- The invariant worth asserting is the gate, not the absence of a column name.
  -- (An earlier version of this block tested LIKE '%SET%project_id%' to prove
  -- the function cannot move a row between projects -- which matches its own
  -- `SET search_path` header and the `pm.project_id` in the overlap check, and
  -- so failed on a perfectly correct function. Textual proofs of a negative are
  -- a trap; assert the positive.)
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_update'
      AND p.prosecdef                                    -- SECURITY DEFINER
      AND pg_get_functiondef(p.oid) LIKE '%can_staff_project(v_row.project_id)%'
  ) THEN
    RAISE EXCEPTION
      'mig 785: project_member_update is not SECURITY DEFINER gated on can_staff_project';
  END IF;

  RAISE NOTICE 'mig 785: OK -- allocation and start date are editable';
END $mig$;
