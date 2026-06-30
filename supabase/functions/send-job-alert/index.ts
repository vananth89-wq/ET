/**
 * send-job-alert
 *
 * Sends a failure alert email for any background job via Resend.
 * Attaches an Excel report (.xlsx) built server-side from the job's details/errors.
 *
 * Called by:
 *   - process-scheduled-terminations Edge Function (scheduled runs + startup failures)
 *   - JobsAdmin frontend (after manual runNow with failures)
 *
 * Required env vars:
 *   RESEND_API_KEY, EMAIL_FROM
 */

// @deno-types="https://esm.sh/xlsx@0.18.5/types/index.d.ts"
import * as XLSX from 'https://esm.sh/xlsx@0.18.5';

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

interface RowDetail {
  terminated_employee_name?: string;
  terminated_employee_id?:   string;
  affected_employee_name?:   string;
  affected_employee_id?:     string;
  employee_name?:            string;
  employee_id?:              string;
  last_working_date?:        string | null;
  separation_date?:          string | null;
  outcome?:                  string;
  reason?:                   string;
  error?:                    string;
}

interface AlertPayload {
  to:            string;
  job_name:      string;
  job_code:      string;
  run_date:      string;
  total:         number;
  succeeded:     number;
  failed:        number;
  skipped?:      number;
  errors:        Array<{ label: string; error: string }>;
  details?:      RowDetail[];
  error_message?: string;
}

/** Build an Excel workbook as a base64 string */
function buildExcel(payload: AlertPayload): string {
  const { job_name, run_date, total, succeeded, failed, skipped = 0, errors, details, error_message } = payload;

  let rows: Record<string, unknown>[];

  if (details && details.length > 0) {
    // Rich per-row detail (termination job)
    rows = details.map(d => ({
      'Terminated Employee':    d.terminated_employee_name ?? d.employee_name ?? '',
      'Terminated Employee ID': d.terminated_employee_id  ?? d.employee_id   ?? '',
      'Affected Employee':      d.affected_employee_name  ?? '—',
      'Affected Employee ID':   d.affected_employee_id   ?? '—',
      'Last Working Date':      d.last_working_date ?? '',
      'Separation Date':        d.separation_date   ?? '',
      'Outcome':                d.outcome ?? '',
      'Reason / Error':         d.error ?? d.reason ?? '',
    }));
  } else if (errors.length > 0) {
    // Per-row errors without full detail
    rows = errors.map(e => ({
      'Job':      job_name,
      'Run Date': run_date,
      'Item':     e.label,
      'Error':    e.error,
    }));
  } else {
    // Top-level / startup failure — single summary row
    rows = [{
      'Job':            job_name,
      'Run Date':       run_date,
      'Status':         'FAILED',
      'Total':          total,
      'Succeeded':      succeeded,
      'Failed':         failed,
      'Skipped':        skipped,
      'Error':          error_message ?? 'Unknown error',
    }];
  }

  const ws = XLSX.utils.json_to_sheet(rows);
  ws['!cols'] = Object.keys(rows[0] ?? {}).map(() => ({ wch: 24 }));
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, 'Run Report');
  return XLSX.write(wb, { type: 'base64', bookType: 'xlsx' }) as string;
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

  // ── Excel attachment ────────────────────────────────────────────────────────
  let attachments: Array<{ filename: string; content: string }> = [];
  try {
    const base64 = buildExcel(payload);
    const jobSlug = job_name.toLowerCase().replace(/\s+/g, '_');
    attachments = [{ filename: `${jobSlug}_${run_date}.xlsx`, content: base64 }];
  } catch (err) {
    console.error('send-job-alert: Excel build failed', err);
    // Non-fatal — send email without attachment rather than dropping the alert
  }

  // ── HTML body ───────────────────────────────────────────────────────────────
  const topError = error_message
    ? `<p style="background:#FEF2F2;border:1px solid #FECACA;border-radius:6px;padding:10px 14px;color:#DC2626;font-size:13px">${error_message}</p>`
    : '';

  const attachNote = attachments.length > 0
    ? `<p style="margin-top:20px;font-size:12px;color:#9CA3AF">
        The full run report is attached as an Excel file.
       </p>`
    : `<p style="margin-top:20px;font-size:12px;color:#9CA3AF">
        Go to <strong>Admin → Background Jobs</strong> to download the full report.
       </p>`;

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
      ${attachNote}
    </div>`;

  // ── Send via Resend ─────────────────────────────────────────────────────────
  const resendBody: Record<string, unknown> = {
    from:    EMAIL_FROM,
    to,
    subject: `[Prowess] ${job_name} failed — ${failed > 0 ? `${failed} error${failed !== 1 ? 's' : ''}` : 'startup error'} on ${run_date}`,
    html,
  };
  if (attachments.length > 0) resendBody['attachments'] = attachments;

  const res = await fetch('https://api.resend.com/emails', {
    method:  'POST',
    headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body:    JSON.stringify(resendBody),
  });

  if (!res.ok) {
    const err = await res.text();
    console.error('send-job-alert: Resend error', err);
    return json({ ok: false, error: `Resend API error: ${err}` }, 500);
  }

  return json({ ok: true });
});
