/**
 * send-notification-email
 *
 * Supabase Edge Function — called by the Postgres trigger
 * `trg_email_notification` via pg_net on every INSERT into `notifications`.
 *
 * Flow:
 *   1. Verify the shared WEBHOOK_SECRET header
 *   2. Look up the recipient's email via Supabase Admin (auth.users)
 *   3. Render a branded HTML email
 *   4. Send via Resend API
 *   5. Write email_status ('sent' | 'failed' | 'skipped') + email_error back
 *      to the notifications row so the Notification Monitor can surface it
 *
 * Required environment variables (set via `supabase secrets set`):
 *   RESEND_API_KEY        — Resend API key  (re_xxxx...)
 *   EMAIL_FROM            — Verified sender  (e.g. "Expenses <no-reply@yourco.com>")
 *   WEBHOOK_SECRET        — Shared secret between Postgres trigger and this function
 *   SUPABASE_URL          — Auto-injected by Supabase
 *   SUPABASE_SERVICE_ROLE_KEY — Auto-injected by Supabase
 *   APP_BASE_URL          — Optional; defaults to deriving from SUPABASE_URL
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ─── Types ────────────────────────────────────────────────────────────────────

interface NotificationPayload {
  notification_id: string;
  profile_id:      string;
  title:           string;
  body:            string | null;
  link:            string | null;
}

// ─── Entry point ──────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  // Only accept POST
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  // ── 1. Authenticate the request ──────────────────────────────────────────
  const webhookSecret = Deno.env.get('WEBHOOK_SECRET');
  if (webhookSecret) {
    const authHeader = req.headers.get('x-webhook-secret');
    if (authHeader !== webhookSecret) {
      console.error('send-notification-email: invalid webhook secret');
      return new Response('Unauthorized', { status: 401 });
    }
  }

  // ── 2. Parse payload ─────────────────────────────────────────────────────
  let payload: NotificationPayload;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad Request: invalid JSON', { status: 400 });
  }

  const { notification_id, profile_id, title, body, link } = payload;

  if (!profile_id || !title) {
    return new Response('Bad Request: missing profile_id or title', { status: 400 });
  }

  // ── 3. Shared clients ─────────────────────────────────────────────────────
  const supabaseUrl    = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const resendApiKey   = Deno.env.get('RESEND_API_KEY');
  const emailFrom      = Deno.env.get('EMAIL_FROM') ?? 'Expense Tracker <no-reply@example.com>';

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Helper: write outcome back to the notification row (best-effort — never throws)
  async function writeOutcome(status: 'sent' | 'failed' | 'skipped', error?: string) {
    if (!notification_id) return;
    const patch: Record<string, unknown> = { email_status: status };
    if (status === 'sent')   patch.email_sent_at = new Date().toISOString();
    if (status === 'failed') patch.email_error   = error?.slice(0, 1000) ?? 'Unknown error';
    await admin.from('notifications').update(patch).eq('id', notification_id);
  }

  if (!resendApiKey) {
    const msg = 'RESEND_API_KEY not configured';
    console.error('send-notification-email:', msg);
    await writeOutcome('failed', msg);
    return new Response(JSON.stringify({ sent: false, reason: msg }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  }

  // ── 4. Look up recipient email via admin client ───────────────────────────
  const { data: userData, error: userErr } = await admin.auth.admin.getUserById(profile_id);

  if (userErr || !userData?.user?.email) {
    const reason = userErr?.message ?? 'no email address on auth user record';
    console.error(`send-notification-email: cannot find email for profile ${profile_id}:`, reason);
    // Mark skipped — no point retrying if there's no email address
    await writeOutcome('skipped', reason);
    return new Response(JSON.stringify({ sent: false, skipped: true, reason }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  }

  const toEmail = userData.user.email;

  // ── 5. Build deep link ────────────────────────────────────────────────────
  const appBaseUrl = Deno.env.get('APP_BASE_URL') ?? supabaseUrl.replace('.supabase.co', '.vercel.app');
  const fullLink   = link ? `${appBaseUrl}${link}` : `${appBaseUrl}/workflow/my-requests`;

  // ── 6. Render HTML email ──────────────────────────────────────────────────
  const html = renderEmail({ title, body: body ?? '', link: fullLink });

  // ── 7. Send via Resend ────────────────────────────────────────────────────
  let resendRes: Response;
  try {
    resendRes = await fetch('https://api.resend.com/emails', {
      method:  'POST',
      headers: {
        'Content-Type':  'application/json',
        'Authorization': `Bearer ${resendApiKey}`,
      },
      body: JSON.stringify({
        from:    emailFrom,
        to:      [toEmail],
        subject: title,
        html,
      }),
    });
  } catch (fetchErr) {
    const msg = `Network error reaching Resend: ${fetchErr instanceof Error ? fetchErr.message : String(fetchErr)}`;
    console.error('send-notification-email:', msg);
    await writeOutcome('failed', msg);
    return new Response(JSON.stringify({ sent: false, error: msg }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  }

  if (!resendRes.ok) {
    const errText = await resendRes.text();
    const msg     = `Resend ${resendRes.status}: ${errText}`;
    console.error(`send-notification-email: ${msg}`);
    // Write failure status back so the monitor surfaces it and retry becomes available
    await writeOutcome('failed', msg);
    return new Response(
      JSON.stringify({ sent: false, resend_status: resendRes.status, error: errText }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  }

  const resendData = await resendRes.json();
  console.log(
    `send-notification-email: sent to ${toEmail}, resend_id=${resendData.id}, notification=${notification_id}`,
  );

  // ── 8. Write success status back ─────────────────────────────────────────
  await writeOutcome('sent');

  return new Response(
    JSON.stringify({ sent: true, resend_id: resendData.id }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
});

// ─── Email renderer ───────────────────────────────────────────────────────────

function renderEmail(opts: { title: string; body: string; link: string }): string {
  const { title, body, link } = opts;

  const bodyHtml = body
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/\n/g, '<br>');

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${escHtml(title)}</title>
</head>
<body style="margin:0;padding:0;background:#F3F4F6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#F3F4F6;padding:40px 16px;">
    <tr>
      <td align="center">
        <table width="560" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.08);">

          <!-- Header -->
          <tr>
            <td style="background:#2F77B5;padding:28px 36px;">
              <span style="font-size:20px;font-weight:700;color:#ffffff;letter-spacing:-0.3px;">
                💼 Expense Tracker
              </span>
            </td>
          </tr>

          <!-- Body -->
          <tr>
            <td style="padding:36px 36px 24px;">
              <h1 style="margin:0 0 16px;font-size:20px;font-weight:700;color:#111827;line-height:1.3;">
                ${escHtml(title)}
              </h1>
              <p style="margin:0 0 24px;font-size:15px;color:#374151;line-height:1.6;">
                ${bodyHtml}
              </p>
              <table cellpadding="0" cellspacing="0">
                <tr>
                  <td style="border-radius:8px;background:#2F77B5;">
                    <a href="${escAttr(link)}"
                       style="display:inline-block;padding:12px 28px;font-size:14px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;">
                      View in Expense Tracker →
                    </a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Divider -->
          <tr>
            <td style="padding:0 36px;">
              <hr style="border:none;border-top:1px solid #E5E7EB;margin:0;" />
            </td>
          </tr>

          <!-- Footer -->
          <tr>
            <td style="padding:20px 36px 28px;">
              <p style="margin:0;font-size:12px;color:#9CA3AF;line-height:1.5;">
                You received this notification from Expense Tracker because an action
                requires your attention. If you have questions, contact your system administrator.
              </p>
              <p style="margin:8px 0 0;font-size:12px;color:#9CA3AF;">
                <a href="${escAttr(link)}" style="color:#6B7280;text-decoration:underline;">
                  Open in app
                </a>
              </p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function escAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}
