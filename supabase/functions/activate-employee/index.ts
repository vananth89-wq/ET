/**
 * activate-employee
 *
 * Server-side employee activation. Replaces the client-side
 * `supabase.auth.signInWithOtp()` magic-link flow with a proper
 * password-recovery flow.
 *
 * Sequence:
 *   1. Verify caller JWT + permission (hire_employee.edit OR super admin)
 *   2. Look up the employee's business_email
 *   3. Create auth.users row via admin API (if not exists)
 *      → handle_new_user trigger fires: creates profile, links to
 *        employee, grants ESS, stamps invite_accepted_at, marks
 *        employee_invites row as accepted
 *   4. Belt+suspenders: call link_profile_to_employee in case trigger
 *      is missing on target env
 *   5. Generate a Supabase password-recovery link
 *   6. Email the link via Resend (uses the recovery template style —
 *      "Set your Prowess password", not "magic link")
 *   7. Return outcome to the client
 *
 * On failure: caller (client) should call mark_invite_failed RPC.
 *
 * Required secrets (set via `supabase secrets set`):
 *   RESEND_API_KEY             — Resend API key
 *   EMAIL_FROM                 — "Prowess HR <no-reply@..>"
 *   APP_BASE_URL               — Public URL for the app (dev.prowessapp.net, etc.)
 *   SUPABASE_URL               — Auto-injected
 *   SUPABASE_SERVICE_ROLE_KEY  — Auto-injected
 *   ANON_KEY                   — Anon key (SUPABASE_ prefix is reserved)
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ─── Types ─────────────────────────────────────────────────────────────────

interface Payload {
  employee_id: string;
}

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
  const appBaseUrl     = Deno.env.get('APP_BASE_URL') ?? 'https://dev.prowessapp.net';
  const anonKey        = Deno.env.get('ANON_KEY')
                        ?? Deno.env.get('SUPABASE_ANON_KEY')
                        ?? serviceRoleKey;

  // Service-role client for admin operations
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── 1. Authenticate the caller ──────────────────────────────────────────
  const authHeader = req.headers.get('Authorization') ?? '';
  const callerJwt  = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!callerJwt) {
    return json({ ok: false, error: 'Missing Authorization header' }, 401);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    auth:   { persistSession: false },
    global: { headers: { Authorization: `Bearer ${callerJwt}` } },
  });

  // ── 2. Parse payload ─────────────────────────────────────────────────────
  let payload: Payload;
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: 'Invalid JSON payload' }, 400);
  }

  const { employee_id } = payload;
  if (!employee_id) {
    return json({ ok: false, error: 'Missing employee_id' }, 400);
  }

  // ── 3. Permission check (runs as caller) ─────────────────────────────────
  //     Allow: super admin OR user_can('hire_employee', 'edit')
  const { data: superOk }  = await userClient.rpc('is_super_admin');
  let allowed = superOk === true;

  if (!allowed) {
    const { data: hireOk } = await userClient.rpc('user_can', {
      p_module_code: 'hire_employee',
      p_action:      'edit',
      p_dept_id:     null,
    });
    allowed = hireOk === true;
  }

  if (!allowed) {
    return json({ ok: false, error: 'Insufficient permissions to activate employees' }, 403);
  }

  // ── 4. Load employee ─────────────────────────────────────────────────────
  const { data: emp, error: empErr } = await adminClient
    .from('employees')
    .select('id, name, business_email, status')
    .eq('id', employee_id)
    .maybeSingle();

  if (empErr || !emp) {
    return json({ ok: false, error: 'Employee not found' }, 404);
  }
  if (!emp.business_email) {
    return json({ ok: false, error: 'Employee has no business_email' }, 400);
  }
  if (emp.status !== 'Active') {
    return json({ ok: false, error: `Employee status is ${emp.status}, not Active` }, 400);
  }

  // ── 5. Check if auth user already exists ─────────────────────────────────
  //     Supabase JS v2 has no getUserByEmail — list + filter is the pattern.
  const { data: existingList } = await adminClient.auth.admin.listUsers({
    page: 1, perPage: 200,
  });
  const existing = existingList?.users.find(
    u => (u.email ?? '').toLowerCase() === emp.business_email.toLowerCase()
  );

  let createdNow = false;
  if (!existing) {
    // Create with a throwaway password — user will set their own via recovery link
    const throwaway = crypto.randomUUID() + crypto.randomUUID();
    const { error: createErr } = await adminClient.auth.admin.createUser({
      email:         emp.business_email,
      password:      throwaway,
      email_confirm: true, // skip confirmation email; recovery link handles login
      user_metadata: { full_name: emp.name },
    });
    if (createErr) {
      return json({ ok: false, error: `Failed to create auth user: ${createErr.message}` }, 500);
    }
    createdNow = true;
    // handle_new_user trigger has already fired: profile + link + ESS all done
  }

  // ── 6. Belt+suspenders: ensure profile is linked ─────────────────────────
  //      (In case handle_new_user trigger is missing on target env.)
  await adminClient.rpc('link_profile_to_employee', { p_email: emp.business_email });

  // ── 7. Generate recovery link ────────────────────────────────────────────
  const { data: linkData, error: linkErr } = await adminClient.auth.admin.generateLink({
    type:  'recovery',
    email: emp.business_email,
    options: { redirectTo: `${appBaseUrl}/reset-password` },
  });

  if (linkErr || !linkData?.properties?.action_link) {
    return json(
      { ok: false, error: `Failed to generate recovery link: ${linkErr?.message ?? 'no link returned'}` },
      500
    );
  }

  const recoveryLink = linkData.properties.action_link;

  // ── 8. Send the email via Resend ─────────────────────────────────────────
  let emailSent = false;
  let emailErr: string | undefined;
  if (resendApiKey) {
    const result = await sendActivationEmail({
      resendApiKey,
      from:         emailFrom,
      to:           emp.business_email,
      name:         emp.name ?? emp.business_email,
      recoveryLink,
      appBaseUrl,
    });
    emailSent = result.ok;
    emailErr  = result.error;
  } else {
    emailErr = 'RESEND_API_KEY not configured';
  }

  return json({
    ok:            emailSent,
    created_user:  createdNow,
    email_sent:    emailSent,
    email_error:   emailErr,
    recipient:     emp.business_email,
    // recoveryLink omitted from response for security
  });
});

// ─── Email sender ────────────────────────────────────────────────────────────

async function sendActivationEmail(opts: {
  resendApiKey: string;
  from:         string;
  to:           string;
  name:         string;
  recoveryLink: string;
  appBaseUrl:   string;
}): Promise<{ ok: boolean; error?: string }> {
  const { resendApiKey, from, to, name, recoveryLink, appBaseUrl } = opts;
  const subject = 'Set your Prowess password to activate your account';
  const displayName = name || to;

  const html = `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"/><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:#F3F4F6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#F3F4F6;padding:40px 16px;">
    <tr><td align="center">
      <table width="560" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.08);">
        <tr><td style="background:#1E3A5F;padding:28px 36px;">
          <span style="font-size:20px;font-weight:700;color:#fff;">Prowess HR</span>
        </td></tr>
        <tr><td style="padding:36px 36px 8px;">
          <h1 style="margin:0 0 16px;font-size:22px;font-weight:700;color:#111827;">Welcome, ${esc(displayName)}!</h1>
          <div style="font-size:15px;color:#374151;line-height:1.6;">
            <p style="margin:0 0 12px;">Your Prowess HR account has been created.</p>
            <p style="margin:0 0 12px;">To activate it, click the button below to set your password. Once done you'll be able to sign in with your email and the password you choose.</p>
          </div>
          <table cellpadding="0" cellspacing="0" style="margin:28px 0;">
            <tr><td style="border-radius:8px;background:#1E3A5F;">
              <a href="${escAttr(recoveryLink)}"
                 style="display:inline-block;padding:14px 32px;font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;">
                Set My Password &rarr;
              </a>
            </td></tr>
          </table>
          <div style="font-size:13px;color:#6B7280;line-height:1.6;">
            <p style="margin:0 0 6px;">This link expires in 24 hours and can only be used once.</p>
            <p style="margin:0;">If you did not expect this email, please ignore it or contact your HR administrator.</p>
          </div>
        </td></tr>
        <tr><td style="padding:0 36px;"><hr style="border:none;border-top:1px solid #E5E7EB;margin:0;"/></td></tr>
        <tr><td style="padding:20px 36px 28px;">
          <p style="margin:0;font-size:12px;color:#9CA3AF;">
            After setting your password, sign in at
            <a href="${escAttr(appBaseUrl)}" style="color:#1E3A5F;">${esc(appBaseUrl)}</a>.
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
      console.error(`activate-employee: Resend error ${res.status}: ${txt}`);
      return { ok: false, error: `Resend ${res.status}: ${txt}` };
    }
    return { ok: true };
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    console.error('activate-employee: email send failed', msg);
    return { ok: false, error: msg };
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
