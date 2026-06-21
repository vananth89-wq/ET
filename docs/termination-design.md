# Termination Module — Design Specification

**Status:** Design Phase — Locked 2026-06-04 | Schema updated 2026-06-05 (migs 497–498)
**Source spec:** `docs/termination-spec-v2.0.txt`
**Next available migration:** `20260530382+`
**Phase estimate:** ~14 working days

Termination is a first-class lifecycle event modelled as an event table — not a timeline table or a slice of employment. This doc is the single source of truth for migrations, RPCs, workflows, post-approval automation, frontend, and bulk-framework integration. Architectural decisions in §1 are LOCKED — do not relitigate.

---

## §1 Decision Summary (LOCKED)

| # | Decision | Verdict |
|---|---|---|
| 1 | Where `notice_period_days` lives | On the **employment satellite** (`employee_employment` per migs 351–356). Effective-dated. Termination reads the slice where `effective_from <= termination_date < effective_to`. |
| 2 | JR cleanup on termination | **No new code.** `sync_profile_on_employee_status` (JR mig 364) auto-closes JR sets when `employees.status` flips to Inactive. Add an integration test, do not rebuild. |
| 3 | `workflow_status` / `approved_by` / `approved_at` on termination | **Denormalize on the termination row.** Required because (a) `REVERSED` is not a `wf_instance` state and (b) the partial unique index in §3.1 can only reference local columns. `wf_instance` remains the audit trail. |
| 4 | Concurrent workflow guard | Enforced inside `wf_submit`. **All modules except `termination` itself** are blocked when a PENDING termination exists for `target_employee_id`. |
| 5 | Reversal representation | **Separate table** `employee_termination_reversals` (own workflow instance, own reason, own attachments) + denormalized `workflow_status='REVERSED'` flag on the original row. |
| 6 | Terminated manager → direct reports | Pre-approval warning modal listing affected reports (via extended `get_deactivation_impact`). Post-approval: keep `manager_id` for audit; `wf_resolve_approver_ex` skips Inactive managers and escalates. No auto-NULL. |
| 7 | Future-dated terminations | Supabase Edge Function `process_scheduled_terminations` on **daily cron** with idempotency columns (`scheduled_executed`, `scheduled_executed_at`). No pg_cron. |
| 8 | Bulk framework | **17th template** in `bulk_template_registry`. Bypasses workflow per framework rule §13; safety enforced by permission lockdown (`termination.bulk_import` granted to a tiny admin group). Bulk rows are stamped `termination_initiation_type='SYSTEM_INITIATED'`. |
| 9 | Termination IS NOT effective-dated | Event table. `termination_date` is the effective date of separation. No `effective_from`/`effective_to`. |
| 10 | Initiation type derivation | `logged_in_employee_id = target_employee_id → SELF`, regardless of role. HR self-termination = SELF. Bulk = SYSTEM_INITIATED. |
| 11 | Reason picklist visibility | Driven by transaction context, not by role: self → RESIGNATION_REASON; other → TERMINATION_REASON. |
| 12 | Notice-period validation | Self-service: hard block on submission. HR/Admin: exempt; auto-set `notice_period_waived=true` and require `notice_period_waiver_reason`. |
| 13 | Withdrawal | Permitted only while `workflow_status='PENDING'`. APPROVED termination requires a Reversal transaction. |
| 14 | Permissions | 5 perms: `termination.view`, `.edit`, `.history`, `.bulk_import`, `.bulk_export`. No default grants. |
| 15 | Comments minimum | 20 chars standard; 50 chars when reason = OTHER. Enforced at API and UI. |
| 16 | UI surface mirrors | Self-service screen mirrors the **Bank Account** add-form pattern. ApproverInbox enrichment mirrors **BankEnrichment** (line 1421). WorkflowReview section mirrors `profile_bank` block. Permission Matrix row sits in the **EMPLOYEE band**; bulk perms surface in **IMPORT/EXPORT band** via framework. |
| 17 | Migration ordering | Termination's bulk slot mig is LAST in the set — it `CREATE OR REPLACE`s `bulk_export` to 17 WHEN clauses. Any rerun ordering must keep this constraint. |

---

## §2 Data Model

### §2.1 `employee_terminations`

> **Schema updated mig 497–498 (2026-06-05).** See §2.6 for full field behaviour by initiation type.

