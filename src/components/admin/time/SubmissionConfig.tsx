/**
 * SubmissionConfig — Admin page for configuring timesheet submission reminders.
 *
 * Rows define when reminder notifications fire relative to the end of the
 * PERIOD, counted in WORKING days (857). Not month end, and not calendar days:
 * on a 26-to-25 cycle a period called August ends on 25 August, and an offset
 * that lands on a weekend or a holiday is pushed forward.
 *
 * Working days are per-employee -- the schedule and the holiday calendar both
 * come from employee_employment -- so one rule fires on different dates for
 * different people. That is why the preview names whose dates it is showing.
 *
 * Each rule also carries RECIPIENTS (858): employee | manager | dept_head, and
 * role:<code> for everyone holding a role. Roles are read live, so a role
 * created after this screen shipped appears here with no deploy.
 *
 * The deadline itself is NOT a reminder offset (856). It is
 * time_edit_config.submission_grace_days, edited in the Settings card below and
 * saved through its own RPC.
 *
 * The rules RPC does a full-replace (delete + re-insert) on save, so every
 * field a rule has must be in the payload -- a field left out is reset.
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
  recipients:        string[];
}

interface RoleOption { code: string; name: string; role_type: string }

/** The two settings that are NOT reminder rules. */
interface Settings { grace: number; catchup: number }

// ─── Helpers ──────────────────────────────────────────────────────────────────

/* "month end" was wrong twice over: on a 26-to-25 cycle the period does not end
   with the month, and since 857 the offset is counted in working days. */
function offsetLabel(days: number): string {
  if (days === 0)  return 'On the last day of the period';
  if (days === -1) return '1 working day before the period ends';
  if (days < 0)    return `${Math.abs(days)} working days before the period ends`;
  if (days === 1)  return '1 working day after the period ends';
  return `${days} working days after the period ends`;
}

const RELATIONSHIP_RECIPIENTS: { token: string; label: string }[] = [
  { token: 'employee',  label: 'Employee'   },
  { token: 'manager',   label: 'Manager'    },
  { token: 'dept_head', label: 'Dept Head'  },
];

function recipientLabel(token: string, roles: RoleOption[]): string {
  const rel = RELATIONSHIP_RECIPIENTS.find(r => r.token === token);
  if (rel) return rel.label;
  if (token.startsWith('role:')) {
    const code = token.slice(5);
    return roles.find(r => r.code === code)?.name ?? code;
  }
  return token;
}

/* Three states, not two. `undefined` means "not computed for this offset yet"
   -- which is what an admin sees the instant they edit the number -- and must
   not be reported as "never", which is a fact about the employee's schedule. */
