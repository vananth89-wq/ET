/**
 * WorkflowAnalytics.tsx
 *
 * Admin-only analytics screen for the workflow platform.
 * Three sections based on admin selections:
 *   1. Approval Turnaround  — avg completion time by template
 *   2. Rejection & SLA Breach Rates — per step breakdown
 *   3. Submitter Activity   — per-employee submission stats
 *
 * Data comes from three SECURITY DEFINER RPCs:
 *   wf_analytics_turnaround, wf_analytics_rejection_rates,
 *   wf_analytics_submitter_activity
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';

// ─── Types ────────────────────────────────────────────────────────────────────

interface TurnaroundRow {
  template_id: string;
  template_name: string;
  template_code: string;
  total_submitted: number;
  approved_count: number;
  rejected_count: number;
  in_progress_count: number;
  avg_hours_all: number | null;
  avg_hours_approved: number | null;
  avg_hours_rejected: number | null;
  min_hours: number | null;
  max_hours: number | null;
}

interface RejectionRow {
  template_name: string;
  template_code: string;
  step_order: number;
  step_name: string;
  sla_hours: number | null;
  total_tasks: number;
  approved_count: number;
  rejected_count: number;
  overdue_now: number;
  completed_late: number;
  rejection_pct: number | null;
  sla_breach_pct: number | null;
}

interface SubmitterRow {
  employee_id: string;
  employee_name: string;
  department_name: string | null;
  total_submissions: number;
  approved_count: number;
  rejected_count: number;
  in_progress_count: number;
  avg_turnaround_hours: number | null;
}

type DatePreset = '7d' | '30d' | '90d' | 'custom';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtHours(h: number | null): string {
  if (h === null || h === undefined) return '—';
  if (h < 1) return `${Math.round(h * 60)}m`;
  if (h < 24) return `${h.toFixed(1)}h`;
  return `${(h / 24).toFixed(1)}d`;
}

function pct(n: number | null): string {
  if (n === null || n === undefined) return '—';
  return `${n.toFixed(1)}%`;
}

function toDateStr(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function presetDates(preset: DatePreset): { from: string; to: string } {
  const to = new Date();
  const from = new Date();
  if (preset === '7d') from.setDate(from.getDate() - 7);
  else if (preset === '30d') from.setDate(from.getDate() - 30);
  else if (preset === '90d') from.setDate(from.getDate() - 90);
  return { from: toDateStr(from), to: toDateStr(to) };
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function KpiCard({ label, value, sub, color }: {
  label: string; value: string; sub?: string; color: string;
}) {
  return (
    <div className="bg-white border border-gray-200 rounded-xl p-4 flex flex-col gap-1 shadow-sm">
      <p className="text-xs text-gray-500 font-medium uppercase tracking-wide">{label}</p>
      <p className={`text-2xl font-bold ${color}`}>{value}</p>
      {sub && <p className="text-xs text-gray-400">{sub}</p>}
    </div>
  );
}

function SectionHeader({ title, icon, count }: { title: string; icon: string; count?: number }) {
  return (
    <div className="flex items-center gap-2 mb-4">
      <i className={`fa-solid ${icon} text-blue-600`} />
      <h2 className="text-base font-semibold text-gray-800">{title}</h2>
      {count !== undefined && (
        <span className="ml-auto text-xs text-gray-400">{count} row{count !== 1 ? 's' : ''}</span>
      )}
    </div>
  );
}

function Th({ children, right }: { children: React.ReactNode; right?: boolean }) {
  return (
    <th className={`px-3 py-2 text-xs font-semibold text-gray-500 uppercase tracking-wide bg-gray-50
      ${right ? 'text-right' : 'text-left'}`}>
      {children}
    </th>
  );
}

function Td({ children, right, muted }: { children: React.ReactNode; right?: boolean; muted?: boolean }) {
  return (
    <td className={`px-3 py-2.5 text-sm border-t border-gray-100
      ${right ? 'text-right' : ''} ${muted ? 'text-gray-400' : 'text-gray-800'}`}>
      {children}
    </td>
  );
}

function PctBadge({ value, threshold }: { value: number | null; threshold: number }) {
  if (value === null || value === undefined) return <span className="text-gray-400">—</span>;
  const high = value >= threshold;
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold
      ${high ? 'bg-red-100 text-red-700' : value > 0 ? 'bg-amber-100 text-amber-700' : 'bg-green-100 text-green-700'}`}>
      {value.toFixed(1)}%
    </span>
  );
}

function LoadingSpinner() {
  return (
    <div className="flex items-center justify-center py-16 text-gray-400">
      <i className="fa-solid fa-circle-notch fa-spin text-2xl mr-3" />
      <span className="text-sm">Loading analytics…</span>
    </div>
  );
}

function EmptyState({ message }: { message: string }) {
  return (
    <div className="text-center py-10 text-gray-400">
      <i className="fa-solid fa-chart-bar text-3xl mb-2 block" />
      <p className="text-sm">{message}</p>
    </div>
  );
}

// ─── Main Component ───────────────────────────────────────────────────────────

export default function WorkflowAnalytics() {
  const [preset, setPreset]           = useState<DatePreset>('30d');
  const [fromDate, setFromDate]       = useState(presetDates('30d').from);
  const [toDate, setToDate]           = useState(presetDates('30d').to);

  const [turnaround, setTurnaround]   = useState<TurnaroundRow[]>([]);
  const [rejection, setRejection]     = useState<RejectionRow[]>([]);
  const [submitters, setSubmitters]   = useState<SubmitterRow[]>([]);

  const [loading, setLoading]         = useState(false);
  const [error, setError]             = useState<string | null>(null);

  // ── Date preset handler ────────────────────────────────────────────────────
  function applyPreset(p: DatePreset) {
    setPreset(p);
    if (p !== 'custom') {
      const dates = presetDates(p);
      setFromDate(dates.from);
      setToDate(dates.to);
    }
  }

  // ── Fetch all three datasets ───────────────────────────────────────────────
  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [t, r, s] = await Promise.all([
        supabase.rpc('wf_analytics_turnaround',
          { p_from: fromDate, p_to: toDate }),
        supabase.rpc('wf_analytics_rejection_rates',
          { p_from: fromDate, p_to: toDate }),
        supabase.rpc('wf_analytics_submitter_activity',
          { p_from: fromDate, p_to: toDate }),
      ]);

      if (t.error) throw new Error(t.error.message);
      if (r.error) throw new Error(r.error.message);
      if (s.error) throw new Error(s.error.message);

      setTurnaround((t.data ?? []) as TurnaroundRow[]);
      setRejection((r.data ?? []) as RejectionRow[]);
      setSubmitters((s.data ?? []) as SubmitterRow[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load analytics');
    } finally {
      setLoading(false);
    }
  }, [fromDate, toDate]);

  useEffect(() => { loadData(); }, [loadData]);

  // ── Derived KPIs ───────────────────────────────────────────────────────────
  const totalSubmissions = turnaround.reduce((s, r) => s + Number(r.total_submitted), 0);
  const totalApproved    = turnaround.reduce((s, r) => s + Number(r.approved_count), 0);
  const totalRejected    = turnaround.reduce((s, r) => s + Number(r.rejected_count), 0);
  const overallAvgHours  = turnaround.length
    ? turnaround
        .filter(r => r.avg_hours_all !== null)
        .reduce((s, r) => s + Number(r.avg_hours_all), 0) /
      turnaround.filter(r => r.avg_hours_all !== null).length
    : null;
  const totalOverdue     = rejection.reduce((s, r) => s + Number(r.overdue_now), 0);

  return (
    <div className="p-6 max-w-7xl mx-auto space-y-8">

      {/* ── Page header ────────────────────────────────────────────────────── */}
      <div className="flex items-center justify-between flex-wrap gap-3">
        <div>
          <h1 className="text-xl font-bold text-gray-900">Workflow Analytics</h1>
          <p className="text-sm text-gray-500 mt-0.5">Approval performance, rejection trends and submitter activity</p>
        </div>
        <button
          onClick={loadData}
          className="inline-flex items-center gap-2 px-3 py-2 text-sm rounded-lg border border-gray-200
            text-gray-600 hover:bg-gray-50 transition"
        >
          <i className="fa-solid fa-arrows-rotate" />
          Refresh
        </button>
      </div>

      {/* ── Date range filter ──────────────────────────────────────────────── */}
      <div className="bg-white border border-gray-200 rounded-xl p-4 flex flex-wrap items-center gap-3">
        <span className="text-sm font-medium text-gray-600 mr-1">Period:</span>
        {(['7d', '30d', '90d'] as DatePreset[]).map(p => (
          <button
            key={p}
            onClick={() => applyPreset(p)}
            className={`px-3 py-1.5 text-xs font-semibold rounded-lg transition
              ${preset === p
                ? 'bg-blue-600 text-white'
                : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}`}
          >
            {p === '7d' ? 'Last 7 days' : p === '30d' ? 'Last 30 days' : 'Last 90 days'}
          </button>
        ))}
        <button
          onClick={() => setPreset('custom')}
          className={`px-3 py-1.5 text-xs font-semibold rounded-lg transition
            ${preset === 'custom'
              ? 'bg-blue-600 text-white'
              : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}`}
        >
          Custom
        </button>
        {preset === 'custom' && (
          <div className="flex items-center gap-2 ml-2">
            <input
              type="date"
              value={fromDate}
              onChange={e => setFromDate(e.target.value)}
              className="text-xs border border-gray-300 rounded-lg px-2 py-1.5 text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-400"
            />
            <span className="text-gray-400 text-xs">to</span>
            <input
              type="date"
              value={toDate}
              onChange={e => setToDate(e.target.value)}
              className="text-xs border border-gray-300 rounded-lg px-2 py-1.5 text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-400"
            />
            <button
              onClick={loadData}
              className="px-3 py-1.5 text-xs font-semibold bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition"
            >
              Apply
            </button>
          </div>
        )}
      </div>

      {/* ── Error banner ───────────────────────────────────────────────────── */}
      {error && (
        <div className="flex items-center gap-2 p-3 bg-red-50 border border-red-200 rounded-xl text-sm text-red-700">
          <i className="fa-solid fa-circle-exclamation" />
          {error}
        </div>
      )}

      {loading ? <LoadingSpinner /> : (
        <>
          {/* ── KPI bar ──────────────────────────────────────────────────────── */}
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
            <KpiCard
              label="Total Submissions"
              value={totalSubmissions.toLocaleString()}
              sub={`${fromDate} – ${toDate}`}
              color="text-blue-700"
            />
            <KpiCard
              label="Avg Turnaround"
              value={fmtHours(overallAvgHours)}
              sub="across all templates"
              color="text-gray-800"
            />
            <KpiCard
              label="Rejection Rate"
              value={totalApproved + totalRejected > 0
                ? `${((totalRejected / (totalApproved + totalRejected)) * 100).toFixed(1)}%`
                : '—'}
              sub={`${totalRejected} rejected`}
              color={totalRejected > 0 ? 'text-red-600' : 'text-green-600'}
            />
            <KpiCard
              label="Overdue Now"
              value={totalOverdue.toLocaleString()}
              sub="pending tasks past SLA"
              color={totalOverdue > 0 ? 'text-amber-600' : 'text-green-600'}
            />
          </div>

          {/* ══ Section 1: Approval Turnaround ════════════════════════════════ */}
          <div className="bg-white border border-gray-200 rounded-xl p-5 shadow-sm">
            <SectionHeader
              title="Approval Turnaround by Template"
              icon="fa-clock"
              count={turnaround.length}
            />
            {turnaround.length === 0
              ? <EmptyState message="No completed workflows in this period." />
              : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr>
                        <Th>Template</Th>
                        <Th right>Submitted</Th>
                        <Th right>Approved</Th>
                        <Th right>Rejected</Th>
                        <Th right>In Progress</Th>
                        <Th right>Avg (All)</Th>
                        <Th right>Avg (Approved)</Th>
                        <Th right>Avg (Rejected)</Th>
                        <Th right>Min</Th>
                        <Th right>Max</Th>
                      </tr>
                    </thead>
                    <tbody>
                      {turnaround.map(row => (
                        <tr key={row.template_id} className="hover:bg-gray-50 transition">
                          <Td>
                            <div className="font-medium text-gray-900">{row.template_name}</div>
                            <div className="text-xs text-gray-400 font-mono">{row.template_code}</div>
                          </Td>
                          <Td right>{Number(row.total_submitted).toLocaleString()}</Td>
                          <Td right>
                            <span className="text-green-700 font-medium">
                              {Number(row.approved_count).toLocaleString()}
                            </span>
                          </Td>
                          <Td right>
                            <span className={row.rejected_count > 0 ? 'text-red-600 font-medium' : 'text-gray-400'}>
                              {Number(row.rejected_count).toLocaleString()}
                            </span>
                          </Td>
                          <Td right muted={row.in_progress_count === 0}>
                            {Number(row.in_progress_count).toLocaleString()}
                          </Td>
                          <Td right>{fmtHours(row.avg_hours_all)}</Td>
                          <Td right>{fmtHours(row.avg_hours_approved)}</Td>
                          <Td right>{fmtHours(row.avg_hours_rejected)}</Td>
                          <Td right muted>{fmtHours(row.min_hours)}</Td>
                          <Td right muted>{fmtHours(row.max_hours)}</Td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
          </div>

          {/* ══ Section 2: Rejection & SLA Breach Rates ═══════════════════════ */}
          <div className="bg-white border border-gray-200 rounded-xl p-5 shadow-sm">
            <SectionHeader
              title="Rejection & SLA Breach Rates by Step"
              icon="fa-triangle-exclamation"
              count={rejection.length}
            />
            {rejection.length === 0
              ? <EmptyState message="No task data in this period." />
              : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr>
                        <Th>Template</Th>
                        <Th>Step</Th>
                        <Th right>SLA</Th>
                        <Th right>Tasks</Th>
                        <Th right>Approved</Th>
                        <Th right>Rejected</Th>
                        <Th right>Overdue Now</Th>
                        <Th right>Late Complete</Th>
                        <Th right>Rejection %</Th>
                        <Th right>SLA Breach %</Th>
                      </tr>
                    </thead>
                    <tbody>
                      {rejection.map((row, i) => (
                        <tr key={i} className="hover:bg-gray-50 transition">
                          <Td>
                            <div className="font-medium text-gray-900">{row.template_name}</div>
                            <div className="text-xs text-gray-400 font-mono">{row.template_code}</div>
                          </Td>
                          <Td>
                            <div className="flex items-center gap-1.5">
                              <span className="text-xs font-mono text-gray-400 w-4 text-right shrink-0">
                                {row.step_order}
                              </span>
                              <span>{row.step_name}</span>
                            </div>
                          </Td>
                          <Td right muted>
                            {row.sla_hours ? `${row.sla_hours}h` : '—'}
                          </Td>
                          <Td right>{Number(row.total_tasks).toLocaleString()}</Td>
                          <Td right>
                            <span className="text-green-700">{Number(row.approved_count).toLocaleString()}</span>
                          </Td>
                          <Td right>
                            <span className={row.rejected_count > 0 ? 'text-red-600' : 'text-gray-400'}>
                              {Number(row.rejected_count).toLocaleString()}
                            </span>
                          </Td>
                          <Td right>
                            {Number(row.overdue_now) > 0
                              ? <span className="font-semibold text-red-600">{Number(row.overdue_now)}</span>
                              : <span className="text-gray-400">0</span>}
                          </Td>
                          <Td right>
                            {Number(row.completed_late) > 0
                              ? <span className="text-amber-600">{Number(row.completed_late)}</span>
                              : <span className="text-gray-400">0</span>}
                          </Td>
                          <Td right>
                            <PctBadge value={row.rejection_pct} threshold={20} />
                          </Td>
                          <Td right>
                            <PctBadge value={row.sla_breach_pct} threshold={30} />
                          </Td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
          </div>

          {/* ══ Section 3: Submitter Activity ═════════════════════════════════ */}
          <div className="bg-white border border-gray-200 rounded-xl p-5 shadow-sm">
            <SectionHeader
              title="Submitter Activity"
              icon="fa-users"
              count={submitters.length}
            />
            {submitters.length === 0
              ? <EmptyState message="No submission activity in this period." />
              : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr>
                        <Th>Employee</Th>
                        <Th>Department</Th>
                        <Th right>Submissions</Th>
                        <Th right>Approved</Th>
                        <Th right>Rejected</Th>
                        <Th right>In Progress</Th>
                        <Th right>Approval Rate</Th>
                        <Th right>Avg Turnaround</Th>
                      </tr>
                    </thead>
                    <tbody>
                      {submitters.map(row => {
                        const completed = Number(row.approved_count) + Number(row.rejected_count);
                        const approvalRate = completed > 0
                          ? (Number(row.approved_count) / completed) * 100
                          : null;
                        return (
                          <tr key={row.employee_id} className="hover:bg-gray-50 transition">
                            <Td>
                              <div className="font-medium text-gray-900">{row.employee_name}</div>
                            </Td>
                            <Td muted={!row.department_name}>
                              {row.department_name ?? '—'}
                            </Td>
                            <Td right>
                              <span className="font-semibold text-blue-700">
                                {Number(row.total_submissions).toLocaleString()}
                              </span>
                            </Td>
                            <Td right>
                              <span className="text-green-700">
                                {Number(row.approved_count).toLocaleString()}
                              </span>
                            </Td>
                            <Td right>
                              <span className={row.rejected_count > 0 ? 'text-red-600' : 'text-gray-400'}>
                                {Number(row.rejected_count).toLocaleString()}
                              </span>
                            </Td>
                            <Td right muted={row.in_progress_count === 0}>
                              {Number(row.in_progress_count).toLocaleString()}
                            </Td>
                            <Td right>
                              {approvalRate !== null ? (
                                <span className={approvalRate >= 80
                                  ? 'text-green-700 font-medium'
                                  : approvalRate >= 50 ? 'text-amber-600' : 'text-red-600'}>
                                  {approvalRate.toFixed(0)}%
                                </span>
                              ) : <span className="text-gray-400">—</span>}
                            </Td>
                            <Td right muted={!row.avg_turnaround_hours}>
                              {fmtHours(row.avg_turnaround_hours)}
                            </Td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
          </div>
        </>
      )}
    </div>
  );
}
