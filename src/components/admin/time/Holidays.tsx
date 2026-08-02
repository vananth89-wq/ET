/**
 * Holidays — Admin page for managing individual holiday entries.
 *
 * Select a calendar from the dropdown, then add/edit/delete holidays within it.
 * Each holiday has: calendar_id, holiday_date, holiday_name, holiday_code.
 * One holiday per date per calendar (enforced by DB unique constraint).
 *
 * Layout: calendar selector + form card at top, holidays list below.
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
}

interface Holiday {
  id:           string;
  calendar_id:  string;
  holiday_date: string;   // 'YYYY-MM-DD'
  holiday_name: string;
  holiday_code: string;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatDate(d: string) {
  if (!d) return '';
  const [y, m, day] = d.split('-');
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return `${parseInt(day)} ${months[parseInt(m) - 1]} ${y}`;
}

const EMPTY_HOLIDAY: Omit<Holiday, 'id'> & { id: string } = {
  id: '', calendar_id: '', holiday_date: '', holiday_name: '', holiday_code: '',
};

// ─── Component ────────────────────────────────────────────────────────────────

export default function Holidays() {
  const [calendars,    setCalendars]    = useState<HolidayCalendar[]>([]);
  const [selectedCal,  setSelectedCal]  = useState<string>('');
  const [holidays,     setHolidays]     = useState<Holiday[]>([]);
  const [loadingCals,  setLoadingCals]  = useState(true);
  const [loadingHols,  setLoadingHols]  = useState(false);
  const [error,        setError]        = useState<string | null>(null);
  const [form,         setForm]         = useState<typeof EMPTY_HOLIDAY>({ ...EMPTY_HOLIDAY });
  const [saving,       setSaving]       = useState(false);
  const [formErrors,   setFormErrors]   = useState<Record<string, string>>({});
  const [deleteModal,  setDeleteModal]  = useState<{ open: boolean; holiday: Holiday | null }>({ open: false, holiday: null });
  const [infoModal,    setInfoModal]    = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  // Load calendars once
  useEffect(() => {
    (async () => {
      setLoadingCals(true);
      const { data, error: err } = await supabase
        .from('time_holiday_calendars')
        .select('id, name, code, country_code')
        .eq('is_active', true)
        .order('name');
      if (err) { setError(err.message); setLoadingCals(false); return; }
      const cals = (data ?? []) as HolidayCalendar[];
      setCalendars(cals);
      if (cals.length > 0) setSelectedCal(cals[0].id);
      setLoadingCals(false);
    })();
  }, []);

  // Load holidays when calendar changes
  const loadHolidays = useCallback(async (calId: string) => {
    if (!calId) return;
    setLoadingHols(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('time_holidays')
      .select('id, calendar_id, holiday_date, holiday_name, holiday_code')
      .eq('calendar_id', calId)
      .order('holiday_date');
    if (err) { setError(err.message); setLoadingHols(false); return; }
    setHolidays((data ?? []) as Holiday[]);
    setLoadingHols(false);
  }, []);

  useEffect(() => {
    if (selectedCal) loadHolidays(selectedCal);
  }, [selectedCal, loadHolidays]);

  function resetForm() {
    setForm({ ...EMPTY_HOLIDAY, calendar_id: selectedCal });
    setFormErrors({});
  }

  function startEdit(h: Holiday) {
    setForm({ ...h });
    setFormErrors({});
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const errs: Record<string, string> = {};
    if (!selectedCal)            errs.cal  = 'Select a calendar first.';
    if (!form.holiday_date)      errs.date = 'Date is required.';
    if (!form.holiday_name.trim()) errs.name = 'Name is required.';
    if (!form.holiday_code.trim()) errs.code = 'Code is required.';
    if (Object.keys(errs).length) { setFormErrors(errs); return; }
    setFormErrors({});
    setSaving(true);

    const payload = {
      ...(form.id ? { id: form.id } : {}),
      calendar_id:  selectedCal,
      holiday_date: form.holiday_date,
      holiday_name: form.holiday_name.trim(),
      holiday_code: form.holiday_code.trim().toUpperCase(),
    };

    const { data, error: rpcErr } = await supabase.rpc('upsert_holiday', { p_data: payload });
    setSaving(false);

    if (rpcErr || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? rpcErr?.message ?? 'Unknown error.' });
      return;
    }
    await loadHolidays(selectedCal);
    resetForm();
  }

  async function confirmDelete() {
    const h = deleteModal.holiday!;
    setDeleteModal({ open: false, holiday: null });
    const { error: err } = await supabase.from('time_holidays').delete().eq('id', h.id);
    if (err) setInfoModal({ open: true, title: 'Cannot Delete', message: err.message });
    else await loadHolidays(selectedCal);
  }

  const activeCal = calendars.find(c => c.id === selectedCal);

  return (
    <div className="ar-panel">
      <h2 className="page-title">Holidays</h2>
      <p className="page-subtitle">
        Add and manage individual holidays within each calendar. One holiday per date per calendar.
      </p>

      {error && <ErrorBanner message={error} onRetry={() => loadHolidays(selectedCal)} />}

      {/* ── Calendar selector ───────────────────────────────────────────────── */}
      <div className="rd-form-card" style={{ marginBottom: 20 }}>
        {loadingCals ? (
          <div style={{ color: '#9CA3AF', fontSize: 13 }}>
            <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading calendars…
          </div>
        ) : calendars.length === 0 ? (
          <div style={{ color: '#9CA3AF', fontSize: 13 }}>
            No active holiday calendars found. Create one on the <strong>Holiday Calendars</strong> page first.
          </div>
        ) : (
          <div className="form-group" style={{ maxWidth: 360, marginBottom: 0 }}>
            <label>Calendar</label>
            <select value={selectedCal} onChange={e => { setSelectedCal(e.target.value); resetForm(); }}>
              {calendars.map(c => (
                <option key={c.id} value={c.id}>
                  {c.name}{c.country_code ? ` (${c.country_code})` : ''}
                </option>
              ))}
            </select>
          </div>
        )}
      </div>

      {/* ── Form card ───────────────────────────────────────────────────────── */}
      {selectedCal && (
        <div className="rd-form-card" style={{ marginBottom: 28 }}>
          <h3 style={{ fontSize: 14, fontWeight: 600, color: '#374151', marginBottom: 16 }}>
            {form.id ? 'Edit Holiday' : `Add Holiday to ${activeCal?.name ?? ''}`}
          </h3>
          <form onSubmit={handleSubmit}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr 1fr', gap: 12, marginBottom: 16 }}>
              <div className={`form-group${formErrors.date ? ' form-group--error' : ''}`}>
                <label>Date</label>
                <input
                  type="date"
                  value={form.holiday_date}
                  onChange={e => { setForm(p => ({ ...p, holiday_date: e.target.value })); setFormErrors(p => ({ ...p, date: '' })); }}
                />
                {formErrors.date && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.date}</small>}
              </div>

              <div className={`form-group${formErrors.name ? ' form-group--error' : ''}`}>
                <label>Holiday Name</label>
                <input
                  type="text" placeholder="e.g. Eid Al-Fitr"
                  value={form.holiday_name}
                  onChange={e => { setForm(p => ({ ...p, holiday_name: e.target.value })); setFormErrors(p => ({ ...p, name: '' })); }}
                />
                {formErrors.name && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.name}</small>}
              </div>

              <div className={`form-group${formErrors.code ? ' form-group--error' : ''}`}>
                <label>Code</label>
                <input
                  type="text" placeholder="e.g. EID_FTR" style={{ textTransform: 'uppercase' }}
                  value={form.holiday_code}
                  onChange={e => { setForm(p => ({ ...p, holiday_code: e.target.value })); setFormErrors(p => ({ ...p, code: '' })); }}
                />
                {formErrors.code && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.code}</small>}
              </div>
            </div>

            <div className="rd-form-actions">
              <button type="submit" className="btn-add" disabled={saving}>
                {saving
                  ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                  : form.id
                    ? <><i className="fa-solid fa-floppy-disk" /> Update Holiday</>
                    : <><i className="fa-solid fa-plus" /> Add Holiday</>
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
      )}

      {/* ── Holidays list ───────────────────────────────────────────────────── */}
      {selectedCal && (
        loadingHols ? (
          <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 32 }}>
            <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
          </div>
        ) : holidays.length === 0 ? (
          <div style={{ color: '#D1D5DB', fontSize: 13, padding: '12px 0' }}>
            No holidays in this calendar yet.
          </div>
        ) : (
          <div className="er-table-wrap">
            <table className="er-table">
              <thead>
                <tr>
                  <th>#</th>
                  <th>Date</th>
                  <th>Holiday Name</th>
                  <th>Code</th>
                  <th style={{ textAlign: 'right' }}>Action</th>
                </tr>
              </thead>
              <tbody>
                {holidays.map((h, i) => (
                  <tr key={h.id}>
                    <td>{i + 1}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>{formatDate(h.holiday_date)}</td>
                    <td><strong>{h.holiday_name}</strong></td>
                    <td><code style={{ background: '#F3F4F6', padding: '2px 6px', borderRadius: 4, fontSize: 12 }}>{h.holiday_code}</code></td>
                    <td style={{ textAlign: 'right' }} className="rd-actions">
                      <button className="rd-btn-edit-val" title="Edit" onClick={() => startEdit(h)}>
                        <i className="fa-solid fa-pen-to-square" />
                      </button>
                      <button className="rd-btn-del-val" title="Delete"
                        onClick={() => setDeleteModal({ open: true, holiday: h })}>
                        <i className="fa-solid fa-trash" />
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )
      )}

      <ConfirmationModal
        isOpen={deleteModal.open}
        title="Delete Holiday"
        message={`Delete "${deleteModal.holiday?.holiday_name ?? ''}" on ${formatDate(deleteModal.holiday?.holiday_date ?? '')}?`}
        confirmText="Delete"
        cancelText="Cancel"
        onConfirm={confirmDelete}
        onCancel={() => setDeleteModal({ open: false, holiday: null })}
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
