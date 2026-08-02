/**
 * EditWindowConfig — Admin page for configuring timesheet edit windows.
 *
 * Single-row settings table. Shows three numeric fields:
 *   - Employee edit window (days back) — required, must be > 0
 *   - Manager edit window  (days back) — optional, NULL = unlimited
 *   - HR edit window       (days back) — optional, NULL = unlimited
 *
 * Reads the single row from time_edit_config and saves via save_time_edit_config().
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface EditConfig {
  employee_edit_window_days: number;
  manager_edit_window_days:  number | null;
  hr_edit_window_days:       number | null;
}

// ─── Helper: parse optional integer field ─────────────────────────────────────

function parseOptionalInt(val: string): number | null {
  if (!val.trim()) return null;
  const n = parseInt(val, 10);
  return isNaN(n) ? null : n;
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function EditWindowConfig() {
  const [config,  setConfig]  = useState<EditConfig>({
    employee_edit_window_days: 30,
    manager_edit_window_days: null,
    hr_edit_window_days: null,
  });
  const [loading,  setLoading]  = useState(true);
  const [saving,   setSaving]   = useState(false);
  const [error,    setError]    = useState<string | null>(null);
  const [saved,    setSaved]    = useState(false);
  const [formErrors, setFormErrors] = useState<Record<string, string>>({});

  // Local string state for optional fields (empty string = NULL)
  const [managerStr, setManagerStr] = useState('');
  const [hrStr,      setHrStr]      = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: e } = await supabase
      .from('time_edit_config')
      .select('employee_edit_window_days, manager_edit_window_days, hr_edit_window_days')
      .single();
    if (e) { setError(e.message); setLoading(false); return; }
    const cfg = data as EditConfig;
    setConfig(cfg);
    setManagerStr(cfg.manager_edit_window_days == null ? '' : String(cfg.manager_edit_window_days));
    setHrStr(cfg.hr_edit_window_days == null ? '' : String(cfg.hr_edit_window_days));
    setLoading(false);
  }, []);

  useEffect(() => { const t = setTimeout(load, 0); return () => clearTimeout(t); }, [load]);

  async function handleSave(e: React.FormEvent) {
    e.preventDefault();
    const errs: Record<string, string> = {};

    if (!config.employee_edit_window_days || config.employee_edit_window_days <= 0) {
      errs.employee = 'Must be a positive number of days.';
    }

    const managerDays = parseOptionalInt(managerStr);
    const hrDays      = parseOptionalInt(hrStr);

    if (managerStr.trim() && (managerDays == null || managerDays <= 0)) {
      errs.manager = 'Must be a positive number of days, or leave blank for unlimited.';
    }
    if (hrStr.trim() && (hrDays == null || hrDays <= 0)) {
      errs.hr = 'Must be a positive number of days, or leave blank for unlimited.';
    }

    if (Object.keys(errs).length) { setFormErrors(errs); return; }
    setFormErrors({});
    setSaving(true);

    const { data, error: err } = await supabase.rpc('save_time_edit_config', {
      p_employee_days: config.employee_edit_window_days,
      p_manager_days:  managerDays,
      p_hr_days:       hrDays,
    });
    setSaving(false);

    if (err || !data?.ok) {
      setError(data?.message ?? err?.message ?? 'Unknown error.');
      return;
    }
    setSaved(true);
    await load();
    setTimeout(() => setSaved(false), 3000);
  }

  if (loading) {
    return (
      <div className="ar-panel" style={{ textAlign: 'center', padding: 40, color: '#9CA3AF' }}>
        <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 8 }} />Loading config…
      </div>
    );
  }

  return (
    <div className="ar-panel">
      <h2 className="page-title">Edit Window Config</h2>
      <p className="page-subtitle">
        Controls how far back each role can edit timesheet entries. These limits apply
        regardless of timesheet status — a timesheet reverted to "To Be Submitted" is still
        subject to the employee's window.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      <div className="rd-form-card" style={{ maxWidth: 560 }}>
        <form onSubmit={handleSave}>

          {/* ── Employee window ──────────────────────────────────────────────── */}
          <div style={{ marginBottom: 24, paddingBottom: 24, borderBottom: '1px solid #F3F4F6' }}>
            <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16 }}>
              <div style={{
                width: 40, height: 40, borderRadius: 20,
                background: '#DBEAFE', color: '#1D4ED8',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                flexShrink: 0, fontSize: 16,
              }}>
                <i className="fa-solid fa-user" />
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 600, color: '#111827', marginBottom: 4 }}>Employee</div>
                <div style={{ fontSize: 13, color: '#6B7280', marginBottom: 10 }}>
                  Employees can edit their own entries within this many calendar days in the past.
                </div>
                <div className={`form-group${formErrors.employee ? ' form-group--error' : ''}`} style={{ maxWidth: 180 }}>
                  <label>Days Back</label>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <input
                      type="number" min={1} max={365}
                      value={config.employee_edit_window_days}
                      onChange={e => {
                        setConfig(p => ({ ...p, employee_edit_window_days: parseInt(e.target.value, 10) || 0 }));
                        setFormErrors(p => ({ ...p, employee: '' }));
                        setSaved(false);
                      }}
                      style={{ width: 100 }}
                    />
                    <span style={{ fontSize: 13, color: '#6B7280' }}>days</span>
                  </div>
                  {formErrors.employee && (
                    <small className="field-error">
                      <i className="fa-solid fa-circle-exclamation" /> {formErrors.employee}
                    </small>
                  )}
                </div>
              </div>
            </div>
          </div>

          {/* ── Manager window ───────────────────────────────────────────────── */}
          <div style={{ marginBottom: 24, paddingBottom: 24, borderBottom: '1px solid #F3F4F6' }}>
            <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16 }}>
              <div style={{
                width: 40, height: 40, borderRadius: 20,
                background: '#D1FAE5', color: '#065F46',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                flexShrink: 0, fontSize: 16,
              }}>
                <i className="fa-solid fa-users" />
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 600, color: '#111827', marginBottom: 4 }}>Manager</div>
                <div style={{ fontSize: 13, color: '#6B7280', marginBottom: 10 }}>
                  How far back a manager can edit team timesheets. Leave blank for no time restriction.
                </div>
                <div className={`form-group${formErrors.manager ? ' form-group--error' : ''}`} style={{ maxWidth: 240 }}>
                  <label>Days Back (blank = unlimited)</label>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <input
                      type="number" min={1} max={730}
                      placeholder="Unlimited"
                      value={managerStr}
                      onChange={e => { setManagerStr(e.target.value); setFormErrors(p => ({ ...p, manager: '' })); setSaved(false); }}
                      style={{ width: 130 }}
                    />
                    <span style={{ fontSize: 13, color: '#6B7280' }}>days</span>
                  </div>
                  {formErrors.manager && (
                    <small className="field-error">
                      <i className="fa-solid fa-circle-exclamation" /> {formErrors.manager}
                    </small>
                  )}
                </div>
              </div>
            </div>
          </div>

          {/* ── HR window ────────────────────────────────────────────────────── */}
          <div style={{ marginBottom: 28 }}>
            <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16 }}>
              <div style={{
                width: 40, height: 40, borderRadius: 20,
                background: '#FEF3C7', color: '#92400E',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                flexShrink: 0, fontSize: 16,
              }}>
                <i className="fa-solid fa-shield-halved" />
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 600, color: '#111827', marginBottom: 4 }}>HR</div>
                <div style={{ fontSize: 13, color: '#6B7280', marginBottom: 10 }}>
                  How far back HR can edit any timesheet. Leave blank for no time restriction.
                </div>
                <div className={`form-group${formErrors.hr ? ' form-group--error' : ''}`} style={{ maxWidth: 240 }}>
                  <label>Days Back (blank = unlimited)</label>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <input
                      type="number" min={1} max={730}
                      placeholder="Unlimited"
                      value={hrStr}
                      onChange={e => { setHrStr(e.target.value); setFormErrors(p => ({ ...p, hr: '' })); setSaved(false); }}
                      style={{ width: 130 }}
                    />
                    <span style={{ fontSize: 13, color: '#6B7280' }}>days</span>
                  </div>
                  {formErrors.hr && (
                    <small className="field-error">
                      <i className="fa-solid fa-circle-exclamation" /> {formErrors.hr}
                    </small>
                  )}
                </div>
              </div>
            </div>
          </div>

          {/* ── Save ─────────────────────────────────────────────────────────── */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, paddingTop: 4 }}>
            <button type="submit" className="btn-add" disabled={saving}>
              {saving
                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : <><i className="fa-solid fa-floppy-disk" /> Save Config</>
              }
            </button>

            {saved && (
              <span style={{ color: '#10B981', fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
                <i className="fa-solid fa-circle-check" /> Saved
              </span>
            )}
          </div>
        </form>
      </div>

      {/* ── Info box ─────────────────────────────────────────────────────────── */}
      <div style={{
        marginTop: 24, padding: '12px 16px', borderRadius: 8,
        background: '#F0FDF4', border: '1px solid #BBF7D0',
        fontSize: 13, color: '#14532D',
      }}>
        <i className="fa-solid fa-circle-info" style={{ marginRight: 8 }} />
        These windows are enforced server-side on every write RPC — changing them here takes effect
        immediately for all subsequent saves, even for timesheets already in progress.
      </div>
    </div>
  );
}