```sql
CREATE TABLE employee_terminations (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id                   UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,

  -- ── Core date fields (mig 497) ──────────────────────────────────────────
  separation_date               DATE NOT NULL,
  -- Employee's stated intent. Immutable after submission.
  -- SELF: must be >= notice_expiry_date. HR/MGR: set freely.
  -- Previously: termination_date (renamed mig 497).

  notice_expiry_date            DATE,
  -- Always computed by RPC: submitted_at + notice_period_days_snapshot.
  -- Never user-supplied. Previously: notice_date (renamed mig 497).

  notice_period_days_snapshot   INTEGER NOT NULL DEFAULT 30,
  -- Point-in-time copy of employee_employment.notice_period_days at submission.
  -- Stored for audit — employment terms may change after submission.

  last_working_date             DATE,
  -- HR-confirmed actual last day. Defaults to separation_date at submission.
  -- HR/MGR can override: earlier → triggers notice waiver; later → extends.
  -- JOB ANCHOR: all post-approval jobs (deactivation, payroll cutoff, etc.)
  -- fire when last_working_date <= CURRENT_DATE.

  submitted_at                  TIMESTAMPTZ,
  -- Stamped once by trigger when workflow_status transitions DRAFT → PENDING.
  -- Used as the base date for computing notice_expiry_date.

  -- ── Classification ───────────────────────────────────────────────────────
  termination_reason_code       TEXT NOT NULL,
  termination_initiation_type   TEXT NOT NULL
                                  CHECK (termination_initiation_type IN
                                    ('SELF','HR_INITIATED','MANAGER_INITIATED',
                                     'ADMIN_INITIATED','SYSTEM_INITIATED')),

  -- ── Notice waiver ────────────────────────────────────────────────────────
  notice_period_waived          BOOLEAN NOT NULL DEFAULT false,
  -- AUTO: set true when last_working_date < notice_expiry_date.
  -- SELF: hard block — employee cannot waive own notice.
  -- HR/MGR: auto-waive with waiver_reason required.
  notice_period_waiver_reason   TEXT,

  -- ── HR-only fields (stripped from SELF submissions) ──────────────────────
  eligible_for_rehire           BOOLEAN NOT NULL DEFAULT true,
  regrettable_termination       BOOLEAN,

  comments                      TEXT NOT NULL,

  -- ── Workflow ──────────────────────────────────────────────────────────────
  workflow_status               TEXT NOT NULL DEFAULT 'DRAFT'
                                  CHECK (workflow_status IN
                                    ('DRAFT','PENDING','APPROVED','REJECTED','WITHDRAWN','REVERSED')),
  workflow_instance_id          UUID REFERENCES workflow_instances(id) ON DELETE SET NULL,
  approved_at                   TIMESTAMPTZ,
  approved_by                   UUID REFERENCES profiles(id) ON DELETE SET NULL,

  -- ── Settlement / scheduler idempotency ───────────────────────────────────
  final_settlement_processed    BOOLEAN NOT NULL DEFAULT false,
  final_settlement_date         DATE,
  scheduled_executed            BOOLEAN NOT NULL DEFAULT false,
  scheduled_executed_at         TIMESTAMPTZ,

  upload_batch_id               UUID,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by                    UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by                    UUID REFERENCES profiles(id) ON DELETE SET NULL,

  CONSTRAINT chk_term_comments_min
    CHECK (length(comments) >= 20),
  CONSTRAINT chk_term_comments_other
    CHECK (termination_reason_code <> 'OTHER' OR length(comments) >= 50),
  CONSTRAINT chk_term_waiver_reason
    CHECK (NOT notice_period_waived OR notice_period_waiver_reason IS NOT NULL),
  -- chk_term_lwd_after_separation DROPPED mig 526 (garden leave: LWD < separation_date is valid)
);

-- One active termination per employee
CREATE UNIQUE INDEX uq_employee_active_termination
  ON employee_terminations (employee_id)
  WHERE workflow_status IN ('PENDING', 'APPROVED');

CREATE INDEX ix_term_employee_id       ON employee_terminations (employee_id);
CREATE INDEX ix_term_separation_date   ON employee_terminations (separation_date);
CREATE INDEX ix_term_status            ON employee_terminations (workflow_status);

-- Scheduler index: anchor on last_working_date (mig 497)
CREATE INDEX ix_term_scheduled         ON employee_terminations (last_working_date, scheduled_executed)
  WHERE workflow_status = 'APPROVED'
    AND scheduled_executed = false
    AND last_working_date IS NOT NULL;

CREATE INDEX ix_term_upload_batch      ON employee_terminations (upload_batch_id)
  WHERE upload_batch_id IS NOT NULL;
```

### §2.2 `employee_termination_attachments`

```sql
CREATE TABLE employee_termination_attachments (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  termination_id    UUID REFERENCES employee_terminations(id) ON DELETE CASCADE,
  reversal_id       UUID REFERENCES employee_termination_reversals(id) ON DELETE CASCADE,
  file_name         TEXT NOT NULL,
  original_file_name TEXT NOT NULL,
  file_path         TEXT NOT NULL,         -- Supabase Storage path
  file_size_bytes   INTEGER,
  mime_type         TEXT,
  is_active         BOOLEAN NOT NULL DEFAULT true,
  uploaded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  uploaded_by       UUID REFERENCES profiles(id) ON DELETE SET NULL,
  CONSTRAINT chk_att_one_parent
    CHECK ((termination_id IS NOT NULL)::int + (reversal_id IS NOT NULL)::int = 1)
);

CREATE INDEX ix_term_att_termination ON employee_termination_attachments (termination_id) WHERE termination_id IS NOT NULL;
CREATE INDEX ix_term_att_reversal    ON employee_termination_attachments (reversal_id) WHERE reversal_id IS NOT NULL;
```

### §2.3 `employee_termination_reversals` (§1 decision #5)

```sql
CREATE TABLE employee_termination_reversals (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  termination_id        UUID NOT NULL REFERENCES employee_terminations(id) ON DELETE RESTRICT,
  reversal_reason       TEXT NOT NULL,
  comments              TEXT NOT NULL,
  workflow_status       TEXT NOT NULL DEFAULT 'DRAFT'
                          CHECK (workflow_status IN
                            ('DRAFT','PENDING','APPROVED','REJECTED','WITHDRAWN')),
  workflow_instance_id  UUID REFERENCES wf_instance(id) ON DELETE SET NULL,
  approved_at           TIMESTAMPTZ,
  approved_by           UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by            UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by            UUID REFERENCES profiles(id) ON DELETE SET NULL,
  CONSTRAINT chk_rev_comments_min CHECK (length(comments) >= 20)
);

-- Only one active reversal per terminated record
CREATE UNIQUE INDEX uq_termination_active_reversal
  ON employee_termination_reversals (termination_id)
  WHERE workflow_status IN ('PENDING','APPROVED');

CREATE INDEX ix_rev_termination ON employee_termination_reversals (termination_id);
CREATE INDEX ix_rev_status      ON employee_termination_reversals (workflow_status);
```

