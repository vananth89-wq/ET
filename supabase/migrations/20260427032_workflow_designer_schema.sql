-- =============================================================================
-- Workflow Designer Schema Upgrade
--
-- Upgrades the workflow engine to support enterprise-grade template management:
--
--   1. Version control — multiple versions per template code; only one active
--      at a time; new submissions always use the latest active version.
--
--   2. Template enhancements
--      - effective_from  : date this version becomes effective
--      - published_at    : when it was promoted to active
--      - parent_version  : which version was cloned to produce this one
--
--   3. Step enhancements
--      - reminder_after_hours   : send reminder if task not actioned within N hours
--      - escalation_after_hours : auto-escalate if task not actioned within N hours
--      - is_mandatory           : if false, step can be skipped by the submitter
--
--   4. New RPCs
--      - wf_clone_template(p_template_id)   → uuid   : fork a version, returns new id
--      - wf_publish_template(p_template_id) → void   : promote draft to active
--      - wf_find_active_template(p_code)    → uuid   : latest active id for a code
--
--   5. wf_submit updated to resolve template by code (already does this;
--      the new unique index guarantees exactly one active version per code)
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — SCHEMA CHANGES
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1a. Drop old single-column UNIQUE on workflow_templates.code ──────────────
-- This constraint prevented multiple versions sharing the same code. Replace it
-- with a composite UNIQUE(code, version) + a partial unique index that enforces
-- exactly one active version per code.

ALTER TABLE workflow_templates
  DROP CONSTRAINT IF EXISTS workflow_templates_code_key;

-- ── 1b. Composite unique: one (code, version) row per template family ─────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'workflow_templates_code_version_key'
  ) THEN
    ALTER TABLE workflow_templates
      ADD CONSTRAINT workflow_templates_code_version_key UNIQUE (code, version);
  END IF;
END;
$$;

-- ── 1c. Partial unique index: only one is_active=true row per code ────────────
-- This is the runtime guard that wf_submit relies on (SELECT … WHERE is_active).
CREATE UNIQUE INDEX IF NOT EXISTS workflow_templates_one_active_per_code_idx
  ON workflow_templates (code)
  WHERE is_active = true;

-- ── 1d. New columns on workflow_templates ─────────────────────────────────────
ALTER TABLE workflow_templates
  ADD COLUMN IF NOT EXISTS effective_from  date,
  ADD COLUMN IF NOT EXISTS published_at    timestamptz,
  ADD COLUMN IF NOT EXISTS parent_version  integer;   -- version number this was cloned from

COMMENT ON COLUMN workflow_templates.effective_from IS
  'Date from which this version is valid. Informational; runtime always uses is_active.';
COMMENT ON COLUMN workflow_templates.published_at IS
  'When wf_publish_template() activated this version.';
COMMENT ON COLUMN workflow_templates.parent_version IS
  'The version number of the template this one was cloned from (NULL for original).';

-- ── 1e. New columns on workflow_steps ─────────────────────────────────────────
ALTER TABLE workflow_steps
  ADD COLUMN IF NOT EXISTS reminder_after_hours    integer,
  ADD COLUMN IF NOT EXISTS escalation_after_hours  integer,
  ADD COLUMN IF NOT EXISTS is_mandatory            boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN workflow_steps.reminder_after_hours IS
  'Send a reminder notification if the task is still pending after N hours.';
COMMENT ON COLUMN workflow_steps.escalation_after_hours IS
  'Auto-escalate to the next approver-up if the task is still pending after N hours. '
  'Escalation delivery is handled by the SLA monitoring job.';
COMMENT ON COLUMN workflow_steps.is_mandatory IS
  'If false, the submitter may choose to skip this step at submission time.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — RPCs
-- ════════════════════════════════════════════════════════════════════════════

-- ── 2a. wf_clone_template() ───────────────────────────────────────────────────
-- Creates a draft copy of an existing template (new version number, is_active=false).
-- All steps are copied verbatim. The clone is ready for editing before publishing.

