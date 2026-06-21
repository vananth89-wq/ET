-- =============================================================================
-- Migration 274: Bank Details — Reference Data, Permissions, Module Code
--
-- 1. Create BANK picklist (child of ID_COUNTRY — same pattern as ID_TYPE)
-- 2. Seed top-10 banks for each of the 4 target countries:
--       India (IND / G001), Saudi Arabia (SAU / G002),
--       Pakistan (PAK / G012), Sri Lanka (LKA / G013)
-- 3. Register two new permissions:
--       employee.view_bank_accounts  (sort 130)
--       employee.edit_bank_accounts  (sort 135)
-- 4. Assign those permissions to default roles
-- 5. Insert profile_bank into module_codes
-- 6. Add BANK picklist relationship to bank_exceptions role (if role exists)
--
-- NOTES
-- ─────
-- Bank picklist mirrors the ID_TYPE / ID_COUNTRY parent pattern:
--   • Each bank row has parent_value_id → the matching ID_COUNTRY picklist value
--   • Filtering by country on the UI: WHERE parent_value_id = <selected country pv.id>
-- Future countries: add the country to ID_COUNTRY picklist + add bank rows with
--   the matching parent_value_id → zero code changes needed.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Create BANK picklist
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO picklists (picklist_id, name, system, meta_fields)
VALUES (
  'BANK',
  'Bank',
  true,
  '[{"key":"swiftCode","label":"SWIFT / BIC","type":"text"}]'::jsonb
)
ON CONFLICT (picklist_id) DO NOTHING;

-- Wire BANK → parent = ID_COUNTRY (same as ID_TYPE → ID_COUNTRY)
UPDATE picklists child
SET    parent_picklist_id = parent.id
FROM   picklists parent
WHERE  child.picklist_id  = 'BANK'
  AND  parent.picklist_id = 'ID_COUNTRY';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Seed top-10 banks per country
--    Ref IDs: B_IND_001..010, B_LKA_001..010, B_PAK_001..010, B_SAU_001..010
--    country_ref matches ID_COUNTRY ref_id:
--      G001 = India, G002 = Saudi Arabia, G012 = Pakistan, G013 = Sri Lanka
-- ─────────────────────────────────────────────────────────────────────────────

-- Guard: skip if BANK values already exist (idempotent re-run safety)
INSERT INTO picklist_values (picklist_id, value, ref_id, parent_value_id, active)
SELECT
  (SELECT id FROM picklists WHERE picklist_id = 'BANK'),
  v.value,
  v.ref_id,
  (SELECT pv.id
   FROM   picklist_values pv
   JOIN   picklists pl ON pl.id = pv.picklist_id
   WHERE  pl.picklist_id = 'ID_COUNTRY'
     AND  pv.ref_id = v.country_ref),
  true
