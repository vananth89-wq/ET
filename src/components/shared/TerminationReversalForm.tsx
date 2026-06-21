/**
 * TerminationReversalForm
 *
 * Form for submitting a Reverse Termination transaction.
 * Original termination must be APPROVED. Uses submit_termination_reversal().
 *
 * Design spec: docs/termination-design.md §9
 */

import { useState } from 'react';

export interface ReversalFormState {
  reversal_reason: string;
  comments:        string;
}

interface Props {
  originalTerminationDate: string;
  onSubmit:   (data: ReversalFormState) => void;
  onCancel:   () => void;
  submitting?: boolean;
}

const REVERSAL_REASONS = [
  'Data Entry Error',
  'Change in Business Decision',
  'Legal / Compliance Requirement',
  'Employee Withdrew Resignation',
  'Other',
];

function FieldErr({ msg }: { msg?: string }) {
  if (!msg) return null;
  return <small style={{ color: '#DC2626', fontSize: 12, display: 'flex', gap: 4, marginTop: 3 }}><i className="fa-solid fa-circle-exclamation" />{msg}</small>;
}

export default function TerminationReversalForm({ originalTerminationDate, onSubmit, onCancel, submitting }: Props) {
  const [form,   setForm]   = useState<ReversalFormState>({ reversal_reason: '', comments: '' });
  const [errors, setErrors] = useState<Partial<ReversalFormState>>({});

  function validate(): boolean {
    const e: Partial<ReversalFormState> = {};
    if (!form.reversal_reason) e.reversal_reason = 'Reversal reason is required.';
    if (!form.comments || form.comments.length < 20) e.comments = 'Comments must be at least 20 characters.';
    setErrors(e);
    return Object.keys(e).length === 0;
  }

  const labelStyle = { display: 'block', fontSize: 12.5, fontWeight: 600, color: '#374151', marginBottom: 4 };
  const inputStyle = { width: '100%', padding: '8px 10px', fontSize: 13, borderRadius: 6, border: '1px solid #D1D5DB', boxSizing: 'border-box' as const };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>

      {/* Context banner */}
      <div style={{ padding: '10px 14px', background: '#FFF7ED', borderRadius: 8, border: '1px solid #FED7AA', fontSize: 13, color: '#92400E' }}>
        <i className="fa-solid fa-rotate-left" style={{ marginRight: 6 }} />
        Reversing termination effective{' '}
        <strong>{new Date(originalTerminationDate + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}</strong>.
        This will reinstate the employee and reopen their employment record.
      </div>

      {/* Reversal reason */}
      <div>
        <label style={labelStyle}>Reversal Reason <span style={{ color: '#DC2626' }}>*</span></label>
        <select value={form.reversal_reason} onChange={e => { setForm(f => ({ ...f, reversal_reason: e.target.value })); setErrors(er => ({ ...er, reversal_reason: '' })); }} style={inputStyle}>
          <option value="">— select —</option>
          {REVERSAL_REASONS.map(r => <option key={r} value={r}>{r}</option>)}
        </select>
        <FieldErr msg={errors.reversal_reason} />
      </div>

      {/* Comments */}
      <div>
        <label style={labelStyle}>
          Comments <span style={{ color: '#DC2626' }}>*</span>
          <span style={{ fontWeight: 400, color: '#6B7280', marginLeft: 6 }}>(min 20 chars · {form.comments.length} typed)</span>
        </label>
        <textarea value={form.comments} onChange={e => { setForm(f => ({ ...f, comments: e.target.value })); setErrors(er => ({ ...er, comments: '' })); }}
          rows={3} placeholder="Explain why this termination is being reversed…"
          style={{ ...inputStyle, resize: 'vertical', fontFamily: 'inherit' }} />
        <FieldErr msg={errors.comments} />
      </div>

      {/* Actions */}
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, paddingTop: 4 }}>
        <button onClick={onCancel} disabled={submitting}
          style={{ padding: '8px 16px', fontSize: 13, borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', cursor: 'pointer', color: '#374151' }}>
          Cancel
        </button>
        <button onClick={() => { if (validate()) onSubmit(form); }} disabled={submitting}
          style={{ padding: '8px 18px', fontSize: 13, borderRadius: 6, background: '#7C3AED', color: '#fff', border: 'none', cursor: 'pointer', fontWeight: 600, display: 'flex', alignItems: 'center', gap: 6 }}>
          {submitting
            ? <><i className="fa-solid fa-spinner fa-spin" />Submitting…</>
            : <><i className="fa-solid fa-rotate-left" />Submit Reversal</>}
        </button>
      </div>
    </div>
  );
}
