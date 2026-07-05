# Prowess HRMS — Architecture, Environments, Deployment & Go-Live

**Status:** Reference document | Version 1.0 | 2026-07-05
**Scope:** Documents current architecture (what exists) + recommendations (marked as such) for environments, deployment pipeline, and production go-live.

This is a reference, not a locked design. Recommendations should be discussed and adjusted against operational reality. Sections marked **[CURRENT]** describe existing state; **[RECOMMENDED]** are proposals; **[GAP]** flags something that needs a decision before go-live.

---

## §1 Executive Summary

Prowess is a Supabase + React HRMS with an event-sourced workflow engine, permission-scoped access control, and a bulk operations framework. It's built for organisations in the 100–2,000 employee range with multi-country requirements. The stack is intentionally boring: Postgres does most of the heavy lifting via RPCs; the React frontend is a thin permission-aware shell; Edge Functions handle asynchronous and integration work.

Current state: **13 modules shipped or in design**, ~600 migrations, ~10 Edge Functions, ~20 permission namespaces, effective-dated satellite pattern, workflow engine, target-population RBAC.

Before production go-live, the three areas that need explicit decisions: (a) environment topology (dev / UAT / prod separation), (b) migration promotion pipeline, (c) data migration from any legacy HRMS.

---

## §2 Architecture Overview

### §2.1 High-level stack **[CURRENT]**

```
┌───────────────────────────────────────────────────────────────────────┐
│                          USER (Browser)                                │
│    Chrome / Safari / Firefox — Desktop + Mobile responsive             │
└──────────────────────────────┬────────────────────────────────────────┘
                               │  HTTPS
                               ▼
┌───────────────────────────────────────────────────────────────────────┐
│                        FRONTEND (Static SPA)                           │
│    React + TypeScript + Vite                                           │
│    Hosted on: CDN-backed static site (Vercel / Netlify / CloudFront)   │
│    Bundle: ~2–5 MB gzipped; single-page app with client-side routing   │
└──────────────────────────────┬────────────────────────────────────────┘
                               │  Supabase JS SDK (JWT auth)
                               ▼
┌───────────────────────────────────────────────────────────────────────┐
│                    SUPABASE (Backend-as-a-Service)                     │
│                                                                         │
│  ┌──────────┐  ┌──────────────┐  ┌──────────┐  ┌────────────────┐      │
│  │   AUTH   │  │  POSTGREST   │  │  STORAGE │  │ EDGE FUNCTIONS │      │
│  │  (JWT)   │  │  (auto REST) │  │  (S3-like)│  │  (Deno runtime)│      │
│  └────┬─────┘  └──────┬───────┘  └────┬─────┘  └────────┬───────┘      │
│       │               │                │                 │              │
│       │        ┌──────▼────────────────▼─────────────────▼──────┐      │
│       └───────►│           POSTGRES (Managed)                    │      │
│                │  • ~600 migrations                              │      │
│                │  • Row-Level Security on every employee-scoped  │      │
│                │    table                                        │      │
│                │  • SECURITY DEFINER RPCs enforce business rules │      │
│                │  • pg_trgm, pg_cron, pgcrypto extensions        │      │
│                │  • Bi-temporal effective-dating pattern         │      │
│                └─────────────────────────────────────────────────┘      │
└──────────────────────────────┬────────────────────────────────────────┘
                               │
                               │  Egress (outbound integrations)
                               ▼
┌───────────────────────────────────────────────────────────────────────┐
│                       EXTERNAL SERVICES                                │
│    Resend (transactional email) — send-job-alert, notifications        │
│    Payroll integration (future) — via Edge Function webhook            │
│    Identity Provider (future) — SAML / OIDC for SSO                    │
└───────────────────────────────────────────────────────────────────────┘
```

### §2.2 Core patterns **[CURRENT]**

