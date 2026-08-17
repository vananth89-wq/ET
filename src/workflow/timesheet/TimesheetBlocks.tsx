/**
 * The two timesheet blocks the workflow screens mount.
 *
 *   TimesheetEnrichment  — inbox panel. Summary pages 1–2: who, the eight
 *                          numbers, what is worth a look, the calendar, the
 *                          matrix. Enough to decide without leaving the queue.
 *   TimesheetFullReview  — /workflow/review/:id. Both exports, tabbed:
 *                          Summary adds weekly progress, the project split and
 *                          the activity breakdown; Daily detail is every entry,
 *                          filterable to what changed since the last approval.
 *
 * Neither offers an edit affordance. module_codes.approval_write_permission and
 * edit_route are NULL for 'timesheet' (mig 742), so the framework's Update
 * button cannot appear; these components do not add one back.
 */

import React, { useEffect, useState } from 'react';
import { useTimesheetApproval } from './useTimesheetApproval';
import {
  TsSectionHead, TsEmployeeStrip, TsKpiTiles, TsExceptionChips,
  TsCalendar, TsMatrix, TsWeeklyProgress, TsMonthSplit, TsByProject, TsDailyDetail,
} from './TimesheetReview';
import { hLabel } from './model';
import { TsDecisionPrep } from './TsDecisionPrep';

// ── shared states ────────────────────────────────────────────────────────────

function Loading() {
  return (
    <div style={{ padding: '12px 0', color: '#9CA3AF', fontSize: 12, display: 'flex', alignItems: 'center', gap: 6 }}>
      <i className="fas fa-spinner fa-spin" /> Loading timesheet…
    </div>
  );
}

function Refused({ message }: { message: string }) {
  return (
    <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', background: '#FEF2F2',
                  border: '1px solid #FECACA', borderRadius: 8, padding: '11px 13px', marginBottom: 16 }}>
      <i className="fas fa-circle-exclamation" style={{ color: '#DC2626', fontSize: 13, marginTop: 2 }} />
      <div>
        <div style={{ fontSize: 12.5, fontWeight: 700, color: '#B91C1C' }}>{message}</div>
        <div style={{ fontSize: 11.5, color: '#991B1B', marginTop: 2, lineHeight: 1.5 }}>
          The approval actions below still work — but decide from the task and the history, not from
          a screen that could not load.
        </div>
      </div>
    </div>
  );
}

// ── inbox panel ──────────────────────────────────────────────────────────────

export function TimesheetEnrichment({ headerId, onOpenFull, onMetaResolved }: {
  headerId: string;
  onOpenFull?: () => void;
  /** Lifts the facts the panel header wants but cannot reach — the payload is
   *  loaded here, and a second query from the header would be a second gate. */
  onMetaResolved?: (meta: { managerName: string | null; periodLabel: string | null }) => void;
}) {
  const { payload, month, loading, error } = useTimesheetApproval(headerId);

  const managerName = payload?.employee?.manager_name ?? null;
  const periodLabel = month?.periodLabel ?? null;
  useEffect(() => {
    if (onMetaResolved && (managerName || periodLabel)) {
      onMetaResolved({ managerName, periodLabel });
    }
  }, [managerName, periodLabel]);

  if (loading)          return <Loading />;
  if (error || !month || !payload) return <Refused message={error ?? 'This timesheet could not be loaded.'} />;

  return (
    <>
      <TsEmployeeStrip payload={payload} />
      <TsKpiTiles month={month} />
      <TsExceptionChips month={month} />

      <TsSectionHead title="Calendar overview" sub={month.periodLabel} />
      <TsCalendar month={month} />

      <TsSectionHead
        title="Hours by day and project"
        sub="every day of the month · h:mm"
        right={onOpenFull ? (
          <button
            onClick={onOpenFull}
            style={{ background: 'none', border: 'none', padding: 0, cursor: 'pointer',
                     fontSize: 11, fontWeight: 600, color: '#2F77B5' }}
          >
            Day-by-day detail →
          </button>
        ) : undefined}
      />
      <TsMatrix month={month} />
    </>
  );
}

// ── full review ──────────────────────────────────────────────────────────────

