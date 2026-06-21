/**
 * JobRelationshipsPortlet — Set-Snapshot Edition
 *
 * Implements view / draft / history UX for matrix-manager assignments.
 * Six fixed codes (PM01–PM03, OM01–OM03); labels fetched from the
 * JOB_RELATIONSHIP_TYPE picklist so admins can relabel them.
 *
 * Used in:
 *   • MyProfile/index.tsx      — ESS self-service (read-only, pending pill)
 *   • EmployeeEditPanel.tsx    — HR direct-edit
 *
 * RPCs consumed (mig 359–360):
 *   get_current_job_relationships(p_employee_id)
 *     → { ok, set: {...}|null, items: [...] }
 *   upsert_job_relationship_set(p_employee_id, p_effective_from, p_items)
 *     → { ok, workflow, set_id?, instance_id?, effective_from? }
 *   get_job_relationships_history(p_employee_id)
 *     → { ok, sets: [...] }
 *
 * Locked decisions (docs/job-relationships-design.md):
 *   - 6 fixed codes — order: PM01, PM02, PM03, OM01, OM02, OM03
 *   - Manager must be Active at assignment time (validated server-side)
 *   - No self-assignment (server CHECK constraint + client guard)
 *   - No effective-from snap — any date, default today
 *   - ESS: read-only; edits gated to HR/admin via job_relationships.edit
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import { usePicklistValues } from '../../hooks/usePicklistValues';

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const JR_CODE_ORDER = ['PM01', 'PM02', 'PM03', 'OM01', 'OM02', 'OM03'] as const;
type JRCode = typeof JR_CODE_ORDER[number];

function todayISO() {
  return new Date().toISOString().slice(0, 10);
}

function fmtDate(iso: string) {
  if (!iso || iso === '9999-12-31') return '—';
  return new Date(iso + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

interface JRSet {
  id:             string;
  employee_id:    string;
  effective_from: string;
  effective_to:   string;
  is_active:      boolean;
  created_at:     string;
}

interface JRItem {
  id:                    string;
  relationship_code:     JRCode;
  manager_employee_id:   string;
  manager_name:          string;
  manager_employee_code: string;
}

// Draft: one slot per code (null = unassigned)
type DraftSlots = Record<JRCode, string | null>; // code → manager employee UUID | null

interface JRPortletProps {
  employeeId:       string;
  employeeName?:    string;
  readOnly?:        boolean;
  canCreate?:       boolean;
  canEdit?:         boolean;
  canDelete?:       boolean;
  pendingCount?:    number;
  onChanged?:       () => void;
  saveAllRef?:      React.MutableRefObject<(() => Promise<boolean>) | undefined>;
  editMode?:        boolean;
  /** When provided, history display is controlled by the parent (MyProfile header). */
  historyOpen?:     boolean;
  /** When true, suppress the internal History+Edit toolbar (parent renders it). */
  hideToolbar?:     boolean;
  /** Ref wired to the enterDraft function — lets parent trigger edit mode. */
  enterDraftRef?:   React.MutableRefObject<(() => void) | undefined>;
}

// ─────────────────────────────────────────────────────────────────────────────
// HistoryPanel — lazy-loaded on first open
// ─────────────────────────────────────────────────────────────────────────────

interface HistorySet {
  id:             string;
  effective_from: string;
  effective_to:   string;
  is_active:      boolean;
  items: {
    relationship_code:     string;
    manager_name:          string;
    manager_employee_code: string;
  }[];
}

