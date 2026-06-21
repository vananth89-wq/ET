/**
 * RecentUploadsPanel
 *
 * Lists bulk_upload_job rows for the selected template — 25 per page.
 * Eye button opens a detail modal.
 * Uploader sees their own rows; System Admin sees all (RLS-enforced).
 */

import { useState, useEffect, useCallback } from 'react';
import { fetchRecentUploads } from '../../../hooks/useBulkUploadJob';
import type { BulkUploadJob } from '../../../hooks/useBulkUploadJob';
import { supabase } from '../../../lib/supabase';

interface JobLogEntry {
  row_number:  number;
  action:      'created' | 'updated' | 'failed' | 'skipped';
  natural_key: Record<string, string>;
  error?:      string;
  created_at:  string;
}

const PAGE_SIZE = 25;

interface Props {
  templateCode: string;
  activeJobId:  string | null;
  refreshKey:   number;
  onSelectJob:  (jobId: string) => void;
}

const STATUS_STYLE: Record<string, { bg: string; color: string; label: string }> = {
  validating:    { bg: '#EFF6FF', color: '#1D4ED8', label: 'Validating…'    },
  awaiting_user: { bg: '#FEF9C3', color: '#854D0E', label: 'Awaiting action' },
  processing:    { bg: '#EFF6FF', color: '#1D4ED8', label: 'Processing…'    },
  completed:     { bg: '#DCFCE7', color: '#166534', label: 'Completed'      },
  partial:       { bg: '#FEF9C3', color: '#854D0E', label: 'Partial'        },
  cancelled:     { bg: '#F3F4F6', color: '#6B7280', label: 'Cancelled'      },
  failed:        { bg: '#FEE2E2', color: '#991B1B', label: 'Failed'         },
};

