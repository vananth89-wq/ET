/**
 * ExpenseAnalytics — Expense Reports Analytics Dashboard
 *
 * Sections:
 *   1. Filter bar  — date range, department, employee, scope toggle
 *   2. KPI row     — 6 headline numbers
 *   3. Charts row  — Spend by Department (bar) + Status Funnel (donut)
 *   4. Trend chart — Monthly approved spend (line)
 *   5. Pending     — In-flight reports sorted oldest-first
 *   6. Export      — CSV per section + full Excel export
 *
 * Permission-aware: managers see their team; finance/admin see org-wide.
 */

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useNavigate }    from 'react-router-dom';
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
  PieChart, Pie, Cell, Legend,
  LineChart, Line,
} from 'recharts';
import { supabase }         from '../../../lib/supabase';
import { usePermissions }   from '../../../hooks/usePermissions';
import { useAuth }          from '../../../contexts/AuthContext';
import { fmtAmount }        from '../../../utils/currency';

// ─── Types ────────────────────────────────────────────────────────────────────

interface KPIs {
  total_submitted:    number;
  total_approved:     number;
  total_rejected:     number;
  total_pending:      number;
  approved_spend:     number;
  rejection_rate:     number;
  avg_approval_hours: number | null;
  sla_compliance_rate: number | null;
}

interface DeptSpend   { dept_id: string; dept_name: string; spend: number; count: number }
interface StatusCount { status: string; count: number }
interface MonthSpend  { month: string; month_start: string; spend: number; count: number }
interface PendingRow  {
  report_id:     string;
  report_name:   string;
  employee_name: string;
  dept_name:     string;
  status:        string;
  submitted_at:  string;
  days_waiting:  number;
  total_amount:  number;
  currency_code: string;
  current_step:  string | null;
  assignee_name: string | null;
}

interface Employee { id: string; name: string }
interface Dept     { id: string; name: string }

// ─── Date range presets ───────────────────────────────────────────────────────

type RangePreset = 'this_month' | 'last_month' | 'this_quarter' | 'last_6_months' | 'this_year' | 'custom';

function rangeToTimestamps(preset: RangePreset, custom: { from: string; to: string }) {
  const now   = new Date();
  const year  = now.getFullYear();
  const month = now.getMonth();

  switch (preset) {
    case 'this_month':
      return { from: new Date(year, month, 1).toISOString(), to: new Date(year, month + 1, 1).toISOString() };
    case 'last_month':
      return { from: new Date(year, month - 1, 1).toISOString(), to: new Date(year, month, 1).toISOString() };
    case 'this_quarter': {
      const q = Math.floor(month / 3);
      return { from: new Date(year, q * 3, 1).toISOString(), to: new Date(year, q * 3 + 3, 1).toISOString() };
    }
    case 'last_6_months':
      return { from: new Date(year, month - 5, 1).toISOString(), to: new Date(year, month + 1, 1).toISOString() };
    case 'this_year':
      return { from: new Date(year, 0, 1).toISOString(), to: new Date(year + 1, 0, 1).toISOString() };
    case 'custom':
      return {
        from: custom.from ? new Date(custom.from).toISOString() : null,
        to:   custom.to   ? new Date(custom.to).toISOString()   : null,
      };
    default:
      return { from: null, to: null };
  }
}

// ─── Chart colours ────────────────────────────────────────────────────────────

const STATUS_COLORS: Record<string,string> = {
  draft:            '#9CA3AF',
  submitted:        '#60A5FA',
  manager_approved: '#FBBF24',
  approved:         '#34D399',
  rejected:         '#F87171',
};
const STATUS_LABELS: Record<string,string> = {
  draft:            'Draft',
  submitted:        'Submitted',
  manager_approved: 'Manager Approved',
  approved:         'Approved',
  rejected:         'Rejected',
};

// ─── CSV export helpers ───────────────────────────────────────────────────────

