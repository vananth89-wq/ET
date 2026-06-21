-- Migration 455: drop the obsolete 5-param overload of fn_apply_bank_account_set_transition
--
-- Problem: mig 390 added a 5-param version with p_attachments defaulting to '[]'.
--   That default makes the 5-param version callable with 4 args, creating an
--   ambiguous overload alongside the 4-param version re-created by migs 454/456.
--   PostgreSQL raises "is not unique" whenever the function is called.
--
-- Fix: drop the 5-param version — its p_attachments arg was never used
--   (attachments are embedded in p_items[].attachments already).

DROP FUNCTION IF EXISTS fn_apply_bank_account_set_transition(UUID, DATE, JSONB, UUID, JSONB);
