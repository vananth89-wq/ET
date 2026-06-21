-- =============================================================================
-- Migration 510 — Drop old 5-param wf_submit overload
--
-- Mig 506 added p_subject_employee_id (6th param, DEFAULT NULL) to wf_submit,
-- creating a second overload. Postgres error 42725 "function is not unique"
-- fires whenever wf_submit is called with 4 named args because both signatures
-- are candidates.
--
-- Fix: drop the old 5-param signature. The 6-param version is a strict superset
-- (the new param defaults to NULL so all existing callers work unchanged).
-- =============================================================================

DROP FUNCTION IF EXISTS wf_submit(
  p_template_code text,
  p_module_code   text,
  p_record_id     uuid,
  p_metadata      jsonb,
  p_comment       text
);

DO $$
BEGIN
  RAISE NOTICE 'Migration 510: old 5-param wf_submit overload dropped. Only 6-param signature (mig 506) remains.';
END;
$$;
