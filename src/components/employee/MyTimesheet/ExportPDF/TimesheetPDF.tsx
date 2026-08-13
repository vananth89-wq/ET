import { Document } from '@react-pdf/renderer';
import { Page1EmpInfo } from './pages/Page1EmpInfo';
import { Page2DailyDetails } from './pages/Page2DailyDetails';
import { Page2Summary } from './pages/Page2Summary';
import { Page3WeeklyProjects } from './pages/Page3WeeklyProjects';
import type { TimesheetExportData } from './types';

/**
 * Two reports, one document.
 *
 *   detail   — page 2 is Daily Entries: every entry, its activities and its
 *              notes, grouped by day. Long months paginate onto continuation
 *              sheets; that is react-pdf splitting a table it cannot fit, not a
 *              bug, and the fixed header and footer follow it.
 *   summary  — page 2 is the day × project matrix, always exactly one page.
 *
 * Pages 1 and 3 are shared verbatim. That is the whole design: a manager
 * comparing the two files should find the same employee block, the same KPIs,
 * the same calendar and the same project breakdown, differing only in how the
 * middle is told. Forking them into two documents is how the KPI on one stops
 * agreeing with the KPI on the other.
 *
 * There were four pages once. The fourth charted hours by activity type across
 * the month; with it gone the approval block would have had a page to itself,
 * so it moved to the foot of page 3 beside the totals it signs off.
 */
export type TimesheetReportVariant = 'detail' | 'summary';

export function TimesheetPDF({
  data,
  variant = 'detail',
}: {
  data: TimesheetExportData;
  variant?: TimesheetReportVariant;
}) {
  const kind = variant === 'summary' ? 'Summary' : 'Detail';
  return (
    <Document
      title={`Timesheet ${kind} ${data.periodLabel} — ${data.employeeName}`}
      author="Prowess"
      subject={`Employee timesheet ${kind.toLowerCase()} report, ${data.periodLabel}`}
      creator="Prowess HRIS"
    >
      <Page1EmpInfo data={data} />
      {variant === 'summary'
        ? <Page2Summary      data={data} />
        : <Page2DailyDetails data={data} />}
      <Page3WeeklyProjects data={data} />
    </Document>
  );
}
