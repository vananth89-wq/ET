/**
 * Timesheet Utilisation — where the recorded hours went.
 *
 * One row per timesheet ENTRY. Expanding a row shows its activity rows, which
 * are detail, not arithmetic: since mig 727 the activities are the source of
 * truth for project time and the entry's hours_minutes is a maintained mirror,
 * so adding both together counts the same hours twice. The RPC returns the
 * parent figure and nests the children; this screen must not sum the children.
 *
 * CHARTS COME FROM `breakdowns`, NEVER FROM `rows`. The RPC paginates, so
 * anything drawn from the row set would describe fifty entries while looking
 * like it describes the report. Migs 750 and 752 compute the breakdowns over
 * the whole filtered set, which is what makes the charts safe to draw at all.
 *
 * PLANNED IS NOT PROJECT-SHAPED. `planned_minutes` is one figure per employee
 * per month, so no project, time type or category filter can narrow it. When
 * one of those is applied, Recorded follows the filter and Planned does not,
 * and dividing one by the other produces a percentage of an unrelated whole.
 * Both Planned and the rate are suppressed in that case rather than shown
 * against a denominator nobody asked for. The number people actually want --
 * hours against a project budget -- needs `projects.budget_hours` and belongs
 * in the Project Summary report.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../../../lib/supabase';
import MSDropdown from './MSDropdown';
import { BarRows, Kpi, MonthRange, Pager, PendingFilters, ReportStatus, ScopeBadge, StackedBars }
  from './reportControls';
import { exportXlsx, fmtDate, fmtDayRange, fmtHM, fromMonthInput, toDecimalHours, useReportRpc }
  from './reportShared';
import type { ReportTabProps } from './reportShared';

interface Activity { id: string; activity_name: string; hours_minutes: number; display_order: number; }
interface Row {
  entry_id: string; entry_date: string; period: string;
  employee_id: string; employee_name: string; employee_code: string;
  department_name: string | null; header_id: string; header_status: string;
  project_id: string | null; project_name: string | null;
  time_type_id: string | null; time_type_name: string | null; time_type_code: string | null;
  category: string | null; hours_minutes: number; notes: string | null;
  is_system_generated: boolean; activities: Activity[];
}
interface Breakdowns {
  by_project: { project_id: string | null; label: string; minutes: number }[];
  other_minutes: number;
  other_projects: number;
  // week_end and partial arrive with mig 752. Optional because the frontend
  // deploys through Vercel and the migration through Actions, so this bundle
  // can be live against a database that has not run 752 yet.
  by_week: { week_start: string; week_end?: string; partial?: boolean;
             attendance_minutes: number; absence_minutes: number }[];
}
interface Payload {
  ok: boolean; page: number; page_size: number; total_rows: number;
  totals: { recorded_minutes: number; planned_minutes: number; entry_count: number;
            employee_count: number; project_count: number };
  breakdowns?: Breakdowns;
  scope: { mode?: string; employee_count?: number | null };
  rows: Row[];
}
interface Opt { value: string; label: string; }

const STATUS_OPTIONS: Opt[] = [
  { value: 'to_be_submitted', label: 'To be submitted' },
  { value: 'to_be_approved',  label: 'To be approved'  },
  { value: 'approved',        label: 'Approved'        },
];
const CATEGORY_OPTIONS: Opt[] = [
  { value: 'attendance', label: 'Attendance' },
  { value: 'absence',    label: 'Absence'    },
];

/**
 * Filter options.
 *
 * These are read straight from the reference tables rather than derived from
 * the returned rows: a filter built from the current page can only offer what
 * is already on screen. RLS still applies to each read, so nobody sees a
 * project they could not otherwise see.
 */
