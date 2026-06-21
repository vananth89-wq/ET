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
import * as XLSX from 'xlsx';
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
// rpc: call via supabase.rpc(); edgeFn: call via Edge Function HTTP POST
const REGISTERED_JOBS: Array<{
  code: string; name: string; description: string; schedule: string;
  icon: string; rpc?: string | null; edgeFn?: string;
  rpcParams?: Record<string, unknown>;   // extra params beyond p_triggered_by
  noTriggeredBy?: boolean;               // true = RPC doesn't accept p_triggered_by
  summaryKeys: { key: string; label: string; color: string }[];
}> = [
  {
    code:        'wf_sla_monitor',
    name:        'Workflow SLA Monitor',
    description: 'Sends reminder notifications and escalates overdue approval tasks to the assignee\'s line manager.',
    schedule:    'Every 5 minutes',
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
  {
    code:        'activate_personal_info_records',
    name:        'Employee Sync',
    description: 'Finds Active employees where employees.name diverges from their current employee_personal record and syncs it. Self-healing — catches any missed activations from past job failures.',
    schedule:    'Daily at 00:15 UTC',
    icon:        'fa-person-circle-check',
    rpc:           'activate_personal_info_records',
    noTriggeredBy: true,
    summaryKeys: [
      { key: 'personal_rows',   label: 'Name syncs',      color: '#2F77B5' },
      { key: 'employment_rows', label: 'Employment syncs', color: '#7C3AED' },
      { key: 'end_date_flips',  label: 'End-date flips',  color: '#D97706' },
      { key: 'errors',          label: 'Errors',           color: '#DC2626' },
    ],
  },
  {
    code:        'bulk_upload_job_retention',
    name:        'Bulk Upload Retention',
    description: 'Deletes bulk upload jobs and their associated storage files (CSV + error reports) older than 90 days.',
    schedule:    'Daily at 02:00 UTC',
    icon:        'fa-trash-clock',
    rpc:         null,   // pg_cron only — no on-demand RPC
    summaryKeys: [],
  },
  {
    code:        'process_scheduled_terminations',
    name:        'Process Scheduled Terminations',
    description: 'Finds APPROVED terminations whose Last Working Date is today or earlier and finalises them — flips employee status to Inactive and applies any direct-report manager reassignments.',
    schedule:    'Daily at 00:05 UTC',
    icon:        'fa-user-slash',
    edgeFn:      'process-scheduled-terminations',
    summaryKeys: [
      { key: 'succeeded', label: 'Finalized',  color: '#16A34A' },
      { key: 'skipped',   label: 'Skipped',    color: '#6B7280' },
      { key: 'failed',    label: 'Failed',     color: '#DC2626' },
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

// ─── Row detail types (stored in summary.details by Edge Functions) ───────────

interface RowDetail {
  termination_id:          string;
  employee_id:             string;
  employee_name:           string;
  terminated_employee_name?: string;
  terminated_employee_id?:  string;
  affected_employee_name?:  string;
  affected_employee_id?:    string;
  last_working_date: string | null;
  separation_date:   string | null;
  outcome:           'finalized' | 'skipped' | 'failed';
  reason?:           string;
  error?:            string;
}

function RunDownloadButton({ run, jobName }: { run: JobRun; jobName: string }) {
  function downloadExcel() {
    const summary = run.summary as Record<string, unknown> | null;
    const details = Array.isArray(summary?.details)
      ? (summary!.details as RowDetail[])
      : null;

    let rows: Record<string, unknown>[];

    if (details && details.length > 0) {
      // Rich per-row detail (termination job)
      rows = details.map(d => ({
        'Terminated Employee':    d.terminated_employee_name ?? d.employee_name,
        'Terminated Employee ID': d.terminated_employee_id  ?? d.employee_id,
        'Affected Employee':      d.affected_employee_name  ?? '—',
        'Affected Employee ID':   d.affected_employee_id   ?? '—',
        'Last Working Date':      d.last_working_date ?? '',
        'Separation Date':        d.separation_date ?? '',
        'Outcome':                d.outcome,
        'Reason / Error':         d.error ?? d.reason ?? '',
      }));
    } else {
      // Generic single-row summary for all other jobs
      const summaryRow: Record<string, unknown> = {
        'Job':            jobName,
        'Started At':     run.startedAt,
        'Completed At':   run.completedAt ?? '',
        'Duration (ms)':  run.durationMs ?? '',
        'Status':         run.status,
        'Rows Processed': run.rowsProcessed ?? 0,
      };
      if (summary) {
        Object.entries(summary).forEach(([k, v]) => {
          if (k !== 'details' && k !== 'errors') {
            summaryRow[k.charAt(0).toUpperCase() + k.slice(1)] = v as string | number;
          }
        });
      }
      if (run.errorMessage) summaryRow['Error'] = run.errorMessage;
      // Per-row errors if present
      const errors = Array.isArray(summary?.errors)
        ? (summary!.errors as Array<Record<string, unknown>>)
        : null;
      if (errors && errors.length > 0) {
        rows = errors.map(e => ({ ...summaryRow, ...e }));
      } else {
        rows = [summaryRow];
      }
    }

    const ws = XLSX.utils.json_to_sheet(rows);
    ws['!cols'] = Object.keys(rows[0] ?? {}).map(() => ({ wch: 22 }));
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Run Report');
    const dateStr = run.startedAt.slice(0, 16).replace('T', '_').replace(':', '-');
    const jobSlug = jobName.toLowerCase().replace(/\s+/g, '_');
    XLSX.writeFile(wb, `${jobSlug}_${dateStr}.xlsx`);
  }

  return (
    <button
      onClick={downloadExcel}
      title="Download report"
      style={{
        padding: '3px 8px', borderRadius: 5,
        border: `1px solid ${C.border}`, background: '#fff',
        color: '#1D6F42', cursor: 'pointer', lineHeight: 1,
      }}
    >
      <i className="fas fa-file-excel" style={{ fontSize: 13 }} />
    </button>
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
  const [histPage,    setHistPage]   = useState<Record<string, number>>({});   // jobCode → 0-based page
  const [notifEmails, setNotifEmails] = useState<Record<string, string>>({});   // jobCode → email
  const [notifSaving, setNotifSaving] = useState<Record<string, boolean>>({});

  // ── Targeted personal info sync (single employee) ─────────────────────────
  const today = new Date().toISOString().split('T')[0];
  const [piSearch,    setPiSearch]    = useState('');
  const [piResults,   setPiResults]   = useState<{ id: string; name: string; employee_id: string }[]>([]);
  const [piSelected,  setPiSelected]  = useState<{ id: string; name: string } | null>(null);
  const [piDate,      setPiDate]      = useState(today);
  const [piRunning,   setPiRunning]   = useState(false);
  const [piOutcome,   setPiOutcome]   = useState<string | null>(null);

  // ── All-employee personal info sync (by date) ─────────────────────────────
  const [piAllDate,    setPiAllDate]    = useState(today);
  const [piAllRunning, setPiAllRunning] = useState(false);
  const [piAllOutcome, setPiAllOutcome] = useState<string | null>(null);

  async function searchEmployees(q: string) {
    setPiSearch(q);
    setPiSelected(null);
    if (!q.trim()) { setPiResults([]); return; }
    const { data } = await supabase
      .from('employees')
      .select('id, name, employee_id')
      .ilike('name', `%${q.trim()}%`)
      .eq('status', 'Active')
      .is('deleted_at', null)
      .limit(8);
    setPiResults((data ?? []) as { id: string; name: string; employee_id: string }[]);
  }

  async function runSingleSync() {
    if (!piSelected) return;
    setPiRunning(true); setPiOutcome(null);
    const { data, error } = await supabase.rpc('sync_personal_info_for_employee', {
      p_employee_id: piSelected.id,
      p_as_of_date:  piDate,
    });
    setPiRunning(false);
    if (error) {
      setPiOutcome(`Error: ${error.message}`);
      showToast('err', error.message);
    } else if (data && !data.ok) {
      setPiOutcome(`Error: ${data.error}`);
      showToast('err', data.error);
    } else if (data?.synced === false) {
      setPiOutcome(`No drift — ${piSelected.name} is already in sync.`);
      showToast('ok', 'No drift detected — already in sync.');
    } else {
      setPiOutcome(`Synced: "${data?.employees_name}" → "${data?.personal_name}" (effective ${data?.effective_from})`);
      showToast('ok', `${piSelected.name} synced successfully.`);
    }
    await loadRuns();
  }

  async function runAllSync() {
    setPiAllRunning(true); setPiAllOutcome(null);
    const { error } = await supabase.rpc('activate_personal_info_records', {
      p_as_of_date: piAllDate,
    });
    setPiAllRunning(false);
    if (error) {
      setPiAllOutcome(`Error: ${error.message}`);
      showToast('err', error.message);
    } else {
      setPiAllOutcome(`Sync complete for all employees as of ${piAllDate}.`);
      showToast('ok', `All-employee name sync complete as of ${piAllDate}.`);
    }
    await loadRuns();
  }

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
      .limit(500);

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

  useEffect(() => {
    const keys = REGISTERED_JOBS.map(j => `${j.code}_notification_email`);
    supabase.from('app_config').select('key, value').in('key', keys)
      .then(({ data }) => {
        if (!data) return;
        const map: Record<string, string> = {};
        for (const row of data) {
          const code = (row.key as string).replace('_notification_email', '');
          map[code] = row.value as string;
        }
        setNotifEmails(map);
      });
  }, []);

  async function saveNotifEmail(jobCode: string) {
    setNotifSaving(p => ({ ...p, [jobCode]: true }));
    await supabase.from('app_config').upsert(
      { key: `${jobCode}_notification_email`, value: notifEmails[jobCode] ?? '' },
      { onConflict: 'key' }
    );
    setNotifSaving(p => ({ ...p, [jobCode]: false }));
    showToast('ok', 'Notification email saved.');
  }

  async function fireJobAlert(
    jobCode: string, jobName: string,
    summary: { total?: number; succeeded?: number; failed?: number; skipped?: number },
    errors: Array<{ label: string; error: string }>,
    errorMessage?: string,
  ) {
    const to = notifEmails[jobCode];
    if (!to || errors.length === 0) return;
    try {
      const { data: { session } } = await supabase.auth.getSession();
      await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/send-job-alert`,
        {
          method: 'POST',
          headers: {
            'Content-Type':  'application/json',
            'Authorization': `Bearer ${session?.access_token ?? ''}`,
            'apikey':        import.meta.env.VITE_SUPABASE_ANON_KEY,
          },
          body: JSON.stringify({
            to,
            job_name:  jobName,
            job_code:  jobCode,
            run_date:  new Date().toISOString().slice(0, 10),
            total:     summary.total     ?? errors.length,
            succeeded: summary.succeeded ?? 0,
            failed:    summary.failed    ?? errors.length,
            skipped:   summary.skipped   ?? 0,
            errors,
            error_message: errorMessage,
          }),
        },
      );
    } catch (e) {
      console.warn('send-job-alert failed', e);
    }
  }

  async function runNow(jobCode: string, rpc: string | null | undefined, edgeFn?: string, noTriggeredBy?: boolean) {
    if (!rpc && !edgeFn) return;
    setRunning(p => ({ ...p, [jobCode]: true }));
    setRunResult(p => ({ ...p, [jobCode]: {} }));

    let data: unknown = null;
    let error: { message: string } | null = null;

    if (edgeFn) {
      // Call Edge Function via HTTP POST
      try {
        const { data: { session } } = await supabase.auth.getSession();
        const res = await fetch(
          `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/${edgeFn}`,
          {
            method: 'POST',
            headers: {
              'Content-Type':  'application/json',
              'Authorization': `Bearer ${session?.access_token ?? ''}`,
              'apikey':        import.meta.env.VITE_SUPABASE_ANON_KEY,
            },
            body: JSON.stringify({ triggered_by: profile?.id ?? null }),
          },
        );
        data = await res.json();
        if (!res.ok) error = { message: (data as any)?.error ?? 'Edge Function failed' };
      } catch (err) {
        error = { message: (err as Error).message };
      }
    } else {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const rpcArgs = noTriggeredBy ? {} : { p_triggered_by: profile?.id ?? null };
      const res = await (supabase as any).rpc(rpc, rpcArgs);
      data = res.data;
      error = res.error;
    }

    setRunning(p => ({ ...p, [jobCode]: false }));

    if (error) {
      showToast('err', `Job failed: ${error.message}`);
      const job = REGISTERED_JOBS.find(j => j.code === jobCode);
      if (job) await fireJobAlert(jobCode, job.name, {}, [{ label: jobCode, error: error.message }], error.message);
    } else {
      // data may be a plain integer (e.g. wf_retry_failed_emails returns int)
      // or a record object (e.g. wf_process_sla_events returns a row)
      const count = typeof data === 'number' ? data : null;
      const result = (typeof data === 'object' && data !== null)
        ? data as Record<string, unknown>
        : {};
      setRunResult(p => ({ ...p, [jobCode]: result as Record<string, number> }));
      if (count !== null) {
        showToast('ok', count > 0 ? `Done — ${count} processed` : 'Done — nothing to process');
      } else {
        const parts = Object.entries(result)
          .filter(([k, v]) => k !== 'errors' && k !== 'details' && (v as number) > 0)
          .map(([k, v]) => `${v} ${k}`)
          .join(', ');
        showToast('ok', parts ? `Done — ${parts}` : 'Done — nothing to process');
      }
      // Fire failure alert if errors present
      const failedCount = (result.failed as number) ?? (result.errors as number) ?? 0;
      if (failedCount > 0) {
        const job = REGISTERED_JOBS.find(j => j.code === jobCode);
        const errDetails = Array.isArray(result.errors)
          ? (result.errors as Array<Record<string, string>>).map(e => ({
              label: e.employee_name ?? e.label ?? jobCode,
              error: e.error ?? '',
            }))
          : [{ label: jobCode, error: `${failedCount} error(s) — check run history for details` }];
        if (job) await fireJobAlert(jobCode, job.name, result as Record<string, number>, errDetails);
      }
      await loadRuns();
    }
  }

  return (
    <div style={{ padding: '0 0 32px 0' }}>

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
          const jobRuns     = runs.filter(r => r.jobCode === job.code);
          const lastRun     = jobRuns[0] ?? null;
          const isRunning   = running[job.code] ?? false;
          const isExpanded  = expanded === job.code;
          const freshResult = runResult[job.code];
          const PAGE_SIZE   = 25;
          const currentPage = histPage[job.code] ?? 0;
          const totalPages  = Math.ceil(jobRuns.length / PAGE_SIZE);
          const pageRuns    = jobRuns.slice(currentPage * PAGE_SIZE, (currentPage + 1) * PAGE_SIZE);

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
                      {/* Failure notification email */}
                      <div style={{ marginTop: 10, display: 'flex', alignItems: 'center', gap: 8 }}>
                        <i className="fas fa-envelope" style={{ fontSize: 11, color: C.faint, flexShrink: 0 }} />
                        <input
                          type="email"
                          placeholder="Failure alert email address…"
                          value={notifEmails[job.code] ?? ''}
                          onChange={e => setNotifEmails(p => ({ ...p, [job.code]: e.target.value }))}
                          onKeyDown={e => e.key === 'Enter' && saveNotifEmail(job.code)}
                          style={{
                            fontSize: 12, padding: '4px 10px', borderRadius: 6,
                            border: `1px solid ${C.border}`, color: C.text,
                            width: 260, outline: 'none',
                          }}
                        />
                        <button
                          onClick={() => saveNotifEmail(job.code)}
                          disabled={notifSaving[job.code]}
                          style={{
                            fontSize: 11, fontWeight: 600, padding: '4px 12px',
                            borderRadius: 6, border: `1px solid ${C.border}`,
                            background: '#fff', color: C.navy, cursor: 'pointer',
                          }}
                        >
                          {notifSaving[job.code] ? 'Saving…' : 'Save'}
                        </button>
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
                    {(job.rpc || job.edgeFn) ? (
                      <button
                        onClick={() => runNow(job.code, job.rpc, job.edgeFn, job.noTriggeredBy)}
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
                    ) : (
                      <span style={{ fontSize: 11, color: C.faint, fontStyle: 'italic' }}>
                        pg_cron only
                      </span>
                    )}
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
                    gridTemplateColumns: '1fr 90px 80px 100px 1fr 48px',
                    gap: 12,
                  }}>
                    <span>Started</span>
                    <span>Duration</span>
                    <span>Rows</span>
                    <span>Status</span>
                    <span>Summary</span>
                    <span>Report</span>
                  </div>

                  {jobRuns.length === 0 ? (
                    <div style={{ padding: '24px', textAlign: 'center', color: C.faint, fontSize: 13 }}>
                      No run history yet.
                    </div>
                  ) : (
                    pageRuns.map(run => (
                      <div
                        key={run.id}
                        style={{
                          padding: '10px 24px',
                          borderTop: `1px solid ${C.border}`,
                          display: 'grid',
                          gridTemplateColumns: '1fr 90px 80px 100px 1fr 48px',
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
                        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
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
                                {run.errorMessage.slice(0, 120)}
                              </span>
                            )}
                            {run.summary && job.summaryKeys.map(sk => {
                              const val = (run.summary as Record<string, unknown>)?.[sk.key];
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
                                  {val as number} {sk.label.toLowerCase()}
                                </span>
                              );
                            })}
                            {run.summary && !Object.entries(run.summary).some(([k, v]) => k !== 'errors' && (v as number) > 0) && (
                              <span style={{ color: C.faint, fontSize: 11 }}>Nothing to process</span>
                            )}
                          </div>
                        </div>

                        {/* Download column */}
                        <RunDownloadButton run={run} jobName={job.name} />
                      </div>
                    ))
                  )}

                  {totalPages > 1 && (
                    <div style={{
                      padding: '10px 24px', borderTop: `1px solid ${C.border}`,
                      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                      fontSize: 12, color: C.muted,
                    }}>
                      <span>
                        {currentPage * PAGE_SIZE + 1}–{Math.min((currentPage + 1) * PAGE_SIZE, jobRuns.length)} of {jobRuns.length} runs
                      </span>
                      <div style={{ display: 'flex', gap: 6 }}>
                        <button
                          onClick={() => setHistPage(p => ({ ...p, [job.code]: currentPage - 1 }))}
                          disabled={currentPage === 0}
                          style={{
                            padding: '4px 10px', borderRadius: 5, fontSize: 12,
                            border: `1px solid ${C.border}`, background: '#fff',
                            color: currentPage === 0 ? C.faint : C.navy,
                            cursor: currentPage === 0 ? 'default' : 'pointer',
                          }}
                        >
                          ← Back
                        </button>
                        <span style={{ padding: '4px 8px', fontSize: 12, color: C.muted }}>
                          Page {currentPage + 1} of {totalPages}
                        </span>
                        <button
                          onClick={() => setHistPage(p => ({ ...p, [job.code]: currentPage + 1 }))}
                          disabled={currentPage >= totalPages - 1}
                          style={{
                            padding: '4px 10px', borderRadius: 5, fontSize: 12,
                            border: `1px solid ${C.border}`, background: '#fff',
                            color: currentPage >= totalPages - 1 ? C.faint : C.navy,
                            cursor: currentPage >= totalPages - 1 ? 'default' : 'pointer',
                          }}
                        >
                          Next →
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* ── Personal Info Sync — parameterized tools ───────────────────────── */}
      <div style={{ marginTop: 28 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.08em', marginBottom: 14 }}>
          Personal Info Sync — Targeted Tools
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>

          {/* ── Card 1: Single Employee ───────────────────────────────────────── */}
          <div style={{ background: '#fff', borderRadius: 12, border: `1px solid ${C.border}`, padding: '20px 22px', boxShadow: '0 1px 4px rgba(0,0,0,0.04)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16 }}>
              <div style={{ width: 36, height: 36, borderRadius: 9, background: '#EDE9FE', color: '#7C3AED', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <i className="fas fa-user-check" style={{ fontSize: 15 }} />
              </div>
              <div>
                <div style={{ fontWeight: 700, fontSize: 14, color: C.navy }}>Sync Single Employee</div>
                <div style={{ fontSize: 11, color: C.muted }}>Sync one employee's name as of a specific date</div>
              </div>
            </div>

            {/* Employee search */}
            <div style={{ marginBottom: 10, position: 'relative' }}>
              <label style={{ fontSize: 11, fontWeight: 600, color: C.muted, display: 'block', marginBottom: 4 }}>Employee Name</label>
              <input
                type="text"
                placeholder="Search by name…"
                value={piSelected ? piSelected.name : piSearch}
                onChange={e => { setPiSelected(null); searchEmployees(e.target.value); }}
                style={{ width: '100%', padding: '7px 10px', borderRadius: 6, border: `1px solid ${C.border}`, fontSize: 13, boxSizing: 'border-box' }}
              />
              {!piSelected && piResults.length > 0 && (
                <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 100, background: '#fff', border: `1px solid ${C.border}`, borderRadius: 7, boxShadow: '0 4px 16px rgba(0,0,0,0.10)', marginTop: 2, overflow: 'hidden' }}>
                  {piResults.map(r => (
                    <button
                      key={r.id}
                      onClick={() => { setPiSelected({ id: r.id, name: r.name }); setPiSearch(''); setPiResults([]); }}
                      style={{ display: 'block', width: '100%', textAlign: 'left', padding: '8px 12px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, borderBottom: `1px solid ${C.border}` }}
                    >
                      <span style={{ fontWeight: 600 }}>{r.name}</span>
                      <span style={{ color: C.faint, marginLeft: 8, fontSize: 11 }}>{r.employee_id}</span>
                    </button>
                  ))}
                </div>
              )}
            </div>

            {/* Date */}
            <div style={{ marginBottom: 14 }}>
              <label style={{ fontSize: 11, fontWeight: 600, color: C.muted, display: 'block', marginBottom: 4 }}>As of Date</label>
              <input
                type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                value={piDate}
                onChange={e => setPiDate(e.target.value)}
                style={{ width: '100%', padding: '7px 10px', borderRadius: 6, border: `1px solid ${C.border}`, fontSize: 13, boxSizing: 'border-box' }}
              />
            </div>

            <button
              onClick={runSingleSync}
              disabled={!piSelected || piRunning}
              style={{
                width: '100%', padding: '8px', borderRadius: 7, border: 'none',
                background: (!piSelected || piRunning) ? C.blueL : '#7C3AED',
                color: (!piSelected || piRunning) ? '#7C3AED' : '#fff',
                fontSize: 13, fontWeight: 600, cursor: (!piSelected || piRunning) ? 'not-allowed' : 'pointer',
                display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
              }}
            >
              <i className={`fas ${piRunning ? 'fa-spinner fa-spin' : 'fa-play'}`} style={{ fontSize: 11 }} />
              {piRunning ? 'Syncing…' : 'Run Sync'}
            </button>

            {piOutcome && (
              <div style={{ marginTop: 10, padding: '8px 12px', borderRadius: 6, background: piOutcome.startsWith('Error') ? C.redL : C.greenL, color: piOutcome.startsWith('Error') ? C.red : C.green, fontSize: 12 }}>
                <i className={`fas ${piOutcome.startsWith('Error') ? 'fa-circle-xmark' : 'fa-circle-check'}`} style={{ marginRight: 6 }} />
                {piOutcome}
              </div>
            )}
          </div>

          {/* ── Card 2: All Employees by Date ──────────────────────────────────── */}
          <div style={{ background: '#fff', borderRadius: 12, border: `1px solid ${C.border}`, padding: '20px 22px', boxShadow: '0 1px 4px rgba(0,0,0,0.04)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16 }}>
              <div style={{ width: 36, height: 36, borderRadius: 9, background: C.amberL, color: C.amber, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <i className="fas fa-users-gear" style={{ fontSize: 15 }} />
              </div>
              <div>
                <div style={{ fontWeight: 700, fontSize: 14, color: C.navy }}>Sync All Employees</div>
                <div style={{ fontSize: 11, color: C.muted }}>Sync all Active employees as of a date — only updates where drift exists</div>
              </div>
            </div>

            {/* Date */}
            <div style={{ marginBottom: 14 }}>
              <label style={{ fontSize: 11, fontWeight: 600, color: C.muted, display: 'block', marginBottom: 4 }}>As of Date</label>
              <input
                type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                value={piAllDate}
                onChange={e => setPiAllDate(e.target.value)}
                style={{ width: '100%', padding: '7px 10px', borderRadius: 6, border: `1px solid ${C.border}`, fontSize: 13, boxSizing: 'border-box' }}
              />
              <div style={{ fontSize: 11, color: C.faint, marginTop: 4 }}>
                Only employees whose employee_personal record was active on this date and whose name has drifted will be updated.
              </div>
            </div>

            <button
              onClick={runAllSync}
              disabled={!piAllDate || piAllRunning}
              style={{
                width: '100%', padding: '8px', borderRadius: 7, border: 'none',
                background: piAllRunning ? C.amberL : C.amber,
                color: piAllRunning ? C.amber : '#fff',
                fontSize: 13, fontWeight: 600, cursor: piAllRunning ? 'not-allowed' : 'pointer',
                display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
              }}
            >
              <i className={`fas ${piAllRunning ? 'fa-spinner fa-spin' : 'fa-play'}`} style={{ fontSize: 11 }} />
              {piAllRunning ? 'Syncing…' : 'Run Sync'}
            </button>

            {piAllOutcome && (
              <div style={{ marginTop: 10, padding: '8px 12px', borderRadius: 6, background: piAllOutcome.startsWith('Error') ? C.redL : C.greenL, color: piAllOutcome.startsWith('Error') ? C.red : C.green, fontSize: 12 }}>
                <i className={`fas ${piAllOutcome.startsWith('Error') ? 'fa-circle-xmark' : 'fa-circle-check'}`} style={{ marginRight: 6 }} />
                {piAllOutcome}
              </div>
            )}
          </div>

        </div>
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
