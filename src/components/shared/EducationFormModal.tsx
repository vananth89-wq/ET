import { randomUUID } from '../../utils/randomUUID';
/**
 * EducationFormModal
 *
 * Add / Edit form for a single employee_education record.
 * Called by EducationPortlet for both the "Add Education" button
 * and per-row pencil action.
 *
 * Attachments are staged to Supabase Storage under:
 *   education/{employee_id}/_new_{uuid}/{filename}
 * before the upsert_education RPC is called.  Backend never rewrites
 * these paths (same pattern as dependents/_new_* staging).
 *
 * Props
 * ─────
 * employeeId   — employee UUID
 * educationId  — UUID of record being edited; null = new record
 * initialData  — pre-filled values when editing
 * onClose      — dismiss without saving
 * onSaved      — called after a successful save (portlet will reload)
 * isNewHire    — true inside AddEmployee hire wizard (skips workflow)
 */

import { useState, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import { usePicklistValues } from '../../hooks/usePicklistValues';

// ─────────────────────────────────────────────────────────────────────────────
// Types
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
  // Pre-upload staging only — not sent to backend
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

interface FormState {
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

export interface EducationFormModalProps {
  employeeId: string;
  educationId: string | null;
  initialData?: Partial<FormState>;
  onClose: () => void;
  onSaved: (result: { workflow: boolean; educationId?: string }) => void;
  isNewHire?: boolean;
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const HR_BUCKET = 'hr-attachments';
const COMPLETED_CODE = 'ES01';
const PURSUING_CODE  = 'ES02';

// ─────────────────────────────────────────────────────────────────────────────
// AttachmentRow — one staged or saved attachment in the form
// ─────────────────────────────────────────────────────────────────────────────

function AttachmentRow({
  att,
  index,
  documentTypes,
  onRemove,
  onDocTypeChange,
  showErrors,
}: {
  att: EduAttachment;
  index: number;
  documentTypes: Array<{ id: unknown; refId?: unknown; value: string }>;
  onRemove: () => void;
  onDocTypeChange: (refId: string) => void;
  showErrors: boolean;
}) {
  const [url, setUrl] = useState<string | null>(att._localUrl ?? null);

  // Lazy-load signed URL for saved attachments
  if (!att._file && att.file_path && !url) {
    supabase.storage.from(HR_BUCKET).createSignedUrl(att.file_path, 3600)
      .then(({ data }) => { if (data?.signedUrl) setUrl(data.signedUrl); });
  }

  const icon = (att.mime_type || '').includes('pdf') ? 'fa-file-pdf' : 'fa-file-image';
  const sizeKb = att.file_size > 0 ? (att.file_size / 1024).toFixed(0) + ' KB' : '';
  const missingType = showErrors && !att.document_type;

  return (
    <div style={{
      background: '#F9FAFB',
      border: `1px solid ${missingType ? '#FCA5A5' : '#E5E7EB'}`,
      borderRadius: 7,
      padding: '8px 10px',
      fontSize: 12.5,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <i className={`fa-regular ${icon}`} style={{ color: '#6366F1', fontSize: 16, flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 600, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {att.original_file_name || att.file_name}
          </div>
          {sizeKb && <div style={{ color: '#9CA3AF', fontSize: 11 }}>{sizeKb}</div>}
        </div>
        {url && (
          <a href={url} target="_blank" rel="noreferrer"
            style={{ color: '#6366F1', fontSize: 12, textDecoration: 'none', flexShrink: 0 }}>
            <i className="fa-solid fa-eye" /> View
          </a>
        )}
        <button
          type="button"
          onClick={onRemove}
          title="Remove attachment"
          style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#EF4444', padding: '2px 4px', flexShrink: 0 }}
        >
          <i className="fa-solid fa-xmark" />
        </button>
      </div>

      {/* Document type selector */}
      <div style={{ marginTop: 6 }}>
        <select
          value={att.document_type ?? ''}
          onChange={e => onDocTypeChange(e.target.value)}
          style={{
            fontSize: 11.5,
            padding: '3px 8px',
            borderRadius: 5,
            border: `1px solid ${att.document_type ? '#C7D2FE' : '#FCA5A5'}`,
            color: att.document_type ? '#4338CA' : '#6B7280',
            background: att.document_type ? '#EEF2FF' : '#fff',
            width: '100%',
          }}
        >
          <option value="">-- Select Document Type * --</option>
          {documentTypes.map(d => (
            <option key={String(d.id)} value={String(d.refId ?? d.id)}>{d.value}</option>
          ))}
        </select>
        {missingType && (
          <div style={{ fontSize: 10.5, color: '#EF4444', marginTop: 2 }}>
            Document type is required
          </div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// EducationFormModal
// ─────────────────────────────────────────────────────────────────────────────

export default function EducationFormModal({
  employeeId,
  educationId,
  initialData,
  onClose,
  onSaved,
  isNewHire = false,
}: EducationFormModalProps) {
  const { picklistValues } = usePicklistValues();

  const educationLevels = picklistValues.filter(p => p.picklistId === 'EDUCATION_LEVEL' && p.active !== false);
  const completionStatuses = picklistValues.filter(p => p.picklistId === 'COMPLETION_STATUS' && p.active !== false);
  const documentTypes = picklistValues.filter(p => p.picklistId === 'EDUCATION_DOCUMENT_TYPE' && p.active !== false);

  const isEdit = !!educationId;

  const [form, setForm] = useState<FormState>({
    education_level:          initialData?.education_level ?? '',
    degree:                   initialData?.degree ?? '',
    institution:              initialData?.institution ?? '',
    start_date:               initialData?.start_date ?? '',
    end_date:                 initialData?.end_date ?? '',
    completion_status:        initialData?.completion_status ?? '',
    grade_or_gpa:             initialData?.grade_or_gpa ?? '',
    is_highest_qualification: initialData?.is_highest_qualification ?? false,
    attachments:              initialData?.attachments ?? [],
  });

  const [saving,     setSaving]     = useState(false);
  const [saveError,  setSaveError]  = useState('');
  const [showErrors, setShowErrors] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // ── Helpers ──────────────────────────────────────────────────────────────

  function set<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm(prev => ({ ...prev, [key]: value }));
  }

  function todayISO() {
    return new Date().toISOString().slice(0, 10);
  }

  const isPursuing   = form.completion_status === PURSUING_CODE;
  const isCompleted  = form.completion_status === COMPLETED_CODE;

  // When status switches to Pursuing, clear end_date
  function handleStatusChange(val: string) {
    set('completion_status', val);
    if (val === PURSUING_CODE) set('end_date', '');
  }

  // ── File handling ─────────────────────────────────────────────────────────

  function handleFileAdd(e: React.ChangeEvent<HTMLInputElement>) {
    const files = Array.from(e.target.files ?? []);
    const staged: EduAttachment[] = files.map(f => ({
      document_type:      '',
      file_name:          f.name,
      original_file_name: f.name,
      file_path:          '',        // filled during upload
      mime_type:          f.type,
      file_size:          f.size,
      _file:              f,
      _localUrl:          URL.createObjectURL(f),
    }));
    set('attachments', [...form.attachments, ...staged]);
    e.target.value = '';
  }

  function removeAttachment(idx: number) {
    const updated = form.attachments.map((a, i) => {
      if (i !== idx) return a;
      if (a._file) return null;           // staged: drop entirely
      return { ...a, _removed: true };    // saved: mark for removal
    }).filter(Boolean) as EduAttachment[];
    set('attachments', updated);
  }

  function setDocType(idx: number, refId: string) {
    set('attachments', form.attachments.map((a, i) =>
      i === idx ? { ...a, document_type: refId } : a
    ));
  }

  const visibleAtts = form.attachments.filter(a => !a._removed);

  // ── Validation ────────────────────────────────────────────────────────────

  function validate(): string | null {
    if (!form.education_level)  return 'Education Level is required.';
    if (!form.degree.trim())    return 'Degree is required.';
    if (!form.institution.trim()) return 'Institution is required.';
    if (!form.start_date)       return 'Start Date is required.';
    if (!form.completion_status) return 'Completion Status is required.';
    if (form.end_date && form.end_date < form.start_date) return 'End Date must be on or after Start Date.';
    if (isCompleted) {
      if (!form.end_date) return 'End Date is required for Completed qualifications.';
      if (form.end_date > todayISO()) return 'End Date cannot be in the future for Completed qualifications.';
    }
    // All visible attachments must have a document_type
    const missingDocType = visibleAtts.some(a => !a.document_type);
    if (missingDocType) return 'Please select a Document Type for each attachment.';
    return null;
  }

  // ── Upload staged files ───────────────────────────────────────────────────

  async function uploadStagedFiles(
    attachments: EduAttachment[],
    stageId: string,
  ): Promise<EduAttachment[]> {
    return Promise.all(
      attachments.map(async (att): Promise<EduAttachment> => {
        if (!att._file) return att; // already-saved attachment
        const ext  = att.file_name.split('.').pop() ?? 'bin';
        const ts   = Date.now();
        const path = `education/${employeeId}/${stageId}/${ts}_${att.file_name}`;
        const { error } = await supabase.storage.from(HR_BUCKET).upload(path, att._file, { upsert: false });
        if (error) throw new Error(`Upload failed for ${att.file_name}: ${error.message}`);
        return {
          ...att,
          file_path: path,
          _file:     undefined,
          _localUrl: undefined,
        };
      })
    );
  }

  // ── Submit ────────────────────────────────────────────────────────────────

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setShowErrors(true);
    const err = validate();
    if (err) { setSaveError(err); return; }

    setSaving(true);
    setSaveError('');

    try {
      // Stage ID: use existing educationId for edits, or a temp UUID for new records
      const crypto = window.crypto ?? (window as unknown as { msCrypto: Crypto }).msCrypto;
      const stageId = educationId ?? `_new_${randomUUID()}`;

      // 1. Upload any staged files
      const withPaths = await uploadStagedFiles(
        form.attachments.filter(a => !a._removed),
        stageId,
      );

      // 2. Build the payload — include _removed flag for soft-delete on existing
      const allAtts = [
        ...withPaths,
        ...form.attachments.filter(a => a._removed && !a._file),
      ];

      const payload = {
        education_level:          form.education_level,
        degree:                   form.degree.trim(),
        institution:              form.institution.trim(),
        start_date:               form.start_date,
        end_date:                 form.end_date || null,
        completion_status:        form.completion_status,
        grade_or_gpa:             form.grade_or_gpa.trim() || null,
        is_highest_qualification: form.is_highest_qualification,
        attachments:              allAtts.map(a => ({
          ...(a.id ? { id: a.id } : {}),
          document_type:      a.document_type,
          file_name:          a.file_name,
          original_file_name: a.original_file_name,
          file_path:          a.file_path,
          mime_type:          a.mime_type,
          file_size:          a.file_size,
          ...(a._removed ? { _removed: true } : {}),
        })),
      };

      const { data, error: rpcErr } = await supabase.rpc('upsert_education', {
        p_employee_id:    employeeId,
        p_education_data: payload,
        p_education_id:   educationId ?? undefined,
      });

      if (rpcErr) throw new Error(rpcErr.message);
      const result = data as { ok: boolean; workflow?: boolean; education_id?: string; instance_id?: string; error?: string; message?: string } | null;
      if (!result?.ok) throw new Error(result?.message ?? result?.error ?? 'Save failed.');

      onSaved({
        workflow:    result.workflow ?? false,
        educationId: result.education_id,
      });
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : 'An unexpected error occurred.');
    } finally {
      setSaving(false);
    }
  }

  // ── Field helpers ─────────────────────────────────────────────────────────

  const fe = (cond: boolean) =>
    cond ? { border: '1px solid #FCA5A5' } : {};

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    /* Overlay */
    <div
      style={{
        position: 'fixed', inset: 0,
        background: 'rgba(0,0,0,0.45)',
        zIndex: 1000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: '20px 16px',
      }}
      onMouseDown={e => { if (e.target === e.currentTarget) onClose(); }}
    >
      {/* Modal panel */}
      <div style={{
        background: '#fff',
        borderRadius: 14,
        width: '100%',
        maxWidth: 640,
        maxHeight: '90vh',
        display: 'flex',
        flexDirection: 'column',
        boxShadow: '0 20px 60px rgba(0,0,0,0.22)',
        overflow: 'hidden',
      }}>

        {/* Header */}
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          padding: '16px 20px',
          borderBottom: '1px solid #F3F4F6',
          flexShrink: 0,
        }}>
          <div style={{
            width: 36, height: 36, borderRadius: 8,
            background: '#EEF2FF',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
          }}>
            <i className="fa-solid fa-graduation-cap" style={{ color: '#4F46E5', fontSize: 16 }} />
          </div>
          <div>
            <div style={{ fontWeight: 700, fontSize: 15, color: '#111827' }}>
              {isEdit ? 'Edit Education Record' : 'Add Education Record'}
            </div>
            <div style={{ fontSize: 12, color: '#9CA3AF', marginTop: 1 }}>
              Fields marked * are required
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            style={{ marginLeft: 'auto', background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 18, padding: '4px 6px' }}
          >
            <i className="fa-solid fa-xmark" />
          </button>
        </div>

        {/* Scrollable body */}
        <form onSubmit={handleSubmit} style={{ overflowY: 'auto', flex: 1 }}>
          <div style={{ padding: '20px 20px 0' }}>

            {/* Row 1: Education Level + Degree */}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 14 }}>
              <div className={`form-group ${showErrors && !form.education_level ? 'form-group--error' : ''}`}>
                <label>
                  <i className="fa-solid fa-layer-group fa-fw" /> Education Level *
                </label>
                <select
                  value={form.education_level}
                  onChange={e => set('education_level', e.target.value)}
                  style={fe(showErrors && !form.education_level)}
                >
                  <option value="">-- Select Level --</option>
                  {educationLevels.map(p => (
                    <option key={String(p.id)} value={String(p.refId ?? p.id)}>{p.value}</option>
                  ))}
                </select>
                {showErrors && !form.education_level && <div className="field-error">Required</div>}
              </div>

              <div className={`form-group ${showErrors && !form.degree.trim() ? 'form-group--error' : ''}`}>
                <label>
                  <i className="fa-solid fa-scroll fa-fw" /> Degree *
                </label>
                <input
                  type="text"
                  value={form.degree}
                  onChange={e => set('degree', e.target.value)}
                  placeholder="e.g. B.Tech in Computer Science"
                  style={fe(showErrors && !form.degree.trim())}
                />
                {showErrors && !form.degree.trim() && <div className="field-error">Required</div>}
              </div>
            </div>

            {/* Row 2: Institution + Field of Study */}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 14 }}>
              <div className={`form-group ${showErrors && !form.institution.trim() ? 'form-group--error' : ''}`}>
                <label>
                  <i className="fa-solid fa-building-columns fa-fw" /> Institution *
                </label>
                <input
                  type="text"
                  value={form.institution}
                  onChange={e => set('institution', e.target.value)}
                  placeholder="e.g. Anna University"
                  style={fe(showErrors && !form.institution.trim())}
                />
                {showErrors && !form.institution.trim() && <div className="field-error">Required</div>}
              </div>

              <div className="form-group">
                <label>
                  <i className="fa-solid fa-book-open fa-fw" /> Field of Study
                </label>
                <input
                  type="text"
                  placeholder="e.g. Computer Science"
                />
              </div>
            </div>

            {/* Row 3: Start Date + End Date + Status */}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 14, marginBottom: 14 }}>
              <div className={`form-group ${showErrors && !form.start_date ? 'form-group--error' : ''}`}>
                <label>
                  <i className="fa-solid fa-calendar-plus fa-fw" /> Start Date *
                </label>
                <input
                  type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                  value={form.start_date}
                  onChange={e => set('start_date', e.target.value)}
                  style={fe(showErrors && !form.start_date)}
                />
                {showErrors && !form.start_date && <div className="field-error">Required</div>}
              </div>

              <div className={`form-group ${showErrors && isCompleted && !form.end_date ? 'form-group--error' : ''}`}>
                <label>
                  <i className="fa-solid fa-calendar-check fa-fw" /> End Date
                  {isCompleted && <span style={{ color: '#EF4444' }}> *</span>}
                </label>
                <input
                  type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                  value={form.end_date}
                  onChange={e => set('end_date', e.target.value)}
                  disabled={isPursuing}
                  max={isCompleted ? todayISO() : undefined}
                  title={isPursuing ? 'Not applicable while Pursuing' : undefined}
                  style={{
                    ...(isPursuing ? { opacity: 0.5, cursor: 'not-allowed' } : {}),
                    ...(showErrors && isCompleted && !form.end_date ? fe(true) : {}),
                  }}
                />
                {showErrors && isCompleted && !form.end_date && <div className="field-error">Required for Completed</div>}
              </div>

              <div className={`form-group ${showErrors && !form.completion_status ? 'form-group--error' : ''}`}>
                <label>
                  <i className="fa-solid fa-circle-check fa-fw" /> Status *
                </label>
                <select
                  value={form.completion_status}
                  onChange={e => handleStatusChange(e.target.value)}
                  style={fe(showErrors && !form.completion_status)}
                >
                  <option value="">-- Select Status --</option>
                  {completionStatuses.map(p => (
                    <option key={String(p.id)} value={String(p.refId ?? p.id)}>{p.value}</option>
                  ))}
                </select>
                {showErrors && !form.completion_status && <div className="field-error">Required</div>}
              </div>
            </div>

            {/* Row 4: Grade + Highest Qualification */}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 14 }}>
              <div className="form-group">
                <label>
                  <i className="fa-solid fa-star-half-stroke fa-fw" /> Grade / GPA
                </label>
                <input
                  type="text"
                  value={form.grade_or_gpa}
                  onChange={e => set('grade_or_gpa', e.target.value)}
                  placeholder="e.g. First Class, 3.8/4.0"
                />
              </div>

              <div style={{ display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', paddingBottom: 4 }}>
                <label style={{
                  display: 'flex', alignItems: 'flex-start', gap: 10,
                  cursor: 'pointer', padding: '10px 12px',
                  border: `1.5px solid ${form.is_highest_qualification ? '#6366F1' : '#E5E7EB'}`,
                  borderRadius: 8,
                  background: form.is_highest_qualification ? '#EEF2FF' : '#F9FAFB',
                }}>
                  <input
                    type="checkbox"
                    checked={form.is_highest_qualification}
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
                        Any previous highest qualification will be replaced.
                      </div>
                    )}
                  </div>
                </label>
              </div>
            </div>

            {/* Attachments */}
            <div style={{ marginBottom: 20 }}>
              <div style={{
                fontSize: 12, fontWeight: 600, color: '#374151', textTransform: 'uppercase',
                letterSpacing: 0.5, marginBottom: 8,
                display: 'flex', alignItems: 'center', justifyContent: 'space-between',
              }}>
                <span><i className="fa-solid fa-paperclip fa-fw" style={{ color: '#6366F1' }} /> Documents</span>
                <button
                  type="button"
                  onClick={() => fileInputRef.current?.click()}
                  style={{
                    fontSize: 12, padding: '4px 10px', borderRadius: 6,
                    border: '1px solid #C7D2FE', background: '#EEF2FF',
                    color: '#4F46E5', cursor: 'pointer', fontWeight: 600,
                  }}
                >
                  <i className="fa-solid fa-plus" style={{ marginRight: 4 }} />Attach File
                </button>
              </div>
              <input
                ref={fileInputRef}
                type="file"
                multiple
                accept=".pdf,.jpg,.jpeg,.png,.doc,.docx"
                onChange={handleFileAdd}
                style={{ display: 'none' }}
              />

              {visibleAtts.length > 0 ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  {form.attachments.map((att, i) => {
                    if (att._removed) return null;
                    return (
                      <AttachmentRow
                        key={att.id ?? `_new_${i}`}
                        att={att}
                        index={i}
                        documentTypes={documentTypes}
                        onRemove={() => removeAttachment(i)}
                        onDocTypeChange={refId => setDocType(i, refId)}
                        showErrors={showErrors}
                      />
                    );
                  })}
                </div>
              ) : (
                <div style={{
                  padding: '14px 12px', border: '1.5px dashed #E5E7EB',
                  borderRadius: 8, textAlign: 'center',
                  fontSize: 12.5, color: '#9CA3AF',
                }}>
                  <i className="fa-solid fa-file-arrow-up" style={{ marginRight: 6, color: '#D1D5DB' }} />
                  No documents attached. Click <strong>Attach File</strong> to add certificates, transcripts, etc.
                </div>
              )}
            </div>

            {/* Error banner */}
            {saveError && (
              <div style={{
                marginBottom: 16, padding: '10px 14px',
                background: '#FEE2E2', borderRadius: 7,
                fontSize: 12.5, color: '#B91C1C',
                display: 'flex', alignItems: 'flex-start', gap: 8,
              }}>
                <i className="fa-solid fa-circle-exclamation" style={{ marginTop: 1, flexShrink: 0 }} />
                <span>{saveError}</span>
              </div>
            )}

          </div>

          {/* Footer */}
          <div style={{
            display: 'flex', justifyContent: 'flex-end', gap: 10,
            padding: '14px 20px',
            borderTop: '1px solid #F3F4F6',
            background: '#FAFAFA',
            flexShrink: 0,
          }}>
            <button
              type="button"
              className="emp-btn-ghost"
              onClick={onClose}
              disabled={saving}
            >
              <i className="fa-solid fa-xmark" style={{ marginRight: 6 }} /> Cancel
            </button>
            <button
              type="submit"
              className="emp-btn-primary"
              disabled={saving}
            >
              {saving
                ? <><i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Saving…</>
                : <><i className="fa-solid fa-check" style={{ marginRight: 6 }} />{isEdit ? 'Save Changes' : 'Add Record'}</>
              }
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
