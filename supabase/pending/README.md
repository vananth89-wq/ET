# supabase/pending — reviewed, tested, deliberately not applied

Migrations here are **not executed by anything**. The deploy workflow watches
`supabase/migrations/**` only, and files here carry a `.staged` suffix so even a
mistaken glob skips them. They are parked because they are correct but not yet
worth the deploy risk.

To activate one: rename off the `.staged` suffix and move it into
`supabase/migrations/`. Nothing else.

---

## 20260419003_rbac_core_tables.sql.staged

**Staged 2026-08-09. Do not apply until you are building a fresh environment.**

### The problem it solves

Five tables at the centre of the permission engine are created by **no migration
in this repository**:

    modules · permissions · roles · user_roles · role_permissions

They exist in Dev and UAT only because they were made by hand in SQL long ago
and carried forward when the database was copied. Every environment has been
built by copying another one, so nobody ever noticed.

Consequence: `supabase/migrations/` **cannot build a database from zero**.
Replaying the history into an empty PostgreSQL fails at `20260422002` with
`relation "roles" does not exist`, and roughly 113 further failures cascade from
that one hole. Measured baseline 2026-08-09: **151 of 713 migrations fail** to
replay. See `.github/workflows/migration-replay.yml`.

### Why it is dated April, not August

Migrations run in filename order. The failures happen near the *beginning* of
the history. A file dated today would run last and fix nothing. `20260419003`
places it immediately after `20260419001_initial_schema` (which creates
`profiles`, referenced by `user_roles`) and before the first migration that
needs these tables.

### Evidence gathered before staging

| Check | Result |
|---|---|
| Any migration DROPs or RENAMEs these tables? | Only `role_permissions`, by mig 146. The other four: never. |
| Dev vs UAT structure | **Identical** — every column, constraint, index, RLS setting |
| `role_permissions` present? | **Absent in both** — correctly, mig 146 dropped it |
| Applied to a reconstruction of Dev | **Zero change** — 74 schema facts + row counts identical, twice |
| Effect on replay | **157 → 37 failures** |

### The two hazards, and how each is handled

**1. `ENABLE ROW LEVEL SECURITY` is not purely additive.** Re-enabling RLS on a
table where someone deliberately turned it *off* would start hiding rows from
the application. RLS is therefore only switched on for tables this migration
actually creates; pre-existing tables are left untouched. Verified by disabling
RLS on `roles` and confirming the migration leaves it disabled.

**2. `role_permissions` was deliberately dropped by mig 146.** Recreating it on
an environment past 146 would resurrect a deleted table. It is created only
where `supabase_migrations.schema_migrations` lacks version `20260506146`. On a
fresh replay that ledger does not exist, so the table is created and 146 drops
it later — exactly as history intended.

### Why it is staged rather than applied

There is no benefit today. Permissions work because the application queries the
**database**, not these files; nothing at runtime ever reads a migration. The
benefit arrives only when an environment is built from files instead of copied.

Two things remain untested and are the reason for caution:

- how the Supabase CLI handles an **out-of-order version** against a real ledger
  (reasoned about, not proven — `--include-all` is already passed by db-push)
- **Prod**, which does not exist yet

### When to apply it

The day you build UAT or Prod from migrations rather than from a copy. Apply to
Dev first, run `supabase/checks/verify_time_backend.sql` before and after, and
confirm the replay count drops from 151 to ~37.

### What is still missing after this one

The replay does not reach zero. Behind these five, two more hand-made tables
surface — `pending_invite_reminders` and `buckets` — plus roughly a dozen
ordering issues and a few genuine bugs (`column ur.assigned_by does not exist`,
`column n.email_status does not exist`). Expect two or three more rounds before
`STRICT: 'true'` can be set on the replay workflow.
