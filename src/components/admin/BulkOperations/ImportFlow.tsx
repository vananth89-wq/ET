/**
 * ImportFlow
 *
 * Full import workflow:
 *   1. File picker → upload to Storage → call validator
 *   2. Show ValidationResultsTable with counts + per-row results
 *   3. User confirms → call processor → show progress
 *   4. Terminal state with download-error-file link
 */

import { useState, useRef }          from 'react';
import { supabase }                  from '../../../lib/supabase';
import type { BulkTemplateRow }      from '../../../hooks/useBulkTemplates';
import type { BulkUploadJob }        from '../../../hooks/useBulkUploadJob';
import ValidationResultsTable        from './ValidationResultsTable';
import CancelInflightButton          from './CancelInflightButton';
import * as XLSX                     from 'xlsx';

interface RowResult {
  row_number: number;
  status:     'valid' | 'warning' | 'error';
  errors:     string[];
  warnings:   string[];
  data:        Record<string, string>;
}

interface DiffPreview {
  new_count:    number;
  update_count: number;
}

interface ValidationResponse {
  ok:              boolean;
  error?:          string;
  header_warnings: string[];
  counts:          { total: number; valid: number; warning: number; error: number };
  diff_preview?:   DiffPreview;
  rows:            RowResult[];
}

type Step = 'idle' | 'uploading' | 'validating' | 'results' | 'processing' | 'done' | 'error';

interface Props {
  template:       BulkTemplateRow;
  activeJob:      BulkUploadJob | null;
  onJobStarted:   (jobId: string) => void;
  onJobSettled:   () => void;
}

