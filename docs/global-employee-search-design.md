# Global Employee Search & Profile Navigation — Design Specification

**Status:** Design Phase — Locked 2026-06-05 (revised with risk mitigations)
**Source spec:** User-supplied spec, 2026-06-05
**Next available migration:** `20260604496+` (per `prowess-termination` memory)
**Phase estimate:** ~9.5 working days (Phase 0 Discovery + 7 build phases). Estimate may revise after Phase 0 findings.

SuccessFactors People Profile pattern adapted for Prowess. A user with `employee_search.view` can locate any employee from a header search and navigate into that employee's profile — but the rendered profile uses the EXISTING MyProfile screen with a `viewedEmployeeId` context, so every section gates on `user_can(module, action, viewedEmployeeId)`. There is NO new "Employee Profile" page. Architectural decisions in §1 are LOCKED.

---

## §1 Decision Summary (LOCKED)

| # | Decision | Verdict |
|---|---|---|
| 1 | Profile architecture | **One MyProfile screen, two modes.** `ProfileContext` carries `viewedEmployeeId`. Self mode = `viewedEmployeeId === currentUserEmployeeId`. Employee mode otherwise. No separate Employee Profile page. |
| 2 | Route shape | `/profile/:employeeId?` — employee_id is optional, defaults to self. Old `/profile` route is renamed; redirects preserved. |
| 3 | Search permission | New permission `employee_search.view` gates header search box + employee-mode navigation. No default grants. |
| 4 | Target population scoping (SF-style) | **Deferred to v2.** v1 leans on existing `user_can(module, view, target_id)`. If no module is viewable for the target → profile renders an empty-state "No access" panel. |
| 5 | MyProfile vs EmployeeEditPanel | **Coexist.** MyProfile (self OR employee mode) **always routes each module through that module's existing path** — workflow-gated modules (termination, bank, dependents, etc.) still flow through workflow; non-gated modules write direct. EmployeeEditPanel is the HR admin surface that ALSO routes each module through its existing path. The two surfaces differ in UX (per-portlet vs full-record) and entry point, not in workflow semantics. Do NOT collapse "EmployeeEditPanel = no workflow" — that's incorrect. |
| 6 | Profile context plumbing | New React `ProfileContext` exposing `viewedEmployeeId`, `isSelf`, `viewedEmployee` (id, code, name, email, status, manager_id). Every `user_can` inside MyProfile reads from this context. Every data hook takes `employeeId` as input. |
| 7 | Search backend | One RPC `search_employees(p_query TEXT, p_limit INT DEFAULT 10, p_include_inactive BOOLEAN DEFAULT false)` returning `{employee_id, employee_code, full_name, email, status, manager_id, avatar_url}`. Permission-gated on `employee_search.view`. |
| 8 | Search indexes | `pg_trgm` GIN on a generated text column `searchable_text = employee_code \|\| ' ' \|\| full_name \|\| ' ' \|\| email`. Sub-50ms target on 500-employee dataset. |
| 9 | Search criteria (v1) | Employee ID (code), Name, Email. No department / manager / national-ID / admin-actions in v1. |
| 10 | Type-ahead UX | 2-character minimum, 300ms debounce, max 10 results, sorted by trigram similarity. Loading + empty + error states all required. |
| 11 | Recently Viewed | **localStorage per-device.** Last 10 employees with cached `{id, code, name, email}` for instant render. Cleared on logout. No DB table. |
| 12 | Inactive employees | Searchable behind an "Include inactive" toggle (HR-only by default). Profile renders with an "Inactive as of YYYY-MM-DD" banner. Edit actions hidden on Inactive employees regardless of permission. |
| 13 | Empty-state semantics | If user has zero `view` permissions for the target across all modules → render "You don't have permission to view this employee." Not a 404. |
| 14 | Workflow context | Workflow Subject Employee = `viewedEmployeeId`. Actor = `currentUserId`. No engine changes — `wf_submit` already takes a target_id parameter; just thread `viewedEmployeeId` through the submit calls in MyProfile. |
| 15 | Audit Actor/Subject | Already split in Prowess (`created_by` ≠ `employee_id`). No schema work. Add an integration test that creates a dependent for EMP_A while logged in as EMP_B(HR) and asserts `created_by=EMP_B`, `employee_id=EMP_A`. |
| 16 | Permission Matrix row | New `employee_search` row in the **SYSTEM band** with single column "View" (`.view` permission). Not in EMPLOYEE or IMPORT/EXPORT bands. |
| 17 | Header placement | Search box between logo and notifications. Width 320px desktop, collapses to icon-only ≤768px (modal overlay on mobile). |
| 18 | Deep-linking | URLs deep-linkable. Pasting `/profile/EMP0001` works for anyone with `employee_search.view`. Permission re-checked on every section render — bookmarks don't bypass security. |
| 19 | Profile context switch UX | Switching from EMP_A to EMP_B clears scroll, resets active tab to first visible section, shows skeleton until data loads. |
| 20 | Bulk framework | **N/A.** Search is a read-only query feature, not a data-mutation surface. No bulk template. |
| 21 | Phase 0 — Discovery before commit | **Mandatory.** Before Phase 1 starts, Sonnet runs two probes: (a) grep `MyProfile/` for `currentUser.employee_id`, `user_can(`, and self-context helper hooks — report the actual count and file fanout. (b) Verify whether `get_target_employees(module, action)` (or equivalent helper) exists; if not, check how Termination / JR currently filter by target population. Report findings; revise Phase 3 / Phase 1 estimates accordingly. ~0.5 day. |
| 22 | "Submitted on behalf of" annotation | **Required.** Add column `initiated_by_actor_id UUID REFERENCES profiles(id)` to `workflow_instances`. `wf_submit` stamps it = `auth.uid()` whenever `subject_employee_id ≠ submitter's employee_id`. Surface in **ApproverInbox** ("Submitted by EMP_B on behalf of EMP_A") and in the subject employee's own workflow view. Half-day add; prevents real user confusion when HR submits a change on someone else's behalf. |
| 23 | Target population filter implementation | If a helper RPC exists (Phase 0 finding) — use it: `WHERE id = ANY(get_target_employees('employee_search','view'))`. If it does not exist — write `get_target_employees(p_module TEXT, p_action TEXT) RETURNS UUID[]` as part of Phase 1 and use it here too. Per-row `user_can` filtering is the fallback only if Termination/JR are already doing it that way (consistency over performance). |

