# Supabase Auth Email Templates

This folder holds the HTML source of every auth email Supabase sends on behalf
of the app. Templates live in each Supabase project's Authentication → Email
Templates dashboard; they cannot be applied via SQL or the CLI today.

## Files

Each template Supabase supports maps to one file below. Any of these left empty
means "use Supabase's default template for that email".

| File                    | Dashboard label       | Sent when |
|-------------------------|-----------------------|-----------|
| `confirm-signup.html`   | Confirm signup        | New user signs up with email/password and needs to verify. |
| `invite.html`           | Invite user           | Admin invites a user via `inviteUserByEmail`. |
| `magic-link.html`       | Magic Link            | User requests a magic link login. |
| `change-email.html`     | Change Email Address  | User initiates an email address change. |
| `reset-password.html`   | Reset Password        | User clicks "Forgot password". |

## Applying to an environment

Because Supabase doesn't expose these as SQL, you paste them into the dashboard
per env. Once for each. Order of operations:

1. Edit the .html file in this folder — that's the source of truth.
2. Open Supabase Dashboard → your project → **Authentication** → **Email Templates**.
3. Pick the template that matches the file.
4. Paste the HTML into the editor. Preview.
5. Save.
6. Repeat for each of the 5 templates.
7. Repeat for each env (Dev, UAT, Prod).

## Variables Supabase substitutes

Available in every template (per [Supabase docs](https://supabase.com/docs/guides/auth/auth-email-templates)):

- `{{ .ConfirmationURL }}` — the link the user must click.
- `{{ .Token }}` — 6-digit OTP (for embedded token flows).
- `{{ .TokenHash }}` — hashed token (older API).
- `{{ .SiteURL }}` — the project's Site URL (from URL Configuration).
- `{{ .Email }}` — recipient email address.
- `{{ .Data.custom_field }}` — any custom data passed via `admin.auth` calls.

## Fetching current templates from an env

Supabase Dashboard doesn't offer a bulk export. To grab what's currently on UAT:

1. Open **Authentication → Email Templates**.
2. Click a template.
3. Copy the HTML source into the matching file in this folder.
4. Repeat for each template.

Do this once from your source-of-truth env (UAT), then treat this folder as
canonical going forward.

## Discovered gap 2026-07-09

Auth email templates are the only piece of the app's runtime configuration
that cannot be codified as a SQL migration. This folder + the manual paste step
is the closest we can get without building a Management API script.
