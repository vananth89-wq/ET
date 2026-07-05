/**
 * WorkflowAnalytics.tsx
 *
 * Admin analytics screen — three sections:
 *   1. Approval Turnaround by template
 *   2. Rejection & SLA Breach Rates by step
 *   3. Submitter Activity
 *
 * RPCs: wf_analytics_turnaround, wf_analytics_rejection_rates,
 *       wf_analytics_submitter_activity
 * Access: has_role('admin') OR has_permission('workflow.admin')
 */

import { useState, useEffect, useCallback, useMemo } from 'react';
import { supabase } from '../../lib/supabase';

// ─── Types ────────────────────────────────────────────────────────────────────

interface TurnaroundRow {
  template_id:       string;
  template_name:     string;
  template_code:     string;
  total_submitted:   number;
  approved_count:    number;
  rejected_count:    number;
  in_progress_count: number;
  avg_hours_all:     number | null;
  avg_hours_approved:number | null;
  avg_hours_rejected:number | null;
  min_hours:         number | null;
  max_hours:         number | null;
}

interface RejectionRow {
  template_name:  string;
  template_code:  string;
  step_order:     number;
  step_name:      string;
  sla_hours:      number | null;
  total_tasks:    number;
  approved_count: number;
  rejected_count: number;
  overdue_now:    number;
  completed_late: number;
  rejection_pct:  number | null;
  sla_breach_pct: number | null;
}

interface SubmitterRow {
  employee_id:          string;
  employee_name:        string;
  department_name:      string | null;
  total_submissions:    number;
  approved_count:       number;
  rejected_count:       number;
  in_progress_count:    number;
  avg_turnaround_hours: number | null;
}

type DatePreset = '7d' | '30d' | '90d' | 'custom';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function safeNum(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const n = Number(v);
  return isNaN(n) ? null : n;
}

function fmtHours(h: number | null): string {
  if (h === null || isNaN(h)) return '—';
  if (h < 1)  return `${Math.round(h * 60)}m`;
  if (h < 24) return `${h.toFixed(1)}h`;
  return `${(h / 24).toFixed(1)}d`;
}

