/**
 * bulk-import-validator
 *
 * Synchronous Edge Function — called immediately after the user uploads a CSV.
 *
 * Flow:
 *   1. Auth check (user must have <module>.bulk_import permission)
 *   2. Read the uploaded file from Storage (bulk-uploads/{job_id}.csv)
 *   3. Strip comment lines, parse CSV (RFC 4180)
 *   4. Validate header: mandatory columns present, unknown columns noted
 *   5. Pre-fetch picklist label maps for templates that need format validation
 *   6. Per-row validation: shape → type → format rules → composite key
 *   7. Write per-row results back to caller (JSON array)
 *   8. Update bulk_upload_job counts + status = 'awaiting_user'
 *
 * Format rules validated here (same rules as the portlets):
 *   contact_info  — mobile number format per dial code (Country Code column)
 *   passport      — passport number format per country + expiry > issue + max 10yr
 *   identification — id_number format per country + id_type
 *
 * Request body: { job_id: string }
 * Response:     { ok: boolean, rows: RowResult[], counts: { valid, warning, error } }
 *
 * Design spec: docs/bulk-operations-framework.md §11
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
  description?: string;
  include_with_system_metadata?: boolean;
  computed_from?: string;
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
  schema_definition: SchemaDefinition;
}

type RowStatus = 'valid' | 'warning' | 'error';

interface DiffPreview {
  new_count:    number;
  update_count: number;
  error?:       string;
}

interface RowResult {
  row_number: number;
  status: RowStatus;
  errors: string[];
  warnings: string[];
  data: Record<string, string>;   // raw CSV values keyed by header name
}

// ─── Picklist label maps ──────────────────────────────────────────────────────

/** UUID → lowercase label, also ref_id → lowercase label for flexible lookup */
type LabelMap = Map<string, string>;

async function fetchLabelMap(
  supabase: ReturnType<typeof createClient>,
  picklistCode: string,
): Promise<LabelMap> {
  // One query: join picklists → picklist_values by picklist_id code
  const { data: pl } = await supabase
    .from('picklists')
    .select('id')
    .eq('picklist_id', picklistCode)
    .single();

  const rows = pl
    ? (await supabase
        .from('picklist_values')
        .select('id, ref_id, value')
        .eq('picklist_id', pl.id)
        .eq('active', true)
      ).data ?? []
    : [];

  const map: LabelMap = new Map();
  for (const row of rows) {
    const label = (row.value ?? '').toLowerCase();
    map.set((row.id as string).toLowerCase(), label);                      // UUID → label
    if (row.ref_id) map.set((row.ref_id as string).toLowerCase(), label); // ref_id → label
    map.set(label, label);                                                  // label → label
  }
  return map;
}