| Pattern | Where used | Purpose |
|---|---|---|
| **Bi-temporal effective-dating** | Personal Info, Employment, Job Relationships, Address, Bank | Timeline-aware records: `effective_from`, `effective_to`, `is_active`. `9999-12-31` = open-ended slice. |
| **Set-snapshot** | Dependents, Bank, Job Relationships | Parent set + child items per effective-dated slice. Whole-set replacement on edit. |
| **Event table** | Termination | Non-effective-dated. Single row per event with its own workflow state. |
| **Dual-path RPC** | Every write RPC | Same entry point routes to direct-write (PATH A) or workflow-staged (PATH B) based on module configuration. |
| **Workflow engine** | Cross-cutting | `wf_submit` / `wf_approve` / `wf_reject` / `wf_resubmit` / `wf_withdraw`. Multi-approver, ROLE fan-out, target-population aware. |
| **Post-approval automation** | Termination, JR, Employment | Edge Function triggered on approval → slice closure, status flips, notifications, integration events. |
| **Bulk Operations Framework** | 17 templates | Cross-module CSV import/export via registry-driven pipeline. Async Edge Function processor. |
| **Permission engine** | Every RPC + every UI section | `user_can(module, action, target_id)` + `target_groups` for population scoping. |

### §2.3 Security model layers **[CURRENT]**

```
Request from browser
  │
  ▼
[Layer 1] Supabase Auth — validates JWT, extracts auth.uid()
  │
  ▼
[Layer 2] Row-Level Security (RLS) — Postgres policies on every table
          Employee-scoped tables enforce "you can see yourself + your subordinates"
  │
  ▼
[Layer 3] SECURITY DEFINER RPC — SET search_path = public
          Calls user_can(module, action, target_id) at entry
  │
  ▼
[Layer 4] user_can — evaluates permission grant + target_groups + role membership
  │
  ▼
[Layer 5] Business logic — validation, workflow, effective-dating
```

Defence-in-depth: even if Layer 1 is bypassed (impossible without Supabase JWT), Layer 2 (RLS) blocks the query. Even if RLS is misconfigured, Layer 3 (SECURITY DEFINER + user_can) rejects the call.

### §2.4 Workflow engine architecture **[CURRENT]**

```
User submits change
    │
    ▼
submit_<module>(...)  [SECURITY DEFINER RPC]
    │
    ├─ user_can('<module>', 'edit', target_id)   ─── rejects if denied
    │
    ├─ Insert / stage record in DRAFT state
    │
    ▼
wf_submit(template_code, module_code, record_id, subject_employee_id, ...)
    │
    ├─ resolve_workflow_for_submission()  ── picks the right template + steps
    ├─ Insert row in workflow_instances (status=PENDING, initiated_by_actor_id if subject≠actor)
    ├─ For each step: wf_resolve_approver_ex → creates workflow_action row
    ├─ Concurrent guard (termination): reject if other module has open termination for target
    │
    ▼
Approver sees task in ApproverInbox → wf_approve() / wf_reject()
    │
    ▼
On final approval: wf_sync_module_status(module_code, record_id, 'approved')
    │
    ├─ Inline execution (Termination): fn_pre_insert + fn_finalize
    │
    ├─ For satellite modules: apply_profile_pending_change trigger
    │       └─ Copies staged row into the real satellite table
    │
    └─ Enqueue Edge Function for post-approval automation (async)
```

Workflow instances table is the audit trail. Denormalized `workflow_status` on the record row exists only where a partial-unique constraint needs it (e.g. Termination).

### §2.5 Bulk operations pipeline **[CURRENT]**

```
CSV upload (up to 10,000 rows) → Storage bucket bulk-uploads/
    │
    ▼
Validator Edge Function (sync, < 1s)
    ├─ Reads bulk_template_registry row for the module
    ├─ Parses CSV with strict mm/dd/yyyy dates + codes-only enforcement
    ├─ Returns row-level errors and warnings
    │
    ▼
Processor Edge Function (async, per-row)
    ├─ For each row: calls the module's processor RPC
    ├─ Bulk bypasses workflow — jumps straight to APPROVED where applicable
    ├─ Stamps upload_batch_id for traceability
    ├─ Errors isolated per-row (BEGIN/EXCEPTION)
    ├─ Status → bulk_upload_job with counts
    │
    ▼
In-app notification on completion → uploader + optional HR group
```

17 templates registered. `bulk_export` RPC has 17 WHEN clauses (grew from 15 → 16 → 17 as Education and Termination shipped).

### §2.6 Effective-dating pattern (detail) **[CURRENT]**

```
Timeline for one employee's employment:

  effective_from   effective_to   is_active   status    manager
  ──────────────   ────────────   ─────────   ──────    ───────
  2020-01-15       2022-03-31     false       Active    Alice    ← historical
  2022-04-01       2024-06-30     false       Active    Bob      ← historical
  2024-07-01       9999-12-31     true        Active    Carol    ← current (open)
```

