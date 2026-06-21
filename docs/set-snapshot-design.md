# Set-Snapshot Model — Design Spec

**Status:** Locked design, pre-implementation
**Scope:** Replace per-row effective-dating for `employee_dependents` and `employee_bank_accounts` with a parent-child set-snapshot pattern, modelled after SAP SuccessFactors Employee Central.
**Author:** 2026-05-29 design session
**Implementation phases:** see `Phases` section at the bottom

---

## 1. Decision Summary

| Decision | Value | Locked |
|---|---|---|
| Data model | Effective-dated parent SET + N child ITEM rows | ✓ |
| Unit of workflow | The entire SET — one workflow request per change session | ✓ |
| `workflow_instances.record_id` for set modules | `employee_id` (UUID, no schema widening) | ✓ |
| Dependents: 1st-of-month snap on `effective_from` | Yes | ✓ |
| Dependents: 15th submission / 20th approver cutoffs | No | ✓ |
| Bank: full per-month cutoff rules (15th / 20th / exempt roles) | Yes (preserve current behaviour at set level) | ✓ |
| Both modules ship the same architecture | Yes (Dependents first, Bank second) | ✓ |
| Legacy tables | Renamed to `_legacy`, kept for ≥2 weeks for rollback | ✓ |

---

## 2. Why this change

**Problem we are solving.** Adding 4 dependents currently requires 4 separate workflow submissions and 4 approver acts. The DB unique constraint on `(module_code, record_id)` was being used at the per-dependent level, forcing the UI to gate "Add Dependent" while any one is in flight. Approvers see N independent tasks for what the employee considers one event.

**Industry alignment.** Workday models this as a Business Process Instance whose target reference is the employee record; SuccessFactors stores a parent workflow_request with multiple child items inside one approval. Both treat "my family configuration as of date X" or "my bank accounts as of date X" as a single atomic concept. Our per-row model fights that.

**What the set model gives us.**

- One workflow per change session, regardless of how many items changed
- Approver sees one diff with adds / amends / removes marked per item
- Point-in-time queries become trivial (`get_employee_dependent_set(emp, as_of)`)
- The DB unique constraint on `(module_code, record_id)` naturally means "one in-flight set change per employee" — which is now the correct business rule
- Effective-dating logic lives in one place (the parent) instead of being chased per row

---

## 3. Schema

### 3.1 Dependents

```sql
CREATE TABLE employee_dependent_set (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  effective_from DATE NOT NULL,
  effective_to   DATE NOT NULL DEFAULT '9999-12-31'::date,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  created_by     UUID REFERENCES profiles(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_dep_set_effective_order
    CHECK (effective_to >= effective_from)
);

CREATE TABLE employee_dependent_item (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  set_id              UUID NOT NULL REFERENCES employee_dependent_set(id) ON DELETE CASCADE,
  dependent_code      TEXT NOT NULL,             -- stable identity ACROSS sets (e.g. EMP-0042_DEP_01)
  relationship_type   TEXT NOT NULL,             -- ref_id from DEPENDENT_RELATIONSHIP_TYPE
  dependent_name      TEXT NOT NULL,
  date_of_birth       DATE NOT NULL,
  gender              TEXT NOT NULL CHECK (gender IN ('Male', 'Female')),
  insurance_eligible  BOOLEAN NOT NULL DEFAULT false,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE UNIQUE INDEX uq_dep_set_active_per_employee
  ON employee_dependent_set (employee_id)
  WHERE is_active = true AND effective_to = '9999-12-31'::date;

CREATE UNIQUE INDEX uq_dep_item_code_per_set
  ON employee_dependent_item (set_id, dependent_code);

CREATE INDEX idx_dep_item_dep_code
  ON employee_dependent_item (dependent_code);

CREATE INDEX idx_dep_set_employee
  ON employee_dependent_set (employee_id, effective_from DESC);
```

### 3.2 Bank accounts

