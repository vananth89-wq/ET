-- ═══════════════════════════════════════════════════════════════════════════
-- Emit CREATE TABLE / constraint / index DDL for the five RBAC tables that no
-- migration in the repo creates. READ ONLY — generates text, changes nothing.
--
-- Run on Dev, copy the whole `ddl` column, and paste it back.
-- ═══════════════════════════════════════════════════════════════════════════
WITH t AS (
  SELECT unnest(ARRAY['roles','user_roles','permissions','role_permissions','modules']) AS tbl
),
cols AS (
  SELECT c.table_name AS tbl,
         '  ' || quote_ident(c.column_name) || ' ' ||
         CASE
           WHEN c.data_type = 'USER-DEFINED' THEN c.udt_name
           WHEN c.data_type = 'ARRAY'        THEN replace(c.udt_name, '_', '') || '[]'
           WHEN c.character_maximum_length IS NOT NULL
             THEN c.data_type || '(' || c.character_maximum_length || ')'
           WHEN c.data_type = 'numeric' AND c.numeric_precision IS NOT NULL
             THEN 'numeric(' || c.numeric_precision || ',' || COALESCE(c.numeric_scale,0) || ')'
           ELSE c.data_type
         END ||
         CASE WHEN c.column_default IS NOT NULL
              THEN ' DEFAULT ' || c.column_default ELSE '' END ||
         CASE WHEN c.is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END AS line,
         c.ordinal_position
    FROM information_schema.columns c
    JOIN t ON t.tbl = c.table_name
   WHERE c.table_schema = 'public'
),
table_ddl AS (
  SELECT tbl,
         'CREATE TABLE IF NOT EXISTS public.' || tbl || E' (\n' ||
         string_agg(line, E',\n' ORDER BY ordinal_position) || E'\n);' AS ddl
    FROM cols GROUP BY tbl
),
cons AS (
  SELECT c.relname AS tbl,
         'ALTER TABLE public.' || c.relname ||
         ' ADD CONSTRAINT ' || con.conname || ' ' ||
         pg_get_constraintdef(con.oid) || ';   -- ' ||
         CASE con.contype WHEN 'p' THEN 'primary key' WHEN 'f' THEN 'foreign key'
                          WHEN 'u' THEN 'unique'      WHEN 'c' THEN 'check'
                          ELSE con.contype::text END AS ddl,
         CASE con.contype WHEN 'p' THEN 1 WHEN 'u' THEN 2 WHEN 'c' THEN 3 ELSE 4 END AS ord
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    JOIN t ON t.tbl = c.relname
),
idx AS (
  SELECT tablename AS tbl,
         replace(indexdef, 'CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS ') || ';' AS ddl
    FROM pg_indexes
    JOIN t ON t.tbl = pg_indexes.tablename
   WHERE schemaname = 'public'
     AND indexname NOT IN (SELECT conname FROM pg_constraint)   -- skip PK/unique backers
),
rls AS (
  SELECT c.relname AS tbl,
         'ALTER TABLE public.' || c.relname || ' ENABLE ROW LEVEL SECURITY;' AS ddl
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname='public'
    JOIN t ON t.tbl = c.relname
   WHERE c.relrowsecurity
)
SELECT * FROM (
  SELECT 0 AS grp, tbl, 1 AS ord, ddl FROM table_ddl
  UNION ALL SELECT 1, tbl, 1 + ord, ddl FROM cons
  UNION ALL SELECT 2, tbl, 9,  ddl FROM idx
  UNION ALL SELECT 3, tbl, 10, ddl FROM rls
) x
ORDER BY tbl, grp, ord;
