/**
 * WorkflowStatusBadge
 *
 * Small pill badge showing the current status of a workflow instance or task.
 * Colours are consistent with the app's existing status badge pattern.
 *
 * Usage:
 *   <WorkflowStatusBadge status="in_progress" />
 *   <WorkflowStatusBadge status="approved" size="sm" />
 */

import type { InstanceStatus } from '../hooks/useWorkflowInstance';

type TaskStatus = 'pending' | 'approved' | 'rejected' | 'reassigned' | 'skipped' | 'cancelled' | 'returned';
type AnyStatus = InstanceStatus | TaskStatus | 'awaiting_clarification';

interface WorkflowStatusBadgeProps {
  status: AnyStatus;
  size?:  'sm' | 'md';
}

const CONFIG: Record<AnyStatus, { label: string; bg: string; color: string }> = {
  // Instance statuses
  in_progress: { label: 'In Progress', bg: '#EFF6FF', color: '#1D4ED8' },
  approved:    { label: 'Approved',    bg: '#DCFCE7', color: '#15803D' },
  rejected:    { label: 'Rejected',    bg: '#FEE2E2', color: '#B91C1C' },
  withdrawn:   { label: 'Withdrawn',   bg: '#F3F4F6', color: '#6B7280' },
  cancelled:   { label: 'Cancelled',   bg: '#F3F4F6', color: '#6B7280' },
  // New statuses (migration 048)
  awaiting_clarification: { label: 'Awaiting Clarification', bg: '#FEF3C7', color: '#B45309' },
  // Task statuses
  pending:     { label: 'Pending',     bg: '#FEF9C3', color: '#A16207' },
  reassigned:  { label: 'Reassigned',  bg: '#F5F3FF', color: '#7C3AED' },
  skipped:     { label: 'Skipped',     bg: '#F3F4F6', color: '#6B7280' },
  returned:    { label: 'Returned',    bg: '#FEF3C7', color: '#B45309' },
};

export function WorkflowStatusBadge({ status, size = 'md' }: WorkflowStatusBadgeProps) {
  const cfg = CONFIG[status] ?? { label: status, bg: '#F3F4F6', color: '#374151' };

  return (
    <span style={{
      display:       'inline-flex',
      alignItems:    'center',
      gap:           4,
      padding:       size === 'sm' ? '2px 8px' : '4px 10px',
      borderRadius:  9999,
      fontSize:      size === 'sm' ? 11 : 12,
      fontWeight:    600,
      background:    cfg.bg,
      color:         cfg.color,
      whiteSpace:    'nowrap',
      letterSpacing: '0.02em',
    }}>
      {cfg.label}
    </span>
  );
}
