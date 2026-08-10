import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { ApprovalStamp } from '../components/ApprovalStamp';
import { fmtHM, fmtDate } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

export function Page4ActivityApproval({ data }: { data: TimesheetExportData }) {
  const withActivities = data.entries.filter(e => e.activities.length > 0);

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Activity Detail & Approval · ${data.periodLabel}`} />
      <View style={styles.body}>

        <Text style={styles.sectionTitle}>Activity Detail by Day</Text>
        <View style={styles.sectionRule} />

        {/* Entries written before per-activity hours existed have names on the
            parent and no rows, so a month can legitimately have none of these.
            Say so plainly rather than printing an empty heading. */}
        {withActivities.length === 0 ? (
          <Text style={{ ...styles.tdMute, marginBottom: 10 }}>
            No per-activity hours recorded this period. Activity detail appears here once entries
            are saved with hours against each activity.
          </Text>
        ) : (
          withActivities.map((e, i) => (
            <View key={`${e.date}-${i}`} style={{ marginBottom: 9 }} wrap={false}>
              <View style={{ flexDirection: 'row', justifyContent: 'space-between',
                             borderBottomWidth: 0.5, borderBottomColor: colors.border,
                             borderBottomStyle: 'solid', paddingBottom: 3, marginBottom: 4 }}>
                <Text style={{ fontSize: 8.5, fontFamily: 'Helvetica-Bold', color: colors.ink }}>
                  {fmtDate(e.date)} · {e.dayLabel}{e.project ? ` · ${e.project}` : ''}
                </Text>
                <Text style={{ fontSize: 8.5, fontFamily: 'Helvetica-Bold', color: colors.blue }}>
                  {fmtHM(e.minutes)}
                </Text>
              </View>
              {e.activities.map((a, ai) => (
                <View key={ai} style={{ flexDirection: 'row', paddingVertical: 1.5, paddingLeft: 8 }}>
                  <View style={{ width: 3, height: 3, borderRadius: 1.5, backgroundColor: colors.greenMid,
                                 marginTop: 3, marginRight: 6 }} />
                  <Text style={{ ...styles.td, flex: 1 }}>{a.name}</Text>
                  <Text style={{ ...styles.td, width: 60, textAlign: 'right' }}>{fmtHM(a.minutes)}</Text>
                </View>
              ))}
            </View>
          ))
        )}

        <ApprovalStamp data={data} />

        <Text style={styles.endLine}>— End of Report —</Text>
        <Text style={{ ...styles.endLine, marginTop: 3, fontSize: 6.5 }}>
          Document {data.documentId} · generated {data.generatedAt}
        </Text>

      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
