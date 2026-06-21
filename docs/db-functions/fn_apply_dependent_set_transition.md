# fn_apply_dependent_set_transition

**Canonical signature:** `(uuid, date, jsonb, uuid)`  
**Definitive migration: `20260603475_fix_dependent_hire_date_guard.sql`
**Tables written:** `employee_dependent_set`, `employee_dependent_item`, `employee_dependent_attachments`

## Features (all must be present — do not drop any)

1. **Advisory lock** — `pg_advisory_xact_lock` per employee
2. **Hire-date guard** — rejects `p_effective_from < employees.hire_date`
3. **Case detection** — correction / prepend / split / amendment
   - `correction`: exact date match → delete items + reuse set (attachments survive by dep_code)
   - `prepend`: before first slice → new set ending day before first
   - `split`: inside a closed slice → trim + new slice
   - `amendment`: default → close open set + new set
4. **dep_code sequence** — auto-generates `{EMP_CODE}_DEP_NN`, excludes correction set from max
5. **Attachment reconciliation per item**
   - 5a. INSERT new rows (NOT EXISTS guard to avoid dupes)
   - 5b. DELETE rows absent from submitted list (user removed them)
   - All inserts set `uploaded_by = created_by = updated_by = p_actor`

## History of regressions

| Mig | What happened |
|-----|--------------|
| 322 | Original: insert-only attachments |
| 342 | Fixed `updated_by` in attachment INSERT |
| 454 | Added case detection — but no attachment deletion |
| 456 | Added hire-date guard — **dropped case detection** |
| 466 | Added attachment deletion — based on 456, **still no case detection** |
| 471 | Fixed updated_by — based on 466, **still no case detection** |
| 474 | **Definitive**: all features combined ✓ |

## Rule: before modifying this function

1. Read this file first.
2. Read mig 474's full body.
3. Your new migration MUST include all 5 features above.
4. Update the "Definitive migration" line here after merging.
