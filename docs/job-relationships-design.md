# Job Relationships (Matrix Managers) — Design Spec

**Status:** Locked design, pre-implementation
**Scope:** Introduce a SuccessFactors-style Job Relationships portlet capturing up to 6 matrix-manager assignments per employee (codes PM01–OM03), effective-dated using the set-snapshot pattern. The six master columns mirror onto `employees` and are available as a new workflow approver type.
**Author:** 2026-05-29 design session
**Reference templates:** `docs/employment-effective-dating-design.md`, `docs/set-snapshot-design.md` (both shipped or in-flight).

---

## 1. Decision Summary

All decisions locked.

| Topic | Decision |
|---|---|
| Data shape | Set-snapshot pattern (parent effective-dated set + per-code item children). Matches dependents/bank model. |
| Codes | Six fixed codes: `PM01`, `PM02`, `PM03`, `OM01`, `OM02`, `OM03`. Seeded in `JOB_RELATIONSHIP_TYPE` picklist; admin edits labels only, never codes. |
| Master mirror columns | Six new nullable UUID columns on `employees`: `pm01_manager_id`, `pm02_manager_id`, `pm03_manager_id`, `om01_manager_id`, `om02_manager_id`, `om03_manager_id`. |
| Cycle check | None. Self-assignment blocked by CHECK constraint (`manager_employee_id <> employee_id`). Matrix relationships are non-hierarchical — two people can mutually be each other's PM01. |
| Assignee validation (write time) | Manager must be `status = 'Active'`. Rejected at RPC if Inactive. |
| Workflow routing (read time) | If the relevant manager is Inactive OR `NULL`, the workflow step is **skipped silently**. A `workflow_action_log` row is emitted ("step skipped: matrix manager unassigned / inactive") for forensics. |
| Auto-clear on deactivation | When an employee is set to Inactive, fanout creates new sets for every dependent-employee whose matrix manager pointed at the deactivated person. Old reference removed. |
| Deactivation UX warning | **The person performing the deactivation** sees a modal listing every employee where this person is currently a matrix manager. HR confirms before the deactivation proceeds. |
| Auto-close `effective_from` | **Today (the deactivation observation day).** Old set's `effective_to = today - 1`; new set's `effective_from = today`. |
| Re-activation | **Never auto-restore.** Once severed, HR re-assigns manually via the portlet. |
| Fanout failure handling | Per-employee `BEGIN/EXCEPTION` blocks. One failure doesn't block Alice's status flip. Errors logged; drift view surfaces inconsistencies for manual repair. |
| Workflow approver type | New type `JOB_RELATIONSHIP`. `workflow_steps.relationship_code` (TEXT, nullable) carries which code to resolve. All 6 codes usable. |
| Effective-from rule | Any date, default today. No 1st-of-month snap, no submission/approval cutoffs. |
| ESS visibility | Read-only in `MyProfile`. Edits gated to HR/admin via `job_relationships.edit`. |
| Hire wizard integration | Post-activation only. The Add Employee wizard does not collect matrix relationships. |
| Permissions | `job_relationships.view`, `.edit`, `.history`, **`.bulk_import`**, **`.bulk_export`** (mig 329 seed). |
| Audit | Existing `audit_employees` trigger on mirror UPDATE captures all changes. No new audit work. |
| Backfill | None — net-new feature. |
| Bulk operations | Plugged into the cross-module Bulk Operations Framework (see §16). Registered in `bulk_template_registry` with processor RPC `upsert_job_relationship_set()`. Workflow always bypassed for bulk. |

---

## 2. Why This Change

Matrix organisations need multiple reporting lines beyond the direct manager. SuccessFactors Employee Central solves this via its Job Relationships entity — effective-dated, multi-typed, queryable as a workflow approver target. Prowess today has only a single `manager_id` on `employees`, which forces workarounds whenever an approval needs to route to anyone other than the direct line manager (project lead, practice manager, operations head).

Adding the 6 fixed codes lets the org configure workflows like "approval routes to MANAGER → PM01 → OM01" without engineering changes per workflow template. Admins manage which labels map to which codes; the codes themselves never change.

---

## 3. Schema Design

### 3.1 `employee_job_relationship_set` — effective-dated parent

```sql
CREATE TABLE employee_job_relationship_set (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  effective_from  DATE NOT NULL,
  effective_to    DATE NOT NULL DEFAULT '9999-12-31'::date,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  created_by      UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_by      UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_ejrs_effective_order CHECK (effective_to >= effective_from)
);

-- One active set per employee (DB-level enforcement of "one in-flight active config")
CREATE UNIQUE INDEX idx_ejrs_one_active
  ON employee_job_relationship_set (employee_id)
  WHERE is_active = true AND effective_to = '9999-12-31';

CREATE INDEX idx_ejrs_employee_timeline
  ON employee_job_relationship_set (employee_id, effective_from, effective_to);
```

### 3.2 `employee_job_relationship_item` — children of one snapshot

