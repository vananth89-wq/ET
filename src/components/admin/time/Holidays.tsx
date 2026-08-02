/**
 * Holidays — Global pool of holiday definitions.
 *
 * A holiday is a date-independent definition: Code + Name.
 * Dates are set when assigning holidays to a calendar (Holiday Calendars page).
 *
 * Fields: holiday_code (unique, uppercase), holiday_name, audit (created_by, created_at, updated_at).
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface Holiday {
  id:           string;
  holiday_code: string;
  holiday_name: string;
  created_at:   string;
  updated_at:   string;
  profiles:     { full_name: string | null } | null;
}

interface FormState {
  id:           string | null;
  holiday_code: string;
  holiday_name: string;
}

const BLANK: FormState = { id: null, holiday_code: '', holiday_name: '' };

function fmtDateTime(ts: string): string {
  if (!ts) return '—';
  return new Date(ts).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

function toCode(name: string): string {
  return name.trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').slice(0, 30);
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function Holidays() {
  const [holidays,   setHolidays]  = useState<Holiday[]>([]);
  const [loading,    setLoading]   = useState(true);
  const [error,      setError]     = useState<string | null>(null);
  const [search,     setSearch]    = useState('');
  const [form,       setForm]      = useState<FormState>(BLANK);
  const [formOpen,   setFormOpen]  = useState(false);
  const [saving,     setSaving]    = useState(false);
  const [deleteId,   setDeleteId]  = useState<string | null>(null);
  const [deleting,   setDeleting]  = useState(false);
  const [infoModal,  setInfoModal] = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('time_holidays')
      .select('id, holiday_code, holiday_name, created_at, updated_at, profiles(full_name)')
      .order('holiday_code');
    if (err) { setError(err.message); setLoading(false); return; }
    setHolidays((data ?? []) as Holiday[]);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const filtered = holidays.filter(h =>
    h.holiday_code.toLowerCase().includes(search.toLowerCase()) ||
    h.holiday_name.toLowerCase().includes(search.toLowerCase())
  );

  function openNew() { setForm(BLANK); setFormOpen(true); }

  function openEdit(h: Holiday) {
    setForm({ id: h.id, holiday_code: h.holiday_code, holiday_name: h.holiday_name });
    setFormOpen(true);
  }

  async function handleSave() {
    if (!form.holiday_code.trim() || !form.holiday_name.trim()) {
      setInfoModal({ open: true, title: 'Validation', message: 'Code and name are required.' });
      return;
    }
    setSaving(true);
    const { data, error: err } = await supabase.rpc('upsert_holiday', {
      p_data: {
        id:           form.id,
        holiday_code: form.holiday_code.toUpperCase().trim(),
        holiday_name: form.holiday_name.trim(),
      },
    });
    setSaving(false);
    if (err || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? err?.message ?? 'Unknown error.' });
      return;
    }
    setFormOpen(false);
    setForm(BLANK);
    await load();
  }

  async function handleDelete(id: string) {
    setDeleting(true);
    const { error: err } = await supabase.from('time_holidays').delete().eq('id', id);
    setDeleting(false);
    if (err) {
      setInfoModal({ open: true, title: 'Error', message: err.message });
      return;
    }
    setDeleteId(null);
    await load();
  }

  // ────────────────────────────────────────────────────────────────────────────

  return (
    <div className="ar-panel">
      <h2 className="page-title">Holidays</h2>
      <p className="page-subtitle">
        Define reusable holiday types (e.g. Christmas Day, Diwali). Assign them with dates on the
        <strong> Holiday Calendars</strong> page.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {/* ── Toolbar ─────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 12, marginBottom: 20, alignItems: 'center' }}>
        <input
          type="text" placeholder="Search code or name…" value={search}
          onChange={e => setSearch(e.target.value)}
          style={{ flex: 1, maxWidth: 320, padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13 }}
        />
        <button className="btn-add" style={{ marginLeft: 'auto' }} onClick={openNew}>
          <i className="fa-solid fa-plus" style={{ marginRight: 6 }} />Add Holiday
        </button>
      </div>

      {/* ── Table ─────────────────────────────────────────────────────────────── */}
      {loading ? (
        <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 32 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
        </div>
      ) : filtered.length === 0 ? (
        <div style={{ color: '#9CA3AF', fontSize: 13, padding: '24px 0' }}>
          {search ? 'No holidays match your search.' : 'No holidays yet. Add one above.'}
        </div>
      ) : (
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
            <thead>
              <tr style={{ borderBottom: '2px solid #E5E7EB', textAlign: 'left' }}>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Code</th>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Name</th>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Created</th>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Last Updated</th>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Created By</th>
                <th style={{ padding: '8px 12px', width: 80 }} />
              </tr>
            </thead>
            <tbody>
              {filtered.map(h => (
                <tr key={h.id} style={{ borderBottom: '1px solid #F3F4F6' }}>
                  <td style={{ padding: '10px 12px' }}>
                    <code style={{ background: '#EFF6FF', color: '#1D4ED8', padding: '3px 8px', borderRadius: 4, fontSize: 12, fontWeight: 600 }}>
                      {h.holiday_code}
                    </code>
                  </td>
                  <td style={{ padding: '10px 12px', fontWeight: 500, color: '#111827' }}>{h.holiday_name}</td>
                  <td style={{ padding: '10px 12px', color: '#6B7280' }}>{fmtDateTime(h.created_at)}</td>
                  <td style={{ padding: '10px 12px', color: '#6B7280' }}>{fmtDateTime(h.updated_at)}</td>
                  <td style={{ padding: '10px 12px', color: '#6B7280' }}>{h.profiles?.full_name ?? '—'}</td>
                  <td style={{ padding: '10px 12px' }}>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button
                        style={{ background: 'none', border: '1px solid #E5E7EB', borderRadius: 4, padding: '3px 8px', cursor: 'pointer', color: '#374151' }}
                        onClick={() => openEdit(h)} title="Edit"
                      ><i className="fa-solid fa-pen" style={{ fontSize: 11 }} /></button>
                      <button
                        style={{ background: 'none', border: '1px solid #FEE2E2', borderRadius: 4, padding: '3px 8px', cursor: 'pointer', color: '#DC2626' }}
                        onClick={() => setDeleteId(h.id)} title="Delete"
                      ><i className="fa-solid fa-trash" style={{ fontSize: 11 }} /></button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <div style={{ fontSize: 12, color: '#9CA3AF', marginTop: 8 }}>{filtered.length} holiday{filtered.length !== 1 ? 's' : ''}</div>
        </div>
      )}

      {/* ── Add/Edit Modal ────────────────────────────────────────────────────── */}
      {formOpen && (
        <div className="modal-overlay" onClick={() => setFormOpen(false)}>
          <div className="modal-box" style={{ maxWidth: 420 }} onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-star-and-crescent modal-icon" style={{ color: '#0369A1' }} />
              <h3>{form.id ? 'Edit Holiday' : 'Add Holiday'}</h3>
            </div>
            <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Code <span style={{ color: '#DC2626' }}>*</span>
                  <span style={{ color: '#9CA3AF', fontWeight: 400, fontSize: 11, marginLeft: 6 }}>Uppercase, unique identifier</span>
                </label>
                <input
                  type="text" placeholder="e.g. CHRISTMAS_DAY"
                  value={form.holiday_code}
                  onChange={e => setForm(f => ({ ...f, holiday_code: e.target.value.toUpperCase().replace(/[^A-Z0-9_]/g, '') }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%', fontFamily: 'monospace' }}
                />
              </div>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Name <span style={{ color: '#DC2626' }}>*</span></label>
                <input
                  type="text" placeholder="e.g. Christmas Day"
                  value={form.holiday_name}
                  onChange={e => setForm(f => ({
                    ...f,
                    holiday_name: e.target.value,
                    holiday_code: f.id ? f.holiday_code : toCode(e.target.value),
                  }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%' }}
                />
              </div>
            </div>
            <div className="modal-actions">
              <button style={{ background: '#F3F4F6', color: '#374151', border: 'none', borderRadius: 7, padding: '9px 20px', cursor: 'pointer', fontWeight: 500 }}
                onClick={() => setFormOpen(false)}>Cancel</button>
              <button className="btn-add" style={{ padding: '9px 24px' }} onClick={handleSave} disabled={saving}>
                {saving ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</> : 'Save'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Delete Confirm ────────────────────────────────────────────────────── */}
      {deleteId && (
        <div className="modal-overlay" onClick={() => setDeleteId(null)}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-triangle-exclamation modal-icon" style={{ color: '#DC2626' }} />
              <h3>Delete Holiday?</h3>
            </div>
            <div className="modal-body">
              This will also remove this holiday from any calendar entries it's used in.
            </div>
            <div className="modal-actions">
              <button style={{ background: '#F3F4F6', color: '#374151', border: 'none', borderRadius: 7, padding: '9px 20px', cursor: 'pointer', fontWeight: 500 }}
                onClick={() => setDeleteId(null)}>Cancel</button>
              <button style={{ background: '#DC2626', color: '#fff', border: 'none', borderRadius: 7, padding: '9px 20px', cursor: 'pointer', fontWeight: 500 }}
                onClick={() => handleDelete(deleteId)} disabled={deleting}>
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
