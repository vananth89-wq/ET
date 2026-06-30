-- Migration 568 — Enforce employees.created_by is always set on INSERT
-- ─────────────────────────────────────────────────────────────────────
-- The mig 253 trigger used COALESCE(NEW.created_by, auth.uid()) silently.
-- If auth.uid() was NULL (service role, migration context) and no explicit
-- created_by was supplied, the row was inserted with created_by = NULL.
-- Fix: raise an exception so the caller is forced to either be authenticated
-- or explicitly supply a created_by value.

CREATE OR REPLACE FUNCTION fn_employees_stamp_created_by()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.created_by := COALESCE(NEW.created_by, auth.uid());

  IF NEW.created_by IS NULL THEN
    RAISE EXCEPTION
      'employees.created_by cannot be NULL. '
      'Either insert as an authenticated user (auth.uid() must be set) '
      'or supply created_by explicitly.'
      USING ERRCODE = 'not_null_violation';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_employees_stamp_created_by() IS
  'BEFORE INSERT trigger: stamps employees.created_by = auth.uid() when not '
  'explicitly provided. Raises not_null_violation if both are NULL so no row '
  'is ever inserted without a creator. Mig 253: initial. Mig 568: enforce NULL guard.';
