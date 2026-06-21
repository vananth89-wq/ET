# Employment Effective-Dating — Design Spec

**Status:** ✅ COMPLETE — Shipped 2026-05-30 (migs 351–356, all phases including Phase 11 cleanup)
**Scope:** Move employment fields from the `employees` master table into a versioned `employee_employment` satellite, mirroring the personal-info effective-dating pattern (migs 315–319). Share a single nightly activation job between personal_info and employment.
**Author:** 2026-05-29 design session
**Reference template:** `docs/set-snapshot-design.md` (recently shipped Phase 2) and migs 315–319 (personal info, already shipped).

---

## 1. Decision Summary

| Decision | Value | Locked? |
|---|---|---|
| Effective-dated entity | `employee_employment` (existing 1:1 satellite, expanded in place) | Locked |
| Fields to effective-date | All 10 fields move to `employee_employment`: `designation`, `job_title`, `dept_id`, `manager_id`, `hire_date`, `end_date`, `work_country`, `work_location`, `base_currency_id`, `status` | **Locked (per user 11.1)** |
| Fields kept on `employees` master | All 10 columns stay as denormalized **mirror cache**. Source of truth is the satellite. Mirror is updated by the RPC + nightly job. | **Locked (per user 11.3)** |
| Status transition handling | Same-date transitions (Draft → Pending → Active) update the current slice's `status` in place. Different-date transitions (Active → Inactive on future end_date) create a new slice. | Locked |
| Sync job sharing | Rename `activate_personal_info_records()` → `activate_effective_dated_records()`. Single pg_cron entry runs both per-table sync helpers + the end_date → Inactive scanner. | Locked |
| Workflow module | `profile_employment` (already registered as stub; promote to fully functional) | Locked |
| Hire-pipeline staging | **No draft table.** Hire wizard writes directly to `employee_employment` with `effective_from = hire_date`. Sync to master happens when `effective_from ≤ CURRENT_DATE` (matches actual personal_info practice — `employee_personal_draft` was conceived but never used). | **Locked (per user 4.2)** |
| Backfill strategy | Per Active employee, seed first slice with `effective_from = hire_date`, all 10 fields copied from `employees` | Locked |
| Legacy `employees.*` columns | Kept as mirror cache; guard trigger blocks direct writes outside sync flow | Locked |
| `job_title` survival | **Keep.** 30+ frontend references rely on it as display title; dropping requires migrating every assignee-render path to resolve `designation` picklist → label. Auto-populate from designation as a fallback when blank. | **Locked (per user 11.2 + reference scan)** |
| end_date → Inactive lifecycle flip | Both synchronous (RPC: if approved end_date ≤ today AND status = Active, flip to Inactive in same slice) AND scanned (nightly job: scan for future-dated end_date that has come due) | **Locked (per user 11.4)** |
| `profile_employment` in WorkflowReview | Add to `FULL_REVIEW_MODULES` allowlist (full-page review supported) | **Locked (per user 11.5)** |
| Admin direct-write via `EmployeeEditPanel` | Yes — admin bypasses workflow, RPC enforces access guards | **Locked (per user 11.6)** |
| Manager cycle detection | RPC walks the manager chain up to 10 hops; on cycle, returns `{ok: false, error: 'CYCLE_DETECTED', ...}` — frontend renders the error as a modal dialog | **Locked (per user 11.7)** |
| `employment.history` permission | Add to seed | **Locked (per user 11.8)** |

---

## 2. Why This Change

**Problem.** Today, every employment field change (promotion, transfer, manager reassignment, country move) is a destructive overwrite on `employees`. There is:
- No timeline of who was the manager / department head / job title at any past date
- No standardized workflow for ESS-initiated employment changes (the `profile_employment` module is registered but is a stub — no satellite, no current-data snapshot, no ESS edit UI)
- Three parallel write paths (`AddEmployee` direct writes, `EmployeeEditPanel` section saves, `update_hire_field` for mid-hire edits) that each have to be touched whenever a field changes
- Forward-propagation gaps (changing `work_country` doesn't auto-sync `base_currency_id` outside `update_hire_field`; changing `manager_id` doesn't recompute the manager role for the new manager)

**Why mirror personal-info exactly.** That pattern just landed (migs 315–319) and works. Sharing the same model and the same nightly activation job keeps cognitive load low and prevents bifurcation of effective-dated tables across the codebase.

**Industry parity.** Both Workday (Position / Job Assignment effective-dated objects) and SuccessFactors (Job Information effective-dated EC entity) treat employment data this way. Promotion/transfer/manager-change all become point-in-time slices on a single timeline.

---

## 3. Current State

### 3.1 Where the 10 fields live today

All 10 sit on `employees` master directly. None are in `employee_employment` yet (which today only holds `probation_end_date`).

| Field | Column on `employees` | Type | FK / Picklist |
|---|---|---|---|
| designation | `designation` | TEXT | Holds `DESIGNATION` picklist UUID (not FK-enforced) |
| job_title | `job_title` | TEXT | Plain display text; never collected by current UI |
| dept_id | `dept_id` | UUID | FK `departments(id) ON DELETE SET NULL` |
| manager_id | `manager_id` | UUID | Self-FK `employees(id) ON DELETE SET NULL` |
| hire_date | `hire_date` | DATE | nullable |
| end_date | `end_date` | DATE | nullable; sentinel `'9999-12-31'` = open-ended |
| work_country | `work_country` | TEXT | Holds `ID_COUNTRY` picklist UUID |
| work_location | `work_location` | TEXT | Holds `LOCATION` picklist UUID (parent-filtered by work_country) |
| base_currency_id | `base_currency_id` | UUID | FK `currencies(id) ON DELETE SET NULL` |
| employment_status | `status` | ENUM `employee_status` | `Draft \| Incomplete \| Pending \| Active \| Inactive` |