```sql
CREATE TABLE employee_job_relationship_item (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  set_id                UUID NOT NULL REFERENCES employee_job_relationship_set(id) ON DELETE CASCADE,
  relationship_code     TEXT NOT NULL,                          -- ref_id from JOB_RELATIONSHIP_TYPE picklist
  manager_employee_id   UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One item per code per set (SF semantics: 1:1 per type)
CREATE UNIQUE INDEX idx_ejri_one_code_per_set
  ON employee_job_relationship_item (set_id, relationship_code);

-- Reverse lookup: "who has Alice as a matrix manager?" — needed by deactivation fanout
CREATE INDEX idx_ejri_manager_lookup
  ON employee_job_relationship_item (manager_employee_id);

-- Validate codes against the picklist at write time inside the RPC
-- (Cannot enforce via CHECK since picklist is data-driven, not enum)
```

`ON DELETE RESTRICT` on `manager_employee_id` is deliberate — we don't want a cascading DELETE on `employees` to silently invalidate matrix relationships. Deactivation should go through the trigger fanout, not raw DELETE.

### 3.3 `employees` master — 6 new mirror columns

```sql
ALTER TABLE employees
  ADD COLUMN pm01_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN pm02_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN pm03_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN om01_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN om02_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN om03_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
  ADD CONSTRAINT chk_pm01_not_self CHECK (pm01_manager_id IS NULL OR pm01_manager_id <> id),
  ADD CONSTRAINT chk_pm02_not_self CHECK (pm02_manager_id IS NULL OR pm02_manager_id <> id),
  ADD CONSTRAINT chk_pm03_not_self CHECK (pm03_manager_id IS NULL OR pm03_manager_id <> id),
  ADD CONSTRAINT chk_om01_not_self CHECK (om01_manager_id IS NULL OR om01_manager_id <> id),
  ADD CONSTRAINT chk_om02_not_self CHECK (om02_manager_id IS NULL OR om02_manager_id <> id),
  ADD CONSTRAINT chk_om03_not_self CHECK (om03_manager_id IS NULL OR om03_manager_id <> id);

-- Partial indexes for the workflow-resolve hot path (only ~10% of rows have these set)
CREATE INDEX idx_emp_pm01 ON employees(pm01_manager_id) WHERE pm01_manager_id IS NOT NULL;
CREATE INDEX idx_emp_pm02 ON employees(pm02_manager_id) WHERE pm02_manager_id IS NOT NULL;
CREATE INDEX idx_emp_pm03 ON employees(pm03_manager_id) WHERE pm03_manager_id IS NOT NULL;
CREATE INDEX idx_emp_om01 ON employees(om01_manager_id) WHERE om01_manager_id IS NOT NULL;
CREATE INDEX idx_emp_om02 ON employees(om02_manager_id) WHERE om02_manager_id IS NOT NULL;
CREATE INDEX idx_emp_om03 ON employees(om03_manager_id) WHERE om03_manager_id IS NOT NULL;
```

Mirror columns are source-of-truth-by-cache: the satellite is canonical, the mirror is denormalized for workflow performance and existing-query compatibility.

**Mirror update mechanism — three paths:**

| Path | When | What |
|---|---|---|
| **Immediate (RPC)** | `effective_from ≤ today` AND most-recent set | `fn_apply_job_relationship_set_transition` calls `sync_job_relationship_mirrors(employee_id, set_id)` inside the same transaction |
| **On activation** | `wf_activate_employee` fires | Mirrors the current open-ended set if `effective_from ≤ today` — ensures newly activated employees have correct pm01–om03 immediately |
| **Nightly (cron)** | 00:05 daily, pass 4 of `activate_effective_dated_records` | `_sync_job_relationships_today` picks up future-dated sets whose `effective_from` has arrived; Active/Inactive employees only |

`sync_job_relationship_mirrors(p_employee_id uuid, p_set_id uuid)` is the shared helper used by both the immediate RPC path and (for consistency) the activation path. It reads PM01–OM03 items from the given set and writes the 6 columns to `employees` in one UPDATE.

### 3.4 Picklist seed

```sql
-- Mig 329:
INSERT INTO picklists (picklist_id, label, parent_picklist_id)
VALUES ('JOB_RELATIONSHIP_TYPE', 'Job Relationship Type', NULL);

INSERT INTO picklist_values (picklist_id, ref_id, value, sort_order, active) VALUES
  ('JOB_RELATIONSHIP_TYPE', 'PM01', 'Project Manager',         1, true),
  ('JOB_RELATIONSHIP_TYPE', 'PM02', 'Programme Manager',       2, true),
  ('JOB_RELATIONSHIP_TYPE', 'PM03', 'Practice Manager',        3, true),
  ('JOB_RELATIONSHIP_TYPE', 'OM01', 'Operations Manager',      4, true),
  ('JOB_RELATIONSHIP_TYPE', 'OM02', 'Operations Lead',         5, true),
  ('JOB_RELATIONSHIP_TYPE', 'OM03', 'Operations Coordinator',  6, true);
```

Codes are seeded once. Admin can edit `value` (label) and `active` flag via the picklist management UI, but `ref_id` is immutable — that's what the 6 master columns and workflow steps reference.

### 3.5 RLS

Same dual-path as dependents/employment:
- **Path A (scoped)**: `user_can('job_relationships', '<action>', employee_id)`
- **Path B (HR pipeline)**: `user_can('job_relationships', '<action>', NULL)` AND `user_can('hire_employee', '<view|edit>', NULL)` AND `employees.status IN ('Draft','Incomplete','Pending')`

