import { Page, View, Text } from '@react-pdf/renderer';
import { styles, rankColors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { SectionHead } from '../components/SectionHead';
import { ApprovalStamp } from '../components/ApprovalStamp';
import { fmtHM, fmtHMWide, fmtStamp } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

/** Beyond this the chart stops being scannable and starts being a list. What is
 *  dropped is never silent — the rows below name it. */
const MAX_BARS = 10;

/**
 * Where the month's hours went, by activity, and the sheet's standing.
 *
 * Label above a full-width bar rather than a name pinned to 21% of the width:
 * two facts a row across eight-plus rows is a chart, and at full width the
 * difference between 30% and 4% is visible rather than inferred.
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
  const all      = data.activities;
  const shown    = all.slice(0, MAX_BARS);
  const overflow = all.slice(MAX_BARS);
  const itemised = all.reduce((s, a) => s + a.minutes, 0);
  const peak     = Math.max(1, ...shown.map(a => a.minutes));

  // Hours with no itemised split: pre-727 entries, and attendance types that
  // carry no activities at all.
  const rest = Math.max(0, data.recordedMinutes - itemised);

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Activity Summary & Approval · ${data.periodLabel}`} />
      <View style={styles.body}>

        <View style={styles.secWrap}>
          <SectionHead sub={`${fmtHM(itemised)} of ${fmtHM(data.recordedMinutes)} itemised · bars compare against the largest activity`}>
            Hours by Activity Type
          </SectionHead>

          {all.length === 0 ? (
            <Text style={styles.tdMute}>
              No itemised activity hours in this period. Entries recorded before per-activity
              hours existed carry activity names without a split, and are not charted.
            </Text>
          ) : (
            <View>
              {shown.map((a, i) => (
                <View key={a.name} style={styles.actStack} wrap={false}>
                  <View style={styles.actTop}>
                    <Text style={styles.actName2}>{a.name}</Text>
                    <Text style={styles.actVals}>
                      {fmtHMWide(a.minutes)}
                      <Text style={styles.actPct2}>   {Math.round(a.pctOfTotal)}%</Text>
                    </Text>
                  </View>
                  <View style={styles.actTrack}>
                    <View style={{
                      ...styles.actFill,
                      width: `${Math.max(1.5, (a.minutes / peak) * 100)}%`,
                      backgroundColor: rankColors[Math.min(i, rankColors.length - 1)],
                    }} />
                  </View>
                </View>
              ))}

              {/* Capped, but never silently. A chart that quietly drops its tail
                  reads as complete when it is not. */}
              {overflow.length > 0 && (
                <View style={styles.actStack} wrap={false}>
                  <View style={styles.actTop}>
                    <Text style={styles.restTxt}>
                      + {overflow.length} more {overflow.length === 1 ? 'activity' : 'activities'}
                    </Text>
                    <Text style={styles.restTxt}>
                      {fmtHMWide(overflow.reduce((s, a) => s + a.minutes, 0))}
                    </Text>
                  </View>
                </View>
              )}

              {rest > 0 && (
                <View style={styles.actStack} wrap={false}>
                  <View style={styles.actTop}>
                    <Text style={styles.restTxt}>Not itemised</Text>
                    <Text style={styles.restTxt}>
                      {fmtHMWide(rest)}
                      <Text style={styles.actPct2}>   {Math.round((rest / Math.max(1, data.recordedMinutes)) * 100)}%</Text>
                    </Text>
                  </View>
                </View>
              )}

              <View style={styles.ltTotal}>
                <Text style={styles.ltTotalL}>Month recorded</Text>
                <Text style={styles.ltTotalV}>{fmtHM(data.recordedMinutes)}</Text>
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
