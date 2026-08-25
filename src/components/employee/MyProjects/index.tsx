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
 *   are staffing. Migration 774 exposes SECURITY DEFINER calls that can, each
 *   gating itself on can_staff_project(). Reaching for the tables directly
 *   would return empty and look like a bug rather than a permission.
 *
 * WHAT MEMBERSHIP DOES, AS OF MIGS 781-785
 *   - The timesheet dropdown offers the projects you are on (783). Offers only:
 *     the database still accepts any project id, so enforcement is a separate
 *     switch.
 *   - The Project Members target group resolves from this table live, so adding
 *     someone puts them in the lead's scope on their next request (781).
 *   - The reports clip those people to the lead's own projects (782).
 *   - Staffing follows ACTIVE projects, like the role and the scope do (784).
 *   - Allocation and start date are editable after the fact (785), because
 *     membership is almost always recorded late.
 *
 * WHY THE HOURS CARRY A BAR
 *   "Who is actually doing the work" is the first question a lead asks, and a
 *   column of numbers makes it arithmetic. One hue, one magnitude, no legend.
 *   The bar is scaled to the BUSIEST member, not to the project total — scaled
 *   to the total, a team of twelve is twelve slivers and the comparison is lost.
 *   So the bar ranks and the number states: the value is always written beside
 *   it, and the tooltip gives the project total for context.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../../../lib/supabase';

interface StaffableProject {
  project_id: string; project_name: string;
  project_type: string | null;
  start_date: string | null; end_date: string | null;
  budget_hours: number | null; hours_booked: number;
  current_members: number; past_members: number;
}
interface Member {
  id: string; employee_id: string; employee_name: string; employee_code: string;
  effective_from: string; effective_to: string | null;
  allocation_pct: number | null; is_current: boolean; has_hours: boolean;
  hours_booked: number;
}
interface Candidate { employee_id: string; employee_name: string; employee_code: string; }

const INK       = '#18345B';
const INK_SOFT  = '#6B7280';
const INK_MUTED = '#9CA3AF';
const LINE      = '#E3E9F2';
const ACCENT    = '#2B54CE';
const DANGER    = '#B42318';
const WARN      = '#B54708';

const nf = new Intl.NumberFormat('en', { maximumFractionDigits: 1 });

function fmt(d: string | null): string {
  if (!d) return '—';
  const dt = new Date(d + 'T00:00:00');
  return isNaN(dt.getTime()) ? d
    : `${String(dt.getDate()).padStart(2, '0')} ${dt.toLocaleString('en', { month: 'short' })} ${dt.getFullYear()}`;
}

// ─── Project header ───────────────────────────────────────────────────────────
//
// Four facts and, when a budget exists, one meter. Deliberately not a chart: a
// single magnitude against a single target is a stat, and a stat reads faster
// than any plot of it. The meter turns amber only past 100% and never carries
// that meaning in colour alone — the caption says it in words.

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div style={{ fontSize: 10, letterSpacing: 0.6, textTransform: 'uppercase',
                    color: '#8A97A8', fontWeight: 700, marginBottom: 3 }}>{label}</div>
      <div style={{ fontSize: 14, color: INK, fontWeight: 600 }}>{value}</div>
    </div>
  );
}

