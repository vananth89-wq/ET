/**
 * TimeTypes — Admin page for managing time entry types.
 *
 * Each time type has: name, code, category (attendance/absence),
 * allows_partial_overlap, is_active.
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
  allows_partial_overlap: boolean;
  is_active:              boolean;
}

// ─── Badges ───────────────────────────────────────────────────────────────────

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

const EMPTY: Omit<TimeType, 'id'> & { id: string } = {
  id: '', name: '', code: '', category: 'attendance', allows_partial_overlap: false, is_active: true,
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
      .select('id, name, code, category, allows_partial_overlap, is_active')
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
      allows_partial_overlap: form.allows_partial_overlap,
      is_active: form.is_active,
    };

    const { data, error: e } = await supabase.rpc('upsert_time_type', { p_data: payload });
    setSaving(false);

    if (e || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? e?.message ?? 'Unknown error.' });
      return;
    }
    await load();
    resetForm();
  }

  async function confirmDelete() {
    const tt = deleteModal.type!;
    setDeleteModal({ open: false, type: null });
    const { error: e } = await supabase.from('time_types').delete().eq('id', tt.id);
    if (e) setInfoModal({ open: true, title: 'Cannot Delete', message: e.message });
    else await load();
  }

  // Group by category for display
  const attendance = types.filter(t => t.category === 'attendance');
  const absence    = types.filter(t => t.category === 'absence');

  return (
    <div className="ar-panel">
      <h2 className="page-title">Time Types</h2>
      <p className="page-subtitle">
        Define categories of time entries employees can log. Absence types (full-day) prevent other
        entries on the same day unless "Allows Partial Overlap" is enabled.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {/* ── Form card ───────────────────────────────────────────────────────── */}
      <div className="rd-form-card" style={{ marginBottom: 28 }}>
        <h3 style={{ fontSize: 14, fontWeight: 600, color: '#374151', marginBottom: 16 }}>
          {form.id ? 'Edit Time Type' : 'New Time Type'}
        </h3>
        <form onSubmit={handleSubmit}>
          <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div className={`form-group${formErrors.name ? ' form-group--error' : ''}`}>
              <label>Name</label>
              <input
                type="text" placeholder="e.g. Training"
                value={form.name}
                onChange={e => { setForm(p => ({ ...p, name: e.target.value })); setFormErrors(p => ({ ...p, name: '' })); }}
              />
              {formErrors.name && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.name}</small>}
            </div>

            <div className={`form-group${formErrors.code ? ' form-group--error' : ''}`}>
              <label>Code</label>
              <input
                type="text" placeholder="e.g. TRN" style={{ textTransform: 'uppercase' }}
                value={form.code}
                onChange={e => { setForm(p => ({ ...p, code: e.target.value })); setFormErrors(p => ({ ...p, code: '' })); }}
              />
              {formErrors.code && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.code}</small>}
            </div>

            <div className="form-group">
              <label>Category</label>
              <select value={form.category} onChange={e => setForm(p => ({ ...p, category: e.target.value as 'attendance' | 'absence' }))}>
                <option value="attendance">Attendance</option>
                <option value="absence">Absence</option>
              </select>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 24, marginBottom: 16 }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, cursor: 'pointer' }}>
              <input
                type="checkbox" checked={form.allows_partial_overlap}
                onChange={e => setForm(p => ({ ...p, allows_partial_overlap: e.target.checked }))}
              />
              Allows Partial Overlap
              <span style={{ color: '#9CA3AF', fontSize: 11 }}>
                (employees can log other hours on a partial {form.category === 'absence' ? 'absence' : 'attendance'} day)
              </span>
            </label>

            <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, cursor: 'pointer' }}>
              <input
                type="checkbox" checked={form.is_active}
                onChange={e => setForm(p => ({ ...p, is_active: e.target.checked }))}
              />
              Active
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
          {[{ label: 'Attendance', items: attendance }, { label: 'Absence', items: absence }].map(({ label, items }) => (
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
                        <th>Partial Overlap</th>
                        <th>Status</th>
                        <th style={{ textAlign: 'right' }}>Action</th>
                      </tr>
                    </thead>
                    <tbody>
                      {items.map((tt, i) => (
                        <tr key={tt.id}>
                          <td>{i + 1}</td>
                          <td><strong>{tt.name}</strong></td>
                          <td><code style={{ background: '#F3F4F6', padding: '2px 6px', borderRadius: 4, fontSize: 12 }}>{tt.code}</code></td>
                          <td><CategoryBadge category={tt.category} /></td>
                          <td style={{ textAlign: 'center' }}>
                            {tt.allows_partial_overlap
                              ? <i className="fa-solid fa-check" style={{ color: '#10B981' }} />
                              : <i className="fa-solid fa-minus" style={{ color: '#D1D5DB' }} />
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
                          <td style={{ textAlign: 'right' }} className="rd-actions">
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
