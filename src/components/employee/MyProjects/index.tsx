/**
 * My Projects — a project lead staffs the projects they are Reporting Manager on.
 *
 * WHY EVERY READ HERE IS AN RPC AND NOT A TABLE QUERY
 *   A lead holds the Team Allocation verbs and, typically, nothing else. That
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
 * WHAT THIS FILE IS, AND IS NOT
 *   It is the lead's SHELL: which projects are mine, and the header for the one
 *   I am looking at. The team table and its editor are <TeamAllocation>, shared
 *   with Admin → Projects → Team. Two copies of a screen this rule-heavy would
 *   diverge within a month.
 */

import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../../lib/supabase';
import TeamAllocation from '../../shared/TeamAllocation';

interface StaffableProject {
  project_id: string; project_name: string;
  project_type: string | null;
  start_date: string | null; end_date: string;
  budget_hours: number | null; hours_booked: number;
  current_members: number; past_members: number;
}

const INK = '#18345B', INK_SOFT = '#6B7280', INK_MUTED = '#9CA3AF';
const ACCENT = '#2B54CE', WARN = '#B54708';

const nf = new Intl.NumberFormat('en', { maximumFractionDigits: 1 });

function fmt(d: string | null): string {
  if (!d) return '—';
  const dt = new Date(d + 'T00:00:00');
  return isNaN(dt.getTime()) ? d
    : `${String(dt.getDate()).padStart(2, '0')} ${dt.toLocaleString('en', { month: 'short' })} ${dt.getFullYear()}`;
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div style={{ fontSize: 10, letterSpacing: 0.6, textTransform: 'uppercase',
                    color: '#8A97A8', fontWeight: 700, marginBottom: 3 }}>{label}</div>
      <div style={{ fontSize: 14, color: INK, fontWeight: 600 }}>{value}</div>
    </div>
  );
}

/**
 * Four facts and, when a budget exists, one meter. Deliberately not a chart: a
 * single magnitude against a single target is a stat, and a stat reads faster
 * than any plot of it. The meter turns amber only past 100% and never carries
 * that meaning in colour alone — the caption says it in words.
 */
function ProjectHeader({ p }: { p: StaffableProject }) {
  const budget = p.budget_hours ?? 0;
  const pct    = budget > 0 ? (p.hours_booked / budget) * 100 : null;
  const over   = pct !== null && pct > 100;

  return (
    <div style={{ background: '#fff', borderRadius: 10, padding: '16px 18px', marginBottom: 14,
                  boxShadow: '0 2px 10px rgba(24,52,91,0.07)' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap', marginBottom: 14 }}>
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
            <div style={{ height: '100%', borderRadius: 3, width: `${Math.min(pct, 100)}%`,
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

export default function MyProjects() {
  const [projects, setProjects] = useState<StaffableProject[]>([]);
  const [sel, setSel]           = useState<string | null>(null);
  const [loading, setLoading]   = useState(true);
  const [tick, setTick]         = useState(0);

  useEffect(() => {
    let live = true;
    (async () => {
      const { data } = await supabase.rpc('my_staffable_projects_detail');
      if (!live) return;
      const rows = (data as StaffableProject[]) ?? [];
      setProjects(rows);
      setSel(prev => (prev && rows.some(r => r.project_id === prev)) ? prev : rows[0]?.project_id ?? null);
      setLoading(false);
    })();
    return () => { live = false; };
  }, [tick]);

  // The team component writes; the header counts and hours are ours to re-read.
  const refresh = useCallback(() => setTick(t => t + 1), []);

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
        <h1 style={{ fontSize: 20, color: INK, margin: '0 0 8px' }}>My Projects</h1>
        <p style={{ fontSize: 14, color: '#4B5563', lineHeight: 1.6 }}>
          No active project lists you as the Reporting Manager, so there is nothing to staff here.
          An administrator sets that on <strong>Admin → Projects</strong>, per project.
        </p>
      </div>
    );
  }

  return (
    <div style={{ padding: '28px 24px', maxWidth: 1280 }}>
      <h1 style={{ fontSize: 20, color: INK, margin: '0 0 4px' }}>My Projects</h1>
      <p style={{ fontSize: 13, color: INK_SOFT, margin: '0 0 18px' }}>
        Who is on the projects you manage. Adding someone does not give you access to their
        data — it records that they are on the project.
      </p>

      {/* Tabs, not a left rail: with an editor panel above the table, a rail is a
          second starting point for the eye and costs the form 250px. One project
          is not a choice, so it does not get a chooser — the header names it. */}
      {projects.length > 1 && (
        <div style={{ display: 'flex', gap: 6, borderBottom: '1px solid #E3E9F2',
                      marginBottom: 18, overflowX: 'auto' }}>
          {projects.map(p => {
            const on = p.project_id === sel;
            return (
              <button key={p.project_id} type="button" onClick={() => setSel(p.project_id)}
                style={{ display: 'flex', alignItems: 'baseline', gap: 8, whiteSpace: 'nowrap',
                         border: 0, background: 'transparent', cursor: 'pointer', font: 'inherit',
                         padding: '9px 16px', fontSize: 13.5, fontWeight: on ? 600 : 500,
                         color: on ? INK : INK_SOFT,
                         borderBottom: `2px solid ${on ? ACCENT : 'transparent'}` }}>
                {p.project_name}
                <span style={{ fontSize: 11, fontWeight: 500, color: on ? '#8A97A8' : INK_MUTED }}>
                  {p.current_members}{p.hours_booked > 0 ? ` · ${nf.format(p.hours_booked)} h` : ''}
                </span>
              </button>
            );
          })}
        </div>
      )}

      {current && (
        <>
          <ProjectHeader p={current} />
          {/* key: remounting per project is what clears a half-typed row, and it
              cannot be forgotten the way a reset effect can. */}
          <TeamAllocation
            key={current.project_id}
            projectId={current.project_id}
            projectName={current.project_name}
            projectEndDate={current.end_date}
            onChanged={refresh}
          />
        </>
      )}
    </div>
  );
}
