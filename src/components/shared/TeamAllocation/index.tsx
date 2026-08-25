/**
 * Team Allocation — who is on a project, and on what terms.
 *
 * ONE COMPONENT, TWO SCREENS
 *   My Projects (a lead, their own projects) and Admin → Projects → Team (an
 *   administrator, any project) mount this same thing. They differ only in which
 *   project list feeds them and whether hard delete is offered. Two copies of a
 *   screen this rule-heavy would diverge within a month, and then a fix in one
 *   would still be a bug in the other.
 *
 * WHY A FORM RATHER THAN INLINE EDITORS
 *   Every field is mandatory. You cannot enforce that across five independent
 *   cells — each one only knows its own value, and a half-filled row would save.
 *   One panel owns the whole row, validates it as a whole, and is the only thing
 *   that writes.
 *
 * WHY HOURS ARE NOT IN THE FORM
 *   They are evidence, summed from timesheets. Putting them in an editor would
 *   imply they can be typed. They stay a column.
 *
 * THE FOUR VERBS (mig 791)
 *   view / create / edit / delete are separate permissions, so the controls are
 *   gated separately: somebody may be allowed to read a team without staffing
 *   it, or to add people without ending anyone's assignment.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../../../lib/supabase';
import { usePermissions } from '../../../hooks/usePermissions';
import { usePicklistValues } from '../../../hooks/usePicklistValues';

export interface TeamMember {
  id: string; employee_id: string; employee_name: string; employee_code: string;
  effective_from: string; effective_to: string | null;
  allocation_pct: number | null; is_current: boolean; has_hours: boolean;
  hours_booked: number; role_id: string | null; role_name: string | null;
}
interface Candidate { employee_id: string; employee_name: string; employee_code: string }

export interface TeamAllocationProps {
  projectId: string;
  projectName: string;
  /** Mandatory since mig 790. Seeds the End date of a new assignment. */
  projectEndDate: string;
  /** Let the parent refresh its own header counts after a write. */
  onChanged?: () => void;
  /** Admin surface only: offer removal of a member who has booked no hours. */
  allowHardDelete?: boolean;
}

const INK = '#18345B', INK_SOFT = '#6B7280', INK_MUTED = '#9CA3AF';
const LINE = '#E3E9F2', ACCENT = '#2B54CE', DANGER = '#B42318';

const nf = new Intl.NumberFormat('en', { maximumFractionDigits: 1 });

function fmt(d: string | null): string {
  if (!d) return '—';
  const dt = new Date(d + 'T00:00:00');
  return isNaN(dt.getTime()) ? d
    : `${String(dt.getDate()).padStart(2, '0')} ${dt.toLocaleString('en', { month: 'short' })} ${dt.getFullYear()}`;
}
const todayIso = () => new Date().toISOString().slice(0, 10);

const lbl: React.CSSProperties = {
  fontSize: 10, letterSpacing: 0.6, textTransform: 'uppercase',
  color: '#8A97A8', fontWeight: 700, marginBottom: 5, display: 'block',
};
const box: React.CSSProperties = {
  width: '100%', boxSizing: 'border-box', padding: '9px 12px', borderRadius: 7,
  border: `1px solid #D8E0EC`, background: '#fff', fontSize: 13, color: INK, font: 'inherit',
};

type Mode = { kind: 'idle' } | { kind: 'add' } | { kind: 'edit'; member: TeamMember };

