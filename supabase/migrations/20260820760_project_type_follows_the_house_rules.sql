-- =============================================================================
-- Migration : 20260820760_project_type_follows_the_house_rules.sql
-- Renumbered : was 20260820758. That version was taken by
--              20260820758_business_email_is_the_login.sql, which reached the
--              database first, so this file failed on the schema_migrations
--              primary key -- AFTER its own statements had run. It opens with
--              BEGIN; and its two UPDATEs match on the old value, so the failed
--              attempt rolled back cleanly and re-running is a no-op either way.
--
-- Purpose   : Make the PROJECT_TYPE picklist behave like every other picklist.
--             755 introduced two differences that were not deliberate.
--
-- 1. IT WAS NOT MARKED system
--    picklists.system (mig 20260420006) is what suppresses the Edit and Delete
--    buttons on the Reference Data list. Every built-in list sets it --
--    DESIGNATION, CURRENCY, RESIGNATION_REASON, TERMINATION_REASON -- and 755
--    did not, so PROJECT_TYPE was the one row on that screen offering to delete
--    itself. Deleting it would cascade its values, and ON DELETE SET NULL would
--    then silently unclassify every project pointing at them.
--
-- 2. ITS ref_ids WERE NOT 4-CHAR CODES
--    Reference Data generates ref_ids as the picklist's first letter plus three
--    digits (ReferenceData.tsx generateRefId): D001 for DESIGNATION, R001 for
--    RESIGNATION_REASON, T001 for TERMINATION_REASON. 755 seeded BILLABLE /
--    INTERNAL / OVERHEAD instead. Beyond being inconsistent, that BREAKS the
--    generator: it scans for the highest ^P(\d{3})$ and finds none, so the
--    first project type an admin adds is handed P001 -- sitting alongside three
--    values that follow no scheme at all.
--
--    So: BILLABLE -> P001, INTERNAL -> P002, OVERHEAD -> P003, and the next
--    value added through the UI becomes P004 as it should.
--
-- SAFE TO RECODE  project_type_id is a uuid FK to picklist_values(id). Nothing
--   references ref_id yet -- no report reads it, and Dev has no classified
--   projects. Recoding now costs nothing; recoding after Project Summary ships
--   would mean a data migration.
--
-- CONSEQUENCE FOR REPORTS  Billable utilisation must match ref_id = 'P001', not
--   'BILLABLE'. That is less self-describing, and it is the price of following
--   the convention rather than inventing a second one -- the same trade every
--   D001 and T001 in this database already makes. The constant is named once,
--   in the column comment below and in design doc s3.
--
-- Depends on : 20260420006 (picklists.system), 755
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1  Mark it built-in
-- ═══════════════════════════════════════════════════════════════════════════

UPDATE picklists
   SET system      = true,
       meta_fields = COALESCE(meta_fields, '[]'::jsonb)
 WHERE picklist_id = 'PROJECT_TYPE'
   AND system IS DISTINCT FROM true;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2  Recode the values onto the house scheme
--
-- Matched on the OLD code, so this is a no-op on a database where 755 never
-- ran with the old seed, and on a re-run.
-- ═══════════════════════════════════════════════════════════════════════════

UPDATE picklist_values pv
   SET ref_id = m.new_ref
  FROM (VALUES ('BILLABLE','P001'),
               ('INTERNAL','P002'),
               ('OVERHEAD','P003')) AS m(old_ref, new_ref)
 WHERE pv.ref_id = m.old_ref
   AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'PROJECT_TYPE');

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3  Re-document the column 755 commented
-- ═══════════════════════════════════════════════════════════════════════════

COMMENT ON COLUMN projects.project_type_id IS
  'Project classification, as a value of the PROJECT_TYPE picklist. NULL means '
  'not classified -- reports must show that plainly rather than assuming '
  'billable. Match on picklist_values.ref_id: P001 billable, P002 internal, '
  'P003 overhead. Never match on the label, which admins may rename.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_codes   text;
  v_sys     boolean;
BEGIN
  SELECT system INTO v_sys FROM picklists WHERE picklist_id = 'PROJECT_TYPE';
  IF v_sys IS NULL THEN
    v_missing := v_missing || 'the PROJECT_TYPE picklist is missing'::text;
  ELSIF NOT v_sys THEN
    v_missing := v_missing || 'PROJECT_TYPE is not marked system -- Reference Data would offer to delete it'::text;
  END IF;

  SELECT string_agg(pv.ref_id, ',' ORDER BY pv.ref_id)
    INTO v_codes
    FROM picklist_values pv JOIN picklists p ON p.id = pv.picklist_id
   WHERE p.picklist_id = 'PROJECT_TYPE';
  IF v_codes IS DISTINCT FROM 'P001,P002,P003' THEN
    v_missing := v_missing || format('expected ref_ids P001,P002,P003 -- found %s', COALESCE(v_codes,'none')); END IF;

  -- Every ref_id must match the generator's pattern, or the next value added
  -- through the UI collides with one of these.
  IF EXISTS (
    SELECT 1 FROM picklist_values pv JOIN picklists p ON p.id = pv.picklist_id
    WHERE p.picklist_id = 'PROJECT_TYPE' AND pv.ref_id !~ '^P[0-9]{3}$'
  ) THEN
    v_missing := v_missing || 'a PROJECT_TYPE ref_id does not match ^P[0-9]{3}$'::text; END IF;

  -- The labels must survive the recode untouched.
  IF NOT EXISTS (SELECT 1 FROM picklist_values pv JOIN picklists p ON p.id = pv.picklist_id
                 WHERE p.picklist_id = 'PROJECT_TYPE' AND pv.ref_id = 'P001' AND pv.value = 'Billable') THEN
    v_missing := v_missing || 'P001 is not Billable'::text; END IF;

  -- 755 must survive.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgname = 'trg_projects_project_type_guard' AND NOT tgisinternal) THEN
    v_missing := v_missing || 'mig 755: the PROJECT_TYPE guard trigger was lost'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'projects_project_type_id_fkey' AND contype = 'f' AND confdeltype = 'n') THEN
    v_missing := v_missing || 'mig 755: the project_type_id FK was lost'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 760 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 760 verified: PROJECT_TYPE is built-in and coded P001-P003, like every other picklist.';
END $mig$;

COMMIT;
