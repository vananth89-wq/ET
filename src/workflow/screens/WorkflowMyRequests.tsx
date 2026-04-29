/**
 * WorkflowMyRequests
 *
 * Employee-side screen showing all workflow instances submitted by the current
 * user. Powered by vw_wf_my_requests.
 *
 * Features:
 *   - Status filter tabs (All / In Progress / Awaiting Clarification / Approved / Rejected)
 *   - Clarification message banner with inline Respond & Resume panel
 *   - Current approver + SLA due date per in-progress request
 *   - Withdraw action for in-progress requests
 *   - Deep-link to the source record (e.g. expense report)
 *
 * Route: /workflow/my-requests
 */

import { useState, useEffect, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase }    from '../../lib/supabase';
import { useAuth }     from '../../contexts/AuthContext';
import { WorkflowStatusBadge } from '../components/WorkflowStatusBadge';

// ─── Types ────────────────────────────────────────────────────────────────────

interface MyRequest {
  id:                      string;
  status:                  string;
  moduleCode:              string;
  recordId:                string;
  templateCode:            string;
  templateName:            string;
  currentStep:             number | null;
  submittedAt:             string;
  updatedAt:               string;
  completedAt:             string | null;
  currentApproverId:       string | null;
  currentApproverName:     string | null;
  currentTaskDue:          string | null;
  // Clarification fields (from migration 048 lateral join in vw_wf_my_requests)
  clarificationMessage:    string | null;
  clarificationFrom:       string | null;
  clarificationAt:         string | null;
}

type FilterStatus =
  | 'all'
  | 'in_progress'
  | 'awaiting_clarification'
  | 'approved'
  | 'rejected'
  | 'withdrawn';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

function relativeTime(iso: string) {
  const diff = Date.now() - new Date(iso).getTime();
  const m = Math.floor(diff / 60_000);
  if (m < 60)  return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24)  return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