- Reads: `WHERE effective_from <= :as_of_date AND effective_to > :as_of_date`
- Current slice: `WHERE effective_to = '9999-12-31' AND is_active = true`
- Historical amendments: close current, insert new with the change
- Never DELETE — set `is_active = false` (soft-close for auditability)

### §2.7 File & attachment storage **[CURRENT]**

Supabase Storage buckets:
- `attachments` — general (dependents, identity records, education, termination)
- `bulk-uploads` — bulk CSV files (7-day retention)
- `avatars` — employee photos (public read, controlled write)

Retention: audit-relevant attachments (dependents, termination) retained permanently; bulk uploads auto-purged.

Reference stored in DB tables (`file_path` column); actual bytes in the bucket. Signed URLs for controlled downloads.

### §2.8 Scheduled jobs **[CURRENT]**

```
pg_cron schedule                    Job
─────────────────────────           ────────────────────────────────────
00:05 UTC daily                     process_scheduled_terminations
02:30 UTC daily                     job_run_log_retention (90-day purge)
[TBD]                               bulk_upload_purge (7-day CSV cleanup)
```

Each scheduled job:
- Runs inside Postgres via pg_cron OR calls an Edge Function
- Logs to `job_run_log` (per-run status, row counts, error details)
- Failure alerts go through `send-job-alert` Edge Function (Resend)
- Surfaced in JobsAdmin UI with per-run history + Excel download

---

## §3 Repository & Codebase Layout **[CURRENT / RECOMMENDED]**

```
/Users/vj/Developer/ET-React/
├── src/
│   ├── components/              — React components (portlets, admin, shared)
│   ├── hooks/                   — Data-fetching + business-logic hooks
│   ├── lib/                     — API clients, formatters, utilities
│   ├── contexts/                — React contexts (Auth, Profile, etc.)
│   ├── workflow/                — Workflow-specific screens (Inbox, Review)
│   ├── pages/ or routes/        — Top-level route components
│   └── main.tsx                 — App entry
├── supabase/
│   ├── migrations/              — YYYYMMDDnnn_description.sql
│   ├── functions/               — Edge Functions (one folder per function)
│   ├── seed.sql                 — Optional local dev seed data
│   └── config.toml              — Supabase project config
├── docs/                        — Design docs (JR, Termination, Search, etc.)
├── prowess_system_docs.html     — Rendered system docs (Parts 1–24)
├── public/                      — Static assets
├── package.json
├── vite.config.ts
└── tsconfig.json
```

**[RECOMMENDED]** Add these if not already present:
- `.github/workflows/` — CI/CD pipelines
- `scripts/` — one-off scripts (seed data, data migration, health checks)
- `tests/` — integration test suites (RPC contract tests, workflow tests)
- `.env.example` — template for developers
- `CHANGELOG.md` — user-facing release notes
- `RUNBOOK.md` — operational procedures (rollback, incident response, common queries)

---

## §4 Environment Strategy

### §4.1 Recommended environments **[RECOMMENDED]**

Four environments, one Supabase project per environment. Do NOT share DBs across environments — cross-contamination is a real risk with a permission model this rich.

| Env | Purpose | Supabase project | Data | Access | Deployment cadence |
|---|---|---|---|---|---|
| **Local** | Developer's laptop | Local (Docker) via `supabase start` | Seeded synthetic | Developer only | Per commit |
| **Dev** | Shared integration, PR previews | prowess-dev | Synthetic + volatile | Engineering team | On merge to `main` |
| **UAT** | Business validation, training | prowess-uat | Anonymised prod snapshot (refreshed monthly) | HR + selected pilot users | Weekly release |
| **Prod** | Live | prowess-prod (`okpnubnswpgybpzgwgtr`) | Live | Restricted; break-glass only | Fortnightly + hotfixes |

**[GAP]** Do you have a UAT environment set up today? Memory only shows the production project ID. If UAT doesn't exist, this is the first thing to fix before go-live.

### §4.2 Per-environment configuration **[RECOMMENDED]**

Each environment needs its own copy of:
- Supabase URL + anon key + service_role key
- Storage bucket policies
- Edge Function secrets (Resend API key, integration credentials)
- pg_cron schedules (may differ — e.g. run daily jobs on Dev at a lower frequency)
- Feature flags (v2 features may be enabled on Dev/UAT before Prod)