### §2.4 `employee_employment` — add `notice_period_days`

```sql
ALTER TABLE employee_employment
  ADD COLUMN notice_period_days INTEGER NOT NULL DEFAULT 30
    CHECK (notice_period_days IN (30, 90, 120));

-- Drop NOT NULL default after backfill
-- All existing rows get DEFAULT 30; HR can amend via the employment edit RPC.
```

Notes for the implementer:
- `notice_period_days` is part of the bi-temporal slice. The employment upsert RPC (mig 351–356 series) must accept it as a writable field.
- Backfill is a no-op — `DEFAULT 30` covers existing rows.
- Remove the `end_date` and `termination_reason_code` columns from `employee_employment` (per spec §2). Migrate any existing data to `employee_terminations` before dropping.

### §2.5 Picklists

```sql
INSERT INTO picklists (code, label, is_admin_editable_labels) VALUES
  ('RESIGNATION_REASON', 'Resignation Reasons', true),
  ('TERMINATION_REASON', 'Termination Reasons', true);

-- RESIGNATION_REASON values
-- BETTER_OPPORTUNITY, HIGHER_STUDIES, RELOCATION, PERSONAL_REASONS,
-- FAMILY_COMMITMENTS, HEALTH_REASONS, RETIREMENT, OTHER

-- TERMINATION_REASON values
-- PERFORMANCE, MISCONDUCT, POLICY_VIOLATION, PROBATION_FAILURE, ABSCONDING,
-- POSITION_REDUNDANCY, ORG_RESTRUCTURING, END_OF_CONTRACT, RETIREMENT, DEATH, OTHER
```

Insert via existing `picklist_values` table. Codes immutable; labels admin-editable per the standard Prowess picklist pattern.

### §2.6 Field Behaviour by Initiation Type

> Added 2026-06-05. This section is the authoritative reference for how each field on `employee_terminations` behaves across the three initiation paths.

**Authoritative source for notice period:** `employee_employment.notice_period_days` — read by the RPC at submission time. `notice_expiry_date` is always derived from this; it is never a manual input.

| Field | SELF | HR_INITIATED | MANAGER_INITIATED |
|---|---|---|---|
| `separation_date` | Employee sets. Must be ≥ `notice_expiry_date`. Immutable after submission. | HR sets at submission. | Manager sets at submission. |
| `notice_expiry_date` | **Always computed:** `submitted_at + notice_period_days_snapshot`. Read-only. Never user-set. | Same — always computed. | Same — always computed. |
| `notice_period_days_snapshot` | Snapshotted from `employee_employment` at submission. | Same. | Same. |
| `last_working_date` | Defaults to `separation_date`. Employee cannot set earlier than `separation_date`. | Defaults to `separation_date`. HR can override — earlier triggers notice waiver. **All jobs fire on this date.** | Same as HR. |
| `notice_period_waived` | AUTO: if LWD < `notice_expiry_date` → **hard block**. Employee cannot waive own notice. | AUTO: if LWD < `notice_expiry_date` → waiver flagged, `notice_period_waiver_reason` required. | Same as HR. |
| `eligible_for_rehire` | Stripped — forced `true`. | HR sets explicitly. | HR/Manager sets. |
| `regrettable_termination` | Stripped — forced `NULL`. | HR sets explicitly. | HR/Manager sets. |
| `submitted_at` | Stamped by trigger on DRAFT → PENDING transition. | Same. | Same. |

**Notice period / waiver check logic (in `submit_termination` RPC):**

```
notice_expiry_date = submitted_at + notice_period_days_snapshot

SELF:
  separation_date must be >= notice_expiry_date   ← form min + RPC guard
  last_working_date defaults to separation_date
  if LWD < notice_expiry_date → HARD BLOCK (no self-waiver)

HR / MANAGER:
  last_working_date defaults to separation_date if not provided
  if LWD < notice_expiry_date → auto-waive (notice_period_waiver_reason required)
  all downstream jobs execute on last_working_date
```

**Downstream jobs — all key on `last_working_date`:**

The scheduler index `ix_term_scheduled` filters `last_working_date <= CURRENT_DATE AND last_working_date IS NOT NULL AND workflow_status = 'APPROVED' AND scheduled_executed = false`. Jobs triggered:
- Close open employment slice (`effective_to = last_working_date`)
- Insert Inactive slice (`effective_from = last_working_date + 1`)
- Set `employees.status = 'Inactive'` → auto-closes JR sets (mig 364)
- Payroll cutoff / access revocation notifications

**Design principle:** `separation_date` = intent (immutable after submission). `last_working_date` = reality (HR-adjustable during approval). All downstream jobs run on reality.

