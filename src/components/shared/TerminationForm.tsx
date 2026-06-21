/**
 * TerminationForm — Self-service resignation variant (initiation_type = SELF)
 *
 * Fields:
 *   resignation_date (required, min = today + noticePeriodDays), last_working_date,
 *   notice_date, termination_reason_code (from RESIGNATION_REASON),
 *   comments (min 20 chars; 50 when reason = OTHER)
 *
 * Design spec: docs/termination-design.md §6.2
 */

import { useState } from 'react';
import { usePicklistValuesLookup } from '../../hooks/usePicklistValues';

interface FormState {
  resignation_date:        string;
  last_working_date:       string;
  termination_reason_code: string;
  comments:                string;
}

interface Props {
  onSubmit:          (data: FormState) => void;
  onCancel:          () => void;
  submitting?:       boolean;
  noticePeriodDays?: number;
  /** Override the submit button label (default: 'Review & Submit') */
  submitLabel?:      string;
  /** Hide the Cancel button — e.g. when embedded in WorkflowReview where
   *  cancel is handled by the parent action bar's Withdraw button */
  hideCancel?:       boolean;
  /** Pre-populate the form fields (amend mode) */
  initialValues?:    Partial<FormState>;
}

const EMPTY: FormState = {
  resignation_date:        '',
  last_working_date:       '',
  termination_reason_code: '',
  comments:                '',
};

function addDays(date: Date, days: number): string {
  const d = new Date(date);
  d.setDate(d.getDate() + days);
  return d.toISOString().split('T')[0];
}

function fmtDisplay(iso: string): string {
  return new Date(iso + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

function FieldErr({ msg }: { msg?: string }) {
  if (!msg) return null;
  return (
    <small style={{ color: '#DC2626', fontSize: 12, display: 'flex', alignItems: 'center', gap: 4, marginTop: 3 }}>
      <i className="fa-solid fa-circle-exclamation" />{msg}
    </small>
  );
}

export default function TerminationForm({
  onSubmit, onCancel, submitting, noticePeriodDays = 30,
  submitLabel = 'Review & Submit', hideCancel = false, initialValues,
}: Props) {
  const [form,       setForm]       = useState<FormState>({ ...EMPTY, ...initialValues });
  const [errors,     setErrors]     = useState<Partial<Record<keyof FormState, string>>>({});
  const [lwdTouched, setLwdTouched] = useState(false);

  const { getValues } = usePicklistValuesLookup();
  const reasons = getValues('RESIGNATION_REASON');

  // Earliest allowed separation date = today + notice period
  const today   = new Date();
  const minDate = addDays(today, noticePeriodDays);

  // LWD defaults to separation_date unless the user explicitly changes it.
  const effectiveLwd = lwdTouched ? form.last_working_date : form.resignation_date;

  function set(field: keyof FormState, value: string) {
    setForm(f => ({ ...f, [field]: value }));
    setErrors(e => ({ ...e, [field]: '' }));
  }

  function setLwd(value: string) {
    setLwdTouched(true);
    set('last_working_date', value);
  }

  function validate(): boolean {
    const e: Partial<Record<keyof FormState, string>> = {};
    if (!form.resignation_date) {
      e.resignation_date = 'Separation date is required.';
    } else if (form.resignation_date < minDate) {
      e.resignation_date = `Separation date must be on or after ${fmtDisplay(minDate)} (today + ${noticePeriodDays} notice days).`;
    }
    if (!form.termination_reason_code) e.termination_reason_code = 'Reason is required.';
    const minComments = form.termination_reason_code === 'OTHER' ? 50 : 20;
    if (!form.comments || form.comments.length < minComments)
      e.comments = `Comments must be at least ${minComments} characters.`;
    if (effectiveLwd && form.resignation_date && effectiveLwd < form.resignation_date)
      e.last_working_date = 'Last working date must be on or after separation date.';
    setErrors(e);
    return Object.keys(e).length === 0;
  }

  function handleSubmit() {
    if (validate()) onSubmit({ ...form, last_working_date: effectiveLwd });
  }

  const labelStyle = { display: 'block', fontSize: 12.5, fontWeight: 600, color: '#374151', marginBottom: 4 };
  const inputStyle = { width: '100%', padding: '8px 10px', fontSize: 13, borderRadius: 6, border: '1px solid #D1D5DB', boxSizing: 'border-box' as const, outline: 'none' };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>

      {/* Separation date + Notice deadline (read-only) */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <div>
          <label style={labelStyle}>Separation Date <span style={{ color: '#DC2626' }}>*</span></label>
          <input
            type="date"
            value={form.resignation_date}
            min={minDate}
            onChange={e => set('resignation_date', e.target.value)}
            style={inputStyle}
          />
          <FieldErr msg={errors.resignation_date} />
        </div>
        <div>
          <label style={labelStyle}>
            Notice Expiry
            <span style={{ fontWeight: 400, color: '#6B7280', marginLeft: 6 }}>({noticePeriodDays} days from today)</span>
          </label>
          <input
            type="text"
            value={fmtDisplay(minDate)}
            readOnly
            style={{ ...inputStyle, background: '#F9FAFB', color: '#6B7280', cursor: 'default' }}
          />
          <small style={{ color: '#6B7280', fontSize: 11, marginTop: 3, display: 'block' }}>
            Separation date must be on or after this date
          </small>
        </div>
      </div>

      {/* Last working date — read-only for SELF; mirrors separation_date (HR overrides via HR form) */}
      <div style={{ maxWidth: '50%' }}>
        <label style={labelStyle}>Last Working Date</label>
        <input
          type="date"
          value={effectiveLwd}
          readOnly
          style={{ ...inputStyle, background: '#F9FAFB', color: '#6B7280', cursor: 'default' }}
        />
        <FieldErr msg={errors.last_working_date} />
      </div>

      {/* Reason */}
      <div>
        <label style={labelStyle}>Reason for Resignation <span style={{ color: '#DC2626' }}>*</span></label>
        <select value={form.termination_reason_code} onChange={e => set('termination_reason_code', e.target.value)} style={inputStyle}>
          <option value="">— select —</option>
          {reasons.map(r => <option key={r.id} value={r.refId ?? r.id}>{r.value}</option>)}
        </select>
        <FieldErr msg={errors.termination_reason_code} />
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
          placeholder="Please provide details about your resignation…"
          style={{ ...inputStyle, resize: 'vertical', fontFamily: 'inherit' }}
        />
        <FieldErr msg={errors.comments} />
      </div>

      {/* Actions */}
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, paddingTop: 4 }}>
        {!hideCancel && (
          <button onClick={onCancel} disabled={submitting}
            style={{ padding: '8px 16px', fontSize: 13, borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', cursor: 'pointer', color: '#374151' }}>
            Cancel
          </button>
        )}
        <button onClick={handleSubmit} disabled={submitting}
          style={{ padding: '8px 18px', fontSize: 13, borderRadius: 6, background: '#2563EB', color: '#fff', border: 'none', cursor: 'pointer', fontWeight: 600 }}>
          {submitting ? <><i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Saving…</> : submitLabel}
        </button>
      </div>
    </div>
  );
}
