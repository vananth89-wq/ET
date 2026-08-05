-- =============================================================================
-- Migration 715 — Add requires_project to time_types; relax timesheet_entries
--                 constraint to allow project_id on time_type entries.
--
-- Business rule: when a time type (attendance category) has requires_project=true,
-- the employee must select an active project when logging that time type.
-- The entry is saved as entry_kind='time_type' with BOTH time_type_id AND
-- project_id populated (e.g. "Work" time type linked to a specific project).
-- =============================================================================

-- ── 1. Add requires_project column to time_types ─────────────────────────────

ALTER TABLE time_types
  ADD COLUMN IF NOT EXISTS requires_project boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN time_types.requires_project IS
  'true = employee must select an active project when logging this time type (attendance only).';

-- ── 2. Relax timesheet_entries constraint to allow optional project_id ────────
-- The old constraint forced project_id IS NULL on all non-project entries.
-- We now allow project_id to be set on time_type/leave entries when the
-- linked time_type has requires_project = true.

ALTER TABLE timesheet_entries
  DROP CONSTRAINT IF EXISTS te_project_kind;

ALTER TABLE timesheet_entries
  ADD CONSTRAINT te_project_kind CHECK (
    (entry_kind = 'project'  AND project_id IS NOT NULL AND time_type_id IS NULL)
    OR
    (entry_kind != 'project' AND time_type_id IS NOT NULL)
    -- project_id is now optional for non-project entries (used for requires_project time types)
  );

-- ── 3. Update upsert_time_type RPC to handle requires_project ────────────────

CREATE OR REPLACE FUNCTION upsert_time_type(p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id     uuid;
  v_is_new boolean;
BEGIN
  v_id := (p_data->>'id')::uuid;
  IF v_id IS NOT NULL THEN
    IF NOT user_can('time_types', 'edit', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to edit time types.');
    END IF;
    v_is_new := false;
  ELSE
    IF NOT user_can('time_types', 'create', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to create time types.');
    END IF;
    v_id := gen_random_uuid();
    v_is_new := true;
  END IF;

  IF (p_data->>'category') NOT IN ('attendance', 'absence') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_CATEGORY',
      'message', 'category must be attendance or absence.');
  END IF;

  -- requires_project only makes sense for attendance types; force false for absence
  INSERT INTO time_types (id, name, code, category, allows_partial_overlap, is_active, requires_project, created_by)
  VALUES (
    v_id,
    trim(p_data->>'name'),
    upper(trim(p_data->>'code')),
    p_data->>'category',
    COALESCE((p_data->>'allows_partial_overlap')::boolean, false),
    COALESCE((p_data->>'is_active')::boolean, true),
    CASE WHEN p_data->>'category' = 'attendance'
         THEN COALESCE((p_data->>'requires_project')::boolean, false)
         ELSE false
    END,
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    name                   = trim(EXCLUDED.name),
    code                   = upper(trim(EXCLUDED.code)),
    category               = EXCLUDED.category,
    allows_partial_overlap = EXCLUDED.allows_partial_overlap,
    is_active              = EXCLUDED.is_active,
    requires_project       = CASE WHEN EXCLUDED.category = 'attendance'
                                  THEN EXCLUDED.requires_project
                                  ELSE false
                             END,
    updated_at             = now();

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'created', v_is_new);

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'DUPLICATE_CODE',
    'message', 'A time type with this code already exists.');
WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_time_type(jsonb) TO authenticated;
COMMENT ON FUNCTION upsert_time_type IS 'Mig 715: Create/update a time type (now supports requires_project).';

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'time_types' AND column_name = 'requires_project'
  ) THEN
    RAISE EXCEPTION 'ABORT: requires_project column not found on time_types.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'te_project_kind' AND conrelid = 'timesheet_entries'::regclass
  ) THEN
    RAISE EXCEPTION 'ABORT: te_project_kind constraint not found on timesheet_entries.';
  END IF;
  RAISE NOTICE 'Migration 715 verified: requires_project added, te_project_kind constraint relaxed.';
END $$;
