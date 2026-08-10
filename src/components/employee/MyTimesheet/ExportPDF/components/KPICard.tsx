import { View, Text } from '@react-pdf/renderer';
import { styles } from '../utils/pdfStyles';

/** One figure, its label, and an optional qualifier. No narrative — raw KPIs. */
export function KPICard({ label, value, sub, tone }: {
  label: string; value: string; sub?: string; tone?: string;
}) {
  return (
    <View style={styles.kpiCard}>
      <View style={styles.kpiInner}>
        <Text style={styles.kpiLbl}>{label.toUpperCase()}</Text>
        <Text style={tone ? { ...styles.kpiVal, color: tone } : styles.kpiVal}>{value}</Text>
        {sub ? <Text style={styles.kpiSub}>{sub}</Text> : null}
      </View>
    </View>
  );
}
