import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { fmtHM, fmtDateShort } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

/**
 * Columns are what this system actually records.
 *
 * The brief specified Time In / Time Out / Break; Prowess is duration-only by
 * design and has never stored a clock time, so those three columns would have
 * been empty on every row of every report. Project and Activities take their
 * place — on a project timesheet that is the detail a reviewer is looking for.
 */
const COLS = [
  { key: 'date',  label: 'DATE',       w: '11%' },
  { key: 'day',   label: 'DAY',        w: '7%'  },
  { key: 'type',  label: 'TYPE',       w: '14%' },
  { key: 'proj',  label: 'PROJECT',    w: '17%' },
  { key: 'acts',  label: 'ACTIVITIES', w: '25%' },
  { key: 'hrs',   label: 'HOURS',      w: '10%', right: true },
  { key: 'notes', label: 'NOTES',      w: '16%' },
];

export function Page2DailyDetails({ data }: { data: TimesheetExportData }) {
  const total = data.entries.reduce((s, e) => s + e.minutes, 0);

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Daily Attendance · ${data.periodLabel}`} />
      <View style={styles.body}>
        <Text style={styles.sectionTitle}>Daily Attendance Details</Text>
        <View style={styles.sectionRule} />

        <View style={styles.th} fixed>
          {COLS.map(c => (
            <Text key={c.key} style={{ ...styles.thCell, width: c.w, textAlign: c.right ? 'right' : 'left' }}>
              {c.label}
            </Text>
          ))}
        </View>

        {data.entries.length === 0 && (
          <View style={styles.tr}><Text style={styles.tdMute}>No entries recorded for this period.</Text></View>
        )}

        {data.entries.map((e, i) => {
          const muted = e.isWeekend || e.isHoliday;
          const cell  = muted ? styles.tdMute : styles.td;
          const rowSt = { ...styles.tr, ...(muted ? styles.trMute : i % 2 ? styles.trAlt : {}) };
          const actLabel = e.activities.length
            ? e.activities.map(a => (a.minutes > 0 ? `${a.name} (${fmtHM(a.minutes)})` : a.name)).join(', ')
            : '—';
          return (
            <View key={`${e.date}-${i}`} style={rowSt} wrap={false}>
              <Text style={{ ...cell, width: COLS[0].w }}>{fmtDateShort(e.date)}</Text>
              <Text style={{ ...cell, width: COLS[1].w }}>{e.dayLabel}</Text>
              <Text style={{ ...cell, width: COLS[2].w }}>{e.typeName}</Text>
              <Text style={{ ...cell, width: COLS[3].w }}>{e.project ?? '—'}</Text>
              <Text style={{ ...cell, width: COLS[4].w }}>{actLabel}</Text>
              <Text style={{ ...cell, width: COLS[5].w, textAlign: 'right',
                             color: muted ? colors.ink4 : colors.ink,
                             fontFamily: 'Helvetica-Bold' }}>{fmtHM(e.minutes)}</Text>
              <Text style={{ ...cell, width: COLS[6].w }}>{e.notes ?? ''}</Text>
            </View>
          );
        })}

        <View style={styles.totalRow}>
          <Text style={{ ...styles.totalCell, width: '74%' }}>
            TOTAL · {data.entries.length} {data.entries.length === 1 ? 'entry' : 'entries'}
          </Text>
          <Text style={{ ...styles.totalCell, width: '10%', textAlign: 'right' }}>{fmtHM(total)}</Text>
          <Text style={{ ...styles.totalCell, width: '16%' }} />
        </View>
      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
