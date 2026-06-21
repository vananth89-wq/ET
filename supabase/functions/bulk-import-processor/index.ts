/**
 * bulk-import-processor
 *
 * Async Edge Function — called when the user clicks "Process N valid rows"
 * after validation. Runs the actual commit loop.
 *
 * Flow:
 *   1. Auth + permission check
 *   2. Flip job status → 'processing'
 *   3. Re-parse CSV from Storage (defensive re-validation pass)
 *   4. Set prowess.bulk_upload_job_id session config so processor RPCs
 *      stamp audit_log rows with the batch id
 *   5. For per_row templates: call processor_rpc once per valid row
 *      For group_by_key templates: group rows then call once per group
 *   6. Handle DELETE_RECORD confirmation rows
 *   7. Poll cancellation flag between rows
 *   8. Write error CSV to Storage if any rows failed
 *   9. Flip job status → 'completed' | 'partial' | 'failed'
 *  10. Fire in-app notification to uploader
 *
 * Request body: { job_id: string, confirmed_delete_records?: boolean }
 * Response:     { ok: boolean, succeeded, failed, skipped }
 *
 * Design spec: docs/bulk-operations-framework.md §11.3
 */

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Papa from 'https://esm.sh/papaparse@5';

// ─── Types ────────────────────────────────────────────────────────────────────

interface ColumnDef {
  name: string;
  data_type: string;
  mandatory: boolean;
  user_fillable: boolean;
}

interface SchemaDefinition {
  columns: ColumnDef[];
  natural_key: string[];
  row_processor: 'per_row' | 'group_by_key';
  group_by?: string[];
}

interface TemplateRow {
  template_code: string;
  permission_import: string;
  processor_rpc: string;
  schema_definition: SchemaDefinition;
}

interface ProcessResult {
  row_number: number;
  status: 'succeeded' | 'failed' | 'skipped';
  error?: string;
}

