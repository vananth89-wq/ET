import { useState, useRef, useEffect } from 'react';
import { supabase } from '../../lib/supabase';
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
    if (Object.keys(errs).length > 0) { setFormErrors(errs); return; }
    setFormErrors({});
    setSaving(true);

    if (editId !== null) {
      // Update existing project
      const { error: err } = await supabase
        .from('projects')
        .update({ name: trimmed, start_date: startDate, end_date: endDate })
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
        .insert({ name: trimmed, start_date: startDate, end_date: endDate, active: true });
      if (err) {
        setInfoModal({ open: true, title: 'Error', message: err.message });
      } else {
        refetch();
        resetForm();
      }
    }
    setSaving(false);
  }

  function startEdit(p: Project) {
    setName(p.name);
    setStartDate(p.startDate);
    setEndDate(p.endDate);
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
                type="date"
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
                type="date"
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
                <th>Status</th>
                <th style={{ textAlign: 'right' }}>Action</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={6} className="rd-empty">
                    <i className="fa-solid fa-spinner fa-spin" /> Loading projects…
                  </td>
                </tr>
              ) : projects.length === 0 ? (
                <tr>
                  <td colSpan={6} className="rd-empty">No projects added yet.</td>
                </tr>
              ) : projects.map((p, i) => {
                const inUse = usedProjectIds.has(p.id);
                return (
                  <tr key={p.id}>
                    <td>{i + 1}</td>
                    <td><strong>{p.name}</strong></td>
                    <td>{p.startDate}</td>
                    <td>{p.endDate}</td>
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
