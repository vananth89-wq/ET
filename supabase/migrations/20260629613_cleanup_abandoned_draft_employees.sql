-- =============================================================================
-- Migration 577 — Clean up abandoned Draft employees
--
-- Findings (2026-06-24 audit):
--
-- EMP-0182 Sharina Syed:  soft-deleted, workflow withdrawn, but locked=true
--                          (wf_sync_module_status for 'draft/withdrawn' should
--                           have cleared locked — fix the stale lock).
--
-- EMP-0193 Mohamed Rayyan  \
-- EMP-0243 Zaara Mohamed    |  No workflow instance ever created.
-- EMP-0289 Harish Kumar     |  Pure abandoned drafts — never submitted.
-- EMP-0375 Shankari Dhevi   |  Safe to soft-delete.
-- EMP-0453 Jeevitha Shankar /
-- =============================================================================

-- ── 1. Fix Sharina's stale lock ───────────────────────────────────────────────
UPDATE employees
SET    locked     = false,
       updated_at = now()
WHERE  employee_id = 'EMP-0182'
  AND  deleted_at IS NOT NULL
  AND  locked = true;

-- ── 2. Soft-delete the 5 never-submitted Draft employees ─────────────────────
UPDATE employees
SET    deleted_at = now(),
       updated_at = now()
WHERE  employee_id IN ('EMP-0193', 'EMP-0243', 'EMP-0289', 'EMP-0375', 'EMP-0453')
  AND  status    = 'Draft'
  AND  deleted_at IS NULL;

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_remaining integer;
BEGIN
  SELECT COUNT(*) INTO v_remaining
  FROM   employees
  WHERE  status = 'Draft'
    AND  deleted_at IS NULL
    AND  employee_id IN ('EMP-0182','EMP-0193','EMP-0243','EMP-0289','EMP-0375','EMP-0453');

  IF v_remaining > 0 THEN
    RAISE WARNING 'Migration 577: % Draft employee(s) still have deleted_at = NULL — check manually.', v_remaining;
  ELSE
    RAISE NOTICE 'Migration 577 verified: all 6 Draft employees cleaned up.';
  END IF;
END $$;
