# Prowess Reporting Suite — Design

**Status:** DESIGN, 2026-08-17. Nothing here is built except where noted as shipped.
**Supersedes:** the ad-hoc two-report plan in `prowess-reports-module` memory.
**Depends on:** mig 744 (the two timesheet report RPCs, shipped), the report registry
(`src/components/admin/reports/registry.ts`, shipped).

---

## 0. The four decisions this document makes

1. **Build one grid, not five reports.** Every capability the brief asks for — saved
   views, pinned columns, subtotals, grouping, column visibility, bulk export,
   keyboard shortcuts — is asked for five times identically. That is a *data grid*
   requirement. Built per-report it will be built five times and diverge within two
   months. → §2
2. **The suite is three reports and one dashboard, not five.** Project Summary is a
   saved view of Utilisation. Missing Entries is a drill-down from Compliance. Both
   still appear as their own catalog rows; neither is its own screen. → §1.2
3. **Two schema gaps block the flagship report.** `projects` has no billable flag and
   no manager. Without them Utilisation cannot answer the question Finance opens it
   for, and a Project Manager cannot be scoped to their own projects. → §3
4. **The current chart palette is measurably inaccessible and must be replaced.**
   Not an opinion — `#8E24AA` and `#3949AB`, adjacent slots in the palette shipping
   in `ExpenseReport.tsx` today, are ΔE 1.6 apart under protanopia. → §6.1

5. **The suite leads with insight, not with a grid.** `Insights → KPIs → Charts →
   Grid → Drill-down → Actions`. Built as a **deterministic rule engine**, with a
   typed producer interface so an AI producer can be added later without redesigning
   anything. Rules, not generation, because a payroll-adjacent claim has to be
   reproducible and clickable. → §2.7
6. **The lifecycle is nine stages, not three.** Discover · Open · Filter · Investigate
   · Act · Export · Schedule · Share · Audit. Four of those were missing from the first
   draft and each implies real features. → §1.3b

**Added after design review:** Workforce Capacity as a fourth report (§10b), the SLA
band on Compliance (§7.2b), KPI deltas and Compare (§7.2c–d), Top Activities and its
free-text problem (§8.2), Project Health with `budget_hours` (§9), business-event
scheduling (§13.5), report access audit (§13.6), watermarking (§13.4b), the reminder
escalation ladder (§7.7), natural-language search with its work shown (§7.4), and
mobile period swipe (§14).

---

## 1. Information architecture

### 1.1 Where reporting lives

```
/admin/reports                     the catalog  (permission: reports_admin.view)
  ├─ Expense Report                            expense_reports.view
  ├─ Timesheet Report                          timesheet_reports.view
  │    ├─ Compliance      (tab)
  │    └─ Utilisation     (tab)
  ├─ Project Summary      (preset of Utilisation)   timesheet_reports.view
  └─ Executive Dashboard                       timesheet_analytics.view   ← new permission
```

The catalog row is the **module**; tabs are **views**; presets are **saved views
promoted to the catalog**. This is the pattern that makes report six cheap.

### 1.2 Report hierarchy — and what is deliberately *not* a report

| The brief asked for | What it becomes | Why |
|---|---|---|
| Compliance Report | **Report** (tab 1 of Timesheet Report) | The month-end worklist. Its own grain, its own actions |
| Utilisation Report | **Report** (tab 2) | Different grain, different audience |
| Missing Entries | **Drill-down** from a Compliance row | Same question, finer grain. "Ali is 12 days short" → click → *which* 12 days. Making it a sibling means leaving, re-filtering and finding Ali again |
| Project Summary | **Preset** of Utilisation, own catalog row | Identical rows, `groupBy: project`, chart header. Once the grid groups and subtotals, a second screen is duplication |
| Executive Dashboard | **Dashboard** | Genuinely different: aggregate-only, no row grain, nightly rollup, different refresh contract |

**Recommended additions the brief did not list:**

| Report | Purpose | Persona |
|---|---|---|
| **Approval Turnaround** | Already exists as `WorkflowPerformanceDashboard.tsx` — cycle time, SLA, bottleneck. **Do not rebuild.** Link to it from the Exec dashboard | HR, Ops |
| **Time Audit Trail** | Every entry added, edited or deleted after approval, from `timesheet_entry_audit` (743). Payroll and internal audit ask for this and nothing else answers it | Payroll, Audit, Compliance officer |
| **Configuration Health** | Employees with no work schedule, no holiday calendar, or an expired project. Today `not_configured` is a state buried inside Compliance; at 50k it is its own admin worklist | Time Administrator |

Time Audit Trail is the one I would fight for. It is cheap — the table exists, is
append-only and is already indexed by header — and it is the only report in the suite
that answers a question with legal weight.

### 1.3 Navigation flow

```
Admin ▸ Reports ─┬─▶ Timesheet Report ─┬─▶ [Compliance]  ─▶ row ─▶ Employee timesheet (read-only month)
                 │                     │                  └─▶ "12 days missing" ─▶ Missing Entries (day grain)
                 │                     └─▶ [Utilisation] ─▶ row ─▶ Employee timesheet, scrolled to that date
                 ├─▶ Project Summary ──▶ project ─▶ Utilisation, pre-filtered to that project
                 └─▶ Executive Dashboard ─▶ any tile ─▶ Compliance, pre-filtered to what the tile counted
```

**Every drill-through carries its filters forward and a breadcrumb back.** The single
most common enterprise reporting failure is the one-way drill: a user clicks a number,
lands on a list, presses Back, and loses the filter set they spent a minute building.
Workday gets this right and it is most of why its reporting feels fast.

### 1.3b The report lifecycle

The design originally assumed **open → filter → export**. That is a third of the real
lifecycle, and the missing two thirds are where enterprise reporting either earns its
keep or becomes a spreadsheet factory.

| Stage | The user's question | What the suite owes them | Built in |
|---|---|---|---|
| **Discover** | "Is there a report for this?" | Catalog search across name, description AND column names; a "recently run" strip; role-suggested rows | B |
| **Open** | — | Lands on a saved view, not a blank grid | B |
| **Filter** | "Narrow to my problem" | Filters, quick search, saved views | B |
| **Investigate** | "Why is this number what it is?" | **Insight cards** (§2.7), drill-through, compare-to-prior | B / F |
| **Act** | "Do something about it" | Row actions, bulk reminders, escalation | F |
| **Export** | "Take it out" | Excel / CSV / PDF / print | C |
| **Schedule** | "Send it to me every month" | Business-event schedules (§13.5) | F |
| **Share** | "Give this to my colleague" | Share a **view definition**, never data — the recipient re-runs it under their own scope | B |
| **Audit** | "Who saw this?" | Report access log (§13.6) | F |

Naming the stages is not documentation for its own sake: **Discover, Act, Share and
Audit each imply features that were absent**, and three of them are procurement
questions an enterprise buyer will ask before they ask about columns.

### 1.4 Persona → surface (challenging the brief)

The brief lists seven personas and implies all seven use the reports. Three should not
have to.

| Persona | Needs | Surface | Report? |
|---|---|---|---|
| Employee | "Am I behind?" | **MyTimesheet** — a banner on their own month | **No report.** An employee who must open a report to find out they are late has been failed by the timesheet screen |
| Line Manager | "What is waiting on me?" | **Approver Inbox** (exists) | **No report.** A manager's worklist is the inbox; a report is a second place for the same queue to disagree |
| Project Manager | "Where did my project's hours go?" | Project Summary | Yes — **blocked** on §3 |
| HR / Time Admin | "Who needs chasing?" | Compliance | Yes |
| Payroll | "Can I close?" | Compliance, `Payroll ready %` KPI + Missing Entries | Yes |
| PMO / Finance | "Billable utilisation" | Utilisation | Yes — **blocked** on §3 |
| Executive | "Are we healthy?" | Dashboard **delivered by email** | Yes, but see §11 |

Cutting Employee and Line Manager out of the report suite is not a reduction in
service. It is the recognition that a report is a *pull* surface and those two
personas need a *push* one.

---

## 2. The ReportGrid platform

### 2.1 Why one grid

SAP SuccessFactors carries both a generic report engine and bespoke time screens, and
the bespoke ones are where the complaints live: each behaves slightly differently, so
learning one teaches you nothing about the next. Workday went the other way — one
engine, many definitions — and a user who can drive one Workday report can drive all
of them.

The cost of the platform is paid once. The cost of *not* building it is paid on every
report, forever, and compounds because the copies drift.

### 2.2 Capability matrix

| Capability | Compliance | Utilisation | Project Summary | Exec Dashboard |
|---|:--:|:--:|:--:|:--:|
| Saved views | ✔ | ✔ | *is one* | ✖ fixed |
| Column visibility / reorder | ✔ | ✔ | ✔ | ✖ |
| Column resize | ✔ | ✔ | ✔ | ✖ |
| Frozen header row | ✔ | ✔ | ✔ | n/a |
| Pinned first column | ✔ Employee | ✔ Employee | ✔ Project | n/a |
| Grouping + subtotals | ✖ | ✔ | ✔ | n/a |
| Grand total row | ✖ | ✔ | ✔ | n/a |
| Conditional formatting | ✔ state, overdue | ✔ variance | ✔ | n/a |
| Sparklines | ✖ | ✖ | ✔ trend | ✔ |
| Charts | **✖** | ✔ 2 | ✔ 3 | ✔ 5 |
| Multi-select rows | ✔ | ✖ | ✖ | ✖ |
| Bulk actions | ✔ | ✖ | ✖ | ✖ |
| Row actions | ✔ | ✔ | ✔ | ✖ |
| Drill-through | ✔ | ✔ | ✔ | ✔ |
| Excel / CSV export | ✔ | ✔ | ✔ | ✔ |
| PDF export | ✔ | ✔ | ✔ | ✔ |
| Scheduled email | ✔ | ✔ | ✔ | ✔ |

**Why no grouping on Compliance.** It is a chase list. Grouping hides names behind
collapsed headers, which is the opposite of what someone assembling a list of people
to email needs. Department is a *filter* there, not a grouping.

**Why no multi-select on Utilisation.** There is no action you can take on a timesheet
entry from a report. A checkbox column that leads only to "export selected" is a
control that promises more than it does.

**Why no charts on Compliance.** The reader's job is "produce a list of names". A
chart of states is eight colours spent on a number the KPI row already shows — the
most common way a chart misses its point.

### 2.3 The report definition contract