**Note:** there is no `EMPLOYMENT_STATUS` picklist. The lifecycle status is the enum on `employees.status`, driven by `submit_hire` / `wf_activate_employee` / `sync_profile_on_employee_status`.

### 3.2 What's broken / missing

- **`profile_employment` workflow is a stub:** `useProfileWorkflowGates` lists it; `ApproverInbox` has label + permission entry; but it has no satellite, no `current_data` snapshot path, no ESS edit UI, no dedicated `EmploymentEnrichment` component. Approvers reviewing a `profile_employment` request see raw UUIDs for picklist fields, snake_case labels, plain text inputs for dates.
- **`MyProfile` Employment section is read-only.** No edit button. The `pendingCount` chip wires through to the gate hook but there's nothing to gate against because there's no editor.
- **Three write paths.** `AddEmployee` (hire creation), `EmployeeEditPanel.section('employment')` (admin edit), `update_hire_field` (mid-flight). Adding a new field requires touching all three.
- **`job_title` is dead code.** No UI collects it; no `update_hire_field` branch updates it; no `get_employee_hire_review` returns it; no audit log surface even cares.

### 3.3 Forward-propagation gaps observed today

- `work_country` change auto-derives `base_currency_id` **only inside `update_hire_field`** (mig 248). A plain UPDATE leaves `base_currency_id` stale.
- `manager_id` change does **not** trigger `sync_system_roles()` for the new manager. The `after_employee_role_sync` trigger fires only on `status` and `deleted_at`.
- `end_date` set in the past does **not** auto-flip `status` to `Inactive`. Lifecycle still requires an explicit status write.
- `dept_id` change does **not** trigger `department_heads` recompute (dept_head role is governed by the `department_heads` table directly).
- Audit log: handled universally via `trg_write_audit_log` on `employees` AFTER INSERT/UPDATE/DELETE — this works correctly today and will continue to.

---

## 4. Schema Design

### 4.1 `employee_employment` — convert in place to effective-dated timeline

Existing 1:1 satellite is repurposed. PK changes from `employee_id` to a new surrogate `id`; `employee_id` becomes a plain FK. **All 10 fields land here** including `hire_date` and `status`:

```sql
ALTER TABLE employee_employment
  ADD COLUMN id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Keep employee_id but drop its PK status; add the 10 effective-dated columns:
  ADD COLUMN designation       TEXT,                                     -- DESIGNATION picklist UUID
  ADD COLUMN job_title         TEXT,                                     -- Free-form title (kept, see §11.2)
  ADD COLUMN dept_id           UUID REFERENCES departments(id) ON DELETE SET NULL,
  ADD COLUMN manager_id        UUID REFERENCES employees(id)   ON DELETE SET NULL,
  ADD COLUMN hire_date         DATE,                                     -- Joining date (effective-dated for corrections)
  ADD COLUMN end_date          DATE,                                     -- Termination date
  ADD COLUMN work_country      TEXT,                                     -- ID_COUNTRY picklist UUID
  ADD COLUMN work_location     TEXT,                                     -- LOCATION picklist UUID
  ADD COLUMN base_currency_id  UUID REFERENCES currencies(id)  ON DELETE SET NULL,
  ADD COLUMN status            employee_status,                          -- Enum: Draft|Incomplete|Pending|Active|Inactive
  -- Effective-dating
  ADD COLUMN effective_from    DATE NOT NULL,
  ADD COLUMN effective_to      DATE NOT NULL DEFAULT '9999-12-31'::date,
  ADD COLUMN is_active         BOOLEAN NOT NULL DEFAULT true,
  -- Audit
  ADD COLUMN created_by        UUID REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN updated_by        UUID REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN inactive_at       TIMESTAMPTZ,
  ADD COLUMN inactive_by       UUID REFERENCES profiles(id) ON DELETE SET NULL,
  ADD CONSTRAINT chk_ee_effective_order CHECK (effective_to >= effective_from);

-- Drop old PK on employee_id (replaced by id surrogate)
ALTER TABLE employee_employment DROP CONSTRAINT employee_employment_pkey;

-- Existing probation_end_date stays in place (effective-dated together with the rest)
```

**Status semantics inside the satellite:**
- Same-day lifecycle transitions (Draft → Pending → Active during onboarding) update the **current slice's** `status` field in place. No new slice. The mirror on `employees.status` is updated atomically inside the RPC. Existing triggers (`sync_profile_on_employee_status`, `sync_everyone_on_employee_status_change`, `after_employee_role_sync`) keep firing on the mirror UPDATE as they do today.
- Different-day transitions (Active on date X → Inactive on date Y) create a **new slice** with `effective_from = Y` and `status = 'Inactive'`. Sync job picks this up on day Y and updates the master, firing the role-revocation chain.

**hire_date in the satellite:** the first slice's `hire_date` is the joining date. Corrections to hire_date (e.g., onboarding admin fixed it) update the current slice in place; the mirror updates atomically. Effective-dating hire_date is conceptually a "correction history" rather than a true timeline, but storing it uniformly avoids special-casing.

**Indexes** (`idx_ee_*` prefix, mirrors `idx_ep_*` for personal):

- `idx_ee_one_active_row` — partial UNIQUE on `(employee_id) WHERE effective_to = '9999-12-31' AND is_active = true`
- `idx_ee_employee_id` — plain FK lookup
- `idx_ee_employee_timeline` — `(employee_id, effective_from, effective_to)` for range queries
- `idx_ee_is_active` — partial `(employee_id, is_active) WHERE effective_to = '9999-12-31'`
- `idx_ee_manager_active` — partial `(manager_id) WHERE effective_to = '9999-12-31' AND is_active = true` — enables fast "who reports to X today" queries without touching legacy `employees.manager_id`

