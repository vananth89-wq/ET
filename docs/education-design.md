# Education Module — Design Spec

**Status:** Locked design, pre-implementation
**Scope:** Multi-row satellite table capturing employee academic and professional qualifications. **Non-effective-dated** (no slice timeline; each record is a discrete fact about an employee's past). Soft-delete via `is_active=false`. Workflow-gated. Hire-wizard-integrated.
**Author:** 2026-05-31 design session
**Reference templates:**
- `docs/job-relationships-design.md` — closest workflow-gated satellite pattern
- Existing `identity_records` / `passports` tables — closest non-effective-dated multi-row pattern
- `docs/bulk-operations-framework.md` — Education plugs in as the 16th template

---

## 1. Decision Summary

All decisions locked.

| Topic | Decision |
|---|---|
| Data shape | Multi-row satellite, one row per qualification, **non-effective-dated**. Soft-delete via `is_active=false`. Closest analogue: `identity_records`. |
| Picklists | Three new: `EDUCATION_LEVEL` (8 values), `COMPLETION_STATUS` (4 values), `EDUCATION_DOCUMENT_TYPE` (5 values for attachments). Codes immutable, labels admin-editable. |
| Validations | (1) end_date >= start_date; (2) Completed status → end_date present AND ≤ today; (3) only one is_highest_qualification per employee; (4) UNIQUE on (employee_id, education_level, institution, start_date) for non-soft-deleted rows |
| Highest qualification semantics | Atomic swap: when a row is marked `is_highest_qualification=true`, the RPC silently unticks any previous highest in the same call. Avoids confusing partial-unique-index rejections. |
| Attachments | **Multi-attachment per record** (matches identity_records). Document types from `EDUCATION_DOCUMENT_TYPE` picklist. |
| Workflow gating | **Yes** — `profile_education` workflow module. ESS submits change requests; HR/admin approves. Same dual-path RPC pattern as personal_info / passport. |
| Hire wizard integration | **Yes** — new Education tab in `AddEmployee.tsx` between Identification and Bank. Educations entered during hire materialise on activation, same as passports/identification today. |
| ESS visibility | Read-only in MyProfile by default. Edits gated to `education.edit` (granted to ESS in default permission seeds). |
| Verification flag | **Deferred to v2.** Completion status alone is the truth for now. |
| Permissions | `education.view`, `.create`, `.edit`, `.delete`, `.history`, `.bulk_import`, `.bulk_export` |
| Bulk operations | Plugs into the Bulk Operations Framework as the **16th template**. Registered with `bulk_template_registry`, processor RPC `upsert_education`. |
| Backfill | None — net-new feature. |
| Audit | Existing `audit_log` pattern via the trigger applied to satellite tables. No new audit work. |
| UI surface mirrors | MyProfile section mirrors **Identification**. EmployeeEditPanel section mirrors **Identification**. AddEmployee hire tab mirrors **Identification**. EmployeeDetails column mirrors **Identification**. ApproverInbox `EducationEnrichment` mirrors **BankEnrichment**. WorkflowReview `profile_education` section mirrors **profile_bank** section. (See §6.) |
| Permission Matrix | New row "Education" in the EMPLOYEE section band (V/C/E/D/H — 5 standard action perms). Bulk perms (`bulk_import` / `bulk_export`) appear separately in the IMPORT/EXPORT band via the framework registry. (See §6.8.) |

---

## 2. Why This Module

Employee education is required for:
- **Hire onboarding** — proof of qualifications collected during the hire pipeline
- **Compliance** — regulated industries (banking, healthcare) need verifiable academic records
- **Promotion / role assignment** — HR needs the candidate's qualifications visible
- **Reporting** — distribution of qualifications across the workforce (for skills inventory and budgeting)

Currently Prowess has no place to capture this. HR records sit in spreadsheets or other systems. The Education module brings it into the core HRIS as a first-class satellite, queryable, exportable, and workflow-controlled.

---

## 3. Schema Design

### 3.1 `employee_education`

```sql
CREATE TABLE employee_education (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id              UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,

  education_level          TEXT NOT NULL,        -- ref_id from EDUCATION_LEVEL picklist
  degree                   TEXT NOT NULL,        -- free-form, e.g. "B.Tech in Computer Science"
  institution              TEXT NOT NULL,        -- free-form, e.g. "Anna University"
  field_of_study           TEXT,                 -- free-form, optional

  start_date               DATE NOT NULL,
  end_date                 DATE,                 -- nullable when status = Pursuing
  completion_status        TEXT NOT NULL,        -- ref_id from COMPLETION_STATUS picklist

  grade_or_gpa             TEXT,                 -- free-form, e.g. "First Class", "3.8/4.0"
  is_highest_qualification BOOLEAN NOT NULL DEFAULT false,

  is_active                BOOLEAN NOT NULL DEFAULT true,
  inactive_at              TIMESTAMPTZ,
  inactive_by              UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_by               UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_by               UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_edu_end_after_start
    CHECK (end_date IS NULL OR end_date >= start_date),

  CONSTRAINT chk_edu_completed_has_past_end
    CHECK (
      completion_status <> 'ES01'                      -- 'ES01' = Completed
      OR (end_date IS NOT NULL AND end_date <= CURRENT_DATE)
    )
);
```

### 3.2 Indexes & constraints

```sql
CREATE INDEX idx_edu_employee
  ON employee_education (employee_id);

CREATE INDEX idx_edu_employee_active
  ON employee_education (employee_id)
  WHERE is_active = true;

-- Exactly one highest qualification per employee (validation rule #3)
CREATE UNIQUE INDEX uq_edu_one_highest_per_employee
  ON employee_education (employee_id)
  WHERE is_highest_qualification = true AND is_active = true;

-- Duplicate prevention (validation rule #4)
CREATE UNIQUE INDEX uq_edu_no_dupes
  ON employee_education (employee_id, education_level, institution, start_date)
  WHERE is_active = true;
```

### 3.3 `employee_education_attachments`

Multi-attachment per record. Same pattern as `employee_dependent_attachments` and `identity_record_attachments`.

```sql
CREATE TABLE employee_education_attachments (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  education_id        UUID NOT NULL REFERENCES employee_education(id) ON DELETE CASCADE,
  employee_id         UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,

  document_type       TEXT NOT NULL,                -- ref_id from EDUCATION_DOCUMENT_TYPE picklist
  file_name           TEXT NOT NULL,
  original_file_name  TEXT NOT NULL,
  file_path           TEXT NOT NULL,                -- hr-attachments storage path
  mime_type           TEXT NOT NULL,
  file_size           BIGINT NOT NULL CHECK (file_size > 0),
  is_active           BOOLEAN NOT NULL DEFAULT true,
  uploaded_by         UUID REFERENCES profiles(id) ON DELETE SET NULL,
  uploaded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by          UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_edu_att_education ON employee_education_attachments (education_id);
CREATE INDEX idx_edu_att_employee  ON employee_education_attachments (employee_id);
```

Storage path convention: `education/{employee_id}/{education_id}/{timestamp}_{filename}` in the `hr-attachments` bucket.

### 3.4 Picklist seeds

```sql
INSERT INTO picklists (picklist_id, label) VALUES
  ('EDUCATION_LEVEL',         'Education Level'),
  ('COMPLETION_STATUS',       'Completion Status'),
  ('EDUCATION_DOCUMENT_TYPE', 'Education Document Type');

INSERT INTO picklist_values (picklist_id, ref_id, value, sort_order, active) VALUES
  ('EDUCATION_LEVEL', 'EDU01', 'High School',                1, true),
  ('EDUCATION_LEVEL', 'EDU02', 'Diploma',                    2, true),
  ('EDUCATION_LEVEL', 'EDU03', 'Bachelor Degree',            3, true),
  ('EDUCATION_LEVEL', 'EDU04', 'Master Degree',              4, true),
  ('EDUCATION_LEVEL', 'EDU05', 'MBA',                        5, true),
  ('EDUCATION_LEVEL', 'EDU06', 'PhD',                        6, true),
  ('EDUCATION_LEVEL', 'EDU07', 'Certification',              7, true),
  ('EDUCATION_LEVEL', 'EDU08', 'Professional Qualification', 8, true),

  ('COMPLETION_STATUS', 'ES01', 'Completed',     1, true),
  ('COMPLETION_STATUS', 'ES02', 'Pursuing',      2, true),
  ('COMPLETION_STATUS', 'ES03', 'Discontinued',  3, true),
  ('COMPLETION_STATUS', 'ES04', 'On Hold',       4, true),

  ('EDUCATION_DOCUMENT_TYPE', 'ED01', 'Certificate',          1, true),
  ('EDUCATION_DOCUMENT_TYPE', 'ED02', 'Mark Sheet',           2, true),
  ('EDUCATION_DOCUMENT_TYPE', 'ED03', 'Transcript',           3, true),
  ('EDUCATION_DOCUMENT_TYPE', 'ED04', 'Provisional',          4, true),
  ('EDUCATION_DOCUMENT_TYPE', 'ED05', 'Other',                5, true);
```

### 3.5 RLS

Standard dual-path pattern (matches dependents, bank, job_relationships):

- **Path A (scoped)**: `user_can('education', '<action>', employee_id)`
- **Path B (HR pipeline)**: `user_can('education', '<action>', NULL)` AND `user_can('hire_employee', '<view|edit>', NULL)` AND `employees.status IN ('Draft','Incomplete','Pending')`

Policy prefix: `edu_select / edu_insert / edu_update / edu_delete` on both `employee_education` and `employee_education_attachments`.

---

## 4. RPC Contracts

Mirrors the `identity_records` / `passports` RPC family with workflow staging.

### 4.1 `upsert_education(p_employee_id uuid, p_education_data jsonb, p_education_id uuid DEFAULT NULL) RETURNS jsonb`

`SECURITY DEFINER`. Dual-path: PATH A direct write, PATH B workflow staging.

**Returns:**
- PATH A: `{ ok: true, workflow: false, education_id }`
- PATH B: `{ ok: true, workflow: true, instance_id, pending_change_id }`
- Errors: `{ ok: false, error, message }`

**`p_education_data` shape:**
```json
{
  "education_level":          "EDU03",
  "degree":                   "B.Tech in Computer Science",
  "institution":              "Anna University",
  "field_of_study":           "Computer Science",
  "start_date":               "2012-06-01",
  "end_date":                 "2016-04-30",
  "completion_status":        "ES01",
  "grade_or_gpa":             "First Class",
  "is_highest_qualification": false,
  "attachments": [
    {
      "document_type":      "ED01",
      "file_name":          "btech_certificate.pdf",
      "original_file_name": "btech_certificate.pdf",
      "file_path":          "education/{emp_id}/_new_{uuid}/btech_cert.pdf",
      "mime_type":           "application/pdf",
      "file_size":          120384
    }
  ]
}
```

**Validations enforced in the RPC:**
- Access guard (Path A / Path B)
- `education_level` exists in `EDUCATION_LEVEL` picklist + active
- `completion_status` exists in `COMPLETION_STATUS` picklist + active
- `start_date` not null; `end_date` (if non-null) >= `start_date`
- If `completion_status = 'ES01'` (Completed): `end_date` not null AND <= today
- Each attachment's `document_type` exists in `EDUCATION_DOCUMENT_TYPE` picklist + active

**Highest-qualification atomic swap:**
When `p_education_data.is_highest_qualification = true`:
```sql
UPDATE employee_education
SET is_highest_qualification = false, updated_by = v_actor, updated_at = NOW()
WHERE employee_id = p_employee_id
  AND is_highest_qualification = true
  AND is_active = true
  AND (p_education_id IS NULL OR id <> p_education_id);
```
Then INSERT/UPDATE the new row. Together this is one transaction; the partial unique index sees only one row with the flag at any moment.

### 4.2 `remove_education(p_employee_id uuid, p_education_id uuid) RETURNS jsonb`

Soft-delete. Sets `is_active = false`, `inactive_at = NOW()`, `inactive_by = auth.uid()` on the row and cascades to attachments (sets attachment.is_active = false). Dual-path same as upsert.

### 4.3 `get_employee_education(p_employee_id uuid, p_include_inactive boolean DEFAULT false) RETURNS jsonb`

Returns rows ordered by `is_highest_qualification DESC, end_date DESC NULLS FIRST, start_date DESC`. Includes attachments per record. Returns `{ ok: true, education: [...] }`.

### 4.4 `get_employee_education_history(p_employee_id uuid) RETURNS jsonb`

Same as get_employee_education but includes soft-deleted rows. Gated on `education.history` OR `education.view`.

---

## 5. Workflow Integration

### 5.1 `submit_change_request` snapshot branch

```sql
WHEN 'profile_education' THEN
  -- For an edit, snapshot the current row identified by p_record_id
  IF p_record_id IS NOT NULL THEN
    SELECT to_jsonb(ee.*)
    INTO v_current_row
    FROM employee_education ee
    WHERE ee.id = p_record_id AND ee.is_active = true;
  ELSE
    v_current_row := NULL;  -- new record, no current snapshot
  END IF;
```

### 5.2 `apply_profile_pending_change` branch

```sql
ELSIF v_module = 'profile_education' THEN
  v_result := upsert_education(
    v_emp_id,
    v_data,
    NEW.record_id   -- NULL = create new; non-null = edit existing
  );
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE WARNING 'apply_profile_pending_change: upsert_education failed for employee=%, error=%',
      v_emp_id, v_result->>'error';
  END IF;
```

For removals (the user clicks Delete on an existing record while workflow is configured), the staging row carries `proposed_data = { _operation: 'remove', education_id: <uuid> }` and the apply branch calls `remove_education` instead. Same pattern as the dependents removal flow.

### 5.3 `EducationEnrichment` component in `ApproverInbox.tsx`

New dedicated component (not the generic fallback). Resolves picklist UUIDs to labels (education_level, completion_status, document_type), shows old → new diff for amendments, renders attachment list with signed URLs from `hr-attachments`.

Required dictionary entries:
```ts
PROFILE_FIELD_LABELS['education'] = {
  education_level:          'Education Level',
  degree:                   'Degree',
  institution:              'Institution',
  field_of_study:           'Field of Study',
  start_date:               'Start Date',
  end_date:                 'End Date',
  completion_status:        'Status',
  grade_or_gpa:             'Grade / GPA',
  is_highest_qualification: 'Highest Qualification',
};
PROFILE_DATE_FIELDS.add('start_date');
PROFILE_DATE_FIELDS.add('end_date');
PROFILE_PICKLIST_FIELDS['profile_education'] = {
  education_level:   'EDUCATION_LEVEL',
  completion_status: 'COMPLETION_STATUS',
};
```

### 5.4 `WorkflowReview` full-page support

Add `'profile_education'` to `FULL_REVIEW_MODULES` allowlist. Same `EducationEnrichment` renders.

---

## 6. UI Surfaces (each surface mirrors an existing analogous pattern)

### 6.1 `EducationPortlet.tsx` (new) — satellite table

Multi-row table layout matching the satellite-card pattern used by `identity_records` in MyProfile. One row per active education record. Header columns: Degree · Institution · Field of Study · Dates · Status · Actions.

- Star/highlight badge on the row marked `is_highest_qualification`
- Per-row actions: pencil (edit), trash (delete) — gated on permissions + `pendingCount['profile_education'] === 0`
- "Add Education" button opens the form modal
- Sort: highest qualification first, then `end_date DESC NULLS FIRST, start_date DESC`
- Empty state: "No education records on file."

Form modal (Add / Edit / Amend mid-flight, mirrors the existing identity_records "Add ID" form pattern):
- Education Level (picklist dropdown — EDUCATION_LEVEL)
- Degree (text)
- Institution (text)
- Field of Study (text, optional)
- Start Date (date picker)
- End Date (date picker, disabled when status = Pursuing)
- Completion Status (picklist dropdown — COMPLETION_STATUS)
- Grade / GPA (text, optional)
- Highest Qualification (checkbox with hint when ticked: "This will be marked as your highest qualification, replacing any current selection")
- Attachments section (multi-file with per-file Document Type dropdown from EDUCATION_DOCUMENT_TYPE — required for each attachment). Mirrors the `DependentsPortlet` attachment row pattern: upload + remove + document-type dropdown.
- Save / Cancel buttons

Validation:
- Real-time client-side: end_date >= start_date; Completed → end_date <= today; document_type required on each attachment
- Server-side RPC re-validates + returns row-level errors

### 6.2 `MyProfile/index.tsx` Education section — mirrors Identification section

Add a new section after `Identification` (around line 2000 in current code). The new section uses the EXACT same shape as the existing identification section:

```tsx
<section id="mps-education" ref={el => { sectionRefs.current.education = el; }} className="mp-section">
  <SectionTitle
    icon="fa-graduation-cap"
    text="Education"
    pending={pendingCounts['profile_education'] ?? 0}
    onViewProgress={() => openParticipants('profile_education', 'Education')}
  />
  {educationRecords.length === 0 ? (
    <p>No education records on file.</p>
  ) : (
    <EducationPortlet
      records={educationRecords}
      mode="my_profile"
      canEdit={can('education.edit') && pendingCounts['profile_education'] === 0}
      onSubmit={(payload, recordId) => submitProfileChange('profile_education', payload, recordId)}
      onRemove={(recordId) => submitProfileChange('profile_education', {_operation: 'remove'}, recordId)}
    />
  )}
</section>
```

- Pending pill (amber "Workflow pending approval") fires from `SectionTitle` when `pendingCounts['profile_education'] > 0` — same as identification today
- "View approval progress" link opens the `WorkflowParticipantsModal` for the in-flight instance, same wiring as identification's `openParticipants('profile_identification', ...)`
- ESS edit submits through `submit_change_request('profile_education', payload, record_id)` — same path as the identification module today

Page-level state additions:
- `educationRecords` derived from a new fetch in `useEmployeeData` (mirrors `idRecords`)
- `viewPermission: 'education.view'` added to the section registry around line 1124

### 6.3 `EmployeeEditPanel.tsx` Education section — mirrors Identification section

Admin direct-edit. Mirrors the identification block (around line 800+):

- Same EducationPortlet rendered with `mode="admin"`, `canEdit={can('education.edit')}`
- Writes go through the admin direct-write path on `upsert_education` (skips workflow staging; mirrors how `upsert_identity_record` is called directly from admin today)
- The "Add ID" form pattern from `newIdForm` state (line 729) is replaced by `newEducationForm` state with the same shape
- "Education History" link below the table opens a panel of soft-deleted records (gated on `education.history`)

### 6.4 `AddEmployee.tsx` hire wizard Education tab — mirrors Identification tab

A new wizard tab "Education" between Identification and Bank tabs. Mirrors the Identification tab structure:

- Tab definition added to the wizard tab registry with the same `requiresValidation` + `markedComplete` flags as identification
- `<EducationPortlet>` rendered with `isNewHire={true}` + the wizard's hire context
- Records added during hire are written to `employee_education` with the hire's employee_id and `is_active=true`. Activation flow does NOT need a special "promote from draft" step — the rows are written directly, same as identification records during hire today.
- Multi-attachment uploads go to `hr-attachments` bucket under the `education/{employee_id}/_new_{uuid}/...` path. On hire activation, the path is rewritten to `education/{employee_id}/{education_id}/...` as a post-insert step (mirrors the identity_records attachment pattern).

### 6.5 `EmployeeDetails.tsx` Education column — mirrors Identification column

Admin-side employee detail view. Two things mirroring identity:

- A new "Education" summary in the employee detail header showing count + highest qualification label (icon: fa-graduation-cap, mirrors the identity icon placement)
- A new Education tab in the detail tabs panel rendering the read-only EducationPortlet (mirrors how identity_records get their own tab)

### 6.6 `ApproverInbox.tsx` — `EducationEnrichment` component (mirrors BankEnrichment)

The inbox panel for `profile_education` workflow tasks. **Modelled exactly on `BankEnrichment` (line 1421+ in ApproverInbox.tsx) and `DependentsEnrichment` (line 1134+)** — read-only diff viewer for the proposed change, with picklist resolution + attachment thumbnails.

```ts
function EducationEnrichment({ metadata, instanceId, editMode, onExitEdit }: {
  metadata: Record<string, unknown>;
  instanceId: string;
  editMode?: boolean;
  onExitEdit?: () => void;
}) {
  // 1. Resolve picklist labels: education_level (EDUCATION_LEVEL),
  //    completion_status (COMPLETION_STATUS), attachment doc_type (EDUCATION_DOCUMENT_TYPE)
  // 2. Render proposed values as cards (matches the field-card layout used by BankEnrichment)
  // 3. If amendment, show old → new diff with strike-through on old values
  // 4. Attachments grid: file name + signed URL + doc type label (matches Bank attachment grid)
  // 5. If editMode, render approver-edit form with save → wf_approver_update_pending_changes
}
```

Required dictionary entries in `ApproverInbox.tsx` (around lines 824–878):

```ts
MODULE_LABELS['profile_education'] = 'Profile – Education';
MODULE_EDIT_PERMISSION['profile_education'] = 'education.edit';
PROFILE_INLINE_MODULES.add('profile_education');
PROFILE_FIELD_LABELS['education'] = {
  education_level:          'Education Level',
  degree:                   'Degree',
  institution:              'Institution',
  field_of_study:           'Field of Study',
  start_date:               'Start Date',
  end_date:                 'End Date',
  completion_status:        'Status',
  grade_or_gpa:             'Grade / GPA',
  is_highest_qualification: 'Highest Qualification',
};
PROFILE_DATE_FIELDS.add('start_date');
PROFILE_DATE_FIELDS.add('end_date');
PROFILE_PICKLIST_FIELDS['profile_education'] = {
  education_level:   'EDUCATION_LEVEL',
  completion_status: 'COMPLETION_STATUS',
};
```

Routing: `ProfileEnrichment` (the inbox's dispatcher) delegates to `EducationEnrichment` when `moduleCode === 'profile_education'`, same as it delegates to `BankEnrichment` for `profile_bank` and `DependentsEnrichment` for `profile_dependents`.

### 6.7 `WorkflowReview.tsx` profile_education section — mirrors profile_bank section

Full-page workflow review. Add `'profile_education'` to `FULL_REVIEW_MODULES` allowlist. Reuses the same `EducationEnrichment` component used by the inbox panel.

- Same `useEffect` pattern as `bankChangeLoading`/`bankChangeData` for fetching the proposed_data
- Same `Section` wrapper layout with the "Proposed Education Details" header
- Same `wfr-summary-grid` header card with key fields (Education Level, Degree, Institution, Start Date)
- "was: [prev value]" diff strikethrough where amendment vs new is detected
- Attachment list with `WfrAttachmentRow` (existing component) reading from `hr-attachments`

Banner above the diff if `op === 'remove'`: "This education record will be soft-deleted (is_active = false). It will remain visible in the History panel."

### 6.8 Permission Matrix row (new)

Add a new row to the existing Permission Matrix `EMPLOYEE` section band (where `Hire employee`, `Manage employees`, `Inactive employees` currently sit). The row label is **"Education"** with checkboxes in View / Create / Edit / Delete / History columns:

```
EMPLOYEE
  Hire employee          ✓ ✓ ✓ ✓ ✓
  Manage employees       — — — ✓ ✓
  Inactive employees     ✓ ✓ ✓ ✓ ✓
  Education              ✓ ✓ ✓ ✓ ✓   ← NEW (5 standard action perms)
```

The row binds to the five base permissions (`education.view`, `.create`, `.edit`, `.delete`, `.history`). The bulk perms (`education.bulk_import`, `education.bulk_export`) appear separately in the **IMPORT / EXPORT** section band below NEW HIRE (per the Bulk Operations Framework), as a row labelled "Education" with the inline Import / Export checkboxes.

So Education has presence in TWO permission matrix sections — same pattern as Picklist (in REFERENCE DATA + IMPORT/EXPORT), Project (in PROJECTS + IMPORT/EXPORT), and Exchange Rate (in EXCHANGE RATE + IMPORT/EXPORT). That's the right architecture: feature-level perms and bulk-operation perms are genuinely different capabilities.

Implementation note: the row title (`Education`) and the description tooltip text should live in the matrix's static module registry (`PermissionMatrix.tsx`), same place where `Hire employee`/`Manage employees`/`Inactive employees` are defined today.

---

## 7. Permissions

Mig 372 (placeholder) seeds:

```sql
INSERT INTO permissions (code, name, description, action) VALUES
  ('education.view',         'View Education',         'See employee education records', 'view'),
  ('education.create',       'Create Education',       'Add new education records',      'create'),
  ('education.edit',         'Edit Education',         'Modify existing education',      'edit'),
  ('education.delete',       'Delete Education',       'Soft-delete education records',  'delete'),
  ('education.history',      'View Education History', 'See full audit of changes',      'history'),
  ('education.bulk_import',  'Bulk Import Education',  'Upload CSV files to create/update education in bulk',  'bulk_import'),
  ('education.bulk_export',  'Bulk Export Education',  'Download education records as CSV',                    'bulk_export');
```

**Default grants:**
- `education.view` → ESS (own records only) + HR + System Admin
- `education.create` → ESS (own) + HR + System Admin
- `education.edit` → ESS (own) + HR + System Admin
- `education.delete` → HR + System Admin (ESS deletion goes through workflow)
- `education.history` → HR + System Admin
- `education.bulk_import` / `bulk_export` → admin enables per set (default OFF, framework convention)

---

## 8. Bulk Operations Integration

Education becomes the **16th template** registered in `bulk_template_registry`.

### 8.1 Registry row

```json
{
  "template_code":   "education",
  "display_label":   "Education",
  "description":     "Academic and professional qualifications per employee",
  "icon":            "ti-school",
  "permission_view": "education.bulk_export",
  "permission_edit": "education.bulk_import",
  "workflow_bypass": true,
  "processor_rpc":   "upsert_education",
  "row_processor":   "per_row",
  "natural_key":     ["Employee Code", "Education Level", "Institution", "Start Date"]
}
```

### 8.2 Bulk CSV schema (user-fillable columns)

```
| Employee Code * | Education Level * | Degree *  | Institution * | Field of Study | Start Date * | End Date   | Completion Status * | Grade or GPA | Is Highest Qualification |
| EMP1042         | EDU03             | B.Tech    | Anna University | Computer Sci | 06/01/2012   | 04/30/2016 | ES01                | First Class  | Yes                      |
| EMP1042         | EDU05             | MBA       | IIM Chennai     | HR Mgmt      | 06/01/2018   | 03/31/2020 | ES01                | Distinction  | No                       |
```

Yes/No column for is_highest_qualification (importer's atomic-swap logic handles the implicit untick of any previous highest).

Bulk attachments are not supported via CSV (URLs would be unwieldy and risky). Attachments stay portlet-only. Documented in the README.

### 8.3 Export shape

Same columns as the template. `Include system metadata` toggle adds `id`, `created_at`, `updated_at`, `created_by`, `updated_by`, `is_active`, `inactive_at`, `inactive_by`, plus display name columns (`Employee Name`, `Education Level Label`, `Completion Status Label`).

---

## 9. Phases & Sequencing

| Phase | Work | Migrations / Files | Estimate |
|---|---|---|---|
| 0 | Design doc (this file) + memory + Part 17 of HTML docs | — | ✅ Done |
| 1 | Schema: `employee_education` + `employee_education_attachments` + indexes + RLS + 3 picklists + 7 permission seeds | mig 371 | 1 day |
| 2 | RPCs: `upsert_education`, `remove_education`, `get_employee_education`, `get_employee_education_history` | mig 372 | 1.5 days |
| 3 | Workflow integration: `profile_education` branch in `submit_change_request` and `apply_profile_pending_change` | mig 373 | 0.5 days |
| 4 | Bulk Operations Framework registry seed (Education as 16th template) + extend `bulk_export` RPC from 15 to 16 WHEN clauses | mig 381 | 0.5 days |
| 5 | Frontend: `EducationPortlet.tsx` (read + edit + draft modes) | new component | 2 days |
| 6 | Frontend: `MyProfile/index.tsx` Education section + `EmployeeEditPanel.tsx` admin write path | existing files | 1 day |
| 7 | Frontend: `AddEmployee.tsx` hire wizard Education tab + activation transfer | existing file | 1.5 days |
| 8 | Frontend: `EducationEnrichment` component + `ApproverInbox.tsx` dictionary entries + `WorkflowReview.tsx` profile_education section | existing files | 1.5 days |
| 9 | Frontend: `EmployeeDetails.tsx` Education column / summary | existing file | 0.5 days |
| 10 | Testing: hire flow with education, ESS edit with workflow, admin direct write, bulk import + export round trip | — | 1 day |

**Total: ~10 working days.** Smaller than JR (~16 days) because there's no set-snapshot, no deactivation fanout, no workflow approver type extension — just a standard satellite + workflow + bulk hook.

---

## 10. Migration File Numbering

**Updated 2026-05-31 (post-bulk-framework shipment):** Bulk Operations Framework already shipped at migs **373–377**, with mig 377 being the `bulk_export` RPC carrying 15 WHEN clauses (one per registered template). Next free slot is **20260530378+**.

Education ships at **migs 378–381**:

| Mig | What |
|---|---|
| 378 | Schema: `employee_education` + `employee_education_attachments` + indexes + RLS + 3 picklists + 7 permission seeds |
| 379 | RPCs: `upsert_education`, `remove_education`, `get_employee_education`, `get_employee_education_history` |
| 380 | Workflow integration: `submit_change_request` snapshot branch + `apply_profile_pending_change` branch for `profile_education` |
| 381 | Bulk template registry seed (16th template) + **EXTEND `bulk_export` RPC** to add the 16th WHEN clause for education. The existing mig 377 needs one more branch added inline. |

Critical implementation note: mig 381 must `CREATE OR REPLACE FUNCTION bulk_export(...)` with all 16 WHEN clauses, not just append one. Postgres can't extend a CASE expression in place.

---

## 11. Risk Register

| Risk | Mitigation |
|---|---|
| Highest-qualification swap race condition (two HR users mark different rows as highest simultaneously) | RPC uses advisory lock per employee (matches personal_info pattern) |
| Pursuing status with future end_date set by mistake | UI disables end_date when status=Pursuing; RPC validates server-side |
| Bulk upload includes is_highest=Yes on multiple rows for same employee | Validator catches as composite-key error before commit ("Multiple rows marked as highest for employee X") |
| Attachment storage paths collide on rapid re-upload | Path includes timestamp; existing pattern from identity_records |
| Education tab in hire wizard mid-fill abandonment | Wizard state already persists on every field change for other tabs; education follows the same pattern |
| Deleting an employee with education records | `ON DELETE CASCADE` on FK; cascades to attachments via FK on education_id |
| Soft-deleted records reappearing in bulk export | Export query default filters `WHERE is_active = true` unless "Include inactive records" toggle is ON |
| ES01 (Completed) constraint blocks legitimate completion in same day | Constraint accepts `end_date = CURRENT_DATE`; only future dates rejected |

---

## 12. Files Inventory

**Backend (migrations) — numbers 378-381 (post-bulk-framework shipment):**
- `mig 378` schema + 3 picklists + 7 permission seeds
- `mig 379` RPCs (upsert_education, remove_education, get_employee_education, get_employee_education_history)
- `mig 380` workflow integration (submit_change_request snapshot + apply_profile_pending_change branch)
- `mig 381` bulk template registry seed (16th template) + extend `bulk_export` RPC from 15 to 16 WHEN clauses

**Frontend (new):**
- `src/components/shared/EducationPortlet.tsx`
- `src/components/shared/EducationFormModal.tsx` (sub-component for Add / Edit form)

**Frontend (modified):**
- `src/components/employee/MyProfile/index.tsx` — new Education section after Identification (around line 2000); add `educationRecords` fetch in `useEmployeeData`; register `viewPermission: 'education.view'` around line 1124
- `src/components/admin/EmployeeEditPanel.tsx` — Education edit section mirroring Identification (around line 800+); `newEducationForm` state mirrors `newIdForm`; admin direct-write via `upsert_education` (skips workflow)
- `src/components/admin/AddEmployee.tsx` — new Education tab between Identification and Bank; same wizard tab structure as Identification; records written directly via `upsert_education` during hire
- `src/components/admin/EmployeeDetails.tsx` — Education summary in header (count + highest qualification label) + Education tab rendering read-only EducationPortlet
- `src/workflow/screens/ApproverInbox.tsx` — `EducationEnrichment` component (mirrors `BankEnrichment`/`DependentsEnrichment`); add `MODULE_LABELS['profile_education']`, `MODULE_EDIT_PERMISSION['profile_education']`, `PROFILE_INLINE_MODULES.add('profile_education')`, `PROFILE_FIELD_LABELS['education']`, `PROFILE_DATE_FIELDS` additions, `PROFILE_PICKLIST_FIELDS['profile_education']`; route in `ProfileEnrichment` dispatcher
- `src/workflow/screens/WorkflowReview.tsx` — `'profile_education'` added to `FULL_REVIEW_MODULES`; new section mirroring `profile_bank` section structure (loading state, summary card, EducationEnrichment for diff render)
- `src/components/admin/permissions/PermissionMatrix.tsx` — new "Education" row in EMPLOYEE section band registry with V/C/E/D/H mapped to `education.view/.create/.edit/.delete/.history`

**Docs:**
- This file (`docs/education-design.md`)
- `prowess_system_docs.html` Part 17 (new tab — to be added)
- `docs/bulk-operations-framework.md` §13 — bump to 16 templates with education row included

---

## 13. Open Items (Deferred to Build Time)

- **Field-of-study autocomplete** — start as free-form text. If HR asks for standardisation later, can convert to a picklist or autocomplete-from-existing-values.
- **Multi-language degree names** — out of scope for v1. Free-form text handles different scripts (English, Tamil, Mandarin) naturally.
- **Verification flag** (v2) — when added, layer on three columns: `verified_by_hr boolean`, `verified_at timestamptz`, `verified_by uuid`. Optional verification workflow.
- **Reciprocity / equivalence checks** (v2) — e.g., "this UK degree is equivalent to a US Master's". Niche; not in v1.
