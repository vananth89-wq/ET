# Project Manager persona — design

**Status:** rev 3 — all three pieces built and sandbox-tested, **nothing pushed**. Migrations `20260826780`, `781`, `782`.
**Date:** 24 Aug 2026
**Supersedes:** the interim `timesheet.view_project` approach (mig 767 / 770 / 771), which stays in place until this is proven on Dev.

---

## 1. The requirement

As stated:

> Someone acting as project manager should see **only the data related to their project**, in both the timesheet and the reports. Project membership must be **dynamic** and driven by the `project_members` table — if a user is added to it, they are automatically in scope.

Restated against the example we've been using:

> Hari is named **Reporting Manager** on project AMPTJ. He should see the people on AMPTJ and their AMPTJ hours — **and nothing else**. No one types Hari's name anywhere except on the project.

Two words in that sentence do all the work:

- **"the people on AMPTJ"** — so the grant must resolve from project membership, live, not from a list someone maintains.
- **"and nothing else"** — so it must be limited **per project**, not per person. Meera's hours on a different project are not Hari's business.

Today's permission engine can express the first. It cannot express the second, and that is the actual gap.

---

## 2. What exists today (verified against the repo)

| Thing | Where | Notes |
|---|---|---|
| `roles` table, `role_type IN ('system','custom','protected')` | `20260419003` | `Grant access to` dropdown reads this table |
| `sync_system_roles(p_role_code text)` | `20260429061` | Auto-grants `ess`, `manager`, `dept_head`. `manager` = has ≥1 active direct report |
| Sync triggers on `employees`, `department_heads`, `profiles` | `20260425010` | Membership self-heals on data change |
| **Sync** button, shown only when `role_type === 'system'` | `RoleAssignments.tsx:1011` | Already wired to the RPC |
| **Create Role** button — creates `role_type: 'custom'` only | `RoleAssignments.tsx:1042` | Manual membership |
| `target_groups.scope_type` CHECK allow-list | last widened by `20260605500` | `self, everyone, direct_l1, direct_l2, hierarchy, same_department, same_country, custom` |
| **Target Groups** screen — creates `scope_type: 'custom'` only | `TargetGroups.tsx:913` | Fixed employee lists |
| `user_can(module, action, owner)` Path D | `20260605500` | One `OR` branch per scope_type |
| `get_target_population(module, action)` | `20260605500` | Returns `{mode: all\|scoped\|none, ...}` — **flat employee id set, no period argument** |
| `projects.manager_id` → `employees(id)`, `projects.active` | `20260819754`, `20260419001` | |
| `project_members(project_id, employee_id, effective_from, effective_to, …)` + gist no-overlap | `20260825773` | Effective-dated, stints allowed |
| `timesheet_report_project_summary` | created `20260820766`, patched `770` | |
| `timesheet_report_utilisation`, `timesheet_report_compliance` | created `20260817744`, patched `746` / `752` / `771` | All three gated by `time_report_scope_mode()` / `time_report_scope_ids()` |

**The precedent to copy:** migration `20260605500` added the `hierarchy` scope type end to end — widen the CHECK, seed the group, add a `user_can` branch, add a `get_target_population` branch, leave the cache alone because it resolves live. Piece 2 below is the same migration with a different `WHERE`.

---

## 3. The three pieces

### Piece 1 — `Project Manager` as a **system** role

**Why not a custom role.** The Create Role button makes a `custom` role, and custom roles have hand-maintained membership. That reintroduces exactly the maintenance we are trying to remove: someone adds Hari, and when Hari comes off AMPTJ nobody remembers to take him out. The role would slowly become a stale list of names.

**Shape.** A new row in `roles`:

```
code        project_manager
name        Project Manager
role_type   system
is_system   true
editable    false
sort_order  8
```

**Membership rule** — added as a fourth branch inside `sync_system_roles()`, alongside `ess` / `manager` / `dept_head`:

> eligible ⇔ `EXISTS (SELECT 1 FROM projects p WHERE p.manager_id = <this employee> AND p.active)`

Identical in structure to the existing `manager` branch, which tests "has ≥1 active direct report". Same `assignment_source = 'system'`, same `ON CONFLICT DO NOTHING` insert, same `DELETE … WHERE assignment_source = 'system'` on the way out — so an admin's *manual* grant of the role is never clobbered by the sync.

**Self-healing.** A new trigger on `projects`, `AFTER INSERT OR UPDATE OF manager_id, active`, calling `sync_system_roles('project_manager')` — mirroring `after_dept_head_role_sync` on `department_heads`. Put Hari's name on a project and he is in the role that moment; remove it and he is out.

