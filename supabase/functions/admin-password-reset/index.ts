/**
 * admin-password-reset
 *
 * Edge Function — called directly from the browser (authenticated via Bearer JWT).
 *
 * Supports two modes:
 *   set_password    — Admin sets a temporary password directly. The target user
 *                     is flagged with force_password_change = true in their
 *                     auth user_metadata so they must change it on next login.
 *                     A notification email is sent to the employee.
 *
 *   send_reset_link — Generates a Supabase password-recovery link and emails
 *                     it to the employee via Resend. No force_change flag needed
 *                     since the employee chooses their own password.
 *
 * Security:
 *   1. Bearer JWT is verified and the caller's profile_id extracted.
 *   2. can_reset_password(target_profile_id) RPC validates permission +
 *      privilege escalation guard (cannot reset super-admin or other admins).
 *   3. All actions are logged to admin_password_resets (immutable audit).
 *   4. Notification email always sent to the target employee.
 *
 * Required secrets (set via `supabase secrets set`):
 *   RESEND_API_KEY          — Resend API key
 *   EMAIL_FROM              — Verified sender e.g. "Prowess HR <no-reply@co.com>"
 *   SUPABASE_URL            — Auto-injected
 *   SUPABASE_SERVICE_ROLE_KEY — Auto-injected
 *   APP_BASE_URL            — Optional; used for email deep links
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ─── Types ─────────────────────────────────────────────────────────────────

interface SetPasswordPayload {
  mode:              'set_password';
  target_profile_id: string;
  new_password:      string;
  force_change:      boolean;
}

interface SendResetLinkPayload {
  mode:              'send_reset_link';
  target_profile_id: string;
}

type Payload = SetPasswordPayload | SendResetLinkPayload;

// ─── Entry point ────────────────────────────────────────────────────────────

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405, headers: CORS_HEADERS });
  }

  const supabaseUrl    = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const resendApiKey   = Deno.env.get('RESEND_API_KEY');
  const emailFrom      = Deno.env.get('EMAIL_FROM') ?? 'Prowess HR <no-reply@example.com>';
  const appBaseUrl     = Deno.env.get('APP_BASE_URL') ?? supabaseUrl.replace('.supabase.co', '.vercel.app');

  // Service-role client — bypasses RLS, used for auth admin calls & audit writes
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── 1. Authenticate the caller via Bearer JWT ────────────────────────────
  const authHeader = req.headers.get('Authorization') ?? '';
  const callerJwt  = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!callerJwt) {
    return json({ ok: false, error: 'Missing Authorization header' }, 401);
  }

  // Build a user-scoped client — all RPC calls run as this user
  // SUPABASE_ prefix is reserved; anon key is stored as ANON_KEY
  const anonKey    = Deno.env.get('ANON_KEY') ?? serviceRoleKey;
  const userClient = createClient(supabaseUrl, anonKey, {
    auth:    { persistSession: false },
    global:  { headers: { Authorization: `Bearer ${callerJwt}` } },
  });

  // ── 2. Parse payload ──────────────────────────────────────────────────────
  let payload: Payload;
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: 'Invalid JSON payload' }, 400);
  }

  const { mode, target_profile_id } = payload;
  if (!mode || !target_profile_id) {
    return json({ ok: false, error: 'Missing mode or target_profile_id' }, 400);
  }

  // ── 3. Permission + privilege-escalation check (runs as caller) ──────────
  const { data: checkData, error: checkErr } = await userClient.rpc(
    'can_reset_password',
    { p_target_profile_id: target_profile_id }
  );
  if (checkErr) {
    return json({ ok: false, error: checkErr.message }, 403);
  }
  const check = checkData as {
    ok: boolean; reason?: string;
    target_email: string; target_auth_id: string;
    target_name: string; actor_name: string;
  };
  if (!check.ok) {
    return json({ ok: false, error: check.reason }, 403);
  }

  const { target_email, target_auth_id, target_name, actor_name } = check;

  // Get caller's auth ID for audit log
  const { data: { user: callerUser } } = await adminClient.auth.admin.getUserById(
    // Decode JWT sub claim without a library
    JSON.parse(atob(callerJwt.split('.')[1])).sub
  );
  const actor_id = callerUser?.id ?? null;

  // ── 4. Execute the reset ──────────────────────────────────────────────────
  let success     = false;
  let errorMsg: string | undefined;
  let resetLink: string | undefined;

  if (mode === 'set_password') {
    const { new_password, force_change } = payload as SetPasswordPayload;

    if (!new_password || new_password.length < 8) {
      return json({ ok: false, error: 'Password must be at least 8 characters.' }, 400);
    }

    const { error: updateErr } = await adminClient.auth.admin.updateUserById(
      target_auth_id,
      {
        password:         new_password,
        email_confirm:    true,   // auto-confirm so the user can log in immediately
        user_metadata:    force_change ? { force_password_change: true } : {},
      }
    );

    if (updateErr) {
      errorMsg = updateErr.message;
    } else {
      success = true;
      // Send notification email to the employee
      if (resendApiKey) {
        await sendEmail(resendApiKey, emailFrom, target_email, target_name, appBaseUrl, {
          type:         'set_password',
          force_change,
        });
      }
    }

  } else if (mode === 'send_reset_link') {
    const { data: linkData, error: linkErr } = await adminClient.auth.admin.generateLink({
      type:  'recovery',
      email: target_email,
      options: { redirectTo: `${appBaseUrl}/reset-password` },
    });

    if (linkErr) {
      errorMsg = linkErr.message;
    } else {
      success   = true;
      resetLink = linkData?.properties?.action_link;
      // Send the recovery link via Resend
      if (resendApiKey && resetLink) {
        await sendEmail(resendApiKey, emailFrom, target_email, target_name, appBaseUrl, {
          type:      'reset_link',
          resetLink,
        });
      }
    }
  }

  // ── 5. Write audit record (best-effort — never fails the response) ────────
  try {
    await adminClient.from('admin_password_resets').insert({
      actor_id,
      actor_name,
      target_profile_id,
      target_email,
      target_name,
      action:       mode,
      force_change: mode === 'set_password' ? (payload as SetPasswordPayload).force_change : false,
      success,
      error_message: errorMsg ?? null,
      ip_address:    req.headers.get('x-forwarded-for') ?? null,
    });
  } catch (auditErr) {
    console.error('admin-password-reset: audit write failed', auditErr);
  }

  if (!success) {
    return json({ ok: false, error: errorMsg ?? 'Unknown error' }, 500);
  }

  return json({ ok: true, mode, target_email });
});

// ─── Email sender ────────────────────────────────────────────────────────────

async function sendEmail(
  resendApiKey: string,
  from:         string,
  to:           string,
  name:         string,
  appBaseUrl:   string,
  opts:
    | { type: 'set_password'; force_change: boolean }
    | { type: 'reset_link';   resetLink: string }
): Promise<void> {
  const displayName = name || to;
  let subject: string;
  let bodyHtml: string;

  if (opts.type === 'set_password') {
    subject  = 'Your Prowess HR password has been reset';
    bodyHtml = `
      <p>Hi ${esc(displayName)},</p>
      <p>Your Prowess HR password has been reset by your administrator.</p>
      ${opts.force_change
        ? '<p><strong>You will be asked to set a new password the next time you sign in.</strong></p>'
        : '<p>Your administrator has set a temporary password which they will share with you separately.</p>'
      }
      <p>If you did not expect this change, please contact your HR administrator immediately.</p>
    `;
  } else {
    subject  = 'Reset your Prowess HR password';
    bodyHtml = `
      <p>Hi ${esc(displayName)},</p>
      <p>Your administrator has requested a password reset for your Prowess HR account.</p>
      <p>Click the button below to set a new password. This link expires in 24 hours.</p>
    `;
  }

  const actionButton = opts.type === 'reset_link'
    ? `<table cellpadding="0" cellspacing="0" style="margin:24px 0;">
         <tr><td style="border-radius:8px;background:#2F77B5;">
           <a href="${escAttr(opts.resetLink)}"
              style="display:inline-block;padding:12px 28px;font-size:14px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;">
             Reset My Password →
           </a>
         </td></tr>
       </table>`
    : `<table cellpadding="0" cellspacing="0" style="margin:24px 0;">
         <tr><td style="border-radius:8px;background:#2F77B5;">
           <a href="${escAttr(appBaseUrl)}"
              style="display:inline-block;padding:12px 28px;font-size:14px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;">
             Sign In to Prowess HR →
           </a>
         </td></tr>
       </table>`;

  const html = `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"/><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:#F3F4F6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#F3F4F6;padding:40px 16px;">
    <tr><td align="center">
      <table width="560" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.08);">
        <tr><td style="background:#2F77B5;padding:28px 36px;">
          <span style="font-size:20px;font-weight:700;color:#fff;">💼 Prowess HR</span>
        </td></tr>
        <tr><td style="padding:36px 36px 24px;">
          <h1 style="margin:0 0 16px;font-size:20px;font-weight:700;color:#111827;">${esc(subject)}</h1>
          <div style="font-size:15px;color:#374151;line-height:1.6;">${bodyHtml}</div>
          ${actionButton}
        </td></tr>
        <tr><td style="padding:0 36px;"><hr style="border:none;border-top:1px solid #E5E7EB;margin:0;"/></td></tr>
        <tr><td style="padding:20px 36px 28px;">
          <p style="margin:0;font-size:12px;color:#9CA3AF;">
            This is an automated security notification from Prowess HR.
            If you have concerns, contact your system administrator.
          </p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`;

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${resendApiKey}` },
      body:    JSON.stringify({ from, to: [to], subject, html }),
    });
    if (!res.ok) {
      const txt = await res.text();
      console.error(`admin-password-reset: Resend error ${res.status}: ${txt}`);
    }
  } catch (e) {
    console.error('admin-password-reset: email send failed', e);
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function escAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}
