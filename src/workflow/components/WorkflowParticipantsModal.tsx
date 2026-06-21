/**
 * WorkflowParticipantsModal
 *
 * Read-only routing chain view for approvers (and submitters).
 * Opened via the "View participants" pill on the task detail panel.
 *
 * Shows the same bubble-chain UI as WorkflowSubmitModal but:
 *   • No action buttons (no Approve / Submit)
 *   • Per-step live status overlays:
 *       ✓ green tick  — completed (step already approved)
 *       ● purple ring — active    (current pending step)
 *       ○ gray dashed — pending   (not yet reached)
 *   • Completed steps show "Approved by X · DD Mon" beneath the bubble
 *
 * Uses useWorkflowInstanceRouting() which calls get_workflow_instance_routing()
 * (mig 206) — a SECURITY DEFINER RPC accessible to both the submitter and any
 * task holder on the instance.
 */

import { useCallback, useRef, useState } from 'react';
import { useWorkflowInstanceRouting }     from '../hooks/useWorkflowInstanceRouting';
import type { RoutingStep }               from '../hooks/useWorkflowInstanceRouting';
import type { WfRoleMember }             from '../hooks/useWorkflowParticipants';

/* ── Shared helpers (mirrors WorkflowSubmitModal) ──────────────────────────── */

const AVATAR_COLORS = [
  '#0875e1', '#7c3aed', '#059669', '#d97706',
  '#dc2626', '#0891b2', '#9333ea', '#16a34a',
];

function avatarBg(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = name.charCodeAt(i) + ((h << 5) - h);
  return AVATAR_COLORS[Math.abs(h) % AVATAR_COLORS.length];
}

function initials(name: string): string {
  return name.split(' ').filter(Boolean).slice(0, 2).map(w => w[0].toUpperCase()).join('');
}

