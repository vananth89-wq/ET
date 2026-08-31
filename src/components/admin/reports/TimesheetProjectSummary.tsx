/**
 * Project Summary — how each project is doing against what it was given.
 *
 * GRAINED ON THE PROJECT, not the entry. Utilisation answers "where did the
 * hours go"; this answers "is this project inside its budget". The denominator
 * is projects.budget_hours (mig 754), the first denominator in this suite that
 * is genuinely about a project — §8.1b exists because planned_minutes is not.
 *
 * NO PERCENTAGE WITHOUT A BUDGET. A project with budget_hours unset shows its
 * hours and nothing else: no meter, no 0%, no "—%". 0% would rank it as the
 * healthiest thing in the portfolio, which is the exact inversion of the truth,
 * and it sorts last rather than first for the same reason. `No budget set` is a
 * first-class status, because a health view that quietly omits un-budgeted
 * projects is how half the portfolio disappears from a review. Design doc §9.1.
 *
 * NO PER-PROJECT "BILLABLE %". project_type sits on the PROJECT, so a project
 * is entirely one type and its billable share is 100% or 0% — a column carrying
 * no information. The portfolio billable share is in the KPI strip instead.
 *
 * HOURS ARE SCOPED. They arrive through timesheet_headers, so they are the
 * hours of employees the caller may see. A project total here is not
 * necessarily the project total, and the scope badge says so.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../../../lib/supabase';
import MSDropdown from './MSDropdown';
import { Kpi, MonthRange, Pager, PendingFilters, ReportStatus, ScopeBadge } from './reportControls';
import { exportXlsx, fmtHM, fromMonthInput, toDecimalHours, useReportRpc } from './reportShared';
import type { ReportTabProps } from './reportShared';

interface Row {
  project_id: string; project_name: string; active: boolean;
  start_date: string | null; end_date: string | null;
  type_ref: string | null; type_label: string | null;
  manager_id: string | null; manager_name: string | null; manager_code: string | null;
  recorded_minutes: number; entry_count: number; contributor_count: number;
  months_active: number; first_entry: string | null; last_entry: string | null;
  budget_hours: number | null; consumed_pct: number | null;
  status: 'on_track' | 'near_budget' | 'over_budget' | 'no_budget';
  /** mig 770. Optional so a bundle live against a pre-770 database degrades to
   *  "no badge" rather than a type error. */
  i_manage?: boolean;
  /** mig 810. Hours given to this project by people not staffed on it. Reported
   *  beside the project's own hours and deliberately absent from
   *  recorded_minutes and consumed_pct — help does not consume a budget it was
   *  never planned into. Optional for the same reason as i_manage. */
  support_minutes?: number;
  support_contributors?: number;
}
interface Payload {
  ok: boolean; page: number; page_size: number; total_rows: number; sort: string;
  totals: {
    recorded_minutes: number; billable_minutes: number; internal_minutes: number;
    overhead_minutes: number; unclassified_minutes: number;
    project_count: number; contributor_count: number;
    budgeted_projects: number; unclassified_projects: number;
    over_budget_projects: number; unmanaged_projects: number;
    /** mig 810. Never part of recorded_minutes or any share taken from it. */
    support_minutes?: number; supported_projects?: number;
  };
  scope: { mode?: string; employee_count?: number | null };
  /** mig 770. Present only once the PM path is deployed. */
  pm?: { is_manager: boolean; managed_projects: number };
  rows: Row[];
}
interface Opt { value: string; label: string; }

const HEADER_STATUS: Opt[] = [
  { value: 'to_be_submitted', label: 'To be submitted' },
  { value: 'to_be_approved',  label: 'To be approved'  },
  { value: 'approved',        label: 'Approved'        },
];

const SORTS: Opt[] = [
  { value: 'hours',    label: 'Hours recorded' },
  { value: 'consumed', label: 'Budget consumed' },
  { value: 'budget',   label: 'Budget size' },
  { value: 'name',     label: 'Project name' },
];

/**
 * The reserved status palette from reportShared — same fills the compliance
 * status bar uses, so a colour means the same thing across the whole suite.
 * These are validated for CVD separation and contrast; do not substitute.
 */