export default function RecentUploadsPanel({ templateCode, activeJobId, refreshKey, onSelectJob }: Props) {
  const [jobs,       setJobs]       = useState<BulkUploadJob[]>([]);
  const [loading,    setLoading]    = useState(false);
  const [page,       setPage]       = useState(0);          // 0-based
  const [hasMore,    setHasMore]    = useState(false);
  const [detailJob,  setDetailJob]  = useState<BulkUploadJob | null>(null);

  useEffect(() => {
    if (!templateCode) return;
    setPage(0);
  }, [templateCode, refreshKey]);

  useEffect(() => {
    if (!templateCode) return;
    setLoading(true);
    fetchRecentUploads(templateCode, PAGE_SIZE, page * PAGE_SIZE).then(({ jobs: rows, hasMore: more }) => {
      setJobs(rows);
      setHasMore(more);
      setLoading(false);
    });
  }, [templateCode, refreshKey, page]);

  function openDetail(job: BulkUploadJob) {
    onSelectJob(job.id);   // keep parent polling / highlight behaviour
    setDetailJob(job);
  }

  if (!templateCode) return null;

  return (
    <div style={{ marginTop: 24 }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', marginBottom: 10, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
        Recent uploads
      </div>

      {loading ? (
        <div style={{ color: '#6B7280', fontSize: 12 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} /> Loading…
        </div>
      ) : jobs.length === 0 ? (
        <div style={{ fontSize: 12, color: '#9CA3AF' }}>No uploads yet for this template.</div>
      ) : (
        <>
          <div style={{ border: '1px solid #E5E7EB', borderRadius: 6, overflow: 'hidden' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr style={{ background: '#F9FAFB', borderBottom: '1px solid #E5E7EB' }}>
                  <th style={thStyle}>File</th>
                  <th style={thStyle}>Uploaded</th>
                  <th style={thStyle}>Rows</th>
                  <th style={thStyle}>Results</th>
                  <th style={thStyle}>Status</th>
                  <th style={thStyle}></th>
                </tr>
              </thead>
              <tbody>
                {jobs.map(job => {
                  const st = STATUS_STYLE[job.status] ?? STATUS_STYLE.failed;
                  const isActive = job.id === activeJobId;
                  return (
                    <tr
                      key={job.id}
                      style={{
                        borderBottom: '0.5px solid #F3F4F6',
                        background: isActive ? '#EFF6FF' : undefined,
                      }}
                    >
                      <td style={tdStyle}>
                        <span style={{ fontFamily: 'monospace', color: '#374151' }}>
                          {job.file_name}
                        </span>
                      </td>
                      <td style={{ ...tdStyle, color: '#6B7280' }}>
                        {new Date(job.uploaded_at).toLocaleString()}
                      </td>
                      <td style={{ ...tdStyle, color: '#374151' }}>
                        {job.row_count ?? '—'}
                      </td>
                      <td style={tdStyle}>
                        {job.status === 'awaiting_user' ? (
                          <span style={{ color: '#6B7280' }}>
                            {job.valid_count ?? 0}✓ {job.error_count ? `${job.error_count}✗` : ''}
                          </span>
                        ) : job.succeeded_count > 0 || job.failed_count > 0 ? (
                          <span>
                            <span style={{ color: '#16A34A' }}>{job.succeeded_count}✓</span>
                            {job.failed_count  > 0 && <span style={{ color: '#DC2626', marginLeft: 6 }}>{job.failed_count}✗</span>}
                            {job.skipped_count > 0 && <span style={{ color: '#9CA3AF', marginLeft: 6 }}>{job.skipped_count} skip</span>}
                          </span>
                        ) : '—'}
                      </td>
                      <td style={tdStyle}>
                        <span style={{
                          background: st.bg, color: st.color,
                          padding: '2px 8px', borderRadius: 10,
                          fontWeight: 600, fontSize: 11,
                        }}>
                          {st.label}
                        </span>
                        {(job as BulkUploadJob & { is_dry_run?: boolean }).is_dry_run && (
                          <span style={{
                            marginLeft: 5, background: '#F3F4F6', color: '#6B7280',
                            padding: '1px 6px', borderRadius: 8, fontSize: 10, fontWeight: 500,
                          }}>
                            preview
                          </span>
                        )}
                      </td>
                      <td style={tdStyle}>
                        <div style={{ display: 'flex', gap: 6 }}>
                          <button
                            onClick={() => openDetail(job)}
                            style={{ ...iconBtn, ...(isActive ? iconBtnActive : {}) }}
                            title="View details"
                          >
                            <i className="fa-solid fa-eye" style={{ fontSize: 11 }} />
                          </button>
                          {job.error_file_path && (
                            <DownloadErrorBtn storagePath={job.error_file_path} />
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {/* Pagination */}
          {(page > 0 || hasMore) && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 8 }}>
              <button
                onClick={() => setPage(p => p - 1)}
                disabled={page === 0}
                style={pagBtn(page === 0)}
              >
                ← Prev
              </button>
              <span style={{ fontSize: 12, color: '#6B7280', alignSelf: 'center' }}>
                Page {page + 1}
              </span>
              <button
                onClick={() => setPage(p => p + 1)}
                disabled={!hasMore}
                style={pagBtn(!hasMore)}
              >
                Next →
              </button>
            </div>
          )}
        </>
      )}

      {/* Detail modal */}
      {detailJob && (
        <JobDetailModal job={detailJob} onClose={() => setDetailJob(null)} />
      )}
    </div>
  );
}

// ─── Job Detail Modal ─────────────────────────────────────────────────────────

function JobDetailModal({ job, onClose }: { job: BulkUploadJob; onClose: () => void }) {
  const st = STATUS_STYLE[job.status] ?? STATUS_STYLE.failed;
  const [tab,     setTab]     = useState<'summary' | 'changes'>('summary');
  const [log,     setLog]     = useState<JobLogEntry[] | null>(null);
  const [logLoad, setLogLoad] = useState(false);
  const [logErr,  setLogErr]  = useState<string | null>(null);

  const loadLog = useCallback(async () => {
    if (log !== null) return;
    setLogLoad(true);
    setLogErr(null);
    try {
      const { data, error } = await supabase.rpc('get_bulk_job_log', { p_job_id: job.id });
      if (error) throw error;
      setLog((data as JobLogEntry[]) ?? []);
    } catch (e: unknown) {
      setLogErr(e instanceof Error ? e.message : 'Failed to load changes');
    } finally {
      setLogLoad(false);
    }
  }, [job.id, log]);

  useEffect(() => {
    if (tab === 'changes') loadLog();
  }, [tab, loadLog]);

  const actionStyle = (action: string): React.CSSProperties => {
    if (action === 'created')  return { color: '#16A34A', fontWeight: 600 };
    if (action === 'updated')  return { color: '#D97706', fontWeight: 600 };
    if (action === 'failed')   return { color: '#DC2626', fontWeight: 600 };
    return { color: '#9CA3AF' };
  };

  return (
    <div
      style={{
        position: 'fixed', inset: 0, zIndex: 1000,
        background: 'rgba(0,0,0,0.35)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}
      onClick={onClose}
    >
      <div
        style={{
          background: '#fff', borderRadius: 10, padding: 28,
          minWidth: 520, maxWidth: 720, width: '90vw', maxHeight: '85vh',
          display: 'flex', flexDirection: 'column',
          boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
        }}
        onClick={e => e.stopPropagation()}
      >
        {/* Header */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 16 }}>
          <div>
            <div style={{ fontSize: 15, fontWeight: 700, color: '#111827', marginBottom: 4 }}>
              Upload Details
            </div>
            <span style={{ fontFamily: 'monospace', fontSize: 12, color: '#6B7280' }}>
              {job.file_name}
            </span>
          </div>
          <button onClick={onClose} style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 18 }}>
            ✕
          </button>
        </div>

        {/* Status badge */}
        <div style={{ marginBottom: 16 }}>
          <span style={{
            background: st.bg, color: st.color,
            padding: '3px 10px', borderRadius: 10,
            fontWeight: 700, fontSize: 12,
          }}>
            {st.label}
          </span>
        </div>

        {/* Tabs */}
        <div style={{ display: 'flex', borderBottom: '1px solid #E5E7EB', marginBottom: 16 }}>
          {(['summary', 'changes'] as const).map(t => (
            <button
              key={t}
              onClick={() => setTab(t)}
              style={{
                padding: '7px 16px', border: 'none', background: 'none',
                cursor: 'pointer', fontSize: 13, fontWeight: tab === t ? 600 : 400,
                color: tab === t ? '#1D4ED8' : '#6B7280',
                borderBottom: tab === t ? '2px solid #1D4ED8' : '2px solid transparent',
                marginBottom: -1,
              }}
            >
              {t === 'summary' ? 'Summary' : `Changes${log ? ` (${log.length})` : ''}`}
            </button>
          ))}
        </div>

        {/* Tab content */}
        <div style={{ flex: 1, overflowY: 'auto' }}>
          {tab === 'summary' && (
            <>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '10px 24px', fontSize: 13 }}>
                <DetailRow label="Uploaded" value={new Date(job.uploaded_at).toLocaleString()} />
                <DetailRow label="Total rows" value={String(job.row_count ?? '—')} />
                <DetailRow label="Succeeded" value={String(job.succeeded_count)} valueColor="#16A34A" />
                <DetailRow label="Failed" value={String(job.failed_count)} valueColor={job.failed_count > 0 ? '#DC2626' : undefined} />
                <DetailRow label="Skipped" value={String(job.skipped_count)} />
                {job.completed_at && (
                  <DetailRow label="Completed" value={new Date(job.completed_at).toLocaleString()} />
                )}
                {job.cancelled_at && (
                  <DetailRow label="Cancelled" value={new Date(job.cancelled_at).toLocaleString()} />
                )}
              </div>
              {job.error_file_path && (
                <div style={{ marginTop: 20, paddingTop: 16, borderTop: '1px solid #F3F4F6', display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <DownloadErrorBtn storagePath={job.error_file_path} label="Download error report" />
                  <RetryFailedRowsBtn storagePath={job.error_file_path} fileName={job.file_name} />
                  <div style={{ fontSize: 11, color: '#9CA3AF' }}>
                    "Download rows to retry" strips the summary header and Row #/Error columns —
                    fix the data and re-import it directly.
                  </div>
                </div>
              )}
            </>
          )}

          {tab === 'changes' && (
            <>
              {logLoad && (
                <div style={{ color: '#6B7280', fontSize: 13 }}>
                  <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
                  Loading changes…
                </div>
              )}
              {logErr && (
                <div style={{ color: '#DC2626', fontSize: 13 }}>{logErr}</div>
              )}
              {log && log.length === 0 && (
                <div style={{ color: '#9CA3AF', fontSize: 13 }}>
                  No change log available for this job.
                  <div style={{ marginTop: 4, fontSize: 11 }}>
                    (Jobs processed before mig 426 don't have row-level logs.)
                  </div>
                </div>
              )}
              {log && log.length > 0 && (
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                  <thead>
                    <tr style={{ background: '#F9FAFB', borderBottom: '1px solid #E5E7EB' }}>
                      <th style={thStyle}>Row #</th>
                      <th style={thStyle}>Action</th>
                      <th style={thStyle}>Record</th>
                      <th style={thStyle}>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    {log.map((entry, i) => (
                      <tr key={i} style={{ borderBottom: '0.5px solid #F3F4F6' }}>
                        <td style={{ ...tdStyle, color: '#9CA3AF' }}>{entry.row_number}</td>
                        <td style={{ ...tdStyle, ...actionStyle(entry.action) }}>
                          {entry.action === 'created' && <><i className="fa-solid fa-plus" style={{ marginRight: 4 }} />New</>}
                          {entry.action === 'updated' && <><i className="fa-solid fa-pen" style={{ marginRight: 4 }} />Updated</>}
                          {entry.action === 'failed'  && <><i className="fa-solid fa-xmark" style={{ marginRight: 4 }} />Failed</>}
                          {entry.action === 'skipped' && <>Skipped</>}
                        </td>
                        <td style={tdStyle}>
                          <span style={{ fontFamily: 'monospace', fontSize: 11, color: '#374151' }}>
                            {Object.values(entry.natural_key).filter(Boolean).join(' · ')}
                          </span>
                        </td>
                        <td style={{ ...tdStyle, color: '#DC2626', fontSize: 11, maxWidth: 200, wordBreak: 'break-word' }}>
                          {entry.error ?? ''}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function DetailRow({ label, value, valueColor }: { label: string; value: string; valueColor?: string }) {
  return (
    <div>
      <div style={{ fontSize: 11, color: '#9CA3AF', marginBottom: 2 }}>{label}</div>
      <div style={{ fontWeight: 600, color: valueColor ?? '#111827' }}>{value}</div>
    </div>
  );
}

// ─── Download error CSV ───────────────────────────────────────────────────────

function DownloadErrorBtn({ storagePath, label }: { storagePath: string; label?: string }) {
  async function download() {
    const path = storagePath.replace('bulk-uploads/', '');
    const { data } = await supabase.storage.from('bulk-uploads').createSignedUrl(path, 60);
    if (data?.signedUrl) window.open(data.signedUrl, '_blank');
  }
  return (
    <button onClick={download} style={label ? downloadBtnFull : iconBtn} title="Download error file">
      {label ? (
        <><i className="fa-solid fa-file-csv" style={{ marginRight: 6, color: '#DC2626' }} />{label}</>
      ) : (
        <i className="fa-solid fa-file-csv" style={{ fontSize: 11, color: '#DC2626' }} />
      )}
    </button>
  );
}

// ─── Retry failed rows ────────────────────────────────────────────────────────
// Strips the # summary header + Row # and Error columns from the error CSV,
// producing a clean file the user can fix and re-import directly.

function RetryFailedRowsBtn({ storagePath, fileName }: { storagePath: string; fileName: string }) {
  const [busy, setBusy] = useState(false);

  async function handleRetry() {
    setBusy(true);
    try {
      const path = storagePath.replace('bulk-uploads/', '');
      const { data: blob } = await supabase.storage.from('bulk-uploads').download(path);
      if (!blob) return;

      const text = await blob.text();
      const lines = text.split('\n');

      // Strip BOM, comment lines, and the Row#/Error columns
      const dataLines = lines
        .map(l => l.replace(/^﻿/, '').trimEnd())
        .filter(l => l && !l.startsWith('#'));

      if (dataLines.length < 2) return; // header only or empty

      // Parse header and find indexes of "Row #" and "Error" columns
      const headerCells = parseCsvLine(dataLines[0]);
      const skipIdxs = new Set(
        headerCells
          .map((h, i) => (['Row #', 'Error'].includes(h.trim()) ? i : -1))
          .filter(i => i >= 0)
      );

      const retryLines = dataLines.map(line => {
        const cells = parseCsvLine(line);
        const kept = cells.filter((_, i) => !skipIdxs.has(i));
        return kept.map(c => (c.includes(',') || c.includes('"') || c.includes('\n'))
          ? `"${c.replace(/"/g, '""')}"` : c
        ).join(',');
      });

      const csv = '﻿' + retryLines.join('\r\n');
      const retryName = fileName.replace(/_errors\.csv$/, '_retry.csv').replace(/\.csv$/, '_retry.csv');
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
      a.download = retryName;
      document.body.appendChild(a); a.click();
      document.body.removeChild(a);
    } finally {
      setBusy(false);
    }
  }

  function parseCsvLine(line: string): string[] {
    const cells: string[] = [];
    let cur = '', inQ = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (inQ) {
        if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
        else if (ch === '"') inQ = false;
        else cur += ch;
      } else {
        if (ch === '"') inQ = true;
        else if (ch === ',') { cells.push(cur); cur = ''; }
        else cur += ch;
      }
    }
    cells.push(cur);
    return cells;
  }

  return (
    <button
      onClick={handleRetry}
      disabled={busy}
      style={{ ...downloadBtnFull, color: '#D97706', borderColor: '#FDE68A', background: '#FFFBEB' }}
      title="Download failed rows as a clean CSV ready for re-import"
    >
      <i className={`fa-solid ${busy ? 'fa-spinner fa-spin' : 'fa-rotate-right'}`} style={{ marginRight: 6 }} />
      Download rows to retry
    </button>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const thStyle: React.CSSProperties = {
  padding: '7px 12px', textAlign: 'left',
  fontSize: 11, fontWeight: 600, color: '#6B7280', textTransform: 'uppercase',
};
const tdStyle: React.CSSProperties = { padding: '7px 12px', verticalAlign: 'middle' };
const iconBtn: React.CSSProperties = {
  padding: '3px 7px', borderRadius: 4, border: '1px solid #E5E7EB',
  background: '#fff', cursor: 'pointer', color: '#6B7280',
};
const iconBtnActive: React.CSSProperties = {
  borderColor: '#93C5FD', background: '#EFF6FF', color: '#1D4ED8',
};
const downloadBtnFull: React.CSSProperties = {
  padding: '6px 12px', borderRadius: 6, border: '1px solid #E5E7EB',
  background: '#fff', cursor: 'pointer', color: '#374151', fontSize: 13,
  display: 'flex', alignItems: 'center',
};
const pagBtn = (disabled: boolean): React.CSSProperties => ({
  padding: '4px 12px', borderRadius: 5,
  border: '1px solid #E5E7EB',
  background: disabled ? '#F9FAFB' : '#fff',
  color: disabled ? '#D1D5DB' : '#374151',
  cursor: disabled ? 'default' : 'pointer',
  fontSize: 12,
});
