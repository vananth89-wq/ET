# Bulk Operations Framework — Design Spec & Reference

**Status:** COMPLETE — all 16 templates live  
**Last updated:** 2026-06-02  
**Migrations:** 373–428  
**Templates:** 16 (13 employee-scoped + 3 admin master)

---

## 1. Decision Summary (24 locked rules)

| # | Rule |
|---|---|
| 1 | Sidebar item "Import / Export" below Reports in the Admin section |
| 2 | Visibility gate: any `*.bulk_*` permission grants tab access; template dropdown filtered per user |
| 3 | Permission naming: `<module>.bulk_import` and `<module>.bulk_export` |
| 4 | 16 modules: personal_info, contact_info, address, passport, identification, emergency_contact, education, employment, job_relationships, dependents, bank_accounts, employees, department, picklist, project, exchange_rate |
| 5 | Date format `mm/dd/yyyy` strict — any other format rejected |
| 6 | **Codes only, never labels** — employee codes, picklist ref_ids, ISO country codes, currency codes. The export stores the raw ref_id for all user-fillable fields (mig 425). |
| 7 | Export = full table contents (filtered by toggles) |
| 8 | CSV only. Template download = `.zip` with `<template>_template.csv` + `README.txt` |
| 9 | Mandatory fields marked `*` in CSV header |
| 10 | Export and template have identical user-fillable column structure (round-trip-safe) |
| 11 | Two export buttons: **Export current** (round-trip-safe) and **Export history** (full timeline, audit-only) |
| 12 | Persistent "Include inactive records" toggle (default OFF) |
| 13 | Bulk uploads bypass workflow regardless of per-module config |
| 14 | Processing goes through the module's registered processor RPC |
| 15 | 10,000 rows hard cap per file; warning at 5,000 |
| 16 | UTF-8 with BOM, comma delimiter, RFC 4180 quoting |
| 17 | Per-row audit trail written to `bulk_job_log` (one row per CSV row processed) |
| 18 | Async processing via Edge Function; status updates to `bulk_upload_job`; in-app notification on completion |
| 19 | Cancellation: committed rows stay; remaining skipped; status = 'cancelled' |
| 20 | `DELETE_RECORD` keyword closes a record — requires confirmation before commit |
| 21 | `DELETE` keyword removes a single value from a set-snapshot slice |
| 22 | Export default = user-fillable business fields only (round-trip safe) |
| 23 | "Include system metadata" toggle: adds id, timestamps, audit fields. NOT round-trip safe. Default OFF. |
| 24 | Template never includes system fields. Importer silently ignores unknown/system headers. |

---

## 2. Architecture

### 2.1 Layers

```
bulk_template_registry      ← single source of truth for all 16 templates
bulk_upload_job             ← one row per upload attempt (status, counts, file paths)
bulk_job_log                ← one row per processed CSV row (natural key + action)
Storage: bulk-uploads/      ← uploaded CSVs + error files (7-day retention)
```

### 2.2 Export — dispatch table pattern (mig 423)

The monolithic 400-line `bulk_export` CASE statement was replaced in mig 423.

**Public dispatcher (stable — never changes):**
```sql
CREATE FUNCTION bulk_export(p_template_code TEXT, p_include_inactive BOOLEAN, p_mode TEXT)
  -- 1. Validate template exists (SQL-injection guard via EXISTS check)
  -- 2. Permission check
  -- 3. EXECUTE format('SELECT * FROM %I($1,$2)', '_bulk_export_' || p_template_code)
```

**Per-template private functions:**
```
_bulk_export_personal_info()    _bulk_export_contact_info()
_bulk_export_address()          _bulk_export_passport()
_bulk_export_identification()   _bulk_export_emergency_contact()
_bulk_export_employment()       _bulk_export_job_relationships()
_bulk_export_dependents()       _bulk_export_bank_accounts()
_bulk_export_employees()        _bulk_export_department()
_bulk_export_picklist()         _bulk_export_project()
_bulk_export_exchange_rate()    _bulk_export_education()
```

**Adding a template:** create `_bulk_export_{code}()` + register in registry. Dispatcher unchanged.

### 2.3 Edge Functions

