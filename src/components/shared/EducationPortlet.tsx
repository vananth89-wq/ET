/**
 * EducationPortlet
 *
 * Satellite portlet for employee_education records.
 * Add / Edit form is inline (no modal) — same UX as Identification in EmployeeEditPanel.
 *
 * Used in:
 *   • MyProfile/index.tsx      — ESS self-service (read-only view + workflow gating)
 *   • EmployeeEditPanel.tsx    — HR direct-edit
 *   • AddEmployee.tsx          — hire wizard (isNewHire=true)
 *
 * RPCs consumed (mig 395–396):
 *   get_employee_education(p_employee_id, p_include_inactive?)
 *     → { ok, education: [...] }
 *   upsert_education(p_employee_id, p_education_data, p_education_id?)
 *     → { ok, workflow, education_id?, instance_id?, pending_change_id? }
 *   remove_education(p_employee_id, p_education_id)
 *     → { ok, workflow, ... }
 */

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { randomUUID } from '../../utils/randomUUID';

// ─────────────────────────────────────────────────────────────────────────────
// Types (re-exported so ApproverInbox / WorkflowReview can import them)
// ─────────────────────────────────────────────────────────────────────────────

export interface EduAttachment {
  id?: string;
  education_id?: string;
  employee_id?: string;
  document_type: string;
  file_name: string;
  original_file_name: string;
  file_path: string;
  mime_type: string;
  file_size: number;
  is_active?: boolean;
  uploaded_at?: string;
  _file?: File;
  _localUrl?: string;
  _removed?: boolean;
}

export interface EducationRecord {
  id: string;
  employee_id: string;
  education_level: string;
  degree: string;
  institution: string;
  start_date: string;
  end_date?: string;
  completion_status: string;
  grade_or_gpa?: string;
  is_highest_qualification: boolean;
  is_active: boolean;
  created_at: string;
  attachments: EduAttachment[];
}

interface InlineFormState {
  education_level: string;
  degree: string;
  institution: string;
  start_date: string;
  end_date: string;
  completion_status: string;
  grade_or_gpa: string;
  is_highest_qualification: boolean;
  attachments: EduAttachment[];
}

