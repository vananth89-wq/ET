-- =============================================================================
-- Migration 587: Drop ambiguous wf_withdraw(uuid) single-param overload
--
-- Mig 261 (hire_pipeline_critical_fixes) introduced wf_withdraw(p_instance_id uuid)
-- with only ONE parameter. All other migrations define
-- wf_withdraw(p_instance_id uuid, p_reason text DEFAULT NULL) with two params.
--
-- Both signatures match a call of wf_withdraw(some_uuid), making PostgreSQL
-- raise "function wf_withdraw(uuid) is not unique".
--
-- Fix: drop the single-param overload. The two-param version (mig 272) is the
-- canonical one and its DEFAULT NULL means existing callers that pass only one
-- argument continue to work unchanged.
-- =============================================================================

DROP FUNCTION IF EXISTS wf_withdraw(uuid);
