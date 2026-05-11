/**
 * WorkflowSubmitModal — Workday-style submission confirmation dialog.
 *
 * Shows before any workflow submission:
 *   • Horizontal approver routing chain (avatars + arrows)
 *   • CC pill row
 *   • Optional comment textarea
 *   • Cancel / Submit (orange pill) buttons
 *
 * Usage:
 *   <WorkflowSubmitModal
 *     open={!!confirmPending}
 *     onClose={() => setConfirmPending(null)}
 *     onConfirm={comment => executeGatedSubmit(comment)}
 *     confirming={saving}
 *     title="Personal Information"
 *     moduleCode="profile_personal"
 *     employeeName="Priya Sharma"
 *   />
 */

import { useState }  from 'react';
import { useAuth }   from '../../contexts/AuthContext';
import { useWorkflowParticipants } from '../hooks/useWorkflowParticipants';
import type { WfParticipant }       from '../hooks/useWorkflowParticipants';

/* ── Avatar helpers ────────────────────────────────────────────────────────── */

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

/* ── Step bubble ───────────────────────────────────────────────────────────── */

function StepBubble({
  participant,
  stepNumber,
}: {
  participant: WfParticipant;
  stepNumber: number;
}) {
  const name    = participant.resolvedName ?? participant.stepName;
  // approver_type is stored UPPERCASE in the DB (ROLE, MANAGER, SPECIFIC_USER, etc.)
  const isRole  = participant.approverType === 'ROLE' || participant.approverType === 'RULE_BASED';
  const isMgr   = participant.approverType === 'MANAGER' || participant.approverType === 'DEPT_HEAD';

  // For role-type steps: if the RPC resolved a specific employee, render them
  // like a profile (initials avatar). Otherwise fall back to the amber icon.
  const showAsGenericRole = isRole && !participant.hasResolvedPerson;

  const bg = (showAsGenericRole || isMgr) ? '#d97706' : avatarBg(name);

  return (
    <div style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      gap: 6, maxWidth: 80,
    }}>
      {/* Avatar with step-number badge */}
      <div style={{ position: 'relative' }}>
        <div style={{
          width: 48, height: 48, borderRadius: '50%',
          background: bg, color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: showAsGenericRole || isMgr ? 20 : 14,
          fontWeight: 500, flexShrink: 0,
        }}>
          {showAsGenericRole || isMgr
            ? <i className={`fa-solid ${isMgr ? 'fa-user-tie' : 'fa-users'}`} />
            : initials(name)}
        </div>
        {/* Step number badge */}
        <div style={{
          position: 'absolute', bottom: 0, right: 0,
          width: 16, height: 16, borderRadius: '50%',
          background: '#f0732b', border: '2px solid #f6f7f8',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <span style={{ fontSize: 8, fontWeight: 700, color: '#fff' }}>{stepNumber}</span>
        </div>
      </div>

      {/* Name */}
      <div style={{
        fontSize: 11, fontWeight: 500, textAlign: 'center',
        lineHeight: 1.3, color: '#1f2937',
        maxWidth: 80, wordBreak: 'break-word',
      }}>
        {name}
      </div>

      {/* Designation / sub-label */}
      <div style={{
        fontSize: 10, color: '#6b7280', textAlign: 'center',
        lineHeight: 1.3, maxWidth: 80,
      }}>
        {showAsGenericRole
          ? 'Any member'
          : (participant.resolvedDesignation ?? (isMgr ? 'Auto-resolved' : ''))}
      </div>
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

/* ── Main modal ────────────────────────────────────────────────────────────── */

interface Props {
  open:          boolean;
  onClose:       () => void;
  onConfirm:     (comment: string) => void;
  confirming:    boolean;
  title:         string;
  moduleCode:    string;
  employeeName?: string;
  submitError?:  string | null;
}

export default function WorkflowSubmitModal({
  open, onClose, onConfirm, confirming,
  title, moduleCode, employeeName, submitError,
}: Props) {
  const [comment, setComment] = useState('');
  const { profile } = useAuth();

  const { loading, approvers, ccParticipants } = useWorkflowParticipants(
    open ? moduleCode : '',
    profile?.id,     // lets the RPC resolve manager-type steps to a real name
  );

  if (!open) return null;

  const initiatorLabel = employeeName ?? 'You';

  return (
    /* Backdrop */
    <div
      onClick={confirming ? undefined : onClose}
      style={{
        position: 'fixed', inset: 0, zIndex: 9000,
        background: 'rgba(15,23,42,0.40)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: 20,
      }}
    >
      {/* Card */}
      <div
        onClick={e => e.stopPropagation()}
        style={{
          background: '#fff', width: '100%', maxWidth: 540,
          maxHeight: '92vh', display: 'flex', flexDirection: 'column',
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
              <div style={{ fontSize: 17, fontWeight: 500, color: '#111827', marginBottom: 3 }}>
                Submit for Approval
              </div>
              <div style={{ fontSize: 13, color: '#6b7280' }}>
                {title}{employeeName ? ` — ${employeeName}` : ''}
              </div>
            </div>
            <button
              onClick={onClose}
              disabled={confirming}
              style={{
                background: 'none', border: 'none',
                cursor: confirming ? 'not-allowed' : 'pointer',
                color: '#9ca3af', fontSize: 20, padding: 0,
                opacity: confirming ? 0.4 : 1, lineHeight: 1,
              }}
              aria-label="Close"
            >
              <i className="fa-solid fa-xmark" />
            </button>
          </div>
          <div style={{ height: 1, background: '#ebebeb', marginTop: 16 }} />
        </div>

        {/* Scrollable body */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '18px 24px 0' }}>

          {/* Routing section label */}
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
              <div style={{ textAlign: 'center', padding: '12px 0', color: '#9ca3af', fontSize: 13 }}>
                <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
                Loading routing…
              </div>
            ) : (
              <div style={{ display: 'flex', alignItems: 'flex-start', gap: 4, minWidth: 'max-content' }}>

                {/* Initiator bubble */}
                <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, maxWidth: 80 }}>
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

                {/* Steps */}
                {approvers.length === 0 && !loading && (
                  <>
                    <Arrow />
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, maxWidth: 80 }}>
                      <div style={{
                        width: 48, height: 48, borderRadius: '50%',
                        background: '#e5e7eb', color: '#9ca3af',
                        display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18,
                      }}>
                        <i className="fa-solid fa-circle-check" />
                      </div>
                      <div style={{ fontSize: 11, color: '#6b7280', textAlign: 'center' }}>No approvers</div>
                    </div>
                  </>
                )}

                {approvers.map((p, i) => (
                  <div key={p.stepOrder} style={{ display: 'flex', alignItems: 'flex-start', gap: 4 }}>
                    <Arrow />
                    <StepBubble participant={p} stepNumber={i + 1} />
                  </div>
                ))}

                {/* Complete node */}
                {approvers.length > 0 && (
                  <>
                    <Arrow />
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, maxWidth: 80 }}>
                      <div style={{
                        width: 48, height: 48, borderRadius: '50%',
                        background: '#e5e7eb', color: '#9ca3af',
                        display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 20,
                      }}>
                        <i className="fa-solid fa-circle-check" />
                      </div>
                      <div style={{ fontSize: 11, fontWeight: 500, color: '#6b7280', textAlign: 'center' }}>Complete</div>
                    </div>
                  </>
                )}
              </div>
            )}
          </div>

          {/* CC row */}
          {ccParticipants.length > 0 && (
            <div style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '10px 14px', background: '#f6f7f8',
              border: '1px solid #ebebeb', borderRadius: 6,
              marginBottom: 16, flexWrap: 'wrap',
            }}>
              <i className="fa-solid fa-envelope" style={{ fontSize: 14, color: '#7C3AED', flexShrink: 0 }} />
              <span style={{ fontSize: 12, color: '#6b7280', flexShrink: 0 }}>CC:</span>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {ccParticipants.map(p => (
                  <span
                    key={p.stepOrder}
                    style={{
                      fontSize: 12, background: '#dbeafe', color: '#1e40af',
                      padding: '3px 10px', borderRadius: 999, fontWeight: 500,
                    }}
                  >
                    {p.resolvedName ?? p.stepName}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* Comment */}
          <div style={{ marginBottom: 6 }}>
            <label style={{ fontSize: 12, fontWeight: 500, color: '#6b7280', display: 'block', marginBottom: 6 }}>
              Comment <span style={{ fontWeight: 400, color: '#aaa' }}>(optional)</span>
            </label>
            <textarea
              value={comment}
              onChange={e => setComment(e.target.value)}
              placeholder="Add a comment for approvers…"
              rows={3}
              style={{
                width: '100%', boxSizing: 'border-box',
                border: '1px solid #d0d0d0', borderRadius: 4,
                padding: '9px 12px', fontSize: 13,
                fontFamily: 'inherit', lineHeight: 1.5,
                color: '#111827', background: '#fff',
                resize: 'vertical', outline: 'none',
              }}
              onFocus={e => { e.target.style.borderColor = '#7C3AED'; e.target.style.boxShadow = '0 0 0 2px rgba(124,58,237,0.15)'; }}
              onBlur={e  => { e.target.style.borderColor = '#d0d0d0'; e.target.style.boxShadow = 'none'; }}
            />
          </div>
        </div>

        {/* Submit error */}
        {submitError && (
          <div style={{
            flexShrink: 0, margin: '0 24px 12px',
            padding: '10px 14px', borderRadius: 5,
            background: '#fef2f2', border: '1px solid #fecaca',
            color: '#dc2626', fontSize: 12, lineHeight: 1.5,
          }}>
            <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
            {submitError}
          </div>
        )}

        {/* Footer */}
        <div style={{
          flexShrink: 0,
          padding: '14px 24px',
          borderTop: '1px solid #ebebeb',
          display: 'flex', justifyContent: 'flex-end', gap: 10,
          marginTop: 16,
        }}>
          {/* Cancel */}
          <button
            onClick={onClose}
            disabled={confirming}
            className="btn-cancel"
            style={{ borderRadius: 999, padding: '8px 24px', fontSize: 13, opacity: confirming ? 0.5 : 1 }}
          >
            Cancel
          </button>

          {/* Submit */}
          <button
            onClick={() => onConfirm(comment)}
            disabled={confirming}
            className="btn-purple"
          >
            {confirming
              ? <><i className="fa-solid fa-spinner fa-spin" /> Submitting…</>
              : <>Submit</>}
          </button>
        </div>
      </div>
    </div>
  );
}
