-- =============================================================================
-- Migration 365 — Job Relationships: add delete permission
--
-- Adds job_relationships.delete so the X (clear) button in the portlet
-- can be gated independently from edit (assign/change).
-- =============================================================================

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'job_relationships';

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'job_relationships module not found — skipping';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES (
    'job_relationships.delete',
    v_module_id,
    'delete',
    'Job Relationships — Remove',
    'Clear (remove) an existing matrix manager assignment.'
  )
  ON CONFLICT (code) DO NOTHING;
END;
$$;

SELECT code, action FROM permissions WHERE code = 'job_relationships.delete';
