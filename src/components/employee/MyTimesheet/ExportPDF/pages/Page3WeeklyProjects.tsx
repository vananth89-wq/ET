import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors, rankColors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { SectionHead } from '../components/SectionHead';
import { fmtHM, fmtHours } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

/**
 * Weekly totals as bar cards, then hours by project.
 *
 * The mockup's project table has a DESCRIPTION column. `projects` has exactly
 * four meaningful columns — name, start_date, end_date, active — and no
 * description, so that column would have been blank on every row. DAYS ACTIVE
 * takes its place: it is real, it is derived from the entries themselves, and
 * it answers a question a reviewer actually has ("was this 72 hours in one
 * week or spread across the month?").
 */
export function Page3WeeklyProjects({ data }: { data: TimesheetExportData }) {
  // Only weeks with hours are shown; a month opening or closing with an empty
  // week would otherwise spend a card saying nothing.
  const weeks = data.weeks.filter(w => w.total > 0);
  const peak  = Math.max(1, ...weeks.map(w => w.total));
  // Capped at a quarter each: a month with two active weeks should not print two
  // half-page bars, which reads as a chart of something else entirely.
  const slotW = weeks.length ? `${100 / weeks.length}%` : '100%';

  const projTotal = data.projects.reduce((s, p) => s + p.minutes, 0);
  const projPeak  = Math.max(1, ...data.projects.map(p => p.minutes));

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Weekly & Project Summary · ${data.periodLabel}`} />
      <View style={styles.body}>

        <View style={styles.secWrap}>
          <SectionHead>Weekly Hour Summary</SectionHead>
          {weeks.length === 0 ? (
            <Text style={styles.tdMute}>No hours recorded in this period.</Text>
          ) : (
            <View style={styles.wkGrid}>
              {weeks.map((w, i) => {
                const over = w.planned > 0 && w.total > w.planned;
                const tone = over ? colors.red : colors.blueMid;
                return (
                  <View key={w.label} style={{ ...styles.wkSlot, width: slotW, maxWidth: '25%' }}>
                    <View style={styles.wkBox}>
                      <Text style={styles.wkLbl}>WEEK {i + 1} · {w.label.toUpperCase()}</Text>
                      <View style={styles.wkBarWrap}>
                        <View style={{
                          ...styles.wkBar, backgroundColor: tone,
                          // Floored at 6pt: a week with one hour in it should
                          // still show a bar, not an invisible sliver.
                          height: Math.max(6, (w.total / peak) * 62),
                        }} />
                      </View>
                      <Text style={{ ...styles.wkVal, color: tone }}>{fmtHours(w.total)}</Text>
                      <Text style={styles.wkSub}>
                        {over ? `${fmtHM(w.total - w.planned)} beyond ${fmtHours(w.planned)}h planned`
                              : 'hrs recorded'}
                      </Text>
                    </View>
                  </View>
                );
              })}
            </View>
          )}
        </View>

        <View>
          <SectionHead>Hours by Project</SectionHead>
          {data.projects.length === 0 ? (
            <Text style={styles.tdMute}>No project time recorded in this period.</Text>
          ) : (
            <View>
              <View style={styles.ltHead}>
                <Text style={{ ...styles.ltHeadC, width: '24%' }}>PROJECT</Text>
                <Text style={{ ...styles.ltHeadC, width: '17%' }}>DAYS ACTIVE</Text>
                <Text style={{ ...styles.ltHeadC, width: '16%' }}>TOTAL HOURS</Text>
                <Text style={{ ...styles.ltHeadC, width: '34%' }}>DISTRIBUTION</Text>
                <Text style={{ ...styles.ltHeadC, width: '9%', textAlign: 'right' }}>%</Text>
              </View>

              {data.projects.map((p, i) => (
                <View key={p.name} style={styles.ltRow} wrap={false}>
                  <Text style={{ ...styles.ltName, width: '24%' }}>{p.name}</Text>
                  <Text style={{ ...styles.ltTxt,  width: '17%' }}>
                    {p.daysActive} {p.daysActive === 1 ? 'day' : 'days'}
                  </Text>
                  <Text style={{ ...styles.ltHrs,  width: '16%' }}>{fmtHM(p.minutes)}</Text>
                  <View style={{ width: '34%', paddingRight: 14 }}>
                    <View style={styles.track}>
                      <View style={{
                        ...styles.fill,
                        width: `${Math.max(2, (p.minutes / projPeak) * 100)}%`,
                        backgroundColor: rankColors[Math.min(i, rankColors.length - 1)],
                      }} />
                    </View>
                  </View>
                  <Text style={{ ...styles.ltPct, width: '9%' }}>{Math.round(p.pctOfTotal)}%</Text>
                </View>
              ))}

              <View style={styles.ltTotal}>
                <Text style={styles.ltTotalL}>Total</Text>
                <Text style={styles.ltTotalV}>{fmtHM(projTotal)}</Text>
              </View>
            </View>
          )}
        </View>

      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
