import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { fmtHM, DOW_LABEL } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

export function Page3WeeklyProjects({ data }: { data: TimesheetExportData }) {
  const maxAct = data.activities.length ? data.activities[0].minutes : 0;

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Weekly, Project & Activity Summary · ${data.periodLabel}`} />
      <View style={styles.body}>

        {/* ── Weekly totals ─────────────────────────────────────────── */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Weekly Totals</Text>
          <View style={styles.sectionRule} />
          <View style={styles.th}>
            <Text style={{ ...styles.thCell, width: '22%' }}>WEEK</Text>
            {DOW_LABEL.map(d => (
              <Text key={d} style={{ ...styles.thCell, width: '9%', textAlign: 'right' }}>{d.toUpperCase()}</Text>
            ))}
            <Text style={{ ...styles.thCell, width: '15%', textAlign: 'right' }}>TOTAL</Text>
          </View>
          {data.weeks.map((w, i) => (
            <View key={w.label} style={{ ...styles.tr, ...(i % 2 ? styles.trAlt : {}) }} wrap={false}>
              <Text style={{ ...styles.td, width: '22%' }}>{w.label}</Text>
              {DOW_LABEL.map((_, dow) => {
                const d = w.days.find(x => x.dow === dow);
                return (
                  <Text key={dow} style={{ ...styles.td, width: '9%', textAlign: 'right',
                                           color: d && d.minutes ? colors.ink2 : colors.ink4 }}>
                    {d && d.minutes ? (d.minutes / 60).toFixed(1) : '·'}
                  </Text>
                );
              })}
              <Text style={{ ...styles.td, width: '15%', textAlign: 'right', fontFamily: 'Helvetica-Bold', color: colors.ink }}>
                {fmtHM(w.total)}
              </Text>
            </View>
          ))}
        </View>

        {/* ── Projects ──────────────────────────────────────────────── */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Project Summary</Text>
          <View style={styles.sectionRule} />
          <View style={styles.th}>
            <Text style={{ ...styles.thCell, width: '46%' }}>PROJECT</Text>
            <Text style={{ ...styles.thCell, width: '18%', textAlign: 'right' }}>HOURS</Text>
            <Text style={{ ...styles.thCell, width: '18%', textAlign: 'right' }}>% OF TOTAL</Text>
            <Text style={{ ...styles.thCell, width: '18%', textAlign: 'right' }}>DAYS ACTIVE</Text>
          </View>
          {data.projects.length === 0 && (
            <View style={styles.tr}><Text style={styles.tdMute}>No project time recorded this period.</Text></View>
          )}
          {data.projects.map((p, i) => (
            <View key={p.name} style={{ ...styles.tr, ...(i % 2 ? styles.trAlt : {}) }} wrap={false}>
              <Text style={{ ...styles.td, width: '46%' }}>{p.name}</Text>
              <Text style={{ ...styles.td, width: '18%', textAlign: 'right', fontFamily: 'Helvetica-Bold', color: colors.ink }}>{fmtHM(p.minutes)}</Text>
              <Text style={{ ...styles.td, width: '18%', textAlign: 'right' }}>{p.pctOfTotal.toFixed(1)}%</Text>
              <Text style={{ ...styles.td, width: '18%', textAlign: 'right' }}>{p.daysActive}</Text>
            </View>
          ))}
        </View>

        {/* ── Activities ────────────────────────────────────────────── */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Activity Summary</Text>
          <View style={styles.sectionRule} />
          {data.activities.length === 0 && (
            <Text style={styles.tdMute}>No activities recorded this period.</Text>
          )}
          {data.activities.slice(0, 12).map(a => (
            <View key={a.name} style={styles.barRow} wrap={false}>
              <Text style={styles.barLbl}>{a.name}</Text>
              <View style={styles.barTrack}>
                <View style={{ ...styles.barFill, width: `${maxAct ? (a.minutes / maxAct) * 100 : 0}%` }} />
              </View>
              <Text style={styles.barVal}>{fmtHM(a.minutes)} · {a.pctOfTotal.toFixed(0)}%</Text>
            </View>
          ))}
          {data.activities.length > 12 && (
            <Text style={{ ...styles.tiny, marginTop: 4 }}>
              Showing the 12 largest of {data.activities.length} activities.
            </Text>
          )}
        </View>

      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
