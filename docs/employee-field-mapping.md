# Employee field mapping

Maps every column across the core `employees` table and its satellite tables to the `emp.*` key used in the frontend and the UI label shown to users.

---

## `employees` table

| DB column | `emp` key | UI label / notes |
|---|---|---|
| `id` | `emp.id` | Internal UUID — not displayed |
| `employee_id` | `emp.employeeId` | Employee ID (read-only) |
| `name` | `emp.name` | Full Name — denormalized cache; computed by `compute_full_name(first_name, middle_name, last_name)` in `employee_personal` and synced here via `upsert_personal_info()` + nightly `activate_personal_info_records` job |
| `business_email` | `emp.businessEmail` | Business Email (read-only) |
| `designation` | `emp.designation` | **Mirror cache** (source of truth: `employee_employment.designation`). Updated by `upsert_employment_info()` + nightly sync. |
| `job_title` | `emp.jobTitle` | **Mirror cache** — auto-populated from DESIGNATION picklist label; user can override. 30+ frontend read paths depend on this column. |
| `dept_id` | `emp.deptId` | **Mirror cache** (source of truth: `employee_employment.dept_id`). |
| `manager_id` | `emp.managerId` | **Mirror cache** (source of truth: `employee_employment.manager_id`). |
| `hire_date` | `emp.hireDate` | **Mirror cache** (source of truth: `employee_employment.hire_date`). |
| `end_date` | `emp.endDate` | **Mirror cache** — also scanned nightly by `_scan_end_date_inactive()` to flip status → Inactive. |
| `work_country` | `emp.workCountry` | **Mirror cache** (source of truth: `employee_employment.work_country`). |
| `work_location` | `emp.workLocation` | **Mirror cache** (source of truth: `employee_employment.work_location`). |
| `base_currency_id` | `emp.baseCurrencyId` | **Mirror cache** — always auto-derived from `work_country` via `picklist_values.meta.currencyId`; never a user input. |
| `status` | `emp.status` | **Mirror cache** for lifecycle status — also the authoritative trigger source for role sync (`sync_profile_on_employee_status`). |
| `locked` | — | Hire pipeline lock — not displayed |
| `invite_sent_at` | — | Not displayed in MyProfile |
| `invite_accepted_at` | — | Not displayed in MyProfile |
| `submitted_at` | — | Hire pipeline only — not displayed |
| `created_by` | — | Audit — not displayed |
| `deleted_at` | — | Soft-delete sentinel — not displayed |
| `created_at` | — | Audit — not displayed |
| `updated_at` | — | Audit — not displayed |

Columns removed from `employees` in mig 020 (moved to satellite tables): `nationality`, `marital_status`, `photo_url`, `country_code`, `mobile`, `personal_email`, `probation_end_date`.

**Mirror cache columns** (mig 351): `designation`, `job_title`, `dept_id`, `manager_id`, `hire_date`, `end_date`, `work_country`, `work_location`, `base_currency_id`, `status` remain on `employees` as denormalized read caches. Source of truth is `employee_employment`. Direct writes to these columns are blocked by `fn_guard_employee_employment_sync` BEFORE UPDATE trigger for Active/Inactive employees. All changes must go through `upsert_employment_info()`.

---

## `employee_employment` (via `get_current_employment_info()` RPC)

Effective-dated table (mig 351). One open-ended active row per employee (`effective_to = '9999-12-31'`, `is_active = true`). **Source of truth for all 10 employment fields.** Mirror on `employees.*` is kept in sync by the RPC and nightly `activate_effective_dated_records()` job. Fetched via `get_current_employment_info()` RPC; history via `get_employment_info_history()`.

| DB column | `emp` key | UI label / notes |
|---|---|---|
| `id` | — | Surrogate PK — internal |
| `employee_id` | — | FK to `employees.id` |
| `designation` | `emp.designation` | Designation (DESIGNATION picklist UUID) |
| `job_title` | `emp.jobTitle` | Job Title — free-form; auto-filled from designation label when blank |
| `dept_id` | `emp.deptId` | Department |
| `manager_id` | `emp.managerId` | Reports To |
| `hire_date` | `emp.hireDate` | Hire Date — seeds `effective_from` of first slice |
| `end_date` | `emp.endDate` | End Date — drives nightly Inactive flip (§11.4) |
| `work_country` | `emp.workCountry` | Country of Work (ID_COUNTRY picklist UUID) |
| `work_location` | `emp.workLocation` | Work Location (LOCATION picklist UUID, parent-filtered by work_country) |
| `base_currency_id` | `emp.baseCurrencyId` | Base Currency — always auto-derived; read-only in all UIs |
| `status` | `emp.status` | Employment lifecycle status (enum: Draft/Incomplete/Pending/Active/Inactive) |
| `probation_end_date` | `emp.probationEndDate` | Probation End Date — effective-dated alongside the rest |
| `effective_from` | — | Slice start date |
| `effective_to` | — | `'9999-12-31'` = current open-ended slice |
| `is_active` | — | Timeline flag |
| `created_by` / `updated_by` | — | Audit |

