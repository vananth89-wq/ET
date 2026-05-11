import type { ExpenseStatus } from '../../types';

interface Props {
  status: ExpenseStatus;
  label?: string;   // override the display text (e.g. "In Review" when workflow is in_progress)
}

const labels: Record<ExpenseStatus, string> = {
  draft:            'Draft',
  submitted:        'Submitted',
  needs_update:     'Needs Update',
  manager_approved: 'Manager Approved',
  approved:         'Approved',
  rejected:         'Rejected',
};

export default function StatusBadge({ status, label }: Props) {
  return (
    <span className={`exp-status-badge exp-status-${status}`}>
      {label ?? labels[status] ?? status}
    </span>
  );
}
