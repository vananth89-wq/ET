import { View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import type { TimesheetExportData } from '../types';

const STATUS_CHIP: Record<TimesheetExportData['status'], { label: string; bg: string; fg: string }> = {
  to_be_submitted: { label: 'TO BE SUBMITTED',  bg: colors.amberLt,  fg: '#92400E' },
  to_be_approved:  { label: 'AWAITING APPROVAL', bg: colors.blueLt,  fg: colors.blue },
  approved:        { label: 'APPROVED',          bg: colors.greenLt, fg: colors.green },
};

/**
 * The blue band at the top of every page. It carries the real status rather
 * than a hard-coded "Approved" — a report that misstates its own standing is
 * worse than one that has no chip at all.
 */
export function PDFHeader({ data, subtitle }: { data: TimesheetExportData; subtitle?: string }) {
  const chip = STATUS_CHIP[data.status];
  return (
    <View style={styles.headerBand} fixed>
      <View style={styles.headerTop}>
        <View>
          <Text style={styles.headerTitle}>Employee Timesheet Report</Text>
          <Text style={styles.headerSub}>{subtitle ?? data.periodLabel}</Text>
          <Text style={styles.headerMeta}>
            {data.employeeName} · {data.employeeCode} · generated {data.generatedAt}
          </Text>
        </View>
        <View style={{ ...styles.chip, backgroundColor: chip.bg, color: chip.fg }}>
          <Text>{chip.label}</Text>
        </View>
      </View>
    </View>
  );
}
