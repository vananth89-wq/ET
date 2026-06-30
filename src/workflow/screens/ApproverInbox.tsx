/**
 * ApproverInbox — Unified workflow inbox
 *
 * Two tabs:
 *   "To Approve"  — pending approval tasks assigned to the current user
 *                   (same split-pane: task list + detail + approve/reject/reassign)
 *   "Sent Back"   — instances the user submitted that an approver returned for
 *                   clarification (same split-pane: clarification list + full
 *                   detail + respond/withdraw action bar)
 *
 * Deep-link:  /workflow/inbox?tab=sent_back  → opens Sent Back tab directly
 *             (used by the My Requests banner "View →" button)
 *
 * Route: /workflow/inbox
 */

import React, { useState, useEffect, useRef, useCallback } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { useWorkflowTasks }          from '../hooks/useWorkflowTasks';
import { useMySentBackItems }         from '../hooks/useMySentBackItems';
import { useApproverReportDetail }   from '../hooks/useApproverReportDetail';
import { useWorkflowInstance }       from '../hooks/useWorkflowInstance';
import { WorkflowTimeline }            from '../components/WorkflowTimeline';
import { WorkflowStatusBadge }         from '../components/WorkflowStatusBadge';
import WorkflowParticipantsModal       from '../components/WorkflowParticipantsModal';
import type { WorkflowTask, SlaStatus } from '../hooks/useWorkflowTasks';
import type { SentBackItem }          from '../hooks/useMySentBackItems';
import { fmtAmount } from '../../utils/currency';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { usePermissions }   from '../../hooks/usePermissions';
import { useDepartments }   from '../../hooks/useDepartments';
import { useEmployees }     from '../../hooks/useEmployees';
import { useCurrencies }    from '../../hooks/useCurrencies';
import { COUNTRIES }        from '../../components/admin/AddEmployee';
import { validateIdentityNumber } from '../../utils/validateIdentity';

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Returns true when the RPC error means another role fan-out member already
 * actioned this step (mode=auto / any-one-approver). The DB cancels the
 * remaining tasks, so the second approver's UI is stale.
 * We show a friendly info modal instead of a red error toast.
 */
function isAlreadyHandledError(msg: string) {
  return msg.toLowerCase().includes('task is not pending (current status: cancelled)');
}

function fmtDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  }).format(new Date(iso));
}

function relativeTime(iso: string) {
  const diffMs  = Date.now() - new Date(iso).getTime();
  const diffMin = Math.floor(diffMs / 60_000);
  if (diffMin < 60)  return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr  < 24)  return `${diffHr}h ago`;
  return `${Math.floor(diffHr / 24)}d ago`;
}

function attIcon(mime: string) {
  if (mime === 'application/pdf')  return 'fa-file-pdf';
  if (mime.startsWith('image/'))   return 'fa-file-image';
  return 'fa-file';
}

