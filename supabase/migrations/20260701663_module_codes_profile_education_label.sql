-- Migration 663 — Rename education module label to "Profile — Education"
-- in module_codes table so the Workflow Assignments UI shows the correct label.

UPDATE module_codes
SET    label = 'Profile — Education'
WHERE  code = 'profile_education';
