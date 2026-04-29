import { useState, useMemo, useRef, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { useEmployees } from '../../hooks/useEmployees';
import ConfirmationModal from '../shared/ConfirmationModal';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

interface MetaField {
  key: string;
  label: string;
  placeholder?: string;
  required?: boolean;
  width?: number;
  /** 'select' renders a dropdown populated from sourcePicklistId instead of a text input */
  type?: 'text' | 'select';
  sourcePicklistId?: string;
}

interface Picklist {
  id: string;
  description: string;
  parentPicklistId?: string | null;
  system?: boolean;
  metaFields?: MetaField[];
}

interface PlValue {
  id: string;
  picklistId: string;
  value: string;
  parentValueId?: string | null;
  active?: boolean;
  refId?: string | null;
  meta?: Record<string, string> | null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Default picklist definitions — exact IDs match what the system uses as keys
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_PICKLISTS: Picklist[] = [
  { id: 'DESIGNATION',       description: 'Designation',       parentPicklistId: null,         system: true,  metaFields: [] },
  { id: 'NATIONALITY',       description: 'Nationality',       parentPicklistId: null,         system: true,  metaFields: [] },
  { id: 'MARITAL_STATUS',    description: 'Marital Status',    parentPicklistId: null,         system: true,  metaFields: [] },
  { id: 'RELATIONSHIP_TYPE', description: 'Relationship Type', parentPicklistId: null,         system: true,  metaFields: [] },
  { id: 'ID_COUNTRY',        description: 'ID Country',        parentPicklistId: null,         system: true,
    metaFields: [
      { key: 'code',       label: 'ISO Code',        placeholder: 'e.g. IN', width: 90 },
      { key: 'currencyId', label: 'Default Currency', type: 'select', sourcePicklistId: 'CURRENCY' },
    ] },
  { id: 'ID_TYPE',           description: 'ID Type',           parentPicklistId: 'ID_COUNTRY', system: true,  metaFields: [] },
  { id: 'LOCATION',          description: 'Location',          parentPicklistId: 'ID_COUNTRY', system: true,  metaFields: [] },
  { id: 'CURRENCY',          description: 'Currency',          parentPicklistId: null,         system: true,
    metaFields: [
      { key: 'code',   label: 'Code',   placeholder: 'e.g. INR', width: 80, required: true },
      { key: 'symbol', label: 'Symbol', placeholder: 'e.g. ₹',   width: 70, required: true },
    ],
  },
  { id: 'Expense_Category',  description: 'Expense Category',  parentPicklistId: null,         system: true,  metaFields: [] },
];


// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────


/** Checks only actual employee / expense data usage — does NOT include child-value references */
function plIsInUse(valueId: string, vals: PlValue[], employees: Record<string, unknown>[]): boolean {
  const vid = valueId;
  const val = vals.find(v => v.id === vid);
  const refId = val?.refId || null;
  const code  = val?.meta?.code || null;

  const checkStr = (s: unknown) => {
    if (!s) return false;
    const str = String(s);
    return str === vid || (refId && str === refId) || (code && str === code);
  };
  return employees.some(emp => Object.values(emp as Record<string, unknown>).some(checkStr));
}

/** Returns count of child values that reference this value as their parent */
function plChildCount(valueId: string, vals: PlValue[]): number {
  return vals.filter(v => v.parentValueId === valueId).length;
}

// ─────────────────────────────────────────────────────────────────────────────
// Page 2 — Values for a selected picklist
// ─────────────────────────────────────────────────────────────────────────────

interface Page2Props {
  picklist: Picklist;
  vals: PlValue[];
  employees: Record<string, unknown>[];
  onBack: () => void;
  /** UUID of this picklist's row in the Supabase `picklists` table (needed for insert) */
  picklistRowId: string;
  onRefetch: () => void;
}

// Modal state shape for Page2
interface ValModal {
  isOpen: boolean;
  kind: 'deactivate-cascade' | 'deactivate-inuse' | 'delete' | null;
  val: PlValue | null;
  childCount?: number;
  // for chained deactivate: after cascade confirm, check in-use next
  pendingInUseCheck?: boolean;
}

function Page2({ picklist, vals, employees, onBack, picklistRowId, onRefetch }: Page2Props) {
  const [showForm, setShowForm]       = useState(false);
  const [editVid, setEditVid]         = useState<string | null>(null);
  const [formValue, setFormValue]     = useState('');
  const [formParent, setFormParent]   = useState('');
  const [formMeta, setFormMeta]       = useState<Record<string, string>>({});
  const [filterParent, setFilterParent] = useState('');
  const [valModal, setValModal]       = useState<ValModal>({ isOpen: false, kind: null, val: null });
  const [valFormErrors, setValFormErrors] = useState<Record<string, string>>({});
  const [valInfoModal, setValInfoModal]   = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });
  const [valSaving, setValSaving]         = useState(false);
  const firstInputRef = useRef<HTMLInputElement | HTMLSelectElement | null>(null);

  const metaFields = picklist.metaFields || [];
  const hasParent  = !!picklist.parentPicklistId;

  // All values for this picklist, sorted
  const pickVals = useMemo(() =>
    vals
      .filter(v => v.picklistId === picklist.id)
      .sort((a, b) => (a.value || '').localeCompare(b.value || '')),
    [vals, picklist.id]
  );

  // Parent options for filter + form
  const parentOptions = useMemo(() => {
    if (!picklist.parentPicklistId) return [];
    return vals
      .filter(v => v.picklistId === picklist.parentPicklistId && v.active !== false)
      .sort((a, b) => (a.value || '').localeCompare(b.value || ''));
  }, [vals, picklist.parentPicklistId]);

  const displayVals = useMemo(() =>
    filterParent
      ? pickVals.filter(v => String(v.parentValueId) === filterParent)
      : pickVals,
    [pickVals, filterParent]
  );

  function openAddForm() {
    setEditVid(null);
    setFormValue('');
    setFormParent('');
    setFormMeta({});
    setShowForm(true);
    setTimeout(() => firstInputRef.current?.focus(), 50);
  }

  function openEditForm(val: PlValue) {
    setEditVid(String(val.id));
    setFormValue(val.value);
    setFormParent(val.parentValueId ?? '');
    const meta: Record<string, string> = {};
    metaFields.forEach(f => { meta[f.key] = val.meta?.[f.key] || ''; });
    setFormMeta(meta);
    setShowForm(true);
    setTimeout(() => firstInputRef.current?.focus(), 50);
  }

  /** Generates a unique 4-char alphanumeric ref_id scoped to this picklist's existing values. */
  function generateRefId(): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    const existing = new Set(pickVals.map(v => v.refId).filter(Boolean) as string[]);
    let id = '';
    let attempts = 0;
    do {
      id = Array.from({ length: 4 }, () =>
        chars[Math.floor(Math.random() * chars.length)]
      ).join('');
      attempts++;
    } while (existing.has(id) && attempts < 500);
    return id;
  }

  async function saveValue() {
    const errs: Record<string, string> = {};
    if (!formValue.trim()) errs.value = 'Value is required.';
    if (hasParent && !formParent) errs.parent = 'Parent value is required.';
    for (const f of metaFields) {
      if (f.required && !formMeta[f.key]?.trim()) errs[f.key] = `${f.label} is required.`;
    }
    if (Object.keys(errs).length > 0) { setValFormErrors(errs); return; }
    setValFormErrors({});

    const meta = metaFields.length
      ? Object.fromEntries(metaFields.map(f => [f.key, formMeta[f.key] || '']))
      : null;

    setValSaving(true);
    try {
      if (editVid !== null) {
        // Edit: update value + meta only, never change ref_id
        const { error } = await supabase.from('picklist_values').update({
          value:           formValue.trim(),
          parent_value_id: formParent || null,
          meta:            meta as unknown as Record<string, string>,
        } as any).eq('id', editVid);
        if (error) throw error;
      } else {
        // Insert via RPC so lock_timeout is enforced server-side
        const { error } = await supabase.rpc('insert_picklist_value', {
          p_picklist_id:     picklistRowId,
          p_value:           formValue.trim(),
          p_parent_value_id: formParent || null,
          p_ref_id:          generateRefId(),
          p_meta:            meta,
        });
        if (error) throw error;
      }

      onRefetch();
      setShowForm(false);
      setEditVid(null);
    } catch (err: any) {
      console.error('[saveValue] Supabase error:', err);
      setValInfoModal({ open: true, title: 'Save Error', message: err?.message ?? 'Failed to save. Check browser console.' });
    } finally {
      setValSaving(false);
    }
  }

  async function toggleValue(val: PlValue) {
    const willDeactivate = val.active !== false;
    if (willDeactivate) {
      const activeChildren = vals.filter(v => v.parentValueId === val.id && v.active !== false);
      if (activeChildren.length) {
        setValModal({
          isOpen: true, kind: 'deactivate-cascade', val,
          childCount: activeChildren.length,
          pendingInUseCheck: plIsInUse(val.id, vals, employees),
        });
        return;
      }
      if (plIsInUse(val.id, vals, employees)) {
        setValModal({ isOpen: true, kind: 'deactivate-inuse', val });
        return;
      }
    }
    const { error } = await supabase.from('picklist_values').update({ active: !willDeactivate } as any).eq('id', val.id);
    if (error) {
      setValInfoModal({ open: true, title: 'Error', message: error.message });
      return;
    }
    onRefetch();
  }

  function deleteValue(val: PlValue) {
    // Check 1: has dependent child values in other picklists
    const childCount = plChildCount(val.id, vals);
    if (childCount > 0) {
      setValInfoModal({
        open: true,
        title: 'Cannot Delete Value',
        message: `"${val.value}" has ${childCount} dependent child value${childCount > 1 ? 's' : ''} in other picklists (e.g. ID Type, Location). Remove those child values first before deleting this entry.`,
      });
      return;
    }
    // Check 2: referenced in actual employee / expense data
    if (plIsInUse(val.id, vals, employees)) {
      setValInfoModal({
        open: true,
        title: 'Cannot Delete Value',
        message: `"${val.value}" is currently used in employee or expense records and cannot be deleted. Deactivate it instead to hide it from new entries.`,
      });
      return;
    }
    setValModal({ isOpen: true, kind: 'delete', val, childCount: 0 });
  }

  // Modal confirm handler — chains cascade → in-use if needed
  async function handleValModalConfirm() {
    const { kind, val, pendingInUseCheck } = valModal;
    if (!val) { setValModal({ isOpen: false, kind: null, val: null }); return; }

    setValSaving(true);
    try {
      if (kind === 'deactivate-cascade') {
        // Deactivate all active children first
        const childIds = vals.filter(v => v.parentValueId === val.id).map(v => v.id);
        if (childIds.length > 0) {
          const { error } = await supabase.from('picklist_values').update({ active: false } as any).in('id', childIds);
          if (error) throw error;
        }
        if (pendingInUseCheck) {
          setValModal({ isOpen: true, kind: 'deactivate-inuse', val });
          onRefetch();
          return;
        }
        // Also deactivate the value itself
        const { error } = await supabase.from('picklist_values').update({ active: false } as any).eq('id', val.id);
        if (error) throw error;
      }

      if (kind === 'deactivate-inuse') {
        const { error } = await supabase.from('picklist_values').update({ active: false } as any).eq('id', val.id);
        if (error) throw error;
      }

      if (kind === 'delete') {
        const children = vals.filter(v => v.parentValueId === val.id);
        const toDelete = [val.id, ...children.map(c => c.id)];
        // Use RPC so lock_timeout=5s is enforced server-side (direct .delete()
        // can hang when line_items FK cascade tries to acquire locks).
        const { error } = await supabase.rpc('delete_picklist_values', { p_ids: toDelete });
        if (error) throw error;
      }

      onRefetch();
      setValModal({ isOpen: false, kind: null, val: null });
    } catch (err: any) {
      console.error('[handleValModalConfirm] Supabase error:', err);
      setValInfoModal({
        open: true,
        title: 'Error',
        message: err?.message ?? 'An unexpected error occurred. Check the browser console for details.',
      });
    } finally {
      setValSaving(false);
    }
  }

  function handleValModalCancel() {
    setValModal({ isOpen: false, kind: null, val: null });
  }

  // Build modal props based on current kind
  const valModalProps = (() => {
    const { kind, val, childCount } = valModal;
    if (!val) return null;
    if (kind === 'deactivate-cascade') return {
      title: 'Deactivate Value',
      message: `Deactivating "${val.value}" will also deactivate all its ${childCount} child value(s).`,
      warning: 'Do you want to continue?',
      confirmText: 'Deactivate',
      destructive: false,
    };
    if (kind === 'deactivate-inuse') return {
      title: 'Value In Use',
      message: `"${val.value}" is used in employee or expense records. Deactivating it will hide it from new entries but existing records will still show "(Inactive)".`,
      warning: 'Do you want to continue?',
      confirmText: 'Deactivate',
      destructive: false,
    };
    if (kind === 'delete') return {
      title: 'Delete Value',
      message: childCount
        ? `Are you sure you want to delete "${val.value}" and its ${childCount} child value(s)?`
        : `Are you sure you want to delete "${val.value}"?`,
      warning: 'This action cannot be undone and will permanently remove the value.',
      confirmText: 'Delete',
      destructive: true,
    };
    return null;
  })();

  function parentLabel(val: PlValue): string {
    if (!val.parentValueId) return '—';
    const pv = vals.find(v => v.id === val.parentValueId);
    return pv ? pv.value : `(${val.parentValueId})`;
  }

  // Dynamic header columns — show the short ref_id code, keep the UUID backend-only
  const cols = ['ID', 'Value'];
  if (hasParent) cols.push('Parent Value');
  metaFields.forEach(f => cols.push(f.label));
  cols.push('Status', 'Actions');

  return (
    <div>
      {/* Header */}
      <div className="rd-header">
        <div className="rd-breadcrumb">
          <button className="rd-back-btn" onClick={onBack}>
            <i className="fa-solid fa-arrow-left" /> Reference Data
          </button>
          <i className="fa-solid fa-chevron-right rd-bc-sep" />
          <span className="rd-page2-title">{picklist.description}</span>
        </div>
        <button className="btn-add" onClick={openAddForm}>
          <i className="fa-solid fa-plus" /> Add Value
        </button>
      </div>

      {/* Parent filter bar */}
      {hasParent && (
        <div className="rd-filter-bar">
          <i className="fa-solid fa-filter" />
          <label htmlFor="rd-parent-filter-sel">Filter by</label>
          <select
            id="rd-parent-filter-sel"
            value={filterParent}
            onChange={e => setFilterParent(e.target.value)}
          >
            <option value="">All</option>
            {parentOptions.map(pv => (
              <option key={pv.id} value={String(pv.id)}>{pv.value}</option>
            ))}
          </select>
        </div>
      )}

      {/* Add / Edit form */}
      {showForm && (
        <div className="rd-form-card">
          <div className="rd-form-row" id="rd-val-form-fields">
            {/* Parent value select */}
            {hasParent && (
              <div className={`form-group${valFormErrors.parent ? ' form-group--error' : ''}`}>
                <label>Parent Value</label>
                <select
                  ref={el => { if (el) firstInputRef.current = el; }}
                  value={formParent}
                  onChange={e => { setFormParent(e.target.value); setValFormErrors(p => ({ ...p, parent: '' })); }}
                  required
                >
                  <option value="">-- Select --</option>
                  {parentOptions.map(pv => (
                    <option key={pv.id} value={String(pv.id)}>{pv.value}</option>
                  ))}
                </select>
                {valFormErrors.parent && (
                  <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                    <i className="fa-solid fa-circle-exclamation" /> {valFormErrors.parent}
                  </small>
                )}
              </div>
            )}
            {/* Value input */}
            <div className={`form-group${valFormErrors.value ? ' form-group--error' : ''}`}>
              <label>Value</label>
              <input
                ref={el => { if (!hasParent && el) firstInputRef.current = el; }}
                type="text"
                value={formValue}
                onChange={e => { setFormValue(e.target.value); setValFormErrors(p => ({ ...p, value: '' })); }}
                required
              />
              {valFormErrors.value && (
                <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                  <i className="fa-solid fa-circle-exclamation" /> {valFormErrors.value}
                </small>
              )}
            </div>
            {/* Meta fields */}
            {metaFields.map(f => {
              const isSelect = f.type === 'select' && !!f.sourcePicklistId;
              const sourceOpts = isSelect
                ? vals.filter(v => v.picklistId === f.sourcePicklistId && v.active !== false)
                    .sort((a, b) => a.value.localeCompare(b.value))
                : [];
              return (
                <div className={`form-group${valFormErrors[f.key] ? ' form-group--error' : ''}`} key={f.key} style={f.width ? { maxWidth: f.width } : undefined}>
                  <label>{f.label}{f.required && <span className="req"> *</span>}</label>
                  {isSelect ? (
                    <select
                      value={formMeta[f.key] || ''}
                      onChange={e => { setFormMeta(m => ({ ...m, [f.key]: e.target.value })); setValFormErrors(p => ({ ...p, [f.key]: '' })); }}
                      required={!!f.required}
                    >
                      <option value="">— None —</option>
                      {sourceOpts.map(opt => (
                        <option key={String(opt.id)} value={String(opt.id)}>{opt.value}</option>
                      ))}
                    </select>
                  ) : (
                    <input
                      type="text"
                      placeholder={f.placeholder || ''}
                      value={formMeta[f.key] || ''}
                      onChange={e => { setFormMeta(m => ({ ...m, [f.key]: e.target.value })); setValFormErrors(p => ({ ...p, [f.key]: '' })); }}
                      required={!!f.required}
                    />
                  )}
                  {valFormErrors[f.key] && (
                    <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                      <i className="fa-solid fa-circle-exclamation" /> {valFormErrors[f.key]}
                    </small>
                  )}
                </div>
              );
            })}
          </div>
          <div className="rd-form-actions">
            <button className="btn-add" onClick={saveValue} disabled={valSaving}>
              {valSaving
                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : <><i className="fa-solid fa-floppy-disk" /> Save</>}
            </button>
            <button className="btn-cancel" onClick={() => setShowForm(false)} disabled={valSaving}>Cancel</button>
          </div>
        </div>
      )}

      {/* Values table */}
      <div className="er-table-wrap" style={{ overflow: 'hidden', maxWidth: '100%' }}>
        <div style={{ overflowY: 'auto', maxHeight: 'calc(100vh - 340px)' }}>
        <table className="er-table" id="rd-val-table">
          <thead style={{ position: 'sticky', top: 0, zIndex: 5 }}>
            <tr>{cols.map(c => <th key={c}>{c}</th>)}</tr>
          </thead>
          <tbody>
            {displayVals.length === 0 ? (
              <tr><td colSpan={cols.length} className="rd-empty">No values defined.</td></tr>
            ) : displayVals.map(val => {
              const isActive = val.active !== false;
              return (
                <tr key={val.id}>
                  <td><span className="rd-id-badge">{val.refId ?? '—'}</span></td>
                  <td>{val.value}</td>
                  {hasParent && <td>{parentLabel(val)}</td>}
                  {metaFields.map(f => {
                    const raw = val.meta?.[f.key] || '';
                    let display = raw || '—';
                    if (f.type === 'select' && f.sourcePicklistId && raw) {
                      const match = vals.find(v => v.picklistId === f.sourcePicklistId && String(v.id) === raw);
                      display = match ? match.value : raw;
                    }
                    return <td key={f.key}>{display}</td>;
                  })}
                  <td>
                    <button
                      className={`rd-toggle-btn ${isActive ? 'is-active' : 'is-inactive'}`}
                      title={isActive ? 'Active – click to deactivate' : 'Inactive – click to activate'}
                      onClick={() => toggleValue(val)}
                    >
                      {isActive ? 'Active' : 'Inactive'}
                    </button>
                  </td>
                  <td className="rd-actions">
                    <button className="rd-btn-edit-val" title="Edit" onClick={() => openEditForm(val)}>
                      <i className="fa-solid fa-pen-to-square" />
                    </button>
                    <button className="rd-btn-del-val" title="Delete" onClick={() => deleteValue(val)}>
                      <i className="fa-solid fa-trash" />
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        </div>
      </div>

      {/* ── Value action modal ──────────────────────────────────────────────── */}
      {valModalProps && (
        <ConfirmationModal
          isOpen={valModal.isOpen}
          title={valModalProps.title}
          message={valModalProps.message}
          warning={valModalProps.warning}
          confirmText={valModalProps.confirmText}
          cancelText="Cancel"
          destructive={valModalProps.destructive}
          loading={valSaving}
          onConfirm={handleValModalConfirm}
          onCancel={handleValModalCancel}
        />
      )}

      {/* ── Info / blocking modal (replaces alert) ── */}
      {valInfoModal.open && (
        <div className="modal-overlay" onClick={() => setValInfoModal(m => ({ ...m, open: false }))}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-circle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>{valInfoModal.title}</h3>
            </div>
            <div className="modal-body">{valInfoModal.message}</div>
            <div className="modal-actions">
              <button className="btn-add" style={{ padding: '9px 28px' }}
                onClick={() => setValInfoModal(m => ({ ...m, open: false }))}>OK</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Page 1 — Picklist Directory
// ─────────────────────────────────────────────────────────────────────────────

interface Page1Props {
  picklists:       Picklist[];
  vals:            PlValue[];
  loading:         boolean;
  onSavePicklist:  (data: { id: string; description: string; parentPicklistId: string | null; isNew: boolean }) => Promise<void>;
  onDeletePicklist:(id: string) => Promise<void>;
  onRefetch:       () => void;
  onOpenPage2:     (id: string) => void;
}

function Page1({ picklists, vals, loading, onSavePicklist, onDeletePicklist, onRefetch, onOpenPage2 }: Page1Props) {
  const [showForm, setShowForm]   = useState(false);
  const [editPlId, setEditPlId]   = useState<string | null>(null);
  const [formId, setFormId]       = useState('');
  const [formDesc, setFormDesc]   = useState('');
  const [formParent, setFormParent] = useState('');
  const [plModal, setPlModal]     = useState<{ isOpen: boolean; pl: Picklist | null; count: number }>({ isOpen: false, pl: null, count: 0 });
  const [plFormErrors, setPlFormErrors] = useState<Record<string, string>>({});
  const [plInfoModal, setPlInfoModal]   = useState<{ open: boolean; title: string; message: string }>({ open: false, title: '', message: '' });
  const [saving, setSaving]             = useState(false);
  const descRef = useRef<HTMLInputElement>(null);

  function countVals(plId: string) {
    return vals.filter(v => v.picklistId === plId).length;
  }

  function parentLabel(parentId?: string | null) {
    if (!parentId) return '—';
    const pl = picklists.find(p => p.id === parentId);
    return pl ? pl.description : parentId;
  }

  function openAddForm() {
    setEditPlId(null);
    setFormId(''); setFormDesc(''); setFormParent('');
    setShowForm(true);
    setTimeout(() => descRef.current?.focus(), 50);
  }

  function openEditForm(pl: Picklist) {
    setEditPlId(pl.id);
    setFormId(pl.id);
    setFormDesc(pl.description);
    setFormParent(pl.parentPicklistId || '');
    setShowForm(true);
    setTimeout(() => descRef.current?.focus(), 50);
  }

  async function savePl() {
    const newId = formId.trim().toUpperCase().replace(/\s+/g, '_');
    const desc  = formDesc.trim();
    const errs: Record<string, string> = {};
    if (!newId)  errs.plId   = 'Picklist ID is required.';
    if (!desc)   errs.plDesc = 'Description is required.';
    if (Object.keys(errs).length > 0) { setPlFormErrors(errs); return; }
    setPlFormErrors({});

    if (!editPlId && picklists.find(p => p.id === newId)) {
      setPlFormErrors({ plId: `A picklist with ID "${newId}" already exists.` });
      return;
    }

    setSaving(true);
    try {
      await onSavePicklist({
        id:               editPlId ?? newId,
        description:      desc,
        parentPicklistId: formParent || null,
        isNew:            !editPlId,
      });
      onRefetch();
      setShowForm(false);
      setEditPlId(null);
    } catch (err: any) {
      setPlInfoModal({ open: true, title: 'Error', message: err.message ?? 'Failed to save picklist.' });
    } finally {
      setSaving(false);
    }
  }

  function deletePl(pl: Picklist) {
    const count = countVals(pl.id);
    setPlModal({ isOpen: true, pl, count });
  }

  async function confirmDeletePl() {
    if (plModal.pl) {
      setSaving(true);
      try {
        await onDeletePicklist(plModal.pl.id);
        onRefetch();
      } catch (err: any) {
        setPlInfoModal({ open: true, title: 'Error', message: err.message ?? 'Failed to delete picklist.' });
      } finally {
        setSaving(false);
      }
    }
    setPlModal({ isOpen: false, pl: null, count: 0 });
  }

  function cancelDeletePl() {
    setPlModal({ isOpen: false, pl: null, count: 0 });
  }

  return (
    <div>
      {/* Header */}
      <div className="rd-header">
        <div>
          <h2 className="page-title">Reference Data</h2>
          <p className="page-subtitle">Manage all picklists used across the system.</p>
        </div>
        <button className="btn-add" onClick={openAddForm}>
          <i className="fa-solid fa-plus" /> New Picklist
        </button>
      </div>

      {/* Add / Edit picklist form */}
      {showForm && (
        <div className="rd-form-card">
          <div className="rd-form-row">
            <div className={`form-group${plFormErrors.plId ? ' form-group--error' : ''}`}>
              <label>
                Picklist ID <span className="req">*</span>
                <span className="field-hint">Unique system key e.g. DEPARTMENT</span>
              </label>
              <input
                type="text"
                placeholder="e.g. DEPARTMENT"
                value={formId}
                readOnly={!!editPlId}
                onChange={e => { setFormId(e.target.value); setPlFormErrors(p => ({ ...p, plId: '' })); }}
                autoComplete="off"
              />
              {plFormErrors.plId && (
                <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                  <i className="fa-solid fa-circle-exclamation" /> {plFormErrors.plId}
                </small>
              )}
            </div>
            <div className={`form-group${plFormErrors.plDesc ? ' form-group--error' : ''}`}>
              <label>Description <span className="req">*</span></label>
              <input
                ref={descRef}
                type="text"
                placeholder="e.g. Department"
                value={formDesc}
                onChange={e => { setFormDesc(e.target.value); setPlFormErrors(p => ({ ...p, plDesc: '' })); }}
              />
              {plFormErrors.plDesc && (
                <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
                  <i className="fa-solid fa-circle-exclamation" /> {plFormErrors.plDesc}
                </small>
              )}
            </div>
            <div className="form-group">
              <label>
                Parent Picklist
                <span className="field-hint">Enables dependent dropdowns</span>
              </label>
              <select value={formParent} onChange={e => setFormParent(e.target.value)}>
                <option value="">— None —</option>
                {picklists
                  .filter(p => !editPlId || p.id !== editPlId)
                  .map(p => (
                    <option key={p.id} value={p.id}>{p.description} ({p.id})</option>
                  ))}
              </select>
            </div>
          </div>
          <div className="rd-form-actions">
            <button className="btn-add" onClick={savePl} disabled={saving}>
              {saving
                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : <><i className="fa-solid fa-floppy-disk" /> Save</>}
            </button>
            <button className="btn-cancel" onClick={() => setShowForm(false)} disabled={saving}>Cancel</button>
          </div>
        </div>
      )}

      {/* Picklist table */}
      <div className="er-table-wrap" style={{ overflow: 'hidden', maxWidth: '100%' }}>
        <div style={{ overflowY: 'auto', maxHeight: 'calc(100vh - 340px)' }}>
        <table className="er-table" id="rd-pl-table">
          <thead style={{ position: 'sticky', top: 0, zIndex: 5 }}>
            <tr>
              <th>Picklist ID</th>
              <th>Description</th>
              <th>Parent Picklist</th>
              <th style={{ textAlign: 'center' }}># Values</th>
              <th style={{ textAlign: 'right' }}>Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr><td colSpan={5} className="rd-empty"><i className="fa-solid fa-spinner fa-spin" /> Loading picklists…</td></tr>
            ) : picklists.length === 0 ? (
              <tr><td colSpan={5} className="rd-empty">No picklists defined.</td></tr>
            ) : picklists.map(pl => (
              <tr key={pl.id}>
                <td><span className="rd-id-badge">{pl.id}</span></td>
                <td>{pl.description}</td>
                <td>{parentLabel(pl.parentPicklistId)}</td>
                <td style={{ textAlign: 'center' }}><span className="rd-count-badge">{countVals(pl.id)}</span></td>
                <td style={{ textAlign: 'right' }} className="rd-actions">
                  <button className="rd-btn-values" onClick={() => onOpenPage2(pl.id)} title="Manage Values">
                    <i className="fa-solid fa-list" /> Values
                  </button>
                  {!pl.system && (
                    <>
                      <button className="rd-btn-edit-pl" title="Edit Picklist" onClick={() => openEditForm(pl)}>
                        <i className="fa-solid fa-pen-to-square" />
                      </button>
                      <button className="rd-btn-del-pl" title="Delete Picklist" onClick={() => deletePl(pl)}>
                        <i className="fa-solid fa-trash" />
                      </button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        </div>
      </div>

      {/* ── Delete picklist confirmation modal ─────────────────────────────── */}
      <ConfirmationModal
        isOpen={plModal.isOpen}
        title="Delete Picklist"
        message={
          plModal.count > 0
            ? `Are you sure you want to delete picklist "${plModal.pl?.id}" and all ${plModal.count} of its values?`
            : `Are you sure you want to delete picklist "${plModal.pl?.id}"?`
        }
        warning="This action cannot be undone and will permanently remove the picklist and all its values."
        confirmText="Delete"
        cancelText="Cancel"
        destructive={true}
        onConfirm={confirmDeletePl}
        onCancel={cancelDeletePl}
      />

      {/* ── Info / blocking modal (replaces alert) ── */}
      {plInfoModal.open && (
        <div className="modal-overlay" onClick={() => setPlInfoModal(m => ({ ...m, open: false }))}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-circle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>{plInfoModal.title}</h3>
            </div>
            <div className="modal-body">{plInfoModal.message}</div>
            <div className="modal-actions">
              <button className="btn-add" style={{ padding: '9px 28px' }}
                onClick={() => setPlInfoModal(m => ({ ...m, open: false }))}>OK</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Root component
// ─────────────────────────────────────────────────────────────────────────────

export default function ReferenceData() {
  // ── Picklist definitions — loaded from Supabase ────────────────────────────
  const [picklists,        setPicklists]        = useState<Picklist[]>([]);
  const [picklistsLoading, setPicklistsLoading] = useState(true);
  const [picklistUuidMap,  setPicklistUuidMap]  = useState<Map<string, string>>(new Map());
  const [plTick,           setPlTick]           = useState(0);
  const refetchPicklists = useCallback(() => setPlTick(t => t + 1), []);

  useEffect(() => {
    let mounted = true;
    setPicklistsLoading(true);

    async function loadPicklists() {
      try {
        const { data, error: err } = await supabase
          .from('picklists')
          .select('id, picklist_id, name, parent_picklist_id, system, meta_fields')
          .order('name', { ascending: true });


        if (!mounted) return;
        if (err) throw err;
        if (!data) return;

        // Build UUID ↔ code maps first (needed for parent resolution)
        const uuidToCode = new Map(data.map((r) => [r.id, r.picklist_id]));
        const codeToUUID = new Map(data.map((r) => [r.picklist_id, r.id]));
        setPicklistUuidMap(codeToUUID);

        // Map DB rows → frontend Picklist shape
        const mapped: Picklist[] = data.map((row) => {
          // System picklists: use DEFAULT_PICKLISTS metaFields (includes placeholder/required/width)
          // User-created picklists: use meta_fields from DB
          const systemDef = DEFAULT_PICKLISTS.find(d => d.id === row.picklist_id);
          return {
            id:               row.picklist_id,
            description:      row.name,
            parentPicklistId: row.parent_picklist_id
              ? (uuidToCode.get(row.parent_picklist_id) ?? null)
              : null,
            system:           row.system ?? false,
            metaFields:       systemDef ? (systemDef.metaFields ?? []) : ((row.meta_fields as unknown as MetaField[] | null) ?? []),
          };
        });
        setPicklists(mapped);
      } catch (err) {
        console.error('[ReferenceData] Failed to load picklists:', err);
        // picklistsLoading clears in finally so the spinner doesn't hang
      } finally {
        if (mounted) setPicklistsLoading(false);
      }
    }

    // Defer past the supabase-js auth lock (held during onAuthStateChange / token refresh).
    // Calling supabase.from() synchronously on mount can deadlock if _initialize() is
    // still running. setTimeout(0) ensures we run after the lock is released.
    const t = setTimeout(() => { loadPicklists(); }, 0);
    return () => { mounted = false; clearTimeout(t); };
  }, [plTick]);

  // ── Picklist values — from Supabase (include inactive for admin management) ─
  const { picklistValues: supabaseVals, refetch: refetchVals } = usePicklistValues(false);
  const vals = supabaseVals as unknown as PlValue[];

  // ── Employees — from Supabase (used for "in-use" checks) ──────────────────
  const { employees: supabaseEmps } = useEmployees();
  const employees = supabaseEmps as unknown as Record<string, unknown>[];

  const [activePlId, setActivePlId] = useState<string | null>(null);

  // ── Save picklist (insert or update) ──────────────────────────────────────
  const handleSavePicklist = useCallback(async (data: {
    id: string; description: string; parentPicklistId: string | null; isNew: boolean;
  }) => {
    const parentUUID = data.parentPicklistId
      ? (picklistUuidMap.get(data.parentPicklistId) ?? null)
      : null;

    if (data.isNew) {
      const { error } = await supabase.from('picklists').insert({
        picklist_id:        data.id,
        name:               data.description,
        system:             false,
        meta_fields:        [],
        parent_picklist_id: parentUUID,
      });
      if (error) throw error;
    } else {
      // Look up the UUID for this picklist_id
      const uuid = picklistUuidMap.get(data.id);
      if (!uuid) throw new Error(`Could not find UUID for picklist "${data.id}"`);
      const { error } = await supabase.from('picklists').update({
        name:               data.description,
        parent_picklist_id: parentUUID,
      } as any).eq('id', uuid);
      if (error) throw error;
    }
  }, [picklistUuidMap]);

  // ── Delete picklist (cascades to picklist_values via FK) ──────────────────
  const handleDeletePicklist = useCallback(async (plCode: string) => {
    const uuid = picklistUuidMap.get(plCode);
    if (!uuid) throw new Error(`Could not find UUID for picklist "${plCode}"`);
    const { error } = await supabase.from('picklists').delete().eq('id', uuid);
    if (error) throw error;
  }, [picklistUuidMap]);

  const activePl = activePlId ? picklists.find(p => p.id === activePlId) ?? null : null;

  if (activePl) {
    return (
      <div className="ar-panel">
        <Page2
          picklist={activePl}
          vals={vals}
          employees={employees}
          onBack={() => setActivePlId(null)}
          picklistRowId={picklistUuidMap.get(activePl.id) ?? ''}
          onRefetch={refetchVals}
        />
      </div>
    );
  }

  return (
    <div className="ar-panel">
      <Page1
        picklists={picklists}
        vals={vals}
        loading={picklistsLoading}
        onSavePicklist={handleSavePicklist}
        onDeletePicklist={handleDeletePicklist}
        onRefetch={refetchPicklists}
        onOpenPage2={setActivePlId}
      />
    </div>
  );
}