function useFilterOptions() {
  const [emps,  setEmps]  = useState<Opt[]>([]);
  const [depts, setDepts] = useState<Opt[]>([]);
  const [projs, setProjs] = useState<Opt[]>([]);
  const [types, setTypes] = useState<Opt[]>([]);

  useEffect(() => {
    let live = true;
    (async () => {
      const [e, d, p, t] = await Promise.all([
        supabase.from('employees').select('id, name, employee_id').eq('status', 'Active').order('name').limit(2000),
        supabase.from('departments').select('id, name').is('deleted_at', null).order('name'),
        supabase.from('projects').select('id, name').eq('active', true).order('name'),
        supabase.from('time_types').select('id, name, category').eq('is_active', true).order('name'),
      ]);
      if (!live) return;
      if (!e.error && e.data) setEmps(e.data.map(r => ({ value: r.id, label: `${r.name} (${r.employee_id})` })));
      if (!d.error && d.data) setDepts(d.data.map(r => ({ value: r.id, label: r.name })));
      if (!p.error && p.data) setProjs(p.data.map(r => ({ value: r.id, label: r.name })));
      if (!t.error && t.data) setTypes(t.data.map(r => ({ value: r.id, label: `${r.name} · ${r.category}` })));
    })();
    return () => { live = false; };
  }, []);

  return { emps, depts, projs, types };
}