Managed via:
- Frontend: `.env.local`, `.env.dev`, `.env.uat`, `.env.prod` (never checked into git)
- Backend: Supabase project secrets (per project)
- CI/CD: environment-scoped secrets in GitHub Actions (or equivalent)

### §4.3 Data across environments **[RECOMMENDED]**

- **Local & Dev**: 100% synthetic. Never restore prod data here. Use a seed script generating fictional employees.
- **UAT**: anonymised prod snapshot. Real structure, fake PII. Refresh monthly. Anonymisation script scrubs: names, emails (all → user@example.com), national IDs, phone numbers, bank account numbers, addresses.
- **Prod**: live. Access strictly controlled. Break-glass procedure documented in `RUNBOOK.md`.

**[GAP]** Anonymisation script does not exist yet — needs to be written before first UAT refresh.

### §4.4 Local development setup **[RECOMMENDED]**

```bash
# One-time
brew install supabase/tap/supabase
npm install
cp .env.example .env.local

# Every session
supabase start                    # boots local Postgres + Storage + Auth
supabase db reset                 # applies all migrations + seed.sql
npm run dev                       # Vite dev server on :5173
supabase functions serve          # Edge Functions locally
```

Local Supabase uses Docker; ~1.5 GB RAM. Every developer runs their own DB — no shared local. Migrations tested locally before push.

---

## §5 Deployment Architecture

### §5.1 Frontend deployment **[RECOMMENDED]**

Static SPA. Options:

**Option A — Vercel (recommended for small ops team)**
- Automatic preview deploys per PR (public URL, gated by Supabase Auth)
- Environment variables per env
- Global CDN
- Zero-config for Vite

**Option B — Netlify**
- Very similar to Vercel; either is fine

**Option C — Self-hosted (CloudFront + S3)**
- More control; more ops overhead
- Recommended only if there's a compliance requirement (e.g. data residency)

Build:
```bash
npm run build          # Vite → dist/
# Vercel / Netlify auto-deploy from git
```

### §5.2 Backend deployment **[RECOMMENDED]**

Migrations:
```bash
supabase link --project-ref <env-project-id>
supabase db push                    # applies pending migrations
# If a version collision: supabase migration repair --status applied <version>
```

Edge Functions:
```bash
supabase functions deploy <function-name> --project-ref <env-project-id>
supabase secrets set --project-ref <env-project-id> RESEND_API_KEY=...
```

**Critical rule (from Termination memory):** Migrations that `CREATE OR REPLACE` a shared function must be idempotent AND must preserve prior work. Termination mig 611 accidentally dropped inline execution added by mig 608 — the root cause of a two-week production bug. Every `CREATE OR REPLACE` should be reviewed against the current function body before push.

### §5.3 CI/CD pipeline **[RECOMMENDED]**

```
Developer pushes commit
    │
    ▼
GitHub Actions on PR:
    ├─ Lint (eslint, prettier)
    ├─ Typecheck (tsc --noEmit)
    ├─ Unit tests (vitest)
    ├─ Build (vite build)
    ├─ Vercel preview deploy (frontend only, no DB migrations)
    │
    ▼
Merge to main:
    ├─ Same checks as PR
    ├─ Deploy frontend → Dev environment (Vercel)
    ├─ Post migration diff as comment (does NOT auto-run)
    ├─ Manual approval → run `supabase db push` against Dev
    ├─ Deploy Edge Functions to Dev
    │
    ▼
Weekly release cut:
    ├─ Tag release
    ├─ Deploy frontend → UAT (Vercel)
    ├─ Manual approval → run migrations against UAT
    ├─ Smoke test suite runs against UAT
    ├─ Business sign-off
    │
    ▼
Fortnightly production release:
    ├─ Deploy frontend → Prod
    ├─ Manual approval + on-call engineer present → run migrations against Prod
    ├─ Post-deploy smoke test
    ├─ Watch dashboards + error rates for 30 min
```

**Migrations never auto-run against Prod.** Always human-in-the-loop.

### §5.4 Secret management **[RECOMMENDED]**

- **Never in git.** No `.env` files committed. `.env.example` documents the shape only.
- **Frontend secrets**: only the Supabase URL + anon key ship to browsers (safe by design; anon key is scoped by RLS).
- **Backend secrets**: Supabase project secrets (service_role, Resend API key, integration credentials).
- **CI secrets**: GitHub Actions environment-scoped secrets. Rotate quarterly.

