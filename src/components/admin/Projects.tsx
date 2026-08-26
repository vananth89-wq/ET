import { useState, useRef, useEffect } from 'react';
import { supabase } from '../../lib/supabase';
import WorkflowGateBanner from '../../workflow/components/WorkflowGateBanner';
import { useProjects } from '../../hooks/useProjects';
import { usePermissions } from '../../hooks/usePermissions';
import TeamAllocation from '../shared/TeamAllocation';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import ManagerAutocomplete from './ManagerAutocomplete';
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

/**
 * The project types are NOT hard-coded here. They are the PROJECT_TYPE picklist
 * (mig 755), so adding "Pre-sales" is an admin editing Reference Data rather
 * than a migration and a deploy — the same treatment every other
 * classification in Prowess gets.
 *
 * "Not classified" is shown plainly rather than assumed to be billable. A
 * project silently defaulted to billable turns up in Finance's billable
 * utilisation as if somebody had decided it, which is why the column is
 * nullable (mig 754).
 */
const PROJECT_TYPE_PICKLIST = 'PROJECT_TYPE';

function TypeCell({ label }: { label: string | null }) {
  if (!label) return <span style={{ color: '#9CA3AF' }}>Not classified</span>;
  return <>{label}</>;
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
  const { can } = usePermissions();

  /* Mig 791. An administrator reaches every project's team through the
     admin door in can_staff_project() -- projects_mgmt.edit short-circuits
     before the Reporting Manager check -- so this button is offered on the
     strength of the Team Allocation verbs OR that door. */
  const maySeeTeam = can('project_members.view')
                  || can('projects_mgmt.manage_members')
                  || can('projects_mgmt.edit');
  const [teamFor, setTeamFor] = useState<Project | null>(null);

  /* The panel renders BELOW the project table, which on a long list puts it a
     screen and a half under the button that opened it -- the click reads as
     doing nothing at all. Bring it into view instead. */
  const teamRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (teamFor) teamRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }, [teamFor]);

  const [name,      setName]      = useState('');
  const [startDate, setStartDate] = useState('');
  const [endDate,   setEndDate]   = useState('');
  const [projType,  setProjType]  = useState('');
  const [managerId, setManagerId] = useState<string | null>(null);
  const [managerNm, setManagerNm] = useState<string | null>(null);
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

  // Project types come from Reference Data, not from this file.
  const { getValues: getPicklistValues } = usePicklistValues();
  const typeOptions = getPicklistValues(PROJECT_TYPE_PICKLIST);

  const unclassified = projects.filter(p => !p.projectTypeId).length;

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
    setProjType(''); setManagerId(null); setManagerNm(null); setBudget('');
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

    /**
     * Project type is required when CREATING, and deliberately not when editing.
     *
     * Whoever creates a project knows whether it is billable, and that is the
     * only cheap moment to capture it — left optional it stays "Not classified"
     * forever and billable utilisation is quietly computed over a partial
     * portfolio. But blocking an EDIT would mean someone extending an end date
     * has to classify a project whose commercial arrangement they may know
     * nothing about, and they will pick something to get past the dialog. A
     * required field that manufactures guesses is worse than an optional one
     * that leaves honest blanks — the report is built to show the blank.
     *
     * Reporting Manager stays optional in both cases, and that asymmetry is the
     * point: it is a SECURITY column. No manager grants nobody PM access and
     * fails closed; a guessed manager grants real access to the wrong person
     * and fails open. Projects also routinely exist before a lead is assigned.
     *
     * Enforced here rather than with NOT NULL: the existing projects are all
     * unclassified, a backfill would have to guess, and the reports need NULL
     * to stay representable.
     */
    if (editId === null && projType === '') {
      errs.projType = 'Choose a project type. This drives billable utilisation.';
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
      project_type_id: projType === '' ? null : projType,
      manager_id:      managerId,
      budget_hours:    budget   === '' ? null : Number(budget),
    };
  }

  function startEdit(p: Project) {
    setName(p.name);
    setStartDate(p.startDate);
    setEndDate(p.endDate);
    setProjType(p.projectTypeId ?? '');
    setManagerId(p.managerId);
    setManagerNm(p.managerName);
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
      {/* Workflow gate banner.
          MIG 798 retired project_create — a create cannot be gated while
          workflow_instances.record_id is NOT NULL and projects has no draft
          state, so its banner promised a door that could not open.

          project_edit's banner is left MOUNTED but tells the truth only when
          the routing exists. Today handleSave() writes straight to the table:
          `supabase.from('projects').update(…)`. Nothing calls wf_submit, so a
          workflow assigned to project_edit gates nothing and this banner would
          claim otherwise. It stays because the moment the routing is built it
          becomes correct — and because hiding it would make the gap invisible
          rather than fixed. Do not assign a workflow to project_edit until
          handleSave routes through the engine. See Q11 in
          docs/prowess-project-staffing.docx. */}
      <WorkflowGateBanner moduleCode="project_edit" actionLabel="project edits saved" />

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
            <div className={`form-group${formErrors.projType ? ' form-group--error' : ''}`} style={{ flex: 1 }}>
              <label>Project Type {editId === null && <span style={{ color: '#D92D20' }}>*</span>}</label>
              <select
                value={projType}
                onChange={e => { setProjType(e.target.value); setFormErrors(p => ({ ...p, projType: '' })); }}
              >
                <option value="">Not classified</option>
                {typeOptions.map(o => <option key={o.id} value={o.id}>{o.value}</option>)}
              </select>
              {formErrors.projType ? (
                <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                  <i className="fa-solid fa-circle-exclamation" /> {formErrors.projType}
                </small>
              ) : (
                <small style={{ color: '#8A97A8', marginTop: 4, display: 'block' }}>
                  {typeOptions.length === 0
                    ? 'No values yet — add them under Reference Data → PROJECT_TYPE.'
                    : 'Maintained in Reference Data → PROJECT_TYPE.'}
                </small>
              )}
            </div>
            <div className="form-group" style={{ flex: 1 }}>
              <label>Reporting Manager</label>
              <ManagerAutocomplete
                valueId={managerId}
                valueName={managerNm}
                onChange={(id, nm) => { setManagerId(id); setManagerNm(nm); }}
              />
              <small style={{ color: '#8A97A8', marginTop: 4, display: 'block' }}>
                The manager this project reports into. Type to search; must be an employee.
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

      {/* Existing projects predate the type field and can only be classified by
          hand — a migration would have to guess, which is the thing 754 removed.
          This line is the worklist for that pass, and it disappears when the
          work is done rather than sitting there as permanent chrome. */}
      {!loading && unclassified > 0 && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12,
                      padding: '10px 14px', borderRadius: 8, background: '#FFFAEB',
                      border: '1px solid #FEDF89', fontSize: 13, color: '#8a5a00' }}>
          <i className="fa-solid fa-circle-info" />
          <span>
            <strong>{unclassified}</strong> of {projects.length} project{projects.length === 1 ? '' : 's'}
            {' '}not classified. Billable utilisation will exclude {unclassified === 1 ? 'it' : 'them'} until a type is set.
          </span>
        </div>
      )}

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
                    <td><TypeCell label={p.projectTypeName} /></td>
                    <td>{p.managerName
                      ?? (p.managerId
                        /* A manager is set but the embed came back empty — the
                           caller cannot read that employee. Saying "None" here
                           would report the opposite of the truth. */
                        ? <span style={{ color: '#9CA3AF' }} title="You do not have access to this employee">Restricted</span>
                        : <span style={{ color: '#9CA3AF' }}>None</span>)}</td>
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
                      {maySeeTeam && (
                        <button
                          className="rd-btn-edit-val"
                          title="Team allocation"
                          onClick={() => setTeamFor(t => t?.id === p.id ? null : p)}
                          style={teamFor?.id === p.id ? { color: '#2B54CE' } : undefined}
                        >
                          <i className="fa-solid fa-users" />
                        </button>
                      )}
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

      {/* ── Team allocation ──────────────────────────────────────────────────────
          The SAME component the lead uses at /my-projects. The only differences
          are the project list feeding it -- every project here, not just the
          ones you manage -- and allowHardDelete, which turns the end-assignment
          control into a real delete for a member who has booked no hours. */}
      {teamFor && (
        <div className="rd-form-card" ref={teamRef} style={{ marginTop: 24, scrollMarginTop: 88 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
                        gap: 12, flexWrap: 'wrap', marginBottom: 16 }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
              <h3 style={{ fontSize: 16, fontWeight: 700, color: '#18345B', margin: 0 }}>
                {teamFor.name}
              </h3>
              <span style={{ fontSize: 12.5, color: '#6B7280' }}>
                Reporting Manager: {teamFor.managerName ?? 'not set'} · runs to {teamFor.endDate}
              </span>
            </div>
            <button type="button" onClick={() => setTeamFor(null)}
              style={{ border: '1px solid #E3E9F2', background: '#fff', borderRadius: 7,
                       padding: '7px 14px', fontSize: 12.5, color: '#6B7280', cursor: 'pointer',
                       font: 'inherit' }}>
              Close
            </button>
          </div>

          {!teamFor.managerId && (
            <div style={{ marginBottom: 14, padding: '9px 14px', borderRadius: 8, fontSize: 13,
                          background: '#FDF2DF', border: '1px solid #EBCF9C', color: '#7A4B00' }}>
              <i className="fa-solid fa-circle-exclamation" /> This project has no Reporting
              Manager, so nobody leads it. You can staff it from here, but no one will see it on
              My&nbsp;Projects until a manager is set.
            </div>
          )}

          <TeamAllocation
            key={teamFor.id}
            projectId={teamFor.id}
            projectName={teamFor.name}
            projectEndDate={teamFor.endDate}
            allowHardDelete
            onChanged={refetch}
          />
        </div>
      )}

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
