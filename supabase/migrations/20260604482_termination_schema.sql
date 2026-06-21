-- =============================================================================
-- Migration 482 — Termination Module: Core Schema
--
-- Creates three tables:
--   1. employee_terminations         — event table (NOT effective-dated)
--   2. employee_termination_reversals — separate-table reversal model
--   3. employee_termination_attachments — shared attachment table for both
--
-- Partial unique indexes enforce:
--   • Only one PENDING or APPROVED termination per employee
--   • Only one PENDING or APPROVED reversal per termination
--
-- Audit triggers use the standard trg_write_audit_log() function.
-- RLS mirrors the education module pattern (Path A + Path B).
--
-- Design spec: docs/termination-design.md §2, §12
-- Next migration: 20260604483 (notice_period_days on employee_employment)
-- =============================================================================


-- =============================================================================
-- 1. employee_terminations
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_terminations (
  id                            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id                   UUID        NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,

  termination_date              DATE        NOT NULL,
  termination_reason_code       TEXT        NOT NULL,
  termination_initiation_type   TEXT        NOT NULL
                                  CHECK (termination_initiation_type IN
                                    ('SELF', 'HR_INITIATED', 'ADMIN_INITIATED', 'SYSTEM_INITIATED')),

  -- SELF-service fields
  resignation_date              DATE,
  notice_date                   DATE,
  last_working_date             DATE,

  -- Notice period
  notice_period_waived          BOOLEAN     NOT NULL DEFAULT false,
  notice_period_waiver_reason   TEXT,

  -- HR-only fields
  eligible_for_rehire           BOOLEAN     NOT NULL DEFAULT true,
  regrettable_termination       BOOLEAN,

  comments                      TEXT        NOT NULL,

  -- Workflow denormalization (§1 decision #3)
  workflow_status               TEXT        NOT NULL DEFAULT 'DRAFT'
                                  CHECK (workflow_status IN
                                    ('DRAFT', 'PENDING', 'APPROVED', 'REJECTED', 'WITHDRAWN', 'REVERSED')),
  workflow_instance_id          UUID        REFERENCES workflow_instances(id) ON DELETE SET NULL,
  approved_at                   TIMESTAMPTZ,
  approved_by                   UUID        REFERENCES profiles(id) ON DELETE SET NULL,

  -- Final settlement
  final_settlement_processed    BOOLEAN     NOT NULL DEFAULT false,
  final_settlement_date         DATE,

  -- Future-dated scheduler idempotency (§5.3)
  scheduled_executed            BOOLEAN     NOT NULL DEFAULT false,
  scheduled_executed_at         TIMESTAMPTZ,

  -- Bulk traceability (§14)
  upload_batch_id               UUID,

  -- Audit columns
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by                    UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by                    UUID        REFERENCES profiles(id) ON DELETE SET NULL,

  -- Constraints (§2.1)
  CONSTRAINT chk_term_comments_min
    CHECK (length(comments) >= 20),
  CONSTRAINT chk_term_comments_other
    CHECK (termination_reason_code <> 'OTHER' OR length(comments) >= 50),
  CONSTRAINT chk_term_waiver_reason
    CHECK (NOT notice_period_waived OR notice_period_waiver_reason IS NOT NULL),
  CONSTRAINT chk_term_resignation_self
    CHECK (termination_initiation_type <> 'SELF' OR resignation_date IS NOT NULL),
  CONSTRAINT chk_term_lwd_after_resignation
    CHECK (
      last_working_date IS NULL OR resignation_date IS NULL
      OR last_working_date >= resignation_date
    )
);

-- One active (PENDING or APPROVED) termination per employee (§3.1)
CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_active_termination
  ON employee_terminations (employee_id)
  WHERE workflow_status IN ('PENDING', 'APPROVED');

-- General-purpose indexes
CREATE INDEX IF NOT EXISTS ix_term_employee_id
  ON employee_terminations (employee_id);

CREATE INDEX IF NOT EXISTS ix_term_date
  ON employee_terminations (termination_date);

CREATE INDEX IF NOT EXISTS ix_term_status
  ON employee_terminations (workflow_status);

-- Partial index for the daily scheduler (§5.3) — only rows that need processing
CREATE INDEX IF NOT EXISTS ix_term_scheduled
  ON employee_terminations (termination_date, scheduled_executed)
  WHERE workflow_status = 'APPROVED' AND scheduled_executed = false;

-- Partial index for bulk batch lookups
CREATE INDEX IF NOT EXISTS ix_term_upload_batch
  ON employee_terminations (upload_batch_id)
  WHERE upload_batch_id IS NOT NULL;


-- =============================================================================
-- 2. employee_termination_reversals (§2.3, §1 decision #5)
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_termination_reversals (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  termination_id        UUID        NOT NULL
                          REFERENCES employee_terminations(id) ON DELETE RESTRICT,

  reversal_reason       TEXT        NOT NULL,
  comments              TEXT        NOT NULL,

  workflow_status       TEXT        NOT NULL DEFAULT 'DRAFT'
                          CHECK (workflow_status IN
                            ('DRAFT', 'PENDING', 'APPROVED', 'REJECTED', 'WITHDRAWN')),
  workflow_instance_id  UUID        REFERENCES workflow_instances(id) ON DELETE SET NULL,
  approved_at           TIMESTAMPTZ,
  approved_by           UUID        REFERENCES profiles(id) ON DELETE SET NULL,

  -- Audit columns
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by            UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by            UUID        REFERENCES profiles(id) ON DELETE SET NULL,

  CONSTRAINT chk_rev_comments_min
    CHECK (length(comments) >= 20)
);

-- One active (PENDING or APPROVED) reversal per termination
CREATE UNIQUE INDEX IF NOT EXISTS uq_termination_active_reversal
  ON employee_termination_reversals (termination_id)
  WHERE workflow_status IN ('PENDING', 'APPROVED');

CREATE INDEX IF NOT EXISTS ix_rev_termination
  ON employee_termination_reversals (termination_id);

CREATE INDEX IF NOT EXISTS ix_rev_status
  ON employee_termination_reversals (workflow_status);


-- =============================================================================
-- 3. employee_termination_attachments (§2.2)
--    Shared for both terminations and reversals.
--    Exactly one of (termination_id, reversal_id) must be non-null.
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_termination_attachments (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  termination_id      UUID        REFERENCES employee_terminations(id) ON DELETE CASCADE,
  reversal_id         UUID        REFERENCES employee_termination_reversals(id) ON DELETE CASCADE,

  file_name           TEXT        NOT NULL,
  original_file_name  TEXT        NOT NULL,
  file_path           TEXT        NOT NULL,
  file_size_bytes     INTEGER,
  mime_type           TEXT,

  is_active           BOOLEAN     NOT NULL DEFAULT true,
  uploaded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  uploaded_by         UUID        REFERENCES profiles(id) ON DELETE SET NULL,

  CONSTRAINT chk_att_one_parent
    CHECK (
      (termination_id IS NOT NULL)::int + (reversal_id IS NOT NULL)::int = 1
    )
);

CREATE INDEX IF NOT EXISTS ix_term_att_termination
  ON employee_termination_attachments (termination_id)
  WHERE termination_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_term_att_reversal
  ON employee_termination_attachments (reversal_id)
  WHERE reversal_id IS NOT NULL;


-- =============================================================================
-- 4. Audit triggers (§12)
--    Reuse the existing trg_write_audit_log() function.
-- =============================================================================

DROP TRIGGER IF EXISTS trg_employee_terminations_audit
  ON employee_terminations;
CREATE TRIGGER trg_employee_terminations_audit
  AFTER INSERT OR UPDATE OR DELETE ON employee_terminations
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

DROP TRIGGER IF EXISTS trg_employee_termination_reversals_audit
  ON employee_termination_reversals;
CREATE TRIGGER trg_employee_termination_reversals_audit
  AFTER INSERT OR UPDATE OR DELETE ON employee_termination_reversals
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

DROP TRIGGER IF EXISTS trg_employee_termination_attachments_audit
  ON employee_termination_attachments;
CREATE TRIGGER trg_employee_termination_attachments_audit
  AFTER INSERT OR UPDATE OR DELETE ON employee_termination_attachments
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();


-- =============================================================================
-- 5. RLS — employee_terminations
--    Path A: user_can('termination', action, employee_id)  — scoped to one employee
--    Path B: user_can('termination', action, NULL)          — org-wide (HR/admin)
-- =============================================================================

ALTER TABLE employee_terminations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS term_select ON employee_terminations;
CREATE POLICY term_select ON employee_terminations
  FOR SELECT USING (
    user_can('termination', 'view', employee_id)
    OR user_can('termination', 'view', NULL)
  );

DROP POLICY IF EXISTS term_insert ON employee_terminations;
CREATE POLICY term_insert ON employee_terminations
  FOR INSERT WITH CHECK (
    user_can('termination', 'edit', employee_id)
    OR user_can('termination', 'edit', NULL)
  );

DROP POLICY IF EXISTS term_update ON employee_terminations;
CREATE POLICY term_update ON employee_terminations
  FOR UPDATE USING (
    user_can('termination', 'edit', employee_id)
    OR user_can('termination', 'edit', NULL)
  );

-- Hard DELETE not permitted via RLS — use workflow transitions instead.
-- (No DELETE policy = no direct deletes allowed.)


-- =============================================================================
-- 6. RLS — employee_termination_reversals (access inherits via termination FK)
-- =============================================================================

ALTER TABLE employee_termination_reversals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rev_select ON employee_termination_reversals;
CREATE POLICY rev_select ON employee_termination_reversals
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM employee_terminations t
      WHERE  t.id = employee_termination_reversals.termination_id
        AND (
          user_can('termination', 'view', t.employee_id)
          OR user_can('termination', 'view', NULL)
        )
    )
  );