const STATUS_META: Record<Row['status'], { label: string; fill: string; tint: string; ink: string }> = {
  on_track:    { label: 'On track',      fill: '#0ca30c', tint: '#E7F8E7', ink: '#0a6b34' },
  near_budget: { label: 'Near budget',   fill: '#c98500', tint: '#FEF0C7', ink: '#8a5a00' },
  over_budget: { label: 'Over budget',   fill: '#d03b3b', tint: '#FEE4E2', ink: '#B42318' },
  no_budget:   { label: 'No budget set', fill: '#6B7280', tint: '#F1F3F6', ink: '#4B5563' },
};

function StatusChip({ status }: { status: Row['status'] }) {
  const m = STATUS_META[status];
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 11.5,
                   fontWeight: 600, color: m.ink, background: m.tint,
                   borderRadius: 999, padding: '3px 9px', whiteSpace: 'nowrap' }}>
      <span aria-hidden="true"
            style={{ width: 7, height: 7, borderRadius: 2, background: m.fill, flex: '0 0 7px' }} />
      {m.label}
    </span>
  );
}

/**
 * The consumption cell. With a budget: a meter capped at 100% of its track, with
 * the true figure in text beside it so an over-run reads as a number even though
 * the bar cannot grow past full. Without one: nothing at all — not an empty
 * track, which invites the eye to read it as zero.
 */
function ConsumedCell({ pct, status }: { pct: number | null; status: Row['status'] }) {
  if (pct === null) {
    return <span style={{ color: '#9CA3AF' }} title="No budget set for this project">—</span>;
  }
  const m = STATUS_META[status];
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, justifyContent: 'flex-end' }}>
      <div style={{ width: 68, height: 8, borderRadius: 4, background: '#EEF2F8', overflow: 'hidden' }}>
        <div style={{ width: `${Math.min(100, pct)}%`, height: '100%', background: m.fill }} />
      </div>
      <span style={{ fontVariantNumeric: 'tabular-nums', minWidth: 46, textAlign: 'right' }}>
        {pct.toFixed(1)}%
      </span>
    </div>
  );
}

function useFilterOptions() {
  const [projs, setProjs] = useState<Opt[]>([]);
  const [types, setTypes] = useState<Opt[]>([]);
  const [emps,  setEmps]  = useState<Opt[]>([]);
  const [depts, setDepts] = useState<Opt[]>([]);

  useEffect(() => {
    let live = true;
    (async () => {
      const [p, t, e, d] = await Promise.all([
        supabase.from('projects').select('id, name').order('name'),
        supabase.from('picklist_values')
          .select('id, value, picklists!inner ( picklist_id )')
          .eq('picklists.picklist_id', 'PROJECT_TYPE')
          .eq('active', true)
          .order('value'),
        supabase.from('employees').select('id, name, employee_id').eq('status', 'Active').order('name').limit(2000),
        supabase.from('departments').select('id, name').is('deleted_at', null).order('name'),
      ]);
      if (!live) return;
      if (!p.error && p.data) setProjs(p.data.map(r => ({ value: r.id, label: r.name })));
      if (!t.error && t.data) setTypes(t.data.map(r => ({ value: r.id, label: r.value })));
      if (!e.error && e.data) setEmps(e.data.map(r => ({ value: r.id, label: `${r.name} (${r.employee_id})` })));
      if (!d.error && d.data) setDepts(d.data.map(r => ({ value: r.id, label: r.name })));
    })();
    return () => { live = false; };
  }, []);

  return { projs, types, emps, depts };
}

