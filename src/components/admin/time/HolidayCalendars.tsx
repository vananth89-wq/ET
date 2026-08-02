/**
 * HolidayCalendars — Manage named holiday calendars.
 *
 * Each calendar (e.g. "India 2026", "UK Public Holidays") can have holidays
 * assigned from the global holiday pool (created on the Holidays page).
 *
 * Expanding a calendar shows its assigned holidays and lets you
 * add/remove from the pool.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface Calendar {
  id:           string;
  name:         string;
  code:         string;
  country_code: string | null;
  is_active:    boolean;
}

interface Holiday {
  id:           string;
  holiday_date: string;
  holiday_name: string;
  holiday_code: string;
  country_code: string | null;
}

interface AssignedHoliday extends Holiday {
  assigned_at: string;
}

interface CalForm {
  id:           string | null;
  name:         string;
  code:         string;
  country_code: string;
  is_active:    boolean;
}

const BLANK_CAL: CalForm = { id: null, name: '', code: '', country_code: '', is_active: true };

function fmtDate(d: string): string {
  if (!d) return '';
  const dt = new Date(d + 'T00:00:00');
  return dt.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

function toCode(name: string): string {
  return name.trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').slice(0, 20);
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function HolidayCalendars() {
  const [calendars,    setCalendars]   = useState<Calendar[]>([]);
  const [loading,      setLoading]     = useState(true);
  const [error,        setError]       = useState<string | null>(null);

  // Calendar CRUD
  const [calForm,      setCalForm]     = useState<CalForm>(BLANK_CAL);
  const [calFormOpen,  setCalFormOpen] = useState(false);
  const [calSaving,    setCalSaving]   = useState(false);
  const [deleteCalId,  setDeleteCalId] = useState<string | null>(null);
  const [deleting,     setDeleting]    = useState(false);

  // Expanded calendar (holidays panel)
  const [expandedId,   setExpandedId]  = useState<string | null>(null);
  const [assigned,     setAssigned]    = useState<AssignedHoliday[]>([]);
  const [allHolidays,  setAllHolidays] = useState<Holiday[]>([]);
  const [panelLoading, setPanelLoading] = useState(false);
  const [assigning,    setAssigning]   = useState(false);

  const [infoModal, setInfoModal] = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('time_holiday_calendars')
      .select('id, name, code, country_code, is_active')
      .order('name');
    if (err) { setError(err.message); setLoading(false); return; }
    setCalendars(data ?? []);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  // Load panel data when a calendar is expanded
  const loadPanel = useCallback(async (calId: string) => {
    setPanelLoading(true);
    const [assignedRes, allRes] = await Promise.all([
      supabase
        .from('time_calendar_holidays')
        .select('holiday_id, assigned_at, time_holidays!inner(id, holiday_date, holiday_name, holiday_code, country_code)')
        .eq('calendar_id', calId)
        .order('assigned_at'),
      supabase
        .from('time_holidays')
        .select('id, holiday_date, holiday_name, holiday_code, country_code')
        .order('holiday_date'),
    ]);
    if (assignedRes.error) {
      setInfoModal({ open: true, title: 'Error', message: assignedRes.error.message });
    } else {
      setAssigned(
        (assignedRes.data ?? []).map((r: any) => ({
          ...r.time_holidays,
          assigned_at: r.assigned_at,
        }))
      );
    }
    setAllHolidays(allRes.data ?? []);
    setPanelLoading(false);
  }, []);

  function toggleExpand(id: string) {
    if (expandedId === id) {
      setExpandedId(null);
    } else {
      setExpandedId(id);
      loadPanel(id);
    }
  }

  // ── Calendar form ────────────────────────────────────────────────────────

  function openNewCal() {
    setCalForm(BLANK_CAL);
    setCalFormOpen(true);
  }

  function openEditCal(c: Calendar) {
    setCalForm({
      id: c.id, name: c.name, code: c.code,
      country_code: c.country_code ?? '', is_active: c.is_active,
    });
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
    setCalForm(BLANK_CAL);
    await load();
  }

  async function handleCalDelete(id: string) {
    setDeleting(true);
    const { data, error: err } = await supabase.rpc('upsert_holiday_calendar', {
      p_data: { id, _delete: true },
    });
    // Fallback: direct delete if RPC doesn't support _delete
    if (err || (data && !data.ok)) {
      const { error: delErr } = await supabase.from('time_holiday_calendars').delete().eq('id', id);
      if (delErr) {
        setInfoModal({ open: true, title: 'Error', message: delErr.message });
        setDeleting(false);
        return;
      }
    }
    setDeleting(false);
    setDeleteCalId(null);
    if (expandedId === id) setExpandedId(null);
    await load();
  }

  // ── Holiday assignment ───────────────────────────────────────────────────

  const assignedIds = new Set(assigned.map(h => h.id));
  const unassigned = allHolidays.filter(h => !assignedIds.has(h.id));

  async function handleAssign(holidayId: string) {
    if (!expandedId) return;
    setAssigning(true);
    const { data, error: err } = await supabase.rpc('assign_holiday_to_calendar', {
      p_calendar_id: expandedId,
      p_holiday_id:  holidayId,
    });
    setAssigning(false);
    if (err || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? err?.message ?? 'Unknown error.' });
      return;
    }
    await loadPanel(expandedId);
  }

  async function handleUnassign(holidayId: string) {
    if (!expandedId) return;
    const { data, error: err } = await supabase.rpc('unassign_holiday_from_calendar', {
      p_calendar_id: expandedId,
      p_holiday_id:  holidayId,
    });
    if (err || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? err?.message ?? 'Unknown error.' });
      return;
    }
    await loadPanel(expandedId);
  }

  // ────────────────────────────────────────────────────────────────────────────

  return (
    <div className="ar-panel">
      <h2 className="page-title">Holiday Calendars</h2>
      <p className="page-subtitle">
        Create named holiday calendars (e.g. by country or office), then assign holidays from the global
        <strong> Holidays</strong> pool.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

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
                marginBottom: 12, overflow: 'hidden',
                opacity: cal.is_active ? 1 : 0.6,
              }}>
                {/* Calendar header row */}
                <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '14px 16px', cursor: 'pointer' }}
                  onClick={() => toggleExpand(cal.id)}>
                  <i className={`fa-solid ${isExpanded ? 'fa-chevron-down' : 'fa-chevron-right'}`}
                    style={{ fontSize: 11, color: '#9CA3AF', width: 12 }} />
                  <div style={{ flex: 1 }}>
                    <span style={{ fontWeight: 600, fontSize: 14, color: '#111827' }}>{cal.name}</span>
                    {cal.country_code && (
                      <span style={{ marginLeft: 8, background: '#EFF6FF', color: '#1D4ED8', borderRadius: 20, padding: '2px 8px', fontSize: 11, fontWeight: 600 }}>
                        {cal.country_code}
                      </span>
                    )}
                    <code style={{ marginLeft: 8, background: '#F3F4F6', padding: '1px 6px', borderRadius: 4, fontSize: 11, color: '#6B7280' }}>
                      {cal.code}
                    </code>
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

                {/* Expanded holiday assignment panel */}
                {isExpanded && (
                  <div style={{ borderTop: '1px solid #F3F4F6', padding: '16px' }}>
                    {panelLoading ? (
                      <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 16 }}>
                        <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading holidays…
                      </div>
                    ) : (
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>

                        {/* Assigned holidays */}
                        <div>
                          <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', marginBottom: 8, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                            Assigned ({assigned.length})
                          </div>
                          {assigned.length === 0 ? (
                            <div style={{ color: '#9CA3AF', fontSize: 12, padding: '8px 0' }}>No holidays assigned yet.</div>
                          ) : (
                            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                              {assigned.map(h => (
                                <div key={h.id} style={{
                                  display: 'flex', alignItems: 'center', gap: 8,
                                  background: '#F0FDF4', border: '1px solid #BBF7D0',
                                  borderRadius: 6, padding: '6px 10px',
                                }}>
                                  <span style={{ fontSize: 12, color: '#166534', flex: 1 }}>
                                    <strong>{fmtDate(h.holiday_date)}</strong> — {h.holiday_name}
                                  </span>
                                  <button
                                    style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#DC2626', fontSize: 11, padding: '2px 4px' }}
                                    onClick={() => handleUnassign(h.id)} title="Remove"
                                  ><i className="fa-solid fa-xmark" /></button>
                                </div>
                              ))}
                            </div>
                          )}
                        </div>

                        {/* Available to add */}
                        <div>
                          <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', marginBottom: 8, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                            Available to add ({unassigned.length})
                          </div>
                          {unassigned.length === 0 ? (
                            <div style={{ color: '#9CA3AF', fontSize: 12, padding: '8px 0' }}>
                              All holidays are assigned, or create more on the <strong>Holidays</strong> page.
                            </div>
                          ) : (
                            <div style={{ display: 'flex', flexDirection: 'column', gap: 4, maxHeight: 300, overflowY: 'auto' }}>
                              {unassigned.map(h => (
                                <div key={h.id} style={{
                                  display: 'flex', alignItems: 'center', gap: 8,
                                  background: '#F9FAFB', border: '1px solid #E5E7EB',
                                  borderRadius: 6, padding: '6px 10px',
                                }}>
                                  <span style={{ fontSize: 12, color: '#374151', flex: 1 }}>
                                    <strong>{fmtDate(h.holiday_date)}</strong> — {h.holiday_name}
                                    {h.country_code && <span style={{ color: '#9CA3AF', marginLeft: 4 }}>({h.country_code})</span>}
                                  </span>
                                  <button
                                    style={{ background: '#0369A1', border: 'none', borderRadius: 4, padding: '3px 8px', cursor: 'pointer', color: '#fff', fontSize: 11 }}
                                    onClick={() => handleAssign(h.id)} disabled={assigning} title="Add to calendar"
                                  ><i className="fa-solid fa-plus" /></button>
                                </div>
                              ))}
                            </div>
                          )}
                        </div>
                      </div>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* ── Calendar Form Modal ───────────────────────────────────────────────── */}
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
                  type="text" placeholder="e.g. India — National Holidays 2026"
                  value={calForm.name}
                  onChange={e => setCalForm(f => ({
                    ...f, name: e.target.value,
                    code: f.id ? f.code : toCode(e.target.value),
                  }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%' }}
                />
              </div>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Code <span style={{ color: '#DC2626' }}>*</span></label>
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

      {/* ── Delete Calendar Confirm ───────────────────────────────────────────── */}
      {deleteCalId && (
        <div className="modal-overlay" onClick={() => setDeleteCalId(null)}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-triangle-exclamation modal-icon" style={{ color: '#DC2626' }} />
              <h3>Delete Calendar?</h3>
            </div>
            <div className="modal-body">
              This will delete the calendar and remove all its holiday assignments. The holidays themselves will remain in the global pool.
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
