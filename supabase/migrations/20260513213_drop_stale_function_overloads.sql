-- =============================================================================
-- Migration 213: Drop stale function overloads
--
-- PROBLEM
-- ───────
-- CREATE OR REPLACE FUNCTION only replaces a function with the EXACT SAME
-- signature. When a migration adds a new parameter, it creates a NEW overload
-- alongside the old one rather than replacing it. PostgreSQL then raises:
--   "Could not choose the best function between..." ambiguity error
-- when a caller's argument list matches both signatures.
--
-- Two such overloads were identified by auditing all migrations:
--
-- 1. wf_submit
--    • Original (mig 030–164): (text, text, uuid, jsonb DEFAULT '{}')  — 4 params
--    • New (mig 177+):         (text, text, uuid, jsonb, text DEFAULT NULL) — 5 params
--    Both live in pg_proc. RPC calls with 4 named args are ambiguous.
--
-- 2. wf_add_step
--    • Original (mig 032):     10 params (no p_is_cc, no p_notification_template_id)
--    • New (mig 093+):         12 params (added p_is_cc, p_notification_template_id)
--    Both live in pg_proc. RPC calls with 10 named args are ambiguous.
--
-- (wf_resubmit had the same issue — fixed in mig 212.)
--
-- FIX
-- ───
-- Explicitly DROP the old overloads. The current (newer) signatures with
-- DEFAULT params continue to handle all existing callers transparently.
--
-- NO LOGIC CHANGES — DROP only.
-- =============================================================================


-- ── 1. wf_submit: drop old 4-param overload ───────────────────────────────────
-- Old: wf_submit(text, text, uuid, jsonb)
-- Keep: wf_submit(text, text, uuid, jsonb, text)  ← has p_comment DEFAULT NULL
DROP FUNCTION IF EXISTS wf_submit(text, text, uuid, jsonb);


-- ── 2. wf_add_step: drop old 10-param overload ────────────────────────────────
-- Old: wf_add_step(uuid, int, text, text, text, uuid, int, int, int, bool, bool)
-- Keep: wf_add_step(uuid, int, text, text, text, uuid, int, int, int, bool, bool, bool, uuid)
--       ← has p_is_cc boolean DEFAULT false, p_notification_template_id uuid DEFAULT NULL
DROP FUNCTION IF EXISTS wf_add_step(uuid, integer, text, text, text, uuid, integer, integer, integer, boolean, boolean);


-- ── Verification: confirm exactly one overload each ───────────────────────────
SELECT proname, pg_get_function_arguments(oid) AS args
FROM   pg_proc
WHERE  proname IN ('wf_submit', 'wf_add_step', 'wf_resubmit')
ORDER  BY proname, args;
