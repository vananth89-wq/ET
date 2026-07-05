-- Migration 664 — Drop old 2-param overloads of upsert_education / remove_education
-- Mig 662 added a 3rd param (p_force_path_a boolean DEFAULT false).
-- PostgREST cannot resolve ambiguity when both signatures exist.

DROP FUNCTION IF EXISTS public.remove_education(uuid, uuid);
DROP FUNCTION IF EXISTS public.upsert_education(uuid, jsonb, uuid);
