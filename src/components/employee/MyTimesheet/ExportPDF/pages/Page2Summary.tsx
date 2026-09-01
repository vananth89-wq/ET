import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors, matrixTone } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { SectionHead } from '../components/SectionHead';
import { billableSharePct } from '../../billability';
import { fmtHM, fmtHMClock } from '../utils/dataTransforms';
import { buildSummaryMatrix } from '../utils/summaryMatrix';
import type { MatrixTone, MatrixColumn, MatrixMonthRow } from '../utils/summaryMatrix';
import type { TimesheetExportData } from '../types';

/**
 * The Summary report's body: one table, the whole month.
 *
 * It replaces the Detail report's Daily Entries — five pages of cards for a
 * 31-day month — with a single grid of day × project. What it gives up is
 * activities and notes, which is the entire point: this is the page a manager
 * scans to see where a month went, and the Detail export is still there for
 * anyone who needs to audit a particular day.
 *
 * PAGE 1 AND PAGE 3 ARE UNCHANGED. Both reports carry the same employee block,
 * the same KPIs, the same calendar and the same project breakdown, because the
 * two documents are one report with one section swapped — not two reports that
 * happen to look alike and will drift apart.
 */

// ── fitting the table to the page ──────────────────────────────────────────
//
// Row height is solved from what the month produced, so a light month gets
// airy rows and a dense one gets tight rows, and the table lands just above the
// footer either way. It is not a fixed height: a 31-day month with only four
// weekend bands has eight more rows than a 28-day one, and a single constant
// would either overflow onto a second page or leave a hand's width of white.
//
// These constants are CALIBRATED, not derived — react-pdf cannot measure
// mid-render, so there is no way to close the loop at runtime. They were fitted
// against the HTML prototype and should be re-checked against a real export if
// the header band, the hero strip or the section furniture change height.
// Getting them slightly wrong is safe in one direction only: DAY_H_MAX is what
// stops a sparse month from overflowing, so leave the ceiling alone.
// Measured, not estimated: at 586 these same three fixtures spill onto a fourth
// page. 574 leaves ~10pt of headroom for the one thing this calculation cannot
// see — a long column label wrapping to two lines and making the header row
// taller. Raise it only with a render in front of you.
const BODY_BUDGET = 574;   // pt of page left for the table, after all furniture
const HEAD_H      = 15;
const WEEK_H      = 17;
const BAND_H      = 11;
const MONTH_H     = 21;
const DAY_H_MIN   = 10.5;
const DAY_H_MAX   = 21;

/** Below this many data columns the table would be mostly gutter, so a bar
 *  showing each day against its target takes the slack instead. */
const BAR_UNTIL_COLUMNS = 4;

const W_DAY = 15, W_TOTAL = 11.5, W_COMPLETE = 13.5;

const toneInk = (t: MatrixTone): string =>
  t === 'met' ? matrixTone.met
  : t === 'short' ? matrixTone.short
  : t === 'over' || t === 'missing' ? matrixTone.over
  : colors.ink2;

/** The ten-segment completion bar. Reads at a glance across five week rows in a
 *  way a continuous track does not — five bars of slightly different length all
 *  look the same; five counts of lit segments do not. */
function Pips({ pct, tone, onDark }: { pct: number; tone: MatrixTone; onDark?: boolean }) {
  const on = Math.max(0, Math.min(10, Math.round(pct / 10)));
  const lit = onDark ? colors.white : toneInk(tone);
  const off = onDark ? 'rgba(255,255,255,0.28)' : '#DDE3EB';
  return (
    <View style={styles.mxPips}>
      {Array.from({ length: 10 }, (_, i) => (
        <View key={i} style={{ ...styles.mxPip, backgroundColor: i < on ? lit : off }} />
      ))}
    </View>
  );
}

function Cell({ minutes, width, ink }: { minutes: number; width: string; ink?: string }) {
  // A blank cell in a grid of figures reads as a rendering fault. A dot says
  // "nothing here" and keeps the column's rhythm.
  return minutes > 0
    ? <Text style={{ ...styles.mxCell, width, color: ink ?? colors.ink2 }}>{fmtHMClock(minutes)}</Text>
    : <Text style={{ ...styles.mxCell, width, color: '#D5DAE2' }}>·</Text>;
}

