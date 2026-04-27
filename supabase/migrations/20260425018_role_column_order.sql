-- =============================================================================
-- Role Column Display Order
--
-- Desired column order in Role Management grid:
--   Employee SS → Manager → Dept Head → Finance → HR → (future custom) → Admin
--
-- Strategy:
--   • System roles (ess, manager, dept_head) get sort_order 1-3
--   • Custom roles (finance, hr, any user-created) keep their existing order
--     but are offset to 10+ so they always follow system roles
--   • Protected (admin) gets sort_order 999 — rendered last within its group,
--     and the frontend puts protected type after custom anyway
-- =============================================================================

-- System roles — explicit workflow order
UPDATE roles SET sort_order = 1  WHERE code = 'ess';
UPDATE roles SET sort_order = 2  WHERE code = 'manager';
UPDATE roles SET sort_order = 3  WHERE code = 'dept_head';

-- Custom roles — offset so they sit after system in the same sort space
UPDATE roles SET sort_order = 10 WHERE code = 'finance';
UPDATE roles SET sort_order = 11 WHERE code = 'hr';

-- Protected — always last
UPDATE roles SET sort_order = 999 WHERE code = 'admin';

-- Verification
SELECT code, name, role_type, sort_order
FROM   roles
WHERE  active = true
ORDER  BY
  CASE role_type WHEN 'system' THEN 0 WHEN 'custom' THEN 1 ELSE 2 END,
  sort_order;
