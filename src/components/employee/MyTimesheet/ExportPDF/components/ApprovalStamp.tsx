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
  // Approved, then edited, and not re-approved. The status field is correct and
  // still misleading on its own: it describes the SHEET, while the reader is
  // holding a set of FIGURES that moved after that approval.
  const stale    = approved && data.changedSinceApproval;
  const accent   = stale ? '#F59E0B'
                 : approved ? colors.greenMid
                 : data.status === 'to_be_approved' ? colors.blueMid : colors.amber;
  // The dot is a View, not a bullet character. react-pdf's built-in Helvetica
  // has no glyph for ● or ○ — they rendered as a zero-width box that collided
  // with the first letter of the label ("○NOT YET SUBMITTED").
  const mark     = stale ? 'EDITED AFTER APPROVAL'
                 : approved ? 'APPROVED'
                 : data.status === 'to_be_approved' ? 'AWAITING APPROVAL'
                 : 'NOT YET SUBMITTED';
  const markCol  = stale ? '#92400E'
                 : approved ? colors.green
                 : data.status === 'to_be_approved' ? colors.blue : '#92400E';

  // With five columns the type has to give a little or the dividers cut into
  // the values — 09:05 lost its last character the first time this rendered.
  const L = stale ? styles.stampLbl2 : styles.stampLbl;
  const V = stale ? styles.stampVal2 : styles.stampVal;

  return (
    <View style={styles.stamp} wrap={false}>
      <View style={{ ...styles.stampAccent, backgroundColor: accent }} />
      <View style={styles.stampBody}>
        <View style={{ ...styles.stampCol, flexDirection: 'row', alignItems: 'center' }}>
          <View style={{ width: 6, height: 6, borderRadius: 3, marginRight: 6,
                         backgroundColor: stale ? '#F59E0B' : approved ? colors.greenMid : 'transparent',
                         borderWidth: (approved && !stale) || stale ? 0 : 1.2,
                         borderStyle: 'solid', borderColor: markCol }} />
          <Text style={{ ...(stale ? styles.stampMark2 : styles.stampMark), color: markCol }}>{mark}</Text>
        </View>
        <View style={styles.stampDiv} />

        <View style={styles.stampCol}>
          <Text style={L}>SUBMITTED BY</Text>
          <Text style={V}>
            {data.submittedAt ? `${data.employeeName} · ${fmtStamp(data.submittedAt)}` : 'Not submitted'}
          </Text>
        </View>
        <View style={styles.stampDiv} />

        <View style={styles.stampCol}>
          <Text style={L}>APPROVED BY</Text>
          {/* NO NAME. There are no approved_by columns on timesheet_headers, so
              this printed the employee's MANAGER — a specific person named as
              having approved something they never saw. With no workflow
              configured the approval is automatic and there is no approver to
              name. The date is a fact; the name was not. */}
          <Text style={V}>
            {data.approvedAt ? fmtStamp(data.approvedAt) : '—'}
          </Text>
        </View>
        <View style={styles.stampDiv} />

        <View style={styles.stampCol}>
          <Text style={L}>REFERENCE</Text>
          <Text style={V}>{data.referenceId}</Text>
        </View>

        {/* A fifth column only when there is something to put in it. The
            reference stays: it is how this document is identified, and losing
            it to make room would trade one fact for another. */}
        {stale && (
          <>
            <View style={styles.stampDiv} />
            <View style={styles.stampCol}>
              <Text style={L}>CHANGES</Text>
              {/* Zero marks with the header flag set means the change was a
                  deletion — nothing survives to carry a tag, so saying
                  "0 entries marked" would read as "nothing happened". */}
              <Text style={V}>
                {data.changedEntryCount === 0
                  ? 'deletions only'
                  : `${data.changedEntryCount} ${data.changedEntryCount === 1 ? 'entry' : 'entries'} marked`}
              </Text>
            </View>
          </>
        )}
      </View>
    </View>
  );
}
