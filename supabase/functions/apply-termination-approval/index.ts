/**
 * apply-termination-approval
 *
 * Called immediately when a termination workflow is fully approved.
 *
 * Two-phase execution:
 *
 * Phase 1 — always runs on approval (regardless of date):
 *   fn_pre_insert_termination_slices
 *     • Closes the Active employment slice at last_working_date
 *     • Inserts the LWD+1 Inactive marker slice
 *     • employees.status stays Active (employee still working)
 *
 * Phase 2 — runs immediately on approval when last_working_date <= today:
 *   fn_finalize_termination_execution
 *     • Sets employees.status = 'Inactive'
 *     • Applies direct report manager reassignments
 *     • Stamps scheduled_executed = true
 *
 *   For future-dated terminations, Phase 2 is deferred to the daily
 *   process-scheduled-terminations cron (00:05 UTC) which runs
 *   fn_finalize_termination_execution on the last_working_date.
 *
 * Both RPCs are idempotent — safe to call multiple times.
 *
 * Called by: ApproverInbox.tsx on final-step approval.
 * Request body: { termination_id: string }
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-service-role',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'Method Not Allowed' }, 405);

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const isServiceCall = req.headers.get('x-service-role') === 'true';
  if (!isServiceCall) {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ ok: false, error: 'Unauthorized' }, 401);
  }

  let body: { termination_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: 'Invalid JSON body' }, 400);
  }

  const { termination_id } = body;
  if (!termination_id) return json({ ok: false, error: 'termination_id is required' }, 400);

  // ── Phase 1: Pre-insert employment slices ─────────────────────────────────
  // Always runs on approval. Closes Active slice + inserts LWD+1 Inactive marker.
  const { data: sliceData, error: sliceError } = await admin.rpc(
    'fn_pre_insert_termination_slices',
    { p_termination_id: termination_id },
  );

  if (sliceError) {
    console.error('apply-termination-approval: fn_pre_insert_termination_slices error', sliceError);
    return json({ ok: false, error: sliceError.message }, 500);
  }

  const sliceResult = sliceData as { ok: boolean; skipped?: boolean; reason?: string; error?: string; lwd?: string };

  if (!sliceResult.ok) {
    console.error('apply-termination-approval: slice RPC returned not-ok', sliceResult.error);
    return json({ ok: false, error: sliceResult.error }, 400);
  }

  console.log(
    'apply-termination-approval: slices',
    sliceResult.skipped ? `skipped — ${sliceResult.reason}` : `written (lwd: ${sliceResult.lwd})`,
  );

  // ── Phase 2: Finalize immediately if LWD <= today ─────────────────────────
  // For backdated or same-day terminations, run fn_finalize_termination_execution
  // now rather than waiting for the next cron at 00:05 UTC.
  // For future-dated, the cron handles it on the last_working_date.
  const today = new Date().toISOString().slice(0, 10);
  const lwd   = sliceResult.lwd ?? null;

  if (lwd && lwd <= today) {
    console.log(`apply-termination-approval: LWD ${lwd} <= today ${today} — running finalize immediately`);

    const { data: finalizeData, error: finalizeError } = await admin.rpc(
      'fn_finalize_termination_execution',
      { p_termination_id: termination_id },
    );

    if (finalizeError) {
      // Non-fatal: slices are already written. Cron will retry finalize.
      console.error('apply-termination-approval: fn_finalize_termination_execution error', finalizeError);
      return json({
        ok:       true,
        termination_id,
        slices:   sliceResult,
        finalize: { ok: false, error: finalizeError.message, note: 'cron will retry' },
      });
    }

    const finalizeResult = finalizeData as { ok: boolean; skipped?: boolean; reason?: string; error?: string; dr_errors?: unknown[] };

    console.log(
      'apply-termination-approval: finalize',
      finalizeResult.skipped
        ? `skipped — ${finalizeResult.reason}`
        : finalizeResult.ok
        ? 'done'
        : `failed — ${finalizeResult.error}`,
    );

    return json({
      ok:            true,
      termination_id,
      slices:        sliceResult,
      finalize:      finalizeResult,
      immediate:     true,
    });
  }

  // Future-dated: Phase 2 deferred to cron
  console.log(`apply-termination-approval: LWD ${lwd} is future-dated — finalize deferred to cron`);
  return json({
    ok:            true,
    termination_id,
    slices:        sliceResult,
    immediate:     false,
    note:          `finalize deferred — cron will run on ${lwd}`,
  });
});
