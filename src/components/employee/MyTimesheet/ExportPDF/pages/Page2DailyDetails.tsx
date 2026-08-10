import { Page, View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import { PDFHeader } from '../components/PDFHeader';
import { PDFFooter } from '../components/PDFFooter';
import { fmtHM, fmtHMWide, fmtDateLong, fmtMonthYear } from '../utils/dataTransforms';
import type { TimesheetExportData, ExportEntry, ExportDay } from '../types';

/**
 * Daily entries, grouped by day, one card per PROJECT.
 *
 * A card is one timesheet entry — which, since mig 726, IS one (day, time type,
 * project). Its activities are listed inside it with their own hours, because
 * per-activity hours are the point of mig 727 and a reviewer asking "what did
 * the six hours on WISAYAH go on?" should not have to open the app.
 *
 * The activity list is itself two columns — name left, hours right-aligned — so
 * the figures stack and can be checked against the card total beside them. No
 * rule between them: the card border and the aligned column already do that
 * work, and a line through the middle of a bordered box is a third fence. They were a single "Code Review — 2h" string, which put
 * the hours wherever the name happened to end and made the one thing a reviewer
 * wants to do, add them up, harder than it needed to be.
 *
 * Deliberately NOT in the mockup, because this system does not have them:
 *   - Time In / Time Out / Break. Prowess is duration-only by design. Those
 *     columns would be empty on every row of every report ever generated.
 *   - The red "Overtime" tag. There is no overtime concept, no calculation and
 *     no approval path for one. The day chip reports recorded against planned
 *     and turns amber when it runs over — the same signal the calendar cell
 *     gives on screen — without naming a policy that does not exist.
 *
 * Days with nothing recorded are omitted entirely, as in the mockup. The month
 * grid on page 1 is where the gaps are visible.
 */

/** Left accent, matching getEntryBadge() in MyTimesheet so the report and the
 *  calendar colour the same thing the same way. */
function accentFor(e: ExportEntry): string {
  if (e.kind === 'holiday') return colors.purple;
  if (e.kind === 'leave')   return colors.amber;
  return e.project ? colors.blueMid : colors.greenMid;
}

function DayChip({ day, total }: { day: ExportDay | undefined; total: number }) {
  const planned = day?.planned ?? 0;

  // A holiday's system-generated row carries no hours, so both sides are zero
  // and the chip would read as a lone dash — which looks like a rendering fault
  // rather than a fact. The purple holiday tag beside the date already says
  // everything this day has to say.
  if (planned <= 0 && total <= 0) return null;

  // No planned hours means a weekend or a holiday — there is nothing to compare
  // against, so comparing would invent a target. Weekend work is real work.
  if (planned <= 0) {
    return (
      <Text style={{ ...styles.dayChip, color: colors.ink3, backgroundColor: colors.surface }}>
        {fmtHM(total)}
      </Text>
    );
  }

  const over = total > planned;
  return (
    <Text style={{
      ...styles.dayChip,
      color:           over ? '#92400E'    : colors.blue,
      backgroundColor: over ? colors.amberLt : colors.blueLt,
    }}>
      {fmtHM(total)} / {fmtHM(planned)}
    </Text>
  );
}

function EntryCard({ e }: { e: ExportEntry }) {
  return (
    <View style={styles.card} wrap={false}>
      <View style={{ ...styles.cardAccent, backgroundColor: accentFor(e) }} />
      <View style={styles.cardBody}>
        <View style={styles.cardRow}>
          <View style={{ width: '26%', paddingRight: 8 }}>
            <Text style={styles.cardProj}>{e.project ?? e.typeName}</Text>
            {/* When the card is a project, the time type still matters — Work
                and Training on the same project are different things. */}
            {e.project ? <Text style={styles.tiny}>{e.typeName}</Text> : null}
          </View>

          <View style={{ width: '56%', paddingRight: 8 }}>
            {e.activities.length === 0 && <Text style={styles.cardActNil}>—</Text>}
            {e.activities.map((a, i) => (
              <View key={`${a.name}-${i}`} style={styles.actLine}>
                <Text style={styles.actName}>{a.name}</Text>
                {/* A pre-727 entry carries names with no split. A blank cell in
                    a column of figures reads as a rendering fault; a dash says
                    the thing that is true — no figure was ever recorded. */}
                {a.minutes > 0
                  ? <Text style={styles.actMins}>{fmtHMWide(a.minutes)}</Text>
                  : <Text style={styles.actMinsNil}>—</Text>}
              </View>
            ))}
          </View>

          <Text style={{ ...styles.cardHrs, width: '18%' }}>{fmtHM(e.minutes)}</Text>
        </View>

        {e.notes ? (
          <View style={styles.cardNoteWrap}>
            <Text style={styles.cardNote}>{e.notes}</Text>
          </View>
        ) : null}
      </View>
    </View>
  );
}

export function Page2DailyDetails({ data }: { data: TimesheetExportData }) {
  const dayByDate = new Map(data.monthDays.map(d => [d.date, d]));

  // Grouped, then sorted by date explicitly. The query does order by entry_date,
  // so insertion order is usually already right — but "usually" is not a basis
  // for a document someone prints and signs, and any future caller that appends
  // an entry to state without re-sorting would silently print August 9th before
  // August 7th. ISO dates sort correctly as strings.
  const groups = new Map<string, ExportEntry[]>();
  for (const e of data.entries) {
    const list = groups.get(e.date);
    if (list) list.push(e); else groups.set(e.date, [e]);
  }
  const ordered = [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0]));

  const monthLabel = data.monthDays[0] ? fmtMonthYear(data.monthDays[0].date) : '';
  const total = data.entries.reduce((s, e) => s + e.minutes, 0);

  return (
    <Page size="A4" style={styles.page}>
      <PDFHeader data={data} subtitle={`Daily Attendance · ${data.periodLabel}`} />
      <View style={styles.body}>
        <Text style={styles.sectionTitle}>Daily Entries — {monthLabel}</Text>
        <View style={styles.sectionRule} />

        {groups.size === 0 && (
          <Text style={styles.tdMute}>No entries recorded for this period.</Text>
        )}

        {ordered.map(([date, list]) => {
          const day     = dayByDate.get(date);
          const dayTot  = list.reduce((s, e) => s + e.minutes, 0);
          const holiday = day?.holidayName;

          return (
            <View key={date}>
              {/* Heading, column labels and the FIRST card are one unwrappable
                  unit, so a date can never strand itself at the foot of a page
                  with its entries overleaf. minPresenceAhead was the obvious
                  alternative and it is far too blunt: it reserved space for the
                  whole day and pushed a group that would have fitted onto the
                  next page, losing half of page 2 to white. The rest of the
                  cards flow normally and pack tight. */}
              <View wrap={false}>
                <View style={styles.dayHead}>
                  <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                    <Text style={styles.dayName}>{fmtDateLong(date)}</Text>
                    {/* A holiday outranks "non-working day" here too — it names
                        the holiday rather than reporting a blank weekend. */}
                    {holiday ? <Text style={styles.dayTag}>{holiday}</Text> : null}
                  </View>
                  <DayChip day={day} total={dayTot} />
                </View>

                <View style={styles.colLbls}>
                  <Text style={{ ...styles.colLbl, width: '26%' }}>PROJECT</Text>
                  <Text style={{ ...styles.colLbl, width: '56%' }}>ACTIVITIES</Text>
                  <Text style={{ ...styles.colLbl, width: '18%', textAlign: 'right' }}>HOURS</Text>
                </View>

                <EntryCard e={list[0]} />
              </View>

              {list.slice(1).map((e, i) => <EntryCard key={`${date}-${i + 1}`} e={e} />)}

              <View style={styles.dayTotal} wrap={false}>
                <Text style={styles.dayTotalLbl}>DAILY TOTAL</Text>
                <Text style={styles.dayTotalVal}>{fmtHM(dayTot)}</Text>
              </View>
            </View>
          );
        })}

        {groups.size > 0 && (
          <View style={styles.monthTotal} wrap={false}>
            <Text style={styles.monthTotalLbl}>
              MONTH TOTAL · {data.entries.length} {data.entries.length === 1 ? 'entry' : 'entries'}
              {' '}across {groups.size} {groups.size === 1 ? 'day' : 'days'}
            </Text>
            <Text style={styles.monthTotalVal}>{fmtHM(total)}</Text>
          </View>
        )}
      </View>
      <PDFFooter documentId={data.documentId} />
    </Page>
  );
}
