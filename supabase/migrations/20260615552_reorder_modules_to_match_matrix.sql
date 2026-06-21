-- =============================================================================
-- Migration 552 — Reorder modules.sort_order to match Permission Matrix layout
--
-- Target order mirrors the Matrix page visual grouping:
--   Expense → Employee info → Employee admin → Department →
--   Reference data → Projects → Exchange rates →
--   Security / Workflow / Jobs / Reports (system band)
-- =============================================================================

UPDATE modules SET sort_order = CASE code
  -- ── Expense ───────────────────────────────────────────────────────────────
  WHEN 'expense_reports'      THEN 10

  -- ── Employee info (satellite portlets) ────────────────────────────────────
  WHEN 'employee_details'     THEN 20
  WHEN 'personal_info'        THEN 21
  WHEN 'contact_info'         THEN 22
  WHEN 'employment'           THEN 23
  WHEN 'address'              THEN 24
  WHEN 'passport'             THEN 25
  WHEN 'identity_documents'   THEN 26
  WHEN 'emergency_contacts'   THEN 27
  WHEN 'bank_accounts'        THEN 28
  WHEN 'dependents'           THEN 29
  WHEN 'job_relationships'    THEN 30
  WHEN 'education'            THEN 31
  WHEN 'termination'          THEN 32
  WHEN 'org_chart'            THEN 33

  -- ── Employee admin ────────────────────────────────────────────────────────
  WHEN 'hire_employee'        THEN 40
  WHEN 'employee_hire'        THEN 41
  WHEN 'inactive_employees'   THEN 42

  -- ── Department ────────────────────────────────────────────────────────────
  WHEN 'departments'          THEN 50

  -- ── Reference data ────────────────────────────────────────────────────────
  WHEN 'picklists'            THEN 60

  -- ── Projects ──────────────────────────────────────────────────────────────
  WHEN 'projects_mgmt'        THEN 70

  -- ── Exchange rates ────────────────────────────────────────────────────────
  WHEN 'exchange_rates_mgmt'  THEN 80

  -- ── System / admin band ───────────────────────────────────────────────────
  WHEN 'security_admin'       THEN 90
  WHEN 'workflow_admin'       THEN 91
  WHEN 'workflow'             THEN 92
  WHEN 'jobs_admin'           THEN 93
  WHEN 'reports_admin'        THEN 94
  WHEN 'employee_search'      THEN 95

  ELSE sort_order  -- leave anything unknown untouched
END;

DO $$
BEGIN
  RAISE NOTICE 'Mig 552: modules.sort_order updated to match Permission Matrix layout.';
END;
$$;
