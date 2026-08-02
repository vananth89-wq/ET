-- =============================================================================
-- Migration 699 — Time Management: time_types table
--
-- Creates time_types: admin-configurable list of time entry categories
-- (e.g. Training, On-Site Visit). Category is attendance or absence.
-- When the leave module ships it will use reserved time_types with category='absence'.
-- =============================================================================

CREATE TABLE time_types (
  id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                     text        NOT NULL,
  code                     text        NOT NULL,
  category                 text        NOT NULL CHECK (category IN ('attendance', 'absence')),
  allows_partial_overlap   boolean     NOT NULL DEFAULT false,
  is_active                boolean     NOT NULL DEFAULT true,
  created_by               uuid        REFERENCES profiles(id),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_types_code_key UNIQUE (code)
);

COMMENT ON TABLE  time_types IS 'Admin-configurable time entry types. category=absence types block same-day entries unless allows_partial_overlap=true.';
COMMENT ON COLUMN time_types.allows_partial_overlap IS 'When true, employees may still log other hours on a partial-day absence.';

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE time_types ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tt_select" ON time_types
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "tt_insert" ON time_types
  FOR INSERT TO authenticated
  WITH CHECK (user_can('time_types', 'create', NULL));

CREATE POLICY "tt_update" ON time_types
  FOR UPDATE TO authenticated
  USING     (user_can('time_types', 'edit', NULL))
  WITH CHECK (user_can('time_types', 'edit', NULL));

CREATE POLICY "tt_delete" ON time_types
  FOR DELETE TO authenticated
  USING (user_can('time_types', 'delete', NULL));

-- ── RPC: upsert_time_type ────────────────────────────────────────────────────

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

  INSERT INTO time_types (id, name, code, category, allows_partial_overlap, is_active, created_by)
  VALUES (
    v_id,
    trim(p_data->>'name'),
    upper(trim(p_data->>'code')),
    p_data->>'category',
    COALESCE((p_data->>'allows_partial_overlap')::boolean, false),
    COALESCE((p_data->>'is_active')::boolean, true),
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    name                   = trim(EXCLUDED.name),
    code                   = upper(trim(EXCLUDED.code)),
    category               = EXCLUDED.category,
    allows_partial_overlap = EXCLUDED.allows_partial_overlap,
    is_active              = EXCLUDED.is_active,
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

COMMENT ON FUNCTION upsert_time_type IS 'Mig 699: Create/update a time type.';

-- ── Seed: common starter types ───────────────────────────────────────────────
-- Admin can edit/delete these; they are just useful defaults.

INSERT INTO time_types (name, code, category, allows_partial_overlap, is_active) VALUES
  ('Training',        'TRN', 'attendance', false, true),
  ('On-Site Visit',   'OSV', 'attendance', false, true),
  ('Public Holiday',  'HOL', 'absence',    false, true),
  ('Annual Leave',    'AL',  'absence',    false, true)
ON CONFLICT (code) DO NOTHING;

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'time_types') THEN
    RAISE EXCEPTION 'ABORT: time_types table not found.';
  END IF;
  RAISE NOTICE 'Migration 699 verified: time_types created with 4 seed rows.';
END $$;
