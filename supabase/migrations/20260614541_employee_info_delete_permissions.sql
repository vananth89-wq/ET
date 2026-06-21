-- =============================================================================
-- Migration 541 — Delete permission codes for all employee-info modules
-- =============================================================================
--
-- Adds .delete action to the 8 modules that only had view/edit(/history):
--   personal_info, contact_info, employment, address, passport,
--   identity_documents, emergency_contacts, termination
--
-- Behaviour:
--   • Effective-dated satellites (personal_info, employment): delete a single
--     historical record; timeline is re-stitched server-side (no gaps).
--     Deleting the last record is blocked (min 1 record enforced by RPC).
--   • Non-dated single-record tables (contact_info, address, passport):
--     hard-delete the row — leaves the section empty (intentional).
--   • Multi-row tables (identity_documents, emergency_contacts): hard-delete
--     the specific record by id.
--   • Termination (multi-row event log): hard-delete the specific record.
--
-- RPCs that enforce these rules are added in migrations 542–544.
-- =============================================================================

INSERT INTO permissions (code, name, description, module_id, action, sort_order)
SELECT
  vals.module_code || '.delete'  AS code,
  'Delete ' || m.name            AS name,
  vals.description,
  m.id                           AS module_id,
  'delete'                       AS action,
  vals.sort_order
FROM (VALUES
  ('personal_info',
   'Hard-delete a personal info history record. Timeline is re-stitched automatically.',
   78),
  ('contact_info',
   'Hard-delete the contact info record for an employee.',
   88),
  ('employment',
   'Hard-delete an employment history record. Timeline is re-stitched automatically.',
   98),
  ('address',
   'Hard-delete the address record for an employee.',
   108),
  ('passport',
   'Hard-delete the passport record for an employee.',
   118),
  ('identity_documents',
   'Hard-delete a specific identity document record.',
   128),
  ('emergency_contacts',
   'Hard-delete a specific emergency contact record.',
   138),
  ('termination',
   'Hard-delete a specific termination record.',
   208)
) AS vals(module_code, description, sort_order)
JOIN modules m ON m.code = vals.module_code
ON CONFLICT (code) DO UPDATE
  SET action      = EXCLUDED.action,
      name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  ASSERT (
    SELECT COUNT(*) FROM permissions
    WHERE  code IN (
      'personal_info.delete', 'contact_info.delete', 'employment.delete',
      'address.delete', 'passport.delete', 'identity_documents.delete',
      'emergency_contacts.delete', 'termination.delete'
    ) AND action = 'delete'
  ) = 8,
  'Expected 8 delete permission rows with action=delete after migration 541';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 541
-- =============================================================================
