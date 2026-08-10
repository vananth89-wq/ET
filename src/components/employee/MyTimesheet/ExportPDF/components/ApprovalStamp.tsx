import { View, Text } from '@react-pdf/renderer';
import { styles, colors } from '../utils/pdfStyles';
import type { TimesheetExportData } from '../types';
import { fmtStamp } from '../utils/dataTransforms';

/**
 * The status block at the foot of the report.
 *
 * The brief asked for a green APPROVED stamp rendered only when the sheet is
 * approved. Nothing in this system can reach `approved` yet — submit is a bare
 * column update with no workflow behind it — so that stamp would never appear
 * and page 4 would simply end, leaving a reader unable to tell whether the sheet
 * was signed off or merely printed. The block therefore always renders and
 * states whichever status is true; the green mark still arrives unchanged the
 * day the workflow lands.
 *
 * There are no submitted_by / approved_by columns on timesheet_headers, so the
 * submitter is the employee themselves — which is a fact, not an assumption —
 * and the approver is shown only once an approval timestamp exists.
 */
export function ApprovalStamp({ data }: { data: TimesheetExportData }) {
  const approved = data.status === 'approved' && !!data.approvedAt;
  const accent   = approved ? colors.greenMid : data.status === 'to_be_approved' ? colors.blueMid : colors.amber;
  // The dot is a View, not a bullet character. react-pdf's built-in Helvetica
  // has no glyph for ● or ○ — they rendered as a zero-width box that collided
  // with the first letter of the label ("○NOT YET SUBMITTED").
  const mark     = approved ? 'APPROVED'
                 : data.status === 'to_be_approved' ? 'AWAITING APPROVAL'
                 : 'NOT YET SUBMITTED';
  const markCol  = approved ? colors.green : data.status === 'to_be_approved' ? colors.blue : '#92400E';

  return (
    <View style={styles.stamp} wrap={false}>
      <View style={{ ...styles.stampAccent, backgroundColor: accent }} />
      <View style={styles.stampBody}>
        <View style={{ ...styles.stampCol, flexDirection: 'row', alignItems: 'center' }}>
          <View style={{ width: 6, height: 6, borderRadius: 3, marginRight: 6,
                         backgroundColor: approved ? colors.greenMid : 'transparent',
                         borderWidth: approved ? 0 : 1.2, borderStyle: 'solid', borderColor: markCol }} />
          <Text style={{ ...styles.stampMark, color: markCol }}>{mark}</Text>
        </View>
        <View style={styles.stampDiv} />

        <View style={styles.stampCol}>
          <Text style={styles.stampLbl}>SUBMITTED BY</Text>
          <Text style={styles.stampVal}>
            {data.submittedAt ? `${data.employeeName} · ${fmtStamp(data.submittedAt)}` : 'Not submitted'}
          </Text>
        </View>
        <View style={styles.stampDiv} />

        <View style={styles.stampCol}>
          <Text style={styles.stampLbl}>APPROVED BY</Text>
          <Text style={styles.stampVal}>
            {data.approvedAt ? `${data.manager} · ${fmtStamp(data.approvedAt)}` : 'Pending'}
          </Text>
        </View>
        <View style={styles.stampDiv} />

        <View style={styles.stampCol}>
          <Text style={styles.stampLbl}>REFERENCE</Text>
          <Text style={styles.stampVal}>{data.referenceId}</Text>
        </View>
      </View>
    </View>
  );
}