function fmtApprovedAt(iso: string | null | undefined): string {
  if (!iso) return '';
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

/* ── Status badge overlays ─────────────────────────────────────────────────── */

function CompletedTick() {
  return (
    <div style={{
      position: 'absolute', bottom: -2, right: -2,
      width: 18, height: 18, borderRadius: '50%',
      background: '#16a34a', border: '2px solid #f6f7f8',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      zIndex: 2,
    }}>
      <i className="fa-solid fa-check" style={{ fontSize: 8, color: '#fff' }} />
    </div>
  );
}

function StepNumberBadge({ n }: { n: number }) {
  return (
    <div style={{
      position: 'absolute', bottom: 0, right: 0,
      width: 16, height: 16, borderRadius: '50%',
      background: '#f0732b', border: '2px solid #f6f7f8',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}>
      <span style={{ fontSize: 8, fontWeight: 700, color: '#fff' }}>{n}</span>
    </div>
  );
}

/* ── Arrow ─────────────────────────────────────────────────────────────────── */

function Arrow() {
  return (
    <div style={{
      alignSelf: 'flex-start', marginTop: 14, flexShrink: 0,
      color: '#d1d5db', fontSize: 18, lineHeight: 1, padding: '0 2px',
    }}>
      <i className="fa-solid fa-arrow-right" />
    </div>
  );
}

/* ── Role group bubble with status overlay ─────────────────────────────────── */

const ROLE_AVATAR_COLORS = [
  '#7C3AED', '#059669', '#0891b2', '#d97706',
  '#dc2626', '#0875e1', '#9333ea', '#16a34a',
];
const STACKED_LIMIT = 4;

function RoleGroupBubble({
  step, stepNumber,
}: {
  step: RoutingStep;
  stepNumber: number;
}) {
  const members: WfRoleMember[] = step.roleMembers ?? [];
  const count   = members.length;
  const stacked = count > 0 && count <= STACKED_LIMIT;
  const roleName = step.resolvedName ?? step.stepName;

  const [tooltipStyle, setTooltipStyle] = useState<React.CSSProperties | null>(null);
  const groupRef = useRef<HTMLDivElement>(null);

  const showTip = useCallback(() => {
    if (!groupRef.current) return;
    const r = groupRef.current.getBoundingClientRect();
    setTooltipStyle({
      position: 'fixed',
      bottom:   window.innerHeight - r.top + 8,
      left:     r.left + r.width / 2,
      transform: 'translateX(-50%)',
      zIndex:   9999,
    });
  }, []);
  const hideTip = useCallback(() => setTooltipStyle(null), []);

  const isCompleted = step.status === 'completed';
  const isActive    = step.status === 'active';

  const avatarBorder = isActive
    ? '2.5px solid #7C3AED'
    : isCompleted
      ? '2px solid #16a34a'
      : '2px solid #e5e7eb';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, maxWidth: 110 }}>
      <div
        ref={groupRef}
        style={{ position: 'relative', cursor: count > 0 ? 'default' : undefined }}
        onMouseEnter={count > 0 ? showTip : undefined}
        onMouseLeave={count > 0 ? hideTip : undefined}
      >
        {stacked ? (
          <div style={{ display: 'flex', alignItems: 'center', position: 'relative' }}>
            {members.map((m, i) => (
              <div key={i} style={{
                width: 40, height: 40, borderRadius: '50%',
                background: ROLE_AVATAR_COLORS[i % ROLE_AVATAR_COLORS.length],
                color: '#fff', fontSize: 12, fontWeight: 500,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                border: avatarBorder,
                marginLeft: i > 0 ? -12 : 0,
                position: 'relative', zIndex: count - i, flexShrink: 0,
              }}>
                {initials(m.name)}
              </div>
            ))}
            {isCompleted
              ? <CompletedTick />
              : <StepNumberBadge n={stepNumber} />}
          </div>
        ) : (
          <div style={{ position: 'relative' }}>
            <div style={{
              width: 48, height: 48, borderRadius: '50%',
              background: '#d97706', color: '#fff',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 20, border: avatarBorder,
            }}>
              <i className="fa-solid fa-users" />
            </div>
            {isCompleted
              ? <CompletedTick />
              : <StepNumberBadge n={stepNumber} />}
          </div>
        )}

        {/* Fixed-position tooltip (escapes overflow-x clipping) */}
        {tooltipStyle && count > 0 && (
          <div style={{
            ...tooltipStyle,
            background: '#fff', border: '1px solid #e5e7eb',
            borderRadius: 10, padding: '10px 12px',
            minWidth: 200, boxShadow: '0 4px 24px rgba(0,0,0,0.14)',
            pointerEvents: 'none',
          }}>
            <div style={{
              fontSize: 10, fontWeight: 600, color: '#7C3AED',
              textTransform: 'uppercase', letterSpacing: '0.05em',
              marginBottom: 8, display: 'flex', alignItems: 'center', gap: 5,
            }}>
              <i className="fa-solid fa-users" style={{ fontSize: 11 }} />
              {roleName} — {count} member{count !== 1 ? 's' : ''}
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
              {members.map((m, i) => (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <div style={{
                    width: 28, height: 28, borderRadius: '50%',
                    background: ROLE_AVATAR_COLORS[i % ROLE_AVATAR_COLORS.length],
                    color: '#fff', fontSize: 10, fontWeight: 600,
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    flexShrink: 0,
                  }}>
                    {initials(m.name)}
                  </div>
                  <div>
                    <div style={{ fontSize: 12, fontWeight: 500, color: '#1f2937' }}>{m.name}</div>
                    {m.jobTitle && <div style={{ fontSize: 11, color: '#6b7280' }}>{m.jobTitle}</div>}
                  </div>
                </div>
              ))}
            </div>
            <div style={{
              borderTop: '1px solid #f3f4f6', marginTop: 8, paddingTop: 6,
              fontSize: 10, color: '#6b7280',
              display: 'flex', alignItems: 'center', gap: 4,
            }}>
              <i className={`fa-solid ${step.approvalMode === 'ALL_OF' ? 'fa-check-double' : 'fa-bolt'}`}
                 style={{ fontSize: 10, color: '#7C3AED' }} />
              {step.approvalMode === 'ALL_OF'
                ? 'All members must approve'
                : 'First to approve advances the step'}
            </div>
            <div style={{
              position: 'absolute', bottom: -5, left: '50%',
              transform: 'translateX(-50%) rotate(45deg)',
              width: 8, height: 8, background: '#fff',
              borderRight: '1px solid #e5e7eb', borderBottom: '1px solid #e5e7eb',
            }} />
          </div>
        )}
      </div>

      <div style={{ fontSize: 11, fontWeight: 500, textAlign: 'center', lineHeight: 1.3, color: '#1f2937', maxWidth: 90, wordBreak: 'break-word' }}>
        {roleName}
      </div>
      {count > 0 && (
        <div style={{ fontSize: 9, background: '#F5F3FF', color: '#7C3AED', border: '1px solid #DDD6FE', borderRadius: 999, padding: '2px 7px', whiteSpace: 'nowrap' }}>
          {count} member{count !== 1 ? 's' : ''}
        </div>
      )}
      <StatusLabel step={step} />
    </div>
  );
}

/* ── Status sub-label beneath each bubble ──────────────────────────────────── */