FROM (VALUES
  -- ── India (IND) ─────────────────────────────────────────────────────────
  ('B_IND_001', 'G001', 'State Bank of India (SBI)'),
  ('B_IND_002', 'G001', 'HDFC Bank'),
  ('B_IND_003', 'G001', 'ICICI Bank'),
  ('B_IND_004', 'G001', 'Axis Bank'),
  ('B_IND_005', 'G001', 'Kotak Mahindra Bank'),
  ('B_IND_006', 'G001', 'Punjab National Bank'),
  ('B_IND_007', 'G001', 'Bank of Baroda'),
  ('B_IND_008', 'G001', 'Canara Bank'),
  ('B_IND_009', 'G001', 'Union Bank of India'),
  ('B_IND_010', 'G001', 'IndusInd Bank'),

  -- ── Saudi Arabia (SAU) ──────────────────────────────────────────────────
  ('B_SAU_001', 'G002', 'Al Rajhi Bank'),
  ('B_SAU_002', 'G002', 'Saudi National Bank (SNB)'),
  ('B_SAU_003', 'G002', 'Riyad Bank'),
  ('B_SAU_004', 'G002', 'Saudi British Bank (SABB)'),
  ('B_SAU_005', 'G002', 'Banque Saudi Fransi'),
  ('B_SAU_006', 'G002', 'Arab National Bank'),
  ('B_SAU_007', 'G002', 'Alinma Bank'),
  ('B_SAU_008', 'G002', 'Bank AlJazira'),
  ('B_SAU_009', 'G002', 'Saudi Investment Bank'),
  ('B_SAU_010', 'G002', 'Gulf International Bank'),

  -- ── Pakistan (PAK) ──────────────────────────────────────────────────────
  ('B_PAK_001', 'G012', 'Habib Bank Limited (HBL)'),
  ('B_PAK_002', 'G012', 'MCB Bank'),
  ('B_PAK_003', 'G012', 'United Bank Limited (UBL)'),
  ('B_PAK_004', 'G012', 'Allied Bank'),
  ('B_PAK_005', 'G012', 'Meezan Bank'),
  ('B_PAK_006', 'G012', 'Standard Chartered Pakistan'),
  ('B_PAK_007', 'G012', 'Bank Alfalah'),
  ('B_PAK_008', 'G012', 'Faysal Bank'),
  ('B_PAK_009', 'G012', 'Askari Bank'),
  ('B_PAK_010', 'G012', 'JS Bank'),

  -- ── Sri Lanka (LKA) ─────────────────────────────────────────────────────
  ('B_LKA_001', 'G013', 'Bank of Ceylon'),
  ('B_LKA_002', 'G013', 'Commercial Bank of Ceylon'),
  ('B_LKA_003', 'G013', 'Hatton National Bank'),
  ('B_LKA_004', 'G013', 'Sampath Bank'),
  ('B_LKA_005', 'G013', 'People''s Bank'),
  ('B_LKA_006', 'G013', 'Nations Trust Bank'),
  ('B_LKA_007', 'G013', 'DFCC Bank'),
  ('B_LKA_008', 'G013', 'NDB Bank'),
  ('B_LKA_009', 'G013', 'Seylan Bank'),
  ('B_LKA_010', 'G013', 'Pan Asia Banking Corporation')

) AS v(ref_id, country_ref, value)
-- ref_id has no unique constraint — guard with NOT EXISTS instead of ON CONFLICT
WHERE NOT EXISTS (
  SELECT 1
  FROM   picklist_values existing_pv
  JOIN   picklists existing_pl ON existing_pl.id = existing_pv.picklist_id
  WHERE  existing_pl.picklist_id = 'BANK'
    AND  existing_pv.ref_id      = v.ref_id
);


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Register permissions
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT p.code, p.name, p.description, m.id, p.sort_order
FROM (VALUES
  ('employee.view_bank_accounts',
   'View Bank Accounts',
   'View the Bank Accounts portlet for employees in your target group: account holder, bank name, account number (masked), country, currency, primary flag.',
   130),
  ('employee.edit_bank_accounts',
   'Edit Bank Accounts',
   'Add and amend bank account records for employees in your target group. Scope controlled by Target Groups. New hires can add accounts during onboarding. ESS employees can manage their own accounts (subject to the 15th-of-month date cutoff).',
   135)
) AS p(code, name, description, sort_order)
JOIN modules m ON m.code = 'employee'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. profile_bank module code
--    (role_permissions seeded via Permission Matrix UI — not done here)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO module_codes (code, label, description)
VALUES (
  'profile_bank',
  'Profile – Bank Details',
  'Employee bank account add / amendment requests requiring approval'
)
ON CONFLICT (code) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Verification
-- ─────────────────────────────────────────────────────────────────────────────

-- Confirm picklist created
SELECT picklist_id, name, system FROM picklists WHERE picklist_id = 'BANK';

-- Confirm banks seeded
SELECT COUNT(*) AS bank_count FROM picklist_values pv
JOIN picklists pl ON pl.id = pv.picklist_id
WHERE pl.picklist_id = 'BANK';

-- Confirm permissions
SELECT code, name, sort_order FROM permissions
WHERE code LIKE 'employee.%bank%'
ORDER BY sort_order;

-- Confirm module code
SELECT code, label FROM module_codes WHERE code = 'profile_bank';

-- =============================================================================
-- END OF MIGRATION 274
-- =============================================================================
