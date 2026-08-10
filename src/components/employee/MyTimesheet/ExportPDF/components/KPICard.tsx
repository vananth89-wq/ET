import { View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import { KPIIcon } from './KPIIcon';
import type { IconName } from './KPIIcon';

/**
 * One summary tile: a coloured rail across the top, a glyph and an uppercase
 * label, a large value in the rail's colour, and a caption saying what the
 * number counts.
 *
 * The caption is not decoration. "22" alone is unreadable; "22 scheduled days"
 * is a fact. Every tile carries one.
 */
export function KPICard({
  label, value, unit, caption, icon, tone = colors.blueMid,
}: {
  label: string;
  value: string;
  unit?: string;
  caption: string;
  icon: IconName;
  tone?: string;
}) {
  return (
    <View style={styles.kpiSlot}>
      <View style={styles.kpiBox}>
        <View style={{ ...styles.kpiRail, backgroundColor: tone }} />
        <View style={styles.kpiPad}>
          <View style={styles.kpiHead}>
            <KPIIcon name={icon} color={tone} />
            <Text style={styles.kpiLblB}>{label.toUpperCase()}</Text>
          </View>
          <Text style={{ ...styles.kpiValB, color: tone }}>
            {value}
            {unit ? <Text style={{ ...styles.kpiUnit, color: tone }}>{unit}</Text> : null}
          </Text>
          <Text style={styles.kpiSubB}>{caption}</Text>
        </View>
      </View>
    </View>
  );
}
