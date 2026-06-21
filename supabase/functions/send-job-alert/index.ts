/**
 * send-job-alert
 *
 * Sends a failure alert email for any background job via Resend.
 * Called by:
 *   - process-scheduled-terminations Edge Function (scheduled runs)
 *   - JobsAdmin frontend (after manual runNow with failures)
 *
 * Required env vars (shared with send-notification-email):
 *   RESEND_API_KEY, EMAIL_FROM
 */

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const EMAIL_FROM     = Deno.env.get('EMAIL_FROM');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-service-role',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

interface AlertPayload {
  to:        string;
  job_name:  string;
  job_code:  string;
  run_date:  string;   // ISO date string
  total:     number;
  succeeded: number;
  failed:    number;
  skipped?:  number;
  errors:    Array<{ label: string; error: string }>;  // label = employee name or item descriptor
  error_message?: string;  // top-level job error (non-per-row)
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST')   return json({ ok: false, error: 'Method Not Allowed' }, 405);

  const isServiceCall = req.headers.get('x-service-role') === 'true';
  const authHeader    = req.headers.get('Authorization') ?? '';
  if (!isServiceCall && !authHeader.startsWith('Bearer ')) {
    return json({ ok: false, error: 'Unauthorized' }, 401);
  }

  if (!RESEND_API_KEY || !EMAIL_FROM) {
    return json({ ok: false, error: 'Email not configured (RESEND_API_KEY / EMAIL_FROM missing)' }, 500);
  }

  let payload: AlertPayload;
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: 'Invalid JSON' }, 400);
  }

  const { to, job_name, run_date, total, succeeded, failed, skipped = 0, errors, error_message } = payload;
  if (!to || !job_name) return json({ ok: false, error: 'Missing required fields: to, job_name' }, 400);

  const errorRows = errors.map(e => `
    <tr>
      <td style="padding:8px 12px;border-bottom:1px solid #E5E7EB">${e.label}</td>
      <td style="padding:8px 12px;border-bottom:1px solid #E5E7EB;color:#DC2626">${e.error}</td>
    </tr>`).join('');

  const tableBlock = errors.length > 0 ? `
    <table style="width:100%;border-collapse:collapse;margin-top:16px;font-size:13px">
      <thead>
        <tr style="background:#F9FAFB">
          <th style="padding:8px 12px;text-align:left;border-bottom:2px solid #E5E7EB">Item</th>
          <th style="padding:8px 12px;text-align:left;border-bottom:2px solid #E5E7EB">Error</th>
        </tr>
      </thead>
      <tbody>${errorRows}</tbody>
    </table>` : '';

  const topError = error_message
    ? `<p style="background:#FEF2F2;border:1px solid #FECACA;border-radius:6px;padding:10px 14px;color:#DC2626;font-size:13px">${error_message}</p>`
    : '';

  const html = `
    <div style="font-family:sans-serif;max-width:640px;margin:0 auto">
      <h2 style="color:#18345B">⚠️ ${job_name} — ${failed} failure${failed !== 1 ? 's' : ''}</h2>
      <p style="color:#6B7280">The job ran on <strong>${run_date}</strong> and completed with errors.</p>
      <div style="display:flex;gap:24px;margin:16px 0">
        <div style="text-align:center">
          <div style="font-size:24px;font-weight:800;color:#16A34A">${succeeded}</div>
          <div style="font-size:11px;color:#6B7280">Succeeded</div>
        </div>
        <div style="text-align:center">
          <div style="font-size:24px;font-weight:800;color:#DC2626">${failed}</div>
          <div style="font-size:11px;color:#6B7280">Failed</div>
        </div>
        ${skipped > 0 ? `<div style="text-align:center">
          <div style="font-size:24px;font-weight:800;color:#6B7280">${skipped}</div>
          <div style="font-size:11px;color:#6B7280">Skipped</div>
        </div>` : ''}
        <div style="text-align:center">
          <div style="font-size:24px;font-weight:800;color:#111827">${total}</div>
          <div style="font-size:11px;color:#6B7280">Total</div>
        </div>
      </div>
      ${topError}
      ${tableBlock}
      <p style="margin-top:20px;font-size:12px;color:#9CA3AF">
        Go to <strong>Admin → Background Jobs</strong> to download the full Excel report.
      </p>
    </div>`;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from:    EMAIL_FROM,
      to,
      subject: `[Prowess] ${job_name} failed — ${failed} error${failed !== 1 ? 's' : ''} on ${run_date}`,
      html,
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    console.error('send-job-alert: Resend error', err);
    return json({ ok: false, error: `Resend API error: ${err}` }, 500);
  }

  return json({ ok: true });
});