```sql
CREATE TABLE employee_bank_account_set (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  effective_from DATE NOT NULL,
  effective_to   DATE NOT NULL DEFAULT '9999-12-31'::date,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  created_by     UUID REFERENCES profiles(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_bank_set_effective_order
    CHECK (effective_to >= effective_from)
);

CREATE TABLE employee_bank_account_item (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  set_id                UUID NOT NULL REFERENCES employee_bank_account_set(id) ON DELETE CASCADE,
  bank_account_group_id UUID NOT NULL,           -- stable identity across sets
  country_code          TEXT NOT NULL,
  currency_code         TEXT NOT NULL,
  bank_name             TEXT NOT NULL,
  branch_name           TEXT,
  branch_code           TEXT,
  account_holder_name   TEXT NOT NULL,
  account_number        TEXT NOT NULL,
  ifsc_code             TEXT,
  iban                  TEXT,
  swift_bic             TEXT,
  is_primary            BOOLEAN NOT NULL DEFAULT false,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Country-specific field rules (lifted from current schema)
  CONSTRAINT chk_bank_ind_ifsc CHECK (country_code <> 'IND' OR ifsc_code IS NOT NULL),
  CONSTRAINT chk_bank_pak_iban CHECK (country_code <> 'PAK' OR iban IS NOT NULL),
  CONSTRAINT chk_bank_sau_iban CHECK (country_code <> 'SAU' OR iban IS NOT NULL),
  CONSTRAINT chk_bank_lka_branch CHECK (country_code <> 'LKA' OR branch_code IS NOT NULL)
);

-- Indexes
CREATE UNIQUE INDEX uq_bank_set_active_per_employee
  ON employee_bank_account_set (employee_id)
  WHERE is_active = true AND effective_to = '9999-12-31'::date;

CREATE UNIQUE INDEX uq_bank_item_group_per_set
  ON employee_bank_account_item (set_id, bank_account_group_id);

-- Exactly one primary per set
CREATE UNIQUE INDEX uq_bank_item_primary_per_set
  ON employee_bank_account_item (set_id)
  WHERE is_primary = true;
```

### 3.3 Attachment tables — no schema change

`employee_dependent_attachments` already keys by `dependent_code` (mig 292). The FK to `employee_dependents.id` becomes dead and can be dropped in cleanup. Attachments survive set transitions because they reference the stable code, not the row id.

Same logic applies to `employee_bank_attachments` once we add `bank_account_group_id` as the join key (it already has the column).

### 3.4 RLS pattern

Identical to the current dependents / bank pattern (see `[[prowess-permission-engine]]`):

- **Path A:** `user_can('dependents', '<action>', employee_id)` / `user_can('bank_accounts', '<action>', employee_id)` — target-group scoped
- **Path B:** `user_can('dependents', '<action>', NULL)` AND `user_can('hire_employee', '<view|edit>', NULL)` AND `employees.status IN ('Draft','Incomplete','Pending')` — HR-guard for hire pipeline

Policies attach to BOTH the set table and the item table (item policy joins on `set_id`).

---

## 4. RPC contracts

### 4.1 Dependents

```sql
-- READ
get_employee_dependent_set(
  p_employee_id UUID,
  p_as_of       DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
  set_id          UUID,
  effective_from  DATE,
  effective_to    DATE,
  items           JSONB                      -- array of items + attachments
)
-- Returns the set active on p_as_of (active = effective_from <= p_as_of < effective_to, is_active=true)

get_employee_dependent_set_history(p_employee_id UUID)
  RETURNS TABLE (set_id, effective_from, effective_to, item_count, change_summary)
-- All sets in reverse chronological order

-- WRITE
submit_dependent_set(
  p_employee_id   UUID,
  p_effective_from DATE,
  p_items         JSONB                       -- [{ dependent_code, relationship_type, name, dob, gender, insurance_eligible, attachments? }, ...]
                                              -- dependent_code = null for NEW items
) RETURNS JSONB                                -- { ok, workflow, instance_id, set_id }
-- Dual-path:
--   1. Snap p_effective_from to 1st of month (always; no cutoffs for dependents)
--   2. Validate items (relationship picklist, dates, no duplicates)
--   3. resolve_workflow_for_submission('profile_dependents', auth.uid())
--      - if NULL → PATH A: fn_apply_dependent_set_transition directly
--      - if non-NULL → PATH B: stage in workflow_pending_changes + wf_submit
--   4. Access guard: user_can('dependents', 'create|edit|delete', p_employee_id)

-- INTERNAL
fn_apply_dependent_set_transition(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_actor          UUID
) RETURNS UUID                                 -- new set_id
-- Idempotent transition: close current set, insert new set, insert items,
-- assign dependent_code for new items, rewrite staged attachment paths
```

### 4.2 Bank

```sql
get_employee_bank_account_set(p_employee_id, p_as_of)
get_employee_bank_account_set_history(p_employee_id)

submit_bank_account_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB
) RETURNS JSONB
-- Rules layered on top of dependent-set behaviour:
--   - effective_from MUST be 1st of current month
--   - Submission day MUST be <= 15 (unless is_bank_exception)
--   - Exactly one item with is_primary=true
--   - Country-specific field rules per item (CHECK constraints back it up)
--   - 20th-of-month approver cutoff enforced in apply_profile_pending_change

fn_apply_bank_account_set_transition(p_employee_id, p_effective_from, p_items, p_actor)
```

### 4.3 Trigger update

`apply_profile_pending_change` for `profile_bank` and `profile_dependents`:

