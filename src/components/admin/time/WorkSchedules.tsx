/**
 * WorkSchedules — Admin page for managing work schedule definitions.
 *
 * Layout:
 *  - Left: list of existing schedules (active/inactive toggle)
 *  - Right: form to create/edit a schedule (header fields + 7-row day table)
 *
 * Each schedule has:
 *  - name, code, start_day_of_week (determines day label order)
 *  - 7 lines: day_number 1–7 mapped to day labels, each with planned hours (hh:mm input)
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';
import ConfirmationModal from '../../shared/ConfirmationModal';

// ─── Types ────────────────────────────────────────────────────────────────────

interface ScheduleLine {
  day_number:      number;   // 1–7
  planned_minutes: number;   // 0 = off
}

interface WorkSchedule {
  id:                string;
  name:              string;
  code:              string;
  start_day_of_week: number; // 0=Sun … 6=Sat
  is_active:         boolean;
  created_at:        string | null;
  updated_at:        string | null;
  creator:           any;
  lines:             ScheduleLine[];
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

function creatorName(creator: any): string {
  const emp = Array.isArray(creator) ? creator[0]?.employees : creator?.employees;
  return (Array.isArray(emp) ? emp[0]?.name : emp?.name) ?? '';
}

/** Returns ordered day names starting from start_day. */
function getOrderedDays(startDay: number): string[] {
  return Array.from({ length: 7 }, (_, i) => DAY_NAMES[(startDay + i) % 7]);
}

/** Convert decimal hours string → minutes (e.g. "8" → 480, "7.5" → 450) */
function hoursToMinutes(val: string): number {
  const h = parseFloat(val);
  return isNaN(h) || h <= 0 ? 0 : Math.round(h * 60);
}

/** Convert minutes → decimal hours string (e.g. 480 → "8", 450 → "7.5") */
function minutesToHours(mins: number): string {
  if (!mins) return '';
  const h = mins / 60;
  return Number.isInteger(h) ? String(h) : h.toFixed(1);
}