DROP POLICY IF EXISTS rev_insert ON employee_termination_reversals;
CREATE POLICY rev_insert ON employee_termination_reversals
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM employee_terminations t
      WHERE  t.id = employee_termination_reversals.termination_id
        AND (
          user_can('termination', 'edit', t.employee_id)
          OR user_can('termination', 'edit', NULL)
        )
    )
  );

DROP POLICY IF EXISTS rev_update ON employee_termination_reversals;
CREATE POLICY rev_update ON employee_termination_reversals
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM employee_terminations t
      WHERE  t.id = employee_termination_reversals.termination_id
        AND (
          user_can('termination', 'edit', t.employee_id)
          OR user_can('termination', 'edit', NULL)
        )
    )
  );


-- =============================================================================
-- 7. RLS — employee_termination_attachments (inherits from parent table)
-- =============================================================================

ALTER TABLE employee_termination_attachments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS term_att_select ON employee_termination_attachments;
CREATE POLICY term_att_select ON employee_termination_attachments
  FOR SELECT USING (
    -- Via termination
    (termination_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM employee_terminations t
      WHERE  t.id = employee_termination_attachments.termination_id
        AND (user_can('termination', 'view', t.employee_id)
             OR user_can('termination', 'view', NULL))
    ))
    OR
    -- Via reversal
    (reversal_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM employee_termination_reversals r
      JOIN   employee_terminations t ON t.id = r.termination_id
      WHERE  r.id = employee_termination_attachments.reversal_id
        AND (user_can('termination', 'view', t.employee_id)
             OR user_can('termination', 'view', NULL))
    ))
  );