```sql
-- Pseudo
WHEN module_code = 'profile_dependents' THEN
  PERFORM fn_apply_dependent_set_transition(
    employee_id      => (proposed_data->>'employee_id')::uuid,
    p_effective_from => (proposed_data->>'effective_from')::date,
    p_items          => proposed_data->'items',
    p_actor          => approved_by
  );

WHEN module_code = 'profile_bank' THEN
  -- Approver 20th-of-month cutoff: reject if today > 20 and user not exempt
  IF EXTRACT(DAY FROM CURRENT_DATE) > 20 AND NOT is_bank_exception(approved_by) THEN
    RAISE EXCEPTION 'Bank set changes cannot be approved after the 20th of the month';
  END IF;

  PERFORM fn_apply_bank_account_set_transition(...);
```

---

## 5. Workflow contract

### 5.1 record_id strategy

`record_id = p_employee_id` (UUID, unchanged column type). Module is namespaced by `module_code`. The active-states partial unique on `(module_code, record_id)` enforces: at most one in-flight set change per employee per module.

### 5.2 workflow_pending_changes shape

```json
{
  "module_code": "profile_dependents",
  "record_id":   "<employee_uuid>",
  "status":      "pending",
  "submitted_by": "<auth.uid()>",
  "proposed_data": {
    "employee_id":    "<employee_uuid>",
    "effective_from": "2026-06-01",
    "items": [
      {
        "dependent_code": "EMP-0042_DEP_01",
        "relationship_type": "DR001",
        "dependent_name":  "Alice",
        "date_of_birth":   "1985-01-01",
        "gender":          "Female",
        "insurance_eligible": true,
        "attachments": [{ "file_path": "...", "document_type": "DD001", ... }]
      },
      {
        "dependent_code": null,
        "_new": true,
        "relationship_type": "DR002",
        "dependent_name":  "Dan",
        "...": "..."
      }
    ]
  }
}
```

### 5.3 Approver mid-flight edits

`wf_approver_update_pending_changes(p_instance_id, p_proposed_data)` writes the new `proposed_data` JSONB. Existing engine support — no change needed. Frontend rewrites the items array based on approver edits.

---

## 6. Approver diff rendering

Diff is computed by joining `current set items` (via `get_employee_dependent_set`) with `proposed_data.items` on `dependent_code`:

| Match state | Diff label |
|---|---|
| In current AND in proposed, all fields equal | Unchanged |
| In current AND in proposed, some fields differ | Amended (show old → new per field) |
| In proposed, `dependent_code = null` (i.e. `_new`) | NEW |
| In current, NOT in proposed | REMOVED (struck through) |

Summary chip at top: `N unchanged · M amended · K added · L removed`.

Same pattern for bank items (key by `bank_account_group_id`).

---

## 7. Frontend changes

### 7.1 DependentsPortlet / BankAccountsPortlet

**View mode** (default):
- Loads active set via `get_employee_dependent_set` / `get_employee_bank_account_set`
- Renders read-only item cards (current FieldCell pattern carries over)
- "Edit Dependents" / "Edit Bank Accounts" button enters draft mode

**Draft mode**:
- Local clone of the active set's items
- Add → push to local array with `dependent_code: null, _new: true`
- Edit → mutate local item
- Remove → mark for omission from the next submission (visual struck-through card)
- Live counter: `(N added, M amended, K removed)`
- Footer: `[Submit Changes]` `[Discard Changes]`
- Submit calls `submit_dependent_set(...)` / `submit_bank_account_set(...)` with the full items array

**Pending preview** (when a workflow is in flight):
- Replaces draft mode entry — shows the proposed set with amber `Pending Approval` badge
- No edit controls; read-only

**History panel**:
- List of past sets (via `get_employee_dependent_set_history`)
- Click a set → expand to show its items at that point in time

### 7.2 ApproverInbox + WorkflowReview

`DependentsEnrichment` / `BankEnrichment` rewritten:
- Fetch current set via `get_employee_dependent_set(employee_id, current_date)`
- Render diff cards per item
- Summary chip at top
- Edit mode mutates `editValues['items']` as JSON-encoded array

### 7.3 Hire wizard

`AddEmployee` dependents tab and bank tab:
- Add multiple items locally during the hire flow (already supported)
- On `submit_hire` / `wf_activate_employee`, the wizard's collected items become the initial set with `effective_from = hireDate`

### 7.4 EmployeeEditPanel

Admin edit uses the same set editor component with HR-guard write path.

---

## 8. Backfill algorithm

### 8.1 Dependents

For each employee with rows in legacy `employee_dependents`:

1. **Active items** (where `is_active=true AND effective_to='9999-12-31'`):
   - Create one set with `effective_from = MIN(effective_from)` of the group, `effective_to = '9999-12-31'`, `is_active = true`
   - Insert items under that set, preserving `dependent_code`