**HR mid-flight amendment (added 2026-06-09, corrected mig 526):** When an approver (HR analyst, manager) reviews a PENDING termination, they may amend `last_working_date` via the Update button in the Approver Inbox. Rules:
- Only `last_working_date` is editable by approvers — `separation_date`, reason, and comments are immutable.
- **LWD < separation_date is valid (garden leave):** employee stops coming in on LWD but remains legally employed until `separation_date`. All downstream jobs fire on LWD. The constraint `chk_term_lwd_after_separation` was dropped in mig 526.
- If the amended LWD < `notice_expiry_date` → notice is waived automatically; `notice_period_waiver_reason` required (≥ 20 chars).
- Implemented by `update_termination_lwd` RPC (migs 525 + 526). Approver identity guard prevents the employee from using this path on their own record.
- The employee's own amendment path (after send-back) is `update_termination` (mig 524), SELF-only.

---

### §2.8 Permissions

```sql
INSERT INTO permissions (name) VALUES
  ('termination.view'),
  ('termination.edit'),
  ('termination.history'),
  ('termination.bulk_import'),
  ('termination.bulk_export')
ON CONFLICT DO NOTHING;
```

---

## §3 RPC Contracts

All RPCs are `SECURITY DEFINER` with `SET search_path = public`. Permission checks via `user_can('termination', <action>, p_employee_id)`.

### §3.1 `submit_termination`

```sql
submit_termination(
  p_employee_id          UUID,
  p_termination_data     JSONB,    -- see payload below
  p_attachments          JSONB     -- array of {file_name, file_path, ...}
) RETURNS JSONB                    -- {ok, termination_id, workflow_instance_id, workflow_status}
```

Payload shape:
```json
{
  "termination_date": "2026-08-15",
  "termination_reason_code": "BETTER_OPPORTUNITY",
  "resignation_date": "2026-06-01",
  "notice_date": "2026-06-01",
  "last_working_date": "2026-08-15",
  "notice_period_waived": false,
  "notice_period_waiver_reason": null,
  "eligible_for_rehire": true,         // HR only — ignored for SELF
  "regrettable_termination": null,     // HR only — ignored for SELF
  "comments": "..."
}
```

Behaviour:
1. Derive `termination_initiation_type` from `logged_in_employee_id = p_employee_id` rule.
2. Lookup picklist: SELF → RESIGNATION_REASON; else → TERMINATION_REASON. Validate `termination_reason_code` against the right picklist.
3. Read `notice_period_days` from the employment slice where `effective_from <= termination_date < effective_to`. Reject if no slice covers the date.
4. SELF path: enforce `last_working_date >= resignation_date + notice_period_days` or ERROR.
5. HR/Admin path: if `last_working_date < termination_date + notice_period_days`, set `notice_period_waived=true` and require `notice_period_waiver_reason`.
6. Strip `eligible_for_rehire` / `regrettable_termination` from SELF payloads (silently force defaults).
7. Insert termination row with `workflow_status='DRAFT'`.
8. Call `wf_submit('termination', termination_id, ...)`. Workflow instance ID is stored on the row.
9. Flip `workflow_status` to `'PENDING'`.
10. Process attachments — insert into `employee_termination_attachments`.
11. Return `{ok: true, termination_id, workflow_instance_id, workflow_status: 'PENDING'}`.

### §3.2 `submit_termination_reversal`

```sql
submit_termination_reversal(
  p_termination_id   UUID,
  p_reversal_data    JSONB,   -- {reversal_reason, comments}
  p_attachments      JSONB
) RETURNS JSONB
```

Requirements: original termination must be `workflow_status='APPROVED'`. Creates a row in `employee_termination_reversals` and submits via `wf_submit('termination', reversal_id, kind='reversal')`.

### §3.3 `withdraw_termination` / `withdraw_termination_reversal`

Calls `wf_withdraw(workflow_instance_id)`. Trigger flips `workflow_status` back to `'DRAFT'` and clears `workflow_instance_id`. Withdrawal allowed only while `workflow_status='PENDING'`.

### §3.4 Read RPCs

```sql
get_employee_terminations(p_employee_id UUID) RETURNS JSONB
  -- Returns latest termination + reversal (if any), with attachments.

get_termination_history(p_employee_id UUID, p_include_reversed BOOLEAN DEFAULT true) RETURNS JSONB
  -- Returns all terminations including REVERSED, ordered by termination_date DESC.

get_termination_deactivation_impact(p_employee_id UUID) RETURNS JSONB
  -- Returns {ok, jr_assignments_to_close: [...], direct_reports: [...]}.
  -- Reuses JR's get_deactivation_impact for JR side; extends with direct-reports count.
```

### §3.7 `update_termination_lwd` (migs 525 + 526 — approver mid-flight amendment)

```sql
update_termination_lwd(
  p_termination_id              uuid,
  p_last_working_date           date,
  p_notice_period_waiver_reason text DEFAULT NULL
) RETURNS jsonb   -- {ok, termination_id, last_working_date, notice_period_waived, notice_period_waiver_reason}
```

Called from the ApproverInbox Update → Save Changes flow. Guards (mig 526 supersedes mig 525):
1. Caller is NOT the employee being terminated (approver-only path).
2. Record is PENDING.
3. `p_last_working_date` must be non-null. No minimum relative to `separation_date` — LWD < separation_date is valid garden leave.
4. If `p_last_working_date < notice_expiry_date` → `p_notice_period_waiver_reason` required (≥ 20 chars); auto-sets `notice_period_waived = true`.
5. If `p_last_working_date >= notice_expiry_date` → clears waiver fields.

Fields NOT touched: `separation_date`, `notice_expiry_date`, `termination_reason_code`, `comments`, `workflow_status`, `submitted_at`.