```ts
interface ReportColumn {
  key:        string;
  label:      string;
  width?:     number;
  align?:     'left' | 'right' | 'center';
  pinned?:    'left';
  sortable?:  boolean;          // maps to a server-side sort key
  format?:    'text' | 'hours' | 'date' | 'period' | 'percent' | 'int';
  hiddenByDefault?: boolean;
  render?:    (row) => ReactNode;      // chips, badges, drill links
  total?:     'sum' | 'avg' | 'none';  // drives subtotal + grand total
  conditional?: (row) => CellTone;     // 'neutral' | 'good' | 'warning' | 'critical'
  exportOnly?: boolean;         // in the spreadsheet, not on screen
}

interface ReportDefinition {
  code:        string;
  rpc:         string;                  // one server function per report
  columns:     ReportColumn[];
  filters:     FilterSpec[];
  defaultSort: { key: string; dir: 'asc' | 'desc' }[];
  defaultFilters: Record<string, unknown>;
  rowKey:      (row) => string;
  rowActions?: RowAction[];
  bulkActions?: BulkAction[];
  groupBy?:    { allowed: string[]; default?: string };
  drill?:      (row) => DrillTarget;
  emptyStates: { noData: string; filtered: string; allClear?: string };
}
```

Everything in `§7`–`§10` below is an instance of this. Nothing in `ReportGrid` knows
what a timesheet is.

### 2.4 Saved views

**Data model** (new migration):

```sql
report_views (
  id, report_code, owner_id, name,
  is_shared    boolean,        -- visible to anyone with the report's permission
  is_default   boolean,        -- this user's landing view for this report
  filters      jsonb,          -- the filter payload
  columns      jsonb,          -- order, visibility, widths
  sort         jsonb,
  group_by     text,
  created_at, updated_at
)
```

RLS: a user reads their own views plus shared ones; writes only their own. Sharing a
view **shares the definition, never the data** — the recipient runs it under their own
scope, so a manager opening HR's shared view sees only their own team. This is the
subtlety SuccessFactors got right and many products get wrong: a shared report that
leaks rows is a security incident wearing a convenience feature's clothes.

**UX.** A view selector in the header, not a modal: `▾ My default view`, with
`Save`, `Save as…`, `Reset to default`, `Share`. Unsaved changes show a dot on the
selector and a `Save` affordance — never an "are you sure" dialog on navigate.

### 2.5 Column preferences

Stored in the active saved view, not separately. A user who drags a column and reloads
expects it to stay; a user who switches views expects the view's layout. One store,
one mental model.

### 2.7 The Insight layer — rules first, AI later

**The architecture is `Insights → KPIs → Charts → Grid → Drill-down → Actions`.** The
reader sees *what matters*, then *why*, then the data. This is the direction Microsoft
Fabric, Salesforce, Workday Illuminate and SAP Joule have all taken, and it is the
single biggest thing the first draft of this design was missing.

**But build it as a deterministic rule engine, not a language model.** Every example
worth showing is computable:

```
✓ Payroll readiness is up 8 points on last month.            (rate delta)
⚠ Engineering has 17 overdue submissions — 3 months running. (threshold + streak)
⚠ Finance approval SLA worsened by 2 days.                   (metric delta)
• Project Atlas took 41% of recorded hours.                  (concentration)
⚠ Four employees changed an approved timesheet.              (audit count)
```

Not one of those needs generation. Doing them with an LLM would buy non-determinism on
a payroll-adjacent surface, per-view latency and cost, and — worst — a claim nobody can
reproduce. A rule engine gives the same sentences, instantly, identically, every time.

**Four rules that make insight cards trustworthy rather than decorative:**

1. **Every insight is a link.** Clicking "17 overdue in Engineering" applies exactly
   that filter. An insight you cannot click through to the rows is a claim you cannot
   check, and a claim nobody can check gets ignored within a month.
2. **Insights are computed inside the caller's scope.** They are aggregates, and
   aggregates leak: an org-wide insight shown to a manager scoped to eight people
   discloses everything that manager's scope exists to withhold. Same scope predicate
   as the rows (§4.1), no exceptions.
3. **Ranked and capped at 3–5.** Each rule emits a card with a severity and a
   magnitude; the surface shows the top few. Twelve bullets is a wall of text with the
   same information density as no bullets.
4. **Silence is a valid output.** "Nothing needs attention this month" is an insight.
   Manufacturing five bullets when the month was quiet trains people to skip the band.

**Rule catalogue for v1** (each is a SQL predicate over the rollup, not a prompt):

| Rule | Fires when | Severity |
|---|---|---|
| Rate movement | any KPI rate moves > 5 points vs prior period | good / warning |
| Concentration | one project/department > 40% of the measure | info |
| Streak | the same department fails the same threshold ≥ 3 periods | serious |
| Threshold breach | compliance < 80%, SLA > target, payroll-ready < 95% at close −2d | critical |
| Post-approval change | any `changes_since_approval > 0` in the set | serious |
| Outlier | a department > 2σ from the org mean | info |
| Configuration | any `not_configured` rows exist | warning |

**The AI extension point — define it now, build it later.** The seam is a typed
contract, not a chat box:

```ts
interface InsightContext {          // what a producer may read
  reportCode: string;
  period: { from: string; to: string };
  compareTo?: { from: string; to: string };
  scope: ScopeDescriptor;           // never bypassed
  aggregates: Record<string, number>;
  breakdowns: Record<string, {key: string; label: string; value: number}[]>;
  priorAggregates?: Record<string, number>;
}

interface InsightCard {
  id: string;
  tone: 'good' | 'info' | 'warning' | 'serious' | 'critical';
  text: string;                     // one sentence, no jargon
  evidence: Record<string, number>; // the numbers behind the sentence
  filter?: Record<string, unknown>; // click → apply this
  rule: string;                     // which rule produced it — always attributable
}

type InsightProducer = (ctx: InsightContext) => Promise<InsightCard[]>;
```