Policy prefix: `ejr_select / ejr_insert / ejr_update / ejr_delete` on both tables.

---

## 4. RPC Contracts

Mirror `upsert_employment_info` style.

### 4.1 `upsert_job_relationship_set(p_employee_id uuid, p_effective_from date, p_items jsonb) RETURNS jsonb`

`SECURITY DEFINER`. Dual-path: PATH A direct write, PATH B workflow staging.

**`p_items` shape:**
```json
[
  { "relationship_code": "PM01", "manager_employee_id": "<uuid>" },
  { "relationship_code": "OM02", "manager_employee_id": "<uuid>" }
]
```
Items can include 0–6 entries. Omitting a code from the array = "no assignment for that code in this set" (or "remove the assignment if it existed in the previous set").

**Returns:**
- PATH A: `{ ok: true, workflow: false, set_id, effective_from }`
- PATH B: `{ ok: true, workflow: true, instance_id, pending_change_id }`
- Errors: `{ ok: false, error: '<code>', message: '<human-readable>' }`

**Validation:**
- Each `relationship_code` exists in `JOB_RELATIONSHIP_TYPE` picklist AND `active=true`
- `manager_employee_id` is an Active employee (`status = 'Active'`)
- `manager_employee_id <> p_employee_id` (no self-assignment)
- No duplicate `relationship_code` within `p_items` array
- `effective_from` not in the past beyond a closed historical slice's range (overlap guard)

**Effective-dating algorithm:**
1. `SELECT … FOR UPDATE` the current open set
2. If amendment AND `current.effective_from >= p_effective_from` → DELETE current (mig 288 pattern); else UPDATE its `effective_to = p_effective_from - 1`
3. INSERT new set with `effective_from = p_effective_from`
4. INSERT items per `p_items`
5. **Mirror sync** when `p_effective_from <= CURRENT_DATE` AND this is the most-recent set: call `sync_job_relationship_mirrors(p_employee_id, new_set_id)`. This sets `prowess.allow_job_relationships_sync = 'true'` and UPDATEs all 6 mirror columns atomically. Future-dated sets defer to the nightly `_sync_job_relationships_today` pass.

### 4.2 `get_current_job_relationships(p_employee_id uuid) RETURNS jsonb`

Returns the active set + items as JSONB. Access guard mirrors dependents read. Returns `{ ok: true, set: null, items: [] }` when no set exists.

### 4.3 `get_job_relationships_history(p_employee_id uuid) RETURNS jsonb`

All sets reverse-chronologically. Gated on `job_relationships.history` OR `.view`.

### 4.4 `get_deactivation_impact(p_employee_id uuid) RETURNS jsonb`

**New RPC** powering the deactivation-time modal. Returns the list of OTHER employees where `p_employee_id` is currently a matrix manager, plus which code(s):

```json
{
  "ok": true,
  "affected_employees": [
    { "employee_id": "<uuid>", "employee_code": "EMP-0042", "name": "Bob Singh",
      "codes_held": ["PM01", "OM02"] },
    { "employee_id": "<uuid>", "employee_code": "EMP-0099", "name": "Carol Patel",
      "codes_held": ["PM01"] }
  ],
  "total": 50
}
```

Read by HR's "Deactivate Employee" confirmation dialog before the deactivation is submitted.

---

## 5. Workflow Engine Integration

### 5.1 New approver type `JOB_RELATIONSHIP`

```sql
-- Mig 330: add column + extend type check
ALTER TABLE workflow_steps
  ADD COLUMN relationship_code TEXT NULL;

-- Update wf_resolve_approver_ex to handle new type
-- Pseudocode:
WHEN 'JOB_RELATIONSHIP' THEN
  -- Submitter's matrix manager for the given code
  SELECT
    CASE p_step.relationship_code
      WHEN 'PM01' THEN e.pm01_manager_id
      WHEN 'PM02' THEN e.pm02_manager_id
      WHEN 'PM03' THEN e.pm03_manager_id
      WHEN 'OM01' THEN e.om01_manager_id
      WHEN 'OM02' THEN e.om02_manager_id
      WHEN 'OM03' THEN e.om03_manager_id
    END
  INTO v_target_employee_id
  FROM employees e
  WHERE e.id = (
    SELECT employee_id FROM profiles WHERE id = p_submitter
  );

  IF v_target_employee_id IS NULL THEN
    -- SKIP: no matrix manager assigned for this code
    INSERT INTO workflow_action_log (instance_id, action, notes, …)
    VALUES (p_instance_id, 'step_skipped',
            format('JOB_RELATIONSHIP step skipped: %s unassigned for submitter',
                   p_step.relationship_code), …);
    RETURN NULL;
  END IF;

  -- Check Active status at read time
  IF NOT EXISTS (SELECT 1 FROM employees WHERE id = v_target_employee_id AND status = 'Active') THEN
    INSERT INTO workflow_action_log (instance_id, action, notes, …)
    VALUES (p_instance_id, 'step_skipped',
            format('JOB_RELATIONSHIP step skipped: %s manager inactive',
                   p_step.relationship_code), …);
    RETURN NULL;
  END IF;

  -- Resolve to profile_id
  SELECT id INTO v_approver_profile_id FROM profiles WHERE employee_id = v_target_employee_id;
  RETURN v_approver_profile_id;
```

