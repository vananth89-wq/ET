/**
 * TerminationImpactModal
 *
 * Shown before submitting a termination for an employee who has direct reports
 * or JR matrix assignments. Calls get_termination_deactivation_impact() (mig 489).
 *
 * Allows HR to optionally search and select a new manager for each direct report.
 * Reassignments are passed back via onConfirm() and stored on the termination record.
 * New slices are applied by fn_finalize_termination_execution() at lwd+1.
 */

import { useState, useEffect, useRef } from 'react';
import { supabase } from '../../lib/supabase';

interface DirectReport {
  employee_id:   string;
  employee_code: string;
  name:          string;
}

interface JRAssignment {
  employee_id:   string;
  employee_code: string;
  name:          string;
  codes_held:    string[];
}

export interface ManagerReassignment {
  employee_id:    string;
  new_manager_id: string;
}

interface TerminationImpactModalProps {
  employeeId:   string;
  employeeName: string;
  onConfirm:    (reassignments: ManagerReassignment[]) => void;
  onCancel:     () => void;
}

interface EmployeeOption {
  id:   string;
  name: string;
  code: string;
}

const JR_CODE_LABELS: Record<string, string> = {
  PM01: 'Project Manager', PM02: 'Programme Manager', PM03: 'Practice Manager',
  OM01: 'Operations Manager', OM02: 'Operations Lead', OM03: 'Operations Coordinator',
};