DROP POLICY IF EXISTS term_att_insert ON employee_termination_attachments;
CREATE POLICY term_att_insert ON employee_termination_attachments
  FOR INSERT WITH CHECK (
    (termination_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM employee_terminations t
      WHERE  t.id = employee_termination_attachments.termination_id
        AND (user_can('termination', 'edit', t.employee_id)
             OR user_can('termination', 'edit', NULL))
    ))
    OR
    (reversal_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM employee_termination_reversals r
      JOIN   employee_terminations t ON t.id = r.termination_id
      WHERE  r.id = employee_termination_attachments.reversal_id
        AND (user_can('termination', 'edit', t.employee_id)
             OR user_can('termination', 'edit', NULL))
    ))
  );

DROP POLICY IF EXISTS term_att_update ON employee_termination_attachments;
CREATE POLICY term_att_update ON employee_termination_attachments
  FOR UPDATE USING (
    (termination_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM employee_terminations t
      WHERE  t.id = employee_termination_attachments.termination_id
        AND (user_can('termination', 'edit', t.employee_id)
             OR user_can('termination', 'edit', NULL))
    ))
    OR
    (reversal_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM employee_termination_reversals r
      JOIN   employee_terminations t ON t.id = r.termination_id
      WHERE  r.id = employee_termination_attachments.reversal_id
        AND (user_can('termination', 'edit', t.employee_id)
             OR user_can('termination', 'edit', NULL))
    ))
  );


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT relname AS table_name
FROM   pg_class c
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  n.nspname = 'public'
  AND  c.relname IN (
    'employee_terminations',
    'employee_termination_reversals',
    'employee_termination_attachments'
  )
ORDER BY relname;

SELECT indexname
FROM   pg_indexes
WHERE  schemaname = 'public'
  AND  tablename IN (
    'employee_terminations',
    'employee_termination_reversals',
    'employee_termination_attachments'
  )
ORDER BY tablename, indexname;

-- =============================================================================
-- END OF MIGRATION 482
-- =============================================================================
