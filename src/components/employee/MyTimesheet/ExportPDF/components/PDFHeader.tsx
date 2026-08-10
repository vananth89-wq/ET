import { View, Text, Image } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import { fmtStamp } from '../utils/dataTransforms';
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
 *
 * The logo sits on a WHITE CHIP rather than being recoloured white. The mark is
 * dark navy on transparent and would vanish outright on this band, and
 * repainting a brand asset is not a call this component should be making. The
 * chip keeps the supplied colours exactly as drawn. If a white-on-blue lockup
 * is ever produced properly, drop it in and delete the chip's background.
 *
 * The right column reads logo first, then status. Above the title the logo made
 * the band taller on every page of every report; here it fills space that was
 * already empty and costs nothing.
 *
 * `logoDataUrl` is null whenever the fetch failed or no logo is configured, and
 * the band then reads exactly as it did before — the title alone. A report is
 * still a correct report without a logo on it.
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
            {data.employeeName} · {data.employeeCode} · generated {fmtStamp(data.generatedAt)}
          </Text>
        </View>

        <View style={styles.headerRight}>
          {data.logoDataUrl ? (
            <View style={styles.logoChip}>
              {/* Height only — react-pdf keeps the intrinsic aspect ratio, so a
                  replacement logo of any proportion still fits the band. */}
              <Image style={styles.logoImg} src={data.logoDataUrl} />
            </View>
          ) : null}
          <View style={{
            ...styles.chip, backgroundColor: chip.bg, color: chip.fg,
            ...(data.logoDataUrl ? styles.chipBelow : {}),
          }}>
            <Text>{chip.label}</Text>
          </View>
        </View>
      </View>
    </View>
  );
}