Returning `NULL` from the resolver tells the workflow engine to skip the step. The engine already supports skipped steps for the existing `remove_duplicate_approver` and `skip_duplicate_approver` paths (migs 163–164) — reuse that machinery.

### 5.2 Workflow designer UI

`WorkflowTemplates.tsx` step editor:
- "Approver Type" dropdown adds **Job Relationship** option
- When selected, a second dropdown appears: "Which Relationship Code?" populated from `JOB_RELATIONSHIP_TYPE` picklist active values (so labels match what admin configured)
- Saved into `workflow_steps.relationship_code`

### 5.3 Routing example (the user-cited scenario)

A leave-request workflow template:
- Step 1: `approver_type = MANAGER` → resolves to direct line manager (from employment portlet)
- Step 2: `approver_type = JOB_RELATIONSHIP`, `relationship_code = 'PM01'` → resolves to PM01 matrix manager (from job-relationships portlet)

Submitter raises a leave request:
- Step 1 fires task to direct manager
- On approval, Step 2 resolves PM01:
  - If submitter has PM01 assigned + Active → task fires to that person
  - If unassigned → log skipped, advance to Step 3 (if any) or complete the instance
  - If assigned but Inactive → log skipped, same behaviour

---

## 6. Deactivation Fanout — Trigger Extension

### 6.1 Extension to `sync_profile_on_employee_status`

The existing trigger (mig 148) fires on `UPDATE OF status ON employees`. Add a new pass at the end:

```sql
-- Pseudocode added to sync_profile_on_employee_status:
IF NEW.status = 'Inactive' AND OLD.status <> 'Inactive' THEN

  -- Set the bypass flag so we can update mirror columns of OTHER employees
  PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

  -- Find every employee where the deactivated person is a matrix manager
  FOR v_affected IN
    SELECT
      e.id,
      e.employee_id,
      ARRAY_REMOVE(ARRAY[
        CASE WHEN e.pm01_manager_id = NEW.id THEN 'PM01' END,
        CASE WHEN e.pm02_manager_id = NEW.id THEN 'PM02' END,
        CASE WHEN e.pm03_manager_id = NEW.id THEN 'PM03' END,
        CASE WHEN e.om01_manager_id = NEW.id THEN 'OM01' END,
        CASE WHEN e.om02_manager_id = NEW.id THEN 'OM02' END,
        CASE WHEN e.om03_manager_id = NEW.id THEN 'OM03' END
      ], NULL) AS codes_held
    FROM employees e
    WHERE NEW.id IN (e.pm01_manager_id, e.pm02_manager_id, e.pm03_manager_id,
                     e.om01_manager_id, e.om02_manager_id, e.om03_manager_id)
  LOOP
    BEGIN
      -- Per-employee EXCEPTION block: one failure doesn't block the whole fanout
      PERFORM fn_close_and_replace_job_relationship_set(
        p_employee_id    => v_affected.id,
        p_effective_from => CURRENT_DATE,
        p_remove_codes   => v_affected.codes_held,
        p_actor          => NULL   -- system trigger, no profile actor
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'job_relationships fanout failed for employee=%, codes=%, error=%',
        v_affected.id, v_affected.codes_held, SQLERRM;
      -- Log to job_run_log with status=partial so ops can investigate
      INSERT INTO job_run_log (job_code, status, message, run_at)
      VALUES ('job_relationships_deactivation_fanout', 'error',
              format('emp=%s codes=%s err=%s', v_affected.id, v_affected.codes_held, SQLERRM),
              NOW());
    END;
  END LOOP;
END IF;
```

### 6.2 Helper RPC `fn_close_and_replace_job_relationship_set`

Closes the current set (effective_to = today - 1, or DELETE if same-day), inserts a new set with `effective_from = today` containing all items EXCEPT those whose `relationship_code` is in `p_remove_codes`, then mirrors to `employees`.

If the new set has zero items, it's still inserted (an empty active set = "no current matrix relationships"). This keeps the timeline complete.

### 6.3 Drift view

`vw_job_relationships_drift` — surfaces any employee whose mirror columns differ from their current active set's items. Used by ops for self-healing reconciliation. Mirror pattern of `vw_personal_name_drift` and `vw_employment_drift`.

---

## 7. Deactivation-Time UX Warning

When HR opens the "Deactivate Employee" confirmation in `EmployeeEditPanel.tsx`:

1. Frontend calls `get_deactivation_impact(employee_id)` BEFORE submitting the status change
2. If `affected_employees.length > 0`, the confirmation modal expands to show:

   ```
   ⚠ This person is a matrix manager for 50 employees:

   • Bob Singh (EMP-0042) — PM01, OM02
   • Carol Patel (EMP-0099) — PM01
   • … 48 more (expand to see all)

   Deactivating will remove these matrix assignments automatically.
   You may want to reassign these relationships to a replacement manager first.

   [ Cancel ]  [ Reassign first ]  [ Deactivate anyway ]
   ```

3. "Reassign first" navigates to a bulk-reassign helper (Phase 4 — see §11).
4. "Deactivate anyway" submits the status change; the trigger fanout runs silently.

The trigger ALWAYS runs the fanout — the modal is purely a UX checkpoint, not a gate. If HR is OK with the loss of references, the change goes through.

