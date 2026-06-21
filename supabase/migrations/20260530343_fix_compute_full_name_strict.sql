-- =============================================================================
-- Migration 343 — Fix compute_full_name: remove STRICT
-- =============================================================================
--
-- BUG
-- ───
-- Mig 334 declared compute_full_name(...) as STRICT.
-- In PostgreSQL, STRICT means the function returns NULL if ANY argument is NULL —
-- not just if all arguments are NULL (the mig-334 comment was incorrect).
--
-- Impact: compute_full_name('Mohammed', NULL, 'Nasik') → NULL
-- This NULL propagates into upsert_personal_info step 8:
--   UPDATE employees SET name = NULL  ← violates NOT NULL constraint
-- The exception is caught and returned as {ok:false}, so Save Draft silently
-- fails to persist first_name / last_name for any employee without a middle name.
--
-- FIX
-- ───
-- Drop STRICT. The CASE logic inside the function already handles NULL inputs
-- correctly for each combination of first/middle/last name.
-- =============================================================================

CREATE OR REPLACE FUNCTION compute_full_name(
  p_first  text,
  p_middle text,
  p_last   text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
-- STRICT removed: PostgreSQL STRICT returns NULL if ANY arg is NULL, but
-- middle_name and last_name are legitimately optional. The CASE below handles
-- all NULL combinations correctly.
SET search_path = public
AS $$
  SELECT trim(
    CASE
      WHEN p_first IS NOT NULL AND p_middle IS NOT NULL AND p_last IS NOT NULL
        THEN p_first || ' ' || p_middle || ' ' || p_last
      WHEN p_first IS NOT NULL AND p_last IS NOT NULL
        THEN p_first || ' ' || p_last
      WHEN p_first IS NOT NULL AND p_middle IS NOT NULL
        THEN p_first || ' ' || p_middle
      ELSE COALESCE(p_first, '')
    END
  )
$$;

COMMENT ON FUNCTION compute_full_name(text, text, text) IS
  'Concatenates first_name, middle_name, last_name into a display name. '
  'Rules: all three present → F M L; first+last → F L; first+middle → F M; '
  'first only → F. Trims result. '
  'Mig 334: initial (had incorrect STRICT). Mig 343: STRICT removed — '
  'middle_name and last_name are optional; STRICT would return NULL whenever '
  'either is NULL, breaking the NOT NULL constraint on employees.name.';
