/**
 * WorkflowTimeline
 *
 * Displays the approval history of a workflow instance as a vertical timeline.
 * Shows each action (submitted, approved, rejected, etc.) with actor, time,
 * and optional notes.
 *
 * Usage:
 *   <WorkflowTimeline history={history} tasks={tasks} currentStep={instance.currentStep} />
 */

import type { WorkflowActionLogRow, WorkflowTaskRow } from '../hooks/useWorkflowInstance';

interface WorkflowTimelineProps {
  history:     WorkflowActionLogRow[];
  tasks:       WorkflowTaskRow[];
  currentStep: number;
  status:      string;
}

// Actions generated purely by the workflow engine — never shown to end users.
const SYSTEM_ACTIONS = new Set([
  'step_advanced', 'completed', 'update_form_opened',
  'auto_skipped', 'step_removed', 'cc_notified',
  'skipped',       // duplicate-approver skip
]);

// Notes written by the workflow engine (not user input). These may appear on
// otherwise-visible actions (e.g. 'submitted') and should not render as a
// user comment. All engine notes start with one of these prefixes.
const ENGINE_NOTE_PREFIXES = [
  'Legacy ROLE step',
  'Multi-approver step',
  'ROLE step auto-skipped',
  'Step removed:',
  'No ',           // "No MANAGER found — step skipped"
  'CC step —',
];

function isEngineNote(notes: string | null): boolean {
  if (!notes) return false;
  return ENGINE_NOTE_PREFIXES.some(p => notes.startsWith(p));
}

const ACTION_CONFIG: Record<string, { icon: string; iconColor: string; label: string }> = {
  submitted:                { icon: 'fa-paper-plane',    iconColor: '#2563EB', label: 'Submitted'                },
  approved:                 { icon: 'fa-circle-check',   iconColor: '#16A34A', label: 'Approved'                 },
  rejected:                 { icon: 'fa-circle-xmark',   iconColor: '#DC2626', label: 'Rejected'                 },
  reassigned:               { icon: 'fa-arrows-rotate',  iconColor: '#7C3AED', label: 'Reassigned'               },
  withdrawn:                { icon: 'fa-rotate-left',    iconColor: '#6B7280', label: 'Withdrawn'                },
  completed:                { icon: 'fa-flag-checkered', iconColor: '#16A34A', label: 'Completed'                },
  cancelled:                { icon: 'fa-ban',            iconColor: '#6B7280', label: 'Cancelled'                },
  step_advanced:            { icon: 'fa-chevron-right',  iconColor: '#2563EB', label: 'Forwarded'                },
  // Return / clarification actions (migration 048)
  returned_to_initiator:    { icon: 'fa-comment-dots',   iconColor: '#B45309', label: 'Returned for Clarification' },
  resubmitted:              { icon: 'fa-reply',          iconColor: '#2563EB', label: 'Submitter Responded'           },
  updated_and_resubmitted:  { icon: 'fa-pen-to-square',  iconColor: '#2563EB', label: 'Submitter Updated & Responded' },
  returned_to_previous_step:{ icon: 'fa-backward-step',  iconColor: '#374151', label: 'Returned to Previous Step'    },
};

function formatDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day:    '2-digit',
    month:  'short',
    year:   'numeric',
    hour:   '2-digit',
    minute: '2-digit',
  }).format(new Date(iso));
}

export function WorkflowTimeline({
  history,
  tasks,
  currentStep: _currentStep,
  status,
}: WorkflowTimelineProps) {
  // Build a combined list: history events + pending future steps
  const pendingTasks = tasks.filter(t => t.status === 'pending');

  if (history.length === 0 && pendingTasks.length === 0) {
    return <p className="wft-empty">No activity yet.</p>;
  }

  return (
    <div className="wft-container">
      {/* Vertical line */}
      <div className="wft-line" />

      {/* History events */}
      {history
        .filter(h => !SYSTEM_ACTIONS.has(h.action))
        .map(event => {
          const cfg = ACTION_CONFIG[event.action] ??
            { icon: 'fa-circle', iconColor: '#9CA3AF', label: event.action };

          return (
            <div key={event.id} className="wft-event-row">
              {/* Icon dot — border colour is dynamic */}
              <div
                className="wft-event-dot"
                style={{ background: '#fff', border: `2px solid ${cfg.iconColor}` }}
              >
                <i className={`fas ${cfg.icon}`} style={{ fontSize: 9, color: cfg.iconColor }} />
              </div>

              {/* Content */}
              <div className="wft-event-content">
                <div className="wft-event-header">
                  <span className="wft-event-label">{cfg.label}</span>
                  {event.actorName && (
                    <span className="wft-event-actor">by {event.actorName}</span>
                  )}
                  {event.stepOrder && event.action !== 'submitted' && (
                    <span className="wft-step-badge">Step {event.stepOrder}</span>
                  )}
                </div>
                <div className="wft-event-time">{formatDate(event.createdAt)}</div>
                {event.notes && !isEngineNote(event.notes) && (
                  <div
                    className="wft-comment-box"
                    style={{ borderLeftColor: cfg.iconColor }}
                  >
                    <div className="wft-comment-label">💬 Comment</div>
                    <div className="wft-comment-text">{event.notes}</div>
                  </div>
                )}
              </div>
            </div>
          );
        })}

      {/* Pending tasks (awaiting action) */}
      {status === 'in_progress' && pendingTasks.map(task => (
        <div key={task.id} className="wft-event-row">
          <div className="wft-pending-dot">
            <i className="fas fa-hourglass-half" style={{ fontSize: 8, color: '#D97706' }} />
          </div>

          <div className="wft-event-content">
            <div className="wft-event-header">
              <span className="wft-pending-label">Awaiting: {task.stepName}</span>
              {task.assigneeName && (
                <span className="wft-event-actor">→ {task.assigneeName}</span>
              )}
              <span className="wft-pending-step-badge">Step {task.stepOrder}</span>
            </div>
            {task.dueAt && (
              <div className="wft-event-time">Due: {formatDate(task.dueAt)}</div>
            )}
          </div>
        </div>
      ))}

      {/* Awaiting clarification — workflow is paused, waiting on submitter */}
      {status === 'awaiting_clarification' && (
        <div className="wft-event-row">
          <div className="wft-clarification-dot">
            <i className="fas fa-comment-dots" style={{ fontSize: 8, color: '#B45309' }} />
          </div>

          <div className="wft-event-content">
            <div className="wft-event-header">
              <span className="wft-clarification-label">Awaiting your response</span>
              <span className="wft-clarification-badge">
                <i className="fas fa-bell" style={{ fontSize: 8 }} />
                Needs your input
              </span>
            </div>
            <div className="wft-clarification-note">
              Review the approver note above, update the details, then hit Resubmit.
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
