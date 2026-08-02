/**
 * TimesheetAdmin — Admin view of all employee timesheets.
 *
 * Filters: period (month picker), status, employee search.
 * Table: employee, period, status, planned h, recorded h, submitted date, action.
 * Action: view entries drill-down in a slide-over panel.
 *
 * Uses timesheet_headers + JOIN to profiles/employees for name.
 * Requires timesheet_admin.view permission.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface TimesheetRow {
  id:               string;
  employee_id:      string;
  employee_name:    string;
  employee_code:    string;
  period:           string;   // 'YYYY-MM-DD' (always 1st of month)
  status:           'to_be_submitted' | 'to_be_approved' | 'approved';
  planned_minutes:  number;
  recorded_minutes: number;
  submitted_at:     string | null;
  approved_at:      string | null;
  department_name:  string | null;
  country_code:     string | null;
}

interface Entry {
  id:           string;
  entry_date:   string;
  entry_kind:   string;
  hours_minutes: number;
  notes:        string | null;
  project_name: string | null;
  time_type_name: string | null;
  is_system_generated: boolean;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtPeriod(d: string) {
  const dt = new Date(d + 'T00:00:00');
  return dt.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
}

function fmtDate(d: string) {
  const dt = new Date(d + 'T00:00:00');
  return dt.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
}

function fmtMins(m: number) {
  if (!m) return '—';
  const h = Math.floor(m / 60), mm = m % 60;
  return mm === 0 ? `${h}h` : `${h}h ${mm}m`;
}

function fmtDateTime(d: string | null) {
  if (!d) return '—';
  return new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

function currentPeriod(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
}

const STATUS_LABELS: Record<string, { label: string; color: string; bg: string }> = {
  to_be_submitted: { label: 'To Submit',   color: '#92400E', bg: '#FEF3C7' },
  to_be_approved:  { label: 'Pending',     color: '#1E40AF', bg: '#DBEAFE' },
  approved:        { label: 'Approved',    color: '#065F46', bg: '#D1FAE5' },
};

// ─── Entry detail panel ───────────────────────────────────────────────────────

function EntryPanel({ ts, onClose }: { ts: TimesheetRow; onClose: () => void }) {
  const [entries,  setEntries]  = useState<Entry[]>([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      setLoading(true);
      const { data, error: err } = await supabase
        .from('timesheet_entries')
        .select(`
          id, entry_date, entry_kind, hours_minutes, notes, is_system_generated,
          projects ( name ),
          time_types ( name )
        `)
        .eq('header_id', ts.id)
        .order('entry_date');
      if (err) { setError(err.message); setLoading(false); return; }
      setEntries((data ?? []).map((e: any) => ({
        id:                  e.id,
        entry_date:          e.entry_date,
        entry_kind:          e.entry_kind,
        hours_minutes:       e.hours_minutes,
        notes:               e.notes,
        is_system_generated: e.is_system_generated,
        project_name:        e.projects?.name ?? null,
        time_type_name:      e.time_types?.name ?? null,
      })));
      setLoading(false);
    })();
  }, [ts.id]);

  const st = STATUS_LABELS[ts.status] ?? STATUS_LABELS.to_be_submitted;

  return (
    <div style={{
      position: 'fixed', inset: 0, zIndex: 1000,
      display: 'flex', justifyContent: 'flex-end',
    }}>
      {/* Backdrop */}
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.3)' }} onClick={onClose} />

      {/* Panel */}
      <div style={{
        position: 'relative', width: 520, maxWidth: '95vw',
        background: '#fff', boxShadow: '-4px 0 24px rgba(0,0,0,0.12)',
        display: 'flex', flexDirection: 'column', overflowY: 'auto',
      }}>
        {/* Header */}
        <div style={{ padding: '20px 24px', borderBottom: '1px solid #E5E7EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div>
            <h3 style={{ margin: 0, fontSize: 16, fontWeight: 700 }}>{ts.employee_name}</h3>
            <p style={{ margin: '4px 0 0', fontSize: 13, color: '#6B7280' }}>
              {fmtPeriod(ts.period)}
              {ts.department_name ? ` · ${ts.department_name}` : ''}
            </p>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{ fontSize: 12, fontWeight: 600, padding: '3px 10px', borderRadius: 20, background: st.bg, color: st.color }}>
              {st.label}
            </span>
            <button onClick={onClose} style={{ background: 'none', border: 'none', cursor: 'pointer', fontSize: 18, color: '#9CA3AF' }}>
              <i className="fa-solid fa-xmark" />
            </button>
          </div>
        </div>

        {/* Summary bar */}
        <div style={{ display: 'flex', gap: 0, borderBottom: '1px solid #E5E7EB' }}>
          {[
            { label: 'Planned',    value: fmtMins(ts.planned_minutes)  },
            { label: 'Recorded',   value: fmtMins(ts.recorded_minutes) },
            { label: 'Submitted',  value: fmtDateTime(ts.submitted_at) },
            { label: 'Approved',   value: fmtDateTime(ts.approved_at)  },
          ].map(({ label, value }) => (
            <div key={label} style={{ flex: 1, padding: '12px 16px', borderRight: '1px solid #E5E7EB' }}>
              <div style={{ fontSize: 11, color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.04em', marginBottom: 2 }}>{label}</div>
              <div style={{ fontSize: 14, fontWeight: 600, color: '#111827' }}>{value}</div>
            </div>
          ))}
        </div>

        {/* Entries */}
        <div style={{ padding: '16px 24px', flex: 1 }}>
          {error && <ErrorBanner message={error} />}
          {loading ? (
            <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 32 }}>
              <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
            </div>
          ) : entries.length === 0 ? (
            <div style={{ color: '#9CA3AF', fontSize: 13 }}>No entries recorded for this period.</div>
          ) : (
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
              <thead>
                <tr style={{ borderBottom: '2px solid #E5E7EB' }}>
                  <th style={{ textAlign: 'left', padding: '6px 0', color: '#6B7280', fontWeight: 600, fontSize: 11 }}>DATE</th>
                  <th style={{ textAlign: 'left', padding: '6px 0', color: '#6B7280', fontWeight: 600, fontSize: 11 }}>DESCRIPTION</th>
                  <th style={{ textAlign: 'right', padding: '6px 0', color: '#6B7280', fontWeight: 600, fontSize: 11 }}>HOURS</th>
                </tr>
              </thead>
              <tbody>
                {entries.map(e => (
                  <tr key={e.id} style={{ borderBottom: '1px solid #F3F4F6' }}>
                    <td style={{ padding: '8px 0', color: '#374151', whiteSpace: 'nowrap' }}>{fmtDate(e.entry_date)}</td>
                    <td style={{ padding: '8px 8px 8px 0' }}>
                      <div style={{ fontWeight: 500 }}>
                        {e.project_name ?? e.time_type_name ?? e.entry_kind}
                        {e.is_system_generated && (
                          <span style={{ fontSize: 10, background: '#F3F4F6', color: '#9CA3AF', padding: '1px 5px', borderRadius: 4, marginLeft: 6 }}>system</span>
                        )}
                      </div>
                      {e.notes && <div style={{ fontSize: 12, color: '#9CA3AF', marginTop: 2 }}>{e.notes}</div>}
                    </td>
                    <td style={{ padding: '8px 0', textAlign: 'right', fontWeight: 600 }}>{fmtMins(e.hours_minutes)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr style={{ borderTop: '2px solid #E5E7EB' }}>
                  <td colSpan={2} style={{ padding: '10px 0', fontWeight: 700, fontSize: 13 }}>Total</td>
                  <td style={{ padding: '10px 0', textAlign: 'right', fontWeight: 700, fontSize: 13 }}>
                    {fmtMins(entries.reduce((s, e) => s + e.hours_minutes, 0))}
                  </td>
                </tr>
              </tfoot>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function TimesheetAdmin() {
  const [timesheets,  setTimesheets]  = useState<TimesheetRow[]>([]);
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState<string | null>(null);
  const [period,      setPeriod]      = useState(currentPeriod());
  const [statusFilter, setStatusFilter] = useState('');
  const [search,      setSearch]      = useState('');
  const [selected,    setSelected]    = useState<TimesheetRow | null>(null);

  const load = useCallback(async (p: string) => {
    setLoading(true);
    setError(null);
    const periodDate = `${p}-01`;

    const { data, error: err } = await supabase
      .from('timesheet_headers')
      .select(`
        id, employee_id, period, status,
        planned_minutes, recorded_minutes,
        submitted_at, approved_at,
        department_name, country_code,
        employees!inner (
          employee_code,
          profiles!employee_id ( first_name, last_name )
        )
      `)
      .eq('period', periodDate)
      .order('period', { ascending: false });

    if (err) { setError(err.message); setLoading(false); return; }

    const rows: TimesheetRow[] = (data ?? []).map((r: any) => ({
      id:               r.id,
      employee_id:      r.employee_id,
      employee_name:    `${r.employees?.profiles?.first_name ?? ''} ${r.employees?.profiles?.last_name ?? ''}`.trim(),
      employee_code:    r.employees?.employee_code ?? '',
      period:           r.period,
      status:           r.status,
      planned_minutes:  r.planned_minutes,
      recorded_minutes: r.recorded_minutes,
      submitted_at:     r.submitted_at,
      approved_at:      r.approved_at,
      department_name:  r.department_name,
      country_code:     r.country_code,
    }));

    setTimesheets(rows);
    setLoading(false);
  }, []);

  useEffect(() => { load(period); }, [period, load]);

  const filtered = timesheets.filter(t => {
    if (statusFilter && t.status !== statusFilter) return false;
    if (search) {
      const q = search.toLowerCase();
      if (!t.employee_name.toLowerCase().includes(q) && !t.employee_code.toLowerCase().includes(q)) return false;
    }
    return true;
  });

  const summaryCount = (s: string) => timesheets.filter(t => t.status === s).length;

  return (
    <div className="ar-panel">
      <h2 className="page-title">Timesheet Admin</h2>
      <p className="page-subtitle">View and monitor employee timesheets across all periods.</p>

      {error && <ErrorBanner message={error} onRetry={() => load(period)} />}

      {/* ── Filters ─────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 12, marginBottom: 20, flexWrap: 'wrap', alignItems: 'flex-end' }}>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>Period</label>
          <input
            type="month"
            value={period}
            onChange={e => setPeriod(e.target.value)}
            style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13 }}
          />
        </div>

        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>Status</label>
          <select
            value={statusFilter}
            onChange={e => setStatusFilter(e.target.value)}
            style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13 }}
          >
            <option value="">All</option>
            <option value="to_be_submitted">To Submit</option>
            <option value="to_be_approved">Pending Approval</option>
            <option value="approved">Approved</option>
          </select>
        </div>

        <div className="form-group" style={{ marginBottom: 0, flex: 1, minWidth: 200 }}>
          <label>Search employee</label>
          <input
            type="text" placeholder="Name or code…"
            value={search}
            onChange={e => setSearch(e.target.value)}
            style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid #D1D5DB', fontSize: 13, width: '100%' }}
          />
        </div>
      </div>

      {/* ── Summary chips ───────────────────────────────────────────────────── */}
      {!loading && timesheets.length > 0 && (
        <div style={{ display: 'flex', gap: 10, marginBottom: 20, flexWrap: 'wrap' }}>
          {Object.entries(STATUS_LABELS).map(([key, { label, color, bg }]) => (
            <span key={key} style={{ fontSize: 12, fontWeight: 600, padding: '4px 12px', borderRadius: 20, background: bg, color }}>
              {summaryCount(key)} {label}
            </span>
          ))}
          <span style={{ fontSize: 12, fontWeight: 600, padding: '4px 12px', borderRadius: 20, background: '#F3F4F6', color: '#374151' }}>
            {timesheets.length} total
          </span>
        </div>
      )}

      {/* ── Table ───────────────────────────────────────────────────────────── */}
      {loading ? (
        <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 40 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
        </div>
      ) : filtered.length === 0 ? (
        <div style={{ color: '#9CA3AF', fontSize: 13, padding: '24px 0' }}>
          {timesheets.length === 0 ? `No timesheets found for ${fmtPeriod(period + '-01')}.` : 'No results match your filters.'}
        </div>
      ) : (
        <div className="er-table-wrap">
          <table className="er-table">
            <thead>
              <tr>
                <th>Employee</th>
                <th>Department</th>
                <th>Status</th>
                <th style={{ textAlign: 'right' }}>Planned</th>
                <th style={{ textAlign: 'right' }}>Recorded</th>
                <th>Submitted</th>
                <th style={{ textAlign: 'right' }}>Action</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map(t => {
                const st = STATUS_LABELS[t.status] ?? STATUS_LABELS.to_be_submitted;
                const pct = t.planned_minutes > 0
                  ? Math.min(100, Math.round((t.recorded_minutes / t.planned_minutes) * 100))
                  : 0;
                return (
                  <tr key={t.id}>
                    <td>
                      <div style={{ fontWeight: 600 }}>{t.employee_name || '—'}</div>
                      <div style={{ fontSize: 11, color: '#9CA3AF' }}>{t.employee_code}</div>
                    </td>
                    <td style={{ fontSize: 13, color: '#6B7280' }}>{t.department_name ?? '—'}</td>
                    <td>
                      <span style={{ fontSize: 11, fontWeight: 600, padding: '2px 8px', borderRadius: 20, background: st.bg, color: st.color }}>
                        {st.label}
                      </span>
                    </td>
                    <td style={{ textAlign: 'right', fontSize: 13 }}>{fmtMins(t.planned_minutes)}</td>
                    <td style={{ textAlign: 'right' }}>
                      <div style={{ fontSize: 13, fontWeight: 600 }}>{fmtMins(t.recorded_minutes)}</div>
                      {t.planned_minutes > 0 && (
                        <div style={{ marginTop: 3, height: 3, background: '#E5E7EB', borderRadius: 2 }}>
                          <div style={{ width: `${pct}%`, height: '100%', background: pct >= 100 ? '#10B981' : '#3B82F6', borderRadius: 2 }} />
                        </div>
                      )}
                    </td>
                    <td style={{ fontSize: 12, color: '#6B7280' }}>{fmtDateTime(t.submitted_at)}</td>
                    <td style={{ textAlign: 'right' }}>
                      <button
                        className="rd-btn-edit-val"
                        title="View entries"
                        onClick={() => setSelected(t)}
                      >
                        <i className="fa-solid fa-eye" />
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {selected && <EntryPanel ts={selected} onClose={() => setSelected(null)} />}
    </div>
  );
}
