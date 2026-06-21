-- Migration 257: Add index on employees.status
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Queries filtering by status (hire pipeline list, RLS policy evaluation,
-- submit_hire status gate, wf_activate_employee guard) currently do a full
-- sequential scan. This index lets the planner use a bitmap index scan for
-- low-cardinality status filters as the table grows.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_employees_status ON employees(status);

COMMENT ON INDEX idx_employees_status IS
  'Supports WHERE status = / IN queries on the hire pipeline and RLS policies.';