**RLS** mirrors `employee_personal` (Path A scope + Path B HR-guard for hire pipeline). Policy prefixes `ee_select / ee_insert / ee_update / ee_delete`.

### 4.2 No draft table

Per locked decision (matches actual personal-info practice): **no `employee_employment_draft` table is created.**

Employment and personal info both write directly to the satellite during the hire pipeline. The satellite is the **sole source of truth** for Draft/Incomplete/Pending employees — the `employees` base table is intentionally NOT mirrored during the hire pipeline (migs 460, 464). This prevents `employees.updated_at` from being stamped on every autosave, which was causing false-positive optimistic lock errors in the hire wizard.

The hire wizard writes one row to `employee_employment`:
- For a hire effective today: `effective_from = today`, satellite is written immediately; mirror to `employees` is deferred until activation
- For a future-dated hire: `effective_from = future hire_date`, row sits in the satellite; nightly sync activates it on the activation date

The `status` field starts as `'Draft'` on the initial row. As the hire workflow progresses (Draft → Pending → Active), the same slice's `status` is updated in place (not a new slice) since these transitions all happen on the same calendar day.

**On activation (`wf_activate_employee`):** a one-time mirror fires — employment fields, job relationship mirrors (pm01–om03), and name are all written to `employees` base atomically. After this point the employee is `Active`, so subsequent RPC calls mirror normally (Active/Inactive guard passes).

### 4.3 `employees` master — denormalized mirror cache

**All 10 fields stay on `employees`** as denormalized mirrors. The satellite (`employee_employment`) is the source of truth; the master mirror exists for backward compatibility with the existing JOIN-heavy codebase (RLS policies, target_groups, expense currency lookups, org chart queries — they all read `employees.dept_id` / `manager_id` / `status` / etc. directly today and rewriting every one of them is out of scope).

Mirror update mechanism — three paths, all gated on `status IN ('Active', 'Inactive')`:

| Path | When | What |
|---|---|---|
| **Immediate (RPC)** | `effective_from ≤ today` AND employee is Active/Inactive | `upsert_employment_info` step 10 mirrors inside the same transaction |
| **On activation** | `wf_activate_employee` fires (hire approved) | One-time mirror of employment satellite + job relationships + name → `employees` base |
| **Nightly (cron)** | 00:05 daily, `activate_effective_dated_records` | `_sync_employment_today` picks up future-dated slices whose `effective_from` has arrived; Active/Inactive employees only |

During hire pipeline (Draft/Incomplete/Pending/Rejected) the mirror is **suppressed entirely** — the satellite is sole source of truth. `mapEmployee` in the frontend reads employment fields from the satellite directly, so the hire wizard works correctly without the mirror.

**Guard trigger** `fn_guard_employee_employment_sync` (BEFORE UPDATE on `employees`) blocks direct UPDATE of any of the 10 mirror columns unless `current_setting('prowess.allow_employment_sync', true) = 'true'`. Bypass is set inside the RPC and the sync helper.

Bypass exception for the hire pipeline: when `OLD.status IN ('Draft','Incomplete','Pending')` the guard allows writes (so the `AddEmployee` wizard can still UPDATE the row mid-flow without going through the RPC). Once the employee is `Active`, only the RPC and the sync job can change these columns.

---

## 5. RPC Contracts

Mirror `upsert_personal_info` / `get_current_personal_info` / `get_personal_info_history` exactly.

### 5.1 `upsert_employment_info(p_employee_id uuid, p_proposed_data jsonb, p_effective_from date) RETURNS jsonb`

`SECURITY DEFINER`. Returns `{ok:true, employment_info_id:uuid}` or `{ok:false, error:text}`.

**Access guard — four paths:**
- HR: `user_can('employment','edit', p_employee_id)`
- ESS self: `p_employee_id = get_my_employee_id() AND has_permission('employment.edit')`
- Approver: pending `workflow_tasks` row exists for this caller + this `profile_employment` instance
- Sent-back: `workflow_instances.status='awaiting_clarification' AND submitted_by = auth.uid()`

