/**
 * bulk-template-generator
 *
 * Synchronous Edge Function — generates a .zip containing:
 *   <template_code>_template.csv   — header-only CSV (user_fillable columns)
 *   README.txt                     — format rules, column table, picklist refs
 *
 * Flow:
 *   1. Auth + bulk_import permission check
 *   2. Load template registry row
 *   3. Build template CSV (user_fillable columns, mandatory suffixed with *)
 *   4. Resolve picklist reference tables for code_picklist:* columns
 *   5. Build README.txt
 *   6. ZIP both files and return as application/zip
 *
 * Request body: { template_code: string }
 * Response:     application/zip download
 *
 * Design spec: docs/bulk-operations-framework.md §9, §12
 */

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { zip } from 'https://esm.sh/fflate@0.8';

interface ColumnDef {
  name: string;
  data_type: string;
  mandatory: boolean;
  user_fillable: boolean;
  description?: string;
  include_with_system_metadata?: boolean;
}

interface SchemaDefinition {
  columns: ColumnDef[];
  natural_key: string[];
  row_processor: string;
  group_by?: string[];
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
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
  let body: { template_code: string };
  try { body = await req.json(); }
  catch { return new Response('Invalid JSON', { status: 400, headers: CORS }); }

  const { template_code } = body;
  if (!template_code) return new Response('template_code required', { status: 400, headers: CORS });

  // ── Load template ─────────────────────────────────────────────────────────
  const { data: tpl } = await supabase
    .from('bulk_template_registry')
    .select('*')
    .eq('template_code', template_code)
    .single();

  if (!tpl) return new Response('Template not found', { status: 404, headers: CORS });

  // ── Permission check ──────────────────────────────────────────────────────
  const [module, action] = tpl.permission_import.split('.');
  const { data: canImport } = await userClient.rpc('user_can', {
    p_module: module, p_action: action, p_owner: null,
  });
  if (!canImport) return new Response('Permission denied', { status: 403, headers: CORS });

  const schema: SchemaDefinition = tpl.schema_definition;
  const userCols = schema.columns.filter(c => c.user_fillable);
  const now = new Date().toISOString().slice(0, 16).replace('T', ' ') + ' UTC';

  // ── Build template CSV ────────────────────────────────────────────────────
  const templateHeader = userCols.map(c => c.name).join(',');
  const templateCsv = '﻿' + templateHeader + '\r\n'; // BOM + header only, no data rows

  // ── Resolve picklist reference tables ─────────────────────────────────────
  const picklistSections: string[] = [];
  for (const col of userCols) {
    // schema seeds use 'picklist:NAME'; legacy seeds may use 'code_picklist:NAME' — handle both
    const isPicklist = col.data_type.startsWith('picklist:') || col.data_type.startsWith('code_picklist:');
    if (!isPicklist) continue;
    const picklistId = col.data_type.startsWith('picklist:')
      ? col.data_type.slice('picklist:'.length)
      : col.data_type.slice('code_picklist:'.length);

    const { data: values } = await supabase
      .from('picklist_values')
      .select('ref_id, value')
      .eq('picklist_id', picklistId)  // if it's a UUID; if it's a code, adjust
      .eq('active', true)
      .order('ref_id');

    // Also try lookup by picklist name (JOB_RELATIONSHIP_TYPE etc.)
    // The data_type stores the picklist name, not UUID, so look up via picklists.id
    // We'll try both: UUID parse then name lookup
    let resolvedValues = values;
    if (!resolvedValues || resolvedValues.length === 0) {
      // Try looking up picklist by UUID stored as template name
      const { data: pl } = await supabase
        .from('picklists')
        .select('id')
        .eq('id', picklistId)
        .single();

      if (pl) {
        const { data: v2 } = await supabase
          .from('picklist_values')
          .select('ref_id, value')
          .eq('picklist_id', pl.id)
          .eq('active', true)
          .order('ref_id');
        resolvedValues = v2;
      }
    }

    if (resolvedValues && resolvedValues.length > 0) {
      const colTitle = col.name.replace(/\s*\*$/, '').trim();
      picklistSections.push(
        `${picklistId} picklist — use ref_id in the "${colTitle}" column:\n` +
        `${'─'.repeat(55)}\n` +
        `| ref_id${' '.repeat(14)} | Label${' '.repeat(30)} |\n` +
        `| ${'─'.repeat(20)} | ${'─'.repeat(35)} |\n` +
        resolvedValues.map(v =>
          `| ${(v.ref_id ?? '').padEnd(20)} | ${(v.value ?? '').slice(0, 35).padEnd(35)} |`
        ).join('\n')
      );
    }
  }

  // ── Build README.txt ──────────────────────────────────────────────────────
  const mandatoryList = userCols.filter(c => c.mandatory).map(c => c.name.replace(/\s*\*$/, '').trim());
  const hasSetSnapshot = schema.row_processor === 'group_by_key';