---

## 8. UI Surfaces

### 8.1 Job Relationships Portlet (`src/components/shared/JobRelationshipsPortlet.tsx` — NEW)

Mirrors `DependentsPortlet` set-editor pattern.

**View mode (read-only by default):**
- Renders the active set's items as a table of up to 6 rows (one per code)
- Codes with no assignment show "—" placeholder
- Codes are ordered by `sort_order` from the picklist
- "Edit Job Relationships" button (gated on `job_relationships.edit`) enters draft mode
- "View History" link in the corner

**Draft mode (HR/admin):**
- Local clone of active set
- For each of 6 codes, an "Assign / Change / Clear" row:
  - Code label (resolved from picklist; admin-editable elsewhere)
  - Employee picker (searches `employees` where `status = 'Active'`, excludes self)
  - Clear button (X)
- Counter: `(N changed, M added, K removed)`
- Footer: `[Submit Changes]` `[Discard Changes]`
- Submit calls `upsert_job_relationship_set(employee_id, today, items)`

**Pending preview (when `pendingCount > 0`):**
- Same ghost-set pattern as dependents PendingSetPreview
- Amber "Pending Approval" badge; no edit controls

**History panel:**
- Timeline of past sets; click to expand and see who was assigned to what code at that point

### 8.2 MyProfile placement

`MyProfile/index.tsx` — add a new section "Job Relationships" below Employment. ESS sees:
- The active set in read-only mode
- Resolved manager names + their job titles
- No edit controls (gating per §11.7)
- Pending-approval pill (consistent with other sections) when a workflow is in flight

### 8.3 EmployeeEditPanel placement

`EmployeeEditPanel.tsx` — new section "Job Relationships" with full edit capability for HR/admin. Direct write path through `upsert_job_relationship_set` (no workflow staging when admin edits, same model as employment).

### 8.4 EmployeeDetails

`EmployeeDetails.tsx` — add a Matrix tab/column showing who an employee's matrix managers are. Reverse lookup view: "Who has X as PM01?" available as a filter/search affordance.

### 8.5 Deactivation modal

Updated `EmployeeEditPanel.tsx` status-change confirmation per §7.

---

## 9. Notifications

Notification template `wf.job_relationship_assigned` (new, mig 332):

- Triggered when a new set is approved and committed (or direct write by admin)
- Fires per item to the NEWLY-assigned matrix manager: "You have been assigned as the {label} for {employee_name}, effective {date}."
- Reverse fan-out also fires to the REMOVED matrix manager (if any): "You are no longer the {label} for {employee_name}, effective {date}."

The deactivation fanout does NOT send notifications to affected employees (per locked decision §1). The deactivating HR's modal is the only surface for that information.

---

## 10. Permissions

Mig 329 seeds five permissions:

```sql
INSERT INTO permissions (code, name, description, action) VALUES
  ('job_relationships.view',         'View Job Relationships',
   'See an employee''s matrix manager assignments', 'view'),
  ('job_relationships.edit',         'Edit Job Relationships',
   'Assign or change matrix managers', 'edit'),
  ('job_relationships.history',      'View Job Relationships History',
   'See the full timeline of past assignments', 'history'),
  ('job_relationships.bulk_import',  'Bulk Import Job Relationships',
   'Upload CSV files to create/update matrix-manager assignments in bulk. Includes template download. Bypasses workflow.', 'bulk_import'),
  ('job_relationships.bulk_export',  'Bulk Export Job Relationships',
   'Download current state and full timeline of matrix-manager assignments as CSV', 'bulk_export');
```

Default grants:
- `job_relationships.view` → granted to ESS via permission set assignment so employees can see their own
- `job_relationships.edit` → HR/admin permission sets only
- `job_relationships.history` → HR/admin
- `job_relationships.bulk_import` → HR Admin + System Admin only (default OFF; admin enables per set in the Permission Matrix UI)
- `job_relationships.bulk_export` → HR Admin + HR Analyst + System Admin (default OFF; admin enables per set)

The bulk permissions appear in the Permission Matrix UI under a new **Import / Export** section band (positioned below the New Hire band) — a single row per registered template with two inline checkboxes (Import, Export). See `docs/bulk-operations-framework.md` §3 for the matrix-UI band structure.

---

## 11. Phases & Sequencing

