# Enterprise RBAC + Lookup View Architecture
## Prowess Design Reference

---

## 1. Core Philosophy

The fundamental principle is **context-based data exposure**: the same master data is needed by different actors for different purposes, and the permission design must reflect that distinction rather than collapsing it into a single gate.

An HR admin managing the projects list needs to see all projects — active, inactive, with budgets, internal notes, created-by metadata, and soft-deleted records. A submitter adding a line item to an expense report needs to pick from a list of active project names. These are not the same operation, and treating them as the same is the root of most RBAC sprawl.

The architecture separates this cleanly: **management permissions** govern the admin surface, **lookup permissions** govern the transactional surface, and a **lookup view** is the technical bridge that enforces column and row restrictions between the two.

---

## 2. Permission Taxonomy

### Management permissions — for admin screens only

```
entity_mgmt.view     Read full record, all columns, all statuses
entity_mgmt.create   Insert new record
entity_mgmt.edit     Update any field
entity_mgmt.delete   Soft or hard delete
```

These live under a module code like `projects_mgmt`. They grant full visibility into the master table — including inactive records, internal metadata, audit fields, budget figures, soft-deleted rows. Granting any of these to a non-admin user is a deliberate admin-level decision.

### Lookup permission — for transactional dropdowns only

```
entity.lookup        Read id + display columns of active records only
```

This is a single permission, not four. Lookup is always read-only, always active-only, always minimal columns. It lives in a separate, flatter module namespace (`projects`, not `projects_mgmt`) so it is semantically distinct from management access.

### Why two module codes

`projects_mgmt` means "manage the projects catalogue." `projects` (or `projects_mgmt.lookup` if you prefer to co-locate) means "use projects as reference data." A permission auditor can answer "who manages projects?" and "who uses projects as a lookup?" as two independent questions.

---

## 3. Naming Conventions

### Permissions

```
{module_code}.{action}
```

| Permission | Meaning |
|---|---|
| `projects_mgmt.view` | Admin: read full projects table |
| `projects_mgmt.create` | Admin: insert new project |
| `projects_mgmt.edit` | Admin: update any project field |
| `projects_mgmt.delete` | Admin: delete project |
| `projects.lookup` | Transactional: read id+name of active projects |

### Views

```
vw_{entity}_lookup
```

Examples: `vw_projects_lookup`, `vw_currencies_lookup`, `vw_departments_lookup`, `vw_cost_centers_lookup`, `vw_picklists_lookup`

### RLS policies

```
{table}_{operation}_{context}
```

| Policy name | Purpose |
|---|---|
| `projects_select_mgmt` | Admin full read |
| `projects_select_lookup` | Employee active-only read |
| `projects_insert` | Admin write |
| `projects_update` | Admin write |
| `projects_delete` | Admin write |

---

## 4. The Lookup View Pattern in Full

### Master table (full schema, strict RLS)

```sql
CREATE TABLE projects (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text        NOT NULL,
  code           text        UNIQUE,
  description    text,
  start_date     date,
  end_date       date,
  active         boolean     NOT NULL DEFAULT true,
  budget         numeric(18,2),
  internal_notes text,                          -- never expose to employees
  created_by     uuid        REFERENCES auth.users,
  updated_by     uuid        REFERENCES auth.users,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz                    -- soft delete
);
```

### Lookup view (minimal, safe, pre-filtered)

```sql
CREATE OR REPLACE VIEW vw_projects_lookup AS
SELECT
  id,
  name,
  code,
  start_date,
  end_date
FROM  projects
WHERE active     = true
  AND deleted_at IS NULL;

COMMENT ON VIEW vw_projects_lookup IS
  'Safe read-only view for transactional dropdowns. '
  'Exposes id+name+code of active projects only. '
  'No budget, internal_notes, or audit columns. '
  'Requires projects.lookup permission via base table RLS.';
```