| Function | Mode | Role |
|---|---|---|
| `bulk-import-validator` | Sync | Shape + type validation; diff preview; returns per-row results |
| `bulk-import-processor` | Async | Lock → upsert loop → audit log → release lock → notify |
| `bulk-export-generator` | Sync (streaming) | Calls `bulk_export` RPC → filters via schema_definition → streams CSV |
| `bulk-template-generator` | Sync | Generates header CSV + README.txt → ZIP |

---

## 3. Database Schema

### 3.1 `bulk_template_registry`

```sql
template_code       TEXT PRIMARY KEY
display_label       TEXT
description         TEXT
icon                TEXT                    -- Tabler icon class e.g. 'ti-briefcase'
sort_order          INTEGER
permission_import   TEXT                    -- e.g. 'employment.bulk_import'
permission_export   TEXT
processor_rpc       TEXT                    -- e.g. 'upsert_employment_info'
schema_definition   JSONB                   -- drives template, column order, validator
natural_key         TEXT[]                  -- uniqueness key column names
workflow_bypass     BOOLEAN DEFAULT true
-- Concurrency guard (mig 427)
processing_lock     BOOLEAN DEFAULT false
locked_by_job_id    UUID REFERENCES bulk_upload_job(id)
locked_at           TIMESTAMPTZ
```

### 3.2 `bulk_upload_job`

```sql
id                  UUID PRIMARY KEY
template_code       TEXT
uploaded_by         UUID
file_name           TEXT
storage_path        TEXT                    -- bulk-uploads/{id}.csv
row_count           INTEGER
valid_count         INTEGER
warning_count       INTEGER
error_count         INTEGER
succeeded_count     INTEGER DEFAULT 0
failed_count        INTEGER DEFAULT 0
skipped_count       INTEGER DEFAULT 0
status              TEXT CHECK (status IN (
                      'validating','awaiting_user','processing',
                      'completed','partial','cancelled','failed'))
is_dry_run          BOOLEAN DEFAULT false   -- mig 428
error_file_path     TEXT
completed_at        TIMESTAMPTZ
cancelled_at        TIMESTAMPTZ
```

### 3.3 `bulk_job_log` (mig 426)

Per-row audit trail.

```sql
id            UUID PRIMARY KEY
job_id        UUID REFERENCES bulk_upload_job(id) ON DELETE CASCADE
row_number    INT
action        TEXT CHECK (action IN ('created','updated','failed','skipped'))
natural_key   JSONB       -- {column_name: value} e.g. {"Employee Code *": "EMP001"}
error         TEXT        -- populated for failed rows
created_at    TIMESTAMPTZ
```

---

## 4. `schema_definition` JSONB format

```json
{
  "columns": [
    {
      "name":        "Employee Code *",
      "data_type":   "code_employee",
      "mandatory":   true,
      "user_fillable": true,
      "description": "Existing employee code e.g. EMP001"
    },
    {
      "name":        "id",
      "data_type":   "uuid",
      "mandatory":   false,
      "user_fillable": false,
      "include_with_system_metadata": true
    }
  ],
  "natural_key":   ["Employee Code *", "Effective Date *"],
  "row_processor": "per_row"
}
```

### 4.1 `data_type` reference

| data_type | Validated as | Import notes |
|---|---|---|
| `date_mmddyyyy` | mm/dd/yyyy strict regex | Converted to ISO DATE |
| `code_employee` | employees.employee_id | Resolved to UUID by Edge Function |
| `code_department` | departments.dept_id | Resolved to UUID |
| `code_currency` | currencies.code | Resolved to UUID |
| `code_picklist:<ID>` | picklist_values.ref_id | ref_id passed as-is to RPC |
| `text` | Free-form | — |
| `yesno` | Yes/No (case-insensitive) | → BOOLEAN |
| `integer` | Integer regex | — |
| `enum:<list>` | Must match listed value | — |
| `uuid` | System-only | Never imported |
| `timestamp` | System-only | Never imported |

### 4.2 `row_processor` modes

- `per_row` — one RPC call per row. Used for flat tables.
- `group_by_key` — rows grouped by natural key prefix, one RPC call per group with all items. Used for `job_relationships`, `dependents`, `bank_accounts`.

---

## 5. Export Pipeline

### 5.1 Column selection

```typescript
columns.filter(col =>
  col.user_fillable ||
  (include_system_metadata && col.include_with_system_metadata)
)
```

### 5.2 Codes-not-labels (mig 425)

User-fillable picklist fields export the stored **ref_id** (code), not the display label.