`RuleEngineProducer` ships in v1. An `LlmProducer` implementing the same interface can
be added later — reading the same context, emitting the same cards, obeying the same
scope — with no change to any screen. Later capabilities ("Why did payroll readiness
drop?", "Summarise the biggest risks") are additional producers over the same context,
**and every card they emit still carries `rule` and `evidence`**, so an AI-authored
insight is as auditable as a computed one. That constraint is what makes it safe to
add AI to a payroll surface at all.

### 2.8 Saved dashboards — presets, not a canvas

Saved *views* are per-report. A saved *dashboard* is a composition across reports:
**My Dashboard · HR · Payroll · Executive · Project Manager**, each a set of widgets
(KPI tile, chart, insight band, mini-grid) with a role default and a user override of
which one is their landing page.

**Recommendation: ship four curated role dashboards, not a drag-and-drop builder.**

Widget-composable canvases are the most requested and least used feature in enterprise
BI. They demand a widget registry, layout persistence, per-widget scoping, resize and
drag behaviour, and a mobile story for arbitrary layouts — and the overwhelming
majority of users keep the default. Build the widget *components* (which the role
dashboards need anyway), ship four opinionated compositions, and let the demand for
user-composed layouts prove itself before funding it. The seam is already there if it
does: a dashboard is a list of widget ids plus a layout, and that is a row in a table
whenever it is wanted.

There is a second reason, specific to the executive surface: a dashboard that can be
rearranged loses the property that makes it useful monthly — looking identical every
time, so that a change in the *data* is the only thing that moves.

### 2.6 Server-side contract

Every report RPC takes and returns the same envelope:

```jsonc
// request
{ "filters": {...}, "sort": [{"key":"due_date","dir":"desc"}],
  "group_by": "project", "cursor": "…", "page_size": 50 }

// response
{ "ok": true,
  "rows": [...],            // the page
  "totals": {...},          // WHOLE filtered set, never the page
  "groups": [...],          // subtotals when group_by is set
  "scope": {"mode":"scoped","employee_count":42},
  "cursor_next": "…",
  "total_rows": 4173,
  "as_of": "2026-08-17T02:00:00Z"   // only on rollup-backed reports
}
```

**`totals` is computed over the whole filtered set, never the page.** A footer that
totals only what is visible is a footer that lies from page two onward, and it is the
single most common bug in enterprise grids.

---

## 3. Schema additions — migration 754, SHIPPED

Three columns block three things. Two unblock reports; one unblocks a persona.

```sql
ALTER TABLE projects
  ADD COLUMN project_type text
    CHECK (project_type IS NULL OR project_type IN ('billable','internal','overhead')),
  ADD COLUMN manager_id   uuid REFERENCES employees(id) ON DELETE SET NULL,
  ADD COLUMN budget_hours numeric(10,2) CHECK (budget_hours IS NULL OR budget_hours > 0);

CREATE INDEX idx_projects_manager ON projects (manager_id) WHERE manager_id IS NOT NULL;
```

**`project_type` moved to the picklist system in 20260819755.** The CHECK
allow-list above made the set of project types a schema fact: adding "Pre-sales"
would need a migration, a deploy and a developer. Every other classification in
Prowess is a picklist an admin edits in Reference Data, and this one is no
different in kind. The column is now `project_type_id uuid REFERENCES
picklist_values(id) ON DELETE SET NULL`, following the `line_items.category_id`
precedent, with a trigger pinning it to the `PROJECT_TYPE` list — a bare FK to
`picklist_values` would accept a CURRENCY row. The old text column is retained
and marked deprecated until a later migration drops it, so 755 can deploy ahead
of the frontend rather than breaking the screen that still selects it.

**20260820758 put the list on the house rules**, which 755 had missed in two
ways. The picklist is now `system = true`, so Reference Data hides Edit and
Delete on it as it does for every other built-in list — without that flag,
deleting the picklist would cascade its values and `ON DELETE SET NULL` would
silently unclassify every project pointing at them. And the values are coded
`P001` / `P002` / `P003` rather than `BILLABLE` / `INTERNAL` / `OVERHEAD`:
`generateRefId()` in `ReferenceData.tsx` issues the picklist's first letter plus
three digits, so non-conforming codes make the next admin-added value collide
at `P001`.

**Reports must match on `picklist_values.ref_id`** — `P001` billable, `P002`
internal, `P003` overhead — never on the label, which admins may rename. Opaque
codes are the price of following the convention, and the same price every
`D001` and `T001` in this database already pays.

### 3a. Which of these fields are mandatory, and why they differ

**Project Type is required when creating a project, and not when editing one.**
Whoever creates a project knows whether it is billable, and that is the only
cheap moment to capture it — left optional it stays `Not classified` forever and
billable utilisation is quietly computed over a partial portfolio. Blocking an
*edit*, though, means someone extending an end date must classify a project
whose commercial arrangement they may know nothing about, and they will pick
something to clear the dialog. A required field that manufactures guesses is
worse than an optional one that leaves honest blanks, and the report is already
built to show the blank.

**Reporting Manager is not required, in either case.** The asymmetry is the
point: it is a *security* column. No manager grants nobody PM access — it fails
closed. A guessed manager grants real access to the wrong person — it fails
open. Projects also routinely exist before a delivery lead is assigned, so a
mandatory field would have no honest answer at creation time. The gap is made
visible instead of blocking: the list shows `None`, and Project Summary reports
"4 of 19 projects have no reporting manager". Require it at the point it
actually matters — when someone asks for PM access to that project.

**The general rule:** mandatory is right for a descriptive field with a knowable
answer, and wrong for a field where a placeholder grants something real.

**Enforced in the form, not with `NOT NULL`.** The existing projects are all
unclassified, so a `NOT NULL` column would need a backfill, and a backfill would
have to guess — the exact fabrication §3 removed. `NULL` must also stay
representable for §9.1. `Projects.tsx` is the only writer to the table, so a
form-level rule is sufficient and reversible.

**`project_type` is nullable with no default — a correction to this document's
first draft**, which specified `NOT NULL DEFAULT 'billable'`. That default would
classify every existing project as billable and put "Billable utilisation 100%" in
front of Finance on day one, computed entirely from a value nobody chose. It is the
same mistake as a fake denominator, and this suite has now made it twice (§8.1b).
`NULL` means *not classified*, the admin screen shows it as such, and the report
must too.

**`ON DELETE SET NULL` on `manager_id`.** A project whose manager row disappears
loses its manager and therefore grants nobody PM access — it fails closed. `RESTRICT`
would instead block deleting an employee because a project points at them, turning an
HR action into a project-admin puzzle.

The migration grants nothing. `timesheet.view_project`, the PM scope predicate and the
column redaction in §5 are deliberately *not* folded into a schema change: a column no
policy reads is inert, whereas adding a policy in the same breath as the column it
reads is how a scope bug ships unnoticed.

`projects` is shared with Expenses. These columns are additive and no expense policy
reads them. Keying expense visibility off `manager_id` later would be a separate,
deliberate decision — a timesheet PM scope must not silently become an expense scope.

**Why `project_type` and not `is_billable`.** A boolean forces overhead (leave,
holiday, training, bench) into "internal", and the first question after "what is our
billable utilisation" is always "what is the non-billable time actually going on".
Three values answer both; a boolean answers one and gets a second column bolted beside
it within a quarter.

**Why `manager_id` on the project rather than a members table.** Row-level security
needs one question answered — "is this caller the PM of this project" — and a
membership table answers a different, larger question nobody has asked for yet. Start
with the column; a `project_members` table is an additive change if assignment
tracking is ever needed.

**One manager per project, and it is the *reporting manager*** — the manager the
project reports into, not necessarily whoever runs delivery day to day. Co-owned
projects are the case this shape does not serve, and are the trigger for revisiting
the members table.

**`budget_hours` is what makes Project Health possible.** "Hours vs budget" is the
first question asked of any project report, and there is nowhere to put the budget
today. Nullable on purpose: a project without a budget shows consumption without a
percentage, rather than being excluded or showing a fake denominator. Hours rather
than currency — Prowess records time, not cost, and a money budget invites a
rate-card conversation this module should not own.

**Consequence for utilisation maths.** Utilisation % becomes ambiguous the moment
these exist, so define it once, here, and put the definition in the UI:

- **Billable utilisation** = billable minutes ÷ *planned* minutes
- **Recording rate** = recorded minutes ÷ planned minutes  ← what today's KPI shows

Today's "Utilisation %" is the second one and is silently mislabelled. Rename it
**Recording rate** now, before anyone builds a target on it.

---

## 3b. Permissions — one per report (migration 745, SHIPPED)

The first draft gave the whole timesheet report one key, `timesheet_reports.view`.
That was a coarse grant chosen for convenience, and the persona map two sections up
says the populations genuinely differ: a Project Manager has no business seeing who
across the org has not submitted a timesheet, and a payroll clerk has no need for the
billable analysis.

**One permission per view:**

```
reports_admin.view                        gates /admin/reports          (unchanged)
timesheet_reports.view_compliance         opens Compliance + its RPC
timesheet_reports.view_utilisation        opens Utilisation + its RPC
timesheet_reports.view_capacity           when Workforce Capacity ships
timesheet_reports.view_analytics          when the dashboard ships
```

### Three decisions inside that

**The umbrella `timesheet_reports.view` was retired, not kept as a section gate.**
Keeping it would have meant either two grants for one capability — grant the report,
the user still sees nothing, and the reason is invisible — or an umbrella that also
grants everything, so report five silently widens everyone who already holds it. The
section is already gated one level up by `reports_admin.view` on the route.

This honours migration 739 rather than reversing it. 739 kept `timesheet_reports.view`
because "PermissionMatrix DOES offer it, so an administrator can grant it today and
reasonably expect something to happen." The promise was that granting it *does*
something. Two specific permissions in the same band, each opening a named report,
keeps that promise better than one vague one did.

**Only the two built reports got permissions.** Seeding `view_capacity` and
`view_analytics` before their screens exist would recreate exactly what 739 spent a
migration cleaning up: keys an administrator can grant that do nothing.

**Doing it now was the whole point.** `timesheet_reports.view` was held by nobody, so
the split cost no backfill and changed nobody's access. The migration asserts that —
if the permission turns out to be granted, it aborts and tells the operator to grant
the replacements first, rather than quietly removing somebody's access.

### The catalog adapts rather than promising a choice

`ReportDef` declares `views[]`, each with its own permission, and the row renders:

| Permitted views | Row |
|---|---|
| 0 | Locked, dimmed, listing every permission that would unlock it |
| 1 (of several) | Takes **that view's** name, icon and description; opens straight into it; **no tab strip** |
| 2+ | The report's name, tabs for the permitted views only |

A segmented control containing one segment is a control that lies about having a
choice. The PERMISSION column lists every key the row involves, dimming the ones the
caller lacks, so an administrator can read off exactly what to grant.

### Enforcement is in the RPC, not the tab

Hiding a tab is cosmetic — both functions are reachable through PostgREST by anyone
holding a token. Migration 745 repoints each RPC at its own action, patched in place
with an asserted hit count so the Phase A pagination rework does not have to be rebased
onto a frozen copy. Same reasoning as 742, which made a rejected timesheet a property
of the data rather than of the markup.

**No change was needed in `PermissionMatrix.tsx`.** The Reports band already renders
whatever actions the RBP catalog holds for each module, so one key becoming two
appeared by itself — which is the payoff for having made that band registry-driven in
Phase 1 rather than hardcoding `reports_admin`.

---

## 4. Performance at 50,000 employees

The current RPCs are correct and will not survive this scale. Three specific problems,
in the order they will bite.

### 4.1 `time_report_scope()` returns an array — this is the hard ceiling

It returns `uuid[]` and every query does `col = ANY(scope)`. For an HR user scoped to
the whole company that is a 50,000-element array marshalled into every call and
compared row by row.

**Fix:** a scope *predicate*, not a scope *list*.

```sql
CREATE FUNCTION time_report_scope_sql() RETURNS TABLE (employee_id uuid) ...
-- used as: WHERE EXISTS (SELECT 1 FROM time_report_scope_sql() s WHERE s.employee_id = e.id)
```

or, better where the target group is expressible as a predicate, push the target-group
logic into the join itself. This is a rework of shipped code and should happen before
anything else is built on top of it.

### 4.2 Compliance builds 600,000 rows to show 50

`employees CROSS JOIN periods` then correlated subqueries **per row**, before `LIMIT`.
50k × 12 months = 600k evaluations to render one page.

**Fix — two-phase:**
1. Build the `(employee, period)` skeleton, apply filters and scope, sort, paginate.
   Cheap: no subqueries, index-only where possible.
2. Compute the expensive columns (`days_with_entries`, `changes_since_approval`) **for
   the page's 50 rows only**, via a lateral join on the paginated set.

Aggregates for the KPI row stay a separate query over the whole set — but a *counting*
query, not a row-building one.

### 4.3 Pagination strategy

| Report | Strategy | Why |
|---|---|---|
| Compliance | **Keyset** on `(period desc, due_date, employee_name, employee_id)` | Deep pages are real here — "show me everyone who has not submitted" is thousands of rows. `OFFSET 10000` re-scans 10,000 rows every time |
| Utilisation | Keyset on `(entry_date, employee_name, entry_id)` | Same, worse — millions of entries |
| Project Summary | Offset is fine | Grouped to hundreds of projects, not millions of rows |
| Dashboard | No pagination | Aggregates only |

Keyset costs an opaque `cursor` in the envelope and the loss of "jump to page 47".
Nobody jumps to page 47; everybody suffers a 9-second page 200.

### 4.4 Indexes required

```sql
CREATE INDEX idx_tsh_period_employee   ON timesheet_headers (period, employee_id);
CREATE INDEX idx_tse_header_date       ON timesheet_entries (header_id, entry_date);
CREATE INDEX idx_tse_project_date      ON timesheet_entries (project_id, entry_date)
  WHERE project_id IS NOT NULL;
CREATE INDEX idx_tea_entry_name        ON timesheet_entry_activities (entry_id);   -- exists
CREATE INDEX idx_ee_emp_effective      ON employee_employment (employee_id, effective_from, effective_to);  -- exists (351)
```

`timesheet_headers` already has `UNIQUE (employee_id, period)` — leading with
`employee_id`, which does not serve a report that filters on `period` first.

### 4.4b MEASURED — Phase A results (mig 746, 2026-08-18)

Run against Postgres 16 with a stand-in schema, 10,004 employees, 42/42 behaviour
tests passing before and after.

| Case | Before | After | |
|---|---|---|---|
| **Scoped** (a manager's team, 1 month) | 1,381 ms | **15 ms** | ~90× |
| Unscoped, 1 month, 10k employees | 1,685 ms | **438 ms** | ~4× |
| Unscoped, 12 months, 120,046 rows | 4,586 ms | 3,494 ms | 1.3× |

The scoped case is the one that matters most — most report users are scoped to a team
or a department, and that path is now effectively instant.

**Most of the original cost was not the query.** `EXPLAIN (ANALYZE)` on the real call
showed 1,607 ms total of which **JIT compilation was 1,570 ms**: Postgres compiled 104
functions to accelerate about 24 ms of actual execution. The trigger is estimate
inflation, not a bad plan — `generate_series` and any set-returning function default to
an estimated 1,000 rows, so the planner prices the period cross join at millions of
rows and the total cost lands far above `jit_above_cost`. `SET jit = 'off'` on the two
report functions removes it; PART 5 of the migration asserts the setting survives, so a
later `CREATE OR REPLACE` that drops it fails the deploy rather than quietly costing a
second and a half per screen.

Two smaller wins in the same migration: the ten separate `count(*)` scans of the
filtered set became one pass with `FILTER` (1,485 ms → 1,052 ms on a 30k skeleton), and
`time_submission_due_date()` moved from once per row to once per period.

**What is still open.** The unscoped 12-month case is 3.5 s here, which extrapolates to
roughly 17 s at 50,000 employees. That residue is the full-set summary, and it is
deliberate — §2.6 requires totals over everything so the footer does not lie at page
two. Removing it needs one of:

1. **Split the summary from the rows** — two requests, grid renders immediately, KPI
   band fills a moment later. What most enterprise grids do, and the cheapest.
2. **Cache the summary** per (filters, period) for a short TTL.
3. **Serve the unfiltered case from the nightly rollup** in §4.5 and compute live only
   when filters narrow the set.

Option 1 first. It is a frontend change plus an RPC split, and it makes the expensive
part asynchronous rather than trying to make it cheap.

### 4.5 Rollups and caching

The Executive Dashboard cannot be computed live. Twelve months of org-wide compliance
over millions of entries is a materialised view refreshed nightly by pg_cron:

```sql
CREATE MATERIALIZED VIEW mv_timesheet_monthly_rollup AS
  SELECT period, department_id, count(*) FILTER (...) AS ..., sum(...) ...
```

**And the dashboard must say so.** `as_of` in the envelope, rendered as
"As at 02:00 today" beside the title. A dashboard that looks live and is not is worse
than one that is honestly stale.

Row-level reports are **not** cached. Compliance exists to be acted on within minutes
of a submission; caching it would produce chase emails to people who have just
submitted, which is the fastest way to lose a reporting tool's credibility.

---

## 5. Row-level security

One rule: **the report never decides who you can see.** It asks the same
`user_can()` / target-population machinery the rest of Prowess uses, because a second
answer is a second thing to keep in step — and migration 740 exists precisely because
the client's flat permission list cannot see that a grant is scoped.

| Persona | Sees | Mechanism |
|---|---|---|
| Employee | Self only | `timesheet.view` scoped to `self`. In practice: no report access at all |
| Line Manager | Direct reports (L1) or hierarchy | `timesheet.view` + target group `direct_l1` / `hierarchy` |
| Project Manager | **Entries against their projects, all employees** | ⚠️ *New shape.* Not an employee-scoped grant — a project-scoped one. See below |
| HR | Everyone, or same-country / same-department | `timesheet.view` + `everyone` / `same_country` |
| Payroll | Everyone, read-only, plus Missing Entries actions | `timesheet_reports.view` + `timesheet.view` = everyone |
| Time Administrator | Everyone + Configuration Health | as HR, plus `time_*` config permissions |
| Executive | Aggregates only, no row access | `timesheet_analytics.view` — **new permission**, dashboard only |

### The Project Manager problem

Every other persona is scoped by *employee*. A PM is scoped by *project*, and the rows
they should see belong to employees they may have no right to see individually.

Two honest options:

**(a) Project-scoped rows, employee columns redacted.** A PM sees every entry against
their project, with employee name shown but department, manager and planned hours
hidden. Delivers the utilisation answer without leaking HR data.

**(b) Intersection.** A PM sees entries against their projects *and* employees already
in their target population. Safer, and frequently empty — a PM whose contributors sit
in another department sees nothing and concludes the report is broken.

**Recommendation: (a)**, with the redaction visible ("3 columns hidden by your
permissions") rather than silent. A PM needs to know hours went to their project; they
do not need to know the contributor's manager. Option (b) fails the report's purpose
often enough that people will route around it by asking HR for a spreadsheet — which
is a worse security outcome than (a).

This needs a new permission — `timesheet.view_project` — and is the single largest
piece of new security work in the suite. It should not be hand-waved into the first
release.

---

## 6. Visual system

### 6.1 The chart palette — measured, not chosen

**The palette shipping in `ExpenseReport.tsx` today fails three of six checks** on a
white surface. Run against the validator:

```
[FAIL] Chroma floor        #90A4AE  C=0.027 — reads as gray, does no identity work
[FAIL] CVD separation      #8E24AA ↔ #3949AB  ΔE 1.6 (protanopia)   target ≥ 8
[FAIL] Normal-vision floor #00ACC1 ↔ #0288D1  ΔE 11.3               floor ≥ 15
[WARN] Contrast vs surface #FB8C00 2.37:1 · #90A4AE 2.59:1 · #00ACC1 2.74:1
```

ΔE 1.6 means slots 3 and 4 are **the same colour** to a protanope — roughly 1 in 12
men. `#00ACC1` vs `#0288D1` at 11.3 means even full-colour readers struggle. This is
not a theoretical concern; it is on the expense charts now.

**Adopt this validated set instead** (passes all six on `#ffffff`, worst adjacent CVD
ΔE 9.1, worst normal-vision ΔE 19.6):

| Slot | Hue | Hex | Use |
|---|---|---|---|
| 1 | blue | `#2a78d6` | first series; the default single-series hue |
| 2 | orange | `#eb6834` | second series |
| 3 | aqua | `#1baf7a` | third series |
| 4 | yellow | `#eda100` | fourth — direct labels become mandatory here |
| 5 | magenta | `#e87ba4` | |
| 6 | green | `#008300` | |
| 7 | violet | `#4a3aa7` | |
| 8 | red | `#e34948` | |

Rules that come with it:

- **Assign in fixed order, never cycled.** A ninth series folds into "Other" or the
  chart facets. Never generate a hue.
- **Colour follows the entity, not its rank.** Filtering out a project must not
  repaint the survivors — a reader who learned "Atlas is blue" is misled otherwise.
- **Scatter / small-multiples cap at three series.** All-pairs separation only holds
  for the first three slots; past that, fold or facet.
- Slots 3, 4 and 5 sit below 3:1 on white, so any chart using them **must** carry
  visible direct labels or the table view. Not optional.

**Sequential** (heatmaps, magnitude): one blue hue, `#cde2fb` → `#0d366b`, with a
scale legend. Never a rainbow.
**Diverging** (variance against plan): blue ↔ red with a **neutral gray** midpoint
(`#f0efec`). Never a hue at the midpoint; never two cool poles.

### 6.2 Status colours — and a bug in shipped code

Status is a reserved scale — good / warning / serious / critical — never reused for a
series, and **always icon + label, never colour alone.**

Measured on white:

| Chip | Text on its tint | Verdict |
|---|---|---|
| Not configured `#92400E` on `#FEF3C7` | 6.37:1 | PASS |
| Not started `#991B1B` on `#FEE2E2` | 6.80:1 | PASS |
| To be submitted `#854D0E` on `#FEF9C3` | 6.38:1 | PASS |
| To be approved `#1E40AF` on `#DBEAFE` | 7.15:1 | PASS |
| Approved `#166534` on `#DCFCE7` | 6.49:1 | PASS |

The chips are fine. Two things are not:

**(1) The seeded `time_color_config` values fail as marks.**
`status_draft #F59E0B` is 2.15:1 and `status_approved #10B981` is 2.54:1 on white —
below the 3:1 a mark needs. They are safe as *chip tints behind dark text* and unsafe
as bare dots, bars or fills. Since Color Config lets an administrator set these to
anything, the guarantee cannot come from the values. It has to come from the pattern:
**status is always chip + icon + label**, and Color Config gains a live contrast
readout that warns when a chosen colour drops below 3:1.

**(2) The variance column in `TimesheetCompliance.tsx` is red/green.**
`variance < 0 ? '#B91C1C' : '#166534'` — red against green is the single most common
colour-vision failure in enterprise software. Variance is **polarity**, so it takes
the diverging pair, and in practice the honest rendering is simpler still: negative
variance in `critical` with a `−` sign, positive in **neutral ink**. Meeting plan is
not news and does not need a colour.

### 6.3 Typography, density, spacing

| Element | Spec | Why |
|---|---|---|
| Table body | 13px / 20px line, system sans | Enterprise grids live at 13px; 14px costs ~2 rows per screen |
| Row height | 44px default, 36px compact toggle | 44px clears the 24px touch minimum with padding; compact is for a 27" monitor and a 400-row chase list |
| Numeric cells | `tabular-nums`, right-aligned | Columns must align vertically to be scanned |
| KPI tile value | 20–24px, **proportional** figures | `tabular-nums` at display size makes `121` look loose |
| Column header | 11px, 600, uppercase, `.05em` | Already the Prowess table convention |
| Section padding | 20px page, 12px between cards | Matches the existing `er-*` layout |
| Hero figure (dashboard only) | 48px, same sans, never a display face | A serif hero reads as decoration |

**Density is a user setting, not a designer's choice.** Comfortable / Compact, stored
in the saved view. HR scanning 400 rows and an executive glancing at 12 want different
things and neither is wrong.

### 6.4 Icons

Font Awesome solid, already in use. One icon per *state*, fixed forever, because the
icon is half the colour-blind mitigation:

```
not_configured   fa-gear              not_started  fa-circle-minus
to_be_submitted  fa-pen               to_be_approved fa-hourglass-half
approved         fa-circle-check      overdue      fa-triangle-exclamation
changed          fa-clock-rotate-left
```

Never an icon-only button in a table row without an accessible name.

---

## 7. Report 1 — Compliance

**Question:** which employees require attention?
**Grain:** one row per (employee, period). Starts from **employees**, left-joins
timesheets, so somebody who never opened one still appears. This is the whole reason
it cannot share a table with Utilisation.

### 7.1 Wireframe

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ ‹ Back to Reports    Timesheet Report    [ Compliance ][ Utilisation ]            │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Period ‹ Jul 2026 ›   Employee ▾   Department ▾   State ▾   ☐ Overdue only        │
│ ▾ My default view *              [Apply] [Reset]        42 in scope · 248 rows  ⬇ │
├──────────────────────────────────────────────────────────────────────────────────┤
│ ┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐┌──────────────┐               │
│ │   12   ││   31   ││   18   ││    7   ││    3   ││    81%    ▲6 │  ← all clickable│
│ │NOT     ││INCOM-  ││AWAITING││OVERDUE ││CHANGED ││PAYROLL READY │               │
│ │STARTED ││PLETE   ││APPROVAL││        ││AFTER   ││   ▁▂▄▅▆█     │               │
│ └────────┘└────────┘└────────┘└────────┘└────────┘└──────────────┘               │
├──────────────────────────────────────────────────────────────────────────────────┤
│ ⚠ 3 employees have no work schedule and cannot submit.  [Review configuration →]  │
├──────────────────────────────────────────────────────────────────────────────────┤
│ ☐ │ EMPLOYEE ▸pinned │ DEPT │ MANAGER │ STATE │ LOGGED│ REC/PLAN │ DUE      │ ⋯   │
│ ☐ │ Ali Hassan  E014 │ Eng  │ R Kumar │ ⛔Not │  0/22 │  0h/176h │ 6 Aug ⚠9d│ ⋯   │
│ ☐ │ Sara Malik  E027 │ Eng  │ R Kumar │ ✎ To  │ 18/22 │ 141h/176h│ 6 Aug ⚠9d│ ⋯   │
│ ☐ │ Omar Nasr   E031 │ Fin  │ L Chen  │ ⏳Awa │ 22/22 │ 176h/176h│ 6 Aug    │ ⋯   │
├──────────────────────────────────────────────────────────────────────────────────┤
│ ‹ 1 2 3 … ›   50/page          3 selected: [Send reminder] [Export selected]      │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 KPIs — six, each one an action

The rule: **a KPI card that is not clickable is decoration.** Clicking a card applies
its filter to the table. This is the Dynamics/Workday pattern and it removes an entire
filter interaction — see the number, get the list, in one click.

| KPI | Definition | Tone | Action on click |
|---|---|---|---|
| **Not started** | expected AND no header | critical | `state = not_started` |
| **Incomplete** | header exists, `recorded < planned`, not approved | warning | `state in (to_be_submitted)` + `variance < 0` |
| **Awaiting approval** | `state = to_be_approved` | neutral | that state — *this is the manager backlog* |
| **Overdue** | not approved AND `today > due_date` | critical | `only_overdue = true` |
| **Changed after approval** | `changes_since_approval > 0` | serious | that filter |
| **Payroll ready %** | approved ÷ expected, with MoM delta + 6-month sparkline | good/critical by threshold | clears filters to the full set |

**Deliberately not KPIs.** "Approved" — it is the complement of everything else and
spends a tile on good news. "Not configured" — an administrator's problem, not a
chase item; it gets the warning strip above the table and links to Configuration
Health. "Total employees" — a number nobody acts on.

### 7.2b The SLA band — act before the deadline, not after

A single **Overdue** tile is a post-mortem. Managers act on what is *about to* be late,
and a report that only names failures arrives after the moment when acting was cheap.

Above the table, a one-line SLA band, each segment a filter:

```
  Due today  3   ·   Due tomorrow  6   ·   Due in 3 days  11   ·   Overdue  7 ⚠
```

Buckets are computed from `time_submission_due_date()`, so they move with the
configured offsets and cannot disagree with the reminder text. `Due today` and
`Overdue` carry an icon as well as a colour; the middle two are neutral ink.

This is the single highest-value small change in the review. It converts Compliance
from a record of what went wrong into a queue of what to prevent.

### 7.2c Trend deltas on KPI tiles

Every **rate** tile carries a delta against the prior period and a 6-month sparkline:

```
   81%            ▲ 6 pts
   PAYROLL READY  vs Jun 2026
   ▁▂▄▅▆█
```

**Deltas belong on rates, never on counts.** "Not started: 12 ▲3" is meaningless if
headcount grew by 40 — the count rose because the company did. Rates are comparable
across a changing denominator; counts are not, and a delta on a count is a number that
will eventually be wrong in a meeting. Tiles showing counts get the sparkline only.

Delta tone follows *direction of good*, which is not always up: payroll readiness up is
good, overdue rate up is bad. Each KPI declares its own polarity; the arrow never
implies "more is better" on its own. The colour is backed by the arrow glyph and the
words "vs Jun 2026", so it survives greyscale and CVD.

### 7.2d Compare

A **Compare** control beside the period picker: `off · previous period · same period
last year`. When on, every KPI tile shows both values and the delta, and the trend
charts overlay the comparison series in categorical slot 2 with a dashed-free, direct-
labelled second line.

**Comparison applies to KPIs and charts, never to rows.** Two rows per employee — July
and June interleaved — is a table nobody can read, and the row-level version of this
question is already answered by widening the period range.

**Incomplete is the addition I would argue hardest for.** A submitted-but-short
timesheet passes every existing check and is the one that quietly breaks payroll. No
current screen surfaces it.

### 7.3 Columns

| # | Column | Format | Default | Total | Notes |
|---|---|---|---|---|---|
| 1 | ☐ select | — | ✔ | — | Only when bulk actions are permitted |
| 2 | **Employee** | text + code | ✔ **pinned** | — | Name over code, two lines. Pinned: the horizontal scroll must never orphan a row from who it is about |
| 3 | Department | text | ✔ | — | |
| 4 | Manager | text | ✔ | — | The chase often routes through the manager, not the employee |
| 5 | Period | period | hidden when range = 1 month | — | Hiding it when it is constant is not a nicety; a constant column is pure noise |
| 6 | **State** | chip | ✔ | — | icon + label + tint |
| 7 | Days logged | `18/22` | ✔ | sum | Days with entries over working days. The fastest "how far off" signal there is |
| 8 | Recorded / Planned | hours | ✔ | sum | One column, not two — the pair is the fact |
| 9 | Variance | hours ± | ✔ | sum | Diverging, **not** red/green (§6.2) |
| 10 | Submitted | date | ✔ | — | `late` chip when `submitted_at > due_date` |
| 11 | Approved | date | hidden | — | |
| 12 | Due | date + age chip | ✔ | — | `⚠ 9d` when overdue |
| 13 | Changed after approval | int chip | ✔ | sum | Blank when never approved — not `0` |
| 14 | Work schedule | text | hidden | — | On-demand for diagnosing `not_configured` |
| 15 | Approver | text | hidden | — | Who the task actually sits with, ≠ line manager |
| 16 | ⋯ actions | — | ✔ | — | |

Columns 11, 14, 15 ship hidden. **A grid whose default is every column is a grid
nobody scans.** They are one click away in Column visibility, and a saved view makes
that permanent for whoever needs them.

### 7.4 Filters

**Default filters — and why this matters more than any other default.** The report
opens on **last complete month**, all states **except Approved**, no employee or
department filter.

A report that opens on everything makes the user do the work of finding the work. A
report that opens on the exception list *is* the work. The risk is a filtered default
that looks like an empty report, so: an always-visible chip reads
`Showing 4 of 5 states · Approved hidden ✕`. Never a silent default filter.

| Filter | Control | Notes |
|---|---|---|
| Period | month range | Shared across tabs |
| Employee | multi-select, server-searched | At 50k this must not be a client-side list — see §4 |
| Department | multi-select | |
| Manager | multi-select | "Everyone reporting to me" is the most common real query |
| State | multi-select | Defaults to 4 of 5 |
| Overdue only | toggle | |
| Variance | `< 0` / `= 0` / `> 0` | Finds the short and the over-loggers |
| Quick search | one box | Name or employee code, debounced 300ms, server-side |

**Natural-language search — with its work shown.** A single box accepting
"Engineering overdue" or "missing more than two days" and translating it into filters.

The non-negotiable: **it populates the visible filter chips and the user sees the
translation before the results.** Typing "show Engineering overdue" fills
`Department = Engineering` and `Overdue only = on`, both removable. A hidden
translation that silently returns the wrong set while looking authoritative is worse
than no feature — and unlike a wrong chart, nothing on screen contradicts it.

v1 is a **deterministic grammar**, not a model: department and employee names matched
against the reference tables, a small keyword vocabulary (`overdue`, `not started`,
`missing`, `approved`, `last month`, `> N days`), and anything unparsed left in the
quick-search box rather than guessed at. That covers the common phrasings without
inheriting non-determinism. If it later becomes a model, it emits the same filter
object and still shows the chips — the same seam as §2.7.

**Advanced search** is deliberately *not* a separate mode. A second query surface that
does the same job differently is how SuccessFactors ended up with users who cannot
predict which one to open. Saved views cover the "complex query I run monthly" need
without a second grammar.

### 7.5 Sorting

**Default: most-at-risk first** — `overdue desc, state severity desc, days_past_due
desc, employee_name asc`. Not alphabetical. A worklist should open on the work; sorting
by name means the person in most trouble is wherever the alphabet put them.

State severity is a fixed ordinal: `not_started > to_be_submitted > to_be_approved >
approved > not_configured`. `not_configured` sorts last on purpose — it is not the
employee's fault and not the chaser's job.

All sorting is server-side. Multi-column via shift-click, up to three, with the order
shown in the header (`1▾ 2▴`).

### 7.6 Row actions

| Action | Shown when | Behaviour |
|---|---|---|
| **View timesheet** | always | Drill-through to the read-only month. Primary; also the row's double-click |
| **View missing days** | `days logged < days expected` | → Missing Entries, day grain, this employee, this period |
| **Send reminder** | not approved | Queues via the existing `workflow_notification_queue` |
| **Copy email** | always | The chase that actually happens is often a personal email |
| **Open in Approver Inbox** | `to_be_approved` AND caller is the approver | Hands off to the existing screen rather than rebuilding approve here |
| **View change history** | `changes_since_approval > 0` | → Time Audit Trail filtered to this header |

**Approve is deliberately absent.** Approving from a report bypasses the approval
screen's context — the calendar, the deleted-entry list from mig 743, the comment box.
An approver who approves from a list is approving a row, not a timesheet.

### 7.7 Bulk actions

Multi-select with a sticky action bar. Header checkbox selects **the page**, with an
explicit `Select all 248 matching` link — never an ambiguous "select all".

| Bulk action | Notes |
|---|---|
| **Send reminder** | The suite's highest-value action. Preview modal: recipient count, the resolved template, opt-out for anyone reminded in the last 48h |
| **Export selected** | |
| **Assign work schedule** | Only for `not_configured` rows; routes to the existing bulk-assign RPC (mig 711) |

**The reminder ladder.** `time_submission_config` has held an escalation sequence
since mig 702 — offsets −1, +3, +6, the last of which literally says "HR has been
notified" — and nothing has ever read it. The reminder feature should be that ladder,
not a second parallel notion of when to nag:

| Step | Offset | Audience | Tone |
|---|---|---|---|
| 1 | −1 day | Employee | "due tomorrow" |
| 2 | +3 days | Employee **+ line manager** | "overdue" |
| 3 | +6 days | Employee + manager **+ HR** | "escalated" |

Options on any send: **Preview** (recipient count and the resolved template) ·
**Exclude already reminded** in the last 48h, on by default · **Notify manager**
· **Escalate after N days**, defaulted from the config rather than typed in again.
Recurring sends are a `report_schedules` row (§13.5), not a separate mechanism.

Wiring reminders to the existing config is what finally makes `time_submission_config`
mean something, and guarantees the report, the reminder and the deadline agree — they
read the same row.

Reminder throttling is not a nicety. Without it the first Monday of a month produces
three reminders per person and the feature is switched off by week two.

### 7.8 Empty states — three of them, and one is a success

Most products ship one empty state and it is wrong in two of the three cases.

| Case | Message | Action |
|---|---|---|
| **No data yet** | "August 2026 has not started. Choose an earlier period." | Jump to last month |
| **Filtered to nothing** | "No employees match these filters." | `Clear filters` |
| **All clear** ✅ | "**All 248 timesheets are approved for July 2026.** Nothing needs attention." | `Export` / `View approved` |

The third is the one that matters. A chase list that finds nothing has delivered the
best possible answer, and rendering that as a grey "no rows" box tells the user the
report is broken.

### 7.9 Pagination

Keyset, 50 per page, options 25/50/100/250. Row count always visible
(`248 rows · page 1 of 5`). No "jump to page". Infinite scroll is **rejected**: it
breaks Ctrl+F, breaks print, breaks "I was on page 3", and makes a total row
impossible to place.

---

## 8. Report 2 — Utilisation

**Question:** where were recorded hours spent?
**Grain:** one row per entry, activities nested. Reads the **parent** entry's
`hours_minutes`; the activity rows are display detail. Summing both counts every
post-727 project entry twice.

### 8.1 KPIs

| KPI | Definition | Note |
|---|---|---|
| **Billable hours** | `project_type = billable` | Needs §3 |
| **Billable utilisation** | billable ÷ planned | The number Finance opens this for |
| **Recording rate** | recorded ÷ planned | Today's mislabelled "Utilisation %" |
| Internal | `project_type = internal` | |
| Absence | `category = absence` | |
| Contributors | distinct employees | |

Each clickable, each filtering the table.

### 8.1b Planned has no project dimension — SHIPPED (mig 752 + UI)

`timesheet_headers.planned_minutes` is **one figure per employee per month**. There is
no planned-by-project value anywhere in the schema, and there cannot be one until
`projects.budget_hours` (§3) exists.

That matters because the two halves of the ratio are drawn from different sets:

| | Source CTE | Narrowed by project / time type / category? |
|---|---|---|
| `recorded_minutes` | `ent` — the entry set | **Yes** |
| `planned_minutes` | `hdr` — the header set | **No** |

So with a single project selected, the tile divided one project's hours by *every
in-scope employee's whole-month capacity* — reported as 29% in a case where the same
hours were 35% of the capacity of the five people who actually worked on it, and
neither figure was utilisation of anything.

**Decision: suppress, do not approximate.** When a project, time type or category
filter is applied, **Planned** and **Recording rate** both render as `—` with a caption
naming the reason. The considered alternative — narrowing the denominator to the
employees present in `ent`, giving a "share of capacity" — was rejected: it is a better
approximation of a question nobody asked. A team can spend 35% of its month on a
project that is 200% over budget, and the number that answers the real question is
`hours ÷ projects.budget_hours`, which belongs in §9 next to the budget.

This follows the rule §9 already sets for the project health strip: *no percentage at
all when the denominator is null, rather than a fake denominator.*

**Recorded is not suppressed.** Under a project filter it is exactly right, and it is
the most useful figure on the screen.

### 8.2 Charts — two, both from server aggregates

Charts here read a `breakdowns` block returned by the RPC over the **whole filtered
set**. Drawing from `rows` would describe the current 50 rows while looking like it
describes the report — which is why the shipped screen currently has no charts at all.

**Chart 1 — Hours by project.** Horizontal bar, top 10 + "Other", sorted descending.

- Horizontal because project names are long; vertical forces rotated labels, which
  fail both readability and screen readers.
- **One series, one hue** (slot 1 `#2a78d6`) for every bar. Not a value ramp — colouring
  bars darker-where-bigger re-encodes what bar length already shows and burns the only
  free channel.
- Direct-label the top 3 and the "Other" bar; the axis and tooltip carry the rest.
- Never a pie. Ten projects in a donut is unreadable at any size.

**Chart 2 — Billable / Internal / Overhead / Absence by week.** Stacked horizontal
bar, four segments, categorical slots 1–4, 2px surface gap between segments.

Shipped today as Attendance / Absence (two segments); the four-way split needs §3.

**Buckets are clipped to the reported period (mig 752).** `date_trunc('week', …)`
returns the Monday of the ISO week, so July 2026 produced a first bucket labelled
`w/c 29-Jun` holding 1–5 Jul and a last one labelled `w/c 27-Jul` holding 27–31 Jul.
Both read as full weeks, so every month appeared to open and close with a collapse in
recording. The hours were always correct — `hdr` bounds them — and only the label lied.
Buckets now carry `week_start`, `week_end` and `partial`, are labelled as day ranges
(`1–5 Jul`), and part-weeks are greyed.

**Empty weeks are zero bars, not gaps.** `GROUP BY` only emits weeks that have rows, so
a week nobody recorded in vanished and its neighbours closed up. A missing bar reads as
*no data collected*; a zero bar reads as *nothing was recorded* — opposite findings, and
the second is the actionable one. `bd_week` is now a generated spine of every week in
the range, LEFT JOINed to what was recorded. Same argument as the vanishing zero slice
in §6.

Over a 12-month range this returns ~53 buckets. The chart should switch to months
beyond a threshold; not yet built.

- Four series is the point where direct labels become mandatory — yellow now sits
  beside orange.
- Segments below ~6% get no in-bar label; it goes to the tooltip and the table view,
  never clipped by `overflow: hidden`.
- **Not a dual-axis chart** with headcount overlaid. Two measures of different scale
  is two charts.

**Chart 3 — Top activities.** Horizontal bar, top 8 + "Other", share of recorded
hours. Answers "what is the time actually going on" in a way project and time type
cannot: `Development 51% · Meetings 18% · Support 11% · Testing 8%`.

⚠️ **This chart has a data problem that must be solved before it ships.** Activities are
**free text** (mig 717): `employee_activity_history` is unique on the activity name
*exactly*, so "Testing" and "testing" are already two rows, and "Dev", "Development"
and "Coding" are three. Charted naively, the top-8 will be a list of spelling variants
and the percentages will be wrong in a way that looks precise.

Three options, in order of preference:

| Option | Effect | Cost |
|---|---|---|
| **(a) Normalise on read** — group by `lower(btrim(activity_name))` | Fixes case and whitespace, which is most of it. Does not fix synonyms | Free. Do this regardless |
| **(b) Optional activity catalogue** — an admin list that autocomplete prefers, free text still allowed | Fixes synonyms going forward, leaves history messy | A table, an admin screen, and a deliberate decision not to force it |
| **(c) Admin merge tool** — map variants onto a canonical name, retrospectively | Fixes history too | The most work; only worth it once (b) exists |

Ship (a) with the chart and label it honestly. Do not present a synonym-riddled
distribution as a finding — the first person who reads "Meetings 18%" will act on it.

### 8.3 Grouping

`None` (default) / Project / Employee / Department / Time type / Week.

Group headers carry subtotals; a grand total row is pinned to the bottom and does not
scroll. Collapse-all and expand-all in the toolbar; group state lives in the saved view.

### 8.4 Columns

Date · Employee (pinned) · Dept · Project · **Type** (billable/internal/overhead chip)
· Time type · Category · Hours · Activities (count, expandable) · Status ·
Notes *(hidden)* · Manager *(hidden)* · Week number *(hidden)*.

Expanding a row lists its activities with per-activity hours — indented, no chart, no
second header row.

### 8.5 Row actions

View timesheet (that employee, that month, scrolled to the date) · View project
(→ Project Summary) · Copy activity text.

No bulk actions, no multi-select — there is no action to take on an entry from here.

---

## 9. Project Summary — a preset, not a screen

`ReportDefinition` = Utilisation, with `groupBy: 'project'`, a different default column
set, a chart header, and its own catalog row. **Zero new screens.**

Header, above the grid:

| Tile | |
|---|---|
| Total hours · Billable % · Contributors · Activities · Months active | |

Charts: attendance mix (stacked horizontal, ≤6 segments) · 12-month trend (**single
series line — no legend box, the title names it**, with a 2px stroke and ≥8px markers)
· top contributors (horizontal bar, one hue, top contributor in emphasis and the rest
in de-emphasis gray).

**Project Health strip**, one row per project above the detail:

| Field | Source | Note |
|---|---|---|
| Hours | recorded | |
| Budget | `projects.budget_hours` (mig 747) | Blank, not zero, when unset |
| Consumed % | hours ÷ budget | Meter against the budget track; **no percentage at all when budget is null**, rather than a fake denominator |
| Billable % | `project_type = billable` share | |
| Contributors | distinct employees who logged time | |
| Trend | 6-month sparkline | |
| Status | derived: `On track` / `Near budget ≥85%` / `Over budget` / `No budget set` | icon + label + colour |

`No budget set` is a real status, shown plainly. A project health view that quietly
omits un-budgeted projects is how half the portfolio disappears from a review.

### 9.1 What a missing budget does, surface by surface

`budget_hours` is nullable and most projects will not have one for a while, so
"no budget" is the normal case rather than an edge case. It has to read the same
way everywhere:

| Surface | With a budget | With none |
|---|---|---|
| Hours | the figure | **the figure** — always shown; it needs no denominator |
| Budget | the figure | blank, **never `0`** |
| Consumed % | `hours ÷ budget`, with a meter | **nothing at all** — no meter, no `0%`, no `—%` |
| Status | On track / Near budget / Over budget | **`No budget set`**, its own chip |
| Sort by Consumed % | ranks normally | sorts to the **end**, never as `0%` |
| Export | the value | **empty cell**, never `0` |
| Portfolio roll-up | included | excluded, and the roll-up **says so**: "budget shown for 12 of 19 projects" |

`0%` is the failure mode to avoid: it ranks an un-budgeted project as the
healthiest thing in the portfolio, which is the exact inversion of the truth. A
blank cannot be misread that way, and an empty meter track invites the reader to
fill in the budget rather than trust the bar.

Billable utilisation is unaffected — its denominator is `planned_minutes` from
the timesheet headers, not `budget_hours`.

Sparkline in each project row showing 6-month hours. A sparkline is a stat-tile
component, not a chart: no axes, no labels, no tooltip — the row's numbers carry the
values.

**"Employees assigned" is reported as "Contributors" and defined as anyone who logged
time.** There is no project-assignment table. Contributors is arguably the better
measure anyway — it is what happened, not what somebody planned in a spreadsheet last
quarter — but the label must not claim more than it knows.

---

## 10. Missing Entries — a drill-down

Reached from a Compliance row, or directly with a period + department filter for
Payroll's own sweep.

**Grain: one row per (employee, working day with no entry).** This is the finest grain
in the suite and the one Payroll acts on.

| Column | Notes |
|---|---|
| Employee (pinned) · Date · Weekday · Planned hours · Reason | |
| **Reason** | `No entry` · `Under-logged (3h of 8h)` · `Holiday not applied` · `Leave pending approval` |

The Reason column is what makes this a report rather than a list of dates. "Ali has 12
missing days" is not actionable; "9 no-entry, 2 under-logged, 1 holiday not applied" is
three different fixes and two of them are not Ali's.

**Actions:** Send reminder (specific dates in the message) · Export for payroll ·
Bulk reminder across selected employees.
**KPIs:** Employees affected · Total missing days · Total unaccounted hours ·
Payroll-blocking count (missing days in an unapproved month).

---

## 10b. Report 4 — Workforce Capacity

**Question:** what is our capacity actually going on, and how much of it is productive?
**Grain:** one row per (department, period). Roll up, not row-level — this is a
leadership report and an employee-grain version is Utilisation.

| Column | Source | Note |
|---|---|---|
| Department | employment | |
| Headcount | distinct expected employees | The denominator everything else is read against |
| Planned hours | `sum(timesheet_headers.planned_minutes)` | Capacity |
| Recorded hours | `sum(recorded_minutes)` | |
| Leave | `time_types.category = absence`, leave types | |
| Holiday | system-generated holiday rows | |
| Training | attendance type `TRN` | Called out separately — it is capacity spent on purpose |
| Billable | `project_type = billable` | mig 747 |
| Internal | `project_type = internal` | mig 747 |
| Overhead | `project_type = overhead` + untagged attendance | |
| **Capacity %** | (planned − leave − holiday) ÷ planned | What was *available* |
| **Productive %** | billable ÷ available | What was *used well* |

Two percentages, not one, because they fail for different reasons and demand different
responses: low capacity is an absence or staffing problem, low productivity is a
pipeline or allocation problem. A single blended "utilisation" number hides which.

Chart: stacked horizontal bar per department — billable · internal · overhead ·
training · leave · holiday. Six segments is the part-to-whole ceiling, and this is
exactly six.

This is the report leadership opens most and the one the original design missed
entirely. It is also almost free: every input already exists except the `project_type`
split, which mig 747 adds.

## 11. Executive Dashboard

**Fixed layout. No grid, no saved views, no column preferences.** An executive
dashboard that can be reconfigured is a report; the value here is that it looks the
same every month so a change in the *data* is what stands out.

```
┌───────────────────────────────────────────────────────────────────────────┐
│ Timesheet Health — July 2026                    As at 02:00 today  [PDF]  │
├───────────────────────────────────────────────────────────────────────────┤
│      87%          ┌──────┐┌──────┐┌──────┐┌──────┐                        │
│  COMPLIANCE       │ 94%  ││ 71%  ││ 1.8d ││  12  │                        │
│    ▲ 6 pts        │PAYROLL││BILL- ││APPR- ││AT    │                        │
│  ▁▂▄▅▆▇█          │ READY ││ABLE  ││OVAL  ││RISK  │                        │
│                   └──────┘└──────┘└──────┘└──────┘                        │
├────────────────────────────────┬──────────────────────────────────────────┤
│ Compliance, 12 months          │ By department (worst first)              │
│  (single line, emphasis)       │  Finance   ████████████░░░  62% ⚠        │
│                                │  Eng       ██████████████░  91%          │
├────────────────────────────────┼──────────────────────────────────────────┤
│ Submission curve               │ Top risks                                │
│  cumulative % vs days-to-due   │  • Finance 8 not started (3 mo running)  │
│  ── this month ── last month   │  • 4 sheets changed after approval       │
└────────────────────────────────┴──────────────────────────────────────────┘
```

**The Key Insights band sits above everything**, between the title and the hero
figure — three to five one-line cards from the rule engine (§2.7), each clickable
through to the rows that produced it:

```
  ✓ Payroll is on track — 94% ready with 3 days to close.
  ⚠ Finance compliance fell 12 points to 62%, third month declining.
  ✓ Engineering improved 9 points.
  ⚠ Four approved timesheets were changed after approval.
```

Executives read bullets before charts. Putting the charts first and the interpretation
nowhere is how a dashboard becomes a monthly screenshot nobody discusses.

**The hero figure** is compliance %, 48px, same sans as everything else, proportional
figures. One number leads; the tiles support it.

**The submission curve is the chart I would fight for.** Cumulative % submitted
plotted against days relative to the deadline, this month against last. It answers a
question no other view can: *are people submitting steadily, or does everything arrive
in a panic on the last day?* A flat line that spikes at day 0 is a process problem, and
no HCM product I know of shows it. Two series, categorical slots 1 and 2, both direct-
labelled at their endpoints.

**Department comparison** is a horizontal bar sorted worst-first, one hue, with the
bottom three in emphasis and the rest in de-emphasis gray. Sorted-worst-first because
an executive scanning top-left-first should meet the problem, not the best performer.

**Optional heatmap** (department × month, compliance %): sequential blue ramp
`#cde2fb`→`#0d366b`, always with a scale legend, capped at ~7 bins — past that,
adjacent classes blur and it should be a table.

**Executives do not log in.** The dashboard's real delivery is a scheduled PDF emailed
on the 5th of each month. Build the screen, but treat the email as the product; a
dashboard only reachable by navigating to it gets opened twice a year.

---

## 12. Chart specification summary

| Chart | Form | Colour job | Series | Where |
|---|---|---|---|---|
| Hours by project | horizontal bar | 1 hue, slot 1 | 1 | Utilisation |
| Type by week | stacked horizontal bar | categorical 1–4 | 4 | Utilisation |
| Attendance mix | stacked horizontal bar | categorical | ≤6 | Project Summary |
| Project trend | line | 1 hue, no legend | 1 | Project Summary |
| Top contributors | horizontal bar + emphasis | 1 hue + gray | 1 | Project Summary |
| Row sparkline | sparkline | 1 hue | 1 | Project Summary |
| Compliance trend | line + emphasis | 1 hue | 1 | Dashboard |
| Department comparison | horizontal bar, worst-first | 1 hue + emphasis | 1 | Dashboard |
| Submission curve | line | categorical 1–2 | 2 | Dashboard |
| Dept × month heatmap | heatmap | sequential blue | — | Dashboard |

**Forbidden throughout, and worth naming so a future contributor does not reintroduce
them:** dual-axis plots · pies or donuts for anything but a ≤6-segment
part-to-whole glance · a value ramp on nominal categories · recolour-on-filter ·
generated 9th+ hues · a number on every data point · dashed gridlines · borders drawn
around marks to separate them (use a 2px surface gap) · a tooltip as the only way to
read a value · a fixed chart height that clips the x-axis band.

Every chart ships with a **table view toggle**. It is the accessibility relief for the
three palette slots below 3:1, and it is also how someone gets the numbers into an
email.

---

## 13. Export

### 13.1 Excel (.xlsx) — the primary format

`xlsx@0.18.5` is already a dependency and is already dynamically imported so its
141 kB gzip only downloads on click.

Every report exports **three sheets**, not one:

| Sheet | Contents |
|---|---|
| **Data** | Every filtered row, all columns including hidden ones. Typed cells — hours as decimal numbers, dates as dates. Never pre-formatted strings |
| **Summary** | The KPI values and subtotals |
| **Report info** | Report name, who ran it, when, **every filter applied in words**, scope statement, row count |

The third sheet is the one people skip and the one that prevents the worst outcome in
enterprise reporting: a spreadsheet forwarded to a director with no record of what it
was filtered to. "248 rows, July 2026, Engineering + Finance, states excluding
Approved, scoped to 42 employees you can see" belongs *in the file*.

**Hours export as decimal** (7.5), not `7h 30m`. A person reads h/m; Excel sums
decimals. The h/m string goes in a second column for readers.

**The export runs the whole filtered set, not the page.** Today it caps at 500 rows and
warns; at 50k that cap must move server-side into a generator Edge Function
(`bulk-export-generator` is the working precedent) that streams and emails a link.

### 13.2 CSV

One flat sheet, no summary, UTF-8 with BOM so Excel does not mangle non-ASCII names.
Offered because systems consume CSV; xlsx is offered because people do.

### 13.3 PDF — two different documents

The brief's PDF section — employee information, weekly summaries, daily entries,
signature block — describes the **existing per-employee timesheet PDF**
(`ExportPDF/`, shipped `dc29811`). That is not a report PDF, and conflating them
would mean rewriting good work.

**(a) Employee Timesheet PDF — exists.** Portrait A4, four pages, per person. Keep.
Add only: approval history from `workflow_action_log`, and the optional signature
block the brief asks for.

**(b) Report PDF — new.** Landscape A4 or A3, per report, for a chase meeting.

```
┌─────────────────────────────────────────────────────────────────────┐
│ [logo]  TIMESHEET COMPLIANCE                      July 2026         │
│         Prowess HR                    Generated 17 Aug 2026, 14:32  │
├─────────────────────────────────────────────────────────────────────┤
│ Filters: Engineering, Finance · States excl. Approved · 42 in scope │
├─────────────────────────────────────────────────────────────────────┤
│  12 Not started   31 Incomplete   18 Awaiting   7 Overdue   81% RDY │
├─────────────────────────────────────────────────────────────────────┤
│  the table, repeating header on every page                          │
├─────────────────────────────────────────────────────────────────────┤
│ Legend: ⛔Not started ✎To be submitted ⏳Awaiting ✔Approved          │
│ Prepared by V Ananth · Confidential · Page 2 of 6                   │
└─────────────────────────────────────────────────────────────────────┘
```

- **Landscape** for Compliance and Utilisation (12+ columns). **Portrait** for the
  Executive Dashboard (one page, chart-led) and the employee timesheet.
- **Automatic column optimisation:** drop hidden columns, then optional ones by a
  declared priority in `ReportColumn`, until the set fits. Print a footnote naming
  what was dropped — a silently truncated report is worse than a dense one.
- **Repeating header row** on every page, and a repeating filter line. A page 4 handed
  round a meeting with no header is unreadable.
- **Colour-blind-safe printing:** status is icon + label; charts switch to the texture
  fill (45° / 135°) rather than relying on hue; the tints drop out and the icons carry
  the meaning. Test by printing greyscale.
- Page numbers as `Page n of m`, generation timestamp, and a confidentiality line.

### 13.4 Print (browser)

A real `@media print` stylesheet — none exists in Prowess today. Hide chrome, nav,
filters and pagination; force the table to full width; `break-inside: avoid` on rows;
repeat `<thead>` via `display: table-header-group`; expand every collapsed group; print
the filter summary as a header. Print is not export; it is the fallback that always
works and it currently produces a screenshot of a scroll container.

### 13.4b Watermarking and classification

Optional per-export, remembered per saved view: a diagonal **CONFIDENTIAL** watermark
on every PDF page, at ~8% opacity behind the content, plus a classification line in the
footer. Frequently a procurement requirement, and trivial once the report PDF exists.

Also stamped in the PDF footer, always, not optionally: **who generated it and when.**
A compliance report circulating with no attribution is the artifact that causes the
incident.

### 13.5 Scheduled reports

```sql
report_schedules (
  report_code, view_id, owner_id, recipients[], format,
  trigger_kind text CHECK (trigger_kind IN ('cron','business_event')),
  cron_expression text,
  business_event  text CHECK (business_event IN
    ('first_working_day','last_working_day','n_days_before_due','on_due_date',
     'n_days_after_due','payroll_close')),
  offset_days integer
)
```

Run by pg_cron into the existing `workflow_notification_queue` and
`send-notification-email`.

**Business events, not raw cron.** HR does not think "0 9 1 * *"; it thinks "the last
working day" and "three days before the deadline". Exposing cron to an HR
administrator guarantees either a wrong schedule or a ticket to IT.

The events are computable from what Prowess already holds: `first_working_day` and
`last_working_day` come from the work schedule and holiday calendar (so they skip a
Friday-Saturday weekend and a public holiday correctly), and the due-date events come
from `time_submission_due_date()`. **`payroll_close` is the exception — there is no
payroll calendar in Prowess.** Either add a simple `payroll_periods` table or leave the
option out of the picker; offering an event that silently never fires is worse than
not offering it.

Advanced users keep a raw cron option behind a "custom schedule" disclosure.

**A scheduled report runs under its owner's permissions, and the email says so.** The
alternative — running as a service account — is a data-leak generator.

### 13.6 Report access audit

Distinct from the timesheet entry audit (mig 743) — that records what changed in the
data; this records **who saw the data**.

```sql
report_access_log (id, report_code, view_id, actor_id, action, row_count,
                   filters jsonb, recipients[], created_at)
-- action: 'run' | 'export' | 'print' | 'share' | 'schedule' | 'scheduled_send'
```

Captures who exported, who shared a view, who created a schedule, and what each
scheduled send delivered to whom. This is asked for in essentially every enterprise
security review, and it costs one insert on an action people take a few times a day.

`run` is optional and off by default — logging every page view produces volume that
buries the events anyone cares about. Exports and shares are the ones that leave the
building.

Retention is a policy decision, not a default: see Appendix A.

---

## 14. Mobile

Reports are desktop-first, and pretending otherwise produces a grid nobody can use on
either device. But three things must work on a phone, because they are what people do
between meetings:

| Breakpoint | Behaviour |
|---|---|
| ≥1280px | Full grid, all features |
| 768–1279px | Grid, horizontal scroll with the pinned column, charts stack |
| <768px | **Card list, not a table.** Each row becomes a card: employee + state chip + the two numbers that matter + one primary action. Filters collapse into a bottom sheet. KPI tiles scroll horizontally |

At <768px, Compliance keeps `Send reminder` and `View timesheet`; everything else moves
behind an overflow. Utilisation is **read-only** on a phone — its value is analysis,
and nobody analyses 4,000 entry rows on a phone. The Executive Dashboard is the one
surface that should be genuinely good on mobile, because that is where a director will
actually read it.

**Swipe left / right steps the period** — the mobile equivalent of the `[` and `]`
shortcuts, and the most repeated action in the suite. Confined to the **card list
below 768px**, where there is no horizontal table scroll to compete with; on the
tablet grid the gesture would fight the pinned-column scroll and is not bound. The
period header animates in the direction of travel so the gesture is legible, and it
is disabled under `prefers-reduced-motion`.

Touch targets ≥44px. Horizontal scroll on a table gets an explicit shadow affordance —
a table that scrolls invisibly reads as a table with missing columns.

---

## 15. Accessibility

Target: **WCAG 2.2 AA**.

| Area | Requirement |
|---|---|
| Colour | Never the sole carrier of meaning. Every state = icon + label + tint. Palette validated by script, not by eye (§6.1) |
| Contrast | Text ≥4.5:1, marks and UI ≥3:1. Measured values in §6.2 |
| Table semantics | Real `<table>` with `<th scope="col">`, `aria-sort` on the sorted header, `<caption>` naming the report and its filters |
| Charts | `role="img"` with an `aria-label` summarising the finding, plus a **table view toggle** — never a tooltip as the only route to a value |
| Focus | Visible 2px focus ring, never `outline: none`. Logical order: filters → KPIs → table → pagination |
| Live regions | `aria-live="polite"` announcing "248 rows" after a filter change; without it a screen-reader user filters and hears nothing |
| Motion | `prefers-reduced-motion` disables chart transitions and skeleton shimmer |
| Zoom | Usable at 200% — no fixed-width containers |
| Forced colors | `forced-colors` media query; charts fall back to texture |

### Keyboard

| Key | Action |
|---|---|
| `/` | Focus quick search |
| `f` | Open filters |
| `↑ ↓` | Move row focus |
| `Enter` | Primary row action (view timesheet) |
| `Space` | Toggle row selection |
| `→ ←` | Expand / collapse group or activity rows |
| `⌘/Ctrl + ⇧ + E` | Export |
| `⌘/Ctrl + ⇧ + P` | Print |
| `[` `]` | Previous / next period |
| `?` | Shortcut help |
| `Esc` | Close panel, clear selection |

`[` and `]` for period stepping is the one to build first. Month-stepping is the most
repeated action in the entire suite and it currently takes three clicks through a date
picker.

### Loading, error and success states

| State | Treatment |
|---|---|
| First load | **Skeleton** matching the real layout — KPI tiles then 8 shimmer rows. Not a spinner: a spinner tells you nothing about what is coming |
| Filter re-run | Keep the old rows, dim to 60%, progress bar under the toolbar. Never blank the table — the user loses their place |
| Slow (>3s) | "Still running — large periods take a moment." Silence past 3 seconds reads as broken |
| Error | Inline banner with the actual message, a `Retry`, and the filter set preserved |
| Permission denied | "You do not have permission to open timesheet reports" + which permission to ask for. Never a blank screen |
| Partial scope | The scope badge, always, when scope ≠ all |
| Export success | Toast with the filename; the download is not self-evident |
| Reminder sent | Toast `12 reminders queued`, and the affected rows show a `Reminded today` marker |

---

## 16. Enterprise patterns adopted, and from where

| Pattern | Source | Why it earns its place here |
|---|---|---|
| One grid engine, many definitions | **Workday** | A user who learns one report can drive all of them. The bespoke-screen alternative is where SuccessFactors' inconsistency complaints live |
| Saved views, shared as *definitions* not data | **Workday, Oracle Fusion** | Lets power users self-serve without a new report request, and recipients see only their own scope |
| Clickable KPI tiles that filter | **Microsoft Dynamics** | Collapses "read a number, reproduce it as a filter" into one click |
| Drill-through that carries filters forward, with a breadcrumb back | **Workday** | The one-way drill is the most common reason enterprise reporting feels slow |
| Exception-first default filters, stated visibly | **UKG** | The report opens on the work. The visible chip is what stops it feeling broken |
| Reminder throttling and preview before bulk send | **UKG, ADP** | Un-throttled reminders get the feature switched off in week two |
| Report-info sheet in every export | **Oracle Fusion** | A forwarded spreadsheet with no record of its filters is the classic reporting incident |
| Landscape report PDF with repeating headers and a legend | **SAP SuccessFactors** | SF's PDF output is genuinely good and worth matching |
| Nightly rollup for executive aggregates, with `as of` on the page | **Workday** | Live aggregates at this scale are not possible; hiding staleness is worse than showing it |
| Density toggle stored per view | **Dynamics** | HR scanning 400 rows and an executive glancing at 12 are both right |

**Where I would deliberately diverge from all of them:**

1. **No separate "advanced search" mode.** SF and Oracle both ship two query surfaces
   and users cannot predict which to open. Saved views cover the recurring-complex-query
   need with one grammar.
2. **No approve-from-report.** Several products allow it. It bypasses the approval
   screen's context — the calendar, the deleted-entry list, the comment box — and turns
   approval into a row operation.
3. **The submission curve** (§11). None of the five show it, and it is the only chart
   that turns "we hit 87%" into "we hit 87% in a panic on the last day".
4. **A success empty state.** Every one of them renders "no rows" when a compliance
   report finds nothing wrong. That is the best possible answer and should read like it.

---

## 17. Phasing

| Phase | Contents | Unblocks |
|---|---|---|
| **0. Permissions** ✅ | Mig 745 — one permission per report, umbrella retired, RPCs repointed, adaptive catalog row | Done. Free only while ungranted |
| **A. Foundations** | Rework `time_report_scope()` to a predicate; two-phase compliance query; the four indexes; keyset pagination | Everything. Do not build on the current ceiling |
| **B. Grid platform** | `ReportGrid` + `ReportDefinition`, saved views table + RLS, column prefs, sticky/pinned, subtotals, density, skeletons, keyboard, print stylesheet | All reports |
| **C. Retrofit** | Compliance and Utilisation onto the grid; palette replacement; the red/green variance fix | Parity, plus accessibility |
| **D. Schema** | Mig 745 — `project_type`, `projects.manager_id`; `timesheet.view_project` permission; rename Utilisation % → Recording rate | Project Summary, PM persona, billable KPIs |
| **E. Fan-out** | Project Summary preset · Missing Entries drill-down · Time Audit Trail · Configuration Health | The suite |
| **E2. Insights** | Rule engine + `InsightCard` contract + the insight band on Compliance and the dashboard. Deltas, Compare, SLA band | Investigate — the stage the first draft skipped |
| **F. Push** | Bulk reminders on the existing ladder · business-event schedules · Executive Dashboard on the nightly rollup · report PDF + watermark · report access log | Executives and Payroll |
| **G. Later** | Workforce Capacity · activity catalogue · natural-language search · `LlmProducer` behind the §2.7 seam · user-composed dashboards *if demand proves itself* | — |

Phase A is not optional and should not be sequenced after the visible work. The scope
array and the 600k-row skeleton are ceilings, not slow paths — they do not degrade
gracefully, they stop.

---

## Appendix A — open questions

1. **Project Manager security (§5)** — option (a) redacted columns is recommended, not
   decided. It needs a real opinion from whoever owns data governance.
2. **Does "Contributors" satisfy the PMO**, or is a real project-assignment table
   needed? Affects whether Project Summary can report on *expected* versus *actual*
   contributors.
3. **Reminder authorship** — do reminders come from Prowess, from the line manager, or
   from HR? Changes the template, the reply-to, and how hard people work to avoid them.
4. **Executive dashboard freshness** — is nightly acceptable to leadership, or is
   month-end-close a case for an on-demand refresh button?
5. **Retention** — how long do report schedules keep generated files, and where? The
   report access log (§13.6) needs the same answer, and it is a policy question, not a
   default.
6. **Activity normalisation (§8.2)** — is an activity catalogue acceptable, or is free
   text a deliberate product position? Top Activities is not shippable as a percentage
   until this is answered.
7. **Payroll calendar** — `payroll_close` as a schedule trigger needs a
   `payroll_periods` table that does not exist. Add it, or drop the option?
8. **Insight thresholds** — the rule catalogue in §2.7 hardcodes 5 points, 40%, 80%,
   3 periods. Should these be configurable per tenant, or is a fixed, explainable set
   better than a knob nobody tunes?

## Appendix B — corrections to shipped code this design implies

| File | Issue | Fix |
|---|---|---|
| `ExpenseReport.tsx` | `BAR_PALETTE` fails 3 of 6 palette checks; `#8E24AA`↔`#3949AB` are ΔE 1.6 under protanopia | Replace with the validated set (§6.1) |
| `TimesheetCompliance.tsx` | Variance rendered red vs green | Diverging pair, or critical + neutral (§6.2) |
| Mig 744 `time_report_scope()` | Returns `uuid[]`; 50k-element array per call | Predicate function (§4.1) |
| Mig 744 compliance RPC | Correlated subqueries before `LIMIT` | Two-phase (§4.2) |
| `TimesheetUtilisation.tsx` | KPI labelled "Utilisation" is recording rate | Rename (§3) |
| Colour Config admin screen | Lets an administrator pick sub-3:1 status colours with no warning | Live contrast readout |
| Everywhere | No `@media print` rule exists | §13.4 |
