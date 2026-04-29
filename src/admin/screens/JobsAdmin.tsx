/**
 * JobsAdmin
 *
 * Admin screen for monitoring and manually triggering background jobs.
 * Shows each registered job's last run status, duration, and a Run Now button.
 * Clicking a job card expands the recent run history.
 *
 * Route: /admin/jobs  (requires system.admin or admin role)
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth }  from '../../contexts/AuthContext';

// ─── Types ────────────────────────────────────────────────────────────────────

interface JobRun {
  id:            string;
  jobCode:       string;
  jobName:       string;
  triggeredBy:   string | null;   // profile id
  startedAt:     string;
  completedAt:   string | null;
  durationMs:    number | null;
  status:        'running' | 'success' | 'partial' | 'failed';
  rowsProcessed: number | null;
  summary:       Record<string, number> | null;
  errorMessage:  string | null;
}

// Static registry of known jobs — extend as new jobs are added
const REGISTERED_JOBS = [
  {
    code:        'wf_sla_monitor',
    name:        'Workflow SLA Monitor',
    description: 'Sends reminder notifications and escalates overdue approval tasks to the assignee\'s line manager.',
    schedule:    'Every 15 minutes',
    icon:        'fa-clock-rotate-left',
    rpc:         'wf_process_sla_events',
    summaryKeys: [
      { key: 'reminders',   label: 'Reminders sent',  color: '#2F77B5' },
      { key: 'escalations', label: 'Escalated',        color: '#D97706' },
      { key: 'skipped',     label: 'Skipped',           color: '#6B7280' },
      { key: 'errors',      label: 'Errors',            color: '#DC2626' },
    ],
  },
  {
    code:        'wf_retry_failed_emails',
    name:        'Email Retry',
    description: 'Re-queues any failed email notifications from the last 24 hours and retries delivery via Resend.',
    schedule:    'On demand',
    icon:        'fa-envelope-circle-check',
    rpc:         'wf_retry_failed_emails',
    summaryKeys: [
      { key: 'retried', label: 'Retried', color: '#2F77B5' },
    ],
  },
];

// ─── Colour tokens ────────────────────────────────────────────────────────────

const C = {
  navy:   '#18345B',
  blue:   '#2F77B5',
  blueL:  '#EFF6FF',
  border: '#E5E7EB',
  bg:     '#F9FAFB',
  text:   '#111827',
  muted:  '#6B7280',
  faint:  '#9CA3AF',
  green:  '#16A34A',
  greenL: '#DCFCE7',
  red:    '#DC2626',
  redL:   '#FEF2F2',
  amber:  '#D97706',
  amberL: '#FFF7ED',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtDate(iso: string | null) {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).format(new Date(iso));
}

function relativeTime(iso: string) {
  const diff = Date.now() - new Date(iso).getTime();
  const s = Math.floor(diff / 1000);
  if (s < 60)   return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60)   return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24)   return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

function fmtDuration(ms: number | null) {
  if (ms === null) return '—';
  if (ms < 1000)   return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function StatusDot({ status }: { status: JobRun['status'] | 'never' }) {
  const map: Record<string, { color: string; label: string; pulse?: boolean }> = {
    running: { color: C.blue,  label: 'Running',  pulse: true },
    success: { color: C.green, label: 'Success' },
    partial: { color: C.amber, label: 'Partial' },
    failed:  { color: C.red,   label: 'Failed'  },
    never:   { color: C.faint, label: 'Never run' },
  };
  const s = map[status] ?? map.never;
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
      <span style={{
        width: 8, height: 8, borderRadius: '50%',
        background: s.color,
        boxShadow: s.pulse ? `0 0 0 3px ${s.color}33` : undefined,
        display: 'inline-block',
        animation: s.pulse ? 'pulse 1.5s infinite' : undefined,
      }} />
      <span style={{ fontSize: 12, fontWeight: 600, color: s.color }}>{s.label}</span>
    </span>
  );
}

function StatusBadge({ status }: { status: JobRun['status'] }) {
  const map: Record<string, { bg: string; color: string }> = {
    running: { bg: C.blueL,  color: C.blue  },
    success: { bg: C.greenL, color: C.green },
    partial: { bg: C.amberL, color: C.amber },
    failed:  { bg: C.redL,   color: C.red   },
  };
  const s = map[status] ?? { bg: C.bg, color: C.muted };
  return (
    <span style={{
      fontSize: 10, fontWeight: 700, padding: '2px 7px',
      borderRadius: 4, background: s.bg, color: s.color,
      textTransform: 'uppercase', letterSpacing: '0.05em',
    }}>
      {status}
    </span>
  );
}

// ─── Main Component ───────────────────────────────────────────────────────────

export default function JobsAdmin() {
  const { profile } = useAuth();

  const [runs,       setRuns]       = useState<JobRun[]>([]);
  const [loading,    setLoading]    = useState(false);
  const [running,    setRunning]    = useState<Record<string, boolean>>({});
  const [expanded,   setExpanded]   = useState<string | null>(null);
  const [toast,      setToast]      = useState<{ type: 'ok' | 'err'; msg: string } | null>(null);
  const [runResult,  setRunResult]  = useState<Record<string, Record<string, number>>>({});

  function showToast(type: 'ok' | 'err', msg: string) {
    setToast({ type, msg });
    setTimeout(() => setToast(null), 5000);
  }

  const loadRuns = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from('job_run_log')
      .select('*')
      .order('started_at', { ascending: false })
      .limit(200);

    if (error) {
      showToast('err', error.message);
    } else {
      setRuns((data ?? []).map((r: any) => ({
        id:            r.id,
        jobCode:       r.job_code,
        jobName:       r.job_name,
        triggeredBy:   r.triggered_by,
        startedAt:     r.started_at,
        completedAt:   r.completed_at,
        durationMs:    r.duration_ms,
        status:        r.status,
        rowsProcessed: r.rows_processed,
        summary:       r.summary,
        errorMessage:  r.error_message,
      })));
    }
    setLoading(false);
  }, []);

  useEffect(() => { loadRuns(); }, [loadRuns]);

  async function runNow(jobCode: string, rpc: string) {
    setRunning(p => ({ ...p, [jobCode]: true }));
    setRunResult(p => ({ ...p, [jobCode]: {} }));

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data, error } = await (supabase as any).rpc(rpc, {
      p_triggered_by: profile?.id ?? null,
    });

    setRunning(p => ({ ...p, [jobCode]: false }));

    if (error) {
      showToast('err', `Job failed: ${error.message}`);
    } else {
      const result = data as Record<string, number>;
      setRunResult(p => ({ ...p, [jobCode]: result }));
      const parts = Object.entries(result)
        .filter(([, v]) => v > 0)
        .map(([k, v]) => `${v} ${k}`)
        .join(', ');
      showToast('ok', parts ? `Done — ${parts}` : 'Done — nothing to process');
      await loadRuns();
    }
  }

  return (
    <div style={{ padding: '32px 40px', maxWidth: 900, margin: '0 auto' }}>

      {/* ── Header ──────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 28 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: C.navy, margin: 0 }}>
            Background Jobs
          </h1>
          <p style={{ fontSize: 13, color: C.muted, marginTop: 4 }}>
            Monitor scheduled jobs and trigger manual runs
          </p>
        </div>
        <button
          onClick={loadRuns}
          style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '7px 14px', borderRadius: 7,
            border: `1px solid ${C.border}`, background: '#fff',
            fontSize: 13, fontWeight: 500, color: C.text, cursor: 'pointer',
          }}
        >
          <i className={`fas fa-arrows-rotate${loading ? ' fa-spin' : ''}`} style={{ fontSize: 12 }} />
          Refresh
        </button>
      </div>

      {/* ── Toast ───────────────────────────────────────────────────────────── */}
      {toast && (
        <div style={{
          position: 'fixed', top: 20, right: 24, zIndex: 9999,
          padding: '10px 18px', borderRadius: 8,
          background: toast.type === 'ok' ? C.greenL : C.redL,
          border: `1px solid ${toast.type === 'ok' ? '#BBF7D0' : '#FECACA'}`,
          color: toast.type === 'ok' ? C.green : C.red,
          fontSize: 13, fontWeight: 600, boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
          display: 'flex', alignItems: 'center', gap: 8,
        }}>
          <i className={`fas ${toast.type === 'ok' ? 'fa-circle-check' : 'fa-circle-xmark'}`} />
          {toast.msg}
        </div>
      )}

      {/* ── Job cards ───────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        {REGISTERED_JOBS.map(job => {
          const jobRuns   = runs.filter(r => r.jobCode === job.code);
          const lastRun   = jobRuns[0] ?? null;
          const isRunning = running[job.code] ?? false;
          const isExpanded= expanded === job.code;
          const freshResult = runResult[job.code];

          return (
            <div
              key={job.code}
              style={{
                background: '#fff', borderRadius: 12,
                border: `1px solid ${C.border}`,
                boxShadow: '0 1px 4px rgba(0,0,0,0.04)',
                overflow: 'hidden',
              }}
            >
              {/* ── Card header ────────────────────────────────────────────── */}
              <div style={{ padding: '20px 24px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 16 }}>
                  {/* Left: icon + name + meta */}
                  <div style={{ display: 'flex', gap: 14, alignItems: 'flex-start', flex: 1, minWidth: 0 }}>
                    <div style={{
                      width: 42, height: 42, borderRadius: 10,
                      background: C.blueL, color: C.blue,
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      flexShrink: 0,
                    }}>
                      <i className={`fas ${job.icon}`} style={{ fontSize: 18 }} />
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 15, fontWeight: 700, color: C.navy }}>{job.name}</div>
                      <div style={{ fontSize: 12, color: C.muted, marginTop: 2 }}>{job.description}</div>
                      <div style={{ display: 'flex', gap: 16, marginTop: 8, flexWrap: 'wrap' }}>
                        <span style={{ fontSize: 12, color: C.muted, display: 'flex', alignItems: 'center', gap: 5 }}>
                          <i className="fas fa-calendar-clock" style={{ fontSize: 10, color: C.faint }} />
                          {job.schedule}
                        </span>
                        {lastRun ? (
                          <>
                            <span style={{ fontSize: 12, color: C.muted, display: 'flex', alignItems: 'center', gap: 5 }}>
                              <i className="fas fa-clock" style={{ fontSize: 10, color: C.faint }} />
                              Last run: {relativeTime(lastRun.startedAt)}
                            </span>
                            <span style={{ fontSize: 12, color: C.muted, display: 'flex', alignItems: 'center', gap: 5 }}>
                              <i className="fas fa-timer" style={{ fontSize: 10, color: C.faint }} />
                              {fmtDuration(lastRun.durationMs)}
                            </span>
                            <StatusDot status={lastRun.status} />
                          </>
                        ) : (
                          <StatusDot status="never" />
                        )}
                      </div>
                    </div>
                  </div>

                  {/* Right: actions */}
                  <div style={{ display: 'flex', gap: 8, flexShrink: 0, alignItems: 'center' }}>
                    <button
                      onClick={() => setExpanded(isExpanded ? null : job.code)}
                      style={{
                        padding: '6px 12px', borderRadius: 6,
                        border: `1px solid ${C.border}`, background: '#fff',
                        fontSize: 12, fontWeight: 500, color: C.muted,
                        cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 5,
                      }}
                    >
                      <i className={`fas fa-chevron-${isExpanded ? 'up' : 'down'}`} style={{ fontSize: 10 }} />
                      History
                    </button>
                    <button
                      onClick={() => runNow(job.code, job.rpc)}
                      disabled={isRunning}
                      style={{
                        padding: '6px 16px', borderRadius: 6, border: 'none',
                        background: isRunning ? C.blueL : C.blue,
                        color: isRunning ? C.blue : '#fff',
                        fontSize: 12, fontWeight: 600,
                        cursor: isRunning ? 'not-allowed' : 'pointer',
                        display: 'flex', alignItems: 'center', gap: 6,
                        transition: 'background 0.15s',
                      }}
                    >
                      <i className={`fas ${isRunning ? 'fa-spinner fa-spin' : 'fa-play'}`} style={{ fontSize: 10 }} />
                      {isRunning ? 'Running…' : 'Run Now'}
                    </button>
                  </div>
                </div>

                {/* ── Last-run result stats (shown after manual run) ──────── */}
                {freshResult && Object.keys(freshResult).length > 0 && (
                  <div style={{
                    marginTop: 16, padding: '12px 16px',
                    background: C.bg, borderRadius: 8,
                    border: `1px solid ${C.border}`,
                    display: 'flex', gap: 24, flexWrap: 'wrap',
                  }}>
                    <span style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.05em', alignSelf: 'center' }}>
                      Last result
                    </span>
                    {job.summaryKeys.map(sk => {
                      const val = freshResult[sk.key] ?? 0;
                      return (
                        <div key={sk.key} style={{ textAlign: 'center' }}>
                          <div style={{ fontSize: 22, fontWeight: 800, color: val > 0 ? sk.color : C.faint }}>
                            {val}
                          </div>
                          <div style={{ fontSize: 11, color: C.muted }}>{sk.label}</div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>

              {/* ── Run history (expandable) ───────────────────────────────── */}
              {isExpanded && (
                <div style={{ borderTop: `1px solid ${C.border}` }}>
                  {/* History header */}
                  <div style={{
                    padding: '10px 24px',
                    background: C.bg,
                    fontSize: 11, fontWeight: 700,
                    color: C.muted, textTransform: 'uppercase', letterSpacing: '0.05em',
                    display: 'grid',
                    gridTemplateColumns: '1fr 90px 80px 100px 1fr',
                    gap: 12,
                  }}>
                    <span>Started</span>
                    <span>Duration</span>
                    <span>Rows</span>
                    <span>Status</span>
                    <span>Summary</span>
                  </div>

                  {jobRuns.length === 0 ? (
                    <div style={{ padding: '24px', textAlign: 'center', color: C.faint, fontSize: 13 }}>
                      No run history yet.
                    </div>
                  ) : (
                    jobRuns.slice(0, 20).map(run => (
                      <div
                        key={run.id}
                        style={{
                          padding: '10px 24px',
                          borderTop: `1px solid ${C.border}`,
                          display: 'grid',
                          gridTemplateColumns: '1fr 90px 80px 100px 1fr',
                          gap: 12, alignItems: 'center',
                          fontSize: 12,
                        }}
                      >
                        {/* Started */}
                        <div>
                          <div style={{ color: C.text, fontWeight: 500 }}>
                            {fmtDate(run.startedAt)}
                          </div>
                          <div style={{ fontSize: 11, color: C.faint, marginTop: 1 }}>
                            {run.triggeredBy ? '⚡ Manual' : '⏱ Scheduled'}
                          </div>
                        </div>

                        {/* Duration */}
                        <span style={{ color: C.muted }}>{fmtDuration(run.durationMs)}</span>

                        {/* Rows */}
                        <span style={{ color: run.rowsProcessed ? C.text : C.faint }}>
                          {run.rowsProcessed ?? '—'}
                        </span>

                        {/* Status */}
                        <StatusBadge status={run.status} />

                        {/* Summary */}
                        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
                          {run.status === 'running' && (
                            <span style={{ color: C.blue, fontSize: 11 }}>
                              <i className="fas fa-spinner fa-spin" style={{ marginRight: 4 }} />In progress…
                            </span>
                          )}
                          {run.errorMessage && (
                            <span style={{
                              color: C.red, fontSize: 11,
                              background: C.redL, padding: '2px 7px',
                              borderRadius: 4, fontFamily: 'monospace',
                            }}>
                              {run.errorMessage.slice(0, 80)}
                            </span>
                          )}
                          {run.summary && job.summaryKeys.map(sk => {
                            const val = run.summary?.[sk.key];
                            if (!val) return null;
                            return (
                              <span
                                key={sk.key}
                                style={{
                                  fontSize: 11, padding: '2px 7px',
                                  borderRadius: 4, background: C.bg,
                                  border: `1px solid ${C.border}`,
                                  color: sk.color, fontWeight: 600,
                                }}
                              >
                                {val} {sk.label.toLowerCase()}
                              </span>
                            );
                          })}
                          {run.summary && !Object.values(run.summary).some(v => v > 0) && (
                            <span style={{ color: C.faint, fontSize: 11 }}>Nothing to process</span>
                          )}
                        </div>
                      </div>
                    ))
                  )}

                  {jobRuns.length > 20 && (
                    <div style={{ padding: '10px 24px', fontSize: 12, color: C.faint, borderTop: `1px solid ${C.border}` }}>
                      Showing last 20 of {jobRuns.length} runs.
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* ── Info banner ─────────────────────────────────────────────────────── */}
      <div style={{
        marginTop: 24, padding: '14px 18px',
        background: C.blueL, borderRadius: 8,
        border: `1px solid #BFDBFE`,
        display: 'flex', alignItems: 'flex-start', gap: 10, fontSize: 12, color: '#1D4ED8',
      }}>
        <i className="fas fa-circle-info" style={{ fontSize: 14, marginTop: 1, flexShrink: 0 }} />
        <span>
          <strong>Scheduled runs</strong> require pg_cron to be enabled in Supabase (Database → Extensions → pg_cron).
          Use <strong>Run Now</strong> to trigger any job immediately regardless of its schedule.
        </span>
      </div>

      {/* ── Keyframes for running dot ────────────────────────────────────────── */}
      <style>{`
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50%       { opacity: 0.4; }
        }
      `}</style>
    </div>
  );
}