/** Resolve a cell value (UUID / ref_id / label) to a lowercase label name. */
function resolveLabel(map: LabelMap, cellValue: string): string | null {
  return map.get(cellValue.trim().toLowerCase()) ?? null;
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
  let body: { job_id: string };
  try { body = await req.json(); }
  catch { return json({ ok: false, error: 'Invalid JSON body' }, 400); }

  const { job_id } = body;
  if (!job_id) return json({ ok: false, error: 'job_id is required' }, 400);

  // ── Load job row ──────────────────────────────────────────────────────────
  const { data: job, error: jobErr } = await supabase
    .from('bulk_upload_job')
    .select('*')
    .eq('id', job_id)
    .single();

  if (jobErr || !job) return json({ ok: false, error: 'Job not found' }, 404);
  if (job.uploaded_by !== user.id) {
    const { data: isAdmin } = await userClient.rpc('is_super_admin');
    if (!isAdmin) return json({ ok: false, error: 'Forbidden' }, 403);
  }

  // ── Load template registry row ────────────────────────────────────────────
  const { data: tpl, error: tplErr } = await supabase
    .from('bulk_template_registry')
    .select('template_code, permission_import, schema_definition')
    .eq('template_code', job.template_code)
    .single();

  if (tplErr || !tpl) return json({ ok: false, error: 'Template not found' }, 404);

  // ── Permission check ──────────────────────────────────────────────────────
  const [module, action] = tpl.permission_import.split('.');
  const { data: canImport } = await userClient.rpc('user_can', {
    p_module: module,
    p_action: action,
    p_owner: null,
  });
  if (!canImport) return json({ ok: false, error: `Permission denied: ${tpl.permission_import}` }, 403);

  // ── Download CSV from Storage ─────────────────────────────────────────────
  const { data: fileData, error: dlErr } = await supabase
    .storage
    .from('bulk-uploads')
    .download(job.storage_path.replace('bulk-uploads/', ''));

  if (dlErr || !fileData) {
    return json({ ok: false, error: `Failed to download file: ${dlErr?.message}` }, 500);
  }

  const csvText = await fileData.text();

  // ── Strip comment lines (#) ───────────────────────────────────────────────
  const strippedCsv = csvText
    .split('\n')
    .filter(line => !line.trimStart().startsWith('#'))
    .join('\n');

  // ── Parse CSV ─────────────────────────────────────────────────────────────
  const parsed = Papa.parse<Record<string, string>>(strippedCsv, {
    header: true,
    skipEmptyLines: true,
    transformHeader: (h: string) => h.trim(),
  });

  if (parsed.errors.length > 0 && parsed.data.length === 0) {
    await updateJobFailed(supabase, job_id, 'CSV parse failed');
    return json({ ok: false, error: 'CSV parse failed', details: parsed.errors }, 422);
  }

  const schema: SchemaDefinition = tpl.schema_definition;
  const userFillableCols = schema.columns.filter(c => c.user_fillable);
  const mandatoryCols    = userFillableCols.filter(c => c.mandatory);
  const headers          = parsed.meta.fields ?? [];

  // ── Header validation ─────────────────────────────────────────────────────
  const headerWarnings: string[] = [];
  const missingMandatory = mandatoryCols
    .map(c => c.name)
    .filter(name => !headers.some(h => h.toLowerCase().trim() === name.toLowerCase().trim()));

  if (missingMandatory.length > 0) {
    await updateJobFailed(supabase, job_id, `Missing mandatory columns: ${missingMandatory.join(', ')}`);
    return json({
      ok: false,
      error: `Missing mandatory columns: ${missingMandatory.join(', ')}`,
    }, 422);
  }

  const knownHeaders = new Set(userFillableCols.map(c => c.name.toLowerCase().trim()));
  const ignoredHeaders = headers.filter(h => !knownHeaders.has(h.toLowerCase().trim()));
  if (ignoredHeaders.length > 0) {
    headerWarnings.push(`Ignored ${ignoredHeaders.length} unrecognised column(s): ${ignoredHeaders.join(', ')}`);
  }

  // ── Row count guard ───────────────────────────────────────────────────────
  const rows = parsed.data;
  if (rows.length > 10000) {
    await updateJobFailed(supabase, job_id, 'File exceeds 10,000 row limit');
    return json({ ok: false, error: 'File exceeds 10,000 row limit. Split into smaller files.' }, 422);
  }

  // ── Pre-fetch picklist label maps (one query per picklist, not per row) ───
  // Only fetched for templates whose format rules need country / id-type names.
  let countryMap: LabelMap = new Map();   // passport + identification
  let idTypeMap:  LabelMap = new Map();   // identification

  // employment cross-field maps (built with 2 queries)
  let workCountryMap:   LabelMap = new Map();              // ref_id/label/uuid → country uuid
  let locationLabelMap: LabelMap = new Map();              // ref_id/label/uuid → location uuid
  let locationParent:   Map<string, string> = new Map();   // location uuid    → parent country uuid

  const tc = job.template_code;
  if (tc === 'passport' || tc === 'identification') {
    countryMap = await fetchLabelMap(supabase, 'ID_COUNTRY');
  }
  if (tc === 'identification') {
    idTypeMap = await fetchLabelMap(supabase, 'ID_TYPE');
  }
  if (tc === 'employment') {
    // Both maps must store UUIDs as values so the parent comparison is UUID vs UUID.
    // fetchLabelMap stores labels as values — we need a UUID-valued map instead.

    // Query 1: ID_COUNTRY → ref_id/label/uuid → country UUID
    const { data: cPl } = await supabase
      .from('picklists').select('id').eq('picklist_id', 'ID_COUNTRY').single();
    if (cPl) {
      const { data: countries } = await supabase
        .from('picklist_values').select('id, ref_id, value')
        .eq('picklist_id', cPl.id).eq('active', true);
      for (const c of (countries ?? [])) {
        const uuid = (c.id as string).toLowerCase();
        workCountryMap.set(uuid, uuid);
        if (c.ref_id) workCountryMap.set((c.ref_id as string).toLowerCase(), uuid);
        if (c.value)  workCountryMap.set((c.value as string).toLowerCase(),  uuid);
      }
    }

    // Query 2: LOCATION → ref_id/label/uuid → location UUID + parent country UUID
    const { data: locPl } = await supabase
      .from('picklists').select('id').eq('picklist_id', 'LOCATION').single();
    if (locPl) {
      const { data: locs } = await supabase
        .from('picklist_values').select('id, ref_id, value, parent_value_id')
        .eq('picklist_id', locPl.id).eq('active', true);
      for (const loc of (locs ?? [])) {
        const uuid = (loc.id as string).toLowerCase();
        locationLabelMap.set(uuid, uuid);
        if (loc.ref_id) locationLabelMap.set((loc.ref_id as string).toLowerCase(), uuid);
        if (loc.value)  locationLabelMap.set((loc.value as string).toLowerCase(),  uuid);
        if (loc.parent_value_id) locationParent.set(uuid, (loc.parent_value_id as string).toLowerCase());
      }
    }
  }

  // ── Per-row validation ────────────────────────────────────────────────────
  const results: RowResult[] = [];
  const seenKeys = new Set<string>();
  let validCount = 0, warnCount = 0, errorCount = 0;

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const rowNum = i + 2; // 1-based + header row
    const errors: string[] = [];
    const warnings: string[] = [];

    // 1. Shape: mandatory columns non-empty
    for (const col of mandatoryCols) {
      const val = getCellValue(row, col.name);
      if (!val) errors.push(`"${col.name}" is required`);
    }

    // 2. Type validation (date format, yesno, integer, enum)
    for (const col of userFillableCols) {
      const val = getCellValue(row, col.name);
      if (!val) continue;
      const typeErr = validateType(val, col.data_type, col.name);
      if (typeErr) errors.push(typeErr);
    }

    // 3. Format rules — portlet-equivalent validation per template
    const formatErrs = validateFormat(tc, row, countryMap, idTypeMap, workCountryMap, locationLabelMap, locationParent);
    errors.push(...formatErrs);

    // 4. Composite key uniqueness within the file
    const naturalKey = schema.natural_key
      .map(k => getCellValue(row, k) ?? '')
      .join('|');
    if (seenKeys.has(naturalKey)) {
      errors.push(`Duplicate row: composite key (${schema.natural_key.join(', ')}) = (${naturalKey}) already appears earlier in this file`);
    } else {
      seenKeys.add(naturalKey);
    }

    const status: RowStatus = errors.length > 0 ? 'error'
      : warnings.length > 0 ? 'warning'
      : 'valid';

    if (status === 'valid')        validCount++;
    else if (status === 'warning') { validCount++; warnCount++; }
    else errorCount++;

    results.push({ row_number: rowNum, status, errors, warnings, data: row });
  }

  // ── Diff preview ──────────────────────────────────────────────────────────
  let diffPreview: DiffPreview = { new_count: 0, update_count: 0 };
  try {
    const validResults = results.filter(r => r.status !== 'error');
    if (validResults.length > 0 && schema.natural_key?.length > 0) {
      const keyObjects = validResults.map(r => {
        const obj: Record<string, string> = {};
        for (const col of schema.natural_key) {
          obj[headerToSnake(col)] = getCellValue(r.data, col) ?? '';
        }
        return obj;
      });
      const { data: diffData } = await supabase.rpc('bulk_diff_preview', {
        p_template_code: job.template_code,
        p_keys: keyObjects,
      });
      if (diffData) diffPreview = diffData as DiffPreview;
    }
  } catch {
    // Non-critical — swallow
  }

  // ── Update job ────────────────────────────────────────────────────────────
  await supabase
    .from('bulk_upload_job')
    .update({
      row_count:     rows.length,
      valid_count:   validCount,
      warning_count: warnCount,
      error_count:   errorCount,
      status:        'awaiting_user',
      updated_at:    new Date().toISOString(),
    })
    .eq('id', job_id);

  return json({
    ok: true,
    header_warnings: headerWarnings,
    counts: { total: rows.length, valid: validCount, warning: warnCount, error: errorCount },
    diff_preview: diffPreview,
    rows: results,
  });
});

