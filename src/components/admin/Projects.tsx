import { useState, useRef, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import WorkflowGateBanner from '../../workflow/components/WorkflowGateBanner';
import { useProjects } from '../../hooks/useProjects';
import ConfirmationModal from '../shared/ConfirmationModal';
import ErrorBanner from '../shared/ErrorBanner';
import type { Project } from '../../hooks/useProjects';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function getStatus(startDate: string, endDate: string): 'Active' | 'Upcoming' | 'Closed' {
  const today = new Date().toISOString().split('T')[0];
  if (today < startDate) return 'Upcoming';
  if (today > endDate)   return 'Closed';
  return 'Active';
}

const TYPE_OPTIONS = [
  { value: 'billable', label: 'Billable' },
  { value: 'internal', label: 'Internal' },
  { value: 'overhead', label: 'Overhead' },
] as const;

/**
 * "Not classified" is shown plainly rather than assumed to be billable.
 * A project silently defaulted to billable turns up in Finance's billable
 * utilisation as if somebody had decided it, which is the whole reason
 * projects.project_type is nullable (mig 754).
 */
function TypeCell({ value }: { value: string | null }) {
  if (!value) return <span style={{ color: '#9CA3AF' }}>Not classified</span>;
  return <>{TYPE_OPTIONS.find(o => o.value === value)?.label ?? value}</>;
}

function StatusBadge({ status }: { status: 'Active' | 'Upcoming' | 'Closed' }) {
  const cls =
    status === 'Active'   ? 'badge badge-active'   :
    status === 'Upcoming' ? 'badge badge-upcoming' :
                            'badge badge-closed';
  return <span className={cls}>{status}</span>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Component
// ─────────────────────────────────────────────────────────────────────────────

export default function Projects() {
  const { projects, loading, error, refetch } = useProjects();

  const [name,      setName]      = useState('');
  const [startDate, setStartDate] = useState('');
  const [endDate,   setEndDate]   = useState('');
  const [projType,  setProjType]  = useState('');
  const [managerId, setManagerId] = useState('');
  const [budget,    setBudget]    = useState('');
  const [editId,    setEditId]    = useState<string | null>(null);
  const [saving,    setSaving]    = useState(false);

  // Delete confirmation modal
  const [modal, setModal] = useState<{ isOpen: boolean; project: Project | null }>({
    isOpen: false, project: null,
  });

  // Inline form validation errors
  const [formErrors, setFormErrors] = useState<Record<string, string>>({});

  // Info / blocking modal (replaces alert)
  const [infoModal, setInfoModal] = useState<{
    open: boolean; title: string; message: string;
  }>({ open: false, title: '', message: '' });

  // Set of project UUIDs that are referenced by at least one active line item
  const [usedProjectIds, setUsedProjectIds] = useState<Set<string>>(new Set());

  const nameRef = useRef<HTMLInputElement>(null);

  /**
   * Candidates for the reporting manager. Active employees, PLUS anyone already
   * recorded as a manager who has since gone inactive — without the second set,
   * opening such a project for edit would show an empty picker and quietly
   * clear the manager on save.
   */
  const [people, setPeople] = useState<{ id: string; label: string; inactive: boolean }[]>([]);
  useEffect(() => {
    let mounted = true;
    const t = setTimeout(async () => {
      const { data } = await supabase
        .from('employees')
        .select('id, name, employee_id, status')
        .order('name');
      if (!mounted || !data) return;
      const held = new Set(projects.map(p => p.managerId).filter(Boolean) as string[]);
      setPeople(
        data
          .filter(r => r.status === 'Active' || held.has(r.id))
          .map(r => ({
            id: r.id,
            label: `${r.name} (${r.employee_id})${r.status === 'Active' ? '' : ' — inactive'}`,
            inactive: r.status !== 'Active',
          }))
      );
    }, 0);
    return () => { mounted = false; clearTimeout(t); };
  }, [projects]);

  const managerName = useCallback(
    (id: string | null) => (id ? people.find(p => p.id === id)?.label ?? '—' : null),
    [people],
  );

  // Load in-use project IDs from line_items table once on mount
  useEffect(() => {
    let mounted = true;
    async function loadUsedIds() {
      const { data } = await supabase
        .from('line_items')
        .select('project_id')
        .is('deleted_at', null)
        .not('project_id', 'is', null);
      if (!mounted) return;
      const ids = new Set<string>(
        (data ?? []).map((r) => r.project_id as string).filter(Boolean)
      );
      setUsedProjectIds(ids);
    }
    // Defer past the supabase-js auth lock (held during onAuthStateChange / token refresh).
    // Calling supabase.from() synchronously on mount can deadlock if _initialize() is
    // still running. setTimeout(0) ensures we run after the lock is released.
    const t = setTimeout(() => { loadUsedIds(); }, 0);
    return () => { mounted = false; clearTimeout(t); };
  }, []);

  // ── Form helpers ────────────────────────────────────────────────────────────

  function resetForm() {
    setName(''); setStartDate(''); setEndDate('');
    setProjType(''); setManagerId(''); setBudget('');
    setEditId(null);
    setFormErrors({});
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const trimmed = name.trim().toUpperCase();
    const errs: Record<string, string> = {};
    if (!trimmed)    errs.name      = 'Project name is required.';
    if (!startDate)  errs.startDate = 'Start date is required.';
    if (!endDate)    errs.endDate   = 'End date is required.';
    if (trimmed && startDate && endDate && endDate < startDate) {
      errs.endDate = 'End date cannot be before start date.';
    }
    // Budget is optional; if given it must be a real positive number, which is
    // also what projects_budget_hours_check enforces. Catch it here so the user
    // gets a field error rather than a Postgres constraint message.
    if (budget !== '' && !(Number(budget) > 0)) {
      errs.budget = 'Budget hours must be greater than zero, or left blank.';
    }
    if (Object.keys(errs).length > 0) { setFormErrors(errs); return; }
    setFormErrors({});
    setSaving(true);

    if (editId !== null) {
      // Update existing project
      const { error: err } = await supabase
        .from('projects')
        .update({
          name: trimmed, start_date: startDate, end_date: endDate,
          ...optionalFields(),
        })
        .eq('id', editId);
      if (err) {
        setInfoModal({ open: true, title: 'Error', message: err.message });
      } else {
        refetch();
        resetForm();
      }
    } else {
      // Duplicate name check (client-side for UX speed)
      if (projects.find(p => p.name === trimmed)) {
        setFormErrors({ name: `A project named "${trimmed}" already exists.` });
        setSaving(false);
        return;
      }
      const { error: err } = await supabase
        .from('projects')
        .insert({
          name: trimmed, start_date: startDate, end_date: endDate, active: true,
          ...optionalFields(),
        });
      if (err) {
        setInfoModal({ open: true, title: 'Error', message: err.message });
      } else {
        refetch();
        resetForm();
      }
    }
    setSaving(false);
  }

  /**
   * Empty string means "not set", and must reach the database as NULL rather
   * than as '' or 0 — the three columns treat NULL as a real state and the
   * reports are built to show it (mig 754).
   */
  function optionalFields() {
    return {
      project_type: projType  === '' ? null : projType,
      manager_id:   managerId === '' ? null : managerId,
      budget_hours: budget    === '' ? null : Number(budget),
    };
  }

  function startEdit(p: Project) {
    setName(p.name);
    setStartDate(p.startDate);
    setEndDate(p.endDate);
    setProjType(p.projectType ?? '');
    setManagerId(p.managerId ?? '');
    setBudget(p.budgetHours === null ? '' : String(p.budgetHours));
    setEditId(p.id);
    setFormErrors({});
    setTimeout(() => nameRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' }), 50);
  }

  async function requestDelete(p: Project) {
    // Re-query in-use status at delete time for accuracy
    const { data } = await supabase
      .from('line_items')
      .select('id')
      .eq('project_id', p.id)
      .is('deleted_at', null)
      .limit(1);
    if (data && data.length > 0) {
      setInfoModal({
        open: true,
        title: 'Cannot Delete Project',
        message: `"${p.name}" is assigned to one or more expense line items and cannot be deleted. Remove it from all expense records first.`,
      });
      return;
    }
    setModal({ isOpen: true, project: p });
  }

  async function confirmDelete() {
    if (modal.project) {
      const { error: err } = await supabase
        .from('projects')
        .delete()
        .eq('id', modal.project.id);
      if (err) {
        setInfoModal({ open: true, title: 'Error', message: err.message });
      } else {
        setUsedProjectIds(prev => { const s = new Set(prev); s.delete(modal.project!.id); return s; });
        refetch();
      }
    }
    setModal({ isOpen: false, project: null });
  }

  function cancelDelete() {
    setModal({ isOpen: false, project: null });
  }

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <div className="ar-panel">
      {/* Workflow gate banners */}
      <WorkflowGateBanner moduleCode="project_create" actionLabel="new projects created" />
      <WorkflowGateBanner moduleCode="project_edit"   actionLabel="project edits saved" />

      {/* Page title */}
      <div style={{ marginBottom: 20 }}>
        <h2 className="page-title">Project Management</h2>
      </div>

      {error && <ErrorBanner message={error} onRetry={refetch} />}

      {/* ── Form card ────────────────────────────────────────────────────────── */}
      <div className="rd-form-card" style={{ marginBottom: 24 }}>
        <form onSubmit={handleSubmit}>
          <div className="rd-form-row">
            <div className={`form-group${formErrors.name ? ' form-group--error' : ''}`} style={{ flex: 2 }}>
              <label>Project Name</label>
              <input
                ref={nameRef}
                type="text"
                placeholder="e.g. AMTPJ"
                value={name}
                onChange={e => { setName(e.target.value); setFormErrors(p => ({ ...p, name: '' })); }}
                required
              />
              {formErrors.name && (
                <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                  <i className="fa-solid fa-circle-exclamation" /> {formErrors.name}
                </small>
              )}
            </div>
            <div className={`form-group${formErrors.startDate ? ' form-group--error' : ''}`} style={{ flex: 1 }}>
              <label>Start Date</label>
              <input
                type="date" min="1900-01-01" max="2100-12-31"
                value={startDate}
                onChange={e => { setStartDate(e.target.value); setFormErrors(p => ({ ...p, startDate: '' })); }}
                required
              />
              {formErrors.startDate && (
                <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                  <i className="fa-solid fa-circle-exclamation" /> {formErrors.startDate}
                </small>
              )}
            </div>
            <div className={`form-group${formErrors.endDate ? ' form-group--error' : ''}`} style={{ flex: 1 }}>
              <label>End Date</label>
              <input
                type="date" min="1900-01-01" max="2100-12-31"
                value={endDate}
                onChange={e => { setEndDate(e.target.value); setFormErrors(p => ({ ...p, endDate: '' })); }}
                required
              />
              {formErrors.endDate && (
                <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                  <i className="fa-solid fa-circle-exclamation" /> {formErrors.endDate}
                </small>
              )}
            </div>
          </div>
          <div className="rd-form-row">
            <div className="form-group" style={{ flex: 1 }}>
              <label>Project Type</label>
              <select value={projType} onChange={e => setProjType(e.target.value)}>
                <option value="">Not classified</option>
                {TYPE_OPTIONS.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
              </select>
              <small style={{ color: '#8A97A8', marginTop: 4, display: 'block' }}>
                Drives billable utilisation. Left unclassified until someone decides.
              </small>
            </div>
            <div className="form-group" style={{ flex: 1 }}>
              <label>Reporting Manager</label>
              <select value={managerId} onChange={e => setManagerId(e.target.value)}>
                <option value="">None</option>
                {people.map(p => <option key={p.id} value={p.id}>{p.label}</option>)}
              </select>
              <small style={{ color: '#8A97A8', marginTop: 4, display: 'block' }}>
                The manager this project reports into.
              </small>
            </div>
            <div className={`form-group${formErrors.budget ? ' form-group--error' : ''}`} style={{ flex: 1 }}>
              <label>Budget Hours</label>
              <input
                type="number" min="0.5" step="0.5" placeholder="Optional"
                value={budget}
                onChange={e => { setBudget(e.target.value); setFormErrors(p => ({ ...p, budget: '' })); }}
              />
              {formErrors.budget ? (
                <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                  <i className="fa-solid fa-circle-exclamation" /> {formErrors.budget}
                </small>
              ) : (
                <small style={{ color: '#8A97A8', marginTop: 4, display: 'block' }}>
                  Hours, not cost. Blank means the report shows hours without a percentage.
                </small>
              )}
            </div>
          </div>
          <div className="rd-form-actions">
            <button type="submit" className="btn-add" disabled={saving}>
              {saving ? (
                <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
              ) : editId !== null ? (
                <><i className="fa-solid fa-floppy-disk" /> Update Project</>
              ) : (
                <><i className="fa-solid fa-plus" /> Add Project</>
              )}
            </button>
            {editId !== null && (
              <button type="button" className="btn-cancel" onClick={resetForm} disabled={saving}>
                Cancel
              </button>
            )}
          </div>
        </form>
      </div>

      {/* ── Table ────────────────────────────────────────────────────────────── */}
      <div className="er-table-wrap" style={{ overflow: 'hidden', maxWidth: '100%' }}>
        <div style={{ overflowY: 'auto', maxHeight: 'calc(100vh - 340px)' }}>
          <table className="er-table">
            <thead style={{ position: 'sticky', top: 0, zIndex: 5 }}>
              <tr>
                <th style={{ width: 48 }}>#</th>
                <th>Project Name</th>
                <th>Start Date</th>
                <th>End Date</th>
                <th>Type</th>
                <th>Reporting Manager</th>
                <th style={{ textAlign: 'right' }}>Budget (h)</th>
                <th>Status</th>
                <th style={{ textAlign: 'right' }}>Action</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={9} className="rd-empty">
                    <i className="fa-solid fa-spinner fa-spin" /> Loading projects…
                  </td>
                </tr>
              ) : projects.length === 0 ? (
                <tr>
                  <td colSpan={9} className="rd-empty">No projects added yet.</td>
                </tr>
              ) : projects.map((p, i) => {
                const inUse = usedProjectIds.has(p.id);
                return (
                  <tr key={p.id}>
                    <td>{i + 1}</td>
                    <td><strong>{p.name}</strong></td>
                    <td>{p.startDate}</td>
                    <td>{p.endDate}</td>
                    <td><TypeCell value={p.projectType} /></td>
                    <td>{managerName(p.managerId) ?? <span style={{ color: '#9CA3AF' }}>None</span>}</td>
                    <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
                      {p.budgetHours === null
                        ? <span style={{ color: '#9CA3AF' }}>—</span>
                        : p.budgetHours}
                    </td>
                    <td><StatusBadge status={getStatus(p.startDate, p.endDate)} /></td>
                    <td style={{ textAlign: 'right' }} className="rd-actions">
                      <button
                        className="rd-btn-edit-val"
                        title="Edit"
                        onClick={() => startEdit(p)}
                      >
                        <i className="fa-solid fa-pen-to-square" />
                      </button>
                      <button
                        className="rd-btn-del-val"
                        title={inUse ? 'In use — cannot delete' : 'Delete'}
                        style={inUse ? { opacity: 0.4, cursor: 'not-allowed' } : undefined}
                        onClick={() => requestDelete(p)}
                      >
                        <i className="fa-solid fa-trash" />
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {/* ── Delete confirmation modal ─────────────────────────────────────────── */}
      <ConfirmationModal
        isOpen={modal.isOpen}
        title="Delete Project"
        message={`Are you sure you want to delete "${modal.project?.name ?? ''}"?`}
        warning="This action cannot be undone and will permanently remove the project."
        confirmText="Delete"
        cancelText="Cancel"
        onConfirm={confirmDelete}
        onCancel={cancelDelete}
      />

      {/* ── Info / blocking modal (replaces alert) ─────────────────────────── */}
      {infoModal.open && (
        <div className="modal-overlay" onClick={() => setInfoModal(m => ({ ...m, open: false }))}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-circle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>{infoModal.title}</h3>
            </div>
            <div className="modal-body">{infoModal.message}</div>
            <div className="modal-actions">
              <button
                className="btn-add"
                style={{ padding: '9px 28px' }}
                onClick={() => setInfoModal(m => ({ ...m, open: false }))}
              >
                OK
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