function downloadCSV(filename: string, rows: Record<string, unknown>[]) {
  if (!rows.length) return;
  const headers = Object.keys(rows[0]);
  const lines = [
    headers.join(','),
    ...rows.map(r => headers.map(h => {
      const v = String(r[h] ?? '');
      return v.includes(',') || v.includes('"') || v.includes('\n')
        ? `"${v.replace(/"/g, '""')}"` : v;
    }).join(',')),
  ];
  const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href = url; a.download = filename; a.click();
  URL.revokeObjectURL(url);
}

// ─── Small helpers ────────────────────────────────────────────────────────────

function fmt(n: number | null | undefined, decimals = 0) {
  if (n == null) return '—';
  return n.toLocaleString('en-US', { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
}

function KpiCard({ label, value, sub, icon, color }: {
  label: string; value: string; sub?: string; icon: string; color: string;
}) {
  return (
    <div className="kpi-card" style={{ flex: '1 1 150px', minWidth: 140 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
        <div style={{
          width: 36, height: 36, borderRadius: 8, background: color + '1A',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        }}>
          <i className={`fas ${icon}`} style={{ color, fontSize: 15 }} />
        </div>
        <span style={{ fontSize: 12, color: 'var(--text-secondary)', fontWeight: 500 }}>{label}</span>
      </div>
      <div className="kpi-value" style={{ fontSize: 24, color }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function ExpenseAnalytics() {
  const navigate          = useNavigate();
  const { can, canAny }   = usePermissions();
  useAuth();

  // ── Permission checks ────────────────────────────────────────────────────
  const isAdmin   = can('security.manage_roles');
  const isFinance = can('expense.view_org');
  const isManager = canAny(['expense.view_direct', 'expense.view_team']);
  const canView   = can('report.view') || isFinance || isManager || isAdmin;

  // ── Filter state ─────────────────────────────────────────────────────────
  const [rangePreset,  setRangePreset]  = useState<RangePreset>('this_month');
  const [customFrom,   setCustomFrom]   = useState('');
  const [customTo,     setCustomTo]     = useState('');
  const [deptId,       setDeptId]       = useState<string>('');
  const [employeeId,   setEmployeeId]   = useState<string>('');

  // ── Reference data for filter dropdowns ──────────────────────────────────
  const [depts,     setDepts]     = useState<Dept[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);

  // ── Data state ────────────────────────────────────────────────────────────
  const [kpis,     setKpis]     = useState<KPIs | null>(null);
  const [deptData, setDeptData] = useState<DeptSpend[]>([]);
  const [funnel,   setFunnel]   = useState<StatusCount[]>([]);
  const [trend,    setTrend]    = useState<MonthSpend[]>([]);
  const [pending,  setPending]  = useState<PendingRow[]>([]);
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);

  // ── Computed timestamps ───────────────────────────────────────────────────
  const { from: dateFrom, to: dateTo } = useMemo(
    () => rangeToTimestamps(rangePreset, { from: customFrom, to: customTo }),
    [rangePreset, customFrom, customTo],
  );

  // ── Load reference data once ─────────────────────────────────────────────
  useEffect(() => {
    supabase.from('departments').select('id, name').order('name')
      .then(({ data }) => setDepts(data ?? []));
    supabase.from('employees').select('id, name').is('deleted_at', null).order('name')
      .then(({ data }) => setEmployees(data ?? []));
  }, []);

  // ── Fetch all analytics data ──────────────────────────────────────────────
  const fetchAll = useCallback(async () => {
    setLoading(true);
    setError(null);

    const params = {
      p_date_from:   dateFrom  || null,
      p_date_to:     dateTo    || null,
      p_dept_id:     deptId    || null,
      p_employee_id: employeeId || null,
    };

    try {
      const [kpisRes, deptRes, funnelRes, trendRes, pendingRes] = await Promise.all([
        supabase.rpc('rpc_expense_kpis',          params),
        supabase.rpc('rpc_spend_by_department',   params),
        supabase.rpc('rpc_expense_status_funnel', params),
        supabase.rpc('rpc_monthly_spend_trend',   { p_months: 6, p_dept_id: params.p_dept_id, p_employee_id: params.p_employee_id }),
        supabase.rpc('rpc_pending_approvals',     { p_dept_id: params.p_dept_id, p_employee_id: params.p_employee_id }),
      ]);

      if (kpisRes.error)    throw new Error(kpisRes.error.message);
      if (deptRes.error)    throw new Error(deptRes.error.message);
      if (funnelRes.error)  throw new Error(funnelRes.error.message);
      if (trendRes.error)   throw new Error(trendRes.error.message);
      if (pendingRes.error) throw new Error(pendingRes.error.message);

      setKpis(kpisRes.data   as unknown as KPIs);
      setDeptData(deptRes.data  as DeptSpend[]);
      setFunnel(funnelRes.data  as StatusCount[]);
      setTrend(trendRes.data    as MonthSpend[]);
      setPending(pendingRes.data as PendingRow[]);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [dateFrom, dateTo, deptId, employeeId]);

  useEffect(() => { fetchAll(); }, [fetchAll]);

  // ── Export handlers ───────────────────────────────────────────────────────
  function exportPendingCSV() {
    downloadCSV('pending_approvals.csv', pending.map(r => ({
      'Report Name':   r.report_name,
      'Employee':      r.employee_name,
      'Department':    r.dept_name,
      'Status':        STATUS_LABELS[r.status] ?? r.status,
      'Submitted At':  r.submitted_at ? new Date(r.submitted_at).toLocaleDateString() : '',
      'Days Waiting':  r.days_waiting,
      'Amount':        r.total_amount,
      'Currency':      r.currency_code,
      'Current Step':  r.current_step ?? '',
      'Assignee':      r.assignee_name ?? '',
    })));
  }

  function exportSpendCSV() {
    downloadCSV('spend_by_department.csv', deptData.map(d => ({
      'Department':    d.dept_name,
      'Approved Spend': d.spend,
      'Report Count':   d.count,
    })));
  }

  function exportSummaryCSV() {
    if (!kpis) return;
    downloadCSV('expense_summary.csv', [{
      'Total Submitted':     kpis.total_submitted,
      'Total Approved':      kpis.total_approved,
      'Total Rejected':      kpis.total_rejected,
      'Total Pending':       kpis.total_pending,
      'Approved Spend':      kpis.approved_spend,
      'Rejection Rate (%)':  kpis.rejection_rate,
      'Avg Approval (hrs)':  kpis.avg_approval_hours ?? '',
      'SLA Compliance (%)':  kpis.sla_compliance_rate ?? '',
    }]);
  }

  // ── Guard ─────────────────────────────────────────────────────────────────
  if (!canView) {
    return (
      <div className="page-container">
        <div className="empty-state">
          <i className="fa-solid fa-ban empty-state-icon" />
          <div className="empty-state-title">Access Denied</div>
          <div className="empty-state-subtitle">You do not have permission to view analytics.</div>
        </div>
      </div>
    );
  }

  // ── Render ────────────────────────────────────────────────────────────────
  return (
    <div className="page-container">

      {/* ── Page header ───────────────────────────────────────────────────── */}
      <div className="page-header">
        <div>
          <h1 className="page-title">
            <i className="fa-solid fa-chart-line" style={{ marginRight: 10 }} />
            Expense Analytics
          </h1>
          <p className="page-subtitle">Spend insights, approval pipeline, and SLA performance.</p>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <button className="btn btn-ghost btn-sm" onClick={exportSummaryCSV} title="Export KPI summary">
            <i className="fa-solid fa-file-csv" /> Summary CSV
          </button>
          <button className="btn btn-ghost btn-sm" onClick={fetchAll} title="Refresh">
            <i className="fa-solid fa-rotate-right" />
          </button>
        </div>
      </div>

      {/* ── Filter bar ────────────────────────────────────────────────────── */}
      <div style={{
        display: 'flex', flexWrap: 'wrap', gap: 10, alignItems: 'flex-end',
        background: 'var(--surface)', borderRadius: 10, padding: '14px 16px', marginBottom: 20,
        border: '1px solid var(--border)',
      }}>
        {/* Date range preset */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <label style={{ fontSize: 11, color: 'var(--text-secondary)', fontWeight: 600 }}>DATE RANGE</label>
          <select
            className="form-input"
            style={{ minWidth: 150 }}
            value={rangePreset}
            onChange={e => setRangePreset(e.target.value as RangePreset)}
          >
            <option value="this_month">This Month</option>
            <option value="last_month">Last Month</option>
            <option value="this_quarter">This Quarter</option>
            <option value="last_6_months">Last 6 Months</option>
            <option value="this_year">This Year</option>
            <option value="custom">Custom</option>
          </select>
        </div>

        {/* Custom date inputs */}
        {rangePreset === 'custom' && (
          <>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <label style={{ fontSize: 11, color: 'var(--text-secondary)', fontWeight: 600 }}>FROM</label>
              <input type="date" className="form-input" value={customFrom} onChange={e => setCustomFrom(e.target.value)} />
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <label style={{ fontSize: 11, color: 'var(--text-secondary)', fontWeight: 600 }}>TO</label>
              <input type="date" className="form-input" value={customTo} onChange={e => setCustomTo(e.target.value)} />
            </div>
          </>
        )}

        {/* Department filter */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <label style={{ fontSize: 11, color: 'var(--text-secondary)', fontWeight: 600 }}>DEPARTMENT</label>
          <select
            className="form-input"
            style={{ minWidth: 160 }}
            value={deptId}
            onChange={e => setDeptId(e.target.value)}
          >
            <option value="">All Departments</option>
            {depts.map(d => <option key={d.id} value={d.id}>{d.name}</option>)}
          </select>
        </div>

        {/* Employee filter */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <label style={{ fontSize: 11, color: 'var(--text-secondary)', fontWeight: 600 }}>EMPLOYEE</label>
          <select
            className="form-input"
            style={{ minWidth: 180 }}
            value={employeeId}
            onChange={e => setEmployeeId(e.target.value)}
          >
            <option value="">All Employees</option>
            {employees.map(e => <option key={e.id} value={e.id}>{e.name}</option>)}
          </select>
        </div>

        {/* Clear filters */}
        {(deptId || employeeId || rangePreset !== 'this_month') && (
          <button
            className="btn btn-ghost btn-sm"
            style={{ alignSelf: 'flex-end' }}
            onClick={() => { setDeptId(''); setEmployeeId(''); setRangePreset('this_month'); }}
          >
            <i className="fa-solid fa-xmark" /> Clear
          </button>
        )}
      </div>

      {/* ── Error ─────────────────────────────────────────────────────────── */}
      {error && (
        <div className="form-error-banner" style={{ marginBottom: 16 }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{error}
        </div>
      )}

      {loading ? (
        <div className="loading-state"><span className="spinner" /> Loading analytics…</div>
      ) : (
        <>
          {/* ── KPI row ─────────────────────────────────────────────────── */}
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, marginBottom: 24 }}>
            <KpiCard label="Approved Spend"      value={fmtAmount(kpis?.approved_spend ?? 0, 'USD')} icon="fa-coins"          color="#2F77B5" />
            <KpiCard label="Reports Submitted"   value={fmt(kpis?.total_submitted)}                  icon="fa-paper-plane"    color="#6366F1" />
            <KpiCard label="Approved"            value={fmt(kpis?.total_approved)}                   icon="fa-circle-check"   color="#10B981" />
            <KpiCard label="Pending Approval"    value={fmt(kpis?.total_pending)}                    icon="fa-clock"          color="#F59E0B" />
            <KpiCard label="Avg Approval Time"
              value={kpis?.avg_approval_hours != null ? `${fmt(kpis.avg_approval_hours, 1)}h` : '—'}
              icon="fa-stopwatch" color="#8B5CF6"
            />
            <KpiCard label="SLA Compliance"
              value={kpis?.sla_compliance_rate != null ? `${fmt(kpis.sla_compliance_rate, 1)}%` : '—'}
              sub={`Rejection rate: ${fmt(kpis?.rejection_rate, 1)}%`}
              icon="fa-shield-check" color="#0EA5E9"
            />
          </div>

          {/* ── Charts row ──────────────────────────────────────────────── */}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 24 }}>

            {/* Spend by Department bar chart */}
            <div className="card" style={{ padding: '20px 16px' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
                <h3 style={{ margin: 0, fontSize: 14, fontWeight: 700 }}>Approved Spend by Department</h3>
                <button className="btn btn-ghost btn-sm" onClick={exportSpendCSV} title="Export CSV">
                  <i className="fa-solid fa-file-csv" />
                </button>
              </div>
              {deptData.length === 0 ? (
                <div className="empty-state" style={{ minHeight: 180 }}>
                  <i className="fa-solid fa-chart-bar empty-state-icon" />
                  <div className="empty-state-subtitle">No data for this period</div>
                </div>
              ) : (
                <ResponsiveContainer width="100%" height={220}>
                  <BarChart data={deptData} margin={{ top: 0, right: 8, bottom: 24, left: 0 }}>
                    <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                    <XAxis dataKey="dept_name" tick={{ fontSize: 11 }} angle={-30} textAnchor="end" interval={0} />
                    <YAxis tick={{ fontSize: 11 }} tickFormatter={v => `$${(v/1000).toFixed(0)}k`} />
                    <Tooltip formatter={(v) => [`$${Number(v).toLocaleString()}`, 'Spend']} />
                    <Bar dataKey="spend" fill="#2F77B5" radius={[4,4,0,0]} />
                  </BarChart>
                </ResponsiveContainer>
              )}
            </div>

            {/* Status Funnel donut */}
            <div className="card" style={{ padding: '20px 16px' }}>
              <h3 style={{ margin: '0 0 16px', fontSize: 14, fontWeight: 700 }}>Report Status Breakdown</h3>
              {funnel.length === 0 ? (
                <div className="empty-state" style={{ minHeight: 180 }}>
                  <i className="fa-solid fa-chart-pie empty-state-icon" />
                  <div className="empty-state-subtitle">No data for this period</div>
                </div>
              ) : (
                <ResponsiveContainer width="100%" height={220}>
                  <PieChart>
                    <Pie
                      data={funnel}
                      dataKey="count"
                      nameKey="status"
                      cx="50%"
                      cy="50%"
                      innerRadius={55}
                      outerRadius={85}
                      paddingAngle={3}
                      label={({ name, value }: { name?: string | number; value?: number }) => `${STATUS_LABELS[String(name)] ?? String(name)}: ${value ?? 0}`}
                      labelLine={false}
                    >
                      {funnel.map((entry) => (
                        <Cell
                          key={entry.status}
                          fill={STATUS_COLORS[entry.status] ?? '#9CA3AF'}
                        />
                      ))}
                    </Pie>
                    <Tooltip formatter={(v, name) => [v, STATUS_LABELS[String(name)] ?? String(name)]} />
                    <Legend
                      formatter={(value) => STATUS_LABELS[value] ?? value}
                      iconType="circle"
                      iconSize={8}
                      wrapperStyle={{ fontSize: 12 }}
                    />
                  </PieChart>
                </ResponsiveContainer>
              )}
            </div>
          </div>

          {/* ── Monthly trend ────────────────────────────────────────────── */}
          <div className="card" style={{ padding: '20px 16px', marginBottom: 24 }}>
            <h3 style={{ margin: '0 0 16px', fontSize: 14, fontWeight: 700 }}>
              Monthly Approved Spend — Last 6 Months
            </h3>
            {trend.length === 0 ? (
              <div className="empty-state" style={{ minHeight: 140 }}>
                <i className="fa-solid fa-chart-line empty-state-icon" />
                <div className="empty-state-subtitle">No approved spend data yet</div>
              </div>
            ) : (
              <ResponsiveContainer width="100%" height={200}>
                <LineChart data={trend} margin={{ top: 0, right: 16, bottom: 0, left: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                  <XAxis dataKey="month" tick={{ fontSize: 12 }} />
                  <YAxis tick={{ fontSize: 11 }} tickFormatter={v => `$${(v/1000).toFixed(0)}k`} />
                  <Tooltip formatter={(v) => [`$${Number(v).toLocaleString()}`, 'Approved Spend']} />
                  <Line
                    type="monotone"
                    dataKey="spend"
                    stroke="#2F77B5"
                    strokeWidth={2.5}
                    dot={{ r: 4, fill: '#2F77B5' }}
                    activeDot={{ r: 6 }}
                  />
                </LineChart>
              </ResponsiveContainer>
            )}
          </div>

          {/* ── Pending approvals table ──────────────────────────────────── */}
          <div className="card" style={{ padding: '20px 16px' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
              <div>
                <h3 style={{ margin: 0, fontSize: 14, fontWeight: 700 }}>
                  Pending Approvals
                  {pending.length > 0 && (
                    <span style={{
                      marginLeft: 8, background: '#FEF3C7', color: '#92400E',
                      borderRadius: 20, padding: '2px 8px', fontSize: 11, fontWeight: 700,
                    }}>{pending.length}</span>
                  )}
                </h3>
                <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--text-secondary)' }}>
                  Sorted by age — oldest first
                </p>
              </div>
              <div style={{ display: 'flex', gap: 8 }}>
                {pending.length > 0 && (
                  <button className="btn btn-ghost btn-sm" onClick={exportPendingCSV}>
                    <i className="fa-solid fa-file-csv" /> Export CSV
                  </button>
                )}
                <button className="btn btn-primary btn-sm" onClick={() => navigate('/admin/workflow/inbox')}>
                  <i className="fa-solid fa-inbox" /> Open Inbox
                </button>
              </div>
            </div>

            {pending.length === 0 ? (
              <div className="empty-state" style={{ minHeight: 120 }}>
                <i className="fa-solid fa-check-circle empty-state-icon" style={{ color: 'var(--success)' }} />
                <div className="empty-state-title">All clear!</div>
                <div className="empty-state-subtitle">No reports are pending approval.</div>
              </div>
            ) : (
              <div style={{ overflowX: 'auto' }}>
                <table className="data-table" style={{ width: '100%' }}>
                  <thead>
                    <tr>
                      <th>Report</th>
                      <th>Employee</th>
                      <th>Department</th>
                      <th>Status</th>
                      <th>Submitted</th>
                      <th>Waiting</th>
                      <th>Amount</th>
                      <th>Step / Assignee</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    {pending.map(row => (
                      <tr key={row.report_id}>
                        <td style={{ fontWeight: 600, maxWidth: 200 }}>
                          <span
                            style={{ cursor: 'pointer', color: 'var(--primary)' }}
                            onClick={() => navigate(`/expense/report/${row.report_id}`)}
                          >
                            {row.report_name}
                          </span>
                        </td>
                        <td>{row.employee_name}</td>
                        <td>{row.dept_name ?? '—'}</td>
                        <td>
                          <span style={{
                            display: 'inline-block', padding: '2px 8px', borderRadius: 20,
                            fontSize: 11, fontWeight: 600,
                            background: (STATUS_COLORS[row.status] ?? '#9CA3AF') + '22',
                            color: STATUS_COLORS[row.status] ?? '#6B7280',
                          }}>
                            {STATUS_LABELS[row.status] ?? row.status}
                          </span>
                        </td>
                        <td style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                          {row.submitted_at ? new Date(row.submitted_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '—'}
                        </td>
                        <td>
                          <span style={{
                            fontWeight: 700,
                            color: row.days_waiting >= 5 ? '#DC2626' : row.days_waiting >= 3 ? '#D97706' : '#10B981',
                          }}>
                            {row.days_waiting}d
                          </span>
                        </td>
                        <td style={{ fontWeight: 600 }}>
                          {fmtAmount(row.total_amount, row.currency_code)}
                        </td>
                        <td style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                          {row.current_step ?? '—'}
                          {row.assignee_name && (
                            <div style={{ fontSize: 11, color: 'var(--text-tertiary)' }}>
                              → {row.assignee_name}
                            </div>
                          )}
                        </td>
                        <td>
                          <button
                            className="btn btn-ghost btn-sm"
                            onClick={() => navigate(`/expense/report/${row.report_id}`)}
                            title="View report"
                          >
                            <i className="fa-solid fa-eye" />
                          </button>
                        </td>
                      </tr>
                    ))}
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
