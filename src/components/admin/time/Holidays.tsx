/**
 * Holidays — Global pool of holiday definitions.
 *
 * Holidays are standalone records (date, name, code, country).
 * They can be assigned to Holiday Calendars on the Holiday Calendars page.
 *
 * Filter by year + country_code. Create/edit/delete holidays here.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface Holiday {
  id:           string;
  holiday_date: string;
  holiday_name: string;
  holiday_code: string;
  country_code: string | null;
  holiday_year: number;
}

interface FormState {
  id:           string | null;
  holiday_date: string;
  holiday_name: string;
  holiday_code: string;
  country_code: string;
}

const BLANK: FormState = {
  id: null, holiday_date: '', holiday_name: '', holiday_code: '', country_code: '',
};

function fmtDate(d: string): string {
  if (!d) return '';
  const dt = new Date(d + 'T00:00:00');
  return dt.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

function toCode(name: string): string {
  return name.trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').slice(0, 20);
}

const currentYear = new Date().getFullYear();
const YEAR_OPTIONS = [currentYear - 1, currentYear, currentYear + 1, currentYear + 2];

// ─── Component ────────────────────────────────────────────────────────────────

export default function Holidays() {
  const [holidays,    setHolidays]   = useState<Holiday[]>([]);
  const [loading,     setLoading]    = useState(true);
  const [error,       setError]      = useState<string | null>(null);
  const [yearFilter,  setYearFilter] = useState<number>(currentYear);
  const [ccFilter,    setCcFilter]   = useState('');
  const [form,        setForm]       = useState<FormState>(BLANK);
  const [formOpen,    setFormOpen]   = useState(false);
  const [saving,      setSaving]     = useState(false);
  const [deleteId,    setDeleteId]   = useState<string | null>(null);
  const [deleting,    setDeleting]   = useState(false);
  const [infoModal,   setInfoModal]  = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('time_holidays')
      .select('id, holiday_date, holiday_name, holiday_code, country_code, holiday_year')
      .order('holiday_date');
    if (err) { setError(err.message); setLoading(false); return; }
    setHolidays(data ?? []);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  // Derived filtered list
  const filtered = holidays.filter(h => {
    if (h.holiday_year !== yearFilter) return false;
    if (ccFilter && (h.country_code ?? '').toUpperCase() !== ccFilter.toUpperCase()) return false;
    return true;
  });

  function openNew() {
    setForm({ ...BLANK, holiday_date: `${yearFilter}-01-01` });
    setFormOpen(true);
  }

  function openEdit(h: Holiday) {
    setForm({
      id: h.id,
      holiday_date: h.holiday_date,
      holiday_name: h.holiday_name,
      holiday_code: h.holiday_code,
      country_code: h.country_code ?? '',
    });
    setFormOpen(true);
  }

  async function handleSave() {
    if (!form.holiday_date || !form.holiday_name.trim() || !form.holiday_code.trim()) {
      setInfoModal({ open: true, title: 'Validation', message: 'Date, name and code are required.' });
      return;
    }
    setSaving(true);
    const { data, error: err } = await supabase.rpc('upsert_holiday', {
      p_data: {
        id:           form.id,
        holiday_date: form.holiday_date,
        holiday_name: form.holiday_name.trim(),
        holiday_code: form.holiday_code.toUpperCase().trim(),
        country_code: form.country_code.trim() || null,
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
    const { error: err } = await supabase
      .from('time_holidays')
      .delete()
      .eq('id', id);
    setDeleting(false);
    if (err) {
      setInfoModal({ open: true, title: 'Error', message: err.message });
      return;
    }
    setDeleteId(null);
    await load();
  }

  // Unique countries in data for filter hint
  const countries = Array.from(new Set(holidays.map(h => h.country_code).filter(Boolean) as string[])).sort();

  return (
    <div className="ar-panel">
      <h2 className="page-title">Holidays</h2>
      <p className="page-subtitle">
        Create and manage your global holiday pool. Assign holidays to specific calendars on the
        <strong> Holiday Calendars</strong> page.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {/* ── Filters ─────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 12, marginBottom: 20, flexWrap: 'wrap', alignItems: 'flex-end' }}>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>Year</label>
          <select
            value={yearFilter}
            onChange={e => setYearFilter(Number(e.target.value))}
            style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13 }}
          >
            {YEAR_OPTIONS.map(y => <option key={y} value={y}>{y}</option>)}
          </select>
        </div>

        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>Country Code</label>
          <select
            value={ccFilter}
            onChange={e => setCcFilter(e.target.value)}
            style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13 }}
          >
            <option value="">All countries</option>
            {countries.map(c => <option key={c} value={c}>{c}</option>)}
          </select>
        </div>

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
          No holidays found for {yearFilter}{ccFilter ? ` / ${ccFilter}` : ''}. Add one above.
        </div>
      ) : (
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
            <thead>
              <tr style={{ borderBottom: '2px solid #E5E7EB', textAlign: 'left' }}>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Date</th>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Name</th>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Code</th>
                <th style={{ padding: '8px 12px', color: '#6B7280', fontWeight: 600 }}>Country</th>
                <th style={{ padding: '8px 12px', width: 80 }} />
              </tr>
            </thead>
            <tbody>
              {filtered.map(h => (
                <tr key={h.id} style={{ borderBottom: '1px solid #F3F4F6' }}>
                  <td style={{ padding: '10px 12px', whiteSpace: 'nowrap' }}>{fmtDate(h.holiday_date)}</td>
                  <td style={{ padding: '10px 12px', fontWeight: 500 }}>{h.holiday_name}</td>
                  <td style={{ padding: '10px 12px' }}>
                    <code style={{ background: '#F3F4F6', padding: '2px 6px', borderRadius: 4, fontSize: 12 }}>
                      {h.holiday_code}
                    </code>
                  </td>
                  <td style={{ padding: '10px 12px', color: '#6B7280' }}>{h.country_code ?? '—'}</td>
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
          <div className="modal-box" style={{ maxWidth: 440 }} onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-star-and-crescent modal-icon" style={{ color: '#0369A1' }} />
              <h3>{form.id ? 'Edit Holiday' : 'Add Holiday'}</h3>
            </div>
            <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Date <span style={{ color: '#DC2626' }}>*</span></label>
                <input
                  type="date"
                  value={form.holiday_date}
                  onChange={e => setForm(f => ({ ...f, holiday_date: e.target.value }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%' }}
                />
              </div>

              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Name <span style={{ color: '#DC2626' }}>*</span></label>
                <input
                  type="text"
                  placeholder="e.g. Christmas Day"
                  value={form.holiday_name}
                  onChange={e => setForm(f => ({
                    ...f,
                    holiday_name: e.target.value,
                    holiday_code: f.id ? f.holiday_code : toCode(e.target.value),
                  }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%' }}
                />
              </div>

              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Code <span style={{ color: '#DC2626' }}>*</span></label>
                <input
                  type="text"
                  placeholder="e.g. CHRISTMAS_DAY"
                  value={form.holiday_code}
                  onChange={e => setForm(f => ({ ...f, holiday_code: e.target.value.toUpperCase() }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%', fontFamily: 'monospace' }}
                />
              </div>

              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Country Code <span style={{ color: '#9CA3AF', fontWeight: 400 }}>(optional, ISO 2-letter)</span></label>
                <input
                  type="text"
                  placeholder="e.g. IN, GB, US"
                  maxLength={2}
                  value={form.country_code}
                  onChange={e => setForm(f => ({ ...f, country_code: e.target.value.toUpperCase() }))}
                  style={{ padding: '7px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: 100, textTransform: 'uppercase' }}
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
              This will also remove this holiday from any calendars it's assigned to.
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
