import { View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import type { ExportDay } from '../types';
import { DOW_LABEL, fmtHours } from '../utils/dataTransforms';

/**
 * The month at a glance. Colour carries the meaning, so the legend below is not
 * decoration — a reader in greyscale needs it.
 *
 * Precedence matches the on-screen calendar: holiday outranks weekend, because a
 * public holiday falling on a Saturday is still a holiday.
 */
function cellTone(d: ExportDay): { bg: string; fg: string } {
  if (d.isHoliday)             return { bg: colors.purpleLt, fg: colors.purple };
  if (d.isLeave)               return { bg: colors.blueLt,   fg: colors.blue };
  if (d.isWeekend)             return { bg: colors.surface,  fg: colors.ink4 };
  if (d.minutes > 0)           return { bg: colors.greenLt,  fg: colors.green };
  return { bg: colors.redLt, fg: colors.red };            // a working day with nothing on it
}

export function CalendarGrid({ days }: { days: ExportDay[] }) {
  if (!days.length) return null;

  // Pad the first row so the 1st lands under its weekday.
  const lead  = days[0].dow;
  const cells: Array<ExportDay | null> = [...Array<null>(lead).fill(null), ...days];
  while (cells.length % 7 !== 0) cells.push(null);

  const rows: Array<Array<ExportDay | null>> = [];
  for (let i = 0; i < cells.length; i += 7) rows.push(cells.slice(i, i + 7));

  return (
    <View>
      <View style={styles.calHead}>
        {DOW_LABEL.map(d => <Text key={d} style={styles.calHeadCell}>{d.toUpperCase()}</Text>)}
      </View>

      {rows.map((row, ri) => (
        <View key={ri} style={styles.calRow}>
          {row.map((d, ci) => {
            if (!d) return <View key={ci} style={{ ...styles.calCell, backgroundColor: colors.white, borderColor: colors.white }} />;
            const tone = cellTone(d);
            return (
              <View key={ci} style={{ ...styles.calCell, backgroundColor: tone.bg }}>
                <Text style={{ ...styles.calDay, color: tone.fg }}>{d.day}</Text>
                <Text style={{ ...styles.calHrs, color: tone.fg }}>
                  {d.minutes > 0 ? `${fmtHours(d.minutes)}h` : ''}
                </Text>
              </View>
            );
          })}
        </View>
      ))}

      <View style={{ flexDirection: 'row', marginTop: 7, flexWrap: 'wrap' }}>
        {[
          ['Present',  colors.greenLt,  colors.green],
          ['Leave',    colors.blueLt,   colors.blue],
          ['Holiday',  colors.purpleLt, colors.purple],
          ['Weekend',  colors.surface,  colors.ink4],
          ['No entry', colors.redLt,    colors.red],
        ].map(([label, bg, fg]) => (
          <View key={label} style={{ flexDirection: 'row', alignItems: 'center', marginRight: 12 }}>
            <View style={{ width: 7, height: 7, borderRadius: 2, backgroundColor: bg, marginRight: 4 }} />
            <Text style={{ fontSize: 6.5, color: fg }}>{label}</Text>
          </View>
        ))}
      </View>
    </View>
  );
}
