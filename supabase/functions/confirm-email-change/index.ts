/**
 * confirm-email-change
 *
 * Called from the browser by /verify-email-change with the one-time token from
 * the verification email. UNAUTHENTICATED on purpose: the person confirming has
 * usually not signed in — quite possibly cannot, if they no longer read the old
 * mailbox. The token IS the credential.
 *
 * Which is why the token is not validated here. claim_email_change_token is
 * SECURITY DEFINER, REVOKEd from anon and authenticated, and reachable only with
 * the service-role key that lives in this function's environment. It hashes the
 * token, and returns a row only if one is pending and unexpired. This function
 * never learns whether a token was almost right.
 *
 * Division of labour, deliberately:
 *   Postgres  rules on the token — it owns the pending state and the clock.
 *   This fn    performs the swap — GoTrue owns auth.users, its identities table
 *              and its confirmation timestamps, and a direct UPDATE from SQL
 *              would leave those inconsistent.
 *
 * Required secrets:
 *   SUPABASE_URL               — auto-injected
 *   SUPABASE_SERVICE_ROLE_KEY  — auto-injected
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: CORS });
  if (req.method !== 'POST')    return new Response('Method Not Allowed', { status: 405, headers: CORS });

  let token = '';
  try { token = (await req.json())?.token ?? ''; }
  catch { return json({ ok: false, error: 'Invalid request.' }, 400); }

  if (!token || typeof token !== 'string') {
    return json({ ok: false, error: 'This link is missing its confirmation code.' }, 400);
  }

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  // ── 1. Let the database rule on it ────────────────────────────────────────
  const { data: rows, error: claimErr } = await admin
    .rpc('claim_email_change_token', { p_token: token });

  if (claimErr) {
    console.error('confirm-email-change: claim failed:', claimErr.message);
    return json({ ok: false, error: 'We could not check this link. Please try again.' }, 500);
  }

  const change = Array.isArray(rows) ? rows[0] : rows;
  if (!change) {
    // One message for expired, already-used, superseded and never-existed. The
    // distinctions are only useful to somebody guessing tokens.
    return json({
      ok:    false,
      error: 'This link is no longer valid. It may have already been used, or a newer '
           + 'change may have replaced it. Ask your HR team to send a new one.',
    }, 410);
  }

  // ── 2. Swap the login ─────────────────────────────────────────────────────
  const { error: updErr } = await admin.auth.admin.updateUserById(
    change.profile_id,
    { email: change.new_email, email_confirm: true },
  );

  if (updErr) {
    // Most likely another auth user already holds this address. The pending row
    // is left pending with the reason recorded, so HR can see why it stalled
    // instead of finding a silently dead link.
    console.error('confirm-email-change: updateUserById failed:', updErr.message);
    await admin.rpc('finish_email_change', {
      p_change_id: change.change_id,
      p_error:     updErr.message,
    });
    return json({
      ok:    false,
      error: updErr.message.toLowerCase().includes('already')
        ? 'That address is already in use by another Prowess account. Your HR team will need to resolve it.'
        : 'We could not update the sign-in address. Your HR team has been given the reason.',
    }, 409);
  }

  // ── 3. Close the request ──────────────────────────────────────────────────
  const { error: finErr } = await admin.rpc('finish_email_change', {
    p_change_id: change.change_id,
    p_error:     null,
  });

  if (finErr) {
    // The login HAS moved; only the bookkeeping failed. Saying "it did not work"
    // here would be a lie that sends someone to sign in with the wrong address.
    console.error('confirm-email-change: login updated but row not closed:', finErr.message);
  }

  console.log(`confirm-email-change: login updated for profile ${change.profile_id}`);

  return json({
    ok:            true,
    email:         change.new_email,
    employee_name: change.employee_name,
  });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
