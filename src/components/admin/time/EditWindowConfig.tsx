/**
 * EditWindowConfig — Admin page for configuring timesheet edit windows.
 *
 * Single-row settings table. Three fields, all now in WHOLE CALENDAR MONTHS:
 *   - Employee edit window (months back) — required, 0 or more
 *   - Manager edit window  (months back) — optional, blank = unlimited
 *   - HR edit window       (months back) — optional, blank = unlimited
 *
 * WHY MONTHS AND NOT DAYS (mig 730)
 *   A timesheet IS a month. A 30-day rolling boundary cut sheets in half: on
 *   11 July, 1–10 July was locked and 11–31 July was open — one document, two
 *   rules, and no way to explain it to the person looking at it. N months back
 *   closes whole sheets, which is the only unit anybody actually reasons about.
 *   0 = the current month only.
 *
 * WHAT IS ACTUALLY ENFORCED
 *   The employee window binds, on INSERT / UPDATE / DELETE, via the trigger
 *   trg_timesheet_entry_edit_window. The manager and HR windows are stored and
 *   editable but NOT yet enforced — no screen lets a manager or HR edit someone
 *   else's timesheet, so there is nothing to enforce them against. The info box
 *   at the foot of this page says so rather than implying otherwise, because
 *   the previous copy claimed all three were enforced on every write and none
 *   of them were.
 *
 * Reads the single row from time_edit_config and saves via save_time_edit_config().
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface EditConfig {
  employee_edit_window_months: number;
  manager_edit_window_months:  number | null;
  hr_edit_window_months:       number | null;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function parseOptionalInt(val: string): number | null {
  if (!val.trim()) return null;
  const n = parseInt(val, 10);
  return isNaN(n) ? null : n;
}

const MONTHS = ['January','February','March','April','May','June',
                'July','August','September','October','November','December'];

/**
 * The same arithmetic the database does in time_employee_edit_floor(), so the
 * admin can see the consequence of the number before saving it. A setting whose
 * effect you have to go and test on a timesheet is a setting people guess at.
 */
