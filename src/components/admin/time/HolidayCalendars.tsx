/**
 * HolidayCalendars — Named holiday calendars with inline date entries.
 *
 * Header: code + name (assigned to employees).
 * Entries (child rows): date + holiday (picked from the global pool).
 *
 * Expand a calendar to manage its entries inline — add rows, pick date +
 * holiday code, delete rows.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface Calendar {
  id:           string;
  code:         string;
  name:         string;
  country_code: string | null;
  is_active:    boolean;
}

interface CalendarEntry {
  id:           string;
  entry_date:   string;
  holiday_id:   string;
  holiday_code: string;
  holiday_name: string;
}

interface HolidayOption {
  id:           string;
  holiday_code: string;
  holiday_name: string;
}

interface CalForm {
  id:           string | null;
  code:         string;
  name:         string;
  country_code: string;
  is_active:    boolean;
}

const BLANK_CAL: CalForm = { id: null, code: '', name: '', country_code: '', is_active: true };

function fmtDate(d: string): string {
  if (!d) return '';
  return new Date(d + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

function toCode(name: string): string {
  return name.trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').slice(0, 20);
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function HolidayCalendars() {
  const [calendars,     setCalendars]    = useState<Calendar[]>([]);
  const [loading,       setLoading]      = useState(true);
  const [error,         setError]        = useState<string | null>(null);
  const [holidayPool,   setHolidayPool]  = useState<HolidayOption[]>([]);

  // Calendar CRUD modal
  const [calForm,       setCalForm]      = useState<CalForm>(BLANK_CAL);
  const [calFormOpen,   setCalFormOpen]  = useState(false);
  const [calSaving,     setCalSaving]    = useState(false);
  const [deleteCalId,   setDeleteCalId]  = useState<string | null>(null);
  const [deleting,      setDeleting]     = useState(false);

  // Expanded calendar entries
  const [expandedId,    setExpandedId]   = useState<string | null>(null);
  const [entries,       setEntries]      = useState<CalendarEntry[]>([]);
  const [entriesLoading, setEntriesLoading] = useState(false);

  // New entry row state
  const [newDate,       setNewDate]      = useState('');
  const [newHolidayId,  setNewHolidayId] = useState('');
  const [addingSaving,  setAddingSaving] = useState(false);

  const [infoModal, setInfoModal] = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  // ── Load calendars + holiday pool ────────────────────────────────────────────

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [calRes, holidayRes] = await Promise.all([
      supabase.from('time_holiday_calendars').select('id, code, name, country_code, is_active').order('name'),
      supabase.from('time_holidays').select('id, holiday_code, holiday_name').order('holiday_code'),
    ]);
    if (calRes.error) { setError(calRes.error.message); setLoading(false); return; }
    setCalendars(calRes.data ?? []);
    setHolidayPool(holidayRes.data ?? []);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  // ── Load entries for expanded calendar ────────────────────────────────────────

  const loadEntries = useCallback(async (calId: string) => {
    setEntriesLoading(true);
    const { data, error: err } = await supabase
      .from('time_calendar_entries')
      .select('id, entry_date, holiday_id, time_holidays!inner(holiday_code, holiday_name)')
      .eq('calendar_id', calId)
      .order('entry_date');
    if (err) {
      setInfoModal({ open: true, title: 'Error', message: err.message });
      setEntriesLoading(false);
      return;
    }
    setEntries(
      (data ?? []).map((r: any) => ({
        id:           r.id,
        entry_date:   r.entry_date,
        holiday_id:   r.holiday_id,
        holiday_code: r.time_holidays.holiday_code,
        holiday_name: r.time_holidays.holiday_name,
      }))
    );
    setEntriesLoading(false);
  }, []);

  function toggleExpand(id: string) {
    if (expandedId === id) {
      setExpandedId(null);
      setEntries([]);
    } else {
      setExpandedId(id);
      setNewDate('');
      setNewHolidayId(holidayPool[0]?.id ?? '');
      loadEntries(id);
    }
  }

  // ── Calendar form ─────────────────────────────────────────────────────────────

  function openNewCal() { setCalForm(BLANK_CAL); setCalFormOpen(true); }

  function openEditCal(c: Calendar) {
    setCalForm({ id: c.id, code: c.code, name: c.name, country_code: c.country_code ?? '', is_active: c.is_active });
    setCalFormOpen(true);
  }

  async function handleCalSave() {
    if (!calForm.name.trim() || !calForm.code.trim()) {
      setInfoModal({ open: true, title: 'Validation', message: 'Name and code are required.' });
      return;
    }
    setCalSaving(true);
    const { data, error: err } = await supabase.rpc('upsert_holiday_calendar', {
      p_data: {
        id:           calForm.id,
        name:         calForm.name.trim(),
        code:         calForm.code.toUpperCase().trim(),
        country_code: calForm.country_code.trim() || null,
        is_active:    calForm.is_active,
      },
    });
    setCalSaving(false);
    if (err || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? err?.message ?? 'Unknown error.' });
      return;
    }
    setCalFormOpen(false);
    await load();
  }

  async function handleCalDelete(id: string) {
    setDeleting(true);
    const { error: err } = await supabase.from('time_holiday_calendars').delete().eq('id', id);
    setDeleting(false);
    if (err) { setInfoModal({ open: true, title: 'Error', message: err.message }); return; }
    setDeleteCalId(null);
    if (expandedId === id) { setExpandedId(null); setEntries([]); }
    await load();
  }

  // ── Entry management ──────────────────────────────────────────────────────────

  async function handleAddEntry() {
    if (!expandedId || !newDate || !newHolidayId) {
      setInfoModal({ open: true, title: 'Validation', message: 'Date and holiday are required.' });
      return;
    }
    setAddingSaving(true);
    const { data, error: err } = await supabase.rpc('upsert_calendar_entry', {
      p_calendar_id: expandedId,
      p_entry_date:  newDate,
      p_holiday_id:  newHolidayId,
    });
    setAddingSaving(false);
    if (err || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? err?.message ?? 'Unknown error.' });
      return;
    }
    setNewDate('');
    setNewHolidayId(holidayPool[0]?.id ?? '');
    await loadEntries(expandedId);
  }

  async function handleDeleteEntry(entryId: string) {
    const { data, error: err } = await supabase.rpc('delete_calendar_entry', { p_entry_id: entryId });
    if (err || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? err?.message ?? 'Unknown error.' });
      return;
    }
    if (expandedId) await loadEntries(expandedId);
  }

  // ────────────────────────────────────────────────────────────────────────────

  return (
    <div className="ar-panel">
      <h2 className="page-title">Holiday Calendars</h2>
      <p className="page-subtitle">
        Create named holiday calendars (identified by code) and assign holidays with specific dates.
        Calendar codes are assigned to employees to determine their public holidays.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {holidayPool.length === 0 && !loading && (
        <div style={{ marginBottom: 16, padding: '10px 14px', background: '#FFF7ED', border: '1px solid #FED7AA', borderRadius: 8, fontSize: 13, color: '#92400E' }}>
          <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 6 }} />
          No holidays in the pool yet. <a href="/admin/time/holidays" style={{ color: '#0369A1', textDecoration: 'underline' }}>Create holidays</a> first, then assign them here.
        </div>
      )}

      <div style={{ marginBottom: 16, display: 'flex', justifyContent: 'flex-end' }}>
        <button className="btn-add" onClick={openNewCal}>
          <i className="fa-solid fa-plus" style={{ marginRight: 6 }} />New Calendar
        </button>
      </div>

      {loading ? (
        <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 32 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
        </div>
      ) : calendars.length === 0 ? (
        <div style={{ color: '#9CA3AF', fontSize: 13 }}>No holiday calendars yet. Create one above.</div>
      ) : (
        <div>
          {calendars.map(cal => {
            const isExpanded = expandedId === cal.id;
            return (
              <div key={cal.id} style={{
                background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
                marginBottom: 12, overflow: 'hidden', opacity: cal.is_active ? 1 : 0.6,
              }}>
                {/* ── Calendar header row ─────────────────────────────────────── */}
                <div
                  style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '14px 16px', cursor: 'pointer' }}
                  onClick={() => toggleExpand(cal.id)}
                >
                  <i className={`fa-solid ${isExpanded ? 'fa-chevron-down' : 'fa-chevron-right'}`}
                    style={{ fontSize: 11, color: '#9CA3AF', width: 12 }} />

                  <div style={{ flex: 1 }}>
                    <span style={{ fontWeight: 700, fontSize: 14, color: '#111827' }}>{cal.name}</span>
                    <code style={{ marginLeft: 10, background: '#EFF6FF', color: '#1D4ED8', padding: '2px 8px', borderRadius: 4, fontSize: 12, fontWeight: 600 }}>
                      {cal.code}
                    </code>
                    {cal.country_code && (
                      <span style={{ marginLeft: 8, background: '#F3F4F6', color: '#6B7280', borderRadius: 20, padding: '2px 8px', fontSize: 11 }}>
                        {cal.country_code}
                      </span>
                    )}
                    {!cal.is_active && (
                      <span style={{ marginLeft: 8, background: '#FEF3C7', color: '#92400E', borderRadius: 20, padding: '2px 8px', fontSize: 11 }}>Inactive</span>
                    )}
                  </div>

                  <div style={{ display: 'flex', gap: 6 }} onClick={e => e.stopPropagation()}>
                    <button
                      style={{ background: 'none', border: '1px solid #E5E7EB', borderRadius: 4, padding: '4px 10px', cursor: 'pointer', fontSize: 12, color: '#374151' }}
                      onClick={() => openEditCal(cal)}
                    ><i className="fa-solid fa-pen" style={{ fontSize: 11 }} /></button>
                    <button
                      style={{ background: 'none', border: '1px solid #FEE2E2', borderRadius: 4, padding: '4px 10px', cursor: 'pointer', fontSize: 12, color: '#DC2626' }}
                      onClick={() => setDeleteCalId(cal.id)}
                    ><i className="fa-solid fa-trash" style={{ fontSize: 11 }} /></button>
                  </div>
                </div>

                {/* ── Expanded entries panel ──────────────────────────────────── */}
                {isExpanded && (
                  <div style={{ borderTop: '1px solid #F3F4F6', padding: 16 }}>
                    {entriesLoading ? (
                      <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 16 }}>
                        <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading entries…
                      </div>
                    ) : (
                      <>
                        {/* Entry table */}
                        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13, marginBottom: 12 }}>
                          <thead>
                            <tr style={{ borderBottom: '2px solid #E5E7EB', textAlign: 'left' }}>
                              <th style={{ padding: '6px 10px', color: '#6B7280', fontWeight: 600 }}>Date</th>
                              <th style={{ padding: '6px 10px', color: '#6B7280', fontWeight: 600 }}>Holiday Code</th>
                              <th style={{ padding: '6px 10px', color: '#6B7280', fontWeight: 600 }}>Holiday Name</th>
                              <th style={{ padding: '6px 10px', width: 50 }} />
                            </tr>
                          </thead>
                          <tbody>
                            {entries.length === 0 ? (
                              <tr>
                                <td colSpan={4} style={{ padding: '12px 10px', color: '#9CA3AF', fontSize: 12 }}>
                                  No entries yet. Add one below.
                                </td>
                              </tr>
                            ) : entries.map(e => (
                              <tr key={e.id} style={{ borderBottom: '1px solid #F3F4F6' }}>
                                <td style={{ padding: '8px 10px', whiteSpace: 'nowrap' }}>{fmtDate(e.entry_date)}</td>
                                <td style={{ padding: '8px 10px' }}>
                                  <code style={{ background: '#EFF6FF', color: '#1D4ED8', padding: '2px 6px', borderRadius: 4, fontSize: 12 }}>
                                    {e.holiday_code}
                                  </code>
                                </td>
                                <td style={{ padding: '8px 10px', color: '#374151' }}>{e.holiday_name}</td>
                                <td style={{ padding: '8px 10px' }}>
                                  <button
                                    style={{ background: 'none', border: '1px solid #FEE2E2', borderRadius: 4, padding: '3px 7px', cursor: 'pointer', color: '#DC2626' }}
                                    onClick={() => handleDeleteEntry(e.id)} title="Remove"
                                  ><i className="fa-solid fa-trash" style={{ fontSize: 11 }} /></button>
                                </td>
                              </tr>
                            ))}

                            {/* Add new entry row */}
                            <tr style={{ borderTop: '2px dashed #E5E7EB', background: '#F9FAFB' }}>
                              <td style={{ padding: '8px 10px' }}>
                                <input
                                  type="date" value={newDate}
                                  onChange={e => setNewDate(e.target.value)}
                                  style={{ padding: '5px 8px', borderRadius: 5, border: '1px solid #D1D5DB', fontSize: 13 }}
                                />
                              </td>
                              <td colSpan={2} style={{ padding: '8px 10px' }}>
                                <select
                                  value={newHolidayId}
                                  onChange={e => setNewHolidayId(e.target.value)}
                                  style={{ padding: '5px 8px', borderRadius: 5, border: '1px solid #D1D5DB', fontSize: 13, minWidth: 260 }}
                                >
                                  <option value="">— Select holiday —</option>
                                  {holidayPool.map(h => (
                                    <option key={h.id} value={h.id}>
                                      {h.holiday_code} — {h.holiday_name}
                                    </option>
                                  ))}
                                </select>
                              </td>
                              <td style={{ padding: '8px 10px' }}>
                                <button
                                  className="btn-add"
                                  style={{ padding: '5px 12px', fontSize: 12 }}
                                  onClick={handleAddEntry}
                                  disabled={addingSaving || !newDate || !newHolidayId}
                                >
                                  {addingSaving
                                    ? <i className="fa-solid fa-spinner fa-spin" />
                                    : <><i className="fa-solid fa-plus" style={{ marginRight: 4 }} />Add</>
                                  }
                                </button>
                              </td>
                            </tr>
                          </tbody>
                        </table>

                        <div style={{ fontSize: 12, color: '#9CA3AF' }}>
                          {entries.length} entr{entries.length !== 1 ? 'ies' : 'y'}
                        </div>
                      </>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* ── Calendar Form Modal ────────────────────────────────────────────────── */}
      {calFormOpen && (
        <div className="modal-overlay" onClick={() => setCalFormOpen(false)}>
          <div className="modal-box" style={{ maxWidth: 420 }} onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-calendar-days modal-icon" style={{ color: '#0369A1' }} />
              <h3>{calForm.id ? 'Edit Calendar' : 'New Calendar'}</h3>
            </div>
            <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Name <span style={{ color: '#DC2626' }}>*</span></label>
                <input
                  type="text" placeholder="e.g. India National Holidays 2026"
                  value={calForm.name}
                  onChange={e => setCalForm(f => ({ ...f, name: e.target.value, code: f.id ? f.code : toCode(e.target.value) }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%' }}
                />
              </div>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Code <span style={{ color: '#DC2626' }}>*</span>
                  <span style={{ color: '#9CA3AF', fontWeight: 400, fontSize: 11, marginLeft: 6 }}>Assigned to employees</span>
                </label>
                <input
                  type="text" placeholder="e.g. IN_2026"
                  value={calForm.code}
                  onChange={e => setCalForm(f => ({ ...f, code: e.target.value.toUpperCase() }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%', fontFamily: 'monospace' }}
                />
              </div>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Country Code <span style={{ color: '#9CA3AF', fontWeight: 400 }}>(optional)</span></label>
                <input
                  type="text" placeholder="e.g. IN" maxLength={2}
                  value={calForm.country_code}
                  onChange={e => setCalForm(f => ({ ...f, country_code: e.target.value.toUpperCase() }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: 100 }}
                />
              </div>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, cursor: 'pointer' }}>
                <input type="checkbox" checked={calForm.is_active}
                  onChange={e => setCalForm(f => ({ ...f, is_active: e.target.checked }))} />
                Active
              </label>
            </div>
            <div className="modal-actions">
              <button style={{ background: '#F3F4F6', color: '#374151', border: 'none', borderRadius: 7, padding: '9px 20px', cursor: 'pointer', fontWeight: 500 }}
                onClick={() => setCalFormOpen(false)}>Cancel</button>
              <button className="btn-add" style={{ padding: '9px 24px' }} onClick={handleCalSave} disabled={calSaving}>
                {calSaving ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</> : 'Save'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Delete Calendar Confirm ────────────────────────────────────────────── */}
      {deleteCalId && (
        <div className="modal-overlay" onClick={() => setDeleteCalId(null)}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-triangle-exclamation modal-icon" style={{ color: '#DC2626' }} />
              <h3>Delete Calendar?</h3>
            </div>
            <div className="modal-body">
              This will delete the calendar and all its date entries. The holidays themselves will remain in the pool.
            </div>
            <div className="modal-actions">
              <button style={{ background: '#F3F4F6', color: '#374151', border: 'none', borderRadius: 7, padding: '9px 20px', cursor: 'pointer', fontWeight: 500 }}
                onClick={() => setDeleteCalId(null)}>Cancel</button>
              <button style={{ background: '#DC2626', color: '#fff', border: 'none', borderRadius: 7, padding: '9px 20px', cursor: 'pointer', fontWeight: 500 }}
                onClick={() => handleCalDelete(deleteCalId)} disabled={deleting}>
                {deleting ? 'Deleting…' : 'Delete'}
              </button>
            </div>
          </div>
        </div>
      )}

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
