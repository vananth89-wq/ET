# Prowess Docs Update Checklist

Run this checklist every time you write a migration.

---

## After every migration

```bash
# 1. Apply migration
npx supabase db push

# 2. Regenerate TypeScript types
npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr > src/types/database.types.ts

# 3. Open the docs and update what changed (see guide below)
open ET-React/prowess_system_docs.html
```

---

## What to update in the docs

| Migration type | Parts to update |
|---|---|
| **New column added** | Part 2 — find the table card, add the field row |
| **New table added** | Part 1 — add a `tbl-card` in the right domain section<br>Part 2 — add a full `table-card` block<br>Part 4 — add entity + relationships to Mermaid ER<br>Part 5 — add RLS row for the new table |
| **RLS policy changed** | Part 5 — update SELECT/INSERT/UPDATE/DELETE cell for that table |
| **New constraint/CHECK** | Part 6 — add a row to the relevant Business Rules table |
| **New migration milestone** | Part 7 — add a row to the Migration Milestone Summary table |
| **Column removed/renamed** | Part 2 — update or remove the field row |
| **New business rule added** | Part 6 — add to the relevant section |

---

## Regenerating Part 2 automatically (future)

Once `scripts/gen-schema-docs.js` is wired to a live Supabase connection:

```bash
node scripts/gen-schema-docs.js
```

This replaces everything between `<!-- AUTO-SCHEMA-START -->` and `<!-- AUTO-SCHEMA-END -->` in the HTML.
The markers need to be added to the HTML first (wrap the Part 2 table cards in them).

### Quickest path to enable auto-regen

Add this migration to expose `information_schema` safely:

```sql
CREATE OR REPLACE FUNCTION get_schema_info()
RETURNS TABLE (
  table_name text, column_name text, data_type text,
  udt_name text, is_nullable text, column_default text, ordinal_position int
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT table_name::text, column_name::text, data_type::text,
         udt_name::text, is_nullable::text, column_default::text,
         ordinal_position::int
  FROM   information_schema.columns
  WHERE  table_schema = 'public'
  ORDER  BY table_name, ordinal_position;
$$;
```

Then uncomment the `supabase.rpc('get_schema_info')` call in `gen-schema-docs.js`.

---

## The 3-layer rule

When changing permissions or auth behaviour, always check all three layers:

| Layer | File | What to check |
|---|---|---|
| DB | `migrations/` | `user_can()`, RLS policies, `is_super_admin()` |
| UI gate | `src/context/PermissionContext.tsx` | `get_my_permissions()` result cached correctly |
| Data scope | `src/hooks/useEmployeeScope.ts` | `get_target_population()` mode |
