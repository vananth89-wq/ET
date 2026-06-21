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

  try {
    const admin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    );

    const body = await req.json().catch(() => ({}));
    const reversal_id: string | undefined = body?.reversal_id;
    if (!reversal_id) return json({ ok: false, error: 'reversal_id is required' }, 400);

    const { data, error } = await admin.rpc('fn_revert_termination_execution', {
      p_reversal_id: reversal_id,
    });

    if (error) {
      console.error('fn_revert_termination_execution error:', JSON.stringify(error));
      return json({ ok: false, error: error.message }, 500);
    }

    console.log('apply-termination-reversal result:', JSON.stringify(data));
    return json({ ok: true, ...data });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('apply-termination-reversal unhandled:', msg);
    return json({ ok: false, error: msg }, 500);
  }
});