  const readme = [
    '='.repeat(61),
    `${tpl.display_label} — Bulk Import Template`,
    `Generated: ${now}`,
    `Framework: Bulk Operations v1`,
    '='.repeat(61),
    '',
    'OVERVIEW',
    tpl.description,
    '',
    'FORMAT RULES',
    '─'.repeat(40),
    '  File format:    CSV (UTF-8 with BOM, comma-delimited, RFC 4180)',
    '  Date format:    mm/dd/yyyy  e.g. 06/01/2026 = June 1, 2026',
    '  Codes only:     Use employee codes (e.g. EMP001), ISO3 country codes (e.g. IND),',
    '                  currency codes (e.g. INR). For picklist columns, use ref_id',
    '                  (e.g. M001), human label (e.g. Single), or raw UUID — all accepted.',
    `  Mandatory cols: ${mandatoryList.join(', ')}`,
    '  Maximum rows:   10,000 per file. Warning shown at 5,000.',
    '  Comment lines:  Lines beginning with # are ignored by the importer.',
    '  Workflow:       This upload bypasses any configured workflow.',
    '',
    'COLUMNS',
    '─'.repeat(40),
    colTable(userCols),
    '',
    ...(hasSetSnapshot ? [
      'SET-SNAPSHOT NOTE',
      '─'.repeat(40),
      '  This template uses the set-snapshot pattern. All rows sharing the same',
      `  (${(schema.group_by ?? []).join(', ')}) are treated as one atomic snapshot.`,
      '  Uploading a new snapshot REPLACES the current active snapshot for that group.',
      '  To remove a code from the snapshot, set its Value to DELETE.',
      '',
    ] : []),
    'KEYWORDS',
    '─'.repeat(40),
    '  DELETE        (in a value cell) — removes that code from the new snapshot.',
    '                Only valid for set-snapshot templates.',
    '  DELETE_RECORD (in any value cell) — closes the entire record as of the',
    '                effective date. Requires confirmation before commit.',
    '',
    ...(picklistSections.length > 0 ? [
      'REFERENCE TABLES',
      '─'.repeat(40),
      ...picklistSections.flatMap(s => [s, '']),
    ] : []),
    'COMMON ERRORS',
    '─'.repeat(40),
    '  "date must be mm/dd/yyyy"       → Use 06/01/2026 format, not 2026-06-01',
    '  "mandatory column is required"  → Column is blank; fill it in',
    '  "enum must be one of ..."       → Check allowed values in COLUMNS table',
    '  "Duplicate row: composite key"  → Two rows have identical natural key values',
    '  "employee code not found"       → Check the employee code exists in Prowess',
    '',
    `For full documentation see docs/bulk-operations-framework.md`,
  ].join('\n');

  // ── ZIP both files ────────────────────────────────────────────────────────
  const enc = new TextEncoder();
  const zipData = await new Promise<Uint8Array>((resolve, reject) => {
    zip(
      {
        [`${template_code}_template.csv`]: enc.encode(templateCsv),
        'README.txt': enc.encode(readme),
      },
      { level: 6 },
      (err, data) => {
        if (err) reject(err);
        else resolve(data);
      },
    );
  });

  return new Response(zipData, {
    headers: {
      'Content-Type': 'application/zip',
      ...CORS,
      'Content-Disposition': `attachment; filename="${template_code}_template.zip"`,
    },
  });
});

// ─── Helpers ──────────────────────────────────────────────────────────────────

function colTable(cols: ColumnDef[]): string {
  const rows = cols.map(c => {
    const name = c.name.padEnd(30);
    const type = dataTypeLabel(c.data_type).padEnd(20);
    const mand = (c.mandatory ? 'Yes' : 'No').padEnd(9);
    const desc = c.description ?? '';
    return `  | ${name} | ${type} | ${mand} | ${desc}`;
  });
  const header = `  | ${'Column'.padEnd(30)} | ${'Type'.padEnd(20)} | ${'Required'.padEnd(9)} | Description`;
  const sep    = `  | ${'─'.repeat(30)} | ${'─'.repeat(20)} | ${'─'.repeat(9)} | ${'─'.repeat(35)}`;
  return [header, sep, ...rows].join('\n');
}

function dataTypeLabel(dt: string): string {
  if (dt === 'date_mmddyyyy')   return 'mm/dd/yyyy';
  if (dt === 'code_employee')   return 'employee code';
  if (dt === 'code_country_iso') return 'ISO3 country code';
  if (dt === 'code_currency')   return 'currency code';
  if (dt === 'code_department') return 'department code';
  if (dt === 'yesno')           return 'Yes / No';
  if (dt === 'integer')         return 'integer';
  if (dt.startsWith('enum:'))   return `one of: ${dt.slice(5)}`;
  if (dt.startsWith('picklist:') || dt.startsWith('code_picklist:')) return `picklist ref_id`;
  if (dt.startsWith('code_employee_or_keyword:'))
    return `employee code or ${dt.split(':')[1]}`;
  return dt;
}