// ─── Format validation (portlet-equivalent rules) ─────────────────────────────

/**
 * Dispatch to per-template format validators.
 * All map lookups are O(1) — no DB calls inside this function.
 */
function validateFormat(
  templateCode: string,
  row: Record<string, string>,
  countryMap: LabelMap,
  idTypeMap: LabelMap,
  workCountryMap: LabelMap,
  locationLabelMap: LabelMap,
  locationParent: Map<string, string>,
): string[] {
  switch (templateCode) {
    case 'contact_info':    return validateContactInfo(row);
    case 'passport':        return validatePassportRow(row, countryMap);
    case 'identification':  return validateIdentificationRow(row, countryMap, idTypeMap);
    case 'employment':      return validateEmploymentRow(row, workCountryMap, locationLabelMap, locationParent);
    default:                return [];
  }
}

// ── contact_info ──────────────────────────────────────────────────────────────

const MOBILE_RULES: Record<string, { pattern: RegExp; message: string }> = {
  '+91':  { pattern: /^[6-9]\d{9}$/,          message: 'Indian mobile: 10 digits starting with 6–9 (e.g. 9876543210)' },
  '+92':  { pattern: /^03\d{9}$/,              message: 'Pakistan mobile: 11 digits starting with 03 (e.g. 03001234567)' },
  '+966': { pattern: /^05\d{8}$/,              message: 'Saudi Arabia mobile: 10 digits starting with 05 (e.g. 0501234567)' },
  '+94':  { pattern: /^07\d{8}$/,              message: 'Sri Lanka mobile: 10 digits starting with 07 (e.g. 0712345678)' },
  '+20':  { pattern: /^01\d{9}$/,              message: 'Egypt mobile: 11 digits starting with 01 (e.g. 01012345678)' },
  '+44':  { pattern: /^(07\d{9}|7\d{9})$/,    message: 'UK mobile: 10–11 digits starting with 7 or 07 (e.g. 07911123456)' },
  '+971': { pattern: /^(05\d{8}|5\d{8})$/,    message: 'UAE mobile: 9–10 digits starting with 5 or 05 (e.g. 0501234567)' },
};
const GENERIC_MOBILE = /^\d{7,15}$/;

