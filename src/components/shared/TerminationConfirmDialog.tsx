/**
 * TerminationConfirmDialog
 *
 * Confirmation step before submit_termination fires.
 * Uses WorkflowSubmitModal — the standard app-wide submission dialog that
 * shows the approval routing chain, CC recipients, and an optional comment.
 *
 * Design spec: docs/termination-design.md §6.2
 */

import WorkflowSubmitModal from '../../workflow/components/WorkflowSubmitModal';

interface Props {
  isSelf:          boolean;
  terminationDate: string;
  employeeName?:   string;
  onConfirm:       (comment: string) => void;
  onCancel:        () => void;
  submitting:      boolean;
  submitError?:    string | null;
}

export default function TerminationConfirmDialog({
  isSelf,
  terminationDate,
  employeeName,
  onConfirm,
  onCancel,
  submitting,
  submitError,
}: Props) {
  const action   = isSelf ? 'resignation' : 'termination';
  const fmtDate  = new Date(terminationDate + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
  const title    = `Submit ${action.charAt(0).toUpperCase() + action.slice(1)} — ${fmtDate}`;
  const moduleCode = 'termination';

  return (
    <WorkflowSubmitModal
      open
      onClose={onCancel}
      onConfirm={onConfirm}
      confirming={submitting}
      submitError={submitError ?? null}
      title={title}
      moduleCode={moduleCode}
      employeeName={employeeName}
    />
  );
}
