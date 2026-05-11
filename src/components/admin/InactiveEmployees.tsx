/**
 * InactiveEmployees
 *
 * Displays employees with status = 'Inactive'.
 * Mirrors the EmployeeDetails screen layout — same table, filters, and edit panel.
 *
 * Access control (two layers):
 *   1. Route-level  — ProtectedRoute requiredPermission="inactive_employees.view"
 *                     blocks the page entirely if the user has no permission.
 *   2. Population   — useTargetPopulation({ module: 'inactive_employees', action: 'view' })
 *                     scopes which inactive employees the user can see:
 *                       mode=all    → all inactive employees
 *                       mode=scoped → only the specific UUIDs in target group
 *                       mode=none   → permission exists but group is empty
 *
 * Edit:    opens EmployeeEditPanel (same as EmployeeDetails).
 *          Status change (reactivate) is gated separately by inactive_employees.edit.
 */

import { useState, useMemo } from 'react';
import { useEmployees, type Employee }  from '../../hooks/useEmployees';
import { useTargetPopulation }          from '../../hooks/useTargetPopulation';
import { usePermissions }               from '../../hooks/usePermissions';
import { usePicklistValues }            from '../../hooks/usePicklistValues';
import { useDepartments }               from '../../hooks/useDepartments';
import ErrorBanner                      from '../shared/ErrorBanner';
import EmployeeEditPanel                from './EmployeeEditPanel';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function fmtDate(val?: string | null): string {
  if (!val) return '—';
  if (val === '9999-12-31') return 'Open-ended';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

function getAvatar(emp: Employee): string {
  if (emp.photo && typeof emp.photo === 'string') return emp.photo;
  const name = emp.name || 'E';
  return `https://ui-avatars.com/api/?name=${encodeURIComponent(name)}&background=DC2626&color=fff&size=40`;
}

function exportCsv(rows: Employee[]) {
  const header = ['#', 'Employee ID', 'Name', 'Designation', 'Department', 'Status', 'Hire Date', 'End Date'];
  const lines = rows.map((e, i) => [
    i + 1,
    e.employeeId,
    e.name,
    e.designation || '',
    e.deptId || '',
    e.status || 'Inactive',
    fmtDate(e.hireDate),
    fmtDate(e.endDate),
  ].map(v => `"${String(v).replace(/"/g, '""')}"`).join(','));

  const csv = [header.join(','), ...lines].join('\n');
  const blob = new Blob([csv], { type: 'text/csv' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href = url;
  a.download = `inactive_employees_${today()}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function InactiveEmployees() {
  const { employees, loading: empLoading, error: empError, refetch } = useEmployees();
  const { picklistValues: picklistVals, error: plError }             = usePicklistValues();
  const { departments, error: deptError }                            = useDepartments();
  const { can }                                                       = usePermissions();

  // ── Target population scoping (UX layer on top of RLS) ────────────────────
  const { result: popResult, loading: popLoading } = useTargetPopulation(
    'inactive_employees',
    'view',
  );

  // ── Edit panel state ──────────────────────────────────────────────────────
  const [editingEmpId, setEditingEmpId] = useState<string | null>(null);

  // ── Filters ───────────────────────────────────────────────────────────────
  const [filterName,  setFilterName]  = useState('');
  const [filterEmpId, setFilterEmpId] = useState('');
  const [filterDept,  setFilterDept]  = useState('');

  // ── Derive inactive employees, scoped by target population ────────────────
  const inactiveEmployees = useMemo(() => {
    // Start with all Inactive employees (RLS already gates this)
    const inactive = employees.filter(e => e.status === 'Inactive');

    // Apply UX-layer population scope
    if (popResult.mode === 'all')    return inactive;
    if (popResult.mode === 'scoped') {
      const allowed = new Set(popResult.ids);
      return inactive.filter(e => allowed.has(e.id));
    }
    // mode=none — no access (shouldn't reach here if ProtectedRoute is correct,
    // but return empty as a safe fallback)
    return [];
  }, [employees, popResult]);

  // ── Filtered rows ─────────────────────────────────────────────────────────
  const filtered = useMemo(() => {
    const nm  = filterName.toLowerCase();
    const eid = filterEmpId.toLowerCase();
    return inactiveEmployees.filter(e => {
      if (nm  && !e.name.toLowerCase().includes(nm))         return false;
      if (eid && !e.employeeId.toLowerCase().includes(eid))  return false;
      if (filterDept && String(e.deptId || '') !== filterDept) return false;
      return true;
    });
  }, [inactiveEmployees, filterName, filterEmpId, filterDept]);

  const hasFilters = !!(filterName || filterEmpId || filterDept);

  function clearFilters() {
    setFilterName(''); setFilterEmpId(''); setFilterDept('');
  }

  // ── Label resolvers ───────────────────────────────────────────────────────
  function resolveLabel(picklistId: string, val?: unknown): string {
    if (!val) return '—';
    const match = picklistVals.find(
      p => p.picklistId === picklistId &&
        (String(p.id) === String(val) || p.refId === String(val) || p.value === String(val))
    );
    return match ? match.value : String(val);
  }

  function resolveDept(deptId?: string | null): string {
    if (!deptId) return '—';
    const d = departments.find(d => d.id === deptId || d.deptId === deptId);
    return d ? d.name : deptId;
  }

  function resolveManager(managerId?: string | null): string {
    if (!managerId) return '—';
    const m = employees.find(e => e.id === managerId || e.employeeId === managerId);
    return m ? m.name : managerId;
  }

  // ── Edit panel ────────────────────────────────────────────────────────────
  if (editingEmpId) {
    const editingEmp = employees.find(e => e.employeeId === editingEmpId);
    if (editingEmp) {
      return (
        <EmployeeEditPanel
          emp={editingEmp as any}
          onClose={() => setEditingEmpId(null)}
          onSaved={() => { refetch(); setEditingEmpId(null); }}
        />
      );
    }
  }

  // ── Error states ──────────────────────────────────────────────────────────
  if (empError)  return <ErrorBanner message={empError}  onRetry={refetch} />;
  if (plError)   return <ErrorBanner message={plError} />;
  if (deptError) return <ErrorBanner message={deptError} />;

  const isLoading = empLoading || popLoading;

  // ── Empty group notice (permission exists but target group has 0 members) ──
  const isEmptyGroup = popResult.mode === 'none' && popResult.reason === 'empty_group';

  const canEdit = can('inactive_employees.edit');

  return (
    <div className="page-content" style={{ padding: '28px 32px' }}>

      {/* ── Header ──────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 20 }}>
        <div style={{
          background: '#FEE2E2', borderRadius: 8, width: 36, height: 36,
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        }}>
          <i className="fa-solid fa-user-slash" style={{ color: '#DC2626', fontSize: 15 }} />
        </div>
        <div>
          <h2 className="page-title" style={{ margin: 0 }}>Inactive Employees</h2>
          <p style={{ margin: 0, fontSize: 12.5, color: '#6B7280', marginTop: 2 }}>
            Employees who have been deactivated. Use the Permission Matrix to control who can view and manage this list.
          </p>
        </div>
      </div>

      {/* ── Empty group notice ───────────────────────────────────────────── */}
      {isEmptyGroup && (
        <div style={{
          background: '#FFFBEB', border: '1px solid #FDE68A', borderRadius: 10,
          padding: '12px 16px', marginBottom: 16, display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <i className="fa-solid fa-triangle-exclamation" style={{ color: '#D97706', fontSize: 14 }} />
          <span style={{ fontSize: 13, color: '#92400E' }}>
            Your target group for <strong>inactive_employees.view</strong> has no members assigned yet.
            Ask an admin to add members to your target group in the Permission Matrix.
          </span>
        </div>
      )}

      {/* ── Filter Bar ──────────────────────────────────────────────────── */}
      <div style={{
        background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
        padding: '14px 18px', marginBottom: 18,
      }}>
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
        </div>

        {/* Count + Clear + Export */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ fontWeight: 600, fontSize: 13, color: '#374151' }}>
            {isLoading ? '—' : `${filtered.length} inactive employee${filtered.length !== 1 ? 's' : ''}`}
          </span>
          {hasFilters && (
            <button className="emp-filter-clear" onClick={clearFilters}>
              <i className="fa-solid fa-xmark" /> Clear filters
            </button>
          )}
          <div style={{ marginLeft: 'auto' }}>
            <button
              className="btn-export"
              onClick={() => exportCsv(filtered)}
              title="Download inactive employee list as CSV"
              disabled={filtered.length === 0}
            >
              <i className="fa-solid fa-file-excel" />
              <span className="btn-export-inner">
                <span className="btn-export-main">Export</span>
                <span className="btn-export-sub">{filtered.length} record{filtered.length !== 1 ? 's' : ''}</span>
              </span>
              <i className="fa-solid fa-download btn-export-dl" />
            </button>
          </div>
        </div>
      </div>

      {/* ── Table ───────────────────────────────────────────────────────── */}
      <div className="table-wrapper">
        <table className="emp-table">
          <thead>
            <tr>
              <th className="emp-th-num">#</th>
              <th>Employee</th>
              <th>Designation</th>
              <th>Department</th>
              <th>Manager</th>
              <th>Hire Date</th>
              <th>End Date</th>
              {canEdit && <th>Action</th>}
            </tr>
          </thead>
          <tbody>
            {isLoading ? (
              <tr>
                <td colSpan={canEdit ? 8 : 7} style={{ textAlign: 'center', padding: '40px 20px', color: '#6B7280' }}>
                  <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 24, display: 'block', marginBottom: 8 }} />
                  Loading…
                </td>
              </tr>
            ) : filtered.length === 0 ? (
              <tr>
                <td colSpan={canEdit ? 8 : 7} style={{ textAlign: 'center', padding: '40px 20px', color: '#9CA3AF' }}>
                  <i className="fa-solid fa-user-slash" style={{ fontSize: 28, display: 'block', marginBottom: 8, color: '#D1D5DB' }} />
                  {hasFilters
                    ? 'No inactive employees match the current filters.'
                    : isEmptyGroup
                    ? 'Your target group has no members yet.'
                    : 'No inactive employees in your scope.'}
                </td>
              </tr>
            ) : (
              filtered.map((emp, idx) => (
                <tr key={emp.id}>
                  <td className="emp-th-num" style={{ color: '#9CA3AF', fontSize: 12 }}>{idx + 1}</td>
                  <td>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <img
                        src={getAvatar(emp)} alt={emp.name}
                        style={{ width: 34, height: 34, borderRadius: '50%', flexShrink: 0, opacity: 0.75 }}
                      />
                      <div>
                        <div style={{ fontWeight: 600, fontSize: 13.5, color: '#374151' }}>{emp.name}</div>
                        <div style={{ fontSize: 11.5, color: '#9CA3AF' }}>{emp.employeeId}</div>
                      </div>
                      <span style={{
                        marginLeft: 6, background: '#FEE2E2', color: '#DC2626',
                        borderRadius: 6, padding: '2px 8px', fontSize: 10.5, fontWeight: 600,
                      }}>Inactive</span>
                    </div>
                  </td>
                  <td style={{ fontSize: 13 }}>{resolveLabel('DESIGNATION', emp.designation)}</td>
                  <td style={{ fontSize: 13 }}>{resolveDept(emp.deptId)}</td>
                  <td style={{ fontSize: 13 }}>{resolveManager(emp.managerId)}</td>
                  <td style={{ fontSize: 13, color: '#6B7280' }}>{fmtDate(emp.hireDate)}</td>
                  <td style={{ fontSize: 13, color: emp.endDate ? '#DC2626' : '#9CA3AF' }}>
                    {fmtDate(emp.endDate)}
                  </td>
                  {canEdit && (
                    <td>
                      <div className="emp-action-btns" style={{ display: 'flex', gap: 6 }}>
                        <button
                          className="btn-edit"
                          title="Edit / reactivate employee"
                          onClick={() => setEditingEmpId(emp.employeeId)}
                        >
                          <i className="fa-solid fa-pen-to-square" />
                        </button>
                      </div>
                    </td>
                  )}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
