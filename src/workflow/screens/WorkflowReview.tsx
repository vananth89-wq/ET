/**
 * WorkflowReview — Full-page approver read-only view of an expense report.
 *
 * Reached via "Open Full View ↗" from the ApproverInbox panel, or linked
 * directly from email notifications. The approver can review all line items,
 * attachments, and history without constraint, then act from sticky headers
 * at both top and bottom.
 *
 * Route: /workflow/review/:id   (id = expense_report.id / record_id)
 * Guard: workflow.approve permission
 */

import { useState, useEffect, useRef } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useApproverReportDetail } from '../hooks/useApproverReportDetail';
import { useWorkflowInstance }      from '../hooks/useWorkflowInstance';
import { useWorkflowTasks }         from '../hooks/useWorkflowTasks';
import { WorkflowTimeline }         from '../components/WorkflowTimeline';
import { WorkflowStatusBadge }      from '../components/WorkflowStatusBadge';
import { usePermissions }           from '../../hooks/usePermissions';
import { fmtAmount } from '../../utils/currency';
import { supabase } from '../../lib/supabase';

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmtDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(iso));
}

function fmtDateTime(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

function attIcon(mime: string) {
  if (mime === 'application/pdf') return 'fa-file-pdf';
  if (mime.startsWith('image/'))  return 'fa-file-image';
  return 'fa-file';
}

function attFmtSize(bytes: number) {
  if (bytes < 1024)    return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

interface Person { id: string; name: string; title: string | null }

// ─────────────────────────────────────────────────────────────────────────────
// Bottom Action Bar — Workday-style: full-width textarea + 3-button row
// ─────────────────────────────────────────────────────────────────────────────

interface ActionBarProps {
  taskId:                 string;
  stepOrder:              number;
  comment:                string;
  onCommentChange:        (v: string) => void;
  loading:                boolean;
  error:                  string | null;
  onApprove:              () => void;
  onReject:               () => void;
  mode:                   'idle' | 'reassign' | 'return_init' | 'return_prev';
  onModeChange:           (m: 'idle' | 'reassign' | 'return_init' | 'return_prev') => void;
  onConfirmSecondary:     () => void;
  reassignTarget:         Person | null;
  onReassignTargetChange: (p: Person | null) => void;
}

function ActionBar({
  taskId: _taskId, stepOrder, comment, onCommentChange, loading, error,
  onApprove, onReject, mode, onModeChange, onConfirmSecondary,
  reassignTarget, onReassignTargetChange,
}: ActionBarProps) {
  const [showMore,  setShowMore]  = useState(false);
  const [query,     setQuery]     = useState('');
  const [results,   setResults]   = useState<Person[]>([]);
  const searchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const moreRef     = useRef<HTMLDivElement>(null);

  // People search for Reassign
  useEffect(() => {
    if (mode !== 'reassign' || query.length < 2) { setResults([]); return; }
    if (searchTimer.current) clearTimeout(searchTimer.current);
    searchTimer.current = setTimeout(async () => {
      const { data } = await supabase
        .from('profiles')
        .select('id, employees!inner(name, job_title)')
        .ilike('employees.name', `%${query}%`)
        .eq('is_active', true)
        .limit(8);
      setResults((data ?? []).map((p: any) => ({
        id: p.id, name: p.employees?.name ?? '—', title: p.employees?.job_title ?? null,
      })));
    }, 300);
  }, [query, mode]);

  // Outside-click-to-close for More dropdown
  useEffect(() => {
    if (!showMore) return;
    function handleOutside(e: MouseEvent) {
      if (moreRef.current && !moreRef.current.contains(e.target as Node)) {
        setShowMore(false);
      }
    }
    document.addEventListener('mousedown', handleOutside);
    return () => document.removeEventListener('mousedown', handleOutside);
  }, [showMore]);

  const placeholder =
    mode === 'reassign'    ? 'Reason for reassigning (optional)…' :
    mode === 'return_init' ? 'Message to submitter (required)…'   :
    mode === 'return_prev' ? 'Reason for returning (optional)…'   :
                             'Add a note — sent with your decision…';

  return (
    <div style={{
      display: 'flex', flexDirection: 'column', gap: 10,
      padding: '14px 32px',
      background: '#fff',
      borderTop: '2px solid #E5E7EB',
    }}>
      {/* Reassign person search — shown above textarea when in reassign mode */}
      {mode === 'reassign' && (
        <div>
          <label style={{ fontSize: 11, fontWeight: 600, color: '#6B7280', textTransform: 'uppercase', display: 'block', marginBottom: 4 }}>
            Reassign to *
          </label>
          {reassignTarget ? (
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 10,
              padding: '7px 12px', borderRadius: 6,
              border: '1px solid #DDD6FE', background: '#F5F3FF', marginBottom: 6,
            }}>
              <div>
                <div style={{ fontSize: 13, fontWeight: 600, color: '#5B21B6' }}>{reassignTarget.name}</div>
                {reassignTarget.title && <div style={{ fontSize: 11, color: '#7C3AED' }}>{reassignTarget.title}</div>}
              </div>
              <button onClick={() => { onReassignTargetChange(null); setQuery(''); }}
                style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#7C3AED', fontSize: 16 }}>×</button>
            </div>
          ) : (
            <div style={{ position: 'relative', maxWidth: 340, marginBottom: 6 }}>
              <input
                value={query} onChange={e => setQuery(e.target.value)}
                placeholder="Search by name…" autoFocus
                style={{
                  width: '100%', padding: '7px 10px', border: '1px solid #D1D5DB',
                  borderRadius: 6, fontSize: 13, outline: 'none', boxSizing: 'border-box',
                }}
              />
              {results.length > 0 && (
                <div style={{
                  position: 'absolute', bottom: '100%', left: 0, right: 0, zIndex: 50,
                  background: '#fff', border: '1px solid #D1D5DB', borderRadius: 6,
                  boxShadow: '0 -4px 12px rgba(0,0,0,0.1)', marginBottom: 2, overflow: 'hidden',
                }}>
                  {results.map(p => (
                    <button key={p.id}
                      onClick={() => { onReassignTargetChange(p); setQuery(''); setResults([]); }}
                      style={{
                        display: 'block', width: '100%', textAlign: 'left',
                        padding: '8px 12px', border: 'none', background: 'none', cursor: 'pointer',
                        borderBottom: '1px solid #F3F4F6',
                      }}
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

      {/* Row 1: full-width textarea */}
      <textarea
        value={comment} onChange={e => onCommentChange(e.target.value)}
        placeholder={placeholder}
        rows={2}
        style={{
          width: '100%', padding: '8px 10px',
          border: `1px solid ${error ? '#FECACA' : '#D1D5DB'}`,
          borderRadius: 6, fontSize: 13, resize: 'none', outline: 'none',
          fontFamily: 'inherit', boxSizing: 'border-box',
        }}
      />

      {/* Row 2: action buttons */}
      {mode === 'idle' ? (
        <div style={{ display: 'flex', gap: 8, height: 38 }}>
          {/* Approve — 30% */}
          <button onClick={onApprove} disabled={loading}
            style={{
              width: '22%', flexShrink: 0, borderRadius: 7, border: 'none',
              background: loading ? '#9CA3AF' : '#16A34A', color: '#fff',
              fontWeight: 700, fontSize: 13, cursor: loading ? 'not-allowed' : 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
            }}>
            {loading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-check" />}
            Approve
          </button>

          {/* Reject — 20% */}
          <button onClick={onReject} disabled={loading}
            style={{
              width: '18%', flexShrink: 0, borderRadius: 7, border: 'none',
              background: '#DC2626', color: '#fff',
              fontWeight: 700, fontSize: 13, cursor: loading ? 'not-allowed' : 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
            }}>
            <i className="fas fa-times" /> Reject
          </button>

          {/* More — 10% */}
          <div ref={moreRef} style={{ position: 'relative', width: '10%', flexShrink: 0 }}>
            <button
              onClick={() => setShowMore(v => !v)} disabled={loading}
              style={{
                width: '100%', height: '100%', borderRadius: 7,
                border: '1.5px solid #D1D5DB',
                background: showMore ? '#F3F4F6' : '#FAFAFA',
                color: '#374151', fontWeight: 600, fontSize: 12,
                cursor: loading ? 'not-allowed' : 'pointer',
                display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 5,
              }}>
              More
              <i className="fas fa-chevron-down" style={{
                fontSize: 10,
                transition: 'transform 0.15s',
                transform: showMore ? 'rotate(180deg)' : 'none',
              }} />
            </button>
            {showMore && (
              <div style={{
                position: 'absolute', bottom: 'calc(100% + 6px)', right: 0, zIndex: 100,
                background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
                boxShadow: '0 8px 24px rgba(0,0,0,0.12)', minWidth: 260, overflow: 'hidden',
              }}>
                {/* Reassign */}
                <button
                  onClick={() => { onModeChange('reassign'); setShowMore(false); }}
                  style={{ display: 'flex', alignItems: 'flex-start', width: '100%', textAlign: 'left',
                    padding: 0, border: 'none', background: 'none', cursor: 'pointer',
                    borderBottom: '1px solid #F3F4F6' }}
                  onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')}
                  onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                >
                  <div style={{ width: 4, alignSelf: 'stretch', background: '#7C3AED', borderRadius: '10px 0 0 10px', flexShrink: 0 }} />
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 14px', flex: 1 }}>
                    <div style={{ width: 32, height: 32, borderRadius: 8, background: '#EDE9FE',
                      display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                      <i className="fas fa-arrow-right-arrow-left" style={{ color: '#7C3AED', fontSize: 13 }} />
                    </div>
                    <div>
                      <div style={{ fontSize: 13, fontWeight: 600, color: '#5B21B6' }}>Reassign</div>
                      <div style={{ fontSize: 11, color: '#7C3AED', marginTop: 1 }}>Transfer to another approver</div>
                    </div>
                  </div>
                </button>

                {/* Send Back */}
                <button
                  onClick={() => { onModeChange('return_init'); setShowMore(false); }}
                  style={{ display: 'flex', alignItems: 'flex-start', width: '100%', textAlign: 'left',
                    padding: 0, border: 'none', background: 'none', cursor: 'pointer',
                    borderBottom: stepOrder > 1 ? '1px solid #F3F4F6' : 'none' }}
                  onMouseEnter={e => (e.currentTarget.style.background = '#FFFBEB')}
                  onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                >
                  <div style={{ width: 4, alignSelf: 'stretch', background: '#D97706', borderRadius: '10px 0 0 10px', flexShrink: 0 }} />
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 14px', flex: 1 }}>
                    <div style={{ width: 32, height: 32, borderRadius: 8, background: '#FFFBEB',
                      display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                      <i className="fas fa-comment-dots" style={{ color: '#D97706', fontSize: 13 }} />
                    </div>
                    <div>
                      <div style={{ fontSize: 13, fontWeight: 600, color: '#92400E' }}>Send Back</div>
                      <div style={{ fontSize: 11, color: '#B45309', marginTop: 1 }}>Request clarification from submitter</div>
                    </div>
                  </div>
                </button>

                {/* Send Back to Previous Step — only if stepOrder > 1 */}
                {stepOrder > 1 && (
                  <button
                    onClick={() => { onModeChange('return_prev'); setShowMore(false); }}
                    style={{ display: 'flex', alignItems: 'flex-start', width: '100%', textAlign: 'left',
                      padding: 0, border: 'none', background: 'none', cursor: 'pointer' }}
                    onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                    onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                  >
                    <div style={{ width: 4, alignSelf: 'stretch', background: '#9CA3AF', borderRadius: '10px 0 0 10px', flexShrink: 0 }} />
                    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 14px', flex: 1 }}>
                      <div style={{ width: 32, height: 32, borderRadius: 8, background: '#F3F4F6',
                        display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                        <i className="fas fa-backward-step" style={{ color: '#6B7280', fontSize: 13 }} />
                      </div>
                      <div>
                        <div style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>Send Back to Previous Step</div>
                        <div style={{ fontSize: 11, color: '#6B7280', marginTop: 1 }}>Return to the prior approval step</div>
                      </div>
                    </div>
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      ) : (
        /* Secondary action mode (Reassign / Send Back / Send Back to Previous Step) */
        <div style={{ display: 'flex', gap: 8 }}>
          <button onClick={onConfirmSecondary} disabled={loading}
            style={{
              flex: 1, padding: '8px 18px', borderRadius: 7, border: 'none',
              background: mode === 'reassign' ? '#7C3AED' : mode === 'return_init' ? '#B45309' : '#374151',
              color: '#fff', fontWeight: 600, fontSize: 13,
              cursor: loading ? 'not-allowed' : 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
            }}>
            {loading && <i className="fas fa-spinner fa-spin" />}
            {mode === 'reassign'    && 'Confirm Reassign'}
            {mode === 'return_init' && 'Send Back'}
            {mode === 'return_prev' && 'Send Back to Previous Step'}
          </button>
          <button onClick={() => { onModeChange('idle'); onReassignTargetChange(null); }}
            style={{ padding: '8px 18px', borderRadius: 7, border: '1px solid #D1D5DB', background: '#fff', color: '#374151', fontWeight: 500, fontSize: 13, cursor: 'pointer' }}>
            Cancel
          </button>
        </div>
      )}

      {error && (
        <p style={{ fontSize: 12, color: '#DC2626', margin: 0 }}>
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{error}
        </p>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Screen
// ─────────────────────────────────────────────────────────────────────────────

export default function WorkflowReview() {
  const { id: recordId } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const { can } = usePermissions();
  const canEditOnApproval = can('expense.edit_approval');

  const { detail, loading, error, refetch: refetchDetail } = useApproverReportDetail(recordId ?? null);
  const wf = useWorkflowInstance('expense_reports', recordId ?? null);
  const { tasks, approve, reject, reassign, returnToInitiator, returnToPreviousStep } = useWorkflowTasks();

  // Find the task for this record (the one assigned to current user)
  const myTask = tasks.find(t => t.recordId === recordId) ?? null;

  // ── WF Edit Gate: fetch allow_edit from the active step ───────────────────
  const [stepAllowEdit, setStepAllowEdit] = useState(false);
  useEffect(() => {
    if (!myTask) { setStepAllowEdit(false); return; }
    supabase
      .from('workflow_tasks')
      .select('workflow_steps ( allow_edit )')
      .eq('id', myTask.taskId)
      .maybeSingle()
      .then(({ data }) => {
        const ae = (data as any)?.workflow_steps?.allow_edit ?? false;
        setStepAllowEdit(ae);
      });
  }, [myTask?.taskId]);

  // Dual-control gate: BOTH the step flag AND the RBP permission must be true
  const canEditMidFlight = stepAllowEdit && canEditOnApproval;

  // Shared action state (both top + bottom bars share it)
  const [comment,        setComment]        = useState('');
  const [mode,           setMode]           = useState<'idle' | 'reassign' | 'return_init' | 'return_prev'>('idle');
  const [actionLoading,  setActionLoading]  = useState(false);
  const [actionError,    setActionError]    = useState<string | null>(null);
  const [actionSuccess,  setActionSuccess]  = useState<string | null>(null);
  const [reassignTarget, setReassignTarget] = useState<Person | null>(null);

  // ── Inline edit state (expense.edit_approval) ─────────────────────────────
  // editedNotes: tracks in-progress note edits keyed by line item id
  // saveState:   per-item save status — 'saving' | 'saved' | 'error'
  const [editedNotes, setEditedNotes] = useState<Record<string, string>>({});
  const [saveState,   setSaveState]   = useState<Record<string, 'saving' | 'saved' | 'error'>>({});
  const savedTimers = useRef<Record<string, ReturnType<typeof setTimeout>>>({});

  // Seed editedNotes when detail loads (so inputs start with current values)
  useEffect(() => {
    if (!detail) return;
    setEditedNotes(
      Object.fromEntries(detail.lineItems.map(li => [li.id, li.note ?? '']))
    );
  }, [detail?.id]); // only re-seed when switching reports, not on every re-render

  async function handleNoteSave(itemId: string) {
    const newNote = (editedNotes[itemId] ?? '').trim();
    const original = detail?.lineItems.find(li => li.id === itemId)?.note ?? '';
    if (newNote === original.trim()) return; // no change

    setSaveState(s => ({ ...s, [itemId]: 'saving' }));
    const { error: err } = await supabase
      .from('line_items')
      .update({ note: newNote || null })
      .eq('id', itemId);

    if (err) {
      setSaveState(s => ({ ...s, [itemId]: 'error' }));
    } else {
      setSaveState(s => ({ ...s, [itemId]: 'saved' }));
      refetchDetail();
      // Clear the 'saved' indicator after 2s
      if (savedTimers.current[itemId]) clearTimeout(savedTimers.current[itemId]);
      savedTimers.current[itemId] = setTimeout(() => {
        setSaveState(s => { const n = { ...s }; delete n[itemId]; return n; });
      }, 2000);
    }
  }

  // Reset on mode change
  useEffect(() => {
    setActionError(null);
  }, [mode]);

  async function run(fn: () => Promise<void>, successMsg: string) {
    setActionLoading(true); setActionError(null);
    try {
      await fn();
      setActionSuccess(successMsg);
      setComment(''); setMode('idle'); setReassignTarget(null);
      // Go back to inbox after a moment
      setTimeout(() => navigate('/workflow/inbox'), 1800);
    } catch (e) {
      setActionError((e as Error).message);
    } finally {
      setActionLoading(false);
    }
  }

  function handleApprove() {
    if (!myTask) return;
    run(() => approve(myTask.taskId, comment.trim() || undefined), 'Approved successfully');
  }

  function handleReject() {
    if (!myTask) return;
    if (!comment.trim()) { setActionError('Rejection reason is required.'); return; }
    run(() => reject(myTask.taskId, comment.trim()), 'Report rejected');
  }

  function handleConfirmSecondary() {
    if (!myTask) return;
    if (mode === 'reassign') {
      if (!reassignTarget) { setActionError('Select a person to reassign to.'); return; }
      run(() => reassign(myTask.taskId, reassignTarget.id, comment.trim() || undefined), 'Task reassigned');
    } else if (mode === 'return_init') {
      if (!comment.trim()) { setActionError('A message to the initiator is required.'); return; }
      run(() => returnToInitiator(myTask.taskId, comment.trim()), 'Returned for clarification');
    } else if (mode === 'return_prev') {
      run(() => returnToPreviousStep(myTask.taskId, comment.trim() || undefined), 'Returned to previous step');
    }
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  const lineItems = detail?.lineItems ?? [];
  const allAttachments = lineItems.flatMap(li => (li.attachments ?? []).map(a => ({ ...a, categoryName: li.categoryName })));
  const baseCurr = detail?.baseCurrencyCode ?? '';

  const actionBarProps = {
    taskId:                 myTask?.taskId ?? '',
    stepOrder:              myTask?.stepOrder ?? 1,
    comment,
    onCommentChange:        setComment,
    loading:                actionLoading,
    error:                  actionError,
    onApprove:              handleApprove,
    onReject:               handleReject,
    mode,
    onModeChange:           setMode,
    onConfirmSecondary:     handleConfirmSecondary,
    reassignTarget,
    onReassignTargetChange: setReassignTarget,
  };

  return (
    <div style={{ minHeight: '100vh', background: '#F8FAFC', display: 'flex', flexDirection: 'column' }}>

      {/* ── Sticky top nav + action bar ──────────────────────────────────── */}
      <div style={{ position: 'sticky', top: 0, zIndex: 40, boxShadow: '0 2px 8px rgba(0,0,0,0.08)' }}>

        {/* Nav bar */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '10px 32px', background: '#18345B',
        }}>
          <button
            onClick={() => navigate('/workflow/inbox')}
            style={{
              display: 'flex', alignItems: 'center', gap: 8,
              background: 'none', border: 'none', color: '#93C5FD',
              fontWeight: 600, fontSize: 13, cursor: 'pointer',
            }}
          >
            <i className="fas fa-arrow-left" /> Back to Inbox
          </button>

          <div style={{ textAlign: 'center' }}>
            {detail && (
              <>
                <div style={{ fontWeight: 800, fontSize: 15, color: '#fff' }}>{detail.name}</div>
                <div style={{ fontSize: 11, color: '#93C5FD' }}>
                  Submitted by {detail.employeeName ?? '—'}
                  {detail.submittedAt && <> · {fmtDate(detail.submittedAt)}</>}
                </div>
              </>
            )}
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            {detail && (
              <span style={{ fontSize: 15, fontWeight: 800, color: '#fff' }}>
                {baseCurr} {detail.totalConverted.toLocaleString('en-IN', { minimumFractionDigits: 2 })}
              </span>
            )}
            <WorkflowStatusBadge status="pending" size="sm" />
          </div>
        </div>

      </div>

      {/* ── Success banner ────────────────────────────────────────────────── */}
      {actionSuccess && (
        <div style={{
          margin: '16px 32px 0',
          padding: '12px 16px', borderRadius: 8,
          background: '#F0FDF4', border: '1px solid #BBF7D0',
          color: '#166534', fontSize: 14, fontWeight: 600,
          display: 'flex', alignItems: 'center', gap: 8,
        }}>
          <i className="fas fa-circle-check" />
          {actionSuccess} — returning to inbox…
        </div>
      )}

      {/* ── Main content ──────────────────────────────────────────────────── */}
      <div style={{ maxWidth: 960, margin: '0 auto', padding: '28px 32px', width: '100%', boxSizing: 'border-box' }}>

        {/* Loading */}
        {loading && (
          <div style={{ textAlign: 'center', padding: '80px 0', color: '#9CA3AF' }}>
            <i className="fas fa-spinner fa-spin" style={{ fontSize: 32, marginBottom: 16, display: 'block' }} />
            Loading report…
          </div>
        )}

        {/* Error */}
        {error && !loading && (
          <div style={{
            padding: '24px', borderRadius: 10,
            background: '#FEF2F2', border: '1px solid #FECACA',
            color: '#DC2626', textAlign: 'center',
          }}>
            <i className="fas fa-triangle-exclamation" style={{ fontSize: 28, marginBottom: 8, display: 'block' }} />
            <strong>Could not load report</strong>
            <p style={{ margin: '8px 0 0' }}>{error}</p>
          </div>
        )}

        {detail && (
          <>
            {/* ── Report summary card ──────────────────────────────────── */}
            <div style={{
              background: '#fff', borderRadius: 12, border: '1px solid #E5E7EB',
              padding: '20px 24px', marginBottom: 24,
              display: 'flex', gap: 24, flexWrap: 'wrap',
            }}>
              <SummaryItem label="Submitted By"   value={detail.employeeName ?? '—'} />
              <SummaryItem label="Submitted On"   value={detail.submittedAt ? fmtDateTime(detail.submittedAt) : '—'} />
              <SummaryItem label="Base Currency"  value={detail.baseCurrencyCode} />
              <SummaryItem label="Total Amount"   value={`${baseCurr} ${detail.totalConverted.toLocaleString('en-IN', { minimumFractionDigits: 2 })}`} highlight />
              {myTask && <SummaryItem label="Current Step" value={`Step ${myTask.stepOrder} — ${myTask.stepName}`} />}
            </div>

            {/* ── Line Items ───────────────────────────────────────────── */}
            <Section title="Line Items" icon="fa-list" count={lineItems.length}>
              <div style={{ border: '1px solid #E5E7EB', borderRadius: 10, overflow: 'hidden' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                  <thead>
                    <tr style={{ background: '#F9FAFB', borderBottom: '1px solid #E5E7EB' }}>
                      {['#', 'Category', 'Date', 'Project', 'Amount', 'Converted',
                      canEditMidFlight ? 'Note ✎' : 'Note', 'Attachments'
                    ].map(h => (
                        <th key={h} style={{ padding: '10px 14px', textAlign: 'left', fontWeight: 600, color: '#6B7280', fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em', whiteSpace: 'nowrap' }}>
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {lineItems.map((li, i) => (
                      <tr key={li.id} style={{ borderBottom: i < lineItems.length - 1 ? '1px solid #F3F4F6' : 'none' }}>
                        <td style={{ padding: '10px 14px', color: '#9CA3AF', fontWeight: 600 }}>{i + 1}</td>
                        <td style={{ padding: '10px 14px', color: '#374151', fontWeight: 500 }}>{li.categoryName || '—'}</td>
                        <td style={{ padding: '10px 14px', color: '#374151', whiteSpace: 'nowrap' }}>{fmtDate(li.date)}</td>
                        <td style={{ padding: '10px 14px', color: '#6B7280' }}>{li.projectName || '—'}</td>
                        <td style={{ padding: '10px 14px', fontWeight: 600, color: '#374151', whiteSpace: 'nowrap' }}>
                          {fmtAmount(li.amount, li.currencyCode)}
                        </td>
                        <td style={{ padding: '10px 14px', fontWeight: 700, color: '#18345B', whiteSpace: 'nowrap' }}>
                          {fmtAmount(li.convertedAmount, baseCurr)}
                        </td>
                        <td style={{ padding: canEditMidFlight ? '6px 10px' : '10px 14px', minWidth: 160, maxWidth: 220 }}>
                          {canEditMidFlight ? (
                            <div style={{ position: 'relative' }}>
                              <textarea
                                value={editedNotes[li.id] ?? li.note ?? ''}
                                onChange={e => setEditedNotes(n => ({ ...n, [li.id]: e.target.value }))}
                                onBlur={() => handleNoteSave(li.id)}
                                rows={1}
                                placeholder="Add note…"
                                style={{
                                  width: '100%', padding: '5px 28px 5px 8px',
                                  border: '1px solid #FDE68A',
                                  borderRadius: 5, fontSize: 12, resize: 'none',
                                  outline: 'none', fontFamily: 'inherit',
                                  background: '#FFFBEB', boxSizing: 'border-box',
                                  color: '#374151', lineHeight: 1.4,
                                }}
                                onFocus={e => (e.currentTarget.style.border = '1px solid #F59E0B')}
                              />
                              {/* Save state indicator */}
                              <span style={{ position: 'absolute', right: 6, top: '50%', transform: 'translateY(-50%)', fontSize: 11 }}>
                                {saveState[li.id] === 'saving' && <i className="fas fa-spinner fa-spin" style={{ color: '#D97706' }} />}
                                {saveState[li.id] === 'saved'  && <i className="fas fa-check"   style={{ color: '#16A34A' }} />}
                                {saveState[li.id] === 'error'  && <i className="fas fa-xmark"   style={{ color: '#DC2626' }} title="Save failed" />}
                              </span>
                            </div>
                          ) : (
                            <span style={{ color: '#6B7280', fontSize: 13 }}>{li.note || '—'}</span>
                          )}
                        </td>
                        {/* Attachments — inline per line item */}
                        <td style={{ padding: '10px 14px', whiteSpace: 'nowrap' }}>
                          {!li.attachments?.length ? (
                            <span style={{ color: '#D1D5DB' }}>—</span>
                          ) : li.attachments.length === 1 ? (
                            <a
                              href={li.attachments[0].dataUrl}
                              target="_blank"
                              rel="noopener noreferrer"
                              title={li.attachments[0].name}
                              style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: '#2563EB', textDecoration: 'none', fontSize: 12, fontWeight: 600 }}
                            >
                              <i className="fas fa-paperclip" style={{ fontSize: 11 }} /> 1
                            </a>
                          ) : (
                            <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                              {li.attachments.map(att => (
                                <a
                                  key={att.id}
                                  href={att.dataUrl}
                                  target="_blank"
                                  rel="noopener noreferrer"
                                  title={att.name}
                                  style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: '#2563EB', textDecoration: 'none', fontSize: 12, fontWeight: 500 }}
                                >
                                  <i className={`fas ${att.type === 'application/pdf' ? 'fa-file-pdf' : att.type.startsWith('image/') ? 'fa-file-image' : 'fa-file'}`}
                                    style={{ fontSize: 11, color: att.type === 'application/pdf' ? '#DC2626' : '#2563EB' }} />
                                  <span style={{ maxWidth: 120, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{att.name}</span>
                                </a>
                              ))}
                            </div>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot>
                    <tr style={{ background: '#F0F4FF', borderTop: '2px solid #BFDBFE' }}>
                      <td colSpan={5} style={{ padding: '10px 14px', fontWeight: 700, color: '#18345B' }}>Total</td>
                      <td style={{ padding: '10px 14px', fontWeight: 800, color: '#18345B', fontSize: 15 }}>
                        {fmtAmount(detail.totalConverted, baseCurr)}
                      </td>
                      <td /><td />
                    </tr>
                  </tfoot>
                </table>
              </div>
            </Section>

            {/* Edit affordance legend */}
            {canEditMidFlight && (
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 8, fontSize: 11, color: '#92400E' }}>
                <span style={{ display: 'inline-block', width: 12, height: 12, borderRadius: 2, background: '#FFFBEB', border: '1px solid #FDE68A' }} />
                Highlighted cells are editable — changes save automatically on blur.
                {/* GL Code editing can be wired here once gl_code column is added to line_items */}
              </div>
            )}

            {/* ── Attachments ──────────────────────────────────────────── */}
            {allAttachments.length > 0 && (
              <Section title="Attachments" icon="fa-paperclip" count={allAttachments.length}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 10 }}>
                  {allAttachments.map(att => (
                    <a
                      key={att.id} href={att.dataUrl} target="_blank" rel="noopener noreferrer"
                      style={{
                        display: 'flex', alignItems: 'center', gap: 12,
                        padding: '12px 14px', borderRadius: 8,
                        border: '1px solid #E5E7EB', background: '#fff',
                        textDecoration: 'none', color: '#374151',
                        transition: 'background 0.12s',
                      }}
                      onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                      onMouseLeave={e => (e.currentTarget.style.background = '#fff')}
                    >
                      <i className={`fas ${attIcon(att.type)}`}
                        style={{ fontSize: 24, color: att.type === 'application/pdf' ? '#DC2626' : '#2563EB', flexShrink: 0 }} />
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 13, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                          {att.name}
                        </div>
                        <div style={{ fontSize: 11, color: '#9CA3AF' }}>
                          {attFmtSize(att.size)} · {att.categoryName || 'Attachment'}
                        </div>
                      </div>
                      <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 12, color: '#9CA3AF', flexShrink: 0 }} />
                    </a>
                  ))}
                </div>
              </Section>
            )}

            {/* ── Approval History ─────────────────────────────────────── */}
            {wf.instance && (
              <Section title="Approval History" icon="fa-clock-rotate-left">
                <WorkflowTimeline
                  history={wf.history}
                  tasks={wf.tasks}
                  currentStep={wf.instance.currentStep}
                  status={wf.instance.status}
                />
              </Section>
            )}
          </>
        )}
      </div>

      {/* ── Sticky bottom action bar ──────────────────────────────────────── */}
      {myTask && detail && (
        <div style={{ position: 'sticky', bottom: 0, zIndex: 40, boxShadow: '0 -2px 8px rgba(0,0,0,0.08)' }}>
          <ActionBar {...actionBarProps} />
        </div>
      )}

      {/* No task — read-only notice */}
      {!myTask && !loading && detail && (
        <div style={{
          position: 'sticky', bottom: 0, zIndex: 40,
          padding: '12px 32px', background: '#FFFBEB',
          borderTop: '1px solid #FDE68A',
          display: 'flex', alignItems: 'center', gap: 8,
          fontSize: 13, color: '#92400E',
        }}>
          <i className="fas fa-circle-info" />
          You are viewing this report in read-only mode — this task is not currently assigned to you.
        </div>
      )}
    </div>
  );
}

// ── Small helpers ─────────────────────────────────────────────────────────────

function Section({ title, icon, count, children }: {
  title: string; icon: string; count?: number; children: React.ReactNode;
}) {
  return (
    <div style={{ marginBottom: 28 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
        <i className={`fas ${icon}`} style={{ fontSize: 14, color: '#6B7280' }} />
        <h2 style={{ fontSize: 14, fontWeight: 700, color: '#18345B', margin: 0, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
          {title}
        </h2>
        {count !== undefined && (
          <span style={{ fontSize: 11, background: '#E5E7EB', color: '#6B7280', borderRadius: 10, padding: '1px 8px', fontWeight: 600 }}>
            {count}
          </span>
        )}
      </div>
      {children}
    </div>
  );
}

function SummaryItem({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div>
      <div style={{ fontSize: 10, fontWeight: 700, color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.05em' }}>{label}</div>
      <div style={{ fontSize: highlight ? 16 : 14, fontWeight: highlight ? 800 : 500, color: highlight ? '#18345B' : '#111827', marginTop: 2 }}>
        {value}
      </div>
    </div>
  );
}