**Frontend, mostly free — with one trap.** The role appears in **Grant access to** because that dropdown reads `roles`, and the **Sync** button appears because it renders for any `role_type === 'system'`. Both for nothing.

But `PermissionMatrix.getRoleCategory(code, name)` buckets a role by **substring match**, and `project_manager` contains `manager` — so it lands in the `mss` bucket and is offered `Direct L1 / Direct L2 / All levels / Same dept / Everyone`, with no `Select target group →` escape hatch (that exists only in the `hr` bucket). **A `Project Members` chip would therefore be unreachable for the one role that needs it.** Fixed alongside Piece 2, not here — see §5.6.

> **The role by itself grants nothing.** It is only the *who*. The *what* and the *whose* still come from a permission set assigned to it — which is Piece 2.

---

### Piece 2 — `Project Members` as a new **target group scope type**

**Why it cannot be done in the UI.** The Target Groups screen only ever writes `scope_type: 'custom'`, i.e. a fixed list of employees. The relational chips are a database CHECK allow-list resolved live in `user_can`. Adding one is a migration; there is no UI path, by design.

**Shape**, following `20260605500` exactly:

1. Widen the `target_groups_scope_type_check` allow-list with `'project_members'`.
2. Seed one system target group: `code = 'project_members'`, `label = 'Project Members'`, `is_system = true`.
3. `user_can()` Path D — new `OR` branch:

   > `p_owner` is an employee with a **current** `project_members` row on a project where `manager_id = <caller>` and `projects.active`.

4. `get_target_population()` — matching branch in the `resolved` CTE, same definition.
5. `sync_target_group_members()` — **untouched**. Like `hierarchy`, this is caller-dependent and resolves live; caching it would need a full resync on every membership change.

**"Current" means as of today** in both functions above, and that is correct: `user_can` answers *"may I open this record right now"*, which is a question about now. It is also **fully dynamic** — no cache, no sync job. The moment a lead adds someone to `project_members`, that person is in the lead's scope on the lead's next request.

Reporting deliberately does **not** use this. See §3.3a.

---

### Piece 3 — per-project row restriction on the report tabs

This is the piece that makes "and nothing else" true, and the only piece with no existing precedent.

**The problem it solves.** A target group hands you an **employee**. An employee carries all of their hours. Without this piece, the moment Meera is in Hari's target population he sees her 60 AMPTJ hours *and* her 100 hours on a project he has nothing to do with.

**The rule.** Split the report's rows into two disjoint sets — the same `hdr` / `hdr_pm` `UNION ALL` shape already proven in migrations 770 and 771:

| Set | Rows | Restriction |
|---|---|---|
| **A** — unrestricted | booked by employees the caller reaches through a scope type **other than** `project_members` (`everyone`, `direct_l1`, `same_department`, …) | none — **all** their rows, exactly as today |
| **B** — project-restricted | every **remaining** row whose `project_id` is a project the caller manages | that's it — no membership test, no dates, department redacted |

Set B is the new behaviour. Set A is untouched, so nobody's existing report changes.

An HR Analyst on `everyone` is entirely in set A and sees no difference. Hari, whose only grant is `Project Members`, has an empty set A and sees AMPTJ only. A department head who also runs a project gets their department in full **plus** their project's outsiders, and the split gives that for free.