function validateContactInfo(row: Record<string, string>): string[] {
  const errors: string[] = [];
  const dialCode = getCellValue(row, 'Country Code');
  const mobile   = getCellValue(row, 'Mobile');

  if (mobile && dialCode) {
    const rule = MOBILE_RULES[dialCode.trim()];
    if (rule) {
      if (!rule.pattern.test(mobile.replace(/\s/g, ''))) {
        errors.push(`"Mobile": ${rule.message}`);
      }
    } else if (!GENERIC_MOBILE.test(mobile.replace(/\s/g, ''))) {
      errors.push(`"Mobile": enter a valid mobile number (7–15 digits)`);
    }
  }

  return errors;
}

// ── passport ──────────────────────────────────────────────────────────────────

const PASSPORT_RULES: Record<string, {
  pattern:  RegExp;
  message:  string;
  maxYears: number;
}> = {
  'india':        { pattern: /^[A-Z]\d{7}$/i,        message: 'India passport: 1 letter + 7 digits (e.g. V6543578)',           maxYears: 10 },
  'pakistan':     { pattern: /^[A-Z]{2}\d{7}$/i,     message: 'Pakistan passport: 2 letters + 7 digits (e.g. AB1234567)',      maxYears: 10 },
  'saudi arabia': { pattern: /^\d{10}$/,              message: 'Saudi Arabia passport: 10 digits (e.g. 1234567890)',            maxYears: 10 },
  'sri lanka':    { pattern: /^[A-Z]{1,2}\d{7}$/i,   message: 'Sri Lanka passport: 1–2 letters + 7 digits (e.g. N1234567)',   maxYears: 10 },
};