| Storage pattern | Field examples | Export method |
|---|---|---|
| ref_id stored directly (TEXT) | designation, work_location, marital_status, id_type, country, relationship, relationship_type | Use raw column value |
| UUID stored (picklist_value.id) | work_country in employment + employees | `LEFT JOIN picklist_values pv ON pv.id::text = column` → use `pv.ref_id` |

### 5.3 Draft/Incomplete exclusion

All 12 employee-scoped templates add `AND e.status NOT IN ('Draft','Incomplete')`. Draft employees' hire-wizard data is excluded.

### 5.4 Row count feedback

After download, the UI counts non-comment non-header CSV lines and shows *"✓ Exported N rows"*.

### 5.5 System metadata tooltip

ⓘ tooltip on the "Include system metadata" checkbox explains: *"Adds id, timestamps and audit fields. Reference-only — importer silently ignores them. Never included in the Download Template."*

---

## 6. Import Pipeline

### 6.1 Validation (synchronous)

1. Upload CSV → Storage → create `bulk_upload_job`
2. `bulk-import-validator` runs:
   - Strip `#` comment lines, parse CSV
   - Validate headers (missing mandatory → fail)
   - Per-row: shape → type → composite key uniqueness within file
   - Call `bulk_diff_preview` RPC → add `diff_preview: {new_count, update_count}` to response
3. UI shows diff preview banner + per-row table + **Preview run** + **Process** buttons

### 6.2 Diff preview — `bulk_diff_preview` RPC (mig 422)

Checks each valid row's natural key against the DB for all 16 templates. Returns `{new_count, update_count}`. Non-authoritative (informational only). Never blocks import.

### 6.3 Concurrency guard (mig 427)

`acquire_bulk_lock(template_code, job_id)` before processing:
- Rejects if another fresh lock exists (< 30 min) → HTTP 409
- Auto-expires stale locks (crashed jobs)

`release_bulk_lock(template_code, job_id)` on completion/failure/cancellation.

### 6.4 Dry-run mode (mig 428)

"Preview run" button → `dry_run: true` → processor:
1. Sets `SAVEPOINT bulk_dry_run`
2. Runs full processing loop (reference resolution, RPC calls)
3. `ROLLBACK TO SAVEPOINT bulk_dry_run` — zero data committed
4. Reports would-succeed / would-fail counts
5. Job stored with `is_dry_run = true` → shown as "preview" badge

### 6.5 Processing loop

```
acquire lock
for each row:
  resolve codes → UUIDs
  call processor_rpc
  append {row_number, action, natural_key, error} to jobLogEntries
  
batch-insert jobLogEntries → bulk_job_log (chunks of 500)
write error CSV (# summary + Row#/Error columns first)
if dry_run: ROLLBACK TO SAVEPOINT
release lock
finalise job status
send in-app notification
```

### 6.6 Error CSV format

```
# Import Error Report
# Total rows processed : 200
# Succeeded            : 178
# Failed               : 22
# Most common error    : Employee code not found (15 rows)
#
# The rows below failed. Fix the errors and re-import only these rows.
#
Row #,Error,Employee Code *,Effective Date *,...
3,"Employee code not found: EMP-999",EMP-999,06/01/2026,...
```

### 6.7 Retry failed rows

"Download rows to retry" button strips `#` header lines and `Row #`/`Error` columns → produces clean `*_retry.csv` ready to fix and re-import.

---

## 7. Recent Uploads Panel

Lists last 25 jobs per template. Detail modal has two tabs:

**Summary:** counts, timestamps, download error CSV, retry button.

**Changes (mig 426):** queries `get_bulk_job_log(job_id)` → table showing:
- Row #, Action (New / Updated / Failed), Natural key, Error message

Jobs before mig 426 show "No change log available."

---

## 8. Per-Template Reference

### Employee-scoped (13) — all exclude Draft/Incomplete