2. **Historical sets** (amendment-closed rows: `is_active=true AND effective_to <> '9999-12-31'`):
   - Cluster rows by `(effective_from, effective_to)` pair — rows sharing the same window belong to the same historical set
   - Create one historical set per cluster, insert its items
3. **Removed items** (`is_active=false`):
   - Do not appear in any subsequent set — they're implicitly "removed" by their absence
   - The amendment-closure history captures them up to the date they went inactive

### 8.2 Bank

Same procedure, keyed by `bank_account_group_id`.

### 8.3 Validation

After backfill:
- Row count check: every legacy active row has a corresponding item in some set
- Identity check: every `dependent_code` / `bank_account_group_id` is present in at least one set
- Date check: `MIN(set.effective_from) <= MIN(legacy.effective_from)` per employee (no time loss)

If any check fails, the migration aborts inside a transaction — DB returns to pre-state.

---

## 9. Rollback strategy

- Legacy tables renamed to `employee_dependents_legacy`, `employee_bank_accounts_legacy` — preserved for ≥2 weeks
- All new RPCs are NEW names — old `upsert_dependent` etc. NOT dropped until cleanup phase
- If a critical bug surfaces in week 1, frontend can swap back to old RPCs and the data is still there
- Cleanup phase drops legacy tables and dead RPCs only after the validation window closes

---

## 10. Notifications

`wf_queue_notification` already routes `<module_prefix>.<event>` (mig 250). Module prefix `profile_dependents` and `profile_bank` continue to work.

Template placeholders need update:
- Old: `{{name}}` of the single dependent
- New: `{{change_summary}}` — e.g. "2 added, 1 amended"

Add new template variants (without breaking the old ones; the new set submissions populate the new placeholders).

---

## 11. Risk register

| Risk | Mitigation |
|---|---|
| Backfill miscounts a historical cluster | Run side-by-side comparison test; abort in tx if validation fails |
| Hire flow's pre-hire dependents don't land in initial set | Explicit integration test on hire activation; verify item count matches wizard input |
| Approver mid-flight edits break on new items array shape | Backward-compat: `wf_approver_update_pending_changes` writes whatever shape it receives; trigger only validates on apply |
| Bank cutoffs at set level reject legitimate adds | Exempt roles work as-is via `is_bank_exception`; document the new "any change after 15th means whole set rejected" rule for stakeholders |
| Old deep-link URLs (notifications referencing dependent_id) 404 | Add redirect: `/dependent/<id>` → look up the current containing set, redirect to set view |

---

## 12. Phases & sequencing

| # | Phase | Files / migrations | Estimate |
|---|---|---|---|
| 0 | Design doc | this file | 1 day (done) |
| 2 | Dependents schema | `mig 301_employee_dependent_set_schema.sql` | 1 day |
| 2 | Dependents RPCs | `mig 302_dependent_set_rpcs.sql` + trigger update in `mig 303_apply_pending_dependents_set.sql` | 2 days |
| 2 | Dependents backfill | `mig 304_dependents_backfill.sql` | 1 day |
| 3 | DependentsPortlet rewrite | `DependentsPortlet.tsx` | 2 days |
| 3 | Approver diff (dep) | `ApproverInbox.tsx` (DependentsEnrichment), `WorkflowReview.tsx` (profile_dependents) | 1.5 days |
| 3 | Hire wizard integration | `AddEmployee.tsx`, `EmployeeEditPanel.tsx` | 1 day |
| 4 | Bank schema + RPCs | `mig 305..307` (mirror) | 2 days |
| 4 | Bank backfill | `mig 308_bank_backfill.sql` | 1 day |
| 5 | Bank frontend | `BankAccountsPortlet.tsx`, `ApproverInbox.tsx` (BankEnrichment), `WorkflowReview.tsx` (profile_bank), wizard + admin | 2.5 days |
| 6 | Cleanup + docs | drop `_legacy` tables, dead RPCs; update `prowess_system_docs.html` Parts 11+12; type regen | 1 day |

**Total: ~14 working days. Phase 0 → 2 → 3 first (Dependents end-to-end), then 4 → 5 (Bank), then 6.**

---

## 13. Open items to settle during build (not blocking start)

- `effective_from` snap behaviour for dependents: if user submits `2026-06-15`, do we silently snap to `2026-06-01` or reject? Recommended: silently snap with a UI note.
- Empty-set handling: employee with zero dependents has either (a) no set row or (b) an empty set. Recommended: no set row; first add creates set #1.
- Bank exempt role rename: keep `bank_exceptions` or introduce a shared `profile_exceptions`? Recommended: keep `bank_exceptions` (no change to existing role assignments).
- New-item attachment uploads: which storage path? Recommended: same `bank/<employee>/<group_id>/...` and `dependents/<employee>/<dep_code>/...` patterns. For NEW items, use `dependents/<employee>/_new_<uuid>/...` until the dependent_code is assigned, then rewrite on apply.
