-- =============================================================================
-- Migration 136: Upgrade currencies & exchange_rates RLS to user_can()
--
-- BACKGROUND
-- ──────────
-- Both tables use has_permission('exchange_rate.*') which reads from the
-- dead role_permissions table. Granular codes (view/create/edit/delete)
-- are collapsed into two Permission Matrix toggles:
--   exchange_rates_mgmt.view — read access to currencies and exchange rates
--   exchange_rates_mgmt.edit — full write access to both tables
--
-- The exchange_rates_mgmt module already exists (seeded in the initial schema).
-- Both permissions are new and seeded here.
--
-- NOTE: currencies and exchange_rates share the same permission gate —
-- you cannot view one without the other, which matches existing UX
-- (the Finance / Exchange Rates screen shows both together).
-- =============================================================================


-- ── 1. Seed exchange_rates_mgmt.view and .edit permissions ───────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT p.code, p.name, p.description, m.id, p.action
FROM (VALUES
  ('exchange_rates_mgmt.view', 'View Exchange Rates',   'Grants read access to currencies and exchange rates',       'view'),
  ('exchange_rates_mgmt.edit', 'Manage Exchange Rates', 'Grants create / update / delete on currencies and rates',   'edit')
) AS p(code, name, description, action)
JOIN modules m ON m.code = 'exchange_rates_mgmt'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. currencies ─────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS currencies_select ON currencies;
DROP POLICY IF EXISTS currencies_insert ON currencies;
DROP POLICY IF EXISTS currencies_update ON currencies;
DROP POLICY IF EXISTS currencies_delete ON currencies;

CREATE POLICY currencies_select ON currencies FOR SELECT
  USING (user_can('exchange_rates_mgmt', 'view', NULL));

CREATE POLICY currencies_insert ON currencies FOR INSERT
  WITH CHECK (user_can('exchange_rates_mgmt', 'edit', NULL));

CREATE POLICY currencies_update ON currencies FOR UPDATE
  USING      (user_can('exchange_rates_mgmt', 'edit', NULL))
  WITH CHECK (user_can('exchange_rates_mgmt', 'edit', NULL));

CREATE POLICY currencies_delete ON currencies FOR DELETE
  USING (user_can('exchange_rates_mgmt', 'edit', NULL));


-- ── 3. exchange_rates ─────────────────────────────────────────────────────────

DROP POLICY IF EXISTS exchange_rates_select ON exchange_rates;
DROP POLICY IF EXISTS exchange_rates_insert ON exchange_rates;
DROP POLICY IF EXISTS exchange_rates_update ON exchange_rates;
DROP POLICY IF EXISTS exchange_rates_delete ON exchange_rates;

CREATE POLICY exchange_rates_select ON exchange_rates FOR SELECT
  USING (user_can('exchange_rates_mgmt', 'view', NULL));

CREATE POLICY exchange_rates_insert ON exchange_rates FOR INSERT
  WITH CHECK (user_can('exchange_rates_mgmt', 'edit', NULL));

CREATE POLICY exchange_rates_update ON exchange_rates FOR UPDATE
  USING      (user_can('exchange_rates_mgmt', 'edit', NULL))
  WITH CHECK (user_can('exchange_rates_mgmt', 'edit', NULL));

CREATE POLICY exchange_rates_delete ON exchange_rates FOR DELETE
  USING (user_can('exchange_rates_mgmt', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('currencies', 'exchange_rates')
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('exchange_rates_mgmt.view', 'exchange_rates_mgmt.edit')
ORDER  BY code;
