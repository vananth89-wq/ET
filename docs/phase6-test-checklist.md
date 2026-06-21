# Phase 6 — Global Employee Search Integration Test Checklist

Run these manually after pushing migs 504–509. All items must pass before Phase 6 is considered complete.

---

## Backend (SQL) tests

Run `supabase test db` — all 18 pgTAP assertions in `supabase/tests/phase6_global_search.sql` must pass.

---

## 1. search_employees RPC

| # | Test | Expected |
|---|------|----------|
| 1.1 | Grant `employee_search.view` to a test role. Call `search_employees('vi', 10, false)` | Returns rows matching "vi" in name/code/email |
| 1.2 | Call without permission | EXCEPTION `insufficient_privilege` |
| 1.3 | Call with query length < 2 (`'v'`) | EXCEPTION `invalid_parameter_value` |
| 1.4 | Call with `p_include_inactive = true` without `employee_search.view_inactive` | Inactive rows excluded despite flag |
| 1.5 | Call with `p_include_inactive = true` WITH `employee_search.view_inactive` | Inactive rows included, amber "Inactive" badge visible in UI |

---

## 2. EmployeeSearchBox UX

| # | Test | Expected |
|---|------|----------|
| 2.1 | User without `employee_search.view` | Search box not rendered |
| 2.2 | User with permission: type 1 char | No search fired, Recently Viewed shown |
| 2.3 | Type 2+ chars | 300ms debounce then results dropdown appears |
| 2.4 | Press ⌘K / Ctrl+K from any page | Input focused |
| 2.5 | Press Esc | Dropdown closes |
| 2.6 | Up/Down arrows | Highlight moves through results |
| 2.7 | Press Enter on highlighted row | Navigates to `/profile/:id` |
| 2.8 | Mobile (≤768px): tap search icon | Full-screen overlay opens |
| 2.9 | Click a result | Employee added to Recently Viewed in localStorage |
| 2.10 | Open search again with empty query | Recently Viewed entries shown |
| 2.11 | Log out, log back in | Recently Viewed cleared |

---

## 3. Profile navigation (employee mode)

| # | Test | Expected |
|---|------|----------|
| 3.1 | Navigate to `/profile` (no param) | Self mode — "My Profile" title, no banner |
| 3.2 | Navigate to `/profile/:activeEmployeeId` | Blue "Viewing EMP001 · Name" banner, "← Return to your profile" link |
| 3.3 | Navigate to `/profile/:inactiveEmployeeId` | Amber "Inactive as of … View-only" banner |
| 3.4 | On inactive employee profile | Edit buttons hidden in all sections |
| 3.5 | Navigate to `/profile/:idWithNoViewPerms` | Red "No access" empty state (no sections visible) |
| 3.6 | Navigate to `/profile/:nonExistentId` | "No access" empty state (employee not found) |
| 3.7 | "← Return to your profile" link | Navigates to `/profile` (self mode) |

---

## 4. On-behalf-of workflow annotation

| # | Test | Expected |
|---|------|----------|
| 4.1 | Log in as EMP_B (HR). Navigate to `/profile/:EMP_A_id`. Submit a Personal Information change. | `workflow_instances.initiated_by_actor_id = EMP_B's profile_id`. `workflow_instances.submitted_by = EMP_B's profile_id`. `workflow_pending_changes.record_id = EMP_A's employee UUID`. |
| 4.2 | In EMP_A's approver's inbox | "Submitted by EMP_B on behalf of EMP_A" purple chip visible on task card |
| 4.3 | Log in as EMP_A. Go to My Requests | "Submitted by EMP_B on your behalf" chip visible on the request card |
| 4.4 | EMP_B submits bank change for EMP_A via BankAccountsPortlet | Same stamping behaviour (mig 509) |
| 4.5 | EMP_B submits dependent change for EMP_A | Same stamping behaviour (mig 509) |

---

## 5. Audit actor/subject split

| # | Test | Expected |
|---|------|----------|
| 5.1 | EMP_B (HR) submits personal info change for EMP_A | `workflow_pending_changes.submitted_by = EMP_B's profile_id` |
| 5.2 | Same row | `workflow_pending_changes.record_id = EMP_A's employee UUID` |
| 5.3 | Self-service: EMP_A submits own change | `initiated_by_actor_id IS NULL` on the resulting `workflow_instances` row |

---

## 6. Permission Matrix

| # | Test | Expected |
|---|------|----------|
| 6.1 | Admin → Permission Matrix → a permission set | "Employee Search" row visible under Employee Workflow section |
| 6.2 | Check View checkbox | `employee_search.view` granted to set |
| 6.3 | Check Include Inactive checkbox | `employee_search.view_inactive` granted |
| 6.4 | Save + reload | Grants persist |

---

## 7. get_profile_workflow_gates in employee mode

| # | Test | Expected |
|---|------|----------|
| 7.1 | HR views EMP_A's profile. EMP_A has a pending personal info workflow. | "Workflow Pending Approval" badge visible on Personal Information section in HR's view |
| 7.2 | HR views EMP_B's profile. EMP_B has no pending workflows. | No pending badges shown |

---

*All items must be ✓ before Phase 6 is signed off. File bugs for any ✗ items.*