| Phase | Work | Migrations / Files | Estimate |
|---|---|---|---|
| 0 | Decisions locked (this doc) | — | ✅ Done |
| 1 | Schema + picklist seed + permissions seed | `mig 329_job_relationships_schema.sql` | 1 day |
| 2 | RPCs: `upsert_job_relationship_set`, `get_current_job_relationships`, `get_job_relationships_history`, `get_deactivation_impact`, `fn_close_and_replace_job_relationship_set` | `mig 330_job_relationship_rpcs.sql` | 2 days |
| 3 | Workflow engine extension: `JOB_RELATIONSHIP` approver type + `workflow_steps.relationship_code` column + `wf_resolve_approver_ex` branch | `mig 331_workflow_job_relationship_type.sql` | 1.5 days |
| 4 | Deactivation fanout: extend `sync_profile_on_employee_status` + new drift view | `mig 332_deactivation_fanout.sql` | 1 day |
| 5 | Notifications: `wf.job_relationship_assigned` template + queuer | `mig 333_job_relationship_notifications.sql` | 0.5 days |
| 6 | Apply branch: extend `apply_profile_pending_change` for `profile_job_relationships` (when workflow-mediated submits exist) | `mig 334_apply_pending_change_job_rel.sql` | 0.5 days |
| 7 | Frontend: `JobRelationshipsPortlet.tsx` set editor + draft/view/history modes | New component | 3 days |
| 8 | Frontend: `MyProfile` section (read-only) + `EmployeeEditPanel` section (edit) | Existing files | 1.5 days |
| 9 | Frontend: deactivation impact modal in `EmployeeEditPanel` | Existing file | 1 day |
| 10 | Frontend: workflow designer Job Relationship approver type config | `WorkflowTemplates.tsx` | 1 day |
| 11 | Frontend: `EmploymentEnrichment`-style approver inbox surface for `profile_job_relationships` workflows (when a JR change is itself workflow-gated) | `ApproverInbox.tsx`, `WorkflowReview.tsx` | 1.5 days |
| 12 | (Optional, deferred) bulk reassign helper for "Reassign first" path in deactivation modal | New component | 2 days |
| 13 | Cleanup + docs: update `prowess_system_docs.html` Part 15 status banner; rename memory file | — | 0.5 days |

**Total: ~16 working days. Phases 1–6 backend first, then 7–11 frontend.**

---

## 12. Risk Register

