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

import { useState, useEffect, useRef, useCallback } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { useWorkflowTasks }          from '../hooks/useWorkflowTasks';
import { useMySentBackItems }         from '../hooks/useMySentBackItems';
import { useApproverReportDetail }   from '../hooks/useApproverReportDetail';
import { useWorkflowInstance }       from '../hooks/useWorkflowInstance';
import { WorkflowTimeline }          from '../components/WorkflowTimeline';
import { WorkflowStatusBadge }       from '../components/WorkflowStatusBadge';
import type { WorkflowTask, SlaStatus } from '../hooks/useWorkflowTasks';
import type { SentBackItem }          from '../hooks/useMySentBackItems';
import { fmtAmount } from '../../utils/currency';
import { usePicklistValues } from '../../hooks/usePicklistValues';

// ── Helpers ───────────────────────────────────────────────────────────────────

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
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
      <i className={`fas ${icon}`} style={{ fontSize: 13, color: '#6B7280' }} />
      <span style={{ fontSize: 12, fontWeight: 700, color: '#374151', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
        {label}
      </span>
      {count !== undefined && (
        <span style={{ fontSize: 11, background: '#E5E7EB', color: '#6B7280', borderRadius: 10, padding: '1px 7px', fontWeight: 600 }}>
          {count}
        </span>
      )}
    </div>
  );
}

function MetaItem({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div style={{ fontSize: 10, fontWeight: 700, color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.05em' }}>{label}</div>
      <div style={{ fontSize: 13, color: '#111827', marginTop: 1, fontWeight: 500 }}>{value}</div>
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
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 8 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 13, color: '#18345B', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {task.metadata?.name as string ?? task.templateName}
          </div>
          <div style={{ fontSize: 11, color: '#6B7280', marginTop: 2 }}>
            {task.stepName} · {task.submittedByName ?? 'Unknown'}
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 4, flexShrink: 0 }}>
          <span style={{ width: 7, height: 7, borderRadius: '50%', background: sla.color, display: 'inline-block' }} />
          <span style={{ fontSize: 10, color: sla.color, fontWeight: 600 }}>{sla.label}</span>
        </div>
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 8 }}>
        {task.metadata?.total_amount !== undefined ? (
          <span style={{ fontSize: 12, fontWeight: 700, color: '#18345B', background: '#F0F4FF', borderRadius: 4, padding: '2px 7px' }}>
            {task.metadata.currency_code as string} {Number(task.metadata.total_amount).toLocaleString('en-IN', { minimumFractionDigits: 2 })}
          </span>
        ) : <span />}
        <span style={{ fontSize: 11, color: '#9CA3AF' }}>{relativeTime(task.taskCreatedAt)}</span>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sent Back Card — Sent Back tab left panel
// ─────────────────────────────────────────────────────────────────────────────

