/**
 * bulk-export-generator
 *
 * Synchronous Edge Function — streams a CSV export for the selected template.
 *
 * Flow:
 *   1. Auth + permission check (bulk_export on the template's module)
 *   2. Read template registry row (exporter_query / history_exporter_query)
 *   3. Execute the query via service-role client
 *   4. Filter columns per schema_definition + toggles
 *   5. Stream UTF-8 BOM CSV to client
 *
 * Request body:
 *   { template_code, mode: 'current' | 'history',
 *     include_inactive?: boolean, include_system_metadata?: boolean }
 *
 * Response: text/csv download
 *
 * Design spec: docs/bulk-operations-framework.md §10
 */

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

interface ColumnDef {
  name: string;
  data_type: string;
  mandatory: boolean;
  user_fillable: boolean;
  include_with_system_metadata?: boolean;
}

interface SchemaDefinition {
  columns: ColumnDef[];
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405, headers: CORS });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // ── Auth ──────────────────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return new Response('Unauthorized', { status: 401, headers: CORS });

  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return new Response('Unauthorized', { status: 401, headers: CORS });

  // ── Parse body ────────────────────────────────────────────────────────────
  let body: {
    template_code: string;
    mode: 'current' | 'history';
    include_inactive?: boolean;
    include_system_metadata?: boolean;
  };
  try { body = await req.json(); }
  catch { return new Response('Invalid JSON', { status: 400, headers: CORS }); }

  const {
    template_code,
    mode = 'current',
    include_inactive = false,
    include_system_metadata = false,
  } = body;

  if (!template_code) return new Response('template_code required', { status: 400, headers: CORS });

  // ── Load template ─────────────────────────────────────────────────────────
  const { data: tpl } = await supabase
    .from('bulk_template_registry')
    .select('*')
    .eq('template_code', template_code)
    .single();

  if (!tpl) return new Response('Template not found', { status: 404, headers: CORS });

  // ── Fast-fail permission check ────────────────────────────────────────────
  // bulk_export RPC enforces auth internally; this pre-check avoids a round-trip
  // to the DB for clearly unauthorised requests.
  const [mod, act] = tpl.permission_export.split('.');
  const { data: canExport } = await userClient.rpc('user_can', {
    p_module: mod, p_action: act, p_owner: null,
  });
  if (!canExport) return new Response('Permission denied', { status: 403, headers: CORS });

  // ── Run export via the single bulk_export RPC (mig 377) ──────────────────
  // The RPC handles all 15 templates with hardcoded CASE clauses.
  // It enforces per-template auth internally and returns SETOF JSONB.
  // JSON keys match schema_definition column names — column order applied below.
  const { data: rows, error: qErr } = await userClient.rpc('bulk_export', {
    p_template_code:    template_code,
    p_include_inactive: include_inactive,
    p_mode:             mode,
  });

  if (qErr) {
    console.error('bulk-export-generator rpc error', qErr);
    const status = qErr.code === '42501' ? 403 : 500;
    return new Response(`Export failed: ${qErr.message}`, { status, headers: CORS });
  }

  // ── Column selection ──────────────────────────────────────────────────────
  const schema: SchemaDefinition = tpl.schema_definition;
  const exportColumns = schema.columns.filter(col => {
    if (col.user_fillable) return true;
    if (include_system_metadata && col.include_with_system_metadata) return true;
    return false;
  });

  const headers = exportColumns.map(c => c.name);

  // ── Build CSV ─────────────────────────────────────────────────────────────
  const lines: string[] = [];

  // History header comment
  if (mode === 'history') {
    lines.push('# This export contains historical slices and is NOT round-trip safe.');
  }

  lines.push(toCsvRow(headers));

  for (const row of (rows ?? [])) {
    const cells = headers.map(h => {
      const val = row[h];
      return val == null ? '' : String(val);
    });
    lines.push(toCsvRow(cells));
  }

  const csvBody = lines.join('\r\n');
  const date = new Date().toISOString().slice(0, 10);
  const filename = `${template_code}_export_${mode}_${date}.csv`;

  // UTF-8 BOM prefix
  const bom = '﻿';

  return new Response(bom + csvBody, {
    headers: {
      ...CORS,
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="${filename}"`,
    },
  });
});

// ─── Helpers ──────────────────────────────────────────────────────────────────

function toCsvRow(cells: string[]): string {
  return cells.map(cell => {
    const s = String(cell ?? '').trim();
    if (s.includes(',') || s.includes('"') || s.includes('\n') || s.includes('\r')) {
      return '"' + s.replace(/"/g, '""') + '"';
    }
    return s;
  }).join(',');
}
