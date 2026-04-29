/**
 * WorkflowGateBanner
 *
 * Drop this at the top of any screen that has a workflow gate.
 * It automatically shows when a workflow assignment is configured for the module.
 *
 * Usage (standalone — hook runs internally):
 *   <WorkflowGateBanner moduleCode="department_edit" />
 *
 * Usage (parent already batched the lookup, e.g. useProfileWorkflowGates):
 *   <WorkflowGateBanner
 *     moduleCode="profile_personal"
 *     active={activeGates.has('profile_personal')}
 *     pendingCount={pendingCounts['profile_personal']}
 *   />
 *
 * When visible it signals to the user that saves will be routed through an
 * approval workflow rather than applied immediately. When pendingCount > 0 a
 * secondary line surfaces how many changes are currently in flight.
 */

import { useWorkflowGate } from '../hooks/useWorkflowGate';

interface Props {
  moduleCode:    string;
  /** Override the default action description shown in the banner */
  actionLabel?:  string;
  /**
   * When provided, skips the internal useWorkflowGate query and uses this
   * value directly. Use this when a parent has already batched the lookup
   * (e.g. useProfileWorkflowGates) to avoid redundant DB calls.
   */
  active?:       boolean;
  /**
   * When provided together with `active`, shows how many changes for this
   * module are currently pending approval. Skips the internal pendingCount
   * fetch from the hook.
   */
  pendingCount?: number;
}

export default function WorkflowGateBanner({
  moduleCode,
  actionLabel,
  active,
  pendingCount: pendingCountProp,
}: Props) {
  // Only run the hook when `active` is not supplied by the parent
  const gate = useWorkflowGate(active !== undefined ? '' : moduleCode);

  const hasWorkflow  = active       !== undefined ? active            : gate.hasWorkflow;
  const loading      = active       !== undefined ? false             : gate.loading;
  const pendingCount = pendingCountProp !== undefined ? pendingCountProp : gate.pendingCount;

  if (loading || !hasWorkflow) return null;

  const action = actionLabel ?? 'changes saved on this screen';

  return (
    <div style={{
      display:      'flex',
      alignItems:   'flex-start',
      gap:          10,
      background:   '#FEF9C3',
      border:       '1px solid #D97706',
      borderRadius: 8,
      padding:      '10px 14px',
      marginBottom: 16,
      fontSize:     13,
      color:        '#92400E',
    }}>
      <i
        className="fa-solid fa-circle-bolt"
        style={{ marginTop: 2, flexShrink: 0, color: '#D97706' }}
      />
      <div>
        <div>
          <strong>Workflow approval required</strong> — {action} will be submitted
          for approval before taking effect. You can track the status under{' '}
          <strong>My Requests</strong>.
        </div>
        {pendingCount > 0 && (
          <div style={{ marginTop: 4, color: '#B45309' }}>
            <i className="fa-solid fa-hourglass-half" style={{ marginRight: 5 }} />
            {pendingCount === 1
              ? '1 change currently pending approval'
              : `${pendingCount} changes currently pending approval`}
          </div>
        )}
      </div>
    </div>
  );
}