function validatePassportRow(row: Record<string, string>, countryMap: LabelMap): string[] {
  const errors: string[] = [];
  const countryRaw  = getCellValue(row, 'Country (ISO3)');
  const passNumber  = getCellValue(row, 'Passport Number *');
  const issueDateRaw  = getCellValue(row, 'Issue Date');
  const expiryDateRaw = getCellValue(row, 'Expiry Date');

  const countryName = countryRaw ? resolveLabel(countryMap, countryRaw) : null;
  const rule = countryName ? PASSPORT_RULES[countryName] : null;

  // Number format
  if (passNumber && rule) {
    if (!rule.pattern.test(passNumber.trim().toUpperCase())) {
      errors.push(`"Passport Number": ${rule.message}`);
    }
  }

  // Dates: parse mm/dd/yyyy
  const issueDate  = parseDate(issueDateRaw);
  const expiryDate = parseDate(expiryDateRaw);

  if (issueDate && expiryDate) {
    if (expiryDate <= issueDate) {
      errors.push(`"Expiry Date" must be after "Issue Date"`);
    } else if (rule) {
      const maxExpiry = new Date(issueDate);
      maxExpiry.setFullYear(maxExpiry.getFullYear() + rule.maxYears);
      if (expiryDate > maxExpiry) {
        errors.push(`"Expiry Date": passport validity cannot exceed ${rule.maxYears} years from Issue Date`);
      }
    }
  }

  return errors;
}

// ── identification ────────────────────────────────────────────────────────────

type IdRule = { pattern: RegExp; strip: string[]; message: string };

const ID_RULES: Record<string, Record<string, IdRule>> = {
  india: {
    aadhaar:          { pattern: /^\d{12}$/,                     strip: [' ', '-'], message: 'Aadhaar: 12 digits (spaces/hyphens ignored)' },
    pan:              { pattern: /^[A-Z]{5}\d{4}[A-Z]$/i,       strip: [],         message: 'PAN: 5 letters + 4 digits + 1 letter (e.g. ABCDE1234F)' },
    'driving license':{ pattern: /^[A-Z]{2}\d{2}\d{4}\d{7}$/i,  strip: [' ', '-'], message: 'Driving License: state code + RTO + year + 7 digits (e.g. TN0120121234567)' },
  },
  pakistan: {
    cnic:  { pattern: /^\d{13}$/, strip: ['-', ' '], message: 'CNIC: 13 digits (hyphens ignored, e.g. 12345-1234567-1)' },
    nicop: { pattern: /^\d{13}$/, strip: ['-', ' '], message: 'NICOP: 13 digits (hyphens ignored, e.g. 12345-1234567-1)' },
  },
  'saudi arabia': {
    iqama:              { pattern: /^2\d{9}$/, strip: [' '], message: 'Iqama: 10 digits starting with 2 (e.g. 2123456789)' },
    'saudi national id':{ pattern: /^1\d{9}$/, strip: [' '], message: 'National ID: 10 digits starting with 1 (e.g. 1123456789)' },
  },
  'sri lanka': {
    nic: {
      pattern: /^(\d{9}[VX]|\d{12})$/i,
      strip: [' ', '-'],
      message: 'NIC: old format 9 digits + V/X (e.g. 123456789V) or new format 12 digits',
    },
  },
};

function validateIdentificationRow(
  row: Record<string, string>,
  countryMap: LabelMap,
  idTypeMap: LabelMap,
): string[] {
  const errors: string[] = [];
  const countryRaw = getCellValue(row, 'Country (ISO3)');
  const idTypeRaw  = getCellValue(row, 'ID Type *');
  const idNumber   = getCellValue(row, 'ID Number *');
  const expiryRaw  = getCellValue(row, 'Expiry Date');

  const countryName = countryRaw ? resolveLabel(countryMap, countryRaw) : null;
  const idTypeName  = idTypeRaw  ? resolveLabel(idTypeMap,  idTypeRaw)  : null;

  if (idNumber && countryName && idTypeName) {
    const countryRules = ID_RULES[countryName];
    const rule = countryRules?.[idTypeName];
    if (rule) {
      let n = idNumber.trim().toUpperCase();
      for (const ch of rule.strip) n = n.split(ch).join('');
      if (!rule.pattern.test(n)) {
        errors.push(`"ID Number": ${rule.message}`);
      }
    }
  }

  // Expiry date: if present, must be in the future (warn, not error)
  // (no issue date on identification — just sanity check it's a future date)
  const expiry = parseDate(expiryRaw);
  if (expiry && expiry < new Date()) {
    errors.push(`"Expiry Date": ID document has already expired`);
  }

  return errors;
}

