/**
 * TargetGroups
 *
 * Admin screen for managing CUSTOM target groups only.
 * System groups (self, everyone, direct_l1, etc.) are defined in the DB and
 * resolved by user_can() — there is nothing to configure on them here.
 * They remain selectable in the Permission Matrix when assigning permissions.
 *
 * Left panel  — list of custom groups with member count and usage count.
 *               "New Group" button to create one.
 *
 * Right panel — criteria builder for the selected custom group:
 *   • Portlet → Field → Values (multi-select chips)
 *   • Multiple rules joined by a single AND / OR operator
 *   • "Preview count" runs a live employee count against the rules
 *   • "Save rules" persists filter_rules JSONB to target_groups
 *
 * filter_rules JSON shape stored in DB:
 * {
 *   "operator": "AND" | "OR",
 *   "rules": [
 *     { "portlet": "employment", "field": "dept_id",     "values": ["<uuid>"] },
 *     { "portlet": "employment", "field": "work_country", "values": ["SA"] }
 *   ]
 * }
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { supabase }       from '../../../lib/supabase';
import ErrorBanner        from '../../shared/ErrorBanner';
import { usePermissions } from '../../../hooks/usePermissions';

// ─── Types ────────────────────────────────────────────────────────────────────

interface TargetGroup {
  id:           string;
  code:         string;
  label:        string;
  scope_type:   'custom';
  filter_rules: FilterRules | null;
  is_system:    boolean;
  created_at:   string;
  memberCount:  number;
  usageCount:   number;
}

interface FilterRules {
  operator: 'AND' | 'OR';
  rules:    FilterRule[];
}

interface FilterRuleValue {
  value: string;   // actual DB value (UUID for FK fields, raw text for plain fields)
  label: string;   // display label shown in the UI
}

interface FilterRule {
  portlet:  string;
  field:    string;
  values:   FilterRuleValue[];
}

// ─── Portlet / field catalogue ────────────────────────────────────────────────
// Maps portlet code → field code → display label + DB column for querying.
// Extend this as more employee fields become relevant.

interface FieldDef {
  label:        string;
  column:       string;       // column name in sourceTable
  sourceTable?: string;       // table to query for plain-text fields (default: 'employees')
                              // use 'employee_personal' for nationality, gender, marital_status
  lookup?:      string;       // FK lookup table ('departments', 'picklist_values')
  labelCol?:    string;       // display column on lookup table ('name', 'value')
                              // when set, search is done against lookup table via ilike on labelCol
}

interface PortletDef {
  label:  string;
  fields: Record<string, FieldDef>;
}

const PORTLET_CATALOGUE: Record<string, PortletDef> = {
  employment: {
    label: 'Employment',
    fields: {
      dept_id:      { label: 'Department',  column: 'dept_id',      lookup: 'departments',    labelCol: 'name'  },
      work_country: { label: 'Work Country', column: 'work_country', lookup: 'picklist_values', labelCol: 'value' },
      work_location:{ label: 'Location',    column: 'work_location', lookup: 'picklist_values', labelCol: 'value' },
      designation:  { label: 'Designation', column: 'designation',  lookup: 'picklist_values', labelCol: 'value' },
      status:       { label: 'Status',      column: 'status' },
    },
  },
  personal_info: {
    label: 'Personal Info',
    fields: {
      name:           { label: 'Name',          column: 'name' },
      employee_id:    { label: 'Employee ID',   column: 'employee_id' },
      nationality:    { label: 'Nationality',   column: 'nationality',    sourceTable: 'employee_personal' },
      gender:         { label: 'Gender',        column: 'gender',         sourceTable: 'employee_personal' },
      marital_status: { label: 'Marital Status',column: 'marital_status', sourceTable: 'employee_personal', lookup: 'picklist_values', labelCol: 'value' },
    },
  },
};

// ─── Toast ────────────────────────────────────────────────────────────────────

interface Toast { id: string; message: string; type: 'success' | 'error'; }

function useToasts() {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const add = useCallback((message: string, type: Toast['type'] = 'success') => {
    const id = `t_${Date.now()}`;
    setToasts(prev => [...prev, { id, message, type }]);
    setTimeout(() => setToasts(prev => prev.filter(t => t.id !== id)), 3500);
  }, []);
  const dismiss = useCallback((id: string) => {
    setToasts(prev => prev.filter(t => t.id !== id));
  }, []);
  return { toasts, add, dismiss };
}

function ToastContainer({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: string) => void }) {
  if (!toasts.length) return null;
  return (
    <div style={{ position: 'fixed', bottom: 24, right: 24, zIndex: 9999, display: 'flex', flexDirection: 'column', gap: 8 }}>
      {toasts.map(t => (
        <div key={t.id} style={{
          display: 'flex', alignItems: 'center', gap: 10,
          padding: '10px 16px', borderRadius: 8, fontSize: 14,
          background: t.type === 'success' ? '#D1FAE5' : '#FEE2E2',
          color:      t.type === 'success' ? '#065F46' : '#991B1B',
          boxShadow: '0 2px 8px rgba(0,0,0,0.12)', minWidth: 300,
        }}>
          <i className={`fa-solid ${t.type === 'success' ? 'fa-circle-check' : 'fa-circle-xmark'}`} />
          <span style={{ flex: 1 }}>{t.message}</span>
          <button onClick={() => onDismiss(t.id)} style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}>
            <i className="fa-solid fa-xmark" style={{ fontSize: 12, opacity: 0.6 }} />
          </button>
        </div>
      ))}
    </div>
  );
}

// ─── Create Group Modal ───────────────────────────────────────────────────────

function CreateGroupModal({
  onSave, onCancel, saving,
}: {
  onSave: (label: string, code: string) => void;
  onCancel: () => void;
  saving: boolean;
}) {
  const [label, setLabel] = useState('');
  const [code,  setCode]  = useState('');
  const typedCode = useRef(false);

  const handleLabel = (val: string) => {
    setLabel(val);
    if (!typedCode.current)
      setCode(val.toLowerCase().replace(/\s+/g, '_').replace(/[^a-z0-9_]/g, ''));
  };
  const handleCode = (val: string) => {
    typedCode.current = true;
    setCode(val.toLowerCase().replace(/[^a-z0-9_]/g, ''));
  };
  const valid = label.trim().length >= 2 && code.trim().length >= 2;

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)', zIndex: 1000, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ background: '#fff', borderRadius: 12, padding: 32, width: 440, boxShadow: '0 8px 32px rgba(0,0,0,0.18)' }}>
        <h3 style={{ margin: '0 0 6px', fontSize: 18, fontWeight: 700, color: '#111827' }}>New Target Group</h3>
        <p style={{ margin: '0 0 24px', fontSize: 13, color: '#6B7280' }}>
          Define membership criteria after creating the group.
        </p>
        <label style={{ display: 'block', fontSize: 13, fontWeight: 600, color: '#374151', marginBottom: 4 }}>Label *</label>
        <input value={label} onChange={e => handleLabel(e.target.value)} placeholder="e.g. Finance APAC"
          style={{ width: '100%', padding: '9px 12px', fontSize: 14, borderRadius: 7, border: '1px solid #D1D5DB', outline: 'none', marginBottom: 16, boxSizing: 'border-box' }} />
        <label style={{ display: 'block', fontSize: 13, fontWeight: 600, color: '#374151', marginBottom: 4 }}>
          Code * <span style={{ fontSize: 11, fontWeight: 400, color: '#9CA3AF' }}>(unique, lowercase, underscores only)</span>
        </label>
        <input value={code} onChange={e => handleCode(e.target.value)} placeholder="e.g. finance_apac"
          style={{ width: '100%', padding: '9px 12px', fontSize: 14, borderRadius: 7, border: '1px solid #D1D5DB', outline: 'none', marginBottom: 24, boxSizing: 'border-box', fontFamily: 'monospace' }} />
        <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
          <button onClick={onCancel} disabled={saving} style={{ padding: '9px 18px', borderRadius: 7, border: '1px solid #D1D5DB', background: '#fff', color: '#374151', fontSize: 14, cursor: 'pointer' }}>Cancel</button>
          <button onClick={() => onSave(label.trim(), code.trim())} disabled={!valid || saving}
            style={{ padding: '9px 18px', borderRadius: 7, border: 'none', background: valid && !saving ? '#1D4ED8' : '#9CA3AF', color: '#fff', fontSize: 14, cursor: valid && !saving ? 'pointer' : 'not-allowed', display: 'flex', alignItems: 'center', gap: 6 }}>
            {saving && <i className="fa-solid fa-circle-notch fa-spin" style={{ fontSize: 12 }} />}
            Create Group
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Delete Confirm ───────────────────────────────────────────────────────────

function DeleteConfirmModal({ group, onConfirm, onCancel, deleting }: {
  group: TargetGroup; onConfirm: () => void; onCancel: () => void; deleting: boolean;
}) {
  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)', zIndex: 1000, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ background: '#fff', borderRadius: 12, padding: 28, width: 420, boxShadow: '0 8px 32px rgba(0,0,0,0.18)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 16 }}>
          <div style={{ background: '#FEE2E2', borderRadius: '50%', width: 40, height: 40, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <i className="fa-solid fa-trash" style={{ color: '#DC2626', fontSize: 16 }} />
          </div>
          <h3 style={{ margin: 0, fontSize: 17, fontWeight: 700, color: '#111827' }}>Delete "{group.label}"?</h3>
        </div>
        <p style={{ margin: '0 0 20px', fontSize: 14, color: '#374151', lineHeight: 1.5 }}>
          This will permanently delete the group, its cached memberships, and clear any permission set assignments referencing it. This cannot be undone.
        </p>
        <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
          <button onClick={onCancel} disabled={deleting} style={{ padding: '9px 18px', borderRadius: 7, border: '1px solid #D1D5DB', background: '#fff', color: '#374151', fontSize: 14, cursor: 'pointer' }}>Cancel</button>
          <button onClick={onConfirm} disabled={deleting} style={{ padding: '9px 18px', borderRadius: 7, border: 'none', background: '#DC2626', color: '#fff', fontSize: 14, cursor: deleting ? 'not-allowed' : 'pointer', display: 'flex', alignItems: 'center', gap: 6 }}>
            {deleting && <i className="fa-solid fa-circle-notch fa-spin" style={{ fontSize: 12 }} />}
            Delete Group
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Value search ─────────────────────────────────────────────────────────────
// Searches DB for matching values as the admin types.
// FK fields (dept_id) search the lookup table by name.
// Plain text fields search distinct values on employees with ilike.

interface FieldValue { value: string; label: string; }

async function searchFieldValues(
  portlet: string,
  field:   string,
  query:   string,
): Promise<FieldValue[]> {
  const def = PORTLET_CATALOGUE[portlet]?.fields[field];
  if (!def) return [];
  const q = query.trim();

  // ── Step 1: get distinct raw values employees actually have ──────────────────
  // For FK fields these are UUIDs; for plain-text fields these are the display values.
  // Querying the source table (employees or employee_personal) ensures we only show
  // values that are actually in use — no cross-picklist bleed, no phantom values.
  const sourceTable = def.sourceTable ?? 'employees';
  const { data: sourceData, error: sourceError } = await supabase
    .from(sourceTable)
    .select(def.column)
    .not(def.column, 'is', null)
    .limit(500);           // FK columns have very few distinct values; plain-text may have more
  if (sourceError || !sourceData) return [];

  const distinctRaw: string[] = [
    ...new Set(
      sourceData
        .map((r: any) => r[def.column])
        .filter((v: unknown): v is string => !!v)
    ),
  ];
  if (distinctRaw.length === 0) return [];

  // ── Step 2a: FK field — resolve UUIDs → labels via lookup table ─────────────
  if (def.lookup && def.labelCol) {
    const { data, error } = await supabase
      .from(def.lookup)
      .select(`id, ${def.labelCol}`)
      .in('id', distinctRaw)          // only IDs employees actually have
      .order(def.labelCol, { ascending: true });
    if (error || !data) return [];
    return data
      .filter((r: any) => !q || String(r[def.labelCol!]).toLowerCase().includes(q.toLowerCase()))
      .map((r: any) => ({ value: String(r.id), label: String(r[def.labelCol!] ?? r.id) }))
      .slice(0, 20);
  }

  // ── Step 2b: Plain-text field — filter in memory ────────────────────────────
  const ql = q.toLowerCase();
  return distinctRaw
    .filter(v => !q || v.toLowerCase().includes(ql))
    .sort()
    .slice(0, 20)
    .map(v => ({ value: v, label: v }));
}

// ─── ValueSearchInput ─────────────────────────────────────────────────────────
// Typeahead input for selecting one or more values for a rule.
// Selected values shown as removable tags above the input.

function ValueSearchInput({
  portlet, field, selected, onAdd, onRemove,
}: {
  portlet:  string;
  field:    string;
  selected: FilterRuleValue[];
  onAdd:    (v: FilterRuleValue) => void;
  onRemove: (value: string) => void;
}) {
  const [query,       setQuery]       = useState('');
  const [suggestions, setSuggestions] = useState<FieldValue[]>([]);
  const [searching,   setSearching]   = useState(false);
  const [open,        setOpen]        = useState(false);
  const debounceRef   = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wrapperRef    = useRef<HTMLDivElement>(null);
  const fieldDef      = PORTLET_CATALOGUE[portlet]?.fields[field];

  // Close dropdown on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (wrapperRef.current && !wrapperRef.current.contains(e.target as Node))
        setOpen(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  // Debounced search
  const handleInput = (val: string) => {
    setQuery(val);
    setOpen(true);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(async () => {
      setSearching(true);
      const results = await searchFieldValues(portlet, field, val);
      // Filter out already-selected values
      setSuggestions(results.filter(r => !selected.some(s => s.value === r.value)));
      setSearching(false);
    }, 280);
  };

  // Open dropdown with all values on focus if query is empty
  const handleFocus = async () => {
    setOpen(true);
    if (!query && suggestions.length === 0) {
      setSearching(true);
      const results = await searchFieldValues(portlet, field, '');
      setSuggestions(results.filter(r => !selected.some(s => s.value === r.value)));
      setSearching(false);
    }
  };

  const handleSelect = (fv: FieldValue) => {
    onAdd({ value: fv.value, label: fv.label });
    setQuery('');
    setSuggestions(prev => prev.filter(s => s.value !== fv.value));
    setOpen(false);
  };

  return (
    <div ref={wrapperRef}>
      {/* Selected tags */}
      {selected.length > 0 && (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
          {selected.map(s => (
            <span key={s.value} style={{
              display: 'inline-flex', alignItems: 'center', gap: 5,
              padding: '3px 8px 3px 10px', borderRadius: 20, fontSize: 12,
              background: '#EFF6FF', border: '1px solid #93C5FD', color: '#1D4ED8',
            }}>
              {s.label}
              <button
                onClick={() => onRemove(s.value)}
                style={{ display: 'flex', alignItems: 'center', background: 'none', border: 'none', cursor: 'pointer', padding: 0, color: '#60A5FA', lineHeight: 1 }}
              >
                <i className="fa-solid fa-xmark" style={{ fontSize: 10 }} />
              </button>
            </span>
          ))}
        </div>
      )}

      {/* Search input + dropdown */}
      <div style={{ position: 'relative' }}>
        <div style={{ position: 'relative', display: 'flex', alignItems: 'center' }}>
          <i className="fa-solid fa-magnifying-glass" style={{
            position: 'absolute', left: 10, fontSize: 12,
            color: '#9CA3AF', pointerEvents: 'none',
          }} />
          <input
            value={query}
            onChange={e => handleInput(e.target.value)}
            onFocus={handleFocus}
            placeholder={`Search ${fieldDef?.label ?? 'values'}…`}
            style={{
              width: '100%', padding: '8px 10px 8px 30px',
              fontSize: 13, borderRadius: 7,
              border: '1px solid #D1D5DB', outline: 'none',
              background: '#fff',
            }}
          />
          {searching && (
            <i className="fa-solid fa-circle-notch fa-spin" style={{
              position: 'absolute', right: 10, fontSize: 12, color: '#9CA3AF',
            }} />
          )}
        </div>

        {/* Suggestions dropdown */}
        {open && (query.length > 0 || suggestions.length > 0) && (
          <div style={{
            position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 50,
            background: '#fff', border: '1px solid #E5E7EB', borderRadius: 8,
            boxShadow: '0 4px 16px rgba(0,0,0,0.10)', marginTop: 2,
            maxHeight: 220, overflowY: 'auto',
          }}>
            {searching ? (
              <div style={{ padding: '10px 14px', fontSize: 13, color: '#9CA3AF' }}>Searching…</div>
            ) : suggestions.length === 0 ? (
              <div style={{ padding: '10px 14px', fontSize: 13, color: '#9CA3AF' }}>
                {query ? 'No matches found' : 'No more values to add'}
              </div>
            ) : (
              suggestions.map(s => (
                <button
                  key={s.value}
                  onMouseDown={e => { e.preventDefault(); handleSelect(s); }}
                  style={{
                    display: 'block', width: '100%', textAlign: 'left',
                    padding: '9px 14px', border: 'none', background: 'transparent',
                    fontSize: 13, color: '#111827', cursor: 'pointer',
                    borderBottom: '1px solid #F9FAFB',
                  }}
                  onMouseOver={e  => (e.currentTarget.style.background = '#F9FAFB')}
                  onMouseOut={e   => (e.currentTarget.style.background = 'transparent')}
                >
                  {s.label}
                </button>
              ))
            )}
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Rule card ────────────────────────────────────────────────────────────────

function RuleCard({
  rule, index,
  onPortletChange, onFieldChange, onAddValue, onRemoveValue, onRemove,
}: {
  rule:            FilterRule;
  index:           number;
  onPortletChange: (idx: number, portlet: string) => void;
  onFieldChange:   (idx: number, field: string) => void;
  onAddValue:      (idx: number, v: FilterRuleValue) => void;
  onRemoveValue:   (idx: number, value: string) => void;
  onRemove:        (idx: number) => void;
}) {
  const portletDef = PORTLET_CATALOGUE[rule.portlet];

  return (
    <div style={{ border: '1px solid #BFDBFE', borderRadius: 10, padding: '14px 16px', background: '#FAFCFF' }}>
      {/* Portlet → Field row */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
        <select
          value={rule.portlet}
          onChange={e => onPortletChange(index, e.target.value)}
          style={{ flex: '0 0 160px', padding: '7px 10px', fontSize: 13, borderRadius: 7, border: '1px solid #D1D5DB', background: '#fff', cursor: 'pointer' }}
        >
          {Object.entries(PORTLET_CATALOGUE).map(([k, v]) => (
            <option key={k} value={k}>{v.label}</option>
          ))}
        </select>

        <i className="fa-solid fa-chevron-right" style={{ fontSize: 11, color: '#9CA3AF', flexShrink: 0 }} />

        <select
          value={rule.field}
          onChange={e => onFieldChange(index, e.target.value)}
          style={{ flex: 1, padding: '7px 10px', fontSize: 13, borderRadius: 7, border: '1px solid #D1D5DB', background: '#fff', cursor: 'pointer' }}
        >
          {Object.entries(portletDef?.fields ?? {}).map(([k, v]) => (
            <option key={k} value={k}>{v.label}</option>
          ))}
        </select>

        <button
          onClick={() => onRemove(index)}
          title="Remove rule"
          style={{ width: 30, height: 30, borderRadius: 6, border: '1px solid #E5E7EB', background: 'transparent', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#9CA3AF', flexShrink: 0 }}
          onMouseOver={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = '#FCA5A5'; (e.currentTarget as HTMLButtonElement).style.color = '#DC2626'; }}
          onMouseOut={e  => { (e.currentTarget as HTMLButtonElement).style.borderColor = '#E5E7EB'; (e.currentTarget as HTMLButtonElement).style.color = '#9CA3AF'; }}
        >
          <i className="fa-solid fa-xmark" style={{ fontSize: 12 }} />
        </button>
      </div>

      {/* Value search */}
      <div>
        <div style={{ fontSize: 12, color: '#6B7280', marginBottom: 8 }}>
          Values
          {rule.values.length > 0 && (
            <span style={{ marginLeft: 6, fontWeight: 600, color: '#374151' }}>· {rule.values.length} selected</span>
          )}
        </div>
        <ValueSearchInput
          key={`${rule.portlet}-${rule.field}`}
          portlet={rule.portlet}
          field={rule.field}
          selected={rule.values}
          onAdd={v => onAddValue(index, v)}
          onRemove={value => onRemoveValue(index, value)}
        />
      </div>
    </div>
  );
}

// ─── Connector (AND / OR toggle between rules) ────────────────────────────────

function Connector({ operator, onChange }: { operator: 'AND' | 'OR'; onChange: (op: 'AND' | 'OR') => void }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '6px 0' }}>
      <div style={{ flex: 1, height: 1, background: '#E5E7EB' }} />
      <div style={{ display: 'flex', border: '1px solid #D1D5DB', borderRadius: 20, overflow: 'hidden', flexShrink: 0 }}>
        {(['AND', 'OR'] as const).map(op => (
          <button
            key={op}
            onClick={() => onChange(op)}
            style={{
              padding: '3px 13px', fontSize: 11, fontWeight: 600,
              border: 'none', cursor: 'pointer',
              background: operator === op ? '#1D4ED8' : 'transparent',
              color:      operator === op ? '#fff'    : '#6B7280',
            }}
          >
            {op}
          </button>
        ))}
      </div>
      <div style={{ flex: 1, height: 1, background: '#E5E7EB' }} />
    </div>
  );
}

// ─── Criteria builder panel ───────────────────────────────────────────────────

function CriteriaBuilder({
  group, onSaved, addToast, canEdit,
}: {
  group:    TargetGroup;
  onSaved:  () => void;
  addToast: (msg: string, type?: 'success' | 'error') => void;
  canEdit:  boolean;
}) {
  const initRules = (): FilterRules => {
    if (group.filter_rules && Array.isArray(group.filter_rules.rules))
      return { operator: group.filter_rules.operator ?? 'AND', rules: group.filter_rules.rules };
    return { operator: 'AND', rules: [] };
  };

  const [draft,        setDraft]        = useState<FilterRules>(initRules);
  const [previewCount, setPreviewCount] = useState<number | null>(group.memberCount || null);
  const [previewing,   setPreviewing]   = useState(false);
  const [saving,       setSaving]       = useState(false);
  const [dirty,        setDirty]        = useState(false);

  const update = (updater: (prev: FilterRules) => FilterRules) => {
    setDraft(updater);
    setDirty(true);
    setPreviewCount(null);
  };

  const handleAddRule = () => {
    update(prev => ({
      ...prev,
      rules: [...prev.rules, { portlet: 'employment', field: 'dept_id', values: [] }],
    }));
  };

  const handlePortletChange = (idx: number, portlet: string) => {
    const field = Object.keys(PORTLET_CATALOGUE[portlet]?.fields ?? {})[0] ?? '';
    update(prev => ({
      ...prev,
      rules: prev.rules.map((r, i) => i === idx ? { portlet, field, values: [] } : r),
    }));
  };

  const handleFieldChange = (idx: number, field: string) => {
    update(prev => ({
      ...prev,
      rules: prev.rules.map((r, i) => i === idx ? { ...r, field, values: [] } : r),
    }));
  };

  const handleAddValue = (idx: number, v: FilterRuleValue) => {
    update(prev => ({
      ...prev,
      rules: prev.rules.map((r, i) =>
        i === idx ? { ...r, values: [...r.values, v] } : r
      ),
    }));
  };

  const handleRemoveValue = (idx: number, value: string) => {
    update(prev => ({
      ...prev,
      rules: prev.rules.map((r, i) =>
        i === idx ? { ...r, values: r.values.filter(v => v.value !== value) } : r
      ),
    }));
  };

  const handleRemoveRule = (idx: number) => {
    update(prev => ({ ...prev, rules: prev.rules.filter((_, i) => i !== idx) }));
  };

  const handlePreview = async () => {
    setPreviewing(true);
    try {
      // Fields in employee_personal satellite table cannot be filtered directly
      // on the employees table — we must pre-fetch matching employee_ids first.
      const isSatellite = (rule: FilterRule) =>
        PORTLET_CATALOGUE[rule.portlet]?.fields[rule.field]?.sourceTable === 'employee_personal';

      const resolveSatellite = async (rule: FilterRule): Promise<string[]> => {
        const def = PORTLET_CATALOGUE[rule.portlet]?.fields[rule.field];
        if (!def || !rule.values.length) return [];
        const { data, error } = await supabase
          .from('employee_personal')
          .select('employee_id')
          .in(def.column, rule.values.map(v => v.value));
        if (error || !data) return [];
        return data.map((r: any) => r.employee_id as string);
      };

      let query = supabase
        .from('employees')
        .select('id', { count: 'exact', head: true })
        .eq('status', 'Active')
        .is('deleted_at', null);

      if (draft.operator === 'AND') {
        // AND: satellite rules → pre-fetch IDs then filter; employees rules → direct filter
        for (const rule of draft.rules) {
          if (!rule.values.length) continue;
          const def = PORTLET_CATALOGUE[rule.portlet]?.fields[rule.field];
          if (!def) continue;
          if (isSatellite(rule)) {
            const ids = await resolveSatellite(rule);
            // No matches from satellite → no employees can satisfy this AND rule
            query = query.in('id', ids.length ? ids : ['00000000-0000-0000-0000-000000000000']);
          } else {
            query = query.in(def.column, rule.values.map(v => v.value));
          }
        }
      } else {
        // OR: collect all satellite IDs, then union with employees-table OR conditions
        const satelliteIds: string[] = [];
        const employeeConditions: string[] = [];

        for (const rule of draft.rules) {
          if (!rule.values.length) continue;
          const def = PORTLET_CATALOGUE[rule.portlet]?.fields[rule.field];
          if (!def) continue;
          if (isSatellite(rule)) {
            const ids = await resolveSatellite(rule);
            satelliteIds.push(...ids);
          } else {
            const vals = rule.values.map(v => `"${v.value}"`).join(',');
            employeeConditions.push(`${def.column}.in.(${vals})`);
          }
        }

        const orParts = [...employeeConditions];
        if (satelliteIds.length) {
          const unique = [...new Set(satelliteIds)];
          orParts.push(`id.in.(${unique.map(id => `"${id}"`).join(',')})`);
        }
        if (orParts.length) query = query.or(orParts.join(','));
      }

      const { count, error } = await query;
      if (error) throw error;
      setPreviewCount(count ?? 0);
    } catch (e: unknown) {
      addToast(e instanceof Error ? e.message : 'Preview failed', 'error');
    } finally {
      setPreviewing(false);
    }
  };

  const handleSave = async () => {
    setSaving(true);
    try {
      const { error } = await supabase
        .from('target_groups')
        .update({ filter_rules: draft as unknown as Record<string, unknown> })
        .eq('id', group.id);
      if (error) throw error;

      // Trigger sync to rebuild target_group_members cache for this group
      await supabase.rpc('sync_target_group_members');

      addToast('Rules saved and cache refreshed');
      setDirty(false);
      onSaved();
    } catch (e: unknown) {
      addToast(e instanceof Error ? e.message : 'Save failed', 'error');
    } finally {
      setSaving(false);
    }
  };

  const hasValues = draft.rules.some(r => r.values.length > 0);

  return (
    <div>
      {/* Rules */}
      {draft.rules.length === 0 ? (
        <div style={{
          padding: '28px 20px', textAlign: 'center', color: '#9CA3AF',
          border: '1px dashed #93C5FD', borderRadius: 10, marginBottom: 10,
        }}>
          <i className="fa-solid fa-filter" style={{ fontSize: 24, marginBottom: 10, display: 'block', opacity: 0.35 }} />
          <div style={{ fontSize: 14, fontWeight: 600, color: '#374151', marginBottom: 4 }}>No rules defined</div>
          <div style={{ fontSize: 13 }}>Add a rule to define who belongs to this group.</div>
        </div>
      ) : (
        draft.rules.map((rule, i) => (
          <div key={i}>
            {i > 0 && (
              <Connector
                operator={draft.operator}
                onChange={op => update(prev => ({ ...prev, operator: op }))}
              />
            )}
            <RuleCard
              rule={rule}
              index={i}
              onPortletChange={handlePortletChange}
              onFieldChange={handleFieldChange}
              onAddValue={handleAddValue}
              onRemoveValue={handleRemoveValue}
              onRemove={handleRemoveRule}
            />
          </div>
        ))
      )}

      {/* Add rule button — edit only */}
      {canEdit && (
        <button
          onClick={handleAddRule}
          style={{
            width: '100%', marginTop: 10, padding: '9px 0',
            border: '1px dashed #93C5FD', borderRadius: 8,
            background: 'transparent', color: '#1D6ED8',
            fontSize: 13, cursor: 'pointer', display: 'flex',
            alignItems: 'center', justifyContent: 'center', gap: 6,
          }}
          onMouseOver={e => { (e.currentTarget as HTMLButtonElement).style.background = '#EFF6FF'; (e.currentTarget as HTMLButtonElement).style.color = '#1D4ED8'; }}
          onMouseOut={e  => { (e.currentTarget as HTMLButtonElement).style.background = 'transparent'; (e.currentTarget as HTMLButtonElement).style.color = '#1D6ED8'; }}
        >
          <i className="fa-solid fa-plus" style={{ fontSize: 12 }} /> Add Rule
        </button>
      )}

      {/* Preview bar */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 14, marginTop: 16,
        padding: '14px 16px', borderRadius: 10,
        background: '#EFF6FF', border: '1px solid #BFDBFE',
      }}>
        <div>
          <div style={{ fontSize: 26, fontWeight: 700, lineHeight: 1, color: '#1D4ED8' }}>
            {previewCount !== null ? previewCount : '—'}
          </div>
          <div style={{ fontSize: 12, color: '#6B7280', marginTop: 3 }}>
            {previewCount !== null
              ? `employee${previewCount !== 1 ? 's' : ''} match current rules`
              : 'run preview to see count'}
          </div>
        </div>
        <button
          onClick={handlePreview}
          disabled={previewing || !hasValues}
          style={{
            marginLeft: 'auto', padding: '8px 16px', borderRadius: 8,
            border: '1px solid #D1D5DB', background: '#fff',
            fontSize: 13, cursor: previewing || !hasValues ? 'not-allowed' : 'pointer',
            color: previewing || !hasValues ? '#9CA3AF' : '#374151',
            display: 'flex', alignItems: 'center', gap: 7,
          }}
        >
          <i className={`fa-solid fa-rotate${previewing ? ' fa-spin' : ''}`} style={{ fontSize: 13 }} />
          Preview count
        </button>
      </div>

      {/* Save / discard — edit only */}
      {canEdit && dirty && (
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 12 }}>
          <button
            onClick={() => { setDraft(initRules()); setDirty(false); setPreviewCount(group.memberCount || null); }}
            style={{ padding: '8px 16px', borderRadius: 8, border: '1px solid #D1D5DB', background: '#fff', color: '#374151', fontSize: 13, cursor: 'pointer' }}
          >
            Discard
          </button>
          <button
            onClick={handleSave}
            disabled={saving}
            style={{
              padding: '8px 18px', borderRadius: 8, border: 'none',
              background: saving ? '#9CA3AF' : '#1D4ED8',
              color: '#fff', fontSize: 13, cursor: saving ? 'not-allowed' : 'pointer',
              display: 'flex', alignItems: 'center', gap: 7,
            }}
          >
            {saving && <i className="fa-solid fa-circle-notch fa-spin" style={{ fontSize: 12 }} />}
            Save rules
          </button>
        </div>
      )}
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function TargetGroups() {
  const { can } = usePermissions();
  const canEdit = can('sec_target_groups.edit');

  const [groups,    setGroups]    = useState<TargetGroup[]>([]);
  const [selected,  setSelected]  = useState<TargetGroup | null>(null);
  const [loading,   setLoading]   = useState(true);
  const [pageError, setPageError] = useState<string | null>(null);

  // Edit label
  const [editingLabel, setEditingLabel] = useState(false);
  const [labelDraft,   setLabelDraft]   = useState('');
  const [savingLabel,  setSavingLabel]  = useState(false);

  // Modals
  const [showCreate, setShowCreate] = useState(false);
  const [savingNew,  setSavingNew]  = useState(false);
  const [showDelete, setShowDelete] = useState(false);
  const [deleting,   setDeleting]   = useState(false);

  const { toasts, add: addToast, dismiss: dismissToast } = useToasts();

  // ── Load (custom groups only) ──────────────────────────────────────────────

  const loadGroups = useCallback(async () => {
    setLoading(true);
    setPageError(null);
    try {
      const { data: tgData, error: tgErr } = await supabase
        .from('target_groups')
        .select('id, code, label, scope_type, filter_rules, is_system, created_at')
        .eq('scope_type', 'custom')          // ← only custom groups
        .eq('is_system', false)              // ← double-check no system rows slip through
        .order('created_at', { ascending: true });
      if (tgErr) throw tgErr;

      const { data: countData } = await supabase
        .from('target_group_members')
        .select('group_id');

      const memberCounts: Record<string, number> = {};
      for (const row of (countData ?? [])) {
        memberCounts[row.group_id] = (memberCounts[row.group_id] ?? 0) + 1;
      }

      const { data: psaData } = await supabase
        .from('permission_set_assignments')
        .select('target_group_id')
        .not('target_group_id', 'is', null);

      const usageCounts: Record<string, number> = {};
      for (const row of (psaData ?? [])) {
        if (row.target_group_id)
          usageCounts[row.target_group_id] = (usageCounts[row.target_group_id] ?? 0) + 1;
      }

      const enriched: TargetGroup[] = (tgData ?? []).map(g => ({
        ...g,
        scope_type:   'custom' as const,
        filter_rules: g.filter_rules as FilterRules | null,
        memberCount:  memberCounts[g.id] ?? 0,
        usageCount:   usageCounts[g.id]  ?? 0,
      }));

      setGroups(enriched);

      // Re-select if we had a group open
      if (selected) {
        const updated = enriched.find(g => g.id === selected.id);
        setSelected(updated ?? null);
      }
    } catch (e: unknown) {
      setPageError(e instanceof Error ? e.message : 'Failed to load target groups');
    } finally {
      setLoading(false);
    }
  }, [selected]);

  useEffect(() => { loadGroups(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Handlers ──────────────────────────────────────────────────────────────

  const handleCreate = async (label: string, code: string) => {
    setSavingNew(true);
    try {
      const { data, error } = await supabase
        .from('target_groups')
        .insert({ label, code, scope_type: 'custom', is_system: false })
        .select('id')
        .single();
      if (error) throw error;
      addToast(`Group "${label}" created`);
      setShowCreate(false);
      await loadGroups();
      // Auto-select the new group
      if (data?.id) {
        const fresh = (await supabase.from('target_groups').select('*').eq('id', data.id).single()).data;
        if (fresh) setSelected({ ...fresh, scope_type: 'custom', filter_rules: null, memberCount: 0, usageCount: 0 });
      }
    } catch (e: unknown) {
      addToast(e instanceof Error ? e.message : 'Failed to create group', 'error');
    } finally {
      setSavingNew(false);
    }
  };

  const handleSaveLabel = async () => {
    if (!selected || !labelDraft.trim()) return;
    setSavingLabel(true);
    try {
      const { error } = await supabase.from('target_groups').update({ label: labelDraft.trim() }).eq('id', selected.id);
      if (error) throw error;
      addToast('Label updated');
      setEditingLabel(false);
      await loadGroups();
    } catch (e: unknown) {
      addToast(e instanceof Error ? e.message : 'Failed to update label', 'error');
    } finally {
      setSavingLabel(false);
    }
  };

  const handleDelete = async () => {
    if (!selected) return;
    setDeleting(true);
    try {
      const { error } = await supabase.from('target_groups').delete().eq('id', selected.id);
      if (error) throw error;
      addToast(`"${selected.label}" deleted`);
      setShowDelete(false);
      setSelected(null);
      await loadGroups();
    } catch (e: unknown) {
      addToast(e instanceof Error ? e.message : 'Failed to delete group', 'error');
    } finally {
      setDeleting(false);
    }
  };

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <div style={{ display: 'flex', height: '100%', minHeight: 0, background: '#F9FAFB', fontFamily: 'inherit' }}>

      {/* Left panel */}
      <div style={{ width: 280, minWidth: 240, flexShrink: 0, borderRight: '1px solid #E5E7EB', background: '#fff', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
        <div style={{ padding: '18px 16px 12px', borderBottom: '1px solid #F3F4F6' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 2 }}>
            <h2 style={{ margin: 0, fontSize: 16, fontWeight: 700, color: '#111827' }}>Target Groups</h2>
            {canEdit && (
              <button
                onClick={() => setShowCreate(true)}
                style={{ display: 'flex', alignItems: 'center', gap: 5, padding: '6px 12px', borderRadius: 7, border: 'none', background: '#1D4ED8', color: '#fff', fontSize: 13, cursor: 'pointer', fontWeight: 600 }}
              >
                <i className="fa-solid fa-plus" style={{ fontSize: 11 }} /> New
              </button>
            )}
          </div>
          <p style={{ margin: '4px 0 0', fontSize: 12, color: '#9CA3AF' }}>
            {loading ? 'Loading…' : `${groups.length} custom group${groups.length !== 1 ? 's' : ''}`}
          </p>
        </div>

        <div style={{ flex: 1, overflowY: 'auto' }}>
          {loading ? (
            <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
              <i className="fa-solid fa-circle-notch fa-spin" style={{ marginRight: 6 }} /> Loading…
            </div>
          ) : groups.length === 0 ? (
            <div style={{ padding: '32px 16px', textAlign: 'center', color: '#9CA3AF' }}>
              <i className="fa-solid fa-people-group" style={{ fontSize: 28, display: 'block', marginBottom: 10, opacity: 0.3 }} />
              <div style={{ fontSize: 13, fontWeight: 600, color: '#374151', marginBottom: 4 }}>No custom groups</div>
              <div style={{ fontSize: 12 }}>Create one to define a rule-based group of employees.</div>
            </div>
          ) : (
            groups.map(g => (
              <button
                key={g.id}
                onClick={() => { setSelected(g); setEditingLabel(false); }}
                style={{
                  display: 'flex', width: '100%', textAlign: 'left',
                  padding: '10px 16px', border: 'none', cursor: 'pointer',
                  background: selected?.id === g.id ? '#EFF6FF' : 'transparent',
                  borderLeft: `3px solid ${selected?.id === g.id ? '#1D4ED8' : 'transparent'}`,
                  gap: 10, alignItems: 'flex-start',
                }}
              >
                <div style={{ width: 9, height: 9, borderRadius: '50%', background: '#3B82F6', flexShrink: 0, marginTop: 4 }} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13, fontWeight: 600, color: '#111827', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {g.label}
                  </div>
                  <div style={{ display: 'flex', gap: 8, marginTop: 3, fontSize: 11, color: '#9CA3AF' }}>
                    {g.memberCount > 0 && <span>{g.memberCount} members</span>}
                    {g.usageCount > 0 && <span style={{ color: '#6366F1', fontWeight: 600 }}>{g.usageCount} permission{g.usageCount !== 1 ? 's' : ''}</span>}
                    {g.memberCount === 0 && g.usageCount === 0 && <span>No rules yet</span>}
                  </div>
                </div>
              </button>
            ))
          )}
        </div>
      </div>

      {/* Right panel */}
      <div style={{ flex: 1, overflowY: 'auto', padding: 28 }}>
        {!canEdit && (
          <div style={{
            marginBottom: 16, padding: '7px 14px', background: '#FEF3C7',
            border: '0.5px solid #FDE68A', borderRadius: 8,
            display: 'flex', alignItems: 'center', gap: 8,
          }}>
            <i className="fa-solid fa-eye" style={{ fontSize: 12, color: '#92400E' }} />
            <span style={{ fontSize: 13, color: '#92400E', fontWeight: 500 }}>
              View only — you don't have edit access to Target Groups
            </span>
          </div>
        )}
        {pageError && <ErrorBanner message={pageError} onDismiss={() => setPageError(null)} />}

        {!selected ? (
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '60%', minHeight: 200 }}>
            <div style={{ textAlign: 'center', maxWidth: 320 }}>
              <i className="fa-solid fa-people-group" style={{ fontSize: 38, color: '#D1D5DB', marginBottom: 14, display: 'block' }} />
              <h3 style={{ margin: '0 0 8px', fontSize: 15, fontWeight: 600, color: '#374151' }}>Select a group</h3>
              <p style={{ margin: 0, fontSize: 13, color: '#9CA3AF', lineHeight: 1.6 }}>
                Choose a custom group from the left to configure its membership criteria.
              </p>
            </div>
          </div>
        ) : (
          <div style={{ maxWidth: 780 }}>
            {/* Header */}
            <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 20 }}>
              <div style={{ flex: 1 }}>
                {editingLabel && canEdit ? (
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <input
                      value={labelDraft}
                      onChange={e => setLabelDraft(e.target.value)}
                      autoFocus
                      onKeyDown={e => { if (e.key === 'Enter') handleSaveLabel(); if (e.key === 'Escape') setEditingLabel(false); }}
                      style={{ fontSize: 20, fontWeight: 700, color: '#111827', border: '1px solid #D1D5DB', borderRadius: 6, padding: '4px 10px', outline: 'none' }}
                    />
                    <button onClick={handleSaveLabel} disabled={savingLabel || !labelDraft.trim()}
                      style={{ padding: '6px 14px', borderRadius: 6, border: 'none', background: '#1D4ED8', color: '#fff', fontSize: 13, cursor: 'pointer' }}>
                      {savingLabel ? <i className="fa-solid fa-circle-notch fa-spin" /> : 'Save'}
                    </button>
                    <button onClick={() => setEditingLabel(false)}
                      style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', color: '#374151', fontSize: 13, cursor: 'pointer' }}>
                      Cancel
                    </button>
                  </div>
                ) : (
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <h2 style={{ margin: 0, fontSize: 20, fontWeight: 700, color: '#111827' }}>{selected.label}</h2>
                    {canEdit && (
                      <button onClick={() => { setLabelDraft(selected.label); setEditingLabel(true); }}
                        style={{ padding: '3px 8px', borderRadius: 5, border: '1px solid #E5E7EB', background: '#fff', color: '#6B7280', fontSize: 12, cursor: 'pointer' }}>
                        <i className="fa-solid fa-pen" />
                      </button>
                    )}
                  </div>
                )}
                <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 6 }}>
                  <span style={{ fontSize: 11, padding: '2px 8px', borderRadius: 10, background: '#DBEAFE', color: '#1E40AF', fontWeight: 600 }}>Custom</span>
                  <span style={{ fontSize: 12, color: '#9CA3AF', fontFamily: 'monospace' }}>{selected.code}</span>
                  {selected.usageCount > 0 && (
                    <span style={{ fontSize: 12, color: '#6366F1', fontWeight: 600 }}>
                      Used by {selected.usageCount} permission{selected.usageCount !== 1 ? 's' : ''}
                    </span>
                  )}
                </div>
              </div>
              {canEdit && (
                <button
                  onClick={() => setShowDelete(true)}
                  disabled={selected.usageCount > 0}
                  title={selected.usageCount > 0 ? `Cannot delete — used by ${selected.usageCount} permission(s)` : 'Delete group'}
                  style={{
                    padding: '8px 14px', borderRadius: 7,
                    border: `1px solid ${selected.usageCount > 0 ? '#E5E7EB' : '#FCA5A5'}`,
                    background: selected.usageCount > 0 ? '#F9FAFB' : '#FFF1F2',
                    color: selected.usageCount > 0 ? '#D1D5DB' : '#DC2626',
                    fontSize: 13, cursor: selected.usageCount > 0 ? 'not-allowed' : 'pointer',
                    display: 'flex', alignItems: 'center', gap: 6,
                  }}
                >
                  <i className="fa-solid fa-trash" /> Delete
                </button>
              )}
            </div>

            {/* Divider */}
            <div style={{ height: 1, background: '#F3F4F6', marginBottom: 20 }} />

            {/* Section heading */}
            <div style={{ marginBottom: 14 }}>
              <h3 style={{ margin: '0 0 4px', fontSize: 14, fontWeight: 700, color: '#111827' }}>Member Criteria</h3>
              <p style={{ margin: 0, fontSize: 13, color: '#6B7280' }}>
                Employees matching all rules below will be added to this group. Rules are re-evaluated every 15 minutes by the scheduled job.
              </p>
            </div>

            <CriteriaBuilder
              key={selected.id}
              group={selected}
              onSaved={loadGroups}
              addToast={addToast}
              canEdit={canEdit}
            />
          </div>
        )}
      </div>

      {/* Modals */}
      {showCreate && <CreateGroupModal onSave={handleCreate} onCancel={() => setShowCreate(false)} saving={savingNew} />}
      {showDelete && selected && <DeleteConfirmModal group={selected} onConfirm={handleDelete} onCancel={() => setShowDelete(false)} deleting={deleting} />}

      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    </div>
  );
}