function HistoryPanel({
  employeeId,
  codeLabels,
}: {
  employeeId: string;
  codeLabels: Record<string, string>;
}) {
  const [sets,    setSets]    = useState<HistorySet[]>([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [selIdx,  setSelIdx]  = useState(0);

  useEffect(() => {
    (async () => {
      const { data, error: err } = await supabase.rpc(
        'get_job_relationships_history',
        { p_employee_id: employeeId }
      );
      if (err) { setError(err.message); setLoading(false); return; }
      const payload = data as { ok: boolean; sets: HistorySet[] } | null;
      setSets(payload?.sets ?? []);
      setLoading(false);
    })();
  }, [employeeId]);

  return (
    <div style={{ border: '1px solid #E0E7FF', borderRadius: 10, overflow: 'hidden', marginTop: 12 }}>
      {/* Header */}
      <div style={{ background: '#EEF2FF', padding: '10px 16px', display: 'flex', alignItems: 'center', gap: 8, borderBottom: '1px solid #E0E7FF' }}>
        <i className="fa-solid fa-clock-rotate-left" style={{ color: '#4F46E5', fontSize: 13 }} />
        <span style={{ fontWeight: 600, fontSize: 13, color: '#3730A3' }}>Assignment History</span>
        {!loading && !error && (
          <span style={{ marginLeft: 'auto', fontSize: 12, color: '#6B7280' }}>
            {sets.length} record{sets.length !== 1 ? 's' : ''}
          </span>
        )}
      </div>

      {loading ? (
        <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading history…
        </div>
      ) : error ? (
        <div style={{ padding: 20, textAlign: 'center', color: '#DC2626', fontSize: 13 }}>{error}</div>
      ) : sets.length === 0 ? (
        <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>No history available.</div>
      ) : (
        <div style={{ display: 'flex', minHeight: 160 }}>
          {/* Date sidebar */}
          <div style={{ width: 150, borderRight: '1px solid #E0E7FF', overflowY: 'auto', flexShrink: 0 }}>
            {sets.map((s, i) => {
              const isCurrent = s.effective_to === '9999-12-31' && s.is_active;
              return (
                <button
                  key={s.id}
                  onClick={() => setSelIdx(i)}
                  style={{
                    width: '100%', textAlign: 'left', padding: '10px 12px',
                    background: selIdx === i ? '#EEF2FF' : 'none',
                    border: 'none', borderBottom: '1px solid #F3F4F6',
                    cursor: 'pointer', fontSize: 12,
                    color: selIdx === i ? '#4F46E5' : '#374151',
                  }}
                >
                  <div style={{ fontWeight: 600 }}>{fmtDate(s.effective_from)}</div>
                  <div style={{ color: '#9CA3AF', fontSize: 11, marginTop: 2 }}>
                    {isCurrent ? 'Current' : `→ ${fmtDate(s.effective_to)}`}
                  </div>
                </button>
              );
            })}
          </div>

          {/* Detail */}
          {(() => {
            const s = sets[selIdx];
            if (!s) return null;
            const isCurrent = s.effective_to === '9999-12-31' && s.is_active;
            return (
              <div style={{ flex: 1, padding: '14px 16px' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
                  <span style={{ fontSize: 12, fontWeight: 600, color: '#6B7280' }}>
                    {fmtDate(s.effective_from)} — {isCurrent ? 'Present' : fmtDate(s.effective_to)}
                  </span>
                  {isCurrent && (
                    <span style={{ fontSize: 11, fontWeight: 600, background: '#D1FAE5', color: '#065F46', borderRadius: 4, padding: '2px 7px' }}>
                      Current
                    </span>
                  )}
                </div>

                {s.items && s.items.length > 0 ? (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                    {JR_CODE_ORDER
                      .filter(c => s.items.some(i => i.relationship_code === c))
                      .map(code => {
                        const item = s.items.find(i => i.relationship_code === code);
                        if (!item) return null;
                        return (
                          <div key={code} style={{ display: 'flex', gap: 8, fontSize: 13 }}>
                            <span style={{ minWidth: 130, color: '#6B7280', fontWeight: 500 }}>
                              {codeLabels[code] ?? code}
                              <span style={{ marginLeft: 5, fontSize: 10, color: '#9CA3AF' }}>{code}</span>
                            </span>
                            <span style={{ color: '#111827' }}>
                              {item.manager_name}
                              <span style={{ color: '#9CA3AF', marginLeft: 4 }}>({item.manager_employee_code})</span>
                            </span>
                          </div>
                        );
                      })}
                  </div>
                ) : (
                  <p style={{ fontSize: 12.5, color: '#9CA3AF', fontStyle: 'italic', margin: 0 }}>
                    No assignments in this period.
                  </p>
                )}
              </div>
            );
          })()}
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// EmployeePicker — typeahead for a single matrix-manager slot
// ─────────────────────────────────────────────────────────────────────────────

interface PickerEmployee {
  id:          string;
  name:        string;
  employee_id: string;  // human-readable code e.g. EMP-001
  job_title:   string | null;
}

function EmployeePicker({
  value,        // currently assigned employee UUID | null
  excludeId,    // self — never suggested
  onChange,
  disabled = false,
}: {
  value:      string | null;
  excludeId:  string;
  onChange:   (empId: string | null) => void;
  disabled?:  boolean;
}) {
  const [query,    setQuery]    = useState('');
  const [results,  setResults]  = useState<PickerEmployee[]>([]);
  const [loading,  setLoading]  = useState(false);
  const [selected, setSelected] = useState<PickerEmployee | null>(null);
  const [open,     setOpen]     = useState(false);
  const timerRef  = useRef<number | null>(null);
  const wrapRef   = useRef<HTMLDivElement>(null);

  // Load the current assignee's name on mount / when value changes externally
  useEffect(() => {
    if (!value) { setSelected(null); setQuery(''); return; }
    // If already selected and id matches, no fetch needed
    if (selected?.id === value) return;
    supabase
      .from('employees')
      .select('id, name, employee_id, job_title')
      .eq('id', value)
      .single()
      .then(({ data }) => {
        if (data) {
          const emp = data as PickerEmployee;
          setSelected(emp);
          setQuery(emp.name);
        }
      });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  // Close dropdown on outside click
  useEffect(() => {
    function handler(e: MouseEvent) {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        setOpen(false);
        // If user typed but didn't select, revert query to current selection
        if (selected) setQuery(selected.name);
        else setQuery('');
      }
    }
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [selected]);

  function search(q: string) {
    setQuery(q);
    setOpen(true);
    if (timerRef.current) clearTimeout(timerRef.current);
    if (!q.trim()) { setResults([]); return; }
    timerRef.current = window.setTimeout(async () => {
      setLoading(true);
      const { data } = await supabase
        .from('employees')
        .select('id, name, employee_id, job_title')
        .eq('status', 'Active')
        .neq('id', excludeId)
        .or(`name.ilike.%${q}%,employee_id.ilike.%${q}%`)
        .order('name')
        .limit(8);
      setLoading(false);
      setResults((data ?? []) as PickerEmployee[]);
    }, 250);
  }

  function select(emp: PickerEmployee) {
    setSelected(emp);
    setQuery(emp.name);
    setResults([]);
    setOpen(false);
    onChange(emp.id);
  }

  function clear() {
    setSelected(null);
    setQuery('');
    setResults([]);
    onChange(null);
  }

  return (
    <div ref={wrapRef} style={{ position: 'relative', flex: 1 }}>
      {selected ? (
        // Selected chip
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '6px 10px', border: '1px solid #6366F1',
          borderRadius: 6, background: '#EEF2FF',
        }}>
          <div style={{
            width: 26, height: 26, borderRadius: '50%',
            background: '#4F46E5', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 11, fontWeight: 700, flexShrink: 0,
          }}>
            {selected.name.charAt(0).toUpperCase()}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: '#1E1B4B', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {selected.name}
            </div>
            <div style={{ fontSize: 11, color: '#6366F1' }}>
              {selected.employee_id}{selected.job_title ? ` · ${selected.job_title}` : ''}
            </div>
          </div>
          {!disabled && (
            <button
              onClick={clear}
              title="Clear"
              style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 14, lineHeight: 1, padding: '0 2px', flexShrink: 0 }}
            >
              <i className="fa-solid fa-xmark" />
            </button>
          )}
        </div>
      ) : (
        // Search input
        <div style={{ position: 'relative' }}>
          <i className="fa-solid fa-magnifying-glass" style={{
            position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
            color: '#9CA3AF', fontSize: 12, pointerEvents: 'none',
          }} />
          <input
            value={query}
            onChange={e => search(e.target.value)}
            onFocus={() => { if (query) setOpen(true); }}
            placeholder="Type name or employee ID…"
            disabled={disabled}
            autoComplete="off"
            style={{
              width: '100%', boxSizing: 'border-box',
              padding: '7px 10px 7px 30px', fontSize: 13,
              border: '1px solid #D1D5DB', borderRadius: 6,
              background: disabled ? '#F9FAFB' : '#fff',
              color: '#111827',
            }}
          />
          {loading && (
            <i className="fa-solid fa-spinner fa-spin" style={{
              position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)',
              color: '#9CA3AF', fontSize: 12,
            }} />
          )}
        </div>
      )}

      {/* Dropdown results */}
      {open && !selected && (
        <div style={{
          position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 100,
          background: '#fff', border: '1px solid #E5E7EB',
          borderRadius: 6, boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
          marginTop: 3, maxHeight: 220, overflowY: 'auto',
        }}>
          {results.length > 0 ? results.map(emp => (
            <button
              key={emp.id}
              onMouseDown={() => select(emp)}
              style={{
                width: '100%', display: 'flex', alignItems: 'center', gap: 10,
                padding: '8px 12px', border: 'none', background: 'none',
                cursor: 'pointer', textAlign: 'left',
                borderBottom: '1px solid #F3F4F6',
              }}
              onMouseEnter={e => (e.currentTarget.style.background = '#EEF2FF')}
              onMouseLeave={e => (e.currentTarget.style.background = 'none')}
            >
              <div style={{
                width: 26, height: 26, borderRadius: '50%',
                background: '#1D4ED8', color: '#fff',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 11, fontWeight: 700, flexShrink: 0,
              }}>
                {emp.name.charAt(0).toUpperCase()}
              </div>
              <div>
                <div style={{ fontSize: 13, fontWeight: 600, color: '#111827' }}>{emp.name}</div>
                <div style={{ fontSize: 11, color: '#6B7280' }}>
                  {emp.employee_id}{emp.job_title ? ` · ${emp.job_title}` : ''}
                </div>
              </div>
            </button>
          )) : query.length > 1 && !loading ? (
            <div style={{ padding: '10px 14px', fontSize: 12, color: '#9CA3AF' }}>
              No active employees found matching "{query}"
            </div>
          ) : null}
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Portlet
// ─────────────────────────────────────────────────────────────────────────────

export default function JobRelationshipsPortlet({
  employeeId,
  readOnly = false,
  canCreate = true,
  canEdit = true,
  canDelete = true,
  pendingCount = 0,
  onChanged,
  saveAllRef,
  editMode = false,
  historyOpen,
  hideToolbar = false,
  enterDraftRef,
}: JRPortletProps) {
  const { picklistValues } = usePicklistValues();

  // Code → label map from picklist (admin-editable labels)
  const codeLabels: Record<string, string> = Object.fromEntries(
    picklistValues
      .filter(p => p.picklistId === 'JOB_RELATIONSHIP_TYPE' && p.active !== false)
      .map(p => [p.refId ?? p.value, p.value])
  );

  // ── Server state ──────────────────────────────────────────────────────────
  const [currentSet,   setCurrentSet]   = useState<JRSet | null>(null);
  const [currentItems, setCurrentItems] = useState<JRItem[]>([]);
  const [loading,      setLoading]      = useState(true);
  const [loadErr,      setLoadErr]      = useState('');

  // ── UI state ──────────────────────────────────────────────────────────────
  const [mode,               setMode]              = useState<'view' | 'draft'>('view');
  const [draftSlots,         setDraftSlots]        = useState<DraftSlots>({} as DraftSlots);
  const [draftEffectiveFrom, setDraftEffectiveFrom] = useState(todayISO());
  const [submitting,         setSubmitting]        = useState(false);
  const [submitError,        setSubmitError]       = useState('');
  const [showHistory,        setShowHistory]       = useState(false);
  const historyLoadedRef = useRef(false);

  // ── Load active set ───────────────────────────────────────────────────────
  const loadCurrentSet = useCallback(async () => {
    if (!employeeId) return;
    setLoading(true); setLoadErr('');
    const { data, error } = await supabase.rpc('get_current_job_relationships', {
      p_employee_id: employeeId,
    });
    if (error) { setLoadErr(error.message); setLoading(false); return; }
    const payload = data as { ok: boolean; set: JRSet | null; items: JRItem[] } | null;
    setCurrentSet(payload?.set ?? null);
    setCurrentItems(payload?.items ?? []);
    setLoading(false);
  }, [employeeId]);

  useEffect(() => { loadCurrentSet(); }, [loadCurrentSet]);

  // ── Auto-enter draft for editMode ─────────────────────────────────────────
  const autoEnteredRef = useRef(false);
  useEffect(() => {
    if (autoEnteredRef.current || loading) return;
    if (editMode) {
      autoEnteredRef.current = true;
      enterDraft();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loading, editMode]);

  // ── Wire saveAllRef + enterDraftRef ──────────────────────────────────────
  useEffect(() => {
    if (saveAllRef)    saveAllRef.current    = handleSubmit;
    if (enterDraftRef) enterDraftRef.current = enterDraft;
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draftSlots, draftEffectiveFrom, mode, loading]);

  // ── Draft management ──────────────────────────────────────────────────────
  function enterDraft() {
    const slots = Object.fromEntries(
      JR_CODE_ORDER.map(code => {
        const item = currentItems.find(i => i.relationship_code === code);
        return [code, item?.manager_employee_id ?? null];
      })
    ) as DraftSlots;
    setDraftSlots(slots);
    setDraftEffectiveFrom(todayISO());
    setSubmitError('');
    setMode('draft');
  }

  function discardDraft() {
    setDraftSlots({} as DraftSlots);
    setSubmitError('');
    setMode('view');
    autoEnteredRef.current = false;
  }

  // ── Submit ────────────────────────────────────────────────────────────────
  async function handleSubmit(): Promise<boolean> {
    // Detect changes vs current set
    const hasChanges = JR_CODE_ORDER.some(code => {
      const current = currentItems.find(i => i.relationship_code === code)?.manager_employee_id ?? null;
      return (draftSlots[code] ?? null) !== current;
    });
    if (!hasChanges) return true;

    // Validate: no self-assignment (belt-and-suspenders, server also checks)
    for (const code of JR_CODE_ORDER) {
      if (draftSlots[code] === employeeId) {
        setSubmitError(`Cannot assign an employee as their own ${codeLabels[code] ?? code}.`);
        return false;
      }
    }

    setSubmitting(true);
    setSubmitError('');

    // Build p_items — only include assigned codes
    const items = JR_CODE_ORDER
      .filter(code => draftSlots[code])
      .map(code => ({
        relationship_code:   code,
        manager_employee_id: draftSlots[code]!,
      }));

    try {
      const { data, error: rpcErr } = await supabase.rpc('upsert_job_relationship_set', {
        p_employee_id:    employeeId,
        p_effective_from: draftEffectiveFrom,
        p_items:          items,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      const result = data as { ok: boolean; workflow?: boolean; error?: string; message?: string } | null;
      if (!result?.ok) throw new Error(result?.message ?? result?.error ?? 'Submit failed.');

      if (result.workflow) {
        // Workflow pending — stay in view, pending pill will appear on next load
      } else {
        onChanged?.();
      }
      setMode('view');
      await loadCurrentSet();
      return true;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'An unexpected error occurred.';
      setSubmitError(msg);
      return false;
    } finally {
      setSubmitting(false);
    }
  }

  // ── Render helpers ────────────────────────────────────────────────────────

  function renderViewRow(code: JRCode) {
    const item = currentItems.find(i => i.relationship_code === code);
    return (
      <tr key={code} style={{ borderTop: '1px solid #F3F4F6' }}>
        <td style={{ padding: '8px 12px', fontSize: 13, fontWeight: 500, color: '#374151', width: '40%' }}>
          {codeLabels[code] ?? code}
          <span style={{ marginLeft: 6, fontSize: 11, color: '#9CA3AF', fontWeight: 400 }}>{code}</span>
        </td>
        <td style={{ padding: '8px 12px', fontSize: 13, color: item ? '#111827' : '#9CA3AF' }}>
          {item
            ? <>{item.manager_name} <span style={{ color: '#9CA3AF' }}>({item.manager_employee_code})</span></>
            : <span style={{ fontStyle: 'italic' }}>—</span>
          }
        </td>
      </tr>
    );
  }

  function renderDraftRow(code: JRCode) {
    const assigned    = draftSlots[code] ?? null;
    const wasAssigned = !!currentItems.find(i => i.relationship_code === code);
    // Unassigned slot → canCreate; already assigned → canEdit to change
    const canChange   = assigned ? canEdit : canCreate;
    // canDelete only for previously-saved (not new) assignments
    const showClear   = assigned && wasAssigned && canDelete;

    return (
      <tr key={code} style={{ borderTop: '1px solid #F3F4F6' }}>
        <td style={{ padding: '10px 12px', fontSize: 13, fontWeight: 500, color: '#374151', width: '38%', verticalAlign: 'top', paddingTop: 14 }}>
          {codeLabels[code] ?? code}
          <span style={{ marginLeft: 6, fontSize: 11, color: '#9CA3AF', fontWeight: 400 }}>{code}</span>
        </td>
        <td style={{ padding: '8px 12px', verticalAlign: 'top' }}>
          <EmployeePicker
            value={assigned}
            excludeId={employeeId}
            disabled={!canChange}
            onChange={(empId) => setDraftSlots(prev => ({ ...prev, [code]: empId }))}
          />
          {showClear && (
            <button
              onClick={() => setDraftSlots(prev => ({ ...prev, [code]: null }))}
              style={{
                marginTop: 5, background: 'none', border: 'none',
                cursor: 'pointer', fontSize: 11.5, color: '#DC2626',
                display: 'flex', alignItems: 'center', gap: 4, padding: 0,
              }}
            >
              <i className="fa-solid fa-trash-can" style={{ fontSize: 10 }} />
              Remove assignment
            </button>
          )}
        </td>
      </tr>
    );
  }

  // ── Main render ───────────────────────────────────────────────────────────
  if (loading) {
    return (
      <div style={{ padding: '24px 20px', color: '#6B7280', fontSize: 13 }}>
        <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
        Loading job relationships…
      </div>
    );
  }

  if (loadErr) {
    return (
      <div style={{ padding: '16px 20px', color: '#DC2626', fontSize: 13 }}>
        <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
        {loadErr}
      </div>
    );
  }

  const hasAnyAssignment = currentItems.length > 0;
  // History display: externally controlled (hideToolbar=true) or internal toggle
  const historyVisible = historyOpen ?? showHistory;

  return (
    <div className="jr-portlet">
      {/* ── Pending pill ──────────────────────────────────────────────────── */}
      {pendingCount > 0 && mode === 'view' && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '8px 16px', background: '#FFFBEB', borderBottom: '1px solid #FEF3C7',
          fontSize: 12.5, color: '#92400E',
        }}>
          <i className="fa-solid fa-clock" style={{ color: '#D97706' }} />
          <span>A change request is currently under workflow review. Editing is paused.</span>
        </div>
      )}

      {/* ── View mode ─────────────────────────────────────────────────────── */}
      {mode === 'view' && (
        <>
          {/* Internal toolbar — hidden when parent (MyProfile) controls via hideToolbar */}
          {!hideToolbar && (
            <div style={{ padding: '12px 16px', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ fontSize: 12.5, color: '#6B7280' }}>
                {historyVisible
                  ? 'Assignment History'
                  : hasAnyAssignment
                    ? `${currentItems.length} of 6 roles assigned · Effective ${fmtDate(currentSet?.effective_from ?? '')}`
                    : <span style={{ fontStyle: 'italic' }}>No matrix manager assignments</span>
                }
              </span>
              <div style={{ display: 'flex', gap: 8 }}>
                <button className="emp-btn-ghost"
                  onClick={() => { setShowHistory(h => !h); historyLoadedRef.current = true; }}>
                  <i className={`fa-solid ${historyVisible ? 'fa-eye-slash' : 'fa-clock-rotate-left'}`} style={{ marginRight: 6 }} />
                  {historyVisible ? 'Hide History' : 'History'}
                </button>
                {!historyVisible && (canCreate || canEdit) && !readOnly && pendingCount === 0 && (
                  <button className="emp-btn-ghost" onClick={enterDraft}>
                    <i className="fa-solid fa-pen-to-square" style={{ marginRight: 6 }} /> Edit
                  </button>
                )}
              </div>
            </div>
          )}

          {/* History replaces the table in-place */}
          {historyVisible ? (
            <div style={{ padding: '0 16px 16px' }}>
              <HistoryPanel employeeId={employeeId} codeLabels={codeLabels} />
            </div>
          ) : (
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
              <thead>
                <tr style={{ background: '#F9FAFB' }}>
                  <th style={{ padding: '8px 12px', textAlign: 'left', fontSize: 12, fontWeight: 600, color: '#6B7280', width: '40%' }}>Role</th>
                  <th style={{ padding: '8px 12px', textAlign: 'left', fontSize: 12, fontWeight: 600, color: '#6B7280' }}>Assigned Manager</th>
                </tr>
              </thead>
              <tbody>
                {JR_CODE_ORDER.map(code => renderViewRow(code))}
              </tbody>
            </table>
          )}
        </>
      )}

      {/* ── Draft mode ────────────────────────────────────────────────────── */}
      {mode === 'draft' && (
        <>
          {/* Effective date row */}
          <div style={{ padding: '12px 16px', display: 'flex', alignItems: 'center', gap: 12, borderBottom: '1px solid #F3F4F6' }}>
            <label style={{ fontSize: 13, fontWeight: 500, color: '#374151', minWidth: 120 }}>
              Effective Date
            </label>
            <input
              type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
              value={draftEffectiveFrom}
              onChange={e => setDraftEffectiveFrom(e.target.value)}
              style={{
                padding: '5px 10px', fontSize: 13, borderRadius: 6,
                border: '1px solid #D1D5DB', color: '#111827',
              }}
            />
            <span style={{ fontSize: 12, color: '#9CA3AF' }}>
              Assignments take effect from this date. Future dates defer mirror sync to nightly job.
            </span>
          </div>

          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
            <thead>
              <tr style={{ background: '#F9FAFB' }}>
                <th style={{ padding: '8px 12px', textAlign: 'left', fontSize: 12, fontWeight: 600, color: '#6B7280', width: '40%' }}>Role</th>
                <th style={{ padding: '8px 12px', textAlign: 'left', fontSize: 12, fontWeight: 600, color: '#6B7280' }}>Assign Manager</th>
              </tr>
            </thead>
            <tbody>
              {JR_CODE_ORDER.map(code => renderDraftRow(code))}
            </tbody>
          </table>

          {submitError && (
            <div style={{
              margin: '10px 16px 0',
              padding: '8px 12px', background: '#FEE2E2', borderRadius: 6,
              fontSize: 12.5, color: '#B91C1C',
              display: 'flex', alignItems: 'center', gap: 6,
            }}>
              <i className="fa-solid fa-circle-exclamation" />
              {submitError}
            </div>
          )}

          {/* Footer — shown only when NOT using saveAllRef (standalone mode) */}
          {!saveAllRef && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, padding: '12px 16px', borderTop: '1px solid #F3F4F6', marginTop: 8 }}>
              <button className="emp-btn-ghost" onClick={discardDraft} disabled={submitting}>
                <i className="fa-solid fa-xmark" style={{ marginRight: 6 }} /> Discard
              </button>
              <button className="emp-btn-primary" onClick={() => handleSubmit()} disabled={submitting}>
                {submitting
                  ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                  : <><i className="fa-solid fa-check" /> Save Changes</>
                }
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
