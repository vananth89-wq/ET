/**
 * EmployeeAssignments — Admin › Projects › Employee Assignments
 *
 * Reverse lookup: search for any employee and see every project they are
 * currently assigned to. This is the admin counterpart to the TeamAllocation
 * panel (which shows members of a single project). Here you start from a
 * person and fan out to all their projects.
 *
 * Permission gate: reuses the same three verbs as the TeamAllocation view —
 * project_members.view | projects_mgmt.manage_members | projects_mgmt.edit.
 * If you can see team composition on any project, you can use this lookup.
 *
 * Data:
 *   - Employee search  → staffable_employee_search  (existing RPC, mig 774)
 *   - Assignment rows  → get_employee_project_assignments (new RPC, mig 836)
 */

import { useEffect, useRef, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { usePermissions } from '../../hooks/usePermissions';

// ─── Types ────────────────────────────────────────────────────────────────────

interface EmployeeHit {
  employee_id: string;
  employee_name: string;
  employee_code: string;
}

interface AssignmentRow {
  assignment_id:     string;
  project_id:        string;
  project_name:      string;
  project_type_name: string | null;
  project_start:     string;
  project_end:       string;
  manager_name:      string | null;
  budget_hours:      number | null;
  role_name:         string | null;
  allocation_pct:    number | null;
  assignment_from:   string;
  assignment_to:     string | null;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const INK       = '#18345B';
const INK_SOFT  = '#6B7280';
const INK_MUTED = '#9CA3AF';
const ACCENT    = '#2B54CE';
const LINE      = '#E3E9F2';

const nf = new Intl.NumberFormat('en', { maximumFractionDigits: 1 });

function fmt(d: string | null): string {
  if (!d) return '—';
  const dt = new Date(d + 'T00:00:00');
  return isNaN(dt.getTime()) ? d
    : `${String(dt.getDate()).padStart(2, '0')} ${dt.toLocaleString('en', { month: 'short' })} ${dt.getFullYear()}`;
}

// ─── Employee typeahead ───────────────────────────────────────────────────────

function EmployeePicker({
  chosen,
  onPick,
  onClear,
}: {
  chosen: EmployeeHit | null;
  onPick: (hit: EmployeeHit) => void;
  onClear: () => void;
}) {
  const [q, setQ]       = useState('');
  const [hits, setHits] = useState<EmployeeHit[]>([]);
  const [open, setOpen] = useState(false);
  const wrap  = useRef<HTMLDivElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (timer.current) clearTimeout(timer.current);
    if (q.trim().length < 2) { setHits([]); setOpen(false); return; }
    let live = true;
    timer.current = setTimeout(async () => {
      const { data } = await supabase.rpc('staffable_employee_search', { p_query: q.trim() });
      if (!live) return;
      setHits((data as EmployeeHit[]) ?? []);
      setOpen(true);
    }, 300);
    return () => { live = false; if (timer.current) clearTimeout(timer.current); };
  }, [q]);

  useEffect(() => {
    function away(e: MouseEvent) {
      if (wrap.current && !wrap.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', away);
    return () => document.removeEventListener('mousedown', away);
  }, []);

  const inputStyle: React.CSSProperties = {
    width: '100%', boxSizing: 'border-box', padding: '10px 14px',
    border: `1px solid ${LINE}`, borderRadius: 8, fontSize: 14,
    color: INK, font: 'inherit', outline: 'none',
  };

  // ── chosen state: show chip ──────────────────────────────────────────────────
  if (chosen) {
    return (
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '9px 14px', border: `1px solid ${LINE}`, borderRadius: 8,
        background: '#F4F7FE', fontSize: 14,
      }}>
        <i className="fa-solid fa-user" style={{ color: ACCENT, fontSize: 13 }} />
        <span style={{ fontWeight: 600, color: INK }}>{chosen.employee_name}</span>
        <span style={{ color: INK_MUTED }}>· {chosen.employee_code}</span>
        <button
          type="button"
          onClick={() => { onClear(); setQ(''); }}
          title="Search a different employee"
          style={{
            marginLeft: 'auto', border: 0, background: 'transparent',
            cursor: 'pointer', color: INK_MUTED, padding: 2, fontSize: 13,
          }}
        >
          <i className="fa-solid fa-xmark" />
        </button>
      </div>
    );
  }

  // ── search state ─────────────────────────────────────────────────────────────
  return (
    <div ref={wrap} style={{ position: 'relative' }}>
      <div style={{ position: 'relative' }}>
        <i className="fa-solid fa-magnifying-glass" style={{
          position: 'absolute', left: 12, top: '50%', transform: 'translateY(-50%)',
          color: INK_MUTED, fontSize: 13, pointerEvents: 'none',
        }} />
        <input
          type="text"
          value={q}
          placeholder="Search by name or employee ID…"
          onChange={e => setQ(e.target.value)}
          style={{ ...inputStyle, paddingLeft: 34 }}
          autoFocus
        />
      </div>

      {open && q.trim().length >= 2 && (
        <ul style={{
          position: 'absolute', top: 'calc(100% + 4px)', left: 0, right: 0,
          zIndex: 30, margin: 0, padding: 4, listStyle: 'none',
          background: '#fff', border: `1px solid ${LINE}`, borderRadius: 8,
          boxShadow: '0 8px 24px rgba(24,52,91,0.14)',
          maxHeight: 260, overflowY: 'auto',
        }}>
          {hits.length === 0 ? (
            <li style={{ padding: '10px 12px', fontSize: 13, color: INK_MUTED }}>
              No active employees match "{q.trim()}".
            </li>
          ) : hits.map(h => (
            <li key={h.employee_id}>
              <button
                type="button"
                onClick={() => { onPick(h); setOpen(false); setQ(''); }}
                style={{
                  width: '100%', textAlign: 'left', border: 0,
                  background: 'transparent', cursor: 'pointer', font: 'inherit',
                  fontSize: 13.5, padding: '9px 12px', borderRadius: 6,
                  display: 'flex', alignItems: 'baseline', gap: 8,
                }}
                onMouseEnter={e => (e.currentTarget.style.background = '#EEF2F8')}
                onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}
              >
                <span style={{ fontWeight: 600, color: INK }}>{h.employee_name}</span>
                <span style={{ color: INK_MUTED, fontSize: 12 }}>· {h.employee_code}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ─── Assignment table ─────────────────────────────────────────────────────────

function AssignmentTable({ rows }: { rows: AssignmentRow[] }) {
  if (rows.length === 0) {
    return (
      <div style={{
        textAlign: 'center', padding: '40px 24px',
        color: INK_MUTED, fontSize: 14, lineHeight: 1.6,
      }}>
        <i className="fa-solid fa-folder-open" style={{ fontSize: 28, marginBottom: 12, display: 'block', opacity: 0.4 }} />
        This employee has no active project assignments right now.
      </div>
    );
  }

  return (
    <div className="er-table-wrap" style={{ overflow: 'hidden', maxWidth: '100%' }}>
      <div style={{ overflowX: 'auto' }}>
        <table className="er-table">
          <thead>
            <tr>
              <th style={{ width: 36 }}>#</th>
              <th>Project</th>
              <th>Type</th>
              <th>Project Period</th>
              <th>Reporting Manager</th>
              <th>Role</th>
              <th style={{ textAlign: 'right' }}>Allocation</th>
              <th>Assignment Period</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={r.assignment_id}>
                <td style={{ color: INK_MUTED, fontSize: 12 }}>{i + 1}</td>

                {/* Project name + budget pill */}
                <td>
                  <strong style={{ color: INK }}>{r.project_name}</strong>
                  {r.budget_hours !== null && (
                    <span style={{
                      marginLeft: 8, fontSize: 10.5, color: INK_SOFT,
                      background: '#F1F5F9', borderRadius: 999, padding: '1px 7px',
                    }}>
                      {nf.format(r.budget_hours)} h budget
                    </span>
                  )}
                </td>

                {/* Type badge */}
                <td>
                  {r.project_type_name
                    ? <span style={{
                        fontSize: 11, fontWeight: 600, color: '#3E5C8A',
                        background: '#EEF3FB', borderRadius: 999, padding: '2px 9px',
                      }}>{r.project_type_name}</span>
                    : <span style={{ color: INK_MUTED, fontSize: 12 }}>—</span>}
                </td>

                {/* Project dates */}
                <td style={{ whiteSpace: 'nowrap', color: INK_SOFT, fontSize: 13 }}>
                  {fmt(r.project_start)} → {fmt(r.project_end)}
                </td>

                {/* Manager */}
                <td style={{ color: r.manager_name ? INK_SOFT : INK_MUTED, fontSize: 13 }}>
                  {r.manager_name ?? '—'}
                </td>

                {/* Role */}
                <td style={{ color: r.role_name ? INK_SOFT : INK_MUTED, fontSize: 13 }}>
                  {r.role_name ?? '—'}
                </td>

                {/* Allocation % */}
                <td style={{ textAlign: 'right', fontWeight: 600, color: INK }}>
                  {r.allocation_pct !== null
                    ? `${nf.format(r.allocation_pct)}%`
                    : <span style={{ fontWeight: 400, color: INK_MUTED }}>—</span>}
                </td>

                {/* Assignment dates */}
                <td style={{ whiteSpace: 'nowrap', color: INK_SOFT, fontSize: 13 }}>
                  {fmt(r.assignment_from)}
                  {' → '}
                  {r.assignment_to ? fmt(r.assignment_to) : (
                    <span style={{ color: ACCENT, fontWeight: 500 }}>ongoing</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function EmployeeAssignments() {
  const { can } = usePermissions();

  // Gate: same verbs that control the TeamAllocation view button in Projects.tsx
  const mayView = can('project_members.view')
               || can('projects_mgmt.manage_members')
               || can('projects_mgmt.edit');

  const [chosen,      setChosen]      = useState<EmployeeHit | null>(null);
  const [assignments, setAssignments] = useState<AssignmentRow[]>([]);
  const [loading,     setLoading]     = useState(false);
  const [error,       setError]       = useState<string | null>(null);

  // Fetch whenever the selected employee changes
  useEffect(() => {
    if (!chosen) { setAssignments([]); return; }
    let live = true;
    setLoading(true);
    setError(null);
    (async () => {
      const { data, error: rpcErr } = await supabase.rpc(
        'get_employee_project_assignments',
        { p_employee_id: chosen.employee_id },
      );
      if (!live) return;
      if (rpcErr) {
        setError(rpcErr.message);
        setAssignments([]);
      } else {
        setAssignments((data as AssignmentRow[]) ?? []);
      }
      setLoading(false);
    })();
    return () => { live = false; };
  }, [chosen]);

  // ── Access denied ────────────────────────────────────────────────────────────
  if (!mayView) {
    return (
      <div style={{ padding: '48px 24px', maxWidth: 560 }}>
        <div style={{
          background: '#FEF3F2', border: '1px solid #FDA29B', borderRadius: 10,
          padding: '20px 24px', color: '#7A271A',
        }}>
          <i className="fa-solid fa-lock" style={{ marginRight: 8 }} />
          You don't have permission to view project team members.
          Contact an administrator to be granted <strong>project_members.view</strong>.
        </div>
      </div>
    );
  }

  // ── Main render ───────────────────────────────────────────────────────────────
  return (
    <div>
      {/* Search card */}
      <div className="rd-form-card" style={{ marginBottom: 20 }}>
        <div style={{ marginBottom: 12 }}>
          <label style={{
            fontSize: 11, letterSpacing: 0.6, textTransform: 'uppercase',
            color: '#8A97A8', fontWeight: 700, display: 'block', marginBottom: 6,
          }}>
            Employee
          </label>
          <EmployeePicker
            chosen={chosen}
            onPick={hit => setChosen(hit)}
            onClear={() => { setChosen(null); setAssignments([]); setError(null); }}
          />
          <small style={{ color: INK_MUTED, display: 'block', marginTop: 6, fontSize: 12 }}>
            Shows all projects this employee is currently staffed on.
          </small>
        </div>
      </div>

      {/* Results */}
      {chosen && (
        <div className="rd-form-card">
          {/* Header row */}
          <div style={{
            display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
            gap: 12, flexWrap: 'wrap', marginBottom: 14,
          }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
              <h3 style={{ fontSize: 15, fontWeight: 700, color: INK, margin: 0 }}>
                Active Assignments
              </h3>
              {!loading && (
                <span style={{ fontSize: 12, color: INK_MUTED }}>
                  {assignments.length === 0
                    ? 'none'
                    : `${assignments.length} project${assignments.length === 1 ? '' : 's'}`}
                </span>
              )}
            </div>
            <span style={{ fontSize: 12.5, color: INK_SOFT }}>
              {chosen.employee_name} · {chosen.employee_code}
            </span>
          </div>

          {/* Loading */}
          {loading && (
            <div style={{ padding: '32px 0', textAlign: 'center', color: INK_MUTED, fontSize: 13 }}>
              <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 8 }} />
              Loading assignments…
            </div>
          )}

          {/* Error */}
          {!loading && error && (
            <div style={{
              padding: '12px 16px', borderRadius: 8, fontSize: 13,
              background: '#FEF3F2', border: '1px solid #FDA29B', color: '#7A271A', marginBottom: 12,
            }}>
              <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
              {error}
            </div>
          )}

          {/* Table */}
          {!loading && !error && <AssignmentTable rows={assignments} />}

          {/* Footnote */}
          {!loading && !error && assignments.length > 0 && (
            <p style={{
              fontSize: 12, color: INK_MUTED, margin: '10px 0 0', lineHeight: 1.55,
            }}>
              Only assignments where the employee is currently active <em>and</em> the
              project is currently running are shown. Past or upcoming assignments do not appear here.
            </p>
          )}
        </div>
      )}

      {/* Prompt before any search */}
      {!chosen && (
        <div style={{
          textAlign: 'center', padding: '52px 24px',
          color: INK_MUTED, fontSize: 14, lineHeight: 1.7,
        }}>
          <i className="fa-solid fa-user-magnifying-glass" style={{
            fontSize: 32, display: 'block', marginBottom: 14, opacity: 0.35,
          }} />
          Search for an employee above to see their active project assignments.
        </div>
      )}
    </div>
  );
}
