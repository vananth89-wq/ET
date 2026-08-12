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
  // Three places on this page state the status — the band's chip, this cell and
  // the stamp on the last page. They have to agree, or the reader picks the one
  // that suits them.
  const st = data.status === 'approved' && data.changedSinceApproval
    ? { txt: 'Edited after approval', tone: '#92400E' }
    : STATUS_TEXT[data.status];

  // "Today" comes from generatedAt rather than a fresh clock read, so every
  // number on the page is measured against the same instant — a report that
  // straddles midnight mid-render would otherwise contradict itself.
  const todayIso = data.generatedAt.slice(0, 10);

  // Days carrying time, counted as DAYS. data.entries would over-count: mig 726
  // put several entries on one day, so a three-project Monday is one day here
  // and three rows there.
  const daysRecorded = data.monthDays.filter(d => d.minutes > 0).length;

  // Has the month finished? Utilisation means one thing on a closed month and
  // something much weaker on a live one, and the caption says which.
  const lastDay        = data.monthDays[data.monthDays.length - 1]?.date ?? '';
  const monthInProgress = !!lastDay && todayIso <= lastDay;

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
            {/* EIGHT TILES, FOUR ACROSS, TWO ROWS THAT EACH ANSWER ONE THING:
                hours on the top row, days on the bottom. Read across rather
                than hunting through eight unrelated boxes.

                PROJECTS was dropped. A count of five said nothing once the
                summary page began naming all five with their hours and shares —
                it was earning its slot only while the report had no month-level
                split at all. */}
            <KPICard label="Planned Hours"   value={fmtHours(data.plannedMinutes)}  caption="hrs this month" icon="clock"
                     tone={colors.blueMid} />
            <KPICard label="Recorded Hours"  value={fmtHours(data.recordedMinutes)} caption="hrs logged" icon="trend"
                     tone={colors.greenMid} />
            {/* The mockup's tile here is OVERTIME. This system has no overtime
                concept, calculation or approval path, so it reports the
                measurement it can defend: hours beyond the DAY's schedule.
                "day's" is load-bearing — this figure sits next to a month
                running 99 hours under, and without that word the two read as a
                contradiction. It is also the reason the figure was wrong once:
                computed month-level as max(0, recorded - planned) it printed
                zero while the calendar flagged a ten-hour Monday in amber. */}
            <KPICard label="Over Planned"    value={fmtHours(overMins)}
                     caption="hrs beyond the day's schedule" icon="over"
                     tone={overMins > 0 ? colors.amber : colors.ink4} />
            {/* The mockup calls this "Attendance / completion rate". It is
                recorded / planned, which is a utilisation figure — calling it
                attendance would imply a presence measurement this system never
                takes.

                Mid-month the caption has to say so. 41% on the 12th is an
                artefact of the month being a third over, not a measure of
                anybody's output, and a reader handed it without that
                qualification will draw the wrong conclusion. */}
            <KPICard label="Utilisation"     value={String(Math.round(data.utilisationPct))} unit="%"
                     caption={monthInProgress ? 'of planned · month in progress' : 'of planned hours'}
                     icon="gauge" tone={colors.green} />

            <KPICard label="Working Days"    value={String(data.workingDays)}       caption="scheduled this month" icon="calendar"
                     tone={colors.blue} />
            {/* Hours alone cannot say this: 69 hours is nine long days or twenty
                short ones, and those are different conversations. Counted as
                DAYS, not entries — since mig 726 one day carries several, so
                counting rows would read a three-project Monday as three days. */}
            <KPICard label="Days Recorded"   value={String(daysRecorded)}
                     caption="days with time against them" icon="calendarCheck"
                     tone={colors.greenMid} />
            <KPICard label="Leave Days"      value={String(data.leaveDays)}         caption="days absent" icon="suitcase"
                     tone={colors.amber} />
            <KPICard label="Public Holidays" value={String(holidays)}               caption="days this month" icon="star"
                     tone={colors.greenMid} />
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