**What the view deliberately hides:** `budget`, `internal_notes`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`

**What the view deliberately includes:** `id` (required for FK storage), `name` (display label), `code` (secondary identifier), `start_date`/`end_date` (useful for filtering in date-aware lookups)

The view is not security enforcement — RLS on the base table is. The view is **column and row restriction as a contract**: it defines what "lookup" means for this entity, centrally, in one place.

---

## 5. RLS Design

### The OR-logic model

PostgreSQL evaluates multiple `SELECT` policies with OR logic: a row is visible if **any** policy returns true for that row. This lets you layer admin access and lookup access independently on the same table.

```sql
-- Policy 1: Admin reads everything (all columns accessible, all rows including inactive)
CREATE POLICY projects_select_mgmt ON projects FOR SELECT
  USING (user_can('projects_mgmt', 'view', NULL));

-- Policy 2: Employee reads active rows only (view enforces column restriction)
CREATE POLICY projects_select_lookup ON projects FOR SELECT
  USING (
    active     = true
    AND deleted_at IS NULL
    AND user_can('projects', 'lookup', NULL)
  );

-- Write policies: management only
CREATE POLICY projects_insert ON projects FOR INSERT
  WITH CHECK (user_can('projects_mgmt', 'edit', NULL));

CREATE POLICY projects_update ON projects FOR UPDATE
  USING      (user_can('projects_mgmt', 'edit', NULL))
  WITH CHECK (user_can('projects_mgmt', 'edit', NULL));

CREATE POLICY projects_delete ON projects FOR DELETE
  USING (user_can('projects_mgmt', 'edit', NULL));
```

**What each user sees:**

| User | `projects_select_mgmt` | `projects_select_lookup` | Result |
|---|---|---|---|
| Admin with `projects_mgmt.view` | true | — | All rows, all columns |
| Employee with `projects.lookup` | false | true (active only) | Active rows only, but column restriction via view |
| Neither | false | false | Nothing |

### Important: column restriction lives in the view, not RLS

RLS controls which **rows** are visible. PostgreSQL does not support per-column RLS without additional complexity. The lookup view is the clean solution: it defines which columns are safe to expose, and the frontend always queries the view (not the base table) for dropdowns.

An employee with `projects.lookup` can technically query `projects` directly and get active rows (RLS allows it), but they will see all columns. The architectural contract is enforced at the application layer: **transactional screens always query `vw_projects_lookup`**. Admin screens query `projects`.

If you need a hard column restriction at the DB level, use a SECURITY DEFINER view (see section 6).

---

## 6. Supabase Compatibility and RLS + VIEW Interaction

### SECURITY INVOKER (Supabase default, PostgreSQL 15+)

By default, Supabase views use `SECURITY INVOKER`: the calling user's identity is passed through to the underlying table. This means:

- When an employee queries `vw_projects_lookup`, their identity hits the base table's RLS
- `projects_select_lookup` fires, checking `user_can('projects', 'lookup', NULL)`
- If it passes, they see active rows. If not, zero rows
- The view's `WHERE active = true` applies on top

This is the **correct and recommended pattern** for Supabase. RLS remains the authoritative gate. The view is just column and row restriction on top.

```sql
-- Confirm your view is SECURITY INVOKER (Supabase default)
SELECT viewname, definition
FROM pg_views
WHERE viewname = 'vw_projects_lookup';
-- No special declaration needed — INVOKER is the default
```

### SECURITY DEFINER views (hard column restriction)

If you need to guarantee employees **cannot** access certain columns even through direct table queries, use a SECURITY DEFINER view. The view runs as its owner (postgres), bypassing table RLS — so you must implement all access control inside the view itself.

```sql
CREATE OR REPLACE VIEW vw_projects_lookup
WITH (security_invoker = false)  -- SECURITY DEFINER
AS
SELECT
  id,
  name,
  code,
  start_date,
  end_date
FROM  projects
WHERE active     = true
  AND deleted_at IS NULL
  AND user_can('projects', 'lookup', NULL);  -- permission check inside view

-- Grant SELECT directly on the view to authenticated users
GRANT SELECT ON vw_projects_lookup TO authenticated;
```

The `user_can()` check inside the view body replaces RLS. This is a clean pattern but means the permission check is in two places if you also have RLS on the base table. **Avoid mixing the two** — choose one approach per view.

**Recommendation for Prowess:** use SECURITY INVOKER with base table RLS (simpler, consistent, auditable). Use SECURITY DEFINER only if you have genuinely sensitive columns that must never be reachable even via direct table queries.

### Supabase REST API — views are first-class

Supabase auto-generates REST endpoints for views the same way it does for tables. No additional configuration needed.

```typescript
// Works exactly like a table query
const { data } = await supabase
  .from('vw_projects_lookup')
  .select('id, name')
  .order('name')
