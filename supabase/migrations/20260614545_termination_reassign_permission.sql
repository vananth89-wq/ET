-- =============================================================================
-- Migration 545: Add termination.reassign permission
--
-- Adds a new action 'reassign' on the termination module.
-- Controls who can view / edit direct-report manager reassignments
-- during a termination or resignation approval.
--
--   View  → see the impact panel (which reports go where) in WorkflowReview
--   Edit  → change the new manager per direct report and save reassignments
--
-- No default grants — admin assigns via Permission Matrix UI.
-- =============================================================================

-- 1. Expand permissions_action_check to include 'reassign'
ALTER TABLE permissions DROP CONSTRAINT IF EXISTS permissions_action_check;
ALTER TABLE permissions ADD CONSTRAINT permissions_action_check
  CHECK (action IN ('view', 'create', 'edit', 'delete', 'history', 'lookup',
                    'view_all_pending', 'edit_all_pending',
                    'bulk_import', 'bulk_export',
                    'view_inactive',
                    'reassign'));

-- 2. Insert the permission rows
DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'termination';

  IF v_module_id IS NULL THEN
    RAISE EXCEPTION 'termination module not found';
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    ('termination.reassign',
     v_module_id,
     'reassign',
     'Reassign direct reports',
     'View: see which direct reports will be reassigned and to whom during a termination/resignation. '
     'Edit: change the new manager assignment per direct report and save to the termination record.'),
    ('termination.reassign.view',
     v_module_id,
     'reassign',
     'Reassign direct reports (view)',
     'See the direct-report reassignment panel in workflow review — read only.'),
    ('termination.reassign.edit',
     v_module_id,
     'reassign',
     'Reassign direct reports (edit)',
     'Change and save new manager assignments for direct reports during termination/resignation approval.')
  ON CONFLICT (code) DO NOTHING;
END;
$$;

-- =============================================================================
-- END OF MIGRATION 545
-- =============================================================================