export default function TimesheetProjectSummary({ shared, setShared }: ReportTabProps) {
  const { projs, types, emps, depts } = useFilterOptions();
  const { data, loading, error, run } = useReportRpc<Payload>('timesheet_report_project_summary');

  const { from, to, employees: selEmp, depts: selDept } = shared;
  const setFrom = useCallback((v: string)   => setShared({ from: v }),      [setShared]);
  const setTo   = useCallback((v: string)   => setShared({ to: v }),        [setShared]);
  const setEmp  = useCallback((v: string[]) => setShared({ employees: v }), [setShared]);
  const setDept = useCallback((v: string[]) => setShared({ depts: v }),     [setShared]);
  const [selProj, setProj]  = useState<string[]>([]);
  const [selType, setType]  = useState<string[]>([]);
  const [selStat, setStat]  = useState<string[]>([]);
  const [sysRows, setSys]   = useState(false);
  const [sort, setSort]     = useState('hours');
  const [page, setPage]     = useState(1);
  const [pageSize, setSize] = useState(50);

  const filters = useMemo(() => {
    const f: Record<string, unknown> = {
      period_from: fromMonthInput(from),
      period_to:   fromMonthInput(to),
      sort, page, page_size: pageSize,
    };
    if (selEmp.length)  f.employee_ids = selEmp;
    if (selDept.length) f.dept_ids     = selDept;
    if (selProj.length) f.project_ids  = selProj;
    if (selType.length) f.type_ids     = selType;
    if (selStat.length) f.statuses     = selStat;
    if (sysRows)        f.include_system = true;
    return f;
  }, [from, to, selEmp, selDept, selProj, selType, selStat, sysRows, sort, page, pageSize]);

  const filterKey = useMemo(() => {
    const { page: _p, page_size: _s, ...rest } = filters as Record<string, unknown>;
    void _p; void _s;
    return JSON.stringify(rest);
  }, [filters]);
  const [appliedKey, setAppliedKey] = useState<string | null>(null);
  const pending = appliedKey !== null && appliedKey !== filterKey;

  // Paging and sorting re-run immediately; filter edits wait for Apply, so a
  // half-built filter never triggers a query.
  const filtersRef = useRef(filters);
  filtersRef.current = filters;
  const keyRef = useRef(filterKey);
  keyRef.current = filterKey;
  useEffect(() => {
    run(filtersRef.current);
    setAppliedKey(keyRef.current);
  }, [page, pageSize, sort, run]);

  const apply = useCallback(() => {
    setPage(1); run({ ...filters, page: 1 }); setAppliedKey(filterKey);
  }, [filters, run, filterKey]);

  const reset = useCallback(() => {
    setProj([]); setType([]); setStat([]); setSys(false); setPage(1);
    const next: Record<string, unknown> = {
      period_from: fromMonthInput(from), period_to: fromMonthInput(to),
      sort,
      ...(selEmp.length  ? { employee_ids: selEmp } : {}),
      ...(selDept.length ? { dept_ids: selDept }    : {}),
      page: 1, page_size: pageSize,
    };
    run(next);
    const { page: _p, page_size: _s, ...rest } = next;
    void _p; void _s;
    setAppliedKey(JSON.stringify(rest));
  }, [run, pageSize, from, to, selEmp, selDept, sort]);

  /** Export pulls the WHOLE filtered set, never the page. */
  const [exporting, setExporting] = useState(false);
  const doExport = useCallback(async () => {
    setExporting(true);
    try {
      const { data: all, error: err } = await supabase.rpc('timesheet_report_project_summary', {
        p_filters: { ...filters, page: 1, page_size: 500 },
      });
      const p = all as Payload | null;
      if (err || !p?.ok) { window.alert('Export failed. Please retry.'); return; }
      await exportXlsx([
        { name: 'Projects', rows: p.rows.map(r => ({
            Project:      r.project_name,
            Type:         r.type_label ?? 'Not classified',
            Manager:      r.manager_name ? `${r.manager_name} (${r.manager_code})` : '',
            Contributors: r.contributor_count,
            Entries:      r.entry_count,
            Hours:        toDecimalHours(r.recorded_minutes),
            Minutes:      r.recorded_minutes,
            // Its own columns, never folded into Hours. A spreadsheet is where
            // somebody adds up a column without reading the header.
            'Support hours':   toDecimalHours(r.support_minutes ?? 0),
            'Support helpers': r.support_contributors ?? 0,
            // Blank, never 0 — a spreadsheet zero is indistinguishable from a
            // real zero once it leaves this screen.
            'Budget (h)': r.budget_hours ?? '',
            'Consumed %': r.consumed_pct ?? '',
            Status:       STATUS_META[r.status].label,
            'Months active': r.months_active,
            'First entry':   r.first_entry ?? '',
            'Last entry':    r.last_entry ?? '',
          })) },
      ], `project_summary_${from}_${to}.xlsx`);
      if (p.total_rows > p.rows.length) {
        window.alert(`Exported the first ${p.rows.length} of ${p.total_rows} projects — the report caps a single read at 500.`);
      }
    } finally { setExporting(false); }
  }, [filters, from, to]);

  const t = data?.totals;
  const billableShare = t && t.recorded_minutes > 0
    ? `${Math.round((t.billable_minutes / t.recorded_minutes) * 100)}%` : '—';

  return (
    <>
      <div className="er-toolbar">
        <div className="er-filters-row">
          <MonthRange from={from} to={to} onFrom={setFrom} onTo={setTo} />
          {/* Employee and department narrow WHOSE hours land on each project;
              they do not remove projects from the list. A project everyone in
              the filter ignored is still part of the portfolio, and showing it
              at zero is the finding. */}
          <MSDropdown id="p-emp"  icon="fa-user"        label="Employee"     options={emps}         selected={selEmp}  onChange={setEmp} />
          <MSDropdown id="p-dept" icon="fa-sitemap"     label="Department"   options={depts}        selected={selDept} onChange={setDept} />
          <MSDropdown id="p-proj" icon="fa-folder-open" label="Project"      options={projs}        selected={selProj} onChange={setProj} />
          <MSDropdown id="p-type" icon="fa-tags"        label="Project type" options={types}        selected={selType} onChange={setType} />
          <MSDropdown id="p-stat" icon="fa-tag"         label="Sheet status" options={HEADER_STATUS} selected={selStat} onChange={setStat} />
        </div>

        <div className="er-filters-row2">
          <label style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12, color: '#4B5563' }}>
            Sort by
            <select value={sort} onChange={e => { setSort(e.target.value); setPage(1); }}
                    style={{ fontSize: 12, padding: '4px 6px' }}>
              {SORTS.map(s => <option key={s.value} value={s.value}>{s.label}</option>)}
            </select>
          </label>
          <label style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12, color: '#4B5563', cursor: 'pointer' }}>
            <input type="checkbox" checked={sysRows} onChange={e => setSys(e.target.checked)}
                   style={{ width: 14, height: 14, accentColor: '#1D4ED8' }} />
            Include system-generated rows
          </label>
          <button className="er-apply-btn" type="button" onClick={apply}>
            <i className="fa-solid fa-filter" /> Apply Filters
          </button>
          <button className="er-reset-btn" type="button" onClick={reset}>
            <i className="fa-solid fa-rotate-left" /> Reset
          </button>
          <PendingFilters show={pending} onApply={apply} />
          <div style={{ flex: 1 }} />
          <ScopeBadge scope={data?.scope} />
          <span className="er-row-count">{data?.total_rows ?? 0} projects</span>
          <button className="er-export-btn" type="button" onClick={doExport} disabled={exporting || loading}>
            <i className={`fa-solid ${exporting ? 'fa-spinner fa-spin' : 'fa-file-excel'}`} /> Export
          </button>
        </div>
      </div>

      {data && (
        <div style={{ display: 'flex', gap: 12, padding: '16px 20px 4px', flexWrap: 'wrap' }}>
          <Kpi label="Hours recorded" value={fmtHM(t?.recorded_minutes)}
               caption="By the employees you can see" />
          <Kpi label="Billable share" value={billableShare} tone="#0F766E"
               caption={t && t.unclassified_minutes > 0
                 ? `${fmtHM(t.unclassified_minutes)} sits on unclassified projects and counts as not billable`
                 : 'Hours on billable projects, over all hours'} />
          <Kpi label="Projects"     value={String(t?.project_count ?? 0)} />
          <Kpi label="Contributors" value={String(t?.contributor_count ?? 0)}
               caption="Anyone who booked hours to the project" />
          {(t?.support_minutes ?? 0) > 0 && (
            <Kpi label="Support received" value={fmtHM(t?.support_minutes)} tone="#7C3AED"
                 caption={`Help given by people not staffed on the project, across ${t?.supported_projects ?? 0} ${(t?.supported_projects ?? 0) === 1 ? 'project' : 'projects'}. Not counted in hours, budget or billable share.`} />
          )}
          <Kpi label="Over budget"  value={String(t?.over_budget_projects ?? 0)}
               tone={(t?.over_budget_projects ?? 0) > 0 ? '#B42318' : undefined}
               swatch={STATUS_META.over_budget.fill} />
          <Kpi label="No budget"    value={String((t?.project_count ?? 0) - (t?.budgeted_projects ?? 0))}
               swatch={STATUS_META.no_budget.fill}
               caption="Consumption cannot be computed for these" />
        </div>
      )}

      {/* A project manager's hours on their own projects are NOT limited to
          their employee scope (mig 770). Without this line the totals look
          impossible: more hours than the people they can see could have
          recorded, and nothing on screen explaining it. */}
      {data?.pm?.is_manager && (
        <div style={{ padding: '4px 20px 0', fontSize: 11.5, color: '#7c3aed' }}>
          You manage <strong>{data.pm.managed_projects}</strong>{' '}
          project{data.pm.managed_projects === 1 ? '' : 's'} — those rows show
          every hour recorded against them, including by people outside your
          employee scope.{' '}
          {/* The one place a lead is already thinking about their project, so the
              one place worth offering the team list from. */}
          <a href="/my-projects" style={{ color: '#7c3aed', fontWeight: 600 }}>
            Manage the team →
          </a>
        </div>
      )}

      {/* Says what the roll-up does not cover, rather than letting the tiles
          imply the whole portfolio is measured. */}
      {data && t && t.project_count > 0 && t.budgeted_projects < t.project_count && (
        <div style={{ padding: '4px 20px 0', fontSize: 11.5, color: '#8A97A8' }}>
          Budget shown for <strong>{t.budgeted_projects}</strong> of {t.project_count} projects.
          {t.unmanaged_projects > 0 && ` ${t.unmanaged_projects} have no reporting manager.`}
        </div>
      )}

      <ReportStatus loading={loading} error={error}
                    empty={!!data && data.rows.length === 0}
                    emptyText="No projects in this period." />

      {data && data.rows.length > 0 && (
        <>
          <div className="er-table-wrap" style={{ margin: '12px 20px' }}>
            <table className="er-table">
              <thead>
                <tr>
                  <th>Project</th>
                  <th>Type</th>
                  <th>Reporting manager</th>
                  <th style={{ textAlign: 'right' }}>Contributors</th>
                  <th style={{ textAlign: 'right' }}>Hours</th>
                  <th style={{ textAlign: 'right' }} title="Help given by people not staffed on the project. Not counted in Hours or Consumed.">Support</th>
                  <th style={{ textAlign: 'right' }}>Budget (h)</th>
                  <th style={{ textAlign: 'right', minWidth: 160 }}>Consumed</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {data.rows.map(r => (
                  <tr key={r.project_id}>
                    <td>
                      <strong>{r.project_name}</strong>
                      {r.i_manage && (
                        <span title="You are the reporting manager for this project"
                              style={{ marginLeft: 6, fontSize: 10, fontWeight: 700, color: '#7c3aed',
                                       background: '#f3e8ff', border: '1px solid #ddd6fe',
                                       borderRadius: 999, padding: '1px 7px', whiteSpace: 'nowrap' }}>
                          You manage
                        </span>
                      )}
                      {!r.active && <span style={{ color: '#9CA3AF', fontSize: 11 }}> · inactive</span>}
                    </td>
                    <td>{r.type_label ?? <span style={{ color: '#9CA3AF' }}>Not classified</span>}</td>
                    <td>
                      {r.manager_name
                        ? `${r.manager_name} (${r.manager_code})`
                        : r.manager_id
                          ? <span style={{ color: '#9CA3AF' }} title="You do not have access to this employee">Restricted</span>
                          : <span style={{ color: '#9CA3AF' }}>None</span>}
                    </td>
                    <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{r.contributor_count}</td>
                    <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{fmtHM(r.recorded_minutes)}</td>
                    <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
                      {(r.support_minutes ?? 0) > 0
                        ? <span style={{ color: '#7C3AED' }}
                                title={`${r.support_contributors} ${r.support_contributors === 1 ? 'person' : 'people'} not staffed on this project. Not counted in Hours or Consumed.`}>
                            {fmtHM(r.support_minutes)}
                          </span>
                        : <span style={{ color: '#D1D5DB' }}>—</span>}
                    </td>
                    <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
                      {r.budget_hours ?? <span style={{ color: '#9CA3AF' }}>—</span>}
                    </td>
                    <td style={{ textAlign: 'right' }}>
                      <ConsumedCell pct={r.consumed_pct} status={r.status} />
                    </td>
                    <td><StatusChip status={r.status} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <Pager page={data.page} pageSize={data.page_size} total={data.total_rows}
                 onPage={setPage} onPageSize={n => { setSize(n); setPage(1); }} />
        </>
      )}
    </>
  );
}
