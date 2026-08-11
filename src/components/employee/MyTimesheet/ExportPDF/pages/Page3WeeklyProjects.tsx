import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors, rankColors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { SectionHead } from '../components/SectionHead';
import { fmtHM, fmtHMWide, fmtHours } from '../utils/dataTransforms';
import type { TimesheetExportData } from '../types';

/**
 * Weekly totals as bar cards, then projects with their activities nested.
 *
 * WHY NESTED
 *   Projects were a flat bar chart here and activities a second flat chart on
 *   page 4. Two lists, two denominators, and a reader with a reasonable question
 *   — "which activities went on WISAYAH?" — that neither could answer. Nesting
 *   answers it and makes the arithmetic self-evident at the same time: activity
 *   lines sum to their project header, headers sum to the section total, and the
 *   difference from the month is printed as non-project attendance.
 *
 *   Page 4's activity chart stays. It counts EVERY activity, including those on
 *   non-project time, which this section excludes by construction — the same
 *   division of labour the screen uses between its donut and its project cards.
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

                // Amber is the ONLY colour on this report that means anything, and
                // it means OVER. A short week stays blue: slate read as "switched
                // off" rather than "under target", and the shortfall is already
                // said twice — by the gap above the bar and by the caption.
                const tone = over ? colors.amber : colors.blueMid;

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
          {/* PROJECTS WITH THEIR ACTIVITIES NESTED, replacing the flat chart.

              The flat version listed projects here and activities on page 4, as
              two independent charts against two different denominators —
              projects 46h, activities 63h, month 80h — and no caption made that
              read as anything but three answers to one question. Nested, the
              arithmetic is visible: activity lines sum to their project header,
              project headers sum to the figure in this heading, and what is left
              is non-project time, printed below with its own name.

              Percentages are of PROJECT time and use largest-remainder rounding,
              so the column totals 100 rather than the 102 five round-ups used to
              produce. */}
          <SectionHead sub={`${fmtHM(projTotal)} of ${fmtHM(data.recordedMinutes)} recorded · shares are of project time`}>
            By Project &amp; Activity
          </SectionHead>
          {data.projectActivities.length === 0 ? (
            <Text style={styles.tdMute}>No project time recorded in this period.</Text>
          ) : (
            <View>
              {data.projectActivities.map((p, i) => {
                const colour = rankColors[Math.min(i, rankColors.length - 1)];
                // Each card scales to its OWN largest activity. Scaling to the
                // project total renders a four-way split as four stubs and there
                // is nothing left to compare; within a card the question being
                // asked is which activity dominated.
                const widest = Math.max(1, ...p.activities.map(a => a.minutes));

                return (
                  /* wrap={false} per card, not per section: a project with eight
                     activities must be allowed to start a new page rather than
                     force the whole chart onto one. A card that splits would put
                     its header on one page and its hours on the next. */
                  <View key={p.name} style={styles.pCard} wrap={false}>
                    <View style={styles.pCardHead}>
                      <View style={{ ...styles.pDot, backgroundColor: colour }} />
                      <Text style={styles.pName}>{p.name}</Text>
                      <Text style={styles.pDays}>
                        {p.daysActive} {p.daysActive === 1 ? 'day' : 'days'}
                      </Text>
                      <Text style={styles.pHrs}>{fmtHMWide(p.minutes)}</Text>
                      <Text style={styles.pPct}>{p.pctOfProjectTime}%</Text>
                    </View>

                    <View style={styles.pActs}>
                      {p.activities.map((a, j) => (
                        <View key={`${a.name}-${j}`} style={styles.pActRow}>
                          <View style={styles.pActTop}>
                            <Text style={styles.pActNo}>{j + 1}.</Text>
                            <Text style={a.itemised ? styles.pActName : styles.pActNameQ}>
                              {a.name}
                            </Text>
                            <Text style={a.itemised ? styles.pActHrs : styles.pActHrsQ}>
                              {fmtHMWide(a.minutes)}
                            </Text>
                          </View>
                          <View style={styles.pActBar}>
                            <View style={styles.pActTrack}>
                              <View style={{
                                ...styles.pActFill,
                                width: `${Math.max(1.5, (a.minutes / widest) * 100)}%`,
                                backgroundColor: a.itemised ? colour : '#D1D5DB',
                              }} />
                            </View>
                          </View>
                        </View>
                      ))}
                    </View>
                  </View>
                );
              })}

              {/* Whatever the cards do not cover, named. Leave, training and any
                  other non-project attendance are real hours; letting them fall
                  out of the bottom of a section headed "of 80h recorded" is how
                  a total stops adding up. No bar — it is not a project. */}
              {rest > 0 && (
                <View style={styles.actStack} wrap={false}>
                  <View style={styles.actTop}>
                    <Text style={styles.restTxt}>Non-project attendance</Text>
                    {/* HOURS ONLY, deliberately. The percentages above are of
                        PROJECT time; this row is the part that is not project
                        time, so its share can only be of the month. Printing
                        both in one column gave 44 + 33 + 20 + 3 + 13 = 113 and
                        a reader who adds a column and gets 113 is right to stop
                        believing the rest. The hours close the gap on their own:
                        70h of project work, 10h here, 80h recorded below. */}
                    <Text style={styles.restTxt}>{fmtHMWide(rest)}</Text>
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
