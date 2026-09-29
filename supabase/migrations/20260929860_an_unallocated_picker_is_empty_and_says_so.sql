-- =============================================================================
-- Migration 860 — an unallocated picker is empty, and says so
--
-- my_timesheet_projects() narrows the timesheet's project dropdown to the
-- projects an employee is actually on. It carried one escape hatch:
--
--     AND ( p.id IN (SELECT project_id FROM keep)
--           OR NOT EXISTS (SELECT 1 FROM keep) )   -- nothing to narrow to
--
-- With nothing in `keep` -- no membership overlapping the period, no entry ever
-- booked -- the filter switched itself off and offered EVERY active project.
-- The reasoning was sound as far as it went: narrowing must never be the reason
-- somebody cannot record their time.
--
-- The cost was invisible, which is what makes it worth removing:
--
--   * It looks exactly like a broken filter. An employee with no allocation
--     sees all twenty projects while everyone else sees three, and nothing on
--     the screen says the rule stopped applying. Reported as a bug, twice.
--   * It let hours land on a project nobody had staffed anyone to. Those hours
--     are then in that project's utilisation, burn and cost, from a person the
--     project has no record of.
--
-- So the fallback goes. An employee with no allocation now gets an empty
-- picker -- and an empty picker with no explanation is the same failure in the
-- other direction, so MyTimesheet ships in the same release with a line saying
-- what is missing and who can fix it. Neither half is any use alone.
--
-- WHAT DELIBERATELY SURVIVES: the `booked` arm. A project this employee has
-- ever booked to stays offered, date-blind and period-blind, because an entry
-- that exists must always be able to name its own project -- otherwise editing
-- an old timesheet silently loses it. Removing the fallback must not touch
-- that, and the verification below proves it did not.
--
-- KNOWN CONSEQUENCE, accepted: a new joiner cannot record project work until
-- somebody allocates them. Allocation becomes a blocking step in onboarding
-- rather than a tidy-up. Leave and other non-project time are unaffected --
-- those time types do not require a project.
--
-- The one-argument wrapper delegates to this function and inherits the change.
--
-- Depends on : 787 (the function this patches)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;
  v_anchor CONSTANT text :=
'    AND  (
           p.id IN (SELECT project_id FROM keep)
           -- Nothing to narrow to: fall back to every active project, which is
           -- exactly the pre-783 dropdown. Narrowing must never be the reason
           -- somebody cannot record their time.
           OR NOT EXISTS (SELECT 1 FROM keep)
         )';
  v_repl CONSTANT text :=
'    -- Mig 860: no fallback. An employee with nothing in `keep` is not shown
    -- every active project -- that read as a broken filter and let hours land
    -- on projects nobody was staffed to. The picker is empty instead, and
    -- MyTimesheet says why. The `booked` arm above still keeps a project an
    -- entry already names.
    AND  p.id IN (SELECT project_id FROM keep)';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'my_timesheet_projects'
    AND  p.prokind = 'f'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_employee_id uuid, p_period_start date, p_period_end date';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 860: my_timesheet_projects(uuid, date, date) not found.';
  END IF;

  -- Semantic, not marker-based: the fallback predicate is either there or it
  -- is not, and its absence IS the applied state.
  IF position('OR NOT EXISTS (SELECT 1 FROM keep)' IN v_src) = 0 THEN
    RAISE NOTICE 'MIG 860: fallback already removed, skipping.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION
      'MIG 860: expected the fallback clause exactly once, found %. The live body '
      'is not what this migration was written against; patching it blind would '
      'discard whatever it became. Live body: %', v_hits, v_src;
  END IF;

  v_new := replace(v_src, v_anchor, v_repl);

  IF position('OR NOT EXISTS (SELECT 1 FROM keep)' IN v_new) > 0 THEN
    RAISE EXCEPTION 'MIG 860: the fallback survived the replacement.';
  END IF;
  -- The booked arm is the thing most easily lost by a careless edit here.
  IF position('booked AS (' IN v_new) = 0 THEN
    RAISE EXCEPTION 'MIG 860: the booked CTE is missing from the rewritten body.';
  END IF;

  EXECUTE v_new;
END
$mig$;

COMMENT ON FUNCTION public.my_timesheet_projects(uuid, date, date) IS
  'Projects offered on a timesheet for a period: memberships overlapping the '
  'period, plus any project this employee has ever booked to. Mig 860 removed '
  'the fall-back-to-everything branch, so an employee with neither gets an '
  'empty list rather than the whole company''s projects.';

-- ── Verification ─────────────────────────────────────────────────────────────

DO $mig$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'my_timesheet_projects'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_employee_id uuid, p_period_start date, p_period_end date';

  IF position('OR NOT EXISTS (SELECT 1 FROM keep)' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 860: fallback still present after the patch.';
  END IF;
  IF position('booked AS (' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 860: booked CTE lost.';
  END IF;
  IF position('p.id IN (SELECT project_id FROM keep)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 860: the narrowing predicate itself is gone -- the picker would be empty for everybody.';
  END IF;

  RAISE NOTICE 'MIG 860: fallback removed; narrowing and the booked arm both intact.';
END
$mig$;

COMMIT;