| Risk | Mitigation |
|---|---|
| Mirror drift between 6 master cols and active set items | `vw_job_relationships_drift` view; reconciliation via re-running `_sync_job_relationships_today()`; guard trigger blocks ad-hoc UPDATEs |
| Deactivation fanout fails partway, leaving inconsistent mirror | Per-employee EXCEPTION blocks; failures logged to `job_run_log` with status=error; drift view surfaces remaining gaps for manual repair |
| Workflow step silently skipped due to NULL matrix manager (per locked §1.5) | Every skip writes a `workflow_action_log` row. Audit dashboards can filter on `action='step_skipped'` to detect routing-drift patterns. |
| Admin accidentally deactivates a high-impact matrix manager | Deactivation impact modal (§7) lists every affected employee. HR sees the blast radius before confirming. |
| Two HR users edit the same employee's job relationships concurrently | RPC uses advisory lock per employee (mirrors personal_info pattern); concurrent writes serialize |
| Picklist label change (e.g. PM01 relabelled from "Project Manager" to "Product Manager") propagates correctly to all surfaces | Codes are stable; only labels live in `picklist_values.value`. UI always resolves to label at render time, never caches it. |
| Inactive matrix manager → workflow skips (per locked §1.2) — submitter unaware their request bypassed an intended approver | The workflow_action_log skip entry is the audit trail. Add optional notification "Your {label} step was skipped because the assigned manager is unavailable" — Phase 5 follow-up if feedback warrants. |
| Cycle by composition (A is B's PM01, B is C's PM01, C is A's PM01) — three-way matrix cycle | Not blocked. Matrix relationships are non-hierarchical (locked §1.1); compositional cycles are valid org structures (peer matrix routing). |
| Future-dated terminations: someone with `end_date = 2026-12-31` is matrix manager today; portlet should not pre-fanout | The fanout fires on the deactivation STATUS change. Future-dated `end_date` alone doesn't trigger anything until the nightly `_scan_end_date_inactive` flips the status. Then the existing trigger handles it. |

---

## 13. Open items deferred to follow-up

- **Bulk reassign helper** for "Reassign first" path in the deactivation modal — phase 12, deferred. Initial release ships with the modal showing the impact list; "Reassign first" navigates to the standalone JobRelationshipsPortlet for the named successor manager and lets HR pick targets manually one at a time. Bulk batching as a single transaction is a future polish.
- **Effective-date snap behaviour for new hires** — when an employee is created, do they start with an empty active set (preferred) or no set at all? Recommendation: no set; first assignment creates set #1. Same model as dependents.
- **JOB_RELATIONSHIP approval workflows** — the design assumes some JR changes will be workflow-gated (e.g., the employee's own change request routed through HR head). The portlet supports the dual-path RPC, but the workflow template assignment and approver-side enrichment UI are Phase 11. Initial release works direct-write only for HR/admin; workflow gating gets bolted on next.

---

## 14. Migration File Numbering

**Updated 2026-05-30:** the set-snapshot rewrite shipped (complete through mig 332) and employment effective-dating shipped (migs 351–356). Per `MEMORY.md` the next free slot is **`20260530357+`**.

Renumber the planned 329–334 sequence to **357–362** at implementation time:

| Original number | Use instead |
|---|---|
| 329 | `20260530357_job_relationships_schema.sql` |
| 330 | `20260530358_job_relationship_rpcs.sql` |
| 331 | `20260530359_workflow_job_relationship_type.sql` |
| 332 | `20260530360_deactivation_fanout.sql` |
| 333 | `20260530361_job_relationship_notifications.sql` |
| 334 | `20260530362_apply_pending_change_job_rel.sql` |

If parallel work shifts these numbers further, the design doc is the source of truth — adjust filenames accordingly.

---

## 15. Surfaces Touched (Files Inventory)

**Backend (migrations) — numbered per §14 (357–362):**
- `mig 357` schema + picklist seed + permissions seed
- `mig 358` RPCs
- `mig 359` workflow approver type extension
- `mig 360` deactivation fanout extension
- `mig 361` notification templates
- `mig 362` apply_profile_pending_change branch

**Frontend (new):**
- `src/components/shared/JobRelationshipsPortlet.tsx` — set editor
- `src/components/shared/JobRelationshipsHistoryPanel.tsx` — history view
- `src/components/admin/DeactivationImpactModal.tsx` — confirmation dialog

**Frontend (modified):**
- `src/components/employee/MyProfile/index.tsx` — read-only section
- `src/components/admin/EmployeeEditPanel.tsx` — edit section + deactivation modal trigger
- `src/components/admin/EmployeeDetails.tsx` — matrix column
- `src/workflow/screens/WorkflowTemplates.tsx` — JOB_RELATIONSHIP approver type config
- `src/workflow/screens/ApproverInbox.tsx` — `profile_job_relationships` enrichment (Phase 11)
- `src/workflow/screens/WorkflowReview.tsx` — `profile_job_relationships` in FULL_REVIEW_MODULES (Phase 11)

**Docs:**
- This file (`docs/job-relationships-design.md`)
- After implementation: update `prowess_system_docs.html` Part 15 (added in same session as this design)
- Cross-reference: `docs/bulk-operations-framework.md` (to be created) — owns the cross-module Import / Export spec referenced in §16

---

## 16. Bulk Operations Integration

Job Relationships plugs into the cross-module Bulk Operations Framework. This section captures Job-Relationships-specific aspects; the framework itself owns the screen, registry, async pipeline, CSV format rules, permission-matrix integration, and round-trip semantics (see `docs/bulk-operations-framework.md`).

### 16.1 Locked framework rules that apply

| # | Rule |
|---|---|
| 0 | Framework covers **15 modules** total: 12 employee-scoped (personal_info, contact_info, address, passport, identification, emergency_contact, employment, job_relationships, dependents, bank_accounts, employees, department) + 3 admin master tables (**picklist, project, exchange_rate**). |
| 1 | New "Import / Export" sidebar item below Reports in the Admin section |
| 2 | Sidebar visibility gate: any `*.bulk_*` permission grants tab access |
| 3 | Permission naming: `<module>.bulk_import` / `.bulk_export` for every registered template |
| 4 | Date format: strict `mm/dd/yyyy` for every date field |
| 5 | Codes only, never names (employee_code, picklist ref_id, ISO country, etc.) |
| 6 | CSV only. Template download = `.zip` containing `<template>_template.csv` + `README.txt` |
| 7 | README auto-generated server-side from the registry; includes format rules + mandatory-field list + current code reference tables (picklist labels resolved at download time) |
| 8 | Mandatory fields marked with `*` in the CSV header row |
| 9 | Export and template have identical column structure (round-trip-safe) |
| 10 | Two export buttons: `[Export current]` (round-trip-safe; one row per natural key) and `[Export history]` (full timeline; not round-trip-safe; audit/migration use) |
| 11 | Persistent "Include inactive records" toggle alongside the export buttons (applies to both); default OFF |
| 12 | Bulk uploads bypass workflow regardless of whether the module has a workflow configured |
| 13 | All processing goes through the existing module RPC (`upsert_job_relationship_set` for this module) — no separate logic path |
| 14 | File size: 10,000 rows hard cap per upload; UI warning at 5,000; above 10,000 rejected with "Split into smaller files" |
| 15 | CSV encoding: UTF-8 with BOM, comma delimiter, RFC 4180 double-quote field quoting |
| 16 | Audit batch id: every audit_log row from one upload shares an `upload_batch_id` UUID stored in `audit_log.metadata->'upload_batch_id'` |
| 17 | Async processing via Supabase Edge Function reading the file from Storage; status updates written to `job_run_log`; in-app notification to uploader on completion |
| 18 | Cancellation: uploader (and System Admin) can cancel an in-flight job; already-processed rows stay committed; remaining rows skipped; `job_run_log.status = 'cancelled'` |
| 19 | Full-record deletion via `DELETE_RECORD` keyword in the Value cell — for terminating an employee, removing a department, closing an entire bank account, etc. Surfaces a confirmation step on the results screen before commit (HR must click "Confirm N record deletions" before processing) |
| 20 | Per-value DELETE keyword in the Value cell (existing semantics for set-snapshot templates like Job Relationships) — removes a single code in the new effective-dated slice |
| 21 | **Export default = user-fillable business fields only.** System-generated columns (UUIDs, timestamps, audit user IDs, computed columns, mirror caches) are omitted. Round-trip safe. |
| 22 | **"Include system metadata" toggle** sits alongside the export buttons (next to "Include inactive records"). When ON: adds row UUIDs (id, set_id, item_id), timestamps (created_at, updated_at, inactive_at), audit user IDs (created_by, updated_by, inactive_by), computed columns (effective_to, generated name fields), mirror cache columns, AND display-name columns (Employee Name, Manager Name, Relationship Label, etc.). Default OFF. NOT round-trip safe. |
| 23 | **Template download never includes system fields.** Template = the exact column set the user can fill. Matches the user-fillable subset of export-default. |
| 24 | **Importer silently ignores unknown / system column headers.** If HR exports with system metadata ON, edits business fields, and re-imports, system columns are dropped on parse with an info notice on the results screen ("Ignored N system columns: id, created_at, …"). Preserves the round-trip path for either export mode. |

### 16.2 Job Relationships registry row

```json
{
  "template_code":   "job_relationships",
  "display_label":   "Job Relationships",
  "description":     "Matrix manager assignments — PM01 through OM03",
  "icon":            "ti-users-group",
  "permission_view": "job_relationships.bulk_export",
  "permission_edit": "job_relationships.bulk_import",
  "workflow_bypass": true,
  "processor_rpc":   "upsert_job_relationship_set",
  "deleter_rpc":     "fn_close_and_replace_job_relationship_set",
  "schema_definition": {
    "columns": [
      { "name": "Effective Date *",     "data_type": "date_mmddyyyy",                          "mandatory": true,  "user_fillable": true },
      { "name": "Employee Code *",      "data_type": "code_employee",                          "mandatory": true,  "user_fillable": true },
      { "name": "Relationship Code *",  "data_type": "code_picklist:JOB_RELATIONSHIP_TYPE",    "mandatory": true,  "user_fillable": true },
      { "name": "Value *",              "data_type": "code_employee_or_keyword:DELETE,DELETE_RECORD", "mandatory": true,  "user_fillable": true },
      { "name": "Employee Name",        "data_type": "display_name",                           "mandatory": false, "user_fillable": false, "include_with_system_metadata": true },
      { "name": "Relationship Label",   "data_type": "display_label",                          "mandatory": false, "user_fillable": false, "include_with_system_metadata": true },
      { "name": "Manager Name",         "data_type": "display_name",                           "mandatory": false, "user_fillable": false, "include_with_system_metadata": true },
      { "name": "set_id",               "data_type": "uuid",                                   "mandatory": false, "user_fillable": false, "include_with_system_metadata": true },
      { "name": "item_id",              "data_type": "uuid",                                   "mandatory": false, "user_fillable": false, "include_with_system_metadata": true },
      { "name": "manager_employee_uuid","data_type": "uuid",                                   "mandatory": false, "user_fillable": false, "include_with_system_metadata": true },
      { "name": "created_at",           "data_type": "timestamptz",                            "mandatory": false, "user_fillable": false, "include_with_system_metadata": true },
      { "name": "updated_at",           "data_type": "timestamptz",                            "mandatory": false, "user_fillable": false, "include_with_system_metadata": true },
      { "name": "created_by",           "data_type": "uuid_profile",                           "mandatory": false, "user_fillable": false, "include_with_system_metadata": true }
    ],
    "natural_key": ["Effective Date", "Employee Code", "Relationship Code"]
  }
}
```

Three behaviours fall out of the per-column flags:
- **Template generator** emits columns where `user_fillable: true` (4 cols)
- **Export-default** emits same 4 cols
- **Export-with-system-metadata** emits all columns (4 user + 9 metadata = 13 cols)
- **Importer** reads only `user_fillable: true` cols; any other header is silently ignored with an info notice on the results screen

### 16.3 Job-Relationships-specific upload semantics

- Default mode = **incremental upsert with carry-forward** — rows grouped by `(Employee Code, Effective Date)`. For each group:
  - Carry forward all current items NOT mentioned in the group
  - Overlay codes mentioned with non-`DELETE` non-`DELETE_RECORD` values
  - Remove codes mentioned with `DELETE` value
  - If any row in the group has `Value = DELETE_RECORD`, close the employee's entire matrix-relationship set as of the effective date (new set with zero items). The results screen prompts HR with "Confirm N record deletions" before commit.
- Duplicate composite key `(Effective Date, Employee Code, Relationship Code)` in the same upload → row-level error
- `DELETE` on an already-unassigned code → row-level **warning** (no-op, processed)
- Self-assignment, manager not found, manager inactive → row-level **error**
- All errors and warnings surface in the validation results table; HR can choose `Process N valid rows` (excluding errors; warnings included) or `Download error file` for offline correction

### 16.4 Export shape

`Export current` for Job Relationships produces one CSV row per active assignment per employee (tall format). Example:

```
Effective Date *,Employee Code *,Employee Name,Relationship Code *,Relationship Label,Value *,Manager Name
06/01/2026,EMP1042,Vijey ASR,PM01,Project Manager,EMP2017,Alice Brown
06/01/2026,EMP1042,Vijey ASR,OM02,Operations Lead,EMP2031,Bob Jones
```

Code columns marked `*` are mandatory for re-import. Display-name columns (`Employee Name`, `Relationship Label`, `Manager Name`) are advisory — included for HR readability, ignored on re-import.

`Export history` adds historical slices for every employee, plus columns `Slice Start`, `Slice End`. NOT round-trip safe.

`Include inactive records` toggle adds matrix relationships where the employee or the manager has `status = 'Inactive'`.

### 16.5 Files added to inventory for bulk integration

- **Backend (mig in framework's range, not Job-Relationships-specific):** registry row INSERT, processor RPC registration. Shared between all 12 templates.
- **Frontend:** no Job-Relationships-specific UI changes — the generic Bulk Operations screen handles everything via the registry.
