-- =============================================================================
-- Migration 484 — Termination: Picklists, Permissions, Module Registration
--
-- 1. Register 'termination' workflow module
-- 2. Seed RESIGNATION_REASON picklist (8 codes — SELF path)
-- 3. Seed TERMINATION_REASON picklist (11 codes — HR/Admin path)
-- 4. Seed 5 permissions:
--      termination.view, .edit, .history, .bulk_import, .bulk_export
--
-- §1 decision #11: picklist visibility is driven by transaction context, not
-- role. SELF → RESIGNATION_REASON; other → TERMINATION_REASON.
-- §1 decision #14: no default grants. All 5 perms start unassigned.
--
-- Notification templates will be seeded in mig 486 alongside workflow setup.
--
-- Predecessor: 20260604483
-- Next migration: 20260604485 (RPCs)
-- =============================================================================


-- =============================================================================
-- 1. Register termination module
-- =============================================================================

INSERT INTO modules (code, name, active, sort_order)
VALUES (
  'termination',
  'Termination',
  true,
  (SELECT COALESCE(MAX(sort_order), 0) + 10 FROM modules)
)
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- 2. RESIGNATION_REASON picklist (8 codes — used when initiation_type = 'SELF')
-- =============================================================================

INSERT INTO picklists (picklist_id, name, system, meta_fields)
VALUES ('RESIGNATION_REASON', 'Resignation Reasons', true, '[]'::jsonb)
ON CONFLICT (picklist_id) DO NOTHING;

INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.label, v.ref_id, true
FROM (VALUES
  ('R001', 'Better Opportunity'),
  ('R002', 'Higher Studies'),
  ('R003', 'Relocation'),
  ('R004', 'Personal Reasons'),
  ('R005', 'Family Commitments'),
  ('R006', 'Health Reasons'),
  ('R007', 'Retirement'),
  ('R008', 'Other')
) AS v(ref_id, label)
JOIN picklists pl ON pl.picklist_id = 'RESIGNATION_REASON'
ON CONFLICT DO NOTHING;


-- =============================================================================
-- 3. TERMINATION_REASON picklist (11 codes — used when initiation_type != 'SELF')
-- =============================================================================

INSERT INTO picklists (picklist_id, name, system, meta_fields)
VALUES ('TERMINATION_REASON', 'Termination Reasons', true, '[]'::jsonb)
ON CONFLICT (picklist_id) DO NOTHING;

INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.label, v.ref_id, true
FROM (VALUES
  ('T001', 'Performance'),
  ('T002', 'Misconduct'),
  ('T003', 'Policy Violation'),
  ('T004', 'Probation Failure'),
  ('T005', 'Absconding'),
  ('T006', 'Position Redundancy'),
  ('T007', 'Organisation Restructuring'),
  ('T008', 'End of Contract'),
  ('T009', 'Retirement'),
  ('T010', 'Death'),
  ('T011', 'Other')
) AS v(ref_id, label)
JOIN picklists pl ON pl.picklist_id = 'TERMINATION_REASON'
ON CONFLICT DO NOTHING;


-- =============================================================================
-- 4. Permissions (5 — no default grants per §1 decision #14)
--    permissions_action_check already allows bulk_import / bulk_export
--    (extended at mig 359 for the job-relationships module).
-- =============================================================================

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'termination';

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'termination module not found — skipping permission seed';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    ('termination.view',
     v_module_id, 'view',
     'Termination — View',
     'View termination records for an employee.'),

    ('termination.edit',
     v_module_id, 'edit',
     'Termination — Edit',
     'Create, edit, withdraw, or reverse termination transactions.'),

    ('termination.history',
     v_module_id, 'history',
     'Termination — History',
     'Access full termination history including REVERSED records.'),

    ('termination.bulk_import',
     v_module_id, 'bulk_import',
     'Termination — Bulk Import',
     'Upload CSV to process terminations in bulk (bypasses workflow; restricted to admin group).'),

    ('termination.bulk_export',
     v_module_id, 'bulk_export',
     'Termination — Bulk Export',
     'Download termination records as CSV.')
  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm module registered
SELECT code, name, active FROM modules WHERE code = 'termination';

-- Confirm picklist value counts
SELECT pl.picklist_id, COUNT(*) AS value_count
FROM   picklist_values pv
JOIN   picklists pl ON pl.id = pv.picklist_id
WHERE  pl.picklist_id IN ('RESIGNATION_REASON', 'TERMINATION_REASON')
GROUP  BY pl.picklist_id
ORDER  BY pl.picklist_id;

-- Confirm permissions seeded
SELECT code FROM permissions
WHERE  code LIKE 'termination.%'
ORDER  BY code;

-- =============================================================================
-- END OF MIGRATION 484
-- =============================================================================
