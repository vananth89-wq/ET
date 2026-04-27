-- =============================================================================
-- Add sort_order to permissions
--
-- Gives every permission an explicit display position within its module so
-- any screen that reads permissions gets a consistent, logical order without
-- client-side hacks.
--
-- Default = 999 → new/unknown permissions sort to the bottom alphabetically.
-- Expense module is seeded with the agreed lifecycle order:
--   own-visibility → create → edit → submit → delete
--   → direct-visibility → team-visibility → org-visibility
--   → approval-action → export
-- =============================================================================


-- ── 1. Add the column ─────────────────────────────────────────────────────────

ALTER TABLE permissions
  ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 999;


-- ── 2. Seed expense permission order ─────────────────────────────────────────

UPDATE permissions SET sort_order = 1  WHERE code = 'expense.view_own';
UPDATE permissions SET sort_order = 2  WHERE code = 'expense.create';
UPDATE permissions SET sort_order = 3  WHERE code = 'expense.edit';
UPDATE permissions SET sort_order = 4  WHERE code = 'expense.submit';
UPDATE permissions SET sort_order = 5  WHERE code = 'expense.delete';
UPDATE permissions SET sort_order = 6  WHERE code = 'expense.view_direct';
UPDATE permissions SET sort_order = 7  WHERE code = 'expense.view_team';
UPDATE permissions SET sort_order = 8  WHERE code = 'expense.view_org';
UPDATE permissions SET sort_order = 9  WHERE code = 'expense.edit_approval';
UPDATE permissions SET sort_order = 10 WHERE code = 'expense.export';


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT code, name, sort_order
FROM   permissions
WHERE  module_id = (SELECT id FROM modules WHERE code = 'expense')
ORDER  BY sort_order, code;
