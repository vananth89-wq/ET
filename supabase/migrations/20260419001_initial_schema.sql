-- =============================================================================
-- Migration : 20260419001_initial_schema.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-04-19
-- Description: Initial schema — Auth, Organisation, Reference Data,
--              Expense, Workflow (placeholder), Notifications (placeholder),
--              Audit. Includes critical day-1 indexes and RLS enablement.
-- =============================================================================


-- ─── EXTENSIONS ──────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- uuid_generate_v4() fallback


-- ─── CUSTOM ENUM TYPES ───────────────────────────────────────────────────────
CREATE TYPE role_type AS ENUM (
  'employee',
  'manager',
  'finance',
  'admin'
);

CREATE TYPE expense_status AS ENUM (
  'draft',
  'submitted',
  'approved',
  'rejected'
);

CREATE TYPE employee_status AS ENUM (
  'Draft',
  'Incomplete',
  'Active',
  'Inactive'
);


-- =============================================================================
-- REFERENCE DATA DOMAIN
-- Created first — no dependencies on other business tables
-- =============================================================================

-- ─── CURRENCIES ──────────────────────────────────────────────────────────────
CREATE TABLE currencies (
  id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT          NOT NULL UNIQUE,   -- ISO: INR, USD, SAR
  name        TEXT          NOT NULL,          -- Indian Rupee, US Dollar
  symbol      TEXT          NOT NULL,          -- ₹, $, ﷼
  active      BOOLEAN       NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE currencies IS 'ISO currency master. Single source of truth for all currency references.';

-- ─── PICKLISTS ───────────────────────────────────────────────────────────────
CREATE TABLE picklists (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  picklist_id  TEXT         NOT NULL UNIQUE,   -- e.g. LOCATION, DESIGNATION
  name         TEXT         NOT NULL,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE picklists IS 'Picklist definitions. Each row defines a dropdown category.';

-- ─── PICKLIST VALUES ─────────────────────────────────────────────────────────
CREATE TABLE picklist_values (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  picklist_id      UUID        NOT NULL REFERENCES picklists(id) ON DELETE CASCADE,
  value            TEXT        NOT NULL,
  ref_id           TEXT,                        -- optional short code e.g. L001
  active           BOOLEAN     NOT NULL DEFAULT true,
  parent_value_id  UUID        REFERENCES picklist_values(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE picklist_values IS 'Values for each picklist. parent_value_id enables cascading dropdowns (Country → State → City).';

-- ─── PROJECTS ────────────────────────────────────────────────────────────────
CREATE TABLE projects (
  id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT          NOT NULL,
  start_date  DATE,
  end_date    DATE,
  active      BOOLEAN       NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE projects IS 'Projects that expense line items can be billed against.';

-- ─── EXCHANGE RATES ──────────────────────────────────────────────────────────
CREATE TABLE exchange_rates (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  from_currency_id  UUID        NOT NULL REFERENCES currencies(id),
  to_currency_id    UUID        NOT NULL REFERENCES currencies(id),
  rate              NUMERIC(18, 6) NOT NULL,
  effective_date    DATE        NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_exchange_rate UNIQUE (from_currency_id, to_currency_id, effective_date),
  CONSTRAINT chk_different_currencies CHECK (from_currency_id <> to_currency_id)
);
COMMENT ON TABLE exchange_rates IS 'Date-effective exchange rates. UNIQUE on (from, to, date) — one rate per currency pair per day.';


-- =============================================================================
-- ORGANISATION DOMAIN
-- Note: departments created before employees to satisfy FK.
--       head_id removed from departments — use department_heads table instead.
-- =============================================================================

-- ─── DEPARTMENTS ─────────────────────────────────────────────────────────────
CREATE TABLE departments (
  id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  dept_id     TEXT          NOT NULL UNIQUE,   -- e.g. D001
  name        TEXT          NOT NULL,
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  deleted_at  TIMESTAMPTZ                      -- soft delete
);
COMMENT ON TABLE departments IS 'Company departments. Current head resolved via department_heads WHERE to_date IS NULL.';

-- ─── EMPLOYEES ───────────────────────────────────────────────────────────────
CREATE TABLE employees (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id         TEXT          NOT NULL UNIQUE,   -- e.g. E001
  name                TEXT          NOT NULL,
  business_email      TEXT          UNIQUE,
  personal_email      TEXT,
  mobile              TEXT,
  country_code        TEXT,
  nationality         TEXT,
  marital_status      TEXT,
  designation         TEXT,
  job_title           TEXT,          -- display only, not for access control
  dept_id             UUID          REFERENCES departments(id) ON DELETE SET NULL,
  manager_id          UUID          REFERENCES employees(id) ON DELETE SET NULL,
  hire_date           DATE,
  end_date            DATE,
  probation_end_date  DATE,
  work_country        TEXT,
  work_location       TEXT,
  base_currency_id    UUID          REFERENCES currencies(id) ON DELETE SET NULL,
  photo_url           TEXT,
  status              employee_status NOT NULL DEFAULT 'Draft',
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  deleted_at          TIMESTAMPTZ              -- soft delete (use status Inactive preferably)
);
COMMENT ON TABLE employees IS 'Employee master. manager_id self-reference drives org chart and approval routing. job_title is display only — access control uses profile_roles.';

-- ─── DEPARTMENT HEADS HISTORY ─────────────────────────────────────────────
CREATE TABLE department_heads (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  department_id  UUID         NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
  employee_id    UUID         NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  from_date      DATE         NOT NULL,
  to_date        DATE,        -- NULL = current head
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_dept_head_period UNIQUE (department_id, from_date)
);
COMMENT ON TABLE department_heads IS 'Historical record of department heads. to_date IS NULL = current head. Query with WHERE to_date IS NULL for current.';

-- ─── EMPLOYEE ADDRESSES ───────────────────────────────────────────────────
CREATE TABLE employee_addresses (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id  UUID         NOT NULL UNIQUE REFERENCES employees(id) ON DELETE CASCADE,
  line1        TEXT,
  line2        TEXT,
  landmark     TEXT,
  city         TEXT,
  district     TEXT,
  state        TEXT,
  pin          TEXT,
  country      TEXT,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE employee_addresses IS 'One address record per employee (UNIQUE on employee_id).';

-- ─── EMERGENCY CONTACTS ──────────────────────────────────────────────────
CREATE TABLE emergency_contacts (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id  UUID         NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  name         TEXT         NOT NULL,
  relationship TEXT,
  phone        TEXT,
  alt_phone    TEXT,
  email        TEXT,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ─── IDENTITY RECORDS ────────────────────────────────────────────────────
CREATE TABLE identity_records (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id  UUID         NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  country      TEXT,
  id_type      TEXT,
  record_type  TEXT,
  id_number    TEXT,
  expiry       DATE,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ─── PASSPORTS ───────────────────────────────────────────────────────────
CREATE TABLE passports (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id      UUID         NOT NULL UNIQUE REFERENCES employees(id) ON DELETE CASCADE,
  country          TEXT,
  passport_number  TEXT,
  issue_date       DATE,
  expiry_date      DATE,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE passports IS 'One passport per employee (UNIQUE on employee_id).';


-- =============================================================================
-- AUTH DOMAIN
-- profiles references auth.users (managed by Supabase)
-- =============================================================================

-- ─── PROFILES ────────────────────────────────────────────────────────────────
CREATE TABLE profiles (
  id           UUID         PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  employee_id  UUID         UNIQUE REFERENCES employees(id) ON DELETE SET NULL,
  is_active    BOOLEAN      NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE profiles IS 'One profile per auth user. Bridges Supabase auth.users to the employees table.';

-- ─── PROFILE ROLES ───────────────────────────────────────────────────────────
CREATE TABLE profile_roles (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id   UUID         NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role         role_type    NOT NULL,
  assigned_by  UUID         REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_profile_role UNIQUE (profile_id, role)   -- no duplicate roles per user
);
COMMENT ON TABLE profile_roles IS 'RBAC — one row per role per user. UNIQUE(profile_id, role) prevents duplicates. assigned_by tracks who granted access.';


-- =============================================================================
-- EXPENSE DOMAIN
-- =============================================================================

-- ─── EXPENSE REPORTS ─────────────────────────────────────────────────────────
CREATE TABLE expense_reports (
  id                UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id       UUID           NOT NULL REFERENCES employees(id),
  name              TEXT           NOT NULL,
  status            expense_status NOT NULL DEFAULT 'draft',
  base_currency_id  UUID           NOT NULL REFERENCES currencies(id),
  submitted_at      TIMESTAMPTZ,
  approved_at       TIMESTAMPTZ,
  approved_by       UUID           REFERENCES employees(id),
  rejected_at       TIMESTAMPTZ,
  rejected_by       UUID           REFERENCES employees(id),
  rejection_reason  TEXT,
  created_at        TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ,   -- soft delete: only allowed when status = 'draft'
  CONSTRAINT chk_delete_only_draft CHECK (
    deleted_at IS NULL OR status = 'draft'
  )
);
COMMENT ON TABLE expense_reports IS 'One report per submission cycle per employee. Soft delete enforced by CHECK — only draft reports can be deleted.';

-- ─── LINE ITEMS ──────────────────────────────────────────────────────────────
CREATE TABLE line_items (
  id                      UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id               UUID           NOT NULL REFERENCES expense_reports(id) ON DELETE CASCADE,
  category_id             UUID           REFERENCES picklist_values(id) ON DELETE SET NULL,
  project_id              UUID           REFERENCES projects(id) ON DELETE SET NULL,
  currency_id             UUID           NOT NULL REFERENCES currencies(id),
  exchange_rate_id        UUID           REFERENCES exchange_rates(id) ON DELETE SET NULL,
  expense_date            DATE           NOT NULL,
  amount                  NUMERIC(18,2)  NOT NULL,
  exchange_rate_snapshot  NUMERIC(18,6),  -- rate value at time of entry, never changes
  converted_amount        NUMERIC(18,2)  NOT NULL,
  note                    TEXT,
  created_at              TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  deleted_at              TIMESTAMPTZ    -- soft delete: cascades from report
);
COMMENT ON TABLE line_items IS 'Individual expense entries within a report. exchange_rate_snapshot preserves the rate at the time of entry — immune to future rate changes.';

-- ─── ATTACHMENTS ─────────────────────────────────────────────────────────────
CREATE TABLE attachments (
  id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  line_item_id  UUID         NOT NULL REFERENCES line_items(id) ON DELETE CASCADE,
  file_name     TEXT         NOT NULL,
  storage_path  TEXT         NOT NULL,   -- Supabase Storage path
  mime_type     TEXT         NOT NULL,
  size_bytes    INTEGER      NOT NULL,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE attachments IS 'Receipts and supporting documents. storage_path references Supabase Storage bucket — no base64 blobs in the database.';


-- =============================================================================
-- WORKFLOW DOMAIN — PLACEHOLDER
-- Full design pending workflow step. Structure reserved to avoid future
-- schema restructuring.
-- =============================================================================

CREATE TABLE workflow_instances (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type  TEXT         NOT NULL DEFAULT 'expense_report',
  entity_id    UUID         NOT NULL,
  current_step TEXT,
  status       TEXT         NOT NULL DEFAULT 'pending',
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE workflow_instances IS 'PLACEHOLDER — workflow engine not yet designed. Reserves table structure to avoid future migration complexity.';


-- =============================================================================
-- NOTIFICATIONS DOMAIN — PLACEHOLDER
-- Full design pending workflow step.
-- =============================================================================

CREATE TABLE notifications (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID         NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type         TEXT         NOT NULL,
  title        TEXT         NOT NULL,
  body         TEXT,
  entity_type  TEXT,
  entity_id    UUID,
  read_at      TIMESTAMPTZ,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE notifications IS 'PLACEHOLDER — notification system not yet designed. Reserves table structure.';


-- =============================================================================
-- AUDIT DOMAIN
-- Immutable — no updated_at by design
-- =============================================================================

CREATE TABLE audit_log (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID         REFERENCES auth.users(id) ON DELETE SET NULL,
  action       TEXT         NOT NULL,   -- e.g. report.submitted, report.approved
  entity_type  TEXT         NOT NULL,   -- e.g. expense_report, employee
  entity_id    UUID,
  metadata     JSONB,                   -- flexible payload per action type
  ip_address   TEXT,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
  -- no updated_at — audit log is append-only and immutable
);
COMMENT ON TABLE audit_log IS 'Immutable audit trail. Append-only — never UPDATE or DELETE rows. No updated_at by design.';


-- =============================================================================
-- CRITICAL DAY-1 INDEXES
-- Added on empty tables — zero cost, immediate benefit
-- =============================================================================

-- RLS runs this on every single API request
CREATE INDEX idx_profile_roles_profile_id
  ON profile_roles(profile_id);

-- Login and employee resolution
CREATE INDEX idx_employees_business_email
  ON employees(business_email);

-- Employee fetches their own reports (most common query)
CREATE INDEX idx_expense_reports_employee_id
  ON expense_reports(employee_id);

-- Line items always fetched together with their report
CREATE INDEX idx_line_items_report_id
  ON line_items(report_id);

-- Active-only report filter runs constantly (excludes soft-deleted)
CREATE INDEX idx_expense_reports_active
  ON expense_reports(deleted_at)
  WHERE deleted_at IS NULL;


-- =============================================================================
-- UPDATED_AT TRIGGER
-- Automatically keeps updated_at current on every row change
-- =============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to every table that has updated_at
CREATE TRIGGER trg_currencies_updated_at
  BEFORE UPDATE ON currencies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_picklists_updated_at
  BEFORE UPDATE ON picklists
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_picklist_values_updated_at
  BEFORE UPDATE ON picklist_values
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_projects_updated_at
  BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_exchange_rates_updated_at
  BEFORE UPDATE ON exchange_rates
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_departments_updated_at
  BEFORE UPDATE ON departments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_department_heads_updated_at
  BEFORE UPDATE ON department_heads
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_employees_updated_at
  BEFORE UPDATE ON employees
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_employee_addresses_updated_at
  BEFORE UPDATE ON employee_addresses
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_emergency_contacts_updated_at
  BEFORE UPDATE ON emergency_contacts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_identity_records_updated_at
  BEFORE UPDATE ON identity_records
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_passports_updated_at
  BEFORE UPDATE ON passports
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_profile_roles_updated_at
  BEFORE UPDATE ON profile_roles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_expense_reports_updated_at
  BEFORE UPDATE ON expense_reports
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_line_items_updated_at
  BEFORE UPDATE ON line_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_attachments_updated_at
  BEFORE UPDATE ON attachments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_workflow_instances_updated_at
  BEFORE UPDATE ON workflow_instances
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_notifications_updated_at
  BEFORE UPDATE ON notifications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- AUTO-CREATE PROFILE ON SIGNUP
-- When Supabase creates a new auth.users row, automatically create
-- a matching profiles row so RLS always has a profile to check.
-- =============================================================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, is_active, created_at, updated_at)
  VALUES (NEW.id, true, NOW(), NOW());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- =============================================================================
-- ROW LEVEL SECURITY — Enable on all tables
-- Policies will be added in a separate migration once auth flow is wired.
-- Enabling RLS now ensures no table is accidentally left open.
-- =============================================================================

ALTER TABLE currencies             ENABLE ROW LEVEL SECURITY;
ALTER TABLE picklists              ENABLE ROW LEVEL SECURITY;
ALTER TABLE picklist_values        ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects               ENABLE ROW LEVEL SECURITY;
ALTER TABLE exchange_rates         ENABLE ROW LEVEL SECURITY;
ALTER TABLE departments            ENABLE ROW LEVEL SECURITY;
ALTER TABLE department_heads       ENABLE ROW LEVEL SECURITY;
ALTER TABLE employees              ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_addresses     ENABLE ROW LEVEL SECURITY;
ALTER TABLE emergency_contacts     ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity_records       ENABLE ROW LEVEL SECURITY;
ALTER TABLE passports              ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles               ENABLE ROW LEVEL SECURITY;
ALTER TABLE profile_roles          ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_reports        ENABLE ROW LEVEL SECURITY;
ALTER TABLE line_items             ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments            ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_instances     ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications          ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log              ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- END OF MIGRATION 20260419001_initial_schema.sql
-- Next migration: 20260419002_rls_policies.sql
-- =============================================================================