```

---

## 7. Frontend Querying Patterns

### Two hooks, two surfaces

```typescript
// src/hooks/useProjectsLookup.ts
// Used by: line item forms, any dropdown needing project selection
export function useProjectsLookup() {
  const [items, setItems] = useState<ProjectLookup[]>([]);

  useEffect(() => {
    supabase
      .from('vw_projects_lookup')   // ← view, not base table
      .select('id, name, code')
      .order('name')
      .then(({ data, error }) => {
        if (!error) setItems(data ?? []);
      });
  }, []);

  return items;
}

// src/hooks/useProjects.ts
// Used by: admin Projects management screen only
export function useProjects() {
  const [projects, setProjects] = useState<Project[]>([]);

  useEffect(() => {
    supabase
      .from('projects')             // ← base table, all columns
      .select('*')
      .order('name')
      .then(({ data, error }) => {
        if (!error) setProjects(data ?? []);
      });
  }, []);

  return projects;
}
```

### Always store FK IDs, never names

```typescript
// Correct — store the uuid FK
const handleProjectSelect = (project: ProjectLookup) => {
  setLineItem(prev => ({ ...prev, project_id: project.id }));
};

// Wrong — name can change, lookup is slow, FK integrity is lost
const handleProjectSelect = (project: ProjectLookup) => {
  setLineItem(prev => ({ ...prev, project_name: project.name }));  // ❌
};
```

When displaying a stored line item, join through the view to get the current display name:

```sql
SELECT
  li.*,
  p.name AS project_name    -- resolved at display time, not stored
