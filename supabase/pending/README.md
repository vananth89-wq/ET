# supabase/pending — empty, and here is why

Nothing is staged here. This file is kept for the record, because what was parked
here for four months turned out to be the single largest thing wrong with the
migration history, and the reason it stayed parked is worth remembering.

## What was here

`20260419003_rbac_core_tables.sql.staged` — creating `modules`, `permissions`,
`roles`, `user_roles` and `role_permissions`. Five tables at the centre of the
permission engine, created by **no migration in this repository**. They existed in
Dev and UAT only because someone made them by hand long ago and every environment
since has been built by copying another one.

It was written, tested and deliberately not applied on 2026-08-09. The evidence was
solid — identical structure in Dev and UAT, zero change when applied to a
reconstruction of Dev, replay 157 → 37 — but two things were unknown, and one of them
was load-bearing:

> how the Supabase CLI handles an **out-of-order version** against a real ledger
> (reasoned about, not proven)

## The unknown, resolved

Measured the same day with the pinned CLI (2.113.0) against a real ledger:

| Scenario | Result |
|---|---|
| **Add a new file with an early version** | `db push --include-all` applies only that file, records it in sorted position, re-runs nothing. Plain `db push` refuses and names the flag. **Safe.** |
| **Rename a file the ledger already contains** | `db push` hard-fails with `LegacyDbPushMissingLocalError` **before applying anything**, and stays failed until `supabase migration repair --status reverted <version>` is run against every environment. **Never do this.** |

`db-push.yml` already passes `--include-all`. The first row is exactly this
migration's shape, so it was activated: moved to `supabase/migrations/`, no longer
staged.

The second row is why `20260803001_time_work_schedules_repair.sql` was **not**
renamed even though its position is the direct cause of fourteen replay failures.
A new file, `20260802696_time_work_schedule_tables.sql`, creates the tables early
instead, and 20260803001 stays exactly where it is doing exactly what it did.

## The lesson worth keeping

Staging it was the right call at the time and the wrong call for four months. The
mistake was not the caution — it was leaving the unknown *unmeasured*. The
experiment that resolved it took under an hour: a throwaway Postgres, five dummy
migrations, and two `db push` runs.

**If something is parked because of an unknown, the next step is to measure the
unknown, not to re-read the reasoning.**

## Where things stand

Replay went from **152 failures to 8** on 2026-08-09. The eight that remain are
itemised, each with a diagnosis, in `docs/migration-replay-backlog.md`. The replay
workflow now ratchets against a `BASELINE` rather than reporting into the void: a run
above the baseline fails the build, a run below it tells you to lower the number.

## If you need to stage something again

Put the file here with a `.staged` suffix — the deploy workflow watches
`supabase/migrations/**` only, so nothing here can execute. Write down what is
unknown about it, and what experiment would settle that. Then run the experiment.
