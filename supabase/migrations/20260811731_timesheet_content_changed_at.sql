-- Migration : 20260811731_timesheet_content_changed_at.sql
-- Purpose   : Know whether a timesheet has actually changed since it was approved.
--
-- WHY
--   Migration 730 made an approved month editable and put a Resubmit button on
--   it. The button was live whenever the month had any entries at all, so it
--   invited a resubmission of a sheet nobody had touched -- which would stamp a
--   fresh approved_at, and later a fresh workflow instance, over nothing. The
--   button has to be able to answer "has anything moved?" and there is currently
--   nothing in the schema that can answer it.
--
-- WHY NOT max(timesheet_entries.updated_at)
--   Three holes, and the first two are the ones that matter:
--
--   1. DELETE leaves no trace. Remove an entry from an approved month and the
--      max over the surviving rows does not move -- the sheet is materially
--      different and reads as untouched. Delete the only entry and there are no
--      rows to take a max over at all.
--
--   2. An activity-level edit can leave the parent row alone. mig 727's sync
--      only writes the parent when the SUM or the NAME LIST differs:
--        UPDATE ... WHERE hours_minutes IS DISTINCT FROM v_sum
--                      OR activities    IS DISTINCT FROM v_names
--      Move an hour from "Code Review" to "Testing" and both are unchanged, so
--      timesheet_entries.updated_at never moves although the day's breakdown --
--      the thing mig 727 exists to record -- did. Hence a trigger on the
--      activities table too, not only on entries.
--
--   3. It is a query over child rows every time the screen renders a button.
--
--   A column the writes maintain answers all three and costs one UPDATE on a row
--   the same statement has usually touched anyway.
--
-- WHAT "CHANGED" MEANS HERE
--   Any insert, update or delete of an entry or of an activity line, INCLUDING
--   system-generated rows. A holiday appearing in an approved month changes what
--   that month says, so it should be re-filed. (In practice migs 722-724 already
--   knock such a sheet back to to_be_submitted, so this is belt and braces.)
--
-- Depends on : 704 (timesheet_headers), 705 (timesheet_entries),
--              727 (timesheet_entry_activities), 730 (editable approved months)

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the column
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.timesheet_headers
  ADD COLUMN IF NOT EXISTS content_changed_at timestamptz;

-- A header created after this migration has no entries yet, so no trigger has
-- fired and the column would sit NULL until the first save. Harmless in
-- practice -- an empty sheet cannot be submitted, let alone approved -- but a
-- column that is "never NULL except sometimes" is a column every future reader
-- has to reason about. The default makes the invariant true instead.
ALTER TABLE public.timesheet_headers
  ALTER COLUMN content_changed_at SET DEFAULT now();

COMMENT ON COLUMN public.timesheet_headers.content_changed_at IS
  'Mig 731: when an entry or activity line under this header was last inserted, '
  'updated or deleted. Compared against approved_at to decide whether there is '
  'anything to resubmit. Defaults to the header''s own creation.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — keep it true
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.time_touch_header_content()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_header uuid;
BEGIN
  IF TG_TABLE_NAME = 'timesheet_entries' THEN
    -- plpgsql will not resolve a record through CASE, so this stays an IF.
    IF TG_OP = 'DELETE' THEN v_header := OLD.header_id;
                        ELSE v_header := NEW.header_id;
    END IF;
  ELSE
    -- Activity lines reach the header through their entry. On a cascade the
    -- entry may already be gone, leaving NULL -- which is correct to ignore,
    -- because the entry's own DELETE has already stamped the header.
    SELECT e.header_id INTO v_header
    FROM   timesheet_entries e
    WHERE  e.id = COALESCE(NEW.entry_id, OLD.entry_id);
  END IF;

  IF v_header IS NOT NULL THEN
    -- Matches zero rows when the header itself is being deleted and this fired
    -- from the ON DELETE CASCADE. That is not an error; there is nothing left
    -- to stamp.
    UPDATE timesheet_headers
    SET    content_changed_at = now()
    WHERE  id = v_header;
  END IF;

  RETURN NULL;   -- AFTER trigger; the return value is ignored
END $$;

REVOKE ALL ON FUNCTION public.time_touch_header_content() FROM PUBLIC;

COMMENT ON FUNCTION public.time_touch_header_content IS
  'Mig 731: stamps timesheet_headers.content_changed_at on any entry or activity write.';

DROP TRIGGER IF EXISTS trg_timesheet_entry_touch_header ON public.timesheet_entries;
CREATE TRIGGER trg_timesheet_entry_touch_header
  AFTER INSERT OR UPDATE OR DELETE ON public.timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION public.time_touch_header_content();

DROP TRIGGER IF EXISTS trg_timesheet_activity_touch_header ON public.timesheet_entry_activities;
CREATE TRIGGER trg_timesheet_activity_touch_header
  AFTER INSERT OR UPDATE OR DELETE ON public.timesheet_entry_activities
  FOR EACH ROW EXECUTE FUNCTION public.time_touch_header_content();

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — backfill
-- ═══════════════════════════════════════════════════════════════════════════
-- An approved sheet gets approved_at, not max(updated_at). Before mig 730
-- nothing could edit an approved month, so by construction nothing HAS changed
-- since it was approved -- and max(updated_at) can legitimately sit after
-- approved_at (mig 730 PART 4 back-dated approvals to the original submission),
-- which would light up Resubmit on every historical sheet at once.
--
-- Anything else is stamped from its newest child row, or from the header's own
-- creation if it has none, so the column is never NULL on an existing row.

UPDATE public.timesheet_headers h
SET    content_changed_at =
         CASE
           WHEN h.status = 'approved' AND h.approved_at IS NOT NULL
             THEN h.approved_at
           ELSE COALESCE(
                  (SELECT max(e.updated_at) FROM timesheet_entries e WHERE e.header_id = h.id),
                  h.created_at)
         END
WHERE  h.content_changed_at IS NULL;

DO $$
DECLARE v_null integer;
BEGIN
  SELECT count(*) INTO v_null FROM timesheet_headers WHERE content_changed_at IS NULL;
  IF v_null > 0 THEN
    RAISE EXCEPTION 'MIG 731: % header(s) left with a NULL content_changed_at.', v_null;
  END IF;
  RAISE NOTICE 'MIG 731: content_changed_at backfilled on every header.';
END $$;

COMMIT;
