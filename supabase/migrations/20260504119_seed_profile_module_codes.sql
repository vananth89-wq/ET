-- =============================================================================
-- Migration 119: Seed profile_* module codes
--
-- PURPOSE
-- ───────
-- The profile workflow feature (migrations 117-118) uses five profile_* module
-- codes when submitting workflow instances via wf_submit(). These codes must
-- exist in module_codes before wf_submit() can insert a workflow_instances row,
-- because workflow_instances.module_code has a FK → module_codes(code).
--
-- CODES ADDED
-- ───────────
--   profile_personal          Personal information changes
--   profile_contact           Contact details changes
--   profile_address           Address changes
--   profile_passport          Passport / travel document changes
--   profile_emergency_contact Emergency contact changes
-- =============================================================================

INSERT INTO module_codes (code, label, description) VALUES
  ('profile_personal',          'Profile – Personal Info',      'Employee personal information change requests'),
  ('profile_contact',           'Profile – Contact Details',    'Employee contact details change requests'),
  ('profile_address',           'Profile – Address',            'Employee address change requests'),
  ('profile_passport',          'Profile – Passport',           'Employee passport / travel document change requests'),
  ('profile_emergency_contact', 'Profile – Emergency Contact',  'Employee emergency contact change requests')
ON CONFLICT (code) DO NOTHING;

-- Verification
SELECT code, label FROM module_codes WHERE code LIKE 'profile_%' ORDER BY code;
