/**
 * process-scheduled-terminations
 *
 * Daily cron Edge Function (00:05 UTC). Post mig 532 redesign:
 *   — Finds APPROVED terminations where last_working_date <= today
 *     AND scheduled_executed = false
 *   — Calls fn_finalize_termination_execution for each:
 *       • Sets employees.status = 'Inactive' (with allow_employment_sync bypass)
 *       • Applies direct_report_reassignments as new employment slices from lwd+1
 *       • Stamps scheduled_executed = true
 *   — Writes a job_run_log row (visible in Admin → Background Jobs)
 *
 * Idempotency: fn_finalize_termination_execution returns skipped if already done.
 * Per-row error isolation: one failure does not abort others.
 *
 * Design spec: docs/termination-design.md §5.3 (updated mig 532)
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL              = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const JOB_CODE = 'process_scheduled_terminations';
const JOB_NAME = 'Process Scheduled Terminations';

/** Translate raw DB/RPC errors into admin-readable messages */
function friendlyError(msg: string): string {
  if (msg.includes('chk_ee_effective_order'))
    return 'This employee\'s employment start date is after the terminated employee\'s Last Working Date. The system updated their manager in-place without creating a history boundary. No action needed — run the job again to retry.';
  if (msg.includes('chk_ep_effective_order'))
    return 'Personal info effective dates are out of order for this employee. Check their employment history in the HR system.';
  if (msg.includes('not found'))
    return 'Termination record not found — it may have been deleted or reversed.';
  if (msg.includes('not APPROVED'))
    return 'Termination is no longer in APPROVED status — it may have been reversed or withdrawn.';
  if (msg.includes('already executed'))
    return 'Already processed in a previous run.';
  return msg;
}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-service-role',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

