import { useState, useMemo } from 'react';
import { useEmployees, type Employee } from '../../hooks/useEmployees';
import WorkflowGateBanner from '../../workflow/components/WorkflowGateBanner';
import { usePicklistValues }           from '../../hooks/usePicklistValues';
import { useDepartments }              from '../../hooks/useDepartments';
import { usePermissions }              from '../../hooks/usePermissions';
import { useCurrencies }               from '../../hooks/useCurrencies';
import ErrorBanner                     from '../shared/ErrorBanner';
import EmployeeEditPanel               from './EmployeeEditPanel';
import { supabase }                    from '../../lib/supabase';
// useNavigate removed — edit now uses inline EmployeeEditPanel

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────
interface PicklistValue {
  picklistId: string;
  id: string | number;
  value: string;
  refId?: string;
}

// Employee from useEmployees already has all fields (status, designation, deptId, etc.)
// No need for a FullEmployee wrapper — use the canonical type directly.
type FullEmployee = Employee;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function daysUntil(dateStr?: string): number | null {
  if (!dateStr || dateStr === '9999-12-31') return null;
  const diff = new Date(dateStr).getTime() - new Date(today()).getTime();
  return Math.ceil(diff / 86400000);
}

function fmtDate(val?: string): string {
  if (!val) return '—';
  if (val === '9999-12-31') return 'Open-ended';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

function getAvatar(emp: FullEmployee): string {
  if (emp.photo && typeof emp.photo === 'string') return emp.photo;
  const name = emp.name || 'E';
  return `https://ui-avatars.com/api/?name=${encodeURIComponent(name)}&background=2F77B5&color=fff&size=40`;
}

const STATUS_COLORS: Record<string, { bg: string; color: string }> = {
  Active:   { bg: '#DCFCE7', color: '#15803D' },
  Inactive: { bg: '#FEE2E2', color: '#DC2626' },
  // Draft / Incomplete / Pending are pre-hire statuses managed via the hire
  // workflow path and are filtered out of this list (see baseEmployees filter).
};

// ─────────────────────────────────────────────────────────────────────────────
// Export helper
// ─────────────────────────────────────────────────────────────────────────────
function exportCsv(rows: FullEmployee[], picklistVals: PicklistValue[]) {
  const resolve = (id: string, val?: unknown) => {
    if (!val) return '';
    const match = picklistVals.find(
      p => p.picklistId === id && (String(p.id) === String(val) || p.refId === String(val))
    );
    return match ? match.value : String(val);
  };

  const header = ['#', 'Employee ID', 'Name', 'Designation', 'Department', 'Manager', 'Role', 'Status', 'Hire Date', 'End Date'];
  const lines = rows.map((e, i) => [
    i + 1,
    e.employeeId,
    e.name,
    resolve('DESIGNATION', e.designation),
    e.deptId || '',
    e.managerId || '',
    e.role || '',
    e.status || '',
    fmtDate(e.hireDate ?? undefined),
    fmtDate(e.endDate ?? undefined),
  ].map(v => `"${String(v).replace(/"/g, '""')}"`).join(','));

  const csv = [header.join(','), ...lines].join('\n');
  const blob = new Blob([csv], { type: 'text/csv' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `employees_${today()}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

// ─────────────────────────────────────────────────────────────────────────────
// Alert Banner
// ─────────────────────────────────────────────────────────────────────────────
function AlertBanner({ type, employees, picklistVals }: {
  type: 'contract' | 'probation';
  employees: FullEmployee[];
  picklistVals: PicklistValue[];
}) {
  const [dismissed, setDismissed] = useState(false);
  if (dismissed) return null;

  const WARN = 30; // days
  const items = employees
    .filter(e => {
      const date = type === 'contract' ? e.endDate : e.probationEndDate;
      const days = daysUntil(date as string | undefined);
      return days !== null && days >= 0 && days <= WARN;
    })
    .map(e => {
      const date = type === 'contract' ? e.endDate : e.probationEndDate;
      const days = daysUntil(date as string | undefined)!;
      const resolvedDesig = (() => {
        const match = picklistVals.find(
          p => p.picklistId === 'DESIGNATION' &&
            (String(p.id) === String(e.designation) || p.refId === e.designation as string)
        );
        return match ? match.value : (e.designation as string | undefined) || '—';
      })();
      return { emp: e, days, date: date as string, resolvedDesig };
    })
    .sort((a, b) => a.days - b.days);

  if (items.length === 0) return null;

  const isContract = type === 'contract';
  const bg   = isContract ? '#FFF7ED' : '#EFF6FF';
  const border = isContract ? '#FDBA74' : '#93C5FD';
  const iconColor = isContract ? '#EA580C' : '#2563EB';
  const icon = isContract ? 'fa-calendar-xmark' : 'fa-hourglass-half';
  const title = isContract
    ? `Contract Expiry Alert — ${items.length} employee${items.length > 1 ? 's' : ''} expiring within ${WARN} days`
    : `Probation Expiry Alert — ${items.length} employee${items.length > 1 ? 's' : ''} ending probation within ${WARN} days`;

  return (
    <div style={{
      background: bg, border: `1px solid ${border}`, borderRadius: 10,
      padding: '12px 16px', marginBottom: 12,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
        <i className={`fa-solid ${icon}`} style={{ color: iconColor, fontSize: 15 }} />
        <span style={{ fontWeight: 600, fontSize: 13.5, color: iconColor }}>{title}</span>
        <button
          style={{ marginLeft: 'auto', background: 'none', border: 'none', cursor: 'pointer',
            color: '#9CA3AF', fontSize: 13, padding: '2px 4px' }}
          onClick={() => setDismissed(true)} title="Dismiss"
        >
          <i className="fa-solid fa-xmark" />
        </button>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {items.map(({ emp, days, date, resolvedDesig }) => (
          <div key={emp.employeeId} style={{
            background: '#fff', border: `1px solid ${border}`, borderRadius: 7,
            padding: '6px 10px', fontSize: 12.5, display: 'flex', gap: 8, alignItems: 'center',
          }}>
            <img src={getAvatar(emp)} alt={emp.name} style={{ width: 24, height: 24, borderRadius: '50%', flexShrink: 0 }} />
            <div>
              <div style={{ fontWeight: 600, color: '#1F2937' }}>{emp.name}</div>
              <div style={{ color: '#6B7280' }}>{resolvedDesig} · {emp.employeeId}</div>
            </div>
            <div style={{
              marginLeft: 4, background: days <= 7 ? '#FEE2E2' : days <= 14 ? '#FFF7ED' : '#FEF9C3',
              color: days <= 7 ? '#DC2626' : days <= 14 ? '#C2410C' : '#92400E',
              borderRadius: 5, padding: '2px 7px', fontWeight: 700, fontSize: 11,
            }}>
              {days === 0 ? 'Today' : `${days}d`} · {fmtDate(date)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Component
// ─────────────────────────────────────────────────────────────────────────────
export default function EmployeeDetails() {
  const { employees, loading: empLoading, error: empError, refetch } = useEmployees();
  const { picklistValues: picklistVals, error: plError }  = usePicklistValues();
  const { departments, error: deptError }                 = useDepartments();
  const { currencies }                                    = useCurrencies();
  const { can }                                           = usePermissions();

  const [editingEmpId, setEditingEmpId] = useState<string | null>(null);

  // Employment history panel
  const [histEmployeeId, setHistEmployeeId] = useState<string | null>(null);
  const [histRows,       setHistRows]       = useState<Record<string, unknown>[]>([]);
  const [histLoading,    setHistLoading]    = useState(false);
  const [histSelIdx,     setHistSelIdx]     = useState(0);

  async function openEmploymentHistory(empId: string) {
    setHistLoading(true);
    setHistEmployeeId(empId);
    setHistSelIdx(0);
    const { data } = await supabase.rpc('get_employment_info_history', { p_employee_id: empId });
    setHistRows((data as Record<string, unknown>[] | null) ?? []);
    setHistLoading(false);
  }

  function resolvePicklistHist(picklistId: string, id: unknown): string {
    if (!id) return '—';
    const found = picklistVals.find(v => v.picklistId === picklistId && (v.id === id || v.refId === String(id)));
    return found?.value ?? String(id);
  }
  function resolveDeptHist(id: unknown): string {
    if (!id) return '—';
    const d = departments.find(d => d.id === id);
    return d?.name ?? d?.deptId ?? String(id);
  }
  function resolveManagerHist(id: unknown): string {
    if (!id) return '—';
    const e = employees.find(e => e.id === id);
    return e ? e.name : String(id);
  }
  function fmtDateHist(v: unknown): string {
    if (!v || v === '9999-12-31') return v === '9999-12-31' ? 'Open-ended' : '—';
    return String(v);
  }

  // Filters
  const [filterName,    setFilterName]    = useState('');
  const [filterEmpId,   setFilterEmpId]   = useState('');
  const [filterDesig,   setFilterDesig]   = useState('');
  const [filterDept,    setFilterDept]    = useState('');
  const [filterStatus,  setFilterStatus]  = useState('');

  // ── Resend invite ──────────────────────────────────────────────────────────
  const [resendingIds,  setResendingIds]  = useState<Set<string>>(new Set());
  const [resendModal,   setResendModal]   = useState<{ ok: boolean; text: string } | null>(null);

  async function handleResendInvite(emp: FullEmployee) {
    if (!emp.id) return;
    setResendingIds(prev => new Set(prev).add(emp.id));
    setResendModal(null);
    try {
      const { data, error: rpcErr } = await supabase.rpc('resend_hire_invite', {
        p_employee_id: emp.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);

      const result = data as { ok: boolean; email: string; name: string } | null;
      if (!result?.ok || !result.email) throw new Error('Unexpected response from server.');

      // Fire the OTP — same mechanism as RoleAssignments.tsx inviteEmployee()
      const appUrl = (import.meta as any).env?.VITE_APP_URL || window.location.origin;
      const { error: otpErr } = await supabase.auth.signInWithOtp({
        email: result.email,
        options: { shouldCreateUser: true, emailRedirectTo: `${appUrl}/reset-password`, data: { full_name: result.name } },
      });

      if (otpErr) {
        // G-D fix: mark the employee_invites row as failed so the audit trail
        // reflects actual delivery rather than showing a spurious 'sent' status.
        await supabase.rpc('mark_invite_failed', {
          p_employee_id: emp.id,
          p_error:       otpErr.message,
        });
        throw new Error(otpErr.message);
      }

      setResendModal({ ok: true, text: `Invite resent to ${result.email}` });
    } catch (err: unknown) {
      const msg = (err as Error)?.message ?? String(err);
      setResendModal({ ok: false, text: msg });
    } finally {
      setResendingIds(prev => { const n = new Set(prev); n.delete(emp.id); return n; });
    }
  }

  // Active / non-draft employees only
  const activeEmployees = useMemo(
    () => employees.filter(e => !e.status || e.status === 'Active' || e.status === 'Inactive'),
    [employees]
  );

  // Unique designations for dropdown
  const designations = useMemo(() => {
    const ids = [...new Set(activeEmployees.map(e => String(e.designation || '')).filter(Boolean))];
    return ids.map(id => {
      const match = picklistVals.find(
        p => p.picklistId === 'DESIGNATION' && (String(p.id) === id || p.refId === id)
      );
      return { id, label: match ? match.value : id };
    });
  }, [activeEmployees, picklistVals]);

  // Filtered rows
  const filtered = useMemo(() => {
    const nm  = filterName.toLowerCase();
    const eid = filterEmpId.toLowerCase();
    return activeEmployees.filter(e => {
      if (nm  && !e.name.toLowerCase().includes(nm)) return false;
      if (eid && !e.employeeId.toLowerCase().includes(eid)) return false;
      if (filterDesig && String(e.designation || '') !== filterDesig) return false;
      if (filterDept  && String(e.deptId || '') !== filterDept) return false;
      if (filterStatus && (e.status || 'Active') !== filterStatus) return false;
      return true;
    });
  }, [activeEmployees, filterName, filterEmpId, filterDesig, filterDept, filterStatus]);

  const hasFilters = !!(filterName || filterEmpId || filterDesig || filterDept || filterStatus);

  function clearFilters() {
    setFilterName(''); setFilterEmpId(''); setFilterDesig('');
    setFilterDept(''); setFilterStatus('');
  }

  function resolveLabel(picklistId: string, val?: unknown): string {
    if (!val) return '—';
    const match = picklistVals.find(
      p => p.picklistId === picklistId &&
        (String(p.id) === String(val) || p.refId === String(val) || p.value === String(val))
    );
    return match ? match.value : String(val);
  }

  function resolveDept(deptId?: string): string {
    if (!deptId) return '—';
    // dept_id in employees table is a UUID FK; match by id (UUID) or deptId (text code) for compatibility
    const d = departments.find(d => d.id === deptId || d.deptId === deptId);
    return d ? d.name : deptId;
  }

  function resolveManager(managerId?: string): string {
    if (!managerId) return '—';
    // manager_id in employees table is a UUID FK; match by id (UUID) or employeeId (text code) for compatibility
    const m = employees.find(e => e.id === managerId || e.employeeId === managerId);
    return m ? m.name : managerId;
  }

  // ── Inline edit panel ─────────────────────────────────────────────────────
  if (editingEmpId) {
    const editingEmp = employees.find(e => e.employeeId === editingEmpId);
    if (editingEmp) {
      return (
        <EmployeeEditPanel
          emp={editingEmp as any}
          onClose={() => setEditingEmpId(null)}
          onSaved={() => refetch()}
        />
      );
    }
  }

  if (empError)  return <ErrorBanner message={empError}  onRetry={refetch} />;
  if (plError)   return <ErrorBanner message={plError} />;
  if (deptError) return <ErrorBanner message={deptError} />;

  return (
    <div className="page-content" style={{ padding: '28px 32px' }}>
      <h2 className="page-title" style={{ marginBottom: 20 }}>Employee Details</h2>

      {/* Workflow gate banner */}
      <WorkflowGateBanner moduleCode="employee_edit" actionLabel="employee detail edits" />

      {/* ── Alerts ──────────────────────────────────────────────────────── */}
      <AlertBanner type="contract"  employees={activeEmployees} picklistVals={picklistVals as any} />
      <AlertBanner type="probation" employees={activeEmployees} picklistVals={picklistVals as any} />

      {/* ── Filter Bar ──────────────────────────────────────────────────── */}
      <div style={{
        background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
        padding: '14px 18px', marginBottom: 18,
      }}>
        {/* Filter fields */}
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10, marginBottom: 12 }}>
          {/* Name */}
          <div className="emp-filter-field">
            <i className="fa-solid fa-magnifying-glass" />
            <input
              type="text" placeholder="Search name…"
              value={filterName} onChange={e => setFilterName(e.target.value)}
            />
          </div>
          {/* Employee ID */}
          <div className="emp-filter-field">
            <i className="fa-solid fa-hashtag" />
            <input
              type="text" placeholder="Employee ID"
              value={filterEmpId} onChange={e => setFilterEmpId(e.target.value)}
            />
          </div>
          {/* Designation */}
          <div className="emp-filter-field">
            <i className="fa-solid fa-id-badge" />
            <select value={filterDesig} onChange={e => setFilterDesig(e.target.value)}>
              <option value="">All Designations</option>
              {designations.map(d => (
                <option key={d.id} value={d.id}>{d.label}</option>
              ))}
            </select>
          </div>
          {/* Department */}
          <div className="emp-filter-field">
            <i className="fa-solid fa-sitemap" />
            <select value={filterDept} onChange={e => setFilterDept(e.target.value)}>
              <option value="">All Departments</option>
              {departments.map(d => (
                <option key={d.deptId} value={d.deptId}>{d.name}</option>
              ))}
            </select>
          </div>
          {/* Status */}
          <div className="emp-filter-field">
            <i className="fa-solid fa-circle-half-stroke" />
            <select value={filterStatus} onChange={e => setFilterStatus(e.target.value)}>
              <option value="">All Status</option>
              <option value="Active">Active</option>
              <option value="Inactive">Inactive</option>
            </select>
          </div>
        </div>

        {/* Count + Clear + Export */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ fontWeight: 600, fontSize: 13, color: '#374151' }}>
            {filtered.length} employee{filtered.length !== 1 ? 's' : ''}
          </span>
          {hasFilters && (
            <button className="emp-filter-clear" onClick={clearFilters}>
              <i className="fa-solid fa-xmark" /> Clear filters
            </button>
          )}
          <div style={{ marginLeft: 'auto' }}>
            <button
              className="btn-export"
              onClick={() => exportCsv(filtered, picklistVals as any)}
              title="Download employee list as CSV"
            >
              <i className="fa-solid fa-file-excel" />
              <span className="btn-export-inner">
                <span className="btn-export-main">Export Employees</span>
                <span className="btn-export-sub">{filtered.length} record{filtered.length !== 1 ? 's' : ''}</span>
              </span>
              <i className="fa-solid fa-download btn-export-dl" />
            </button>
          </div>
        </div>
      </div>

      {/* ── Employee Table ───────────────────────────────────────────────── */}
      <div className="table-wrapper">
        <table className="emp-table">
          <thead>
            <tr>
              <th className="emp-th-num">#</th>
              <th>Employee</th>
              <th>Designation</th>
              <th>Department</th>
              <th>Manager</th>
              <th>Role</th>
              <th>Status</th>
              <th>Action</th>
            </tr>
          </thead>
          <tbody>
            {empLoading ? (
              <tr>
                <td colSpan={8} style={{ textAlign: 'center', padding: '40px 20px', color: '#6B7280' }}>
                  <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 24, display: 'block', marginBottom: 8 }} />
                  Loading employees…
                </td>
              </tr>
            ) : filtered.length === 0 ? (
              <tr>
                <td colSpan={8} style={{ textAlign: 'center', padding: '40px 20px', color: '#9CA3AF' }}>
                  <i className="fa-solid fa-users" style={{ fontSize: 28, display: 'block', marginBottom: 8 }} />
                  {hasFilters ? 'No employees match the current filters.' : 'No employees yet. Add employees from "Add New Employee".'}
                </td>
              </tr>
            ) : (
              filtered.map((emp, idx) => {
                const status = (emp.status as string | undefined) || 'Active';
                const sc = STATUS_COLORS[status] ?? { bg: '#F3F4F6', color: '#374151' };
                return (
                  <tr key={emp.employeeId}>
                    <td className="emp-th-num" style={{ color: '#9CA3AF', fontSize: 12 }}>{idx + 1}</td>
                    <td>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                        <img
                          src={getAvatar(emp)} alt={emp.name}
                          style={{ width: 34, height: 34, borderRadius: '50%', flexShrink: 0 }}
                        />
                        <div>
                          <div style={{ fontWeight: 600, fontSize: 13.5, color: '#111827' }}>{emp.name}</div>
                          <div style={{ fontSize: 11.5, color: '#9CA3AF' }}>{emp.employeeId}</div>
                        </div>
                      </div>
                    </td>
                    <td style={{ fontSize: 13 }}>{resolveLabel('DESIGNATION', emp.designation)}</td>
                    <td style={{ fontSize: 13 }}>{resolveDept(emp.deptId ?? undefined)}</td>
                    <td style={{ fontSize: 13 }}>{resolveManager(emp.managerId ?? undefined)}</td>
                    <td style={{ fontSize: 13 }}>
                      {emp.role === 'Department Manager'
                        ? <span style={{ background: '#F3E8FF', color: '#7C3AED', padding: '2px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600 }}>Dept Manager</span>
                        : emp.role === 'Manager'
                        ? <span style={{ background: '#DBEAFE', color: '#1D4ED8', padding: '2px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600 }}>Manager</span>
                        : <span style={{ background: '#F3F4F6', color: '#374151', padding: '2px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600 }}>Employee</span>}
                    </td>
                    <td>
                      <span style={{
                        background: sc.bg, color: sc.color,
                        borderRadius: 6, padding: '3px 10px',
                        fontSize: 11.5, fontWeight: 600,
                      }}>{status}</span>
                    </td>
                    <td>
                      <div className="emp-action-btns" style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                        <button
                          className="btn-edit" title="Edit employee"
                          onClick={() => setEditingEmpId(emp.employeeId)}
                        >
                          <i className="fa-solid fa-pen-to-square" />
                        </button>
                        {/* Resend Invite — Active employees only; RPC validates no-auth-account server-side */}
                        {(emp.status === 'Active' || !emp.status) && (
                          <button
                            className="btn-edit"
                            title="Resend invite email"
                            disabled={resendingIds.has(emp.id as string)}
                            onClick={() => handleResendInvite(emp)}
                            style={{ color: '#6366F1' }}
                          >
                            {resendingIds.has(emp.id as string)
                              ? <i className="fa-solid fa-spinner fa-spin" />
                              : <i className="fa-solid fa-paper-plane" />}
                          </button>
                        )}
                        {can('employment.history') && (
                          <button
                            className="btn-edit"
                            title="Employment history"
                            style={{ background: histEmployeeId === emp.id ? '#EEF2FF' : undefined, color: histEmployeeId === emp.id ? '#4F46E5' : undefined }}
                            onClick={() => {
                              if (histEmployeeId === emp.id) { setHistEmployeeId(null); setHistRows([]); }
                              else openEmploymentHistory(emp.id as string);
                            }}
                          >
                            <i className="fa-solid fa-clock-rotate-left" />
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* ── Employment History Panel ─────────────────────────────────── */}
      {histEmployeeId && (
        <div style={{
          marginTop: 20, background: '#fff', border: '1px solid #E5E7EB',
          borderRadius: 12, padding: '20px 24px',
          boxShadow: '0 2px 8px rgba(0,0,0,0.06)',
        }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
            <h3 style={{ margin: 0, fontSize: 15, fontWeight: 700, color: '#111827' }}>
              <i className="fa-solid fa-clock-rotate-left" style={{ marginRight: 8, color: '#4F46E5' }} />
              Employment History — {employees.find(e => e.id === histEmployeeId)?.name ?? histEmployeeId}
            </h3>
            <button
              onClick={() => { setHistEmployeeId(null); setHistRows([]); }}
              style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#6B7280', fontSize: 18 }}
            >
              <i className="fa-solid fa-xmark" />
            </button>
          </div>

          {histLoading ? (
            <p style={{ color: '#6B7280', fontSize: 13 }}>Loading…</p>
          ) : histRows.length === 0 ? (
            <p style={{ color: '#6B7280', fontSize: 13 }}>No history available.</p>
          ) : (
            <div style={{ display: 'flex', gap: 16, alignItems: 'flex-start' }}>
              {/* Timeline selector */}
              <div style={{ minWidth: 180, flexShrink: 0 }}>
                {histRows.map((h, i) => {
                  const from = h.effective_from as string;
                  const to   = h.effective_to as string;
                  const isCurrent = to === '9999-12-31';
                  return (
                    <button
                      key={h.id as string}
                      onClick={() => setHistSelIdx(i)}
                      style={{
                        display: 'block', width: '100%', textAlign: 'left',
                        padding: '6px 12px', marginBottom: 4, borderRadius: 8, cursor: 'pointer',
                        background: histSelIdx === i ? '#EEF2FF' : '#F9FAFB',
                        border: `1px solid ${histSelIdx === i ? '#A5B4FC' : '#E5E7EB'}`,
                        color: histSelIdx === i ? '#4F46E5' : '#374151',
                        fontSize: 12, fontWeight: histSelIdx === i ? 600 : 400,
                      }}
                    >
                      {from}
                      <span style={{ display: 'block', color: histSelIdx === i ? '#818CF8' : '#9CA3AF', fontSize: 11 }}>
                        → {isCurrent ? 'Present' : to}
                      </span>
                    </button>
                  );
                })}
              </div>
              {/* Detail card */}
              {(() => {
                const h = histRows[histSelIdx];
                if (!h) return null;
                const fields: [string, string][] = [
                  ['Designation',     resolvePicklistHist('DESIGNATION', h.designation)],
                  ['Job Title',       String(h.job_title ?? '—')],
                  ['Department',      resolveDeptHist(h.dept_id)],
                  ['Reports To',      resolveManagerHist(h.manager_id)],
                  ['Hire Date',       fmtDateHist(h.hire_date)],
                  ['End Date',        fmtDateHist(h.end_date)],
                  ['Work Country',    resolvePicklistHist('ID_COUNTRY', h.work_country)],
                  ['Work Location',   resolvePicklistHist('LOCATION', h.work_location)],
                  ['Base Currency',   currencies.find(c => c.id === h.base_currency_id)?.name ?? '—'],
                  ['Status',          String(h.status ?? '—')],
                ];
                return (
                  <div style={{
                    display: 'grid', gridTemplateColumns: '1fr 1fr',
                    gap: '10px 24px', flex: 1,
                  }}>
                    {fields.map(([label, value]) => (
                      <div key={label}>
                        <div style={{ fontSize: 11, color: '#9CA3AF', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.04em' }}>{label}</div>
                        <div style={{ fontSize: 13.5, color: '#111827', marginTop: 2 }}>{value || '—'}</div>
                      </div>
                    ))}
                  </div>
                );
              })()}
            </div>
          )}
        </div>
      )}

      {/* ── Resend invite result modal ─────────────────────────────────────── */}
      {resendModal && (
        <div className="modal-overlay" onClick={() => setResendModal(null)}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className={`fa-solid ${resendModal.ok ? 'fa-circle-check' : 'fa-triangle-exclamation'} modal-icon`}
                style={{ color: resendModal.ok ? '#16A34A' : '#D97706' }} />
              <h3>{resendModal.ok ? 'Invite Sent' : 'Could Not Send Invite'}</h3>
            </div>
            <div className="modal-body">{resendModal.text}</div>
            <div className="modal-actions">
              <button className="emp-btn-primary" onClick={() => setResendModal(null)}>OK</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