---

## §2 Architecture

### §2.1 Component diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│ AppShell                                                                │
│ ┌──────────────────────────────────────────────────────────────────┐   │
│ │ Header                                                            │   │
│ │  Logo  [ EmployeeSearchBox  ─────────── ]   🔔   UserMenu        │   │
│ │           │                                                       │   │
│ │           ▼  type-ahead dropdown                                 │   │
│ │           │  ┌─ Recently Viewed (localStorage) ─┐                │   │
│ │           │  ├─ Search results (search_employees RPC) ┤         │   │
│ │           │  └────────────────────────────────────────┘         │   │
│ └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│ Routes:                                                                  │
│   /profile           → ProfileScreen(viewedEmployeeId = currentUser)    │
│   /profile/:id       → ProfileScreen(viewedEmployeeId = :id)            │
│                                                                          │
│ ProfileScreen wraps <MyProfile> in <ProfileContextProvider>:            │
│   <ProfileContext.Provider value={{ viewedEmployeeId, isSelf, viewed }}>│
│     <MyProfile />   ← unchanged screen, now reads from context         │
│   </ProfileContext.Provider>                                            │
└─────────────────────────────────────────────────────────────────────────┘
```

### §2.2 Why this architecture

- **Single profile screen** = lowest maintenance cost; every future field added to MyProfile is automatically available in employee mode.
- **React context = clean threading** of `viewedEmployeeId` to dozens of permission checks and data hooks without prop-drilling.
- **Route-driven** means deep-links work, browser back/forward works, bookmark works.
- **localStorage Recently Viewed** = zero backend, instant render, per-device acceptable for the use case.

---

## §3 Data Model

### §3.1 `employees` — generated search column + GIN index

```sql
-- Generated column (Postgres 12+) — auto-maintained by Postgres.
ALTER TABLE employees
  ADD COLUMN searchable_text TEXT GENERATED ALWAYS AS (
    COALESCE(employee_code, '') || ' ' ||
    COALESCE(full_name,     '') || ' ' ||
    COALESCE(email,         '')
  ) STORED;

-- Trigram extension (idempotent — likely already installed).
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- GIN index for fast ILIKE and similarity().
CREATE INDEX ix_employees_searchable_trgm
  ON employees USING gin (searchable_text gin_trgm_ops);
```

Trade-off: `STORED` adds ~30 bytes per row × 500 rows = 15 KB. Trivial.

### §3.2 New permission

```sql
INSERT INTO permissions (name) VALUES
  ('employee_search.view')