export default function TeamAllocation({
  projectId, projectName, projectEndDate, onChanged, allowHardDelete = false,
}: TeamAllocationProps) {
  const { can } = usePermissions();
  const { getValues } = usePicklistValues();
  const roles = useMemo(
    () => getValues('PROJECT_ROLE').filter(r => r.active),
    [getValues]);

  const mayCreate = can('project_members.create') || can('projects_mgmt.manage_members') || can('projects_mgmt.edit');
  const mayEdit   = can('project_members.edit')   || can('projects_mgmt.manage_members') || can('projects_mgmt.edit');
  const mayDelete = can('project_members.delete') || can('projects_mgmt.manage_members') || can('projects_mgmt.edit');

  const [members, setMembers] = useState<TeamMember[]>([]);
  const [mode, setMode]       = useState<Mode>({ kind: 'idle' });
  const [busy, setBusy]       = useState(false);
  const [toast, setToast]     = useState<string | null>(null);
  const [error, setError]     = useState<string | null>(null);
  const [confirmId, setConfirm] = useState<string | null>(null);
  const [showPast, setShowPast] = useState(false);
  const [sortKey, setSortKey]   = useState<'hours' | 'name'>('hours');
  const [tick, setTick]         = useState(0);

  // ── form ───────────────────────────────────────────────────────────────────
  const [empId, setEmpId]   = useState('');
  const [empName, setName]  = useState('');
  const [roleId, setRoleId] = useState('');
  const [pct, setPct]       = useState('');
  const [from, setFrom]     = useState('');
  const [to, setTo]         = useState('');

  const openAdd = useCallback(() => {
    setEmpId(''); setName(''); setRoleId(''); setPct('');
    setFrom(todayIso()); setTo(projectEndDate);
    setError(null); setConfirm(null); setMode({ kind: 'add' });
  }, [projectEndDate]);

  const openEdit = useCallback((m: TeamMember) => {
    setEmpId(m.employee_id); setName(`${m.employee_name} · ${m.employee_code}`);
    setRoleId(m.role_id ?? '');
    setPct(m.allocation_pct === null ? '' : String(m.allocation_pct));
    setFrom(m.effective_from); setTo(m.effective_to ?? projectEndDate);
    setError(null); setConfirm(null); setMode({ kind: 'edit', member: m });
  }, [projectEndDate]);

  const close = useCallback(() => { setMode({ kind: 'idle' }); setError(null); }, []);

  useEffect(() => {
    let live = true;
    (async () => {
      const { data } = await supabase.rpc('my_project_members', { p_project_id: projectId });
      if (live) setMembers((data as TeamMember[]) ?? []);
    })();
    return () => { live = false; };
  }, [projectId, tick]);

  // Switching project must never carry a half-typed row across — it would save
  // onto the wrong project. The parent gives this component key={projectId}, so
  // React remounts it and every piece of state goes with it. Resetting in an
  // effect instead would leave the old form on screen for one render, and is
  // the cascading-render pattern the lint rule exists to catch.

  const done = useCallback((msg: string) => {
    setToast(msg); setError(null); setConfirm(null); setMode({ kind: 'idle' });
    setTick(t => t + 1); onChanged?.();
    setTimeout(() => setToast(null), 4000);
  }, [onChanged]);

  const fail = useCallback((msg: string) => {
    setError(msg);
    setTimeout(() => setError(null), 8000);
  }, []);

  const save = useCallback(async () => {
    // Narrows the mode for everything below: with the panel closed there is no
    // row to save, and TypeScript cannot know that from the ternaries alone.
    if (mode.kind === 'idle') return;
    const n = Number(pct);
    if (mode.kind === 'add' && !empId) { fail('Choose the employee to add.'); return; }
    if (!roleId)                       { fail('Role is required.'); return; }
    if (!pct.trim() || !Number.isFinite(n) || n <= 0 || n > 100) {
      fail('Percentage is required, between 1 and 100.'); return;
    }
    if (!from) { fail('Start date is required.'); return; }
    if (!to)   { fail('End date is required.'); return; }
    if (to < from) { fail('The end date cannot be before the start date.'); return; }
    if (to > projectEndDate) {
      fail(`The assignment cannot run past the project, which ends ${fmt(projectEndDate)}.`); return;
    }

    setBusy(true);
    const { data, error: rpcErr } = mode.kind === 'add'
      ? await supabase.rpc('project_member_add', {
          p_project_id: projectId, p_employee_id: empId, p_effective_from: from,
          p_allocation_pct: n, p_role_id: roleId, p_effective_to: to })
      : await supabase.rpc('project_member_update', {
          p_id: mode.member.id, p_allocation_pct: n, p_role_id: roleId,
          p_effective_from: from, p_effective_to: to });
    setBusy(false);

    const res = data as { ok: boolean; message?: string; notified?: number; notify_error?: string } | null;
    if (rpcErr || !res?.ok) { fail(res?.message ?? rpcErr?.message ?? 'Could not save that assignment.'); return; }

    done(mode.kind === 'add'
      ? (res.notify_error
          ? `${empName.split(' · ')[0]} added — but they could not be notified. Tell them directly.`
          : `${empName.split(' · ')[0]} added${res.notified ? ' and notified' : ''}.`)
      : `${mode.member.employee_name} updated.`);
  }, [mode, empId, empName, roleId, pct, from, to, projectId, projectEndDate, done, fail]);

  const remove = useCallback(async (m: TeamMember) => {
    setBusy(true);
    const { data, error: rpcErr } = await supabase.rpc('project_member_remove', { p_id: m.id });
    setBusy(false);
    const res = data as { ok: boolean; action?: string; message?: string } | null;
    if (rpcErr || !res?.ok) { fail(res?.message ?? rpcErr?.message ?? 'Could not update that assignment.'); return; }
    done(res.action === 'deleted' ? `${m.employee_name} removed.` : `${m.employee_name}'s assignment ended.`);
  }, [done, fail]);

  const { live, past, maxHours } = useMemo(() => {
    const by = (a: TeamMember, b: TeamMember) =>
      sortKey === 'hours'
        ? b.hours_booked - a.hours_booked || a.employee_name.localeCompare(b.employee_name)
        : a.employee_name.localeCompare(b.employee_name);
    return {
      live: members.filter(m => m.is_current).sort(by),
      past: members.filter(m => !m.is_current).sort(by),
      maxHours: Math.max(1, ...members.map(m => m.hours_booked)),
    };
  }, [members, sortKey]);

  const sortable = (key: 'hours' | 'name', text: string, align: 'left' | 'right') => (
    <th style={{ textAlign: align }}>
      <button type="button" onClick={() => setSortKey(key)}
        style={{ border: 0, background: 'transparent', font: 'inherit', color: 'inherit',
                 cursor: 'pointer', padding: 0, letterSpacing: 'inherit' }}>
        {text}{sortKey === key && <i className="fa-solid fa-arrow-down-short-wide" style={{ marginLeft: 5, opacity: 0.75 }} />}
      </button>
    </th>
  );

  const row = (m: TeamMember) => (
    <tr key={m.id} style={{
      opacity: m.is_current ? 1 : 0.62,
      background: mode.kind === 'edit' && mode.member.id === m.id ? '#F4F7FE' : undefined,
      boxShadow:  mode.kind === 'edit' && mode.member.id === m.id ? `inset 3px 0 0 ${ACCENT}` : undefined,
    }}>
      <td>
        <strong style={{ color: INK }}>{m.employee_name}</strong>
        <span style={{ color: '#8A97A8' }}> · {m.employee_code}</span>
        {!m.is_current && (
          <span style={{ marginLeft: 6, fontSize: 10, color: INK_SOFT, background: '#F1F3F6',
                         borderRadius: 999, padding: '1px 7px' }}>past</span>
        )}
      </td>
      <td>{m.role_name ?? <span style={{ color: INK_MUTED }}>—</span>}</td>
      <td style={{ textAlign: 'right', fontWeight: 600, color: INK }}>
        {m.allocation_pct === null ? <span style={{ color: INK_MUTED, fontWeight: 400 }}>—</span>
                                   : `${nf.format(m.allocation_pct)}%`}
      </td>
      <td style={{ whiteSpace: 'nowrap', color: INK_SOFT }}>{fmt(m.effective_from)}</td>
      <td style={{ whiteSpace: 'nowrap', color: INK_SOFT }}>{fmt(m.effective_to)}</td>
      <td style={{ minWidth: 120 }}>
        <div style={{ textAlign: 'right', fontWeight: m.hours_booked > 0 ? 600 : 400,
                      color: m.hours_booked > 0 ? INK : INK_MUTED }}>
          {m.hours_booked > 0 ? `${nf.format(m.hours_booked)} h` : '—'}
        </div>
        {m.hours_booked > 0 && (
          <div style={{ height: 4, borderRadius: 2, background: '#EEF2F7', marginTop: 5 }}
               title={`${nf.format(m.hours_booked)} h of ${nf.format(members.reduce((s, x) => s + x.hours_booked, 0))} h on this project`}>
            <div style={{ height: '100%', borderRadius: 2, background: ACCENT,
                          width: `${Math.max(3, (m.hours_booked / maxHours) * 100)}%` }} />
          </div>
        )}
      </td>
      <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
        {m.is_current && (
          <span style={{ display: 'inline-flex', gap: 10 }}>
            {mayEdit && (
              <button type="button" disabled={busy} onClick={() => openEdit(m)} title="Edit this assignment"
                style={{ border: 0, background: 'transparent', cursor: 'pointer', color: INK_MUTED, padding: 2 }}>
                <i className="fa-solid fa-pen" />
              </button>
            )}
            {mayDelete && (
              <button type="button" disabled={busy}
                onClick={() => setConfirm(confirmId === m.id ? null : m.id)}
                title={m.has_hours ? 'End this assignment' : 'Remove from the project'}
                style={{ border: 0, background: 'transparent', cursor: 'pointer', padding: 2,
                         color: confirmId === m.id ? DANGER : INK_MUTED }}>
                <i className={m.has_hours || !allowHardDelete ? 'fa-solid fa-user-minus' : 'fa-solid fa-trash'} />
              </button>
            )}
          </span>
        )}
      </td>
    </tr>
  );

  const confirmRow = (m: TeamMember) => (
    <tr key={`${m.id}-c`}>
      <td colSpan={7} style={{ background: '#FFF7F5', borderTop: '1px solid #FBD5CD' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
                      padding: '4px 0', fontSize: 13, color: '#7A271A' }}>
          <span>
            {m.has_hours
              ? <><strong>{m.employee_name}</strong> has booked {nf.format(m.hours_booked)} h to this project,
                  so the assignment is <strong>end-dated today</strong> — past timesheets stay valid and the
                  hours stay in the project report.
                  {allowHardDelete && (
                    <> To remove the assignment outright instead, clear those entries from{' '}
                      <a href={`/timesheet/${m.employee_id}`} style={{ color: DANGER, fontWeight: 600 }}>
                        their timesheet
                      </a>{' '}first — deleting it while the hours exist would leave them booked to a project
                      nobody is on.</>
                  )}</>
              : <><strong>{m.employee_name}</strong> has booked no time here, so the assignment is
                  <strong> removed entirely</strong>.</>}
          </span>
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
            <button type="button" disabled={busy} onClick={() => setConfirm(null)}
              style={{ border: `1px solid ${LINE}`, background: '#fff', borderRadius: 6,
                       padding: '4px 12px', fontSize: 12, cursor: 'pointer', color: INK_SOFT }}>Cancel</button>
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

  return (
    <div>
      {toast && (
        <div style={{ marginBottom: 12, padding: '9px 14px', borderRadius: 8, fontSize: 13,
                      background: '#DCFAE6', border: '1px solid #A6F4C5', color: '#0a6b34' }}>
          <i className="fa-solid fa-circle-check" /> {toast}
        </div>
      )}
      {error && (
        <div style={{ marginBottom: 12, padding: '9px 14px', borderRadius: 8, fontSize: 13,
                      background: '#FEF3F2', border: '1px solid #FDA29B', color: '#7A271A' }}>
          <i className="fa-solid fa-circle-exclamation" /> {error}
        </div>
      )}

      {mode.kind !== 'idle' && (
        <MemberForm
          heading={mode.kind === 'add' ? 'Add to the team' : 'Edit assignment'}
          subtitle={mode.kind === 'add' ? projectName : `${mode.member.employee_name} · ${mode.member.employee_code} — ${projectName}`}
          isAdd={mode.kind === 'add'}
          projectId={projectId} projectEndDate={projectEndDate}
          roles={roles} busy={busy}
          empName={empName} onPick={(c) => { setEmpId(c.employee_id); setName(`${c.employee_name} · ${c.employee_code}`); }}
          roleId={roleId} setRoleId={setRoleId}
          pct={pct} setPct={setPct} from={from} setFrom={setFrom} to={to} setTo={setTo}
          onSave={() => void save()} onCancel={close}
        />
      )}

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 9 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
          <h3 style={{ fontSize: 14, fontWeight: 700, color: INK, margin: 0 }}>Team Allocation</h3>
          <span style={{ fontSize: 12, color: INK_MUTED }}>
            {live.length} current{past.length ? ` · ${past.length} past` : ''}
          </span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          {past.length > 0 && (
            <button type="button" onClick={() => setShowPast(v => !v)}
              style={{ border: 0, background: 'transparent', font: 'inherit', fontSize: 12.5,
                       color: ACCENT, cursor: 'pointer', padding: 0 }}>
              {showPast ? 'Hide' : 'Show'} past member{past.length === 1 ? '' : 's'}
            </button>
          )}
          {mayCreate && mode.kind === 'idle' && (
            <button type="button" onClick={openAdd}
              style={{ display: 'inline-flex', alignItems: 'center', gap: 7, border: 0,
                       background: ACCENT, color: '#fff', borderRadius: 7, padding: '9px 15px',
                       fontSize: 13, fontWeight: 600, cursor: 'pointer', font: 'inherit' }}>
              <i className="fa-solid fa-user-plus" /> Add member
            </button>
          )}
        </div>
      </div>

      <div className="er-table-wrap er-table-wrap--fluid"
           style={{ background: '#fff', borderRadius: 10, boxShadow: '0 2px 10px rgba(24,52,91,0.07)' }}>
        <table className="er-table">
          <thead>
            <tr>
              {sortable('name', 'Name', 'left')}
              <th>Role</th>
              <th style={{ textAlign: 'right' }}>Percentage</th>
              <th>Start date</th>
              <th>End date</th>
              {sortable('hours', 'Hours', 'right')}
              <th style={{ textAlign: 'right' }} aria-label="Actions" />
            </tr>
          </thead>
          <tbody>
            {live.length === 0 && past.length === 0 ? (
              <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: INK_MUTED, fontSize: 13 }}>
                Nobody on this project yet.{mayCreate ? ' Use Add member to staff the first person.' : ''}
              </td></tr>
            ) : (
              <>
                {live.flatMap(m => confirmId === m.id ? [row(m), confirmRow(m)] : [row(m)])}
                {showPast && past.map(m => row(m))}
              </>
            )}
          </tbody>
        </table>
      </div>

      <p style={{ fontSize: 12, color: INK_MUTED, margin: '10px 0 0', maxWidth: 92, minWidth: '100%', lineHeight: 1.55 }}>
        <strong style={{ color: INK_SOFT }}>Percentage</strong> is how much of that person's time is committed
        to this project — it does not affect their timesheet, which records the hours actually worked. Someone
        who has booked time is <strong style={{ color: INK_SOFT }}>end-dated</strong> rather than deleted, so
        approved timesheets stay valid and their hours stay in the project report.
      </p>
    </div>
  );
}