export function TimesheetFullReview({ headerId }: { headerId: string }) {
  const { payload, month, loading, error } = useTimesheetApproval(headerId);
  const [tab, setTab] = useState<'summary' | 'detail'>('summary');
  const [changedOnly, setChangedOnly] = useState(false);

  if (loading)          return <Loading />;
  if (error || !month || !payload) return <Refused message={error ?? 'This timesheet could not be loaded.'} />;

  const card: React.CSSProperties = {
    background: '#fff', border: '1px solid #E8EDF5', borderRadius: 10,
    padding: '16px 18px', marginBottom: 16, boxShadow: '0 1px 2px rgba(0,0,0,0.03)',
  };

  const tabBtn = (key: 'summary' | 'detail', label: string, icon: string, badge?: string) => {
    const on = tab === key;
    return (
      <button
        key={key}
        onClick={() => setTab(key)}
        style={{
          padding: '8px 18px', border: 'none', background: 'none', cursor: 'pointer',
          fontSize: 13, fontWeight: on ? 700 : 500, color: on ? '#2B54CE' : '#6B7280',
          borderBottom: `2px solid ${on ? '#2B54CE' : 'transparent'}`, marginBottom: -1,
          display: 'flex', alignItems: 'center', gap: 7,
        }}
      >
        <i className={`fas ${icon}`} style={{ fontSize: 11 }} />{label}
        {badge && (
          <span style={{ fontSize: 10, fontWeight: 700, background: '#FEF3C7', color: '#92400E',
                         borderRadius: 10, padding: '1px 7px' }}>{badge}</span>
        )}
      </button>
    );
  };

  return (
    <div>
      {/* The numbers and the exceptions, where the approver lands — not below
          six sections of tables they have to scroll back up from. */}
      <TsDecisionPrep month={month} />

      <div style={{ display: 'flex', gap: 2, borderBottom: '1px solid #E5E7EB', marginBottom: 16 }}>
        {tabBtn('summary', 'Summary', 'fa-chart-simple')}
        {tabBtn('detail', 'Daily detail', 'fa-list-ul',
                month.changedCount ? `${month.changedCount} changed` : undefined)}
      </div>

      {tab === 'summary' ? (
        <>
          <div style={card}>
            <TsSectionHead title="Employee information" sub={month.periodLabel} />
            <TsEmployeeStrip payload={payload} />
            <TsKpiTiles month={month} />
            <TsExceptionChips month={month} />
          </div>
          <div style={card}>
            <TsSectionHead title="Calendar overview" />
            <TsCalendar month={month} />
          </div>
          <div style={card}>
            <TsSectionHead title="Hours by day and project" sub="every day of the month · h:mm" />
            <TsMatrix month={month} />
          </div>
          <div style={card}>
            <TsSectionHead title="Weekly progress" sub="Sun – Sat, matching the calendar above" />
            <TsWeeklyProgress month={month} />
          </div>
          <div style={card}>
            <TsSectionHead title="Month split" sub={`${hLabel(month.recorded)} recorded · by project and type`} />
            <TsMonthSplit month={month} />
          </div>
          <div style={card}>
            <TsSectionHead title="By project & activity" />
            <TsByProject month={month} />
          </div>
        </>
      ) : (
        <div style={card}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                        gap: 16, marginBottom: 13 }}>
            <div style={{ flex: 1 }}>
              <TsSectionHead title={`Daily entries — ${month.periodLabel}`} />
            </div>
            {month.changedCount > 0 && (
              <label
                onClick={e => { e.preventDefault(); setChangedOnly(v => !v); }}
                style={{ display: 'inline-flex', alignItems: 'center', gap: 8, fontSize: 12, fontWeight: 600,
                         color: '#475569', cursor: 'pointer', userSelect: 'none', whiteSpace: 'nowrap' }}
              >
                <span style={{ width: 34, height: 19, borderRadius: 11, position: 'relative', flexShrink: 0,
                               background: changedOnly ? '#D97706' : '#D8DEE7', transition: 'background 0.15s' }}>
                  <span style={{ position: 'absolute', top: 2, left: changedOnly ? 17 : 2, width: 15, height: 15,
                                 borderRadius: '50%', background: '#fff', transition: 'left 0.15s',
                                 boxShadow: '0 1px 2px rgba(0,0,0,0.25)' }} />
                </span>
                Days with changes only
                <span style={{ fontSize: 10, fontWeight: 800, background: '#FEF3C7', color: '#92400E',
                               borderRadius: 10, padding: '1px 7px' }}>{month.changedCount}</span>
              </label>
            )}
          </div>
          <TsDailyDetail month={month} payload={payload} changedOnly={changedOnly} />
        </div>
      )}
    </div>
  );
}