function ProjectHeader({ p }: { p: StaffableProject }) {
  const budget = p.budget_hours ?? 0;
  const pct    = budget > 0 ? (p.hours_booked / budget) * 100 : null;
  const over   = pct !== null && pct > 100;

  return (
    <div style={{ background: '#fff', borderRadius: 10, padding: '16px 18px', marginBottom: 14,
                  boxShadow: '0 2px 10px rgba(24,52,91,0.07)' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap',
                    marginBottom: 14 }}>
        <h2 style={{ fontSize: 17, color: INK, margin: 0, fontWeight: 700 }}>{p.project_name}</h2>
        {p.project_type && (
          <span style={{ fontSize: 11, fontWeight: 600, color: '#3E5C8A', background: '#EEF3FB',
                         borderRadius: 999, padding: '2px 9px' }}>{p.project_type}</span>
        )}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(130px, 1fr))',
                    gap: 16, marginBottom: pct === null ? 0 : 16 }}>
        <Stat label="Runs"   value={`${fmt(p.start_date)} → ${fmt(p.end_date)}`} />
        <Stat label="Team"   value={`${p.current_members} current${p.past_members ? ` · ${p.past_members} past` : ''}`} />
        <Stat label="Budget" value={budget > 0 ? `${nf.format(budget)} h` : 'Not set'} />
        <Stat label="Booked" value={p.hours_booked > 0 ? `${nf.format(p.hours_booked)} h` : 'None yet'} />
      </div>

      {pct !== null && (
        <div>
          <div style={{ height: 6, borderRadius: 3, background: '#EEF2F7', overflow: 'hidden' }}>
            <div style={{ height: '100%', borderRadius: 3,
                          width: `${Math.min(pct, 100)}%`,
                          background: over ? WARN : ACCENT }} />
          </div>
          <div style={{ fontSize: 11.5, color: INK_SOFT, marginTop: 6 }}>
            {nf.format(p.hours_booked)} of {nf.format(budget)} budget hours · {nf.format(pct)}%
            {over && <strong style={{ color: WARN }}> · over budget by {nf.format(p.hours_booked - budget)} h</strong>}
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Allocation, edited in place ──────────────────────────────────────────────
//
// The column existed from mig 774 and could never hold a value — add() accepted
// an allocation but nothing could change one afterwards, and the screen added
// with defaults. Mig 785 closed that; this is the affordance.

function Allocation({ m, onSaved, onError }:
  { m: Member; onSaved: (msg: string) => void; onError: (msg: string) => void }) {
  const [editing, setEditing] = useState(false);
  const [val, setVal]         = useState(m.allocation_pct === null ? '' : String(m.allocation_pct));
  const [busy, setBusy]       = useState(false);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => { if (editing) input.current?.focus(); }, [editing]);

  const save = useCallback(async () => {
    const raw   = val.trim();
    const clear = raw === '';
    const num   = clear ? null : Number(raw);
    if (!clear && (!Number.isFinite(num as number) || (num as number) <= 0 || (num as number) > 100)) {
      onError('Allocation must be between 1 and 100 percent.');
      return;
    }
    setBusy(true);
    const { data, error } = await supabase.rpc('project_member_update', {
      p_id: m.id, p_allocation_pct: num, p_clear_allocation: clear,
    });
    setBusy(false);
    const res = data as { ok: boolean; message?: string } | null;
    if (error || !res?.ok) { onError(res?.message ?? 'Could not save that allocation.'); return; }
    setEditing(false);
    onSaved(clear ? `${m.employee_name}'s allocation cleared.`
                  : `${m.employee_name} set to ${nf.format(num as number)}%.`);
  }, [val, m.id, m.employee_name, onSaved, onError]);

  if (!m.is_current) {
    return <span style={{ color: INK_MUTED }}>
      {m.allocation_pct === null ? '—' : `${nf.format(m.allocation_pct)}%`}
    </span>;
  }

  if (!editing) {
    return (
      <button type="button" onClick={() => setEditing(true)}
        title="Click to set this person's allocation to the project"
        style={{ border: 0, background: 'transparent', font: 'inherit', cursor: 'pointer',
                 padding: '2px 4px', borderRadius: 4,
                 color: m.allocation_pct === null ? INK_MUTED : INK,
                 fontWeight: m.allocation_pct === null ? 400 : 600,
                 borderBottom: `1px dashed ${m.allocation_pct === null ? INK_MUTED : 'transparent'}` }}>
        {m.allocation_pct === null ? 'Set' : `${nf.format(m.allocation_pct)}%`}
      </button>
    );
  }

  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
      <input
        ref={input} type="number" min={1} max={100} value={val} disabled={busy}
        onChange={e => setVal(e.target.value)}
        onKeyDown={e => {
          if (e.key === 'Enter') { e.preventDefault(); void save(); }
          if (e.key === 'Escape') { setEditing(false); setVal(m.allocation_pct === null ? '' : String(m.allocation_pct)); }
        }}
        placeholder="—"
        style={{ width: 62, padding: '3px 6px', borderRadius: 5, border: `1px solid ${LINE}`,
                 fontSize: 13, textAlign: 'right' }}
      />
      <button type="button" onClick={() => void save()} disabled={busy} title="Save"
        style={{ border: 0, background: 'transparent', cursor: 'pointer', color: ACCENT, padding: 2 }}>
        <i className="fa-solid fa-check" />
      </button>
      <button type="button" disabled={busy} title="Cancel"
        onClick={() => { setEditing(false); setVal(m.allocation_pct === null ? '' : String(m.allocation_pct)); }}
        style={{ border: 0, background: 'transparent', cursor: 'pointer', color: INK_MUTED, padding: 2 }}>
        <i className="fa-solid fa-xmark" />
      </button>
    </span>
  );
}