// ─── The form ─────────────────────────────────────────────────────────────────

function MemberForm(p: {
  heading: string; subtitle: string; isAdd: boolean;
  projectId: string; projectEndDate: string;
  roles: { id: string; value: string }[]; busy: boolean;
  empName: string; onPick: (c: Candidate) => void;
  roleId: string; setRoleId: (v: string) => void;
  pct: string; setPct: (v: string) => void;
  from: string; setFrom: (v: string) => void;
  to: string; setTo: (v: string) => void;
  onSave: () => void; onCancel: () => void;
}) {
  return (
    <div style={{ background: '#fff', border: '1px solid #C9D6EE', borderRadius: 10,
                  boxShadow: '0 4px 18px rgba(24,52,91,0.10)', padding: '18px 20px 20px', marginBottom: 16 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
                    gap: 12, flexWrap: 'wrap', marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
          <h3 style={{ fontSize: 15, fontWeight: 700, color: INK, margin: 0 }}>{p.heading}</h3>
          <span style={{ fontSize: 12.5, color: INK_SOFT }}>{p.subtitle}</span>
        </div>
        <span style={{ fontSize: 11.5, color: '#8A97A8' }}>
          <span style={{ color: DANGER, fontWeight: 700 }}>*</span> all fields required
        </span>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))', gap: 14, marginBottom: 18 }}>
        <div>
          <span style={lbl}>Employee <span style={{ color: DANGER }}>*</span></span>
          {p.isAdd
            ? <EmployeePicker onPick={p.onPick} chosen={p.empName} disabled={p.busy} />
            : <div style={{ ...box, background: '#F4F6FA', color: INK_SOFT, borderColor: LINE }}>{p.empName}</div>}
        </div>

        <div>
          <span style={lbl}>Role <span style={{ color: DANGER }}>*</span></span>
          <select value={p.roleId} disabled={p.busy} style={box}
                  onChange={e => p.setRoleId(e.target.value)}>
            <option value="">— Select —</option>
            {p.roles.map(r => <option key={r.id} value={r.id}>{r.value}</option>)}
          </select>
        </div>

        <div>
          <span style={lbl}>Percentage <span style={{ color: DANGER }}>*</span></span>
          <input type="number" min={1} max={100} value={p.pct} disabled={p.busy} placeholder="e.g. 50"
                 onChange={e => p.setPct(e.target.value)} style={box} />
        </div>

        <div>
          <span style={lbl}>Start date <span style={{ color: DANGER }}>*</span></span>
          <input type="date" value={p.from} disabled={p.busy}
                 onChange={e => p.setFrom(e.target.value)} style={box} />
        </div>

        <div>
          <span style={lbl}>End date <span style={{ color: DANGER }}>*</span></span>
          <input type="date" value={p.to} disabled={p.busy} max={p.projectEndDate}
                 onChange={e => p.setTo(e.target.value)} style={box} />
          <div style={{ fontSize: 11, color: INK_SOFT, marginTop: 5 }}>
            Defaults to the project's end date. You can shorten it, not extend it.
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                    gap: 12, flexWrap: 'wrap', borderTop: '1px solid #EEF2F8', paddingTop: 14 }}>
        <span style={{ fontSize: 11.5, color: '#8A97A8' }}>
          <i className="fa-solid fa-circle-info" style={{ marginRight: 6 }} />
          Hours are recorded on timesheets — they are never entered here.
        </span>
        <span style={{ display: 'flex', gap: 9 }}>
          <button type="button" onClick={p.onCancel} disabled={p.busy}
            style={{ border: `1px solid ${LINE}`, background: '#fff', borderRadius: 7,
                     padding: '9px 18px', fontSize: 13, color: INK_SOFT, cursor: 'pointer', font: 'inherit' }}>
            Cancel
          </button>
          <button type="button" onClick={p.onSave} disabled={p.busy}
            style={{ border: 0, background: ACCENT, color: '#fff', borderRadius: 7,
                     padding: '9px 22px', fontSize: 13, fontWeight: 600, cursor: 'pointer', font: 'inherit' }}>
            {p.busy ? 'Saving…' : 'Save'}
          </button>
        </span>
      </div>
    </div>
  );
}

