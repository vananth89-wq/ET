/**
 * Timesheet Detail — one employee's period, in full.
 *
 * Vj's item 3. The other three timesheet reports AGGREGATE: Compliance counts
 * submissions, Utilisation groups hours, Project Summary groups projects. None
 * of them answers the question people actually ask about a person — *what did
 * she do in September?* Before this, the only ways to find out were to be that
 * employee's approver, or to ask her to export it herself.
 *
 * SO THIS REPORT DERIVES NOTHING.
 *   It reads `time_approval_payload` — the same blob the approval screen reads
 *   — runs it through `buildMonth`, and renders the same components. Not
 *   similar components: the same ones. An employee, her approver and whoever
 *   opens this report are looking at one rendering of one month, so there is no
 *   version of "the report says something different from the timesheet".
 *
 *   That also means everything the approval screen has gained arrives here for
 *   free and correctly: 826's per-activity billable answers, 836's separation
 *   of help from internal work, 841's requester, 842's billable split.
 *
 * ACCESS
 *   Two gates, both server-side, both pre-existing:
 *     * `timesheet_reports.view_detail` decides whether this report is in the
 *       catalog at all.
 *     * `user_can('timesheet','view', employee)` decides WHOSE sheets it can
 *       open. It is enforced by RLS on timesheet_headers (704) and again by
 *       time_approval_payload (743) — so a token and no UI gets you nothing
 *       this screen would not have shown you anyway.
 *   Migration 842 says plainly which of those is the real boundary. The second
 *   one is.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase } from '../../../lib/supabase';
import { labelAnchorRange } from '../../../lib/period';
import { buildMonth } from '../../../workflow/timesheet/model';
import type { TsPayload } from '../../../workflow/timesheet/model';
import {
  TsEmployeeStrip, TsKpiTiles, TsExceptionChips, TsBillSplit,
  TsCalendar, TsMatrix, TsWeeklyProgress, TsMonthSplit, TsByProject, TsDailyDetail,
  TsSectionHead,
} from '../../../workflow/timesheet/TimesheetReview';
import MSDropdown from './MSDropdown';
import { ReportStatus } from './reportControls';
import type { ReportTabProps } from './reportShared';

interface Opt { value: string; label: string }

const card: React.CSSProperties = {
  background: '#fff', border: '1px solid #E8EDF5', borderRadius: 10,
  padding: '14px 16px', marginBottom: 14,
};

export default function TimesheetDetail({ shared, setShared }: ReportTabProps) {
  const [emps, setEmps] = useState<Opt[]>([]);
  useEffect(() => {
    let live = true;
    supabase.from('employees').select('id, name, employee_id')
      .eq('status', 'Active').order('name').limit(2000)
      .then(({ data, error }) => {
        if (!live || error || !data) return;
        setEmps(data.map(r => ({ value: r.id, label: `${r.name} (${r.employee_id})` })));
      });
    return () => { live = false; };
  }, []);

  /* The shell's shared filters carry a RANGE, because the other three reports
   * aggregate over one. This report reads one sheet, so it uses `from` as the
   * single period and leaves `to` alone rather than fighting the shell for a
   * different shape. */
  const month = shared.from;
  /* Shared with the other tabs, so picking somebody here and switching to
   * Utilisation keeps them selected. Only the first is used. */
  const empId = shared.employees[0] ?? '';
  const setEmp = useCallback((v: string[]) => setShared({ employees: v.slice(-1) }), [setShared]);

  const [payload, setPayload] = useState<TsPayload | null>(null);
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState<string | null>(null);
  /* Told apart from "nothing loaded yet", because they need different words:
   * one is a month nobody filed, the other is a report nobody has run. */
  const [noSheet, setNoSheet] = useState(false);
  const [changedOnly, setChangedOnly] = useState(false);

  const run = useCallback(async () => {
    if (!empId || !month) return;
    setLoading(true); setError(null); setPayload(null); setNoSheet(false);

    /* Mig 837/840: a period is a CYCLE, so the header for "August" is not
     * anchored on the 1st of August. labelAnchorRange gives the closed range an
     * anchor can be in for ANY legal cycle without reading the configured one,
     * which also means this keeps working the day cycles go per-employee and
     * one month's sheets stop sharing an anchor. */
    const [lo, hi] = labelAnchorRange(Number(month.slice(0, 4)), Number(month.slice(5, 7)));

    const { data: hdrs, error: hErr } = await supabase
      .from('timesheet_headers')
      .select('id, period')
      .eq('employee_id', empId)
      .gte('period', lo)
      .lte('period', hi)
      .order('period', { ascending: false })
      .limit(1);

    /* RLS decides this, not the screen. An employee outside the caller's
     * timesheet.view population returns zero rows rather than an error, which
     * is why the empty state says "no timesheet" rather than "not permitted" —
     * the screen genuinely cannot tell those apart, and guessing would either
     * leak that the person exists or accuse the caller of nothing. */
    if (hErr) { setError(hErr.message); setLoading(false); return; }
    if (!hdrs?.length) { setNoSheet(true); setLoading(false); return; }

    const { data, error: pErr } = await supabase.rpc('time_approval_payload',
      { p_header_id: hdrs[0].id });
    if (pErr) { setError(pErr.message); setLoading(false); return; }

    const p = data as unknown as (TsPayload & { ok?: boolean; error?: string }) | null;
    if (!p || p.ok === false) {
      setError(p?.error === 'NOT_FOUND'
        ? 'That timesheet no longer exists.'
        : 'You do not have access to this employee’s timesheet.');
      setLoading(false); return;
    }
    setPayload(p);
    setLoading(false);
  }, [empId, month]);

  const model = useMemo(() => (payload ? buildMonth(payload) : null), [payload]);

  const empLabel = emps.find(e => e.value === empId)?.label ?? '';

  return (
    <>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10, alignItems: 'center', marginBottom: 14 }}>
        <div className="er-chip er-chip-date">
          <i className="fa-solid fa-calendar-days er-chip-icon" />
          <span className="er-date-lbl">Period</span>
          <input type="month" className="er-date-inp" value={month}
                 onChange={e => setShared({ from: e.target.value })} />
        </div>
        {/* The shared control, multi-select like everywhere else -- but setEmp
            keeps only the last pick, because this report reads ONE sheet and a
            control that accepts three while showing one would be lying. */}
        <MSDropdown id="ts-detail-employee" icon="fa-user" label="Employee"
                    options={emps} selected={empId ? [empId] : []} onChange={setEmp} />
        <button
          onClick={run}
          disabled={!empId || !month || loading}
          className="er-apply-btn"
          type="button"
          style={{ opacity: (!empId || !month || loading) ? 0.5 : 1,
                   cursor: (!empId || !month) ? 'not-allowed' : 'pointer' }}
        >
          <i className="fa-solid fa-magnifying-glass" style={{ marginRight: 6 }} />
          Open timesheet
        </button>
        {model && (
          <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12,
                          color: '#475569', cursor: 'pointer', marginLeft: 'auto' }}>
            <input type="checkbox" checked={changedOnly}
                   onChange={e => setChangedOnly(e.target.checked)} />
            Changed since last approval only
          </label>
        )}
      </div>

      {/* Deliberately not auto-running on mount. This report reads ONE person's
          month; opening it should be a decision somebody made, not a side
          effect of clicking a tab. */}
      {!payload && !loading && !error && !noSheet && (
        <div style={{ padding: '48px 16px', textAlign: 'center', color: '#94A3B8', fontSize: 13 }}>
          Pick an employee and a period, then <b>Open timesheet</b>.
        </div>
      )}

      {noSheet && (
        <div style={{ padding: '40px 16px', textAlign: 'center', color: '#94A3B8', fontSize: 13 }}>
          <i className="fa-regular fa-calendar-xmark" style={{ fontSize: 22, display: 'block', marginBottom: 10 }} />
          No timesheet for {empLabel || 'that employee'} in this period.
          <div style={{ fontSize: 12, marginTop: 6 }}>
            Either nothing was recorded, or the sheet is outside what you can see.
          </div>
        </div>
      )}

      <ReportStatus loading={loading} error={error} empty={false} emptyText="" />

      {model && payload && (
        <>
          <div style={card}>
            <TsSectionHead title="Employee information" sub={model.periodLabel} />
            <TsEmployeeStrip payload={payload} />
            <TsKpiTiles month={model} />
            <TsExceptionChips month={model} />
          </div>
          <div style={card}>
            <TsSectionHead title="Billable split" sub="what the period was worth" />
            <TsBillSplit month={model} />
          </div>
          <div style={card}>
            <TsSectionHead title="Calendar overview" sub={model.periodLabel} />
            <TsCalendar month={model} />
          </div>
          <div style={card}>
            <TsSectionHead title="Hours by day and project" sub="every day of the period · h:mm" />
            <TsMatrix month={model} />
          </div>
          <div style={card}>
            <TsSectionHead title="Weekly progress" sub="Sun – Sat, matching the calendar above" />
            <TsWeeklyProgress month={model} />
          </div>
          <div style={card}>
            <TsSectionHead title="Month split" sub="by project and type" />
            <TsMonthSplit month={model} />
          </div>
          <div style={card}>
            <TsSectionHead title="By project & activity" />
            <TsByProject month={model} />
          </div>
          <div style={card}>
            <TsSectionHead title={`Daily entries — ${model.periodLabel}`} />
            <TsDailyDetail month={model} payload={payload} changedOnly={changedOnly} />
          </div>
        </>
      )}
    </>
  );
}
