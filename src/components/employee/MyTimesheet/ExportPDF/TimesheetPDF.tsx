import { Document } from '@react-pdf/renderer';
import { Page1EmpInfo } from './pages/Page1EmpInfo';
import { Page2DailyDetails } from './pages/Page2DailyDetails';
import { Page3WeeklyProjects } from './pages/Page3WeeklyProjects';
import type { TimesheetExportData } from './types';

/**
 * Three A4 pages. Long months push page 2 onto a continuation sheet — that is
 * react-pdf paginating a table it cannot fit, not a bug, and the fixed header
 * and footer follow it.
 *
 * There were four. The fourth charted hours by activity type across the month;
 * with it gone the approval block would have had a page to itself, so it moved
 * to the foot of page 3 beside the totals it signs off.
 */
export function TimesheetPDF({ data }: { data: TimesheetExportData }) {
  return (
    <Document
      title={`Timesheet ${data.periodLabel} — ${data.employeeName}`}
      author="Prowess"
      subject={`Employee timesheet report, ${data.periodLabel}`}
      creator="Prowess HRIS"
    >
      <Page1EmpInfo         data={data} />
      <Page2DailyDetails    data={data} />
      <Page3WeeklyProjects  data={data} />
    </Document>
  );
}
