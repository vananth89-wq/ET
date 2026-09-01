/**
 * TimeTypes — Admin page for managing time entry types.
 *
 * Each time type has: name, code, category (attendance/absence),
 * allows_half_day, is_active.
 *
 * Layout: form card at top, sortable list below.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';
import ConfirmationModal from '../../shared/ConfirmationModal';

// ─── Types ────────────────────────────────────────────────────────────────────

interface TimeType {
  id:                     string;
  name:                   string;
  code:                   string;
  category:               'attendance' | 'absence';
  allows_half_day:        boolean;
  allows_future:          boolean;   // either category, per type — mig 729
  is_system_managed:      boolean;
  requires_project:       boolean;
  is_billable:            boolean;   // attendance only - mig 800
  uses_related_project:   boolean;   // only where a project is required - mig 801
  is_active:              boolean;
  created_at:             string | null;
  updated_at:             string | null;
  creator:                any;
}

// ─── Badges ───────────────────────────────────────────────────────────────────

function creatorName(creator: any): string {
  const emp = Array.isArray(creator) ? creator[0]?.employees : creator?.employees;
  return (Array.isArray(emp) ? emp[0]?.name : emp?.name) ?? '';
}

function CategoryBadge({ category }: { category: string }) {
  const isAtt = category === 'attendance';
  return (
    <span style={{
      display: 'inline-block', padding: '2px 10px', borderRadius: 10,
      fontSize: 11, fontWeight: 600,
      background: isAtt ? '#D1FAE5' : '#FEE2E2',
      color: isAtt ? '#065F46' : '#991B1B',
    }}>
      {isAtt ? 'Attendance' : 'Absence'}
    </span>
  );
}

// ─── Component ────────────────────────────────────────────────────────────────

/** One checkbox rule: an 18px gutter for the box, the label beside it, and the
 *  explanation on the next line starting at the label's left edge. */
const ruleRowSt: React.CSSProperties = {
  display: 'grid', gridTemplateColumns: '18px 1fr', columnGap: 10, rowGap: 3,
  alignItems: 'start', cursor: 'pointer',
};
const ruleBoxSt:   React.CSSProperties = { marginTop: 3, width: 15, height: 15, cursor: 'pointer' };
const ruleLabelSt: React.CSSProperties = { fontSize: 13, fontWeight: 600, color: '#374151' };
const ruleHintSt:  React.CSSProperties = { gridColumn: 2, fontSize: 11.5, color: '#9CA3AF', lineHeight: 1.55 };

const EMPTY: Omit<TimeType, 'id'> & { id: string } = {
  id: '', name: '', code: '', category: 'attendance', allows_half_day: false, allows_future: false, is_system_managed: false, requires_project: false, is_billable: false, uses_related_project: false, is_active: true, created_at: null, updated_at: null, creator: null,
};

