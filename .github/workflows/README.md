# CI/CD Workflows

## db-push.yml — Automated Supabase migration deployment

Applies migrations in `supabase/migrations/` to the correct Supabase project based on the git branch pushed.

### Branch → env mapping

| Branch | Env | Approval |
|---|---|---|
| `main` | Dev (prowess-dev) | none (auto) |
| `staging` | UAT (prowess-uat) | optional reviewer |
| `production` | Prod | required reviewer |

### One-time setup

**1. Create GitHub Environments** (Settings → Environments → New environment):

- `dev` — no protection rules
- `uat` — protection rules: 0-1 required reviewers (optional)
- `production` — protection rules: **1+ required reviewers** (mandatory)

**2. Per environment, add secrets and variables:**

| Name | Type | Value |
|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | Secret | Personal access token from https://supabase.com/dashboard/account/tokens |
| `SUPABASE_DB_PASSWORD` | Secret | DB password from Supabase Dashboard → Project Settings → Database |
| `SUPABASE_PROJECT_REF` | Variable | `etmnumptfadkynbsgszz` (dev), `okpnubnswpgybpzgwgtr` (uat), TBD (prod) |

The access token can be shared across envs (single personal token). DB passwords MUST be per-env.

### How the workflow runs

- Only fires when `supabase/migrations/**` or `.github/workflows/db-push.yml` changes on a tracked branch
- Determines target env from branch name
- Uses GitHub Environments to gate on protection rules (Prod push waits for approval)
- Applies migrations via `supabase db push --yes`
- Prints migration list before + after for audit

### Manual trigger

You can also trigger from the Actions tab (`workflow_dispatch`) — useful for re-runs after fixing a broken migration.

### Rollback

`supabase db push` does not support rollback. If a migration is bad:
1. Write a new "revert" migration
2. Push through the same pipeline
3. Never edit already-applied migrations (they run once per env)

### Frontend deploys

The frontend is handled separately by Vercel — no GitHub Actions needed. Vercel auto-detects git pushes and deploys to the matching env's Vercel project (prowess-dev, prowess-uat, prowess-prod).
