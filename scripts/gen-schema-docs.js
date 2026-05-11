#!/usr/bin/env node
/**
 * gen-schema-docs.js
 *
 * Queries the live Supabase schema via information_schema and updates
 * prowess_system_docs.html Part 2 (Detailed Field Schema) in-place.
 *
 * Usage:
 *   node scripts/gen-schema-docs.js
 *
 * Requires:
 *   SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in .env (never the anon key —
 *   the service role key can read information_schema)
 *
 * What it does:
 *   1. Fetches all columns from information_schema.columns for the public schema
 *   2. Fetches constraints (PK, FK, UNIQUE) from information_schema
 *   3. For each table, generates a <div class="table-card"> block
 *   4. Replaces the content between <!-- AUTO-SCHEMA-START --> and
 *      <!-- AUTO-SCHEMA-END --> markers in prowess_system_docs.html
 *
 * What it does NOT touch:
 *   - Part 1 (domain cards) — edit manually when adding new tables
 *   - Part 3/4 (ER diagrams) — edit manually when FK relationships change
 *   - Part 5 (RLS docs) — edit manually when RLS policies change
 *   - Part 6 (business rules) — edit manually when constraints change
 *   - Part 7 (design notes) — edit manually
 */

import { createClient } from '@supabase/supabase-js';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// ── Config ───────────────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir   = path.resolve(__dirname, '..');
const docsFile  = path.join(rootDir, 'prowess_system_docs.html');

// Load .env manually (avoid requiring dotenv as a dep)
const envPath = path.join(rootDir, '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const [k, ...vParts] = line.split('=');
    if (k && vParts.length) process.env[k.trim()] = vParts.join('=').trim().replace(/^"|"$/g, '');
  }
}

const SUPABASE_URL      = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  console.error('❌  Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env');
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// ── Domain mapping ───────────────────────────────────────────────────────────

const DOMAIN_MAP = {
  currencies:                   { domain: 'Reference',    badge: 'badge-ref',   purpose: 'ISO currency master — single source of truth for all money values' },
  exchange_rates:               { domain: 'Reference',    badge: 'badge-ref',   purpose: 'Daily FX rates between currency pairs for expense conversion' },
  picklists:                    { domain: 'Reference',    badge: 'badge-ref',   purpose: 'Dropdown category definitions e.g. LOCATION, DESIGNATION, NATIONALITY' },
  picklist_values:              { domain: 'Reference',    badge: 'badge-ref',   purpose: 'Options for each picklist. Self-ref parent enables Country→State→City' },
  projects:                     { domain: 'Reference',    badge: 'badge-ref',   purpose: 'Projects that expense line items can be billed against' },
  departments:                  { domain: 'Organisation', badge: 'badge-org',   purpose: 'Company departments with self-referential hierarchy' },
  department_heads:             { domain: 'Organisation', badge: 'badge-org',   purpose: 'Historical record of department head assignments' },
  employees:                    { domain: 'Organisation', badge: 'badge-org',   purpose: 'Core employee record. manager_id self-ref drives org chart' },
  employee_personal:            { domain: 'Satellite',    badge: 'badge-emp',   purpose: '1-to-1 personal details. RLS-gated separately.' },
  employee_contact:             { domain: 'Satellite',    badge: 'badge-emp',   purpose: '1-to-1 contact details. RLS-gated separately.' },
  employee_employment:          { domain: 'Satellite',    badge: 'badge-emp',   purpose: '1-to-1 employment terms. Admin-only by default.' },
  employee_addresses:           { domain: 'Satellite',    badge: 'badge-emp',   purpose: 'Residential/mailing addresses per employee.' },
  emergency_contacts:           { domain: 'Satellite',    badge: 'badge-emp',   purpose: 'Emergency contacts. Multiple rows per employee allowed.' },
  identity_records:             { domain: 'Satellite',    badge: 'badge-emp',   purpose: 'National IDs, visas, and identity documents.' },
  passports:                    { domain: 'Satellite',    badge: 'badge-emp',   purpose: 'Passport details per employee.' },
  profiles:                     { domain: 'Auth',         badge: 'badge-auth',  purpose: 'Auth user profile. Linked to employee on invite accept.' },
  super_admins:                 { domain: 'Auth',         badge: 'badge-auth',  purpose: 'Break-glass UUID allowlist. service_role writes only.' },
  roles:                        { domain: 'Auth',         badge: 'badge-auth',  purpose: 'Named roles assigned to users e.g. Employee, Manager, Finance, Admin.' },
  user_roles:                   { domain: 'Auth',         badge: 'badge-auth',  purpose: 'Many-to-many user ↔ role. Tracks assignment source. Audited.' },
  modules:                      { domain: 'Permissions',  badge: 'badge-perm',  purpose: 'Top-level permission groupings e.g. expense, employee, workflow.' },
  permissions:                  { domain: 'Permissions',  badge: 'badge-perm',  purpose: 'Atomic permission codes e.g. expense.submit, employee.edit.' },
  permission_sets:              { domain: 'Permissions',  badge: 'badge-perm',  purpose: 'Named bundles of permissions assigned to roles.' },
  permission_set_items:         { domain: 'Permissions',  badge: 'badge-perm',  purpose: 'Which permissions belong to each set. Composite PK.' },
  permission_set_assignments:   { domain: 'Permissions',  badge: 'badge-perm',  purpose: 'Assigns a set to a role, optionally scoped to a target group.' },
  target_groups:                { domain: 'Permissions',  badge: 'badge-perm',  purpose: 'Scope definitions: self / everyone / direct_l1 / dept / country / custom.' },
  target_group_members:         { domain: 'Permissions',  badge: 'badge-perm',  purpose: 'Pre-computed membership cache. Synced by pg_cron.' },
  expense_reports:              { domain: 'Expense',      badge: 'badge-exp',   purpose: 'Report header. Lifecycle: draft → submitted → approved | rejected.' },
  line_items:                   { domain: 'Expense',      badge: 'badge-exp',   purpose: 'Individual expense lines with currency, amount, project.' },
  attachments:                  { domain: 'Expense',      badge: 'badge-exp',   purpose: 'Receipts linked to a report or specific line item.' },
  workflow_templates:           { domain: 'Workflow',     badge: 'badge-wf',    purpose: 'Configurable approval templates with versioning.' },
  workflow_steps:               { domain: 'Workflow',     badge: 'badge-wf',    purpose: 'Ordered steps. approver_type routes to manager / role / dept head.' },
  workflow_instances:           { domain: 'Workflow',     badge: 'badge-wf',    purpose: 'Live execution per record. One in_progress per record at a time.' },
  workflow_tasks:               { domain: 'Workflow',     badge: 'badge-wf',    purpose: 'Per-step tasks. Written only via RPCs (wf_approve, wf_reject).' },
  wf_sla_events:                { domain: 'Workflow',     badge: 'badge-wf',    purpose: 'SLA breach and escalation events.' },
  wf_delegations:               { domain: 'Workflow',     badge: 'badge-wf',    purpose: 'Temporary delegation of approval authority.' },
  notifications:                { domain: 'Workflow',     badge: 'badge-wf',    purpose: 'In-app notifications. read_at = NULL means unread.' },
  audit_log:                    { domain: 'Audit',        badge: 'badge-audit', purpose: 'General action log. Permission changes, admin actions. Append-only.' },
  employee_audit_log:           { domain: 'Audit',        badge: 'badge-audit', purpose: 'Row-level change trail for employees + all satellite tables.' },
  job_run_log:                  { domain: 'Jobs',         badge: 'badge-jobs',  purpose: 'pg_cron job execution history.' },
};

