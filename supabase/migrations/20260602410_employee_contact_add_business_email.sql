-- =============================================================================
-- Migration 410 — employee_contact: add business_email as denormalized copy
-- =============================================================================
-- employees.business_email remains the source of truth and identity key.
-- employee_contact.business_email is a convenience copy so all contact info
-- (mobile, personal_email, business_email) is queryable from one table —
-- useful for bulk export, duplicate checks, and contact sheets.
--
-- Sync strategy: written together with personal_email/mobile in saveExtendedData.
-- No trigger needed — the app always writes both in the same upsert call.
-- =============================================================================

ALTER TABLE employee_contact
  ADD COLUMN IF NOT EXISTS business_email TEXT;

-- Backfill from employees.business_email for all existing rows
UPDATE employee_contact ec
SET    business_email = e.business_email
FROM   employees e
WHERE  e.id = ec.employee_id
  AND  ec.business_email IS NULL;

-- Index for duplicate-check queries
CREATE INDEX IF NOT EXISTS idx_employee_contact_business_email
  ON employee_contact (lower(business_email))
  WHERE business_email IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_employee_contact_personal_email
  ON employee_contact (lower(personal_email))
  WHERE personal_email IS NOT NULL;

COMMENT ON COLUMN employee_contact.business_email IS
  'Denormalized copy of employees.business_email. '
  'employees.business_email is still the source of truth and identity key. '
  'This copy exists so all contact fields are queryable from one table. '
  'Written by saveExtendedData alongside personal_email and mobile. Mig 410.';
