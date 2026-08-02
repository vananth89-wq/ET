/**
 * SubmissionConfig — Admin page for configuring timesheet submission reminders.
 *
 * Rows define when reminder notifications fire relative to month-end.
 * offset_days: negative = before month end, positive = after.
 * The RPC does a full-replace (delete + re-insert) on save.
 *
 * Layout: editable table of reminder rows, + Add Row button, Save button.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface ConfigRow {
  _key:              number;   // local-only key for React list rendering
  offset_days:       number;
  message_template:  string;
  notification_type: 'in_app' | 'email' | 'both';
  is_active:         boolean;
  sort_order:        number;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function offsetLabel(days: number): string {
  if (days === 0)  return 'On last day of month';
  if (days === -1) return '1 day before month end';
  if (days < 0)   return `${Math.abs(days)} days before month end`;
  if (days === 1)  return '1 day after month end';
  return `${days} days after month end`;
}

const NOTIF_OPTIONS: { value: ConfigRow['notification_type']; label: string }[] = [
  { value: 'in_app', label: 'In-App'     },
  { value: 'email',  label: 'Email'      },
  { value: 'both',   label: 'Both'       },
];

let _keyCounter = 0;
function nextKey() { return ++_keyCounter; }

// ─── Component ────────────────────────────────────────────────────────────────

export default function SubmissionConfig() {
  const [rows,    setRows]    = useState<ConfigRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving,  setSaving]  = useState(false);
  const [error,   setError]   = useState<string | null>(null);
  const [saved,   setSaved]   = useState(false);
  const [infoModal, setInfoModal] = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('time_submission_config')
      .select('offset_days, message_template, notification_type, is_active, sort_order')
      .order('sort_order');
    if (err) { setError(err.message); setLoading(false); return; }
    setRows(
      (data ?? []).map(r => ({ ...r, _key: nextKey() } as ConfigRow))
    );
    setLoading(false);
  }, []);

  useEffect(() => { const t = setTimeout(load, 0); return () => clearTimeout(t); }, [load]);

  function addRow() {
    setRows(prev => [...prev, {
      _key:              nextKey(),
      offset_days:       prev.length === 0 ? -1 : (prev[prev.length - 1].offset_days + 3),
      message_template:  'Hi {{employee_name}}, your timesheet for {{period}} requires attention.',
      notification_type: 'both',
      is_active:         true,
      sort_order:        prev.length,
    }]);
  }

  function removeRow(key: number) {
    setRows(prev => prev.filter(r => r._key !== key).map((r, i) => ({ ...r, sort_order: i })));
  }

  function updateRow(key: number, patch: Partial<ConfigRow>) {
    setRows(prev => prev.map(r => r._key === key ? { ...r, ...patch } : r));
    setSaved(false);
  }

  function moveRow(key: number, dir: -1 | 1) {
    setRows(prev => {
      const idx = prev.findIndex(r => r._key === key);
      const next = idx + dir;
      if (next < 0 || next >= prev.length) return prev;
      const arr = [...prev];
      [arr[idx], arr[next]] = [arr[next], arr[idx]];
      return arr.map((r, i) => ({ ...r, sort_order: i }));
    });
    setSaved(false);
  }

  async function handleSave() {
    // Validate
    for (const r of rows) {
      if (!r.message_template.trim()) {
        setInfoModal({ open: true, title: 'Validation Error', message: 'All rows must have a message template.' });
        return;
      }
    }
    setSaving(true);
    setSaved(false);
    const payload = rows.map((r, i) => ({
      offset_days:       r.offset_days,
      message_template:  r.message_template.trim(),
      notification_type: r.notification_type,
      is_active:         r.is_active,
      sort_order:        i,
    }));

    const { data, error: rpcErr } = await supabase.rpc('upsert_submission_config', { p_rows: payload });
    setSaving(false);

    if (rpcErr || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? rpcErr?.message ?? 'Unknown error.' });
      return;
    }
    setSaved(true);
    await load();
  }

  const TOKENS = ['{{employee_name}}', '{{period}}', '{{deadline}}'];

  return (
    <div className="ar-panel">
      <h2 className="page-title">Submission Config</h2>
      <p className="page-subtitle">
        Configure when reminder notifications are sent to employees about timesheet submission.
        Offset is relative to the last day of the month — negative days fire before, positive after.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {/* ── Token reference ─────────────────────────────────────────────────── */}
      <div style={{ marginBottom: 20, padding: '10px 14px', background: '#F0F9FF', borderRadius: 8, border: '1px solid #BAE6FD', fontSize: 12, color: '#0369A1' }}>
        <strong>Message tokens:</strong>&nbsp;
        {TOKENS.map(t => (
          <code key={t} style={{ background: '#E0F2FE', padding: '1px 6px', borderRadius: 4, marginRight: 8 }}>{t}</code>
        ))}
      </div>

      {loading ? (
        <div style={{ textAlign: 'center', color: '#9CA3AF', padding: 32 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
        </div>
      ) : (
        <>
          {rows.length === 0 ? (
            <div style={{ color: '#9CA3AF', fontSize: 13, marginBottom: 16 }}>No reminder rules yet. Add one below.</div>
          ) : (
            <div style={{ marginBottom: 20 }}>
              {rows.map((row, i) => (
                <div key={row._key} style={{
                  background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
                  padding: '16px', marginBottom: 12,
                  opacity: row.is_active ? 1 : 0.55,
                }}>
                  {/* Row header */}
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12 }}>
                    <span style={{
                      background: '#EFF6FF', color: '#1D4ED8', borderRadius: 20,
                      padding: '3px 12px', fontSize: 12, fontWeight: 600, whiteSpace: 'nowrap',
                    }}>
                      #{i + 1} · {offsetLabel(row.offset_days)}
                    </span>

                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginLeft: 'auto' }}>
                      <button
                        style={{ background: 'none', border: '1px solid #E5E7EB', borderRadius: 4, padding: '3px 8px', cursor: 'pointer', color: '#6B7280' }}
                        onClick={() => moveRow(row._key, -1)} disabled={i === 0} title="Move up"
                      ><i className="fa-solid fa-chevron-up" style={{ fontSize: 11 }} /></button>
                      <button
                        style={{ background: 'none', border: '1px solid #E5E7EB', borderRadius: 4, padding: '3px 8px', cursor: 'pointer', color: '#6B7280' }}
                        onClick={() => moveRow(row._key, 1)} disabled={i === rows.length - 1} title="Move down"
                      ><i className="fa-solid fa-chevron-down" style={{ fontSize: 11 }} /></button>
                      <button
                        style={{ background: 'none', border: '1px solid #FEE2E2', borderRadius: 4, padding: '3px 8px', cursor: 'pointer', color: '#DC2626' }}
                        onClick={() => removeRow(row._key)} title="Remove row"
                      ><i className="fa-solid fa-trash" style={{ fontSize: 11 }} /></button>
                    </div>
                  </div>

                  {/* Fields */}
                  <div style={{ display: 'grid', gridTemplateColumns: '120px 1fr 120px', gap: 12, marginBottom: 10 }}>
                    <div className="form-group" style={{ marginBottom: 0 }}>
                      <label>Offset Days</label>
                      <input
                        type="number"
                        value={row.offset_days}
                        onChange={e => updateRow(row._key, { offset_days: parseInt(e.target.value) || 0 })}
                        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #D1D5DB', fontSize: 13, width: '100%' }}
                      />
                    </div>

                    <div className="form-group" style={{ marginBottom: 0 }}>
                      <label>Message Template</label>
                      <textarea
                        rows={2}
                        value={row.message_template}
                        onChange={e => updateRow(row._key, { message_template: e.target.value })}
                        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #D1D5DB', fontSize: 13, width: '100%', resize: 'vertical', fontFamily: 'inherit' }}
                      />
                    </div>

                    <div className="form-group" style={{ marginBottom: 0 }}>
                      <label>Notification</label>
                      <select
                        value={row.notification_type}
                        onChange={e => updateRow(row._key, { notification_type: e.target.value as ConfigRow['notification_type'] })}
                        style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #D1D5DB', fontSize: 13, width: '100%' }}
                      >
                        {NOTIF_OPTIONS.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
                      </select>
                    </div>
                  </div>

                  <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, cursor: 'pointer' }}>
                    <input
                      type="checkbox" checked={row.is_active}
                      onChange={e => updateRow(row._key, { is_active: e.target.checked })}
                    />
                    Active
                  </label>
                </div>
              ))}
            </div>
          )}

          {/* ── Actions ─────────────────────────────────────────────────────── */}
          <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
            <button className="btn-add" style={{ background: '#F3F4F6', color: '#374151', border: '1px dashed #D1D5DB' }} onClick={addRow}>
              <i className="fa-solid fa-plus" style={{ marginRight: 6 }} />Add Reminder Rule
            </button>

            <button className="btn-add" onClick={handleSave} disabled={saving}>
              {saving
                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : <><i className="fa-solid fa-floppy-disk" /> Save</>
              }
            </button>

            {saved && (
              <span style={{ fontSize: 13, color: '#059669' }}>
                <i className="fa-solid fa-circle-check" style={{ marginRight: 4 }} />Saved
              </span>
            )}
          </div>
        </>
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