### §3.5 `derive_termination_initiation_type` (helper)

```sql
derive_termination_initiation_type(p_employee_id UUID, p_is_bulk BOOLEAN DEFAULT false)
RETURNS TEXT
```

Logic:
- `p_is_bulk = true` → 'SYSTEM_INITIATED'
- `auth.uid() = p_employee_id`'s profile → 'SELF'
- caller has `termination.edit` and is an HR role → 'HR_INITIATED'
- caller has `termination.edit` and is an admin role → 'ADMIN_INITIATED'
- else: raise insufficient_privilege

### §3.6 `upsert_termination_bulk` (bulk framework processor — §14)

```sql
upsert_termination_bulk(
  p_employee_id              UUID,
  p_termination_data         JSONB,
  p_upload_batch_id          UUID
) RETURNS JSONB
```

Bypasses workflow per framework rule §13. Inserts the row with `workflow_status='APPROVED'`, `termination_initiation_type='SYSTEM_INITIATED'`, `upload_batch_id` stamped, then invokes the same post-approval automation (§5). Mandatory: permission `termination.bulk_import`.

---

## §4 Workflow Integration

### §4.1 New workflow module

Add `'termination'` to the workflow module enum (or table) used by `workflow_templates`. Existing engine carries it through `wf_submit/approve/reject/resubmit/withdraw` without change.

### §4.2 Concurrent guard inside `wf_submit`

Add at the top of `wf_submit`, after parameter validation:

```sql
-- Concurrent termination guard (§1 decision #4)
IF p_module <> 'termination' THEN
  IF EXISTS (
    SELECT 1 FROM employee_terminations
    WHERE employee_id = p_target_id
      AND workflow_status = 'PENDING'
  ) THEN
    RAISE EXCEPTION 'A termination is pending approval for this employee.'
      USING ERRCODE = 'check_violation';
  END IF;
END IF;
```

This blocks every other module's submissions while a termination is pending, but allows termination's own submission and its reversal submission (both have `p_module='termination'`).

### §4.3 Approval trigger

When `wf_approve` finalises a workflow instance with `module='termination'`, a trigger on `wf_instance` calls `apply_termination_approval(workflow_instance_id)`. The function dispatches based on the linked record kind:

```
wf_instance.entity_id matches employee_terminations.id     → apply_termination_approval(...)
wf_instance.entity_id matches employee_termination_reversals.id → apply_termination_reversal(...)
```

Both functions update `workflow_status` and `approved_at` / `approved_by` on the relevant row and enqueue the appropriate Edge Function call.

### §4.4 Default workflow templates

Seeded as configurable templates — not hardcoded:

- **Self-Service Resignation:** Step 1 MANAGER → Step 2 HR_APPROVER → Step 3 FINAL_APPROVER
- **HR/Admin Initiated:** Step 1 HR_MANAGER → Step 2 FINAL_APPROVER
- **Reversal:** Step 1 HR_MANAGER → Step 2 FINAL_APPROVER

---

## §5 Post-Approval Automation

Edge Functions. Not DB triggers. Consistent with spec §9.2 and the existing bulk/JR-fanout pattern.

### §5.1 `apply_termination_approval` Edge Function

Invoked when a termination workflow approves. Steps:

