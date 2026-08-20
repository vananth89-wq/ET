/**
 * send-email-change-verification
 *
 * Called by Postgres (pg_net) from trg_employee_email_change whenever
 * employees.business_email is edited on a person who already has a login.
 *
 * Sends TWO emails, and the second one matters as much as the first:
 *
 *   → NEW address   a one-time link that swaps the login when clicked. This is
 *                   the only way the change ever takes effect, which is what
 *                   makes a typo recoverable rather than an account lockout.
 *
 *   → OLD address   a notice that the change was requested, naming the new
 *                   address. It carries no link and asks nothing of the reader.
 *                   Its whole job is to make a change to somebody's login
 *                   visible to the person who currently holds that login, so a
 *                   takeover cannot be silent. Changing business_email is
 *                   reachable by anyone with employee_details.edit; this is the
 *                   tripwire on that.
 *
 * The raw token arrives in the payload and is never stored anywhere: Postgres
 * keeps only sha256(token). This function is the one place it exists outside
 * the recipient's inbox, so it is not logged.
 *
 * Required secrets:
 *   WEBHOOK_SECRET             — shared with app_config.webhook_secret
 *   RESEND_API_KEY             — Resend API key
 *   EMAIL_FROM                 — "Prowess HR <no-reply@..>"
 *   APP_BASE_URL               — public app URL, e.g. https://dev.prowessapp.net
 *   SUPABASE_URL               — auto-injected
 *   SUPABASE_SERVICE_ROLE_KEY  — auto-injected
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

interface Payload {
  change_id:     string;
  token:         string;
  employee_name: string;
  old_email:     string;
  new_email:     string;
  expires_at:    string;
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('Method Not Allowed', { status: 405 });

  const webhookSecret = Deno.env.get('WEBHOOK_SECRET');
  if (webhookSecret && req.headers.get('x-webhook-secret') !== webhookSecret) {
    console.error('send-email-change-verification: invalid webhook secret');
    return new Response('Unauthorized', { status: 401 });
  }

  let p: Payload;
  try { p = await req.json(); }
  catch { return new Response('Bad Request: invalid JSON', { status: 400 }); }

  const supabaseUrl    = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const resendApiKey   = Deno.env.get('RESEND_API_KEY');
  const emailFrom      = Deno.env.get('EMAIL_FROM') ?? 'Prowess HR <no-reply@example.com>';
  const appBaseUrl     = Deno.env.get('APP_BASE_URL') ?? 'https://dev.prowessapp.net';

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });

  async function writeOutcome(status: string, error?: string) {
    await admin.from('employee_email_changes')
      .update({ email_status: status, error_message: error ?? null })
      .eq('id', p.change_id);
  }

  if (!resendApiKey) {
    await writeOutcome('skipped', 'RESEND_API_KEY not configured');
    return json({ sent: false, error: 'RESEND_API_KEY not configured' });
  }

  const verifyUrl = `${appBaseUrl}/verify-email-change?token=${encodeURIComponent(p.token)}`;
  const expires   = new Date(p.expires_at).toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });

  async function send(to: string, subject: string, html: string) {
    const res = await fetch('https://api.resend.com/emails', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${resendApiKey}` },
      body:    JSON.stringify({ from: emailFrom, to: [to], subject, html }),
    });
    if (!res.ok) throw new Error(`Resend ${res.status}: ${await res.text()}`);
    return await res.json();
  }

  // ── 1. The new address — the only copy that can act ────────────────────────
  try {
    await send(
      p.new_email,
      'Confirm this address for your Prowess sign-in',
      shell(`
        <p style="margin:0 0 14px">Hello ${esc(p.employee_name)},</p>
        <p style="margin:0 0 14px">Your Prowess record now lists
          <b>${esc(p.new_email)}</b> as your work email. Confirm it below and it becomes the
          address you sign in with.</p>
        <p style="margin:0 0 22px">Until you do, keep signing in as
          <b>${esc(p.old_email)}</b> — nothing has changed yet.</p>
        <p style="margin:0 0 22px">
          <a href="${verifyUrl}" style="background:#18345B;color:#fff;text-decoration:none;
             padding:11px 20px;border-radius:6px;display:inline-block;font-weight:600">
            Confirm this address</a>
        </p>
        <p style="margin:0 0 6px;color:#6B7280;font-size:13px">
          This link works once and expires on ${esc(expires)}.</p>
        <p style="margin:0;color:#6B7280;font-size:13px">
          If you were not expecting this, ignore it and tell your HR team — your sign-in
          will not change.</p>
      `),
    );
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('send-email-change-verification: verification email failed:', msg);
    await writeOutcome('failed', msg);
    return json({ sent: false, error: msg });
  }

  // ── 2. The old address — the tripwire ─────────────────────────────────────
  // Best-effort. A bounce here must not stop a legitimate change from being
  // confirmable, so its failure is recorded and not fatal.
  let noticeError: string | null = null;
  if (p.old_email && p.old_email.toLowerCase() !== p.new_email.toLowerCase()) {
    try {
      await send(
        p.old_email,
        'A change to your Prowess sign-in address was requested',
        shell(`
          <p style="margin:0 0 14px">Hello ${esc(p.employee_name)},</p>
          <p style="margin:0 0 14px">Someone updated your work email in Prowess to
            <b>${esc(p.new_email)}</b>. Once that address is confirmed, it will replace
            <b>${esc(p.old_email)}</b> as your sign-in.</p>
          <p style="margin:0 0 14px"><b>You do not need to do anything</b> if you were
            expecting this.</p>
          <p style="margin:0;color:#6B7280;font-size:13px">
            If you were not, contact your HR team now — before ${esc(expires)}, which is when
            the request lapses on its own.</p>
        `),
      );
    } catch (e) {
      noticeError = e instanceof Error ? e.message : String(e);
      console.error('send-email-change-verification: old-address notice failed:', noticeError);
    }
  }

  await writeOutcome('sent', noticeError ? `old-address notice failed: ${noticeError}` : undefined);
  return json({ sent: true, notice_failed: noticeError !== null });
});

function json(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200, headers: { 'Content-Type': 'application/json' },
  });
}

function esc(s: string) {
  return (s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function shell(inner: string) {
  return `<!DOCTYPE html><html><body style="margin:0;padding:0;background:#F3F4F6">
    <table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:28px 14px">
      <table width="560" cellpadding="0" cellspacing="0"
             style="background:#fff;border-radius:10px;overflow:hidden;
                    font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif">
        <tr><td style="background:#18345B;padding:16px 26px;color:#fff;font-weight:700;
                       letter-spacing:.04em">PROWESS</td></tr>
        <tr><td style="padding:26px;color:#111827;font-size:14.5px;line-height:1.6">${inner}</td></tr>
        <tr><td style="padding:14px 26px;background:#F9FAFB;color:#9CA3AF;font-size:12px">
          This message was sent automatically by Prowess. Please do not reply.</td></tr>
      </table>
    </td></tr></table></body></html>`;
}
