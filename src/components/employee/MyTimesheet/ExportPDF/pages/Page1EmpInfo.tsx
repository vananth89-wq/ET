import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { SectionHead } from '../components/SectionHead';
import { KPICard } from '../components/KPICard';
import { CalendarGrid } from '../components/CalendarGrid';
import { fmtHours } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

const STATUS_TEXT: Record<TimesheetExportData['status'], { txt: string; tone: string }> = {
  to_be_submitted: { txt: 'To Be Submitted',  tone: '#B45309' },
  to_be_approved:  { txt: 'Pending Approval', tone: colors.blue },
  approved:        { txt: '✓ Approved',       tone: colors.green },
};

/** Two cells per row, each with its own divider, so the grid reads as a table
 *  rather than a list. The last row has no bottom rule — the box supplies it. */
function InfoRow({ pairs, last }: { pairs: Array<[string, string, string?]>; last?: boolean }) {
  return (
    <View style={{
      ...styles.infoRow,
      ...(last ? {} : { borderBottomWidth: 1, borderBottomColor: colors.rule, borderBottomStyle: 'solid' }),
    }}>
      {pairs.map(([lbl, val, tone], i) => (
        <View key={lbl} style={{
          ...styles.infoCellB,
          ...(i === 0 ? { borderRightWidth: 1, borderRightColor: colors.rule, borderRightStyle: 'solid' } : {}),
        }}>
          <Text style={styles.infoLblB}>{lbl.toUpperCase()}</Text>
          <Text style={{ ...styles.infoValB, ...(tone ? { color: tone } : {}) }}>{val}</Text>
        </View>
      ))}
    </View>
  );
}

export function Page1EmpInfo({ data }: { data: TimesheetExportData }) {
  const st = STATUS_TEXT[data.status];

  // "Today" comes from generatedAt rather than a fresh clock read, so every
  // number on the page is measured against the same instant — a report that
  // straddles midnight mid-render would otherwise contradict itself.
  const todayIso = data.generatedAt.slice(0, 10);

  const holidays = data.monthDays.filter(d => d.isHoliday).length;
  const overMins = data.overtimeMinutes;

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} />
      <View style={styles.body}>

        <View style={styles.secWrap}>
          <SectionHead>Employee Information</SectionHead>
          <View style={styles.infoBox}>
            <InfoRow pairs={[['Employee Name', data.employeeName], ['Employee ID', data.employeeCode]]} />
            <InfoRow pairs={[['Department', data.department], ['Holiday Calendar', data.holidayCalendar]]} />
            <InfoRow pairs={[['Manager', data.manager], ['Work Schedule', data.workSchedule]]} />
            <InfoRow last pairs={[['Reporting Period', data.periodLabel], ['Timesheet Status', st.txt, st.tone]]} />
          </View>
        </View>

        <View style={styles.secWrap}>
          <SectionHead>Monthly Summary</SectionHead>
          <View style={styles.kpiGrid}>
            <KPICard label="Planned Hours"   value={fmtHours(data.plannedMinutes)}  caption="hrs this month" icon="clock"
                     tone={colors.blueMid} />
            <KPICard label="Recorded Hours"  value={fmtHours(data.recordedMinutes)} caption="hrs logged" icon="trend"
                     tone={colors.greenMid} />
            {/* The mockup calls this "Attendance / completion rate". It is
                recorded ÷ planned, which is a utilisation figure — calling it
                attendance would imply a presence measurement this system never
                takes. */}
            <KPICard label="Utilisation"     value={String(Math.round(data.utilisationPct))} unit="%"
                     caption="of planned hours" icon="gauge" tone={colors.green} />
            <KPICard label="Projects"        value={String(data.projects.length)}   caption="active this month" icon="folder"
                     tone={colors.blue} />
            <KPICard label="Working Days"    value={String(data.workingDays)}       caption="scheduled days" icon="calendar"
                     tone={colors.blue} />
            <KPICard label="Leave Days"      value={String(data.leaveDays)}         caption="days absent" icon="suitcase"
                     tone={colors.amber} />
            <KPICard label="Public Holidays" value={String(holidays)}               caption="days this month" icon="star"
                     tone={colors.greenMid} />
            {/* The mockup's eighth tile is OVERTIME. This system has no overtime
                concept, calculation or approval path, so the tile reports the
                measurement it can defend: hours recorded beyond planned. */}
            <KPICard label="Over Planned"    value={fmtHours(overMins)}             caption="hrs beyond schedule" icon="over"
                     tone={overMins > 0 ? colors.red : colors.ink4} />
          </View>
        </View>

        <View>
          <SectionHead>Calendar Overview</SectionHead>
          <CalendarGrid days={data.monthDays} todayIso={todayIso} />
        </View>

      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