function floorLabel(months: number | null): string {
  if (months == null) return 'No limit — any month can be edited.';
  const now = new Date();
  const d   = new Date(now.getFullYear(), now.getMonth() - months, 1);
  const label = `${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
  return months === 0
    ? `Current month only — ${label}.`
    : `Back to ${label} (${months} month${months === 1 ? '' : 's'} before this one).`;
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function EditWindowConfig() {
  const [config,  setConfig]  = useState<EditConfig>({
    employee_edit_window_months: 1,
    manager_edit_window_months: null,
    hr_edit_window_months: null,
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
      .select('employee_edit_window_months, manager_edit_window_months, hr_edit_window_months')
      .single();
    if (e) { setError(e.message); setLoading(false); return; }
    const cfg = data as EditConfig;
    setConfig(cfg);
    setManagerStr(cfg.manager_edit_window_months == null ? '' : String(cfg.manager_edit_window_months));
    setHrStr(cfg.hr_edit_window_months == null ? '' : String(cfg.hr_edit_window_months));
    setLoading(false);
  }, []);

  useEffect(() => { const t = setTimeout(load, 0); return () => clearTimeout(t); }, [load]);

  async function handleSave(e: React.FormEvent) {
    e.preventDefault();
    const errs: Record<string, string> = {};

    // 0 is a legitimate answer here — "the current month only" — so the check is
    // >= 0, not > 0 as it was in days. Guarding against 0 would remove the
    // strictest setting the feature has.
    const emp = config.employee_edit_window_months;
    if (emp == null || Number.isNaN(emp) || emp < 0) {
      errs.employee = 'Must be 0 or more months. 0 means the current month only.';
    }

    const managerMonths = parseOptionalInt(managerStr);
    const hrMonths      = parseOptionalInt(hrStr);

    if (managerStr.trim() && (managerMonths == null || managerMonths < 0)) {
      errs.manager = 'Must be 0 or more months, or leave blank for unlimited.';
    }
    if (hrStr.trim() && (hrMonths == null || hrMonths < 0)) {
      errs.hr = 'Must be 0 or more months, or leave blank for unlimited.';
    }

    if (Object.keys(errs).length) { setFormErrors(errs); return; }
    setFormErrors({});
    setSaving(true);

    const { data, error: err } = await supabase.rpc('save_time_edit_config', {
      p_employee_months: emp,
      p_manager_months:  managerMonths,
      p_hr_months:       hrMonths,
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

  const previewStyle: React.CSSProperties = {
    marginTop: 8, fontSize: 12, color: '#1D4ED8',
    background: '#EFF6FF', border: '1px solid #DBEAFE',
    borderRadius: 6, padding: '6px 10px', display: 'inline-block',
  };

  return (
    <div className="ar-panel">
      <h2 className="page-title">Edit Window Config</h2>
      <p className="page-subtitle">
        Controls how many backdated months each role can still edit and submit. Windows are
        whole calendar months, because a timesheet is a whole calendar month — 0 means the
        current month only. These limits apply regardless of timesheet status: an approved
        month stays editable until its window closes.
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
                <div style={{ fontWeight: 600, color: '#111827', marginBottom: 4 }}>
                  Employee
                  <span style={{
                    marginLeft: 8, fontSize: 11, fontWeight: 600, letterSpacing: 0.3,
                    color: '#065F46', background: '#D1FAE5',
                    borderRadius: 999, padding: '2px 8px', verticalAlign: 'middle',
                  }}>ENFORCED</span>
                </div>
                <div style={{ fontSize: 13, color: '#6B7280', marginBottom: 10 }}>
                  Employees can add, change and delete their own entries in this many
                  calendar months before the current one, and re-submit them.
                </div>
                <div className={`form-group${formErrors.employee ? ' form-group--error' : ''}`} style={{ maxWidth: 200 }}>
                  <label>Months Back</label>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <input
                      type="number" min={0} max={36}
                      value={config.employee_edit_window_months}
                      onChange={e => {
                        const raw = e.target.value;
                        setConfig(p => ({
                          ...p,
                          // Empty input must not silently become 0 — 0 is a real
                          // setting, so an empty box has to read as NaN and fail
                          // validation rather than quietly locking every past month.
                          employee_edit_window_months: raw === '' ? NaN : parseInt(raw, 10),
                        }));
                        setFormErrors(p => ({ ...p, employee: '' }));
                        setSaved(false);
                      }}
                      style={{ width: 100 }}
                    />
                    <span style={{ fontSize: 13, color: '#6B7280' }}>months</span>
                  </div>
                  {formErrors.employee && (
                    <small className="field-error">
                      <i className="fa-solid fa-circle-exclamation" /> {formErrors.employee}
                    </small>
                  )}
                </div>
                {!Number.isNaN(config.employee_edit_window_months) &&
                 config.employee_edit_window_months >= 0 && (
                  <div style={previewStyle}>
                    <i className="fa-solid fa-calendar-day" style={{ marginRight: 6 }} />
                    {floorLabel(config.employee_edit_window_months)}
                  </div>
                )}
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
                <div style={{ fontWeight: 600, color: '#111827', marginBottom: 4 }}>
                  Manager
                  <span style={{
                    marginLeft: 8, fontSize: 11, fontWeight: 600, letterSpacing: 0.3,
                    color: '#92400E', background: '#FEF3C7',
                    borderRadius: 999, padding: '2px 8px', verticalAlign: 'middle',
                  }}>NOT YET ENFORCED</span>
                </div>
                <div style={{ fontSize: 13, color: '#6B7280', marginBottom: 10 }}>
                  How far back a manager will be able to edit team timesheets. Stored now,
                  applied when manager editing ships. Leave blank for no limit.
                </div>
                <div className={`form-group${formErrors.manager ? ' form-group--error' : ''}`} style={{ maxWidth: 260 }}>
                  <label>Months Back (blank = unlimited)</label>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <input
                      type="number" min={0} max={36}
                      placeholder="Unlimited"
                      value={managerStr}
                      onChange={e => { setManagerStr(e.target.value); setFormErrors(p => ({ ...p, manager: '' })); setSaved(false); }}
                      style={{ width: 130 }}
                    />
                    <span style={{ fontSize: 13, color: '#6B7280' }}>months</span>
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
                <div style={{ fontWeight: 600, color: '#111827', marginBottom: 4 }}>
                  HR
                  <span style={{
                    marginLeft: 8, fontSize: 11, fontWeight: 600, letterSpacing: 0.3,
                    color: '#92400E', background: '#FEF3C7',
                    borderRadius: 999, padding: '2px 8px', verticalAlign: 'middle',
                  }}>NOT YET ENFORCED</span>
                </div>
                <div style={{ fontSize: 13, color: '#6B7280', marginBottom: 10 }}>
                  How far back HR will be able to edit any timesheet. Stored now, applied
                  when HR editing ships. Leave blank for no limit.
                </div>
                <div className={`form-group${formErrors.hr ? ' form-group--error' : ''}`} style={{ maxWidth: 260 }}>
                  <label>Months Back (blank = unlimited)</label>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <input
                      type="number" min={0} max={36}
                      placeholder="Unlimited"
                      value={hrStr}
                      onChange={e => { setHrStr(e.target.value); setFormErrors(p => ({ ...p, hr: '' })); setSaved(false); }}
                      style={{ width: 130 }}
                    />
                    <span style={{ fontSize: 13, color: '#6B7280' }}>months</span>
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
        The <strong>employee</strong> window is enforced in the database on every add, change
        and delete, so a change here takes effect immediately — including for months already
        recorded and approved. Manager and HR windows are saved but not yet applied.
      </div>
    </div>
  );
}
