import { View, Text } from '@react-pdf/renderer';
import { styles, dayState } from '../utils/pdfStyles';
import type { DayStateKey } from '../utils/pdfStyles';
import { fmtHM } from '../utils/dataTransforms';
import type { ExportDay } from '../types';

const DOW = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

/**
 * Classify a day into one of the six legend states.
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
  if (d.planned <= 0)        return d.minutes > 0 ? 'working' : 'weekend';
  if (d.minutes > d.planned) return 'over';
  if (d.minutes > 0)         return 'working';
  return d.date <= todayIso ? 'missing' : 'future';
}

export function CalendarGrid({ days, todayIso }: { days: ExportDay[]; todayIso: string }) {
  if (!days.length) return null;

  // Lead the first row with blanks so the 1st lands under its real weekday.
  const cells: (ExportDay | null)[] = [...Array(days[0].dow).fill(null), ...days];
  while (cells.length % 7 !== 0) cells.push(null);
  const rows: (ExportDay | null)[][] = [];
  for (let i = 0; i < cells.length; i += 7) rows.push(cells.slice(i, i + 7));

  // Only the states actually present are shown. A legend listing six colours
  // when four are on the page sends the reader hunting for two that aren't there.
  const present = new Set(days.map(d => classify(d, todayIso)));

  return (
    <View>
      <View style={styles.calHeadB}>
        {DOW.map(l => <Text key={l} style={styles.calHeadC}>{l}</Text>)}
      </View>

      {rows.map((row, ri) => (
        <View key={ri} style={styles.calRowB} wrap={false}>
          {row.map((d, ci) => {
            if (!d) return <View key={ci} style={styles.calSlot} />;
            const key = classify(d, todayIso);
            const st  = dayState[key];
            // A weekend and a day still to come record nothing BY NATURE. A dash
            // there would read as an omission; the empty cell is the honest mark.
            const caption = key === 'weekend' || key === 'future' ? ''
                          : d.isHoliday ? 'HOL'
                          : d.isLeave && d.minutes === 0 ? 'LV'
                          : d.minutes > 0 ? fmtHM(d.minutes)
                          : '—';
            return (
              <View key={ci} style={styles.calSlot}>
                <View style={{ ...styles.calBox, backgroundColor: st.bg, borderColor: st.border }}>
                  <Text style={{ ...styles.calDayB, color: st.ink }}>{d.day}</Text>
                  {caption ? <Text style={{ ...styles.calHrsB, color: st.ink }}>{caption}</Text> : null}
                  {st.dot ? <View style={{ ...styles.calDot, backgroundColor: st.dot }} /> : null}
                </View>
              </View>
            );
          })}
        </View>
      ))}

      <View style={styles.legend}>
        {(Object.keys(dayState) as DayStateKey[]).filter(k => present.has(k)).map(k => (
          <View key={k} style={styles.legendIt}>
            <View style={{ ...styles.legendSw, backgroundColor: dayState[k].bg, borderColor: dayState[k].border }} />
            <Text style={styles.legendTx}>{dayState[k].label}</Text>
          </View>
        ))}
      </View>
    </View>
  );
}