function StatusLabel({ step }: { step: RoutingStep }) {
  if (step.status === 'completed') {
    return (
      <div style={{ fontSize: 10, color: '#16a34a', textAlign: 'center', lineHeight: 1.3, maxWidth: 90 }}>
        {step.approvedByName
          ? <>Approved by {step.approvedByName}<br />{fmtApprovedAt(step.approvedAt)}</>
          : 'Approved'}
      </div>
    );
  }
  if (step.status === 'active') {
    return (
      <div style={{ fontSize: 10, color: '#7C3AED', textAlign: 'center', lineHeight: 1.3 }}>
        Awaiting approval
      </div>
    );
  }
  return (
    <div style={{ fontSize: 10, color: '#9ca3af', textAlign: 'center', lineHeight: 1.3 }}>
      {step.resolvedDesignation ?? ''}
    </div>
  );
}

/* ── Single-approver bubble ────────────────────────────────────────────────── */

function StepBubble({
  step, stepNumber,
}: {
  step: RoutingStep;
  stepNumber: number;
}) {
  const name         = step.resolvedName ?? step.stepName;
  const isMgr        = step.approverType === 'MANAGER' || step.approverType === 'DEPT_HEAD';
  const isCompleted  = step.status === 'completed';
  const isActive     = step.status === 'active';

  const bg = isMgr ? '#d97706' : avatarBg(name);

  const borderStyle = isActive
    ? '2.5px solid #7C3AED'
    : isCompleted
      ? '2px solid #16a34a'
      : '2px solid transparent';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, maxWidth: 90 }}>
      <div style={{ position: 'relative' }}>
        <div style={{
          width: 48, height: 48, borderRadius: '50%',
          background: bg, color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: isMgr ? 20 : 14, fontWeight: 500,
          border: borderStyle,
        }}>
          {isMgr
            ? <i className="fa-solid fa-user-tie" />
            : initials(name)}
        </div>
        {isCompleted
          ? <CompletedTick />
          : <StepNumberBadge n={stepNumber} />}
      </div>

      <div style={{ fontSize: 11, fontWeight: 500, textAlign: 'center', lineHeight: 1.3, color: '#1f2937', maxWidth: 80, wordBreak: 'break-word' }}>
        {name}
      </div>

      <StatusLabel step={step} />
    </div>
  );
}

/* ── Main modal ────────────────────────────────────────────────────────────── */

interface Props {
  open:            boolean;
  onClose:         () => void;
  instanceId:      string | null | undefined;
  /** Display title, e.g. "Reeshatha A — Profile – Contact Details" */
  title:           string;
  submittedByName: string | null | undefined;
}

