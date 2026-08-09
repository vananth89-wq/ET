# Migration replay — the eight that remain

`.github/workflows/migration-replay.yml` replays every versioned migration into an
empty PostgreSQL 16 on each push. On **2026-08-09** that count went from **152 to 8**.
This file is what is left, why each one fails, and what it would take to fix.

Measured with the same harness CI uses. Reproduce locally in about 40 seconds:
a throwaway database, the prelude from the workflow, then every
`supabase/migrations/[0-9]{11}_*.sql` in filename order.

## How the 152 became 8

| Change | Failures removed |
|---|---|
| `20260419003_rbac_core_tables.sql` — the five RBAC tables no migration created | **123** |
| `20260802696_time_work_schedule_tables.sql` — work schedule tables, early enough | **14** |
| `pg_net` / `pg_cron` shim extensions + a `cron.schedule` that records the job | **5** |
| `20260617564` — `SAVEPOINT` removed from a plpgsql body | **1** |
| `20260807724` — drop the trigger from the table it is actually on | **1** |

Two structural mistakes accounted for 137 of the 152. Both were the same mistake:
a table created by hand on a live database, so no migration ever needed to create
it, so nobody noticed the history could not build one from scratch.

## The rule that governs any fix here

**Never rename a migration that has already been applied.** Measured against a real
ledger with the pinned CLI (2.113.0) on 2026-08-09:

- **Adding a new file with an early version** — `db push --include-all` applies only
  that file, records it in sorted position, re-runs nothing. Plain `db push` refuses
  and tells you to add the flag; `db-push.yml` already passes it. **Safe.**
- **Renaming a file the ledger already contains** — `db push` hard-fails with
  `LegacyDbPushMissingLocalError` *before applying anything*, and stays failed until
  someone runs `supabase migration repair --status reverted <version>` against every
  environment. Dev, UAT and Prod would each need manual intervention and no deploy
  could land in between. **Never do this.**

That is why `20260803001_time_work_schedules_repair.sql` was left exactly where it
is and a new early file added alongside it.

---

## The eight

### 1. `20260422002_sync_user_roles_to_profile_roles.sql`
> `column ur.assigned_by does not exist`

`user_roles` has no `assigned_by` column — not in the DDL extracted from Dev, not
anywhere in the history. Either the column existed when this migration was written
and was later dropped by hand, or it never existed and this migration has never
worked. **Check Dev before changing anything**: if `assigned_by` is genuinely absent
there, this migration is dead code and the honest fix is to make it a no-op with a
comment saying why.

### 2. `20260502102_fix_get_my_permissions_include_sets.sql`
> `UNION types text[] and text cannot be matched`

A real SQL bug in a `UNION` inside `get_my_permissions`. One branch selects an array,
the other a scalar. Needs someone who knows which shape the caller expects — the
function is central to permissions, so this is worth reading carefully rather than
casting one side to match the other.

### 3. `20260503112_super_admins.sql`
> `violates foreign key constraint "super_admins_profile_id_fkey"`

Seeds a specific person's profile id that does not exist in an empty database. A data
migration in schema clothing. Fix: guard the insert with
`WHERE EXISTS (SELECT 1 FROM profiles WHERE id = ...)`, so it seeds where it can and
stays quiet where it cannot.

### 4. `20260520269_rejected_hire_inbox_flow.sql`
> `operator does not exist: uuid = text`

A comparison missing a cast. Small and self-contained; needs a look at which side is
wrong rather than a blind `::uuid`.

### 5–6. `20260526279_fix_bank_permission_codes.sql`, `20260526280_bank_permission_codes_upsert.sql`
> `relation "role_permissions" does not exist`

`role_permissions` is dropped by `20260506146`. These two, dated three weeks later,
still write to it. On a real environment they were applied before the drop landed, or
they silently did nothing. Fix: wrap both in
`IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='role_permissions')`,
or retire them if the permission codes they set are now handled elsewhere.

### 7. `20260603456_validate_effective_date_not_before_hire.sql`
> `cannot change name of input parameter "p_items"`

`CREATE OR REPLACE FUNCTION` cannot rename a parameter. Fix is mechanical: a
`DROP FUNCTION IF EXISTS <name>(<exact arg types>)` immediately before the create.
Name the argument types explicitly so an overload is not dropped by accident.

### 8. `20260803711_bulk_assign_work_schedule_holiday_calendar.sql`
> `Work schedule with code 'GEN' not found. Create it first in Admin → Work Schedules.`

Deliberately raises when its seed data is absent — reasonable as an admin action,
wrong as a migration. It will fail every clean replay forever. Fix: skip with a
`RAISE NOTICE` when `GEN` does not exist, and keep the exception only for the
interactive path.

---

## Two findings worth acting on outside the replay

### `20260617564` could never have applied — but nothing is broken by it

**Resolved 2026-08-09. No action needed. Recorded because the reasoning matters.**

`20260617564` set out to fix a termination bug where reassigning a direct report
produced `effective_to < effective_from`. Its function body used
`SAVEPOINT` / `ROLLBACK TO SAVEPOINT` / `RELEASE SAVEPOINT`, which **are not valid
inside a plpgsql function** — plpgsql gives you the same thing implicitly through
`BEGIN ... EXCEPTION`. The statements were redundant *and* fatal: with
`check_function_bodies = on` the create fails outright; with it off the function is
created happily and then raises `syntax error at or near "TO"` the first time the
direct-report branch runs.

That sounded alarming, and the first read of it was that live environments were
carrying a function which throws whenever a manager with direct reports is
terminated. **They are not.** Two pieces of evidence:

1. `20260623573_rewrite_fn_finalize_termination_execution.sql` replaced the whole
   function six days later, and three further fixes followed (574, 596, 610).
   **All four carry the `effective_from > v_lwd` branch** — the very fix 564 was
   written to introduce. Whoever wrote the rewrite reproduced it independently, so
   nothing was lost when 564 failed.
2. Dev confirms it:

   ```sql
   SELECT prosrc LIKE '%ROLLBACK TO SAVEPOINT%' AS still_broken
   FROM   pg_proc WHERE proname = 'fn_finalize_termination_execution';
   -- false
   ```

The file is now fixed so it replays, which costs nothing and keeps the history
buildable from zero. No forward migration is needed.

**The lesson is about the failure mode, not this function.** A migration failed
silently, and the only reason it did not matter is that someone happened to rewrite
the same function a week later. Nothing detected the failure at the time — that is
what the replay job now exists to catch, and why its `BASELINE` ratchets downward
instead of reporting into a void.

### `20260807722`'s verification message contradicts itself

722 attaches `trg_time_holidays_recalc` to `time_calendar_entries` (line 277) but its
own abort message reads *"not found on time_holidays"*. Harmless — but that stale
sentence is exactly what led 724 to drop the trigger from the wrong table, which is
failure 5 of the old list. Worth correcting the next time 722 is touched.