const s = {
  overlay:  { position: 'fixed' as const, inset: 0, background: 'rgba(0,0,0,0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 2000 },
  modal:    { background: '#fff', borderRadius: 12, width: 600, maxHeight: '85vh', display: 'flex', flexDirection: 'column' as const, boxShadow: '0 20px 60px rgba(0,0,0,0.2)' },
  header:   { padding: '20px 24px 16px', borderBottom: '1px solid #E5E7EB' },
  body:     { flex: 1, overflowY: 'auto' as const, padding: '16px 24px', overflowX: 'visible' as const },
  footer:   { padding: '14px 24px', borderTop: '1px solid #E5E7EB', display: 'flex', justifyContent: 'flex-end', gap: 8, background: '#F9FAFB' },
  iconWrap: { width: 36, height: 36, borderRadius: '50%', background: '#FEE2E2', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 },
  chip:     { fontSize: 11, fontWeight: 600 as const, background: '#EEF2FF', color: '#4F46E5', borderRadius: 10, padding: '2px 8px' },
};

// ── Inline manager search picker ───────────────────────────────────────────────
function ManagerPicker({
  options,
  value,
  onChange,
}: {
  options: EmployeeOption[];
  value: string;
  onChange: (id: string) => void;
}) {
  const selected = options.find(o => o.id === value) ?? null;
  const [query, setQuery]     = useState('');
  const [open,  setOpen]      = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  // Close dropdown on outside click
  useEffect(() => {
    function handle(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', handle);
    return () => document.removeEventListener('mousedown', handle);
  }, []);

  const filtered = query.trim()
    ? options.filter(o =>
        o.name.toLowerCase().includes(query.toLowerCase()) ||
        o.code.toLowerCase().includes(query.toLowerCase())
      ).slice(0, 8)
    : [];

  function select(opt: EmployeeOption) {
    onChange(opt.id);
    setQuery('');
    setOpen(false);
  }

  function clear() {
    onChange('');
    setQuery('');
  }

  return (
    <div ref={ref} style={{ position: 'relative', flex: 1, minWidth: 200 }}>
      {selected ? (
        // Show selected employee as a chip with clear button
        <div style={{
          display: 'flex', alignItems: 'center', gap: 6,
          padding: '5px 10px', background: '#EFF6FF', border: '1px solid #BFDBFE',
          borderRadius: 6, fontSize: 12, color: '#1D4ED8',
        }}>
          <i className="fa-solid fa-user" style={{ fontSize: 10, color: '#3B82F6' }} />
          <span style={{ flex: 1, fontWeight: 500 }}>{selected.name}</span>
          <span style={{ color: '#93C5FD' }}>({selected.code})</span>
          <button onClick={clear} style={{
            background: 'none', border: 'none', cursor: 'pointer',
            color: '#93C5FD', padding: 0, fontSize: 12, lineHeight: 1,
          }} title="Clear">×</button>
        </div>
      ) : (
        <input
          type="text"
          placeholder="Search employee…"
          value={query}
          onChange={e => { setQuery(e.target.value); setOpen(true); }}
          onFocus={() => setOpen(true)}
          style={{
            width: '100%', boxSizing: 'border-box',
            fontSize: 12, padding: '5px 10px', borderRadius: 6,
            border: '1px solid #D1D5DB', outline: 'none', color: '#374151',
          }}
        />
      )}

      {open && filtered.length > 0 && (
        <div style={{
          position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 100,
          background: '#fff', border: '1px solid #E5E7EB', borderRadius: 8,
          boxShadow: '0 4px 16px rgba(0,0,0,0.12)', marginTop: 2, overflow: 'hidden',
        }}>
          {filtered.map(opt => (
            <div
              key={opt.id}
              onMouseDown={() => select(opt)}
              style={{
                padding: '8px 12px', cursor: 'pointer', fontSize: 12,
                display: 'flex', alignItems: 'center', gap: 8,
                borderBottom: '1px solid #F3F4F6',
              }}
              onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
              onMouseLeave={e => (e.currentTarget.style.background = '#fff')}
            >
              <i className="fa-solid fa-user" style={{ color: '#9CA3AF', fontSize: 10 }} />
              <span style={{ color: '#111827', fontWeight: 500 }}>{opt.name}</span>
              <span style={{ color: '#9CA3AF', marginLeft: 'auto' }}>{opt.code}</span>
            </div>
          ))}
        </div>
      )}

      {open && query.trim() && filtered.length === 0 && (
        <div style={{
          position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 100,
          background: '#fff', border: '1px solid #E5E7EB', borderRadius: 8,
          padding: '10px 12px', fontSize: 12, color: '#9CA3AF',
          boxShadow: '0 4px 16px rgba(0,0,0,0.12)', marginTop: 2,
        }}>
          No employees found
        </div>
      )}
    </div>
  );
}

// ── Main modal ─────────────────────────────────────────────────────────────────
export default function TerminationImpactModal({ employeeId, employeeName, onConfirm, onCancel }: TerminationImpactModalProps) {
  const [directReports,  setDirectReports]  = useState<DirectReport[]>([]);
  const [jrAssignments,  setJrAssignments]  = useState<JRAssignment[]>([]);
  const [drCount,        setDrCount]        = useState(0);
  const [jrCount,        setJrCount]        = useState(0);
  const [loading,        setLoading]        = useState(true);
  const [error,          setError]          = useState('');

  // manager selections: direct_report employee_id → new manager employee_id
  const [reassignments,  setReassignments]  = useState<Record<string, string>>({});
  const [managerOptions, setManagerOptions] = useState<EmployeeOption[]>([]);

  useEffect(() => {
    (async () => {
      const { data, error: err } = await supabase.rpc('get_termination_deactivation_impact', {
        p_employee_id: employeeId,
      });
      if (err) { setError(err.message); setLoading(false); return; }
      const p = data as {
        ok: boolean; error?: string;
        direct_reports: DirectReport[]; direct_report_count: number;
        jr_assignments: JRAssignment[]; jr_assignment_count: number;
      } | null;
      if (!p?.ok) { setError(p?.error ?? 'Failed to load impact data.'); setLoading(false); return; }

      setDirectReports(p.direct_reports ?? []);
      setDrCount(p.direct_report_count ?? 0);
      setJrAssignments(p.jr_assignments ?? []);
      setJrCount(p.jr_assignment_count ?? 0);

      // Fetch manager candidates: Active employees excluding the terminated employee
      // and the direct reports (they can't be each other's managers in this flow)
      const drIds = (p.direct_reports ?? []).map((r: DirectReport) => r.employee_id);
      const excludeIds = [employeeId, ...drIds];

      const { data: empRows } = await supabase
        .from('employees')
        .select('id, name, employee_id')
        .eq('status', 'Active')
        .not('id', 'in', `(${excludeIds.join(',')})`)
        .order('name');

      setManagerOptions(
        (empRows ?? []).map((e: { id: string; name: string; employee_id: string }) => ({
          id:   e.id,
          name: e.name,
          code: e.employee_id,
        }))
      );

      setLoading(false);
    })();
  }, [employeeId]);

  const totalImpact = drCount + jrCount;

  // All direct reports must have a manager selected before confirming
  const allAssigned = drCount === 0 ||
    directReports.every(r => !!reassignments[r.employee_id]);

  function handleConfirm() {
    if (!allAssigned) return;
    const result: ManagerReassignment[] = directReports
      .filter(r => reassignments[r.employee_id])
      .map(r => ({ employee_id: r.employee_id, new_manager_id: reassignments[r.employee_id] }));
    onConfirm(result);
  }

  return (
    <div style={s.overlay}>
      <div style={s.modal}>
        {/* Header */}
        <div style={s.header}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 6 }}>
            <div style={s.iconWrap}>
              <i className="fa-solid fa-triangle-exclamation" style={{ color: '#DC2626', fontSize: 16 }} />
            </div>
            <h2 style={{ margin: 0, fontSize: 16, fontWeight: 700, color: '#111827' }}>Confirm Termination</h2>
          </div>
          <p style={{ margin: 0, fontSize: 13.5, color: '#374151', lineHeight: 1.5 }}>
            You are about to terminate <strong>{employeeName}</strong>.
          </p>
        </div>

        {/* Body */}
        <div style={s.body}>
          {loading ? (
            <div style={{ textAlign: 'center', padding: '24px 0', color: '#6B7280', fontSize: 13 }}>
              <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Checking impact…
            </div>
          ) : error ? (
            <div style={{ color: '#DC2626', fontSize: 13 }}>
              <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{error}
            </div>
          ) : totalImpact === 0 ? (
            <div style={{ padding: '14px 16px', background: '#F0FDF4', borderRadius: 8, border: '1px solid #BBF7D0', fontSize: 13.5, color: '#166534', display: 'flex', gap: 8 }}>
              <i className="fa-solid fa-circle-check" />
              <span>No direct reports or matrix assignments will be affected.</span>
            </div>
          ) : (
            <>
              <div style={{ padding: '12px 16px', background: '#FFF7ED', borderRadius: 8, border: '1px solid #FED7AA', fontSize: 13.5, color: '#92400E', marginBottom: 14 }}>
                <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 6, color: '#D97706' }} />
                This termination will affect <strong>{totalImpact} employee{totalImpact !== 1 ? 's' : ''}</strong>.
                Job Relationship assignments are auto-closed; direct reports must be reassigned manually.
              </div>

              {/* Direct reports with manager search */}
              {drCount > 0 && (
                <div style={{ marginBottom: 16 }}>
                  <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 4 }}>
                    Direct Reports ({drCount}) — Reassign Manager
                  </div>
                  <div style={{ fontSize: 12, color: '#9CA3AF', marginBottom: 10 }}>
                    New manager takes effect from Last Working Day + 1. Required for all direct reports.
                  </div>

                  {directReports.map(r => (
                    <div key={r.employee_id} style={{
                      padding: '10px 14px', background: '#F9FAFB', borderRadius: 8,
                      border: '1px solid #E5E7EB', marginBottom: 8,
                    }}>
                      <div style={{ marginBottom: 8 }}>
                        <strong style={{ color: '#111827', fontSize: 13 }}>{r.name}</strong>
                        <span style={{ color: '#6B7280', fontSize: 12, marginLeft: 6 }}>({r.employee_code})</span>
                      </div>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <span style={{ fontSize: 11, color: '#9CA3AF', whiteSpace: 'nowrap' }}>New manager:</span>
                        <ManagerPicker
                          options={managerOptions}
                          value={reassignments[r.employee_id] ?? ''}
                          onChange={id => setReassignments(prev => ({ ...prev, [r.employee_id]: id }))}
                        />
                      </div>
                    </div>
                  ))}
                </div>
              )}

              {/* JR assignments (auto-closed, no action needed) */}
              {jrCount > 0 && (
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>
                    Job Relationship Assignments ({jrCount}) — auto-closed on termination
                  </div>
                  {jrAssignments.slice(0, 5).map(r => (
                    <div key={r.employee_id} style={{ padding: '9px 14px', background: '#F9FAFB', borderRadius: 8, border: '1px solid #E5E7EB', marginBottom: 6, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <span style={{ fontSize: 13, color: '#111827' }}>
                        <strong>{r.name}</strong>
                        <span style={{ color: '#6B7280', marginLeft: 8 }}>({r.employee_code})</span>
                      </span>
                      <div style={{ display: 'flex', gap: 4 }}>
                        {r.codes_held?.map(c => (
                          <span key={c} style={s.chip} title={JR_CODE_LABELS[c] ?? c}>{c}</span>
                        ))}
                      </div>
                    </div>
                  ))}
                  {jrCount > 5 && <p style={{ fontSize: 12, color: '#6B7280', margin: '4px 0 0' }}>…and {jrCount - 5} more</p>}
                </div>
              )}
            </>
          )}
        </div>

        {/* Footer */}
        <div style={{ ...s.footer, flexDirection: 'column', alignItems: 'flex-end', gap: 8 }}>
          {!allAssigned && !loading && (
            <div style={{ fontSize: 11, color: '#D97706', display: 'flex', alignItems: 'center', gap: 4 }}>
              <i className="fa-solid fa-circle-exclamation" />
              Assign a new manager to all direct reports before proceeding.
            </div>
          )}
          <div style={{ display: 'flex', gap: 8 }}>
            <button onClick={onCancel} disabled={loading}
              className="emp-btn-ghost">
              Cancel
            </button>
            <button onClick={handleConfirm} disabled={loading || !allAssigned}
              style={{
                padding: '8px 18px', fontSize: 13, borderRadius: 6, border: 'none',
                background: allAssigned ? '#DC2626' : '#FCA5A5',
                color: '#fff', cursor: allAssigned ? 'pointer' : 'not-allowed',
                fontWeight: 600, display: 'flex', alignItems: 'center', gap: 6,
              }}>
              <i className="fa-solid fa-user-slash" />Confirm & Submit
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
