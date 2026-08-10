import { Page, View, Text } from '@react-pdf/renderer';
import { styles, rankColors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { SectionHead } from '../components/SectionHead';
import { ApprovalStamp } from '../components/ApprovalStamp';
import { fmtHM, fmtStamp } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

/**
 * Where the month's hours went, by activity, and the sheet's standing.
 *
 * This page used to also carry a per-day activity breakdown. Page 2 now lists
 * every activity with its hours inside its project's card, so that section was
 * printing the same numbers a second time in a different shape — and two
 * renderings of one fact are two chances to disagree. It is gone.
 *
 * Activity names are free text (mig 717 — there is no master list), so the
 * chart shows whatever people actually typed. That is the point: it reports the
 * vocabulary in use rather than a taxonomy nobody agreed to.
 */
export function Page4ActivityApproval({ data }: { data: TimesheetExportData }) {
  const acts  = data.activities;
  const peak  = Math.max(1, ...acts.map(a => a.minutes));
  const total = acts.reduce((s, a) => s + a.minutes, 0);

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Activity Summary & Approval · ${data.periodLabel}`} />
      <View style={styles.body}>

        <View style={styles.secWrap}>
          <SectionHead>Hours by Activity Type</SectionHead>
          {acts.length === 0 ? (
            <Text style={styles.tdMute}>
              No itemised activity hours in this period. Entries recorded before per-activity
              hours existed carry activity names without a split, and are not charted.
            </Text>
          ) : (
            <View>
              {acts.map((a, i) => (
                <View key={a.name} style={styles.actRow} wrap={false}>
                  <Text style={styles.actLbl}>{a.name}</Text>
                  <View style={{ flex: 1, paddingRight: 12 }}>
                    <View style={styles.actTrack}>
                      <View style={{
                        ...styles.actFill,
                        width: `${Math.max(2, (a.minutes / peak) * 100)}%`,
                        backgroundColor: rankColors[Math.min(i, rankColors.length - 1)],
                      }} />
                    </View>
                  </View>
                  <Text style={styles.actHrs}>{fmtHM(a.minutes)}</Text>
                  <Text style={styles.actPct}>{Math.round(a.pctOfTotal)}%</Text>
                </View>
              ))}
              <View style={styles.ltTotal}>
                <Text style={styles.ltTotalL}>Total itemised</Text>
                <Text style={styles.ltTotalV}>{fmtHM(total)}</Text>
              </View>
            </View>
          )}
        </View>

        <ApprovalStamp data={data} />

        <Text style={styles.endLine}>— End of Report —</Text>
        <Text style={styles.docLine}>
          Document ID: {data.documentId} · generated {fmtStamp(data.generatedAt)}
        </Text>

      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
