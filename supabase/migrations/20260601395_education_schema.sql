-- =============================================================================
-- Migration 395 — Education Module: Schema, Picklists, Permissions, RLS
--
-- Introduces multi-row satellite tables for employee academic and professional
-- qualifications. Non-effective-dated (each row is a discrete fact). Soft-delete
-- via is_active=false. Workflow-gated (profile_education module).
--
-- Changes:
--   1. Create employee_education
--   2. Create employee_education_attachments
--   3. Seed 3 picklists (EDUCATION_LEVEL, COMPLETION_STATUS, EDUCATION_DOCUMENT_TYPE)
--   4. Register education module
--   5. Seed 7 permissions (view, create, edit, delete, history, bulk_import, bulk_export)
--   6. RLS policies on both tables
--
-- Design spec: docs/education-design.md §3, §4
-- Next migration: 20260601396 (RPCs)
-- =============================================================================


-- =============================================================================
-- 1. employee_education — one row per qualification per employee
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_education (
  id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id              UUID        NOT NULL REFERENCES employees(id) ON DELETE CASCADE,

  education_level          TEXT        NOT NULL,   -- ref_id from EDUCATION_LEVEL picklist
  degree                   TEXT        NOT NULL,   -- free-form, e.g. "B.Tech in Computer Science"
  institution              TEXT        NOT NULL,   -- free-form, e.g. "Anna University"
  field_of_study           TEXT,                   -- optional free-form

  start_date               DATE        NOT NULL,
  end_date                 DATE,                   -- NULL when status = Pursuing

  completion_status        TEXT        NOT NULL,   -- ref_id from COMPLETION_STATUS picklist

  grade_or_gpa             TEXT,                   -- optional free-form
  is_highest_qualification BOOLEAN     NOT NULL DEFAULT false,

  is_active                BOOLEAN     NOT NULL DEFAULT true,
  inactive_at              TIMESTAMPTZ,
  inactive_by              UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  created_by               UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  updated_by               UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- end_date must be >= start_date when provided
  CONSTRAINT chk_edu_end_after_start
    CHECK (end_date IS NULL OR end_date >= start_date),

  -- Completed (ES01) requires a non-future end_date
  CONSTRAINT chk_edu_completed_has_past_end
    CHECK (
      completion_status <> 'ES01'
      OR (end_date IS NOT NULL AND end_date <= CURRENT_DATE)
    )
);

CREATE INDEX IF NOT EXISTS idx_edu_employee
  ON employee_education (employee_id);

CREATE INDEX IF NOT EXISTS idx_edu_employee_active
  ON employee_education (employee_id)
  WHERE is_active = true;

-- Exactly one highest qualification per employee (active rows only)
CREATE UNIQUE INDEX IF NOT EXISTS uq_edu_one_highest_per_employee
  ON employee_education (employee_id)
  WHERE is_highest_qualification = true AND is_active = true;

-- Prevent duplicate enrolments (active rows only)
CREATE UNIQUE INDEX IF NOT EXISTS uq_edu_no_dupes
  ON employee_education (employee_id, education_level, institution, start_date)
  WHERE is_active = true;


