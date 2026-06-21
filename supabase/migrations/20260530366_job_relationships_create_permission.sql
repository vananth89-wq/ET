-- =============================================================================
-- Migration 366 — Job Relationships: add create permission
--
-- Splits "assign new" from "change existing" so HR can be given
-- create-only (add) or edit-only (change) access independently.
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
    'job_relationships.create',
    v_module_id,
    'create',
    'Job Relationships — Assign New',
    'Assign a manager to a previously unassigned relationship code.'
  )
  ON CONFLICT (code) DO NOTHING;
END;
$$;

SELECT code, action FROM permissions WHERE code = 'job_relationships.create';
