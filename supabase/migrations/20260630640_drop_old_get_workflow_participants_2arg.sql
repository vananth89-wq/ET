-- ============================================================
-- Mig 640: drop old 2-arg get_workflow_participants overload
--
-- Two overloads exist:
--   get_workflow_participants(text, uuid)          ← old, mig 337
--   get_workflow_participants(text, uuid, uuid)    ← new, mig 589/635
--
-- Postgres may pick the 2-arg version when the JS client calls with
-- named params p_module_code + p_profile_id + p_subject_employee_id,
-- causing the SELF step to always resolve via p_profile_id (the admin)
-- instead of the subject employee.
--
-- Drop the old overload so only the 3-arg version exists.
-- ============================================================

DROP FUNCTION IF EXISTS get_workflow_participants(text, uuid);