export function Page2Summary({ data }: { data: TimesheetExportData }) {
  const m = buildSummaryMatrix(data);
  const n = m.columns.length;

  const showBar = n > 0 && n <= BAR_UNTIL_COLUMNS;
  const rest    = 100 - W_DAY - W_TOTAL - W_COMPLETE;
  const barW    = showBar ? Math.max(0, rest - n * 11) : 0;
  const colW    = n > 0 ? (rest - barW) / n : rest;

  const wCol   = `${colW}%`;
  const wBar   = `${barW}%`;
  const wDay   = `${W_DAY}%`;
  const wTot   = `${W_TOTAL}%`;
  const wCmp   = `${W_COMPLETE}%`;
  const spanW  = `${colW * n + barW}%`;   // a band row's single wide cell

  const fixed = HEAD_H + m.weekRows * WEEK_H + m.bandRows * BAND_H + MONTH_H;
  const dayH  = Math.max(DAY_H_MIN,
                  Math.min(DAY_H_MAX, m.dayRows > 0 ? (BODY_BUDGET - fixed) / m.dayRows : DAY_H_MAX));

  // The hero's headline is the month row's own figure, not a second calculation
  // of it — two arithmetics for one number is how a report ends up disagreeing
  // with itself.
  const monthRow = m.rows.find((r): r is MatrixMonthRow => r.kind === 'month');
  const monthPct = monthRow?.pct ?? 0;
  const monthTone: MatrixTone =
    m.plannedMinutes <= 0 ? 'none'
    : m.totalMinutes > m.plannedMinutes ? 'over'
    : m.totalMinutes >= m.plannedMinutes ? 'met'
    : 'short';

  // Shown only where the month actually has chargeable time to report, or an
  // untyped project whose hours nobody has classified yet.
  const billShare = billableSharePct(data.billSplit);
  const showBill  = data.billSplit.billable > 0 || data.billSplit.unclassified > 0
                 || data.projectActivities.some(p => p.cls === 'billable');

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Monthly Summary · ${data.periodLabel}`} />
      <View style={styles.body}>

        {/* The strip that makes this a dashboard rather than a spreadsheet: the
            three numbers a reviewer opens the file for, before any cell. */}
        <View style={styles.mxHero}>
          <View style={styles.mxHeroCell}>
            <Text style={styles.mxHeroLbl}>RECORDED</Text>
            <Text style={styles.mxHeroVal}>{fmtHM(m.totalMinutes)}</Text>
          </View>
          <View style={styles.mxHeroCell}>
            <Text style={styles.mxHeroLbl}>PLANNED</Text>
            <Text style={{ ...styles.mxHeroVal, color: colors.ink4 }}>{fmtHM(m.plannedMinutes)}</Text>
          </View>
          <View style={styles.mxHeroCell}>
            <Text style={styles.mxHeroLbl}>COMPLETE</Text>
            <Text style={{ ...styles.mxHeroVal, color: toneInk(monthTone) }}>{monthPct}%</Text>
          </View>
          {/* Migs 820/822/825. Hours over WORKED hours -- absence is out of the
              denominator, exactly as on the Utilisation report and on the
              Monthly Summary this file is exported from. Printed only when
              there is something to say: an employee who never touches a
              billable project would otherwise carry a permanent 0% on a
              document that goes to their approver. */}
          {showBill && (
            <View style={styles.mxHeroCell}>
              <Text style={styles.mxHeroLbl}>BILLABLE</Text>
              <Text style={{ ...styles.mxHeroVal, color: '#047857' }}>
                {fmtHM(data.billSplit.billable)}
              </Text>
            </View>
          )}
          <View style={styles.mxHeroBar}>
            <View style={styles.mxTrack}>
              <View style={{ ...styles.mxTrackFill,
                             width: `${Math.min(100, monthPct)}%`,
                             backgroundColor: toneInk(monthTone) }} />
            </View>
            <Text style={styles.mxHeroCap}>
              {fmtHM(m.totalMinutes)} of {fmtHM(m.plannedMinutes)} recorded · {n} {n === 1 ? 'column' : 'columns'} this month
              {showBill && billShare !== null && ` · ${billShare}% of ${fmtHM(data.billSplit.worked)} worked is billable`}
              {showBill && data.billSplit.unclassified > 0 &&
                ` · ${fmtHM(data.billSplit.unclassified)} on a project with no type set`}
            </Text>
          </View>
        </View>

        <SectionHead sub="every day of the month · h:mm">Hours by day and project</SectionHead>

        {/* Header row */}
        <View style={styles.mxHead}>
          <Text style={{ ...styles.mxHeadDay, width: wDay }}>DAY</Text>
          {showBar ? <View style={{ width: wBar }} /> : null}
          {m.columns.map(c => (
            <View key={c.key} style={{ width: wCol, alignItems: 'flex-end' }}>
              <View style={{ ...styles.mxDot, backgroundColor: colorFor(c, m.columns) }} />
              <Text style={styles.mxHeadCol}>{c.label}</Text>
            </View>
          ))}
          <Text style={{ ...styles.mxHeadMeta, width: wTot }}>TOTAL</Text>
          <Text style={{ ...styles.mxHeadMeta, width: wCmp }}>COMPLETE</Text>
        </View>

        {m.rows.map((r, i) => {
          if (r.kind === 'band') {
            return (
              <View key={`b${i}`} style={{ ...styles.mxBand, height: BAND_H,
                                           backgroundColor: r.isHoliday ? '#F8F5FF' : '#F5F7FA' }}>
                <Text style={{ ...styles.mxBandLead, width: wDay,
                               color: r.isHoliday ? '#8B72CE' : '#94A0B0' }}>{r.lead}</Text>
                <Text style={{ ...styles.mxBandTxt, width: spanW,
                               color: r.isHoliday ? '#9B87D6' : '#A6AEBA' }}>{r.text}</Text>
                <View style={{ width: wTot }} />
                <View style={{ width: wCmp }} />
              </View>
            );
          }

          if (r.kind === 'week') {
            return (
              <View key={`w${i}`} style={{ ...styles.mxWeek, height: WEEK_H }}>
                <View style={{ width: wDay, flexDirection: 'row', alignItems: 'baseline' }}>
                  <Text style={styles.mxWeekLbl}>{r.label}</Text>
                  <Text style={{ ...styles.mxWeekRange, marginLeft: 4 }}>{r.range}</Text>
                </View>
                {showBar ? <View style={{ width: wBar }} /> : null}
                {r.cells.map((v, j) => (
                  <Cell key={j} minutes={v} width={wCol} ink={colors.blue} />
                ))}
                <Text style={{ ...styles.mxWeekTot, width: wTot }}>{fmtHM(r.total)}</Text>
                <View style={{ width: wCmp, flexDirection: 'row', alignItems: 'center',
                               justifyContent: 'flex-end' }}>
                  {r.pct === null
                    ? <Text style={{ ...styles.mxCmpVal, color: colors.ink4 }}>—</Text>
                    : (<>
                        <Pips pct={r.pct} tone={r.tone} />
                        <Text style={{ ...styles.mxCmpVal, color: toneInk(r.tone) }}>{r.pct}%</Text>
                      </>)}
                </View>
              </View>
            );
          }

          if (r.kind === 'month') {
            return (
              <View key="m" style={{ ...styles.mxMonth, height: MONTH_H }}>
                <Text style={{ ...styles.mxMonthLbl, width: wDay }}>MONTH TOTAL</Text>
                {showBar ? <View style={{ width: wBar }} /> : null}
                {r.cells.map((v, j) => (
                  <Text key={j} style={{ ...styles.mxMonthCell, width: wCol }}>
                    {v > 0 ? fmtHMClock(v) : '·'}
                  </Text>
                ))}
                <Text style={{ ...styles.mxMonthTot, width: wTot }}>{fmtHM(r.total)}</Text>
                <View style={{ width: wCmp, flexDirection: 'row', alignItems: 'center',
                               justifyContent: 'flex-end' }}>
                  <Pips pct={r.pct} tone="none" onDark />
                  <Text style={{ ...styles.mxCmpVal, color: colors.white }}>{r.pct}%</Text>
                </View>
              </View>
            );
          }

          const missing = r.tone === 'missing';
          const bg = missing ? '#FEF6F6'
                   : r.planned <= 0 ? '#F7F9FB'
                   : r.zebra ? '#FAFBFD' : colors.white;
          return (
            <View key={r.date} style={{ ...styles.mxRow, height: dayH, backgroundColor: bg }}>
              <View style={{ width: wDay, flexDirection: 'row', alignItems: 'center' }}>
                <Text style={{ ...styles.mxDow, color: missing ? '#C05252' : colors.ink4 }}>
                  {r.label.slice(0, 3)}
                </Text>
                <Text style={{ ...styles.mxDayNum, color: missing ? '#C05252' : colors.ink2 }}>
                  {r.label.slice(4)}
                </Text>
                {r.tag ? (
                  <Text style={{ ...styles.mxTag,
                                 color:           missing ? '#B91C1C' : r.planned <= 0 ? '#8A93A0' : '#6D28D9',
                                 backgroundColor: missing ? '#FDECEC' : r.planned <= 0 ? '#F1F3F6' : '#F3EEFF' }}>
                    {r.tag}
                  </Text>
                ) : null}
              </View>

              {showBar ? (
                <View style={{ width: wBar, paddingRight: 10, justifyContent: 'center' }}>
                  {r.total > 0 ? (
                    <View style={styles.mxTrack}>
                      <View style={{
                        ...styles.mxTrackFill,
                        // Neutral by choice. A month at 49% would otherwise be a
                        // wall of amber bars, which is noise, not a signal — the
                        // traffic light lives on the figures.
                        backgroundColor: r.tone === 'over' ? '#F0A9A9' : '#B9C8EE',
                        width: `${Math.min(100, Math.round((r.total / (r.planned || r.total)) * 100))}%`,
                      }} />
                    </View>
                  ) : null}
                </View>
              ) : null}

              {r.cells.map((v, j) => <Cell key={j} minutes={v} width={wCol} />)}

              <Text style={{ ...styles.mxTotal, width: wTot, color: toneInk(r.tone) }}>
                {r.total > 0 ? fmtHMClock(r.total) : '—'}
              </Text>
              <View style={{ width: wCmp }} />
            </View>
          );
        })}

        <View style={styles.mxKey}>
          {([['met', 'Met'], ['short', 'Short'], ['over', 'Over'],
             ['missing', 'Missing'], ['holiday', 'Holiday'], ['weekoff', 'Week off']] as const)
            .map(([k, label]) => (
              <View key={k} style={styles.mxKeyItem}>
                <View style={{ ...styles.mxKeyDot, backgroundColor: KEY_INK[k] }} />
                <Text style={styles.mxKeyTxt}>{label}</Text>
              </View>
            ))}
        </View>
      </View>
      <PDFFooter documentId={data.documentId} generatedAt={data.generatedAt} />
    </Page>
  );
}

const KEY_INK: Record<string, string> = {
  met: matrixTone.met, short: matrixTone.short, over: matrixTone.over,
  missing: '#F09A9A', holiday: colors.purple, weekoff: '#CBD3DD',
};

/** Column dots repeat the palette page 3's donut uses, so a reader who has seen
 *  one page recognises the colours on the other. */
function colorFor(c: MatrixColumn, all: MatrixColumn[]): string {
  const PALETTE = ['#2563EB', '#7C3AED', '#0D9488', '#D97706', '#DB2777',
                   '#0891B2', '#65A30D', '#9333EA', '#E11D48', '#475569'];
  return PALETTE[all.indexOf(c) % PALETTE.length];
}