// ─── The picker ───────────────────────────────────────────────────────────────

function AddMember({ projectId, onAdded }: { projectId: string; onAdded: (msg: string) => void }) {
  const [q, setQ]       = useState('');
  const [hits, setHits] = useState<Candidate[]>([]);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr]   = useState<string | null>(null);
  const wrap  = useRef<HTMLDivElement>(null);
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

  // Added with today's date and no allocation, on purpose: one click. Both are
  // editable in the row afterwards (mig 785), which is a better trade than
  // three decisions at the moment of adding somebody.
  const add = useCallback(async (c: Candidate) => {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc('project_member_add', {
      p_project_id: projectId, p_employee_id: c.employee_id,
    });
    setBusy(false);
    const res = data as { ok: boolean; message?: string } | null;
    if (error || !res?.ok) { setErr(res?.message ?? 'Could not add that person.'); return; }
    setQ(''); setHits([]); setOpen(false);
    onAdded(`${c.employee_name} added. Set their allocation in the row below.`);
  }, [projectId, onAdded]);

  return (
    <div ref={wrap} style={{ position: 'relative', maxWidth: 420 }}>
      <div style={{ position: 'relative' }}>
        <i className="fa-solid fa-user-plus"
           style={{ position: 'absolute', left: 12, top: '50%', transform: 'translateY(-50%)',
                    color: INK_MUTED, fontSize: 12, pointerEvents: 'none' }} />
        <input
          type="text" value={q} disabled={busy}
          placeholder="Search a name or employee ID to add…"
          onChange={e => { setQ(e.target.value); setErr(null); }}
          style={{ width: '100%', padding: '8px 12px 8px 32px', borderRadius: 6,
                   border: `1px solid ${LINE}`, fontSize: 13, boxSizing: 'border-box' }}
        />
      </div>
      {err && (
        <div style={{ marginTop: 6, fontSize: 12, color: DANGER }}>
          <i className="fa-solid fa-circle-exclamation" /> {err}
        </div>
      )}
      {open && q.trim().length >= 2 && (
        <ul style={{ position: 'absolute', top: 'calc(100% + 4px)', left: 0, right: 0, zIndex: 30,
                     margin: 0, padding: 4, listStyle: 'none', background: '#fff',
                     border: `1px solid ${LINE}`, borderRadius: 8,
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
                <span style={{ color: INK, fontWeight: 600 }}>{c.employee_name}</span>
                <span style={{ color: '#8A97A8' }}> · {c.employee_code}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ─── Screen ───────────────────────────────────────────────────────────────────

type SortKey = 'hours' | 'name';

export default function MyProjects() {
  const [projects, setProjects] = useState<StaffableProject[]>([]);
  const [sel, setSel]           = useState<string | null>(null);
  const [members, setMembers]   = useState<Member[]>([]);
  const [loading, setLoading]   = useState(true);
  const [busy, setBusy]         = useState(false);
  const [toast, setToast]       = useState<string | null>(null);
  const [error, setError]       = useState<string | null>(null);
  const [confirmId, setConfirm] = useState<string | null>(null);
  const [showPast, setShowPast] = useState(false);
  const [sortKey, setSortKey]   = useState<SortKey>('hours');

  // Bumped to re-read after a write, rather than calling the loaders directly
  // from an effect body.
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let live = true;
    (async () => {
      const { data } = await supabase.rpc('my_staffable_projects_detail');
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
    setToast(msg); setError(null); setConfirm(null);
    setTick(t => t + 1);
    setTimeout(() => setToast(null), 4000);
  }, []);

  const fail = useCallback((msg: string) => {
    setError(msg);
    setTimeout(() => setError(null), 6000);
  }, []);

  /**
   * The button says what will actually happen. `has_hours` comes from the RPC,
   * which is the only thing that can see the entries — so the label is the
   * server's answer, not a guess. Confirmed inline rather than through
   * window.confirm: a native dialog cannot say which of the two this is without
   * a wall of text, and it steals focus from a table the user is reading.
   */
  const remove = useCallback(async (m: Member) => {
    setBusy(true);
    const { data, error: rpcErr } = await supabase.rpc('project_member_remove', { p_id: m.id });
    setBusy(false);
    const res = data as { ok: boolean; action?: string; message?: string } | null;
    if (rpcErr || !res?.ok) { fail(res?.message ?? 'Could not update that assignment.'); return; }
    refresh(res.action === 'deleted'
      ? `${m.employee_name} removed.`
      : `${m.employee_name}'s assignment ended.`);
  }, [refresh, fail]);

  const current = projects.find(p => p.project_id === sel) ?? null;

  const { live, past, maxHours } = useMemo(() => {
    const byKey = (a: Member, b: Member) =>
      sortKey === 'hours'
        ? b.hours_booked - a.hours_booked || a.employee_name.localeCompare(b.employee_name)
        : a.employee_name.localeCompare(b.employee_name);
    const l = members.filter(m => m.is_current).sort(byKey);
    const p = members.filter(m => !m.is_current).sort(byKey);
    return { live: l, past: p, maxHours: Math.max(1, ...members.map(m => m.hours_booked)) };
  }, [members, sortKey]);

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
        <h1 style={{ fontSize: 20, color: INK, margin: '0 0 8px' }}>My Projects</h1>
        <p style={{ fontSize: 14, color: '#4B5563', lineHeight: 1.6 }}>
          No active project lists you as the Reporting Manager, so there is nothing to staff here.
          An administrator sets that on <strong>Admin → Projects</strong>, per project.
        </p>
      </div>
    );
  }

  const rowOf = (m: Member) => (
    <tr key={m.id} style={{ opacity: m.is_current ? 1 : 0.62 }}>
      <td>
        <strong style={{ color: INK }}>{m.employee_name}</strong>
        <span style={{ color: '#8A97A8' }}> · {m.employee_code}</span>
        {!m.is_current && (
          <span style={{ marginLeft: 6, fontSize: 10, color: INK_SOFT,
                         background: '#F1F3F6', borderRadius: 999, padding: '1px 7px' }}>
            past
          </span>
        )}
      </td>

      {/* Hours, with the share bar directly under the number it belongs to. */}
      <td style={{ minWidth: 150 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'flex-end', gap: 6 }}>
          <span style={{ fontWeight: m.hours_booked > 0 ? 600 : 400,
                         color: m.hours_booked > 0 ? INK : INK_MUTED }}>
            {m.hours_booked > 0 ? `${nf.format(m.hours_booked)} h` : '—'}
          </span>
        </div>
        {m.hours_booked > 0 && (
          <div style={{ height: 4, borderRadius: 2, background: '#EEF2F7', marginTop: 5 }}
               title={`${nf.format(m.hours_booked)} h of ${nf.format(current?.hours_booked ?? 0)} h on this project`}>
            <div style={{ height: '100%', borderRadius: 2, background: ACCENT,
                          width: `${Math.max(3, (m.hours_booked / maxHours) * 100)}%` }} />
          </div>
        )}
      </td>

      <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
        <Allocation m={m} onSaved={refresh} onError={fail} />
      </td>

      <td style={{ whiteSpace: 'nowrap', color: INK_SOFT }}>
        {m.is_current
          ? <>since {fmt(m.effective_from)}</>
          : <>{fmt(m.effective_from)} – {fmt(m.effective_to)}</>}
      </td>

      <td style={{ textAlign: 'right' }}>
        {m.is_current && (
          <button type="button" disabled={busy} onClick={() => setConfirm(confirmId === m.id ? null : m.id)}
            title={m.has_hours ? 'End this assignment' : 'Remove from the project'}
            style={{ border: `1px solid ${confirmId === m.id ? DANGER : 'transparent'}`,
                     background: 'transparent', borderRadius: 6, padding: '4px 8px',
                     cursor: 'pointer', color: confirmId === m.id ? DANGER : INK_MUTED }}
            onMouseEnter={e => (e.currentTarget.style.color = DANGER)}
            onMouseLeave={e => (e.currentTarget.style.color = confirmId === m.id ? DANGER : INK_MUTED)}>
            <i className="fa-solid fa-user-minus" />
          </button>
        )}
      </td>
    </tr>
  );

  const confirmRowOf = (m: Member) => (
    <tr key={`${m.id}-confirm`}>
      <td colSpan={5} style={{ background: '#FFF7F5', borderTop: `1px solid #FBD5CD` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
                      padding: '4px 0', fontSize: 13, color: '#7A271A' }}>
          <span>
            {m.has_hours
              ? <><strong>{m.employee_name}</strong> has booked {nf.format(m.hours_booked)} h to this
                  project, so the assignment is <strong>end-dated today</strong> — past timesheets stay
                  valid and the hours stay in the project report.</>
              : <><strong>{m.employee_name}</strong> has booked no time here, so the assignment is
                  <strong> removed entirely</strong>.</>}
          </span>
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
            <button type="button" disabled={busy} onClick={() => setConfirm(null)}
              style={{ border: `1px solid ${LINE}`, background: '#fff', borderRadius: 6,
                       padding: '4px 12px', fontSize: 12, cursor: 'pointer', color: INK_SOFT }}>
              Cancel
            </button>
            <button type="button" disabled={busy} onClick={() => void remove(m)}
              style={{ border: 0, background: DANGER, borderRadius: 6, padding: '4px 12px',
                       fontSize: 12, cursor: 'pointer', color: '#fff', fontWeight: 600 }}>
              {m.has_hours ? 'End assignment' : 'Remove'}
            </button>
          </span>
        </div>
      </td>
    </tr>
  );

  const sortable = (key: SortKey, label: string, align: 'left' | 'right') => (
    <th style={{ textAlign: align }}>
      <button type="button" onClick={() => setSortKey(key)}
        style={{ border: 0, background: 'transparent', font: 'inherit', color: 'inherit',
                 cursor: 'pointer', padding: 0, letterSpacing: 'inherit' }}>
        {label}{sortKey === key && <i className="fa-solid fa-arrow-down-short-wide" style={{ marginLeft: 5, opacity: 0.75 }} />}
      </button>
    </th>
  );

  return (
    <div style={{ padding: '28px 24px', maxWidth: 1280 }}>
      <h1 style={{ fontSize: 20, color: INK, margin: '0 0 4px' }}>My Projects</h1>
      <p style={{ fontSize: 13, color: INK_SOFT, margin: '0 0 20px' }}>
        Who is on the projects you manage. Adding someone does not give you access to their
        data — it records that they are on the project.
      </p>

      {toast && (
        <div style={{ marginBottom: 14, padding: '9px 14px', borderRadius: 8, fontSize: 13,
                      background: '#DCFAE6', border: '1px solid #A6F4C5', color: '#0a6b34' }}>
          <i className="fa-solid fa-circle-check" /> {toast}
        </div>
      )}
      {error && (
        <div style={{ marginBottom: 14, padding: '9px 14px', borderRadius: 8, fontSize: 13,
                      background: '#FEF3F2', border: '1px solid #FDA29B', color: '#7A271A' }}>
          <i className="fa-solid fa-circle-exclamation" /> {error}
        </div>
      )}

      <div style={{ display: 'flex', gap: 20, alignItems: 'flex-start', flexWrap: 'wrap' }}>
        {/* One project is not a choice, so it does not get a chooser — the
            header names it, and the 250px goes to the table instead. */}
        {projects.length > 1 && (
          <div style={{ flex: '0 0 250px', background: '#fff', borderRadius: 10,
                        boxShadow: '0 2px 10px rgba(24,52,91,0.07)', overflow: 'hidden' }}>
            {projects.map(p => (
              <button key={p.project_id} type="button"
                onClick={() => { setSel(p.project_id); setConfirm(null); setShowPast(false); }}
                style={{ display: 'block', width: '100%', textAlign: 'left', border: 0,
                         cursor: 'pointer', font: 'inherit', padding: '11px 14px',
                         borderLeft: `3px solid ${p.project_id === sel ? ACCENT : 'transparent'}`,
                         background: p.project_id === sel ? '#F4F7FE' : 'transparent' }}>
                <div style={{ fontSize: 13, fontWeight: 600, color: INK }}>{p.project_name}</div>
                <div style={{ fontSize: 11, color: '#8A97A8', marginTop: 2 }}>
                  {p.current_members} on the team{p.hours_booked > 0 ? ` · ${nf.format(p.hours_booked)} h` : ''}
                </div>
              </button>
            ))}
          </div>
        )}

        <div style={{ flex: 1, minWidth: 520 }}>
          {current && (
            <>
              <ProjectHeader p={current} />

              <div style={{ marginBottom: 14 }}>
                <AddMember projectId={current.project_id} onAdded={refresh} />
              </div>

              <div className="er-table-wrap er-table-wrap--fluid"
                   style={{ background: '#fff', borderRadius: 10,
                            boxShadow: '0 2px 10px rgba(24,52,91,0.07)' }}>
                <table className="er-table">
                  <thead>
                    <tr>
                      {sortable('name', 'Name', 'left')}
                      {sortable('hours', 'Hours', 'right')}
                      <th style={{ textAlign: 'right' }}>Allocation</th>
                      <th>On the project</th>
                      <th style={{ textAlign: 'right' }} aria-label="Actions" />
                    </tr>
                  </thead>
                  <tbody>
                    {live.length === 0 && past.length === 0 ? (
                      <tr><td colSpan={5} style={{ padding: 24, textAlign: 'center', color: INK_MUTED, fontSize: 13 }}>
                        Nobody on this project yet. Search above to add the first person.
                      </td></tr>
                    ) : (
                      <>
                        {live.flatMap(m => confirmId === m.id ? [rowOf(m), confirmRowOf(m)] : [rowOf(m)])}
                        {showPast && past.map(m => rowOf(m))}
                      </>
                    )}
                  </tbody>
                </table>
              </div>

              <div style={{ display: 'flex', gap: 14, alignItems: 'baseline', flexWrap: 'wrap',
                            marginTop: 10 }}>
                {past.length > 0 && (
                  <button type="button" onClick={() => setShowPast(v => !v)}
                    style={{ border: 0, background: 'transparent', font: 'inherit', fontSize: 12.5,
                             color: ACCENT, cursor: 'pointer', padding: 0 }}>
                    {showPast ? 'Hide' : 'Show'} {past.length} past member{past.length === 1 ? '' : 's'}
                  </button>
                )}
                <span style={{ fontSize: 12, color: INK_MUTED }}>
                  Someone who has booked time is <strong>end-dated</strong> rather than deleted, so
                  approved timesheets stay valid and their hours stay in the project report.
                </span>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
