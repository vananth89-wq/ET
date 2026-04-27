import type { ExpenseStatus } from '../../types';

interface Props { status: ExpenseStatus; }

const labels: Record<ExpenseStatus, string> = {
  draft:            'Draft',
  submitted:        'Submitted',
  manager_approved: 'Manager Approved',
  approved:         'Approved',
  rejected:         'Rejected',
};

export default function StatusBadge({ status }: Props) {
  return (
    <span className={`exp-status-badge exp-status-${status}`}>
      {labels[status] ?? status}
    </span>
  );
}