FROM line_items li
LEFT JOIN vw_projects_lookup p ON p.id = li.project_id;
```

### Cache lookup data aggressively

Reference data changes rarely. In React Query:

```typescript
useQuery({
  queryKey: ['projects-lookup'],
  queryFn: fetchProjectsLookup,
  staleTime: 10 * 60 * 1000,   // 10 minutes
  gcTime:    30 * 60 * 1000,   // 30 minutes
})
```

---

## 8. Why Not the Alternatives

### Alternative A: Duplicate lookup tables

```sql
-- Don't do this
CREATE TABLE project_lookup_cache (id uuid, name text);
```

This approach requires a sync mechanism (triggers or scheduled jobs) to keep the cache in sync with the master. When the master changes, the cache lags. When a migration adds a column, you must update two tables. FK constraints from line_items must reference the master, making the cache useless for anything authoritative. The entire pattern is an anti-pattern in systems with a real database: views solve the same problem without any of these costs.

### Alternative B: Reuse management permissions for lookup

```sql
-- Don't do this
-- Grant projects_mgmt.view to all employees so they can see the dropdown
```

Every employee in the system now holds an admin-level permission. Permission audits are meaningless ("who has projects_mgmt.view?" returns 500 employees). Admin screens that gate on `projects_mgmt.view` in the UI are now accessible to all employees — the UI guard works but the mental model is broken. When you later want to restrict who manages projects, you cannot tighten `projects_mgmt.view` without breaking the expense form dropdown for everyone. The two concerns are coupled at the permission level.

### Alternative C: Module-coupled implicit permissions

```sql
-- Don't do this
-- Assume: having expense_reports.view implicitly grants access to the projects table
```

This creates hidden dependencies between modules. The expense module now implicitly depends on the projects module. Changing one module's permissions silently affects the other. When a new module (timesheets, purchase orders) also needs a project dropdown, it couples to projects again through its own permission — and there is now no single answer to "who can see projects?" You have to trace all modules that have implicit dependencies. The lookup permission makes this explicit and auditable.

---

## 9. Applied to Prowess — Migration 147 Design

The pattern for Prowess is: one migration that seeds lookup permissions, adds lookup policies to all affected tables, and creates the lookup views.

**Entities needing lookup views:**

| Entity | Lookup permission | View name | Columns |
|---|---|---|---|
| `projects` | `projects.lookup` | `vw_projects_lookup` | id, name, code, start_date, end_date |
| `currencies` | `currencies.lookup` | `vw_currencies_lookup` | id, code, name, symbol |
| `exchange_rates` | — | — | (not a dropdown entity — rates are used programmatically) |
| `picklists` | `picklists.lookup` | `vw_picklists_lookup` | id, name, code |
| `picklist_values` | `picklists.lookup` | `vw_picklist_values_lookup` | id, picklist_id, value, display_order |
| `departments` | `departments.lookup` | `vw_departments_lookup` | id, name, code |
| `cost_centers` | `cost_centers.lookup` | `vw_cost_centers_lookup` | id, name, code |

**Permission set assignments:**

| Permission set | Gets these lookup permissions |
|---|---|
| ESS (all employees) | `projects.lookup`, `currencies.lookup`, `picklists.lookup` |
| Finance | All of the above + any finance-specific lookups |
| Admin | Gets `*_mgmt.*` — lookup permissions redundant but harmless |

**Frontend hook updates:**

| Hook | Change |
|---|---|
| `useProjects` | Add `useProjectsLookup` variant querying `vw_projects_lookup` |
| `useExpenseData` | Switch project fetch to `vw_projects_lookup` |
| Future currency dropdowns | Query `vw_currencies_lookup` |
| Category/type dropdowns | Query `vw_picklist_values_lookup` |

---

## 10. Tradeoffs and Long-Term Considerations

### What you gain

**Security isolation.** Admin and lookup access are independently controllable. Tightening admin access never affects dropdowns. Removing an employee's lookup access never affects admin screens.

**Audit clarity.** "Who can manage projects?" and "Who can see the projects dropdown?" are answerable as clean permission queries.

**Schema evolution.** Adding columns to the master table is invisible to transactional users — the view is unchanged until you explicitly update it. Removing sensitive columns from the view is a one-line change, not a frontend refactor.

**Central filtering.** `active = true AND deleted_at IS NULL` lives in one place: the view definition. If the filter logic changes, it changes once.

**Frontend hygiene.** Admin hooks and lookup hooks are separate code paths. A developer adding a new dropdown knows to reach for `useProjectsLookup`, not `useProjects`. The codebase expresses intent.

### What it costs

**More objects to maintain.** Every entity with a dropdown needs a view, a permission, and two RLS policies instead of one. This is real overhead and should be accepted consciously.

**View definitions can drift.** If someone adds a column to the master table that should also appear in the lookup view (e.g., a display code), they must remember to update the view. The view is a contract — breaking changes are possible if not reviewed.

**No column-level RLS without SECURITY DEFINER.** With SECURITY INVOKER, an employee who knows the table name and has `projects.lookup` can query `projects` directly and see all columns. The architectural contract (use the view) is enforced at the application layer, not the DB layer. This is an acceptable tradeoff in most enterprise systems; use SECURITY DEFINER only where column-level hard enforcement is a compliance requirement.

### Long-term recommendation

Adopt this pattern from the start for every new entity that will serve as reference data in transactional workflows. Retrofitting it to existing entities (as Prowess is doing with migration 147) is straightforward because the master table doesn't change — you're only adding policies and views on top.

As the system grows, consider a naming convention check in CI: any `.from('projects')` call outside the admin module directory should be a lint warning. This makes the architectural boundary explicit in the tooling.

---

## 11. Summary Reference

```
MASTER TABLE          LOOKUP VIEW              PERMISSION
─────────────         ─────────────────────    ─────────────────────
projects              vw_projects_lookup        projects.lookup
  id                    id                      (ESS permission set)
  name                  name
  code                  code
  description     ✗
  budget          ✗
  internal_notes  ✗     WHERE active = true
  active                AND deleted_at IS NULL
  deleted_at      ✗
  created_by      ✗
  updated_by      ✗
  created_at      ✗
  updated_at      ✗

ADMIN SCREEN                    TRANSACTIONAL SCREEN
─────────────────────────────   ──────────────────────────────────────
useProjects()                   useProjectsLookup()
  .from('projects')               .from('vw_projects_lookup')
  .select('*')                    .select('id, name')
  → requires projects_mgmt.view   → requires projects.lookup
  → sees all rows                 → sees active rows only
  → sees all columns              → sees id, name, code only
```
