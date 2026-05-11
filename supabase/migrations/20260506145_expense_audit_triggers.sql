-- =============================================================================
-- Migration 145: Audit triggers — expense_reports, line_items, attachments
--
-- DESIGN
-- ══════
-- Three SECURITY DEFINER trigger functions write to audit_log on every
-- meaningful change to the expense domain.
--
-- expense_reports — status transitions get their own named action verbs so
--   the audit trail reads naturally (submitted / approved / rejected / deleted)
--   rather than a generic "updated".  All other field edits log as
--   'expense_report.updated'.  Soft delete (deleted_at going non-NULL) logs
--   as 'expense_report.deleted'.
--
-- line_items — INSERT / UPDATE / soft-delete each get a distinct verb.
--   metadata includes the report_id so a full report trail can be reconstructed
--   by querying on entity_type='line_items' + metadata->>'report_id'.
--
-- attachments — INSERT (upload) and DELETE (removal) only; attachments are
--   immutable once uploaded so UPDATE is not wired.  metadata includes
--   module_code + record_id (report-level) and line_item_id (line-level)
--   to support both attachment styles.
--
-- entity_id mapping
-- ─────────────────
--   expense_reports  → id (uuid PK)
--   line_items       → id (uuid PK)
--   attachments      → id (uuid PK)
--
-- audit_log columns used
-- ───────────────────────
--   action       text  — namespaced verb  e.g. 'expense_report.submitted'
--   entity_type  text  — table name
--   entity_id    uuid  — PK of the changed row
--   user_id      uuid  — auth.uid() at time of change
--   metadata     jsonb — full NEW (or OLD on delete) row snapshot
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. expense_reports — status-aware audit trigger
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_audit_expense_reports()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action text;
  v_row    jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'expense_report.created';
    v_row    := to_jsonb(NEW);

  ELSIF TG_OP = 'DELETE' THEN
    v_action := 'expense_report.hard_deleted';
    v_row    := to_jsonb(OLD);

  ELSE
    -- UPDATE — derive action from what changed
    v_row := to_jsonb(NEW);

    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
      -- Soft delete (only allowed on draft — enforced by CHECK constraint)
      v_action := 'expense_report.deleted';

    ELSIF OLD.status <> NEW.status THEN
      -- Status transition — name it explicitly
      v_action := CASE NEW.status
        WHEN 'submitted' THEN 'expense_report.submitted'
        WHEN 'approved'  THEN 'expense_report.approved'
        WHEN 'rejected'  THEN 'expense_report.rejected'
        ELSE 'expense_report.status_changed'
      END;

    ELSE
      -- Generic field edit (name, base_currency_id, etc.)
      v_action := 'expense_report.updated';
    END IF;
  END IF;

  INSERT INTO audit_log (user_id, action, entity_type, entity_id, metadata)
  VALUES (
    auth.uid(),
    v_action,
    'expense_reports',
    (v_row->>'id')::uuid,
    v_row
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION trg_audit_expense_reports() IS
  'Status-aware audit trigger for expense_reports. '
  'Status transitions log distinct verbs (submitted/approved/rejected). '
  'Soft-delete logs as expense_report.deleted. '
  'Other edits log as expense_report.updated.';

DROP TRIGGER IF EXISTS audit_expense_reports ON expense_reports;
CREATE TRIGGER audit_expense_reports
  AFTER INSERT OR UPDATE OR DELETE ON expense_reports
  FOR EACH ROW EXECUTE FUNCTION trg_audit_expense_reports();


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. line_items — audit trigger
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_audit_line_items()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action text;
  v_row    jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'line_item.created';
    v_row    := to_jsonb(NEW);

  ELSIF TG_OP = 'DELETE' THEN
    v_action := 'line_item.hard_deleted';
    v_row    := to_jsonb(OLD);

  ELSE
    -- UPDATE
    v_row := to_jsonb(NEW);

    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
      v_action := 'line_item.deleted';
    ELSE
      v_action := 'line_item.updated';
    END IF;
  END IF;

  INSERT INTO audit_log (user_id, action, entity_type, entity_id, metadata)
  VALUES (
    auth.uid(),
    v_action,
    'line_items',
    (v_row->>'id')::uuid,
    v_row   -- includes report_id — query by metadata->>'report_id' to get full report trail
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION trg_audit_line_items() IS
  'Audit trigger for line_items. '
  'metadata includes report_id so a full report trail can be reconstructed '
  'by filtering on entity_type=''line_items'' AND metadata->>''report_id'' = <id>.';

DROP TRIGGER IF EXISTS audit_line_items ON line_items;
CREATE TRIGGER audit_line_items
  AFTER INSERT OR UPDATE OR DELETE ON line_items
  FOR EACH ROW EXECUTE FUNCTION trg_audit_line_items();


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. attachments — upload / delete audit trigger
-- ─────────────────────────────────────────────────────────────────────────────
-- Attachments are immutable once uploaded — no UPDATE trigger needed.
-- metadata captures both attachment styles:
--   report-level: record_id + module_code set, line_item_id = NULL
--   line-level:   line_item_id set, record_id = NULL

CREATE OR REPLACE FUNCTION trg_audit_attachments()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action text;
  v_row    jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'attachment.uploaded';
    v_row    := to_jsonb(NEW);
  ELSE
    v_action := 'attachment.deleted';
    v_row    := to_jsonb(OLD);
  END IF;

  INSERT INTO audit_log (user_id, action, entity_type, entity_id, metadata)
  VALUES (
    auth.uid(),
    v_action,
    'attachments',
    (v_row->>'id')::uuid,
    v_row
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION trg_audit_attachments() IS
  'Audit trigger for attachments — INSERT (upload) and DELETE only. '
  'Attachments are immutable once uploaded so UPDATE is not wired. '
  'metadata includes line_item_id (line-level) and record_id+module_code (report-level).';

DROP TRIGGER IF EXISTS audit_attachments ON attachments;
CREATE TRIGGER audit_attachments
  AFTER INSERT OR DELETE ON attachments
  FOR EACH ROW EXECUTE FUNCTION trg_audit_attachments();


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  trigger_name,
  event_object_table                                                        AS "table",
  action_timing                                                             AS timing,
  string_agg(event_manipulation, ' OR ' ORDER BY event_manipulation)       AS events
FROM information_schema.triggers
WHERE trigger_name IN (
  'audit_expense_reports',
  'audit_line_items',
  'audit_attachments'
)
GROUP BY trigger_name, event_object_table, action_timing
ORDER BY event_object_table;

-- =============================================================================
-- END OF MIGRATION 145
--
-- Action verbs written to audit_log.action:
--   expense_report.created
--   expense_report.submitted
--   expense_report.approved
--   expense_report.rejected
--   expense_report.status_changed   (fallback for any other status value)
--   expense_report.updated          (non-status field edits)
--   expense_report.deleted          (soft delete — deleted_at set)
--   expense_report.hard_deleted     (direct DELETE, should never happen in app)
--
--   line_item.created
--   line_item.updated
--   line_item.deleted               (soft delete)
--   line_item.hard_deleted          (direct DELETE — cascade from report)
--
--   attachment.uploaded
--   attachment.deleted
-- =============================================================================