/** Convert minutes → display label e.g. "8h" or "7h 30m" */
function minutesToHhmm(mins: number): string {
  if (!mins) return 'Off';
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

/** Build default 7 lines (Mon–Fri 8h, Sat–Sun off) relative to startDay */
function buildDefaultLines(startDay: number): ScheduleLine[] {
  return Array.from({ length: 7 }, (_, i) => {
    const actualDay = (startDay + i) % 7;
    const isWeekend = actualDay === 0 || actualDay === 6; // Sun or Sat
    return { day_number: i + 1, planned_minutes: isWeekend ? 0 : 480 };
  });
}

// ─── Empty form state ─────────────────────────────────────────────────────────

function emptyForm(startDay = 0): WorkSchedule {
  return {
    id: '',
    name: '',
    code: '',
    start_day_of_week: startDay,
    is_active: true,
    created_at: null,
    updated_at: null,
    creator: null,
    lines: buildDefaultLines(startDay),
  };
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function WorkSchedules() {
  const [schedules, setSchedules] = useState<WorkSchedule[]>([]);
  const [loading,   setLoading]   = useState(true);
  const [error,     setError]     = useState<string | null>(null);
  const [form,      setForm]      = useState<WorkSchedule>(emptyForm());
  const [saving,    setSaving]    = useState(false);
  const [formErrors, setFormErrors] = useState<Record<string, string>>({});
  const [deleteModal, setDeleteModal] = useState<{ open: boolean; schedule: WorkSchedule | null }>({ open: false, schedule: null });
  const [infoModal, setInfoModal] = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  // ── Load ─────────────────────────────────────────────────────────────────

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data: hdrs, error: e1 } = await supabase
      .from('time_work_schedules')
      .select('id, name, code, start_day_of_week, is_active, created_at, updated_at, creator:profiles!created_by(employees!employee_id(name))')
      .order('name');
    if (e1) { setError(e1.message); setLoading(false); return; }

    const { data: lines, error: e2 } = await supabase
      .from('time_work_schedule_lines')
      .select('work_schedule_id, day_number, planned_minutes')
      .order('day_number');
    if (e2) { setError(e2.message); setLoading(false); return; }

    const lineMap = new Map<string, ScheduleLine[]>();
    for (const l of lines ?? []) {
      if (!lineMap.has(l.work_schedule_id)) lineMap.set(l.work_schedule_id, []);
      lineMap.get(l.work_schedule_id)!.push({ day_number: l.day_number, planned_minutes: l.planned_minutes });
    }

    setSchedules((hdrs ?? []).map(h => ({
      ...h,
      lines: lineMap.get(h.id) ?? buildDefaultLines(h.start_day_of_week),
    })));
    setLoading(false);
  }, []);

  useEffect(() => { const t = setTimeout(load, 0); return () => clearTimeout(t); }, [load]);

  // ── Form handlers ─────────────────────────────────────────────────────────

  function resetForm() {
    setForm(emptyForm());
    setFormErrors({});
  }

  function startEdit(s: WorkSchedule) {
    setForm({ ...s, lines: s.lines.map(l => ({ ...l })) });
    setFormErrors({});
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function handleStartDayChange(val: number) {
    // When start day changes, rebuild lines but preserve planned_minutes values
    setForm(prev => {
      const existing = [...prev.lines];
      const newLines = Array.from({ length: 7 }, (_, i) => ({
        day_number: i + 1,
        planned_minutes: existing[i]?.planned_minutes ?? 0,
      }));
      return { ...prev, start_day_of_week: val, lines: newLines };
    });
  }

  function setLineMinutes(dayNumber: number, val: string) {
    const mins = hoursToMinutes(val);
    setForm(prev => ({
      ...prev,
      lines: prev.lines.map(l =>
        l.day_number === dayNumber ? { ...l, planned_minutes: mins } : l,
      ),
    }));
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
      name:              form.name.trim(),
      code:              form.code.trim(),
      start_day_of_week: form.start_day_of_week,
      is_active:         form.is_active,
      lines:             form.lines,
    };

    const { data, error: rpcErr } = await supabase.rpc('upsert_work_schedule', { p_data: payload });
    setSaving(false);

    if (rpcErr || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? rpcErr?.message ?? 'Unknown error.' });
      return;
    }
    await load();
    resetForm();
  }

  async function confirmDelete() {
    const s = deleteModal.schedule!;
    setDeleteModal({ open: false, schedule: null });
    const { error: e } = await supabase.from('time_work_schedules').delete().eq('id', s.id);
    if (e) setInfoModal({ open: true, title: 'Error', message: e.message });
    else await load();
  }

  // ── Render ───────────────────────────────────────────────────────────────

  const orderedDays = getOrderedDays(form.start_day_of_week);

  return (
    <div className="ar-panel">
      <h2 className="page-title">Work Schedules</h2>
      <p className="page-subtitle">
        Define named work schedules with planned hours per day. Assign schedules to employees
        in Employment Info. Schedules are snapshotted onto timesheets at creation.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 24, alignItems: 'start' }}>

        {/* ── Left: schedule list ──────────────────────────────────────────── */}
        <div>
          <h3 style={{ fontSize: 14, fontWeight: 600, color: '#374151', marginBottom: 12 }}>
            Existing Schedules
          </h3>

          {loading ? (
            <div style={{ color: '#9CA3AF', padding: 20, textAlign: 'center' }}>
              <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
            </div>
          ) : schedules.length === 0 ? (
            <div style={{ color: '#9CA3AF', padding: 20, textAlign: 'center' }}>No schedules yet.</div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {schedules.map(s => (
                <div key={s.id} style={{
                  border: '1px solid #E5E7EB', borderRadius: 8, padding: '12px 16px',
                  background: form.id === s.id ? '#EFF6FF' : '#FFFFFF',
                }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                    <div>
                      <div style={{ fontWeight: 600, fontSize: 14 }}>{s.name}</div>
                      <code style={{ fontSize: 12, color: '#6B7280', background: '#F3F4F6', padding: '1px 6px', borderRadius: 4 }}>
                        {s.code}
                      </code>
                      <span style={{ marginLeft: 8, fontSize: 12, color: '#9CA3AF' }}>
                        Starts {DAY_NAMES[s.start_day_of_week]}
                      </span>
                      <span style={{ marginLeft: 12, fontSize: 11, color: '#9CA3AF' }}>
                        Created {s.created_at ? new Date(s.created_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '—'}
                        {' · '}Updated {s.updated_at ? new Date(s.updated_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '—'}
                        {creatorName(s.creator) ? ` · ${creatorName(s.creator)}` : ''}
                      </span>
                    </div>
                    <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                      {!s.is_active && (
                        <span style={{ fontSize: 11, background: '#FEF3C7', color: '#92400E', padding: '2px 8px', borderRadius: 10 }}>
                          Inactive
                        </span>
                      )}
                      <button className="rd-btn-edit-val" title="Edit" onClick={() => startEdit(s)}>
                        <i className="fa-solid fa-pen-to-square" />
                      </button>
                      <button className="rd-btn-del-val" title="Delete"
                        onClick={() => setDeleteModal({ open: true, schedule: s })}>
                        <i className="fa-solid fa-trash" />
                      </button>
                    </div>
                  </div>

                  {/* Day summary mini-row */}
                  <div style={{ marginTop: 8, display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                    {getOrderedDays(s.start_day_of_week).map((day, i) => {
                      const line = s.lines.find(l => l.day_number === i + 1);
                      const mins = line?.planned_minutes ?? 0;
                      return (
                        <span key={day} style={{
                          fontSize: 11, padding: '2px 6px', borderRadius: 4,
                          background: mins === 0 ? '#F3F4F6' : '#DBEAFE',
                          color: mins === 0 ? '#9CA3AF' : '#1E40AF',
                        }}>
                          {day.slice(0, 3)} {mins === 0 ? 'Off' : minutesToHhmm(mins)}
                        </span>
                      );
                    })}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* ── Right: form ─────────────────────────────────────────────────── */}
        <div className="rd-form-card">
          <h3 style={{ fontSize: 14, fontWeight: 600, color: '#374151', marginBottom: 16 }}>
            {form.id ? 'Edit Schedule' : 'New Schedule'}
          </h3>

          <form onSubmit={handleSubmit}>
            {/* Header fields */}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              <div className={`form-group${formErrors.name ? ' form-group--error' : ''}`}>
                <label>Name</label>
                <input
                  type="text" placeholder="e.g. Standard 5-Day"
                  value={form.name}
                  onChange={e => { setForm(p => ({ ...p, name: e.target.value })); setFormErrors(p => ({ ...p, name: '' })); }}
                />
                {formErrors.name && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.name}</small>}
              </div>

              <div className={`form-group${formErrors.code ? ' form-group--error' : ''}`}>
                <label>Code</label>
                <input
                  type="text" placeholder="e.g. STD5" style={{ textTransform: 'uppercase' }}
                  value={form.code}
                  onChange={e => { setForm(p => ({ ...p, code: e.target.value })); setFormErrors(p => ({ ...p, code: '' })); }}
                />
                {formErrors.code && <small className="field-error"><i className="fa-solid fa-circle-exclamation" /> {formErrors.code}</small>}
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
              <div className="form-group">
                <label>Week Starts On</label>
                <select value={form.start_day_of_week} onChange={e => handleStartDayChange(Number(e.target.value))}>
                  {DAY_NAMES.map((d, i) => <option key={i} value={i}>{d}</option>)}
                </select>
              </div>

              <div className="form-group" style={{ paddingTop: 24 }}>
                <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer' }}>
                  <input
                    type="checkbox" checked={form.is_active}
                    onChange={e => setForm(p => ({ ...p, is_active: e.target.checked }))}
                  />
                  Active
                </label>
              </div>
            </div>

            {/* 7-row day table */}
            <div style={{ marginBottom: 20 }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', marginBottom: 8, textTransform: 'uppercase' }}>
                Daily Hours
              </div>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                <thead>
                  <tr style={{ background: '#F9FAFB' }}>
                    <th style={{ textAlign: 'left', padding: '6px 10px', color: '#6B7280', fontSize: 11, fontWeight: 600 }}>DAY</th>
                    <th style={{ textAlign: 'left', padding: '6px 10px', color: '#6B7280', fontSize: 11, fontWeight: 600 }}>PLANNED HOURS</th>
                    <th style={{ textAlign: 'center', padding: '6px 10px', color: '#6B7280', fontSize: 11, fontWeight: 600 }}>OFF</th>
                  </tr>
                </thead>
                <tbody>
                  {orderedDays.map((dayName, i) => {
                    const line = form.lines.find(l => l.day_number === i + 1) ?? { day_number: i + 1, planned_minutes: 0 };
                    return (
                      <tr key={dayName} style={{ borderBottom: '1px solid #F3F4F6' }}>
                        <td style={{ padding: '6px 10px', fontWeight: 500 }}>{dayName}</td>
                        <td style={{ padding: '4px 10px' }}>
                          <input
                            type="number"
                            min="0" max="24" step="0.5"
                            placeholder="0"
                            value={minutesToHours(line.planned_minutes)}
                            disabled={line.planned_minutes === 0}
                            onChange={e => setLineMinutes(line.day_number, e.target.value)}
                            style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid #D1D5DB', fontSize: 13, width: 80 }}
                          />
                        </td>
                        <td style={{ padding: '4px 10px', textAlign: 'center' }}>
                          <input
                            type="checkbox"
                            checked={line.planned_minutes === 0}
                            onChange={e => setLineMinutes(line.day_number, e.target.checked ? '0' : '8')}
                          />
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>

            {/* Actions */}
            <div className="rd-form-actions">
              <button type="submit" className="btn-add" disabled={saving}>
                {saving
                  ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                  : form.id
                    ? <><i className="fa-solid fa-floppy-disk" /> Update Schedule</>
                    : <><i className="fa-solid fa-plus" /> Add Schedule</>
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
      </div>

      {/* ── Modals ───────────────────────────────────────────────────────── */}
      <ConfirmationModal
        isOpen={deleteModal.open}
        title="Delete Work Schedule"
        message={`Are you sure you want to delete "${deleteModal.schedule?.name ?? ''}"?`}
        warning="This cannot be undone. Employees currently assigned this schedule will retain it until reassigned."
        confirmText="Delete"
        cancelText="Cancel"
        onConfirm={confirmDelete}
        onCancel={() => setDeleteModal({ open: false, schedule: null })}
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