// ── employment ────────────────────────────────────────────────────────────────

function validateEmploymentRow(
  row: Record<string, string>,
  workCountryMap: LabelMap,
  locationLabelMap: LabelMap,
  locationParent: Map<string, string>,
): string[] {
  const errors: string[] = [];

  // 1. hire_date ≤ end_date
  const hireDate  = parseDate(getCellValue(row, 'Hire Date'));
  const endDate   = parseDate(getCellValue(row, 'End Date'));
  if (hireDate && endDate && endDate < hireDate) {
    errors.push(`"End Date" must be on or after "Hire Date"`);
  }

  // 2. work_location belongs to work_country
  const countryRaw  = getCellValue(row, 'Work Country (ISO3)');
  const locationRaw = getCellValue(row, 'Work Location');

  if (countryRaw && locationRaw) {
    const countryUuid   = resolveLabel(workCountryMap,   countryRaw);
    const locationUuid  = resolveLabel(locationLabelMap, locationRaw);

    if (countryUuid && locationUuid) {
      const parentCountryUuid = locationParent.get(locationUuid.toLowerCase());
      if (parentCountryUuid && parentCountryUuid !== countryUuid.toLowerCase()) {
        errors.push(`"Work Location" does not belong to the selected "Work Country"`);
      }
    } else if (!countryUuid && countryRaw) {
      errors.push(`"Work Country": unknown value "${countryRaw}"`);
    } else if (!locationUuid && locationRaw) {
      errors.push(`"Work Location": unknown value "${locationRaw}"`);
    }
  }

  return errors;
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

/** Parse m/d/yyyy or mm/dd/yyyy → Date, or null if missing/invalid. */
function parseDate(raw: string | undefined): Date | null {
  if (!raw) return null;
  const m = raw.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (!m) return null;
  const mo = Number(m[1]), dy = Number(m[2]), yr = Number(m[3]);
  const d = new Date(yr, mo - 1, dy);
  return (isNaN(d.getTime()) || d.getMonth() !== mo - 1 || d.getDate() !== dy) ? null : d;
}

/** Mirrors headerToSnake in bulk-import-processor — must stay in sync. */
function headerToSnake(header: string): string {
  return header
    .replace(/\s*\*$/, '')
    .replace(/[()\/]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, '_')
    .replace(/_+/g, '_');
}

function getCellValue(row: Record<string, string>, colName: string): string | undefined {
  const key = Object.keys(row).find(
    k => k.toLowerCase().trim() === colName.toLowerCase().trim()
  );
  const val = key ? row[key]?.trim() : undefined;
  return val || undefined;
}

function validateType(val: string, dataType: string, colName: string): string | null {
  if (val === 'DELETE' || val === 'DELETE_RECORD') return null;

  if (dataType === 'date_mmddyyyy') {
    // Accept m/d/yyyy and mm/dd/yyyy — Excel strips leading zeros
    if (!/^\d{1,2}\/\d{1,2}\/\d{4}$/.test(val)) {
      return `"${colName}": date must be mm/dd/yyyy (got "${val}")`;
    }
    const [mo, dy, yr] = val.split('/').map(Number);
    const d = new Date(yr, mo - 1, dy);
    if (isNaN(d.getTime()) || d.getMonth() !== mo - 1 || d.getDate() !== dy) {
      return `"${colName}": invalid date "${val}"`;
    }
  }

  if (dataType === 'yesno') {
    if (!['yes', 'no'].includes(val.toLowerCase())) {
      return `"${colName}": must be Yes or No (got "${val}")`;
    }
  }

  if (dataType === 'integer') {
    if (!/^-?\d+$/.test(val)) {
      return `"${colName}": must be an integer (got "${val}")`;
    }
  }

  if (dataType.startsWith('enum:')) {
    const allowed = dataType.slice(5).split(',');
    if (!allowed.includes(val)) {
      return `"${colName}": must be one of ${allowed.join(', ')} (got "${val}")`;
    }
  }

  return null;
}

async function updateJobFailed(
  supabase: ReturnType<typeof createClient>,
  jobId: string,
  reason: string,
) {
  await supabase
    .from('bulk_upload_job')
    .update({ status: 'failed', updated_at: new Date().toISOString() })
    .eq('id', jobId);
  console.error(`bulk-import-validator: job ${jobId} failed — ${reason}`);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
