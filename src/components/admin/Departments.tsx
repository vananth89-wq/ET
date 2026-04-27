import { useState, useMemo, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import { useDepartments } from '../../hooks/useDepartments';
import { useEmployees } from '../../hooks/useEmployees';
import ConfirmationModal from '../shared/ConfirmationModal';

// ─────────────────────────────────────────────────────────────────────────────
// Re-exports and shared types (used by OrgChart, EmployeeDetails, etc.)
// ─────────────────────────────────────────────────────────────────────────────

export type { Department } from '../../hooks/useDepartments';

// Generic employee shape used as a bridge type in OrgChart / EmployeeDetails
export interface Employee {
  employeeId: string;
  name: string;
  role?: string;
  departmentId?: string;
  managerId?: string;
  photo?: string;
  [key: string]: unknown;
}

type DeptStatus = 'Active' | 'Upcoming' | 'Expired';

export function getDeptStatus(
  dept: { startDate?: string | null; endDate?: string | null },
  viewDate: string,
): DeptStatus {
  if (!dept.startDate || !dept.endDate) return 'Active';
  if (viewDate < dept.startDate) return 'Upcoming';
  if (viewDate > dept.endDate)   return 'Expired';
  return 'Active';
}

export function fmtDate(val: string | null | undefined): string {
  if (!val) return '—';
  if (val === '9999-12-31') return 'Open-ended';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

const AVATAR_COLORS = [
  '#2F77B5','#4CAF50','#E91E63','#FF9800','#9C27B0',
  '#00BCD4','#795548','#607D8B','#3F51B5','#009688',
];
export function getAvatarColor(name: string): string {
  let h = 0;
  for (const c of (name || 'A')) h = (h * 31 + c.charCodeAt(0)) | 0;
  return AVATAR_COLORS[Math.abs(h) % AVATAR_COLORS.length];
}

function generateDeptId(usedIds: string[]): string {
  const maxNum = usedIds.reduce((max, id) => {
    const m = id.match(/^DEPT(\d+)$/);
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return 'DEPT' + String(maxNum + 1).padStart(3, '0');
}

// ─────────────────────────────────────────────────────────────────────────────
// Component
// ─────────────────────────────────────────────────────────────────────────────

export default function Departments() {
  const { departments, loading, error, refetch } = useDepartments(false);
  const { employees } = useEmployees();

  const today = new Date().toISOString().split('T')[0];
  const [viewDate, setViewDate] = useState(today);

  // ── Form state ──────────────────────────────────────────────────────────────
  const [showForm,         setShowForm]         = useState(false);
  const [editId,           setEditId]           = useState<string | null>(null); // UUID
  const [formName,         setFormName]         = useState('');
  const [formDeptId,       setFormDeptId]       = useState('');
  const [formHeadId,       setFormHeadId]       = useState('');       // employee UUID
  const [formParentDeptId, setFormParentDeptId] = useState('');       // dept UUID
  const [formStartDate,    setFormStartDate]    = useState(today);
  const [formEndDate,      setFormEndDate]      = useState('9999-12-31');
  const [saving,           setSaving]           = useState(false);

  // ── Filter state ────────────────────────────────────────────────────────────
  const [filterName,   setFilterName]   = useState('');
  const [filterDeptId, setFilterDeptId] = useState('');
  const [filterHead,   setFilterHead]   = useState('');   // employee UUID
  const [filterParent, setFilterParent] = useState('');   // dept UUID
  const [filterStatus, setFilterStatus] = useState('');

  // ── Form validation errors ──────────────────────────────────────────────────
  const [formErrors, setFormErrors] = useState<{
    name?: string; startDate?: string; general?: string;
  }>({});

  // ── Clone source (for banner) ───────────────────────────────────────────────
  const [cloneSource, setCloneSource] = useState<string | null>(null);

  // ── Delete modal ────────────────────────────────────────────────────────────
  const [deleteModal, setDeleteModal] = useState<{ isOpen: boolean; deptId: string | null; deptName: string }>({
    isOpen: false, deptId: null, deptName: '',
  });

  const nameRef = useRef<HTMLInputElement>(null);

  // ── Form handlers ───────────────────────────────────────────────────────────

  function openAddForm() {
    setEditId(null);
    setFormName('');
    setFormDeptId(generateDeptId(departments.map(d => d.deptId)));
    setFormHeadId('');
    setFormParentDeptId('');
    setFormStartDate(today);
    setFormEndDate('9999-12-31');
    setFormErrors({});
    setCloneSource(null);
    setShowForm(true);
    setTimeout(() => nameRef.current?.focus(), 50);
  }

  function openEditForm(dept: ReturnType<typeof useDepartments>['departments'][number]) {
    setEditId(dept.id);
    setFormName(dept.name);
    setFormDeptId(dept.deptId);
    setFormHeadId(dept.headEmployeeId || '');
    // dept.parentDeptId is stored as a text code (e.g. "DEPT001") by mapDepartment,
    // but the dropdown options use d.id (UUID). Translate text code → UUID here.
    setFormParentDeptId(
      dept.parentDeptId
        ? (departments.find(d => d.deptId === dept.parentDeptId)?.id || '')
        : ''
    );
    setFormStartDate(dept.startDate || today);
    setFormEndDate(dept.endDate || '9999-12-31');
    setFormErrors({});
    setCloneSource(null);
    setShowForm(true);
    setTimeout(() => nameRef.current?.focus(), 50);
  }

  function openCloneForm(dept: ReturnType<typeof useDepartments>['departments'][number]) {
    setEditId(null);
    setFormName('');
    setFormDeptId(generateDeptId(departments.map(d => d.deptId)));
    setFormHeadId(dept.headEmployeeId || '');
    // Same translation as openEditForm — text code → UUID for the dropdown
    setFormParentDeptId(
      dept.parentDeptId
        ? (departments.find(d => d.deptId === dept.parentDeptId)?.id || '')
        : ''
    );
    setFormStartDate(dept.startDate || today);
    setFormEndDate(dept.endDate || '9999-12-31');
    setFormErrors({});
    setCloneSource(dept.name);
    setShowForm(true);
    setTimeout(() => nameRef.current?.focus(), 50);
  }

  function resetForm() {
    setShowForm(false);
    setEditId(null);
    setFormErrors({});
    setCloneSource(null);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const name = formName.trim();
    const errors: typeof formErrors = {};

    if (!name) errors.name = 'Department name is required.';
    if (!formStartDate) errors.startDate = 'Start date is required.';

    if (Object.keys(errors).length > 0) {
      setFormErrors(errors);
      nameRef.current?.focus();
      return;
    }

    const todayStr = new Date().toISOString().slice(0, 10);
    // Yesterday string — used to close an outgoing dept head record without
    // overlapping the new head's from_date (both use today).
    const yesterdayStr = (() => {
      const d = new Date();
      d.setDate(d.getDate() - 1);
      return d.toISOString().slice(0, 10);
    })();

    if (editId !== null) {
      // ── Edit existing ──────────────────────────────────────────────────────
      const editing = departments.find(d => d.id === editId);
      if (!editing) return;

      if (formParentDeptId && editing.id === formParentDeptId) {
        setFormErrors({ general: 'A department cannot be its own parent.' });
        return;
      }

      setSaving(true);
      const { error: dbErr } = await supabase
        .from('departments')
        .update({
          name,
          head_employee_id: formHeadId        || null,
          parent_dept_id:   formParentDeptId  || null,
          start_date:       formStartDate      || null,
          end_date:         formEndDate        || null,
        } as Record<string, unknown>)
        .eq('id', editId);

      if (dbErr) {
        setSaving(false);
        setFormErrors({ general: dbErr.message });
        return;
      }

      // ── Sync department_heads ─────────────────────────────────────────────
      const oldHeadId = editing.headEmployeeId || null;
      const newHeadId = formHeadId || null;

      if (oldHeadId !== newHeadId) {
        // Head changed — close the outgoing record and open a new one

        if (oldHeadId) {
          const { error: closeErr } = await supabase
            .from('department_heads')
            .update({ to_date: yesterdayStr })
            .eq('department_id', editId)
            .eq('employee_id', oldHeadId)
            .is('to_date', null);
          if (closeErr) console.error('[dept_heads] close old head:', closeErr.message);
        }

        if (newHeadId) {
          const { error: insertErr } = await supabase
            .from('department_heads')
            .insert({
              department_id: editId,
              employee_id:   newHeadId,
              from_date:     todayStr,
              to_date:       null,
            });
          if (insertErr) console.error('[dept_heads] insert new head:', insertErr.message);
        }

      } else if (newHeadId) {
        // Head unchanged — but backfill if no active row exists yet
        // (covers all existing departments that were saved before this fix was in place)
        const { data: existing, error: checkErr } = await supabase
          .from('department_heads')
          .select('id')
          .eq('department_id', editId)
          .eq('employee_id', newHeadId)
          .is('to_date', null)
          .maybeSingle();

        if (checkErr) {
          console.error('[dept_heads] check existing:', checkErr.message);
        } else if (!existing) {
          const { error: backfillErr } = await supabase
            .from('department_heads')
            .insert({
              department_id: editId,
              employee_id:   newHeadId,
              from_date:     editing.startDate || todayStr,
              to_date:       null,
            });
          if (backfillErr) console.error('[dept_heads] backfill:', backfillErr.message);
        }
      }

      setSaving(false);
    } else {
      // ── Add new ────────────────────────────────────────────────────────────
      if (departments.some(d => d.name.toLowerCase() === name.toLowerCase())) {
        setFormErrors({ name: 'A department with this name already exists.' });
        return;
      }

      setSaving(true);
      // Insert the department row (no chained .select — departments TS schema is outdated
      // and chaining breaks type inference; we get the new UUID via a follow-up lookup).
      const { error: dbErr } = await supabase
        .from('departments')
        .insert({
          dept_id:          formDeptId,
          name,
          head_employee_id: formHeadId        || null,
          parent_dept_id:   formParentDeptId  || null,
          start_date:       formStartDate      || null,
          end_date:         formEndDate        || null,
        } as Record<string, unknown>);

      if (dbErr) {
        setSaving(false);
        setFormErrors({ general: dbErr.message });
        return;
      }

      // Fetch the UUID of the newly inserted department by its unique dept_id code
      if (formHeadId) {
        const { data: newDeptRow, error: fetchErr } = await supabase
          .from('departments')
          .select('id')
          .eq('dept_id', formDeptId)
          .single();

        if (fetchErr) {
          console.error('[dept_heads] fetch new dept id:', fetchErr.message);
        } else if (newDeptRow?.id) {
          const { error: insertErr } = await supabase
            .from('department_heads')
            .insert({
              department_id: newDeptRow.id,
              employee_id:   formHeadId,
              from_date:     formStartDate || todayStr,
              to_date:       null,
            });
          if (insertErr) console.error('[dept_heads] insert for new dept:', insertErr.message);
        }
      }

      setSaving(false);
    }

    refetch();
    setFormErrors({});
    resetForm();
  }

  // ── Delete ──────────────────────────────────────────────────────────────────

  function requestDelete(dept: ReturnType<typeof useDepartments>['departments'][number]) {
    setDeleteModal({ isOpen: true, deptId: dept.id, deptName: dept.name });
  }

  async function confirmDelete() {
    const { deptId } = deleteModal;
    setDeleteModal({ isOpen: false, deptId: null, deptName: '' });
    if (!deptId) return;

    const { error: dbErr } = await supabase
      .from('departments')
      .update({ deleted_at: new Date().toISOString() } as Record<string, unknown>)
      .eq('id', deptId);

    if (dbErr) {
      setFormErrors({ general: `Delete failed: ${dbErr.message}` });
      return;
    }
    refetch();
  }

  // ── Derived data ────────────────────────────────────────────────────────────

  const sortedEmployees = useMemo(() =>
    [...employees].sort((a, b) => (a.name as string).localeCompare(b.name as string)),
    [employees],
  );

  // Employees who are currently heads of any department
  const deptHeadOptions = useMemo(() => {
    const headIds = new Set(departments.map(d => d.headEmployeeId).filter(Boolean));
    return sortedEmployees.filter(e => headIds.has(e.id));
  }, [departments, sortedEmployees]);

  const sortedParentOptions = useMemo(() =>
    [...departments].sort((a, b) => a.name.localeCompare(b.name)),
    [departments],
  );

  const filteredDepts = useMemo(() => {
    const nameQ   = filterName.trim().toLowerCase();
    const deptIdQ = filterDeptId.trim().toLowerCase();
    let list = departments.filter(d => {
      if (nameQ        && !d.name.toLowerCase().includes(nameQ))      return false;
      if (deptIdQ      && !d.deptId.toLowerCase().includes(deptIdQ))  return false;
      if (filterHead   && d.headEmployeeId !== filterHead)             return false;
      // filterParent is a UUID (from dropdown); d.parentDeptId is a text code — resolve to UUID
      if (filterParent) {
        const parentUUID = d.parentDeptId
          ? (departments.find(p => p.deptId === d.parentDeptId)?.id || d.parentDeptId)
          : '';
        if (parentUUID !== filterParent) return false;
      }
      if (filterStatus && getDeptStatus(d, viewDate) !== filterStatus) return false;
      return true;
    });
    const order: Record<DeptStatus, number> = { Active: 0, Upcoming: 1, Expired: 2 };
    list.sort((a, b) => order[getDeptStatus(a, viewDate)] - order[getDeptStatus(b, viewDate)]);
    return list;
  }, [departments, filterName, filterDeptId, filterHead, filterParent, filterStatus, viewDate]);

  const hasFilter = !!(filterName || filterDeptId || filterHead || filterParent || filterStatus);

  function statusBadgeClass(s: DeptStatus) {
    return s === 'Active' ? 'badge badge-active' : s === 'Upcoming' ? 'badge badge-upcoming' : 'badge badge-closed';
  }

  // ── Render ──────────────────────────────────────────────────────────────────

  if (loading) {
    return (
      <div className="ar-panel" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: 200 }}>
        <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 22, color: '#6B7280' }} />
        <span style={{ marginLeft: 10, color: '#6B7280' }}>Loading departments…</span>
      </div>
    );
  }

  if (error) {
    return (
      <div className="ar-panel">
        <div style={{ background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 8, padding: '14px 18px', color: '#B91C1C', fontSize: 13 }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 8 }} />
          {error}
        </div>
      </div>
    );
  }

  return (
    <div className="ar-panel">

      {/* Title */}
      <h2 className="page-title">Department Management</h2>
      <p className="page-subtitle" style={{ marginBottom: 16 }}>
        Create and manage departments, assign heads, and define reporting hierarchies.
      </p>

      {/* View as of date bar */}
      <div className="dept-date-bar" style={{ marginBottom: 20 }}>
        <i className="fa-regular fa-calendar" />
        <label>View as of</label>
        <input
          type="date"
          value={viewDate}
          onChange={e => setViewDate(e.target.value || today)}
        />
        {viewDate === today && <span className="dept-date-hint">(Today)</span>}
      </div>

      {/* Add button */}
      {!showForm && (
        <div style={{ marginBottom: 16 }}>
          <button className="btn-add" onClick={openAddForm}>
            <i className="fa-solid fa-plus" /> Add Department
          </button>
        </div>
      )}

      {/* Form card */}
      {showForm && (
        <div className="rd-form-card" style={{ marginBottom: 24, padding: '20px 24px' }}>
          <form onSubmit={handleSubmit} noValidate>

            {/* Clone source banner */}
            {cloneSource && (
              <div style={{
                background: '#EFF6FF', border: '1px solid #BFDBFE', borderRadius: 7,
                padding: '9px 14px', marginBottom: 16, fontSize: 13, color: '#1D4ED8',
                display: 'flex', alignItems: 'center', gap: 8,
              }}>
                <i className="fa-solid fa-copy" style={{ fontSize: 12 }} />
                Cloning from <strong style={{ marginLeft: 3 }}>{cloneSource}</strong>
                <span style={{ color: '#60A5FA', marginLeft: 4 }}>— enter a new department name to continue.</span>
              </div>
            )}

            {/* General error banner */}
            {formErrors.general && (
              <div style={{
                background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 7,
                padding: '10px 14px', marginBottom: 16, fontSize: 13, color: '#B91C1C',
                display: 'flex', alignItems: 'center', gap: 8,
              }}>
                <i className="fa-solid fa-circle-exclamation" />
                {formErrors.general}
              </div>
            )}

            {/* ── Row 1: Name | ID | Head ───────────────────────────────── */}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 130px 1fr', gap: 16, marginBottom: 16 }}>
              {/* Name */}
              <div className={`form-group${formErrors.name ? ' form-group--error' : ''}`}>
                <label>Department Name</label>
                <input
                  ref={nameRef}
                  type="text"
                  placeholder="e.g. Engineering"
                  value={formName}
                  onChange={e => { setFormName(e.target.value); setFormErrors(p => ({ ...p, name: undefined })); }}
                  required
                />
                {formErrors.name && (
                  <span style={{ fontSize: 12, color: '#DC2626', marginTop: 4, display: 'block' }}>
                    <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 4 }} />
                    {formErrors.name}
                  </span>
                )}
              </div>
              {/* Dept ID */}
              <div className="form-group">
                <label>Department ID</label>
                <input
                  type="text"
                  value={formDeptId}
                  readOnly
                  style={{ background: '#F3F4F6', color: '#6B7280', cursor: 'default' }}
                  title="Auto-generated"
                />
              </div>
              {/* Head */}
              <div className="form-group">
                <label>Department Head</label>
                <select value={formHeadId} onChange={e => setFormHeadId(e.target.value)}>
                  <option value="">— Select Employee —</option>
                  {sortedEmployees.map(e => (
                    <option key={e.id} value={e.id}>
                      {e.name as string} ({e.employeeId as string})
                    </option>
                  ))}
                </select>
              </div>
            </div>

            {/* ── Row 2: Parent | Start Date | End Date ─────────────────── */}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 16 }}>
              {/* Parent */}
              <div className="form-group">
                <label>Parent Department</label>
                <select value={formParentDeptId} onChange={e => setFormParentDeptId(e.target.value)}>
                  <option value="">None (Top Level)</option>
                  {sortedParentOptions
                    .filter(d => editId === null || d.id !== editId)
                    .map(d => (
                      <option key={d.id} value={d.id}>
                        {d.name} ({d.deptId})
                      </option>
                    ))}
                </select>
              </div>
              {/* Start date */}
              <div className={`form-group${formErrors.startDate ? ' form-group--error' : ''}`}>
                <label>Start Date</label>
                <input
                  type="date"
                  value={formStartDate}
                  onChange={e => { setFormStartDate(e.target.value); setFormErrors(p => ({ ...p, startDate: undefined })); }}
                  required
                  style={{ cursor: 'pointer' }}
                />
                {formErrors.startDate && (
                  <span style={{ fontSize: 12, color: '#DC2626', marginTop: 4, display: 'block' }}>
                    <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 4 }} />
                    {formErrors.startDate}
                  </span>
                )}
              </div>
              {/* End date */}
              <div className="form-group">
                <label>End Date</label>
                <input
                  type="date"
                  value={formEndDate}
                  onChange={e => setFormEndDate(e.target.value || '9999-12-31')}
                  required
                  style={{ cursor: 'pointer' }}
                />
              </div>
            </div>

            {/* ── Row 3: Actions ────────────────────────────────────────── */}
            <div className="rd-form-actions" style={{ marginTop: 20, gap: 12, alignItems: 'center' }}>
              <button type="submit" className="btn-add" style={{ minWidth: 160 }} disabled={saving}>
                {saving
                  ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                  : <><i className={`fa-solid ${editId !== null ? 'fa-floppy-disk' : 'fa-plus'}`} />
                    {' '}{editId !== null ? 'Update Department' : 'Add Department'}</>
                }
              </button>
              <button
                type="button"
                onClick={resetForm}
                disabled={saving}
                style={{
                  background: 'transparent',
                  color: '#4B5563',
                  border: '1px solid #9CA3AF',
                  padding: '9px 20px',
                  fontFamily: 'inherit',
                  fontSize: 13,
                  fontWeight: 600,
                  borderRadius: 8,
                  cursor: 'pointer',
                  transition: 'all 0.15s',
                  minWidth: 90,
                }}
                onMouseEnter={e => { (e.currentTarget as HTMLButtonElement).style.background = '#F3F4F6'; }}
                onMouseLeave={e => { (e.currentTarget as HTMLButtonElement).style.background = 'transparent'; }}
              >
                Cancel
              </button>
            </div>

          </form>
        </div>
      )}

      {/* Filter bar */}
      <div style={{
        background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
        padding: '12px 16px', marginBottom: 16,
      }}>
        {/* Row 1: filters */}
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center' }}>
          {/* Name search */}
          <div style={{ position: 'relative', flex: '1 1 160px', minWidth: 140 }}>
            <i className="fa-solid fa-magnifying-glass" style={{
              position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
              color: '#9CA3AF', fontSize: 13, pointerEvents: 'none',
            }} />
            <input
              type="text"
              placeholder="Search name…"
              value={filterName}
              onChange={e => setFilterName(e.target.value)}
              style={{
                width: '100%', boxSizing: 'border-box',
                padding: '7px 10px 7px 30px',
                border: '1px solid #D1D5DB', borderRadius: 7, fontSize: 13,
              }}
            />
          </div>
          {/* Dept ID search */}
          <div style={{ position: 'relative', flex: '0 1 140px', minWidth: 120 }}>
            <i className="fa-solid fa-hashtag" style={{
              position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
              color: '#9CA3AF', fontSize: 13, pointerEvents: 'none',
            }} />
            <input
              type="text"
              placeholder="Dept ID"
              value={filterDeptId}
              onChange={e => setFilterDeptId(e.target.value.toUpperCase())}
              style={{
                width: '100%', boxSizing: 'border-box',
                padding: '7px 10px 7px 30px',
                border: '1px solid #D1D5DB', borderRadius: 7, fontSize: 13,
              }}
            />
          </div>
          {/* Head filter */}
          <div style={{ position: 'relative', flex: '0 1 170px', minWidth: 140 }}>
            <i className="fa-solid fa-user" style={{
              position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
              color: '#9CA3AF', fontSize: 12, pointerEvents: 'none', zIndex: 1,
            }} />
            <select
              value={filterHead}
              onChange={e => setFilterHead(e.target.value)}
              style={{
                width: '100%', padding: '7px 10px 7px 30px',
                border: '1px solid #D1D5DB', borderRadius: 7, fontSize: 13,
                background: '#fff', appearance: 'auto',
              }}
            >
              <option value="">All Heads</option>
              {deptHeadOptions.map(e => (
                <option key={e.id} value={e.id}>{e.name as string}</option>
              ))}
            </select>
          </div>
          {/* Parent filter */}
          <div style={{ position: 'relative', flex: '0 1 170px', minWidth: 140 }}>
            <i className="fa-solid fa-sitemap" style={{
              position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
              color: '#9CA3AF', fontSize: 12, pointerEvents: 'none', zIndex: 1,
            }} />
            <select
              value={filterParent}
              onChange={e => setFilterParent(e.target.value)}
              style={{
                width: '100%', padding: '7px 10px 7px 30px',
                border: '1px solid #D1D5DB', borderRadius: 7, fontSize: 13,
                background: '#fff', appearance: 'auto',
              }}
            >
              <option value="">All Parents</option>
              {sortedParentOptions.map(d => (
                <option key={d.id} value={d.id}>{d.name}</option>
              ))}
            </select>
          </div>
          {/* Status filter */}
          <div style={{ position: 'relative', flex: '0 1 140px', minWidth: 120 }}>
            <i className="fa-solid fa-circle-dot" style={{
              position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
              color: '#9CA3AF', fontSize: 12, pointerEvents: 'none', zIndex: 1,
            }} />
            <select
              value={filterStatus}
              onChange={e => setFilterStatus(e.target.value)}
              style={{
                width: '100%', padding: '7px 10px 7px 30px',
                border: '1px solid #D1D5DB', borderRadius: 7, fontSize: 13,
                background: '#fff', appearance: 'auto',
              }}
            >
              <option value="">All Status</option>
              <option value="Active">Active</option>
              <option value="Upcoming">Upcoming</option>
              <option value="Expired">Expired</option>
            </select>
          </div>
          {hasFilter && (
            <button
              onClick={() => { setFilterName(''); setFilterDeptId(''); setFilterHead(''); setFilterParent(''); setFilterStatus(''); }}
              style={{
                padding: '7px 12px', border: '1px solid #D1D5DB', borderRadius: 7,
                fontSize: 13, cursor: 'pointer', background: '#fff',
                display: 'flex', alignItems: 'center', gap: 5, color: '#6B7280',
              }}
            >
              <i className="fa-solid fa-xmark" /> Clear
            </button>
          )}
        </div>
        {/* Row 2: count + export */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 10 }}>
          <span style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>
            {hasFilter
              ? `${filteredDepts.length} of ${departments.length} department${departments.length !== 1 ? 's' : ''}`
              : `${departments.length} department${departments.length !== 1 ? 's' : ''}`}
          </span>
          {departments.length > 0 && (
            <button
              onClick={() => {
                const rows = filteredDepts.map((d, i) => {
                  const head   = employees.find(e => e.id === d.headEmployeeId);
                  const parent = departments.find(p => p.id === d.parentDeptId);
                  return [
                    i + 1, d.deptId, d.name,
                    head   ? (head.name as string)   : '',
                    parent ? parent.name : '',
                    d.startDate ?? '',
                    d.endDate === '9999-12-31' ? 'Open-ended' : (d.endDate ?? ''),
                    getDeptStatus(d, viewDate),
                  ];
                });
                const headers = ['#', 'Dept ID', 'Department', 'Head', 'Parent', 'Start Date', 'End Date', 'Status'];
                const csv = [headers, ...rows]
                  .map(r => r.map(c => `"${String(c ?? '').replace(/"/g, '""')}"`).join(','))
                  .join('\n');
                const blob = new Blob([csv], { type: 'text/csv' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url; a.download = 'departments.csv'; a.click();
                URL.revokeObjectURL(url);
              }}
              style={{
                display: 'flex', alignItems: 'center', gap: 8,
                padding: '7px 14px', borderRadius: 7, border: 'none',
                background: '#16A34A', color: '#fff', fontSize: 13,
                fontWeight: 600, cursor: 'pointer',
              }}
            >
              <i className="fa-solid fa-file-excel" style={{ fontSize: 14 }} />
              <span>
                Export {hasFilter ? filteredDepts.length : departments.length} Department{(hasFilter ? filteredDepts.length : departments.length) !== 1 ? 's' : ''}
                <span style={{ display: 'block', fontSize: 11, fontWeight: 400, opacity: 0.85 }}>
                  {hasFilter ? 'filtered records' : 'all records'} · Excel
                </span>
              </span>
              <i className="fa-solid fa-download" style={{ fontSize: 12 }} />
            </button>
          )}
        </div>
      </div>

      {/* Table */}
      <div className="er-table-wrap" style={{ overflow: 'hidden', maxWidth: '100%' }}>
        <div style={{ overflowY: 'auto', maxHeight: 'calc(100vh - 380px)' }}>
          <table className="er-table">
            <thead style={{ position: 'sticky', top: 0, zIndex: 5 }}>
              <tr>
                <th style={{ width: 40 }}>#</th>
                <th>Department</th>
                <th>Head</th>
                <th>Parent</th>
                <th>Start Date</th>
                <th>End Date</th>
                <th>Status</th>
                <th style={{ textAlign: 'right' }}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {departments.length === 0 ? (
                <tr>
                  <td colSpan={8} className="er-empty-state">
                    <div className="er-empty-icon"><i className="fa-solid fa-sitemap" /></div>
                    <p className="er-empty-msg">No departments added yet.<br />Click "Add Department" to create your first one.</p>
                  </td>
                </tr>
              ) : filteredDepts.length === 0 ? (
                <tr>
                  <td colSpan={8} style={{ textAlign: 'center', padding: '24px 16px', color: '#6B7280', fontSize: 13 }}>
                    No departments match the current filters.
                  </td>
                </tr>
              ) : filteredDepts.map((dept, i) => {
                const headEmp    = employees.find(e => e.id === dept.headEmployeeId);
                const headName   = headEmp ? (headEmp.name as string) : dept.headEmployeeId ? dept.headEmployeeId : '—';
                const parentDept = departments.find(d => d.id === dept.parentDeptId);
                const parentName = parentDept ? parentDept.name : dept.parentDeptId ? dept.parentDeptId : '—';
                const status      = getDeptStatus(dept, viewDate);
                const avatarColor = getAvatarColor(dept.name);
                const initial     = (dept.name || '?').charAt(0).toUpperCase();
                return (
                  <tr key={dept.id}>
                    <td style={{ color: '#9CA3AF', fontSize: 12 }}>{i + 1}</td>
                    <td>
                      <div className="emp-name-cell">
                        <div className="emp-avatar-sm" style={{ background: avatarColor }}>{initial}</div>
                        <div className="emp-name-info">
                          <span className="emp-name-primary">{dept.name}</span>
                          <span className="emp-name-id">{dept.deptId}</span>
                        </div>
                      </div>
                    </td>
                    <td style={{ fontSize: 13 }}>{headName}</td>
                    <td style={{ fontSize: 13 }}>{parentName}</td>
                    <td style={{ fontSize: 13 }}>{fmtDate(dept.startDate)}</td>
                    <td style={{ fontSize: 13 }}>{fmtDate(dept.endDate)}</td>
                    <td><span className={statusBadgeClass(status)}>{status}</span></td>
                    <td style={{ textAlign: 'right' }}>
                      <div className="emp-action-btns">
                        <button className="btn-edit" title="Edit" onClick={() => openEditForm(dept)}>
                          <i className="fa-solid fa-pen-to-square" />
                        </button>
                        <button
                          className="btn-edit"
                          title={`Clone "${dept.name}"`}
                          onClick={() => openCloneForm(dept)}
                          style={{ color: '#0891B2' }}
                        >
                          <i className="fa-solid fa-copy" />
                        </button>
                        <button className="btn-delete" title="Delete" onClick={() => requestDelete(dept)}>
                          <i className="fa-solid fa-trash" />
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {/* Delete confirmation */}
      <ConfirmationModal
        isOpen={deleteModal.isOpen}
        title="Delete Department"
        message={`Are you sure you want to delete "${deleteModal.deptName}"?`}
        warning="This action cannot be undone and will permanently remove the department."
        confirmText="Delete"
        cancelText="Cancel"
        destructive={true}
        onConfirm={confirmDelete}
        onCancel={() => setDeleteModal({ isOpen: false, deptId: null, deptName: '' })}
      />
    </div>
  );
}