export default function ImportFlow({ template, activeJob, onJobStarted, onJobSettled }: Props) {
  const fileRef         = useRef<HTMLInputElement>(null);
  const [step, setStep] = useState<Step>('idle');
  const [msg,  setMsg]  = useState('');
  const [validation, setValidation] = useState<ValidationResponse | null>(null);
  const [jobId, setJobId]           = useState<string | null>(null);
  const [hasDeleteRecord, setHasDeleteRecord] = useState(false);

  // Show in-flight job state from parent polling
  const inflight = activeJob &&
    ['validating', 'awaiting_user', 'processing'].includes(activeJob.status);

  async function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    e.target.value = '';

    if (!file.name.toLowerCase().endsWith('.csv')) {
      setMsg('Please select a .csv file.');
      setStep('error');
      return;
    }
    if (file.size > 52_428_800) {
      setMsg('File exceeds 50 MB limit.');
      setStep('error');
      return;
    }

    setStep('uploading');
    setMsg('Uploading file…');
    setValidation(null);

    try {
      // 1. Create job row first
      const { data: jobRow, error: jobErr } = await supabase
        .from('bulk_upload_job')
        .insert({
          template_code: template.template_code,
          file_name:     file.name,
          storage_path:  'bulk-uploads/placeholder',   // updated after upload
          row_count:     0,
          status:        'validating',
          uploaded_by:   (await supabase.auth.getUser()).data.user?.id,
        })
        .select()
        .single();

      if (jobErr || !jobRow) throw new Error(jobErr?.message ?? 'Failed to create job');

      const newJobId = jobRow.id as string;
      setJobId(newJobId);
      onJobStarted(newJobId);

      // 2. Upload CSV to Storage
      const storagePath = `${newJobId}.csv`;
      const { error: upErr } = await supabase.storage
        .from('bulk-uploads')
        .upload(storagePath, file, { contentType: 'text/csv', upsert: true });

      if (upErr) throw new Error(upErr.message);

      // 3. Update storage_path on job row
      await supabase
        .from('bulk_upload_job')
        .update({ storage_path: `bulk-uploads/${storagePath}` })
        .eq('id', newJobId);

      // 4. Call validator Edge Function
      setStep('validating');
      setMsg('Validating rows…');

      const { data: { session } } = await supabase.auth.getSession();
      const resp = await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/bulk-import-validator`,
        {
          method: 'POST',
          headers: {
            'Content-Type':  'application/json',
            'Authorization': `Bearer ${session?.access_token}`,
            'apikey':        import.meta.env.VITE_SUPABASE_ANON_KEY,
          },
          body: JSON.stringify({ job_id: newJobId }),
        }
      );

      const result: ValidationResponse = await resp.json();

      if (!resp.ok || !result.ok) {
        throw new Error(result.error ?? 'Validation failed');
      }

      // Check for DELETE_RECORD
      setHasDeleteRecord(
        result.rows.some(r => Object.values(r.data).some(v => v?.trim() === 'DELETE_RECORD'))
      );

      setValidation(result);
      setStep('results');
    } catch (e: unknown) {
      const errMsg = e instanceof Error ? e.message : 'Unknown error';
      setMsg(errMsg);
      setStep('error');
    }
  }

  async function handleProcess(confirmedDeleteRecords = false, dryRun = false) {
    if (!jobId || !validation) return;

    // Guard: must have at least one valid row
    if (validation.counts.valid === 0) {
      setMsg('No valid rows to process.');
      return;
    }

    if (!dryRun && hasDeleteRecord && !confirmedDeleteRecords) {
      const ok = confirm(
        `This file contains DELETE_RECORD rows.\n\n` +
        `This will permanently close records as of the specified effective date. ` +
        `Committed rows cannot be undone via bulk operations.\n\nProceed?`
      );
      if (!ok) return;
      handleProcess(true, false);
      return;
    }

    setStep('processing');
    setMsg(dryRun ? 'Running preview (no data will be committed)…' : 'Processing rows…');

    try {
      const { data: { session } } = await supabase.auth.getSession();
      const resp = await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/bulk-import-processor`,
        {
          method: 'POST',
          headers: {
            'Content-Type':  'application/json',
            'Authorization': `Bearer ${session?.access_token}`,
            'apikey':        import.meta.env.VITE_SUPABASE_ANON_KEY,
          },
          body: JSON.stringify({
            job_id: jobId,
            confirmed_delete_records: confirmedDeleteRecords,
            dry_run: dryRun,
          }),
        }
      );

      const result = await resp.json();

      // 409 = concurrency lock conflict
      if (resp.status === 409) throw new Error(result.error ?? 'Another import is already running for this template');
      if (!resp.ok) throw new Error(result.error ?? 'Processing failed');

      if (dryRun) {
        setStep('done');
        setMsg(`Preview complete (no data committed) — ${result.succeeded} would succeed, ${result.failed} would fail.`);
      } else {
        setStep('done');
        setMsg(`Done — ${result.succeeded} succeeded, ${result.failed} failed, ${result.skipped} skipped.`);
      }
      onJobSettled();
    } catch (e: unknown) {
      setMsg(e instanceof Error ? e.message : 'Processing failed');
      setStep('error');
      onJobSettled();
    }
  }

  function reset() {
    setStep('idle');
    setMsg('');
    setValidation(null);
    setJobId(null);
    setHasDeleteRecord(false);
  }

  function downloadValidationReport() {
    if (!validation || validation.rows.length === 0) return;

    // Collect all original CSV column headers (from first row's data keys)
    const csvHeaders = Object.keys(validation.rows[0].data);

    // Build sheet: original columns + Row # + Status + Errors + Warnings
    const sheetRows = validation.rows.map(r => {
      const out: Record<string, string | number> = { 'Row #': r.row_number };
      for (const h of csvHeaders) out[h] = r.data[h] ?? '';
      out['Validation Status'] = r.status.toUpperCase();
      out['Errors']            = r.errors.join(' | ');
      out['Warnings']          = r.warnings.join(' | ');
      return out;
    });

    const ws = XLSX.utils.json_to_sheet(sheetRows);

    // Highlight error rows red, warning rows amber
    const range = XLSX.utils.decode_range(ws['!ref'] ?? 'A1');
    const statusColIdx = csvHeaders.length + 1; // Row# + csvHeaders + Status col
    for (let R = 1; R <= range.e.r; R++) {
      const statusCell = ws[XLSX.utils.encode_cell({ r: R, c: statusColIdx })];
      if (!statusCell) continue;
      const fill = statusCell.v === 'ERROR'
        ? { fgColor: { rgb: 'FEE2E2' } }   // red-100
        : statusCell.v === 'WARNING'
        ? { fgColor: { rgb: 'FEF9C3' } }   // yellow-100
        : { fgColor: { rgb: 'DCFCE7' } };  // green-100
      // Apply fill to all cells in this row
      for (let C = 0; C <= range.e.c; C++) {
        const addr = XLSX.utils.encode_cell({ r: R, c: C });
        if (!ws[addr]) ws[addr] = { v: '', t: 's' };
        ws[addr].s = { fill: { patternType: 'solid', ...fill } };
      }
    }

    // Auto column widths
    ws['!cols'] = [{ wch: 6 }, ...csvHeaders.map(h => ({ wch: Math.max(h.length + 2, 16) })), { wch: 18 }, { wch: 60 }, { wch: 40 }];

    // Summary sheet
    const summary = [
      { Metric: 'Template',    Value: template.display_label },
      { Metric: 'Total rows',  Value: validation.counts.total },
      { Metric: 'Valid',       Value: validation.counts.valid },
      { Metric: 'Errors',      Value: validation.counts.error },
      { Metric: 'Warnings',    Value: validation.counts.warning },
    ];

    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws,                                   'Validation Results');
    XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(summary),   'Summary');

    const date = new Date().toISOString().slice(0, 10);
    XLSX.writeFile(wb, `${template.template_code}_validation_${date}.xlsx`);
  }

  const counts = validation?.counts;

  return (
    <div style={{
      padding: '14px 16px', borderRadius: 8,
      border: '1px solid #E5E7EB', background: '#FAFAFA',
      marginBottom: 16,
    }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', marginBottom: 10, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
        Import data
      </div>

      {/* File picker — hidden when processing or done */}
      {(step === 'idle' || step === 'error') && (
        <>
          <input
            ref={fileRef}
            type="file"
            accept=".csv"
            style={{ display: 'none' }}
            onChange={handleFileChange}
          />
          <button
            onClick={() => fileRef.current?.click()}
            style={{
              display: 'inline-flex', alignItems: 'center', gap: 6,
              padding: '6px 14px', borderRadius: 6, fontSize: 13,
              border: '1px solid #D1D5DB', background: '#fff', color: '#374151',
              cursor: 'pointer', fontWeight: 500,
            }}
          >
            <i className="fa-solid fa-file-arrow-up" style={{ fontSize: 12 }} />
            Choose CSV file
          </button>
          {step === 'error' && msg && (
            <div style={{ marginTop: 8, fontSize: 12, color: '#DC2626' }}>
              <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 5 }} />
              {msg}
            </div>
          )}
        </>
      )}

      {/* In-progress spinner */}
      {(step === 'uploading' || step === 'validating' || step === 'processing') && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, color: '#1D4ED8', fontSize: 13 }}>
          <i className="fa-solid fa-spinner fa-spin" />
          {msg}
          {step === 'processing' && jobId && (
            <div style={{ marginLeft: 16 }}>
              <CancelInflightButton jobId={jobId} onCancel={() => { setStep('done'); onJobSettled(); }} />
            </div>
          )}
        </div>
      )}

      {/* Validation results */}
      {step === 'results' && validation && (
        <>
          {validation.header_warnings.length > 0 && (
            <div style={{ marginBottom: 8, fontSize: 12, color: '#92400E', background: '#FFFBEB', padding: '6px 10px', borderRadius: 4 }}>
              {validation.header_warnings.map((w, i) => <div key={i}>{w}</div>)}
            </div>
          )}

          <ValidationResultsTable
            rows={validation.rows}
            naturalKey={template.schema_definition.natural_key}
          />

          {/* Diff preview */}
          {validation.diff_preview && (validation.diff_preview.new_count > 0 || validation.diff_preview.update_count > 0) && (
            <div style={{
              display: 'flex', gap: 16, marginTop: 10,
              padding: '8px 12px', borderRadius: 6,
              background: '#EFF6FF', border: '1px solid #BFDBFE',
              fontSize: 12, color: '#1E40AF',
            }}>
              <span>
                <i className="fa-solid fa-chart-bar" style={{ marginRight: 5 }} />
                Preview:
              </span>
              {validation.diff_preview.new_count > 0 && (
                <span>
                  <i className="fa-solid fa-plus-circle" style={{ marginRight: 4, color: '#16A34A' }} />
                  <strong>{validation.diff_preview.new_count}</strong> new
                </span>
              )}
              {validation.diff_preview.update_count > 0 && (
                <span>
                  <i className="fa-solid fa-pen-to-square" style={{ marginRight: 4, color: '#D97706' }} />
                  <strong>{validation.diff_preview.update_count}</strong> update{validation.diff_preview.update_count !== 1 ? 's' : ''}
                </span>
              )}
              <span style={{ color: '#6B7280', fontSize: 11 }}>
                (informational — based on natural key lookup)
              </span>
            </div>
          )}

          <div style={{ display: 'flex', gap: 8, marginTop: 14, alignItems: 'center', flexWrap: 'wrap' }}>
            {counts && counts.valid > 0 && (
              <>
                <button
                  onClick={() => handleProcess(false, true)}
                  style={{
                    display: 'inline-flex', alignItems: 'center', gap: 6,
                    padding: '7px 16px', borderRadius: 6, fontSize: 13,
                    background: '#fff', border: '1px solid #D1D5DB', color: '#374151',
                    cursor: 'pointer', fontWeight: 500,
                  }}
                  title="Simulate the import without committing any data. Shows exactly which rows would succeed or fail."
                >
                  <i className="fa-solid fa-eye" style={{ fontSize: 11 }} />
                  Preview run
                </button>
                <button
                  onClick={() => handleProcess()}
                  style={{
                    display: 'inline-flex', alignItems: 'center', gap: 6,
                    padding: '7px 16px', borderRadius: 6, fontSize: 13,
                    background: '#16A34A', border: 'none', color: '#fff',
                    cursor: 'pointer', fontWeight: 600,
                  }}
                >
                  <i className="fa-solid fa-play" style={{ fontSize: 11 }} />
                  Process {counts.valid} valid row{counts.valid !== 1 ? 's' : ''}
                  {counts.error > 0 && <span style={{ opacity: 0.8, fontSize: 11 }}> (skip {counts.error} errors)</span>}
                </button>
              </>
            )}
            <button
              onClick={downloadValidationReport}
              title="Download an Excel report showing each row's status, employee code, and error details"
              style={{
                display: 'inline-flex', alignItems: 'center', gap: 6,
                padding: '7px 14px', borderRadius: 6, fontSize: 13,
                border: '1px solid #D1D5DB', background: '#fff', color: '#374151',
                cursor: 'pointer',
              }}
            >
              <i className="fa-solid fa-file-excel" style={{ fontSize: 12, color: '#16A34A' }} />
              Download report
            </button>
            <button
              onClick={reset}
              style={{
                padding: '7px 14px', borderRadius: 6, fontSize: 13,
                border: '1px solid #D1D5DB', background: '#fff', color: '#374151',
                cursor: 'pointer',
              }}
            >
              Cancel
            </button>
          </div>
        </>
      )}

      {/* Done state */}
      {step === 'done' && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <span style={{ fontSize: 13, color: '#166534' }}>
            <i className="fa-solid fa-circle-check" style={{ marginRight: 6 }} />
            {msg}
          </span>
          <button onClick={reset} style={{ fontSize: 12, color: '#1D4ED8', background: 'none', border: 'none', cursor: 'pointer', textDecoration: 'underline' }}>
            Import another file
          </button>
        </div>
      )}

      {/* Row count warning at 5000 */}
      {validation && counts && counts.total >= 5000 && counts.total < 10000 && (
        <div style={{ marginTop: 8, fontSize: 12, color: '#92400E' }}>
          <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 5 }} />
          {counts.total} rows — large file. Processing may take a few minutes.
        </div>
      )}
    </div>
  );
}
