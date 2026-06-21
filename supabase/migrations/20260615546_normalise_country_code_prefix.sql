-- =============================================================================
-- Migration 546 — Normalise country_code values to always include leading '+'
--
-- Root cause: older imports / direct DB inserts stored dial codes without the
-- leading '+' (e.g. '91' instead of '+91'). The MyProfile form selects from
-- PHONE_CODES which always uses '+'-prefixed codes, so the form itself is
-- correct. Only pre-existing rows are affected.
--
-- Fix: prefix any country_code value that doesn't start with '+'.
-- Safe to re-run: WHERE clause limits to affected rows only.
-- =============================================================================

UPDATE employee_contact
SET    country_code = '+' || country_code,
       updated_at   = now()
WHERE  country_code IS NOT NULL
  AND  country_code <> ''
  AND  country_code NOT LIKE '+%';

DO $$
DECLARE v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM   employee_contact
  WHERE  country_code IS NOT NULL
    AND  country_code <> ''
    AND  country_code NOT LIKE '+%';

  ASSERT v_count = 0, 'country_code normalisation incomplete — rows without + prefix still exist';
  RAISE NOTICE 'Mig 546: all country_code values now have + prefix.';
END;
$$;
