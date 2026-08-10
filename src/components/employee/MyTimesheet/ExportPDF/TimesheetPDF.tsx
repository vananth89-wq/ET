import { Document } from '@react-pdf/renderer';
import { Page1EmpInfo } from './pages/Page1EmpInfo';
import { Page2DailyDetails } from './pages/Page2DailyDetails';
import { Page3WeeklyProjects } from './pages/Page3WeeklyProjects';
import { Page4ActivityApproval } from './pages/Page4ActivityApproval';
import type { TimesheetExportData } from './types';

/**
 * Four A4 pages. Long months push page 2 onto a continuation sheet — that is
 * react-pdf paginating a table it cannot fit, not a bug, and the fixed header
 * and footer follow it.
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
      <Page4ActivityApproval data={data} />
    </Document>
  );
}
