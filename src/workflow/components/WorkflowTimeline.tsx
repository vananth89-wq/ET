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
  resubmitted:              { icon: 'fa-reply',          iconColor: '#2563EB', label: 'Submitter Responded'      },
  returned_to_previous_step:{ icon: 'fa-backward-step',  iconColor: '#374151', label: 'Returned to Previous Step'},
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
    return (
      <p style={{ color: '#9CA3AF', fontSize: 13, padding: '16px 0' }}>
        No activity yet.
      </p>
    );
  }

  return (
    <div style={{ position: 'relative', paddingLeft: 32 }}>
      {/* Vertical line */}
      <div style={{
        position: 'absolute',
        left:     10,
        top:      8,
        bottom:   8,
        width:    2,
        background: '#E5E7EB',
        borderRadius: 2,
      }} />

      {/* History events */}
      {history
        .filter(h => h.action !== 'step_advanced') // hide internal advance events
        .map(event => {
          const cfg = ACTION_CONFIG[event.action] ??
            { icon: 'fa-circle', iconColor: '#9CA3AF', label: event.action };

          return (
            <div key={event.id} style={{ display: 'flex', gap: 12, marginBottom: 20, position: 'relative' }}>
              {/* Icon dot */}
              <div style={{
                position:     'absolute',
                left:         -32,
                width:        20,
                height:       20,
                borderRadius: '50%',
                background:   '#fff',
                border:       `2px solid ${cfg.iconColor}`,
                display:      'flex',
                alignItems:   'center',
                justifyContent: 'center',
                flexShrink:   0,
              }}>
                <i className={`fas ${cfg.icon}`}
                   style={{ fontSize: 9, color: cfg.iconColor }} />
              </div>

              {/* Content */}
              <div style={{ flex: 1 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  <span style={{ fontWeight: 600, fontSize: 13, color: '#111827' }}>
                    {cfg.label}
                  </span>
                  {event.actorName && (
                    <span style={{ fontSize: 12, color: '#6B7280' }}>
                      by {event.actorName}
                    </span>
                  )}
                  {event.stepOrder && (
                    <span style={{
                      fontSize: 11, color: '#9CA3AF',
                      background: '#F3F4F6', borderRadius: 4,
                      padding: '1px 6px',
                    }}>
                      Step {event.stepOrder}
                    </span>
                  )}
                </div>
                <div style={{ fontSize: 12, color: '#9CA3AF', marginTop: 2 }}>
                  {formatDate(event.createdAt)}
                </div>
                {event.notes && (
                  <div style={{
                    marginTop: 6, fontSize: 12, color: '#374151',
                    background: '#F9FAFB', border: '1px solid #E5E7EB',
                    borderRadius: 6, padding: '6px 10px',
                  }}>
                    {event.notes}
                  </div>
                )}
              </div>
            </div>
          );
        })}

      {/* Pending tasks (awaiting action) */}
      {status === 'in_progress' && pendingTasks.map(task => (
        <div key={task.id} style={{ display: 'flex', gap: 12, marginBottom: 20, position: 'relative' }}>
          <div style={{
            position:     'absolute',
            left:         -32,
            width:        20,
            height:       20,
            borderRadius: '50%',
            background:   '#FEF9C3',
            border:       '2px dashed #D97706',
            display:      'flex',
            alignItems:   'center',
            justifyContent: 'center',
            flexShrink:   0,
          }}>
            <i className="fas fa-hourglass-half" style={{ fontSize: 8, color: '#D97706' }} />
          </div>

          <div style={{ flex: 1 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
              <span style={{ fontWeight: 600, fontSize: 13, color: '#92400E' }}>
                Awaiting: {task.stepName}
              </span>
              {task.assigneeName && (
                <span style={{ fontSize: 12, color: '#6B7280' }}>
                  → {task.assigneeName}
                </span>
              )}
              <span style={{
                fontSize: 11, background: '#FEF9C3', color: '#92400E',
                borderRadius: 4, padding: '1px 6px',
              }}>
                Step {task.stepOrder}
              </span>
            </div>
            {task.dueAt && (
              <div style={{ fontSize: 12, color: '#9CA3AF', marginTop: 2 }}>
                Due: {formatDate(task.dueAt)}
              </div>
            )}
          </div>
        </div>
      ))}

      {/* Awaiting clarification — workflow is paused, waiting on submitter */}
      {status === 'awaiting_clarification' && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 20, position: 'relative' }}>
          <div style={{
            position:       'absolute',
            left:           -32,
            width:          20,
            height:         20,
            borderRadius:   '50%',
            background:     '#FEF3C7',
            border:         '2px dashed #B45309',
            display:        'flex',
            alignItems:     'center',
            justifyContent: 'center',
            flexShrink:     0,
          }}>
            <i className="fas fa-comment-dots" style={{ fontSize: 8, color: '#B45309' }} />
          </div>

          <div style={{ flex: 1 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
              <span style={{ fontWeight: 600, fontSize: 13, color: '#92400E' }}>
                Awaiting your response
              </span>
              <span style={{
                fontSize: 11, background: '#FEF3C7', color: '#B45309',
                border: '1px solid #FDE68A',
                borderRadius: 4, padding: '1px 6px',
                display: 'flex', alignItems: 'center', gap: 3,
              }}>
                <i className="fas fa-bell" style={{ fontSize: 8 }} />
                Needs your input
              </span>
            </div>
            <div style={{ fontSize: 12, color: '#B45309', marginTop: 3 }}>
              An approver has requested clarification — respond via My Requests to resume.
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