-- =============================================================================
-- 2. employee_education_attachments — multi-attachment per education record
--    Same pattern as employee_dependent_attachments / identity_record_attachments
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_education_attachments (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  education_id        UUID        NOT NULL REFERENCES employee_education(id) ON DELETE CASCADE,
  employee_id         UUID        NOT NULL REFERENCES employees(id) ON DELETE CASCADE,

  document_type       TEXT        NOT NULL,   -- ref_id from EDUCATION_DOCUMENT_TYPE picklist
  file_name           TEXT        NOT NULL,
  original_file_name  TEXT        NOT NULL,
  file_path           TEXT        NOT NULL,   -- hr-attachments storage path
  mime_type           TEXT        NOT NULL,
  file_size           BIGINT      NOT NULL CHECK (file_size > 0),

  is_active           BOOLEAN     NOT NULL DEFAULT true,
  uploaded_by         UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  uploaded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by          UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_edu_att_education
  ON employee_education_attachments (education_id);

CREATE INDEX IF NOT EXISTS idx_edu_att_employee
  ON employee_education_attachments (employee_id);

CREATE INDEX IF NOT EXISTS idx_edu_att_active
  ON employee_education_attachments (education_id)
  WHERE is_active = true;


-- =============================================================================
-- 3. Picklists
-- =============================================================================

INSERT INTO picklists (picklist_id, name, system, meta_fields)
VALUES
  ('EDUCATION_LEVEL',         'Education Level',         true, '[]'::jsonb),
  ('COMPLETION_STATUS',       'Completion Status',       true, '[]'::jsonb),
  ('EDUCATION_DOCUMENT_TYPE', 'Education Document Type', true, '[]'::jsonb)
ON CONFLICT (picklist_id) DO NOTHING;

-- EDUCATION_LEVEL — 8 codes
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.label, v.ref_id, true
FROM (VALUES
  ('EDU01', 'High School'),
  ('EDU02', 'Diploma'),
  ('EDU03', 'Bachelor Degree'),
  ('EDU04', 'Master Degree'),
  ('EDU05', 'MBA'),
  ('EDU06', 'PhD'),
  ('EDU07', 'Certification'),
  ('EDU08', 'Professional Qualification')
) AS v(ref_id, label)
JOIN picklists pl ON pl.picklist_id = 'EDUCATION_LEVEL'
ON CONFLICT DO NOTHING;

-- COMPLETION_STATUS — 4 codes
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.label, v.ref_id, true
FROM (VALUES
  ('ES01', 'Completed'),
  ('ES02', 'Pursuing'),
  ('ES03', 'Discontinued'),
  ('ES04', 'On Hold')
) AS v(ref_id, label)
JOIN picklists pl ON pl.picklist_id = 'COMPLETION_STATUS'
ON CONFLICT DO NOTHING;

-- EDUCATION_DOCUMENT_TYPE — 5 codes
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.label, v.ref_id, true
FROM (VALUES
  ('ED01', 'Certificate'),
  ('ED02', 'Mark Sheet'),
  ('ED03', 'Transcript'),
  ('ED04', 'Provisional'),
  ('ED05', 'Other')
) AS v(ref_id, label)
JOIN picklists pl ON pl.picklist_id = 'EDUCATION_DOCUMENT_TYPE'
ON CONFLICT DO NOTHING;


-- =============================================================================
-- 4. Register education module
-- =============================================================================

INSERT INTO modules (code, name, active, sort_order)
VALUES (
  'education',
  'Education',
  true,
  (SELECT COALESCE(MAX(sort_order), 0) + 10 FROM modules)
)
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- 5. Seed 7 permissions
--    permissions_action_check already allows bulk_import / bulk_export
--    since mig 359 extended it. No constraint change needed here.
-- =============================================================================

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'education';

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'education module not found — skipping permission seed';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    ('education.view',        v_module_id, 'view',        'Education — View',
     'See an employee''s education records.'),
    ('education.create',      v_module_id, 'create',      'Education — Add',
     'Add a new education record for an employee.'),
    ('education.edit',        v_module_id, 'edit',        'Education — Edit',
     'Edit an existing education record.'),
    ('education.delete',      v_module_id, 'delete',      'Education — Remove',
     'Soft-delete an education record (sets is_active=false).'),
    ('education.history',     v_module_id, 'history',     'Education — History',
     'View removed education records alongside active ones.'),
    ('education.bulk_import', v_module_id, 'bulk_import', 'Education — Bulk Import',
     'Upload CSV to create or update education records in bulk.'),
    ('education.bulk_export', v_module_id, 'bulk_export', 'Education — Bulk Export',
     'Download current education records as CSV.')
  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- 6. RLS — employee_education
--    Path A: user_can('education', action, employee_id)  — scoped to one employee
--    Path B: user_can('education', action, NULL) + hire-pipeline guard
-- =============================================================================

ALTER TABLE employee_education ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS edu_select ON employee_education;
CREATE POLICY edu_select ON employee_education
  FOR SELECT USING (
    user_can('education', 'view', employee_id)
    OR (
      user_can('education', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = employee_education.employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  );

DROP POLICY IF EXISTS edu_insert ON employee_education;
CREATE POLICY edu_insert ON employee_education
  FOR INSERT WITH CHECK (
    user_can('education', 'create', employee_id)
    OR user_can('education', 'create', NULL)
  );

DROP POLICY IF EXISTS edu_update ON employee_education;
CREATE POLICY edu_update ON employee_education
  FOR UPDATE USING (
    user_can('education', 'edit', employee_id)
    OR user_can('education', 'edit', NULL)
  );

DROP POLICY IF EXISTS edu_delete ON employee_education;
CREATE POLICY edu_delete ON employee_education
  FOR DELETE USING (
    user_can('education', 'delete', employee_id)
    OR user_can('education', 'delete', NULL)
  );


-- =============================================================================
-- 7. RLS — employee_education_attachments (inherits via education_id FK)
-- =============================================================================

ALTER TABLE employee_education_attachments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS edu_att_select ON employee_education_attachments;
CREATE POLICY edu_att_select ON employee_education_attachments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM employee_education ee
      WHERE  ee.id = employee_education_attachments.education_id
        AND  (
          user_can('education', 'view', ee.employee_id)
          OR user_can('education', 'view', NULL)
        )
    )
  );

DROP POLICY IF EXISTS edu_att_insert ON employee_education_attachments;
CREATE POLICY edu_att_insert ON employee_education_attachments
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM employee_education ee
      WHERE  ee.id = employee_education_attachments.education_id
        AND  (
          user_can('education', 'create', ee.employee_id)
          OR user_can('education', 'create', NULL)
          OR user_can('education', 'edit',   ee.employee_id)
          OR user_can('education', 'edit',   NULL)
        )
    )
  );

DROP POLICY IF EXISTS edu_att_update ON employee_education_attachments;
CREATE POLICY edu_att_update ON employee_education_attachments
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM employee_education ee
      WHERE  ee.id = employee_education_attachments.education_id
        AND  (
          user_can('education', 'edit', ee.employee_id)
          OR user_can('education', 'edit', NULL)
        )
    )
  );

DROP POLICY IF EXISTS edu_att_delete ON employee_education_attachments;
CREATE POLICY edu_att_delete ON employee_education_attachments
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM employee_education ee
      WHERE  ee.id = employee_education_attachments.education_id
        AND  (
          user_can('education', 'edit', ee.employee_id)
          OR user_can('education', 'edit', NULL)
        )
    )
  );


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT COUNT(*) AS edu_tables
FROM   pg_class c
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  n.nspname = 'public'
  AND  c.relname IN ('employee_education', 'employee_education_attachments');

SELECT pl.picklist_id, COUNT(*) AS value_count
FROM   picklist_values pv
JOIN   picklists pl ON pl.id = pv.picklist_id
WHERE  pl.picklist_id IN ('EDUCATION_LEVEL', 'COMPLETION_STATUS', 'EDUCATION_DOCUMENT_TYPE')
GROUP  BY pl.picklist_id
ORDER  BY pl.picklist_id;

SELECT code FROM permissions
WHERE  code LIKE 'education.%'
ORDER  BY code;

-- =============================================================================
-- END OF MIGRATION 395
-- =============================================================================