// ─── Employee picker ──────────────────────────────────────────────────────────

function EmployeePicker({ onPick, chosen, disabled }:
  { onPick: (c: Candidate) => void; chosen: string; disabled: boolean }) {
  const [q, setQ]       = useState('');
  const [hits, setHits] = useState<Candidate[]>([]);
  const [open, setOpen] = useState(false);
  const wrap  = useRef<HTMLDivElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (timer.current) clearTimeout(timer.current);
    if (q.trim().length < 2) return;
    let liveQ = true;
    timer.current = setTimeout(async () => {
      const { data } = await supabase.rpc('staffable_employee_search', { p_query: q.trim() });
      if (!liveQ) return;
      setHits((data as Candidate[]) ?? []);
      setOpen(true);
    }, 300);
    return () => { liveQ = false; if (timer.current) clearTimeout(timer.current); };
  }, [q]);

  useEffect(() => {
    function away(e: MouseEvent) {
      if (wrap.current && !wrap.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', away);
    return () => document.removeEventListener('mousedown', away);
  }, []);

  const shown = q.trim().length >= 2 ? hits : [];

  if (chosen) {
    return (
      <div style={{ ...box, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
        <span>{chosen}</span>
        <button type="button" disabled={disabled} onClick={() => { onPick({ employee_id: '', employee_name: '', employee_code: '' }); setQ(''); }}
          title="Choose somebody else"
          style={{ border: 0, background: 'transparent', cursor: 'pointer', color: INK_MUTED, padding: 0 }}>
          <i className="fa-solid fa-xmark" />
        </button>
      </div>
    );
  }

  return (
    <div ref={wrap} style={{ position: 'relative' }}>
      <input type="text" value={q} disabled={disabled} placeholder="Search a name or employee ID…"
             onChange={e => setQ(e.target.value)} style={box} />
      {open && q.trim().length >= 2 && (
        <ul style={{ position: 'absolute', top: 'calc(100% + 4px)', left: 0, right: 0, zIndex: 30,
                     margin: 0, padding: 4, listStyle: 'none', background: '#fff',
                     border: `1px solid ${LINE}`, borderRadius: 8,
                     boxShadow: '0 8px 24px rgba(24,52,91,0.14)', maxHeight: 240, overflowY: 'auto' }}>
          {shown.length === 0 ? (
            <li style={{ padding: '8px 10px', fontSize: 13, color: '#8A97A8' }}>
              Nobody active matches “{q.trim()}”.
            </li>
          ) : shown.map(c => (
            <li key={c.employee_id}>
              <button type="button" onClick={() => { onPick(c); setOpen(false); }}
                style={{ width: '100%', textAlign: 'left', border: 0, background: 'transparent',
                         cursor: 'pointer', font: 'inherit', fontSize: 13, padding: '8px 10px', borderRadius: 6 }}
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
