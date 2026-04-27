import { useMemo, useState, useRef, useEffect, useCallback } from 'react';
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer,
  PieChart, Pie, Cell, Legend,
  Area, AreaChart,
} from 'recharts';
import { useLocalStorage } from '../../hooks/useLocalStorage';
import { useAuth } from '../../contexts/AuthContext';
import { useEmployees, type Employee } from '../../hooks/useEmployees';
import { useDepartments } from '../../hooks/useDepartments';
import { useExpenseData } from '../../hooks/useExpenseData';
import { useProjects } from '../../hooks/useProjects';
import { usePermissions } from '../../hooks/usePermissions';
import { useExchangeRates } from '../../hooks/useExchangeRates';
import { useCurrencies } from '../../hooks/useCurrencies';
import type { ExpenseReport } from '../../types';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

interface Dept  { deptId: string; name: string; }
interface Proj  { id: string | number; name: string; }

interface FlatRow {
  reportId: string; reportName: string; status: string; baseCurrency: string;
  submittedAt: string; approvedAt: string;
  employeeId: string; empName: string;
  deptId: string; deptName: string;
  liId: string; category: string; date: string;
  projectId: string; projectName: string;
  amount: number; currencyCode: string; exchangeRate: number | null;
  convertedAmount: number; // base INR
  note: string;
}