export interface EducationPortletProps {
  employeeId:    string;
  readOnly?:     boolean;
  canCreate?:    boolean;
  canEdit?:      boolean;
  canDelete?:    boolean;
  pendingCount?: number;
  onChanged?:    () => void;
  /** Called after every load, add, or delete with the current active record count.
   *  Use this to track whether the employee has ≥1 education record. */
  onRecordCountChange?: (hasRecords: boolean) => void;
  isNewHire?:    boolean;
  /** Hire wizard: ref wired to submit the open inline form (called by Next / Save Draft). */
  saveTriggerRef?: React.MutableRefObject<(() => Promise<boolean>) | null>;
  editMode?:     boolean;
  sectionTitle?: {
    icon:            string;
    text:            string;
    pending?:        number;
    onViewProgress?: () => void;
  };
  hideToolbar?:  boolean;
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const HR_BUCKET       = 'hr-attachments';
const COMPLETED_CODE  = 'ES01';
const PURSUING_CODE   = 'ES02';

function todayISO() { return new Date().toISOString().slice(0, 10); }

function fmtDate(iso?: string | null): string {
  if (!iso) return '—';
  return new Date(iso + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

function fmtDateRange(start?: string | null, end?: string | null): string {
  if (!start) return '—';
  return end ? `${fmtDate(start)} – ${fmtDate(end)}` : `${fmtDate(start)} – Present`;
}

const BLANK_FORM: InlineFormState = {
  education_level: '', degree: '', institution: '',
  start_date: '', end_date: '', completion_status: '',
  grade_or_gpa: '', is_highest_qualification: false, attachments: [],
};

// ─────────────────────────────────────────────────────────────────────────────
// StatusBadge
// ─────────────────────────────────────────────────────────────────────────────

const STATUS_COLORS: Record<string, { bg: string; text: string }> = {
  ES01: { bg: '#D1FAE5', text: '#065F46' },
  ES02: { bg: '#DBEAFE', text: '#1E3A8A' },
  ES03: { bg: '#FEE2E2', text: '#991B1B' },
  ES04: { bg: '#FEF3C7', text: '#92400E' },
};

function StatusBadge({ code, label }: { code: string; label: string }) {
  const c = STATUS_COLORS[code] ?? { bg: '#F3F4F6', text: '#374151' };
  return (
    <span style={{ fontSize: 11, fontWeight: 600, borderRadius: 5, padding: '2px 8px', background: c.bg, color: c.text, whiteSpace: 'nowrap' }}>
      {label}
    </span>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// AttachmentRowReadOnly
// ─────────────────────────────────────────────────────────────────────────────

function AttachmentRowReadOnly({ att, docTypeLabel }: { att: EduAttachment; docTypeLabel: string }) {
  const [url, setUrl] = useState<string | null>(att._localUrl ?? null);
  useEffect(() => {
    if (att._localUrl || !att.file_path) return;
    supabase.storage.from(HR_BUCKET).createSignedUrl(att.file_path, 3600)
      .then(({ data }) => { if (data?.signedUrl) setUrl(data.signedUrl); });
  }, [att.file_path, att._localUrl]);
  const icon = (att.mime_type || '').includes('pdf') ? 'fa-file-pdf' : 'fa-file-image';
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: '#F9FAFB', border: '1px solid #E5E7EB', borderRadius: 6, padding: '6px 10px', fontSize: 12 }}>
      <i className={`fa-regular ${icon}`} style={{ color: '#6366F1', fontSize: 14, flexShrink: 0 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {att.original_file_name || att.file_name}
        </div>
        <div style={{ color: '#9CA3AF', fontSize: 10.5 }}>{docTypeLabel}</div>
      </div>
      {url && (
        <div style={{ display: 'flex', gap: 6, flexShrink: 0 }}>
          <a href={url} target="_blank" rel="noreferrer"
            style={{ width: 28, height: 28, borderRadius: 6, background: '#F3F4F6', border: '1px solid #E5E7EB',
              display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#374151', textDecoration: 'none' }}
            title="View">
            <i className="fa-solid fa-eye" style={{ fontSize: 12 }} />
          </a>
          <a href={url} download={att.original_file_name || att.file_name}
            target="_blank" rel="noreferrer"
            style={{ width: 28, height: 28, borderRadius: 6, background: '#F3F4F6', border: '1px solid #E5E7EB',
              display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#374151', textDecoration: 'none' }}
            title="Download">
            <i className="fa-solid fa-download" style={{ fontSize: 12 }} />
          </a>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// EducationCard — one record in read/view mode
// ─────────────────────────────────────────────────────────────────────────────

function EducationCard({
  record, levelLabel, statusLabel, statusCode, docTypeLabels,
  canEdit, canDelete, pending, onEdit, onDelete,
}: {
  record: EducationRecord; levelLabel: string; statusLabel: string; statusCode: string;
  docTypeLabels: Record<string, string>; canEdit: boolean; canDelete: boolean;
  pending: boolean; onEdit: () => void; onDelete: () => void;
}) {
  const [deleting, setDeleting] = useState(false);
  const activeAtts = (record.attachments ?? []).filter(a => a.is_active !== false);

  return (
    <div style={{
      border: `1.5px solid ${record.is_highest_qualification ? '#6366F1' : '#E5E7EB'}`,
      borderRadius: 10, background: '#fff', overflow: 'hidden', marginBottom: 12,
    }}>
      {/* Header — matches BankViewCard */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '12px 14px', borderBottom: '1px solid #F3F4F6',
      }}>
        <i className="fa-solid fa-graduation-cap" style={{ color: '#6366F1', fontSize: 16, flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 600, fontSize: 14, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {record.degree}
          </div>
          <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
            {levelLabel} · {record.institution}
          </div>
        </div>
        {/* Badges */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0 }}>
          <StatusBadge code={statusCode} label={statusLabel} />
          {record.is_highest_qualification && (
            <span style={{ background: '#EEF2FF', color: '#4F46E5', borderRadius: 5, padding: '2px 8px', fontSize: 11, fontWeight: 700 }}>
              ⭐ Highest
            </span>
          )}
        </div>
        {/* Action buttons */}
        {!pending && (canEdit || canDelete) && (
          <div style={{ display: 'flex', gap: 4, flexShrink: 0 }}>
            {canEdit && (
              <button type="button" onClick={onEdit} title="Edit" style={{
                background: 'none', border: '1px solid #E5E7EB', borderRadius: 6,
                cursor: 'pointer', color: '#6B7280', padding: '4px 8px',
                display: 'inline-flex', alignItems: 'center', fontSize: 12,
              }}>
                <i className="fa-solid fa-pen" style={{ fontSize: 11 }} />
              </button>
            )}
            {canDelete && (
              <button type="button" disabled={deleting} onClick={async () => { if (!window.confirm('Remove this education record?')) return; setDeleting(true); onDelete(); }} title="Delete" style={{
                background: 'none', border: '1px solid #E5E7EB', borderRadius: 6,
                cursor: 'pointer', color: deleting ? '#9CA3AF' : '#EF4444', padding: '4px 8px',
                display: 'inline-flex', alignItems: 'center', fontSize: 12,
              }}>
                <i className={deleting ? 'fa-solid fa-spinner fa-spin' : 'fa-solid fa-trash-can'} style={{ fontSize: 11 }} />
              </button>
            )}
          </div>
        )}
      </div>

      {/* Field grid + documents — matches BankViewCard body */}
      <div style={{ padding: '10px 14px 14px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0 16px' }}>
          <div style={{ padding: '6px 0', borderBottom: '1px solid #F3F4F6' }}>
            <div style={{ fontSize: 10.5, color: '#9CA3AF', marginBottom: 2, fontWeight: 500, textTransform: 'uppercase', letterSpacing: 0.5 }}>Duration</div>
            <div style={{ fontSize: 13, color: '#111827', fontWeight: 500 }}>{fmtDateRange(record.start_date, record.end_date)}</div>
          </div>
          <div style={{ padding: '6px 0', borderBottom: '1px solid #F3F4F6' }}>
            <div style={{ fontSize: 10.5, color: '#9CA3AF', marginBottom: 2, fontWeight: 500, textTransform: 'uppercase', letterSpacing: 0.5 }}>Status</div>
            <div style={{ fontSize: 13, color: '#111827', fontWeight: 500 }}>{statusLabel}</div>
          </div>
          <div style={{ padding: '6px 0', borderBottom: '1px solid #F3F4F6' }}>
            <div style={{ fontSize: 10.5, color: '#9CA3AF', marginBottom: 2, fontWeight: 500, textTransform: 'uppercase', letterSpacing: 0.5 }}>Grade / GPA</div>
            <div style={{ fontSize: 13, color: '#111827', fontWeight: 500 }}>{record.grade_or_gpa || '—'}</div>
          </div>
        </div>
        {activeAtts.length > 0 && (
          <div style={{ marginTop: 10 }}>
            <div style={{ fontSize: 10.5, color: '#9CA3AF', fontWeight: 600, textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 6 }}>
              Documents
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {activeAtts.map((a, i) => (
                <AttachmentRowReadOnly key={a.id ?? i} att={a} docTypeLabel={docTypeLabels[a.document_type] ?? a.document_type} />
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// EduAttachmentEditActions — view + download buttons for edit-mode attachment rows
// Uses _localUrl for newly staged files (not yet uploaded), signed URL for existing.
function EduAttachmentEditActions({ att }: { att: EduAttachment }) {
  const [signedUrl, setSignedUrl] = useState<string | null>(null);
  useEffect(() => {
    if (att._localUrl || !att.file_path) return;
    supabase.storage.from(HR_BUCKET).createSignedUrl(att.file_path, 3600)
      .then(({ data }) => { if (data?.signedUrl) setSignedUrl(data.signedUrl); });
  }, [att.file_path, att._localUrl]);

  const url = att._localUrl ?? signedUrl;
  if (!url) return null;
  const btnStyle: React.CSSProperties = {
    width: 26, height: 26, borderRadius: 6,
    background: '#F3F4F6', border: '1px solid #E5E7EB',
    display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
    color: '#374151', textDecoration: 'none', flexShrink: 0,
  };
  return (
    <div style={{ display: 'flex', gap: 5, flexShrink: 0 }}>
      <a href={url} target="_blank" rel="noreferrer" style={btnStyle} title="View">
        <i className="fa-solid fa-eye" style={{ fontSize: 11 }} />
      </a>
      {!att._localUrl && (
        <a href={url} download={att.original_file_name || att.file_name} target="_blank" rel="noreferrer" style={btnStyle} title="Download">
          <i className="fa-solid fa-download" style={{ fontSize: 11 }} />
        </a>
      )}
    </div>
  );
}

// InlineEducationForm — inline add/edit form (no modal)
// ─────────────────────────────────────────────────────────────────────────────

function InlineEducationForm({
  employeeId,
  educationId,
  initialData,
  onSaved,
  onCancel,
  isNewHire = false,
  submitRef,
  educationLevels,
  completionStatuses,
  documentTypes,
}: {
  employeeId:    string;
  educationId:   string | null;
  initialData:   InlineFormState;
  onSaved:       (result: { workflow: boolean }) => void;
  onCancel:      () => void;
  isNewHire?:    boolean;
  /** Ref wired to this form's submit fn so the outer wizard can trigger save */
  submitRef?:    React.MutableRefObject<(() => Promise<boolean>) | null>;
  educationLevels:    Array<{ id: unknown; refId?: unknown; value: string }>;
  completionStatuses: Array<{ id: unknown; refId?: unknown; value: string }>;
  documentTypes:      Array<{ id: unknown; refId?: unknown; value: string }>;
}) {
  const [form,       setForm]       = useState<InlineFormState>(initialData);
  const [saving,     setSaving]     = useState(false);
  const [saveError,  setSaveError]  = useState('');
  const [showErrors, setShowErrors] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Always keep a ref pointing at the latest doSubmit so the outer wizard
  // doesn't capture a stale closure over an old form state.
  const latestDoSubmit = useRef(doSubmit);
  useEffect(() => { latestDoSubmit.current = doSubmit; }); // runs after every render

  useEffect(() => {
    if (!submitRef) return;
    submitRef.current = () => latestDoSubmit.current();
    return () => { if (submitRef) submitRef.current = null; };
  }, [submitRef]);

  function set<K extends keyof InlineFormState>(key: K, value: InlineFormState[K]) {
    setForm(prev => ({ ...prev, [key]: value }));
    setSaveError(''); // clear stale error on any change
  }

  const isPursuing  = form.completion_status === PURSUING_CODE;
  const isCompleted = form.completion_status === COMPLETED_CODE;

  function handleStatusChange(val: string) {
    set('completion_status', val);
    if (val === PURSUING_CODE) set('end_date', '');
  }

  function handleFileAdd(e: React.ChangeEvent<HTMLInputElement>) {
    const files = Array.from(e.target.files ?? []);
    const staged: EduAttachment[] = files.map(f => ({
      document_type: '', file_name: f.name, original_file_name: f.name,
      file_path: '', mime_type: f.type, file_size: f.size,
      _file: f, _localUrl: URL.createObjectURL(f),
    }));
    set('attachments', [...form.attachments, ...staged]);
    e.target.value = '';
  }

  function removeAttachment(idx: number) {
    const updated = form.attachments.map((a, i) => {
      if (i !== idx) return a;
      return a._file ? null : { ...a, _removed: true };
    }).filter(Boolean) as EduAttachment[];
    set('attachments', updated);
  }

  function setDocType(idx: number, refId: string) {
    set('attachments', form.attachments.map((a, i) => i === idx ? { ...a, document_type: refId } : a));
  }

  const visibleAtts = form.attachments.filter(a => !a._removed);

  function validate(): string | null {
    if (!form.education_level)    return 'Education Level is required.';
    if (!form.degree.trim())      return 'Degree is required.';
    if (!form.institution.trim()) return 'Institution is required.';
    if (!form.start_date)         return 'Start Date is required.';
    if (!form.completion_status)  return 'Completion Status is required.';
    if (form.start_date) {
      const yr = new Date(form.start_date + 'T00:00:00').getFullYear();
      if (yr < 1900 || yr > 2100) return 'Start Date year looks incorrect — please check.';
    }
    if (form.end_date) {
      const yr = new Date(form.end_date + 'T00:00:00').getFullYear();
      if (yr < 1900 || yr > 2100) return 'End Date year looks incorrect — please check.';
    }
    if (form.end_date && form.end_date < form.start_date) return 'End Date must be on or after Start Date.';
    if (isCompleted) {
      if (!form.end_date) return 'End Date is required for Completed qualifications.';
      if (form.end_date > todayISO()) return 'End Date cannot be in the future for Completed.';
    }
    if (visibleAtts.some(a => !a.document_type)) return 'Please select a Document Type for each attachment.';
    return null;
  }

  async function uploadStagedFiles(attachments: EduAttachment[], stageId: string): Promise<EduAttachment[]> {
    return Promise.all(attachments.map(async (att): Promise<EduAttachment> => {
      if (!att._file) return att;
      const ts   = Date.now();
      const path = `education/${employeeId}/${stageId}/${ts}_${att.file_name}`;
      const { error } = await supabase.storage.from(HR_BUCKET).upload(path, att._file, { upsert: false });
      if (error) throw new Error(`Upload failed for ${att.file_name}: ${error.message}`);
      return { ...att, file_path: path, _file: undefined, _localUrl: undefined };
    }));
  }

  // Core submit logic — called by form onSubmit AND by saveTriggerRef
  async function doSubmit(): Promise<boolean> {
    setShowErrors(true);
    const err = validate();
    if (err) { setSaveError(err); return false; }
    setSaving(true);
    setSaveError('');
    try {
      const crypto = window.crypto ?? (window as unknown as { msCrypto: Crypto }).msCrypto;
      const stageId = educationId ?? `_new_${randomUUID()}`;
      const withPaths = await uploadStagedFiles(form.attachments.filter(a => !a._removed), stageId);
      const allAtts = [...withPaths, ...form.attachments.filter(a => a._removed && !a._file)];
      const payload = {
        education_level:          form.education_level,
        degree:                   form.degree.trim(),
        institution:              form.institution.trim(),
        start_date:               form.start_date,
        end_date:                 form.end_date || null,
        completion_status:        form.completion_status,
        grade_or_gpa:             form.grade_or_gpa.trim() || null,
        is_highest_qualification: form.is_highest_qualification,
        attachments: allAtts.map(a => ({
          ...(a.id ? { id: a.id } : {}),
          document_type: a.document_type, file_name: a.file_name,
          original_file_name: a.original_file_name, file_path: a.file_path,
          mime_type: a.mime_type, file_size: a.file_size,
          ...(a._removed ? { _removed: true } : {}),
        })),
      };
      const { data, error: rpcErr } = await supabase.rpc('upsert_education', {
        p_employee_id: employeeId, p_education_data: payload,
        p_education_id: educationId ?? undefined,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      const result = data as { ok: boolean; workflow?: boolean; error?: string; message?: string } | null;
      if (!result?.ok) throw new Error(result?.message ?? result?.error ?? 'Save failed.');
      onSaved({ workflow: result.workflow ?? false });
      return true;
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : 'An unexpected error occurred.');
      return false;
    } finally {
      setSaving(false);
    }
  }

  const fe = (cond: boolean) => cond ? { border: '1.5px solid #FCA5A5' } : {};

  return (
    <div
      role="form"
      onKeyDown={e => { if (e.key === 'Enter' && (e.target as HTMLElement).tagName !== 'TEXTAREA') { e.preventDefault(); doSubmit(); } }}
      style={{
        border: '2px solid #6366F1', borderRadius: 10,
        background: '#FAFAFE', marginBottom: 10, overflow: 'hidden',
      }}
    >
      {/* Form header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', borderBottom: '1px solid #E0E7FF', background: '#EEF2FF' }}>
        <i className="fa-solid fa-graduation-cap" style={{ color: '#4F46E5', fontSize: 15 }} />
        <span style={{ fontWeight: 700, fontSize: 14, color: '#1E1B4B', flex: 1 }}>
          {educationId ? 'Edit Education Record' : 'Add Education Record'}
        </span>
        <button type="button" onClick={onCancel} style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 16, padding: '2px 4px' }}>
          <i className="fa-solid fa-xmark" />
        </button>
      </div>

      <div style={{ padding: '16px 14px' }}>
        {/* Row 1: Level + Degree */}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
          <div className={`form-group ${showErrors && !form.education_level ? 'form-group--error' : ''}`}>
            <label><i className="fa-solid fa-layer-group fa-fw" /> Education Level *</label>
            <select value={form.education_level} onChange={e => set('education_level', e.target.value)} style={fe(showErrors && !form.education_level)}>
              <option value="">-- Select Level --</option>
              {educationLevels.map(p => <option key={String(p.id)} value={String(p.refId ?? p.id)}>{p.value}</option>)}
            </select>
            {showErrors && !form.education_level && <div className="field-error">Required</div>}
          </div>
          <div className={`form-group ${showErrors && !form.degree.trim() ? 'form-group--error' : ''}`}>
            <label><i className="fa-solid fa-scroll fa-fw" /> Degree *</label>
            <input type="text" value={form.degree} onChange={e => set('degree', e.target.value)} placeholder="e.g. B.Tech in Computer Science" style={fe(showErrors && !form.degree.trim())} />
            {showErrors && !form.degree.trim() && <div className="field-error">Required</div>}
          </div>
        </div>

        {/* Row 2: Institution (full width) */}
        <div style={{ marginBottom: 12 }}>
          <div className={`form-group ${showErrors && !form.institution.trim() ? 'form-group--error' : ''}`}>
            <label><i className="fa-solid fa-building-columns fa-fw" /> Institution *</label>
            <input type="text" value={form.institution} onChange={e => set('institution', e.target.value)} placeholder="e.g. Anna University" style={fe(showErrors && !form.institution.trim())} />
            {showErrors && !form.institution.trim() && <div className="field-error">Required</div>}
          </div>
        </div>

        {/* Row 3: Start Date + End Date + Status */}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12, marginBottom: 12 }}>
          <div className={`form-group ${showErrors && !form.start_date ? 'form-group--error' : ''}`}>
            <label><i className="fa-solid fa-calendar-plus fa-fw" /> Start Date *</label>
            <input type="date" value={form.start_date} onChange={e => set('start_date', e.target.value)} min="1900-01-01" max="2100-12-31" style={fe(showErrors && !form.start_date)} />
            {showErrors && !form.start_date && <div className="field-error">Required</div>}
          </div>
          <div className={`form-group ${showErrors && isCompleted && !form.end_date ? 'form-group--error' : ''}`}>
            <label>
              <i className="fa-solid fa-calendar-check fa-fw" /> End Date{isCompleted && <span style={{ color: '#EF4444' }}> *</span>}
            </label>
            <input
              type="date" value={form.end_date}
              onChange={e => set('end_date', e.target.value)}
              disabled={isPursuing}
              min="1900-01-01"
              max={isCompleted ? todayISO() : '2100-12-31'}
              style={{ ...(isPursuing ? { opacity: 0.5, cursor: 'not-allowed' } : {}), ...(showErrors && isCompleted && !form.end_date ? fe(true) : {}) }}
            />
            {showErrors && isCompleted && !form.end_date && <div className="field-error">Required for Completed</div>}
          </div>
          <div className={`form-group ${showErrors && !form.completion_status ? 'form-group--error' : ''}`}>
            <label><i className="fa-solid fa-circle-check fa-fw" /> Status *</label>
            <select value={form.completion_status} onChange={e => handleStatusChange(e.target.value)} style={fe(showErrors && !form.completion_status)}>
              <option value="">-- Select Status --</option>
              {completionStatuses.map(p => <option key={String(p.id)} value={String(p.refId ?? p.id)}>{p.value}</option>)}
            </select>
            {showErrors && !form.completion_status && <div className="field-error">Required</div>}
          </div>
        </div>

        {/* Row 4: Grade + Highest Qual */}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 14 }}>
          <div className="form-group">
            <label><i className="fa-solid fa-star-half-stroke fa-fw" /> Grade / GPA</label>
            <input type="text" value={form.grade_or_gpa} onChange={e => set('grade_or_gpa', e.target.value)} placeholder="e.g. First Class, 3.8/4.0" />
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', paddingBottom: 2 }}>
            <label style={{
              display: 'flex', alignItems: 'flex-start', gap: 10, cursor: 'pointer',
              padding: '9px 12px',
              border: `1.5px solid ${form.is_highest_qualification ? '#6366F1' : '#E5E7EB'}`,
              borderRadius: 8,
              background: form.is_highest_qualification ? '#EEF2FF' : '#F9FAFB',
            }}>
              <input
                type="checkbox" checked={form.is_highest_qualification}
                onChange={e => set('is_highest_qualification', e.target.checked)}
                style={{ marginTop: 2, accentColor: '#4F46E5', flexShrink: 0 }}
              />
              <div>
                <div style={{ fontSize: 13, fontWeight: 600, color: form.is_highest_qualification ? '#4338CA' : '#374151' }}>
                  <i className="fa-solid fa-star fa-fw" style={{ color: '#F59E0B', marginRight: 4 }} />
                  Highest Qualification
                </div>
                {form.is_highest_qualification && (
                  <div style={{ fontSize: 11, color: '#6B7280', marginTop: 2, lineHeight: 1.4 }}>
                    Previous highest will be replaced.
                  </div>
                )}
              </div>
            </label>
          </div>
        </div>

        {/* Attachments */}
        <div style={{ marginBottom: 4 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
            <span style={{ fontSize: 12, fontWeight: 600, color: '#374151', textTransform: 'uppercase', letterSpacing: 0.5 }}>
              <i className="fa-solid fa-paperclip fa-fw" style={{ color: '#6366F1' }} /> Documents
            </span>
            <button type="button" onClick={() => fileInputRef.current?.click()}
              style={{ fontSize: 12, padding: '3px 10px', borderRadius: 6, border: '1px solid #C7D2FE', background: '#EEF2FF', color: '#4F46E5', cursor: 'pointer', fontWeight: 600 }}>
              <i className="fa-solid fa-plus" style={{ marginRight: 4 }} />Attach File
            </button>
          </div>
          <input ref={fileInputRef} type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.doc,.docx" onChange={handleFileAdd} style={{ display: 'none' }} />

          {visibleAtts.length > 0 ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {form.attachments.map((att, i) => {
                if (att._removed) return null;
                const missingType = showErrors && !att.document_type;
                return (
                  <div key={att.id ?? `_new_${i}`} style={{ background: '#F9FAFB', border: `1px solid ${missingType ? '#FCA5A5' : '#E5E7EB'}`, borderRadius: 7, padding: '8px 10px', fontSize: 12.5 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <i className={`fa-regular ${(att.mime_type || '').includes('pdf') ? 'fa-file-pdf' : 'fa-file-image'}`} style={{ color: '#6366F1', fontSize: 15, flexShrink: 0 }} />
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontWeight: 600, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{att.original_file_name || att.file_name}</div>
                        {att.file_size > 0 && <div style={{ color: '#9CA3AF', fontSize: 11 }}>{(att.file_size / 1024).toFixed(0)} KB</div>}
                      </div>
                      <EduAttachmentEditActions att={att} />
                      <button type="button" onClick={() => removeAttachment(i)} style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#EF4444', padding: '2px 4px', flexShrink: 0 }}>
                        <i className="fa-solid fa-xmark" />
                      </button>
                    </div>
                    <div style={{ marginTop: 6 }}>
                      <select value={att.document_type ?? ''} onChange={e => setDocType(i, e.target.value)}
                        style={{ fontSize: 11.5, padding: '3px 8px', borderRadius: 5, border: `1px solid ${att.document_type ? '#C7D2FE' : '#FCA5A5'}`, color: att.document_type ? '#4338CA' : '#6B7280', background: att.document_type ? '#EEF2FF' : '#fff', width: '100%' }}>
                        <option value="">-- Select Document Type * --</option>
                        {documentTypes.map(d => <option key={String(d.id)} value={String(d.refId ?? d.id)}>{d.value}</option>)}
                      </select>
                      {missingType && <div style={{ fontSize: 10.5, color: '#EF4444', marginTop: 2 }}>Document type is required</div>}
                    </div>
                  </div>
                );
              })}
            </div>
          ) : (
            <div style={{ padding: '12px', border: '1.5px dashed #E5E7EB', borderRadius: 8, textAlign: 'center', fontSize: 12.5, color: '#9CA3AF' }}>
              <i className="fa-solid fa-file-arrow-up" style={{ marginRight: 6, color: '#D1D5DB' }} />
              No documents attached.
            </div>
          )}
        </div>

        {/* Error */}
        {saveError && (
          <div style={{ margin: '12px 0 4px', padding: '8px 12px', background: '#FEE2E2', borderRadius: 7, fontSize: 12.5, color: '#B91C1C', display: 'flex', alignItems: 'flex-start', gap: 8 }}>
            <i className="fa-solid fa-circle-exclamation" style={{ marginTop: 1, flexShrink: 0 }} />
            <span>{saveError}</span>
          </div>
        )}
      </div>

      {/* Footer — hidden in hire wizard (Next / Save Draft controls saving) */}
      {!isNewHire && (
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10, padding: '12px 14px', borderTop: '1px solid #E0E7FF', background: '#F5F3FF' }}>
          <button type="button" className="emp-btn-ghost" onClick={onCancel} disabled={saving}>
            <i className="fa-solid fa-xmark" style={{ marginRight: 6 }} /> Cancel
          </button>
          <button type="button" className="emp-btn-primary" disabled={saving} onClick={() => doSubmit()}>
            {saving
              ? <><i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Saving…</>
              : <><i className="fa-solid fa-check" style={{ marginRight: 6 }} />{educationId ? 'Save Changes' : 'Add Record'}</>
            }
          </button>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// EducationPortlet
// ─────────────────────────────────────────────────────────────────────────────

export default function EducationPortlet({
  employeeId,
  readOnly     = false,
  canCreate    = true,
  canEdit      = true,
  canDelete    = true,
  pendingCount = 0,
  onChanged,
  onRecordCountChange,
  isNewHire    = false,
  saveTriggerRef,
  editMode     = false,
  sectionTitle,
  hideToolbar  = false,
}: EducationPortletProps) {
  const { picklistValues } = usePicklistValues();

  // Stable ref so load() can call the latest onRecordCountChange
  // without it being a useCallback dep (which would cause an infinite reload loop).
  const onRecordCountChangeRef = useRef(onRecordCountChange);
  useEffect(() => { onRecordCountChangeRef.current = onRecordCountChange; }, [onRecordCountChange]);

  const educationLevels    = picklistValues.filter(p => p.picklistId === 'EDUCATION_LEVEL'         && p.active !== false);
  const completionStatuses = picklistValues.filter(p => p.picklistId === 'COMPLETION_STATUS'       && p.active !== false);
  const documentTypes      = picklistValues.filter(p => p.picklistId === 'EDUCATION_DOCUMENT_TYPE' && p.active !== false);

  const levelLabels: Record<string, string>   = Object.fromEntries(educationLevels.map(p    => [String(p.refId ?? p.id), p.value]));
  const statusLabels: Record<string, string>  = Object.fromEntries(completionStatuses.map(p => [String(p.refId ?? p.id), p.value]));
  const docTypeLabels: Record<string, string> = Object.fromEntries(documentTypes.map(p      => [String(p.refId ?? p.id), p.value]));

  // Server state
  const [records,  setRecords]  = useState<EducationRecord[]>([]);
  const [loading,  setLoading]  = useState(true);
  const [loadErr,  setLoadErr]  = useState('');

  // Inline form state — null = closed, string = editing that record id, 'new' = add mode
  const [inlineTarget, setInlineTarget] = useState<string | 'new' | null>(null);
  const [deleteError,  setDeleteError]  = useState('');
  const [successMsg,   setSuccessMsg]   = useState('');

  const load = useCallback(async () => {
    if (!employeeId) return;
    setLoading(true); setLoadErr('');
    const { data, error } = await supabase.rpc('get_employee_education', { p_employee_id: employeeId, p_include_inactive: false });
    if (error) { setLoadErr(error.message); setLoading(false); return; }
    const payload = data as { ok: boolean; education: EducationRecord[]; error?: string } | null;
    if (!payload?.ok) { setLoadErr(payload?.error ?? 'Failed to load education records.'); setLoading(false); return; }
    const edu = payload.education ?? [];
    setRecords(edu);
    setLoading(false);
    onRecordCountChangeRef.current?.(edu.length > 0);
  }, [employeeId]); // onRecordCountChange intentionally excluded — it's a callback, not a fetch dependency

  useEffect(() => { load(); }, [load]);

  // Auto-open inline form in editMode (hire wizard / workflow review Update).
  // • records exist  → open first record pre-populated for editing
  // • no records     → open blank add form
  // Guard fires once per editMode=true session (reset when editMode→false so
  // clicking Update again re-opens correctly).
  //
  // Deps are intentionally [editMode, loading] only:
  //   • inlineTarget excluded — Cancel (setInlineTarget(null)) must NOT re-trigger
  //   • records.length excluded — change after load must NOT re-trigger
  // recordsRef carries the latest records without being a dep.
  const autoOpenedRef = useRef(false);
  const recordsRef    = useRef(records);
  recordsRef.current  = records;            // always up-to-date, no stale closure

  useEffect(() => {
    if (!editMode) {
      autoOpenedRef.current = false;
      setInlineTarget(null);   // close any open form when exiting edit mode
      return;
    }
    if (loading || autoOpenedRef.current) return;
    autoOpenedRef.current = true;
    const first = recordsRef.current[0];
    setInlineTarget(first ? first.id : 'new');
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editMode, loading]);

  // ── Wire saveTriggerRef (hire wizard: Next / Save Draft calls this) ─────────
  // If a form is currently open, submit it. No-op if nothing is open.
  const submitOpenFormRef = useRef<(() => Promise<boolean>) | null>(null);
  useEffect(() => {
    if (!saveTriggerRef) return;
    saveTriggerRef.current = async () => {
      if (!inlineTarget) return true;          // no open form → nothing to save
      if (submitOpenFormRef.current) return submitOpenFormRef.current();
      return true;
    };
  }, [inlineTarget, saveTriggerRef]);

  async function handleDelete(record: EducationRecord) {
    setDeleteError('');
    const { data, error } = await supabase.rpc('remove_education', { p_employee_id: employeeId, p_education_id: record.id });
    if (error) { setDeleteError(error.message); return; }
    const result = data as { ok: boolean; workflow?: boolean; error?: string; message?: string } | null;
    if (!result?.ok) { setDeleteError(result?.message ?? result?.error ?? 'Delete failed.'); return; }
    if (result.workflow) setSuccessMsg('Removal submitted for approval.');
    else { setSuccessMsg('Record removed.'); onChanged?.(); }
    await load();
    setTimeout(() => setSuccessMsg(''), 4000);
  }

  async function handleSaved({ workflow }: { workflow: boolean }) {
    const wasEditing = inlineTarget !== 'new';
    setInlineTarget(null);
    if (workflow) setSuccessMsg('Change submitted for approval.');
    else { setSuccessMsg(wasEditing ? 'Education record updated.' : 'Education record added.'); onChanged?.(); }
    await load();
    setTimeout(() => setSuccessMsg(''), 4000);
  }

  function getInitialFormData(record: EducationRecord | null): InlineFormState {
    if (!record) return BLANK_FORM;
    return {
      education_level:          record.education_level,
      degree:                   record.degree,
      institution:              record.institution,
      start_date:               record.start_date,
      end_date:                 record.end_date ?? '',
      completion_status:        record.completion_status,
      grade_or_gpa:             record.grade_or_gpa ?? '',
      is_highest_qualification: record.is_highest_qualification,
      attachments:              record.attachments ?? [],
    };
  }

  const blocked = pendingCount > 0;

  if (loading) return (
    <div style={{ padding: '24px 20px', color: '#6B7280', fontSize: 13 }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading education records…
    </div>
  );

  if (loadErr) return (
    <div style={{ padding: '16px 20px', color: '#DC2626', fontSize: 13 }}>
      <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{loadErr}
    </div>
  );

  const editingRecord = inlineTarget && inlineTarget !== 'new'
    ? records.find(r => r.id === inlineTarget) ?? null
    : null;

  return (
    <div className="edu-portlet">

      {/* Section header (MyProfile pattern) */}
      {sectionTitle && (
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 14 }}>
          <div className="ev-section-title" style={{ display: 'flex', alignItems: 'flex-start', flexDirection: 'column', gap: 6 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <i className={`fa-solid ${sectionTitle.icon}`} /> {sectionTitle.text}
              {(sectionTitle.pending ?? 0) > 0 && (
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, background: '#FEF3C7', color: '#B45309', border: '1px solid #F59E0B', borderRadius: 10, padding: '2px 8px', fontSize: 11, fontWeight: 600, lineHeight: 1.4 }}>
                  <i className="fa-solid fa-hourglass-half" style={{ fontSize: 10 }} />Workflow Pending Approval
                </span>
              )}
            </div>
            {(sectionTitle.pending ?? 0) > 0 && sectionTitle.onViewProgress && (
              <button onClick={sectionTitle.onViewProgress} style={{ background: 'none', border: 'none', padding: 0, cursor: 'pointer', color: '#6366F1', fontSize: 12, fontWeight: 500, textDecoration: 'underline' }}>
                View progress
              </button>
            )}
          </div>
          {!readOnly && !blocked && canCreate && !inlineTarget && (
            <button type="button" className="emp-btn-ghost" style={{ fontSize: 13 }} onClick={() => setInlineTarget('new')}>
              <i className="fa-solid fa-plus" style={{ marginRight: 6 }} /> Add Education
            </button>
          )}
        </div>
      )}

      {/* Pending workflow banner */}
      {blocked && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 16px', background: '#FFFBEB', borderBottom: '1px solid #FEF3C7', fontSize: 12.5, color: '#92400E' }}>
          <i className="fa-solid fa-clock" style={{ color: '#D97706' }} />
          <span>{pendingCount > 1 ? `${pendingCount} education changes are pending approval. Editing is paused.` : 'An education change is pending approval. Editing is paused.'}</span>
        </div>
      )}

      {/* Success / delete error messages */}
      {successMsg && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 16px', background: '#D1FAE5', borderBottom: '1px solid #A7F3D0', fontSize: 12.5, color: '#065F46' }}>
          <i className="fa-solid fa-circle-check" style={{ color: '#059669' }} />{successMsg}
        </div>
      )}
      {deleteError && (
        <div style={{ margin: '10px 16px 0', padding: '8px 12px', background: '#FEE2E2', borderRadius: 6, fontSize: 12.5, color: '#B91C1C', display: 'flex', alignItems: 'center', gap: 6 }}>
          <i className="fa-solid fa-circle-exclamation" />{deleteError}
        </div>
      )}

      {/* Internal toolbar — non-hire-wizard only */}
      {!hideToolbar && !sectionTitle && !isNewHire && (
        <div style={{ padding: '12px 16px', display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderBottom: records.length > 0 ? '1px solid #F3F4F6' : 'none' }}>
          <span style={{ fontSize: 12.5, color: '#6B7280' }}>
            {records.length > 0
              ? `${records.length} record${records.length !== 1 ? 's' : ''} on file`
              : <span style={{ fontStyle: 'italic' }}>No education records on file</span>
            }
          </span>
          {!readOnly && !blocked && canCreate && !inlineTarget && (
            <button type="button" className="emp-btn-ghost" onClick={() => setInlineTarget('new')}>
              <i className="fa-solid fa-plus" style={{ marginRight: 6 }} /> Add Education
            </button>
          )}
        </div>
      )}

      {/* Record list */}
      <div style={{ padding: records.length > 0 || inlineTarget ? '12px 16px' : isNewHire ? '12px 16px' : '0 16px' }}>

        {records.length === 0 && !inlineTarget && (
          <div style={isNewHire
            ? { fontSize: 13, color: '#9CA3AF', fontStyle: 'italic', marginBottom: 4 }
            : { padding: '24px 0', textAlign: 'center' as const }
          }>
            {!isNewHire && <i className="fa-solid fa-graduation-cap" style={{ fontSize: 28, color: '#D1D5DB', marginBottom: 8, display: 'block' }} />}
            <span>No education records on file.</span>
            {/* In non-wizard mode only — wizard uses the button below */}
            {!isNewHire && !readOnly && !blocked && canCreate && (
              <div>
                <button type="button" className="emp-btn-ghost" style={{ marginTop: 10 }} onClick={() => setInlineTarget('new')}>
                  <i className="fa-solid fa-plus" style={{ marginRight: 6 }} /> Add Education
                </button>
              </div>
            )}
          </div>
        )}

        {records.map(r => {
          // If this record is being edited, show the inline form in its place
          if (inlineTarget === r.id) {
            return (
              <InlineEducationForm
                key={r.id}
                employeeId={employeeId}
                educationId={r.id}
                initialData={getInitialFormData(r)}
                onSaved={handleSaved}
                onCancel={() => setInlineTarget(null)}
                isNewHire={isNewHire}
                submitRef={submitOpenFormRef}
                educationLevels={educationLevels}
                completionStatuses={completionStatuses}
                documentTypes={documentTypes}
              />
            );
          }
          return (
            <EducationCard
              key={r.id}
              record={r}
              levelLabel={levelLabels[r.education_level] ?? r.education_level}
              statusLabel={statusLabels[r.completion_status] ?? r.completion_status}
              statusCode={r.completion_status}
              docTypeLabels={docTypeLabels}
              canEdit={!readOnly && !blocked && canEdit && !inlineTarget}
              canDelete={!readOnly && !blocked && canDelete && !inlineTarget}
              pending={blocked}
              onEdit={() => setInlineTarget(r.id)}
              onDelete={() => handleDelete(r)}
            />
          );
        })}

        {/* Add form at the bottom */}
        {inlineTarget === 'new' && (
          <InlineEducationForm
            employeeId={employeeId}
            educationId={null}
            initialData={BLANK_FORM}
            onSaved={handleSaved}
            onCancel={() => setInlineTarget(null)}
            isNewHire={isNewHire}
            submitRef={submitOpenFormRef}
            educationLevels={educationLevels}
            completionStatuses={completionStatuses}
            documentTypes={documentTypes}
          />
        )}

        {/* Hire-wizard Add button — single left-aligned button, matches Bank "Add Account" */}
        {isNewHire && !inlineTarget && !readOnly && !blocked && canCreate && (
          <button type="button" className="emp-btn-ghost" style={{ marginTop: 8 }} onClick={() => setInlineTarget('new')}>
            <i className="fa-solid fa-plus" style={{ marginRight: 6 }} /> Add Education
          </button>
        )}

        {/* Non-wizard Add Another at bottom when records exist */}
        {!isNewHire && !hideToolbar && !sectionTitle && records.length > 0 && !inlineTarget && !readOnly && !blocked && canCreate && (
          <button type="button" className="emp-btn-ghost" style={{ width: '100%', marginTop: 4, justifyContent: 'center' }} onClick={() => setInlineTarget('new')}>
            <i className="fa-solid fa-plus" style={{ marginRight: 6 }} /> Add Another
          </button>
        )}
      </div>
    </div>
  );
}