function attFmtSize(bytes: number) {
  if (bytes < 1024)    return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

function getNextTask(tasks: WorkflowTask[], currentId: string): WorkflowTask | null {
  const idx = tasks.findIndex(t => t.taskId === currentId);
  if (idx === -1) return tasks[0] ?? null;
  return tasks[idx + 1] ?? tasks[idx - 1] ?? null;
}

function getNextItem(items: SentBackItem[], currentId: string): SentBackItem | null {
  const idx = items.findIndex(i => i.instanceId === currentId);
  if (idx === -1) return items[0] ?? null;
  return items[idx + 1] ?? items[idx - 1] ?? null;
}

// ── SLA config ────────────────────────────────────────────────────────────────

const SLA: Record<SlaStatus, { color: string; bg: string; border: string; label: string }> = {
  on_track: { color: '#16A34A', bg: '#F0FDF4', border: '#BBF7D0', label: 'On Track'  },
  due_soon: { color: '#D97706', bg: '#FFFBEB', border: '#FDE68A', label: 'Due Soon'  },
  overdue:  { color: '#DC2626', bg: '#FEF2F2', border: '#FECACA', label: 'Overdue'   },
};

// ── Types ─────────────────────────────────────────────────────────────────────

interface Person { id: string; name: string; title: string | null }

// ─────────────────────────────────────────────────────────────────────────────
// Shared small helpers
// ─────────────────────────────────────────────────────────────────────────────

function SectionTitle({ icon, label, count }: { icon: string; label: string; count?: number }) {
  return (
    <div className="wfi-section-title">
      <i className={`fas ${icon} wfi-section-title-icon`} />
      <span className="wfi-section-title-text">{label}</span>
      {count !== undefined && (
        <span className="wfi-section-count">{count}</span>
      )}
    </div>
  );
}

function MetaItem({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="wfi-meta-label">{label}</div>
      <div className="wfi-meta-value">{value}</div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Already-Handled Modal
// Shown when the approver tries to action a task that was already actioned by
// another role fan-out member (status=cancelled). Info-style — not an error.
// ─────────────────────────────────────────────────────────────────────────────

function AlreadyHandledModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  if (!open) return null;
  return (
    <div style={{
      position: 'fixed', inset: 0, zIndex: 1100,
      background: 'rgba(0,0,0,0.35)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}>
      <div style={{
        background: '#fff', borderRadius: 12, padding: '28px 28px 22px',
        maxWidth: 400, width: '90%', boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
        textAlign: 'center',
      }}>
        {/* Icon */}
        <div style={{
          width: 52, height: 52, borderRadius: '50%',
          background: '#EFF6FF', border: '2px solid #BFDBFE',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          margin: '0 auto 16px',
        }}>
          <i className="fas fa-circle-check" style={{ fontSize: 22, color: '#2F77B5' }} />
        </div>

        {/* Title */}
        <div style={{ fontSize: 16, fontWeight: 700, color: '#111827', marginBottom: 8 }}>
          Already Approved
        </div>

        {/* Body */}
        <div style={{ fontSize: 13, color: '#6B7280', lineHeight: 1.6, marginBottom: 22 }}>
          Another approver in this step has already actioned this request.
          The task has been automatically removed from your inbox.
        </div>

        {/* Button */}
        <button
          onClick={onClose}
          style={{
            background: '#2F77B5', color: '#fff',
            border: 'none', borderRadius: 7,
            padding: '9px 28px', fontSize: 13, fontWeight: 600,
            cursor: 'pointer',
          }}
        >
          Got it
        </button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// KPI Card (To Approve tab only)
// ─────────────────────────────────────────────────────────────────────────────

function KpiCard({
  label, value, icon, color, bg, border, active, onClick,
}: {
  label: string; value: number; icon: string;
  color: string; bg: string; border: string;
  active?: boolean; onClick?: () => void;
}) {
  return (
    <div
      onClick={onClick}
      style={{
        flex: '1 1 0', minWidth: 100,
        background:   active ? bg : '#fff',
        border:       `1.5px solid ${active ? color : '#E5E7EB'}`,
        borderRadius: 10, padding: '12px 16px',
        cursor: onClick ? 'pointer' : 'default',
        boxShadow: active ? `0 0 0 3px ${border}` : '0 1px 3px rgba(0,0,0,0.05)',
        transition: 'all 0.15s',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
        <span style={{ fontSize: 10, fontWeight: 700, color: active ? color : '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
          {label}
        </span>
        <i className={`fas ${icon}`} style={{ fontSize: 13, color: active ? color : '#D1D5DB' }} />
      </div>
      <div style={{ fontSize: 24, fontWeight: 800, color: active ? color : '#111827', lineHeight: 1 }}>
        {value}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Task Card — To Approve tab left panel
// ─────────────────────────────────────────────────────────────────────────────

function TaskCard({ task, selected, onClick }: { task: WorkflowTask; selected: boolean; onClick: () => void }) {
  const sla = SLA[task.slaStatus];
  return (
    <div
      onClick={onClick}
      style={{
        padding: '14px 16px', cursor: 'pointer',
        borderBottom: '1px solid #F3F4F6',
        background: selected ? '#EFF6FF' : '#fff',
        borderLeft: `3px solid ${selected ? '#2F77B5' : 'transparent'}`,
        transition: 'background 0.12s',
      }}
    >
      <div className="wfi-task-card-top">
        <div className="wfi-task-card-info">
          <div className="wfi-task-name">
            {getPortletName(task.moduleCode, task.metadata, task.templateName, task.submittedByName, task.subjectEmployeeName)}
          </div>
          {task.initiatedByActorId && task.initiatedByActorName && (
            <div style={{
              display: 'flex', flexDirection: 'column', gap: 2,
              fontSize: 11, background: '#F5F3FF', border: '1px solid #DDD6FE',
              borderRadius: 6, padding: '5px 9px', margin: '3px 0 2px',
            }}>
              {/* Row 1 — HR actor who submitted */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 5, color: '#7C3AED' }}>
                <i className="fa-solid fa-user-shield" style={{ fontSize: 10, width: 12, textAlign: 'center' }} />
                <span style={{ color: '#6B7280' }}>Submitted by</span>
                <strong style={{ color: '#4C1D95' }}>{task.initiatedByActorName}</strong>
              </div>
              {/* Row 2 — subject employee */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 5, color: '#7C3AED' }}>
                <span style={{ fontSize: 11, width: 12, textAlign: 'center', color: '#A78BFA' }}>↳</span>
                <span style={{ color: '#6B7280' }}>On behalf of</span>
                <strong style={{ color: '#4C1D95' }}>{task.subjectEmployeeName ?? task.submittedByName ?? 'employee'}</strong>
              </div>
            </div>
          )}
          <div className="wfi-task-meta">
            {task.stepName} · {
              (task.moduleCode === 'termination' || task.moduleCode === 'termination_reversal') && task.metadata?.employee_name
                ? (task.metadata.employee_name as string)
                : (task.submittedByName ?? 'Unknown')
            }
          </div>
        </div>
        <div className="wfi-task-sla">
          <span style={{ width: 7, height: 7, borderRadius: '50%', background: sla.color, display: 'inline-block' }} />
          <span style={{ fontSize: 10, color: sla.color, fontWeight: 600 }}>{sla.label}</span>
        </div>
      </div>
      <div className="wfi-task-footer">
        {task.metadata?.total_amount !== undefined ? (
          <span className="wfi-task-amount">
            {task.metadata.currency_code as string} {Number(task.metadata.total_amount).toLocaleString('en-IN', { minimumFractionDigits: 2 })}
          </span>
        ) : <span />}
        <span className="wfi-task-time">{relativeTime(task.taskCreatedAt)}</span>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sent Back Card — Sent Back tab left panel
// ─────────────────────────────────────────────────────────────────────────────

function SentBackCard({ item, selected, onClick }: { item: SentBackItem; selected: boolean; onClick: () => void }) {
  const isRejected = item.status === 'rejected';
  const selBg      = isRejected ? '#FEF2F2' : '#FFFBEB';
  const selBorder  = isRejected ? '#DC2626' : '#B45309';
  return (
    <div
      onClick={onClick}
      style={{
        padding: '14px 16px', cursor: 'pointer',
        borderBottom: '1px solid #F3F4F6',
        background: selected ? selBg : '#fff',
        borderLeft: `3px solid ${selected ? selBorder : 'transparent'}`,
        transition: 'background 0.12s',
      }}
    >
      <div className="wfi-task-card-top">
        <div className="wfi-task-card-info">
          <div className="wfi-task-name">
            {getPortletName(item.moduleCode, item.metadata, item.templateName, (item as any).submittedByName, (item as any).subjectEmployeeName)}
          </div>
          <div className="wfi-task-meta">
            {item.templateName}
            {isRejected
              ? item.clarificationFrom ? ` · Rejected by ${item.clarificationFrom}` : ''
              : item.clarificationFrom ? ` · Sent back by ${item.clarificationFrom}` : ''}
          </div>
        </div>
        {isRejected ? (
          <span style={{
            fontSize: 10, fontWeight: 700, color: '#fff',
            background: '#DC2626', borderRadius: 4, padding: '2px 8px',
            whiteSpace: 'nowrap',
          }}>
            Rejected
          </span>
        ) : (
          <span className="wfi-sentback-badge">
            Needs Response
          </span>
        )}
      </div>
      {item.clarificationMessage && (
        <div className="wfi-sentback-preview">
          <i className={`fas ${isRejected ? 'fa-circle-xmark' : 'fa-comment-dots'} wfi-sentback-preview-icon`}
             style={{ color: isRejected ? '#DC2626' : undefined }} />
          {item.clarificationMessage}
        </div>
      )}
      <div className="wfi-sentback-time">
        {relativeTime(item.clarificationAt)}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Approve tab — Action Bar (Approve / Reject / Reassign / More)
// ─────────────────────────────────────────────────────────────────────────────

interface ApproveActionBarProps {
  task:                   WorkflowTask;
  onApprove:              (taskId: string, notes?: string) => Promise<void>;
  onReject:               (taskId: string, reason: string) => Promise<void>;
  onReassign:             (taskId: string, profileId: string, reason?: string) => Promise<void>;
  onReturnToInitiator:    (taskId: string, message: string) => Promise<void>;
  onReturnToPreviousStep: (taskId: string, reason?: string) => Promise<void>;
  onAfterAction:          () => void;
  // Update: present when step allow_edit is ON and the module has an edit_route
  onUpdate?:              () => void;
}

function PanelActionBar({
  task, onApprove, onReject, onReassign,
  onReturnToInitiator, onReturnToPreviousStep, onAfterAction, onUpdate,
}: ApproveActionBarProps) {
  const [comment,  setComment]  = useState('');
  const [mode,     setMode]     = useState<'idle' | 'reassign' | 'return_init' | 'return_prev'>('idle');
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);
  const [showMore, setShowMore] = useState(false);

  const [query,    setQuery]    = useState('');
  const [results,  setResults]  = useState<Person[]>([]);
  const [target,   setTarget]   = useState<Person | null>(null);
  const searchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const moreRef     = useRef<HTMLDivElement>(null);
  const sb = supabase;

  useEffect(() => {
    if (!showMore) return;
    function handleOutside(e: MouseEvent) {
      if (moreRef.current && !moreRef.current.contains(e.target as Node)) setShowMore(false);
    }
    document.addEventListener('mousedown', handleOutside);
    return () => document.removeEventListener('mousedown', handleOutside);
  }, [showMore]);

  useEffect(() => {
    setComment(''); setMode('idle'); setError(null);
    setShowMore(false); setQuery(''); setResults([]); setTarget(null);
  }, [task.taskId]);

  useEffect(() => {
    if (mode !== 'reassign' || query.length < 2) { setResults([]); return; }
    if (searchTimer.current) clearTimeout(searchTimer.current);
    searchTimer.current = setTimeout(async () => {
      const { data: empData } = await sb
        .from('employees')
        .select('id, name, job_title')
        .ilike('name', `%${query}%`)
        .eq('status', 'Active')
        .is('deleted_at', null)
        .limit(8);

      if (!empData?.length) { setResults([]); return; }

      const { data: profileData } = await sb
        .from('profiles')
        .select('id, employee_id')
        .in('employee_id', empData.map((e: any) => e.id))
        .eq('is_active', true);

      const profileMap = new Map((profileData ?? []).map((p: any) => [p.employee_id, p.id]));

      setResults(
        empData
          .filter((e: any) => profileMap.has(e.id))
          .map((e: any) => ({
            id:    profileMap.get(e.id)!,
            name:  e.name      ?? '—',
            title: e.job_title ?? null,
          }))
      );
    }, 300);
  }, [query, mode]);

  async function run(fn: () => Promise<void>) {
    setLoading(true); setError(null);
    try { await fn(); onAfterAction(); }
    catch (e) { setError((e as Error).message); }
    finally { setLoading(false); }
  }

  const handleApprove   = () => run(() => onApprove(task.taskId, comment.trim() || undefined));
  const handleReject    = () => {
    if (!comment.trim()) { setError('Rejection reason is required.'); return; }
    run(() => onReject(task.taskId, comment.trim()));
  };
  const handleReassign  = () => {
    if (!target) { setError('Select a person to reassign to.'); return; }
    run(() => onReassign(task.taskId, target.id, comment.trim() || undefined));
  };
  const handleReturnInit = () => {
    if (!comment.trim()) { setError('A message to the initiator is required.'); return; }
    run(() => onReturnToInitiator(task.taskId, comment.trim()));
  };
  const handleReturnPrev = () => run(() => onReturnToPreviousStep(task.taskId, comment.trim() || undefined));

  return (
    <div className="wfi-panel-action-bar">
      {mode === 'reassign' && (
        <div style={{ marginBottom: 10 }}>
          <div className="wfi-reassign-label">Reassign to *</div>
          {target ? (
            <div className="wfi-reassign-chip">
              <div>
                <div className="wfi-reassign-chip-name">{target.name}</div>
                {target.title && <div className="wfi-reassign-chip-title">{target.title}</div>}
              </div>
              <button className="wfi-reassign-chip-remove" onClick={() => { setTarget(null); setQuery(''); }}>×</button>
            </div>
          ) : (
            <div className="wfi-search-wrapper">
              <input
                value={query} onChange={e => setQuery(e.target.value)}
                placeholder="Search by name…" autoFocus
                className="wfi-search-input"
              />
              {results.length > 0 && (
                <div className="wfi-search-dropdown">
                  {results.map(p => (
                    <button key={p.id}
                      className="wfi-search-result-btn"
                      onClick={() => { setTarget(p); setQuery(''); setResults([]); }}
                      onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')}
                      onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                    >
                      <div className="wfi-search-result-name">{p.name}</div>
                      {p.title && <div className="wfi-search-result-title">{p.title}</div>}
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>
      )}

      <textarea
        value={comment}
        onChange={e => { setComment(e.target.value); setError(null); }}
        placeholder={
          mode === 'reassign'    ? 'Reason for reassigning (optional)…' :
          mode === 'return_init' ? 'Message to submitter (required)…'   :
          mode === 'return_prev' ? 'Reason for returning (optional)…'   :
                                   'Add a note — sent with your decision…'
        }
        rows={2}
        className="wfi-action-textarea"
        style={{ border: `1px solid ${error ? '#FECACA' : '#D1D5DB'}`, marginBottom: 4 }}
      />

      {error && (
        <p className="wfi-action-error">
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{error}
        </p>
      )}

      {mode === 'idle' && (
        <div className="wfi-action-btn-row">
          <button onClick={handleApprove} disabled={loading}
            className="wfi-action-approve-btn"
            style={{ background: loading ? '#9CA3AF' : '#16A34A', cursor: loading ? 'not-allowed' : 'pointer' }}>
            {loading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-check" />} Approve
          </button>
          <button onClick={handleReject} disabled={loading}
            className="wfi-action-reject-btn"
            style={{ background: loading ? '#9CA3AF' : '#DC2626', cursor: loading ? 'not-allowed' : 'pointer' }}>
            <i className="fas fa-times" /> Reject
          </button>
          {onUpdate && (
            <button onClick={onUpdate} disabled={loading}
              className="wfi-action-update-btn"
              style={{ cursor: loading ? 'not-allowed' : 'pointer' }}>
              <i className="fas fa-pen-to-square" /> Update
            </button>
          )}
          <div ref={moreRef} className="wfi-action-more-wrapper">
            <button
              onClick={() => setShowMore(v => !v)} disabled={loading}
              className="wfi-action-more-btn"
              style={{ background: showMore ? '#F3F4F6' : '#FAFAFA', cursor: loading ? 'not-allowed' : 'pointer' }}
              onMouseEnter={e => { if (!loading) { e.currentTarget.style.background = '#F3F4F6'; e.currentTarget.style.borderColor = '#9CA3AF'; }}}
              onMouseLeave={e => { if (!showMore) { e.currentTarget.style.background = '#FAFAFA'; e.currentTarget.style.borderColor = '#D1D5DB'; }}}
            >
              More <i className="fas fa-chevron-down" style={{ fontSize: 9, transition: 'transform 0.15s', transform: showMore ? 'rotate(180deg)' : 'none' }} />
            </button>
            {showMore && (
              <div className="wfi-more-dropdown">
                <button
                  className="wfi-more-item wfi-more-item--reassign"
                  onClick={() => { setMode('reassign'); setShowMore(false); }}
                  onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')}
                  onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                >
                  <div className="wfi-more-item-icon wfi-icon-bg--purple">
                    <i className="fas fa-arrow-right-arrow-left" style={{ fontSize: 13, color: '#7C3AED' }} />
                  </div>
                  <div>
                    <div className="wfi-more-item-title">Reassign</div>
                    <div className="wfi-more-item-sub">Transfer to another approver</div>
                  </div>
                </button>
                <button
                  className="wfi-more-item wfi-more-item--sendback"
                  onClick={() => { setMode('return_init'); setShowMore(false); }}
                  style={{ borderBottom: task.stepOrder > 1 ? '1px solid #F3F4F6' : 'none' }}
                  onMouseEnter={e => (e.currentTarget.style.background = '#FFFBEB')}
                  onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                >
                  <div className="wfi-more-item-icon wfi-icon-bg--amber">
                    <i className="fas fa-comment-dots" style={{ fontSize: 13, color: '#B45309' }} />
                  </div>
                  <div>
                    <div className="wfi-more-item-title">Send Back</div>
                    <div className="wfi-more-item-sub">Request clarification from submitter</div>
                  </div>
                </button>
                {task.stepOrder > 1 && (
                  <button
                    className="wfi-more-item wfi-more-item--returnprev"
                    onClick={() => { setMode('return_prev'); setShowMore(false); }}
                    onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                    onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                  >
                    <div className="wfi-more-item-icon wfi-icon-bg--gray">
                      <i className="fas fa-backward-step wf-icon-color--gray" />
                    </div>
                    <div>
                      <div className="wfi-more-item-title">Send Back to Previous Step</div>
                      <div className="wfi-more-item-sub">Return to the previous approver</div>
                    </div>
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      )}

      {mode !== 'idle' && (
        <div className="wfi-secondary-btn-row">
          <button
            onClick={mode === 'reassign' ? handleReassign : mode === 'return_init' ? handleReturnInit : handleReturnPrev}
            disabled={loading}
            className="wfi-secondary-confirm-btn"
            style={{
              background: mode === 'reassign' ? '#7C3AED' : mode === 'return_init' ? '#B45309' : '#374151',
              cursor: loading ? 'not-allowed' : 'pointer',
            }}
          >
            {loading && <i className="fas fa-spinner fa-spin" />}
            {mode === 'reassign'    && 'Confirm Reassign'}
            {mode === 'return_init' && 'Send Back'}
            {mode === 'return_prev' && 'Send Back to Previous Step'}
          </button>
          <button
            className="wfi-secondary-cancel-btn"
            onClick={() => { setMode('idle'); setError(null); setTarget(null); setQuery(''); }}
            disabled={loading}
          >
            Cancel
          </button>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sent Back tab — Action Bar (Respond & Resume + Withdraw)
// ─────────────────────────────────────────────────────────────────────────────

function SentBackActionBar({ item, onUpdate, onEnterEditMode, onRespond, onWithdraw, onAfterAction }: {
  item:             SentBackItem;
  onUpdate:         (instanceId: string) => Promise<void>;
  // For profile modules: enters inline edit mode instead of navigating away
  onEnterEditMode?: () => void;
  onRespond:        (instanceId: string, response?: string) => Promise<void>;
  onWithdraw:       (instanceId: string, reason?: string)   => Promise<void>;
  onAfterAction:    () => void;
}) {
  const [response,        setResponse]        = useState('');
  const [loading,         setLoading]         = useState(false);
  const [updateLoading,   setUpdateLoading]   = useState(false);
  const [error,           setError]           = useState<string | null>(null);
  const [confirmWithdraw, setConfirmWithdraw] = useState(false);

  const isRejected      = item.status === 'rejected';
  // Respond & Update only available for sent-back (awaiting_clarification) items.
  // Rejected items can only be withdrawn (soft-delete).
  const supportsUpdate  = !isRejected && (
    ['expense_reports', 'employee_hire'].includes(item.moduleCode) || item.moduleCode.startsWith('profile_')
  );
  const isProfileModule = item.moduleCode.startsWith('profile_');
  const isHireModule    = item.moduleCode === 'employee_hire';

  useEffect(() => {
    setResponse(''); setError(null); setConfirmWithdraw(false);
  }, [item.instanceId]);

  async function run(fn: () => Promise<void>) {
    setLoading(true); setError(null);
    try { await fn(); onAfterAction(); }
    catch (e) { setError((e as Error).message); }
    finally { setLoading(false); }
  }

  async function handleUpdate() {
    setUpdateLoading(true); setError(null);
    try { await onUpdate(item.instanceId); }
    catch (e) { setError((e as Error).message); }
    finally { setUpdateLoading(false); }
  }

  return (
    <div className="wfi-panel-action-bar">
      {/* Rejected: concise callout — no respond textarea */}
      {isRejected ? (
        <p style={{ fontSize: 12, color: '#6B7280', margin: '0 0 10px', lineHeight: 1.5 }}>
          This request was rejected. Withdraw to permanently remove the hire record.
        </p>
      ) : (
        <textarea
          value={response}
          onChange={e => { setResponse(e.target.value); setError(null); }}
          placeholder="Your response to the approver (optional — adds context when you resume)…"
          rows={2}
          className="wfi-action-textarea"
          style={{ border: `1px solid ${error ? '#FECACA' : '#D1D5DB'}`, marginBottom: 8 }}
        />
      )}
      {error && (
        <p className="wfi-action-error">
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{error}
        </p>
      )}
      <div className="wfi-respond-btn-row">

        {/* Respond & Resume — only for awaiting_clarification */}
        {!isRejected && (
          <button
            onClick={() => run(() => onRespond(item.instanceId, response.trim() || undefined))}
            disabled={loading || updateLoading}
            className="wfi-respond-btn"
            style={{
              background: (loading || updateLoading) ? '#9CA3AF' : '#B45309',
              cursor: (loading || updateLoading) ? 'not-allowed' : 'pointer',
            }}
          >
            {loading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-reply" />}
            Respond & Resume
          </button>
        )}

        {/* Update — only for awaiting_clarification */}
        {supportsUpdate && (
          <button
            onClick={isProfileModule ? () => onEnterEditMode?.() : isHireModule ? () => onEnterEditMode?.() : handleUpdate}
            disabled={loading || updateLoading}
            className="wfi-update-btn"
            style={{ cursor: (loading || updateLoading) ? 'not-allowed' : 'pointer' }}
          >
            {updateLoading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-pen-to-square" />}
            {isHireModule ? 'Review & Edit' : 'Update'}
          </button>
        )}

        {/* Withdraw */}
        {!confirmWithdraw ? (
          <button
            onClick={() => setConfirmWithdraw(true)} disabled={loading || updateLoading}
            className="wfi-withdraw-btn"
            style={isRejected ? { background: '#FEF2F2', color: '#DC2626', borderColor: '#FECACA' } : {}}
          >
            {isRejected ? <><i className="fas fa-trash-can" style={{ marginRight: 4 }} /> Discard Record</> : 'Withdraw'}
          </button>
        ) : (
          <div className="wfi-withdraw-confirm-row">
            <span className="wfi-withdraw-confirm-label">
              {isRejected ? 'Remove hire record?' : 'Cancel request?'}
            </span>
            <button className="wfi-withdraw-confirm-yes" onClick={() => run(() => onWithdraw(item.instanceId))}>Yes</button>
            <button className="wfi-withdraw-confirm-no" onClick={() => setConfirmWithdraw(false)}>No</button>
          </div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Module enrichment components (shared between both tabs)
// ─────────────────────────────────────────────────────────────────────────────

function ExpenseEnrichment({
  recordId, onOpenFull, onAmountResolved,
}: {
  recordId: string;
  onOpenFull: () => void;
  onAmountResolved?: (amount: number, currencyCode: string) => void;
}) {
  const { detail, loading } = useApproverReportDetail(recordId);
  const LARGE_THRESHOLD = 10;

  useEffect(() => {
    if (detail && onAmountResolved) {
      onAmountResolved(detail.totalConverted, detail.baseCurrencyCode);
    }
  }, [detail?.totalConverted, detail?.baseCurrencyCode]);

  if (loading) return (
    <div className="wfi-inline-loading">
      <i className="fas fa-spinner fa-spin" /> Loading line items…
    </div>
  );
  if (!detail) return null;

  const lineItems = detail.lineItems;
  const isLarge   = lineItems.length > LARGE_THRESHOLD;
  const allAtts   = lineItems.flatMap(li =>
    (li.attachments ?? []).map(a => ({ ...a, categoryName: li.categoryName }))
  );

  return (
    <>
      {isLarge && (
        <div className="wfi-large-report-banner">
          <i className="fas fa-circle-info" style={{ color: '#D97706', fontSize: 13 }} />
          <span className="wfi-large-report-text">
            {lineItems.length} items — use{' '}
            <button onClick={onOpenFull} className="wfi-large-report-link">Full View</button>{' '}
            for easier review.
          </span>
        </div>
      )}
      {lineItems.length > 0 && (
        <div style={{ marginBottom: 18 }}>
          <SectionTitle icon="fa-list" label="Line Items" count={lineItems.length} />
          <div style={{ maxHeight: isLarge ? 260 : 'none', overflowY: isLarge ? 'auto' : 'visible', border: '1px solid #E5E7EB', borderRadius: 8, overflow: 'hidden' }}>
            <table className="wf-table wf-table--sm">
              <thead>
                <tr className="wf-thead-row">
                  {['#', 'Category', 'Date', 'Amount', 'Converted', 'Note', 'Attachments'].map(h => (
                    <th key={h} className="wf-th-sm">{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {lineItems.map((li, i) => (
                  <tr key={li.id} style={{ borderBottom: i < lineItems.length - 1 ? '1px solid #F3F4F6' : 'none' }}>
                    <td className="wf-td-num--sm">{i + 1}</td>
                    <td className="wf-td-main--sm">{li.categoryName || '—'}</td>
                    <td className="wf-td-date--sm">{fmtDate(li.date)}</td>
                    <td className="wf-td-amount--sm">
                      <span className="wf-currency-code">{li.currencyCode}</span>
                      {li.amount.toLocaleString('en-IN', { minimumFractionDigits: 2 })}
                    </td>
                    <td className="wf-td-converted--sm">{fmtAmount(li.convertedAmount, detail.baseCurrencyCode)}</td>
                    <td className="wf-td-muted--sm">{li.note || '—'}</td>
                    <td className="wf-td-att--sm">
                      {!li.attachments?.length ? <span className="wf-att-empty">—</span> :
                       li.attachments.length === 1 ? (
                        <a href={li.attachments[0].dataUrl} target="_blank" rel="noopener noreferrer" title={li.attachments[0].name} className="wf-att-link">
                          <i className="fas fa-paperclip wf-att-icon" /> 1
                        </a>
                       ) : (
                        <span className="wf-att-link">
                          <i className="fas fa-paperclip wf-att-icon" /> {li.attachments.length}
                        </span>
                       )}
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr className="wf-tfoot-row">
                  <td colSpan={4} className="wf-tfoot-label--sm">Total</td>
                  <td className="wf-tfoot-value--sm">{fmtAmount(detail.totalConverted, detail.baseCurrencyCode)}</td>
                  <td /><td />
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      )}
      {/* Attachments shown inline per line item — no separate flat section */}
    </>
  );
}

const MODULE_LABELS: Record<string, string> = {
  expense_reports:           'Expense Reports',
  time_off:                  'Time Off',
  employee_hire:             'New Employee Hire',
  profile_personal:          'Profile – Personal Info',
  profile_contact:           'Profile – Contact Details',
  profile_address:           'Profile – Address',
  profile_passport:          'Profile – Passport',
  profile_emergency_contact: 'Profile – Emergency Contact',
  profile_identification:    'Profile – Identification',
  profile_employment:        'Profile – Employment',
  profile_bank:              'Bank Account Update',
  profile_dependents:        'Dependents Update',
  profile_job_relationships: 'Job Relationships Update',
  profile_education:         'Education Update',
  termination:               'Termination',
  termination_reversal:       'Termination Reversal',
};

/** Returns the human-readable "portlet name" for a task card title.
 *
 *  - expense_reports → the report name stored in metadata (added by migration 189)
 *  - profile_*       → "{submitter} — {module label}", e.g. "Reeshatha A — Profile – Personal Info"
 *  - other           → template name as fallback
 */
function getPortletName(
  moduleCode:        string,
  metadata:          Record<string, unknown>,
  templateName:      string,
  submittedByName:   string | null,
  subjectEmployeeName?: string | null,
): string {
  // Termination: use metadata.employee_name (stamped by mig 575+) or
  // subjectEmployeeName only when it's a verified on-behalf submission
  // (pre-575 records have subject_profile_id = submitter, so subjectEmployeeName
  // would incorrectly show the submitter's name — ignore it here).
  if (moduleCode === 'termination') {
    const empName = (metadata?.employee_name as string | undefined) ?? null;
    return empName ? `Termination — ${empName}` : 'Termination';
  }
  if (moduleCode === 'termination_reversal') {
    const empName = (metadata?.employee_name as string | undefined) ?? null;
    return empName ? `Termination Reversal — ${empName}` : 'Termination Reversal';
  }
  const metaName = metadata?.name as string | undefined;
  if (metaName) return metaName;
  if (moduleCode.startsWith('profile_')) {
    const label = MODULE_LABELS[moduleCode] ?? moduleCode.replace(/_/g, ' ');
    return submittedByName ? `${submittedByName} — ${label}` : label;
  }
  return templateName;
}

const PROFILE_PICKLIST_FIELDS: Record<string, Record<string, string>> = {
  // nationality is stored as a plain country name (string), NOT a picklist UUID —
  // MyProfile submits it via COUNTRIES array (value = label). Use PROFILE_COUNTRY_FIELDS instead.
  profile_personal:          { marital_status: 'MARITAL_STATUS' },
  // profile_address.country is also a plain country name string (COUNTRIES array).
  // profile_passport.country IS a picklist UUID (ID_COUNTRY picklist).
  profile_passport:          { country: 'ID_COUNTRY' },
  profile_emergency_contact: { relationship: 'RELATIONSHIP_TYPE' },
  profile_employment:        { designation: 'DESIGNATION', work_country: 'ID_COUNTRY', work_location: 'LOCATION' },
  profile_education:         { education_level: 'EDUCATION_LEVEL', completion_status: 'COMPLETION_STATUS' },
};

// Fields stored as plain country name strings (from the COUNTRIES constant),
// rendered as a countries select in edit mode rather than a picklist select.
const PROFILE_COUNTRY_FIELDS: Record<string, Set<string>> = {
  profile_personal: new Set(['nationality']),
  profile_address:  new Set(['country']),
};

const PROFILE_FIELD_LABELS: Record<string, string> = {
  first_name: 'First Name', middle_name: 'Middle Name', last_name: 'Last Name',
  name: 'Full Name',
  nationality: 'Nationality', marital_status: 'Marital Status', gender: 'Gender',
  dob: 'Date of Birth', country_code: 'Country Code', mobile: 'Mobile',
  personal_email: 'Personal Email', line1: 'Address Line 1', line2: 'Address Line 2',
  landmark: 'Landmark', city: 'City', district: 'District', state: 'State',
  pin: 'PIN Code', country: 'Country', passport_number: 'Passport Number',
  issue_date: 'Issue Date', expiry_date: 'Expiry Date',
  relationship: 'Relationship', phone: 'Phone', alt_phone: 'Alt Phone', email: 'Email',
  effective_from: 'Effective From', preferred_name: 'Preferred Name',
  // Employment fields
  designation: 'Designation', job_title: 'Job Title', dept_id: 'Department',
  manager_id: 'Reports To', end_date: 'End Date',
  work_country: 'Work Country', work_location: 'Work Location',
  base_currency_id: 'Base Currency',
  // Job Relationships fields
  effective_from: 'Effective From', items: 'Assignments',
  // Education fields
  education_level: 'Education Level', degree: 'Degree', institution: 'Institution',
  start_date: 'Start Date',
  completion_status: 'Status', grade_or_gpa: 'Grade / GPA',
  is_highest_qualification: 'Highest Qualification',
};

// Canonical field display order per module — keys not listed appear last
const PROFILE_FIELD_ORDER: Record<string, string[]> = {
  profile_personal: [
    'effective_from',
    'first_name', 'middle_name',
    'last_name', 'name',
    'nationality', 'marital_status',
    'gender', 'dob',
  ],
  profile_employment: [
    'effective_from',
    'designation', 'job_title',
    'dept_id', 'manager_id',
    'work_country', 'work_location',
    'end_date', 'base_currency_id',
  ],
};

// Fields that render as <input type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"> in edit mode
const PROFILE_DATE_FIELDS = new Set(['dob', 'issue_date', 'expiry_date', 'effective_from', 'end_date', 'start_date']);

// Gender options for the inline select (not a picklist in the DB — stored as plain text)
const GENDER_OPTIONS = ['Male', 'Female'];

// ── HireEnrichment — read-only hire sections shown inline in the inbox panel ──
type HireField   = { label: string; value: string };
type HireAttachment = Record<string, unknown>;
type HireSection = { section: string; fields: HireField[]; attachments?: HireAttachment[] };

// Compact attachment chip — paperclip + count, click opens signed URL
function HireAttachmentChips({ atts }: { atts: HireAttachment[] }) {
  const [urls, setUrls] = useState<(string | null)[]>([]);

  useEffect(() => {
    Promise.all(atts.map(att => {
      const path = (att.storage_path ?? att.file_path) as string | undefined;
      if (!path) return Promise.resolve(null);
      return supabase.storage.from('hr-attachments')
        .createSignedUrl(path, 3600)
        .then(({ data, error }) => {
          if (error) console.warn('[HireAttachmentChips] signed URL failed', path, error.message);
          return data?.signedUrl ?? null;
        });
    })).then(setUrls);
  }, [atts.length]);

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
      {atts.map((att, i) => {
        const fileName = String(att.original_file_name ?? att.file_name ?? 'Attachment');
        const url = urls[i];
        const btnStyle: React.CSSProperties = {
          width: 26, height: 26, borderRadius: 6,
          background: '#F3F4F6', border: '1px solid #E5E7EB',
          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          cursor: 'pointer', textDecoration: 'none', color: '#374151', flexShrink: 0,
        };
        return (
          <div key={i} style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
            <span style={{
              display: 'inline-flex', alignItems: 'center', gap: 5,
              background: '#EEF2FF', border: '1px solid #C7D2FE',
              borderRadius: 20, padding: '3px 10px 3px 7px',
              fontSize: 11.5, color: '#4F46E5', fontWeight: 500,
              whiteSpace: 'nowrap', maxWidth: 180,
              overflow: 'hidden', textOverflow: 'ellipsis',
            }}>
              <i className="fa-solid fa-paperclip" style={{ fontSize: 10 }} />
              <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{fileName}</span>
            </span>
            {url && (
              <>
                <a href={url} target="_blank" rel="noreferrer" style={btnStyle} title="View">
                  <i className="fa-solid fa-eye" style={{ fontSize: 12 }} />
                </a>
                <a href={url} download={fileName} target="_blank" rel="noreferrer" style={btnStyle} title="Download">
                  <i className="fa-solid fa-download" style={{ fontSize: 12 }} />
                </a>
              </>
            )}
          </div>
        );
      })}
    </div>
  );
}

function HireEnrichment({ recordId }: { recordId: string }) {
  const [sections, setSections] = useState<HireSection[]>([]);
  const [loading,  setLoading]  = useState(true);

  useEffect(() => {
    setLoading(true);
    supabase.rpc('get_employee_hire_review', { p_employee_id: recordId })
      .then(({ data }) => {
        if (data) setSections(data as HireSection[]);
        setLoading(false);
      });
  }, [recordId]);

  if (loading) {
    return <div style={{ padding: '14px 0', color: '#6B7280', fontSize: 13 }}><i className="fas fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading hire details…</div>;
  }
  if (!sections.length) return null;

  return (
    <div style={{ marginBottom: 16 }}>
      <div className="wfi-profile-header">
        <SectionTitle icon="fa-user-plus" label="New Employee Hire" />
      </div>
      {sections.map(sec => (
        <div key={sec.section} style={{ marginBottom: 14 }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: '#0369A1', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 6 }}>
            {sec.section}
          </div>
          {/* Fields + attachments share the same bordered card */}
          <div style={{ border: '1px solid #BAE6FD', borderRadius: 6, overflow: 'hidden' }}>
            <div className="wfi-profile-grid">
              {sec.fields.map(f => (
                <div key={f.label}>
                  <div className="wfi-profile-field-label">{f.label}</div>
                  <div className={`wfi-profile-field-value${f.value === '—' ? ' wfi-hire-empty' : ''}`}>
                    {f.value === '—' ? 'Not provided' : f.value}
                  </div>
                </div>
              ))}
            </div>
            {sec.attachments && sec.attachments.length > 0 && (
              <div style={{ borderTop: '1px solid #BAE6FD', padding: '8px 12px', display: 'flex', alignItems: 'center', gap: 8 }}>
                <i className="fa-solid fa-paperclip" style={{ fontSize: 11, color: '#9CA3AF', flexShrink: 0 }} />
                <HireAttachmentChips atts={sec.attachments} />
              </div>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

// Internal fields that should never render as user-facing rows for profile_dependents
const DEP_INTERNAL_KEYS = new Set([
  'operation', 'employee_id', 'dependent_code', 'prev_data', 'attachments',
]);

// Relationship labels are resolved at call-time from the DEPENDENT_RELATIONSHIP_TYPE
// picklist (see DependentsEnrichment). Pass `labels` keyed by ref_id (or id) → display
// value so any newly-seeded entries resolve without code changes.
function fmtDepValue(key: string, val: unknown, labels?: Record<string, string>): string {
  if (val == null || val === '') return '—';
  if (typeof val === 'boolean' || val === 'true' || val === 'false')
    return (val === true || val === 'true') ? 'Yes' : 'No';
  const s = String(val);
  if (labels && labels[s]) return labels[s];
  if (/^\d{4}-\d{2}-\d{2}/.test(s))
    return new Date(s + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
  return s || '—';
}

const DEP_FIELD_ORDER = [
  ['dependent_name',    'Dependent Name'],
  ['relationship_type', 'Relationship'],
  ['date_of_birth',     'Date of Birth'],
  ['gender',            'Gender'],
  ['insurance_eligible','Insurance Eligible'],
  ['effective_from',    'Effective From'],
  ['removal_date',      'Removal Date'],
] as const;

// Sub-component: one attachment row — fetches signed URL on mount
function DepAttachmentRow({ att, docTypeLabel }: {
  att: Record<string, unknown>;
  docTypeLabel: string;
}) {
  const [url, setUrl] = useState<string | null>(null);

  useEffect(() => {
    const path = att.file_path as string | undefined;
    if (!path) return;
    supabase.storage.from('hr-attachments')
      .createSignedUrl(path, 3600)
      .then(({ data }) => { if (data?.signedUrl) setUrl(data.signedUrl); });
  }, [att.file_path]);

  const isImage   = String(att.mime_type ?? '').startsWith('image/');
  const icon      = isImage ? 'fa-file-image' : 'fa-file-pdf';
  const sizeKb    = att.file_size ? ((att.file_size as number) / 1024).toFixed(0) : null;
  const fileName  = String(att.original_file_name ?? att.file_name ?? 'Attachment');

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: '8px 10px',
      background: '#F9FAFB', border: '1px solid #E5E7EB',
      borderRadius: 7, fontSize: 12.5,
    }}>
      <i className={`fa-regular ${icon}`} style={{ color: '#6366F1', fontSize: 16, flexShrink: 0 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {fileName}
        </div>
        <div style={{ color: '#9CA3AF', fontSize: 11, marginTop: 1 }}>
          {docTypeLabel}{sizeKb ? ` · ${sizeKb} KB` : ''}
        </div>
      </div>
      {url && (
        <a href={url} target="_blank" rel="noreferrer"
          style={{ color: '#6366F1', fontSize: 12, textDecoration: 'none', flexShrink: 0, display: 'flex', alignItems: 'center', gap: 4 }}>
          <i className="fa-solid fa-eye" /> View
        </a>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DependentsEnrichment — set-snapshot diff viewer (Phase 3 rewrite)
//
// Replaces the old per-row enrichment with a set-level diff:
//   • Fetches proposed_data from workflow_pending_changes (by instanceId)
//   • Fetches current set via get_employee_dependent_set
//   • Computes NEW / AMENDED / REMOVED / UNCHANGED per item
//   • Approver edit is read-only in the panel; direct to Full View for edits
// ─────────────────────────────────────────────────────────────────────────────

type DepProposedItem = {
  dependent_code:   string | null;
  relationship_type: string;
  dependent_name:   string;
  date_of_birth:    string;
  gender:           string;
  insurance_eligible: boolean;
  attachments?:     Record<string, unknown>[];
};

type DepCurrentItem = {
  id:               string;
  dependent_code:   string;
  relationship_type: string;
  dependent_name:   string;
  date_of_birth:    string;
  gender:           string;
  insurance_eligible: boolean;
  attachments:      Record<string, unknown>[];
};

type DepDiffStatus = 'new' | 'amended' | 'removed' | 'unchanged';

type DepDiffItem = {
  status:        DepDiffStatus;
  proposed:      DepProposedItem | null;
  current:       DepCurrentItem  | null;
  code:          string | null;
  changedFields: string[];
};

const DEP_COMPARABLE_FIELDS = [
  'dependent_name', 'relationship_type', 'date_of_birth', 'gender', 'insurance_eligible',
];

const DEP_FIELD_LABELS_MAP: Record<string, string> = {
  dependent_name:    'Dependent Name',
  relationship_type: 'Relationship',
  date_of_birth:     'Date of Birth',
  gender:            'Gender',
  insurance_eligible:'Insurance Eligible',
};

function computeDepDiff(
  proposed: DepProposedItem[],
  current:  DepCurrentItem[],
): DepDiffItem[] {
  const result: DepDiffItem[] = [];
  const currentByCode = new Map(current.map(c => [c.dependent_code, c]));
  const proposedCodes = new Set(
    proposed.filter(p => p.dependent_code).map(p => p.dependent_code as string)
  );

  // NEW items (null/missing dependent_code)
  for (const p of proposed.filter(p => !p.dependent_code)) {
    result.push({ status: 'new', proposed: p, current: null, code: null, changedFields: [] });
  }

  // Existing codes — AMENDED or UNCHANGED
  for (const p of proposed.filter(p => p.dependent_code)) {
    const c = currentByCode.get(p.dependent_code!);
    if (!c) {
      result.push({ status: 'new', proposed: p, current: null, code: p.dependent_code, changedFields: [] });
      continue;
    }
    const changed = DEP_COMPARABLE_FIELDS.filter(f =>
      String((p as any)[f] ?? '') !== String((c as any)[f] ?? '')
    );
    result.push({
      status: changed.length > 0 ? 'amended' : 'unchanged',
      proposed: p, current: c,
      code: p.dependent_code, changedFields: changed,
    });
  }

  // REMOVED items (in current, not in proposed)
  for (const c of current) {
    if (!proposedCodes.has(c.dependent_code)) {
      result.push({ status: 'removed', proposed: null, current: c, code: c.dependent_code, changedFields: [] });
    }
  }

  return result;
}

function DependentsEnrichment({ metadata, instanceId, editMode, onExitEdit }: {
  metadata:    Record<string, unknown>;
  instanceId?: string;
  editMode?:   boolean;
  onExitEdit?: () => void;
}) {
  const { picklistValues } = usePicklistValues();

  const relOptions = picklistValues.filter(p => p.picklistId === 'DEPENDENT_RELATIONSHIP_TYPE' && p.active !== false);
  const docOptions = picklistValues.filter(p => p.picklistId === 'DEPENDENT_DOCUMENT_TYPE'     && p.active !== false);

  const relLabels = relOptions.reduce<Record<string, string>>((acc, r) => {
    if (r.refId) acc[String(r.refId)] = r.value;
    if (r.id)    acc[String(r.id)]    = r.value;
    return acc;
  }, {});

  const employeeId = String(metadata.employee_id ?? '');

  const [proposedItems, setProposedItems] = useState<DepProposedItem[]>([]);
  const [currentItems,  setCurrentItems]  = useState<DepCurrentItem[]>([]);
  const [effectiveFrom, setEffectiveFrom] = useState('');
  const [loading, setLoading] = useState(true);
  const [err, setErr]         = useState('');

  useEffect(() => {
    if (!instanceId && !employeeId) { setLoading(false); return; }
    let mounted = true;
    setLoading(true); setErr('');

    (async () => {
      try {
        // 1. Proposed items from workflow_pending_changes
        let proposed: DepProposedItem[] = [];
        let effFrom = String(metadata.effective_from ?? '');

        if (instanceId) {
          const { data: wpcRow, error: wpcErr } = await supabase
            .from('workflow_pending_changes')
            .select('proposed_data')
            .eq('instance_id', instanceId)
            .maybeSingle();
          if (wpcErr) throw new Error(wpcErr.message);
          if (wpcRow?.proposed_data) {
            const pd = wpcRow.proposed_data as any;
            proposed = Array.isArray(pd.items) ? pd.items : [];
            effFrom  = pd.effective_from ?? effFrom;
          }
        }

        // 2. Current active set
        let current: DepCurrentItem[] = [];
        if (employeeId) {
          const { data: setData } = await supabase
            .rpc('get_employee_dependent_set', { p_employee_id: employeeId });
          const sd = setData as { ok: boolean; set: any; items: DepCurrentItem[] } | null;
          current = sd?.items ?? [];
        }

        if (!mounted) return;
        setProposedItems(proposed);
        setCurrentItems(current);
        setEffectiveFrom(effFrom);
      } catch (e) {
        if (mounted) setErr((e as Error).message);
      } finally {
        if (mounted) setLoading(false);
      }
    })();

    return () => { mounted = false; };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instanceId, employeeId]);

  const diff = computeDepDiff(proposedItems, currentItems);
  const counts = {
    added:     diff.filter(d => d.status === 'new').length,
    amended:   diff.filter(d => d.status === 'amended').length,
    removed:   diff.filter(d => d.status === 'removed').length,
    unchanged: diff.filter(d => d.status === 'unchanged').length,
  };

  function fmtVal(key: string, val: unknown): string {
    if (val == null || val === '') return '—';
    if (key === 'insurance_eligible') return (val === true || val === 'true') ? 'Yes' : 'No';
    if (key === 'relationship_type')  return relLabels[String(val)] ?? String(val);
    if (/^\d{4}-\d{2}-\d{2}/.test(String(val)))
      return new Date(String(val) + 'T00:00:00').toLocaleDateString('en-GB',
        { day: '2-digit', month: 'short', year: 'numeric' });
    return String(val);
  }

  if (loading) return (
    <div style={{ padding: '20px 0', textAlign: 'center', color: '#9CA3AF' }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading dependents…
    </div>
  );

  if (err) return (
    <div style={{ color: '#DC2626', fontSize: 13, padding: '8px 0' }}>
      <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{err}
    </div>
  );

  const statusStyle = (s: DepDiffStatus) => ({
    new:       { border: '#BBF7D0', bg: '#F0FDF4', badge: '#059669', badgeBg: '#ECFDF5', label: 'NEW'       },
    amended:   { border: '#FDE68A', bg: '#FFFBEB', badge: '#D97706', badgeBg: '#FFFBEB', label: 'AMENDED'   },
    removed:   { border: '#FECACA', bg: '#FEF2F2', badge: '#DC2626', badgeBg: '#FEF2F2', label: 'REMOVED'   },
    unchanged: { border: '#E5E7EB', bg: '#fff',    badge: '#6B7280', badgeBg: '#F3F4F6', label: 'UNCHANGED' },
  }[s]);

  return (
    <div style={{ marginBottom: 16 }}>
      <div className="wfi-profile-header">
        <SectionTitle icon="fa-people-group" label="Proposed Dependents Change" />
      </div>

      {/* Summary chips */}
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14, alignItems: 'center' }}>
        {counts.added   > 0 && <span style={{ background: '#ECFDF5', color: '#059669', border: '1px solid #BBF7D0', borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>+{counts.added} added</span>}
        {counts.amended > 0 && <span style={{ background: '#FFFBEB', color: '#D97706', border: '1px solid #FDE68A', borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>{counts.amended} amended</span>}
        {counts.removed > 0 && <span style={{ background: '#FEF2F2', color: '#DC2626', border: '1px solid #FECACA', borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>−{counts.removed} removed</span>}
        {counts.unchanged > 0 && <span style={{ background: '#F3F4F6', color: '#6B7280', border: '1px solid #E5E7EB', borderRadius: 6, padding: '3px 10px', fontSize: 11.5 }}>{counts.unchanged} unchanged</span>}
        {effectiveFrom && (
          <span style={{ fontSize: 11.5, color: '#6B7280', display: 'flex', alignItems: 'center', gap: 4 }}>
            <i className="fa-solid fa-calendar-check" style={{ color: '#6366F1' }} />
            Effective {fmtVal('date_of_birth', effectiveFrom)}
          </span>
        )}
      </div>

      {/* Per-item diff cards */}
      {diff.map((item, idx) => {
        const data = item.proposed ?? item.current;
        if (!data) return null;
        const ss = statusStyle(item.status);
        const name   = String((data as any).dependent_name || '');
        const dob    = String((data as any).date_of_birth  || '');
        const gender = String((data as any).gender         || '');

        return (
          <div key={idx} style={{
            border: `1.5px solid ${ss.border}`, borderRadius: 10, marginBottom: 10,
            background: ss.bg, overflow: 'hidden', opacity: item.status === 'removed' ? 0.85 : 1,
          }}>
            {/* Card header */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', borderBottom: '1px solid rgba(0,0,0,0.05)' }}>
              <i className="fa-solid fa-person" style={{ color: ss.badge, fontSize: 16, flexShrink: 0 }} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 600, fontSize: 14, color: '#111827',
                  textDecoration: item.status === 'removed' ? 'line-through' : 'none',
                  overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {name || '—'}
                </div>
                {dob && (
                  <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
                    {fmtVal('date_of_birth', dob)}{gender ? ` · ${gender}` : ''}
                  </div>
                )}
              </div>
              <span style={{ background: ss.badgeBg, color: ss.badge, borderRadius: 5, padding: '2px 8px', fontSize: 10, fontWeight: 700, flexShrink: 0 }}>
                {ss.label}
              </span>
            </div>

            {/* Field grid */}
            <div style={{ padding: '10px 14px 14px' }}>
              <div className="wfi-profile-grid">
                {Object.entries(DEP_FIELD_LABELS_MAP).map(([key, label]) => {
                  const val    = item.proposed ? (item.proposed as any)[key] : (item.current as any)[key];
                  const oldVal = item.current  ? (item.current  as any)[key] : undefined;
                  const changed = item.status === 'amended' && item.changedFields.includes(key);

                  return (
                    <div key={key}>
                      <div className="wfi-profile-field-label">{label}</div>
                      <div style={{
                        fontSize: 13, fontWeight: changed ? 600 : 400,
                        background: changed ? '#FEFCE8' : 'transparent',
                        borderRadius: changed ? 4 : 0, padding: changed ? '2px 6px' : 0,
                        color: '#111827',
                      }}>
                        {fmtVal(key, val)}
                      </div>
                      {changed && oldVal !== undefined && (
                        <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2, textDecoration: 'line-through' }}>
                          was: {fmtVal(key, oldVal)}
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>

              {/* Attachments */}
              {item.status !== 'removed' && (() => {
                const atts = Array.isArray((item.proposed as any)?.attachments)
                  ? ((item.proposed as any).attachments as Record<string, unknown>[])
                  : [];
                if (!atts.length) return null;
                return (
                  <div style={{ marginTop: 10, paddingTop: 10, borderTop: '1px solid rgba(0,0,0,0.05)' }}>
                    <div className="wfi-profile-field-label" style={{ marginBottom: 6 }}>Documents</div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                      {atts.map((att, i) => {
                        const dPv = docOptions.find(p =>
                          String(p.refId) === String(att.document_type) ||
                          String(p.id)    === String(att.document_type)
                        );
                        return (
                          <DepAttachmentRow
                            key={String(att.file_path ?? i)}
                            att={att}
                            docTypeLabel={dPv?.value ?? String(att.document_type ?? 'Document')}
                          />
                        );
                      })}
                    </div>
                  </div>
                );
              })()}
            </div>
          </div>
        );
      })}

      {diff.length === 0 && !loading && (
        <div style={{ textAlign: 'center', color: '#9CA3AF', fontSize: 13, padding: '16px 0' }}>
          No dependents in this change request.
        </div>
      )}

      {/* Edit mode notice — full item editing is in WorkflowReview Full View */}
      {editMode && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          background: '#EFF6FF', border: '1px solid #BFDBFE',
          borderRadius: 7, padding: '10px 14px', marginTop: 10, fontSize: 12.5, color: '#1E40AF',
        }}>
          <i className="fa-solid fa-circle-info" style={{ flexShrink: 0 }} />
          <span>
            To modify individual dependent items, open the <strong>Full View</strong>.
            This panel shows the diff read-only.
          </span>
          <button onClick={() => onExitEdit?.()}
            style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#1D4ED8',
              fontSize: 12, marginLeft: 'auto', flexShrink: 0, fontWeight: 600 }}>
            Done
          </button>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// EducationEnrichment — single-record diff viewer for profile_education
//
// Education is non-effective-dated (each submission = one record add/edit/remove).
// proposed_data = the full education_data JSONB passed to upsert_education.
// current_data  = snapshot of the existing row (null for new records).
// Resolves education_level and completion_status picklist codes → labels.
// Shows attachment list with signed URLs if present.
// ─────────────────────────────────────────────────────────────────────────────

const EDU_DISPLAY_FIELDS = [
  'education_level', 'degree', 'institution',
  'start_date', 'end_date', 'completion_status', 'grade_or_gpa',
  'is_highest_qualification',
];

const EDU_FIELD_LABELS: Record<string, string> = {
  education_level: 'Education Level', degree: 'Degree', institution: 'Institution',
  start_date: 'Start Date', end_date: 'End Date',
  completion_status: 'Status', grade_or_gpa: 'Grade / GPA',
  is_highest_qualification: 'Highest Qualification',
};

function fmtEduField(key: string, val: unknown): string {
  if (val == null || val === '') return '—';
  if (key === 'is_highest_qualification') return (val === true || val === 'true') ? 'Yes' : 'No';
  if ((key === 'start_date' || key === 'end_date') && typeof val === 'string') {
    return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
  }
  return String(val);
}

function EducationEnrichment({ metadata, currentData }: {
  metadata:     Record<string, unknown>;
  currentData?: Record<string, unknown> | null;
  editMode?:    boolean;
  editValues?:  Record<string, string>;
  onEditChange?: (key: string, value: string) => void;
}) {
  const { picklistValues } = usePicklistValues();

  const levelLabels: Record<string, string> = Object.fromEntries(
    picklistValues
      .filter(p => p.picklistId === 'EDUCATION_LEVEL' && p.active !== false)
      .map(p => [String(p.refId ?? p.id), p.value])
  );
  const statusLabels: Record<string, string> = Object.fromEntries(
    picklistValues
      .filter(p => p.picklistId === 'COMPLETION_STATUS' && p.active !== false)
      .map(p => [String(p.refId ?? p.id), p.value])
  );
  const docTypeLabels: Record<string, string> = Object.fromEntries(
    picklistValues
      .filter(p => p.picklistId === 'EDUCATION_DOCUMENT_TYPE' && p.active !== false)
      .map(p => [String(p.refId ?? p.id), p.value])
  );

  function resolveEdu(key: string, val: unknown): string {
    if (key === 'education_level')   return levelLabels[String(val ?? '')] ?? fmtEduField(key, val);
    if (key === 'completion_status') return statusLabels[String(val ?? '')] ?? fmtEduField(key, val);
    return fmtEduField(key, val);
  }

  const isRemoval = metadata._operation === 'remove';
  const attachments = Array.isArray(metadata.attachments)
    ? (metadata.attachments as Record<string, unknown>[]).filter(a => !a._removed)
    : [];

  return (
    <div style={{ marginBottom: 16 }}>
      <div className="wfi-profile-header">
        <SectionTitle
          icon="fa-graduation-cap"
          label={isRemoval ? 'Record Removal Request' : 'Proposed Changes'}
        />
      </div>

      {isRemoval ? (
        <div style={{
          padding: '12px 14px', background: '#FEF2F2', border: '1.5px solid #FECACA',
          borderRadius: 8, fontSize: 13, color: '#B91C1C',
          display: 'flex', alignItems: 'center', gap: 8,
        }}>
          <i className="fa-solid fa-trash-can" />
          This request removes an education record.
        </div>
      ) : (
        <div className="wfi-profile-grid" style={{ border: '1px solid #BAE6FD' }}>
          {EDU_DISPLAY_FIELDS.map(key => {
            const proposed = metadata[key];
            const current  = currentData?.[key];
            const changed  = currentData != null && current !== proposed;
            const display  = resolveEdu(key, proposed);
            if (display === '—' && !changed) return null;
            return (
              <div key={key}>
                <div className="wfi-profile-field-label">{EDU_FIELD_LABELS[key]}</div>
                <div style={{
                  fontSize: 13, color: '#111827', fontWeight: changed ? 600 : 400,
                  background: changed ? '#FEFCE8' : 'transparent',
                  borderRadius: changed ? 4 : 0, padding: changed ? '2px 5px' : 0,
                }}>
                  {display === '—'
                    ? <span style={{ color: '#9CA3AF', fontStyle: 'italic' }}>—</span>
                    : display}
                </div>
                {changed && current !== undefined && (
                  <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2, textDecoration: 'line-through' }}>
                    was: {resolveEdu(key, current)}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Attachments */}
      {attachments.length > 0 && (
        <div style={{ marginTop: 10 }}>
          <div style={{ fontSize: 10.5, color: '#9CA3AF', fontWeight: 600, textTransform: 'uppercase', letterSpacing: 0.4, marginBottom: 6 }}>
            Documents
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
            {attachments.map((att, i) => (
              <EduAttachmentChip
                key={String(att.id ?? att.file_path ?? i)}
                att={att}
                docTypeLabel={docTypeLabels[String(att.document_type ?? '')] ?? String(att.document_type ?? 'Document')}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function EduAttachmentChip({ att, docTypeLabel }: {
  att: Record<string, unknown>;
  docTypeLabel: string;
}) {
  const [url, setUrl] = useState<string | null>(null);
  const filePath = String(att.file_path ?? '');

  useEffect(() => {
    if (!filePath) return;
    supabase.storage.from('hr-attachments').createSignedUrl(filePath, 3600)
      .then(({ data }) => { if (data?.signedUrl) setUrl(data.signedUrl); });
  }, [filePath]);

  const icon = String(att.mime_type ?? '').includes('pdf') ? 'fa-file-pdf' : 'fa-file-image';

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      background: '#F9FAFB', border: '1px solid #E5E7EB',
      borderRadius: 6, padding: '6px 10px', fontSize: 12,
    }}>
      <i className={`fa-regular ${icon}`} style={{ color: '#6366F1', fontSize: 14, flexShrink: 0 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {String(att.original_file_name ?? att.file_name ?? 'Document')}
        </div>
        <div style={{ color: '#9CA3AF', fontSize: 10.5 }}>{docTypeLabel}</div>
      </div>
      {url && (
        <a href={url} target="_blank" rel="noreferrer"
          style={{ color: '#6366F1', fontSize: 11.5, textDecoration: 'none', flexShrink: 0 }}>
          <i className="fa-solid fa-eye" /> View
        </a>
      )}
    </div>
  );
}

// TerminationEnrichment — summary card for module_code = 'termination'
//
// Fetches the termination (or reversal) record using the task recordId.
// The task metadata contains {employee_id, separation_date, initiation_type}
// (older in-flight records may still have termination_date — dual-read below)
// (for terminations) or {employee_id, termination_id, reversal_reason} (for reversals).
// ─────────────────────────────────────────────────────────────────────────────

function fmtTermDate(v?: string | null): string {
  if (!v) return '—';
  return new Date(v + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

function TerminationEnrichment({ recordId, metadata, editMode, editValues, onEditChange }: {
  recordId:      string;
  metadata:      Record<string, unknown>;
  editMode?:     boolean;
  editValues?:   Record<string, string>;
  onEditChange?: (key: string, value: string) => void;
}) {
  const [term,    setTerm]    = useState<Record<string, unknown> | null>(null);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');

  useEffect(() => {
    if (!recordId) return;
    (async () => {
      // Try termination table first, then reversal table
      const { data: termRow } = await supabase
        .from('employee_terminations')
        .select('*, employees(name, employee_id)')
        .eq('id', recordId)
        .maybeSingle();
      if (termRow) { setTerm(termRow); setLoading(false); return; }

      const { data: revRow, error: revErr } = await supabase
        .from('employee_termination_reversals')
        .select('*, employee_terminations!inner(separation_date, employee_id)')
        .eq('id', recordId)
        .maybeSingle();
      if (revErr) { setError(revErr.message); setLoading(false); return; }
      setTerm(revRow ?? null);
      setLoading(false);
    })();
  }, [recordId]);

  const { picklistValues } = usePicklistValues();
  const reasonLabels: Record<string, string> = Object.fromEntries(
    picklistValues
      .filter(p => p.picklistId === 'TERMINATION_REASON' || p.picklistId === 'RESIGNATION_REASON')
      .map(p => [String(p.refId ?? p.id), p.value])
  );

  if (loading) return (
    <div style={{ padding: '12px 0', color: '#6B7280', fontSize: 13, textAlign: 'center' }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading termination details…
    </div>
  );
  if (error) return <div style={{ color: '#DC2626', fontSize: 13 }}>{error}</div>;
  if (!term) return null;

  const isReversal = !!(term as any).reversal_reason;
  // Dual-read: support old key (termination_date) for in-flight workflows pre-mig 498
  const sepDate       = (term as any).separation_date ?? (term as any).termination_date;
  const noticeExpiry  = (term as any).notice_expiry_date ?? '';
  const origDate      = (term as any).employee_terminations?.separation_date
                      ?? (term as any).employee_terminations?.termination_date;

  // For the three mutable fields (last_working_date, notice_period_waived,
  // notice_period_waiver_reason), prefer live task.metadata over the DB-fetched
  // term object. The useEffect only re-fetches when recordId changes; after an
  // approver edit (Save Changes), recordId stays the same so term is stale.
  // update_termination_lwd patches wi.metadata (mig 526) so onRefreshTasks()
  // causes task.metadata to carry the updated values immediately.
  const liveLwd           = metadata?.last_working_date != null
    ? String(metadata.last_working_date)
    : String((term as any).last_working_date ?? '');
  const liveWaived        = metadata?.notice_period_waived != null
    ? Boolean(metadata.notice_period_waived)
    : Boolean((term as any).notice_period_waived);
  const liveWaiverReason  = metadata?.notice_period_waiver_reason != null
    ? String(metadata.notice_period_waiver_reason)
    : String((term as any).notice_period_waiver_reason ?? '');

  const terminatedEmployeeName = (term as any).employees?.name as string | undefined;

  const rows: [string, string][] = isReversal ? [
    ...(terminatedEmployeeName ? [['Employee', terminatedEmployeeName] as [string, string]] : []),
    ['Type',             'Reversal'],
    ['Reversal Reason',  String((term as any).reversal_reason ?? '—')],
    ['Comments',         String((term as any).comments ?? '—')],
    ['Original Date',    fmtTermDate(origDate)],
  ] : [
    ...(terminatedEmployeeName ? [['Employee', terminatedEmployeeName] as [string, string]] : []),
    ['Type',             String((term as any).termination_initiation_type ?? '—').replace(/_/g, ' ')],
    ['Separation Date',  fmtTermDate(sepDate)],
    ['Notice Expiry',    fmtTermDate(noticeExpiry)],
    ['Reason',           reasonLabels[String((term as any).termination_reason_code ?? '')] ?? String((term as any).termination_reason_code ?? '—')],
    ['Last Working Day', fmtTermDate(liveLwd || null)],
    ...(liveWaived ? [['Notice Waiver', liveWaiverReason || '—'] as [string, string]] : []),
    ['Comments',         String((term as any).comments ?? '—')],
  ];

  // In edit mode (approver), only last_working_date is editable.
  // If LWD < notice_expiry_date → waiver section shown and justification required.
  // Use liveLwd/liveWaiverReason as the base (metadata-preferred) so the edit
  // form pre-populates with the most recently saved values, not the stale DB fetch.
  const lwdValue     = editValues?.['last_working_date'] ?? liveLwd;
  const waiverValue  = editValues?.['notice_period_waiver_reason'] ?? liveWaiverReason;
  const waiverNeeded = editMode && !isReversal && noticeExpiry && lwdValue && lwdValue < noticeExpiry;

  // Shortfall = notice_expiry - lwd (calendar days)
  const shortfallDays = (waiverNeeded && noticeExpiry && lwdValue)
    ? Math.round((new Date(noticeExpiry).getTime() - new Date(lwdValue).getTime()) / 86400000)
    : 0;

  // Severity: 0 = compliant, 1–15 = amber, >15 = red
  const severity = shortfallDays === 0 ? 'compliant' : shortfallDays <= 15 ? 'amber' : 'red';
  const SEVERITY = {
    compliant: { label: 'COMPLIANT',                            bg: '#F0FDF4', border: '#BBF7D0', color: '#166534' },
    amber:     { label: `NOTICE SHORTFALL: ${shortfallDays} DAYS`,          bg: '#FFFBEB', border: '#FDE68A', color: '#92400E' },
    red:       { label: `SIGNIFICANT NOTICE SHORTFALL: ${shortfallDays} DAYS`, bg: '#FEF2F2', border: '#FECACA', color: '#7F1D1D' },
  }[severity];

  // Notice start date = submitted_at date (the base for notice computation)
  const noticeStartDate = (term as any).submitted_at
    ? String((term as any).submitted_at).slice(0, 10)
    : sepDate ?? '';

  const inputStyle: React.CSSProperties = {
    width: '100%', padding: '6px 8px', fontSize: 12.5,
    borderRadius: 5, border: '1px solid #93C5FD',
    background: '#EFF6FF', outline: 'none', boxSizing: 'border-box',
  };
  const labelStyle: React.CSSProperties = { minWidth: 150, color: '#6B7280', flexShrink: 0, fontSize: 13 };
  const WAIVER_MAX = 500;
  const WAIVER_MIN = 20;

  return (
    <div style={{ marginBottom: 16 }}>
      <div className="wfi-profile-header">
        <SectionTitle icon={isReversal ? 'fa-rotate-left' : 'fa-user-slash'} label="Termination Details" />
        {editMode && !isReversal && (
          <span className="wfi-editing-badge">
            <i className="fas fa-pencil" style={{ fontSize: 9, marginRight: 4 }} />Editing
          </span>
        )}
      </div>

      {editMode && !isReversal ? (
        /* ── Edit mode: read-only summary + editable LWD (+ optional waiver reason) ── */
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {/* Read-only fields */}
          {rows.filter(([label]) => label !== 'Last Working Day').map(([label, value]) => (
            <div key={label} style={{ display: 'flex', gap: 8, fontSize: 13 }}>
              <span style={labelStyle}>{label}</span>
              <span style={{ color: '#111827', fontWeight: 500 }}>{value}</span>
            </div>
          ))}
          {/* Editable: Last Working Date */}
          <div style={{ display: 'flex', gap: 8, fontSize: 13, alignItems: 'center' }}>
            <span style={labelStyle}>Last Working Day <span style={{ color: '#DC2626' }}>*</span></span>
            <input
              type="date"
              value={lwdValue}
              onChange={e => onEditChange?.('last_working_date', e.target.value)}
              style={{ ...inputStyle, width: 180 }}
            />
          </div>

          {/* ── Early Exit card — shown only when LWD < notice expiry ─────── */}
          {waiverNeeded && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10, marginTop: 4 }}>

              {/* Warning banner */}
              <div style={{
                background: severity === 'red' ? '#FEF2F2' : '#FFFBEB',
                border: `1px solid ${severity === 'red' ? '#FECACA' : '#FDE68A'}`,
                borderRadius: 8, padding: '12px 14px',
              }}>
                {/* Header */}
                <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginBottom: 10 }}>
                  <i className="fas fa-triangle-exclamation" style={{
                    color: severity === 'red' ? '#DC2626' : '#D97706', fontSize: 13, flexShrink: 0,
                  }} />
                  <span style={{
                    fontWeight: 700, fontSize: 12,
                    color: severity === 'red' ? '#7F1D1D' : '#78350F',
                    letterSpacing: '0.04em', textTransform: 'uppercase',
                  }}>
                    Early Exit Detected
                  </span>
                  {/* Severity badge */}
                  <span style={{
                    marginLeft: 'auto', fontSize: 10, fontWeight: 700,
                    letterSpacing: '0.05em', textTransform: 'uppercase',
                    padding: '2px 8px', borderRadius: 20,
                    background: SEVERITY.bg, border: `1px solid ${SEVERITY.border}`,
                    color: SEVERITY.color,
                  }}>
                    {SEVERITY.label}
                  </span>
                </div>

                {/* Notice Summary grid */}
                <div style={{
                  background: 'rgba(255,255,255,0.6)', borderRadius: 6,
                  border: `1px solid ${severity === 'red' ? '#FECACA' : '#FDE68A'}`,
                  padding: '8px 12px', marginBottom: 10,
                  display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '4px 16px',
                }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: '#6B7280', letterSpacing: '0.06em',
                    textTransform: 'uppercase', gridColumn: '1 / -1', marginBottom: 4 }}>
                    Notice Summary
                  </div>
                  {[
                    ['Notice Start Date', fmtTermDate(noticeStartDate)],
                    ['Notice Expiry',     fmtTermDate(noticeExpiry)],
                    ['Last Working Day',  fmtTermDate(lwdValue)],
                    ['Shortfall',         `${shortfallDays} day${shortfallDays !== 1 ? 's' : ''}`],
                  ].map(([k, v]) => (
                    <div key={k} style={{ display: 'flex', gap: 6, fontSize: 11.5, alignItems: 'baseline' }}>
                      <span style={{ color: '#6B7280', flexShrink: 0 }}>{k}</span>
                      <span style={{
                        fontWeight: 600,
                        color: k === 'Shortfall' ? (severity === 'red' ? '#DC2626' : '#D97706') : '#111827',
                      }}>{v}</span>
                    </div>
                  ))}
                </div>

                {/* Explanatory message */}
                <p style={{ margin: 0, fontSize: 12, color: severity === 'red' ? '#7F1D1D' : '#92400E', lineHeight: 1.5 }}>
                  The employee will leave before completing the required notice period.
                  A business justification is required before this request can be approved.
                </p>
              </div>

              {/* Justification field */}
              <div>
                <label style={{
                  display: 'block', fontSize: 12, fontWeight: 600, color: '#374151', marginBottom: 5,
                }}>
                  Notice Waiver Justification <span style={{ color: '#DC2626' }}>*</span>
                  <span style={{ fontWeight: 400, color: '#6B7280', marginLeft: 6 }}>
                    (min {WAIVER_MIN} chars · {waiverValue.length} / {WAIVER_MAX})
                  </span>
                </label>
                <textarea
                  value={waiverValue}
                  rows={3}
                  maxLength={WAIVER_MAX}
                  placeholder="Provide justification for approving an early release. Include business approval, notice buyout agreement, management exception, or any special circumstances supporting the waiver."
                  onChange={e => onEditChange?.('notice_period_waiver_reason', e.target.value)}
                  style={{
                    width: '100%', padding: '8px 10px', fontSize: 12.5,
                    borderRadius: 6, fontFamily: 'inherit', resize: 'vertical',
                    outline: 'none', boxSizing: 'border-box',
                    border: `1px solid ${
                      waiverValue.length === 0     ? '#D1D5DB' :
                      waiverValue.length < WAIVER_MIN ? '#FCA5A5' : '#86EFAC'
                    }`,
                    background: waiverValue.length >= WAIVER_MIN ? '#F0FDF4' : '#FFFFFF',
                  }}
                />
                {waiverValue.length > 0 && waiverValue.length < WAIVER_MIN && (
                  <small style={{ color: '#DC2626', fontSize: 11, display: 'flex', alignItems: 'center', gap: 4, marginTop: 3 }}>
                    <i className="fas fa-circle-exclamation" />
                    Notice Waiver Justification is required when a notice shortfall exists. Minimum {WAIVER_MIN} characters.
                  </small>
                )}
                {waiverValue.length === 0 && (
                  <small style={{ color: '#6B7280', fontSize: 11, marginTop: 3, display: 'block' }}>
                    Notice Waiver Justification is required when a notice shortfall exists.
                  </small>
                )}
              </div>
            </div>
          )}
        </div>
      ) : (
        /* ── Read-only view ── */
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {rows.map(([label, value]) => (
            <div key={label} style={{ display: 'flex', gap: 8, fontSize: 13 }}>
              <span style={labelStyle}>{label}</span>
              <span style={{ color: '#111827', fontWeight: 500 }}>{value}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}


// BankEnrichment — set-snapshot diff viewer (Phase 5 rewrite)
//
// Mirrors DependentsEnrichment: read-only set-level diff in the inbox panel.
// Full item editing lives in WorkflowReview Full View.
// metadata = proposed_data: { employee_id, effective_from, items: [...] }
// ─────────────────────────────────────────────────────────────────────────────

const BANK_CMP_FIELDS_INBOX = [
  'bank_name', 'account_holder_name', 'account_number',
  'country_code', 'currency_code', 'branch_name', 'branch_code',
  'ifsc_code', 'iban', 'swift_bic', 'is_primary',
];

const BANK_FIELD_LABELS_INBOX: Record<string, string> = {
  bank_name: 'Bank Name', account_holder_name: 'Account Holder',
  account_number: 'Account Number', country_code: 'Country',
  currency_code: 'Currency', branch_name: 'Branch',
  branch_code: 'Branch Code', ifsc_code: 'IFSC Code',
  iban: 'IBAN', swift_bic: 'SWIFT / BIC', is_primary: 'Primary',
};

function fmtBankFieldInbox(key: string, val: unknown): string {
  if (val == null || val === '') return '—';
  if (key === 'is_primary') return (val === true || val === 'true') ? 'Yes' : 'No';
  if (key === 'account_number') {
    const s = String(val);
    return s.length > 4 ? '•'.repeat(s.length - 4) + s.slice(-4) : s;
  }
  return String(val);
}

function BankEnrichment({ metadata }: {
  metadata: Record<string, unknown>;
  // editMode / editValues / onEditChange intentionally ignored — inbox is read-only.
  // Parent handleApproverSave is no-op for profile_bank (same pattern as profile_dependents).
  editMode?:     boolean;
  editValues?:   Record<string, string>;
  onEditChange?: (key: string, value: string) => void;
}) {
  const empId        = String(metadata.employee_id ?? '');
  const effectiveFrom = String(metadata.effective_from ?? '');
  const proposedItems: Record<string, unknown>[] = Array.isArray(metadata.items)
    ? metadata.items as Record<string, unknown>[]
    : [];

  // Load current active set for diff
  const [currentItems, setCurrentItems] = useState<Record<string, unknown>[]>([]);
  const [loading,      setLoading]      = useState(false);
  const [loadErr,      setLoadErr]      = useState('');

  useEffect(() => {
    if (!empId) return;
    let cancelled = false;
    setLoading(true);
    supabase.rpc('get_employee_bank_account_set', { p_employee_id: empId })
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) { setLoadErr(error.message); }
        else {
          const sd = data as { ok: boolean; items: Record<string, unknown>[] } | null;
          setCurrentItems(sd?.items ?? []);
        }
        setLoading(false);
      });
    return () => { cancelled = true; };
  }, [empId]);

  // Compute set-snapshot diff
  type BankDiffStatus = 'new' | 'amended' | 'removed' | 'unchanged';
  type BankDiffItem = {
    status: BankDiffStatus;
    proposed: Record<string, unknown> | null;
    current:  Record<string, unknown> | null;
    changedFields: string[];
  };

  const currentByGroup = new Map(currentItems.map(c => [String(c.bank_account_group_id ?? ''), c]));
  const proposedGroupIds = new Set(
    proposedItems.filter(p => p.bank_account_group_id).map(p => String(p.bank_account_group_id))
  );

  const diff: BankDiffItem[] = [];
  for (const p of proposedItems.filter(p => !p.bank_account_group_id))
    diff.push({ status: 'new', proposed: p, current: null, changedFields: [] });
  for (const p of proposedItems.filter(p => p.bank_account_group_id)) {
    const gid = String(p.bank_account_group_id);
    const c = currentByGroup.get(gid);
    if (!c) { diff.push({ status: 'new', proposed: p, current: null, changedFields: [] }); continue; }
    const changed = BANK_CMP_FIELDS_INBOX.filter(f => String((p as any)[f] ?? '') !== String((c as any)[f] ?? ''));
    diff.push({ status: changed.length > 0 ? 'amended' : 'unchanged', proposed: p, current: c, changedFields: changed });
  }
  for (const c of currentItems)
    if (!proposedGroupIds.has(String(c.bank_account_group_id ?? '')))
      diff.push({ status: 'removed', proposed: null, current: c, changedFields: [] });

  const counts = {
    added:     diff.filter(d => d.status === 'new').length,
    amended:   diff.filter(d => d.status === 'amended').length,
    removed:   diff.filter(d => d.status === 'removed').length,
    unchanged: diff.filter(d => d.status === 'unchanged').length,
  };

  const ssStyle = (s: BankDiffStatus) => ({
    new:       { border: '#BBF7D0', bg: '#F0FDF4', color: '#059669', label: 'NEW'       },
    amended:   { border: '#FDE68A', bg: '#FFFBEB', color: '#D97706', label: 'AMENDED'   },
    removed:   { border: '#FECACA', bg: '#FEF2F2', color: '#DC2626', label: 'REMOVED'   },
    unchanged: { border: '#E5E7EB', bg: '#fff',    color: '#6B7280', label: 'UNCHANGED' },
  }[s]);

  if (loading) return (
    <div style={{ textAlign: 'center', padding: '14px 0', color: '#9CA3AF', fontSize: 13 }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading bank details…
    </div>
  );
  if (loadErr) return (
    <div style={{ color: '#DC2626', fontSize: 13, padding: '8px 0' }}>
      <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{loadErr}
    </div>
  );

  return (
    <div style={{ marginBottom: 16 }}>
      <div className="wfi-profile-header">
        <SectionTitle icon="fa-building-columns" label="Proposed Changes" />
      </div>

      {/* Summary chips */}
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 10 }}>
        {effectiveFrom && (
          <span style={{ fontSize: 11, color: '#6366F1', fontWeight: 600,
            background: '#EEF2FF', borderRadius: 4, padding: '2px 8px' }}>
            Effective {new Date(effectiveFrom + 'T00:00:00').toLocaleDateString('en-GB', {
              day: '2-digit', month: 'short', year: 'numeric',
            })}
          </span>
        )}
        {counts.added   > 0 && <span style={{ background: '#ECFDF5', color: '#059669', border: '1px solid #BBF7D0', borderRadius: 4, padding: '2px 8px', fontSize: 11, fontWeight: 600 }}>+{counts.added} added</span>}
        {counts.amended > 0 && <span style={{ background: '#FFFBEB', color: '#D97706', border: '1px solid #FDE68A', borderRadius: 4, padding: '2px 8px', fontSize: 11, fontWeight: 600 }}>{counts.amended} amended</span>}
        {counts.removed > 0 && <span style={{ background: '#FEF2F2', color: '#DC2626', border: '1px solid #FECACA', borderRadius: 4, padding: '2px 8px', fontSize: 11, fontWeight: 600 }}>−{counts.removed} removed</span>}
        {counts.unchanged > 0 && <span style={{ background: '#F3F4F6', color: '#6B7280', border: '1px solid #E5E7EB', borderRadius: 4, padding: '2px 8px', fontSize: 11 }}>{counts.unchanged} unchanged</span>}
      </div>

      {/* Per-item diff cards */}
      {diff.map((item, idx) => {
        const data = item.proposed ?? item.current;
        if (!data) return null;
        const ss = ssStyle(item.status);
        return (
          <div key={idx} style={{
            border: `1.5px solid ${ss.border}`, borderRadius: 8, marginBottom: 8,
            background: ss.bg, overflow: 'hidden',
            opacity: item.status === 'removed' ? 0.8 : 1,
          }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', borderBottom: '1px solid rgba(0,0,0,0.05)' }}>
              <i className="fa-solid fa-building-columns" style={{ color: ss.color, fontSize: 14, flexShrink: 0 }} />
              <div style={{ flex: 1, minWidth: 0, fontWeight: 600, fontSize: 13, color: '#111827',
                textDecoration: item.status === 'removed' ? 'line-through' : 'none',
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {String(data.bank_name || '—')}
              </div>
              {data.is_primary && (
                <span style={{ background: '#EEF2FF', color: '#4F46E5', borderRadius: 4, padding: '1px 6px', fontSize: 10, fontWeight: 700 }}>Primary</span>
              )}
              <span style={{ background: ss.bg, color: ss.color, border: `1px solid ${ss.border}`, borderRadius: 4, padding: '1px 6px', fontSize: 10, fontWeight: 700 }}>{ss.label}</span>
            </div>
            <div className="wfi-profile-grid" style={{ padding: '8px 12px 10px', border: 'none', gridTemplateColumns: 'repeat(2, 1fr)' }}>
              {BANK_CMP_FIELDS_INBOX.filter(f => f !== 'is_primary').map(key => {
                const val     = item.proposed ? (item.proposed as any)[key] : (item.current as any)[key];
                const oldVal  = item.current  ? (item.current  as any)[key] : undefined;
                const changed = item.status === 'amended' && item.changedFields.includes(key);
                const display = fmtBankFieldInbox(key, val);
                if (display === '—' && !changed) return null;
                return (
                  <div key={key}>
                    <div className="wfi-profile-field-label">{BANK_FIELD_LABELS_INBOX[key]}</div>
                    <div style={{ fontSize: 13, color: '#111827', fontWeight: changed ? 600 : 400,
                      background: changed ? '#FEFCE8' : 'transparent',
                      borderRadius: changed ? 4 : 0, padding: changed ? '2px 5px' : 0 }}>
                      {display === '—' ? <span style={{ color: '#9CA3AF', fontStyle: 'italic' }}>—</span> : display}
                    </div>
                    {changed && oldVal !== undefined && (
                      <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2, textDecoration: 'line-through' }}>
                        was: {fmtBankFieldInbox(key, oldVal)}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        );
      })}

      {diff.length === 0 && (
        <div style={{ fontSize: 13, color: '#9CA3AF', textAlign: 'center', padding: '12px 0' }}>
          No bank account items in this request.
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// EmploymentEnrichment — FK-aware renderer for profile_employment requests
// Resolves dept_id → dept name, manager_id → employee name, picklists inline.
// ─────────────────────────────────────────────────────────────────────────────

function EmploymentEnrichment({ metadata, currentData, editMode, editValues, onEditChange }: {
  metadata:      Record<string, unknown>;
  currentData?:  Record<string, unknown> | null;
  editMode?:     boolean;
  editValues?:   Record<string, string>;
  onEditChange?: (key: string, value: string) => void;
}) {
  const { picklistValues }   = usePicklistValues();
  const { departments }      = useDepartments();
  const { employees }        = useEmployees();
  const { currencies }       = useCurrencies();

  function resolveDept(id: unknown): string {
    if (!id) return '—';
    const d = departments.find(d => d.id === id);
    return d?.name ?? d?.deptId ?? String(id);
  }

  function resolveManager(id: unknown): string {
    if (!id) return '—';
    const e = employees.find(e => e.id === id);
    return e ? `${e.name}${e.jobTitle ? ` — ${e.jobTitle}` : ''}` : String(id);
  }

  function resolveCurrency(id: unknown): string {
    if (!id) return '—';
    const c = currencies.find(c => c.id === id);
    return c?.name ?? String(id);
  }

  function resolvePicklist(picklistId: string, id: unknown): string {
    if (!id) return '—';
    const found = picklistValues.find(v => v.picklistId === picklistId && v.id === id);
    return found?.value ?? String(id);
  }

  function resolveField(key: string, raw: unknown): string {
    if (raw == null || raw === '') return '—';
    switch (key) {
      case 'designation':    return resolvePicklist('DESIGNATION', raw);
      case 'work_country':   return resolvePicklist('ID_COUNTRY',  raw);
      case 'work_location':  return resolvePicklist('LOCATION',    raw);
      case 'dept_id':        return resolveDept(raw);
      case 'manager_id':     return resolveManager(raw);
      case 'base_currency_id': return resolveCurrency(raw);
      default:               return String(raw);
    }
  }

  const fieldOrder = PROFILE_FIELD_ORDER['profile_employment'] ?? [];
  const merged: Record<string, unknown> = { ...(currentData ?? {}), ...metadata };
  const entries: [string, unknown][] = [
    ...fieldOrder.filter(k => k in merged).map(k => [k, merged[k]] as [string, unknown]),
    ...Object.entries(merged).filter(([k]) => !fieldOrder.includes(k) && k !== 'employee_id'),
  ];

  if (!entries.length) return null;

  // filtered locations for work_location edit select
  const selectedCountry = editValues?.['work_country'] ?? '';

  return (
    <div style={{ marginBottom: 16 }}>
      <div className="wfi-profile-header">
        <SectionTitle icon="fa-pen-to-square" label={editMode ? 'Edit Proposed Changes' : 'Proposed Changes'} />
        {editMode && (
          <span className="wfi-editing-badge">
            <i className="fas fa-pencil" style={{ fontSize: 9, marginRight: 4 }} />
            Editing
          </span>
        )}
      </div>
      <div className="wfi-profile-grid" style={{ border: `1px solid ${editMode ? '#7DD3FC' : '#BAE6FD'}` }}>
        {entries.map(([k, v]) => {
          const proposedLabel = resolveField(k, v);
          const hasOld        = currentData != null && currentData[k] !== v;
          const oldLabel      = hasOld ? resolveField(k, currentData![k]) : null;

          return (
            <div key={k}>
              <div className="wfi-profile-field-label">
                {PROFILE_FIELD_LABELS[k] ?? k.replace(/_/g, ' ')}
              </div>
              {editMode && onEditChange ? (
                k === 'designation' ? (
                  <select value={editValues?.[k] ?? ''} onChange={e => onEditChange(k, e.target.value)} className="wfi-profile-input">
                    <option value="">— Select —</option>
                    {picklistValues.filter(pv => pv.picklistId === 'DESIGNATION').map(pv => <option key={pv.id} value={pv.id}>{pv.value}</option>)}
                  </select>
                ) : k === 'work_country' ? (
                  <select value={editValues?.[k] ?? ''} onChange={e => { onEditChange(k, e.target.value); onEditChange('work_location', ''); }} className="wfi-profile-input">
                    <option value="">— Select —</option>
                    {picklistValues.filter(pv => pv.picklistId === 'ID_COUNTRY').map(pv => <option key={pv.id} value={pv.id}>{pv.value}</option>)}
                  </select>
                ) : k === 'work_location' ? (
                  <select value={editValues?.[k] ?? ''} onChange={e => onEditChange(k, e.target.value)} className="wfi-profile-input">
                    <option value="">{selectedCountry ? '— Select Location —' : '— Select country first —'}</option>
                    {picklistValues.filter(pv => pv.picklistId === 'LOCATION' && String(pv.parentValueId) === selectedCountry).map(pv => <option key={pv.id} value={pv.id}>{pv.value}</option>)}
                  </select>
                ) : k === 'dept_id' ? (
                  <select value={editValues?.[k] ?? ''} onChange={e => onEditChange(k, e.target.value)} className="wfi-profile-input">
                    <option value="">— Select —</option>
                    {departments.map(d => <option key={d.id} value={d.id}>{d.name ?? d.deptId}</option>)}
                  </select>
                ) : k === 'manager_id' ? (
                  <select value={editValues?.[k] ?? ''} onChange={e => onEditChange(k, e.target.value)} className="wfi-profile-input">
                    <option value="">— Select —</option>
                    {employees.map(e => <option key={e.id} value={e.id}>{e.name}{e.jobTitle ? ` — ${e.jobTitle}` : ''}</option>)}
                  </select>
                ) : k === 'base_currency_id' ? (
                  <div className="wfi-profile-field-value" style={{ color: '#6B7280', fontSize: 12 }}>
                    {resolveCurrency(v)} <span style={{ color: '#9CA3AF' }}>(auto-derived)</span>
                  </div>
                ) : PROFILE_DATE_FIELDS.has(k) ? (
                  <>
                    <input type="date" min="1900-01-01" max="2100-12-31" value={editValues?.[k] ?? ''} onChange={e => {
                      const val = e.target.value;
                      onEditChange(k, val);
                      // end_date must not be before hire_date
                      if (k === 'end_date' && val && val !== '9999-12-31') {
                        const hd = String(currentData?.['hire_date'] ?? '');
                        if (hd && val < hd) onEditChange('_date_error_end_date', 'End Date cannot be before Hire Date.');
                        else onEditChange('_date_error_end_date', '');
                      }
                      // expiry_date must be future
                      if (k === 'expiry_date') {
                        const today = new Date().toISOString().slice(0, 10);
                        if (val && val <= today) onEditChange('_date_error_expiry_date', 'Expiry Date must be a future date.');
                        else onEditChange('_date_error_expiry_date', '');
                      }
                    }} className="wfi-profile-input" />
                    {k === 'end_date' && editValues?.['_date_error_end_date'] && (
                      <div style={{ fontSize: 11, color: '#EF4444', marginTop: 3 }}>{editValues['_date_error_end_date']}</div>
                    )}
                    {k === 'expiry_date' && editValues?.['_date_error_expiry_date'] && (
                      <div style={{ fontSize: 11, color: '#EF4444', marginTop: 3 }}>{editValues['_date_error_expiry_date']}</div>
                    )}
                  </>
                ) : (
                  <input type="text" value={editValues?.[k] ?? ''} onChange={e => onEditChange(k, e.target.value)} className="wfi-profile-input" />
                )
              ) : (
                <>
                  <div className="wfi-profile-field-value">{proposedLabel}</div>
                  {hasOld && oldLabel && <div className="wfi-profile-field-old">{oldLabel}</div>}
                </>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────

function ProfileEnrichment({ moduleCode, metadata, currentData, editMode, editValues, onEditChange, instanceId, onExitEdit }: {
  moduleCode:    string;
  metadata:      Record<string, unknown>;
  currentData?:  Record<string, unknown> | null;
  editMode?:     boolean;
  editValues?:   Record<string, string>;
  onEditChange?: (key: string, value: string) => void;
  /** Passed through to DependentsEnrichment for fetching workflow_pending_changes */
  instanceId?:   string;
  /** Called by DependentsEnrichment when the approver finishes viewing the edit notice */
  onExitEdit?:   () => void;
}) {
  const { picklistValues } = usePicklistValues();
  const picklistMap   = PROFILE_PICKLIST_FIELDS[moduleCode] ?? {};
  const countryFields = PROFILE_COUNTRY_FIELDS[moduleCode]  ?? new Set<string>();

  function resolveValue(key: string, raw: unknown): string {
    if (raw == null || raw === '') return '—';
    const picklistId = picklistMap[key];
    if (picklistId) {
      const found = picklistValues.find(v => v.picklistId === picklistId && v.id === raw);
      return found?.value ?? String(raw);
    }
    return String(raw);
  }

  // ── Dependents: delegate to DependentsEnrichment (set-snapshot diff view) ─
  if (moduleCode === 'profile_dependents') {
    return (
      <DependentsEnrichment
        metadata={metadata}
        instanceId={instanceId}
        editMode={editMode}
        onExitEdit={onExitEdit}
      />
    );
  }

  // ── Education: delegate to EducationEnrichment ───────────────────────────
  if (moduleCode === 'profile_education') {
    return (
      <EducationEnrichment
        metadata={metadata}
        currentData={currentData}
        editMode={editMode}
        editValues={editValues}
        onEditChange={onEditChange}
      />
    );
  }

  // ── Bank: delegate to BankEnrichment (needs its own hooks) ────────────────
  if (moduleCode === 'profile_bank') {
    return (
      <BankEnrichment
        metadata={metadata}
        editMode={editMode}
        editValues={editValues}
        onEditChange={onEditChange}
      />
    );
  }

  // ── Employment: delegate to EmploymentEnrichment (FK-aware resolution) ───
  if (moduleCode === 'profile_employment') {
    return (
      <EmploymentEnrichment
        metadata={metadata}
        currentData={currentData}
        editMode={editMode}
        editValues={editValues}
        onEditChange={onEditChange}
      />
    );
  }

  // ── All other profile modules: generic key-value grid ───────────────────
  const fieldOrder = PROFILE_FIELD_ORDER[moduleCode];

  // For modules with a canonical field order, supplement metadata with
  // currentData so every field always shows (not just the ones that changed).
  const mergedData: Record<string, unknown> = fieldOrder
    ? { ...(currentData ?? {}), ...metadata }
    : metadata;

  const rawEntries = Object.entries(mergedData).filter(([k]) => k !== 'employee_id' && !k.startsWith('_'));
  const entries = fieldOrder
    ? [
        ...fieldOrder.filter(k => k in mergedData).map(k => [k, mergedData[k]] as [string, unknown]),
        ...rawEntries.filter(([k]) => !fieldOrder.includes(k)),
      ]
    : rawEntries;
  if (!entries.length) return null;

  return (
    <div style={{ marginBottom: 16 }}>
      <div className="wfi-profile-header">
        <SectionTitle icon="fa-pen-to-square" label={editMode ? 'Edit Proposed Changes' : 'Proposed Changes'} />
        {editMode && (
          <span className="wfi-editing-badge">
            <i className="fas fa-pencil" style={{ fontSize: 9, marginRight: 4 }} />
            Editing
          </span>
        )}
      </div>
      <div className="wfi-profile-grid" style={{ border: `1px solid ${editMode ? '#7DD3FC' : '#BAE6FD'}` }}>
        {entries.map(([k, v]) => {
          const proposedLabel = resolveValue(k, v);
          const hasOld        = currentData != null && currentData[k] !== v;
          const oldLabel      = hasOld ? resolveValue(k, currentData![k]) : null;
          const picklistId    = picklistMap[k];

          return (
            <div key={k}>
              <div className="wfi-profile-field-label">
                {PROFILE_FIELD_LABELS[k] ?? k.replace(/_/g, ' ')}
              </div>

              {editMode && onEditChange ? (
                // ── Edit mode: render the right input type ────────────────
                countryFields.has(k) ? (
                  // Country name stored as plain string (not a picklist UUID)
                  <select
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    className="wfi-profile-input"
                  >
                    <option value="">— Select —</option>
                    {COUNTRIES.map(c => <option key={c} value={c}>{c}</option>)}
                  </select>
                ) : picklistId ? (
                  <select
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    className="wfi-profile-input"
                  >
                    <option value="">— Select —</option>
                    {picklistValues
                      .filter(pv => pv.picklistId === picklistId)
                      .map(pv => <option key={pv.id} value={pv.id}>{pv.value}</option>)}
                  </select>
                ) : PROFILE_DATE_FIELDS.has(k) ? (
                  <input
                    type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    className="wfi-profile-input"
                  />
                ) : k === 'gender' ? (
                  <select
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    className="wfi-profile-input"
                  >
                    <option value="">— Select —</option>
                    {GENDER_OPTIONS.map(g => <option key={g} value={g}>{g}</option>)}
                  </select>
                ) : (
                  <input
                    type="text"
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    className="wfi-profile-input"
                  />
                )
              ) : (
                // ── Read mode: static display ─────────────────────────────
                <>
                  <div className="wfi-profile-field-value">{proposedLabel}</div>
                  {hasOld && oldLabel && (
                    <div className="wfi-profile-field-old">{oldLabel}</div>
                  )}
                </>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

const META_HEADER_KEYS = new Set(['name', 'total_amount', 'currency_code', 'status', 'dept_id', 'currency_id', 'employee_id', 'work_country',
  // termination / reversal keys — rendered by TerminationEnrichment, not the header meta row
  'termination_id', 'reversal_reason',
]);

// ─────────────────────────────────────────────────────────────────────────────
// To Approve tab — Detail Panel
// ─────────────────────────────────────────────────────────────────────────────

interface ApproveActionBarFullProps extends ApproveActionBarProps {
  /** Called after a mid-flight edit Save — refreshes task list WITHOUT moving
   *  to the next task (contrast with onAfterAction which advances the selection). */
  onRefreshTasks: () => void;
}

function DetailPanel({
  task, onApprove, onReject, onReassign, onReturnToInitiator, onReturnToPreviousStep,
  onAfterAction, onRefreshTasks,
}: ApproveActionBarFullProps) {
  const navigate = useNavigate();
  const { can } = usePermissions();
  const wf = useWorkflowInstance(task.moduleCode, task.recordId);
  const extraMeta = Object.entries(task.metadata ?? {}).filter(([k]) => !META_HEADER_KEYS.has(k));
  // WorkflowReview handles expense_reports, employee_hire, and profile_employment
  // (full-page review surface). Other profile modules use inline edit (Pattern B).
  const FULL_REVIEW_MODULES = new Set(['expense_reports', 'employee_hire', 'profile_employment', 'termination', 'termination_reversal']);
  const fullViewRoute = FULL_REVIEW_MODULES.has(task.moduleCode) ? `/workflow/review/${task.recordId}` : null;

  const [participantsOpen, setParticipantsOpen] = useState(false);

  const [resolvedAmount,   setResolvedAmount]   = useState<number | undefined>(task.metadata?.total_amount as number | undefined);
  const [resolvedCurrency, setResolvedCurrency] = useState<string | undefined>(task.metadata?.currency_code as string | undefined);

  // For termination module: resolve the terminated employee's name.
  // metadata.employee_name is reliable (set by mig 575+).
  // subjectEmployeeName is NOT reliable for pre-575 records (it equals the
  // submitter when initiated_by_actor_id was not stamped). Always DB-fetch
  // as the authoritative source; seed optimistically from metadata first.
  const [terminationSubjectName, setTerminationSubjectName] = useState<string | null>(
    (task.metadata?.employee_name as string | undefined) ?? null
  );
  useEffect(() => {
    setTerminationSubjectName((task.metadata?.employee_name as string | undefined) ?? null);
    if (task.moduleCode === 'termination' || task.moduleCode === 'termination_reversal') {
      supabase
        .from('employee_terminations')
        .select('employees(name)')
        .eq('id', task.recordId)
        .maybeSingle()
        .then(({ data }) => {
          const name = (data as any)?.employees?.name as string | undefined;
          if (name) setTerminationSubjectName(name);
        });
    }
  }, [task.taskId]);

  useEffect(() => {
    setResolvedAmount(task.metadata?.total_amount as number | undefined);
    setResolvedCurrency(task.metadata?.currency_code as string | undefined);
  }, [task.taskId]);

  // ── Edit gate: step_allow_edit from task (via vw_wf_pending_tasks, mig 197)
  // edit_route from module_codes drives Pattern A (navigate) vs B (inline).
  // stepAllowEdit no longer needs a separate query — it comes from the view.
  const [editRoute,  setEditRoute]  = useState<string | null>(null);
  const [editMode,   setEditMode]   = useState(false);
  const [editValues, setEditValues] = useState<Record<string, string>>({});
  const [editSaving, setEditSaving] = useState(false);
  const [editError,  setEditError]  = useState<string | null>(null);

  useEffect(() => {
    setEditRoute(null);
    setEditMode(false);
    setEditValues({});
    setEditError(null);
    if (!task.taskId) return;

    // Fetch edit_route from module_codes — non-null = Pattern A (navigate to form)
    // null = Pattern B (inline edit of proposed changes)
    supabase
      .from('module_codes')
      .select('edit_route')
      .eq('code', task.moduleCode)
      .maybeSingle()
      .then(({ data }) => {
        setEditRoute((data as any)?.edit_route ?? null);
      });
  }, [task.taskId, task.moduleCode]);

  // Module-code → RBP permission code mapping.
  // The module_code keys do NOT match the permission resource codes — e.g.
  // 'profile_personal' maps to the 'personal_info' resource seeded in mig 082.
  // Map workflow module_code → RBP permission resource code.
  // Workflow engine and RBP permission catalog use different naming conventions.
  const MODULE_EDIT_PERMISSION: Record<string, string> = {
    profile_personal:          'personal_info.edit',
    profile_contact:           'contact_info.edit',
    profile_address:           'address.edit',
    profile_passport:          'passport.edit',
    profile_identification:    'identity_documents.edit',
    profile_emergency_contact: 'emergency_contacts.edit',
    profile_employment:        'employment.edit',
    profile_dependents:        'dependents.edit',
    profile_bank:              'bank_accounts.edit',
    profile_education:         'education.edit',
    expense_reports:           'expense_reports.edit',
    employee_hire:             'hire_employee.edit', // workflow='employee_hire', RBP='hire_employee'
    termination:               'termination.edit',
  };
  const editPermCode = MODULE_EDIT_PERMISSION[task.moduleCode] ?? `${task.moduleCode}.edit`;

  // handlePanelUpdate:
  //   Pattern A (editRoute non-null) — navigate to the module's edit form.
  //   Pattern B (editRoute null)     — enter inline edit mode for proposed changes.
  // Both patterns require stepAllowEdit and the correct module edit permission.
  //
  // IMPORTANT: profile_* modules ALWAYS use Pattern B (inline edit), even if
  // edit_route is somehow non-null (mig 333 clears them, this is belt-and-suspenders).
  // Reason: profile edit_routes are ESS self-service paths (/profile/personal etc.)
  // that show the APPROVER's own profile, not the employee under review.
  const PROFILE_INLINE_MODULES = new Set([
    'profile_personal', 'profile_contact', 'profile_employment',
    'profile_address',  'profile_passport', 'profile_identification',
    'profile_emergency_contact', 'profile_bank', 'profile_dependents',
    'profile_education',
  ]);
  const returnTo = fullViewRoute ?? `/workflow/inbox?task=${task.taskId}`;
  const handlePanelUpdate = task.stepAllowEdit && can(editPermCode)
    ? // Hire module: editing happens in WorkflowReview's inline mode — navigate there directly
      (task.moduleCode === 'employee_hire' && fullViewRoute)
      ? () => navigate(`${fullViewRoute}?edit=1`)
      : // Profile modules: always inline — never navigate to the ESS self-service route
        PROFILE_INLINE_MODULES.has(task.moduleCode) || !editRoute
        ? enterApproverEditMode
        : () => {
            const base = editRoute.replace(':id', task.recordId);
            const sep  = base.includes('?') ? '&' : '?';
            navigate(`${base}${sep}returnTo=${encodeURIComponent(returnTo)}`);
          }
    : undefined;

  function enterApproverEditMode() {
    const initial: Record<string, string> = {};
    for (const [k, v] of Object.entries(task.metadata ?? {})) {
      if (k !== 'name') initial[k] = v != null ? String(v) : '';
    }
    setEditValues(initial);
    setEditMode(true);
    setEditError(null);
  }

  async function handleApproverSave() {
    if (!wf.instance?.id) return;
    // profile_dependents: DependentsEnrichment owns the save; just exit edit mode.
    if (task.moduleCode === 'profile_dependents') { setEditMode(false); return; }

    // ── Date validation before saving ──────────────────────────────────────
    const todayISO = new Date().toISOString().slice(0, 10);

    if (task.moduleCode === 'profile_employment') {
      const endDate  = editValues['end_date'];
      // hire_date comes from currentData (the live employee record)
      const hireDate = String(task.currentData?.['hire_date'] ?? '');
      if (endDate && endDate !== '9999-12-31' && hireDate && endDate < hireDate) {
        setEditError('End Date cannot be before Hire Date.');
        return;
      }
    }

    if (task.moduleCode === 'profile_passport') {
      const expiryDate = editValues['expiry_date'];
      if (expiryDate && expiryDate <= todayISO) {
        setEditError('Expiry Date must be a future date.');
        return;
      }
    }

    if (task.moduleCode === 'profile_identification') {
      const expiryDate = editValues['expiry_date'] ?? editValues['expiry'];
      if (expiryDate && expiryDate <= todayISO) {
        setEditError('Expiry Date must be a future date.');
        return;
      }
      // Validate ID number format if the approver edited it
      const idNum     = editValues['id_number'];
      const countryId = editValues['country'] ?? (task.proposedData?.['country'] as string);
      const idTypeId  = editValues['id_type']  ?? (task.proposedData?.['id_type']  as string);
      if (idNum && countryId && idTypeId) {
        const countryName = usePicklistValues ? '' : ''; // resolved below
        // Resolve picklist labels from task metadata — same approach as the field renders
        const _allPl  = (task.metadata?.picklists ?? {}) as Record<string, { id: number; value: string }[]>;
        const _idPl   = (_allPl['id_type_by_country'] ?? []) as { id: number; value: string }[];
        const _cPl    = (_allPl['id_countries']        ?? []) as { id: number; value: string }[];
        const _cName  = _cPl.find(p => String(p.id) === String(countryId))?.value  ?? '';
        const _tName  = _idPl.find(p => String(p.id) === String(idTypeId))?.value  ?? '';
        const _fmtErr = validateIdentityNumber(_cName, _tName, String(idNum).trim());
        if (_fmtErr) { setEditError(_fmtErr); return; }
      }
    }

    // ── Termination: HR edits last_working_date mid-flight ──────────────────
    // Calls update_termination_lwd — does NOT go through wf_approver_update_pending_changes
    // (termination is an event table, not a set-snapshot module).
    if (task.moduleCode === 'termination') {
      const lwd = editValues['last_working_date'];
      if (!lwd) { setEditError('Last Working Date is required.'); return; }

      const waiverReason = editValues['notice_period_waiver_reason'] ?? '';
      // Determine if waiver is needed (LWD < notice_expiry_date, if known from metadata)
      const noticeExpiry = String(task.metadata?.['notice_expiry_date'] ?? '');
      if (noticeExpiry && lwd < noticeExpiry) {
        if (!waiverReason.trim()) {
          setEditError('Notice Waiver Justification is required when a notice shortfall exists.');
          return;
        }
        if (waiverReason.trim().length < 20) {
          setEditError('Notice Waiver Justification must be at least 20 characters.');
          return;
        }
      }

      setEditSaving(true);
      setEditError(null);
      try {
        const { data: result, error: err } = await supabase.rpc('update_termination_lwd', {
          p_termination_id:              task.recordId,
          p_last_working_date:           lwd,
          p_notice_period_waiver_reason: waiverReason.trim() || null,
        });
        if (err) throw new Error(err.message);
        if (result && !result.ok) throw new Error(result.error ?? 'Update failed.');
        setEditMode(false);
        onRefreshTasks();
      } catch (e) {
        setEditError((e as Error).message);
      } finally {
        setEditSaving(false);
      }
      return;
    }

    setEditSaving(true);
    setEditError(null);
    try {
      // Strip UI-only sentinel keys (_date_error_*) before sending to DB
      const cleanValues = Object.fromEntries(
        Object.entries(editValues).filter(([k]) => !k.startsWith('_date_error_'))
      );
      const { error: err } = await supabase.rpc('wf_approver_update_pending_changes', {
        p_instance_id:   wf.instance.id,
        p_proposed_data: cleanValues,
      });
      if (err) throw new Error(err.message);
      setEditMode(false);
      // Refresh task list so the panel shows the new proposed_data (via mig 198
      // COALESCE), but stay on the current task — do NOT call onAfterAction()
      // which would advance to the next task.
      onRefreshTasks();
    } catch (e) {
      setEditError((e as Error).message);
    } finally {
      setEditSaving(false);
    }
  }

  return (
    <div className="wfi-detail-wrapper">
      <div className="wfi-panel-scroll">
        <div className="wfi-detail-header">
          <div className="wfi-detail-header-row">
            <div className="wfi-detail-title-group">
              <h2 className="wfi-detail-title">
                {(task.moduleCode === 'termination' || task.moduleCode === 'termination_reversal')
                  ? (() => {
                      const lbl = task.moduleCode === 'termination_reversal' ? 'Termination Reversal' : 'Termination';
                      return terminationSubjectName ? `${lbl} — ${terminationSubjectName}` : lbl;
                    })()
                  : getPortletName(task.moduleCode, task.metadata, task.templateName, task.submittedByName, task.subjectEmployeeName)
                }
              </h2>
              <div className="wfi-detail-subtitle">
                Submitted by <strong style={{ color: '#374151' }}>{task.submittedByName ?? '—'}</strong>
                {' · '}{fmtDate(task.taskCreatedAt)}
              </div>
            </div>
            {fullViewRoute && (
              <button onClick={() => navigate(fullViewRoute)} className="wfi-full-view-btn">
                Open Full View <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 10 }} />
              </button>
            )}
          </div>
          <div className="wfi-badge-row">
            {resolvedAmount !== undefined && (
              <span className="wfi-amount-badge">
                {resolvedCurrency ? `${resolvedCurrency} ` : ''}{resolvedAmount.toLocaleString('en-IN', { minimumFractionDigits: 2 })}
              </span>
            )}
            <WorkflowStatusBadge status={wf.instance?.status ?? 'pending'} size="sm" />
            <span style={{ fontSize: 11, fontWeight: 600, color: SLA[task.slaStatus].color, background: SLA[task.slaStatus].bg, border: `1px solid ${SLA[task.slaStatus].border}`, borderRadius: 4, padding: '2px 8px' }}>
              {SLA[task.slaStatus].label}
            </span>
          </div>
        </div>
        <div className="wfi-separator" />
        <div className="wfi-meta-row" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap' }}>
            <MetaItem label="Step"     value={`${task.stepOrder} — ${task.stepName}`} />
            <MetaItem label="Workflow" value={task.templateName} />
            <MetaItem label="Module"   value={MODULE_LABELS[task.moduleCode] ?? task.moduleCode.replace(/_/g, ' ')} />
            {!task.moduleCode.startsWith('profile_') && extraMeta.map(([k, v]) => (
              <MetaItem key={k} label={k.replace(/_/g, ' ')} value={String(v)} />
            ))}
          </div>
          <button
            onClick={() => setParticipantsOpen(true)}
            style={{
              display: 'flex', alignItems: 'center', gap: 5,
              background: '#F5F3FF', border: '1px solid #DDD6FE',
              borderRadius: 6, padding: '4px 10px',
              fontSize: 12, fontWeight: 500, color: '#7C3AED',
              cursor: 'pointer', whiteSpace: 'nowrap', flexShrink: 0,
            }}
          >
            <i className="fa-solid fa-users" style={{ fontSize: 11 }} />
            View participants
          </button>
        </div>
        {(() => {
          const HUMAN_ACTIONS = new Set(['approved', 'rejected', 'sent_back', 'resubmitted', 'commented']);
          const notedEvents = wf.history.filter(h => h.notes && h.notes.trim() && HUMAN_ACTIONS.has(h.action));
          const recentNote  = notedEvents.slice(-1);
          if (!recentNote.length) return null;
          return (
            <div style={{ marginBottom: 16 }}>
              {recentNote.map(event => (
                <div key={event.id} className="wfi-note-callout">
                  <i className="fas fa-comment-dots wfi-note-callout-icon" />
                  <div className="wfi-note-callout-content">
                    <div className="wfi-note-callout-meta">
                      {event.actorName ?? 'Approver'}{event.stepOrder ? ` · Step ${event.stepOrder}` : ''}
                      <span className="wfi-note-callout-time">
                        {new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }).format(new Date(event.createdAt))}
                      </span>
                    </div>
                    <div className="wfi-note-callout-text">{event.notes}</div>
                  </div>
                </div>
              ))}
            </div>
          );
        })()}
        {task.moduleCode === 'expense_reports' && (
          <ExpenseEnrichment
            recordId={task.recordId}
            onOpenFull={() => fullViewRoute && navigate(fullViewRoute)}
            onAmountResolved={(amount, currencyCode) => { setResolvedAmount(amount); setResolvedCurrency(currencyCode); }}
          />
        )}
        {task.moduleCode.startsWith('profile_') && (
          <>
            <ProfileEnrichment
              moduleCode={task.moduleCode}
              metadata={task.metadata ?? {}}
              currentData={task.currentData}
              editMode={editMode}
              editValues={editValues}
              onEditChange={(k, v) => setEditValues(prev => ({ ...prev, [k]: v }))}
              instanceId={wf.instance?.id}
              onExitEdit={() => { setEditMode(false); onRefreshTasks(); }}
            />
          </>
        )}
        {task.moduleCode === 'employee_hire' && (
          <HireEnrichment recordId={task.recordId} />
        )}
        {(task.moduleCode === 'termination' || task.moduleCode === 'termination_reversal') && (
          <TerminationEnrichment
            recordId={task.recordId}
            metadata={task.metadata ?? {}}
            editMode={editMode}
            editValues={editValues}
            onEditChange={(k, v) => setEditValues(prev => ({ ...prev, [k]: v }))}
          />
        )}
        {wf.instance && (
          <div style={{ marginBottom: 8 }}>
            <SectionTitle icon="fa-clock-rotate-left" label="Approval History" />
            <WorkflowTimeline history={wf.history} tasks={wf.tasks} currentStep={wf.instance.currentStep} status={wf.instance.status} />
          </div>
        )}
      </div>

      {/* ── Pattern B edit save bar — replaces action bar while editing ───── */}
      {editMode ? (
        <div className="wfi-edit-mode-bar">
          {editError && (
            <p className="wfi-action-error">
              <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{editError}
            </p>
          )}
          <div className="wfi-edit-btn-row">
            <button
              onClick={handleApproverSave}
              disabled={editSaving}
              className="wfi-edit-submit-btn"
              style={{ background: editSaving ? '#9CA3AF' : '#2F77B5', cursor: editSaving ? 'not-allowed' : 'pointer' }}
            >
              {editSaving
                ? <><i className="fas fa-spinner fa-spin" /> Saving…</>
                : <><i className="fas fa-floppy-disk" /> Save Changes</>}
            </button>
            <button
              onClick={() => { setEditMode(false); setEditError(null); }}
              disabled={editSaving}
              className="wfi-edit-cancel-btn"
            >
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <PanelActionBar
          task={task}
          onApprove={async (taskId, notes) => {
            await onApprove(taskId, notes);
            // Post-approval hook for termination module.
            // Both primary terminations AND reversals share module_code='termination'.
            // Distinguish by metadata: reversal tasks have reversal_reason; primary do not.
            // Each Edge Function guards internally (wrong record type → 400/404 harmlessly).
            if (task.moduleCode === 'termination' || task.moduleCode === 'termination_reversal') {
              if (task.moduleCode === 'termination_reversal') {
                // Reversal approved → undo employment slices, reactivate employee
                supabase.functions
                  .invoke('apply-termination-reversal', { body: { reversal_id: task.recordId } })
                  .catch(err => console.error('apply-termination-reversal:', err));
              } else {
                // Primary termination approved → close slice, insert Inactive, deactivate
                // Guards: skips if not APPROVED or already scheduled_executed
                supabase.functions
                  .invoke('apply-termination-approval', { body: { termination_id: task.recordId } })
                  .catch(err => console.error('apply-termination-approval:', err));
              }
            }
          }}
          onReject={onReject}
          onReassign={onReassign}
          onReturnToInitiator={onReturnToInitiator}
          onReturnToPreviousStep={onReturnToPreviousStep}
          onAfterAction={onAfterAction}
          onUpdate={handlePanelUpdate}
        />
      )}

      {/* ── Workflow Participants Modal ─────────────────────────────────────── */}
      <WorkflowParticipantsModal
        open={participantsOpen}
        onClose={() => setParticipantsOpen(false)}
        instanceId={task.instanceId}
        title={(() => {
          if (task.moduleCode === 'termination' || task.moduleCode === 'termination_reversal') {
            const label   = task.moduleCode === 'termination_reversal' ? 'Termination Reversal' : 'Termination';
            const empName = (task.metadata?.employee_name as string | undefined) ?? task.submittedByName ?? 'Submission';
            return `${empName} — ${label}`;
          }
          return `${task.submittedByName ?? 'Submission'} — ${MODULE_LABELS[task.moduleCode] ?? task.moduleCode.replace(/_/g, ' ')}`;
        })()}
        submittedByName={task.submittedByName}
      />
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sent Back tab — Detail Panel (same layout, different action bar)
// ─────────────────────────────────────────────────────────────────────────────

function SentBackDetailPanel({ item, onUpdate, onRespond, onWithdraw, onAfterAction }: {
  item:          SentBackItem;
  onUpdate:      (instanceId: string) => Promise<void>;
  onRespond:     (instanceId: string, response?: string) => Promise<void>;
  onWithdraw:    (instanceId: string, reason?: string)   => Promise<void>;
  onAfterAction: () => void;
}) {
  const navigate = useNavigate();
  const wf = useWorkflowInstance(item.moduleCode, item.recordId);
  const fullViewRoute =
    item.moduleCode === 'expense_reports'
      ? `/workflow/review/${item.recordId}`
      : item.moduleCode === 'employee_hire'
        ? `/workflow/review/${item.recordId}?role=initiator&module=employee_hire`
        : null;

  // ── Inline edit state (profile modules only) ──────────────────────────────
  const [editMode,     setEditMode]     = useState(false);
  const [editValues,   setEditValues]   = useState<Record<string, string>>({});
  const [editResponse, setEditResponse] = useState('');
  const [resubmitting, setResubmitting] = useState(false);
  const [editError,    setEditError]    = useState<string | null>(null);

  // Reset edit state whenever the selected item changes
  useEffect(() => {
    setEditMode(false);
    setEditValues({});
    setEditResponse('');
    setEditError(null);
  }, [item.instanceId]);

  function enterEditMode() {
    // Initialise edit values from the current proposed data (excluding display-only keys)
    const initial: Record<string, string> = {};
    for (const [k, v] of Object.entries(item.metadata ?? {})) {
      if (k !== 'name') initial[k] = v != null ? String(v) : '';
    }
    setEditValues(initial);
    setEditMode(true);
    setEditError(null);
  }

  async function handleInlineResubmit() {
    setResubmitting(true);
    setEditError(null);
    try {
      const { error: err } = await supabase.rpc('wf_resubmit', {
        p_instance_id:   item.instanceId,
        p_response:      editResponse.trim() || null,
        p_proposed_data: editValues,
      });
      if (err) throw new Error(err.message);
      setEditMode(false);
      onAfterAction(); // move to next item + refresh list
    } catch (e) {
      setEditError((e as Error).message);
    } finally {
      setResubmitting(false);
    }
  }

  return (
    <div className="wfi-detail-wrapper">
      <div className="wfi-panel-scroll">

        {/* Header */}
        <div className="wfi-detail-header">
          <div className="wfi-detail-header-row">
            <div className="wfi-detail-title-group">
              <h2 className="wfi-detail-title">
                {getPortletName(item.moduleCode, item.metadata, item.templateName, item.submittedByName)}
              </h2>
              <div className="wfi-detail-subtitle">Submitted {fmtDate(item.submittedAt)}</div>
            </div>
            {fullViewRoute && (
              <button onClick={() => navigate(fullViewRoute)} className="wfi-full-view-btn">
                Open Full View <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 10 }} />
              </button>
            )}
          </div>
          <div className="wfi-badge-row">
            {item.metadata?.total_amount !== undefined && (
              <span className="wfi-amount-badge">
                {item.metadata.currency_code as string ?? ''} {Number(item.metadata.total_amount).toLocaleString('en-IN', { minimumFractionDigits: 2 })}
              </span>
            )}
            <WorkflowStatusBadge status={item.status as any} size="sm" />
          </div>
        </div>

        <div className="wfi-separator" />

        {/* Approver's message / rejection reason — prominent callout */}
        <div className="wfi-clarification-callout" style={item.status === 'rejected' ? {
          background: '#FEF2F2', borderLeft: '3px solid #DC2626', borderColor: '#FECACA',
        } : {}}>
          <div className="wfi-clarification-callout-header" style={item.status === 'rejected' ? { color: '#991B1B' } : {}}>
            <i className={`fas ${item.status === 'rejected' ? 'fa-circle-xmark' : 'fa-comment-dots'}`}
               style={item.status === 'rejected' ? { color: '#DC2626' } : {}} />
            {item.status === 'rejected'
              ? `Rejection reason${item.clarificationFrom ? ` from ${item.clarificationFrom}` : ''}`
              : `Message from ${item.clarificationFrom ?? 'Approver'}`}
            {item.clarificationAt && (
              <span className="wfi-clarification-callout-time">
                · {relativeTime(item.clarificationAt)}
              </span>
            )}
          </div>
          <div className="wfi-clarification-callout-body" style={item.status === 'rejected' ? { color: '#7F1D1D' } : {}}>
            {item.clarificationMessage || 'No reason provided.'}
          </div>
        </div>

        {/* Summary row */}
        <div className="wfi-meta-row">
          <MetaItem label="Workflow" value={item.templateName} />
          <MetaItem label="Module"   value={MODULE_LABELS[item.moduleCode] ?? item.moduleCode.replace(/_/g, ' ')} />
          <MetaItem label="Submitted" value={fmtDate(item.submittedAt)} />
        </div>

        {/* Module enrichment — same components as approver view */}
        {item.moduleCode === 'expense_reports' && (
          <ExpenseEnrichment
            recordId={item.recordId}
            onOpenFull={() => fullViewRoute && navigate(fullViewRoute)}
          />
        )}
        {item.moduleCode === 'employee_hire' && (
          <HireEnrichment recordId={item.recordId} />
        )}
        {(item.moduleCode === 'termination' || item.moduleCode === 'termination_reversal') && (
          <TerminationEnrichment recordId={item.recordId} metadata={item.metadata ?? {}} />
        )}
        {item.moduleCode.startsWith('profile_') && (
          <ProfileEnrichment
            moduleCode={item.moduleCode}
            metadata={item.metadata ?? {}}
            currentData={null}
            editMode={editMode}
            editValues={editValues}
            onEditChange={(k, v) => setEditValues(prev => ({ ...prev, [k]: v }))}
          />
        )}

        {/* Approval history */}
        {wf.instance && (
          <div style={{ marginBottom: 8 }}>
            <SectionTitle icon="fa-clock-rotate-left" label="Approval History" />
            <WorkflowTimeline
              history={wf.history}
              tasks={wf.tasks}
              currentStep={wf.instance.currentStep}
              status={wf.instance.status}
            />
          </div>
        )}
      </div>

      {/* ── Action bar — inline edit bar replaces the normal bar when editing ── */}
      {editMode ? (
        <div className="wfi-edit-mode-bar">
          <textarea
            value={editResponse}
            onChange={e => { setEditResponse(e.target.value); setEditError(null); }}
            placeholder="Add a note to the approver (optional)…"
            rows={2}
            className="wfi-edit-mode-textarea"
          />
          {editError && (
            <p className="wfi-action-error">
              <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{editError}
            </p>
          )}
          <div className="wfi-edit-btn-row">
            <button
              onClick={handleInlineResubmit}
              disabled={resubmitting}
              className="wfi-edit-submit-btn"
              style={{ background: resubmitting ? '#9CA3AF' : '#2F77B5', cursor: resubmitting ? 'not-allowed' : 'pointer' }}
            >
              {resubmitting
                ? <><i className="fas fa-spinner fa-spin" /> Submitting…</>
                : <><i className="fas fa-paper-plane" /> Update & Resubmit</>}
            </button>
            <button
              onClick={() => { setEditMode(false); setEditError(null); }}
              disabled={resubmitting}
              className="wfi-edit-cancel-btn"
            >
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <SentBackActionBar
          item={item}
          onUpdate={onUpdate}
          onEnterEditMode={
            item.status === 'rejected'
              ? undefined  // rejected items are read-only — no editing
              : item.moduleCode.startsWith('profile_')
                ? enterEditMode
                : item.moduleCode === 'employee_hire'
                  ? () => navigate(`/workflow/review/${item.recordId}?role=initiator&module=employee_hire`)
                  : undefined
          }
          onRespond={onRespond}
          onWithdraw={onWithdraw}
          onAfterAction={onAfterAction}
        />
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Screen
// ─────────────────────────────────────────────────────────────────────────────

export default function ApproverInbox() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const activeTab = searchParams.get('tab') === 'sent_back' ? 'sent_back' : 'approve';

  function switchTab(tab: 'approve' | 'sent_back') {
    setSearchParams(tab === 'sent_back' ? { tab: 'sent_back' } : {}, { replace: true });
  }

  // ── To Approve tab state ───────────────────────────────────────────────────
  const {
    tasks, loading: approveLoading, error: approveError, pendingCount, refresh: refreshApprove,
    approve, reject, reassign, returnToInitiator, returnToPreviousStep,
  } = useWorkflowTasks();

  // Seed selection from ?task= param so "Back to Inbox" from full-view reopens the same item
  const [selectedTaskId,      setSelectedTaskId]      = useState<string | null>(searchParams.get('task'));
  const [filter,              setFilter]              = useState<'all' | SlaStatus>('all');
  const [actionError,         setActionError]         = useState<string | null>(null);
  const [alreadyHandledOpen,  setAlreadyHandledOpen]  = useState(false);

  const filtered     = filter === 'all' ? tasks : tasks.filter(t => t.slaStatus === filter);
  const selectedTask = filtered.find(t => t.taskId === selectedTaskId) ?? null;

  const handleFilterChange = (f: 'all' | SlaStatus) => {
    setFilter(f);
    const newFiltered = f === 'all' ? tasks : tasks.filter(t => t.slaStatus === f);
    if (selectedTaskId && !newFiltered.find(t => t.taskId === selectedTaskId)) {
      setSelectedTaskId(newFiltered[0]?.taskId ?? null);
    }
  };

  useEffect(() => {
    if (!selectedTaskId && filtered.length > 0) setSelectedTaskId(filtered[0].taskId);
  }, [filtered.length]);

  useEffect(() => {
    // Guard: don't clear a URL-seeded selection while tasks are still loading (filtered is empty)
    if (selectedTaskId && filtered.length > 0 && !filtered.find(t => t.taskId === selectedTaskId)) {
      setSelectedTaskId(filtered[0]?.taskId ?? null);
    }
  }, [filtered]);

  const handleAfterAction = useCallback(() => {
    if (!selectedTaskId) return;
    const next = getNextTask(filtered, selectedTaskId);
    setSelectedTaskId(next?.taskId ?? null);
    setActionError(null);
  }, [selectedTaskId, filtered]);

  async function handleApprove(taskId: string, notes?: string) {
    try {
      await approve(taskId, notes);
    } catch (e) {
      const msg = (e as Error).message;
      if (isAlreadyHandledError(msg)) {
        // Another fan-out member already actioned this step.
        // Show info modal; don't re-throw so run() calls onAfterAction()
        // which clears the selection, then refresh to drop it from the list.
        setAlreadyHandledOpen(true);
        refreshApprove();
        return;
      }
      setActionError(msg);
      throw e;
    }
  }
  async function handleReject(taskId: string, reason: string) {
    try {
      await reject(taskId, reason);
    } catch (e) {
      const msg = (e as Error).message;
      if (isAlreadyHandledError(msg)) {
        setAlreadyHandledOpen(true);
        refreshApprove();
        return;
      }
      setActionError(msg);
      throw e;
    }
  }
  async function handleReassign(taskId: string, profileId: string, reason?: string) {
    try { await reassign(taskId, profileId, reason); } catch (e) { setActionError((e as Error).message); throw e; }
  }
  async function handleReturnToInitiator(taskId: string, message: string) {
    try { await returnToInitiator(taskId, message); } catch (e) { setActionError((e as Error).message); throw e; }
  }
  async function handleReturnToPreviousStep(taskId: string, reason?: string) {
    try { await returnToPreviousStep(taskId, reason); } catch (e) { setActionError((e as Error).message); throw e; }
  }

  const kpi = {
    total:   tasks.length,
    overdue: tasks.filter(t => t.slaStatus === 'overdue').length,
    dueSoon: tasks.filter(t => t.slaStatus === 'due_soon').length,
    onTrack: tasks.filter(t => t.slaStatus === 'on_track').length,
  };

  // ── Sent Back tab state ────────────────────────────────────────────────────
  const {
    items: sentItems, loading: sentLoading, error: sentError,
    sentBackCount, refresh: refreshSentBack, update, respond, withdraw,
  } = useMySentBackItems();

  const [selectedInstanceId, setSelectedInstanceId] = useState<string | null>(null);
  const selectedItem = sentItems.find(i => i.instanceId === selectedInstanceId) ?? null;

  useEffect(() => {
    if (!selectedInstanceId && sentItems.length > 0) setSelectedInstanceId(sentItems[0].instanceId);
  }, [sentItems.length]);

  useEffect(() => {
    if (selectedInstanceId && !sentItems.find(i => i.instanceId === selectedInstanceId)) {
      setSelectedInstanceId(sentItems[0]?.instanceId ?? null);
    }
  }, [sentItems]);

  const handleAfterSentBackAction = useCallback(() => {
    if (!selectedInstanceId) return;
    const next = getNextItem(sentItems, selectedInstanceId);
    setSelectedInstanceId(next?.instanceId ?? null);
  }, [selectedInstanceId, sentItems]);

  async function handleUpdate(instanceId: string) {
    // Profile modules now use inline edit inside SentBackDetailPanel — the
    // Update button calls onEnterEditMode directly without going through here.
    // This handler is only reached for expense_reports.
    const item = sentItems.find(i => i.instanceId === instanceId);
    if (!item || item.moduleCode !== 'expense_reports') return;
    const { moduleCode, recordId } = await update(instanceId);
    navigate(`/expense/report/${recordId}?resume_instance=${instanceId}`);
  }
  async function handleRespond(instanceId: string, response?: string) {
    try { await respond(instanceId, response); }
    catch (e) { setActionError((e as Error).message); throw e; }
  }
  async function handleWithdraw(instanceId: string, reason?: string) {
    try { await withdraw(instanceId, reason); }
    catch (e) { setActionError((e as Error).message); throw e; }
  }

  // ── Unified refresh ────────────────────────────────────────────────────────
  function handleRefresh() {
    if (activeTab === 'approve') refreshApprove();
    else refreshSentBack();
  }

  const loading = activeTab === 'approve' ? approveLoading : sentLoading;

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <div className="wfi-root">

      {/* ── Header ───────────────────────────────────────────────────────── */}
      <div className="wfi-header">
        <div>
          <h1 className="wfi-header-title">Workflow Inbox</h1>
          <p className="wfi-header-subtitle">
            {loading ? 'Loading…'
              : activeTab === 'approve'
                ? pendingCount === 0 ? 'All caught up' : `${pendingCount} task${pendingCount === 1 ? '' : 's'} pending`
                : sentBackCount === 0 ? 'No items need your attention' : `${sentBackCount} item${sentBackCount === 1 ? '' : 's'} need${sentBackCount === 1 ? 's' : ''} your attention`
            }
          </p>
        </div>
        <button onClick={handleRefresh} className="wfi-refresh-btn">
          <i className="fas fa-arrows-rotate" style={{ fontSize: 11 }} /> Refresh
        </button>
      </div>

      {/* ── Tab Bar ──────────────────────────────────────────────────────── */}
      <div className="wfi-tab-bar">
        {(['approve', 'sent_back'] as const).map(tab => {
          const isActive = activeTab === tab;
          const label    = tab === 'approve' ? 'To Approve' : 'Sent Back';
          const count    = tab === 'approve' ? pendingCount : sentBackCount;
          const badgeBg  = tab === 'approve' ? '#2F77B5' : '#B45309';
          return (
            <button
              key={tab}
              onClick={() => switchTab(tab)}
              style={{
                padding: '10px 20px', border: 'none', background: 'none', cursor: 'pointer',
                fontWeight: isActive ? 700 : 500, fontSize: 13,
                color: isActive ? (tab === 'approve' ? '#2F77B5' : '#B45309') : '#6B7280',
                borderBottom: isActive ? `2px solid ${tab === 'approve' ? '#2F77B5' : '#B45309'}` : '2px solid transparent',
                marginBottom: -1,
                display: 'flex', alignItems: 'center', gap: 8,
                transition: 'all 0.15s',
              }}
            >
              {label}
              {count > 0 && (
                <span style={{
                  fontSize: 11, fontWeight: 700, color: '#fff',
                  background: badgeBg, borderRadius: 10,
                  padding: '1px 7px', lineHeight: '16px',
                }}>
                  {count}
                </span>
              )}
            </button>
          );
        })}
      </div>

      {/* ── To Approve tab ───────────────────────────────────────────────── */}
      {activeTab === 'approve' && (
        <>
          {/* KPI Bar */}
          {!approveLoading && (
            <div className="wfi-kpi-bar">
              <KpiCard label="Pending"  value={kpi.total}   icon="fa-inbox"              color="#2F77B5" bg="#EFF6FF" border="#BFDBFE" active={filter==='all'}      onClick={() => handleFilterChange('all')} />
              <KpiCard label="Overdue"  value={kpi.overdue} icon="fa-circle-exclamation" color="#DC2626" bg="#FEF2F2" border="#FECACA" active={filter==='overdue'}  onClick={() => handleFilterChange('overdue')} />
              <KpiCard label="Due Soon" value={kpi.dueSoon} icon="fa-hourglass-half"     color="#D97706" bg="#FFFBEB" border="#FDE68A" active={filter==='due_soon'} onClick={() => handleFilterChange('due_soon')} />
              <KpiCard label="On Track" value={kpi.onTrack} icon="fa-circle-check"       color="#16A34A" bg="#F0FDF4" border="#BBF7D0" active={filter==='on_track'} onClick={() => handleFilterChange('on_track')} />
            </div>
          )}

          {/* Split pane */}
          <div className="wfi-split-pane">
            <div className="wfi-list-panel">
              {approveLoading && <div className="wfi-loading"><i className="fas fa-spinner fa-spin wfi-spinner-icon" />Loading tasks…</div>}
              {approveError && !approveLoading && <div className="wfi-error-inline"><i className="fas fa-triangle-exclamation" style={{ marginRight: 6 }} />{approveError}</div>}
              {!approveLoading && !approveError && filtered.length === 0 && (
                <div className="wfi-empty-state">
                  <div className="wfi-empty-icon-wrap">
                    <i className="fas fa-check-circle wfi-empty-check-icon" />
                  </div>
                  <div className="wfi-empty-title">All caught up</div>
                  <div className="wfi-empty-subtitle">No tasks in this category.</div>
                  {filter !== 'all' && (
                    <button onClick={() => handleFilterChange('all')} className="wfi-filter-reset-btn">View all tasks</button>
                  )}
                </div>
              )}
              {!approveLoading && !approveError && filtered.map(task => (
                <TaskCard key={task.taskId} task={task} selected={task.taskId === selectedTaskId} onClick={() => setSelectedTaskId(task.taskId)} />
              ))}
            </div>
            <div className="wfi-detail-panel">
              {selectedTask ? (
                <DetailPanel task={selectedTask} onApprove={handleApprove} onReject={handleReject} onReassign={handleReassign} onReturnToInitiator={handleReturnToInitiator} onReturnToPreviousStep={handleReturnToPreviousStep} onAfterAction={handleAfterAction} onRefreshTasks={refreshApprove} />
              ) : (
                <div className="wfi-empty-right">
                  <div className="wfi-empty-icon-wrap">
                    <i className="fas fa-inbox" style={{ fontSize: 28, color: '#D1D5DB' }} />
                  </div>
                  <div>
                    <div className="wfi-empty-title">Select a task to review</div>
                    <div className="wfi-empty-subtitle">Click a task on the left to load the report details here.</div>
                  </div>
                </div>
              )}
            </div>
          </div>
        </>
      )}

      {/* ── Sent Back tab ─────────────────────────────────────────────────── */}
      {activeTab === 'sent_back' && (
        <div className="wfi-split-pane">
          {/* Left: clarification list */}
          <div className="wfi-list-panel">
            {sentLoading && <div className="wfi-loading"><i className="fas fa-spinner fa-spin wfi-spinner-icon" />Loading…</div>}
            {sentError && !sentLoading && <div className="wfi-error-inline"><i className="fas fa-triangle-exclamation" style={{ marginRight: 6 }} />{sentError}</div>}
            {!sentLoading && !sentError && sentItems.length === 0 && (
              <div className="wfi-empty-state">
                <div className="wfi-empty-icon-wrap">
                  <i className="fas fa-check-circle wfi-empty-check-icon" />
                </div>
                <div className="wfi-empty-title">Nothing needs your response</div>
                <div className="wfi-empty-subtitle">When an approver sends a request back for clarification, it will appear here.</div>
              </div>
            )}
            {!sentLoading && !sentError && sentItems.map(item => (
              <SentBackCard key={item.instanceId} item={item} selected={item.instanceId === selectedInstanceId} onClick={() => setSelectedInstanceId(item.instanceId)} />
            ))}
          </div>

          {/* Right: detail panel */}
          <div className="wfi-detail-panel">
            {selectedItem ? (
              <SentBackDetailPanel item={selectedItem} onUpdate={handleUpdate} onRespond={handleRespond} onWithdraw={handleWithdraw} onAfterAction={handleAfterSentBackAction} />
            ) : (
              <div className="wfi-empty-right">
                <div className="wfi-empty-icon-wrap wfi-empty-icon-wrap--amber">
                  <i className="fas fa-reply" style={{ fontSize: 28, color: '#FDE68A' }} />
                </div>
                <div>
                  <div className="wfi-empty-title">Select a request to respond</div>
                  <div className="wfi-empty-subtitle">Click an item on the left to see the full details and respond.</div>
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Already-handled modal — shown when fan-out peer already approved */}
      <AlreadyHandledModal
        open={alreadyHandledOpen}
        onClose={() => setAlreadyHandledOpen(false)}
      />

      {/* Global error toast */}
      {actionError && (
        <div className="wfi-error-toast">
          <i className="fas fa-triangle-exclamation" />
          {actionError}
          <button className="wfi-error-toast-close" onClick={() => setActionError(null)}>×</button>
        </div>
      )}
    </div>
  );
}