interface ReportDef {
  id: string; name: string; description: string;
  roles: string[]; active: boolean; lastUpdated: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const RPT_ICONS: Record<string, string> = { expense: 'fa-file-invoice-dollar' };
const DEFAULT_REPORTS: ReportDef[] = [{
  id: 'expense', name: 'Expense Report',
  description: 'View all employee expenses and export to Excel.',
  roles: ['admin', 'finance'], active: true, lastUpdated: '2026-04-16',
}];

const FX_FALLBACK: Record<string, Record<string, number>> = {
  INR: { '2023': 1,     '2024': 1,     '2025': 1,     '2026': 1     },
  SAR: { '2023': 22.38, '2024': 22.50, '2025': 22.60, '2026': 22.70 },
  PKR: { '2023': 0.288, '2024': 0.299, '2025': 0.300, '2026': 0.302 },
  LKR: { '2023': 0.252, '2024': 0.272, '2025': 0.270, '2026': 0.287 },
};
const CCY_SYM: Record<string, string> = { INR: '₹', SAR: '﷼', PKR: '₨', LKR: 'Rs' };
const BAR_PALETTE = ['#1976D2','#00897B','#3949AB','#8E24AA','#FB8C00','#90A4AE','#0288D1','#00ACC1'];
const STATUS_PALETTE: Record<string, string> = {
  Draft: '#757575', Submitted: '#1976D2', 'Mgr Approved': '#7B1FA2',
  Approved: '#2E7D32', Rejected: '#D32F2F',
};

/** Maps a raw DB status code to a human-readable label. */
function statusLabel(s: string): string {
  const map: Record<string, string> = {
    draft: 'Draft', submitted: 'Submitted',
    manager_approved: 'Mgr Approved',
    approved: 'Approved', rejected: 'Rejected',
  };
  return map[s] ?? capitalize(s);
}
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const PAGE_SIZES = [20, 50, 100];

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function fmtNum(n: number) {
  return n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
function fmtDate(str: string) {
  if (!str) return '—';
  const d = new Date(str.length === 10 ? str + 'T00:00:00' : str);
  if (isNaN(d.getTime())) return str;
  return `${String(d.getDate()).padStart(2,'0')}-${MONTHS[d.getMonth()]}-${String(d.getFullYear()).slice(2)}`;
}
function fmtLastUpdated(iso: string) {
  try { return new Date(iso + 'T00:00:00').toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' }); } catch { return iso; }
}
function initial(name: string) { return (name || '?').charAt(0).toUpperCase(); }
function capitalize(s: string) { return s.charAt(0).toUpperCase() + s.slice(1); }

function getFxRate(
  ccy: string, date: string,
  rates: { date: string; fromCcy: string; toCcy: string; rate: number }[]
): number {
  if (ccy === 'INR') return 1;
  const m = rates.find(r => r.date === date && r.fromCcy === ccy && r.toCcy === 'INR');
  if (m) return Number(m.rate);
  const m2 = rates.find(r => r.date === date && r.fromCcy === 'INR' && r.toCcy === ccy);
  if (m2 && Number(m2.rate)) return 1 / Number(m2.rate);
  const year = (date || String(new Date().getFullYear())).slice(0, 4);
  const ccyMap = FX_FALLBACK[ccy];
  if (!ccyMap) return 1;
  return ccyMap[year] || ccyMap['2025'] || 1;
}

function convertToView(row: FlatRow, viewCcy: string, rates: { date: string; fromCcy: string; toCcy: string; rate: number }[]): number {
  if (viewCcy === 'INR') return row.convertedAmount;
  if (row.currencyCode === viewCcy && row.exchangeRate) return row.amount;
  const rate = getFxRate(viewCcy, row.date, rates);
  return rate > 0 ? row.convertedAmount / rate : row.convertedAmount;
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-select dropdown component
// ─────────────────────────────────────────────────────────────────────────────

interface MSDropdownProps {
  id: string; icon: string; label: string;
  options: { value: string; label: string }[];
  selected: string[];
  onChange: (vals: string[]) => void;
}
function MSDropdown({ id, icon, label, options, selected, onChange }: MSDropdownProps) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState('');
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handler(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  const visible = options.filter(o => !search || o.label.toLowerCase().includes(search.toLowerCase()));
  const active = selected.length > 0;
  const btnLabel = active ? `${label} (${selected.length})` : label;

  return (
    <div className="er-chip er-chip-ms" ref={ref} style={{ position: 'relative' }}>
      <button
        className={`er-ms-btn${active ? ' er-ms-btn-active' : ''}`}
        onClick={() => setOpen(o => !o)}
        type="button"
      >
        <i className={`fa-solid ${icon} er-chip-icon`} />
        <span className="er-ms-lbl">{btnLabel}</span>
        <i className="fa-solid fa-chevron-down er-ms-caret" />
      </button>
      {open && (
        <div className="er-ms-panel" id={`er-ms-panel-${id}`}>
          <div className="er-ms-search">
            <input
              className="er-ms-search-inp"
              placeholder="Search…"
              value={search}
              onChange={e => setSearch(e.target.value)}
              autoFocus
            />
          </div>
          <ul className="er-ms-list">
            {visible.map(o => (
              <li key={o.value}>
                <label className="er-ms-item">
                  <input
                    type="checkbox"
                    checked={selected.includes(o.value)}
                    onChange={e => {
                      if (e.target.checked) onChange([...selected, o.value]);
                      else onChange(selected.filter(v => v !== o.value));
                    }}
                  />
                  <span>{o.label}</span>
                </label>
              </li>
            ))}
            {visible.length === 0 && (
              <li style={{ padding: '10px 14px', color: '#9aadc8', fontSize: 12 }}>No options</li>
            )}
          </ul>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Status badge
// ─────────────────────────────────────────────────────────────────────────────

function ErStatusBadge({ status }: { status: string }) {
  const cls: Record<string, string> = {
    draft:            'er-badge-draft',
    submitted:        'er-badge-submitted',
    manager_approved: 'er-badge-manager-approved',
    approved:         'er-badge-approved',
    rejected:         'er-badge-rejected',
  };
  return (
    <span className={`er-status-badge ${cls[status] || 'er-badge-draft'}`}>
      {statusLabel(status)}
    </span>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Charts
// ─────────────────────────────────────────────────────────────────────────────

interface ChartsProps { rows: FlatRow[]; viewCcy: string; rates: { date: string; fromCcy: string; toCcy: string; rate: number }[]; }

function Charts({ rows, viewCcy, rates }: ChartsProps) {
  const sym = CCY_SYM[viewCcy] || viewCcy;

  // KPI total
  const total = rows.reduce((s, r) => s + convertToView(r, viewCcy, rates), 0);

  // Bar — project-wise spend
  const projTotals: Record<string, number> = {};
  rows.forEach(r => {
    const k = r.projectName || 'Unknown';
    projTotals[k] = (projTotals[k] || 0) + convertToView(r, viewCcy, rates);
  });
  const barData = Object.entries(projTotals)
    .sort((a, b) => b[1] - a[1]).slice(0, 12)
    .map(([name, value], i) => ({ name, value: Math.round(value * 100) / 100, fill: BAR_PALETTE[i % BAR_PALETTE.length] }));

  // Donut — status distribution (per unique report)
  const seenReports: Record<string, boolean> = {};
  const statusCounts: Record<string, number> = {
    Draft: 0, Submitted: 0, 'Mgr Approved': 0, Approved: 0, Rejected: 0,
  };
  rows.forEach(r => {
    if (!seenReports[r.reportId]) {
      seenReports[r.reportId] = true;
      const key = statusLabel(r.status || 'draft');
      if (key in statusCounts) statusCounts[key]++;
      else statusCounts['Draft']++;
    }
  });
  const donutData = Object.entries(statusCounts)
    .filter(([, v]) => v > 0)
    .map(([name, value]) => ({ name, value }));

  // Line — monthly trend
  const monthTotals: Record<string, number> = {};
  rows.forEach(r => {
    if (!r.date) return;
    const ym = r.date.slice(0, 7);
    monthTotals[ym] = (monthTotals[ym] || 0) + convertToView(r, viewCcy, rates);
  });
  const lineData = Object.keys(monthTotals).sort().map(ym => {
    const [y, m] = ym.split('-');
    return { name: `${MONTHS[parseInt(m) - 1]} ${y}`, value: Math.round(monthTotals[ym] * 100) / 100 };
  });

  return (
    <div className="er-charts-section" id="er-charts-section">
      {/* KPI */}
      <div className="er-chart-card er-kpi-card">
        <div className="er-chart-title"><i className="fa-solid fa-coins" /> Total Spend</div>
        <div className="er-kpi-body">
          <div className="er-kpi-amount" id="er-kpi-amount">{sym} {fmtNum(total)}</div>
          <div className="er-kpi-label">Total Spend</div>
        </div>
      </div>

      {/* Bar */}
      <div className="er-chart-card">
        <div className="er-chart-title"><i className="fa-solid fa-chart-column" /> Project-wise Spend</div>
        <div className="er-chart-body">
          <ResponsiveContainer width="100%" height={160}>
            <BarChart data={barData} margin={{ top: 8, right: 4, left: 4, bottom: 0 }}>
              <XAxis dataKey="name" tick={{ fontSize: 10 }} axisLine={false} tickLine={false} />
              <YAxis tick={{ fontSize: 10 }} tickFormatter={v => fmtNum(v)} axisLine={false} tickLine={false} />
              <Tooltip formatter={(v: unknown) => [`${sym} ${fmtNum(Number(v))}`, 'Spend']} />
              <Bar dataKey="value" radius={[4, 4, 0, 0]}>
                {barData.map((entry, i) => <Cell key={i} fill={entry.fill} />)}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Donut */}
      <div className="er-chart-card">
        <div className="er-chart-title"><i className="fa-solid fa-circle-half-stroke" /> Status Distribution</div>
        <div className="er-chart-body">
          <ResponsiveContainer width="100%" height={160}>
            <PieChart>
              <Pie data={donutData} cx="50%" cy="50%" innerRadius={48} outerRadius={68} dataKey="value">
                {donutData.map((entry, i) => <Cell key={i} fill={STATUS_PALETTE[entry.name] || '#90A4AE'} />)}
              </Pie>
              <Legend iconSize={10} wrapperStyle={{ fontSize: 11 }} />
              <Tooltip formatter={(v: unknown) => [`${v} reports`, '']} />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Line */}
      <div className="er-chart-card">
        <div className="er-chart-title"><i className="fa-solid fa-chart-line" /> Monthly Trend</div>
        <div className="er-chart-body">
          <ResponsiveContainer width="100%" height={160}>
            <AreaChart data={lineData} margin={{ top: 8, right: 8, left: 4, bottom: 0 }}>
              <defs>
                <linearGradient id="trendGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="#1976D2" stopOpacity={0.15} />
                  <stop offset="95%" stopColor="#1976D2" stopOpacity={0} />
                </linearGradient>
              </defs>
              <XAxis dataKey="name" tick={{ fontSize: 10 }} axisLine={false} tickLine={false} />
              <YAxis tick={{ fontSize: 10 }} tickFormatter={v => fmtNum(v)} axisLine={false} tickLine={false} />
              <Tooltip formatter={(v: unknown) => [`${sym} ${fmtNum(Number(v))}`, 'Spend']} />
              <Area type="monotone" dataKey="value" stroke="#1976D2" strokeWidth={2.5}
                fill="url(#trendGrad)" dot={{ r: 4, fill: '#1976D2' }} />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Expense Report Detail (Panel 2) — line-item analytics
// ─────────────────────────────────────────────────────────────────────────────

function ExpenseReportDetail({ onBack }: { onBack: () => void }) {
  const { reports }  = useExpenseData();
  const { employees: supabaseEmps } = useEmployees();
  const { departments: supabaseDepts } = useDepartments();
  const { employee: authEmployee }  = useAuth();
  const { can } = usePermissions();
  const employees = supabaseEmps;
  const depts     = supabaseDepts as unknown as Dept[];
  const { projects } = useProjects(false);
  const { rates: rawRates } = useExchangeRates();
  const { currencies }      = useCurrencies();

  // Normalise Supabase exchange rate rows to the shape getFxRate expects
  const exRates = useMemo(
    () => rawRates.map(r => ({ date: r.effectiveDate, fromCcy: r.fromCode ?? '', toCcy: r.toCode ?? '', rate: r.rate })),
    [rawRates],
  );

  const [viewCcy, setViewCcy]     = useState('INR');
  const [search, setSearch]       = useState('');
  const [selEmp, setSelEmp]       = useState<string[]>([]);
  const [selDept, setSelDept]     = useState<string[]>([]);
  const [selProj, setSelProj]     = useState<string[]>([]);
  const [selStatus, setSelStatus] = useState<string[]>([]);
  const [expFrom, setExpFrom]     = useState('');
  const [expTo, setExpTo]         = useState('');
  const [appFrom, setAppFrom]     = useState('');
  const [appTo, setAppTo]         = useState('');
  const [page, setPage]           = useState(1);
  const [pageSize, setPageSize]   = useState(20);

  // Applied filter state (only updated on "Apply Filters")
  const [applied, setApplied] = useState({
    search: '', selEmp: [] as string[], selDept: [] as string[], selProj: [] as string[],
    selStatus: [] as string[], expFrom: '', expTo: '', appFrom: '', appTo: '',
  });

  // Resolve employee record by ID.
  const resolveEmployee = useCallback((empId: string, hintName?: string) => {
    // 1. Direct ID match
    let emp = employees.find(e => String(e.employeeId) === String(empId));
    if (emp) return emp;

    // 2. Match by stored employeeName on the report (set on new reports)
    if (hintName) {
      emp = employees.find(e => (e.name || '').toLowerCase() === hintName.toLowerCase());
      if (emp) return emp;
    }

    // 3. For legacy 'current' ID — use AuthContext employee
    if (empId === 'current') {
      if (authEmployee) {
        // Match the auth employee in the full list to get all fields.
        // authEmployee is already typed as Employee (camelCase), no cast needed.
        emp = employees.find(e =>
          e.employeeId === authEmployee.employeeId ||
          (e.name || '').toLowerCase() === (authEmployee.name || '').toLowerCase()
        );
        if (emp) return emp;
        // Return authEmployee itself as fallback — same Employee type now
        return authEmployee;
      }
      if (employees.length > 0) return employees[0];
    }

    return null;
  }, [employees]);

  // Current employee name for display on legacy 'current' reports
  const profileName = authEmployee?.name ?? '';

  // Flatten all reports → one row per line item
  const allRows: FlatRow[] = useMemo(() => {
    const rows: FlatRow[] = [];
    reports.forEach(rpt => {
      const emp    = resolveEmployee(rpt.employeeId || '', rpt.employeeName);
      const deptId = emp?.deptId ?? '';
      // deptId from Supabase employees is a UUID FK; match by id (UUID) or deptId (text code)
      const dept   = deptId ? depts.find(d => d.id === deptId || d.deptId === deptId) : null;

      // Determine best display name for this report's owner
      const displayName = emp
        ? (emp.name || '—')
        : (rpt.employeeName || (rpt.employeeId === 'current' ? profileName : rpt.employeeId) || '—');

      (rpt.lineItems || []).forEach(li => {
        const proj = projects.find(p => String(p.id) === String(li.projectId));
        rows.push({
          reportId:        rpt.id,
          reportName:      rpt.name || '—',
          status:          rpt.status || 'draft',
          baseCurrency:    (rpt as any).baseCurrencyCode || 'INR',
          submittedAt:     rpt.submittedAt || '',
          approvedAt:      (rpt as any).approvedAt || '',
          employeeId:      emp ? emp.employeeId : (rpt.employeeId || ''),
          empName:         displayName,
          deptId:          deptId,
          deptName:        dept ? (dept.name || '—') : '—',
          liId:            li.id,
          category:        (li as any).categoryName || (li as any).category_name || li.category || '—',
          date:            li.date || '',
          projectId:       String(li.projectId || ''),
          projectName:     proj ? (proj.name || '—') : (li.projectId ? String(li.projectId) : '—'),
          amount:          Number(li.amount || 0),
          currencyCode:    li.currencyCode || (rpt as any).baseCurrencyCode || 'INR',
          exchangeRate:    li.exchangeRate ? Number(li.exchangeRate) : null,
          convertedAmount: Number(li.convertedAmount || li.amount || 0),
          note:            li.note || '',
        });
      });
    });
    return rows;
  }, [reports, resolveEmployee, depts, projects]);

  // Options for multi-selects
  const empOptions = useMemo(() => {
    const m: Record<string, string> = {};
    allRows.forEach(r => { if (r.employeeId) m[r.employeeId] = r.empName; });
    return Object.entries(m).map(([value, label]) => ({ value, label })).sort((a, b) => a.label.localeCompare(b.label));
  }, [allRows]);
  const deptOptions = useMemo(() => {
    const m: Record<string, string> = {};
    allRows.forEach(r => { if (r.deptId) m[r.deptId] = r.deptName; });
    return Object.entries(m).map(([value, label]) => ({ value, label })).sort((a, b) => a.label.localeCompare(b.label));
  }, [allRows]);
  const projOptions = useMemo(() => {
    const m: Record<string, string> = {};
    allRows.forEach(r => { if (r.projectId) m[r.projectId] = r.projectName; });
    return Object.entries(m).map(([value, label]) => ({ value, label })).sort((a, b) => a.label.localeCompare(b.label));
  }, [allRows]);
  const statusOptions = [
    { value: 'draft',            label: 'Draft'        },
    { value: 'submitted',        label: 'Submitted'    },
    { value: 'manager_approved', label: 'Mgr Approved' },
    { value: 'approved',         label: 'Approved'     },
    { value: 'rejected',         label: 'Rejected'     },
  ];

  // Apply filters
  function applyFilters() {
    setApplied({ search, selEmp, selDept, selProj, selStatus, expFrom, expTo, appFrom, appTo });
    setPage(1);
  }
  function resetFilters() {
    setSearch(''); setSelEmp([]); setSelDept([]); setSelProj([]); setSelStatus([]);
    setExpFrom(''); setExpTo(''); setAppFrom(''); setAppTo('');
    setApplied({ search: '', selEmp: [], selDept: [], selProj: [], selStatus: [], expFrom: '', expTo: '', appFrom: '', appTo: '' });
    setPage(1);
  }

  const filtered: FlatRow[] = useMemo(() => {
    const a = applied;
    return allRows.filter(r => {
      if (a.search) {
        const q = a.search.toLowerCase();
        if (!r.empName.toLowerCase().includes(q) && !r.reportName.toLowerCase().includes(q) && !r.note.toLowerCase().includes(q)) return false;
      }
      if (a.selEmp.length && !a.selEmp.includes(r.employeeId)) return false;
      if (a.selDept.length && !a.selDept.includes(r.deptId)) return false;
      if (a.selProj.length && !a.selProj.includes(r.projectId)) return false;
      if (a.selStatus.length && !a.selStatus.includes(r.status)) return false;
      if (a.expFrom && r.date < a.expFrom) return false;
      if (a.expTo   && r.date > a.expTo)   return false;
      if (a.appFrom && (!r.approvedAt || r.approvedAt.slice(0, 10) < a.appFrom)) return false;
      if (a.appTo   && (!r.approvedAt || r.approvedAt.slice(0, 10) > a.appTo))   return false;
      return true;
    });
  }, [allRows, applied]);

  const sym = CCY_SYM[viewCcy] || viewCcy;
  const totalPages = Math.max(1, Math.ceil(filtered.length / pageSize));
  const pageRows = filtered.slice((page - 1) * pageSize, page * pageSize);

  const footerTotal = filtered.reduce((s, r) => s + convertToView(r, viewCcy, exRates), 0);

  // Export to CSV
  const handleExport = useCallback(() => {
    const headers = ['#','Employee','Employee ID','Department','Report Name','Exp. Date','Category','Project','Amount','Currency','Converted (INR)','Status','Submitted','Approved'];
    const rows = filtered.map((r, i) => [
      i + 1, r.empName, r.employeeId, r.deptName, r.reportName,
      r.date, r.category, r.projectName,
      r.amount, r.currencyCode, r.convertedAmount,
      r.status, r.submittedAt ? r.submittedAt.slice(0, 10) : '', r.approvedAt ? r.approvedAt.slice(0, 10) : '',
    ]);
    const csv = [headers, ...rows].map(row => row.map(c => `"${String(c).replace(/"/g,'""')}"`).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = 'expense_report.csv'; a.click();
    URL.revokeObjectURL(url);
  }, [filtered]);

  return (
    <div className="er-page">
      {/* Detail header */}
      <div className="rpt-detail-header">
        <button className="rpt-back-btn" onClick={onBack}>
          <i className="fa-solid fa-arrow-left" /> Back to Reports
        </button>
        <h2 className="rpt-detail-title" style={{ margin: 0 }}>
          <i className="fa-solid fa-file-invoice-dollar" /> Expense Report
        </h2>
      </div>

      {/* Sticky toolbar */}
      <div className="er-toolbar" id="er-toolbar">
        {/* Row 1: search + multi-selects + date ranges */}
        <div className="er-filters-row">
          <div className="er-chip er-chip-search">
            <i className="fa-solid fa-magnifying-glass er-chip-icon" />
            <input
              className="er-search-inp"
              placeholder="Search employee, report, note…"
              value={search}
              onChange={e => setSearch(e.target.value)}
              onKeyDown={e => e.key === 'Enter' && applyFilters()}
            />
          </div>
          <MSDropdown id="emp" icon="fa-user" label="Employee" options={empOptions} selected={selEmp} onChange={setSelEmp} />
          <MSDropdown id="dept" icon="fa-sitemap" label="Department" options={deptOptions} selected={selDept} onChange={setSelDept} />
          <MSDropdown id="proj" icon="fa-folder-open" label="Project" options={projOptions} selected={selProj} onChange={setSelProj} />
          <MSDropdown id="status" icon="fa-tag" label="Status" options={statusOptions} selected={selStatus} onChange={setSelStatus} />
          <div className="er-chip er-chip-date">
            <i className="fa-solid fa-calendar-days er-chip-icon" />
            <span className="er-date-lbl">Exp. Date</span>
            <input type="date" className="er-date-inp" value={expFrom} onChange={e => setExpFrom(e.target.value)} />
            <span className="er-date-sep">–</span>
            <input type="date" className="er-date-inp" value={expTo} onChange={e => setExpTo(e.target.value)} />
          </div>
          <div className="er-chip er-chip-date">
            <i className="fa-solid fa-calendar-check er-chip-icon" />
            <span className="er-date-lbl">Approval Date</span>
            <input type="date" className="er-date-inp" value={appFrom} onChange={e => setAppFrom(e.target.value)} />
            <span className="er-date-sep">–</span>
            <input type="date" className="er-date-inp" value={appTo} onChange={e => setAppTo(e.target.value)} />
          </div>
        </div>

        {/* Row 2: currency + apply/reset + count + export */}
        <div className="er-filters-row2">
          <div className="er-ccy-group">
            <span className="er-ccy-label"><i className="fa-solid fa-coins" /> View Currency</span>
            <div className="er-ccy-toggle">
              {(currencies.length > 0 ? currencies : [{ code: 'INR', symbol: '₹' }]).map(c => (
                <button
                  key={c.code}
                  className={`er-ccy-btn${viewCcy === c.code ? ' er-ccy-active' : ''}`}
                  onClick={() => setViewCcy(c.code)}
                  type="button"
                >
                  {c.symbol} {c.code}
                </button>
              ))}
            </div>
          </div>
          <button className="er-apply-btn" onClick={applyFilters} type="button">
            <i className="fa-solid fa-filter" /> Apply Filters
          </button>
          <button className="er-reset-btn" onClick={resetFilters} type="button">
            <i className="fa-solid fa-rotate-left" /> Reset
          </button>
          <div style={{ flex: 1 }} />
          <span className="er-row-count" id="er-row-count">{filtered.length} rows</span>
          {can('expense.export') && (
            <button className="er-export-btn" onClick={handleExport} type="button">
              <i className="fa-solid fa-file-excel" /> Export
            </button>
          )}
        </div>
      </div>

      {/* Charts */}
      <Charts rows={filtered} viewCcy={viewCcy} rates={exRates} />

      {/* Single table with sticky thead — avoids the dual-table width sync problem */}
      <div style={{ overflowX: 'auto', overflowY: 'auto', maxHeight: 'calc(100vh - 420px)', minHeight: 200, background: '#fff', borderRadius: '0 0 12px 12px', boxShadow: '0 4px 16px rgba(24,52,91,0.08)' }}>
        <table className="er-table" id="er-table" style={{ tableLayout: 'auto', width: '100%' }}>
          <thead style={{ position: 'sticky', top: 0, zIndex: 10 }}>
            <tr>
              <th className="er-th-num">#</th>
              <th className="er-th-emp" style={{ minWidth: 180 }}>Employee</th>
              <th style={{ minWidth: 110, whiteSpace: 'nowrap' }}>Department</th>
              <th style={{ minWidth: 140, whiteSpace: 'nowrap' }}>Report Name</th>
              <th className="er-th-date" style={{ whiteSpace: 'nowrap' }}>Exp. Date</th>
              <th style={{ minWidth: 100, whiteSpace: 'nowrap' }}>Category</th>
              <th style={{ minWidth: 100, whiteSpace: 'nowrap' }}>Project</th>
              <th className="er-th-amt" style={{ whiteSpace: 'nowrap' }}>Amount</th>
              <th className="er-th-ccy" style={{ whiteSpace: 'nowrap' }}>Currency</th>
              <th className="er-th-amt" style={{ whiteSpace: 'nowrap' }}>Converted ({viewCcy})</th>
              <th className="er-th-status" style={{ whiteSpace: 'nowrap' }}>Status</th>
              <th className="er-th-date" style={{ whiteSpace: 'nowrap' }}>Submitted</th>
              <th className="er-th-date" style={{ whiteSpace: 'nowrap' }}>Approved</th>
            </tr>
          </thead>
          <tbody id="er-tbody">
            {pageRows.length === 0 ? (
              <tr>
                <td colSpan={13} style={{ textAlign: 'center', padding: 40, color: '#94a3b8' }}>
                  <i className="fa-solid fa-inbox" style={{ fontSize: 24, display: 'block', marginBottom: 8 }} />
                  No expense line items found.
                </td>
              </tr>
            ) : pageRows.map((r, i) => {
              const viewAmt = convertToView(r, viewCcy, exRates);
              const rowNum = (page - 1) * pageSize + i + 1;
              const isFx = r.currencyCode !== 'INR';
              return (
                <tr key={`${r.reportId}-${r.liId}`} className={`er-row${isFx ? ' er-row-fx' : ''}`}>
                  <td className="er-td-num">{rowNum}</td>
                  <td>
                    <div className="er-td-emp">
                      <span className="er-emp-avatar">{initial(r.empName)}</span>
                      <div className="er-emp-info">
                        <span className="er-emp-name">{r.empName}</span>
                        <span className="er-emp-id">{r.employeeId}</span>
                      </div>
                    </div>
                  </td>
                  <td style={{ whiteSpace: 'nowrap' }}>{r.deptName}</td>
                  <td className="er-td-report">
                    <div className="er-report-name" style={{ whiteSpace: 'nowrap' }}>{r.reportName}</div>
                  </td>
                  <td className="er-td-date">{fmtDate(r.date)}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>{r.category}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>{r.projectName}</td>
                  <td className="er-td-amt">{fmtNum(r.amount)}</td>
                  <td style={{ textAlign: 'center' }}>
                    <span className="er-ccy-pill">{r.currencyCode}</span>
                  </td>
                  <td className="er-td-amt">{sym} {fmtNum(viewAmt)}</td>
                  <td style={{ textAlign: 'center' }}><ErStatusBadge status={r.status} /></td>
                  <td className="er-td-date">{fmtDate(r.submittedAt)}</td>
                  <td className="er-td-date">{fmtDate(r.approvedAt)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {/* Footer */}
      <div className="er-footer" id="er-footer" style={{
        display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        padding: '10px 20px', background: '#fff', borderTop: '1px solid #e8eef5',
        borderRadius: '0 0 12px 12px', flexWrap: 'wrap', gap: 8,
      }}>
        <div className="er-pagination">
          <button className="er-pg-btn" onClick={() => setPage(p => Math.max(1, p - 1))} disabled={page <= 1} type="button">
            <i className="fa-solid fa-chevron-left" />
          </button>
          <span className="er-pg-info">Page {page} of {totalPages}</span>
          <button className="er-pg-btn" onClick={() => setPage(p => Math.min(totalPages, p + 1))} disabled={page >= totalPages} type="button">
            <i className="fa-solid fa-chevron-right" />
          </button>
          <select className="er-pg-size" value={pageSize} onChange={e => { setPageSize(Number(e.target.value)); setPage(1); }}>
            {PAGE_SIZES.map(s => <option key={s} value={s}>{s} / page</option>)}
          </select>
        </div>
        <div className="er-footer-totals" style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 12, color: '#4a5568' }}>
          <span className="er-footer-count" id="er-footer-count">{filtered.length} items</span>
          <span className="er-footer-sep">·</span>
          <span>Total: <strong>{sym} {fmtNum(footerTotal)}</strong></span>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Report Catalog (Panel 1)
// ─────────────────────────────────────────────────────────────────────────────

export default function AdminReports() {
  const [rptDescs, setRptDescs] = useLocalStorage<Record<string, string>>('prowess-rpt-desc', {});
  const [search, setSearch]       = useState('');
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState('');
  const [activeReport, setActiveReport] = useState<string | null>(null);
  const taRef = useRef<HTMLTextAreaElement>(null);

  const reports: ReportDef[] = useMemo(() =>
    DEFAULT_REPORTS.map(r => ({ ...r, description: rptDescs[r.id] ?? r.description })),
    [rptDescs]
  );

  const filtered = useMemo(() =>
    reports.filter(r =>
      !search ||
      r.name.toLowerCase().includes(search.toLowerCase()) ||
      r.description.toLowerCase().includes(search.toLowerCase()) ||
      r.roles.some(role => role.toLowerCase().includes(search.toLowerCase()))
    ), [reports, search]
  );

  function startEdit(rpt: ReportDef) {
    setEditingId(rpt.id);
    setEditDraft(rpt.description);
    setTimeout(() => taRef.current?.focus(), 50);
  }
  function saveDesc(id: string) {
    setRptDescs(prev => ({ ...prev, [id]: editDraft.trim() || prev[id] || '' }));
    setEditingId(null);
  }
  function cancelEdit() { setEditingId(null); setEditDraft(''); }

  if (activeReport === 'expense') {
    return <ExpenseReportDetail onBack={() => setActiveReport(null)} />;
  }

  return (
    <div className="ar-panel">
      <div className="rpt-title-bar">
        <div>
          <div className="rpt-title">Reports</div>
          <div className="rpt-subtitle">View and manage available reports</div>
        </div>
      </div>

      <div className="rpt-list-toolbar">
        <div className="rpt-list-search">
          <i className="fa-solid fa-magnifying-glass" />
          <input
            className="rpt-list-search-inp"
            placeholder="Search reports…"
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <div className="rpt-list-toolbar-right">
          <span className="rpt-list-count">{filtered.length} report{filtered.length !== 1 ? 's' : ''}</span>
        </div>
      </div>

      <div className="rpt-list-table-frame">
        {filtered.length === 0 ? (
          <div className="rpt-list-empty">
            <i className="fa-solid fa-file-chart-column" />
            <p>No reports match your search.</p>
          </div>
        ) : (
          <table className="rpt-list-table">
            <thead>
              <tr>
                <th>REPORT NAME</th><th>DESCRIPTION</th><th>ROLES</th>
                <th>STATUS</th><th>LAST UPDATED</th><th>ACTION</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map(rpt => {
                const icon = RPT_ICONS[rpt.id] || 'fa-file-chart-column';
                const isEditing = editingId === rpt.id;
                return (
                  <tr key={rpt.id} className="rpt-list-row">
                    <td>
                      <div className="rpt-name-cell">
                        <div className="rpt-name-icon"><i className={`fa-solid ${icon}`} /></div>
                        <div className="rpt-name-text">{rpt.name}</div>
                      </div>
                    </td>
                    <td className="rpt-list-td-desc">
                      <div className="rpt-card-desc-area">
                        {isEditing ? (
                          <div className="rpt-desc-edit-wrap" style={{ display: 'block' }}>
                            <textarea ref={taRef} className="rpt-desc-ta" value={editDraft}
                              onChange={e => setEditDraft(e.target.value)} rows={3} />
                            <div className="rpt-desc-edit-actions">
                              <button className="rpt-desc-save" onClick={() => saveDesc(rpt.id)}>
                                <i className="fa-solid fa-floppy-disk" /> Save
                              </button>
                              <button className="rpt-desc-cancel" onClick={cancelEdit}>Cancel</button>
                            </div>
                          </div>
                        ) : (
                          <>
                            <span className="rpt-card-desc">{rpt.description}</span>
                            <button className="rpt-pen-btn" title="Edit description" onClick={() => startEdit(rpt)}>
                              <i className="fa-solid fa-pen" />
                            </button>
                          </>
                        )}
                      </div>
                    </td>
                    <td>
                      <div className="rpt-roles-wrap">
                        {rpt.roles.map(role => (
                          <span key={role} className="rpt-role-badge">{capitalize(role)}</span>
                        ))}
                      </div>
                    </td>
                    <td>
                      <span className={`rpt-list-status ${rpt.active ? 'rpt-list-status-active' : 'rpt-list-status-inactive'}`}>
                        <i className={`fa-solid ${rpt.active ? 'fa-circle-check' : 'fa-circle-xmark'}`} />
                        {' '}{rpt.active ? 'Active' : 'Inactive'}
                      </span>
                    </td>
                    <td className="rpt-list-td-date">{fmtLastUpdated(rpt.lastUpdated)}</td>
                    <td className="rpt-list-td-action">
                      <button className="rpt-list-view-btn" onClick={() => setActiveReport(rpt.id)}>
                        View <i className="fa-solid fa-arrow-right" />
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
