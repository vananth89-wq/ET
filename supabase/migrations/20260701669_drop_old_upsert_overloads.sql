-- Drop old 3-arg overloads that conflict with the current 4-arg versions.
-- PostgreSQL can't resolve (uuid, jsonb, date) when both a 3-arg and a
-- 4-arg-with-default overload exist — this removes the ambiguity.

DROP FUNCTION IF EXISTS public.upsert_personal_info(uuid, jsonb, date);
DROP FUNCTION IF EXISTS public.upsert_employment_info(uuid, jsonb, date);