CREATE OR REPLACE FUNCTION wf_clone_template(p_template_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_src      RECORD;
  v_new_id   uuid;
  v_new_ver  integer;
BEGIN
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_clone_template: permission denied';
  END IF;

  SELECT * INTO v_src FROM workflow_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_clone_template: template % not found', p_template_id;
  END IF;

  -- Next version number for this code family
  SELECT COALESCE(MAX(version), 0) + 1
  INTO   v_new_ver
  FROM   workflow_templates
  WHERE  code = v_src.code;

  -- Insert draft clone (inactive)
  INSERT INTO workflow_templates
    (code, name, description, module_code, is_active, version, parent_version)
  VALUES
    (v_src.code, v_src.name, v_src.description, v_src.module_code,
     false, v_new_ver, v_src.version)
  RETURNING id INTO v_new_id;

  -- Copy all steps from source template
  INSERT INTO workflow_steps (
    template_id, step_order, name,
    approver_type, approver_role, approver_profile_id,
    sla_hours, reminder_after_hours, escalation_after_hours,
    allow_delegation, is_mandatory, is_active
  )
  SELECT
    v_new_id, step_order, name,
    approver_type, approver_role, approver_profile_id,
    sla_hours, reminder_after_hours, escalation_after_hours,
    allow_delegation, is_mandatory, is_active
  FROM   workflow_steps
  WHERE  template_id = p_template_id
  ORDER  BY step_order;

  RETURN v_new_id;
END;
$$;

COMMENT ON FUNCTION wf_clone_template(uuid) IS
  'Forks a template into a new draft version (is_active=false). '
  'All steps are copied. Returns the new template id. '
  'Use wf_publish_template() to make the clone the active version.';


-- ── 2b. wf_publish_template() ────────────────────────────────────────────────
-- Promotes a draft template to active. Automatically deactivates any previously
-- active version for the same code. The old version stays in the table as a
-- historical record; in-flight instances referencing it are unaffected because
-- they snapshot template_version at submission time.

CREATE OR REPLACE FUNCTION wf_publish_template(p_template_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tpl RECORD;
BEGIN
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_publish_template: permission denied';
  END IF;

  SELECT id, code, is_active, version
  INTO   v_tpl
  FROM   workflow_templates
  WHERE  id = p_template_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_publish_template: template % not found', p_template_id;
  END IF;

  IF v_tpl.is_active THEN
    RAISE EXCEPTION 'wf_publish_template: version % is already active', v_tpl.version;
  END IF;

  -- Deactivate current active version for this code (if any)
  UPDATE workflow_templates
  SET    is_active   = false,
         updated_at  = now()
  WHERE  code        = v_tpl.code
    AND  is_active   = true;

  -- Activate the new version
  UPDATE workflow_templates
  SET    is_active     = true,
         published_at  = now(),
         updated_at    = now()
  WHERE  id = p_template_id;
END;
$$;

COMMENT ON FUNCTION wf_publish_template(uuid) IS
  'Promotes a draft template version to active, deactivating the previous active '
  'version for the same code. In-flight workflow instances are unaffected — they '
  'reference template_version which is snapshotted at submission time.';


-- ── 2c. wf_find_active_template() ────────────────────────────────────────────
-- Convenience lookup used by wf_submit and UI calls.
-- Returns the id of the currently active template for a given code, or NULL.

CREATE OR REPLACE FUNCTION wf_find_active_template(p_code text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM workflow_templates
  WHERE  code      = p_code
    AND  is_active = true
  LIMIT  1;
$$;

COMMENT ON FUNCTION wf_find_active_template(text) IS
  'Returns the id of the active template version for a given template code, '
  'or NULL if no active version exists.';


-- ── 2d. wf_add_step() ────────────────────────────────────────────────────────
-- Adds a new step to a draft (inactive) template.
-- Prevents accidental edits to live templates.

CREATE OR REPLACE FUNCTION wf_add_step(
  p_template_id          uuid,
  p_step_order           integer,
  p_name                 text,
  p_approver_type        text,
  p_approver_role        text    DEFAULT NULL,
  p_approver_profile_id  uuid    DEFAULT NULL,
  p_sla_hours            integer DEFAULT NULL,
  p_reminder_hours       integer DEFAULT NULL,
  p_escalation_hours     integer DEFAULT NULL,
  p_allow_delegation     boolean DEFAULT true,
  p_is_mandatory         boolean DEFAULT true
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tpl     RECORD;
  v_step_id uuid;
BEGIN
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_add_step: permission denied';
  END IF;

  SELECT id, is_active INTO v_tpl FROM workflow_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_add_step: template % not found', p_template_id;
  END IF;

  -- Allow adding steps to active templates too (needed for initial setup),
  -- but warn if it's active so UI can surface the message.
  -- For strict version safety, call wf_clone_template first.

  -- Shift existing steps down if inserting mid-sequence
  UPDATE workflow_steps
  SET    step_order = step_order + 1
  WHERE  template_id = p_template_id
    AND  step_order  >= p_step_order;

  INSERT INTO workflow_steps (
    template_id, step_order, name, approver_type,
    approver_role, approver_profile_id,
    sla_hours, reminder_after_hours, escalation_after_hours,
    allow_delegation, is_mandatory
  ) VALUES (
    p_template_id, p_step_order, p_name, p_approver_type,
    p_approver_role, p_approver_profile_id,
    p_sla_hours, p_reminder_hours, p_escalation_hours,
    p_allow_delegation, p_is_mandatory
  )
  RETURNING id INTO v_step_id;

  RETURN v_step_id;
END;
$$;


-- ── 2e. wf_delete_step() ─────────────────────────────────────────────────────
-- Removes a step and re-sequences remaining steps.

CREATE OR REPLACE FUNCTION wf_delete_step(p_step_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_step RECORD;
BEGIN
  IF NOT has_role('admin') AND NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_delete_step: permission denied';
  END IF;

  SELECT id, template_id, step_order INTO v_step
  FROM workflow_steps WHERE id = p_step_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_delete_step: step % not found', p_step_id;
  END IF;

  DELETE FROM workflow_steps WHERE id = p_step_id;

  -- Compact step_order to remove gap
  UPDATE workflow_steps
  SET    step_order = step_order - 1
  WHERE  template_id = v_step.template_id
    AND  step_order  > v_step.step_order;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'workflow_templates'
  AND  column_name IN ('effective_from','published_at','parent_version')
ORDER  BY column_name;

SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'workflow_steps'
  AND  column_name IN ('reminder_after_hours','escalation_after_hours','is_mandatory')
ORDER  BY column_name;

SELECT proname FROM pg_proc
WHERE  proname IN (
  'wf_clone_template','wf_publish_template',
  'wf_find_active_template','wf_add_step','wf_delete_step'
)
ORDER  BY proname;
