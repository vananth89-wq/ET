import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { KPICard } from '../components/KPICard';
import { CalendarGrid } from '../components/CalendarGrid';
import { fmtHM, fmtHours } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

const STATUS_TEXT: Record<TimesheetExportData['status'], string> = {
  to_be_submitted: 'To be submitted',
  to_be_approved:  'Awaiting approval',
  approved:        '✓ Approved',
};

export function Page1EmpInfo({ data }: { data: TimesheetExportData }) {
  const variance = data.varianceMinutes;
  const info: Array<[string, string]> = [
    ['EMPLOYEE NAME',    data.employeeName],
    ['EMPLOYEE ID',      data.employeeCode],
    ['DEPARTMENT',       data.department],
    ['HOLIDAY CALENDAR', data.holidayCalendar],
    ['MANAGER',          data.manager],
    ['WORK SCHEDULE',    data.workSchedule],
    ['REPORTING PERIOD', data.periodLabel],
    ['TIMESHEET STATUS', STATUS_TEXT[data.status]],
  ];

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} />
      <View style={styles.body}>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Employee Information</Text>
          <View style={styles.sectionRule} />
          <View style={styles.infoGrid}>
            {info.map(([lbl, val], i) => (
              <View key={lbl} style={styles.infoCell}>
                <Text style={styles.infoLbl}>{lbl}</Text>
                <Text style={i === 7 && data.status === 'approved'
                  ? { ...styles.infoVal, color: colors.green }
                  : styles.infoVal}>{val || '—'}</Text>
              </View>
            ))}
          </View>
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Monthly Summary</Text>
          <View style={styles.sectionRule} />
          <View style={styles.kpiRow}>
            <KPICard label="Planned Hours"  value={fmtHours(data.plannedMinutes) + 'h'} />
            <KPICard label="Recorded Hours" value={fmtHours(data.recordedMinutes) + 'h'} />
            <KPICard label="Overtime"       value={data.overtimeMinutes > 0 ? fmtHM(data.overtimeMinutes) : '—'}
                     tone={data.overtimeMinutes > 0 ? colors.amber : undefined} />
            <KPICard label="Leave Days"     value={String(data.leaveDays)} />
            <KPICard label="Working Days"   value={String(data.workingDays)} />
            <KPICard label="Days Present"   value={String(data.daysPresent)}
                     sub={`of ${data.workingDays}`} />
            <KPICard label="Utilisation"    value={`${data.utilisationPct.toFixed(0)}%`}
                     tone={data.utilisationPct >= 100 ? colors.green : undefined} />
            <KPICard label="Variance"
                     value={`${variance >= 0 ? '+' : '−'}${fmtHours(Math.abs(variance))}h`}
                     tone={variance >= 0 ? colors.green : colors.red} />
          </View>
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Calendar Overview</Text>
          <View style={styles.sectionRule} />
          <CalendarGrid days={data.monthDays} />
        </View>

      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