### §5.5 Observability **[GAP — decide before go-live]**

Current state: `job_run_log` + `audit_log` tables + Supabase's built-in dashboard. This is thin for a production HRMS.

Recommended additions before go-live:
- **Error tracking**: Sentry for frontend + Edge Function errors. Free tier covers small orgs.
- **Uptime monitoring**: BetterStack or Uptime Robot pinging the frontend + a health-check RPC every minute.
- **Log aggregation**: Supabase logs are searchable but retention is limited. Consider ship-to-Datadog / Better Stack for 90-day retention on high-signal logs (workflow submissions, permission denials, failed migrations).
- **Alerting**: PagerDuty or email-to-Slack for: Edge Function 5xx rate > 1%, scheduled job failures, DB connection saturation, Storage bucket over 80% quota.
- **Metrics dashboard**: Weekly review of: active users, workflow instances submitted/approved/rejected, avg approval time, bulk upload volumes, Edge Function invocation counts.

---

## §6 Data Migration From Legacy **[GAP — needs your input]**

If Prowess is replacing an existing HRMS, the migration is often the biggest go-live risk. Key questions:

1. **Source system**: what HRMS is currently in use? Excel, custom app, SAP, Workday, PeopleSoft, other?
2. **Data volume**: employee count, historical years to migrate.
3. **Fidelity requirement**: do you need full history (every employment slice, every dependent change) or only current state?
4. **Cutover strategy**: big-bang (one weekend) vs phased (department-by-department).

**[RECOMMENDED]** for phased cutover:
- Extract → Transform → Load scripts per module
- Load into `bulk-uploads` bucket → run through Bulk Framework processor
- Every migration row stamped with `upload_batch_id = 'legacy_import_<date>'`
- Reconciliation report: source count vs Prowess count per module
- Delta migration on cutover day for records changed since initial load

**Non-negotiables:**
- All migrated data must satisfy every CHECK constraint before load. Cleanse in staging, not in prod.
- Effective-dating preserved: closed slices in source → closed slices in Prowess.
- Workflow instances NOT migrated. Historical approvals are a paper trail elsewhere.

---

## §7 Backup & Disaster Recovery **[RECOMMENDED]**

### §7.1 Supabase backups **[CURRENT / verify]**

Supabase Pro plans include:
- Daily automated backups (retained 7 days)
- Point-in-time recovery (PITR) — restore to any second within retention

**[GAP]** Confirm the plan tier for the prod project. If on Free/Starter, PITR is not available → upgrade before go-live.

### §7.2 Additional backup **[RECOMMENDED]**

- Nightly `pg_dump` to an external S3 bucket (encrypted, retained 90 days). Weekly full backup retained 1 year. Insurance against Supabase account compromise.
- Storage bucket contents backed up separately (attachments are irreplaceable).
- Migration files versioned in git — the schema IS the code.

### §7.3 Disaster recovery drill **[RECOMMENDED]**

Once per quarter:
- Restore latest backup to a scratch Supabase project.
- Run a smoke test suite against it.
- Time the restore + validation. Document RTO (recovery time objective).
- Post-drill review: what would you have lost if this were real?

### §7.4 Rollback strategy **[RECOMMENDED]**

- **Frontend rollback**: revert deploy in Vercel/Netlify. ~30 seconds.
- **Migration rollback**: Postgres doesn't natively support forward-only migration rollback. Every destructive migration (DROP COLUMN, DROP TABLE) needs a documented undo path. For fast rollback: restore from the pre-deploy PITR snapshot (loses any writes in between).
- **Edge Function rollback**: `supabase functions deploy` the previous version.

**Rule:** never do multiple destructive migrations in the same deployment window. One at a time, with a rollback plan documented for each.

---

## §8 Access Control & Compliance **[GAP + RECOMMENDED]**

### §8.1 User provisioning **[GAP]**

Currently unclear from memory: how are new employees added?
- Manual admin creation via UI?
- Bulk import via CSV?
- SCIM / SSO auto-provisioning?

**[RECOMMENDED]** for production:
- SSO via SAML or OIDC (Okta, Google Workspace, Microsoft Entra ID)
- SCIM provisioning for automatic user lifecycle (create, update, deactivate)
- Supabase Auth supports OIDC natively; SAML requires the Pro plan

