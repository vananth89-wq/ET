/**
 * HolidayCalendars — Admin page for managing holiday calendar definitions.
 *
 * Each calendar has: name, code, country_code (ISO 3166-1 alpha-2), is_active.
 * Holidays within a calendar are managed on the Holidays page.
 *
 * Layout: form card at top, sortable list below.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';
import ConfirmationModal from '../../shared/ConfirmationModal';

// ─── Types ────────────────────────────────────────────────────────────────────

interface HolidayCalendar {
  id:           string;
  name:         string;
  code:         string;
  country_code: string;
  is_active:    boolean;
}

// ─── Component ────────────────────────────────────────────────────────────────

const EMPTY: HolidayCalendar = { id: '', name: '', code: '', country_code: '', is_active: true };

export default function HolidayCalendars() {
  const [calendars,   setCalendars]   = useState<HolidayCalendar[]>([]);
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState<string | null>(null);
  const [form,        setForm]        = useState<HolidayCalendar>({ ...EMPTY });
  const [saving,      setSaving]      = useState(false);
  const [formErrors,  setFormErrors]  = useState<Record<string, string>>({});
  const [deleteModal, setDeleteModal] = useState<{ open: boolean; cal: HolidayCalendar | null }>({ open: false, cal: null });
  const [infoModal,   setInfoModal]   = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('time_holiday_calendars')
      .select('id, name, code, country_code, is_active')
      .order('name');
    if (err) { setError(err.message); setLoading(false); return; }
    setCalendars((data ?? []) as HolidayCalendar[]);
    setLoading(false);
  }, []);

  useEffect(() => { const t = setTimeout(load, 0); return () => clearTimeout(t); }, [load]);

  function resetForm() { setForm({ ...EMPTY }); setFormErrors({}); }

  function startEdit(cal: HolidayCalendar) {
    setForm({ ...cal });
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
      name:         form.name.trim(),
      code:         form.code.trim().toUpperCase(),
      country_code: form.country_code.trim().toUpperCase(),
      is_active:    form.is_active,
    };

    const { data, error: rpcErr } = await supabase.rpc('upsert_holiday_calendar', { p_data: payload });
    setSaving(false);

    if (rpcErr || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? rpcErr?.message ?? 'Unknown error.' });
      return;
    }
    await load();
    resetForm();
  }

  async function confirmDelete() {
    const cal = deleteModal.cal!;
    setDeleteModal({ open: false, cal: null });
    const { error: err } = await supabase.from('time_holiday_calendars').delete().eq('id', cal.id);
    if (err) setInfoModal({ open: true, title: 'Cannot Delete', message: err.message });
    else await load();
  }

  return (
    <div className="ar-panel">
      <h2 className="page-title">Holiday Calendars</h2>
      <p className="page-subtitle">
        Define named holiday calendars — typically one per country. Add individual holidays to each calendar on the Holidays page.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {/* ── Form card ───────────────────────────────────────────────────────── */}
      <div className="rd-form-card" style={{ marginBottom: 28 }}>
        <h3 style={{ fontSize: 14, fontWeight: 600, color: '#374151', marginBottom: 16 }}>
          {form.id ? 'Edit Calendar' : 'New Calendar'}
        </h3>
        <form onSubmit={handleSubmit}>
          <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div className={`form-group${formErrors.name ? ' form-group--error' : ''}`}>
              <label>Name</label>
              <input
                type="text" placeholder="e.g. Saudi Arabia Public Holidays"
                value={form.name}
                onChange={e => { setForm(p => ({ ...p, name: e.target.value })); setFormErrors(p => ({ ...p, name: '' })); }}
              />
              {formErrors.name && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.name}</small>}
            </div>

            <div className={`form-group${formErrors.code ? ' form-group--error' : ''}`}>
              <label>Code</label>
              <input
                type="text" placeholder="e.g. SA_2025" style={{ textTransform: 'uppercase' }}
                value={form.code}
                onChange={e => { setForm(p => ({ ...p, code: e.target.value })); setFormErrors(p => ({ ...p, code: '' })); }}
              />
              {formErrors.code && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.code}</small>}
            </div>

            <div className="form-group">
              <label>Country Code <span style={{ color: '#9CA3AF', fontWeight: 400 }}>(ISO 2-letter)</span></label>
              <input
                type="text" placeholder="e.g. SA" maxLength={2} style={{ textTransform: 'uppercase' }}
                value={form.country_code}
                onChange={e => setForm(p => ({ ...p, country_code: e.target.value }))}
              />
            </div>
          </div>

          <div style={{ display: 'flex', gap: 24, marginBottom: 16 }}>
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
                  ? <><i className="fa-solid fa-floppy-disk" /> Update Calendar</>
                  : <><i className="fa-solid fa-plus" /> Add Calendar</>
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

      {/* ── List ────────────────────────────────────────────────────────────── */}
      {loading ? (
        <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 32 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
        </div>
      ) : calendars.length === 0 ? (
        <div style={{ color: '#D1D5DB', fontSize: 13, padding: '12px 0' }}>No holiday calendars yet.</div>
      ) : (
        <div className="er-table-wrap">
          <table className="er-table">
            <thead>
              <tr>
                <th>#</th>
                <th>Name</th>
                <th>Code</th>
                <th>Country</th>
                <th>Status</th>
                <th style={{ textAlign: 'right' }}>Action</th>
              </tr>
            </thead>
            <tbody>
              {calendars.map((cal, i) => (
                <tr key={cal.id}>
                  <td>{i + 1}</td>
                  <td><strong>{cal.name}</strong></td>
                  <td><code style={{ background: '#F3F4F6', padding: '2px 6px', borderRadius: 4, fontSize: 12 }}>{cal.code}</code></td>
                  <td>
                    {cal.country_code
                      ? <span style={{ fontSize: 12, fontWeight: 600, background: '#EFF6FF', color: '#1D4ED8', padding: '2px 8px', borderRadius: 8 }}>{cal.country_code}</span>
                      : <span style={{ color: '#D1D5DB', fontSize: 12 }}>—</span>
                    }
                  </td>
                  <td>
                    <span style={{
                      fontSize: 11, padding: '2px 8px', borderRadius: 10,
                      background: cal.is_active ? '#D1FAE5' : '#F3F4F6',
                      color: cal.is_active ? '#065F46' : '#9CA3AF',
                    }}>
                      {cal.is_active ? 'Active' : 'Inactive'}
                    </span>
                  </td>
                  <td style={{ textAlign: 'right' }} className="rd-actions">
                    <button className="rd-btn-edit-val" title="Edit" onClick={() => startEdit(cal)}>
                      <i className="fa-solid fa-pen-to-square" />
                    </button>
                    <button className="rd-btn-del-val" title="Delete"
                      onClick={() => setDeleteModal({ open: true, cal })}>
                      <i className="fa-solid fa-trash" />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <ConfirmationModal
        isOpen={deleteModal.open}
        title="Delete Holiday Calendar"
        message={`Delete "${deleteModal.cal?.name ?? ''}"?`}
        warning="All holidays within this calendar will also be deleted. This cannot be undone."
        confirmText="Delete"
        cancelText="Cancel"
        onConfirm={confirmDelete}
        onCancel={() => setDeleteModal({ open: false, cal: null })}
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