> **The detail that makes this correct.** Set A must be built from the caller's scopes **excluding** `project_members`. If it isn't, Meera — a current member, therefore in the caller's target population via Piece 2 — lands in set A and Hari sees her 100 hours on the other project. That is the exact outcome this design exists to prevent. Concretely: `time_report_scope_ids()` needs a companion that returns ids from non-`project_members` scopes only, and anyone whose only route in is `project_members` falls through into set B, where the project restriction bites.
>
> Piece 2 therefore does real work on the **timesheet** side (Hari can open a current member's timesheet) and is deliberately **ignored by the reports**. The two halves of the requirement are served by two different mechanisms — see §3.3a.

**Set B's rule contains no dates.** It is a flat `project_id IN (projects I manage)`. Why that is the right rule, and not membership-as-of-the-period, is §3.3a — the single most important decision in this document.

---

### 3.3a — Why the report is driven by the project, not by membership

**The trap.** The obvious rule is *"show me the hours of people on my project"*. Follow it and you must answer **"was Meera a member of AMPTJ in March?"** — which is date arithmetic, evaluated at report time, against an effective-dated table. That is precisely where wrong totals come from, and a report that is quietly wrong is worse than one that errors.

Concretely, with membership resolved **as of today**: Meera is on AMPTJ Jan–Mar, logs 60h, rolls off 31 March. Hari's March report reads **152h** in April and **92h** in May. Same report, same period, two different answers. Disqualifying.

**The fix is to ask a different question.** These two mean the same thing in ordinary speech, but only one of them is stable:

| Question | Stable? |
|---|---|
| Was this person a member of my project during that period? | No — the answer changes as membership changes |
| **Is this hour booked to a project I manage?** | **Yes — true in April, still true in 2028** |

Meera's March hours were booked to AMPTJ. Nothing that happens to her membership afterwards can change that. So the report asks the second question and never touches `project_members` at all.

**The design therefore splits the two questions and drives each from its own source:**

| Question | Driven by | Resolved as of |
|---|---|---|
| **Whose timesheet may I open?** | `project_members` — current members of projects I manage (Piece 2) | **today** |
| **Which hours appear in my report?** | `timesheet_entries.project_id` ∈ projects I manage (Piece 3, set B) | **no date logic at all** |

The report never asks who was a member. It asks which project the hour was booked to.

Neither needs an effective-dated lookup. The period-aware helper this document previously proposed is **deleted** — along with the `effective_from <= period_end AND (effective_to IS NULL OR effective_to >= period_start)` predicate, the risk of getting it subtly wrong, and its test case.

**Behaviour over time — Meera, on AMPTJ Jan–Mar, 60h, rolls off 31 March:**

| Hari does this | Result |
|---|---|
| Runs the March report, in April | 60 h shown |
| Runs the **same** March report, in July | 60 h shown — identical, nothing drifted |
| Runs the June report | nothing from Meera — she booked no June hours to AMPTJ |
| Opens Meera's timesheet in July | **denied** — she is not on his team any more |
| Meera's department, in the July run of the March report | **Hidden** |

Only the last row changes over time, and it changes in the safe direction: Hari keeps the **cost to his project** permanently and loses the **person's attributes** the day she leaves his team.

**Redaction survives, and becomes meaningful.** The existing `via_project` NULL-out of `department_name` is not deleted — it is repurposed. A row is redacted when the person is not in the caller's current target population, so it now says:

> *you are seeing this line because it is your project, not because this is your person*

which is true, and is the correct privacy answer for an ex-member. Current members are in Hari's target population via Piece 2 and render normally — name, department, no badge.

**The cost, stated honestly.** Someone who booked hours to AMPTJ but was never added to `project_members` — legacy data, an admin correction, a mis-keyed entry — still appears in Hari's report. Under a membership-driven rule they would be invisible and the project total would silently be short. Showing the line is the better failure: a project's hours are the project's hours.

**Rejected alternative — "ever a member".** Stable totals, but it keeps every past member permanently inside Hari's person-level scope, so he could still open a 2024 leaver's timesheet. It fixes the totals by over-granting the access.

**Where the historic team list lives.** `my_project_members()` (mig 774) already reads `project_members` directly for projects the caller manages, dates included — so the My Projects screen can show past stints with a "to 31 Mar" label. Nothing is lost by keeping history out of the report's scope logic.

---

## 4. Worked example — Hari and AMPTJ

**Setup, once, by an admin:**

1. Put Hari in the **Reporting Manager** field on project AMPTJ. → `sync_system_roles` puts him in **Project Manager**. Nobody typed his name in Security.
2. Create a permission set — say `Project Lead` — with **Timesheet → View** and the two Timesheet Report permissions ticked.
3. **Assignments** tab → **Grant access to: Project Manager**, **Target group: Project Members**, **Include self** ticked.

That is the whole setup, and it is done **once for every project lead who will ever exist**. The next lead is created by naming them on a project.

**What Hari sees**, with Meera (60h AMPTJ, 100h elsewhere) and Rahul (52h AMPTJ) as AMPTJ members and Hari's own 40h:

| | Today (`↳ Managed projects`) | This design |
|---|---|---|
| AMPTJ total | 152 h | 152 h |
| Meera's name | shown | shown |
| Meera's department | **Hidden** always | shown while she is a member; **Hidden** after she rolls off |
| Meera's 100 h elsewhere | not shown | **not shown** |
| Can open Meera's timesheet | no | yes while she is a member; no after |
| AMPTJ March total, re-run months later | 152 h | 152 h — cannot drift (§3.3a) |
| Setup per new project lead | tick a box per person | none |

**When Hari comes off AMPTJ:** his name leaves the project, the trigger fires, the role membership goes, and every grant that hung off it evaporates the same second. No cleanup task.

---

## 5. Decisions still open

1. **Eligibility on `projects.active` only, or also `end_date`?** Recommend `active` only. A project past its end date is often still being closed out and the lead still needs the report.
2. **Should `Project Members` be selectable for non-timesheet modules** (`employee_details.view`, `personal_info.view`)? It would be, once the scope type exists — the chip appears everywhere. That would let a project lead open a team member's personal data. Recommend we ship it and note it, rather than trying to restrict a scope type per module (the engine has no such concept and adding one is a much bigger change).
3. **Does a member with zero hours appear?** On the **team screen**, yes — they are on the project. In the **report**, no — there are no hours to show. Per §3.3a these are two different questions with two different sources, and this is the visible consequence.
4. **Does the lead see their own hours?** Governed by the **Include self** checkbox on the assignment, same as every other role.
5. **Retiring `↳ Managed projects`** — decided: **leave it until proven**. Revisit after this runs on Dev against real data.
6. **How the `Project Members` chip becomes reachable.** `getRoleCategory` is a substring heuristic (`ess` / `mss` / `hr`) and `project_manager` falls into `mss`, which has no escape hatch. Options: (a) add a fourth `pm` category matched on the role code, offering `Project Members` plus `Select target group →`; (b) add the chip to every category; (c) drop the heuristic and let any role reach any group. Recommend **(a)** — smallest change, and it keeps the matrix from offering `Project Members` to an HR role where it would mean nothing.
7. **Trigger cost.** `sync_system_roles()` loops every linked profile per firing, so the new `projects` trigger is O(profiles) per row changed — already true of the `employees` and `department_heads` triggers. `UPDATE OF` is narrowed to `manager_id, active` so ordinary project edits never fire it. If a bulk project import ever becomes a real workload, the fix is a per-profile fast path, not a different trigger.

---

## 6. Explicitly not in this design

- Narrowing the timesheet **project dropdown** to member projects, and the enforcement trigger behind it. Separate switch, separate change.
- The assignment **email** to the employee, CC lead and line manager.
- Any change to `sync_target_group_members()` or the pg_cron job.
- Any change to sets A's behaviour, or to the Compliance tab.

---

## 7. Build order, when we build

| # | Migration | Change | State |
|---|---|---|---|
| 1 | `20260826780` | `project_manager` role + `sync_system_roles` branch + `projects` trigger | built, 18 assertions |
| 2 | `20260826781` | `project_members` scope type: CHECK, seed, `user_can`, `get_target_population` | built, 18 assertions |
| 3 | `20260826782` | set A excludes `project_members`; set B gate widened; redaction narrowed | built, 17 assertions |

All three must land together. Between 781 and 782 a lead on `Project Members` would see the whole employee — the thing this design exists to prevent — so 781 must never ship alone.

**One structural change worth knowing about**, made in 782: the reports need *"the population, but pretend this scope type isn't there"*. Rather than keep a second copy of `get_target_population` (which is how functions drift), its body moved to **`get_target_population_scoped(module, action, exclude_scope_types[])`** and the two-argument function became a three-line wrapper. Behaviour is unchanged for every existing caller. **Anchored patches must now target the scoped function** — one aimed at the old body fails its hit-count assertion rather than silently doing nothing.

Why *exclude at resolution* rather than *subtract afterwards*: someone who is both a department head and a project lead reaches their department through `same_department` and their project's outsiders through `project_members`. Subtracting would strip their own department members out of set A and clip them to the project. Excluding the scope type leaves the other routes intact.

## 8. Test plan

- Role sync: name on project → in role; remove name → out; deactivate project → out; manual grant survives sync.
- Scope: `user_can('timesheet','view', <member>)` true for the lead, false for a non-member, false for a member of someone *else's* project.
- **Stability (the §3.3a test):** run the March report; roll Meera off AMPTJ; run the *identical* March report again → **byte-identical output**. This is the regression that must never pass silently.
- Ex-member: after roll-off, Meera's March hours still appear, her department renders **Hidden**, and `user_can('timesheet','view', meera)` returns false for Hari.
- Dynamic membership: add someone to `project_members` → they are in the lead's scope on the next request, with no sync job run and no cache rebuild.
- **Isolation while she is a current member** — the case most likely to regress: Meera is in Hari's target population via `Project Members`, and her 100 non-AMPTJ hours must still never appear in his totals or his export. This is the assertion that catches set A being built without the `project_members` exclusion.
- No regression: HR Analyst on `everyone` gets byte-identical output before and after.
