import { Page, View, Text, Svg, Circle, Path } from '@react-pdf/renderer';
import { styles, colors, rankColors } from '../utils/pdfStyles';

/** Non-project time: a neutral ramp, deliberately quieter than the projects.
 *  Leave is the exception — it keeps the tint the weekly bars use for it, so
 *  a segment in a bar and a slice in the donut are visibly the same fact. */
const NEUTRAL = ['#94A3B8', '#CBD5E1', '#B8C0CC', '#DDE3EA'];
const LEAVE_BLUE = '#93C5FD';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { SectionHead } from '../components/SectionHead';
import { ApprovalStamp } from '../components/ApprovalStamp';
import { fmtHM, fmtHMWide, fmtDateShort } from '../utils/dataTransforms';
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

  /* Weeks that have not started say the same nothing each time, and on a report
     produced early in the month that is half the block — three grey rows
     reading "Not yet due". On screen they earn their place by lining up with
     the calendar you are working in; a report is a statement about what
     happened, so the tail collapses to one line that still carries the planned
     hours it is deferring. */
  const firstFuture = data.weeks.findIndex(w => w.start > todayIso && w.planned > 0);
  const tailAllFuture = firstFuture >= 0
    && data.weeks.slice(firstFuture).every(w => w.start > todayIso || w.planned === 0);
  const collapseFrom = tailAllFuture && data.weeks.length - firstFuture >= 2 ? firstFuture : -1;
  const shownWeeks   = collapseFrom >= 0 ? data.weeks.slice(0, collapseFrom) : data.weeks;
  const deferred     = collapseFrom >= 0 ? data.weeks.slice(collapseFrom) : [];
  const deferredPlan = deferred.reduce((s, w) => s + w.planned, 0);

  const projTotal = data.projects.reduce((s, p) => s + p.minutes, 0);

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Summary & Approval · ${data.periodLabel}`} />
      <View style={styles.body}>

        <View style={styles.secGap}>
          {/* WEEKLY PROGRESS, one row per week — the same panel the employee
              sees on screen, rather than a second vocabulary for the same four
              facts. The tall bar cards this replaced showed only the weeks that
              had hours in them, which meant the empty weeks a reviewer is
              actually looking for were the ones it left out. */}
          <SectionHead sub="Sun – Sat, matching the calendar above">Weekly Progress</SectionHead>
          {data.weeks.length === 0 ? (
            <Text style={styles.tdMute}>No weeks in this period.</Text>
          ) : (
            <View>
              {shownWeeks.map((w, i) => {
                const done  = w.end <= todayIso;
                const start = w.start > todayIso;
                const pct   = w.planned > 0 ? (w.total / w.planned) * 100 : 0;
                const over  = w.planned > 0 && w.total > w.planned;
                const work  = w.total - w.leave;

                // The fill is capped at the track and the overshoot named in the
                // tag; work and leave then split that fill by their real share,
                // so the two segments always sum to the bar and never to more.
                const fill     = Math.min(100, pct);
                const workPct  = w.total > 0 ? fill * (work / w.total)    : 0;
                const leavePct = w.total > 0 ? fill * (w.leave / w.total) : 0;

                // A week is judged only once it is over. Week 2 is not "short"
                // on the 10th — most of it has not happened, and mig 729 forbids
                // recording most types in advance anyway.
                const tag = w.planned === 0 ? { t: 'Non-working',  bg: '#F3F4F6', fg: colors.ink3 }
                          : start           ? { t: 'Not yet due',  bg: '#F3F4F6', fg: colors.ink3 }
                          // Red, not amber: overtime is the house red now, and
                          // amber below still means "short". One colour cannot
                          // mean both directions of the same miss.
                          : over            ? { t: `Over by ${fmtHM(w.total - w.planned)}`,
                                                                   bg: '#FDECEC', fg: '#B91C1C' }
                          : !done           ? { t: 'In progress',  bg: colors.blueLt,  fg: colors.blue }
                          : pct >= 100      ? { t: 'Complete',     bg: '#ECFDF5', fg: '#047857' }
                          : pct > 0         ? { t: 'Partial',      bg: colors.amberLt, fg: '#92400E' }
                          :                   { t: 'Nothing logged', bg: colors.amberLt, fg: '#92400E' };

                const workCol = over ? '#F59E0B' : pct >= 100 ? '#10B981' : colors.blueMid;

                return (
                  <View key={w.start} style={i === 0 ? styles.wkRow1 : styles.wkRow} wrap={false}>
                    <View style={{ width: 74 }}>
                      <Text style={styles.wkName}>Week {i + 1}</Text>
                      {/* Only holidays that actually cost this week hours. One
                          on a weekend leaves the target untouched, and a note
                          against an unchanged /40h explains nothing. */}
                      {w.holidays > 0 && (
                        <Text style={styles.wkHol}>
                          {w.holidays} {w.holidays === 1 ? 'holiday' : 'holidays'}
                        </Text>
                      )}
                    </View>

                    <View style={styles.wkTrack}>
                      <View style={{ ...styles.wkFill, width: `${workPct}%`, backgroundColor: workCol }} />
                      {/* The calendar's leave blue, lightened: same family,
                          visibly subordinate — hours accounted for rather than
                          hours worked. */}
                      <View style={{ ...styles.wkFill, width: `${leavePct}%`, backgroundColor: '#93C5FD' }} />
                    </View>

                    <Text style={styles.wkHrs}>
                      {w.total > 0 ? fmtHM(w.total) : '—'}
                      <Text style={styles.wkPlan}> / {fmtHM(w.planned) === '—' ? '0h' : fmtHM(w.planned)}</Text>
                    </Text>

                    <View style={styles.wkTagWrap}>
                      <Text style={{ ...styles.wkTag, backgroundColor: tag.bg, color: tag.fg }}>{tag.t}</Text>
                    </View>

                    <Text style={styles.wkDates}>{w.label}</Text>
                  </View>
                );
              })}

              {deferred.length > 0 && (
                <View style={styles.wkRow} wrap={false}>
                  <Text style={{ ...styles.wkName, width: 74 }}>
                    Weeks {collapseFrom + 1}–{data.weeks.length}
                  </Text>
                  <Text style={{ ...styles.wkDefer, flex: 1 }}>
                    {/* From the DATE, not the label: splitting "16–22 Aug" on
                        the dash gave "16 onwards" and dropped the month. */}
                    not yet due · from {fmtDateShort(deferred[0].start)}
                  </Text>
                  <Text style={styles.wkHrs}>
                    <Text style={styles.wkPlan}>— / {fmtHM(deferredPlan)}</Text>
                  </Text>
                  <View style={styles.wkTagWrap}>
                    <Text style={{ ...styles.wkTag, backgroundColor: '#F3F4F6', color: colors.ink3 }}>
                      Not yet due
                    </Text>
                  </View>
                  <Text style={styles.wkDates}>{'\u00A0'}</Text>
                </View>
              )}
            </View>
          )}
        </View>

        <View style={styles.secGap}>
          {/* THE WHOLE MONTH, projects and non-project time alike. The nested
              breakdown below covers project time only — it has no home for
              training or leave — so without this the report could be read end
              to end without the word "leave" appearing anywhere but a KPI count.
              Two blocks, two denominators, each stated in its own heading. */}
          {/* "By Project & Type" sat directly above "By Project & Activity" —
              two headings differing by one word, describing different things.
              This one is the whole month; the one below is the project detail. */}
          <SectionHead sub={`${fmtHM(data.recordedMinutes)} recorded · every hour, by project and type`}>
            Month Split
          </SectionHead>
          {data.monthSplit.length === 0 ? (
            <Text style={styles.tdMute}>Nothing recorded in this period.</Text>
          ) : (
            <View style={styles.dnWrap}>
              <Svg width={74} height={74} viewBox="0 0 42 42">
                <Circle cx="21" cy="21" r="15.9155" fill="none" stroke="#EDEFF2" strokeWidth="5" />
                {(() => {
                  /* EXPLICIT ARCS, not a dash-array.
                     The browser trick — circumference exactly 100 via
                     r = 15.9155, dasharray "pct  100-pct", dashoffset a running
                     total — is what the on-screen donut uses and it does not
                     survive react-pdf. Its SVG renderer does not honour
                     strokeDashoffset, so every slice started at the same angle
                     and the ring came out part-filled with the colours stacked
                     on top of each other. Rendering it is the only way that was
                     ever going to be visible.

                     An arc path is arithmetic we control: start angle, end
                     angle, and the large-arc flag once a slice passes half. */
                  const R = 15.9155, CX = 21, CY = 21;
                  const at = (pct: number): [number, number] => {
                    const a = (pct / 100) * 2 * Math.PI - Math.PI / 2;   // 12 o'clock
                    return [CX + R * Math.cos(a), CY + R * Math.sin(a)];
                  };

                  let cum = 0, pi = 0, oi = 0;
                  return data.monthSplit.map(sl => {
                    const colour = sl.isLeave   ? LEAVE_BLUE
                                 : sl.isProject ? rankColors[Math.min(pi++, rankColors.length - 1)]
                                 :                NEUTRAL[Math.min(oi++, NEUTRAL.length - 1)];
                    const from = cum;
                    cum += sl.pct;

                    // A single slice covering the whole month has no arc to
                    // draw — its start and end are the same point, and the path
                    // would render nothing at all.
                    if (sl.pct >= 99.5) {
                      return (
                        <Circle key={sl.name} cx="21" cy="21" r="15.9155"
                          fill="none" stroke={colour} strokeWidth="5" />
                      );
                    }
                    if (sl.pct <= 0) return null;

                    const [x0, y0] = at(from);
                    const [x1, y1] = at(cum);
                    const large    = sl.pct > 50 ? 1 : 0;
                    return (
                      <Path key={sl.name}
                        d={`M ${x0.toFixed(3)} ${y0.toFixed(3)} A ${R} ${R} 0 ${large} 1 ${x1.toFixed(3)} ${y1.toFixed(3)}`}
                        fill="none" stroke={colour} strokeWidth="5" />
                    );
                  });
                })()}
              </Svg>

              {/* TWO COLUMNS. One column of seven rows left the names hard
                  against the donut and the hours pinned to the far margin, with
                  a hand's width of nothing in between — the single biggest
                  reason this section read as sparse. */}
              <View style={styles.dnLeg}>
                {(() => {
                  let pi = 0, oi = 0;
                  return data.monthSplit.map(sl => {
                    const colour = sl.isLeave   ? LEAVE_BLUE
                                 : sl.isProject ? rankColors[Math.min(pi++, rankColors.length - 1)]
                                 :                NEUTRAL[Math.min(oi++, NEUTRAL.length - 1)];
                    return (
                      <View key={sl.name} style={styles.dnCol}>
                        <View style={styles.dnRow}>
                          <View style={{ ...styles.dnDot, backgroundColor: colour }} />
                          <Text style={sl.isProject ? styles.dnName : styles.dnNameQ}>{sl.name}</Text>
                          <Text style={styles.dnHrs}>{fmtHM(sl.minutes)}</Text>
                          <Text style={styles.dnPct}>{sl.pct}%</Text>
                        </View>
                      </View>
                    );
                  });
                })()}
              </View>
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

                    {/* Only where somebody is paying. On an internal project
                        the question was never put, and "Billable 0h" would read
                        as a judgement on work never meant to be charged for. */}
                    {p.cls === 'billable' && (
                      <View style={styles.pSplit}>
                        <Text style={styles.pSplitB}>Billable {fmtHMWide(p.split.billable)}</Text>
                        <Text style={styles.pSplitN}>Not billable {fmtHMWide(p.split.nonBillable)}</Text>
                      </View>
                    )}
                    {p.cls === 'unclassified' && (
                      <Text style={styles.pSplitU}>
                        No project type set — these hours are reported as not classified.
                      </Text>
                    )}

                    <View style={styles.pActs}>
                      {/* KEYED ON THE ANSWER TOO. Since mig 824 one name can
                          appear twice in this list with different answers. */}
                      {p.activities.map((a, j) => (
                        <View key={`${a.name}-${a.billable}-${j}`} style={styles.pActRow}>
                          <View style={styles.pActTop}>
                            <Text style={styles.pActNo}>{j + 1}.</Text>
                            <Text style={a.itemised ? styles.pActName : styles.pActNameQ}>
                              {a.name}
                            </Text>
                            {p.cls === 'billable' && a.billable !== null && (
                              <Text style={a.billable ? styles.pActBill : styles.pActNBill}>
                                {a.billable ? 'Billable' : 'Not billable'}
                              </Text>
                            )}
                            <Text style={a.itemised ? styles.pActHrs : styles.pActHrsQ}>
                              {fmtHMWide(a.minutes)}
                            </Text>
                          </View>
                          <View style={styles.pActBar}>
                            <View style={styles.pActTrack}>
                              <View style={{
                                ...styles.pActFill,
                                width: `${Math.max(1.5, (a.minutes / widest) * 100)}%`,
                                backgroundColor: !a.itemised ? '#D1D5DB'
                                  : p.cls === 'billable' && a.billable === false ? '#CBD5E1'
                                  : colour,
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
              {/* The named non-project rows that used to sit here are now the
                  donut above, which says the same thing with a share against
                  the month. Two lists of Annual Leave and Training on one page
                  is one list too many — the same mistake as the project table
                  next to the project bars. */}
              <View style={styles.ltTotal}>
                <Text style={styles.ltTotalL}>Month recorded</Text>
                <Text style={styles.ltTotalV}>{fmtHM(data.recordedMinutes)}</Text>
              </View>
            </View>
          )}
        </View>

        {/* The approval block had a page to itself once the activity chart was
            removed — a sheet carrying one strip and a footer. It closes this
            page instead, which is where the totals it is signing off already
            are. */}
        {/* One unbreakable block. Split across a page boundary it produced the
            worst of both: the stamp closing page 4 and "End of Report" sitting
            alone on page 5.

            The document-ID line that used to follow is gone — the fixed footer
            prints the same id on every page and the header band prints the same
            generation time, so it was the third copy of two facts. */}
        <View wrap={false}>
          <ApprovalStamp data={data} />
          <Text style={styles.endLine}>— End of Report —</Text>
        </View>

      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