// ── Helpers ──────────────────────────────────────────────────────────────────

function esc(str) {
  return String(str ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function badgeHtml(col, pks, fks, uniques, indexes) {
  let out = `<span class="field-name">${esc(col.column_name)}</span>`;
  if (pks.has(col.column_name))     out += `<span class="badge-pk">PK</span>`;
  if (fks.has(col.column_name))     out += `<span class="badge-fk">FK</span>`;
  if (uniques.has(col.column_name)) out += `<span class="badge-unique">UNIQUE</span>`;
  if (indexes.has(col.column_name)) out += `<span class="badge-idx">IDX</span>`;
  return out;
}

function typeHtml(col) {
  const t = col.udt_name || col.data_type;
  return `<span class="dtype">${esc(t)}</span>`;
}

function nullHtml(col) {
  return col.is_nullable === 'NO'
    ? `<span class="nullable">NOT NULL</span>`
    : `<span class="nullable" style="color:var(--muted)">nullable</span>`;
}

function defaultHtml(col) {
  const d = col.column_default;
  if (!d) return '—';
  return `<span class="field-default">${esc(d.replace(/::[\w\s]+/g,''))}</span>`;
}

// ── Query helpers ─────────────────────────────────────────────────────────────

async function rpc(sql) {
  const { data, error } = await supabase.rpc('exec_sql', { query: sql });
  if (error) throw new Error(`SQL error: ${error.message}\nSQL: ${sql}`);
  return data;
}

async function fetchColumns() {
  const { data, error } = await supabase
    .from('information_schema.columns')
    .select('table_name,column_name,data_type,udt_name,is_nullable,column_default,ordinal_position')
    .eq('table_schema', 'public')
    .order('table_name')
    .order('ordinal_position');
  if (error) throw new Error(`columns fetch: ${error.message}`);
  return data;
}

// ── Generate HTML for one table ───────────────────────────────────────────────

function tableCard(tableName, cols, pks, fks, uniques, indexes) {
  const meta = DOMAIN_MAP[tableName] || { domain: 'Unknown', badge: 'badge-ref', purpose: '' };

  const rows = cols.map(col => `
  <tr>
    <td>${badgeHtml(col, pks, fks, uniques, indexes)}</td>
    <td>${typeHtml(col)}</td>
    <td>${nullHtml(col)}</td>
    <td>${defaultHtml(col)}</td>
    <td class="field-desc">—</td>
  </tr>`).join('');

  return `
  <div class="table-card" id="t-${tableName}">
    <div class="table-header" onclick="toggleTable(this)">
      <span class="table-name">${esc(tableName)}</span>
      <span class="table-domain-badge ${meta.badge}">${esc(meta.domain)}</span>
      <span class="table-purpose">${esc(meta.purpose)}</span>
      <span class="table-chevron">▸</span>
    </div>
    <div class="table-body">
      <table class="fields-table">
        <thead><tr><th>Field</th><th>Type</th><th>Null</th><th>Default</th><th>Description</th></tr></thead>
        <tbody>${rows}
        </tbody>
      </table>
    </div>
  </div>`;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  console.log('🔍  Fetching schema from Supabase…');

  // NOTE: information_schema is not accessible via the Supabase JS client's
  // .from() because PostgREST only exposes the public schema.
  // Use the Supabase SQL Editor or a direct pg connection instead.
  // This script is a TEMPLATE — wire up the data source that fits your setup:
  //
  //   Option A: Direct PostgreSQL connection (recommended)
  //     Replace this section with: import pg from 'pg'; const client = new pg.Client(...)
  //
  //   Option B: Supabase SQL via a SECURITY DEFINER RPC
  //     Create: CREATE FUNCTION get_schema_info() RETURNS TABLE(...) SECURITY DEFINER...
  //
  //   Option C: Export from migration files (no live DB needed)
  //     Parse your .sql files and extract CREATE TABLE statements.

  console.log('');
  console.log('⚠️  SETUP REQUIRED:');
  console.log('   The Supabase JS client cannot query information_schema directly.');
  console.log('   Choose one of the approaches documented in this file and wire it up.');
  console.log('');
  console.log('   QUICKEST PATH — add this RPC to a new migration:');
  console.log('');
  console.log(`   CREATE OR REPLACE FUNCTION get_schema_info()
   RETURNS TABLE (
     table_name text, column_name text, data_type text,
     udt_name text, is_nullable text, column_default text, ordinal_position int
   )
   LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
     SELECT table_name::text, column_name::text, data_type::text,
            udt_name::text, is_nullable::text, column_default::text,
            ordinal_position::int
     FROM   information_schema.columns
     WHERE  table_schema = 'public'
     ORDER  BY table_name, ordinal_position;
   $$;`);
  console.log('');
  console.log('   Then uncomment and use: supabase.rpc("get_schema_info")');
  console.log('   and feed the result into generatePart2(columns).');
  console.log('');
  console.log('📄  For now, use this script as a TEMPLATE.');
  console.log('    The generatePart2() function below is fully implemented.');
  console.log('    Provide the columns array and it will patch the HTML file.');
}

/**
 * Call this with real column data to patch the HTML file.
 * columns: array from information_schema.columns (table_name, column_name, etc.)
 * constraints: { pks, fks, uniques, indexes } — Maps of table_name → Set<column_name>
 */
export function generatePart2(columns, constraints = {}) {
  const { pks = {}, fks = {}, uniques = {}, indexes = {} } = constraints;

  // Group by table
  const byTable = {};
  for (const col of columns) {
    if (!byTable[col.table_name]) byTable[col.table_name] = [];
    byTable[col.table_name].push(col);
  }

  // Render all cards
  const allCards = Object.entries(byTable).map(([tbl, cols]) =>
    tableCard(
      tbl, cols,
      new Set(pks[tbl]     || []),
      new Set(fks[tbl]     || []),
      new Set(uniques[tbl] || []),
      new Set(indexes[tbl] || []),
    )
  ).join('\n');

  const wrapped = `<!-- AUTO-SCHEMA-START -->\n${allCards}\n<!-- AUTO-SCHEMA-END -->`;

  let html = fs.readFileSync(docsFile, 'utf8');
  const startMarker = '<!-- AUTO-SCHEMA-START -->';
  const endMarker   = '<!-- AUTO-SCHEMA-END -->';

  if (!html.includes(startMarker)) {
    console.warn('⚠️  Markers not found in HTML file. Add the following to Part 2 where table cards should go:');
    console.warn('   <!-- AUTO-SCHEMA-START -->');
    console.warn('   <!-- AUTO-SCHEMA-END -->');
    return;
  }

  const start = html.indexOf(startMarker);
  const end   = html.indexOf(endMarker) + endMarker.length;
  html = html.slice(0, start) + wrapped + html.slice(end);

  fs.writeFileSync(docsFile, html, 'utf8');
  console.log(`✅  Part 2 updated in ${path.relative(process.cwd(), docsFile)}`);
  console.log(`    ${Object.keys(byTable).length} tables · ${columns.length} fields`);
}

main().catch(err => { console.error('❌', err.message); process.exit(1); });