ON CONFLICT DO NOTHING;
```

No default grants. Admin assigns via Permission Matrix → SYSTEM band.

### §3.3 No other schema changes

- No new tables.
- No changes to `employees` other than the generated column.
- Recently Viewed lives in localStorage.

---

## §4 RPC Contract

### §4.1 `search_employees`

```sql
search_employees(
  p_query             TEXT,
  p_limit             INTEGER DEFAULT 10,
  p_include_inactive  BOOLEAN DEFAULT false
) RETURNS TABLE (
  employee_id     UUID,
  employee_code   TEXT,
  full_name       TEXT,
  email           TEXT,
  status          TEXT,
  manager_id      UUID,
  avatar_url      TEXT,
  similarity      REAL
)
SECURITY DEFINER
SET search_path = public;
```

Behaviour:

1. Permission check: `IF NOT user_can('employee_search', 'view', NULL) THEN RAISE EXCEPTION '...'`. `target_id=NULL` because search itself is a global capability.
2. Trim + lowercase + sanitize `p_query`. Reject if length < 2.
3. Query:
   ```sql
   SELECT id, employee_code, full_name, email, status, manager_id, avatar_url,
          similarity(searchable_text, p_query) AS sim
   FROM employees
   WHERE searchable_text ILIKE '%' || p_query || '%'
     AND (p_include_inactive OR status = 'Active')
   ORDER BY similarity(searchable_text, p_query) DESC, full_name ASC
   LIMIT p_limit;
   ```
4. Returns up to `p_limit` rows.

Target performance: < 50ms on 500 rows. Verified via `EXPLAIN ANALYZE` against a seeded dataset in Phase 5.

---

## §5 Frontend Architecture

### §5.1 New components

```
src/components/header/EmployeeSearchBox.tsx
  - Renders the input in the header (when permission granted)
  - Type-ahead dropdown with debounce
  - Renders Recently Viewed when input is empty
  - Renders Loading / Empty / Error states

src/components/header/SearchResultRow.tsx
  - One row in the dropdown
  - Avatar + employee_code + full_name + email
  - Click → navigate to /profile/:id

src/components/header/RecentlyViewedList.tsx
  - Reads from localStorage
  - Same row shape as search results

src/contexts/ProfileContext.tsx
  - Provides { viewedEmployeeId, isSelf, viewedEmployee }
  - useProfileContext() hook

src/hooks/useEmployeeSearch.ts
  - Debounced wrapper around search_employees RPC
  - Returns { results, loading, error }

src/hooks/useRecentlyViewed.ts
  - localStorage CRUD: add, remove, list, clear
  - Cap at 10 entries

src/components/profile/ProfileEmptyState.tsx
  - "You don't have permission to view this employee" panel
  - "This employee is Inactive" banner variant
