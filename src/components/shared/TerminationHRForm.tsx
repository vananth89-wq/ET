/**
 * TerminationHRForm — HR / Admin / Manager variant
 *
 * Fields (aligned to mig 497/498 column names):
 *   separation_date (required) — the legal end-of-employment date
 *   termination_reason_code    — from TERMINATION_REASON picklist
 *   last_working_date (opt)    — defaults to separation_date; HR can set earlier (garden leave)
 *   notice_period_waived       — AUTO-SET when LWD < notice_expiry_date (not a manual checkbox)
 *   notice_period_waiver_reason — required when auto-waiver triggered (min 20 chars)
 *   eligible_for_rehire        — HR-only boolean
 *   regrettable_termination    — HR-only boolean | null
 *   comments                   — min 20 chars (50 when reason = OTHER)
 *
 * Fields intentionally NOT in the form (computed by submit_termination RPC):
 *   notice_expiry_date  — always = submission_date + notice_period_days
 *   notice_period_days  — read from employee_employment by RPC
 *
 * Design spec: docs/termination-design.md §6.3
 */

import { useState } from 'react';
import { usePicklistValuesLookup } from '../../hooks/usePicklistValues';

export interface HRFormState {
  separation_date:              string;
  termination_reason_code:      string;
  last_working_date:            string;
  notice_period_waived:         boolean;   // auto-set by form when LWD < notice_expiry
  notice_period_waiver_reason:  string;
  eligible_for_rehire:          boolean;
  regrettable_termination:      boolean | null;
  comments:                     string;
}

interface Props {
  onSubmit:          (data: HRFormState) => void;
  onCancel:          () => void;
  submitting?:       boolean;
  noticePeriodDays?: number;
}

const EMPTY: HRFormState = {
  separation_date: '', termination_reason_code: '',
  last_working_date: '',
  notice_period_waived: false, notice_period_waiver_reason: '',
  eligible_for_rehire: true, regrettable_termination: null,
  comments: '',
};

function addDays(date: Date, days: number): string {
  const d = new Date(date);
  d.setDate(d.getDate() + days);
  return d.toISOString().split('T')[0];
}