**Validation:**
- `effective_from` not null; must be `< '9999-12-30'`
- `manager_id` (if changing): not equal to `p_employee_id` (self-FK guard); not in the transitive subordinate chain (cycle check — **NEW**, fixes today's gap)
- `dept_id` (if changing): exists in `departments`; not soft-deleted
- `work_location` (if changing): is a `LOCATION` picklist value whose `parent_value_id` matches the chosen `work_country`
- `end_date` (if changing): must be `>= hire_date`
- `base_currency_id` ignored as input — always derived from `work_country` (see §7)

**Effective-dating algorithm** — identical to personal info:
1. `SELECT … FOR UPDATE` the current open row; `v_is_amendment := FOUND`.
2. Overlap guard: reject if any closed historical row has `effective_to >= p_effective_from`.
3. If amendment AND `current.effective_from >= p_effective_from` → DELETE current (mig 288 pattern). Else → UPDATE current `effective_to = p_effective_from - 1 day`.
4. INSERT new slice with `COALESCE(p_proposed_data->>'field', v_current.field)` for every domain field (carry-forward).
5. **Auto-derive `base_currency_id`** from new `work_country` via `picklist_values[ID_COUNTRY].meta->>'currencyId'` → CURRENCY picklist → `currencies.id`. If derivation fails for the resolved country, return `{ok:false, error}`.
6. **Master sync** when `p_effective_from <= CURRENT_DATE`: `PERFORM set_config('prowess.allow_employment_sync', 'true', true)` then UPDATE the 8 mirror columns on `employees`. Future-dated rows defer to the nightly job.
7. **Manager role sync** when `manager_id` changed AND `p_effective_from <= CURRENT_DATE`: call `sync_system_roles(<new_manager_profile_id>)`. Closes the gap noted in §3.3.

### 5.2 `get_current_employment_info(p_employee_id uuid) RETURNS jsonb`

Returns the current open slice as JSONB with all 8 fields + audit metadata. Access: same as personal info's read (view/edit + ESS self + approver + sent-back + hire-pipeline view). Returns NULL on access denied.

### 5.3 `get_employment_info_history(p_employee_id uuid) RETURNS jsonb`

Returns `jsonb_agg(... ORDER BY effective_from DESC)` of all slices. Gated on `employment.history` OR `employment.edit`. Returns `'[]'::jsonb` on denial.

---

## 6. Sync Job — Shared Across All Effective-Dated Tables

One cron entry, four passes. Runs nightly at **00:05** via `pg_cron`.

### 6.1 Function structure

```
activate_effective_dated_records(p_as_of_date date)   ← top-level cron wrapper
  ├── _sync_personal_info_today(p_as_of_date)          pass 1 — name
  ├── _sync_employment_today(p_as_of_date)              pass 2 — 10 employment columns
  ├── _scan_end_date_inactive()                         pass 3 — end_date → Inactive flip
  └── _sync_job_relationships_today(p_as_of_date)      pass 4 — 6 job relationship columns
```

All four passes share the same discipline:
- **Active/Inactive employees only** — Draft/Incomplete/Pending/Rejected are skipped. Their satellites are authoritative; `employees` base is intentionally not mirrored during the hire pipeline.
- **Drift detection** — each pass only writes rows where satellite ≠ mirror (IS DISTINCT FROM). No-op runs are fast and cheap.
- **Per-row `BEGIN/EXCEPTION`** — one failure never aborts the others. Errors accumulate in the log.
- **One `job_run_log` row** covers all four passes per run.

### 6.2 Pass details

**Pass 1 — `_sync_personal_info_today`**
Syncs `employees.name` from `employee_personal` for Active/Inactive employees whose active slice covers `p_as_of_date` and whose name has drifted. Sets `prowess.allow_name_sync = 'true'` for the transaction.

**Pass 2 — `_sync_employment_today`**
Syncs all 10 employment mirror columns from `employee_employment` for Active/Inactive employees. On `manager_id` change, calls `sync_system_roles()`. On `status → Inactive`, existing trigger `sync_profile_on_employee_status` fires on the mirror UPDATE and revokes roles. Sets `prowess.allow_employment_sync = 'true'` for the transaction.

**Pass 3 — `_scan_end_date_inactive`** (locked §11.4 part C)
Finds Active employees whose `end_date ≤ today`. Flips the satellite slice `status → Inactive` in place, then mirrors to `employees`. The mirror UPDATE fires `sync_profile_on_employee_status` → roles revoked.

**Pass 4 — `_sync_job_relationships_today`**
Syncs all 6 pm/om mirror columns (`pm01_manager_id` … `om03_manager_id`) from `employee_job_relationship_set` + items for Active/Inactive employees. Uses a CTE to aggregate satellite values before the drift comparison (avoids non-aggregate column references in HAVING). Sets `prowess.allow_job_relationships_sync = 'true'` for the transaction.

### 6.3 `_scan_end_date_inactive()` body — the future-dated end_date scanner (locked §11.4 part C)

When an employee was set to terminate on a future date but their `status` is still `'Active'` (because no new slice was created with `status='Inactive'`), this scan flips them automatically once `end_date` has come due.

```sql
-- Pseudo:
FOR v_emp IN
  SELECT e.id, e.end_date, ee.id AS slice_id
  FROM   employees e
  JOIN   employee_employment ee ON ee.employee_id = e.id
                              AND ee.is_active = true
                              AND ee.effective_to = '9999-12-31'::date
  WHERE  e.status   = 'Active'
    AND  e.end_date IS NOT NULL
    AND  e.end_date <= CURRENT_DATE
LOOP
  BEGIN
    -- Update the slice's status in-place; mirror sync via guard bypass
    PERFORM set_config('prowess.allow_employment_sync', 'true', true);
    UPDATE employee_employment
       SET status = 'Inactive', updated_at = NOW()
     WHERE id = v_emp.slice_id;
    UPDATE employees
       SET status = 'Inactive', updated_at = NOW()
     WHERE id = v_emp.id;
    -- sync_profile_on_employee_status fires on the master update → revokes roles
    v_rows := v_rows + 1;
  EXCEPTION WHEN OTHERS THEN
    -- accumulate error
  END;
END LOOP;
```

Same per-row `BEGIN/EXCEPTION` discipline as the personal-info sync. One failure doesn't abort the rest.

### 6.3 Drift view

`vw_employment_drift` — joins Active employees to current `employee_employment` row; surfaces any row where any of the 8 mirror columns differ. Same shape as `vw_personal_name_drift`. Used by ops for self-healing reconciliation.

---

## 7. Forward Propagation Rules

Inside `upsert_employment_info`, lock these cascades server-side so they fire on every write path (workflow apply, admin edit, hire wizard, mid-flight `update_hire_field`):

| Field changed | Cascade | Justification |
|---|---|---|
| `work_country` | Auto-derive `base_currency_id` from `picklist_values[ID_COUNTRY].meta->>'currencyId'` chain. Reject save if derivation fails. | Fixes today's gap where currency goes stale outside `update_hire_field`. |
| `manager_id` | (1) Cycle check: walk the manager chain up to 10 hops; if `p_employee_id` appears upstream → `{ok: false, error: 'CYCLE_DETECTED', chain: […]}`. Frontend renders as **modal error** per §11.7. (2) On successful save: `sync_system_roles(<new_manager_profile_id>)` to grant the manager role to the new manager. | Closes today's "manager role not synced" gap; prevents cycles. |
| `dept_id` | `sync_single_target_group(<everyone>)` + invalidate per-dept target_groups (call `sync_target_group_members()`). | Department-scoped target groups need cache refresh. |
| `designation` | If any custom target_group's `filter_rules` matches on designation, kick `sync_target_group_members()`. | Custom-scoped permissions can depend on designation. |
| `work_location` | Same as `designation` (custom-scope filter sync). | Same logic. |
| `end_date` set with `effective_from ≤ today` AND `end_date ≤ today` AND `status = 'Active'` | **Part B of §11.4 locked:** the RPC also writes `status = 'Inactive'` into the same slice (no separate slice needed since the change is current). Mirror sync flips `employees.status`, which fires `sync_profile_on_employee_status` → roles revoked. | Same-day terminations close cleanly without an extra workflow. |
| `end_date` set with future date | Slice carries `end_date`. **Part C of §11.4** — the nightly `_scan_end_date_inactive()` flips `status = 'Inactive'` on the activation day. | Handles "set end_date to 31 Dec for someone leaving year-end" without requiring a follow-up workflow on that date. |
| `hire_date` change (correction) | Mirror sync updates `employees.hire_date`. If `hire_date` was used as the original `effective_from` seed of the slice, the slice keeps its existing `effective_from` (we don't rewrite history slices retroactively). Audit log captures the correction. | Hire-date corrections are rare; storing the correction history in the satellite plus audit log is sufficient. |
| `status` (Draft → Pending → Active during onboarding) | Same-slice in-place update. Mirror sync triggers existing role-grant and ESS-resync logic. | Lifecycle transitions are event-driven, not date-driven. |
| Any of the 10 fields | `audit_employees` trigger fires on the mirror UPDATE — audit log row written automatically via existing trigger. | No change needed. |

**All previously-implicit triggers continue to fire** on the mirror UPDATE path: `sync_profile_on_employee_status`, `sync_everyone_on_employee_status_change`, `after_employee_role_sync`. The model places ALL change paths through `upsert_employment_info` (or, during onboarding, direct writes under the guard bypass) — the triggers fire on the mirror update step at the end of the RPC, indistinguishable from today's direct-write behavior.

---

## 8. Workflow Integration

### 8.1 `submit_change_request` — add `profile_employment` snapshot branch

Mig 319 added a snapshot branch for `profile_personal`. Need an analogous one for `profile_employment`:

```sql
WHEN 'profile_employment' THEN
  SELECT to_jsonb(ee.*)
  INTO v_current_row
  FROM employee_employment ee
  WHERE ee.employee_id = v_emp_id
    AND ee.effective_to = '9999-12-31'::date
    AND ee.is_active    = true;
```

The existing filter-to-proposed-keys logic carries over unchanged.

### 8.2 `apply_profile_pending_change` — wire `profile_employment` branch

Currently no-op for `profile_employment`. Add:

```sql
ELSIF v_module = 'profile_employment' THEN
  v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
  v_result := upsert_employment_info(v_emp_id, v_data, v_eff_from);
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE WARNING 'apply_profile_pending_change: upsert_employment_info failed for employee=%, error=%',
      v_emp_id, v_result->>'error';
  END IF;
```

### 8.3 `EmploymentEnrichment` component (new) — replaces generic fallback in ApproverInbox

Today `profile_employment` falls through to the generic `ProfileEnrichment` grid showing raw UUIDs and snake_case labels. Build a dedicated component mirroring `DependentsEnrichment` / `BankEnrichment`:

- FK-aware resolution: designation → picklist label; dept_id → department name; manager_id → employee name lookup; work_country → country label; work_location → location label; base_currency_id → currency code; end_date → date format
- Edit-mode inputs: picklist selects for designation/country, parent-filtered select for location, department typeahead, manager search, date picker for end_date, currency derived/read-only
- Manager search: reuse existing employee typeahead pattern from ApproverInbox reassign flow
- Per-field diff badge: highlight changed fields in amend mode (mirror existing wfi-profile-grid pattern with `was:` strikethrough)

Required dictionary additions in `ApproverInbox.tsx`:

```ts
PROFILE_FIELD_LABELS['employment'] = {
  designation:      'Designation',
  job_title:        'Job Title',
  dept_id:          'Department',
  manager_id:       'Reports To',
  end_date:         'End Date',
  work_country:     'Work Country',
  work_location:    'Work Location',
  base_currency_id: 'Base Currency',
};
PROFILE_DATE_FIELDS.add('end_date');                         // hire_date stays on employees, not here
PROFILE_PICKLIST_FIELDS['profile_employment'] = {
  designation:   'DESIGNATION',
  work_country:  'ID_COUNTRY',
  work_location: 'LOCATION',
};
```

### 8.4 `wf_approver_update_pending_changes` — already supports this

The existing approver mid-flight edit RPC overwrites `proposed_data` JSONB. Frontend just needs to send the full diff in the same shape. No backend change.

### 8.5 `WorkflowReview` full-page surface

Today `FULL_REVIEW_MODULES` restricts WorkflowReview to expense + hire. `profile_employment` doesn't reach the full-page view. **Open decision** (§11.5) — add it to the allowlist or keep it inbox-only.

---

## 9. UI Changes

### 9.1 `MyProfile/index.tsx` — promote Employment to editable

- Currently: read-only section, line 1560–1585.
- New: Edit button (gated on `employment.edit` permission + `pendingCount['profile_employment'] === 0`)
- Form fields: designation (picklist), job_title (text), dept_id (department select), manager_id (employee typeahead), end_date (date), work_country (picklist), work_location (parent-filtered picklist), base_currency_id (read-only, auto-derived display)
- Save → `submit_change_request('profile_employment', { effective_from, designation, …field changes… })`. Pattern matches existing personal_info save flow exactly.
- `effective_from` snap: same as personal_info — date input with default = `today`, validation reject past hire_date, format hint "Applied from {date}"

### 9.2 `AddEmployee.tsx` — write to draft table instead of `employees`

- Hire wizard's Employment section currently writes the 8 fields to `employees` (lines 823–836). New: write to `employee_employment_draft` keyed by the new `employees.id`
- On `wf_activate_employee`: trigger consumes the draft row → seeds first `employee_employment` slice with `effective_from = hire_date` → deletes draft
- Backward compat: if draft row missing on activate (e.g. partial hire from before this change), fall back to reading the 8 fields from `employees` and seeding the slice from there

### 9.3 `EmployeeEditPanel.tsx` — admin section save routes to `upsert_employment_info`

- Currently lines 513–530 do a direct UPDATE on `employees`. New: call `upsert_employment_info(employee_id, { …8 fields }, today)`
- Admin gets the same effective-dated semantics as a workflow-approved change (immediate apply since admin bypasses workflow)
- `is_super_admin()` and HR with `employment.edit` keep their existing access via the RPC's access guard

### 9.4 `EmployeeDetails.tsx` — read paths use mirror, history link added

- List view (lines 415–417) keeps reading from `employees.*` mirrors — no change, the mirror is kept in sync
- Add "Employment History" link on the employee detail row → opens a panel showing `get_employment_info_history(employee_id)` as a timeline (effective_from, effective_to, summary of values per slice)

### 9.5 Frontend RPCs to add to a hooks layer (recommended)

- `useEmploymentSection(employeeId)` — wraps `get_current_employment_info` + `get_employment_info_history` for MyProfile/EmployeeEditPanel reuse
- `submitEmploymentChange(employeeId, fields, effective_from)` — thin wrapper around `submit_change_request('profile_employment', …)`

---

## 10. Backfill Algorithm

Backfill EVERY employee (not just Active) so the satellite is the complete source of truth from day one.

Per employee in `employees`:

1. Skip if `employee_employment` already has an active row for them (idempotency)
2. Read all 10 fields from `employees` master
3. Insert one slice into `employee_employment`:
   - **`effective_from = hire_date`** (locked per user; fall back to `COALESCE(created_at::date, '2000-01-01')` only if `hire_date IS NULL`, which should be vanishingly rare since `validate_hire_fields` enforces it on activation)
   - `effective_to = '9999-12-31'`
   - `is_active = true`
   - All 10 fields (`designation`, `job_title`, `dept_id`, `manager_id`, `hire_date`, `end_date`, `work_country`, `work_location`, `base_currency_id`, `status`) copied from `employees`
   - `created_by = NULL` (system-backfilled)
4. Validation queries:
   - Count of employees in master == count of slices created (after skip)
   - Every employee with `hire_date IS NOT NULL` has matching `effective_from = hire_date`
   - No employee has more than one open slice (partial unique index enforces this anyway)
   - For each Active employee, the satellite slice's `status = 'Active'` (no mismatch)

`probation_end_date` already on the satellite — preserved in place by the column additions (not overwritten by backfill).

If validation fails, the whole migration aborts in transaction → DB rolls back to pre-state. Legacy `employees.*` columns are not touched by backfill (they ARE the source we read from) and remain functional during the migration window.

**No draft table backfill** (since no draft table exists per §4.2).

---

## 11. Decisions (formerly open — all locked 2026-05-29)

### 11.1 Fields to effective-date — LOCKED

**All 10 fields move to `employee_employment`** and sync back to `employees` master as a denormalized mirror cache:

| Field | Effective-dated? | Notes |
|---|---|---|
| designation | ✓ | DESIGNATION picklist UUID |
| job_title | ✓ | Free-form text; see §11.2 |
| dept_id | ✓ | FK to departments |
| manager_id | ✓ | Self-FK; cycle check in RPC |
| hire_date | ✓ | Seeds the first slice's `effective_from`; corrections via in-place update |
| end_date | ✓ | Termination date; drives §11.4 |
| work_country | ✓ | ID_COUNTRY picklist UUID |
| work_location | ✓ | LOCATION picklist UUID (parent-filtered by work_country) |
| base_currency_id | ✓ | FK to currencies; auto-derived from work_country |
| status | ✓ | ENUM; same-day transitions update slice in place |

### 11.2 `job_title` — KEEP (locked after reference scan)

User initially asked "drop it", contingent on reference check. The check surfaced **30+ files** consuming `employees.job_title` as the display subtitle under person names across the workflow UI:

- `ApproverInbox.tsx` — assignee reassign typeahead (lines 371, 393)
- `WorkflowOperations.tsx` — bulk-reassign panel + selected-person card (8 distinct references)
- `WorkflowSubmitModal.tsx` — participants list (line 336)
- `WorkflowParticipantsModal.tsx` — member rows (line 210)
- `WorkflowDelegations.tsx` — delegate picker (line 235)
- `WorkflowReview.tsx` — participants embed query (line 162)
- `WorkflowActions.tsx` — assignee resolution
- `WorkflowPerformanceDashboard.tsx` — assignee card subtitle (3 references)
- `useEmployees.ts` — common employee hook
- `database.types.ts` — 5 generated type references (regenerates from schema, so drop would propagate)

Dropping `job_title` requires migrating every one of those reads to:
- Either query `designation` (a picklist UUID) and resolve label client-side per row — expensive at list scale
- Or join through a denormalized "display_title" view — added complexity for marginal gain

**Locked decision: keep `job_title` in the satellite as a free-form column.** Auto-populate it from the resolved DESIGNATION picklist label when the user leaves it blank (computed in `upsert_employment_info`); allow user override for things like "Senior Engineer — Platform". This way:
- All existing 30+ reads continue to work unchanged
- Users get a meaningful default rather than a NULL display
- The "drop it" goal can revisit in a future cleanup phase if the team decides the UX cost of migrating reads is worthwhile

### 11.3 Master mirror policy — LOCKED (expanded explanation)

The choice is between two architectures:

**Option A — Mirror on `employees` (locked).** All 10 fields stay as columns on the master `employees` table, kept in sync from the satellite by the RPC + nightly job. The satellite is the source of truth; the mirror is a denormalized cache for backward-compat. Pro: zero code migration outside the new RPC. Existing JOINs on `employees.dept_id` / `manager_id` / `status` / etc. continue to work — that's RLS policies, target_group filters, expense currency lookups, org chart queries, every audit trail, every report query. Con: drift risk (mitigated by `vw_employment_drift` view + guard trigger + `audit_employees` capturing every mirror UPDATE).

**Option B — Pure satellite (rejected).** Drop the 10 columns from `employees`; every consumer must JOIN `employee_employment WHERE effective_to='9999-12-31'` to read current values. Pro: single source of truth, no drift possible. Con: touches every RLS policy, every target_group filter rule, every list query, every report, every analytics dashboard. The codebase has dozens of `employees.dept_id` reads in RLS alone — migrating all of them is a multi-week refactor with high regression risk.

We're picking A because the cost/benefit of B isn't justified for a Phase 1 migration. The mirror approach lets us ship effective-dating with a small surface change while leaving the door open to a future "drop mirror columns" cleanup once we've validated the satellite works.

**Drift protection** has three layers:
1. **Write discipline**: the only legitimate path that updates the 10 mirror columns is `upsert_employment_info`, the sync job, or hire-pipeline writes (under guard bypass). `fn_guard_employee_employment_sync` BEFORE UPDATE trigger rejects ad-hoc writes.
2. **Audit visibility**: every mirror UPDATE goes through the existing `audit_employees` trigger → `employee_audit_log` captures who/what/when.
3. **Reconciliation**: `vw_employment_drift` view surfaces any row where any of the 10 mirror columns differ from the current open slice. Ops can re-run `_sync_employment_today()` to heal.

### 11.4 `end_date` → status flip — LOCKED (both B and C)

- **Part B (synchronous)**: inside `upsert_employment_info`, if `end_date` resolves to `<= CURRENT_DATE` AND `status = 'Active'`, the same slice writes `status = 'Inactive'`. Mirror sync fires the existing role-revoke chain.
- **Part C (nightly scan)**: `_scan_end_date_inactive()` runs daily as part of `activate_effective_dated_records()`. For every Active employee whose mirror `end_date` is now in the past, the slice's status is flipped to `Inactive`, mirror updates, role-revoke fires.

Part C is needed because Part B only covers same-day terminations. When a user sets a **future** `end_date` (e.g., "leaving on 31 Dec"), the slice sits in the satellite with status still `Active`. On 31 Dec, the scanner activates the inactivation.

### 11.5 `profile_employment` in WorkflowReview — LOCKED (add to allowlist)

Add `'profile_employment'` to `FULL_REVIEW_MODULES` in `WorkflowReview.tsx`. The full-page approver surface should render the same `EmploymentEnrichment` component used in the inbox panel (consistency with how `expense_reports` and `employee_hire` are handled).

### 11.6 Admin direct-write via `EmployeeEditPanel` — LOCKED (yes)

Admin edits go direct through `upsert_employment_info` without staging a workflow. The RPC's access guard handles authorization (HR has `employment.edit`; super-admin bypasses). The same audit-log capture applies. Admin is the workflow's escape hatch — same model as today.

### 11.7 Manager cycle check + error UX — LOCKED

`upsert_employment_info` walks the proposed `manager_id`'s manager chain up to 10 hops. If `p_employee_id` appears anywhere upstream, the RPC returns:

```json
{
  "ok": false,
  "error": "CYCLE_DETECTED",
  "message": "Assigning {newManager} as manager would create a reporting cycle.",
  "chain": ["EMP-0042", "EMP-0017", "EMP-0042"]
}
```

**Frontend renders this as a modal dialog** (not an inline error). The modal title is "Reporting cycle detected", body shows the chain visualisation (`EMP-0042 → EMP-0017 → EMP-0042`), and a single "Got it" button dismisses. The user has to pick a different manager. The same modal renders whether the call originated from MyProfile (ESS edit), EmployeeEditPanel (admin save), AddEmployee (hire wizard manager pick), or `wf_approver_update_pending_changes` (approver mid-flight edit).

### 11.8 `employment.history` permission — LOCKED (yes, add)

Seed `employment.history` action in the permissions catalog. Used to gate the history panel in `EmployeeDetails.tsx` and the history dropdown in MyProfile. The existing `employment.view` permission only gates current-slice reads; history is a separate concern.

---

## 12. Risk Register

| Risk | Mitigation |
|---|---|
| Mirror drift between `employees` and `employee_employment` | `vw_employment_drift` view for ops; reconciliation tooling; `fn_guard_employee_employment_sync` blocks ad-hoc UPDATEs on Active employees outside the bypass flag |
| Sync job failure on one row stops all syncs | Per-row BEGIN/EXCEPTION blocks (matches personal-info pattern). Errors accumulate into `job_run_log.message`. |
| Backfill miscalculates `effective_from` for employees with NULL `hire_date` | Fallback chain `hire_date → created_at::date → '2000-01-01'`. Validation checks that every backfilled slice has a non-null `effective_from` before commit. |
| `EmployeeEditPanel` admin save breaks because the guard trigger blocks their UPDATE | All admin saves route through `upsert_employment_info` (which sets the bypass flag). The direct-UPDATE path at lines 513–530 of `EmployeeEditPanel.tsx` is rewritten in Phase 9. |
| Manager cycle check is expensive on deep org trees | Cap at 10 hops; partial unique index `idx_ee_manager_active` enables fast chain walks; if the chain exceeds 10 hops, the check assumes no cycle and lets the save through (graceful degradation). |
| Backward compat for in-flight `profile_employment` workflows from before cutover | Pre-cutover the module is a stub (no satellite, no current_data snapshot); no real in-flight workflows exist to migrate. |
| Currency derivation fails for a newly-added country with no `meta.currencyId` | Validation surface — `upsert_employment_info` returns `{ok: false, error: 'CURRENCY_DERIVATION_FAILED', country: <iso>}`. Frontend renders as the same modal pattern as cycle detection. |
| Same-day Draft → Pending → Active transitions trample each other if two writes race | Advisory lock per `employee_id` inside `upsert_employment_info` (mirrors the personal-info FOR UPDATE pattern). Concurrent writes serialize cleanly. |
| Future-dated end_date scan misses someone (job fails, holiday window, etc.) | Drift view surfaces "status=Active, end_date in past" rows. Manual re-trigger via `SELECT _scan_end_date_inactive()` is safe and idempotent. |
| `job_title` auto-population from designation can produce stale display labels if user later updates designation but had previously customized job_title | If `job_title` was last changed by the user (tracked via a `_user_overridden` flag, OR by detecting non-equality with the resolved designation label at the time of write), preserve their override; otherwise auto-update on designation change. **Implementation note for Phase 2 RPCs.** |
| Hire pipeline (Draft/Incomplete/Pending) writes still need to mutate the row | Guard trigger bypasses for non-Active statuses (Draft/Incomplete/Pending). The `AddEmployee` wizard keeps doing direct INSERT/UPDATE on the satellite + mirror without going through the RPC during onboarding. RPC takes over once status flips to Active. |

---

## 13. Phases & Sequencing

| Phase | Work | Migrations | Status |
|---|---|---|---|
| 0 | All decisions LOCKED (this doc) | — | ✅ Done |
| 1 | Schema: expand `employee_employment` + guard trigger | `mig 351` | ✅ Done |
| 2 | RPCs: `upsert_employment_info` + reads + currency + cycle check | `mig 352` | ✅ Done |
| 3 | Shared sync job: `activate_effective_dated_records` + end_date scanner | `mig 353` | ✅ Done |
| 4 | Workflow apply branch + `submit_change_request` snapshot | `mig 354` | ✅ Done |
| 5 | Backfill 10 fields for every employee | `mig 355` | ✅ Done (21 skipped — already had slices) |
| 6 | Frontend MyProfile edit form + cycle modal | `MyProfile/index.tsx` | ✅ Done |
| 7 | EmploymentEnrichment + ApproverInbox dictionary | `ApproverInbox.tsx` | ✅ Done |
| 8 | AddEmployee writes to `employee_employment`; `wf_activate_employee` patch | `AddEmployee.tsx`, `mig 356` | ✅ Done |
| 9 | EmployeeEditPanel admin save → `upsert_employment_info` | `EmployeeEditPanel.tsx` | ✅ Done |
| 10 | EmployeeDetails history panel + WorkflowReview allowlist | `EmployeeDetails.tsx`, `ApproverInbox.tsx` | ✅ Done |
| 11 | Cleanup: strip employment fields from `corePayload`/`dbPayload`; mark doc complete | `AddEmployee.tsx` | ✅ Done |

**All phases complete. Shipped 2026-05-30.**

---

## 14. Migration File Numbering

Per `[[prowess-set-snapshot-rewrite]]` memory: next free slot is `20260529324`. The set-snapshot rewrite is using 320–323; this employment work continues at 324+. Watch out for the user's parallel work (bank cleanups at 301–305, personal_info at 315–319) — those slots are taken.

For any new migration in this design: use `20260529324` or higher.

---

## 15. Surfaces Touched (Files Inventory)

**Backend (migrations):**
- 5 new migrations (schema, RPCs, sync, apply, backfill)
- Touches: `apply_profile_pending_change`, `submit_change_request`, `activate_personal_info_records` (rename), `cron.schedule` (reschedule)

**Frontend:**
- `src/components/employee/MyProfile/index.tsx` — Employment section editable
- `src/components/admin/AddEmployee.tsx` — draft table write path
- `src/components/admin/EmployeeEditPanel.tsx` — RPC-based section save
- `src/components/admin/EmployeeDetails.tsx` — history panel link
- `src/workflow/screens/ApproverInbox.tsx` — EmploymentEnrichment component + dictionary entries
- `src/workflow/screens/WorkflowReview.tsx` — optional FULL_REVIEW_MODULES extension (§11.5)
- `src/workflow/hooks/useProfileWorkflowGates.ts` — already lists `profile_employment` (no change)
- New: `src/components/employee/hooks/useEmploymentSection.ts` (recommended)

**Docs:**
- This file (`docs/employment-effective-dating-design.md`)
- After implementation: update `prowess_system_docs.html` Parts 2 (Detailed Field Schema), 7 (Migration Milestone Summary)