function SentBackCard({ item, selected, onClick }: { item: SentBackItem; selected: boolean; onClick: () => void }) {
  return (
    <div
      onClick={onClick}
      style={{
        padding: '14px 16px', cursor: 'pointer',
        borderBottom: '1px solid #F3F4F6',
        background: selected ? '#FFFBEB' : '#fff',
        borderLeft: `3px solid ${selected ? '#B45309' : 'transparent'}`,
        transition: 'background 0.12s',
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 8 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 13, color: '#18345B', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {item.metadata?.name as string ?? item.templateName}
          </div>
          <div style={{ fontSize: 11, color: '#6B7280', marginTop: 2 }}>
            {item.templateName}
            {item.clarificationFrom ? ` · Sent back by ${item.clarificationFrom}` : ''}
          </div>
        </div>
        <span style={{
          fontSize: 10, fontWeight: 700, color: '#B45309',
          background: '#FEF3C7', borderRadius: 4, padding: '2px 7px', flexShrink: 0,
        }}>
          Needs Response
        </span>
      </div>
      {item.clarificationMessage && (
        <div style={{
          marginTop: 8, fontSize: 12, color: '#92400E',
          background: '#FFFBEB', borderRadius: 6, padding: '6px 10px',
          border: '1px solid #FDE68A',
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        }}>
          <i className="fas fa-comment-dots" style={{ marginRight: 6, fontSize: 11 }} />
          {item.clarificationMessage}
        </div>
      )}
      <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 6 }}>
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
}

function PanelActionBar({
  task, onApprove, onReject, onReassign,
  onReturnToInitiator, onReturnToPreviousStep, onAfterAction,
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
    <div style={{ borderTop: '2px solid #E5E7EB', padding: '14px 20px', background: '#FAFAFA', flexShrink: 0 }}>
      {mode === 'reassign' && (
        <div style={{ marginBottom: 10 }}>
          <div style={{ fontSize: 11, fontWeight: 600, color: '#6B7280', textTransform: 'uppercase', marginBottom: 4 }}>Reassign to *</div>
          {target ? (
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '7px 10px', borderRadius: 6, border: '1px solid #DDD6FE', background: '#F5F3FF', marginBottom: 8 }}>
              <div>
                <div style={{ fontSize: 13, fontWeight: 600, color: '#5B21B6' }}>{target.name}</div>
                {target.title && <div style={{ fontSize: 11, color: '#7C3AED' }}>{target.title}</div>}
              </div>
              <button onClick={() => { setTarget(null); setQuery(''); }} style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#7C3AED', fontSize: 16 }}>×</button>
            </div>
          ) : (
            <div style={{ position: 'relative', marginBottom: 8 }}>
              <input
                value={query} onChange={e => setQuery(e.target.value)}
                placeholder="Search by name…" autoFocus
                style={{ width: '100%', padding: '7px 10px', border: '1px solid #D1D5DB', borderRadius: 6, fontSize: 13, outline: 'none', boxSizing: 'border-box' }}
              />
              {results.length > 0 && (
                <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 50, background: '#fff', border: '1px solid #D1D5DB', borderRadius: 6, boxShadow: '0 4px 12px rgba(0,0,0,0.1)', marginTop: 2, overflow: 'hidden' }}>
                  {results.map(p => (
                    <button key={p.id}
                      onClick={() => { setTarget(p); setQuery(''); setResults([]); }}
                      style={{ display: 'block', width: '100%', textAlign: 'left', padding: '8px 12px', border: 'none', background: 'none', cursor: 'pointer', borderBottom: '1px solid #F3F4F6' }}
                      onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')}
                      onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                    >
                      <div style={{ fontSize: 13, fontWeight: 600 }}>{p.name}</div>
                      {p.title && <div style={{ fontSize: 11, color: '#6B7280' }}>{p.title}</div>}
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
        style={{ width: '100%', padding: '8px 10px', border: `1px solid ${error ? '#FECACA' : '#D1D5DB'}`, borderRadius: 6, fontSize: 13, resize: 'none', outline: 'none', fontFamily: 'inherit', boxSizing: 'border-box', marginBottom: 4 }}
      />

      {error && (
        <p style={{ fontSize: 12, color: '#DC2626', margin: '0 0 8px' }}>
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{error}
        </p>
      )}

      {mode === 'idle' && (
        <div style={{ display: 'flex', height: 34, gap: 3 }}>
          <button onClick={handleApprove} disabled={loading} style={{ width: '22%', flexShrink: 0, borderRadius: 7, border: 'none', background: loading ? '#9CA3AF' : '#16A34A', color: '#fff', fontWeight: 700, fontSize: 12, cursor: loading ? 'not-allowed' : 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}>
            {loading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-check" />} Approve
          </button>
          <button onClick={handleReject} disabled={loading} style={{ width: '18%', flexShrink: 0, borderRadius: 7, border: 'none', background: loading ? '#9CA3AF' : '#DC2626', color: '#fff', fontWeight: 700, fontSize: 12, cursor: loading ? 'not-allowed' : 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}>
            <i className="fas fa-times" /> Reject
          </button>
          <div ref={moreRef} style={{ position: 'relative', width: '10%', flexShrink: 0 }}>
            <button
              onClick={() => setShowMore(v => !v)} disabled={loading}
              style={{ width: '100%', height: '100%', borderRadius: 7, border: '1.5px solid #D1D5DB', background: showMore ? '#F3F4F6' : '#FAFAFA', color: '#6B7280', fontWeight: 600, fontSize: 12, cursor: loading ? 'not-allowed' : 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 4, transition: 'background 0.12s, border-color 0.12s' }}
              onMouseEnter={e => { if (!loading) { e.currentTarget.style.background = '#F3F4F6'; e.currentTarget.style.borderColor = '#9CA3AF'; }}}
              onMouseLeave={e => { if (!showMore) { e.currentTarget.style.background = '#FAFAFA'; e.currentTarget.style.borderColor = '#D1D5DB'; }}}
            >
              More <i className="fas fa-chevron-down" style={{ fontSize: 9, transition: 'transform 0.15s', transform: showMore ? 'rotate(180deg)' : 'none' }} />
            </button>
            {showMore && (
              <div style={{ position: 'absolute', bottom: 'calc(100% + 6px)', right: 0, zIndex: 100, background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10, boxShadow: '0 8px 24px rgba(0,0,0,0.12)', minWidth: 260, overflow: 'hidden' }}>
                <button onClick={() => { setMode('reassign'); setShowMore(false); }} style={{ display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left', padding: '12px 14px', border: 'none', background: 'none', cursor: 'pointer', borderBottom: '1px solid #F3F4F6', borderLeft: '3px solid #7C3AED' }} onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')} onMouseLeave={e => (e.currentTarget.style.background = 'none')}>
                  <div style={{ width: 32, height: 32, borderRadius: 8, background: '#EDE9FE', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}><i className="fas fa-arrow-right-arrow-left" style={{ fontSize: 13, color: '#7C3AED' }} /></div>
                  <div><div style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>Reassign</div><div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 1 }}>Transfer to another approver</div></div>
                </button>
                <button onClick={() => { setMode('return_init'); setShowMore(false); }} style={{ display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left', padding: '12px 14px', border: 'none', background: 'none', cursor: 'pointer', borderBottom: task.stepOrder > 1 ? '1px solid #F3F4F6' : 'none', borderLeft: '3px solid #B45309' }} onMouseEnter={e => (e.currentTarget.style.background = '#FFFBEB')} onMouseLeave={e => (e.currentTarget.style.background = 'none')}>
                  <div style={{ width: 32, height: 32, borderRadius: 8, background: '#FEF3C7', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}><i className="fas fa-comment-dots" style={{ fontSize: 13, color: '#B45309' }} /></div>
                  <div><div style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>Send Back</div><div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 1 }}>Request clarification from submitter</div></div>
                </button>
                {task.stepOrder > 1 && (
                  <button onClick={() => { setMode('return_prev'); setShowMore(false); }} style={{ display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left', padding: '12px 14px', border: 'none', background: 'none', cursor: 'pointer', borderLeft: '3px solid #6B7280' }} onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')} onMouseLeave={e => (e.currentTarget.style.background = 'none')}>
                    <div style={{ width: 32, height: 32, borderRadius: 8, background: '#F3F4F6', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}><i className="fas fa-backward-step" style={{ fontSize: 13, color: '#6B7280' }} /></div>
                    <div><div style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>Send Back to Previous Step</div><div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 1 }}>Return to the previous approver</div></div>
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      )}

      {mode !== 'idle' && (
        <div style={{ display: 'flex', gap: 8 }}>
          <button
            onClick={mode === 'reassign' ? handleReassign : mode === 'return_init' ? handleReturnInit : handleReturnPrev}
            disabled={loading}
            style={{ padding: '7px 16px', borderRadius: 6, border: 'none', cursor: loading ? 'not-allowed' : 'pointer', background: mode === 'reassign' ? '#7C3AED' : mode === 'return_init' ? '#B45309' : '#374151', color: '#fff', fontWeight: 600, fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}
          >
            {loading && <i className="fas fa-spinner fa-spin" />}
            {mode === 'reassign'    && 'Confirm Reassign'}
            {mode === 'return_init' && 'Send Back'}
            {mode === 'return_prev' && 'Send Back to Previous Step'}
          </button>
          <button onClick={() => { setMode('idle'); setError(null); setTarget(null); setQuery(''); }} disabled={loading} style={{ padding: '7px 14px', borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', color: '#374151', fontWeight: 500, fontSize: 13, cursor: 'pointer' }}>
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

  // Expense reports navigate to the full edit form; profile modules use inline edit
  const supportsUpdate = item.moduleCode === 'expense_reports' || item.moduleCode.startsWith('profile_');
  const isProfileModule = item.moduleCode.startsWith('profile_');

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
    <div style={{ borderTop: '2px solid #E5E7EB', padding: '14px 20px', background: '#FAFAFA', flexShrink: 0 }}>
      <textarea
        value={response}
        onChange={e => { setResponse(e.target.value); setError(null); }}
        placeholder="Your response to the approver (optional — adds context when you resume)…"
        rows={2}
        style={{ width: '100%', padding: '8px 10px', border: `1px solid ${error ? '#FECACA' : '#D1D5DB'}`, borderRadius: 6, fontSize: 13, resize: 'none', outline: 'none', fontFamily: 'inherit', boxSizing: 'border-box', marginBottom: 8 }}
      />
      {error && (
        <p style={{ fontSize: 12, color: '#DC2626', margin: '0 0 8px' }}>
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{error}
        </p>
      )}
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>

        {/* Respond & Resume — comment only, no data change */}
        <button
          onClick={() => run(() => onRespond(item.instanceId, response.trim() || undefined))}
          disabled={loading || updateLoading}
          style={{ flex: 1, padding: '8px 16px', borderRadius: 6, border: 'none', cursor: (loading || updateLoading) ? 'not-allowed' : 'pointer', background: (loading || updateLoading) ? '#9CA3AF' : '#B45309', color: '#fff', fontWeight: 700, fontSize: 13, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}
        >
          {loading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-reply" />}
          Respond & Resume
        </button>

        {/* Update — profile modules open inline edit; expense_reports navigate to full form */}
        {supportsUpdate && (
          <button
            onClick={isProfileModule ? () => onEnterEditMode?.() : handleUpdate}
            disabled={loading || updateLoading}
            style={{ padding: '8px 14px', borderRadius: 6, border: '1.5px solid #2F77B5', background: '#EFF6FF', color: '#2F77B5', fontWeight: 600, fontSize: 13, cursor: (loading || updateLoading) ? 'not-allowed' : 'pointer', whiteSpace: 'nowrap', display: 'flex', alignItems: 'center', gap: 6 }}
          >
            {updateLoading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-pen-to-square" />}
            Update
          </button>
        )}

        {/* Withdraw */}
        {!confirmWithdraw ? (
          <button
            onClick={() => setConfirmWithdraw(true)} disabled={loading || updateLoading}
            style={{ padding: '8px 14px', borderRadius: 6, border: '1.5px solid #D1D5DB', background: '#fff', color: '#6B7280', fontWeight: 500, fontSize: 13, cursor: 'pointer', whiteSpace: 'nowrap' }}
          >
            Withdraw
          </button>
        ) : (
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0 }}>
            <span style={{ fontSize: 12, color: '#DC2626', whiteSpace: 'nowrap' }}>Cancel request?</span>
            <button onClick={() => run(() => onWithdraw(item.instanceId))} style={{ padding: '5px 10px', borderRadius: 5, border: 'none', background: '#DC2626', color: '#fff', fontWeight: 600, fontSize: 12, cursor: 'pointer' }}>Yes</button>
            <button onClick={() => setConfirmWithdraw(false)} style={{ padding: '5px 10px', borderRadius: 5, border: '1px solid #D1D5DB', background: '#fff', color: '#374151', fontSize: 12, cursor: 'pointer' }}>No</button>
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
    <div style={{ padding: '12px 0', color: '#9CA3AF', fontSize: 12, display: 'flex', alignItems: 'center', gap: 6 }}>
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
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 13px', borderRadius: 7, marginBottom: 14, background: '#FFFBEB', border: '1px solid #FDE68A' }}>
          <i className="fas fa-circle-info" style={{ color: '#D97706', fontSize: 13 }} />
          <span style={{ fontSize: 12, color: '#92400E' }}>
            {lineItems.length} items — use{' '}
            <button onClick={onOpenFull} style={{ background: 'none', border: 'none', padding: 0, color: '#2F77B5', fontWeight: 600, fontSize: 12, cursor: 'pointer', textDecoration: 'underline' }}>Full View</button>{' '}
            for easier review.
          </span>
        </div>
      )}
      {lineItems.length > 0 && (
        <div style={{ marginBottom: 18 }}>
          <SectionTitle icon="fa-list" label="Line Items" count={lineItems.length} />
          <div style={{ maxHeight: isLarge ? 260 : 'none', overflowY: isLarge ? 'auto' : 'visible', border: '1px solid #E5E7EB', borderRadius: 8, overflow: 'hidden' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr style={{ background: '#F9FAFB', borderBottom: '1px solid #E5E7EB' }}>
                  {['#', 'Category', 'Date', 'Amount', 'Converted', 'Note', 'Attachments'].map(h => (
                    <th key={h} style={{ padding: '7px 10px', textAlign: 'left', fontWeight: 600, color: '#6B7280', fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.04em', whiteSpace: 'nowrap' }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {lineItems.map((li, i) => (
                  <tr key={li.id} style={{ borderBottom: i < lineItems.length - 1 ? '1px solid #F3F4F6' : 'none' }}>
                    <td style={{ padding: '7px 10px', color: '#9CA3AF', fontWeight: 600 }}>{i + 1}</td>
                    <td style={{ padding: '7px 10px', color: '#374151', fontWeight: 500 }}>{li.categoryName || '—'}</td>
                    <td style={{ padding: '7px 10px', color: '#374151', whiteSpace: 'nowrap' }}>{fmtDate(li.date)}</td>
                    <td style={{ padding: '7px 10px', color: '#374151', whiteSpace: 'nowrap', fontWeight: 600 }}>
                      <span style={{ fontSize: 10, color: '#6B7280', marginRight: 2 }}>{li.currencyCode}</span>
                      {li.amount.toLocaleString('en-IN', { minimumFractionDigits: 2 })}
                    </td>
                    <td style={{ padding: '7px 10px', color: '#18345B', fontWeight: 700, whiteSpace: 'nowrap' }}>{fmtAmount(li.convertedAmount, detail.baseCurrencyCode)}</td>
                    <td style={{ padding: '7px 10px', color: '#6B7280', maxWidth: 110, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{li.note || '—'}</td>
                    <td style={{ padding: '7px 10px', whiteSpace: 'nowrap' }}>
                      {!li.attachments?.length ? <span style={{ color: '#D1D5DB' }}>—</span> :
                       li.attachments.length === 1 ? (
                        <a href={li.attachments[0].dataUrl} target="_blank" rel="noopener noreferrer" title={li.attachments[0].name} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: '#2563EB', textDecoration: 'none', fontSize: 12, fontWeight: 600 }}>
                          <i className="fas fa-paperclip" style={{ fontSize: 11 }} /> 1
                        </a>
                       ) : (
                        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: '#2563EB', fontSize: 12, fontWeight: 600 }}>
                          <i className="fas fa-paperclip" style={{ fontSize: 11 }} /> {li.attachments.length}
                        </span>
                       )}
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr style={{ background: '#F0F4FF', borderTop: '2px solid #BFDBFE' }}>
                  <td colSpan={4} style={{ padding: '7px 10px', fontWeight: 700, color: '#18345B', fontSize: 11 }}>Total</td>
                  <td style={{ padding: '7px 10px', fontWeight: 800, color: '#18345B', fontSize: 12 }}>{fmtAmount(detail.totalConverted, detail.baseCurrencyCode)}</td>
                  <td /><td />
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      )}
      {allAtts.length > 0 && (
        <div style={{ marginBottom: 18 }}>
          <SectionTitle icon="fa-paperclip" label="Attachments" count={allAtts.length} />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            {allAtts.map(att => (
              <a key={att.id} href={att.dataUrl} target="_blank" rel="noopener noreferrer"
                style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '7px 11px', borderRadius: 7, border: '1px solid #E5E7EB', background: '#fff', textDecoration: 'none', color: '#374151' }}
                onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                onMouseLeave={e => (e.currentTarget.style.background = '#fff')}
              >
                <i className={`fas ${attIcon(att.type)}`} style={{ fontSize: 15, color: att.type === 'application/pdf' ? '#DC2626' : '#2563EB', flexShrink: 0 }} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 12, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{att.name}</div>
                  <div style={{ fontSize: 11, color: '#9CA3AF' }}>{attFmtSize(att.size)} · {att.categoryName || 'Attachment'}</div>
                </div>
                <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 10, color: '#9CA3AF' }} />
              </a>
            ))}
          </div>
        </div>
      )}
    </>
  );
}

const MODULE_LABELS: Record<string, string> = {
  expense_reports:           'Expense Reports',
  time_off:                  'Time Off',
  profile_personal:          'Profile – Personal Info',
  profile_contact:           'Profile – Contact Details',
  profile_address:           'Profile – Address',
  profile_passport:          'Profile – Passport',
  profile_emergency_contact: 'Profile – Emergency Contact',
};

const PROFILE_PICKLIST_FIELDS: Record<string, Record<string, string>> = {
  profile_personal:          { nationality: 'NATIONALITY', marital_status: 'MARITAL_STATUS' },
  profile_passport:          { country: 'ID_COUNTRY' },
  profile_emergency_contact: { relationship: 'RELATIONSHIP_TYPE' },
};

const PROFILE_FIELD_LABELS: Record<string, string> = {
  nationality: 'Nationality', marital_status: 'Marital Status', gender: 'Gender',
  dob: 'Date of Birth', country_code: 'Country Code', mobile: 'Mobile',
  personal_email: 'Personal Email', line1: 'Address Line 1', line2: 'Address Line 2',
  landmark: 'Landmark', city: 'City', district: 'District', state: 'State',
  pin: 'PIN Code', country: 'Country', passport_number: 'Passport Number',
  issue_date: 'Issue Date', expiry_date: 'Expiry Date', name: 'Name',
  relationship: 'Relationship', phone: 'Phone', alt_phone: 'Alt Phone', email: 'Email',
};

// Fields that render as <input type="date"> in edit mode
const PROFILE_DATE_FIELDS = new Set(['dob', 'issue_date', 'expiry_date']);

// Gender options for the inline select (not a picklist in the DB — stored as plain text)
const GENDER_OPTIONS = ['Male', 'Female', 'Non-binary', 'Prefer not to say'];

function ProfileEnrichment({ moduleCode, metadata, currentData, editMode, editValues, onEditChange }: {
  moduleCode:    string;
  metadata:      Record<string, unknown>;
  currentData?:  Record<string, unknown> | null;
  // Inline edit mode — when true, fields render as inputs instead of static text
  editMode?:     boolean;
  editValues?:   Record<string, string>;
  onEditChange?: (key: string, value: string) => void;
}) {
  const { picklistValues } = usePicklistValues();
  const picklistMap = PROFILE_PICKLIST_FIELDS[moduleCode] ?? {};

  function resolveValue(key: string, raw: unknown): string {
    if (raw == null || raw === '') return '—';
    const picklistId = picklistMap[key];
    if (picklistId) {
      const found = picklistValues.find(v => v.picklistId === picklistId && v.id === raw);
      return found?.value ?? String(raw);
    }
    return String(raw);
  }

  const entries = Object.entries(metadata).filter(([k]) => k !== 'name');
  if (!entries.length) return null;

  const fieldInputStyle: React.CSSProperties = {
    width: '100%', padding: '5px 8px',
    border: '1px solid #7DD3FC', borderRadius: 5,
    fontSize: 12, outline: 'none', fontFamily: 'inherit',
    background: '#fff', boxSizing: 'border-box', color: '#0C4A6E',
  };

  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
        <SectionTitle icon="fa-pen-to-square" label={editMode ? 'Edit Proposed Changes' : 'Proposed Changes'} />
        {editMode && (
          <span style={{
            fontSize: 11, color: '#0369A1', background: '#E0F2FE',
            borderRadius: 4, padding: '2px 8px', fontWeight: 600,
          }}>
            <i className="fas fa-pencil" style={{ fontSize: 9, marginRight: 4 }} />
            Editing
          </span>
        )}
      </div>
      <div style={{
        background: '#F0F9FF',
        border: `1px solid ${editMode ? '#7DD3FC' : '#BAE6FD'}`,
        borderRadius: 8, padding: '12px 16px',
        display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
        gap: '12px 24px',
      }}>
        {entries.map(([k, v]) => {
          const proposedLabel = resolveValue(k, v);
          const hasOld        = currentData != null && currentData[k] !== v;
          const oldLabel      = hasOld ? resolveValue(k, currentData![k]) : null;
          const picklistId    = picklistMap[k];

          return (
            <div key={k}>
              <div style={{ fontSize: 10, fontWeight: 700, color: '#0369A1', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 4 }}>
                {PROFILE_FIELD_LABELS[k] ?? k.replace(/_/g, ' ')}
              </div>

              {editMode && onEditChange ? (
                // ── Edit mode: render the right input type ────────────────
                picklistId ? (
                  <select
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    style={fieldInputStyle}
                  >
                    <option value="">— Select —</option>
                    {picklistValues
                      .filter(pv => pv.picklistId === picklistId)
                      .map(pv => <option key={pv.id} value={pv.id}>{pv.value}</option>)}
                  </select>
                ) : PROFILE_DATE_FIELDS.has(k) ? (
                  <input
                    type="date"
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    style={fieldInputStyle}
                  />
                ) : k === 'gender' ? (
                  <select
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    style={fieldInputStyle}
                  >
                    <option value="">— Select —</option>
                    {GENDER_OPTIONS.map(g => <option key={g} value={g}>{g}</option>)}
                  </select>
                ) : (
                  <input
                    type="text"
                    value={editValues?.[k] ?? ''}
                    onChange={e => onEditChange(k, e.target.value)}
                    style={fieldInputStyle}
                  />
                )
              ) : (
                // ── Read mode: static display ─────────────────────────────
                <>
                  <div style={{ fontSize: 13, fontWeight: 500, color: '#0C4A6E' }}>{proposedLabel}</div>
                  {hasOld && oldLabel && (
                    <div style={{ fontSize: 12, color: '#9CA3AF', textDecoration: 'line-through', textDecorationColor: '#9CA3AF', marginTop: 2 }}>{oldLabel}</div>
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

const META_HEADER_KEYS = new Set(['name', 'total_amount', 'currency_code', 'status', 'dept_id', 'currency_id', 'employee_id', 'work_country']);

// ─────────────────────────────────────────────────────────────────────────────
// To Approve tab — Detail Panel
// ─────────────────────────────────────────────────────────────────────────────

interface ApproveActionBarFullProps extends ApproveActionBarProps {}

function DetailPanel({
  task, onApprove, onReject, onReassign, onReturnToInitiator, onReturnToPreviousStep, onAfterAction,
}: ApproveActionBarFullProps) {
  const navigate = useNavigate();
  const wf = useWorkflowInstance(task.moduleCode, task.recordId);
  const extraMeta = Object.entries(task.metadata ?? {}).filter(([k]) => !META_HEADER_KEYS.has(k));
  const fullViewRoute = task.moduleCode === 'expense_reports' ? `/workflow/review/${task.recordId}` : null;

  const [resolvedAmount,   setResolvedAmount]   = useState<number | undefined>(task.metadata?.total_amount as number | undefined);
  const [resolvedCurrency, setResolvedCurrency] = useState<string | undefined>(task.metadata?.currency_code as string | undefined);

  useEffect(() => {
    setResolvedAmount(task.metadata?.total_amount as number | undefined);
    setResolvedCurrency(task.metadata?.currency_code as string | undefined);
  }, [task.taskId]);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, overflow: 'hidden' }}>
      <div style={{ flex: 1, overflowY: 'auto', minHeight: 0, padding: '20px 24px' }}>
        <div style={{ marginBottom: 16 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12 }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <h2 style={{ fontSize: 18, fontWeight: 800, color: '#18345B', margin: 0, lineHeight: 1.3 }}>{task.metadata?.name as string ?? task.templateName}</h2>
              <div style={{ fontSize: 12, color: '#6B7280', marginTop: 4 }}>
                Submitted by <strong style={{ color: '#374151' }}>{task.submittedByName ?? '—'}</strong>{' · '}{fmtDate(task.taskCreatedAt)}
              </div>
            </div>
            {fullViewRoute && (
              <button onClick={() => navigate(fullViewRoute)} style={{ flexShrink: 0, display: 'flex', alignItems: 'center', gap: 5, padding: '6px 12px', borderRadius: 6, border: '1px solid #2F77B5', background: '#EFF6FF', color: '#2F77B5', fontWeight: 600, fontSize: 12, cursor: 'pointer' }}>
                Open Full View <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 10 }} />
              </button>
            )}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 12, flexWrap: 'wrap' }}>
            {resolvedAmount !== undefined && (
              <span style={{ fontSize: 20, fontWeight: 800, color: '#18345B', background: '#F0F4FF', borderRadius: 6, padding: '4px 12px' }}>
                {resolvedCurrency ? `${resolvedCurrency} ` : ''}{resolvedAmount.toLocaleString('en-IN', { minimumFractionDigits: 2 })}
              </span>
            )}
            <WorkflowStatusBadge status={wf.instance?.status ?? 'pending'} size="sm" />
            <span style={{ fontSize: 11, fontWeight: 600, color: SLA[task.slaStatus].color, background: SLA[task.slaStatus].bg, border: `1px solid ${SLA[task.slaStatus].border}`, borderRadius: 4, padding: '2px 8px' }}>
              {SLA[task.slaStatus].label}
            </span>
          </div>
        </div>
        <div style={{ borderTop: '1px solid #F3F4F6', marginBottom: 16 }} />
        <div style={{ display: 'flex', gap: 20, flexWrap: 'wrap', marginBottom: 16 }}>
          <MetaItem label="Step"     value={`${task.stepOrder} — ${task.stepName}`} />
          <MetaItem label="Workflow" value={task.templateName} />
          <MetaItem label="Module"   value={MODULE_LABELS[task.moduleCode] ?? task.moduleCode.replace(/_/g, ' ')} />
          {!task.moduleCode.startsWith('profile_') && extraMeta.map(([k, v]) => (
            <MetaItem key={k} label={k.replace(/_/g, ' ')} value={String(v)} />
          ))}
        </div>
        {(() => {
          const notedEvents = wf.history.filter(h => h.notes && h.notes.trim());
          const recentNote  = notedEvents.slice(-1);
          if (!recentNote.length) return null;
          return (
            <div style={{ marginBottom: 16 }}>
              {recentNote.map(event => (
                <div key={event.id} style={{ display: 'flex', gap: 10, alignItems: 'flex-start', padding: '10px 12px', borderRadius: 8, marginBottom: 6, background: '#FFFBEB', border: '1px solid #FDE68A' }}>
                  <i className="fas fa-comment-dots" style={{ color: '#D97706', fontSize: 13, marginTop: 2, flexShrink: 0 }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontSize: 11, fontWeight: 600, color: '#92400E', marginBottom: 2 }}>
                      {event.actorName ?? 'Approver'}{event.stepOrder ? ` · Step ${event.stepOrder}` : ''}
                      <span style={{ fontWeight: 400, color: '#B45309', marginLeft: 6 }}>
                        {new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }).format(new Date(event.createdAt))}
                      </span>
                    </div>
                    <div style={{ fontSize: 12, color: '#374151', lineHeight: 1.5 }}>{event.notes}</div>
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
          <ProfileEnrichment moduleCode={task.moduleCode} metadata={task.metadata ?? {}} currentData={task.currentData} />
        )}
        {wf.instance && (
          <div style={{ marginBottom: 8 }}>
            <SectionTitle icon="fa-clock-rotate-left" label="Approval History" />
            <WorkflowTimeline history={wf.history} tasks={wf.tasks} currentStep={wf.instance.currentStep} status={wf.instance.status} />
          </div>
        )}
      </div>
      <PanelActionBar task={task} onApprove={onApprove} onReject={onReject} onReassign={onReassign} onReturnToInitiator={onReturnToInitiator} onReturnToPreviousStep={onReturnToPreviousStep} onAfterAction={onAfterAction} />
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
  const fullViewRoute = item.moduleCode === 'expense_reports' ? `/workflow/review/${item.recordId}` : null;

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
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, overflow: 'hidden' }}>
      <div style={{ flex: 1, overflowY: 'auto', minHeight: 0, padding: '20px 24px' }}>

        {/* Header */}
        <div style={{ marginBottom: 16 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12 }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <h2 style={{ fontSize: 18, fontWeight: 800, color: '#18345B', margin: 0, lineHeight: 1.3 }}>
                {item.metadata?.name as string ?? item.templateName}
              </h2>
              <div style={{ fontSize: 12, color: '#6B7280', marginTop: 4 }}>
                Submitted {fmtDate(item.submittedAt)}
              </div>
            </div>
            {fullViewRoute && (
              <button onClick={() => navigate(fullViewRoute)} style={{ flexShrink: 0, display: 'flex', alignItems: 'center', gap: 5, padding: '6px 12px', borderRadius: 6, border: '1px solid #2F77B5', background: '#EFF6FF', color: '#2F77B5', fontWeight: 600, fontSize: 12, cursor: 'pointer' }}>
                Open Full View <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 10 }} />
              </button>
            )}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 12, flexWrap: 'wrap' }}>
            {item.metadata?.total_amount !== undefined && (
              <span style={{ fontSize: 20, fontWeight: 800, color: '#18345B', background: '#F0F4FF', borderRadius: 6, padding: '4px 12px' }}>
                {item.metadata.currency_code as string ?? ''} {Number(item.metadata.total_amount).toLocaleString('en-IN', { minimumFractionDigits: 2 })}
              </span>
            )}
            <WorkflowStatusBadge status="awaiting_clarification" size="sm" />
          </div>
        </div>

        <div style={{ borderTop: '1px solid #F3F4F6', marginBottom: 16 }} />

        {/* Approver's message — prominent callout */}
        <div style={{ padding: '14px 16px', borderRadius: 8, background: '#FEF3C7', border: '1px solid #FDE68A', marginBottom: 18 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: '#92400E', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8, display: 'flex', alignItems: 'center', gap: 6 }}>
            <i className="fas fa-comment-dots" />
            Message from {item.clarificationFrom ?? 'Approver'}
            {item.clarificationAt && (
              <span style={{ fontSize: 10, fontWeight: 400, color: '#B45309', marginLeft: 4 }}>
                · {relativeTime(item.clarificationAt)}
              </span>
            )}
          </div>
          <div style={{ fontSize: 14, color: '#374151', lineHeight: 1.6 }}>
            {item.clarificationMessage || 'No message provided.'}
          </div>
        </div>

        {/* Summary row */}
        <div style={{ display: 'flex', gap: 20, flexWrap: 'wrap', marginBottom: 16 }}>
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
        <div style={{ borderTop: '2px solid #7DD3FC', padding: '14px 20px', background: '#F0F9FF', flexShrink: 0 }}>
          <textarea
            value={editResponse}
            onChange={e => { setEditResponse(e.target.value); setEditError(null); }}
            placeholder="Add a note to the approver (optional)…"
            rows={2}
            style={{ width: '100%', padding: '8px 10px', border: '1px solid #BAE6FD', borderRadius: 6, fontSize: 13, resize: 'none', outline: 'none', fontFamily: 'inherit', boxSizing: 'border-box', marginBottom: 8, background: '#fff' }}
          />
          {editError && (
            <p style={{ fontSize: 12, color: '#DC2626', margin: '0 0 8px' }}>
              <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{editError}
            </p>
          )}
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              onClick={handleInlineResubmit}
              disabled={resubmitting}
              style={{ flex: 1, padding: '8px 16px', borderRadius: 6, border: 'none', background: resubmitting ? '#9CA3AF' : '#2F77B5', color: '#fff', fontWeight: 700, fontSize: 13, cursor: resubmitting ? 'not-allowed' : 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6 }}
            >
              {resubmitting
                ? <><i className="fas fa-spinner fa-spin" /> Submitting…</>
                : <><i className="fas fa-paper-plane" /> Update & Resubmit</>}
            </button>
            <button
              onClick={() => { setEditMode(false); setEditError(null); }}
              disabled={resubmitting}
              style={{ padding: '8px 16px', borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', color: '#374151', fontWeight: 500, fontSize: 13, cursor: 'pointer' }}
            >
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <SentBackActionBar
          item={item}
          onUpdate={onUpdate}
          onEnterEditMode={item.moduleCode.startsWith('profile_') ? enterEditMode : undefined}
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

  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [filter,         setFilter]         = useState<'all' | SlaStatus>('all');
  const [actionError,    setActionError]    = useState<string | null>(null);

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
    if (selectedTaskId && !filtered.find(t => t.taskId === selectedTaskId)) {
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
    try { await approve(taskId, notes); } catch (e) { setActionError((e as Error).message); throw e; }
  }
  async function handleReject(taskId: string, reason: string) {
    try { await reject(taskId, reason); } catch (e) { setActionError((e as Error).message); throw e; }
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
    <div style={{
      display: 'flex', flexDirection: 'column', overflow: 'hidden', background: '#F8FAFC',
      height: 'calc(100vh - 60px)',
      margin: '-28px -32px',
    }}>

      {/* ── Header ───────────────────────────────────────────────────────── */}
      <div style={{ padding: '12px 24px', borderBottom: '1px solid #E5E7EB', background: '#fff', flexShrink: 0, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <h1 style={{ fontSize: 18, fontWeight: 800, color: '#18345B', margin: 0 }}>Workflow Inbox</h1>
          <p style={{ fontSize: 12, color: '#6B7280', margin: 0 }}>
            {loading ? 'Loading…'
              : activeTab === 'approve'
                ? pendingCount === 0 ? 'All caught up' : `${pendingCount} task${pendingCount === 1 ? '' : 's'} pending`
                : sentBackCount === 0 ? 'No items need your response' : `${sentBackCount} item${sentBackCount === 1 ? '' : 's'} need${sentBackCount === 1 ? 's' : ''} your response`
            }
          </p>
        </div>
        <button
          onClick={handleRefresh}
          style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '6px 14px', borderRadius: 7, border: '1px solid #D1D5DB', background: '#fff', fontSize: 12, fontWeight: 500, color: '#374151', cursor: 'pointer' }}
        >
          <i className="fas fa-arrows-rotate" style={{ fontSize: 11 }} /> Refresh
        </button>
      </div>

      {/* ── Tab Bar ──────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', borderBottom: '1px solid #E5E7EB', background: '#fff', flexShrink: 0, paddingLeft: 24 }}>
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
            <div style={{ display: 'flex', gap: 10, padding: '12px 24px', background: '#fff', borderBottom: '1px solid #E5E7EB', flexShrink: 0 }}>
              <KpiCard label="Pending"  value={kpi.total}   icon="fa-inbox"              color="#2F77B5" bg="#EFF6FF" border="#BFDBFE" active={filter==='all'}      onClick={() => handleFilterChange('all')} />
              <KpiCard label="Overdue"  value={kpi.overdue} icon="fa-circle-exclamation" color="#DC2626" bg="#FEF2F2" border="#FECACA" active={filter==='overdue'}  onClick={() => handleFilterChange('overdue')} />
              <KpiCard label="Due Soon" value={kpi.dueSoon} icon="fa-hourglass-half"     color="#D97706" bg="#FFFBEB" border="#FDE68A" active={filter==='due_soon'} onClick={() => handleFilterChange('due_soon')} />
              <KpiCard label="On Track" value={kpi.onTrack} icon="fa-circle-check"       color="#16A34A" bg="#F0FDF4" border="#BBF7D0" active={filter==='on_track'} onClick={() => handleFilterChange('on_track')} />
            </div>
          )}

          {/* Split pane */}
          <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
            <div style={{ width: 320, flexShrink: 0, overflowY: 'auto', borderRight: '1px solid #E5E7EB', background: '#fff' }}>
              {approveLoading && <div style={{ textAlign: 'center', padding: '48px 16px', color: '#9CA3AF' }}><i className="fas fa-spinner fa-spin" style={{ fontSize: 24, marginBottom: 8, display: 'block' }} />Loading tasks…</div>}
              {approveError && !approveLoading && <div style={{ padding: 16, color: '#DC2626', fontSize: 13 }}><i className="fas fa-triangle-exclamation" style={{ marginRight: 6 }} />{approveError}</div>}
              {!approveLoading && !approveError && filtered.length === 0 && (
                <div style={{ textAlign: 'center', padding: '48px 16px', color: '#9CA3AF' }}>
                  <i className="fas fa-check-circle" style={{ fontSize: 32, marginBottom: 12, display: 'block', color: '#BBF7D0' }} />
                  <div style={{ fontWeight: 600, color: '#374151', marginBottom: 4 }}>All caught up</div>
                  <div style={{ fontSize: 12 }}>No tasks in this category.</div>
                  {filter !== 'all' && (
                    <button onClick={() => handleFilterChange('all')} style={{ marginTop: 12, fontSize: 12, color: '#2F77B5', background: 'none', border: 'none', cursor: 'pointer', textDecoration: 'underline' }}>View all tasks</button>
                  )}
                </div>
              )}
              {!approveLoading && !approveError && filtered.map(task => (
                <TaskCard key={task.taskId} task={task} selected={task.taskId === selectedTaskId} onClick={() => setSelectedTaskId(task.taskId)} />
              ))}
            </div>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
              {selectedTask ? (
                <DetailPanel task={selectedTask} onApprove={handleApprove} onReject={handleReject} onReassign={handleReassign} onReturnToInitiator={handleReturnToInitiator} onReturnToPreviousStep={handleReturnToPreviousStep} onAfterAction={handleAfterAction} />
              ) : (
                <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#9CA3AF', flexDirection: 'column', gap: 12 }}>
                  <div style={{ width: 72, height: 72, borderRadius: '50%', background: '#F3F4F6', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                    <i className="fas fa-inbox" style={{ fontSize: 28, color: '#D1D5DB' }} />
                  </div>
                  <div>
                    <div style={{ fontWeight: 600, color: '#374151', textAlign: 'center', fontSize: 15 }}>Select a task to review</div>
                    <div style={{ fontSize: 13, color: '#9CA3AF', textAlign: 'center', marginTop: 4 }}>Click a task on the left to load the report details here.</div>
                  </div>
                </div>
              )}
            </div>
          </div>
        </>
      )}

      {/* ── Sent Back tab ─────────────────────────────────────────────────── */}
      {activeTab === 'sent_back' && (
        <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
          {/* Left: clarification list */}
          <div style={{ width: 320, flexShrink: 0, overflowY: 'auto', borderRight: '1px solid #E5E7EB', background: '#fff' }}>
            {sentLoading && <div style={{ textAlign: 'center', padding: '48px 16px', color: '#9CA3AF' }}><i className="fas fa-spinner fa-spin" style={{ fontSize: 24, marginBottom: 8, display: 'block' }} />Loading…</div>}
            {sentError && !sentLoading && <div style={{ padding: 16, color: '#DC2626', fontSize: 13 }}><i className="fas fa-triangle-exclamation" style={{ marginRight: 6 }} />{sentError}</div>}
            {!sentLoading && !sentError && sentItems.length === 0 && (
              <div style={{ textAlign: 'center', padding: '48px 16px', color: '#9CA3AF' }}>
                <i className="fas fa-check-circle" style={{ fontSize: 32, marginBottom: 12, display: 'block', color: '#BBF7D0' }} />
                <div style={{ fontWeight: 600, color: '#374151', marginBottom: 4 }}>Nothing needs your response</div>
                <div style={{ fontSize: 12 }}>When an approver sends a request back for clarification, it will appear here.</div>
              </div>
            )}
            {!sentLoading && !sentError && sentItems.map(item => (
              <SentBackCard key={item.instanceId} item={item} selected={item.instanceId === selectedInstanceId} onClick={() => setSelectedInstanceId(item.instanceId)} />
            ))}
          </div>

          {/* Right: detail panel */}
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
            {selectedItem ? (
              <SentBackDetailPanel item={selectedItem} onUpdate={handleUpdate} onRespond={handleRespond} onWithdraw={handleWithdraw} onAfterAction={handleAfterSentBackAction} />
            ) : (
              <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#9CA3AF', flexDirection: 'column', gap: 12 }}>
                <div style={{ width: 72, height: 72, borderRadius: '50%', background: '#FEF3C7', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  <i className="fas fa-reply" style={{ fontSize: 28, color: '#FDE68A' }} />
                </div>
                <div>
                  <div style={{ fontWeight: 600, color: '#374151', textAlign: 'center', fontSize: 15 }}>Select a request to respond</div>
                  <div style={{ fontSize: 13, color: '#9CA3AF', textAlign: 'center', marginTop: 4 }}>Click an item on the left to see the full details and respond.</div>
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Global error toast */}
      {actionError && (
        <div style={{ position: 'fixed', bottom: 24, right: 24, zIndex: 9999, background: '#FEF2F2', border: '1px solid #FECACA', color: '#DC2626', borderRadius: 8, padding: '12px 18px', fontSize: 13, boxShadow: '0 4px 12px rgba(0,0,0,0.12)', display: 'flex', alignItems: 'center', gap: 10 }}>
          <i className="fas fa-triangle-exclamation" />
          {actionError}
          <button onClick={() => setActionError(null)} style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#DC2626', fontSize: 16 }}>×</button>
        </div>
      )}
    </div>
  );
}