```

### §5.2 Modified files (with line-level hints)

| File | Edit |
|---|---|
| `App.tsx` or `routes.tsx` | New route `/profile/:employeeId?` replacing the static `/profile` (or wrap with optional param). |
| `MyProfile/index.tsx` | Replace every `currentUser.employee_id` lookup with `useProfileContext().viewedEmployeeId`. Replace every `user_can(module, action)` call to pass `viewedEmployeeId`. Add Inactive banner. Wrap permission-empty render in `<ProfileEmptyState />`. |
| `MyProfile/index.tsx` data fetches | `useEmployeeData(viewedEmployeeId)` instead of self. All satellite hooks: `useIdentityRecords(viewedEmployeeId)`, `useDependents(viewedEmployeeId)`, `useTerminationData(viewedEmployeeId)`, etc. |
| `MyProfile/index.tsx` workflow submits | Every `submit_change_request(...)` and dual-path RPC takes `viewedEmployeeId` as the target. Most already do — confirm and thread. |
| `Header.tsx` / `AppShell.tsx` | Mount `<EmployeeSearchBox />` between logo and notification bell. Conditional render on `user_can('employee_search', 'view', null)`. |
| `src/components/admin/permissions/PermissionMatrix.tsx` | Add SYSTEM-band row "Employee Search" with single column "View". |
| `prowess_system_docs.html` | Add Part 24. |

### §5.3 ProfileContext shape

```tsx
interface ProfileContextValue {
  viewedEmployeeId: string;
  isSelf: boolean;
  viewedEmployee: {
    id: string;
    employee_code: string;
    full_name: string;
    email: string;
    status: 'Active' | 'Inactive';
    manager_id: string | null;
    avatar_url: string | null;
  } | null;
  isLoading: boolean;
  error: Error | null;
}
```

The provider fetches the basic employee record once on mount + on `:employeeId` change. Heavy data (dependents, bank, etc.) stays in the individual portlet hooks — context is for identity + isSelf only.

### §5.4 Permission gating example

Before (self-only):
```tsx
const canEditPersonal = user_can('personal_info', 'edit');
```

After (employee-aware):
```tsx
const { viewedEmployeeId } = useProfileContext();
const canEditPersonal = user_can('personal_info', 'edit', viewedEmployeeId);
```

This single pattern repeats ~30–50 times across MyProfile. Mechanical refactor.

---

## §6 UX Specification

### §6.1 Header search box

- Desktop: 320px wide, between logo and bell icon, placeholder "Search employee…"
- Mobile (≤768px): icon-only; clicking opens a full-screen modal overlay with the same search experience
- Keyboard: ⌘K / Ctrl+K focuses the search box from anywhere in the app
- Escape closes the dropdown without navigating
- Down/Up arrows move through results; Enter selects highlighted; Tab/Click outside closes

### §6.2 Dropdown contents

```
┌─ EmployeeSearchBox open ────────────────────────────┐
│ [ vi                                           ] ✕ │
├─────────────────────────────────────────────────────┤
│ RECENT                                              │
│ ◉ EMP001 · Vijey ASR · vijey@company.com           │
│ ◉ EMP012 · Priya Sharma · priya@company.com        │
├─────────────────────────────────────────────────────┤
│ RESULTS (3)                                         │
│ ◯ EMP001 · Vijey ASR · vijey@company.com           │
│ ◯ EMP015 · Vignesh Kumar · vignesh@company.com     │
│ ◯ EMP022 · Vinoth Raj · vinoth@company.com         │
└─────────────────────────────────────────────────────┘
```

Recently Viewed appears when the query is empty (or < 2 chars). Results section replaces it once the query is long enough.

### §6.3 Empty / loading / error states

- **Empty (0 chars)**: show Recently Viewed if available; else "Start typing to search employees".
- **Loading**: skeleton rows for 200ms+ debounce overlap.
- **No results**: "No employees match 'xxx'".
- **Error**: "Search failed — please retry" with a retry button.
- **Permission denied**: search box doesn't render at all.

### §6.4 Profile mode banners

- **Self mode**: no banner — looks exactly like today's MyProfile.
- **Employee mode, Active**: subtle blue banner at top: "Viewing EMP0001 · Vijey ASR · (Return to your profile)".
- **Employee mode, Inactive**: amber banner: "EMP0001 · Vijey ASR is Inactive as of 2026-06-30. View-only."
- **Permission empty**: red empty-state panel inside MyProfile body: "You don't have permission to view this employee."

### §6.5 Loading states for profile context switch

When `:employeeId` changes:
1. Show top-level skeleton (banner + section placeholders).
2. Each portlet shows its own skeleton while its hook re-fetches.
3. Scroll resets to top.
4. Active tab/section resets to the first visible section.

---

## §7 Recently Viewed (localStorage)

### §7.1 Storage shape

```ts
// Key: `prowess.recentlyViewed.${currentUserId}`
type RecentlyViewedEntry = {
  employee_id: string;
  employee_code: string;
  full_name: string;
  email: string;
  viewed_at: string;  // ISO timestamp
};
```

Stored as a JSON array, max 10 entries, sorted by `viewed_at` DESC.

### §7.2 Behaviour

- On profile open (employee mode only): add entry, deduplicate by `employee_id`, trim to 10.
- Self-profile views are NOT added.
- Cleared on logout (`localStorage.removeItem` in the auth provider's logout flow).
- Per-device (no sync) — acceptable for v1.

### §7.3 Cache invalidation

If a recently-viewed employee changes name / email / code, the cached entry will be stale until the next time they appear in search results. Accepted — the dropdown fetches fresh data when the user actually clicks a result.

---

## §8 Permissions & Security

### §8.1 New permission

| Permission | Description |
|---|---|
| `employee_search.view` | Display header search; allow navigation to other employees' profiles |

No default grants. Recommended assignment: Manager, HR, Admin.

### §8.2 Permission re-check on every section

The search-permission opens the door to navigate. Each portlet inside the profile still calls `user_can(module, action, viewedEmployeeId)` independently. Bookmarks / deep-links cannot bypass section-level gating.

### §8.3 What's NOT in scope for v1

- **Target population (SF-style permission groups)** — deferred. Without it, anyone with `employee_search.view` can find anyone, but module-level `view` still gates what they see. Acceptable for a 500-employee org; revisit at 2000+.
- **Per-field sensitive masking** — out of scope. Salary fields etc. continue to be gated at the module level (e.g., `compensation.view`).
- **Audit trail for "who viewed whom"** — out of scope. If required later, add a `profile_view_log` table.

---

## §9 Workflow & Audit Behaviour

### §9.1 Workflow subject = viewed employee

When HR (logged in as EMP_B) opens EMP_A's profile and submits a dependent change:

```
wf_submit('dependents', viewed_employee_id=EMP_A, ...)
                                       ↑
                          NOT EMP_B (the actor)
