/**
 * DependentsPortlet — Set-Snapshot Edition
 *
 * Implements the view / draft / pending / history UX described in
 * docs/set-snapshot-design.md §7.1.
 *
 * Used in:
 *   • MyProfile/index.tsx      — ESS self-service (workflow gate)
 *   • AddEmployee.tsx          — hire flow (isNewHire=true)
 *   • EmployeeEditPanel.tsx    — admin direct-edit (editMode=true)
 *
 * RPCs consumed (set-snapshot, mig 322):
 *   get_employee_dependent_set(p_employee_id, p_as_of?)
 *     → { ok, set: {...}|null, items: [...] }
 *   submit_dependent_set(p_employee_id, p_effective_from, p_items)
 *     → { ok, workflow, instance_id|set_id, effective_from, change_summary }
 *   get_employee_dependent_set_history(p_employee_id)
 *     → { ok, sets: [...] }
 *
 * Legacy RPCs (upsert_dependent, remove_dependent, get_employee_dependents)
 * are NOT called here. They stay alive until Phase 6 cleanup.
 *
 * Locked decisions (docs/set-snapshot-design.md + memory):
 *   - effective_from snaps to 1st of month (server + client-side both)
 *   - Empty employee → no set row; first submit creates set #1
 *   - New-item attachments: staged to dependents/{emp}/_new_{uuid}/... — no path rewrite on apply
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { randomUUID } from '../../utils/randomUUID';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export interface DependentAttachment {
  id?: string;
  file_name: string;
  original_file_name?: string;
  file_path: string;           // empty until uploaded
  mime_type: string;
  file_size: number;
  document_type?: string;      // ref_id from DEPENDENT_DOCUMENT_TYPE
  is_active?: boolean;
  uploaded_at?: string;
  // Pre-upload staging only (not sent to backend)
  _file?: File;
  _localUrl?: string;
}

interface DraftAttachment extends DependentAttachment {
  _removed?: boolean;          // soft-removed in draft; filtered before submit
}

interface DependentItem {
  id?: string;
  dependent_code: string;
  relationship_type: string;
  dependent_name: string;
  date_of_birth: string;
  gender: 'Male' | 'Female';
  insurance_eligible: boolean;
  attachments: DependentAttachment[];
}

interface DependentSetInfo {
  id: string;
  employee_id: string;
  effective_from: string;
  effective_to: string;
  is_active: boolean;
  created_at: string;
}

interface DraftItem {
  _localId: string;             // stable React key, never sent to backend
  dependent_code: string | null;
  relationship_type: string;
  dependent_name: string;
  date_of_birth: string;
  gender: 'Male' | 'Female' | '';
  insurance_eligible: boolean;
  attachments: DraftAttachment[];
  // Draft state flags
  _new: boolean;
  _removed: boolean;
  _editing: boolean;
  _hasError: boolean;
  // Snapshot of original values for amendment detection
  _original: {
    relationship_type: string;
    dependent_name: string;
    date_of_birth: string;
    gender: 'Male' | 'Female';
    insurance_eligible: boolean;
    activePaths: string[];       // file_path of non-removed existing attachments
  } | null;
}

interface SetHistoryRow {
  set_id: string;
  effective_from: string;
  effective_to: string;
  is_active: boolean;
  created_at: string;
  item_count: number;
  items: Array<{
    id: string;
    dependent_code: string;
    relationship_type: string;
    dependent_name: string;
    date_of_birth: string;
    gender: 'Male' | 'Female';
    insurance_eligible: boolean;
  }>;
}

// Backward-compat export for callers that still type against the old model
export interface Dependent extends DependentItem {
  id: string;
  employee_id: string;
  effective_from: string;
  effective_to: string;
  is_active: boolean;
  inactive_at?: string;
  inactive_by?: string;
}

export interface DependentsPortletProps {
  employeeId: string;
  hireDate?: string;
  isNewHire?: boolean;
  readOnly?: boolean;
  canEdit?: boolean;
  /** In-flight pending_change count for profile_dependents from the parent. Blocks editing. */
  pendingCount?: number;
  /** @deprecated No-op in set-snapshot model — removal is by omitting the item from the submitted set. */
  canDelete?: boolean;
  onChanged?: () => void;
  /** Called after every load or submit with the current active dependent count.
   *  Use this to track whether the employee has ≥1 dependent. */
  onRecordCountChange?: (hasRecords: boolean) => void;
  /** Hire-wizard integration: call to trigger submit+validation. Returns true on success. */
  saveTriggerRef?: React.MutableRefObject<(() => Promise<boolean>) | null>;
  /** Legacy compat: auto-enter draft mode. EmployeeEditPanel uses this. */
  editMode?: boolean;
  /** Legacy compat: wired to submit fn when editMode=true. */
  saveAllRef?: React.MutableRefObject<(() => Promise<boolean>) | null>;
  // canDelete no longer needed — removal is part of the draft set (omit item from submit)
  /** WorkflowReview context: effective_from shown as display text, all cards auto-expanded, pencil hidden. */
  reviewMode?: boolean;
  /** When provided, renders title + History/Edit buttons in one row — matching Personal Info pattern. */
  sectionTitle?: {
    icon: string;
    text: string;
    pending?: number;
    onViewProgress?: () => void;
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants & helpers
// ─────────────────────────────────────────────────────────────────────────────

const HR_BUCKET = 'hr-attachments';

function fmtDate(val?: string): string {
  if (!val || val === '9999-12-31') return 'Open-ended';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

function fmtMonthYear(isoDate: string): string {
  const d = new Date(isoDate + 'T00:00:00');
  return d.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
}

function todayISO(): string {
  return new Date().toISOString().slice(0, 10);
}

/** Snap an ISO date string to the 1st of its month. */
function snapToFirstOfMonth(iso: string): string {
  if (!iso) return iso;
  return iso.slice(0, 7) + '-01';
}

function isItemAmended(item: DraftItem): boolean {
  if (!item._original || item._new || item._removed) return false;
  const o = item._original;
  const activeAtts = item.attachments.filter(a => !a._removed && a.is_active !== false);
  // Staged files (_file set) have file_path='' — count them separately so adding
  // a new attachment to an existing dependent is always detected as amended.
  const hasStagedFiles = activeAtts.some(a => (a as any)._file);
  const activePaths = activeAtts.map(a => a.file_path).filter(Boolean);
  const pathsChanged =
    hasStagedFiles ||                                     // new upload pending
    activePaths.length !== o.activePaths.length ||        // attachment removed
    activePaths.some((p, i) => p !== o.activePaths[i]);  // path changed
  return (
    item.relationship_type !== o.relationship_type ||
    item.dependent_name !== o.dependent_name ||
    item.date_of_birth !== o.date_of_birth ||
    item.gender !== o.gender ||
    item.insurance_eligible !== o.insurance_eligible ||
    pathsChanged
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-component: FieldCell
// ─────────────────────────────────────────────────────────────────────────────

function FieldCell({ label, value, danger }: { label: string; value: string; danger?: boolean }) {
  return (
    <div style={{ padding: '6px 0', borderBottom: '1px solid #F3F4F6' }}>
      <div style={{ fontSize: 10.5, color: '#9CA3AF', marginBottom: 2,
        fontWeight: 500, textTransform: 'uppercase', letterSpacing: 0.5 }}>
        {label}
      </div>
      <div style={{ fontSize: 13, color: danger ? '#DC2626' : '#111827', fontWeight: 500 }}>
        {value}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-component: AttachmentRow — renders one attachment in read or edit mode
// ─────────────────────────────────────────────────────────────────────────────

function AttachmentRow({ att, onRemove, onDocTypeChange, documentTypes }: {
  att: DraftAttachment | DependentAttachment;
  onRemove?: () => void;
  onDocTypeChange?: (refId: string) => void;
  documentTypes?: Array<{ id: unknown; refId?: unknown; value: string }>;
}) {
  const [url, setUrl] = useState<string | null>((att as DependentAttachment)._localUrl ?? null);

  useEffect(() => {
    const a = att as DependentAttachment;
    if (a._localUrl || !a.file_path) return;
    supabase.storage.from(HR_BUCKET).createSignedUrl(a.file_path, 3600)
      .then(({ data }) => { if (data?.signedUrl) setUrl(data.signedUrl); });
  }, [(att as DependentAttachment).file_path, (att as DependentAttachment)._localUrl]);

  const icon = (att.mime_type || '').includes('pdf') ? 'fa-file-pdf' : 'fa-file-image';
  const sizeKb = (att.file_size / 1024).toFixed(0);

  return (
    <div style={{
      background: '#F9FAFB', border: '1px solid #E5E7EB',
      borderRadius: 7, padding: '8px 10px', fontSize: 12.5,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <i className={`fa-regular ${icon}`} style={{ color: '#6366F1', fontSize: 16, flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 600, color: '#111827',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {att.original_file_name || att.file_name}
          </div>
          <div style={{ color: '#9CA3AF', fontSize: 11 }}>{sizeKb} KB</div>
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
        {onRemove && (
          <button onClick={onRemove}
            style={{ background: 'none', border: 'none', cursor: 'pointer',
              color: '#EF4444', padding: '2px 4px', flexShrink: 0 }}>
            <i className="fa-solid fa-xmark" />
          </button>
        )}
      </div>

      {/* Inline doc-type selector (edit mode) */}
      {documentTypes && onDocTypeChange && (
        <div style={{ marginTop: 6 }}>
          <select
            value={att.document_type ?? ''}
            onChange={e => onDocTypeChange(e.target.value)}
            style={{
              fontSize: 11.5, padding: '3px 8px', borderRadius: 5,
              border: `1px solid ${att.document_type ? '#C7D2FE' : '#FCA5A5'}`,
              color: att.document_type ? '#4338CA' : '#6B7280',
              background: att.document_type ? '#EEF2FF' : '#FFF',
              width: '100%',
            }}>
            <option value="">-- Select Document Type * --</option>
            {documentTypes.map(d => (
              <option key={String(d.id)} value={String(d.refId ?? d.id)}>{d.value}</option>
            ))}
          </select>
          {!att.document_type && (
            <div style={{ fontSize: 10.5, color: '#EF4444', marginTop: 2 }}>
              Document type is required
            </div>
          )}
        </div>
      )}

      {/* Read-only doc-type badge */}
      {!onDocTypeChange && att.document_type && documentTypes && (
        <div style={{ marginTop: 4 }}>
          <span style={{ background: '#EEF2FF', color: '#4338CA',
            borderRadius: 4, padding: '1px 6px', fontSize: 10.5, fontWeight: 600 }}>
            {documentTypes.find(d => String(d.refId ?? d.id) === att.document_type)?.value
              ?? att.document_type}
          </span>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-component: ViewItemCard — read-only card in view/pending mode
// ─────────────────────────────────────────────────────────────────────────────

function ViewItemCard({ item, relationshipLabel, documentTypes }: {
  item: DependentItem;
  relationshipLabel: string;
  documentTypes: Array<{ id: unknown; refId?: unknown; value: string }>;
}) {
  const activeAtts = (item.attachments ?? []).filter(a => a.is_active !== false);

  return (
    <div style={{
      border: '1.5px solid #6366F1', borderRadius: 10,
      marginBottom: 10, background: '#fff', overflow: 'hidden',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10,
        padding: '10px 14px', borderBottom: '1px solid #F3F4F6' }}>
        <i className="fa-solid fa-person" style={{ color: '#6366F1', fontSize: 16, flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 600, fontSize: 14, color: '#111827',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {item.dependent_name}
          </div>
          <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
            {fmtDate(item.date_of_birth)} · {item.gender}
          </div>
        </div>
      </div>
      <div style={{ padding: '10px 14px 14px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0 16px' }}>
          <FieldCell label="Relationship"        value={relationshipLabel} />
          <FieldCell label="Date of Birth"       value={fmtDate(item.date_of_birth)} />
          <FieldCell label="Insurance Eligible"  value={item.insurance_eligible ? 'Yes' : 'No'} />
          <FieldCell label="Gender"              value={item.gender} />
        </div>
        {activeAtts.length > 0 && (
          <div style={{ marginTop: 10 }}>
            <div style={{ fontSize: 10.5, color: '#9CA3AF', fontWeight: 600,
              textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 6 }}>
              Documents
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {activeAtts.map((a, i) => (
                <AttachmentRow key={a.id ?? i} att={a} documentTypes={documentTypes} />
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-component: DraftItemEditor — inline form inside a draft item card
// ─────────────────────────────────────────────────────────────────────────────

function DraftItemEditor({ item, onChange, relationshipTypes, documentTypes, hasError }: {
  item: DraftItem;
  onChange: (update: Partial<DraftItem>) => void;
  relationshipTypes: Array<{ id: unknown; refId?: unknown; value: string }>;
  documentTypes: Array<{ id: unknown; refId?: unknown; value: string }>;
  hasError: boolean;
}) {
  function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const files = Array.from(e.target.files ?? []);
    const newAtts: DraftAttachment[] = files.map(f => ({
      file_name: f.name,
      original_file_name: f.name,
      file_path: '',
      mime_type: f.type,
      file_size: f.size,
      document_type: undefined,
      _file: f,
      _localUrl: URL.createObjectURL(f),
    }));
    onChange({ attachments: [...item.attachments, ...newAtts] });
    e.target.value = '';
  }

  function removeAtt(idx: number) {
    const updated = item.attachments.map((a, i) =>
      i === idx
        ? a._file
          ? null                             // staged file → drop entirely
          : { ...a, _removed: true }         // DB file → soft-remove
        : a
    ).filter(Boolean) as DraftAttachment[];
    onChange({ attachments: updated });
  }

  function setDocType(idx: number, refId: string) {
    onChange({
      attachments: item.attachments.map((a, i) =>
        i === idx ? { ...a, document_type: refId || undefined } : a
      ),
    });
  }

  const visibleAtts = item.attachments.filter(a => !a._removed);

  const fieldError = (cond: boolean) => cond && hasError
    ? { border: '1px solid #FCA5A5' } : {};

  return (
    <div style={{ padding: '12px 14px', borderTop: '1px solid #F3F4F6', background: '#FAFAFE',
      ['--dep-input-h' as string]: '1' }}>
      <div className="emp-field-grid emp-grid-2" style={{ gap: 10 }}>

        {/* Dependent Name — full width */}
        <div className={`form-group ${hasError && !item.dependent_name.trim() ? 'form-group--error' : ''}`}
          style={{ gridColumn: '1 / -1' }}>
          <label><i className="fa-solid fa-user fa-fw" /> Dependent Name *</label>
          <input
            type="text"
            value={item.dependent_name}
            onChange={e => onChange({ dependent_name: e.target.value })}
            placeholder="Full name"
            style={fieldError(!item.dependent_name.trim())}
          />
          {hasError && !item.dependent_name.trim() && (
            <div className="field-error">Dependent name is required.</div>
          )}
        </div>

        {/* Relationship Type */}
        <div className={`form-group ${hasError && !item.relationship_type ? 'form-group--error' : ''}`}>
          <label><i className="fa-solid fa-people-group fa-fw" /> Relationship Type *</label>
          <select
            value={item.relationship_type}
            onChange={e => onChange({ relationship_type: e.target.value })}
            style={fieldError(!item.relationship_type)}>
            <option value="">-- Select Relationship --</option>
            {relationshipTypes.map(r => (
              <option key={String(r.id)} value={String(r.refId ?? r.id)}>{r.value}</option>
            ))}
          </select>
          {hasError && !item.relationship_type && (
            <div className="field-error">Relationship type is required.</div>
          )}
        </div>

        {/* Date of Birth */}
        <div className={`form-group ${hasError && !item.date_of_birth ? 'form-group--error' : ''}`}>
          <label><i className="fa-solid fa-cake-candles fa-fw" /> Date of Birth *</label>
          <input
            type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
            value={item.date_of_birth}
            max={todayISO()}
            onChange={e => onChange({ date_of_birth: e.target.value })}
            style={fieldError(!item.date_of_birth)}
          />
          {hasError && !item.date_of_birth && (
            <div className="field-error">Date of birth is required.</div>
          )}
        </div>

        {/* Gender */}
        <div className={`form-group ${hasError && !item.gender ? 'form-group--error' : ''}`}>
          <label><i className="fa-solid fa-venus-mars fa-fw" /> Gender *</label>
          <select
            value={item.gender ?? ''}
            onChange={e => onChange({ gender: e.target.value as 'Male' | 'Female' })}
            style={fieldError(!item.gender)}>
            <option value="">-- Select Gender --</option>
            <option value="Male">Male</option>
            <option value="Female">Female</option>
          </select>
          {hasError && !item.gender && (
            <div className="field-error">Gender is required.</div>
          )}
        </div>

        {/* Insurance Eligible */}
        <div className="form-group">
          <label><i className="fa-solid fa-shield-halved fa-fw" /> Insurance Eligible</label>
          <select
            value={item.insurance_eligible ? 'yes' : 'no'}
            onChange={e => onChange({ insurance_eligible: e.target.value === 'yes' })}>
            <option value="no">No</option>
            <option value="yes">Yes</option>
          </select>
        </div>
      </div>

      {/* Attachments */}
      <div style={{ marginTop: 12 }}>
        <div style={{ fontWeight: 600, fontSize: 13, color: '#374151', marginBottom: 4 }}>
          <i className="fa-solid fa-paperclip" style={{ marginRight: 6 }} />
          Supporting Documents
          <span style={{ fontWeight: 400, color: '#9CA3AF', fontSize: 11, marginLeft: 6 }}>
            (Birth certificate, marriage certificate, etc.)
          </span>
        </div>
        {hasError && visibleAtts.some(a => a._file && !a.document_type) && (
          <div style={{ fontSize: 12, color: '#EF4444', marginBottom: 6 }}>
            <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 4 }} />
            Please select a document type for each attached file.
          </div>
        )}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {visibleAtts.map((att, i) => (
            <AttachmentRow
              key={i}
              att={att}
              onRemove={() => removeAtt(item.attachments.indexOf(att))}
              documentTypes={att._file ? documentTypes : undefined}
              onDocTypeChange={att._file ? (refId) => setDocType(item.attachments.indexOf(att), refId) : undefined}
            />
          ))}
        </div>
        <label style={{
          display: 'inline-flex', alignItems: 'center', gap: 7,
          cursor: 'pointer', marginTop: 8,
          background: '#EEF2FF', color: '#4338CA',
          border: '1px dashed #C7D2FE', borderRadius: 7,
          padding: '7px 14px', fontSize: 12.5, fontWeight: 600,
        }}>
          <i className="fa-solid fa-upload" /> Attach Document
          <input type="file" accept="image/*,application/pdf" multiple
            style={{ display: 'none' }} onChange={handleFileChange} />
        </label>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-component: DraftItemCard — card in draft mode
// ─────────────────────────────────────────────────────────────────────────────

const iconBtnBase: React.CSSProperties = {
  width: 28, height: 28, borderRadius: 6,
  border: '1px solid #E5E7EB', background: 'none',
  cursor: 'pointer', display: 'inline-flex', alignItems: 'center',
  justifyContent: 'center', color: '#6B7280', flexShrink: 0,
};

function DraftItemCard({ item, onUpdate, onToggleRemove, onToggleEdit, hidePencil = false,
  relationshipLabel, relationshipTypes, documentTypes }: {
  item: DraftItem;
  onUpdate: (update: Partial<DraftItem>) => void;
  onToggleRemove: () => void;
  onToggleEdit: () => void;
  hidePencil?: boolean;
  relationshipLabel: string;
  relationshipTypes: Array<{ id: unknown; refId?: unknown; value: string }>;
  documentTypes: Array<{ id: unknown; refId?: unknown; value: string }>;
}) {
  const amended  = isItemAmended(item);
  const isNew    = item._new && !item._removed;
  const isRemoved = item._removed;

  const borderColor = isRemoved
    ? '#E5E7EB'
    : item._hasError
    ? '#FCA5A5'
    : isNew
    ? '#34D399'
    : amended
    ? '#FCD34D'
    : '#6366F1';

  const headerBg = isRemoved ? '#F9FAFB' : '#fff';

  return (
    <div style={{
      border: `1.5px solid ${borderColor}`,
      borderRadius: 10, marginBottom: 10,
      background: headerBg, overflow: 'hidden',
      opacity: isRemoved ? 0.6 : 1,
    }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10,
        padding: '10px 14px', borderBottom: item._editing ? '1px solid #F3F4F6' : 'none' }}>
        <i className="fa-solid fa-person"
          style={{ color: isRemoved ? '#9CA3AF' : '#6366F1', fontSize: 16, flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          {item.dependent_name ? (
            <>
              <div style={{ fontWeight: 600, fontSize: 14,
                color: isRemoved ? '#6B7280' : '#111827',
                textDecoration: isRemoved ? 'line-through' : 'none',
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {item.dependent_name}
              </div>
              {item.date_of_birth && (
                <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
                  {fmtDate(item.date_of_birth)}{item.gender ? ` · ${item.gender}` : ''}
                </div>
              )}
            </>
          ) : (
            <div style={{ fontSize: 13, color: '#9CA3AF', fontStyle: 'italic' }}>
              New dependent — fill in details below
            </div>
          )}
        </div>

        {/* Badges */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
          {isNew && !isRemoved && (
            <span style={{ background: '#ECFDF5', color: '#059669',
              borderRadius: 5, padding: '2px 7px', fontSize: 10, fontWeight: 700 }}>
              NEW
            </span>
          )}
          {amended && !isRemoved && (
            <span style={{ background: '#FFFBEB', color: '#D97706',
              borderRadius: 5, padding: '2px 7px', fontSize: 10, fontWeight: 700 }}>
              AMENDED
            </span>
          )}
          {isRemoved && (
            <span style={{ background: '#FEF2F2', color: '#DC2626',
              borderRadius: 5, padding: '2px 7px', fontSize: 10, fontWeight: 700 }}>
              REMOVED
            </span>
          )}
        </div>

        {/* Action buttons */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 4, flexShrink: 0 }}>
          {!isRemoved && !hidePencil && (
            <button
              style={{
                ...iconBtnBase,
                borderColor: item._editing ? '#A5B4FC' : '#E5E7EB',
                color:       item._editing ? '#4F46E5' : '#6B7280',
                background:  item._editing ? '#EEF2FF' : 'none',
              }}
              title={item._editing ? 'Collapse' : 'Edit'}
              onClick={onToggleEdit}
              aria-label="Edit dependent">
              <i className="fa-solid fa-pen" style={{ fontSize: 12 }} />
            </button>
          )}
          <button
            style={{
              ...iconBtnBase,
              borderColor: isRemoved ? '#A5B4FC' : '#E5E7EB',
              color:       isRemoved ? '#4F46E5' : '#6B7280',
              background:  isRemoved ? '#EEF2FF' : 'none',
            }}
            title={isRemoved ? 'Restore' : 'Remove'}
            onClick={onToggleRemove}
            onMouseEnter={e => {
              if (!isRemoved) {
                (e.currentTarget as HTMLButtonElement).style.borderColor = '#FCA5A5';
                (e.currentTarget as HTMLButtonElement).style.color = '#DC2626';
                (e.currentTarget as HTMLButtonElement).style.background = '#FEF2F2';
              }
            }}
            onMouseLeave={e => {
              if (!isRemoved) {
                (e.currentTarget as HTMLButtonElement).style.borderColor = '#E5E7EB';
                (e.currentTarget as HTMLButtonElement).style.color = '#6B7280';
                (e.currentTarget as HTMLButtonElement).style.background = 'none';
              }
            }}
            aria-label={isRemoved ? 'Restore dependent' : 'Remove dependent'}>
            <i className={`fa-solid ${isRemoved ? 'fa-rotate-left' : 'fa-trash'}`}
              style={{ fontSize: 12 }} />
          </button>
        </div>
      </div>

      {/* Compact field summary when not editing and not removed */}
      {!item._editing && !isRemoved && item.dependent_name && (
        <div style={{ padding: '10px 14px 14px' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0 16px' }}>
            <FieldCell label="Relationship"       value={relationshipLabel || '—'} />
            <FieldCell label="Date of Birth"      value={item.date_of_birth ? fmtDate(item.date_of_birth) : '—'} />
            <FieldCell label="Insurance Eligible" value={item.insurance_eligible ? 'Yes' : 'No'} />
            <FieldCell label="Gender"             value={item.gender || '—'} />
          </div>
          {/* Attachments — same visual as bank "Proof of Account" */}
          {item.attachments.filter(a => !a._removed).length > 0 && (
            <div style={{ marginTop: 10 }}>
              <div style={{ fontSize: 10.5, color: '#9CA3AF', fontWeight: 600,
                textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 6 }}>
                Documents
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                {item.attachments.filter(a => !a._removed).map((a, i) => (
                  <AttachmentRow
                    key={(a as DependentAttachment).id ?? i}
                    att={a}
                    documentTypes={documentTypes}
                  />
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {/* Inline editor */}
      {item._editing && !isRemoved && (
        <DraftItemEditor
          item={item}
          onChange={onUpdate}
          relationshipTypes={relationshipTypes}
          documentTypes={documentTypes}
          hasError={item._hasError}
        />
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-component: HistoryPanel — set-level history, loaded lazily
// ─────────────────────────────────────────────────────────────────────────────

function HistoryPanel({ employeeId, resolveRelationship }: {
  employeeId: string;
  resolveRelationship: (refId: string) => string;
}) {
  const [sets,    setSets]    = useState<SetHistoryRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [err,     setErr]     = useState('');
  const [expandedSetId, setExpandedSetId] = useState<string | null>(null);
  const loaded = useRef(false);

  useEffect(() => {
    if (loaded.current) return;
    loaded.current = true;
    setLoading(true);
    supabase.rpc('get_employee_dependent_set_history', { p_employee_id: employeeId })
      .then(({ data, error }) => {
        if (error) { setErr(error.message); return; }
        const payload = data as { ok: boolean; sets: SetHistoryRow[] } | null;
        setSets(payload?.sets ?? []);
      })
      .finally(() => setLoading(false));
  }, [employeeId]);

  if (loading) return (
    <div style={{ textAlign: 'center', padding: '16px 0', color: '#9CA3AF', fontSize: 13 }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading history…
    </div>
  );

  if (err) return (
    <div style={{ color: '#DC2626', fontSize: 13, padding: '10px 0' }}>
      <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{err}
    </div>
  );

  if (sets.length === 0) return (
    <div style={{ color: '#9CA3AF', fontSize: 13, padding: '10px 0', textAlign: 'center' }}>
      No prior sets on record.
    </div>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      {sets.map((set, idx) => {
        const isExpanded = expandedSetId === set.set_id;
        const isCurrent = idx === 0 && set.is_active;

        return (
          <div key={set.set_id} style={{
            border: '1px solid #E5E7EB', borderRadius: 8, overflow: 'hidden',
          }}>
            <button
              style={{
                width: '100%', textAlign: 'left',
                padding: '10px 14px', background: isExpanded ? '#F5F3FF' : '#FAFAFA',
                border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 10,
              }}
              onClick={() => setExpandedSetId(isExpanded ? null : set.set_id)}>
              <i className="fa-solid fa-layer-group"
                style={{ color: '#6366F1', fontSize: 14, flexShrink: 0 }} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 600, fontSize: 13, color: '#111827' }}>
                  {fmtDate(set.effective_from)}
                  {' → '}
                  {fmtDate(set.effective_to)}
                </div>
                <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
                  {set.item_count} dependent{set.item_count !== 1 ? 's' : ''}
                </div>
              </div>
              {isCurrent && (
                <span style={{ background: '#EEF2FF', color: '#4F46E5',
                  borderRadius: 10, padding: '1px 8px', fontSize: 10, fontWeight: 700 }}>
                  Current
                </span>
              )}
              <i className={`fa-solid ${isExpanded ? 'fa-chevron-up' : 'fa-chevron-down'}`}
                style={{ color: '#9CA3AF', fontSize: 11 }} />
            </button>

            {isExpanded && set.items && set.items.length > 0 && (
              <div style={{ padding: '10px 14px', background: '#fff', borderTop: '1px solid #F3F4F6' }}>
                {set.items.map(item => (
                  <div key={item.id} style={{
                    padding: '8px 0', borderBottom: '1px solid #F9FAFB',
                    display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0 16px',
                  }}>
                    <FieldCell label="Name"         value={item.dependent_name} />
                    <FieldCell label="Relationship" value={resolveRelationship(item.relationship_type)} />
                    <FieldCell label="Date of Birth" value={fmtDate(item.date_of_birth)} />
                  </div>
                ))}
              </div>
            )}

            {isExpanded && (!set.items || set.items.length === 0) && (
              <div style={{ padding: '10px 14px', color: '#9CA3AF', fontSize: 13 }}>
                No items in this set.
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Portlet
// ─────────────────────────────────────────────────────────────────────────────

export default function DependentsPortlet({
  employeeId,
  hireDate,
  isNewHire = false,
  readOnly = false,
  canEdit = true,
  pendingCount = 0,
  onChanged,
  onRecordCountChange,
  saveTriggerRef,
  editMode = false,
  saveAllRef,
  reviewMode = false,
  sectionTitle,
}: DependentsPortletProps) {
  const { picklistValues } = usePicklistValues();

  // Stable ref so loadCurrentSet can call the latest onRecordCountChange
  // without it being a useCallback dep (which would cause an infinite reload loop).
  const onRecordCountChangeRef = useRef(onRecordCountChange);
  useEffect(() => { onRecordCountChangeRef.current = onRecordCountChange; }, [onRecordCountChange]);

  const relationshipTypes = picklistValues.filter(
    p => p.picklistId === 'DEPENDENT_RELATIONSHIP_TYPE' && p.active !== false
  );
  const documentTypes = picklistValues.filter(
    p => p.picklistId === 'DEPENDENT_DOCUMENT_TYPE' && p.active !== false
  );

  // ── Server state ──────────────────────────────────────────────────────────
  const [currentSet,   setCurrentSet]   = useState<DependentSetInfo | null>(null);
  const [currentItems, setCurrentItems] = useState<DependentItem[]>([]);
  const [loading,      setLoading]      = useState(true);
  const [loadErr,      setLoadErr]      = useState('');

  // ── UI state ──────────────────────────────────────────────────────────────
  const [mode,                setMode]                = useState<'view' | 'draft'>('view');
  const [draftItems,          setDraftItems]          = useState<DraftItem[]>([]);
  const [draftEffectiveFrom,  setDraftEffectiveFrom]  = useState(todayISO());
  const [submitting,          setSubmitting]          = useState(false);
  const [submitError,         setSubmitError]         = useState('');
  const [workflowPending,     setWorkflowPending]     = useState(false);
  const [showHistory,         setShowHistory]         = useState(false);

  // ── Load active set ───────────────────────────────────────────────────────
  const loadCurrentSet = useCallback(async () => {
    if (!employeeId) return;
    setLoading(true); setLoadErr('');
    const { data, error } = await supabase.rpc('get_employee_dependent_set', {
      p_employee_id: employeeId,
    });
    if (error) { setLoadErr(error.message); setLoading(false); return; }
    const payload = data as { ok: boolean; set: DependentSetInfo | null; items: DependentItem[] } | null;
    const items = payload?.items ?? [];
    setCurrentSet(payload?.set ?? null);
    setCurrentItems(items);
    setLoading(false);
    onRecordCountChangeRef.current?.(items.length > 0);
  }, [employeeId]); // onRecordCountChange intentionally excluded — it's a callback, not a fetch dependency

  useEffect(() => { loadCurrentSet(); }, [loadCurrentSet]);

  // ── Auto-enter draft for new hire / editMode ──────────────────────────────
  const autoEnteredRef = useRef(false);
  useEffect(() => {
    if (autoEnteredRef.current || loading) return;
    if (isNewHire || editMode) {
      autoEnteredRef.current = true;
      enterDraft();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loading, isNewHire, editMode]);

  // ── reviewMode: stay in view unless editMode is explicitly true ──────────
  // Runs on every change to editMode, reviewMode, or mode so it catches both:
  //   (a) the portlet auto-entering draft after load (isNewHire=true) while
  //       editMode is still false — discards immediately back to view
  //   (b) the Cancel button clearing editingSections (editMode→false) — discards
  // discardDraft() already resets autoEnteredRef, enabling re-entry on Update.
  useEffect(() => {
    if (reviewMode && !editMode && mode === 'draft') {
      discardDraft();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editMode, reviewMode, mode]);

  // ── Draft management ──────────────────────────────────────────────────────
  function itemToDraft(item: DependentItem): DraftItem {
    const activeAtts = (item.attachments ?? []).filter(a => a.is_active !== false);
    return {
      _localId:         randomUUID(),
      dependent_code:   item.dependent_code,
      relationship_type: item.relationship_type,
      dependent_name:   item.dependent_name,
      date_of_birth:    item.date_of_birth,
      gender:           item.gender,
      insurance_eligible: item.insurance_eligible,
      attachments:      activeAtts.map(a => ({ ...a })),
      _new:     false,
      _removed: false,
      _editing: false,
      _hasError: false,
      _original: {
        relationship_type: item.relationship_type,
        dependent_name:    item.dependent_name,
        date_of_birth:     item.date_of_birth,
        gender:            item.gender,
        insurance_eligible: item.insurance_eligible,
        activePaths: activeAtts.map(a => a.file_path).filter(Boolean),
      },
    };
  }

  function enterDraft() {
    // Dependents always use the exact date — no first-of-month snapping.
    // Hire wizard: exact hire date. Active-employee edits: today's date.
    const defaultEffFrom = isNewHire && hireDate
      ? hireDate.slice(0, 10)
      : todayISO();
    // In reviewMode (WorkflowReview), show read-only summary cards (field grid + attachments).
    // Only expand to the editor form when editMode is true (approver/initiator actively editing).
    // Using reviewMode here was wrong — it showed DraftItemEditor, hiding AttachmentRow.
    setDraftItems(currentItems.map(item => ({ ...itemToDraft(item), _editing: editMode })));
    setDraftEffectiveFrom(defaultEffFrom);
    setSubmitError('');
    setMode('draft');
  }

  function discardDraft() {
    setDraftItems([]);
    setSubmitError('');
    setMode('view');
    autoEnteredRef.current = false;
  }

  function addItem() {
    setDraftItems(prev => [...prev, {
      _localId:         randomUUID(),
      dependent_code:   null,
      relationship_type: '',
      dependent_name:   '',
      date_of_birth:    '',
      gender:           '',
      insurance_eligible: false,
      attachments:      [],
      _new:     true,
      _removed: false,
      _editing: true,
      _hasError: false,
      _original: null,
    }]);
  }

  function updateDraftItem(localId: string, update: Partial<DraftItem>) {
    setDraftItems(prev =>
      prev.map(item => item._localId === localId ? { ...item, ...update } : item)
    );
  }

  function toggleRemove(localId: string) {
    setDraftItems(prev =>
      prev.map(item =>
        item._localId === localId
          ? { ...item, _removed: !item._removed, _editing: false, _hasError: false }
          : item
      )
    );
  }

  function toggleEdit(localId: string) {
    setDraftItems(prev =>
      prev.map(item =>
        item._localId === localId ? { ...item, _editing: !item._editing } : item
      )
    );
  }

  // ── Submit ────────────────────────────────────────────────────────────────
  async function handleSubmit(): Promise<boolean> {
    const active = draftItems.filter(item => !item._removed);

    // No dependents at all and never had any — nothing to write
    if (active.length === 0 && currentItems.length === 0) return true;

    // Hire-flow guard: the employee is not yet active — "removing" all previously
    // staged dependents from the draft is equivalent to having none. Never submit
    // an empty set during a hire (the employee has no real dependents to remove).
    if (active.length === 0 && isNewHire) return true;

    // No changes from the current set — skip the write (admin opened but didn't edit)
    const hasAdded   = draftItems.some(i => i._new    && !i._removed);
    const hasRemoved = draftItems.some(i => i._removed && !i._new);
    const hasAmended = draftItems.some(i => !i._new && !i._removed && isItemAmended(i));
    if (!hasAdded && !hasRemoved && !hasAmended) return true;

    // Validate
    const withErrors = draftItems.map(item => {
      if (item._removed) return { ...item, _hasError: false };
      const hasStagedWithoutType = item.attachments.some(
        a => !a._removed && a._file && !a.document_type
      );
      const hasError =
        !item.dependent_name.trim() ||
        !item.relationship_type ||
        !item.date_of_birth ||
        !item.gender ||
        hasStagedWithoutType;
      return { ...item, _hasError: hasError };
    });

    if (withErrors.some(i => i._hasError)) {
      setDraftItems(withErrors.map(i => ({
        ...i,
        _editing: i._hasError ? true : i._editing,
      })));
      setSubmitError('Please fix the highlighted errors before submitting.');
      return false;
    }

    setSubmitting(true);
    setSubmitError('');

    try {
      // Upload staged files
      const submitItems = await Promise.all(active.map(async (item) => {
        const uploadedAtts: DependentAttachment[] = [];

        for (const att of item.attachments.filter(a => !a._removed && a.is_active !== false)) {
          if (!att._file) {
            // Existing attachment — carry file_path and metadata as-is
            uploadedAtts.push(att);
            continue;
          }
          const ext = att.file_name.split('.').pop() ?? 'bin';
          const safeName = `${Date.now()}-${randomUUID().slice(0, 8)}.${ext}`;
          // Use _new_{uuid} prefix for new-item uploads (no path rewrite on apply)
          const pathPrefix = item.dependent_code
            ? `dependents/${employeeId}/${item.dependent_code}`
            : `dependents/${employeeId}/_new_${randomUUID().slice(0, 8)}`;
          const path = `${pathPrefix}/${safeName}`;
          const { error: upErr } = await supabase.storage
            .from(HR_BUCKET)
            .upload(path, att._file, { contentType: att.mime_type, upsert: false });
          if (upErr) throw new Error(`Upload failed for ${att.file_name}: ${upErr.message}`);
          uploadedAtts.push({ ...att, file_path: path, _file: undefined, _localUrl: undefined });
        }

        return {
          dependent_code:   item.dependent_code,   // null for new items
          relationship_type: item.relationship_type,
          dependent_name:   item.dependent_name.trim(),
          date_of_birth:    item.date_of_birth,
          gender:           item.gender,
          insurance_eligible: item.insurance_eligible,
          attachments: uploadedAtts.map(a => ({
            file_path:          a.file_path,
            file_name:          a.file_name,
            original_file_name: a.original_file_name ?? a.file_name,
            mime_type:          a.mime_type,
            file_size:          a.file_size,
            document_type:      a.document_type ?? null,
          })),
        };
      }));

      const { data, error: rpcErr } = await supabase.rpc('submit_dependent_set', {
        p_employee_id:    employeeId,
        p_effective_from: draftEffectiveFrom,
        p_items:          submitItems,
      });

      if (rpcErr) throw new Error(rpcErr.message);
      const result = data as {
        ok: boolean; workflow: boolean;
        instance_id?: string; set_id?: string;
        effective_from: string; change_summary: string;
      } | null;
      if (!result?.ok) throw new Error('Submit failed.');

      if (result.workflow) {
        setWorkflowPending(true);
      } else {
        onChanged?.();
      }
      setMode('view');
      await loadCurrentSet();
      return true;

    } catch (err: any) {
      setSubmitError(err.message ?? 'An unexpected error occurred.');
      return false;
    } finally {
      setSubmitting(false);
    }
  }

  // Keep ref always pointing to the latest handleSubmit
  const handleSubmitRef = useRef(handleSubmit);
  useEffect(() => { handleSubmitRef.current = handleSubmit; });

  // Wire saveTriggerRef (hire wizard)
  useEffect(() => {
    if (!saveTriggerRef) return;
    saveTriggerRef.current = () => handleSubmitRef.current();
    return () => { saveTriggerRef.current = null; };
  }, [saveTriggerRef]);

  // Wire saveAllRef (editMode compat for EmployeeEditPanel)
  useEffect(() => {
    if (!saveAllRef) return;
    saveAllRef.current = () => handleSubmitRef.current();
    return () => { saveAllRef.current = null; };
  }, [saveAllRef]);

  // ── Computed draft counters ───────────────────────────────────────────────
  const added     = draftItems.filter(i => i._new    && !i._removed).length;
  const removed   = draftItems.filter(i => i._removed && !i._new).length;
  const amended   = draftItems.filter(i => !i._new && !i._removed && isItemAmended(i)).length;
  const unchanged = draftItems.filter(i => !i._new && !i._removed && !isItemAmended(i)).length;
  const hasDraftChanges = added > 0 || removed > 0 || amended > 0;

  // Dependents use the exact date — no first-of-month snap.

  function resolveRelationship(refId: string): string {
    const pv = picklistValues.find(
      p => p.picklistId === 'DEPENDENT_RELATIONSHIP_TYPE' &&
        (p.refId === refId || String(p.id) === refId)
    );
    return pv?.value ?? refId;
  }

  // ── Loading / error states ────────────────────────────────────────────────
  if (loading) return (
    <div style={{ textAlign: 'center', padding: '24px 0', color: '#9CA3AF' }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading dependents…
    </div>
  );

  if (loadErr) return (
    <div style={{ color: '#DC2626', fontSize: 13, padding: '10px 0' }}>
      <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{loadErr}
    </div>
  );

  // ── Render ────────────────────────────────────────────────────────────────
  const historyBtn = !isNewHire ? (
    <button
      style={{
        background: showHistory ? '#EEF2FF' : 'none',
        border: `1px solid ${showHistory ? '#A5B4FC' : '#E5E7EB'}`,
        borderRadius: 6, padding: '4px 8px', cursor: 'pointer',
        color: showHistory ? '#4F46E5' : '#6B7280', fontSize: 12,
        display: 'inline-flex', alignItems: 'center', gap: 4,
      }}
      onClick={() => setShowHistory(p => !p)}>
      <i className="fa-solid fa-clock-rotate-left" style={{ fontSize: 11 }} />
      {showHistory ? 'Close' : 'History'}
    </button>
  ) : null;

  const editBtn = canEdit && !readOnly && !reviewMode && pendingCount === 0 ? (
    <button
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 5,
        padding: '5px 14px', borderRadius: 6, cursor: 'pointer',
        border: '1px solid #D1D5DB', background: '#F9FAFB',
        fontSize: 12, fontWeight: 600, color: '#374151',
      }}
      onClick={enterDraft}>
      <i className="fa-solid fa-pen" style={{ fontSize: 11 }} />
      Edit
    </button>
  ) : null;

  return (
    <div>
      {/* ── Section header — title + action buttons in one row (Personal Info pattern) ── */}
      {sectionTitle && (
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 14 }}>
          <div className="ev-section-title" style={{ display: 'flex', alignItems: 'flex-start', flexDirection: 'column', gap: 6 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <i className={`fa-solid ${sectionTitle.icon}`} /> {sectionTitle.text}
              {(sectionTitle.pending ?? 0) > 0 && (
                <span style={{
                  display: 'inline-flex', alignItems: 'center', gap: 4,
                  background: '#FEF3C7', color: '#B45309', border: '1px solid #F59E0B',
                  borderRadius: 10, padding: '2px 8px', fontSize: 11, fontWeight: 600, lineHeight: 1.4,
                }}>
                  <i className="fa-solid fa-hourglass-half" style={{ fontSize: 10 }} />
                  Workflow Pending Approval
                </span>
              )}
            </div>
            {(sectionTitle.pending ?? 0) > 0 && sectionTitle.onViewProgress && (
              <button
                onClick={sectionTitle.onViewProgress}
                style={{ background: 'none', border: 'none', padding: 0, cursor: 'pointer',
                  color: '#6366F1', fontSize: 12, fontWeight: 500, textDecoration: 'underline' }}
              >
                View progress
              </button>
            )}
          </div>
          {mode === 'view' && (
            <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
              {historyBtn}
              {editBtn}
            </div>
          )}
        </div>
      )}

      {/* Post-submit workflow-pending banner */}
      {workflowPending && pendingCount === 0 && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          background: '#FFFBEB', border: '1px solid #FCD34D',
          borderRadius: 8, padding: '10px 14px', marginBottom: 14, fontSize: 13,
        }}>
          <i className="fa-solid fa-clock" style={{ color: '#D97706', fontSize: 15 }} />
          <span style={{ flex: 1, color: '#92400E' }}>
            <strong>Submitted for approval</strong> — your dependent changes are pending review.
            You'll be notified once approved.
          </span>
          <button
            onClick={() => { setWorkflowPending(false); loadCurrentSet(); }}
            style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#92400E', padding: 2 }}
            title="Dismiss">
            <i className="fa-solid fa-xmark" />
          </button>
        </div>
      )}

      {/* ── VIEW MODE ─────────────────────────────────────────────────────── */}
      {mode === 'view' && (
        <>
          {/* Fallback buttons — shown at bottom when sectionTitle prop is not set */}
          {!sectionTitle && (!isNewHire || (canEdit && !readOnly && pendingCount === 0)) && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 6, marginBottom: 12, flexWrap: 'wrap' }}>
              {historyBtn}
              {editBtn}
            </div>
          )}

          {/* Empty state */}
          {currentItems.length === 0 && (
            <div style={{ textAlign: 'center', padding: '24px 0', color: '#9CA3AF', fontSize: 13 }}>
              <i className="fa-solid fa-people-group"
                style={{ display: 'block', fontSize: 28, marginBottom: 8, color: '#E5E7EB' }} />
              No dependents on file.
            </div>
          )}

          {/* Active set info chip */}
          {currentSet && (
            <div style={{ marginBottom: 10, fontSize: 12, color: '#6B7280',
              display: 'flex', alignItems: 'center', gap: 6 }}>
              <i className="fa-solid fa-calendar-check" style={{ color: '#6366F1' }} />
              Effective {fmtDate(currentSet.effective_from)}
            </div>
          )}

          {/* Item cards */}
          {currentItems.map(item => (
            <ViewItemCard
              key={item.dependent_code}
              item={item}
              relationshipLabel={resolveRelationship(item.relationship_type)}
              documentTypes={documentTypes}
            />
          ))}

          {!isNewHire && showHistory && (
            <div style={{ marginTop: 10 }}>
              <HistoryPanel
                employeeId={employeeId}
                resolveRelationship={resolveRelationship}
              />
            </div>
          )}
        </>
      )}

      {/* ── DRAFT MODE ────────────────────────────────────────────────────── */}
      {mode === 'draft' && (
        <>
          {/* Draft header: effective_from + change counter.
              Hidden entirely in hire wizard when there are no changes yet — avoids empty blue bar. */}
          {(!isNewHire || hasDraftChanges) && <div style={{
            background: '#F5F3FF', border: '1px solid #C7D2FE',
            borderRadius: 8, padding: '12px 16px', marginBottom: 14,
            display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 12,
          }}>
            {!isNewHire && (
              <div style={{ flex: 1, minWidth: 200 }}>
                <div style={{ fontSize: 11, fontWeight: 600, color: '#4338CA',
                  textTransform: 'uppercase', letterSpacing: 0.4, marginBottom: 4 }}>
                  Effective From
                </div>
                <input
                  type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                  value={draftEffectiveFrom}
                  style={{
                    fontSize: 13, padding: '5px 8px', borderRadius: 6,
                    border: '1px solid #C7D2FE', color: '#111827', background: '#fff',
                  }}
                  onChange={e => {
                    if (!e.target.value) return;
                    const minDate = hireDate ? hireDate.slice(0, 10) : null;
                    const val = e.target.value;
                    setDraftEffectiveFrom(minDate && val < minDate ? minDate : val);
                  }}
                />
                {draftEffectiveFrom && (
                  <div style={{ fontSize: 11, color: '#6366F1', marginTop: 3 }}>
                    <i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />
                    Effective from {fmtDate(draftEffectiveFrom)}
                  </div>
                )}
              </div>
            )}

            {/* Change counter */}
            {hasDraftChanges && (
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {added > 0 && (
                  <span style={{ background: '#ECFDF5', color: '#059669',
                    borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>
                    +{added} added
                  </span>
                )}
                {amended > 0 && (
                  <span style={{ background: '#FFFBEB', color: '#D97706',
                    borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>
                    {amended} amended
                  </span>
                )}
                {removed > 0 && (
                  <span style={{ background: '#FEF2F2', color: '#DC2626',
                    borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>
                    −{removed} removed
                  </span>
                )}
                {unchanged > 0 && (
                  <span style={{ background: '#F3F4F6', color: '#6B7280',
                    borderRadius: 6, padding: '3px 10px', fontSize: 11.5 }}>
                    {unchanged} unchanged
                  </span>
                )}
              </div>
            )}
          </div>}

          {/* Empty draft state */}
          {draftItems.length === 0 && (
            <div style={{ textAlign: 'center', padding: '20px 0', color: '#9CA3AF', fontSize: 13 }}>
              <i className="fa-solid fa-people-group"
                style={{ display: 'block', fontSize: 26, marginBottom: 8, color: '#E5E7EB' }} />
              No dependents — click "Add Dependent" to begin.
            </div>
          )}

          {/* Draft item cards */}
          {draftItems.map(item => (
            <DraftItemCard
              key={item._localId}
              item={item}
              onUpdate={update => updateDraftItem(item._localId, update)}
              onToggleRemove={() => toggleRemove(item._localId)}
              onToggleEdit={() => toggleEdit(item._localId)}
              hidePencil={reviewMode}
              relationshipLabel={item.relationship_type
                ? resolveRelationship(item.relationship_type) : '—'}
              relationshipTypes={relationshipTypes}
              documentTypes={documentTypes}
            />
          ))}

          {/* Add Dependent */}
          <button className="emp-btn-secondary"
            style={{ marginTop: 4, padding: '7px 18px', fontSize: 13 }}
            onClick={addItem}>
            <i className="fa-solid fa-plus" style={{ marginRight: 6 }} />Add Dependent
          </button>

          {/* Error banner */}
          {submitError && (
            <div style={{
              background: '#FEF2F2', border: '1px solid #FECACA',
              borderRadius: 7, padding: '8px 12px', color: '#DC2626',
              fontSize: 12.5, marginTop: 14,
            }}>
              <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
              {submitError}
            </div>
          )}

          {/* Draft footer: Submit + Discard (hidden in hire-wizard isNewHire mode — wizard controls save) */}
          {!isNewHire && (
            <div style={{ display: 'flex', gap: 10, marginTop: 18, paddingTop: 14,
              borderTop: '1px solid #F3F4F6' }}>
              <button
                className="emp-btn-primary"
                style={{ padding: '8px 22px', fontSize: 13 }}
                disabled={submitting}
                onClick={handleSubmit}>
                {submitting
                  ? <><i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Submitting…</>
                  : <><i className="fa-solid fa-check" style={{ marginRight: 6 }} />Submit Changes</>
                }
              </button>
              <button
                className="emp-btn-ghost"
                style={{ padding: '8px 18px', fontSize: 13 }}
                disabled={submitting}
                onClick={discardDraft}>
                Discard Changes
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