| Template | Natural Key | Processor | History |
|---|---|---|---|
| personal_info | Employee Code, Effective Date | upsert_personal_info | ✅ |
| contact_info | Employee Code | upsert_contact_info | — |
| address | Employee Code | upsert_employee_address | — |
| passport | Employee Code, Passport Number | upsert_passport | — |
| identification | Employee Code, ID Type, ID Number | upsert_identity_record | — |
| emergency_contact | Employee Code | upsert_emergency_contact | — |
| education | Employee Code, Education Level Code, Institution, Start Date | upsert_education | ✅ |
| employment | Employee Code, Effective Date | upsert_employment_info | ✅ |
| job_relationships | Employee Code, Effective Date, Relationship Code | upsert_job_relationship_set | ✅ |
| dependents | Employee Code, Effective Date, Dependent Code | upsert_dependent_set | ✅ |
| bank_accounts | Employee Code, Effective Date, Account Group Id | upsert_bank_account_set | ✅ |
| employees | Employee Code | upsert_employee_master | — |
| department | Department Code | upsert_department | — |

### Admin/master (3)

| Template | Natural Key | Processor | History |
|---|---|---|---|
| picklist | Picklist Id, Ref Id | upsert_picklist_value | — |
| project | Project Name | upsert_project | — |
| exchange_rate | From Currency, To Currency, Effective Date | upsert_exchange_rate | — |

### Known column notes

**contact_info — Business Email:**
Exported as system metadata (`include_with_system_metadata: true`). NOT user-fillable on import — `employees.business_email` is the source of truth (login identity key). Change via Employees master template.

**education — Field of Study:**
`field_of_study` column was dropped in mig 405. Not in export, template, or schema.

**picklist — Sort Order:**
`sort_order` was never added to `picklist_values`. Not in export, template, or schema (cleaned up mig 423 Part 4).

---

## 9. Migration Index (373–428)

| Mig | Description |
|---|---|
| 373 | Schema: registry + upload_job + storage + visibility gate function |
| 374 | 30 bulk permission seeds |
| 375 | 15 registry row seeds |
| 376 | 12 processor RPC wrappers + unique indexes |
| 377 | `bulk_export` RPC (original 15-WHEN monolith) |
| 378–403 | Education module + hire pipeline fixes + export fixes |
| 405 | Education: drop `field_of_study` |
| 408 | Bulk export: full column coverage all 15 templates |
| 410 | `employee_contact`: add `business_email` |
| 412 | `upsert_department`: fix p_row keys + extended fields |
| 413 | Schema_definition re-apply all 15 templates (system metadata + ORDER BY fix) |
| 414–416 | Currency seeds + hire pipeline migrations |
| 418–420 | Bulk export: education clause + field_of_study fix + Draft/Incomplete guard |
| 422 | `bulk_diff_preview` RPC (all 16 templates) |
| 423 | **Dispatch table**: `_bulk_export_*` per-template functions + stable dispatcher |
| 424 | contact_info: add Business Email to export + schema |
| 425 | **Codes not labels**: remove picklist_label() wrappers (7 templates) |
| 426 | `bulk_job_log` + `get_bulk_job_log` RPC + processor writes audit rows |
| 427 | **Concurrency guard**: processing_lock + acquire/release RPCs |
| 428 | **Dry-run mode**: is_dry_run column + SAVEPOINT/ROLLBACK RPCs |

**Next migration: 20260602429+**

---

## 10. Key Invariants

1. **Dispatcher never grows** — adding a template = new `_bulk_export_{code}()` only
2. **Codes only** — `picklist_label()` banned in `_bulk_export_*` for user-fillable columns
3. **Draft/Incomplete excluded** — `AND e.status NOT IN ('Draft','Incomplete')` in every employee query
4. **System metadata never round-trips** — `user_fillable: false` columns silently ignored on import
5. **Concurrency serialised** — only one active processing job per template at any time
6. **Dry-run is always safe** — SAVEPOINT/ROLLBACK guarantees zero data committed

---

## 11. Adding a New Template (checklist)

- [ ] `CREATE FUNCTION _bulk_export_{code}(BOOLEAN, TEXT) RETURNS SETOF JSONB` — codes not labels, exclude Draft/Incomplete if employee-scoped
- [ ] `GRANT EXECUTE ON FUNCTION _bulk_export_{code}(BOOLEAN, TEXT) TO authenticated`
- [ ] Add `WHEN '{code}'` block to `bulk_diff_preview` RPC
- [ ] Create or confirm processor RPC exists
- [ ] Seed `{code}.bulk_import` + `{code}.bulk_export` permissions
- [ ] Insert registry row with full `schema_definition` JSONB
- [ ] Update `PermissionMatrix.tsx` BULK_TEMPLATES array