async function processDueTerminations(triggeredBy: string | null = null) {
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const startedAt = new Date().toISOString();
  const today = new Date().toISOString().slice(0, 10);

  // Insert a 'running' log row
  const { data: logRow } = await admin.from('job_run_log').insert({
    job_code:     JOB_CODE,
    job_name:     JOB_NAME,
    triggered_by: triggeredBy,
    started_at:   startedAt,
    status:       'running',
  }).select('id').single();
  const logId = logRow?.id ?? null;

  type RowDetail = {
    terminated_employee_name: string;
    terminated_employee_id:   string;
    affected_employee_name:   string;
    affected_employee_id:     string;
    last_working_date:        string | null;
    separation_date:          string | null;
    outcome:                  'finalized' | 'skipped' | 'failed';
    reason?:                  string;
    error?:                   string;
    // kept for internal use
    termination_id:           string;
    employee_id:              string;
    employee_name:            string;
  };

  const results = {
    total: 0, succeeded: 0, failed: 0, skipped: 0,
    errors:  [] as Array<{ termination_id: string; employee_name: string; last_working_date: string | null; error: string }>,
    details: [] as RowDetail[],
  };

  try {
    const { data: dueRows, error: fetchErr } = await admin
      .from('employee_terminations')
      .select('id, employee_id, last_working_date, separation_date, employees(name, employee_id)')
      .eq('workflow_status', 'APPROVED')
      .eq('scheduled_executed', false)
      .not('last_working_date', 'is', null)
      .lte('last_working_date', today);

    if (fetchErr) {
      console.error('process-scheduled-terminations: fetch failed', fetchErr);
      await finaliseLog(admin, logId, 'failed', results, fetchErr.message);
      return results;
    }

    if (!dueRows || dueRows.length === 0) {
      console.log('process-scheduled-terminations: no due rows for', today);
      await finaliseLog(admin, logId, 'success', results);
      return results;
    }

    results.total = dueRows.length;
    console.log(`process-scheduled-terminations: ${dueRows.length} rows due for ${today}`);

    for (const row of dueRows) {
      const empName   = (row.employees as { name?: string; employee_id?: string } | null)?.name        ?? 'Unknown';
      const empEmpId  = (row.employees as { name?: string; employee_id?: string } | null)?.employee_id ?? row.employee_id;
      try {
        const { data, error } = await admin.rpc('fn_finalize_termination_execution', {
          p_termination_id: row.id,
        });

        const result = data as { ok: boolean; skipped?: boolean; reason?: string; error?: string } | null;

        if (error || !result?.ok) {
          results.failed++;
          const rawMsg = error?.message ?? result?.error ?? 'Unknown error';
          const drErrors = (result as any)?.dr_errors as Array<{ employee_id: string; employee_name: string; error: string }> | undefined;

          if (drErrors && drErrors.length > 0) {
            // Per-DR errors returned by migration 564+ SAVEPOINT handler
            for (const dr of drErrors) {
              const drMsg = friendlyError(dr.error);
              results.errors.push({ termination_id: row.id, employee_name: `${empName} → ${dr.employee_name}`, last_working_date: row.last_working_date, error: drMsg });
              results.details.push({ termination_id: row.id, employee_id: dr.employee_id, employee_name: `${empName} → ${dr.employee_name}`, terminated_employee_name: empName, terminated_employee_id: empEmpId, affected_employee_name: dr.employee_name, affected_employee_id: dr.employee_id, last_working_date: row.last_working_date, separation_date: row.separation_date, outcome: 'failed', error: drMsg });
              console.error(`process-scheduled-terminations: ${row.id} DR ${dr.employee_name} failed:`, drMsg);
            }
          } else if (rawMsg.includes('chk_ee_effective_order') || rawMsg.includes('effective_order')) {
            // DB-level constraint — fetch direct reports to build per-employee detail
            const { data: termData } = await admin
              .from('employee_terminations')
              .select('direct_report_reassignments')
              .eq('id', row.id)
              .single();

            const reassignments = (termData?.direct_report_reassignments ?? []) as Array<{
              employee_id: string; employee_name?: string; new_manager_id?: string; new_manager_name?: string;
            }>;

            if (reassignments.length > 0) {
              const drIds = reassignments.map(r => r.employee_id);

              // Fetch names + employee numbers
              const { data: empRows } = await admin
                .from('employees')
                .select('id, name, employee_id')
                .in('id', drIds);

              // Fetch current open employment slice for each DR
              const { data: slices } = await admin
                .from('employee_employment')
                .select('employee_id, effective_from, effective_to')
                .in('employee_id', drIds)
                .eq('effective_to', '9999-12-31')
                .eq('is_active', true);

              const empMap   = Object.fromEntries((empRows  ?? []).map(e => [e.id, e]));
              const sliceMap = Object.fromEntries((slices   ?? []).map(s => [s.employee_id, s]));

              for (const r of reassignments) {
                const emp     = empMap[r.employee_id];
                const slice   = sliceMap[r.employee_id];
                const drName  = emp?.name ?? r.employee_name ?? r.employee_id;
                const drEmpId = emp?.employee_id ?? r.employee_id;
                const drMsg   = slice
                  ? `Employment starts ${slice.effective_from} which is after the Last Working Date ${row.last_working_date}. Cannot close the employment record at LWD. Action: correct the employment start date or the Last Working Date.`
                  : `Employment record conflict — could not apply manager reassignment. Check employment history for this employee.`;
                results.errors.push({ termination_id: row.id, employee_name: `${empName} → ${drName}`, last_working_date: row.last_working_date, error: drMsg });
                results.details.push({ termination_id: row.id, employee_id: drEmpId, employee_name: `${empName} → ${drName}`, terminated_employee_name: empName, terminated_employee_id: empEmpId, affected_employee_name: drName, affected_employee_id: drEmpId, last_working_date: row.last_working_date, separation_date: row.separation_date, outcome: 'failed', error: drMsg });
              }
            } else {
              const msg = friendlyError(rawMsg);
              results.errors.push({ termination_id: row.id, employee_name: empName, last_working_date: row.last_working_date, error: msg });
              results.details.push({ termination_id: row.id, employee_id: row.employee_id, employee_name: empName, terminated_employee_name: empName, terminated_employee_id: empEmpId, affected_employee_name: '—', affected_employee_id: '—', last_working_date: row.last_working_date, separation_date: row.separation_date, outcome: 'failed', error: msg });
            }
            console.error(`process-scheduled-terminations: ${row.id} effective_order constraint:`, rawMsg);
          } else {
            const msg = friendlyError(rawMsg);
            results.errors.push({ termination_id: row.id, employee_name: empName, last_working_date: row.last_working_date, error: msg });
            results.details.push({ termination_id: row.id, employee_id: row.employee_id, employee_name: empName, terminated_employee_name: empName, terminated_employee_id: empEmpId, affected_employee_name: '—', affected_employee_id: '—', last_working_date: row.last_working_date, separation_date: row.separation_date, outcome: 'failed', error: msg });
            console.error(`process-scheduled-terminations: ${row.id} failed:`, msg);
          }
        } else if (result.skipped) {
          results.skipped++;
          results.details.push({ termination_id: row.id, employee_id: row.employee_id, employee_name: empName, terminated_employee_name: empName, terminated_employee_id: empEmpId, affected_employee_name: '—', affected_employee_id: '—', last_working_date: row.last_working_date, separation_date: row.separation_date, outcome: 'skipped', reason: result.reason });
          console.log(`process-scheduled-terminations: ${row.id} skipped:`, result.reason);
        } else {
          results.succeeded++;
          results.details.push({ termination_id: row.id, employee_id: row.employee_id, employee_name: empName, terminated_employee_name: empName, terminated_employee_id: empEmpId, affected_employee_name: '—', affected_employee_id: '—', last_working_date: row.last_working_date, separation_date: row.separation_date, outcome: 'finalized' });
          console.log(`process-scheduled-terminations: ${row.id} finalized`);
        }
      } catch (err) {
        results.failed++;
        const msg = (err as Error).message;
        results.errors.push({ termination_id: row.id, employee_name: empName, last_working_date: row.last_working_date, error: msg });
        results.details.push({ termination_id: row.id, employee_id: row.employee_id, employee_name: empName, last_working_date: row.last_working_date, separation_date: row.separation_date, outcome: 'failed', error: msg });
        console.error(`process-scheduled-terminations: ${row.id} threw:`, err);
      }
    }

    const status = results.failed > 0 && results.succeeded === 0
      ? 'failed'
      : results.failed > 0
      ? 'partial'
      : 'success';

    await finaliseLog(admin, logId, status, results);
    if (results.failed > 0) await sendFailureEmail(admin, results);
  } catch (err) {
    await finaliseLog(admin, logId, 'failed', results, (err as Error).message);
    if (results.failed > 0) await sendFailureEmail(admin, results);
  }

  console.log('process-scheduled-terminations: summary', results);
  return results;
}