function moduleLink(moduleCode: string, recordId: string) {
  if (moduleCode === 'expense_reports') return `/expense/report/${recordId}`;
  return null;
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function WorkflowMyRequests() {
  const { user }   = useAuth();
  const navigate   = useNavigate();

  const [requests,  setRequests]  = useState<MyRequest[]>([]);
  const [loading,   setLoading]   = useState(false);
  const [error,     setError]     = useState<string | null>(null);
  const [filter,    setFilter]    = useState<FilterStatus>('all');

  // Withdraw state
  const [withdrawId,     setWithdrawId]     = useState<string | null>(null);
  const [withdrawReason, setWithdrawReason] = useState('');
  const [withdrawing,    setWithdrawing]    = useState(false);

  // Respond & Resume state (per-instance inline panel)
  const [respondId,   setRespondId]   = useState<string | null>(null);
  const [respondText, setRespondText] = useState('');
  const [responding,  setResponding]  = useState(false);
  const [respondErr,  setRespondErr]  = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!user) return;
    setLoading(true);
    setError(null);

    const { data, error: err } = await supabase
      .from('vw_wf_my_requests')
      .select('*')
      .order('submitted_at', { ascending: false });

    if (err) {
      setError(err.message);
    } else {
      setRequests((data ?? []).map(r => ({
        id:                   r.id,
        status:               r.status,
        moduleCode:           r.module_code,
        recordId:             r.record_id,
        templateCode:         r.template_code,
        templateName:         r.template_name,
        currentStep:          r.current_step,
        submittedAt:          r.submitted_at,
        updatedAt:            r.updated_at,
        completedAt:          r.completed_at,
        currentApproverId:    r.current_approver_id,
        currentApproverName:  r.current_approver_name,
        currentTaskDue:       r.current_task_due,
        clarificationMessage: r.clarification_message ?? null,
        clarificationFrom:    r.clarification_from    ?? null,
        clarificationAt:      r.clarification_at      ?? null,
      })));
    }
    setLoading(false);
  }, [user]);

  useEffect(() => { load(); }, [load]);

  const filtered = filter === 'all'
    ? requests
    : requests.filter(r => r.status === filter);

  const counts: Record<FilterStatus, number> = {
    all:                      requests.length,
    in_progress:              requests.filter(r => r.status === 'in_progress').length,
    awaiting_clarification:   requests.filter(r => r.status === 'awaiting_clarification').length,
    approved:                 requests.filter(r => r.status === 'approved').length,
    rejected:                 requests.filter(r => r.status === 'rejected').length,
    withdrawn:                requests.filter(r => r.status === 'withdrawn').length,
  };

  // ── Withdraw ─────────────────────────────────────────────────────────────────

  async function handleWithdraw() {
    if (!withdrawId) return;
    setWithdrawing(true);
    const { error: err } = await supabase.rpc('wf_withdraw', {
      p_instance_id: withdrawId,
      p_reason:      withdrawReason.trim() || null,
    });
    setWithdrawing(false);
    if (err) {
      setError(err.message);
    } else {
      setWithdrawId(null);
      setWithdrawReason('');
      await load();
    }
  }

  // ── Respond & Resume ─────────────────────────────────────────────────────────

  async function handleResubmit() {
    if (!respondId) return;
    setResponding(true);
    setRespondErr(null);
    const { error: err } = await supabase.rpc('wf_resubmit', {
      p_instance_id: respondId,
      p_response:    respondText.trim() || null,
    });
    setResponding(false);
    if (err) {
      setRespondErr(err.message);
    } else {
      setRespondId(null);
      setRespondText('');
      await load();
    }
  }

  // ─── Render ───────────────────────────────────────────────────────────────────

  const FILTER_TABS: { key: FilterStatus; label: string }[] = [
    { key: 'all',                    label: 'All'                  },
    { key: 'in_progress',            label: 'In Progress'          },
    { key: 'awaiting_clarification', label: 'Needs Your Input'     },
    { key: 'approved',               label: 'Approved'             },
    { key: 'rejected',               label: 'Rejected'             },
    { key: 'withdrawn',              label: 'Withdrawn'            },
  ];

  return (
    <div style={{ padding: '32px 40px', maxWidth: 900, margin: '0 auto' }}>

      {/* ── Header ─────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: '#18345B', margin: 0 }}>
            My Requests
          </h1>
          <p style={{ fontSize: 13, color: '#6B7280', marginTop: 4 }}>
            Approval requests you have submitted
          </p>
        </div>
        <button
          onClick={load}
          style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '7px 14px', borderRadius: 7,
            border: '1px solid #D1D5DB', background: '#fff',
            fontSize: 13, fontWeight: 500, color: '#374151', cursor: 'pointer',
          }}
        >
          <i className="fas fa-arrows-rotate" style={{ fontSize: 12 }} />
          Refresh
        </button>
      </div>

      {/* ── Attention banner: items awaiting user input ──────────────────────── */}
      {counts.awaiting_clarification > 0 && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          padding: '10px 14px', borderRadius: 8, marginBottom: 20,
          background: '#FEF3C7', border: '1px solid #FDE68A',
          cursor: 'pointer',
        }}
          onClick={() => setFilter('awaiting_clarification')}
        >
          <i className="fas fa-bell" style={{ color: '#B45309', fontSize: 13 }} />
          <span style={{ fontSize: 13, fontWeight: 600, color: '#92400E' }}>
            {counts.awaiting_clarification} request{counts.awaiting_clarification !== 1 ? 's need' : ' needs'} your input
          </span>
          <span style={{ fontSize: 12, color: '#B45309', marginLeft: 4 }}>
            — an approver has returned a request asking for clarification
          </span>
          <span style={{ marginLeft: 'auto', fontSize: 11, color: '#B45309', fontWeight: 600 }}>
            View →
          </span>
        </div>
      )}

      {/* ── Filter tabs ─────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 4, marginBottom: 20, flexWrap: 'wrap' }}>
        {FILTER_TABS.map(({ key, label }) => {
          const count = counts[key];
          const isActive = filter === key;
          const isAlert = key === 'awaiting_clarification' && count > 0;
          return (
            <button
              key={key}
              onClick={() => setFilter(key)}
              style={{
                padding: '5px 12px', borderRadius: 6, border: 'none',
                background: isActive
                  ? (isAlert ? '#B45309' : '#18345B')
                  : (isAlert ? '#FEF3C7' : '#F3F4F6'),
                color: isActive ? '#fff' : (isAlert ? '#92400E' : '#6B7280'),
                fontWeight: 600, fontSize: 12, cursor: 'pointer',
              }}
            >
              {label}
              {count > 0 && (
                <span style={{
                  marginLeft: 6,
                  background: isActive ? 'rgba(255,255,255,0.25)' : (isAlert ? '#FDE68A' : '#E5E7EB'),
                  color: isActive ? '#fff' : (isAlert ? '#92400E' : '#374151'),
                  borderRadius: 10, padding: '0 6px', fontSize: 11,
                }}>
                  {count}
                </span>
              )}
            </button>
          );
        })}
      </div>

      {/* ── Error ───────────────────────────────────────────────────────────── */}
      {error && (
        <div style={{
          padding: '10px 14px', borderRadius: 8, marginBottom: 16,
          background: '#FEF2F2', border: '1px solid #FECACA', color: '#DC2626', fontSize: 13,
        }}>
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 8 }} />
          {error}
        </div>
      )}

      {/* ── Loading ─────────────────────────────────────────────────────────── */}
      {loading && (
        <div style={{ textAlign: 'center', padding: '48px 0', color: '#9CA3AF' }}>
          <i className="fas fa-spinner fa-spin" style={{ fontSize: 24, display: 'block', marginBottom: 12 }} />
          Loading requests…
        </div>
      )}

      {/* ── Empty state ─────────────────────────────────────────────────────── */}
      {!loading && !error && filtered.length === 0 && (
        <div style={{
          textAlign: 'center', padding: '48px 24px',
          background: '#fff', borderRadius: 10,
          border: '1px solid #E5E7EB', color: '#9CA3AF',
        }}>
          <i className="fas fa-paper-plane" style={{ fontSize: 32, display: 'block', marginBottom: 12 }} />
          {filter === 'all'
            ? "You haven't submitted any approval requests yet."
            : `No ${filter.replace(/_/g, ' ')} requests.`}
        </div>
      )}

      {/* ── Request cards ───────────────────────────────────────────────────── */}
      {!loading && !error && filtered.length > 0 && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {filtered.map(req => {
            const link      = moduleLink(req.moduleCode, req.recordId);
            const needsInput = req.status === 'awaiting_clarification';
            const isResponding = respondId === req.id;

            return (
              <div
                key={req.id}
                style={{
                  background: needsInput ? '#FFFBEB' : '#fff',
                  borderRadius: 10,
                  border: `1px solid ${needsInput ? '#FDE68A' : '#E5E7EB'}`,
                  padding: '16px 20px',
                }}
              >
                {/* Top row */}
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12 }}>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                      <span style={{ fontWeight: 700, fontSize: 14, color: '#18345B' }}>
                        {req.templateName}
                      </span>
                      <WorkflowStatusBadge status={req.status as any} size="sm" />
                      {needsInput && (
                        <span style={{
                          fontSize: 11, fontWeight: 700, color: '#B45309',
                          background: '#FDE68A', borderRadius: 4, padding: '1px 7px',
                          display: 'flex', alignItems: 'center', gap: 4,
                        }}>
                          <i className="fas fa-bell" style={{ fontSize: 9 }} />
                          Needs your input
                        </span>
                      )}
                    </div>
                    <div style={{ fontSize: 12, color: '#9CA3AF', marginTop: 3 }}>
                      Submitted {relativeTime(req.submittedAt)} · {formatDate(req.submittedAt)}
                    </div>
                  </div>

                  {/* Actions */}
                  <div style={{ display: 'flex', gap: 8, flexShrink: 0, flexWrap: 'wrap' }}>
                    {link && (
                      <button
                        onClick={() => navigate(link)}
                        style={outlineBtn}
                      >
                        <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 10 }} />
                        View
                      </button>
                    )}
                    {needsInput && !isResponding && (
                      <button
                        onClick={() => { setRespondId(req.id); setRespondText(''); setRespondErr(null); }}
                        style={{
                          ...outlineBtn,
                          borderColor: '#FCA5A5',
                          background: '#FFFBEB',
                          color: '#B45309',
                        }}
                      >
                        <i className="fas fa-reply" style={{ fontSize: 10 }} />
                        Respond &amp; Resume
                      </button>
                    )}
                    {req.status === 'in_progress' && (
                      <button
                        onClick={() => { setWithdrawId(req.id); setWithdrawReason(''); }}
                        style={{
                          ...outlineBtn,
                          borderColor: '#FCA5A5',
                          background: '#FEF2F2',
                          color: '#DC2626',
                        }}
                      >
                        <i className="fas fa-rotate-left" style={{ fontSize: 10 }} />
                        Withdraw
                      </button>
                    )}
                  </div>
                </div>

                {/* Clarification message banner */}
                {needsInput && req.clarificationMessage && (
                  <div style={{
                    marginTop: 12,
                    padding: '10px 14px',
                    background: '#FEF3C7',
                    border: '1px solid #FDE68A',
                    borderRadius: 7,
                  }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: '#B45309', marginBottom: 4 }}>
                      <i className="fas fa-comment-dots" style={{ marginRight: 5 }} />
                      Message from approver
                      {req.clarificationFrom && (
                        <span style={{ fontWeight: 400, marginLeft: 4 }}>
                          ({req.clarificationFrom}
                          {req.clarificationAt && ` · ${relativeTime(req.clarificationAt)}`})
                        </span>
                      )}
                    </div>
                    <p style={{ fontSize: 13, color: '#78350F', margin: 0, lineHeight: 1.5 }}>
                      {req.clarificationMessage}
                    </p>
                  </div>
                )}

                {/* Respond & Resume inline panel */}
                {isResponding && (
                  <div style={{
                    marginTop: 12, padding: 14,
                    background: '#fff',
                    border: '1px solid #FDE68A',
                    borderRadius: 8,
                  }}>
                    <label style={labelStyle}>
                      Your response (optional — helps the approver continue)
                    </label>
                    <textarea
                      value={respondText}
                      onChange={e => setRespondText(e.target.value)}
                      placeholder="Provide any clarification or additional information requested…"
                      rows={3}
                      style={textareaStyle}
                      autoFocus
                    />
                    {respondErr && (
                      <p style={{ fontSize: 12, color: '#DC2626', margin: '6px 0 0' }}>{respondErr}</p>
                    )}
                    <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                      <button
                        onClick={handleResubmit}
                        disabled={responding}
                        style={{
                          padding: '6px 16px', borderRadius: 6, border: 'none',
                          background: '#B45309', color: '#fff',
                          fontWeight: 600, fontSize: 13,
                          cursor: responding ? 'not-allowed' : 'pointer',
                          opacity: responding ? 0.7 : 1,
                          display: 'flex', alignItems: 'center', gap: 6,
                        }}
                      >
                        <i className="fas fa-paper-plane" style={{ fontSize: 11 }} />
                        {responding ? 'Resuming…' : 'Resume Approval'}
                      </button>
                      <button
                        onClick={() => { setRespondId(null); setRespondText(''); setRespondErr(null); }}
                        disabled={responding}
                        style={{
                          ...outlineBtn,
                          fontSize: 13,
                        }}
                      >
                        Cancel
                      </button>
                    </div>
                  </div>
                )}

                {/* Progress / approver info chips */}
                <div style={{ marginTop: 12, display: 'flex', gap: 10, flexWrap: 'wrap' }}>
                  {req.status === 'in_progress' && (
                    <>
                      <InfoChip icon="fa-shoe-prints" label={`Step ${req.currentStep}`} />
                      {req.currentApproverName && (
                        <InfoChip icon="fa-user-check" label={`Awaiting: ${req.currentApproverName}`} />
                      )}
                      {req.currentTaskDue && (
                        <InfoChip
                          icon="fa-clock"
                          label={`Due: ${formatDate(req.currentTaskDue)}`}
                          color={new Date(req.currentTaskDue) < new Date() ? '#DC2626' : undefined}
                        />
                      )}
                    </>
                  )}
                  {req.completedAt && (
                    <InfoChip
                      icon={req.status === 'approved' ? 'fa-circle-check' : 'fa-circle-xmark'}
                      label={`${req.status === 'approved' ? 'Completed' : 'Closed'}: ${formatDate(req.completedAt)}`}
                      color={req.status === 'approved' ? '#16A34A' : '#DC2626'}
                    />
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* ── Withdraw modal ───────────────────────────────────────────────────── */}
      {withdrawId && (
        <div style={{
          position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          zIndex: 9999,
        }}>
          <div style={{
            background: '#fff', borderRadius: 12, padding: 28,
            width: 420, boxShadow: '0 20px 60px rgba(0,0,0,0.25)',
          }}>
            <h3 style={{ fontSize: 16, fontWeight: 700, color: '#18345B', margin: '0 0 8px' }}>
              Withdraw Request
            </h3>
            <p style={{ fontSize: 13, color: '#6B7280', marginBottom: 16 }}>
              This will cancel the approval process. You can resubmit after making changes.
            </p>
            <label style={{ fontSize: 12, fontWeight: 600, color: '#374151', display: 'block', marginBottom: 6 }}>
              Reason (optional)
            </label>
            <textarea
              value={withdrawReason}
              onChange={e => setWithdrawReason(e.target.value)}
              placeholder="Why are you withdrawing this request?"
              rows={3}
              style={textareaStyle}
            />
            <div style={{ display: 'flex', gap: 8, marginTop: 16, justifyContent: 'flex-end' }}>
              <button
                onClick={() => { setWithdrawId(null); setWithdrawReason(''); }}
                disabled={withdrawing}
                style={outlineBtn}
              >
                Cancel
              </button>
              <button
                onClick={handleWithdraw}
                disabled={withdrawing}
                style={{
                  padding: '7px 16px', borderRadius: 6, border: 'none',
                  background: '#DC2626', color: '#fff',
                  fontWeight: 600, fontSize: 13,
                  cursor: withdrawing ? 'not-allowed' : 'pointer',
                  opacity: withdrawing ? 0.7 : 1,
                }}
              >
                {withdrawing ? 'Withdrawing…' : 'Confirm Withdraw'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Small helpers ─────────────────────────────────────────────────────────────

function InfoChip({ icon, label, color }: { icon: string; label: string; color?: string }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      fontSize: 12, color: color ?? '#374151',
      background: '#F9FAFB', borderRadius: 5, padding: '3px 8px',
      border: '1px solid #E5E7EB',
    }}>
      <i className={`fas ${icon}`} style={{ fontSize: 10, color: color ?? '#6B7280' }} />
      {label}
    </span>
  );
}

const outlineBtn: React.CSSProperties = {
  padding: '5px 12px', borderRadius: 6,
  border: '1px solid #D1D5DB', background: '#fff',
  fontSize: 12, fontWeight: 500, color: '#374151',
  cursor: 'pointer',
  display: 'flex', alignItems: 'center', gap: 5,
};

const labelStyle: React.CSSProperties = {
  fontSize: 11, fontWeight: 600, color: '#6B7280',
  textTransform: 'uppercase', letterSpacing: '0.05em',
  display: 'block', marginBottom: 5,
};

const textareaStyle: React.CSSProperties = {
  width: '100%', padding: '8px 10px',
  border: '1px solid #D1D5DB', borderRadius: 6,
  fontSize: 13, resize: 'vertical', outline: 'none',
  fontFamily: 'inherit', boxSizing: 'border-box',
};
