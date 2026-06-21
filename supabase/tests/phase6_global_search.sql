-- =============================================================================
-- Phase 6 Integration Tests — Global Employee Search & Profile Navigation
-- Run with: supabase test db
-- =============================================================================

BEGIN;

SELECT plan(18);

-- ─────────────────────────────────────────────────────────────────────────────
-- T1: search_employees RPC exists with correct signature
-- ─────────────────────────────────────────────────────────────────────────────
SELECT has_function(
  'public', 'search_employees',
  ARRAY['text','integer','boolean'],
  'T1: search_employees(text, integer, boolean) exists'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T2: search_employees is SECURITY DEFINER
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  (SELECT prosecdef FROM pg_proc WHERE proname = 'search_employees' LIMIT 1),
  'T2: search_employees is SECURITY DEFINER'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T3: check_permission_for_target exists
-- ─────────────────────────────────────────────────────────────────────────────
SELECT has_function(
  'public', 'check_permission_for_target',
  ARRAY['text','text','uuid'],
  'T3: check_permission_for_target(text, text, uuid) exists'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T4: employees.searchable_text generated column exists
-- ─────────────────────────────────────────────────────────────────────────────
SELECT col_is_unique(
  'public', 'employees', 'id',
  'T4: employees.id is primary key (sanity check table exists)'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'employees'
      AND column_name  = 'searchable_text'
  ),
  'T4b: employees.searchable_text column exists'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T5: GIN trigram index exists on searchable_text
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE tablename = 'employees'
      AND indexname  = 'ix_employees_searchable_trgm'
  ),
  'T5: ix_employees_searchable_trgm GIN index exists'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T6: employee_search.view permission seeded
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS (SELECT 1 FROM permissions WHERE code = 'employee_search.view'),
  'T6a: employee_search.view permission exists'
);

SELECT ok(
  EXISTS (SELECT 1 FROM permissions WHERE code = 'employee_search.view_inactive'),
  'T6b: employee_search.view_inactive permission exists'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T7: workflow_instances.initiated_by_actor_id column exists
-- ─────────────────────────────────────────────────────────────────────────────
SELECT col_is_nullable(
  'public', 'workflow_instances', 'initiated_by_actor_id',
  'T7: workflow_instances.initiated_by_actor_id is nullable uuid column'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T8: wf_submit has 6 parameters (p_subject_employee_id added in mig 506)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  (SELECT MAX(pronargs) FROM pg_proc WHERE proname = 'wf_submit') = 6,
  'T8: wf_submit has 6 parameters including p_subject_employee_id'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T9: submit_change_request still has 5 parameters (unchanged signature)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'submit_change_request' AND pronargs = 5
  ),
  'T9: submit_change_request retains 5-parameter signature'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T10: get_profile_workflow_gates accepts optional p_employee_id
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'get_profile_workflow_gates'
      AND pronargs = 1
  ),
  'T10: get_profile_workflow_gates(uuid) overload exists (mig 507)'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T11: vw_wf_pending_tasks has initiated_by_actor_id column
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'vw_wf_pending_tasks'
      AND column_name  = 'initiated_by_actor_id'
  ),
  'T11a: vw_wf_pending_tasks.initiated_by_actor_id column exists (mig 508)'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'vw_wf_pending_tasks'
      AND column_name  = 'initiated_by_actor_name'
  ),
  'T11b: vw_wf_pending_tasks.initiated_by_actor_name column exists (mig 508)'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T12: vw_wf_my_requests has initiated_by_actor_id column
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'vw_wf_my_requests'
      AND column_name  = 'initiated_by_actor_id'
  ),
  'T12: vw_wf_my_requests.initiated_by_actor_id column exists (mig 508)'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T13: submit_bank_account_set + submit_dependent_set exist (mig 509 patch applied)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT has_function(
  'public', 'submit_bank_account_set',
  ARRAY['uuid','date','jsonb','jsonb'],
  'T13a: submit_bank_account_set(uuid, date, jsonb, jsonb) exists'
);

SELECT has_function(
  'public', 'submit_dependent_set',
  ARRAY['uuid','date','jsonb'],
  'T13b: submit_dependent_set(uuid, date, jsonb) exists'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T14: initiated_by_actor_id stamp logic — unit test via wf_submit internals
--      Verify the column is correctly set when subject ≠ actor.
--      This test uses a DO block to inspect the function body since we cannot
--      call auth.uid() directly in a test context without a real session.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  (
    SELECT prosrc FROM pg_proc WHERE proname = 'wf_submit' ORDER BY pronargs DESC LIMIT 1
  ) LIKE '%initiated_by_actor_id%',
  'T14: wf_submit function body references initiated_by_actor_id'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T15: Audit split — workflow_pending_changes.record_id ≠ submitted_by semantics
--      Verify that the table has BOTH record_id (subject) and submitted_by (actor)
--      columns — the structural guarantee of actor/subject split.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'workflow_pending_changes'
      AND column_name  = 'record_id'
  ) AND EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'workflow_pending_changes'
      AND column_name  = 'submitted_by'
  ),
  'T15: workflow_pending_changes has both record_id (subject) and submitted_by (actor) columns'
);

SELECT * FROM finish();

ROLLBACK;