function toDateStr(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function presetDates(preset: DatePreset) {
  const to   = new Date();
  const from = new Date();
  if (preset === '7d')  from.setDate(from.getDate() - 7);
  if (preset === '30d') from.setDate(from.getDate() - 30);
  if (preset === '90d') from.setDate(from.getDate() - 90);
  return { from: toDateStr(from), to: toDateStr(to) };
}

function formatDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
    .format(new Date(iso));
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function KpiCard({ label, value, sub, accent }: {
  label: string; value: string; sub?: string; accent: string;
}) {
  return (
    <div style={{
      flex: '1 1 0', minWidth: 130,
      background: '#fff', border: '1.5px solid #E5E7EB',
      borderRadius: 10, padding: '16px 20px',
      boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
    }}>
      <div style={{ fontSize: 10, fontWeight: 700, color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.07em', marginBottom: 8 }}>
        {label}
      </div>
      <div style={{ fontSize: 26, fontWeight: 800, color: accent, lineHeight: 1 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

function Section({ title, icon, children, badge }: {
  title: string; icon: string; children: React.ReactNode; badge?: string;
}) {
  return (
    <div style={{
      background: '#fff', borderRadius: 12,
      border: '1px solid #E5E7EB', padding: '20px 24px', marginBottom: 20,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 16 }}>
        <i className={`fas ${icon}`} style={{ fontSize: 14, color: '#18345B' }} />
        <span style={{ fontWeight: 700, fontSize: 15, color: '#18345B' }}>{title}</span>
        {badge && (
          <span style={{
            fontSize: 11, fontWeight: 700, background: '#EFF6FF', color: '#2F77B5',
            borderRadius: 12, padding: '1px 8px', marginLeft: 2,
          }}>{badge}</span>
        )}
      </div>
      {children}
    </div>
  );
}

function EmptyState({ message }: { message: string }) {
  return (
    <div style={{ textAlign: 'center', padding: '32px 0', color: '#9CA3AF' }}>
      <i className="fas fa-chart-bar" style={{ fontSize: 26, display: 'block', marginBottom: 10, color: '#D1D5DB' }} />
      <span style={{ fontSize: 13 }}>{message}</span>
    </div>
  );
}

function THead({ children }: { children: React.ReactNode }) {
  return (
    <thead>
      <tr style={{ background: '#F9FAFB', borderBottom: '2px solid #E5E7EB' }}>
        {children}
      </tr>
    </thead>
  );
}

function Th({ children, right }: { children: React.ReactNode; right?: boolean }) {
  return (
    <th style={{
      padding: '10px 12px', textAlign: right ? 'right' : 'left',
      fontSize: 11, fontWeight: 700, color: '#9CA3AF',
      textTransform: 'uppercase', letterSpacing: '0.05em', whiteSpace: 'nowrap',
    }}>
      {children}
    </th>
  );
}

function Td({ children, right, muted }: { children: React.ReactNode; right?: boolean; muted?: boolean }) {
  return (
    <td style={{
      padding: '10px 12px', textAlign: right ? 'right' : 'left',
      fontSize: 13, color: muted ? '#9CA3AF' : '#111827',
      borderTop: '1px solid #F3F4F6', whiteSpace: 'nowrap',
    }}>
      {children}
    </td>
  );
}

function PctBadge({ value, threshold }: { value: number | null; threshold: number }) {
  if (value === null) return <span style={{ color: '#9CA3AF' }}>—</span>;
  const high = value >= threshold;
  const mid  = value > 0;
  return (
    <span style={{
      display: 'inline-block', padding: '1px 8px', borderRadius: 4,
      fontSize: 11, fontWeight: 700,
      background: high ? '#FEF2F2' : mid ? '#FFFBEB' : '#F0FDF4',
      color:      high ? '#DC2626' : mid ? '#D97706' : '#16A34A',
    }}>
      {value.toFixed(1)}%
    </span>
  );
}

// ─── Main Component ───────────────────────────────────────────────────────────

export default function WorkflowAnalytics() {
  const [preset,   setPreset]   = useState<DatePreset>('30d');
  const [fromDate, setFromDate] = useState(presetDates('30d').from);
  const [toDate,   setToDate]   = useState(presetDates('30d').to);

  const [turnaround, setTurnaround] = useState<TurnaroundRow[]>([]);
  const [rejection,  setRejection]  = useState<RejectionRow[]>([]);
  const [submitters, setSubmitters] = useState<SubmitterRow[]>([]);

  const [loading,     setLoading]     = useState(false);
  const [error,       setError]       = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);

  // Submitter search + pagination
  const [submitterSearch, setSubmitterSearch] = useState('');
  const [submitterPage,   setSubmitterPage]   = useState(1);
  const submitterPageSize = 10;

  function applyPreset(p: DatePreset) {
    setPreset(p);
    if (p !== 'custom') {
      const d = presetDates(p);
      setFromDate(d.from);
      setToDate(d.to);
    }
  }

  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [t, r, s] = await Promise.all([
        supabase.rpc('wf_analytics_turnaround',        { p_from: fromDate, p_to: toDate }),
        supabase.rpc('wf_analytics_rejection_rates',   { p_from: fromDate, p_to: toDate }),
        supabase.rpc('wf_analytics_submitter_activity',{ p_from: fromDate, p_to: toDate }),
      ]);
      if (t.error) throw new Error(t.error.message);
      if (r.error) throw new Error(r.error.message);
      if (s.error) throw new Error(s.error.message);

      setTurnaround((t.data ?? []).map((row: any) => ({
        ...row,
        total_submitted:    Number(row.total_submitted   ?? 0),
        approved_count:     Number(row.approved_count    ?? 0),
        rejected_count:     Number(row.rejected_count    ?? 0),
        in_progress_count:  Number(row.in_progress_count ?? 0),
        avg_hours_all:      safeNum(row.avg_hours_all),
        avg_hours_approved: safeNum(row.avg_hours_approved),
        avg_hours_rejected: safeNum(row.avg_hours_rejected),
        min_hours:          safeNum(row.min_hours),
        max_hours:          safeNum(row.max_hours),
      })));

      setRejection((r.data ?? []).map((row: any) => ({
        ...row,
        step_order:     Number(row.step_order    ?? 0),
        total_tasks:    Number(row.total_tasks    ?? 0),
        approved_count: Number(row.approved_count ?? 0),
        rejected_count: Number(row.rejected_count ?? 0),
        overdue_now:    Number(row.overdue_now    ?? 0),
        completed_late: Number(row.completed_late ?? 0),
        rejection_pct:  safeNum(row.rejection_pct),
        sla_breach_pct: safeNum(row.sla_breach_pct),
        sla_hours:      safeNum(row.sla_hours),
      })));

      setSubmitters((s.data ?? []).map((row: any) => ({
        ...row,
        total_submissions:   Number(row.total_submissions   ?? 0),
        approved_count:      Number(row.approved_count      ?? 0),
        rejected_count:      Number(row.rejected_count      ?? 0),
        in_progress_count:   Number(row.in_progress_count   ?? 0),
        avg_turnaround_hours: safeNum(row.avg_turnaround_hours),
      })));

      setLastUpdated(new Date());
      setSubmitterPage(1);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load analytics');
    } finally {
      setLoading(false);
    }
  }, [fromDate, toDate]);

  useEffect(() => { loadData(); }, [loadData]);

  // ── KPIs ──────────────────────────────────────────────────────────────────
  const totalSubmitted  = turnaround.reduce((s, r) => s + r.total_submitted,  0);
  const totalApproved   = turnaround.reduce((s, r) => s + r.approved_count,   0);
  const totalRejected   = turnaround.reduce((s, r) => s + r.rejected_count,   0);
  const totalOverdue    = rejection.reduce( (s, r) => s + r.overdue_now,      0);
  const avgRows         = turnaround.filter(r => r.avg_hours_all !== null);
  const overallAvg      = avgRows.length
    ? avgRows.reduce((s, r) => s + r.avg_hours_all!, 0) / avgRows.length
    : null;
  const rejectionRate   = totalApproved + totalRejected > 0
    ? (totalRejected / (totalApproved + totalRejected)) * 100
    : null;

  // ── Submitter filter + pagination ─────────────────────────────────────────
  const filteredSubmitters = useMemo(() => {
    const q = submitterSearch.trim().toLowerCase();
    return !q ? submitters : submitters.filter(s => s.employee_name.toLowerCase().includes(q));
  }, [submitters, submitterSearch]);

  const submitterTotalPages = Math.max(1, Math.ceil(filteredSubmitters.length / submitterPageSize));
  const submitterSafePage   = Math.min(submitterPage, submitterTotalPages);
  const pagedSubmitters     = filteredSubmitters.slice(
    (submitterSafePage - 1) * submitterPageSize,
    submitterSafePage * submitterPageSize
  );

  // ─── Render ───────────────────────────────────────────────────────────────

  return (
    <div style={{ padding: '32px 40px', maxWidth: 1200, margin: '0 auto' }}>

      {/* Header */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: '#18345B', margin: 0 }}>
            Workflow Analytics
          </h1>
          <p style={{ fontSize: 13, color: '#6B7280', marginTop: 4, margin: 0 }}>
            Approval performance, rejection trends and submitter activity
          </p>
        </div>
        <button
          onClick={loadData}
          disabled={loading}
          style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '6px 12px', borderRadius: 6, border: '1px solid #D1D5DB',
            background: '#fff', fontSize: 12, fontWeight: 500, color: '#374151',
            cursor: loading ? 'not-allowed' : 'pointer', opacity: loading ? 0.7 : 1,
          }}
        >
          <i className={`fas fa-arrows-rotate ${loading ? 'fa-spin' : ''}`} style={{ fontSize: 11 }} />
          Refresh
        </button>
      </div>

      {/* Date filter */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap',
        marginBottom: 20,
      }}>
        <div style={{ display: 'flex', gap: 4, background: '#F3F4F6', borderRadius: 8, padding: 3 }}>
          {(['7d', '30d', '90d'] as DatePreset[]).map(p => (
            <button key={p} onClick={() => applyPreset(p)} style={{
              padding: '5px 11px', borderRadius: 6, border: 'none',
              background: preset === p ? '#18345B' : 'transparent',
              color:      preset === p ? '#fff'    : '#6B7280',
              fontWeight: 600, fontSize: 12, cursor: 'pointer', transition: 'all 0.15s',
            }}>
              {p === '7d' ? 'Last 7 days' : p === '30d' ? 'Last 30 days' : 'Last 90 days'}
            </button>
          ))}
          <button onClick={() => applyPreset('custom')} style={{
            padding: '5px 11px', borderRadius: 6, border: 'none',
            background: preset === 'custom' ? '#18345B' : 'transparent',
            color:      preset === 'custom' ? '#fff'    : '#6B7280',
            fontWeight: 600, fontSize: 12, cursor: 'pointer', transition: 'all 0.15s',
          }}>
            Custom
          </button>
        </div>

        {preset === 'custom' && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input type="date" value={fromDate} onChange={e => setFromDate(e.target.value)}
              style={dateInputStyle} />
            <span style={{ fontSize: 12, color: '#9CA3AF' }}>to</span>
            <input type="date" value={toDate} onChange={e => setToDate(e.target.value)}
              style={dateInputStyle} />
            <button onClick={loadData} style={{
              padding: '5px 12px', borderRadius: 6, border: 'none',
              background: '#18345B', color: '#fff', fontSize: 12, fontWeight: 600, cursor: 'pointer',
            }}>
              Apply
            </button>
          </div>
        )}

        {lastUpdated && !loading && (
          <span style={{ fontSize: 11, color: '#9CA3AF', marginLeft: 'auto' }}>
            {formatDate(fromDate)} – {formatDate(toDate)} · updated {lastUpdated.toLocaleTimeString()}
          </span>
        )}
      </div>

      {/* Error */}
      {error && (
        <div style={{
          padding: '10px 14px', borderRadius: 8, marginBottom: 20,
          background: '#FEF2F2', border: '1px solid #FECACA', color: '#DC2626', fontSize: 13,
        }}>
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 8 }} />
          {error}
        </div>
      )}

      {/* Loading */}
      {loading && (
        <>
          <div style={{ display: 'flex', gap: 12, marginBottom: 20 }}>
            {[1,2,3,4].map(i => (
              <div key={i} style={{
                flex: '1 1 0', height: 80, borderRadius: 10,
                background: 'linear-gradient(90deg,#F3F4F6 25%,#E5E7EB 50%,#F3F4F6 75%)',
                backgroundSize: '200% 100%', animation: 'shimmer 1.4s infinite',
              }} />
            ))}
          </div>
          <style>{`@keyframes shimmer{0%{background-position:200% 0}100%{background-position:-200% 0}}`}</style>
        </>
      )}

      {!loading && (
        <>
          {/* KPIs */}
          <div style={{ display: 'flex', gap: 12, marginBottom: 20, flexWrap: 'wrap' }}>
            <KpiCard label="Total Submitted"  value={totalSubmitted.toLocaleString()} accent="#2F77B5"
              sub={`${formatDate(fromDate)} – ${formatDate(toDate)}`} />
            <KpiCard label="Avg Turnaround"   value={fmtHours(overallAvg)} accent="#7C3AED"
              sub="across all templates" />
            <KpiCard label="Rejection Rate"
              value={rejectionRate !== null ? `${rejectionRate.toFixed(1)}%` : '—'}
              accent={totalRejected > 0 ? '#DC2626' : '#16A34A'}
              sub={`${totalRejected} rejected`} />
            <KpiCard label="Overdue Now"      value={totalOverdue.toLocaleString()}
              accent={totalOverdue > 0 ? '#D97706' : '#16A34A'}
              sub="pending tasks past SLA" />
          </div>

          {/* ── Section 1: Turnaround ── */}
          <Section title="Approval Turnaround by Template" icon="fa-clock" badge={String(turnaround.length)}>
            {turnaround.length === 0
              ? <EmptyState message="No completed workflows in this period." />
              : (
                <div style={{ overflowX: 'auto' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                    <THead>
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
                    </THead>
                    <tbody>
                      {turnaround.map(row => (
                        <tr key={row.template_id} style={{ transition: 'background 0.1s' }}
                          onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                          onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}>
                          <Td>
                            <div style={{ fontWeight: 600, color: '#111827' }}>{row.template_name}</div>
                            <div style={{ fontSize: 10, color: '#9CA3AF', fontFamily: 'monospace' }}>{row.template_code}</div>
                          </Td>
                          <Td right>{row.total_submitted.toLocaleString()}</Td>
                          <Td right><span style={{ color: '#16A34A', fontWeight: 600 }}>{row.approved_count.toLocaleString()}</span></Td>
                          <Td right>
                            <span style={{ color: row.rejected_count > 0 ? '#DC2626' : '#9CA3AF', fontWeight: row.rejected_count > 0 ? 600 : 400 }}>
                              {row.rejected_count.toLocaleString()}
                            </span>
                          </Td>
                          <Td right muted={row.in_progress_count === 0}>{row.in_progress_count.toLocaleString()}</Td>
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
          </Section>

          {/* ── Section 2: Rejection & SLA ── */}
          <Section title="Rejection & SLA Breach Rates by Step" icon="fa-triangle-exclamation" badge={String(rejection.length)}>
            {rejection.length === 0
              ? <EmptyState message="No task data in this period." />
              : (
                <div style={{ overflowX: 'auto' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                    <THead>
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
                    </THead>
                    <tbody>
                      {rejection.map((row, i) => (
                        <tr key={i}
                          onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                          onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}>
                          <Td>
                            <div style={{ fontWeight: 600, color: '#111827' }}>{row.template_name}</div>
                            <div style={{ fontSize: 10, color: '#9CA3AF', fontFamily: 'monospace' }}>{row.template_code}</div>
                          </Td>
                          <Td>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                              <span style={{
                                fontSize: 10, background: '#EFF6FF', color: '#1D4ED8',
                                borderRadius: 4, padding: '1px 6px', fontWeight: 700,
                              }}>Step {row.step_order}</span>
                              {row.step_name}
                            </div>
                          </Td>
                          <Td right muted>{row.sla_hours ? `${row.sla_hours}h` : '—'}</Td>
                          <Td right>{row.total_tasks.toLocaleString()}</Td>
                          <Td right><span style={{ color: '#16A34A' }}>{row.approved_count.toLocaleString()}</span></Td>
                          <Td right>
                            <span style={{ color: row.rejected_count > 0 ? '#DC2626' : '#9CA3AF' }}>
                              {row.rejected_count.toLocaleString()}
                            </span>
                          </Td>
                          <Td right>
                            {row.overdue_now > 0
                              ? <span style={{ color: '#DC2626', fontWeight: 700 }}>{row.overdue_now}</span>
                              : <span style={{ color: '#9CA3AF' }}>0</span>}
                          </Td>
                          <Td right>
                            {row.completed_late > 0
                              ? <span style={{ color: '#D97706' }}>{row.completed_late}</span>
                              : <span style={{ color: '#9CA3AF' }}>0</span>}
                          </Td>
                          <Td right><PctBadge value={row.rejection_pct}  threshold={20} /></Td>
                          <Td right><PctBadge value={row.sla_breach_pct} threshold={30} /></Td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
          </Section>

          {/* ── Section 3: Submitter Activity ── */}
          <Section title="Submitter Activity" icon="fa-users" badge={String(submitters.length)}>
            {submitters.length === 0
              ? <EmptyState message="No submission activity in this period." />
              : (
                <>
                  {/* Search */}
                  <div style={{ position: 'relative', maxWidth: 280, marginBottom: 12 }}>
                    <i className="fas fa-magnifying-glass" style={{
                      position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
                      fontSize: 12, color: '#9CA3AF', pointerEvents: 'none',
                    }} />
                    <input
                      type="text" placeholder="Search by name…"
                      value={submitterSearch}
                      onChange={e => { setSubmitterSearch(e.target.value); setSubmitterPage(1); }}
                      style={{
                        width: '100%', padding: '7px 10px 7px 30px', borderRadius: 6,
                        border: '1px solid #D1D5DB', fontSize: 13, color: '#374151',
                        outline: 'none', boxSizing: 'border-box',
                      }}
                    />
                  </div>

                  <div style={{ overflowX: 'auto' }}>
                    <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                      <THead>
                        <Th>Employee</Th>
                        <Th>Department</Th>
                        <Th right>Submissions</Th>
                        <Th right>Approved</Th>
                        <Th right>Rejected</Th>
                        <Th right>In Progress</Th>
                        <Th right>Approval Rate</Th>
                        <Th right>Avg Turnaround</Th>
                      </THead>
                      <tbody>
                        {pagedSubmitters.length === 0 ? (
                          <tr>
                            <td colSpan={8} style={{ textAlign: 'center', padding: '24px 0', color: '#9CA3AF', fontSize: 13 }}>
                              No results for "{submitterSearch}"
                            </td>
                          </tr>
                        ) : pagedSubmitters.map(row => {
                          const completed    = row.approved_count + row.rejected_count;
                          const approvalRate = completed > 0 ? (row.approved_count / completed) * 100 : null;
                          return (
                            <tr key={row.employee_id}
                              onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                              onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}>
                              <Td><span style={{ fontWeight: 600 }}>{row.employee_name}</span></Td>
                              <Td muted={!row.department_name}>{row.department_name ?? '—'}</Td>
                              <Td right><span style={{ fontWeight: 600, color: '#2F77B5' }}>{row.total_submissions.toLocaleString()}</span></Td>
                              <Td right><span style={{ color: '#16A34A' }}>{row.approved_count.toLocaleString()}</span></Td>
                              <Td right>
                                <span style={{ color: row.rejected_count > 0 ? '#DC2626' : '#9CA3AF' }}>
                                  {row.rejected_count.toLocaleString()}
                                </span>
                              </Td>
                              <Td right muted={row.in_progress_count === 0}>{row.in_progress_count.toLocaleString()}</Td>
                              <Td right>
                                {approvalRate !== null ? (
                                  <span style={{
                                    fontWeight: 700,
                                    color: approvalRate >= 80 ? '#16A34A' : approvalRate >= 50 ? '#D97706' : '#DC2626',
                                  }}>
                                    {approvalRate.toFixed(0)}%
                                  </span>
                                ) : <span style={{ color: '#9CA3AF' }}>—</span>}
                              </Td>
                              <Td right muted={!row.avg_turnaround_hours}>{fmtHours(row.avg_turnaround_hours)}</Td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>

                  {/* Pagination */}
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 12 }}>
                    <span style={{ fontSize: 12, color: '#9CA3AF' }}>
                      {filteredSubmitters.length === 0 ? 'No results'
                        : `${(submitterSafePage - 1) * submitterPageSize + 1}–${Math.min(submitterSafePage * submitterPageSize, filteredSubmitters.length)} of ${filteredSubmitters.length}`}
                    </span>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <PaginationBtn disabled={submitterSafePage === 1}
                        onClick={() => setSubmitterPage(p => Math.max(1, p - 1))}>
                        <i className="fas fa-chevron-left" style={{ fontSize: 10 }} /> Prev
                      </PaginationBtn>
                      <PaginationBtn disabled={submitterSafePage === submitterTotalPages}
                        onClick={() => setSubmitterPage(p => Math.min(submitterTotalPages, p + 1))}>
                        Next <i className="fas fa-chevron-right" style={{ fontSize: 10 }} />
                      </PaginationBtn>
                    </div>
                  </div>
                </>
              )}
          </Section>
        </>
      )}
    </div>
  );
}

// ── Tiny helpers ───────────────────────────────────────────────────────────────

function PaginationBtn({ disabled, onClick, children }: {
  disabled: boolean; onClick: () => void; children: React.ReactNode;
}) {
  return (
    <button onClick={onClick} disabled={disabled} style={{
      padding: '5px 12px', borderRadius: 6, border: '1px solid #D1D5DB',
      background: disabled ? '#F9FAFB' : '#fff',
      color: disabled ? '#D1D5DB' : '#374151',
      fontSize: 12, fontWeight: 500, cursor: disabled ? 'not-allowed' : 'pointer',
      display: 'flex', alignItems: 'center', gap: 5,
    }}>
      {children}
    </button>
  );
}

const dateInputStyle: React.CSSProperties = {
  padding: '5px 8px', borderRadius: 6, border: '1px solid #D1D5DB',
  fontSize: 12, color: '#374151', outline: 'none',
};