### §8.2 Compliance considerations **[GAP]**

Depending on your operating regions:
- **GDPR** (EU): right to be forgotten, data portability, DPO contact. Prowess needs a "delete/anonymise employee" flow that respects legal retention rules.
- **SOC 2** (customer contracts): audit trail, access reviews, change management. Prowess audit tables get you 70% there; the ops policies get you the rest.
- **HIPAA** (US healthcare): if employees are in healthcare orgs, PHI in the system needs BAA with Supabase and encryption at rest (Supabase provides both).
- **Data residency** (India / EU): Supabase project region matters. Once chosen it cannot be moved.

**[GAP]** No "who viewed whom" audit log exists today (flagged in Global Employee Search design). Compliance risk for orgs with strict access-review requirements.

### §8.3 Access reviews **[RECOMMENDED]**

Quarterly:
- Export the permission matrix per role.
- HR + Security review: who has `termination.edit`? Who has `.bulk_import`? Are these still appropriate?
- Any permissions granted outside the standard roles → require re-approval.

Prowess already has the raw data (`user_permissions`, `role_permissions`, `target_groups`). Needs a UI or export.

---

## §9 Go-Live Plan

### §9.1 Pre-flight checklist **[RECOMMENDED]**

Six weeks before go-live:
- [ ] UAT environment set up and populated with anonymised data
- [ ] Data migration scripts written + dry-run against UAT
- [ ] Workflow templates configured for the actual org structure (not defaults)
- [ ] Permission matrix populated per role
- [ ] Target groups defined (by department / region / entity)
- [ ] SSO / SCIM integration configured (if applicable)
- [ ] Backup + PITR verified via a restore drill
- [ ] Observability wired up (Sentry, uptime, alerts)
- [ ] `RUNBOOK.md` drafted (top-10 operational scenarios)

Four weeks before:
- [ ] Pilot user group identified (~20 employees across departments)
- [ ] Training materials drafted (video walkthroughs, quick-reference PDFs)
- [ ] Support model defined: who handles tier-1 tickets, escalation path, SLA
- [ ] Cutover date confirmed with business stakeholders
- [ ] Communication plan: announcement email, town hall, FAQ

Two weeks before:
- [ ] Full data migration dry-run against UAT
- [ ] Reconciliation report reviewed + signed off by HR
- [ ] Pilot users trained
- [ ] Performance test: 100 concurrent users on UAT
- [ ] Security test: penetration test or focused review

One week before:
- [ ] Freeze code (only critical hotfixes)
- [ ] Prod migrations reviewed line-by-line by two engineers
- [ ] Rollback procedure walkthrough
- [ ] On-call schedule confirmed for cutover weekend + first week

### §9.2 Cutover weekend **[RECOMMENDED]**

Assumes a Friday-evening → Monday-morning window.

**Friday 18:00 — Freeze legacy**
- Announce read-only mode on legacy HRMS.
- Take final export from legacy for delta migration.

**Friday 20:00 → Saturday 08:00 — Migration**
- Run delta migration against Prod.
- Reconciliation report generated + reviewed.
- Any variance > 0.1% → HR sign-off before continuing.

**Saturday 08:00 → Sunday 20:00 — Verification**
- Smoke tests + critical user flow tests against Prod.
- Pilot user login + walk-through key journeys.
- 24-hour observation window with on-call engineer active.

**Sunday 20:00 → Monday 08:00 — Communications**
- Go/no-go decision by leadership.
- If GO: announcement email, "system is live" banner activated.
- If NO-GO: rollback to legacy (documented procedure).

**Monday 08:00 — Go-live**
- Legacy set to fully read-only (kept online for 90 days as reference).
- Support team on standby.
- Hourly check-ins during business hours for first day.

### §9.3 Pilot vs big-bang **[RECOMMENDED — pilot]**

Strong recommendation for a **pilot phase** before full rollout:
- 2–4 weeks pilot with ~20 users (mix of employees, managers, HR).
- Fix any critical bugs from pilot feedback.
- THEN full rollout, department by department (2 depts per week).
- Big-bang go-live works only if user base is < 100 AND workflows are simple. Prowess with the workflow engine + effective-dating + termination is complex enough that pilot is safer.