1. **Same-day or past-dated termination:** execute immediately. Future-dated: skip, leave for the scheduled Edge Function (§5.3).
2. Close current open employment slice: `UPDATE employee_employment SET effective_to = termination_date WHERE employee_id=? AND effective_to='9999-12-31'`.
3. Insert new employment slice: `effective_from = termination_date + 1`, `status='Inactive'`, all other fields copied from the closing slice.
4. Set `employees.status='Inactive'`. **This fires `sync_profile_on_employee_status` which auto-closes JR sets (§1 decision #2).**
5. Stamp `employee_terminations.scheduled_executed=true`, `scheduled_executed_at=NOW()`.
6. Fire downstream integration events (payroll cutoff, identity provider deactivation — stubs for now).
7. Dispatch notifications per §11.
8. Per-row `BEGIN/EXCEPTION` so a single failure doesn't abort the function.

### §5.2 `apply_termination_reversal` Edge Function

1. Mark original termination: `workflow_status='REVERSED'`. Unlocks the partial unique index.
2. Delete the inactive employment slice (`effective_from = original.termination_date + 1`).
3. Reopen prior slice: `effective_to='9999-12-31'`.
4. Set `employees.status='Active'`. **Does NOT auto-restore JR — JR memory locked decision says no auto-restore on re-activation.** HR must reassign JR manually.
5. Dispatch notifications per §11.

### §5.3 `process_scheduled_terminations` Edge Function (daily cron)

Runs once daily via Supabase scheduled trigger.

```sql
SELECT id FROM employee_terminations
WHERE workflow_status='APPROVED'
  AND termination_date <= CURRENT_DATE
  AND scheduled_executed=false
FOR UPDATE SKIP LOCKED;
```

For each row, invoke `apply_termination_approval` with the row's ID. Per-row `BEGIN/EXCEPTION` to isolate failures. Audit logged.

---

## §6 UI Surfaces

Every surface explicitly clones an existing pattern — see decision #16.

### §6.1 New shared components

```
src/components/shared/TerminationPortlet.tsx
src/components/shared/TerminationForm.tsx          (self-service variant)
src/components/shared/TerminationHRForm.tsx        (HR/Admin variant)
src/components/shared/TerminationReversalForm.tsx
src/components/shared/TerminationConfirmDialog.tsx
src/components/admin/TerminationImpactModal.tsx   (mirrors DeactivationImpactModal from JR)
```

### §6.2 MyProfile section — self-service

Mirror the Identification section pattern (line ~1998 in `MyProfile/index.tsx`):
- New section `<section id="mps-termination">`.
- Title "Termination" + pending pill driven by `pendingCounts['termination']`.
- Shows current termination state if one exists; otherwise a "Submit Resignation" button.
- Confirmation dialog (§11.1 of spec) shown before submission.

### §6.3 EmployeeEditPanel — HR/Admin

Mirror the Identification edit block:
- New `newTerminationForm` state mirroring `newIdForm`.
- Shows the HR-only fields: `Eligible for Rehire`, `Regrettable Termination`, full TERMINATION_REASON picklist.
- Trigger `TerminationImpactModal` before submission to show direct-reports + JR impact.

### §6.4 EmployeeDetails

Mirror Identification column + tab pattern. Add a "Termination" tab showing termination history (including REVERSED records, gated by `termination.history`).

### §6.5 ApproverInbox — `TerminationEnrichment`

Mirrors **BankEnrichment** at line ~1421. Dictionary entries:

```ts
MODULE_LABELS['profile_termination'] = 'Profile – Termination';
MODULE_EDIT_PERMISSION['profile_termination'] = 'termination.edit';
PROFILE_INLINE_MODULES.add('profile_termination');
PROFILE_FIELD_LABELS['termination'] = {
  termination_date: 'Termination Date',
  termination_reason_code: 'Termination Reason',
  resignation_date: 'Resignation Date',
  notice_date: 'Notice Date',
  last_working_date: 'Last Working Date',
  notice_period_waived: 'Notice Period Waived',
  notice_period_waiver_reason: 'Waiver Reason',
  eligible_for_rehire: 'Eligible for Rehire',
  regrettable_termination: 'Regrettable Termination',
  comments: 'Comments',
};
PROFILE_DATE_FIELDS.add('termination_date');
PROFILE_DATE_FIELDS.add('resignation_date');
PROFILE_DATE_FIELDS.add('notice_date');
PROFILE_DATE_FIELDS.add('last_working_date');
PROFILE_PICKLIST_FIELDS['profile_termination'] = {
  termination_reason_code: ['RESIGNATION_REASON', 'TERMINATION_REASON'], // resolver picks by initiation type
};
FULL_REVIEW_MODULES.add('profile_termination');
```

A reversal renders as a "Termination Reversal — [reason]" header above the diff view; the diff shows the original termination data + reversal reason.

### §6.6 WorkflowReview — `profile_termination` block

Mirror the `profile_bank` block exactly: same `bankChangeLoading`/`bankChangeData` fetch pattern adapted to termination, same Section wrapper, summary card, and `WfrAttachmentRow` for attachments. Add `profile_termination` to `FULL_REVIEW_MODULES`.

### §6.7 Permission Matrix

- New row "Termination" in the **EMPLOYEE band** with V / E / H columns (`view`, `edit`, `history`). C and D columns hidden — termination doesn't use create/delete semantics outside the dedicated form.
- Bulk perms `bulk_import` / `bulk_export` surface separately in the **IMPORT/EXPORT band** via the framework registry — no additional matrix code needed.

### §6.8 No hire-wizard surface

Termination is post-hire. AddEmployee is unaffected.

---

## §7 Picklists (full code listing)

### §7.1 RESIGNATION_REASON

| Code | Label |
|---|---|
| BETTER_OPPORTUNITY | Better Opportunity |
| HIGHER_STUDIES | Higher Studies |
| RELOCATION | Relocation |
| PERSONAL_REASONS | Personal Reasons |
| FAMILY_COMMITMENTS | Family Commitments |
| HEALTH_REASONS | Health Reasons |
| RETIREMENT | Retirement |
| OTHER | Other |

### §7.2 TERMINATION_REASON

| Code | Label |
|---|---|
| PERFORMANCE | Performance |
| MISCONDUCT | Misconduct |
| POLICY_VIOLATION | Policy Violation |
| PROBATION_FAILURE | Probation Failure |
| ABSCONDING | Absconding |
| POSITION_REDUNDANCY | Position Redundancy |
| ORG_RESTRUCTURING | Organisation Restructuring |
| END_OF_CONTRACT | End of Contract |
| RETIREMENT | Retirement |
| DEATH | Death |
| OTHER | Other |

Codes immutable; labels admin-editable via the picklist management screen.

---

## §8 Permissions

| Permission | Description |
|---|---|
| termination.view | View termination records and history |
| termination.edit | Create, edit, withdraw, reverse termination transactions |
| termination.history | Access full history including REVERSED records |
| termination.bulk_import | CSV import via Bulk Operations Framework |
| termination.bulk_export | CSV export via Bulk Operations Framework |

No default grants. Bulk perms intentionally locked down to a small admin group per decision #8.

---

## §9 Reversal Flow (separate-table model — decision #5)

1. HR submits a `Reverse Termination` transaction → row inserted in `employee_termination_reversals` linked to the original termination.
2. `wf_submit('termination', reversal_id, kind='reversal')` starts the reversal approval.
3. On final approval:
   - Reversal row: `workflow_status='APPROVED'`, `approved_at/by` stamped.
   - Original termination row: `workflow_status='REVERSED'`, `approved_at/by` of the reversal recorded for cross-reference.
   - `apply_termination_reversal` Edge Function executes (§5.2).
4. Partial unique index now permits a new termination for the same employee.

Reversal is not a direct override. It participates fully in the workflow engine.

---

## §10 Rehire Support

- Existing termination row is never modified on rehire — preserved permanently.
- New `employee_employment` slice begins at the rehire date (effective-dated normal employment flow).
- Partial unique index allows a fresh termination if the rehired employee subsequently leaves: their previous APPROVED termination doesn't block a new one because the rehire created a new employment timeline.

Edge case: if the previous termination was REVERSED and a new termination is needed for a separate event, the REVERSED status excludes it from the unique index, so the new submission proceeds without conflict.

---

## §11 Notifications

Dispatched via the existing notification framework. Templates seeded in the schema mig:

| Event | Recipients |
|---|---|
| Termination submitted | Submitter's manager |
| Termination approved (final) | Employee, HR group |
| Termination rejected | Submitter |
| Termination withdrawn | Manager, HR group |
| Termination reversed | HR group, original approvers (audit trail of `wf_step_action`) |
| Bulk termination batch processed | Bulk uploader, HR group (one summary per `upload_batch_id`) |

---

## §12 Audit

All standard Prowess audit columns are present. The existing `audit_employees` trigger covers `employees.status` flips. `audit_employee_terminations` and `audit_employee_termination_reversals` triggers — modelled on `audit_employee_education` — track all column changes.

Attachment uploads + deletes audited via `audit_employee_termination_attachments`.

`workflow_action_log` continues to be the source of truth for approval-step transitions (no new audit table for that).

---

## §13 Reporting

Identical to spec §18 — no new reporting infrastructure required. All reports are derived views on `employee_terminations`:

```sql
-- Voluntary attrition (last 12 months)
SELECT date_trunc('month', termination_date) AS month, count(*)
FROM employee_terminations
WHERE workflow_status = 'APPROVED'
  AND termination_initiation_type = 'SELF'
  AND termination_date >= CURRENT_DATE - INTERVAL '12 months'
GROUP BY 1 ORDER BY 1;
```

Regrettable attrition, rehire eligibility, monthly trends, etc. all follow the same filter-on-columns shape. No materialised views unless query perf demands it later.

---

## §14 Bulk Framework Integration (decision #8)

Termination registers as the **17th template** in `bulk_template_registry`.

### §14.1 Registry row

```jsonb
{
  "code": "termination",
  "label": "Termination",
  "module": "termination",
  "processor_rpc": "upsert_termination_bulk",
  "schema_definition": {
    "columns": [
      {"name":"Employee Id","field":"employee_id","required":true,"type":"text"},
      {"name":"Termination Date","field":"termination_date","required":true,"type":"date"},
      {"name":"Termination Reason Code","field":"termination_reason_code","required":true,"type":"picklist","picklist":"TERMINATION_REASON"},
      {"name":"Last Working Date","field":"last_working_date","required":false,"type":"date"},
      {"name":"Notice Period Waived","field":"notice_period_waived","required":false,"type":"boolean"},
      {"name":"Notice Period Waiver Reason","field":"notice_period_waiver_reason","required":false,"type":"text"},
      {"name":"Eligible For Rehire","field":"eligible_for_rehire","required":false,"type":"boolean"},
      {"name":"Regrettable Termination","field":"regrettable_termination","required":false,"type":"boolean"},
      {"name":"Comments","field":"comments","required":true,"type":"text"},
      {"name":"Operation","field":"_operation","required":false,"type":"text","values":["CREATE","REVERSE"]}
    ]
  },
  "exporter_query": "..."
}
```

### §14.2 `bulk_export` RPC — 17 WHEN clauses

The Education-shipped mig 381 sets `bulk_export` to 16 WHEN clauses. Termination's mig must `CREATE OR REPLACE FUNCTION bulk_export(...)` with 17 — adding the WHEN branch for `'termination'` with its own `user_can('termination','bulk_export',NULL)` guard.

### §14.3 Bulk lifecycle

1. CSV uploaded → validator Edge Function checks `termination.bulk_import` permission, picklist codes, date format, employee IDs.
2. Processor Edge Function calls `upsert_termination_bulk` per row, batch-stamped with one `upload_batch_id`.
3. Each row jumps straight to `workflow_status='APPROVED'`, `termination_initiation_type='SYSTEM_INITIATED'`.
4. Post-approval Edge Function runs per row (slice closure etc.) — same path as workflow approval.
5. Future-dated rows wait for the daily scheduler (§5.3).

### §14.4 Bulk rollback path

`upload_batch_id` enables a per-batch reversal workflow as a future enhancement (HR can review the batch and submit reversals for all rows in one transaction). v1 ships without this — individual reversals only.

---

## §15 Phase Plan

8 phases, ~14 working days. Each phase is independently shippable and testable.

### Phase 1 — Schema + Permissions + Picklists (≈2 days)
- **Mig 20260530382** — `employee_terminations` + `employee_termination_reversals` + `employee_termination_attachments` tables + indexes + partial unique constraints.
- **Mig 20260530383** — `employee_employment.notice_period_days` ADD COLUMN + drop legacy `end_date` / `termination_reason_code` after data migration.
- **Mig 20260530384** — picklist seeds (RESIGNATION_REASON 8 codes + TERMINATION_REASON 11 codes) + 5 permission seeds.
- Audit triggers for new tables.

### Phase 2 — RPCs (≈2 days)
- **Mig 20260530385** — all CRUD RPCs: `submit_termination`, `submit_termination_reversal`, `withdraw_termination`, `get_employee_terminations`, `get_termination_history`, `get_termination_deactivation_impact`, `derive_termination_initiation_type`.

### Phase 3 — Workflow Integration (≈2 days)
- **Mig 20260530386** — new `termination` workflow module; modify `wf_submit` with concurrent guard (§4.2); approval triggers for `apply_termination_approval` and `apply_termination_reversal`; default workflow templates seeded.

### Phase 4 — Edge Functions (≈2.5 days)
- Deploy `apply_termination_approval` Edge Function.
- Deploy `apply_termination_reversal` Edge Function.
- Deploy `process_scheduled_terminations` Edge Function + register daily Supabase scheduled trigger.
- Notification templates seeded via accompanying mig.

### Phase 5 — Bulk Framework Hook (≈1.5 days)
- **Mig 20260530387** — registry row for termination + processor RPC `upsert_termination_bulk` + 2 bulk permission seeds + `CREATE OR REPLACE bulk_export` with 17 WHEN clauses.
- Smoke-test all 17 templates after replace.

### Phase 6 — Frontend (self-service + HR/Admin) (≈2 days)
- `TerminationPortlet`, `TerminationForm`, `TerminationHRForm`, `TerminationConfirmDialog`, `TerminationReversalForm`, `TerminationImpactModal`.
- MyProfile section + EmployeeEditPanel section + EmployeeDetails column.

### Phase 7 — Frontend (approver + workflow review + matrix) (≈1.5 days)
- ApproverInbox `TerminationEnrichment` + all dictionary entries.
- WorkflowReview `profile_termination` block + `FULL_REVIEW_MODULES` addition.
- PermissionMatrix EMPLOYEE-band row.

### Phase 8 — Documentation + Verification (≈0.5 day)
- Add Part 18 to `prowess_system_docs.html`.
- Update memory file `prowess-termination.md`.
- Integration tests: JR fanout verification, concurrent guard, reversal flow, future-dated scheduler, bulk processor, 17-template smoke test.

---

## §16 Files Inventory

### §16.1 Backend (8 migrations + 3 Edge Functions)

| Mig | Description |
|---|---|
| 20260530382 | Termination + reversal + attachment tables, indexes, constraints, audit triggers |
| 20260530383 | `employee_employment.notice_period_days` + legacy column removal |
| 20260530384 | Picklist seeds + permission seeds |
| 20260530385 | All termination RPCs |
| 20260530386 | Workflow module, `wf_submit` guard, approval triggers, default templates |
| 20260530387 | Bulk registry row + processor RPC + `CREATE OR REPLACE bulk_export` with 17 WHEN clauses + bulk permission seeds |
| (+notification mig) | Notification template seeds — can fold into 384 if compact |

Edge Functions:
- `supabase/functions/apply_termination_approval/index.ts`
- `supabase/functions/apply_termination_reversal/index.ts`
- `supabase/functions/process_scheduled_terminations/index.ts`

### §16.2 Frontend new files

```
src/components/shared/TerminationPortlet.tsx
src/components/shared/TerminationForm.tsx
src/components/shared/TerminationHRForm.tsx
src/components/shared/TerminationReversalForm.tsx
src/components/shared/TerminationConfirmDialog.tsx
src/components/admin/TerminationImpactModal.tsx
src/hooks/useTerminationData.ts
```

### §16.3 Frontend modifications (with line-level hints)

| File | Edit |
|---|---|
| `MyProfile/index.tsx` | Perm registry entry (~line 1124); new `<section id="mps-termination">` (~line 2000 area); `useTerminationData` fetch added to `useEmployeeData` flow |
| `EmployeeEditPanel.tsx` | New HR-only termination block (~line 800+); `newTerminationForm` state mirroring `newIdForm`; `TerminationImpactModal` trigger before submit |
| `EmployeeDetails.tsx` | New Termination column/tab mirroring Identification |
| `ApproverInbox.tsx` | Dictionary entries (lines 824–878 area); `TerminationEnrichment` component modelled on `BankEnrichment` (line 1421); reversal sub-render |
| `WorkflowReview.tsx` | `profile_termination` block mirroring `profile_bank`; `FULL_REVIEW_MODULES.add('profile_termination')` |
| `src/components/admin/permissions/PermissionMatrix.tsx` | EMPLOYEE-band row "Termination" (V/E/H) |
| `AddEmployee.tsx` | **No changes** — termination is post-hire |
| `prowess_system_docs.html` | Add Part 18 — Termination |
| `src/components/admin/BulkOperations/...` | **No code changes** — framework picks up the new registry row automatically |

---

## §17 Related Projects

- [[prowess-employment-effective-dating]] — `notice_period_days` lives on the satellite this module shipped
- [[prowess-job-relationships]] — `sync_profile_on_employee_status` fanout we depend on; `get_deactivation_impact` extended
- [[prowess-workflow-engine]] — `wf_submit`/`wf_approve` engine + new `termination` module + concurrent guard hook
- [[prowess-bulk-operations]] — termination registers as the 17th template
- [[prowess-education]] — previous module (16th template); same design-doc pattern mirrored here
- [[prowess-set-snapshot-rewrite]] — pattern reference only; termination is NOT set-snapshot (event table)
