/**
 * My Projects — a project lead staffs the projects they are Reporting Manager on.
 *
 * WHY EVERY READ HERE IS AN RPC AND NOT A TABLE QUERY
 *   A lead holds projects_mgmt.manage_members and, typically, nothing else. That
 *   leaves them unable to SELECT the two tables this screen obviously needs:
 *
 *     projects   → POLICY requires projects_mgmt.view      (the admin screen)
 *     employees  → POLICY requires employee_details.view, per employee
 *
 *   So they cannot read their own project's name, nor the name of anyone they
 *   are staffing. Migration 774 exposes four SECURITY DEFINER calls that can,
 *   each gating itself on can_staff_project(). Reaching for the tables directly
 *   would return empty and look like a bug rather than a permission.
 *
 * WHAT MEMBERSHIP DOES AND DOES NOT DO, TODAY
 *   Nothing yet, deliberately. The timesheet dropdown still lists every project
 *   and nothing blocks an entry against a project you are not on (step 2), and
 *   membership grants the lead no visibility of anyone (step 3). This screen
 *   fills the table so those steps have something real to switch on.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '../../../lib/supabase';

interface StaffableProject { project_id: string; project_name: string; member_count: number; }
interface Member {
  id: string; employee_id: string; employee_name: string; employee_code: string;
  effective_from: string; effective_to: string | null;
  allocation_pct: number | null; is_current: boolean; has_hours: boolean;
}
interface Candidate { employee_id: string; employee_name: string; employee_code: string; }

function fmt(d: string | null): string {
  if (!d) return '—';
  const dt = new Date(d + 'T00:00:00');
  return isNaN(dt.getTime()) ? d
    : `${String(dt.getDate()).padStart(2, '0')} ${dt.toLocaleString('en', { month: 'short' })} ${dt.getFullYear()}`;
}

// ─── The picker ───────────────────────────────────────────────────────────────

function AddMember({ projectId, onAdded }: { projectId: string; onAdded: (msg: string) => void }) {
  const [q, setQ]           = useState('');
  const [hits, setHits]     = useState<Candidate[]>([]);
  const [open, setOpen]     = useState(false);
  const [busy, setBusy]     = useState(false);
  const [err, setErr]       = useState<string | null>(null);
  const wrap = useRef<HTMLDivElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (timer.current) clearTimeout(timer.current);
    if (q.trim().length < 2) return;      // rendered as no results; not a state change
    let live = true;
    timer.current = setTimeout(async () => {
      const { data } = await supabase.rpc('staffable_employee_search', { p_query: q.trim() });
      if (!live) return;
      setHits((data as Candidate[]) ?? []);
      setOpen(true);
    }, 300);
    return () => { live = false; if (timer.current) clearTimeout(timer.current); };
  }, [q]);

  // Below the minimum the server returns nothing anyway, so showing a stale hit
  // list would be a lie the effect had to clear. Derive it instead.
  const shown = q.trim().length >= 2 ? hits : [];

  useEffect(() => {
    function away(e: MouseEvent) {
      if (wrap.current && !wrap.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', away);
    return () => document.removeEventListener('mousedown', away);
  }, []);

  const add = useCallback(async (c: Candidate) => {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc('project_member_add', {
      p_project_id: projectId, p_employee_id: c.employee_id,
    });
    setBusy(false);
    const res = data as { ok: boolean; message?: string } | null;
    if (error || !res?.ok) { setErr(res?.message ?? 'Could not add that person.'); return; }
    setQ(''); setHits([]); setOpen(false);
    onAdded(`${c.employee_name} added.`);
  }, [projectId, onAdded]);

  return (
    <div ref={wrap} style={{ position: 'relative', maxWidth: 420 }}>
      <input
        type="text" value={q} disabled={busy}
        placeholder="Search a name or employee ID to add…"
        onChange={e => { setQ(e.target.value); setErr(null); }}
        style={{ width: '100%', padding: '8px 12px', borderRadius: 6,
                 border: '1px solid #D1D5DB', fontSize: 13, boxSizing: 'border-box' }}
      />
      {err && (
        <div style={{ marginTop: 6, fontSize: 12, color: '#B42318' }}>
          <i className="fa-solid fa-circle-exclamation" /> {err}
        </div>
      )}
      {open && q.trim().length >= 2 && (
        <ul style={{ position: 'absolute', top: 'calc(100% + 4px)', left: 0, right: 0, zIndex: 30,
                     margin: 0, padding: 4, listStyle: 'none', background: '#fff',
                     border: '1px solid #E3E9F2', borderRadius: 8,
                     boxShadow: '0 8px 24px rgba(24,52,91,0.14)', maxHeight: 260, overflowY: 'auto' }}>
          {shown.length === 0 ? (
            <li style={{ padding: '8px 10px', fontSize: 13, color: '#8A97A8' }}>
              Nobody active matches “{q.trim()}”.
            </li>
          ) : shown.map(c => (
            <li key={c.employee_id}>
              <button type="button" onClick={() => add(c)}
                style={{ width: '100%', textAlign: 'left', border: 0, background: 'transparent',
                         cursor: 'pointer', font: 'inherit', fontSize: 13, padding: '8px 10px',
                         borderRadius: 6 }}
                onMouseEnter={e => (e.currentTarget.style.background = '#EEF2F8')}
                onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}>
                <span style={{ color: '#18345B', fontWeight: 600 }}>{c.employee_name}</span>
                <span style={{ color: '#8A97A8' }}> · {c.employee_code}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ─── The screen ───────────────────────────────────────────────────────────────

export default function MyProjects() {
  const [projects, setProjects] = useState<StaffableProject[]>([]);
  const [sel, setSel]           = useState<string | null>(null);
  const [members, setMembers]   = useState<Member[]>([]);
  const [loading, setLoading]   = useState(true);
  const [busy, setBusy]         = useState(false);
  const [toast, setToast]       = useState<string | null>(null);

  // Bumped to re-read after a write, rather than calling the loaders directly
  // from an effect body.
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let live = true;
    (async () => {
      const { data } = await supabase.rpc('my_staffable_projects');
      if (!live) return;
      const rows = (data as StaffableProject[]) ?? [];
      setProjects(rows);
      setSel(prev => prev ?? rows[0]?.project_id ?? null);
      setLoading(false);
    })();
    return () => { live = false; };
  }, [tick]);

  useEffect(() => {
    if (!sel) return;
    let live = true;
    (async () => {
      const { data } = await supabase.rpc('my_project_members', { p_project_id: sel });
      if (live) setMembers((data as Member[]) ?? []);
    })();
    return () => { live = false; };
  }, [sel, tick]);

  const refresh = useCallback((msg: string) => {
    setToast(msg);
    setTick(t => t + 1);
    setTimeout(() => setToast(null), 4000);
  }, []);

  /**
   * The button says what will actually happen. `has_hours` comes from the RPC,
   * which is the only thing that can see the entries — so the label is the
   * server's answer, not a guess.
   */
  const remove = useCallback(async (m: Member) => {
    const ending = m.has_hours;
    const ok = window.confirm(
      ending
        ? `${m.employee_name} has already booked time to this project.\n\nTheir assignment will be END-DATED today. Past timesheets stay valid and their hours stay in the project report.`
        : `${m.employee_name} has booked no time to this project.\n\nThe assignment will be removed entirely.`);
    if (!ok) return;
    setBusy(true);
    const { data, error } = await supabase.rpc('project_member_remove', { p_id: m.id });
    setBusy(false);
    const res = data as { ok: boolean; action?: string; message?: string } | null;
    if (error || !res?.ok) { window.alert(res?.message ?? 'Could not update that assignment.'); return; }
    refresh(res.action === 'deleted'
      ? `${m.employee_name} removed.`
      : `${m.employee_name}'s assignment ended.`);
  }, [refresh]);

  const current = projects.find(p => p.project_id === sel) ?? null;

  if (loading) {
    return <div style={{ padding: 48, textAlign: 'center', color: '#94a3b8' }}>
      <i className="fa-solid fa-spinner fa-spin" /> Loading your projects…
    </div>;
  }

  // Holding the permission but managing nothing is a real state, and it has a
  // specific cause worth naming rather than an empty screen.
  if (projects.length === 0) {
    return (
      <div style={{ padding: 40, maxWidth: 640 }}>
        <h1 style={{ fontSize: 20, color: '#18345B', margin: '0 0 8px' }}>My Projects</h1>
        <p style={{ fontSize: 14, color: '#4B5563', lineHeight: 1.6 }}>
          No projects list you as the Reporting Manager, so there is nothing to staff here.
          An administrator sets that on <strong>Admin → Projects</strong>, per project.
        </p>
      </div>
    );
  }

  return (
    <div style={{ padding: '28px 24px', maxWidth: 1100 }}>
      <h1 style={{ fontSize: 20, color: '#18345B', margin: '0 0 4px' }}>My Projects</h1>
      <p style={{ fontSize: 13, color: '#6B7280', margin: '0 0 20px' }}>
        Who is on the projects you manage. Adding someone does not give you access to their
        data — it records that they are on the project.
      </p>

      {toast && (
        <div style={{ marginBottom: 14, padding: '9px 14px', borderRadius: 8, fontSize: 13,
                      background: '#DCFAE6', border: '1px solid #A6F4C5', color: '#0a6b34' }}>
          <i className="fa-solid fa-circle-check" /> {toast}
        </div>
      )}

      <div style={{ display: 'flex', gap: 20, alignItems: 'flex-start', flexWrap: 'wrap' }}>
        <div style={{ flex: '0 0 240px', background: '#fff', borderRadius: 10,
                      boxShadow: '0 2px 10px rgba(24,52,91,0.07)', overflow: 'hidden' }}>
          {projects.map(p => (
            <button key={p.project_id} type="button" onClick={() => setSel(p.project_id)}
              style={{ display: 'block', width: '100%', textAlign: 'left', border: 0,
                       cursor: 'pointer', font: 'inherit', padding: '11px 14px',
                       borderLeft: `3px solid ${p.project_id === sel ? '#2B54CE' : 'transparent'}`,
                       background: p.project_id === sel ? '#F4F7FE' : 'transparent' }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: '#18345B' }}>{p.project_name}</div>
              <div style={{ fontSize: 11, color: '#8A97A8', marginTop: 2 }}>
                {p.member_count} on the team
              </div>
            </button>
          ))}
        </div>

        <div style={{ flex: 1, minWidth: 460 }}>
          {current && (
            <>
              <div style={{ marginBottom: 14 }}>
                <AddMember projectId={current.project_id} onAdded={refresh} />
              </div>

              <div className="er-table-wrap er-table-wrap--fluid" style={{ background: '#fff', borderRadius: 10,
                                                      boxShadow: '0 2px 10px rgba(24,52,91,0.07)' }}>
                <table className="er-table">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>From</th>
                      <th>Until</th>
                      <th style={{ textAlign: 'right' }}>Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    {members.length === 0 ? (
                      <tr><td colSpan={4} style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
                        Nobody on this project yet.
                      </td></tr>
                    ) : members.map(m => (
                      <tr key={m.id} style={{ opacity: m.is_current ? 1 : 0.55 }}>
                        <td>
                          <strong>{m.employee_name}</strong>
                          <span style={{ color: '#8A97A8' }}> · {m.employee_code}</span>
                          {!m.is_current && (
                            <span style={{ marginLeft: 6, fontSize: 10, color: '#6B7280',
                                           background: '#F1F3F6', borderRadius: 999, padding: '1px 7px' }}>
                              past
                            </span>
                          )}
                        </td>
                        <td style={{ whiteSpace: 'nowrap' }}>{fmt(m.effective_from)}</td>
                        <td style={{ whiteSpace: 'nowrap' }}>{fmt(m.effective_to)}</td>
                        <td style={{ textAlign: 'right' }}>
                          {m.is_current && (
                            <button type="button" disabled={busy} onClick={() => remove(m)}
                              style={{ border: '1px solid #E3E9F2', background: '#fff', borderRadius: 6,
                                       padding: '4px 10px', fontSize: 12, cursor: 'pointer', color: '#B42318' }}>
                              {m.has_hours ? 'End assignment' : 'Remove'}
                            </button>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <p style={{ fontSize: 11.5, color: '#8A97A8', marginTop: 10, lineHeight: 1.5 }}>
                Someone who has booked time is <strong>end-dated</strong> rather than deleted, so
                approved timesheets stay valid and their hours stay in the project report.
              </p>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
