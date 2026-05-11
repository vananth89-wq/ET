-- =============================================================================
-- Migration 187: Drop the old 4-parameter overload of wf_submit
--
-- ROOT CAUSE
-- ──────────
-- Migration 177 (employee_comment) added p_comment text DEFAULT NULL to
-- wf_submit, changing its signature from:
--   wf_submit(text, text, uuid, jsonb)           ← old
-- to:
--   wf_submit(text, text, uuid, jsonb, text)      ← new (with p_comment)
--
-- In PostgreSQL, CREATE OR REPLACE FUNCTION only replaces a function when
-- the parameter list is IDENTICAL. Adding a new parameter — even with a
-- DEFAULT — creates a SECOND overload instead of replacing the original.
-- Both versions now coexist in pg_proc, causing:
--
--   function wf_submit(p_template_code => text, p_module_code => unknown,
--     p_record_id => uuid, p_metadata => jsonb) is not unique
--
-- whenever the frontend calls wf_submit without p_comment (which is the
-- normal path since p_comment is optional).
--
-- FIX
-- ───
-- Drop the stale 4-parameter overload. The 5-parameter version (with
-- p_comment DEFAULT NULL) is fully backward-compatible — all callers that
-- omit p_comment continue to work unchanged.
-- =============================================================================

DROP FUNCTION IF EXISTS wf_submit(text, text, uuid, jsonb);


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

-- Should return exactly ONE row for wf_submit after the drop.
SELECT proname,
       pg_get_function_arguments(oid) AS args
FROM   pg_proc
WHERE  proname = 'wf_submit';

-- =============================================================================
-- END OF MIGRATION 187
-- =============================================================================
