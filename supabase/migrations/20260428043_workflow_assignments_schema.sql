-- =============================================================================
-- Workflow Assignment Module — Schema
--
-- Centralised, database-driven workflow assignment system.
-- Replaces all hardcoded template lookups in submission functions.
--
-- Tables
-- ──────
--   workflow_assignments       — which workflow template applies to each module
--   workflow_assignment_audit  — immutable change log (trigger-driven)
--
-- Design decisions
-- ────────────────
--   • module_code matches workflow_templates.module_code (e.g. 'expense_reports')
--   • assignment_type: GLOBAL < ROLE < EMPLOYEE (EMPLOYEE = highest priority)
--   • entity_id: NULL for GLOBAL, roles.id for ROLE, profiles.id for EMPLOYEE
--   • Overlap is blocked via btree_gist EXCLUDE constraint
--   • Audit rows are written by a trigger — never by application code
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — workflow_assignments
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS workflow_assignments (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  module_code      text        NOT NULL,               -- e.g. 'expense_reports'
  wf_template_id   uuid        NOT NULL REFERENCES workflow_templates(id),
  assignment_type  text        NOT NULL
                               CHECK (assignment_type IN ('GLOBAL','ROLE','EMPLOYEE')),
  entity_id        uuid,                               -- NULL=GLOBAL, role/profile UUID otherwise
  priority         integer     NOT NULL DEFAULT 0,     -- lower number = higher priority within type
  effective_from   date        NOT NULL DEFAULT CURRENT_DATE,
  effective_to     date,                               -- NULL = open-ended
  is_active        boolean     NOT NULL DEFAULT true,
  created_by       uuid        REFERENCES profiles(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  -- GLOBAL assignments must have NULL entity_id; ROLE/EMPLOYEE must have one
  CONSTRAINT wa_entity_check
    CHECK (
      (assignment_type = 'GLOBAL'   AND entity_id IS NULL) OR
      (assignment_type != 'GLOBAL'  AND entity_id IS NOT NULL)
    ),
  CONSTRAINT wa_date_check
    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

COMMENT ON TABLE workflow_assignments IS
  'Maps business modules to workflow templates. Supports GLOBAL, ROLE, and '
  'EMPLOYEE (future) assignment types with effective dating and priority ordering. '
  'Resolution order: EMPLOYEE > ROLE > GLOBAL.';

COMMENT ON COLUMN workflow_assignments.module_code    IS 'Matches workflow_templates.module_code (e.g. expense_reports).';
COMMENT ON COLUMN workflow_assignments.wf_template_id IS 'The workflow template to use when this assignment matches.';
COMMENT ON COLUMN workflow_assignments.assignment_type IS 'GLOBAL = default fallback; ROLE = role-based override; EMPLOYEE = future per-person override.';
COMMENT ON COLUMN workflow_assignments.entity_id       IS 'NULL for GLOBAL. roles.id for ROLE. profiles.id for EMPLOYEE.';
COMMENT ON COLUMN workflow_assignments.priority        IS 'Lower value wins within the same assignment_type. Used to break ties when a user has multiple matching ROLE assignments.';


-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS wa_module_type_active_idx
  ON workflow_assignments (module_code, assignment_type, is_active);

CREATE INDEX IF NOT EXISTS wa_entity_idx
  ON workflow_assignments (entity_id) WHERE entity_id IS NOT NULL;


-- ── Overlap prevention ────────────────────────────────────────────────────────
-- No two ACTIVE assignments for the same (module + type + entity) may have
-- overlapping effective date ranges.
-- Uses btree_gist; coalesces NULL entity_id to nil-UUID so the equality
-- operator works correctly inside the EXCLUDE constraint.

CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE workflow_assignments
  ADD COLUMN IF NOT EXISTS entity_id_coalesced uuid
    GENERATED ALWAYS AS (
      COALESCE(entity_id, '00000000-0000-0000-0000-000000000000'::uuid)
    ) STORED;

ALTER TABLE workflow_assignments
  DROP CONSTRAINT IF EXISTS wa_no_overlap;

ALTER TABLE workflow_assignments
  ADD CONSTRAINT wa_no_overlap
  EXCLUDE USING gist (
    module_code          WITH =,
    assignment_type      WITH =,
    entity_id_coalesced  WITH =,
    daterange(effective_from,
              COALESCE(effective_to, '9999-12-31'::date), '[]') WITH &&
  )
  WHERE (is_active = true);


-- ── RLS ───────────────────────────────────────────────────────────────────────

ALTER TABLE workflow_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wa_select ON workflow_assignments;
DROP POLICY IF EXISTS wa_admin  ON workflow_assignments;

-- Anyone authenticated can read assignments (needed to resolve during submission)
CREATE POLICY wa_select ON workflow_assignments FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- Only workflow admins can write
CREATE POLICY wa_admin ON workflow_assignments FOR ALL
  USING  (has_role('admin') OR has_permission('workflow.admin'))
  WITH CHECK (has_role('admin') OR has_permission('workflow.admin'));


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — workflow_assignment_audit
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS workflow_assignment_audit (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id   uuid        REFERENCES workflow_assignments(id),
  module_code     text        NOT NULL,
  assignment_type text        NOT NULL,
  entity_id       uuid,
  action          text        NOT NULL CHECK (action IN ('INSERT','UPDATE','DEACTIVATE')),
  old_template_id uuid        REFERENCES workflow_templates(id),
  new_template_id uuid        REFERENCES workflow_templates(id),
  old_effective_from date,
  new_effective_from date,
  old_effective_to   date,
  new_effective_to   date,
  changed_by      uuid        REFERENCES profiles(id),
  changed_at      timestamptz NOT NULL DEFAULT now(),
  reason          text
);

COMMENT ON TABLE workflow_assignment_audit IS
  'Immutable audit log of all workflow assignment changes. Written by trigger only.';

CREATE INDEX IF NOT EXISTS waa_assignment_idx
  ON workflow_assignment_audit (assignment_id, changed_at DESC);

CREATE INDEX IF NOT EXISTS waa_module_idx
  ON workflow_assignment_audit (module_code, changed_at DESC);

ALTER TABLE workflow_assignment_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS waa_admin ON workflow_assignment_audit;

CREATE POLICY waa_admin ON workflow_assignment_audit FOR ALL
  USING (has_role('admin') OR has_permission('workflow.admin'));


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — Audit trigger
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wa_audit_trigger_fn()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'INSERT';
    INSERT INTO workflow_assignment_audit (
      assignment_id, module_code, assignment_type, entity_id, action,
      old_template_id, new_template_id,
      old_effective_from, new_effective_from,
      old_effective_to,   new_effective_to,
      changed_by
    ) VALUES (
      NEW.id, NEW.module_code, NEW.assignment_type, NEW.entity_id, v_action,
      NULL,     NEW.wf_template_id,
      NULL,     NEW.effective_from,
      NULL,     NEW.effective_to,
      NEW.created_by
    );

  ELSIF TG_OP = 'UPDATE' THEN
    -- Only log meaningful changes
    IF OLD.wf_template_id  IS DISTINCT FROM NEW.wf_template_id  OR
       OLD.effective_from  IS DISTINCT FROM NEW.effective_from  OR
       OLD.effective_to    IS DISTINCT FROM NEW.effective_to    OR
       OLD.is_active       IS DISTINCT FROM NEW.is_active       THEN

      v_action := CASE
        WHEN OLD.is_active = true AND NEW.is_active = false THEN 'DEACTIVATE'
        ELSE 'UPDATE'
      END;

      INSERT INTO workflow_assignment_audit (
        assignment_id, module_code, assignment_type, entity_id, action,
        old_template_id, new_template_id,
        old_effective_from, new_effective_from,
        old_effective_to,   new_effective_to,
        changed_by
      ) VALUES (
        NEW.id, NEW.module_code, NEW.assignment_type, NEW.entity_id, v_action,
        OLD.wf_template_id, NEW.wf_template_id,
        OLD.effective_from, NEW.effective_from,
        OLD.effective_to,   NEW.effective_to,
        NEW.created_by      -- updated_by stored in created_by on UPDATE calls
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS wa_audit_trigger ON workflow_assignments;

CREATE TRIGGER wa_audit_trigger
  AFTER INSERT OR UPDATE ON workflow_assignments
  FOR EACH ROW EXECUTE FUNCTION wa_audit_trigger_fn();

COMMENT ON FUNCTION wa_audit_trigger_fn() IS
  'Writes to workflow_assignment_audit on every meaningful INSERT or UPDATE '
  'to workflow_assignments. Never called directly.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 4 — updated_at auto-stamp
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wa_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS wa_updated_at ON workflow_assignments;
CREATE TRIGGER wa_updated_at
  BEFORE UPDATE ON workflow_assignments
  FOR EACH ROW EXECUTE FUNCTION wa_set_updated_at();


-- ════════════════════════════════════════════════════════════════════════════
-- PART 5 — Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'workflow_assignments'
ORDER  BY ordinal_position;

SELECT table_name FROM information_schema.tables
WHERE  table_name IN ('workflow_assignments','workflow_assignment_audit')
  AND  table_schema = 'public';