export default function TimesheetUtilisation({ shared, setShared }: ReportTabProps) {
  const { emps, depts, projs, types } = useFilterOptions();
  const { data, loading, error, run } = useReportRpc<Payload>('timesheet_report_utilisation');

  // Period, employee and department live in the shell so they survive a tab
  // switch. Everything below them is only meaningful here.
  const { from, to, employees: selEmp, depts: selDept } = shared;
  const setFrom = useCallback((v: string)   => setShared({ from: v }),      [setShared]);
  const setTo   = useCallback((v: string)   => setShared({ to: v }),        [setShared]);
  const setEmp  = useCallback((v: string[]) => setShared({ employees: v }), [setShared]);
  const setDept = useCallback((v: string[]) => setShared({ depts: v }),     [setShared]);
  const [selProj, setProj]  = useState<string[]>([]);
  const [selType, setType]  = useState<string[]>([]);
  const [selCat, setCat]    = useState<string[]>([]);
  const [selStat, setStat]  = useState<string[]>([]);
  const [sysRows, setSys]   = useState(false);
  const [page, setPage]     = useState(1);
  const [pageSize, setSize] = useState(50);
  const [open, setOpen]     = useState<Record<string, boolean>>({});

  const filters = useMemo(() => {
    const f: Record<string, unknown> = {
      period_from: fromMonthInput(from),
      period_to:   fromMonthInput(to),
      page, page_size: pageSize,
    };
    if (selEmp.length)  f.employee_ids  = selEmp;
    if (selDept.length) f.dept_ids      = selDept;
    if (selProj.length) f.project_ids   = selProj;
    if (selType.length) f.time_type_ids = selType;
    if (selCat.length)  f.categories    = selCat;
    if (selStat.length) f.statuses      = selStat;
    if (sysRows)        f.include_system = true;
    return f;
  }, [from, to, selEmp, selDept, selProj, selType, selCat, selStat, sysRows, page, pageSize]);

  // Paging re-runs immediately; filter edits wait for Apply, so a half-built
  // filter never triggers a query.
  // Same pending-filter signal as Compliance. This tab has more filters, not
  // fewer, so it needs it more -- and a report that tells you filters are
  // waiting on one tab and stays silent on the other is the inconsistency this
  // whole module was reorganised to avoid.
  //
  // Compared as a serialised key rather than field by field: this toolbar has
  // seven controls and a hand-written comparison would fall out of step with
  // them the first time an eighth is added.
  const filterKey = useMemo(() => {
    const { page: _p, page_size: _s, ...rest } = filters as Record<string, unknown>;
    void _p; void _s;
    return JSON.stringify(rest);
  }, [filters]);
  const [appliedKey, setAppliedKey] = useState<string | null>(null);
  const pending = appliedKey !== null && appliedKey !== filterKey;

  // Project, time type and category filter ENTRIES; everything else filters
  // HEADERS. Planned lives on the header, so only these three can pull Recorded
  // away from Planned and leave the ratio measuring nothing.
  //
  // Read from appliedKey rather than from the controls: this describes the
  // numbers currently on screen, not the ones the toolbar would fetch next.
  const entryFiltered = useMemo(() => {
    if (!appliedKey) return false;
    try {
      const f = JSON.parse(appliedKey) as Record<string, unknown>;
      return !!(f.project_ids || f.time_type_ids || f.categories);
    } catch { return false; }
  }, [appliedKey]);

  // Filters are read through a ref so this effect can declare every
  // dependency it actually has. Editing a filter must NOT fire a query --
  // that waits for Apply -- but changing the page or the page size must,
  // and both are covered by this one effect, which also runs on mount.
  const filtersRef = useRef(filters);
  filtersRef.current = filters;
  const keyRef = useRef(filterKey);
  keyRef.current = filterKey;
  useEffect(() => {
    run(filtersRef.current);
    setAppliedKey(keyRef.current);
  }, [page, pageSize, run]);

  const apply = useCallback(() => {
    setPage(1); run({ ...filters, page: 1 }); setAppliedKey(filterKey);
  }, [filters, run, filterKey]);
  // Reset clears this tab's filters but LEAVES the shared period, employee and
  // department alone. They are the context you switched tabs carrying; wiping
  // them from inside one tab would undo the other tab's screen too.
  const reset = useCallback(() => {
    setProj([]); setType([]); setCat([]); setStat([]); setSys(false); setPage(1);
    const next: Record<string, unknown> = {
      period_from: fromMonthInput(from), period_to: fromMonthInput(to),
      ...(selEmp.length  ? { employee_ids: selEmp } : {}),
      ...(selDept.length ? { dept_ids: selDept }    : {}),
      page: 1, page_size: pageSize,
    };
    run(next);
    const { page: _p, page_size: _s, ...rest } = next;
    void _p; void _s;
    setAppliedKey(JSON.stringify(rest));
  }, [run, pageSize, from, to, selEmp, selDept]);

  /**
   * Export pulls the WHOLE filtered set, not the page. A spreadsheet that
   * silently contains 50 of 4,000 rows is worse than no spreadsheet, because
   * nothing on the page says which 50.
   */
  const [exporting, setExporting] = useState(false);
  const doExport = useCallback(async () => {
    setExporting(true);
    try {
      const { data: all, error: err } = await supabase.rpc('timesheet_report_utilisation', {
        p_filters: { ...filters, page: 1, page_size: 500 },
      });
      if (err) { window.alert(`Export failed: ${err.message}`); return; }
      const p = all as unknown as Payload;
      const rows = p?.rows ?? [];

      await exportXlsx([
        { name: 'Entries', rows: rows.map(r => ({
            Date: r.entry_date, Employee: r.employee_name, 'Employee ID': r.employee_code,
            Department: r.department_name ?? '', Project: r.project_name ?? '',
            'Time type': r.time_type_name ?? '', Category: r.category ?? '',
            Hours: toDecimalHours(r.hours_minutes), Minutes: r.hours_minutes,
            Activities: r.activities.length, Status: r.header_status, Notes: r.notes ?? '',
          })) },
        { name: 'Activities', rows: rows.flatMap(r => r.activities.map(a => ({
            Date: r.entry_date, Employee: r.employee_name, Project: r.project_name ?? '',
            Activity: a.activity_name, Hours: toDecimalHours(a.hours_minutes), Minutes: a.hours_minutes,
          }))) },
      ], `timesheet_utilisation_${from}_${to}.xlsx`);

      if (p.total_rows > rows.length) {
        window.alert(`Exported the first ${rows.length} of ${p.total_rows} rows — the report caps a single read at 500. Narrow the period or the filters to export the rest.`);
      }
    } finally { setExporting(false); }
  }, [filters, from, to]);

  const t = data?.totals;
  const util = t && t.planned_minutes > 0
    ? `${Math.round((t.recorded_minutes / t.planned_minutes) * 100)}%` : '—';

  return (
    <>
      <div className="er-toolbar">
        <div className="er-filters-row">
          <MonthRange from={from} to={to} onFrom={setFrom} onTo={setTo} />
          <MSDropdown id="u-emp"  icon="fa-user"        label="Employee"   options={emps}            selected={selEmp}  onChange={setEmp} />
          <MSDropdown id="u-dept" icon="fa-sitemap"     label="Department" options={depts}           selected={selDept} onChange={setDept} />
          <MSDropdown id="u-proj" icon="fa-folder-open" label="Project"    options={projs}           selected={selProj} onChange={setProj} />
          <MSDropdown id="u-type" icon="fa-clock"       label="Time type"  options={types}           selected={selType} onChange={setType} />
          <MSDropdown id="u-cat"  icon="fa-layer-group" label="Category"   options={CATEGORY_OPTIONS} selected={selCat}  onChange={setCat} />
          <MSDropdown id="u-stat" icon="fa-tag"         label="Status"     options={STATUS_OPTIONS}   selected={selStat} onChange={setStat} />
        </div>

        <div className="er-filters-row2">
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
          <span className="er-row-count">{data?.total_rows ?? 0} rows</span>
          <button className="er-export-btn" type="button" onClick={doExport} disabled={exporting || loading}>
            <i className={`fa-solid ${exporting ? 'fa-spinner fa-spin' : 'fa-file-excel'}`} /> Export
          </button>
        </div>
      </div>

      {data && (
        <div style={{ display: 'flex', gap: 12, padding: '16px 20px 4px', flexWrap: 'wrap' }}>
          <Kpi label="Recorded" value={fmtHM(t?.recorded_minutes)}
               caption={entryFiltered ? 'Hours matching the current filter' : undefined} />
          <Kpi label="Planned" value={entryFiltered ? '\u2014' : fmtHM(t?.planned_minutes)}
               caption={entryFiltered
                 ? 'Planned hours are set per employee per month, never per project. Clear the project, time type and category filters to see them.'
                 : undefined} />
          <Kpi label="Recording rate" value={entryFiltered ? '\u2014' : util}
               tone={entryFiltered ? undefined : '#0F766E'}
               caption={entryFiltered
                 ? 'Needs a planned figure to divide by. Project budgets live in the Project Summary report.'
                 : 'Recorded against planned, for everyone in scope'} />
          <Kpi label="Entries"     value={String(t?.entry_count ?? 0)} />
          <Kpi label="Employees"   value={String(t?.employee_count ?? 0)} />
          <Kpi label="Projects"    value={String(t?.project_count ?? 0)} />
        </div>
      )}

      {/* Fed from `breakdowns`, which mig 750 computes over the WHOLE filtered
          set. Drawn from `rows` these would describe fifty entries while
          looking like they describe the report — which is why this screen
          shipped without charts until the RPC could answer properly. */}
      {!loading && !error && data?.breakdowns && data.total_rows > 0 && (
        <div style={{ display: 'grid', gap: 12, padding: '4px 20px 0',
                      gridTemplateColumns: 'repeat(auto-fit, minmax(330px, 1fr))' }}>
          <BarRows
            title="Hours by project"
            format={fmtHM}
            note={data.breakdowns.other_projects > 0
              ? `“Other” folds ${data.breakdowns.other_projects} further project${data.breakdowns.other_projects === 1 ? '' : 's'}. Filter by project to see them individually.`
              : undefined}
            data={[
              ...data.breakdowns.by_project.map(b => ({ label: b.label, value: b.minutes })),
              ...(data.breakdowns.other_minutes > 0
                ? [{ label: 'Other', value: data.breakdowns.other_minutes, muted: true }]
                : []),
            ]}
          />
          {/* Buckets are clipped to the reported period by mig 752, so a bar
              labelled 1-5 Jul holds exactly those days. Part-weeks at the
              edges are short by construction and are greyed rather than left
              to read as a collapse in recording. Weeks with nothing recorded
              come back as zero bars, not as gaps. */}
          <StackedBars
            title="By week"
            aLabel="Attendance" bLabel="Absence"
            format={fmtHM}
            note={data.breakdowns.by_week.some(w => w.partial)
              ? 'Greyed weeks are part-weeks at the edge of the period \u2014 fewer days, not less recording.'
              : undefined}
            data={data.breakdowns.by_week.map(w => ({
              label: w.week_end
                ? fmtDayRange(w.week_start, w.week_end)
                : `w/c ${fmtDate(w.week_start).slice(0, 6)}`,
              a: w.attendance_minutes,
              b: w.absence_minutes,
              muted: !!w.partial,
            }))}
          />
        </div>
      )}

      <ReportStatus loading={loading} error={error}
                    empty={!!data && data.rows.length === 0}
                    emptyText="No timesheet entries match these filters." />

      {!loading && !error && data && data.rows.length > 0 && (
        <div style={{ overflow: 'auto', maxHeight: 'calc(100vh - 460px)', minHeight: 200,
                      background: '#fff', margin: '12px 20px 0', borderRadius: 12,
                      boxShadow: '0 4px 16px rgba(24,52,91,0.08)' }}>
          <table className="er-table" style={{ width: '100%' }}>
            <thead style={{ position: 'sticky', top: 0, zIndex: 10 }}>
              <tr>
                <th style={{ width: 34 }} />
                <th style={{ whiteSpace: 'nowrap' }}>Date</th>
                <th style={{ minWidth: 170 }}>Employee</th>
                <th style={{ whiteSpace: 'nowrap' }}>Department</th>
                <th style={{ whiteSpace: 'nowrap' }}>Project</th>
                <th style={{ whiteSpace: 'nowrap' }}>Time type</th>
                <th className="er-th-amt" style={{ whiteSpace: 'nowrap' }}>Hours</th>
                <th style={{ textAlign: 'center', whiteSpace: 'nowrap' }}>Activities</th>
                <th style={{ textAlign: 'center', whiteSpace: 'nowrap' }}>Status</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map(r => {
                const isOpen = !!open[r.entry_id];
                const hasKids = r.activities.length > 0;
                return [
                  <tr key={r.entry_id} className="er-row">
                    <td style={{ textAlign: 'center' }}>
                      {hasKids && (
                        <button type="button"
                                aria-label={isOpen ? 'Hide activities' : 'Show activities'}
                                onClick={() => setOpen(o => ({ ...o, [r.entry_id]: !o[r.entry_id] }))}
                                style={{ border: 'none', background: 'none', cursor: 'pointer', color: '#64748b' }}>
                          <i className={`fa-solid fa-chevron-${isOpen ? 'down' : 'right'}`} style={{ fontSize: 11 }} />
                        </button>
                      )}
                    </td>
                    <td className="er-td-date">{fmtDate(r.entry_date)}</td>
                    <td>
                      <div className="er-emp-info">
                        <span className="er-emp-name">{r.employee_name}</span>
                        <span className="er-emp-id">{r.employee_code}</span>
                      </div>
                    </td>
                    <td style={{ whiteSpace: 'nowrap' }}>{r.department_name ?? '—'}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>{r.project_name ?? '—'}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>
                      {r.time_type_name ?? '—'}
                      {r.category === 'absence' && (
                        <span style={{ marginLeft: 6, fontSize: 10, color: '#7C3AED',
                                       background: '#F3E8FF', borderRadius: 4, padding: '1px 5px' }}>absence</span>
                      )}
                      {r.is_system_generated && (
                        <span style={{ marginLeft: 6, fontSize: 10, color: '#64748B',
                                       background: '#F1F5F9', borderRadius: 4, padding: '1px 5px' }}>system</span>
                      )}
                    </td>
                    <td className="er-td-amt" style={{ whiteSpace: 'nowrap' }}>{fmtHM(r.hours_minutes)}</td>
                    <td style={{ textAlign: 'center', color: hasKids ? '#334155' : '#CBD5E1' }}>
                      {hasKids ? r.activities.length : '—'}
                    </td>
                    <td style={{ textAlign: 'center' }}>
                      <span className="er-status-badge">{r.header_status.replace(/_/g, ' ')}</span>
                    </td>
                  </tr>,
                  isOpen && (
                    <tr key={`${r.entry_id}-a`}>
                      <td />
                      <td colSpan={8} style={{ background: '#F8FAFC', padding: '8px 14px' }}>
                        {r.activities.map(a => (
                          <div key={a.id} style={{ display: 'flex', gap: 12, fontSize: 12,
                                                   color: '#475569', padding: '3px 0' }}>
                            <span style={{ minWidth: 240 }}>{a.activity_name}</span>
                            <strong>{fmtHM(a.hours_minutes)}</strong>
                          </div>
                        ))}
                      </td>
                    </tr>
                  ),
                ];
              })}
            </tbody>
          </table>
        </div>
      )}

      <div className="er-footer" style={{ display: 'flex', justifyContent: 'space-between',
                                          alignItems: 'center', padding: '10px 20px', margin: '0 20px 24px',
                                          background: '#fff', borderTop: '1px solid #e8eef5',
                                          borderRadius: '0 0 12px 12px' }}>
        <Pager page={page} pageSize={pageSize} total={data?.total_rows ?? 0}
               onPage={setPage} onPageSize={setSize} />
        <div style={{ fontSize: 12, color: '#4a5568' }}>
          Total recorded: <strong>{fmtHM(t?.recorded_minutes)}</strong>
        </div>
      </div>
    </>
  );
}