### §9.4 Post-go-live support model **[RECOMMENDED]**

- **First 2 weeks (hypercare)**: dedicated support engineer during business hours, 30-minute response SLA, daily standup with HR.
- **Weeks 3–8**: normal support, 2-hour response SLA, weekly review with HR.
- **After week 8**: BAU (business-as-usual).

Support channels:
- Slack channel for HR-to-engineering questions
- Ticketing system (Linear, Jira, Zendesk) for bug reports
- Weekly office hours for user questions

Ticket triage:
- P0 (system down / data loss): 15-min response, all-hands
- P1 (blocking function for HR): 1-hour response, single engineer
- P2 (annoyance / workaround exists): next business day
- P3 (enhancement request): backlog

### §9.5 Success metrics for first 90 days **[RECOMMENDED]**

Weekly review:
- % of employees active in the system (target: 90% by week 4)
- Workflow instances submitted (baseline)
- Avg workflow approval time (target: < 2 business days for standard modules)
- Ticket volume (declining trend)
- Uptime (target: 99.5% including planned maintenance)
- P0 incident count (target: 0)

---

## §10 Cost Estimation **[RECOMMENDED — refine with actual usage]**

Rough monthly at 500 employees, moderate usage:

| Item | Est. cost / month | Notes |
|---|---|---|
| Supabase Pro (Prod) | ~$25 base + usage | Includes daily backup, PITR, 8 GB DB, 100 GB egress |
| Supabase Pro (UAT) | ~$25 base | Lower usage |
| Supabase Free (Dev) | $0 | Free tier fine for dev |
| Vercel Pro | $20 | Per developer seat if needed; otherwise free tier |
| Resend (email) | ~$10 | Up to 50k emails / month |
| Sentry (errors) | $0–$26 | Free tier ~5k events/month |
| BetterStack (uptime) | $0–$18 | Free tier 3 monitors |
| **Total baseline** | **~$100–$150 / month** | Not including one-time migration work |

Additional at scale:
- Extra Supabase compute (if concurrent users > 100 sustained): +$60/mo tier
- Log retention / observability upgrades: $50–200/mo
- SSO addons (Supabase SAML): +$25/mo

---

## §11 Risks & Open Decisions

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **UAT environment doesn't exist** | Certain (needs confirmation) | High | Set up before starting migration work |
| **No anonymisation script for UAT refresh** | Certain | Medium | Write before first UAT data refresh |
| **Data migration from legacy is scoped as "later"** | High | High | Start scoping now — this is often the go-live blocker |
| **No SSO integration yet** | High | Medium | Fine to launch with password auth; SSO can follow |
| **"Who viewed whom" audit log absent** | Certain | Medium (compliance) | Not blocking for internal HRMS; blocker for regulated industries |
| **Backup restore never drilled** | High | High | Do a restore drill against a scratch project before go-live |
| **Migration collision from parallel work** | Medium | Medium | Documented in migration-conventions memory; enforce sequential mig numbers |
| **Edge Function `CREATE OR REPLACE` accidentally drops prior logic** | Confirmed (Termination mig 611 → 625) | High | Every CREATE OR REPLACE reviewed against current function body before push |
| **`app_config` used for env-specific behaviour** | Unknown | Low | Confirm what's in `app_config`; consider moving to env variables |
| **No observability dashboard** | Certain | High | Wire Sentry + uptime before go-live |

---

## §12 Related Documents

- `docs/prowess_system_docs.html` — Parts 1–24: rendered system reference for the current build
- `docs/termination-design.md`, `docs/global-employee-search-design.md`, `docs/job-relationships-design.md`, etc. — module-specific design docs
- `docs/bulk-operations-framework.md` — cross-module bulk framework spec
- Memory files (linked via `MEMORY.md`) — living notes on implementation history, corrections, gotchas

---

## §13 Next Steps

Before the next major module ships, get answers to:

1. Which environments exist today? Is there a UAT?
2. Is the Prod project on the Supabase plan tier that supports PITR + daily backup?
3. Who is the "customer" — is this a single-tenant deployment for one org, or is Prowess destined to be multi-tenant?
4. Is there a legacy HRMS to migrate from? What system, what fidelity, what deadline?
5. What is the target go-live date?
6. What are the compliance obligations (GDPR / SOC 2 / country-specific labour law)?

Answers to these five reshape the priority order of everything in §9.