**Write path:** all changes go through `upsert_employment_info(p_employee_id, p_proposed_data, p_effective_from)`. Admin saves (EmployeeEditPanel) call it directly with `effective_from = today`. ESS saves (MyProfile) go through `submit_change_request('profile_employment', ...)` → workflow → `apply_profile_pending_change` → `upsert_employment_info`. Hire wizard (AddEmployee `saveExtendedData`) calls it during onboarding.

---

## `employee_personal` (via `get_current_personal_info()` RPC)

Effective-dated table (mig 315). One open-ended active row per employee. Fetched via RPC, not direct table select.

Name fields were split into structured columns in mig 332. Existing rows were backfilled by splitting `name` on the last space (everything before → `first_name`, last word → `last_name`). `name` is now a computed cache maintained by `compute_full_name(first_name, middle_name, last_name)` — callers never set it directly.

| DB column | `emp` key | UI label / notes |
|---|---|---|
| `first_name` | `emp.firstName` | First Name — required; editable |
| `middle_name` | `emp.middleName` | Middle Name — optional; editable |
| `last_name` | `emp.lastName` | Last Name — optional; editable |
| `name` | `emp.name` (synced) | Full Name — computed from first/middle/last via `compute_full_name()`; synced to `employees.name`; read-only in UI |
| `preferred_name` | — | Not fetched / not shown |
| `nationality` | `emp.nationality` | Nationality |
| `marital_status` | `emp.maritalStatus` | Marital Status |
| `gender` | `emp.gender` | Gender |
| `dob` | `emp.dob` | Date of Birth |
| `photo_url` | `emp.photo` | Avatar (separate upload UI) |
| `effective_from` | — | Effective From (edit form only — not shown in view mode) |
| `effective_to` | — | Timeline sentinel — not displayed |
| `is_active` | — | Timeline flag — not displayed |
| `created_by` / `updated_by` | — | Audit — not displayed |

**Name computation rules** (matches `compute_full_name()` in DB):

| first | middle | last | result |
|---|---|---|---|
| ✓ | ✓ | ✓ | `first middle last` |
| ✓ | — | ✓ | `first last` |
| ✓ | ✓ | — | `first middle` |
| ✓ | — | — | `first` |

**Backfill** (mig 332): existing `name` values were split on the last space — e.g. `"Vijey Ananthan"` → `first_name = "Vijey"`, `last_name = "Ananthan"`. Single-word names land entirely in `first_name`.

---

## `employee_contact` (direct table select)

Flat 1:1 satellite table.

| DB column | `emp` key | UI label |
|---|---|---|
| `mobile` | `emp.mobile` | Mobile |
| `country_code` | `emp.countryCode` | Country Code |
| `personal_email` | `emp.personalEmail` | Personal Email |

---

## `employee_addresses` (direct table select)

Flat 1:1 satellite table.

| DB column | `emp` key | UI label |
|---|---|---|
| `id` | `emp.addrId` | Internal — not displayed |
| `line1` | `emp.addrLine1` | Address Line 1 |
| `line2` | `emp.addrLine2` | Address Line 2 |
| `landmark` | `emp.addrLandmark` | Landmark |
| `city` | `emp.addrCity` | City |
| `district` | `emp.addrDistrict` | District |
| `state` | `emp.addrState` | State |
| `pin` | `emp.addrPin` | PIN / ZIP |
| `country` | `emp.addrCountry` | Country |

---

## `passports` (direct table select)

Flat 1:1 satellite table (one passport per employee).

| DB column | `emp` key | UI label |
|---|---|---|
| `id` | `emp.passportId` | Internal — not displayed |
| `country` | `emp.passportCountry` | Passport Country |
| `passport_number` | `emp.passportNumber` | Passport Number |
| `issue_date` | `emp.passportIssueDate` | Issue Date |
| `expiry_date` | `emp.passportExpiryDate` | Expiry Date |

---

## `emergency_contacts` (direct table select, first row)

Multi-row table; MyProfile fetches only the first row.

| DB column | `emp` key | UI label |
|---|---|---|
| `id` | `emp.ecId` | Internal — not displayed |
| `name` | `emp.ecName` | Name |
| `relationship` | `emp.ecRelationship` | Relationship |
| `phone` | `emp.ecPhone` | Phone |
| `alt_phone` | `emp.ecAltPhone` | Alternate Phone |
| `email` | `emp.ecEmail` | Email |

---

## `identity_records` (direct table select, all rows)

Multi-row table; stored as `emp.idRecords[]`.

| DB column | `emp.idRecords[n]` key | UI label |
|---|---|---|
| `country` | `country` | Country |
| `id_type` | `idType` | ID Type |
| `record_type` | `recordType` | Record Type |
| `id_number` | `idNumber` | ID Number |
| `expiry` | `expiry` | Expiry |

---

## How `emp` is assembled

```ts
// loadExtData() fetches all satellite tables in parallel, then:
const emp = authEmployee ? { ...authEmployee, ...extData } : authEmployee;
```

`authEmployee` comes from the auth context (core `employees` row). `extData` is the patch object built from all satellite fetches — it overwrites matching keys and adds satellite-only keys. The personal section fields (`firstName`, `middleName`, `lastName`, `nationality`, `maritalStatus`, `gender`, `dob`, `photo`) all come from `extData` via `get_current_personal_info()`. `emp.name` comes from `authEmployee` (the `employees.name` cache) and is always the computed full name.
