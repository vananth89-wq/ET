# fn_apply_bank_account_set_transition

**Canonical signature:** `(uuid, date, jsonb, uuid)`  
**Definitive migration: `20260603475_fix_dependent_hire_date_guard.sql`
**Table written:** `employee_bank_account_set`, `employee_bank_account_item`, `employee_bank_attachments`

## What it does (all features — do not remove any)

1. **Hire-date guard** — rejects `p_effective_from < employees.hire_date`
2. **Case detection** — one of: correction / prepend / split / amendment
   - `correction`: exact date match → delete+reinsert items in same set
   - `prepend`: before earliest slice → new set with inherited end date
   - `split`: inside a closed slice → trim + new slice
   - `amendment`: default → close current open set + new set
3. **gen_random_uuid() for new accounts** — `p_items[i].bank_account_group_id` is null for new accounts; auto-generates a UUID
4. **Attachment saving** — after each item INSERT, loops over `p_items[i].attachments[]` and inserts rows into `employee_bank_attachments` (FK: `bank_account_item_id`)

## History of regressions (for awareness)

- Mig 390 added attachments to a 5-param overload, dropped the 4-param.
- Mig 454 re-added a 4-param (for effective dating) without reading mig 390 — silently dropped attachments.
- Mig 465 dropped the 5-param overload — eliminated the last attachment-capable version.
- Mig 473 restored the complete function.

## Rule: before modifying this function

1. Read this file first.
2. Read mig 473's full function body.
3. Your new migration must include ALL 4 features above.
4. Update this file's "Definitive migration" line after merging.
