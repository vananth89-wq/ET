import { View, Text } from '@react-pdf/renderer';
import { styles, dayState, colors } from '../utils/pdfStyles';
import type { DayStateKey } from '../utils/pdfStyles';
import { fmtHM } from '../utils/dataTransforms';
import type { ExportDay } from '../types';

const DOW = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

/**
 * Classify a day into one of the legend states.
 *
 * Order matters and encodes rules this system already enforces elsewhere:
 *   - A HOLIDAY OUTRANKS A WEEKEND. Same precedence as the calendar cell on
 *     screen (`6c4cde1`, mig 729) and as the day header on page 2.
 *   - "Missing" is only ever claimed about the PAST. A working day later this
 *     month has not been missed, it has not arrived — and mig 729 forbids
 *     recording it in advance for most types, so flagging it would be telling
 *     someone off for obeying the rules.
 */
function classify(d: ExportDay, todayIso: string): DayStateKey {
  if (d.isHoliday)           return 'holiday';
  if (d.isLeave)             return 'leave';
  // Hours on a day with no plan are hours beyond the schedule — the same thing
  // 'over' means on a working day, and what the OVER PLANNED KPI has always
  // counted. This used to return 'working', which drew weekend overtime in the
  // ordinary blue and made the grid disagree with the KPI above it.
  if (d.planned <= 0)        return d.minutes > 0 ? 'over' : 'weekend';
  if (d.minutes > d.planned) return 'over';
  if (d.minutes > 0)         return d.minutes < d.planned ? 'underPlan' : 'onPlan';
  return d.date <= todayIso ? 'missing' : 'future';
}

/**
 * The month grid, with each row's total in an eighth column.
 *
 * That column is why there is no separate "month timeline" chart: the shape of
 * the month is already here, a row at a time, beside the days that produced it.
 * A strip of week bars underneath would be the same five numbers a second time,
 * and page 3's weekly cards a third.
 */
export function CalendarGrid({ days, todayIso }: { days: ExportDay[]; todayIso: string }) {
  if (!days.length) return null;

  // Lead the first row with blanks so the 1st lands under its real weekday.
  const cells: (ExportDay | null)[] = [...Array(days[0].dow).fill(null), ...days];
  while (cells.length % 7 !== 0) cells.push(null);
  const rows: (ExportDay | null)[][] = [];
  for (let i = 0; i < cells.length; i += 7) rows.push(cells.slice(i, i + 7));

  // Only the states actually present are shown. A legend listing seven colours
  // when four are on the page sends the reader hunting for three that aren't.
  const present = new Set(days.map(d => classify(d, todayIso)));

  return (
    <View>
      <View style={styles.calHeadB}>
        {DOW.map(l => <Text key={l} style={styles.calHeadC}>{l}</Text>)}
        <Text style={styles.calWkHead}>WEEK</Text>
      </View>

      {rows.map((row, ri) => {
        // Totals come from the days actually in this row, so the figure can
        // never disagree with the cells beside it.
        const real    = row.filter(Boolean) as ExportDay[];
        const total   = real.reduce((s, d) => s + d.minutes, 0);
        const planned = real.reduce((s, d) => s + d.planned, 0);
        // A week is judged only once it is over — the same reasoning as the
        // `future` day state, and as the weekly cards on page 3.
        const done  = real.length > 0 && real[real.length - 1].date <= todayIso;
        const over  = planned > 0 && total > planned;
        const short = planned > 0 && done && total < planned;
        // Same rule as the weekly cards: RED for over, ordinary ink for
        // everything else. The '4h short' line below still says it. Amber used
        // to carry over-plan here while also carrying "Partial" on page 3 —
        // one colour meaning both too much and too little.
        const tone  = over ? '#B91C1C' : colors.ink2;

        return (
          <View key={ri} style={styles.calRowB} wrap={false}>
            {row.map((d, ci) => {
              if (!d) return <View key={ci} style={styles.calSlot} />;
              const key = classify(d, todayIso);
              const st  = dayState[key];
              // A weekend and a day still to come record nothing BY NATURE. A
              // dash would read as an omission; the empty cell is the honest mark.
              const caption = key === 'weekend' || key === 'future' ? ''
                            : d.isHoliday ? 'HOL'
                            : d.isLeave && d.minutes === 0 ? 'LV'
                            : d.minutes > 0 ? fmtHM(d.minutes)
                            : '—';
              const delta = key === 'over' ? d.minutes - d.planned : 0;
              return (
                <View key={ci} style={styles.calSlot}>
                  <View style={{ ...styles.calBox, backgroundColor: st.bg, borderColor: st.border, borderWidth: st.bw }}>
                    <Text style={{ ...styles.calDayB, color: st.ink }}>{d.day}</Text>
                    {caption ? <Text style={{ ...styles.calHrsB, color: st.ink }}>{caption}</Text> : null}
                    {delta > 0
                      ? <Text style={{ ...styles.calDelta, color: st.ink }}>+{fmtHM(delta)}</Text>
                      : st.dot ? <View style={{ ...styles.calDot, backgroundColor: st.dot }} /> : null}
                  </View>
                </View>
              );
            })}

            <View style={styles.calWkSlot}>
              {/* Nothing recorded is only worth reporting when the week both had
                  hours to give and has already gone. A week still ahead, or a
                  stub row that is all weekend, reports nothing rather than a
                  dash saying only that the obvious is true. */}
              {real.length === 0 || (total === 0 && (planned === 0 || !done)) ? null : (<>
                <Text style={{ ...styles.calWkVal, color: tone }}>
                  {total > 0 ? fmtHM(total) : '—'}{planned > 0 ? ` / ${fmtHM(planned)}` : ''}
                </Text>
                {over  && <Text style={{ ...styles.calWkSub, color: '#B91C1C' }}>{fmtHM(total - planned)} over</Text>}
                {short && <Text style={{ ...styles.calWkSub, color: colors.ink4 }}>{fmtHM(planned - total)} short</Text>}
              </>)}
            </View>
          </View>
        );
      })}

      <View style={styles.legend}>
        {(Object.keys(dayState) as DayStateKey[]).filter(k => present.has(k)).map(k => (
          <View key={k} style={{
            ...styles.legendPill,
            backgroundColor: dayState[k].bg,
            borderColor:     dayState[k].border,
          }}>
            <Text style={{ ...styles.legendTx, color: dayState[k].ink }}>{dayState[k].label}</Text>
          </View>
        ))}
      </View>
    </View>
  );
}
