import type { CSSProperties } from 'react';
import type { ExpenseStatus } from '../../types';

interface Props {
  status: ExpenseStatus;
  label?: string;        // override the display text (e.g. "In Review" when workflow is in_progress)
  style?: CSSProperties; // optional style override (e.g. amber for awaiting_clarification)
}

const labels: Record<ExpenseStatus, string> = {
  draft:            'Draft',
  submitted:        'Submitted',
  needs_update:     'Needs Update',
  manager_approved: 'Manager Approved',
  approved:         'Approved',
  rejected:         'Rejected',
};

export default function StatusBadge({ status, label, style }: Props) {
  return (
    <span className={`exp-status-badge exp-status-${status}`} style={style}>
      {label ?? labels[status] ?? status}
    </span>
  );
}
