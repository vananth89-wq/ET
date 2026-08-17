/**
 * Timesheet Compliance — who has and has not submitted.
 *
 * One row per (employee, period), produced by an RPC that starts from EMPLOYEES
 * and left-joins headers. That is the whole reason this is a separate report
 * from Utilisation: an employee who logged nothing has no entries and no
 * header, so an entry-grain report has no row to show for them, and they are
 * exactly the person this screen is for.
 *
 * The five states:
 *   not_configured   employed, but no work schedule — cannot legitimately log
 *                    anything, so this is a configuration error, not lateness
 *   not_started      expected, no timesheet at all
 *   to_be_submitted  started, not sent
 *   to_be_approved   sent, waiting on an approver
 *   approved         done
 *
 * Someone with no employment overlapping the period does not appear at all.
 * A leaver is not late.
 *
 * The due date comes from time_submission_config via time_submission_due_date(),
 * so this screen and any future reminder cron cannot drift apart.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../../../lib/supabase';
import MSDropdown from './MSDropdown';
import { Kpi, MonthRange, Pager, ReportHeader, ReportStatus, ScopeBadge } from './reportControls';
import { exportXlsx, fmtDate, fmtHM, fmtPeriod, fromMonthInput, lastMonthInput, toDecimalHours, useReportRpc } from './reportShared';

interface Row {
  employee_id: string; employee_name: string; employee_code: string;
  manager_name: string | null; department_name: string | null; schedule_name: string | null;
  period: string; state: string; header_id: string | null; header_status: string | null;
  planned_minutes: number; recorded_minutes: number; variance_minutes: number;
  days_with_entries: number; submitted_at: string | null; approved_at: string | null;
  due_date: string; is_overdue: boolean; days_past_due: number;
  changes_since_approval: number | null; workflow_instance_id: string | null;
}
interface Payload {
  ok: boolean; page: number; page_size: number; total_rows: number;
  summary: { expected: number; not_configured: number; not_started: number;
             to_be_submitted: number; to_be_approved: number; approved: number;
             overdue: number; planned_minutes: number; recorded_minutes: number };
  scope: { mode?: string; employee_count?: number | null };
  rows: Row[];
}
interface Opt { value: string; label: string; }

const STATE_OPTIONS: Opt[] = [
  { value: 'not_configured',  label: 'Not configured'  },
  { value: 'not_started',     label: 'Not started'     },
  { value: 'to_be_submitted', label: 'To be submitted' },
  { value: 'to_be_approved',  label: 'To be approved'  },
  { value: 'approved',        label: 'Approved'        },
];

const STATE_STYLE: Record<string, { bg: string; fg: string; label: string; icon: string }> = {
  not_configured:  { bg: '#FEF3C7', fg: '#92400E', label: 'Not configured',  icon: 'fa-gear'          },
  not_started:     { bg: '#FEE2E2', fg: '#991B1B', label: 'Not started',     icon: 'fa-circle-minus'  },
  to_be_submitted: { bg: '#FEF9C3', fg: '#854D0E', label: 'To be submitted', icon: 'fa-pen'           },
  to_be_approved:  { bg: '#DBEAFE', fg: '#1E40AF', label: 'To be approved',  icon: 'fa-hourglass-half'},
  approved:        { bg: '#DCFCE7', fg: '#166534', label: 'Approved',        icon: 'fa-circle-check'  },
};

function StateBadge({ state }: { state: string }) {
  const s = STATE_STYLE[state] ?? { bg: '#F1F5F9', fg: '#475569', label: state, icon: 'fa-circle' };
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, background: s.bg, color: s.fg,
                   borderRadius: 6, padding: '3px 9px', fontSize: 11.5, fontWeight: 600, whiteSpace: 'nowrap' }}>
      <i className={`fa-solid ${s.icon}`} style={{ fontSize: 10 }} /> {s.label}
    </span>
  );
}

function useFilterOptions() {
  const [emps,  setEmps]  = useState<Opt[]>([]);
  const [depts, setDepts] = useState<Opt[]>([]);
  useEffect(() => {
    let live = true;
    (async () => {
      const [e, d] = await Promise.all([
        supabase.from('employees').select('id, name, employee_id').eq('status', 'Active').order('name').limit(2000),
        supabase.from('departments').select('id, name').is('deleted_at', null).order('name'),
      ]);
      if (!live) return;
      if (!e.error && e.data) setEmps(e.data.map(r => ({ value: r.id, label: `${r.name} (${r.employee_id})` })));
      if (!d.error && d.data) setDepts(d.data.map(r => ({ value: r.id, label: r.name })));
    })();
    return () => { live = false; };
  }, []);
  return { emps, depts };
}

export default function TimesheetCompliance({ onBack }: { onBack: () => void }) {
  const { emps, depts } = useFilterOptions();
  const { data, loading, error, run } = useReportRpc<Payload>('timesheet_report_compliance');

  // Defaults to LAST month, not this one. The current month is not late yet,
  // so opening on it shows a screen of red that means nothing.
  const lastMonth = useMemo(() => lastMonthInput(), []);

  const [from, setFrom]      = useState(lastMonth);
  const [to, setTo]          = useState(lastMonth);
  const [selEmp, setEmp]     = useState<string[]>([]);
  const [selDept, setDept]   = useState<string[]>([]);
  const [selState, setState] = useState<string[]>([]);
  const [onlyLate, setLate]  = useState(false);
  const [page, setPage]      = useState(1);
  const [pageSize, setSize]  = useState(50);

  const filters = useMemo(() => {
    const f: Record<string, unknown> = {
      period_from: fromMonthInput(from), period_to: fromMonthInput(to),
      page, page_size: pageSize,
    };
    if (selEmp.length)   f.employee_ids = selEmp;
    if (selDept.length)  f.dept_ids     = selDept;
    if (selState.length) f.states       = selState;
    if (onlyLate)        f.only_overdue = true;
    return f;
  }, [from, to, selEmp, selDept, selState, onlyLate, page, pageSize]);

  // Filters are read through a ref so this effect can declare every
  // dependency it actually has. Editing a filter must NOT fire a query --
  // that waits for Apply -- but changing the page or the page size must,
  // and both are covered by this one effect, which also runs on mount.
  const filtersRef = useRef(filters);
  filtersRef.current = filters;
  useEffect(() => { run(filtersRef.current); }, [page, pageSize, run]);

  const apply = useCallback(() => { setPage(1); run({ ...filters, page: 1 }); }, [filters, run]);
  const reset = useCallback(() => {
    setEmp([]); setDept([]); setState([]); setLate(false);
    setFrom(lastMonth); setTo(lastMonth); setPage(1);
    run({ period_from: fromMonthInput(lastMonth), period_to: fromMonthInput(lastMonth), page: 1, page_size: pageSize });
  }, [run, pageSize, lastMonth]);

  const [exporting, setExporting] = useState(false);
  const doExport = useCallback(async () => {
    setExporting(true);
    try {
      const { data: all, error: err } = await supabase.rpc('timesheet_report_compliance', {
        p_filters: { ...filters, page: 1, page_size: 500 },
      });
      if (err) { window.alert(`Export failed: ${err.message}`); return; }
      const p = all as unknown as Payload;
      const rows = p?.rows ?? [];
      const s = p?.summary;

      await exportXlsx([
        { name: 'Compliance', rows: rows.map(r => ({
            Period: r.period, Employee: r.employee_name, 'Employee ID': r.employee_code,
            Department: r.department_name ?? '', Manager: r.manager_name ?? '',
            Schedule: r.schedule_name ?? '', State: STATE_STYLE[r.state]?.label ?? r.state,
            'Planned hours':  toDecimalHours(r.planned_minutes),
            'Recorded hours': toDecimalHours(r.recorded_minutes),
            'Variance hours': toDecimalHours(r.variance_minutes),
            'Days logged': r.days_with_entries,
            Submitted: r.submitted_at ? r.submitted_at.slice(0, 10) : '',
            Approved:  r.approved_at  ? r.approved_at.slice(0, 10)  : '',
            Due: r.due_date, Overdue: r.is_overdue ? 'Yes' : 'No',
            'Days past due': r.is_overdue ? r.days_past_due : 0,
            'Changes since approval': r.changes_since_approval ?? '',
          })) },
        { name: 'Summary', rows: s ? [
            { Measure: 'Expected',        Value: s.expected },
            { Measure: 'Not configured',  Value: s.not_configured },
            { Measure: 'Not started',     Value: s.not_started },
            { Measure: 'To be submitted', Value: s.to_be_submitted },
            { Measure: 'To be approved',  Value: s.to_be_approved },
            { Measure: 'Approved',        Value: s.approved },
            { Measure: 'Overdue',         Value: s.overdue },
            { Measure: 'Planned hours',   Value: toDecimalHours(s.planned_minutes) },
            { Measure: 'Recorded hours',  Value: toDecimalHours(s.recorded_minutes) },
          ] : [] },
      ], `timesheet_compliance_${from}_${to}.xlsx`);

      if (p.total_rows > rows.length) {
        window.alert(`Exported the first ${rows.length} of ${p.total_rows} rows — the report caps a single read at 500. Narrow the period or the filters to export the rest.`);
      }
    } finally { setExporting(false); }
  }, [filters, from, to]);

  const s = data?.summary;

  return (
    <div className="er-page">
      <ReportHeader icon="fa-clipboard-check" title="Timesheet Compliance" onBack={onBack} />

      <div className="er-toolbar">
        <div className="er-filters-row">
          <MonthRange from={from} to={to} onFrom={setFrom} onTo={setTo} />
          <MSDropdown id="c-emp"   icon="fa-user"    label="Employee"   options={emps}          selected={selEmp}   onChange={setEmp} />
          <MSDropdown id="c-dept"  icon="fa-sitemap" label="Department" options={depts}         selected={selDept}  onChange={setDept} />
          <MSDropdown id="c-state" icon="fa-tag"     label="State"      options={STATE_OPTIONS} selected={selState} onChange={setState} />
        </div>

        <div className="er-filters-row2">
          <label style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12, color: '#4B5563', cursor: 'pointer' }}>
            <input type="checkbox" checked={onlyLate} onChange={e => setLate(e.target.checked)}
                   style={{ width: 14, height: 14, accentColor: '#DC2626' }} />
            Overdue only
          </label>
          <button className="er-apply-btn" type="button" onClick={apply}>
            <i className="fa-solid fa-filter" /> Apply Filters
          </button>
          <button className="er-reset-btn" type="button" onClick={reset}>
            <i className="fa-solid fa-rotate-left" /> Reset
          </button>
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
          <Kpi label="Expected"        value={String(s?.expected ?? 0)} />
          <Kpi label="Not started"     value={String(s?.not_started ?? 0)}     tone={s?.not_started ? '#991B1B' : undefined} />
          <Kpi label="To be submitted" value={String(s?.to_be_submitted ?? 0)} />
          <Kpi label="To be approved"  value={String(s?.to_be_approved ?? 0)} />
          <Kpi label="Approved"        value={String(s?.approved ?? 0)}        tone="#166534" />
          <Kpi label="Overdue"         value={String(s?.overdue ?? 0)}         tone={s?.overdue ? '#DC2626' : undefined} />
          <Kpi label="Not configured"  value={String(s?.not_configured ?? 0)}  tone={s?.not_configured ? '#92400E' : undefined} />
        </div>
      )}

      {!!s?.not_configured && (
        <div style={{ margin: '10px 20px 0', padding: '9px 14px', borderRadius: 8, fontSize: 12.5,
                      background: '#FFFBEB', border: '1px solid #FDE68A', color: '#92400E' }}>
          <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 8 }} />
          {s.not_configured} employee{s.not_configured === 1 ? ' has' : 's have'} no work schedule assigned.
          They have no planned hours, so they cannot submit a timesheet at all — this is a configuration
          gap, not lateness, and it is excluded from the Expected count.
        </div>
      )}

      <ReportStatus loading={loading} error={error}
                    empty={!!data && data.rows.length === 0}
                    emptyText="No employees match these filters for this period." />

      {!loading && !error && data && data.rows.length > 0 && (
        <div style={{ overflow: 'auto', maxHeight: 'calc(100vh - 470px)', minHeight: 200,
                      background: '#fff', margin: '12px 20px 0', borderRadius: 12,
                      boxShadow: '0 4px 16px rgba(24,52,91,0.08)' }}>
          <table className="er-table" style={{ width: '100%' }}>
            <thead style={{ position: 'sticky', top: 0, zIndex: 10 }}>
              <tr>
                <th style={{ minWidth: 180 }}>Employee</th>
                <th style={{ whiteSpace: 'nowrap' }}>Department</th>
                <th style={{ whiteSpace: 'nowrap' }}>Manager</th>
                <th style={{ whiteSpace: 'nowrap' }}>Period</th>
                <th style={{ textAlign: 'center', whiteSpace: 'nowrap' }}>State</th>
                <th className="er-th-amt" style={{ whiteSpace: 'nowrap' }}>Planned</th>
                <th className="er-th-amt" style={{ whiteSpace: 'nowrap' }}>Recorded</th>
                <th className="er-th-amt" style={{ whiteSpace: 'nowrap' }}>Variance</th>
                <th style={{ textAlign: 'center', whiteSpace: 'nowrap' }}>Days</th>
                <th style={{ whiteSpace: 'nowrap' }}>Due</th>
                <th style={{ textAlign: 'center', whiteSpace: 'nowrap' }}>Changes</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map(r => (
                <tr key={`${r.employee_id}-${r.period}`} className="er-row">
                  <td>
                    <div className="er-emp-info">
                      <span className="er-emp-name">{r.employee_name}</span>
                      <span className="er-emp-id">{r.employee_code}</span>
                    </div>
                  </td>
                  <td style={{ whiteSpace: 'nowrap' }}>{r.department_name ?? '—'}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>{r.manager_name ?? '—'}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>{fmtPeriod(r.period)}</td>
                  <td style={{ textAlign: 'center' }}><StateBadge state={r.state} /></td>
                  <td className="er-td-amt">{fmtHM(r.planned_minutes)}</td>
                  <td className="er-td-amt">{fmtHM(r.recorded_minutes)}</td>
                  <td className="er-td-amt" style={{ color: r.variance_minutes < 0 ? '#B91C1C' : '#166534' }}>
                    {r.variance_minutes > 0 ? '+' : ''}{fmtHM(r.variance_minutes)}
                  </td>
                  <td style={{ textAlign: 'center' }}>{r.days_with_entries}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>
                    {fmtDate(r.due_date)}
                    {r.is_overdue && (
                      <span style={{ marginLeft: 6, fontSize: 10, fontWeight: 700, color: '#B91C1C',
                                     background: '#FEE2E2', borderRadius: 4, padding: '1px 5px' }}>
                        {r.days_past_due}d late
                      </span>
                    )}
                  </td>
                  <td style={{ textAlign: 'center' }}>
                    {r.changes_since_approval === null ? (
                      <span style={{ color: '#CBD5E1' }}>—</span>
                    ) : r.changes_since_approval === 0 ? (
                      <span style={{ color: '#94A3B8' }}>0</span>
                    ) : (
                      <span title="Entries added or changed since this timesheet was last approved."
                            style={{ fontSize: 11, fontWeight: 700, color: '#92400E',
                                     background: '#FEF3C7', borderRadius: 4, padding: '1px 6px' }}>
                        {r.changes_since_approval}
                      </span>
                    )}
                  </td>
                </tr>
              ))}
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
          {s?.overdue ? <strong style={{ color: '#B91C1C' }}>{s.overdue} overdue</strong> : 'Nothing overdue'}
        </div>
      </div>
    </div>
  );
}