export default function WorkflowParticipantsModal({
  open, onClose, instanceId, title, submittedByName,
}: Props) {
  const { loading, error, steps } = useWorkflowInstanceRouting(
    open ? instanceId : null,
  );

  if (!open) return null;

  const approvers = steps.filter(s => !s.isCC);
  const ccSteps   = steps.filter(s => s.isCC);

  const initiatorLabel = submittedByName ?? 'Submitter';

  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, zIndex: 9100,
        background: 'rgba(15,23,42,0.40)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: 20,
      }}
    >
      <div
        onClick={e => e.stopPropagation()}
        style={{
          background: '#fff', width: '100%', maxWidth: 560,
          maxHeight: '88vh', display: 'flex', flexDirection: 'column',
          borderRadius: 6, border: '1px solid #d8d8d8',
          boxShadow: '0 8px 40px rgba(0,0,0,0.18)',
          overflow: 'hidden',
        }}
      >
        {/* Purple accent strip */}
        <div style={{ height: 5, background: '#7C3AED', flexShrink: 0 }} />

        {/* Header */}
        <div style={{ padding: '18px 24px 0', flexShrink: 0 }}>
          <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
            <div>
              <div style={{ fontSize: 16, fontWeight: 500, color: '#111827', marginBottom: 3 }}>
                Workflow participants
              </div>
              <div style={{ fontSize: 13, color: '#6b7280' }}>{title}</div>
            </div>
            <button
              onClick={onClose}
              style={{
                background: 'none', border: 'none',
                cursor: 'pointer', color: '#9ca3af', fontSize: 20, padding: 0, lineHeight: 1,
              }}
              aria-label="Close"
            >
              <i className="fa-solid fa-xmark" />
            </button>
          </div>
          <div style={{ height: 1, background: '#ebebeb', marginTop: 16 }} />
        </div>

        {/* Body */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '18px 24px' }}>

          {/* Section label */}
          <div style={{
            fontSize: 11, fontWeight: 600, letterSpacing: '0.06em',
            textTransform: 'uppercase', color: '#7C3AED', marginBottom: 14,
          }}>
            <i className="fa-solid fa-route" style={{ marginRight: 5, fontSize: 12 }} />
            Approval routing
          </div>

          {/* Routing chain */}
          <div style={{
            padding: '16px 14px', background: '#f6f7f8',
            border: '1px solid #ebebeb', borderRadius: 6,
            overflowX: 'auto', marginBottom: 14,
          }}>
            {loading ? (
              <div style={{ textAlign: 'center', padding: '16px 0', color: '#9ca3af', fontSize: 13 }}>
                <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
                Loading routing…
              </div>
            ) : error ? (
              <div style={{ textAlign: 'center', padding: '12px 0', color: '#dc2626', fontSize: 13 }}>
                <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
                Could not load participants.
              </div>
            ) : (
              <div style={{ display: 'flex', alignItems: 'flex-start', gap: 4, minWidth: 'max-content' }}>

                {/* Initiator bubble */}
                <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, maxWidth: 80 }}>
                  <div style={{ position: 'relative' }}>
                    <div style={{
                      width: 48, height: 48, borderRadius: '50%',
                      background: '#0875e1', color: '#fff',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      fontSize: 14, fontWeight: 500,
                    }}>
                      {initials(initiatorLabel)}
                    </div>
                    {/* Green "online" dot */}
                    <div style={{
                      position: 'absolute', bottom: 0, right: 0,
                      width: 14, height: 14, borderRadius: '50%',
                      background: '#22c55e', border: '2px solid #f6f7f8',
                    }} />
                  </div>
                  <div style={{ fontSize: 11, fontWeight: 500, color: '#1f2937', textAlign: 'center', lineHeight: 1.3 }}>
                    {initiatorLabel}
                  </div>
                  <div style={{ fontSize: 10, color: '#6b7280', textAlign: 'center' }}>Initiator</div>
                </div>

                {/* Step bubbles */}
                {approvers.map((step, i) => (
                  <div key={step.stepOrder} style={{ display: 'flex', alignItems: 'flex-start', gap: 4 }}>
                    <Arrow />
                    {step.approverType === 'ROLE'
                      ? <RoleGroupBubble step={step} stepNumber={i + 1} />
                      : <StepBubble     step={step} stepNumber={i + 1} />}
                  </div>
                ))}

                {/* Complete node */}
                {approvers.length > 0 && (
                  <>
                    <Arrow />
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, maxWidth: 80 }}>
                      <div style={{
                        width: 48, height: 48, borderRadius: '50%',
                        background: '#e5e7eb', color: '#9ca3af',
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                        fontSize: 20, border: '2px dashed #d1d5db',
                      }}>
                        <i className="fa-solid fa-circle-check" />
                      </div>
                      <div style={{ fontSize: 11, fontWeight: 500, color: '#6b7280', textAlign: 'center' }}>
                        Complete
                      </div>
                    </div>
                  </>
                )}
              </div>
            )}
          </div>

          {/* CC row */}
          {ccSteps.length > 0 && (
            <div style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '10px 14px', background: '#f6f7f8',
              border: '1px solid #ebebeb', borderRadius: 6,
              marginBottom: 14, flexWrap: 'wrap',
            }}>
              <i className="fa-solid fa-envelope" style={{ fontSize: 14, color: '#7C3AED', flexShrink: 0 }} />
              <span style={{ fontSize: 12, color: '#6b7280', flexShrink: 0 }}>CC:</span>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {ccSteps.map(s => (
                  <span key={s.stepOrder} style={{
                    fontSize: 12, background: '#dbeafe', color: '#1e40af',
                    padding: '3px 10px', borderRadius: 999, fontWeight: 500,
                  }}>
                    {s.resolvedName ?? s.stepName}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* Legend */}
          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
              <div style={{ width: 10, height: 10, borderRadius: '50%', background: '#16a34a' }} />
              <span style={{ fontSize: 11, color: '#6b7280' }}>Approved</span>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
              <div style={{ width: 10, height: 10, borderRadius: '50%', background: '#7C3AED' }} />
              <span style={{ fontSize: 11, color: '#6b7280' }}>Awaiting approval</span>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
              <div style={{ width: 10, height: 10, borderRadius: '50%', background: '#e5e7eb', border: '1px dashed #d1d5db' }} />
              <span style={{ fontSize: 11, color: '#6b7280' }}>Pending</span>
            </div>
          </div>
        </div>

        {/* Footer — close only */}
        <div style={{
          flexShrink: 0, padding: '12px 24px',
          borderTop: '1px solid #ebebeb',
          display: 'flex', justifyContent: 'flex-end',
        }}>
          <button
            onClick={onClose}
            className="btn-cancel"
            style={{ borderRadius: 999, padding: '8px 24px', fontSize: 13 }}
          >
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
