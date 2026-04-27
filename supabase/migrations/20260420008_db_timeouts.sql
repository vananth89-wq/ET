-- =============================================================================
-- Migration : 20260420008_db_timeouts.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-04-20
-- Description: Sets session-level timeouts on the PostgREST roles so that
--              dead connections never accumulate as "idle in transaction".
--
--   idle_in_transaction_session_timeout
--     → Kills any session that has been idle INSIDE a transaction for > 30s.
--       This is the root cause of write operations hanging: page refreshes or
--       network drops during a Supabase request leave the PostgreSQL transaction
--       open, holding row/table locks. New operations queue behind those locks
--       indefinitely until the dead session is manually terminated.
--
--   statement_timeout
--     → Kills any single SQL statement that runs for > 30s.
--       Safety net for runaway queries; does not affect normal OLTP workloads.
--
-- Roles targeted:
--   authenticated  — JWT-authenticated API calls (all supabase-js write ops)
--   anon           — public / unauthenticated API calls
--   authenticator  — PostgREST session role that switches to anon/authenticated
-- =============================================================================

ALTER ROLE authenticated  SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE authenticated  SET statement_timeout                   = '30s';

ALTER ROLE anon           SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE anon           SET statement_timeout                   = '30s';

ALTER ROLE authenticator  SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE authenticator  SET statement_timeout                   = '30s';

-- =============================================================================
-- END OF MIGRATION 20260420008_db_timeouts.sql
-- =============================================================================