function fmtFireDate(iso: string | null | undefined): string | null {
  if (iso === undefined) return null;
  if (iso === null)      return 'never — this employee has no working days';
  return new Date(iso + 'T00:00:00')
    .toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
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

  const [roles,    setRoles]    = useState<RoleOption[]>([]);
  const [settings, setSettings] = useState<Settings>({ grace: 0, catchup: 3 });
  const [savingSettings, setSavingSettings] = useState(false);
  const [savedSettings,  setSavedSettings]  = useState(false);
  /* Working-day arithmetic is invisible on a number input: an admin types +1 and
     cannot see that a holiday moved it. The preview shows real dates from
     time_reminder_fire_date, and names the employee, because the answer differs
     per person -- a Sun-Thu week and a Mon-Fri week do not share a Friday. */
  const [preview, setPreview] = useState<{ name: string; dates: Record<number, string | null> } | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('time_submission_config')
      .select('offset_days, message_template, notification_type, is_active, sort_order, recipients')
      .order('sort_order');
    if (err) { setError(err.message); setLoading(false); return; }
    const loaded = (data ?? []).map(r => ({
      ...r,
      // A rule with no recipients cannot reach anyone. The column is NOT NULL so
      // this should not happen, but the screen should not render an empty rule
      // as though it were configured.
      recipients: (r as any).recipients?.length ? (r as any).recipients : ['employee'],
      _key: nextKey(),
    } as ConfigRow));
    setRows(loaded);

    /* Roles are data, not a list this file knows -- read live, so a role created
       next month appears with no deploy.
    
       But NOT every role. System roles (ess, mss, dept_head, project_manager)
       have their membership synced from org structure, so they are
       population-sized: role:ess is all 58 employees, and CC-ing it on a
       reminder mails the company. 'Department Head' the system role would also
       sit next to 'Dept Head' the relationship meaning something different --
       the relationship is THIS employee's head, the role is everyone who is
       one. Custom and protected roles are assigned deliberately by a person,
       which is what a CC list wants.
    
       The cost, stated: there is no way to copy "this employee's project
       manager", because that is a relationship and no token exists for it yet.
       Adding one is a resolver change, not a config change. */
    const { data: roleData } = await supabase
      .from('roles').select('code, name, role_type').order('name');
    setRoles(((roleData ?? []) as RoleOption[]).filter(r => r.role_type !== 'system'));

    const { data: cfg } = await supabase
      .from('time_edit_config')
      .select('submission_grace_days, reminder_catchup_days')
      .limit(1).maybeSingle();
    if (cfg) {
      setSettings({
        grace:   (cfg as any).submission_grace_days ?? 0,
        catchup: (cfg as any).reminder_catchup_days ?? 3,
      });
    }

    setLoading(false);
  }, []);

  /* Fetched after the rules load, and again after a save -- deliberately not on
     every keystroke in the offset box: each rule costs one RPC round trip, and a
     half-typed "-" would ask the database about offset 0. */
  const loadPreview = useCallback(async (current: ConfigRow[]) => {
    const { data: emp } = await supabase
      .from('employee_employment')
      .select('employee_id, employees!inner(name, status, deleted_at)')
      .not('work_schedule_id', 'is', null)
      .limit(1).maybeSingle();
    if (!emp) { setPreview(null); return; }

    const empId = (emp as any).employee_id as string;
    const name  = (emp as any).employees?.name ?? 'an employee';

    const { data: periodRow } = await supabase.rpc('timesheet_period_of', { p_date: new Date().toISOString().slice(0, 10) });
    if (!periodRow) { setPreview(null); return; }

    const dates: Record<number, string | null> = {};
    for (const r of current) {
      const { data: fire } = await supabase.rpc('time_reminder_fire_date', {
        p_employee_id: empId, p_period: periodRow, p_offset: r.offset_days,
      });
      dates[r.offset_days] = (fire as string | null) ?? null;
    }
    setPreview({ name, dates });
  }, []);

  useEffect(() => { const t = setTimeout(load, 0); return () => clearTimeout(t); }, [load]);

  useEffect(() => {
    if (!loading && rows.length) { void loadPreview(rows); }
    // Rules only: re-running on every keystroke would be one RPC per character.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loading]);

  function addRow() {
    setRows(prev => [...prev, {
      _key:              nextKey(),
      offset_days:       prev.length === 0 ? -1 : (prev[prev.length - 1].offset_days + 3),
      message_template:  'Hi {{employee_name}}, your timesheet for {{period}} requires attention.',
      notification_type: 'both',
      is_active:         true,
      sort_order:        prev.length,
      recipients:        ['employee'],
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
      if (!r.recipients.length) {
        setInfoModal({ open: true, title: 'Validation Error',
          message: `The rule at offset ${r.offset_days} has no recipients. A reminder that reaches nobody is not a reminder.` });
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
      // Must be sent. The RPC is a full replace and falls back to {employee}
      // for any row that omits this key -- which would silently drop a CC list.
      recipients:        r.recipients,
    }));

    const { data, error: rpcErr } = await supabase.rpc('upsert_submission_config', { p_rows: payload });
    setSaving(false);

    if (rpcErr || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? rpcErr?.message ?? 'Unknown error.' });
      return;
    }
    setSaved(true);
    await load();
    await loadPreview(rows);
  }

  function toggleRecipient(key: number, token: string) {
    setRows(prev => prev.map(r => {
      if (r._key !== key) return r;
      const has = r.recipients.includes(token);
      return { ...r, recipients: has ? r.recipients.filter(t => t !== token) : [...r.recipients, token] };
    }));
    setSaved(false);
  }

  async function handleSaveSettings() {
    setSavingSettings(true);
    setSavedSettings(false);
    const { data, error: rpcErr } = await supabase.rpc('save_time_submission_settings', {
      p_grace_days: settings.grace, p_catchup_days: settings.catchup,
    });
    setSavingSettings(false);
    if (rpcErr || !data?.ok) {
      setInfoModal({ open: true, title: 'Error', message: data?.message ?? rpcErr?.message ?? 'Unknown error.' });
      return;
    }
    setSavedSettings(true);
    await loadPreview(rows);
  }

  const TOKENS = ['{{employee_name}}', '{{period}}', '{{deadline}}'];

  return (
    <div className="ar-panel">
      <h2 className="page-title">Submission Config</h2>
      <p className="page-subtitle">
        Configure when reminder notifications are sent about timesheet submission, and who
        receives them. Offset is counted in <strong>working days</strong> from the last day of
        the <strong>period</strong> — negative fires before, positive after. A reminder landing
        on a weekend or a holiday is pushed to the next working day, using each employee&rsquo;s own
        schedule and holiday calendar, so one rule can fire on different dates for different people.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {/* ── Deadline + catch-up ─────────────────────────────────────────────
          Not reminder rules, and deliberately not derived from them. Until
          mig 856 the deadline WAS the largest active offset, so editing a
          message moved who counted as late. */}
      {!loading && (
        <div style={{
          marginBottom: 20, padding: '14px 16px', background: '#fff',
          border: '1px solid #E5E7EB', borderRadius: 10,
        }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: '#374151', marginBottom: 10 }}>
            Submission settings
          </div>
          <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-end' }}>
            <div className="form-group" style={{ marginBottom: 0 }}>
              <label>Deadline — days after the period ends</label>
              <input
                type="number" min={0} max={31} value={settings.grace}
                onChange={e => { setSettings(v => ({ ...v, grace: parseInt(e.target.value) || 0 })); setSavedSettings(false); }}
                style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #D1D5DB', fontSize: 13, width: 120 }}
              />
              <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 3 }}>
                Calendar days. 0 = due on the last day of the period.
              </div>
            </div>

            <div className="form-group" style={{ marginBottom: 0 }}>
              <label>Catch-up window — days</label>
              <input
                type="number" min={0} max={30} value={settings.catchup}
                onChange={e => { setSettings(v => ({ ...v, catchup: parseInt(e.target.value) || 0 })); setSavedSettings(false); }}
                style={{ padding: '6px 8px', borderRadius: 4, border: '1px solid #D1D5DB', fontSize: 13, width: 120 }}
              />
              <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 3 }}>
                How late a missed reminder may still be sent, once. 0 = only on the exact day.
              </div>
            </div>

            <button className="btn-add" onClick={handleSaveSettings} disabled={savingSettings}>
              {savingSettings
                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : <><i className="fa-solid fa-floppy-disk" /> Save settings</>}
            </button>
            {savedSettings && (
              <span style={{ fontSize: 13, color: '#059669' }}>
                <i className="fa-solid fa-circle-check" style={{ marginRight: 4 }} />Saved
              </span>
            )}
          </div>
        </div>
      )}

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

                    {preview && fmtFireDate(preview.dates[row.offset_days]) && (
                      <span style={{ fontSize: 11.5, color: '#6B7280' }}>
                        <i className="fa-regular fa-calendar" style={{ marginRight: 5, color: '#9CA3AF' }} />
                        {fmtFireDate(preview.dates[row.offset_days])}
                        <span style={{ color: '#9CA3AF' }}> · for {preview.name}</span>
                      </span>
                    )}

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

                  {/* Recipients. Tokens, not people: who a token resolves to is
                      worked out per employee when the reminder is sent. */}
                  <div style={{ marginBottom: 10 }}>
                    <label style={{ display: 'block', marginBottom: 5 }}>Recipients</label>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                      {[...RELATIONSHIP_RECIPIENTS.map(r => r.token),
                        ...roles.map(r => `role:${r.code}`)].map(token => {
                        const on = row.recipients.includes(token);
                        return (
                          <button
                            key={token}
                            type="button"
                            onClick={() => toggleRecipient(row._key, token)}
                            style={{
                              font: 'inherit', fontSize: 12, fontWeight: 600,
                              padding: '3px 10px', borderRadius: 20, cursor: 'pointer',
                              background:   on ? '#1D4ED8' : '#F8FAFC',
                              borderWidth: 1, borderStyle: 'solid',
                              borderColor:  on ? '#1D4ED8' : '#E2E8F0',
                              color:        on ? '#fff'    : '#475569',
                              transition: 'background .12s, border-color .12s, color .12s',
                            }}
                            title={token}
                          >
                            {on && <i className="fa-solid fa-check" style={{ fontSize: 9, marginRight: 5 }} />}
                            {recipientLabel(token, roles)}
                          </button>
                        );
                      })}
                    </div>
                    {row.recipients.length === 0 && (
                      <div style={{ fontSize: 11.5, color: '#B91C1C', marginTop: 4 }}>
                        Pick at least one — a reminder with no recipients reaches nobody.
                      </div>
                    )}
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