export default function TimeTypes() {
  const [types,     setTypes]     = useState<TimeType[]>([]);
  const [loading,   setLoading]   = useState(true);
  const [error,     setError]     = useState<string | null>(null);
  const [form,      setForm]      = useState<TimeType>({ ...EMPTY });
  const [saving,    setSaving]    = useState(false);
  const [formErrors, setFormErrors] = useState<Record<string, string>>({});
  const [deleteModal, setDeleteModal] = useState<{ open: boolean; type: TimeType | null }>({ open: false, type: null });
  const [infoModal, setInfoModal] = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: e } = await supabase
      .from('time_types')
      .select('id, name, code, category, allows_half_day, allows_future, is_system_managed, requires_project, is_billable, uses_related_project, is_active, created_at, updated_at, creator:profiles!created_by(employees!employee_id(name))')
      .order('category')
      .order('name');
    if (e) { setError(e.message); setLoading(false); return; }
    setTypes((data ?? []) as TimeType[]);
    setLoading(false);
  }, []);

  useEffect(() => { const t = setTimeout(load, 0); return () => clearTimeout(t); }, [load]);

  function resetForm() { setForm({ ...EMPTY }); setFormErrors({}); }

  function startEdit(tt: TimeType) {
    setForm({ ...tt });
    setFormErrors({});
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const errs: Record<string, string> = {};
    if (!form.name.trim()) errs.name = 'Name is required.';
    if (!form.code.trim()) errs.code = 'Code is required.';
    if (Object.keys(errs).length) { setFormErrors(errs); return; }
    setFormErrors({});
    setSaving(true);

    const payload = {
      ...(form.id ? { id: form.id } : {}),
      name: form.name.trim(),
      code: form.code.trim(),
      category: form.category,
      // The first two flags belong to exactly one category each — mirrored in
      // upsert_time_type. allows_future does NOT: "is this scheduled?" is a fair
      // question of Training as much as of planned leave (mig 729).
      allows_half_day:  form.category === 'absence'    ? form.allows_half_day  : false,
      allows_future:    form.allows_future,
      requires_project: form.category === 'attendance' ? form.requires_project : false,
      // Absence is not unbillable work, it is not work. upsert_time_type forces
      // this false for absence anyway; sending it false is how the screen says
      // the same thing rather than relying on the database to correct it.
      is_billable:      form.category === 'attendance' ? form.is_billable      : false,
      // A type that names no project cannot name somebody else's. Mirrored in
      // upsert_time_type, which gates on requires_project rather than category.
      uses_related_project: form.category === 'attendance' && form.requires_project
                              ? form.uses_related_project : false,
      is_active: form.is_active,
    };

    const { data, error: rpcErr } = await supabase.rpc('upsert_time_type', { p_data: payload });
    setSaving(false);

    if (rpcErr || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? rpcErr?.message ?? 'Unknown error.' });
      return;
    }
    await load();
    resetForm();
  }

  async function confirmDelete() {
    const tt = deleteModal.type!;
    setDeleteModal({ open: false, type: null });
    const { error: delErr } = await supabase.from('time_types').delete().eq('id', tt.id);
    if (delErr) setInfoModal({ open: true, title: 'Cannot Delete', message: delErr.message });
    else await load();
  }

  // Group by category for display
  const attendance = types.filter(t => t.category === 'attendance');
  const absence    = types.filter(t => t.category === 'absence');

  return (
    <div className="ar-panel">
      <h2 className="page-title">Time Types</h2>
      <p className="page-subtitle">
        Define the categories of time entry employees can log. Each type carries its own rules:
        whether it needs a project, whether an absence may be taken as a half day, and whether it
        can be recorded ahead of today.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {/* ── Form card ───────────────────────────────────────────────────────── */}
      <div className="rd-form-card" style={{ marginBottom: 28 }}>
        <h3 style={{ fontSize: 14, fontWeight: 600, color: '#374151', marginBottom: 16 }}>
          {form.id ? 'Edit Time Type' : 'New Time Type'}
        </h3>
        <form onSubmit={handleSubmit}>
          {/* One field per row, each sized to what it actually holds.
              A full-width input quietly promises a long answer — a Code box wide
              enough for forty characters invites someone to type a sentence into
              it. Sizing the box is a form of instruction: it tells you roughly
              how much to write before you have read the label.
              The stack is capped so labels, inputs, checkboxes and the button all
              share ONE left edge and one comfortable reading column, while the
              card itself stays full width and aligned with the tables below. */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 14, marginBottom: 18, maxWidth: 560 }}>
            <div className={`form-group${formErrors.name ? ' form-group--error' : ''}`} style={{ maxWidth: 560 }}>
              <label>Name</label>
              <input
                type="text" placeholder="e.g. Training"
                value={form.name}
                onChange={e => { setForm(p => ({ ...p, name: e.target.value })); setFormErrors(p => ({ ...p, name: '' })); }}
              />
              {formErrors.name && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.name}</small>}
            </div>

            <div className={`form-group${formErrors.code ? ' form-group--error' : ''}`} style={{ maxWidth: 180 }}>
              <label>Code</label>
              <input
                type="text" placeholder="e.g. TRN" style={{ textTransform: 'uppercase' }}
                value={form.code}
                onChange={e => { setForm(p => ({ ...p, code: e.target.value })); setFormErrors(p => ({ ...p, code: '' })); }}
              />
              {formErrors.code && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.code}</small>}
            </div>

            <div className="form-group" style={{ maxWidth: 280 }}>
              <label>Category</label>
              <select value={form.category} onChange={e => setForm(p => ({ ...p, category: e.target.value as 'attendance' | 'absence' }))}>
                <option value="attendance">Attendance</option>
                <option value="absence">Absence</option>
              </select>
            </div>
          </div>

          {/* One rule per row. The old layout put the label and its explanation on
              the SAME line inside a flex row, so three options of very different
              lengths produced ragged columns and the longest label wrapped mid-phrase.
              A grid gives each option a fixed 18px gutter for the box and puts the
              explanation directly beneath its own label — one left edge to read down,
              and the checkbox you are about to tick is never separated from the
              sentence that says what it does. */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 13, marginBottom: 18, maxWidth: 660 }}>

            {form.category === 'attendance' && (
              <label style={ruleRowSt}>
                <input
                  type="checkbox" checked={form.requires_project}
                  onChange={e => setForm(p => ({ ...p, requires_project: e.target.checked }))}
                  style={ruleBoxSt}
                />
                <span style={ruleLabelSt}>Requires Project</span>
                <span style={ruleHintSt}>
                  The employee must pick an active project when logging this type.
                </span>
              </label>
            )}

            {form.category === 'attendance' && (
              <label style={ruleRowSt}>
                <input
                  type="checkbox" checked={form.is_billable}
                  onChange={e => setForm(p => ({ ...p, is_billable: e.target.checked }))}
                  style={ruleBoxSt}
                />
                <span style={ruleLabelSt}>Billable</span>
                <span style={ruleHintSt}>
                  Applies only when the entry names <b>no</b> project &mdash; for a type
                  that requires one, the project&rsquo;s own type decides whether the hours
                  are billable. So this governs types like Training, and it is what
                  classifies them in the Utilisation billable share. Absence types are
                  never billable and are reported in their own bucket.
                </span>
              </label>
            )}

            {form.category === 'attendance' && form.requires_project && (
              <label style={ruleRowSt}>
                <input
                  type="checkbox" checked={form.uses_related_project}
                  onChange={e => setForm(p => ({ ...p, uses_related_project: e.target.checked }))}
                  style={ruleBoxSt}
                />
                <span style={ruleLabelSt}>Records help given to another project</span>
                <span style={ruleHintSt}>
                  The employee picks from <b>every</b> active project, not just their own,
                  and the hours are recorded as help rather than booked to that project &mdash;
                  so they never reach its utilisation, budget or cost. Once hours exist on
                  this type, this setting can no longer be changed.
                </span>
              </label>
            )}

            {form.category === 'absence' && (
              <label style={ruleRowSt}>
                <input
                  type="checkbox" checked={form.allows_half_day}
                  onChange={e => setForm(p => ({ ...p, allows_half_day: e.target.checked }))}
                  style={ruleBoxSt}
                />
                <span style={ruleLabelSt}>Allows Half Day</span>
                <span style={ruleHintSt}>
                  May be taken for part of a day, and attendance can be logged alongside it.
                  Leave it off and the entry is locked to the whole planned day and blocks
                  everything else.
                </span>
              </label>
            )}

            <label style={ruleRowSt}>
              <input
                type="checkbox" checked={form.allows_future}
                onChange={e => setForm(p => ({ ...p, allows_future: e.target.checked }))}
                style={ruleBoxSt}
              />
              <span style={ruleLabelSt}>Allows Future Dates</span>
              <span style={ruleHintSt}>
                For things that are <i>scheduled</i> — a booked training next week, planned
                leave. Leave it off for anything only reportable after the fact: project work,
                sick leave.
              </span>
            </label>

            {/* Active is a status, not a rule about how time is recorded, so it sits
                below a divider rather than in the same list. */}
            <label style={{ ...ruleRowSt, borderTop: '1px solid #F1F5F9', paddingTop: 13 }}>
              <input
                type="checkbox" checked={form.is_active}
                onChange={e => setForm(p => ({ ...p, is_active: e.target.checked }))}
                style={{ ...ruleBoxSt, marginTop: 16 }}
              />
              <span style={{ ...ruleLabelSt, marginTop: 13 }}>Active</span>
              <span style={ruleHintSt}>
                Inactive types disappear from the employee's picker. Entries already recorded
                against them are untouched.
              </span>
            </label>

          </div>

          <div className="rd-form-actions">
            <button type="submit" className="btn-add" disabled={saving}>
              {saving
                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : form.id
                  ? <><i className="fa-solid fa-floppy-disk" /> Update Time Type</>
                  : <><i className="fa-solid fa-plus" /> Add Time Type</>
              }
            </button>
            {form.id && (
              <button type="button" className="btn-cancel" onClick={resetForm} disabled={saving}>
                Cancel
              </button>
            )}
          </div>
        </form>
      </div>

      {/* ── Lists ───────────────────────────────────────────────────────────── */}
      {loading ? (
        <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 32 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
        </div>
      ) : (
        <>
          {[{ label: 'Attendance', items: attendance, isAttendance: true }, { label: 'Absence', items: absence, isAttendance: false }].map(({ label, items, isAttendance }) => (
            <div key={label} style={{ marginBottom: 28 }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: '#6B7280', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>
                {label} ({items.length})
              </div>

              {items.length === 0 ? (
                <div style={{ color: '#D1D5DB', fontSize: 13, padding: '12px 0' }}>No {label.toLowerCase()} types yet.</div>
              ) : (
                <div className="er-table-wrap">
                  <table className="er-table">
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Name</th>
                        <th>Code</th>
                        <th>Category</th>
                        {isAttendance && <th>Req. Project</th>}
                        {isAttendance && <th>Billable</th>}
                        {isAttendance && <th>Helps Others</th>}
                        {!isAttendance && <th>Half Day</th>}
                        <th>In Advance</th>
                        <th>Status</th>
                        <th>Created</th>
                        <th>Last Updated</th>
                        <th>Created By</th>
                        <th style={{ textAlign: 'right', position: 'sticky', right: 0, background: 'var(--navy)', zIndex: 2 }}>Action</th>
                      </tr>
                    </thead>
                    <tbody>
                      {items.map((tt, i) => (
                        <tr key={tt.id}>
                          <td>{i + 1}</td>
                          <td><strong>{tt.name}</strong></td>
                          <td><code style={{ background: '#F3F4F6', padding: '2px 6px', borderRadius: 4, fontSize: 12 }}>{tt.code}</code></td>
                          <td><CategoryBadge category={tt.category} /></td>
                          {isAttendance && (
                            <td style={{ textAlign: 'center' }}>
                              {tt.requires_project
                                ? <i className="fa-solid fa-check" style={{ color: '#3B82F6' }} title="Requires Project" />
                                : <i className="fa-solid fa-minus" style={{ color: '#D1D5DB' }} />
                              }
                            </td>
                          )}
                          {isAttendance && (
                            <td style={{ textAlign: 'center' }}>
                              {tt.is_billable
                                ? <i className="fa-solid fa-check" style={{ color: '#0F766E' }} title="Billable" />
                                : <i className="fa-solid fa-minus" style={{ color: '#D1D5DB' }} title="Not billable" />
                              }
                            </td>
                          )}
                          {isAttendance && (
                            <td style={{ textAlign: 'center' }}>
                              {tt.uses_related_project
                                ? <i className="fa-solid fa-hands-helping" style={{ color: '#7C3AED' }} title="Records help given to another project" />
                                : <i className="fa-solid fa-minus" style={{ color: '#D1D5DB' }} />
                              }
                            </td>
                          )}
                          {!isAttendance && (
                            <td style={{ textAlign: 'center' }}>
                              {tt.allows_half_day
                                ? <i className="fa-solid fa-check" style={{ color: '#10B981' }} title="May be taken as a half day" />
                                : <i className="fa-solid fa-minus" style={{ color: '#D1D5DB' }} title="Full day only" />
                              }
                            </td>
                          )}
                          <td style={{ textAlign: 'center' }}>
                            {tt.allows_future
                              ? <i className="fa-solid fa-check" style={{ color: '#8B5CF6' }} title="May be recorded ahead of today" />
                              : <i className="fa-solid fa-minus" style={{ color: '#D1D5DB' }} title="Cannot be recorded in advance" />
                            }
                          </td>
                          <td>
                            <span style={{
                              fontSize: 11, padding: '2px 8px', borderRadius: 10,
                              background: tt.is_active ? '#D1FAE5' : '#F3F4F6',
                              color: tt.is_active ? '#065F46' : '#9CA3AF',
                            }}>
                              {tt.is_active ? 'Active' : 'Inactive'}
                            </span>
                          </td>
                          <td style={{ color: '#6B7280', fontSize: 12 }}>{tt.created_at ? new Date(tt.created_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '—'}</td>
                          <td style={{ color: '#6B7280', fontSize: 12 }}>{tt.updated_at ? new Date(tt.updated_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '—'}</td>
                          <td style={{ color: '#6B7280', fontSize: 12 }}>{creatorName(tt.creator) || '—'}</td>
                          <td style={{ textAlign: 'right', position: 'sticky', right: 0, background: '#fff', zIndex: 1, boxShadow: '-2px 0 6px rgba(0,0,0,0.06)' }} className="rd-actions">
                            <button className="rd-btn-edit-val" title="Edit" onClick={() => startEdit(tt)}>
                              <i className="fa-solid fa-pen-to-square" />
                            </button>
                            <button className="rd-btn-del-val" title="Delete"
                              onClick={() => setDeleteModal({ open: true, type: tt })}>
                              <i className="fa-solid fa-trash" />
                            </button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          ))}
        </>
      )}

      <ConfirmationModal
        isOpen={deleteModal.open}
        title="Delete Time Type"
        message={`Delete "${deleteModal.type?.name ?? ''}"?`}
        warning="Timesheet entries using this type will retain a reference. The type will no longer appear in new entry dropdowns."
        confirmText="Delete"
        cancelText="Cancel"
        onConfirm={confirmDelete}
        onCancel={() => setDeleteModal({ open: false, type: null })}
      />

      {infoModal.open && (
        <div className="modal-overlay" onClick={() => setInfoModal(m => ({ ...m, open: false }))}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-circle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>{infoModal.title}</h3>
            </div>
            <div className="modal-body">{infoModal.message}</div>
            <div className="modal-actions">
              <button className="btn-add" style={{ padding: '9px 28px' }}
                onClick={() => setInfoModal(m => ({ ...m, open: false }))}>OK</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