```

The workflow instance is created for EMP_A. Routing, approvals, notifications all use EMP_A as the subject. No engine changes — `wf_submit` already accepts a target.

**Verification:** Phase 6 integration test — log in as EMP_B (HR), open EMP_A, submit dependent change, assert workflow_instance.target_id = EMP_A and the instance routes to EMP_A's manager (not EMP_B's manager).

### §9.2 Audit logging

Audit columns are already split correctly:

```
created_by  = EMP_B (actor)
employee_id = EMP_A (subject)
```

No schema change. Integration test in Phase 6 confirms.

---

## §10 Phase Plan

**8 phases (Phase 0 discovery + 7 build), ~9.5 working days.** Backend small; frontend refactor is the bulk. Phase 0 findings may shift the estimate up or down for Phase 1 and Phase 3.

### Phase 0 — Discovery (≈0.5 day) — REQUIRED before committing to estimates

Two probes, results reported back to the user before Phase 1 starts:

**(a) MyProfile refactor scale**
```bash
grep -rn "currentUser\.employee_id\|currentUser?\.\?employee_id" src/components/employee/MyProfile/
grep -rn "user_can(" src/components/employee/MyProfile/
grep -rn "useEmployeeData\|useCurrentEmployee" src/components/employee/MyProfile/
```
Report: total occurrence count, file spread, AND whether any data hooks (`useEmployeeData`, etc.) hard-code "current user" internally (look at the hook implementations, not just call sites). If hard-coded, those hooks need refactoring too — that's the silent scope expander.

**(b) Target population helper**
```bash
grep -rn "get_target_employees\|target_employees\|get_my_target" supabase/migrations/
# Also inspect how Termination + JR filter by target population:
grep -rn "target_group\|target_population\|user_can.*employee_id" supabase/migrations/20260530359_*.sql
```
Report: does a helper RPC exist? If yes, name + signature. If no, what pattern do Termination/JR use today? This decides decision #23.

**Decision gate:** based on (a) + (b), revise Phase 3 estimate (currently 3 days) and Phase 1 estimate (currently 0.5 day — may grow to 1 day if the helper RPC needs writing).

### Phase 1 — Schema + Permission + RPC (≈0.5–1 day)

- **Mig 20260604496** — generated `searchable_text` column on `employees`, GIN trigram index, `employee_search.view` + `employee_search.view_inactive` permission seeds. Also adds `workflow_instances.initiated_by_actor_id UUID REFERENCES profiles(id)` (decision #22).
- **Mig 20260604497** — `search_employees` RPC with permission check + target-population filter (per Phase 0 finding) + ILIKE + similarity ordering. Plus `get_target_employees(p_module, p_action)` helper if Phase 0 finds it missing.
- **Mig 20260604498** — `wf_submit` stamps `initiated_by_actor_id` when subject ≠ actor.

### Phase 2 — ProfileContext + route (≈1 day)
- Create `ProfileContext` + provider + `useProfileContext` hook.
- Add `/profile/:employeeId?` route with default-to-self behaviour.
- Old `/profile` redirects to new route.

### Phase 3 — Refactor MyProfile to use ProfileContext (≈3 days)
- Replace ~30–50 `currentUser.employee_id` lookups with `viewedEmployeeId`.
- Replace ~30–50 `user_can(...)` calls to pass `viewedEmployeeId`.
- Thread `viewedEmployeeId` into every data hook + workflow submit.
- Add Inactive banner + permission-empty state.

### Phase 4 — Header search UI (≈2 days)
- `EmployeeSearchBox` + `SearchResultRow` + `RecentlyViewedList` + `useEmployeeSearch` + `useRecentlyViewed`.
- Mount in `Header.tsx` with permission gate.
- Keyboard shortcuts (⌘K, Esc, arrows).
- Mobile responsive overlay.

### Phase 5 — Permission Matrix + "On behalf of" UI + docs (≈1 day)
- EMPLOYEE-band row for `employee_search.view` + `employee_search.view_inactive` (target-population scoped).
- ApproverInbox: when `wf_instance.initiated_by_actor_id IS NOT NULL`, render "Submitted by [actor_name] on behalf of [subject_name]" above the standard inbox card.
- Subject employee's own workflow view: same annotation when actor ≠ subject.
- Update Part 24 in `prowess_system_docs.html` (set status to "Implemented").
- Update memory file status to COMPLETE.

### Phase 6 — Integration tests (≈1 day)
- Search RPC perf test on seeded 500-employee dataset.
- Target-population filter test (HR_Mumbai cannot see Chennai employees in search).
- HR-edits-employee workflow test (subject ≠ actor verification, `initiated_by_actor_id` populated).
- "Submitted by [actor] on behalf of [subject]" annotation visible in ApproverInbox AND in EMP_A's own workflow view when EMP_B (HR) submitted.
- Audit log Actor/Subject test.
- Inactive employee search + banner test (with and without `view_inactive` perm).
- Permission-empty state test.

### Phase 7 — Cross-browser + a11y polish (≈0.5 day)
- Keyboard nav verified on Chrome / Safari / Firefox.
- Screen reader announces dropdown results.
- Focus management on context switch.
- Mobile overlay tested on iOS Safari + Android Chrome.

---

## §11 Files Inventory

### §11.1 Backend

| Mig | Description |
|---|---|
| 20260604496 | Generated `searchable_text` column + GIN trigram index + `employee_search.view` permission |
| 20260604497 | `search_employees` RPC |

### §11.2 Frontend new files

```
src/contexts/ProfileContext.tsx
src/hooks/useEmployeeSearch.ts
src/hooks/useRecentlyViewed.ts
src/components/header/EmployeeSearchBox.tsx
src/components/header/SearchResultRow.tsx
src/components/header/RecentlyViewedList.tsx
src/components/profile/ProfileEmptyState.tsx
src/components/profile/InactiveEmployeeBanner.tsx
src/components/profile/EmployeeModeBanner.tsx
```

### §11.3 Frontend modifications

| File | Edit |
|---|---|
| `App.tsx` / `routes.tsx` | Replace `/profile` route with `/profile/:employeeId?`; add `<ProfileContextProvider>` wrapper around `<MyProfile />` |
| `MyProfile/index.tsx` | Mechanical refactor: all `user_can` calls + all data hooks thread `viewedEmployeeId`. Add banners. ~50–80 line-level edits. |
| `Header.tsx` (or `AppShell.tsx`) | Mount `<EmployeeSearchBox />` with permission gate |
| `src/components/admin/permissions/PermissionMatrix.tsx` | SYSTEM-band row "Employee Search" / View |
| `src/lib/auth.ts` (or equivalent) | On logout, clear `prowess.recentlyViewed.*` from localStorage |
| `prowess_system_docs.html` | Add Part 24 |
| `EmployeeEditPanel.tsx` | **No changes** — coexists with MyProfile employee mode |

---

## §12 Related Projects

- [[prowess-permission-engine]] — `user_can(module, action, target_id)` is the foundation; this work just threads `viewedEmployeeId` through it.
- [[prowess-workflow-engine]] — `wf_submit` already accepts a target; no engine change.
- [[prowess-overview]] — establishes that Prowess uses Supabase + React + permission-gated everything.
- [[prowess-termination]] — most-recent module; this work depends on termination's status banner pattern for the Inactive banner.
- `docs/job-relationships-design.md` — pattern for permission-gated portlet rendering.

---

## §13 Future Enhancements (Not in v1)

- Target Population (SF-style permission groups) for search scoping
- Department / Manager / Job Title / Location / National ID search criteria
- Admin actions surfaced in search ("Terminate Employee", "Transfer Employee")
- Profile view audit log (`profile_view_log`)
- Cross-device Recently Viewed sync via a backed table
- Full-text search via a dedicated search service when employee count crosses ~5,000
- Per-field sensitive masking (compensation, performance ratings)
- "Recently Edited" alongside "Recently Viewed" for HR users
