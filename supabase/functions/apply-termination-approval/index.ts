/**
 * apply-termination-approval
 *
 * Called immediately when a termination workflow is fully approved.
 * Responsibility (post mig 532 redesign):
 *   — Pre-insert employment slices (close Active slice, add future Inactive slice)
 *   — Does NOT flip employees.status (stays Active while employee still working)
 *   — Does NOT stamp scheduled_executed (cron owns that after last_working_date)
 *
 * Slice insertion is atomic inside fn_pre_insert_termination_slices (SECURITY
 * DEFINER), avoiding the idx_ee_one_active_row unique-index race window.
 *
 * Called by: ApproverInbox.tsx on final-step approval.
 * Request body: { termination_id: string }
 * Design spec: docs/termination-design.md §5.1 (updated mig 532)
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

  // Atomic slice pre-insertion via SECURITY DEFINER RPC.
  // Works for same-day and future-dated alike. Inactive slice visible in history
  // immediately. employees.status stays Active — cron flips on last_working_date.
  const { data, error } = await admin.rpc('fn_pre_insert_termination_slices', {
    p_termination_id: termination_id,
  });

  if (error) {
    console.error('apply-termination-approval: RPC error', error);
    return json({ ok: false, error: error.message }, 500);
  }

  const result = data as { ok: boolean; skipped?: boolean; reason?: string; error?: string };

  if (!result.ok) {
    console.error('apply-termination-approval: RPC error', result.error);
    return json({ ok: false, error: result.error }, 400);
  }

  console.log('apply-termination-approval:', result.skipped ? `skipped — ${result.reason}` : `slices written for ${termination_id}`);
  return json({ ok: true, termination_id, ...result });
});
