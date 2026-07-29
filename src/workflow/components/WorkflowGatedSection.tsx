/**
 * <WorkflowGatedSection>
 *
 * Shared UI wrapper for any employee-profile portlet whose changes route
 * through a workflow approval. Encapsulates the "pending" visual language
 * so every portlet looks and behaves identically.
 *
 * Rendering:
 *   ┌ Section title with icon + amber "WORKFLOW PENDING APPROVAL" pill (when pending)
 *   │  [View approval progress → link]                       [actions slot →]
 *   │
 *   ├ Amber alert bar: "This section has N change(s) pending approval. Editing is paused."
 *   │  (only when pendingCount > 0)
 *   │
 *   └ children (the portlet's own body)
 *
 * The component owns NONE of the workflow-submission modal state — parents
 * still mount <WorkflowSubmitModal> as they do today. Same for participants
 * modal — the parent supplies onViewProgress that opens
 * <WorkflowParticipantsModal>.
 *
 * ── Design goals ────────────────────────────────────────────────────────
 * 1. One canonical wording — "This section has N change(s) pending approval.
 *    Editing is paused." Replaces the ad-hoc wording each portlet had.
 * 2. One canonical label — "View approval progress →" (previously mixed
 *    "View progress" / "View approval progress" across portlets).
 * 3. One canonical pill — amber `WORKFLOW PENDING APPROVAL`. Previously
 *    every portlet re-implemented the same span with slightly different
 *    padding/colors.
 * 4. Automatically hides the actions slot (Edit button etc.) while pending
 *    unless caller opts out via `actionsAlwaysVisible`.
 */

import React from 'react';

export interface WorkflowGatedSectionProps {
  /** FontAwesome icon class, e.g. "fa-graduation-cap" */
  icon:            string;
  /** Section title, e.g. "Education" or "Bank Accounts" */
  title:           string;
  /** Number of in-flight pending_change rows for this module (drives pill + alert bar) */
  pendingCount:    number;
  /**
   * Called when user clicks "View approval progress →" — should open
   * <WorkflowParticipantsModal> with the current active instance_id.
   * If omitted, the link is hidden.
   */
  onViewProgress?: () => void;
  /**
   * Actions slot (typically an Edit or Add button). Hidden while pending
   * unless `actionsAlwaysVisible` is true.
   */
  actions?:        React.ReactNode;
  /** Show `actions` even when pending. Default false (recommended). */
  actionsAlwaysVisible?: boolean;
  /** Portlet body */
  children:        React.ReactNode;
  /**
   * Optional override for the alert-bar noun ("education change",
   * "bank change", etc.). Default: "change".
   */
  changeNoun?:     string;
}

export function WorkflowGatedSection({
  icon,
  title,
  pendingCount,
  onViewProgress,
  actions,
  actionsAlwaysVisible = false,
  children,
  changeNoun = 'change',
}: WorkflowGatedSectionProps) {
  const isPending = pendingCount > 0;
  const showActions = actionsAlwaysVisible || !isPending;

  const article = /^[aeiou]/i.test(changeNoun) ? 'An' : 'A';
  const alertText =
    pendingCount > 1
      ? `${pendingCount} ${changeNoun}s are pending approval. Editing is paused.`
      : `${article} ${changeNoun} is pending approval. Editing is paused.`;

  return (
    <div>
      {/* ── Title row ─────────────────────────────────────────────────── */}
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'flex-start',
          marginBottom: 14,
        }}
      >
        <div
          className="ev-section-title"
          style={{
            display: 'flex',
            alignItems: 'flex-start',
            flexDirection: 'column',
            gap: 6,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className={`fa-solid ${icon}`} />
            {title}
            {isPending && (
              <span
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 4,
                  background: '#FEF3C7',
                  color: '#B45309',
                  border: '1px solid #F59E0B',
                  borderRadius: 10,
                  padding: '2px 8px',
                  fontSize: 11,
                  fontWeight: 600,
                  lineHeight: 1.4,
                }}
              >
                <i
                  className="fa-solid fa-hourglass-half"
                  style={{ fontSize: 10 }}
                />
                WORKFLOW PENDING APPROVAL
              </span>
            )}
          </div>

          {isPending && onViewProgress && (
            <button
              onClick={onViewProgress}
              style={{
                background: 'none',
                border: 'none',
                padding: 0,
                cursor: 'pointer',
                color: '#6366F1',
                fontSize: 12,
                fontWeight: 500,
                textDecoration: 'underline',
                display: 'inline-flex',
                alignItems: 'center',
                gap: 4,
              }}
            >
              <i className="fa-solid fa-users" style={{ fontSize: 11 }} />
              View approval progress →
            </button>
          )}
        </div>

        {showActions && actions}
      </div>

      {/* ── Alert bar ─────────────────────────────────────────────────── */}
      {isPending && (
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            padding: '8px 16px',
            background: '#FFFBEB',
            borderBottom: '1px solid #FEF3C7',
            fontSize: 12.5,
            color: '#92400E',
          }}
        >
          <i className="fa-solid fa-clock" style={{ color: '#D97706' }} />
          <span>{alertText}</span>
        </div>
      )}

      {/* ── Body ──────────────────────────────────────────────────────── */}
      {children}
    </div>
  );
}
