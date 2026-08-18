/**
 * Timesheet Report — one catalog entry, two views.
 *
 * WHY ONE ROW AND NOT TWO
 *   Utilisation and Compliance answer different questions at different grains,
 *   which is why they are two RPCs and cannot be one table. But they are the
 *   same report to the person opening it: same module, same permission, same
 *   period, usually the same team. Two catalog rows carrying an identical
 *   PERMISSION and an identical ACCESS column is duplication the reader has to
 *   parse before discovering it did not matter.
 *
 *   So the catalog row is the MODULE and the tabs are the VIEWS. That scales:
 *   when leave or payroll reporting arrives it adds one row, not four.
 *
 * THE ONE THING TO WATCH
 *   Both tabs are gated by the single `permission` on the registry entry. If
 *   Compliance ever needs to be visible to HR while Utilisation is restricted
 *   to delivery managers, that split cannot be expressed here -- they would
 *   have to become separate registry entries again with separate permissions.
 *   Nothing about this shell prevents that; it is a five-minute reversal.
 */

import { useCallback, useState } from 'react';
import { ReportHeader } from './reportControls';
import { lastMonthInput } from './reportShared';
import type { SharedReportFilters } from './reportShared';
import TimesheetUtilisation from './TimesheetUtilisation';
import TimesheetCompliance from './TimesheetCompliance';

type Tab = 'utilisation' | 'compliance';

const TABS: { key: Tab; label: string; icon: string }[] = [
  { key: 'compliance',  label: 'Compliance',  icon: 'fa-clipboard-check' },
  { key: 'utilisation', label: 'Utilisation', icon: 'fa-chart-simple'    },
];

export default function TimesheetReport({ onBack }: { onBack: () => void }) {
  // Compliance leads. It is the month-end question, it is the one with a
  // deadline attached, and it is the view that answers "is anything wrong"
  // rather than "how did it go".
  const [tab, setTab] = useState<Tab>('compliance');

  // Both tabs default to LAST month, not this one. A complete month is the
  // right default for any report -- the current one is always partial, and on
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

  /**
   * A SEGMENTED CONTROL, matching the Summary / Daily detail switch on the
   * approval screen. Underlined text reads as a heading; a raised pill in a
   * sunken track says "two positions of one switch" before anyone reads the
   * labels, and the inactive half still looks pressable.
   */
  const tabBtn = ({ key, label, icon }: { key: Tab; label: string; icon: string }) => {
    const on = tab === key;
    return (
      <button
        key={key}
        onClick={() => setTab(key)}
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
        <i className={`fa-solid ${icon}`} style={{ fontSize: 11, color: on ? '#2B54CE' : '#8A93A0' }} />
        {label}
      </button>
    );
  };

  return (
    <div className="er-page">
      <ReportHeader icon="fa-clock" title="Timesheet Report" onBack={onBack}>
        <div style={{ display: 'inline-flex', gap: 3, padding: 3, borderRadius: 9,
                      background: '#EEF1F6', border: '1px solid #E1E6EF', marginLeft: 18 }}>
          {TABS.map(tabBtn)}
        </div>
      </ReportHeader>

      {/*
        The inactive tab is UNMOUNTED, not hidden. Keeping both alive would mean
        both querying on open, and the shared filters above are what actually
        needed to survive the switch -- not two sets of results nobody is
        looking at.
      */}
      {tab === 'compliance'
        ? <TimesheetCompliance  shared={shared} setShared={setShared} />
        : <TimesheetUtilisation shared={shared} setShared={setShared} />}
    </div>
  );
}