async function finaliseLog(
  admin: ReturnType<typeof createClient>,
  logId: string | null,
  status: string,
  results: { total: number; succeeded: number; failed: number; skipped: number; errors: Array<{ termination_id: string; employee_name: string; last_working_date: string | null; error: string }>; details?: unknown[] },
  errorMessage?: string,
) {
  if (!logId) return;
  const completedAt = new Date().toISOString();
  await admin.from('job_run_log').update({
    completed_at:   completedAt,
    status,
    rows_processed: results.succeeded,
    summary: {
      total:     results.total,
      succeeded: results.succeeded,
      skipped:   results.skipped,
      failed:    results.failed,
      errors:    results.errors.length > 0 ? results.errors : undefined,
      details:   results.details && results.details.length > 0 ? results.details : undefined,
    },
    error_message: errorMessage ?? null,
  }).eq('id', logId);
}

async function sendFailureEmail(
  admin: ReturnType<typeof createClient>,
  results: { total: number; succeeded: number; failed: number; skipped: number; errors: Array<{ employee_name: string; last_working_date: string | null; error: string }> },
) {
  const { data: cfg } = await admin
    .from('app_config')
    .select('value')
    .eq('key', 'process_scheduled_terminations_notification_email')
    .single();

  const to = cfg?.value as string | undefined;
  if (!to) return;

  const alertPayload = {
    to,
    job_name:  'Process Scheduled Terminations',
    job_code:  'process_scheduled_terminations',
    run_date:  new Date().toISOString().slice(0, 10),
    total:     results.total,
    succeeded: results.succeeded,
    failed:    results.failed,
    skipped:   results.skipped,
    errors:    results.errors.map(e => ({ label: e.employee_name, error: e.error })),
  };

  await fetch(`${SUPABASE_URL}/functions/v1/send-job-alert`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json', 'x-service-role': 'true' },
    body:    JSON.stringify(alertPayload),
  });
}

// HTTP handler — triggered by pg_cron (daily 00:05 UTC) or manually via Run Now
Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') return json({ ok: false, error: 'Method Not Allowed' }, 405);

  const isServiceCall = req.headers.get('x-service-role') === 'true';
  const authHeader    = req.headers.get('Authorization') ?? '';
  if (!isServiceCall && !authHeader.startsWith('Bearer ')) {
    return json({ ok: false, error: 'Unauthorized' }, 401);
  }

  let triggeredBy: string | null = null;
  try {
    const body = await req.json().catch(() => ({}));
    triggeredBy = body?.triggered_by ?? null;
  } catch { /* ignore */ }

  const results = await processDueTerminations(triggeredBy);
  return json({ ok: true, ...results });
});
