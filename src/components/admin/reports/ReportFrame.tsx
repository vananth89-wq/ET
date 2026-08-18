/**
 * ReportFrame — the chrome around any report, however many views it has.
 *
 * Owns the header, the tab strip and the filters that mean the same thing on
 * every view, so a view component only has to render its own toolbar and rows.
 *
 * WHY THE SHARED FILTERS LIVE HERE
 *   Period, employee and department survive a tab switch. That is the entire
 *   justification for tabs over separate catalog rows: filter Compliance to
 *   Engineering for July, see who is missing, switch to Utilisation to see
 *   where that team's hours went. If they reset on the way across, the tab has
 *   bought nothing.
 *
 *   Filters only one view has — project, time type, overdue-only — stay local
 *   to it and reset on switch, which is right: they have no meaning elsewhere.
 */

import { useCallback, useState } from 'react';
import { ReportHeader } from './reportControls';
import { lastMonthInput } from './reportShared';
import type { SharedReportFilters } from './reportShared';
import type { ReportDef, ReportView } from './registry';

export default function ReportFrame({ report, views, onBack }: {
  report: ReportDef;
  /** Only the views this caller may open. Never empty — the catalog checks first. */
  views: ReportView[];
  onBack: () => void;
}) {
  const [activeCode, setActiveCode] = useState(views[0].code);
  const active = views.find(v => v.code === activeCode) ?? views[0];

  // Both tabs default to LAST month, not this one. A complete month is the
  // right default for any report — the current one is always partial, and on
  // Compliance nothing in it is late yet, so it opens as a screen of red that
  // means nothing.
  const [shared, setSharedState] = useState<SharedReportFilters>(() => ({
    from: lastMonthInput(), to: lastMonthInput(), employees: [], depts: [],
  }));

  // Functional merge, so several patches in one handler compose instead of the
  // last one winning.
  const setShared = useCallback((patch: Partial<SharedReportFilters>) => {
    setSharedState(s => ({ ...s, ...patch }));
  }, []);

  const multi = views.length > 1;
  const Active = active.Component;

  /**
   * A SEGMENTED CONTROL, matching the Summary / Daily detail switch on the
   * approval screen. Underlined text reads as a heading; a raised pill in a
   * sunken track says "two positions of one switch" before anyone reads the
   * labels, and the inactive half still looks pressable.
   *
   * Rendered only when there is a choice to make. One segment is not a switch.
   */
  const tabBtn = (v: ReportView) => {
    const on = v.code === active.code;
    return (
      <button
        key={v.code}
        onClick={() => setActiveCode(v.code)}
        aria-pressed={on}
        style={{
          padding: '7px 16px', cursor: 'pointer', borderRadius: 7,
          fontSize: 13, fontWeight: on ? 700 : 600,
          color: on ? '#1F3B73' : '#5B6472',
          background: on ? '#FFFFFF' : 'transparent',
          border: `1px solid ${on ? '#DCE6FA' : 'transparent'}`,
          boxShadow: on ? '0 1px 2px rgba(16,24,40,0.10)' : 'none',
          display: 'flex', alignItems: 'center', gap: 7, transition: 'background 120ms ease',
        }}
      >
        <i className={`fa-solid ${v.icon}`} style={{ fontSize: 11, color: on ? '#2B54CE' : '#8A93A0' }} />
        {v.name.replace(/^Timesheet /, '')}
      </button>
    );
  };

  return (
    <div className="er-page">
      {/* With one view the frame wears that view's identity, not the report's —
          "Timesheet Report" with a single Compliance tab would promise a choice
          the caller does not have. */}
      <ReportHeader
        icon={multi ? report.icon : active.icon}
        title={multi ? report.name : active.name}
        onBack={onBack}
      >
        {multi && (
          <div style={{ display: 'inline-flex', gap: 3, padding: 3, borderRadius: 9,
                        background: '#EEF1F6', border: '1px solid #E1E6EF', marginLeft: 18 }}>
            {views.map(tabBtn)}
          </div>
        )}
      </ReportHeader>

      {/* The inactive view is UNMOUNTED, not hidden. Keeping both alive would
          mean both querying on open, and the shared filters above are what
          actually needed to survive the switch — not two sets of results nobody
          is looking at. */}
      <Active key={active.code} shared={shared} setShared={setShared} />
    </div>
  );
}
