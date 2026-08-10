import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors, rankColors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { SectionHead } from '../components/SectionHead';
import { fmtHM, fmtHMWide, fmtHours } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

/**
 * Weekly totals as bar cards, then hours by project.
 *
 * Projects use the same stacked bars as the activity chart on page 4, so the
 * two summaries read as one idea. They were briefly a table on the argument
 * that four facts a row need columns — which was wrong: name and days sit on
 * the top line, hours and share on the right, and the fourth fact IS the bar.
 *
 * The design asked for a DESCRIPTION per project. `projects` has exactly four
 * meaningful columns — name, start_date, end_date, active — so DAYS ACTIVE takes
 * its place, and answers a question a reviewer actually has ("was this 72 hours
 * in one week or spread across the month?").
 */
export function Page3WeeklyProjects({ data }: { data: TimesheetExportData }) {
  const todayIso = data.generatedAt.slice(0, 10);

  // Only weeks with hours are shown; a month opening or closing with an empty
  // week would otherwise spend a card saying nothing.
  const weeks = data.weeks.filter(w => w.total > 0);
  // Bars and their planned ghosts share one scale, so a bar shorter than its
  // ghost means exactly what it looks like.
  const peak  = Math.max(1, ...weeks.map(w => Math.max(w.total, w.planned)));
  // Capped at a quarter each: a month with two active weeks should not print two
  // half-page bars, which reads as a chart of something else entirely.
  const slotW = weeks.length ? `${100 / weeks.length}%` : '100%';

  const projTotal = data.projects.reduce((s, p) => s + p.minutes, 0);
  const projPeak  = Math.max(1, ...data.projects.map(p => p.minutes));
  // Hours recorded against no project at all — leave, training, anything the
  // project chart cannot show.
  const rest      = Math.max(0, data.recordedMinutes - projTotal);

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
                // A week is judged only once it is over. Week 2 of a month is
                // not "short" on the 10th — most of it has not happened, and mig
                // 729 forbids recording most types in advance anyway. Same
                // reasoning as the calendar's `future` day state on page 1.
                const done    = w.end <= todayIso;
                const hasPlan = w.planned > 0;
                const over    = hasPlan && w.total > w.planned;
                const short   = hasPlan && done && w.total < w.planned;

                // The same three colours the calendar and the KPI tiles use:
                // red beyond plan, amber short of it, blue otherwise.
                // Amber is the only alert on this report and it means OVER.
                // Falling short is slate: informative, not an accusation.
                const tone = over ? colors.amber : short ? colors.ink3 : colors.blueMid;

                const caption =
                    over  ? `${fmtHM(w.total - w.planned)} beyond ${fmtHM(w.planned)} planned`
                  : short ? `${fmtHM(w.planned - w.total)} short of ${fmtHM(w.planned)}`
                  : !done ? 'hrs so far'
                  : hasPlan ? `of ${fmtHM(w.planned)} planned`
                  : 'hrs recorded';

                return (
                  <View key={w.label} style={{ ...styles.wkSlot, width: slotW, maxWidth: '25%' }}>
                    <View style={styles.wkBox}>
                      <Text style={styles.wkLbl}>WEEK {i + 1} · {w.label.toUpperCase()}</Text>
                      <View style={styles.wkBarWrap}>
                        {hasPlan && (
                          <View style={{ ...styles.wkGhost, height: (w.planned / peak) * 62 }} />
                        )}
                        <View style={{
                          ...styles.wkBar, backgroundColor: tone,
                          // Floored at 6pt: a week with one hour in it should
                          // still show a bar, not an invisible sliver.
                          height: Math.max(6, (w.total / peak) * 62),
                        }} />
                      </View>
                      <Text style={{ ...styles.wkVal, color: tone }}>{fmtHours(w.total)}</Text>
                      <Text style={styles.wkSub}>{caption}</Text>
                    </View>
                  </View>
                );
              })}
            </View>
          )}
        </View>

        <View>
          {/* The heading carries the denominator. Kept as a table rather than
              stacked bars because each row holds four facts and there are rarely
              more than a handful — four sorted numbers do not need a chart to be
              compared. The bar column went from 34% to 44% by tightening the
              rest, which is where the comparison actually improves. */}
          <SectionHead sub={`${fmtHM(projTotal)} of ${fmtHM(data.recordedMinutes)} recorded · bars compare against the largest project`}>
            Hours by Project
          </SectionHead>
          {data.projects.length === 0 ? (
            <Text style={styles.tdMute}>No project time recorded in this period.</Text>
          ) : (
            <View>
              {data.projects.map((p, i) => (
                <View key={p.name} style={styles.actStack} wrap={false}>
                  <View style={styles.actTop}>
                    <Text style={styles.actName2}>
                      {p.name}
                      <Text style={styles.actMeta}>
                        {'   '}{p.daysActive} {p.daysActive === 1 ? 'day' : 'days'}
                      </Text>
                    </Text>
                    <Text style={styles.actVals}>
                      {fmtHMWide(p.minutes)}
                      <Text style={styles.actPct2}>   {Math.round(p.pctOfTotal)}%</Text>
                    </Text>
                  </View>
                  <View style={styles.actTrack}>
                    <View style={{
                      ...styles.actFill,
                      width: `${Math.max(1.5, (p.minutes / projPeak) * 100)}%`,
                      backgroundColor: rankColors[Math.min(i, rankColors.length - 1)],
                    }} />
                  </View>
                </View>
              ))}

              {/* Whatever the chart does not cover, named. Leave, training and
                  any other non-project attendance are real hours; letting them
                  fall out of the bottom of a chart headed "of 80h recorded" is
                  how a total stops adding up. No bar — it is not a project. */}
              {rest > 0 && (
                <View style={styles.actStack} wrap={false}>
                  <View style={styles.actTop}>
                    <Text style={styles.restTxt}>Non-project attendance</Text>
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

      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