function fmtDisplay(iso: string): string {
  if (!iso) return '—';
  return new Date(iso + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

function FieldErr({ msg }: { msg?: string }) {
  if (!msg) return null;
  return (
    <small style={{ color: '#DC2626', fontSize: 12, display: 'flex', gap: 4, marginTop: 3 }}>
      <i className="fa-solid fa-circle-exclamation" />{msg}
    </small>
  );
}

export default function TerminationHRForm({ onSubmit, onCancel, submitting, noticePeriodDays = 30 }: Props) {
  const [form,      setForm]      = useState<HRFormState>(EMPTY);
  const [errors,    setErrors]    = useState<Partial<Record<keyof HRFormState, string>>>({});
  const [lwdTouched, setLwdTouched] = useState(false);

  const { getValues } = usePicklistValuesLookup();
  const reasons = getValues('TERMINATION_REASON');

  // notice_expiry_date = today + notice_period_days (display only; RPC recomputes at submission)
  const today           = new Date();
  const noticeExpiryIso = addDays(today, noticePeriodDays);

  // Effective LWD: mirrors separation_date until HR explicitly changes it
  const effectiveLwd = lwdTouched ? form.last_working_date : form.separation_date;

  // Auto-waiver: LWD < notice_expiry_date → waiver card shown + reason required
  const waiverNeeded  = Boolean(effectiveLwd && effectiveLwd < noticeExpiryIso);
  const shortfallDays = waiverNeeded && effectiveLwd
    ? Math.round((new Date(noticeExpiryIso).getTime() - new Date(effectiveLwd + 'T00:00:00').getTime()) / 86400000)
    : 0;

  function set<K extends keyof HRFormState>(field: K, value: HRFormState[K]) {
    setForm(f => ({ ...f, [field]: value }));
    setErrors(e => ({ ...e, [field]: '' }));
  }

  function setLwd(value: string) {
    setLwdTouched(true);
    set('last_working_date', value);
  }

  function validate(): boolean {
    const e: Partial<Record<keyof HRFormState, string>> = {};
    if (!form.separation_date)         e.separation_date = 'Separation date is required.';
    if (!form.termination_reason_code) e.termination_reason_code = 'Reason is required.';
    const minComments = form.termination_reason_code === 'OTHER' ? 50 : 20;
    if (!form.comments || form.comments.length < minComments)
      e.comments = `Comments must be at least ${minComments} characters.`;
    if (waiverNeeded) {
      if (!form.notice_period_waiver_reason.trim())
        e.notice_period_waiver_reason = 'Waiver justification is required when LWD is before notice expiry.';
      else if (form.notice_period_waiver_reason.trim().length < 20)
        e.notice_period_waiver_reason = 'Waiver justification must be at least 20 characters.';
    }
    setErrors(e);
    return Object.keys(e).length === 0;
  }

  function handleSubmit() {
    if (validate()) {
      onSubmit({
        ...form,
        last_working_date:           effectiveLwd,
        notice_period_waived:        waiverNeeded,
        notice_period_waiver_reason: waiverNeeded ? form.notice_period_waiver_reason.trim() : '',
      });
    }
  }

  const labelStyle = { display: 'block', fontSize: 12.5, fontWeight: 600, color: '#374151', marginBottom: 4 };
  const inputStyle = { width: '100%', padding: '8px 10px', fontSize: 13, borderRadius: 6, border: '1px solid #D1D5DB', boxSizing: 'border-box' as const };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>

      {/* Separation date + Notice Expiry (read-only computed) */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <div>
          <label style={labelStyle}>Separation Date <span style={{ color: '#DC2626' }}>*</span></label>
          <input
            type="date"
            value={form.separation_date}
            onChange={e => set('separation_date', e.target.value)}
            style={inputStyle}
          />
          <FieldErr msg={errors.separation_date} />
        </div>
        <div>
          <label style={labelStyle}>
            Notice Expiry
            <span style={{ fontWeight: 400, color: '#6B7280', marginLeft: 6 }}>
              ({noticePeriodDays} days from today · computed)
            </span>
          </label>
          <input
            type="text"
            value={fmtDisplay(noticeExpiryIso)}
            readOnly
            style={{ ...inputStyle, background: '#F9FAFB', color: '#6B7280', cursor: 'default' }}
          />
          <small style={{ color: '#6B7280', fontSize: 11, marginTop: 3, display: 'block' }}>
            Always computed by system — never user input
          </small>
        </div>
      </div>

      {/* Reason */}
      <div>
        <label style={labelStyle}>Termination Reason <span style={{ color: '#DC2626' }}>*</span></label>
        <select value={form.termination_reason_code} onChange={e => set('termination_reason_code', e.target.value)} style={inputStyle}>
          <option value="">— select —</option>
          {reasons.map(r => <option key={r.id} value={r.refId ?? r.id}>{r.value}</option>)}
        </select>
        <FieldErr msg={errors.termination_reason_code} />
      </div>

      {/* Last Working Date — optional, defaults to separation_date */}
      <div style={{ maxWidth: '50%' }}>
        <label style={labelStyle}>
          Last Working Date
          <span style={{ fontWeight: 400, color: '#6B7280', marginLeft: 6 }}>(defaults to separation date)</span>
        </label>
        <input
          type="date"
          value={effectiveLwd}
          onChange={e => setLwd(e.target.value)}
          style={inputStyle}
        />
        <small style={{ color: '#6B7280', fontSize: 11, marginTop: 3, display: 'block' }}>
          Set earlier for garden leave / notice buyout. Sets waiver if before notice expiry.
        </small>
      </div>

      {/* Auto-waiver card — shown when LWD < notice_expiry */}
      {waiverNeeded && (
        <div style={{
          background: shortfallDays <= 15 ? '#FFFBEB' : '#FEF2F2',
          border: `1.5px solid ${shortfallDays <= 15 ? '#FDE68A' : '#FECACA'}`,
          borderRadius: 8, padding: '12px 14px',
        }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <span style={{ fontWeight: 700, fontSize: 12.5, color: shortfallDays <= 15 ? '#92400E' : '#7F1D1D' }}>
              ⚠ EARLY EXIT DETECTED
            </span>
            <span style={{
              fontSize: 11, fontWeight: 700, padding: '2px 8px', borderRadius: 10,
              background: shortfallDays <= 15 ? '#FDE68A' : '#FECACA',
              color: shortfallDays <= 15 ? '#92400E' : '#7F1D1D',
            }}>
              {shortfallDays <= 15
                ? `NOTICE SHORTFALL: ${shortfallDays} DAYS`
                : `SIGNIFICANT NOTICE SHORTFALL: ${shortfallDays} DAYS`}
            </span>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '4px 16px', fontSize: 12, marginBottom: 10 }}>
            <span style={{ color: '#6B7280' }}>Notice Expiry</span>
            <span style={{ fontWeight: 600 }}>{fmtDisplay(noticeExpiryIso)}</span>
            <span style={{ color: '#6B7280' }}>Last Working Day</span>
            <span style={{ fontWeight: 600, color: shortfallDays <= 15 ? '#92400E' : '#7F1D1D' }}>{fmtDisplay(effectiveLwd)}</span>
            <span style={{ color: '#6B7280' }}>Shortfall</span>
            <span style={{ fontWeight: 700, color: shortfallDays <= 15 ? '#92400E' : '#7F1D1D' }}>{shortfallDays} days</span>
          </div>
          <p style={{ fontSize: 11.5, color: shortfallDays <= 15 ? '#92400E' : '#7F1D1D', marginBottom: 10 }}>
            The employee will leave before completing the required notice period. A business justification is required.
          </p>
          <label style={labelStyle}>
            Notice Waiver Justification <span style={{ color: '#DC2626' }}>*</span>
            <span style={{ fontWeight: 400, color: '#6B7280', marginLeft: 6 }}>
              (min 20 chars · {form.notice_period_waiver_reason.length} / 500)
            </span>
          </label>
          <textarea
            value={form.notice_period_waiver_reason}
            onChange={e => set('notice_period_waiver_reason', e.target.value)}
            maxLength={500}
            rows={3}
            placeholder="e.g. Matching payroll cut-off date, notice buyout agreed, garden leave arrangement…"
            style={{
              ...inputStyle,
              resize: 'vertical', fontFamily: 'inherit',
              border: `1px solid ${
                !form.notice_period_waiver_reason.trim()               ? '#D1D5DB'
                : form.notice_period_waiver_reason.trim().length < 20  ? '#DC2626'
                : '#16A34A'
              }`,
            }}
          />
          <FieldErr msg={errors.notice_period_waiver_reason} />
        </div>
      )}

      {/* HR-only: eligible for rehire + regrettable */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <div>
          <label style={labelStyle}>Eligible for Rehire</label>
          <select value={form.eligible_for_rehire ? 'yes' : 'no'} onChange={e => set('eligible_for_rehire', e.target.value === 'yes')} style={inputStyle}>
            <option value="yes">Yes</option>
            <option value="no">No</option>
          </select>
        </div>
        <div>
          <label style={labelStyle}>Regrettable Termination</label>
          <select
            value={form.regrettable_termination === null ? '' : form.regrettable_termination ? 'yes' : 'no'}
            onChange={e => set('regrettable_termination', e.target.value === '' ? null : e.target.value === 'yes')}
            style={inputStyle}
          >
            <option value="">— not specified —</option>
            <option value="yes">Yes</option>
            <option value="no">No</option>
          </select>
        </div>
      </div>

      {/* Comments */}
      <div>
        <label style={labelStyle}>
          Comments <span style={{ color: '#DC2626' }}>*</span>
          <span style={{ fontWeight: 400, color: '#6B7280', marginLeft: 6 }}>
            (min {form.termination_reason_code === 'OTHER' ? 50 : 20} chars · {form.comments.length} typed)
          </span>
        </label>
        <textarea
          value={form.comments}
          onChange={e => set('comments', e.target.value)}
          rows={3}
          placeholder="Reason for termination…"
          style={{ ...inputStyle, resize: 'vertical', fontFamily: 'inherit' }}
        />
        <FieldErr msg={errors.comments} />
      </div>

      {/* Actions */}
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, paddingTop: 4 }}>
        <button
          onClick={onCancel}
          disabled={submitting}
          style={{ padding: '8px 16px', fontSize: 13, borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', cursor: 'pointer', color: '#374151' }}
        >
          Cancel
        </button>
        <button
          onClick={handleSubmit}
          disabled={submitting}
          style={{ padding: '8px 18px', fontSize: 13, borderRadius: 6, background: '#DC2626', color: '#fff', border: 'none', cursor: 'pointer', fontWeight: 600 }}
        >
          {submitting
            ? <><i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Saving…</>
            : 'Review & Submit'}
        </button>
      </div>
    </div>
  );
}