// ─── Entry point ──────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }
  if (req.method !== 'POST') {
    return json({ ok: false, error: 'Method Not Allowed' }, 405);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // ── Auth ─────────────────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ ok: false, error: 'Unauthorized' }, 401);

  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return json({ ok: false, error: 'Unauthorized' }, 401);

  // ── Parse body ────────────────────────────────────────────────────────────
  let body: { job_id: string; confirmed_delete_records?: boolean; dry_run?: boolean };
  try { body = await req.json(); }
  catch { return json({ ok: false, error: 'Invalid JSON body' }, 400); }

  const { job_id, confirmed_delete_records = false, dry_run = false } = body;
  if (!job_id) return json({ ok: false, error: 'job_id is required' }, 400);

  // ── Load + guard job ──────────────────────────────────────────────────────
  const { data: job } = await supabase
    .from('bulk_upload_job')
    .select('*')
    .eq('id', job_id)
    .single();

  if (!job) return json({ ok: false, error: 'Job not found' }, 404);
  if (job.status !== 'awaiting_user') {
    return json({ ok: false, error: `Job is not awaiting_user (status: ${job.status})` }, 409);
  }
  if (job.uploaded_by !== user.id) {
    const { data: isAdmin } = await userClient.rpc('is_super_admin');
    if (!isAdmin) return json({ ok: false, error: 'Forbidden' }, 403);
  }

  // ── Load template ─────────────────────────────────────────────────────────
  const { data: tpl } = await supabase
    .from('bulk_template_registry')
    .select('template_code, permission_import, processor_rpc, schema_definition')
    .eq('template_code', job.template_code)
    .single() as { data: TemplateRow | null };

  if (!tpl) return json({ ok: false, error: 'Template not found' }, 404);

  // ── Permission check ──────────────────────────────────────────────────────
  const [module, action] = tpl.permission_import.split('.');
  const { data: canImport } = await userClient.rpc('user_can', {
    p_module: module, p_action: action, p_owner: null,
  });
  if (!canImport) return json({ ok: false, error: `Permission denied: ${tpl.permission_import}` }, 403);

  // ── Mark dry_run on job if applicable ────────────────────────────────────
  if (dry_run) {
    await supabase.from('bulk_upload_job').update({ is_dry_run: true }).eq('id', job_id);
  }

  // ── Acquire concurrency lock ──────────────────────────────────────────────
  const { data: lockResult } = await supabase.rpc('acquire_bulk_lock', {
    p_template_code: job.template_code,
    p_job_id: job_id,
  });
  if (!lockResult?.ok) {
    await supabase.from('bulk_upload_job')
      .update({ status: 'failed', updated_at: new Date().toISOString() })
      .eq('id', job_id);
    return json({ ok: false, error: lockResult?.error ?? 'Template is locked by another import' }, 409);
  }

  // ── Flip to processing ────────────────────────────────────────────────────
  await supabase
    .from('bulk_upload_job')
    .update({ status: 'processing', updated_at: new Date().toISOString() })
    .eq('id', job_id);

  // ── Dry-run: set savepoint before any DB writes ───────────────────────────
  if (dry_run) {
    await supabase.rpc('bulk_dry_run_savepoint');
  }

  // ── Download CSV ──────────────────────────────────────────────────────────
  const { data: fileData } = await supabase
    .storage
    .from('bulk-uploads')
    .download(job.storage_path.replace('bulk-uploads/', ''));

  if (!fileData) {
    await finaliseJob(supabase, job_id, 'failed', 0, 0, 0, 0);
    return json({ ok: false, error: 'Failed to download file' }, 500);
  }

  const csvText = (await fileData.text())
    .split('\n')
    .filter((l: string) => !l.trimStart().startsWith('#'))
    .join('\n');

  const parsed = Papa.parse<Record<string, string>>(csvText, {
    header: true,
    skipEmptyLines: true,
    transformHeader: (h: string) => h.trim(),
  });

  const schema: SchemaDefinition = tpl.schema_definition;
  const rows = parsed.data;
  const errorRows: Array<Record<string, string> & { _error: string; _row: number }> = [];

  let succeeded = 0, failed = 0, skipped = 0;
  const results: ProcessResult[] = [];

  // Audit log entries — batch-inserted after processing loop
  type JobLogEntry = {
    job_id: string; row_number: number; action: string;
    natural_key: Record<string, string>; error?: string;
  };
  const jobLogEntries: JobLogEntry[] = [];

  // Helper: extract natural key from a CSV row using schema.natural_key column names
  function extractNaturalKey(row: Record<string, string>): Record<string, string> {
    const key: Record<string, string> = {};
    for (const colName of (schema.natural_key ?? [])) {
      key[colName] = getCellValue(row, colName) ?? '';
    }
    return key;
  }

  // ── Check for DELETE_RECORD rows requiring confirmation ───────────────────
  const hasDeleteRecord = rows.some(row =>
    Object.values(row).some(v => v?.trim() === 'DELETE_RECORD')
  );
  if (hasDeleteRecord && !confirmed_delete_records) {
    await supabase
      .from('bulk_upload_job')
      .update({ status: 'awaiting_user', updated_at: new Date().toISOString() })
      .eq('id', job_id);
    return json({
      ok: false,
      requires_confirmation: true,
      message: 'File contains DELETE_RECORD rows. Re-submit with confirmed_delete_records: true to proceed.',
    }, 409);
  }

  // ── Pre-build lookup caches (one DB round-trip each, before the loop) ─────
  // Standard caches
  const empCodeToUuid  = await buildEmployeeCache(supabase, rows);
  const deptCodeToUuid = await buildDeptCache(supabase, rows);

  // Picklist caches — built for any column whose data_type starts with 'picklist:'
  // Maps lowercase(label or ref_id) → UUID, plus raw UUID → UUID (passthrough).
  // upsert_personal_info resolves marital_status server-side (mig 380); these
  // caches cover designation + work_location for upsert_employment_info.
  const picklistCaches = await buildPicklistCaches(supabase, schema);

  // ── Process rows ──────────────────────────────────────────────────────────
  if (schema.row_processor === 'per_row') {
    for (let i = 0; i < rows.length; i++) {
      // Check cancellation every 50 rows
      if (i % 50 === 0) {
        const { data: fresh } = await supabase
          .from('bulk_upload_job')
          .select('status')
          .eq('id', job_id)
          .single();
        if (fresh?.status === 'cancelled') {
          skipped += rows.length - i;
          break;
        }
      }

      const row = rows[i];
      const rowNum = i + 2;

      // Build RPC args — resolves employee/dept/picklist → UUIDs
      const argsResult = buildPerRowArgs(
        row, schema, tpl.processor_rpc,
        empCodeToUuid, deptCodeToUuid, picklistCaches,
      );
      if ('error' in argsResult) {
        failed++;
        errorRows.push({ ...row, _error: argsResult.error, _row: rowNum });
        results.push({ row_number: rowNum, status: 'failed', error: argsResult.error });
        continue;
      }

      const { data: result, error: rpcErr } = await userClient.rpc(
        tpl.processor_rpc,
        argsResult,
      );

      if (rpcErr || !result?.ok) {
        const errMsg = result?.error ?? rpcErr?.message ?? 'Unknown error';
        failed++;
        errorRows.push({ ...row, _error: errMsg, _row: rowNum });
        results.push({ row_number: rowNum, status: 'failed', error: errMsg });
        jobLogEntries.push({ job_id, row_number: rowNum, action: 'failed', natural_key: extractNaturalKey(row), error: errMsg });
      } else {
        succeeded++;
        results.push({ row_number: rowNum, status: 'succeeded' });
        jobLogEntries.push({ job_id, row_number: rowNum, action: 'updated', natural_key: extractNaturalKey(row) });
      }

      // Incremental job update every 100 rows
      if (i % 100 === 0) {
        await supabase.from('bulk_upload_job').update({
          processed_count: i + 1,
          succeeded_count: succeeded,
          failed_count: failed,
          skipped_count: skipped,
          updated_at: new Date().toISOString(),
        }).eq('id', job_id);
      }
    }
  } else {
    // group_by_key — group rows then call once per group
    const groups = groupRows(rows, schema.group_by ?? []);

    let groupIdx = 0;
    for (const [_key, groupRows] of groups.entries()) {
      if (groupIdx % 20 === 0) {
        const { data: fresh } = await supabase
          .from('bulk_upload_job')
          .select('status')
          .eq('id', job_id)
          .single();
        if (fresh?.status === 'cancelled') {
          skipped += [...groups.values()].slice(groupIdx).reduce((a, g) => a + g.length, 0);
          break;
        }
      }

      const argsResult = buildGroupArgs(groupRows, schema, tpl.processor_rpc, empCodeToUuid);
      if ('error' in argsResult) {
        const errMsg = argsResult.error;
        failed += groupRows.length;
        groupRows.forEach(r => errorRows.push({ ...r, _error: errMsg, _row: r._row_number ?? 2 }));
        results.push({ row_number: groupRows[0]._row_number ?? 2, status: 'failed', error: errMsg });
        groupIdx++;
        continue;
      }

      const { data: result, error: rpcErr } = await userClient.rpc(
        tpl.processor_rpc,
        argsResult,
      );

      const startRow = groupRows[0]._row_number ?? 2;
      if (rpcErr || !result?.ok) {
        const errMsg = result?.error ?? rpcErr?.message ?? 'Unknown error';
        failed += groupRows.length;
        groupRows.forEach(r => errorRows.push({ ...r, _error: errMsg, _row: r._row_number }));
        results.push({ row_number: startRow, status: 'failed', error: errMsg });
        jobLogEntries.push({ job_id, row_number: startRow, action: 'failed', natural_key: extractNaturalKey(groupRows[0]), error: errMsg });
      } else {
        succeeded += groupRows.length;
        results.push({ row_number: startRow, status: 'succeeded' });
        jobLogEntries.push({ job_id, row_number: startRow, action: 'updated', natural_key: extractNaturalKey(groupRows[0]) });
      }

      groupIdx++;
    }
  }

  // ── Write error CSV if needed ─────────────────────────────────────────────
  let errorFilePath: string | undefined;
  if (errorRows.length > 0) {
    // Build error frequency map to find most common error
    const errorFreq: Record<string, number> = {};
    for (const r of errorRows) {
      const key = r._error ?? 'Unknown error';
      errorFreq[key] = (errorFreq[key] ?? 0) + 1;
    }
    const mostCommonError = Object.entries(errorFreq)
      .sort((a, b) => b[1] - a[1])[0];

    // Summary comment lines at the top
    const summaryLines = [
      `# Import Error Report`,
      `# Total rows processed : ${succeeded + failed + skipped}`,
      `# Succeeded            : ${succeeded}`,
      `# Failed               : ${failed}`,
      `# Skipped              : ${skipped}`,
      `# Most common error    : ${mostCommonError[0]} (${mostCommonError[1]} row${mostCommonError[1] !== 1 ? 's' : ''})`,
      `#`,
      `# The rows below failed. Fix the errors and re-import only these rows.`,
      `#`,
    ].join('\r\n');

    // Reorder columns: Row # first, then data columns, then Error last
    const orderedRows = errorRows.map(r => {
      const { _row, _error, ...rest } = r;
      return { 'Row #': _row, ...rest, 'Error': _error };
    });

    const errorCsv = summaryLines + '\r\n' + Papa.unparse(orderedRows);
    const errorPath = `${job_id}_errors.csv`;
    await supabase.storage
      .from('bulk-uploads')
      .upload(errorPath, new Blob(['﻿' + errorCsv], { type: 'text/csv' }), { upsert: true });
    errorFilePath = `bulk-uploads/${errorPath}`;
  }

  // ── Batch-insert audit log entries ────────────────────────────────────────
  if (jobLogEntries.length > 0) {
    // Insert in chunks of 500 to stay within Supabase limits
    const CHUNK = 500;
    for (let i = 0; i < jobLogEntries.length; i += CHUNK) {
      await supabase.from('bulk_job_log').insert(jobLogEntries.slice(i, i + CHUNK));
    }
  }

  // ── Finalise ──────────────────────────────────────────────────────────────
  const { data: finalJob } = await supabase
    .from('bulk_upload_job')
    .select('status')
    .eq('id', job_id)
    .single();

  const finalStatus = finalJob?.status === 'cancelled' ? 'cancelled'
    : failed === 0 ? 'completed'
    : succeeded === 0 ? 'failed'
    : 'partial';

  await finaliseJob(
    supabase, job_id, finalStatus,
    rows.length, succeeded, failed, skipped,
    errorFilePath,
  );

  // ── Dry-run: rollback all writes, then update job status ──────────────────
  if (dry_run) {
    await supabase.rpc('bulk_dry_run_rollback');
    // Re-set job to dry_run completed (rollback wiped the status update above)
    await supabase.from('bulk_upload_job').update({
      status: 'completed',
      is_dry_run: true,
      row_count: rows.length,
      succeeded_count: succeeded,
      failed_count: failed,
      skipped_count: skipped,
      completed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq('id', job_id);
  }

  // ── Release concurrency lock ──────────────────────────────────────────────
  await supabase.rpc('release_bulk_lock', {
    p_template_code: job.template_code,
    p_job_id: job_id,
  });

  // ── In-app notification ───────────────────────────────────────────────────
  await sendCompletionNotification(supabase, job, tpl, succeeded, failed, skipped, finalStatus);

  return json({ ok: true, status: finalStatus, succeeded, failed, skipped });
});

// ─── Helpers ──────────────────────────────────────────────────────────────────

function getCellValue(row: Record<string, string>, colName: string): string | undefined {
  const key = Object.keys(row).find(
    k => k.toLowerCase().trim() === colName.toLowerCase().trim()
  );
  const val = key ? row[key]?.trim() : undefined;
  return val || undefined;
}

/** Convert "Employee Code *" → "employee_code", "Line 1" → "line1" etc. */
function headerToSnake(header: string): string {
  return header
    .replace(/\s*\*$/, '')
    .replace(/[()\/]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, '_')
    .replace(/_+/g, '_');
}

/** Convert mm/dd/yyyy → yyyy-mm-dd (ISO). Returns null if blank/invalid. */
function mmddyyyyToIso(val: string | null | undefined): string | null {
  if (!val) return null;
  const m = val.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  if (!m) return null;
  return `${m[3]}-${m[1]}-${m[2]}`;
}

// ─── Cache builders ───────────────────────────────────────────────────────────

async function buildEmployeeCache(
  supabase: ReturnType<typeof createClient>,
  rows: Record<string, string>[],
): Promise<Map<string, string>> {
  const codes = [
    ...new Set(
      rows.flatMap(r => [
        getCellValue(r, 'Employee Code *'),
        getCellValue(r, 'Manager Employee Code'),
      ]).filter(Boolean) as string[]
    ),
  ];
  if (codes.length === 0) return new Map();
  const { data } = await supabase
    .from('employees')
    .select('id, employee_id')
    .in('employee_id', codes);
  return new Map((data ?? []).map((e: { id: string; employee_id: string }) => [e.employee_id, e.id]));
}

async function buildDeptCache(
  supabase: ReturnType<typeof createClient>,
  rows: Record<string, string>[],
): Promise<Map<string, string>> {
  const codes = [
    ...new Set(
      rows.map(r => getCellValue(r, 'Department Code')).filter(Boolean) as string[]
    ),
  ];
  if (codes.length === 0) return new Map();
  const { data } = await supabase
    .from('departments')
    .select('id, dept_id')
    .in('dept_id', codes);
  return new Map((data ?? []).map((d: { id: string; dept_id: string }) => [d.dept_id, d.id]));
}

/**
 * Build picklist caches for every column whose data_type is 'picklist:<CODE>'.
 * Returns Map<picklistCode, Map<lookupKey, uuid>> where lookupKey is
 * lowercase(label), lowercase(ref_id), or the raw uuid string itself.
 *
 * One SELECT per distinct picklist code, run in parallel.
 * upsert_personal_info resolves marital_status server-side (mig 380), so
 * MARITAL_STATUS is included here only if the schema has it — harmless either way.
 */
async function buildPicklistCaches(
  supabase: ReturnType<typeof createClient>,
  schema: SchemaDefinition,
): Promise<Map<string, Map<string, string>>> {
  const picklistCodes = [
    ...new Set(
      schema.columns
        .map(c => c.data_type)
        .filter(dt => dt?.startsWith('picklist:'))
        .map(dt => dt.split(':')[1])
    ),
  ];

  if (picklistCodes.length === 0) return new Map();

  const results = await Promise.all(
    picklistCodes.map(async code => {
      const { data } = await supabase
        .from('picklist_values')
        .select('id, value, ref_id, picklists!inner(picklist_id)')
        .eq('picklists.picklist_id', code)
        .eq('active', true);

      const cache = new Map<string, string>();
      for (const row of (data ?? [])) {
        const uuid = row.id as string;
        cache.set(uuid, uuid);                              // raw UUID passthrough
        if (row.value) cache.set(row.value.toLowerCase(), uuid);    // label
        if (row.ref_id) cache.set(row.ref_id.toLowerCase(), uuid);  // ref_id
      }
      return [code, cache] as [string, Map<string, string>];
    })
  );

  return new Map(results);
}

/**
 * Resolve a user-supplied picklist value (label, ref_id, or UUID) to a stored UUID.
 * Returns null if input is blank; returns { error } if no match found.
 */
function resolvePicklist(
  cache: Map<string, string>,
  input: string | null | undefined,
  colLabel: string,
): string | null | { error: string } {
  if (!input) return null;
  const key = input.trim();
  const resolved = cache.get(key) ?? cache.get(key.toLowerCase());
  if (!resolved) {
    const validLabels = [...new Set(
      [...cache.keys()].filter(k => k.length === 36 ? false : true) // exclude UUID keys
    )].join(', ');
    return { error: `Invalid ${colLabel} "${key}". Valid values: ${validLabels}` };
  }
  return resolved;
}


// ─── RPC argument builders ────────────────────────────────────────────────────

function buildPerRowArgs(
  row: Record<string, string>,
  schema: SchemaDefinition,
  processorRpc: string,
  empCache: Map<string, string>,
  deptCache: Map<string, string>,
  picklistCaches: Map<string, Map<string, string>>,
): Record<string, unknown> | { error: string } {

  // ── Family C — admin/master tables (no employee) ─────────────────────────
  const adminRpcs = [
    'upsert_employee_master', 'upsert_department',
    'upsert_picklist_value',  'upsert_project', 'upsert_exchange_rate',
  ];
  if (adminRpcs.includes(processorRpc)) {
    const p_row: Record<string, string | null> = {};
    for (const col of schema.columns.filter(c => c.user_fillable)) {
      p_row[headerToSnake(col.name)] = getCellValue(row, col.name) ?? null;
    }
    return { p_row };
  }

  // ── Resolve employee UUID (required for families A and B) ─────────────────
  const empCode = getCellValue(row, 'Employee Code *');
  if (!empCode) return { error: '"Employee Code *" is required' };
  const empUuid = empCache.get(empCode);
  if (!empUuid) return { error: `Employee code not found: ${empCode}` };

  // ── Family A — upsert_personal_info ──────────────────────────────────────
  // marital_status resolution handled server-side by mig 380 upsert_personal_info.
  if (processorRpc === 'upsert_personal_info') {
    const proposed: Record<string, string | null> = {
      first_name:     getCellValue(row, 'First Name *')       ?? null,
      last_name:      getCellValue(row, 'Last Name *')        ?? null,
      middle_name:    getCellValue(row, 'Middle Name')        ?? null,
      gender:         getCellValue(row, 'Gender')             ?? null,
      dob:            mmddyyyyToIso(getCellValue(row, 'Date of Birth')),
      nationality:    getCellValue(row, 'Nationality (ISO3)') ?? null,
      marital_status: getCellValue(row, 'Marital Status')     ?? null,
    };
    return {
      p_employee_id:    empUuid,
      p_proposed_data:  proposed,
      p_effective_from: mmddyyyyToIso(getCellValue(row, 'Effective Date *')) ?? new Date().toISOString().slice(0, 10),
    };
  }

  // ── Family A — upsert_employment_info ────────────────────────────────────
  if (processorRpc === 'upsert_employment_info') {
    const effectiveDateRaw = getCellValue(row, 'Effective Date *');
    const effectiveFrom    = mmddyyyyToIso(effectiveDateRaw);
    if (!effectiveFrom) return { error: '"Effective Date *" is required and must be mm/dd/yyyy' };

    // dept code → UUID
    const deptCode = getCellValue(row, 'Department Code');
    let deptId: string | null = null;
    if (deptCode) {
      deptId = deptCache.get(deptCode) ?? null;
      if (!deptId) return { error: `Department code not found: ${deptCode}` };
    }

    // manager employee code → UUID
    const managerCode = getCellValue(row, 'Manager Employee Code');
    let managerId: string | null = null;
    if (managerCode) {
      managerId = empCache.get(managerCode) ?? null;
      if (!managerId) return { error: `Manager employee code not found: ${managerCode}` };
    }

    // designation: label/ref_id/UUID → stored UUID
    const desigCache = picklistCaches.get('DESIGNATION');
    let designationId: string | null = null;
    if (desigCache) {
      const resolved = resolvePicklist(desigCache, getCellValue(row, 'Designation'), 'designation');
      if (resolved && typeof resolved === 'object') return resolved;
      designationId = resolved;
    } else {
      designationId = getCellValue(row, 'Designation') ?? null;
    }

    // work_location: label/ref_id/UUID → stored UUID
    const locCache = picklistCaches.get('LOCATION');
    let workLocationId: string | null = null;
    if (locCache) {
      const resolved = resolvePicklist(locCache, getCellValue(row, 'Work Location'), 'work location');
      if (resolved && typeof resolved === 'object') return resolved;
      workLocationId = resolved;
    } else {
      workLocationId = getCellValue(row, 'Work Location') ?? null;
    }

    // work_country: label/ref_id/UUID → stored UUID
    // Must resolve to UUID — upsert_employment_info cross-checks
    // work_location.parent_value_id === work_country (both must be UUIDs).
    // Schema uses 'picklist:ID_COUNTRY' (same country list as passport/identification)
    const wcCache = picklistCaches.get('ID_COUNTRY');
    let workCountryId: string | null = null;
    if (wcCache) {
      const resolved = resolvePicklist(wcCache, getCellValue(row, 'Work Country (ISO3)'), 'work country');
      if (resolved && typeof resolved === 'object') return resolved;
      workCountryId = resolved;
    } else {
      workCountryId = getCellValue(row, 'Work Country (ISO3)') ?? null;
    }

    const proposed: Record<string, string | null> = {
      designation:   designationId,
      job_title:     getCellValue(row, 'Job Title')           ?? null,
      dept_id:       deptId,
      manager_id:    managerId,
      hire_date:     mmddyyyyToIso(getCellValue(row, 'Hire Date')),
      end_date:      mmddyyyyToIso(getCellValue(row, 'End Date')),
      work_country:  workCountryId,
      work_location: workLocationId,
      status:        getCellValue(row, 'Status')              ?? null,
    };

    return {
      p_employee_id:    empUuid,
      p_proposed_data:  proposed,
      p_effective_from: effectiveFrom,
    };
  }

  // ── Family B — mig-376 per-row wrappers: (p_employee_id, p_row) ──────────
  const p_row: Record<string, string | null> = {};
  for (const col of schema.columns.filter(c => c.user_fillable)) {
    const key = headerToSnake(col.name);
    if (key === 'employee_code') continue;
    let val = getCellValue(row, col.name) ?? null;
    if (col.data_type === 'date_mmddyyyy' && val) {
      val = mmddyyyyToIso(val);
    }
    // Resolve any picklist: columns generically
    if (col.data_type?.startsWith('picklist:') && val) {
      const code = col.data_type.split(':')[1];
      const cache = picklistCaches.get(code);
      if (cache) {
        const resolved = resolvePicklist(cache, val, col.name);
        if (resolved && typeof resolved === 'object') return resolved;
        val = resolved;
      }
    }
    p_row[key] = val;
  }

  return { p_employee_id: empUuid, p_row };
}

function buildGroupArgs(
  groupRows: Array<Record<string, string> & { _row_number?: number }>,
  schema: SchemaDefinition,
  _processorRpc: string,
  empCache: Map<string, string>,
): Record<string, unknown> | { error: string } {
  const firstRow = groupRows[0];

  const empCode = getCellValue(firstRow, 'Employee Code *');
  if (!empCode) return { error: '"Employee Code *" is required' };
  const empUuid = empCache.get(empCode);
  if (!empUuid) return { error: `Employee code not found: ${empCode}` };

  const effectiveDateRaw = getCellValue(firstRow, 'Effective Date *');
  const effectiveFrom    = mmddyyyyToIso(effectiveDateRaw);
  if (!effectiveFrom) return { error: '"Effective Date *" is required and must be mm/dd/yyyy' };

  const items = groupRows.map(row => {
    const item: Record<string, string | null> = {};
    for (const col of schema.columns.filter(c =>
      c.user_fillable &&
      !['Employee Code *', 'Effective Date *'].includes(col.name)
    )) {
      let val = getCellValue(row, col.name) ?? null;
      if (col.data_type === 'date_mmddyyyy' && val) val = mmddyyyyToIso(val);
      item[headerToSnake(col.name)] = val;
    }
    return item;
  });

  return {
    p_employee_id:    empUuid,
    p_effective_from: effectiveFrom,
    p_items:          items,
  };
}

function groupRows(
  rows: Record<string, string>[],
  groupByHeaders: string[],
): Map<string, Array<Record<string, string> & { _row_number: number }>> {
  const map = new Map<string, Array<Record<string, string> & { _row_number: number }>>();
  rows.forEach((row, i) => {
    const key = groupByHeaders.map(h => getCellValue(row, h) ?? '').join('|');
    if (!map.has(key)) map.set(key, []);
    map.get(key)!.push({ ...row, _row_number: i + 2 });
  });
  return map;
}

async function finaliseJob(
  supabase: ReturnType<typeof createClient>,
  jobId: string,
  status: string,
  processed: number,
  succeeded: number,
  failed: number,
  skipped: number,
  errorFilePath?: string,
) {
  await supabase.from('bulk_upload_job').update({
    status,
    processed_count: processed,
    succeeded_count: succeeded,
    failed_count:    failed,
    skipped_count:   skipped,
    completed_at:    new Date().toISOString(),
    error_file_path: errorFilePath ?? null,
    updated_at:      new Date().toISOString(),
  }).eq('id', jobId);
}

async function sendCompletionNotification(
  supabase: ReturnType<typeof createClient>,
  job: Record<string, unknown>,
  tpl: TemplateRow,
  succeeded: number,
  failed: number,
  skipped: number,
  status: string,
) {
  try {
    const label = tpl.template_code.replace(/_/g, ' ');
    const body = status === 'cancelled'
      ? `${label} upload cancelled. ${succeeded} rows committed before cancellation.`
      : `${label} upload ${status}. ${succeeded} succeeded, ${failed} failed, ${skipped} skipped.`;

    await supabase.from('notifications').insert({
      profile_id:  job.uploaded_by,
      title:       `Bulk import ${status}: ${label}`,
      body,
      link:        '/admin/import-export',
    });
  } catch (e) {
    console.warn('bulk-import-processor: notification failed', e);
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
