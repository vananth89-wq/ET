/**
 * WorkflowMyRequests
 *
 * Employee-side screen showing all workflow instances submitted by the current
 * user. Powered by vw_wf_my_requests.
 *
 * Features:
 *   - Vertical filter sidebar: keyword, portlet, workflow, status, date ranges
 *   - Active filter chips + result count
 *   - Sort (newest / oldest / status)
 *   - Module icons per portlet
 *   - Clarification message banner with inline Respond & Resume panel
 *   - Withdraw action for in-progress requests
 *
 * Route: /workflow/my-requests
 */

import { useState, useEffect, useCallback, useMemo } from 'react';
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
  clarificationMessage:    string | null;
  clarificationFrom:       string | null;
  clarificationAt:         string | null;
}

type SortKey = 'newest' | 'oldest' | 'status';

// ─── Module display names & icons ─────────────────────────────────────────────

const MODULE_DISPLAY_NAMES: Record<string, string> = {
  profile_personal:          'Personal Information',
  profile_contact:           'Contact Information',
  profile_employment:        'Employment Information',
  profile_address:           'Address Information',
  profile_passport:          'Passport Details',
  profile_identification:    'Identification Details',
  profile_emergency_contact: 'Emergency Contact',
  expense_reports:           'Expense Report',
};

const MODULE_ICONS: Record<string, string> = {
  profile_personal:          'fa-user',
  profile_contact:           'fa-address-book',
  profile_employment:        'fa-briefcase',
  profile_address:           'fa-map-pin',
  profile_passport:          'fa-passport',
  profile_identification:    'fa-id-card',
  profile_emergency_contact: 'fa-phone',
  expense_reports:           'fa-receipt',
};

function requestTitle(moduleCode: string, templateName: string): string {
  return MODULE_DISPLAY_NAMES[moduleCode] ?? templateName;
}

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

function toDateOnly(iso: string) {
  return iso.slice(0, 10);
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function WorkflowMyRequests() {
  const { user }   = useAuth();
  const navigate   = useNavigate();

  const [requests,  setRequests]  = useState<MyRequest[]>([]);
  const [loading,   setLoading]   = useState(false);
  const [error,     setError]     = useState<string | null>(null);

  // ── Filter state ─────────────────────────────────────────────────────────────
  const [keyword,        setKeyword]        = useState('');
  const [filterPortlet,  setFilterPortlet]  = useState('');
  const [filterStatus,   setFilterStatus]   = useState('');
  const [submittedFrom,  setSubmittedFrom]  = useState('');
  const [submittedTo,    setSubmittedTo]    = useState('');
  const [completedFrom,  setCompletedFrom]  = useState('');
  const [completedTo,    setCompletedTo]    = useState('');
  const [sort,           setSort]           = useState<SortKey>('newest');

  // ── Withdraw state ───────────────────────────────────────────────────────────
  const [withdrawId,     setWithdrawId]     = useState<string | null>(null);
  const [withdrawReason, setWithdrawReason] = useState('');
  const [withdrawing,    setWithdrawing]    = useState(false);

  // ── Respond & Resume state ───────────────────────────────────────────────────
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

  // ── Filter + sort ────────────────────────────────────────────────────────────
  const filtered = useMemo(() => {
    let list = requests.filter(r => {
      if (keyword) {
        const kw = keyword.toLowerCase();
        const title = requestTitle(r.moduleCode, r.templateName).toLowerCase();
        if (!title.includes(kw) && !r.templateName.toLowerCase().includes(kw)) return false;
      }
      if (filterPortlet  && r.moduleCode !== filterPortlet) return false;
      if (filterStatus   && r.status    !== filterStatus)   return false;
      if (submittedFrom  && toDateOnly(r.submittedAt) < submittedFrom) return false;
      if (submittedTo    && toDateOnly(r.submittedAt) > submittedTo)   return false;
      if ((completedFrom || completedTo) && !r.completedAt) return false;
      if (completedFrom  && r.completedAt && toDateOnly(r.completedAt) < completedFrom) return false;
      if (completedTo    && r.completedAt && toDateOnly(r.completedAt) > completedTo)   return false;
      return true;
    });

    if (sort === 'oldest') {
      list = [...list].sort((a, b) => a.submittedAt.localeCompare(b.submittedAt));
    } else if (sort === 'status') {
      const ORDER: Record<string, number> = {
        awaiting_clarification: 0, in_progress: 1,
        approved: 2, rejected: 3, withdrawn: 4,
      };
      list = [...list].sort((a, b) => (ORDER[a.status] ?? 9) - (ORDER[b.status] ?? 9));
    }
    // 'newest' is already ordered by the DB query

    return list;
  }, [requests, keyword, filterPortlet, filterStatus,
      submittedFrom, submittedTo, completedFrom, completedTo, sort]);

  const needsInputCount = requests.filter(r => r.status === 'awaiting_clarification').length;

  // ── Active filter chips ───────────────────────────────────────────────────────
  const activeFilters: { label: string; clear: () => void }[] = [];
  if (keyword)        activeFilters.push({ label: `"${keyword}"`,                                        clear: () => setKeyword('') });
  if (filterPortlet)  activeFilters.push({ label: MODULE_DISPLAY_NAMES[filterPortlet] ?? filterPortlet, clear: () => setFilterPortlet('') });
  if (filterStatus)   activeFilters.push({ label: filterStatus.replace(/_/g, ' '),                      clear: () => setFilterStatus('') });
  if (submittedFrom || submittedTo) activeFilters.push({ label: `Submitted: ${submittedFrom || '…'} → ${submittedTo || '…'}`, clear: () => { setSubmittedFrom(''); setSubmittedTo(''); } });
  if (completedFrom || completedTo) activeFilters.push({ label: `Completed: ${completedFrom || '…'} → ${completedTo || '…'}`, clear: () => { setCompletedFrom(''); setCompletedTo(''); } });

  function clearAll() {
    setKeyword(''); setFilterPortlet('');
    setFilterStatus(''); setSubmittedFrom(''); setSubmittedTo('');
    setCompletedFrom(''); setCompletedTo('');
  }

  // ── Withdraw ──────────────────────────────────────────────────────────────────
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

  // ── Respond & Resume ──────────────────────────────────────────────────────────
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

  return (
    <div style={{ padding: '28px 36px', maxWidth: 1280, margin: '0 auto' }}>

      {/* ── Header ──────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: '#18345B', margin: 0 }}>
            My Requests
          </h1>
          <p style={{ fontSize: 13, color: '#6B7280', marginTop: 4 }}>
            Approval requests you have submitted
          </p>
        </div>
        <button onClick={load} style={outlineBtn}>
          <i className="fas fa-arrows-rotate" style={{ fontSize: 12 }} />
          Refresh
        </button>
      </div>

      {/* ── Attention banner ─────────────────────────────────────────────────── */}
      {needsInputCount > 0 && (
        <div
          onClick={() => navigate('/workflow/inbox?tab=sent_back')}
          style={{
            display: 'flex', alignItems: 'center', gap: 10,
            padding: '10px 14px', borderRadius: 8, marginBottom: 20,
            background: '#FEF3C7', border: '1px solid #FDE68A', cursor: 'pointer',
          }}
        >
          <i className="fas fa-bell" style={{ color: '#B45309', fontSize: 13 }} />
          <span style={{ fontSize: 13, fontWeight: 600, color: '#92400E' }}>
            {needsInputCount} request{needsInputCount !== 1 ? 's need' : ' needs'} your input
          </span>
          <span style={{ fontSize: 12, color: '#B45309', marginLeft: 4 }}>
            — an approver has returned a request asking for clarification
          </span>
          <span style={{ marginLeft: 'auto', fontSize: 11, color: '#B45309', fontWeight: 600 }}>
            View →
          </span>
        </div>
      )}

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

      {/* ── Layout: sidebar + list ───────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 20, alignItems: 'flex-start' }}>

        {/* ── Filter sidebar ─────────────────────────────────────────────────── */}
        <div style={{
          width: 284, flexShrink: 0,
          background: '#fff', border: '1px solid #E5E7EB',
          borderRadius: 12, padding: '16px 18px',
          position: 'sticky', top: 24,
        }}>
          {/* Sidebar header */}
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
            <span style={{ fontSize: 13, fontWeight: 700, color: '#18345B', display: 'flex', alignItems: 'center', gap: 7 }}>
              <i className="fas fa-sliders" style={{ fontSize: 13, color: '#6B7280' }} />
              Filters
            </span>
            {activeFilters.length > 0 && (
              <button
                onClick={clearAll}
                style={{ background: 'none', border: 'none', fontSize: 11, color: '#3B82F6', cursor: 'pointer', padding: 0, fontWeight: 600 }}
              >
                Clear all
              </button>
            )}
          </div>

          {/* Keyword */}
          <div style={filterGroupStyle}>
            <label style={filterLabelStyle}>Search</label>
            <div style={{
              display: 'flex', alignItems: 'center', gap: 8,
              background: '#F9FAFB', border: '1px solid #E5E7EB',
              borderRadius: 7, padding: '0px 9px', height: 31, boxSizing: 'border-box', overflow: 'hidden',
              transition: 'border-color 0.15s',
            }}>
              <i className="fas fa-magnifying-glass" style={{ fontSize: 12, color: '#9CA3AF', flexShrink: 0 }} />
              <input
                value={keyword}
                onChange={e => setKeyword(e.target.value)}
                placeholder="Search requests…"
                style={{ border: 'none', background: 'none', fontSize: 13, outline: 'none', width: '100%', color: '#374151', padding: 0, height: '100%' }}
              />
            </div>
          </div>

          <hr style={hrStyle} />

          {/* Portlet */}
          <div style={filterGroupStyle}>
            <label style={filterLabelStyle}>Portlet</label>
            <select
              value={filterPortlet}
              onChange={e => setFilterPortlet(e.target.value)}
              style={{ ...selectStyle, ...(filterPortlet ? activeSelectStyle : {}) }}
            >
              <option value="">All portlets</option>
              {Object.entries(MODULE_DISPLAY_NAMES).map(([code, name]) => (
                <option key={code} value={code}>{name}</option>
              ))}
            </select>
          </div>

          {/* Status */}
          <div style={filterGroupStyle}>
            <label style={filterLabelStyle}>Status</label>
            <select
              value={filterStatus}
              onChange={e => setFilterStatus(e.target.value)}
              style={{ ...selectStyle, ...(filterStatus ? activeSelectStyle : {}) }}
            >
              <option value="">All statuses</option>
              <option value="in_progress">In Progress</option>
              <option value="awaiting_clarification">Needs Your Input</option>
              <option value="approved">Approved</option>
              <option value="rejected">Rejected</option>
              <option value="withdrawn">Withdrawn</option>
            </select>
          </div>

          <hr style={hrStyle} />

          {/* Submitted date */}
          <div style={filterGroupStyle}>
            <label style={filterLabelStyle}>Submitted date</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{ flex: 1 }}>
                <span style={dateRangeLabelStyle}>From</span>
                <input type="date" value={submittedFrom} onChange={e => setSubmittedFrom(e.target.value)} style={dateInputStyle} />
              </div>
              <div style={{ flex: 1 }}>
                <span style={dateRangeLabelStyle}>To</span>
                <input type="date" value={submittedTo} onChange={e => setSubmittedTo(e.target.value)} style={dateInputStyle} />
              </div>
            </div>
          </div>

          <hr style={hrStyle} />

          {/* Completed date */}
          <div style={{ ...filterGroupStyle, marginBottom: 0 }}>
            <label style={filterLabelStyle}>Completed date</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{ flex: 1 }}>
                <span style={dateRangeLabelStyle}>From</span>
                <input type="date" value={completedFrom} onChange={e => setCompletedFrom(e.target.value)} style={dateInputStyle} />
              </div>
              <div style={{ flex: 1 }}>
                <span style={dateRangeLabelStyle}>To</span>
                <input type="date" value={completedTo} onChange={e => setCompletedTo(e.target.value)} style={dateInputStyle} />
              </div>
            </div>
          </div>
        </div>

        {/* ── Main list ──────────────────────────────────────────────────────── */}
        <div style={{ flex: 1, minWidth: 0 }}>

          {/* Result bar */}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
              <span style={{ fontSize: 12, color: '#6B7280' }}>
                {filtered.length} result{filtered.length !== 1 ? 's' : ''}
                {activeFilters.length > 0 && ` · ${activeFilters.length} filter${activeFilters.length !== 1 ? 's' : ''} active`}
              </span>
              {activeFilters.map((f, i) => (
                <span
                  key={i}
                  style={{
                    display: 'inline-flex', alignItems: 'center', gap: 5,
                    fontSize: 11, fontWeight: 500,
                    background: '#EFF6FF', color: '#1D4ED8',
                    borderRadius: 99, padding: '2px 8px',
                  }}
                >
                  {f.label}
                  <button
                    onClick={f.clear}
                    style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 0, color: '#60A5FA', fontSize: 10, lineHeight: 1 }}
                    aria-label="Remove filter"
                  >
                    ✕
                  </button>
                </span>
              ))}
            </div>
            <select
              value={sort}
              onChange={e => setSort(e.target.value as SortKey)}
              style={{ ...selectStyle, width: 'auto', minWidth: 130 }}
            >
              <option value="newest">Newest first</option>
              <option value="oldest">Oldest first</option>
              <option value="status">By status</option>
            </select>
          </div>

          {/* Loading */}
          {loading && (
            <div style={{ textAlign: 'center', padding: '48px 0', color: '#9CA3AF' }}>
              <i className="fas fa-spinner fa-spin" style={{ fontSize: 24, display: 'block', marginBottom: 12 }} />
              Loading requests…
            </div>
          )}

          {/* Empty */}
          {!loading && !error && filtered.length === 0 && (
            <div style={{
              textAlign: 'center', padding: '48px 24px',
              background: '#fff', borderRadius: 10,
              border: '1px solid #E5E7EB', color: '#9CA3AF',
            }}>
              <i className="fas fa-filter-circle-xmark" style={{ fontSize: 28, display: 'block', marginBottom: 10 }} />
              {requests.length === 0
                ? "You haven't submitted any approval requests yet."
                : 'No requests match your filters.'}
            </div>
          )}

          {/* Cards */}
          {!loading && !error && filtered.length > 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {filtered.map(req => {
                const link        = moduleLink(req.moduleCode, req.recordId);
                const needsInput  = req.status === 'awaiting_clarification';
                const isActive    = req.status === 'in_progress';
                const isResponding = respondId === req.id;
                const icon        = MODULE_ICONS[req.moduleCode] ?? 'fa-file-lines';
                const iconBg      = isActive    ? '#EFF6FF'
                                  : needsInput  ? '#FFFBEB'
                                  : req.status === 'approved'  ? '#F0FDF4'
                                  : req.status === 'rejected'  ? '#FEF2F2'
                                  : '#F9FAFB';
                const iconColor   = isActive    ? '#1D4ED8'
                                  : needsInput  ? '#B45309'
                                  : req.status === 'approved'  ? '#16A34A'
                                  : req.status === 'rejected'  ? '#DC2626'
                                  : '#6B7280';

                return (
                  <div
                    key={req.id}
                    style={{
                      background: needsInput ? '#FFFBEB' : '#fff',
                      borderRadius: 10,
                      border: `1px solid ${needsInput ? '#FDE68A' : '#E5E7EB'}`,
                      borderLeft: isActive ? '3px solid #3B82F6' : undefined,
                      padding: '14px 18px',
                      display: 'flex', alignItems: 'flex-start', gap: 12,
                    }}
                  >
                    {/* Module icon */}
                    <div style={{
                      width: 34, height: 34, borderRadius: 8, flexShrink: 0,
                      background: iconBg, display: 'flex', alignItems: 'center', justifyContent: 'center',
                    }}>
                      <i className={`fas ${icon}`} style={{ fontSize: 14, color: iconColor }} />
                    </div>

                    <div style={{ flex: 1, minWidth: 0 }}>
                      {/* Title row */}
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12 }}>
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                            <span style={{ fontWeight: 700, fontSize: 14, color: '#18345B' }}>
                              {requestTitle(req.moduleCode, req.templateName)}
                            </span>
                            <WorkflowStatusBadge status={req.status as any} size="sm" />
                            {needsInput && (
                              <span style={{
                                fontSize: 11, fontWeight: 700, color: '#B45309',
                                background: '#FDE68A', borderRadius: 4, padding: '1px 7px',
                                display: 'inline-flex', alignItems: 'center', gap: 4,
                              }}>
                                <i className="fas fa-bell" style={{ fontSize: 9 }} />
                                Needs your input
                              </span>
                            )}
                          </div>
                          <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 3 }}>
                            Submitted {relativeTime(req.submittedAt)} · {formatDate(req.submittedAt)}
                            <span style={{ marginLeft: 8, color: '#D1D5DB' }}>·</span>
                            <span style={{ marginLeft: 8, color: '#9CA3AF' }}>{req.templateName}</span>
                          </div>
                        </div>

                        {/* Actions */}
                        <div style={{ display: 'flex', gap: 6, flexShrink: 0, flexWrap: 'wrap' }}>
                          {link && (
                            <button onClick={() => navigate(link)} style={outlineBtn}>
                              <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 10 }} />
                              View
                            </button>
                          )}
                          {needsInput && !isResponding && (
                            <button
                              onClick={() => { setRespondId(req.id); setRespondText(''); setRespondErr(null); }}
                              style={{ ...outlineBtn, borderColor: '#FCA5A5', background: '#FFFBEB', color: '#B45309' }}
                            >
                              <i className="fas fa-reply" style={{ fontSize: 10 }} />
                              Respond &amp; Resume
                            </button>
                          )}
                          {req.status === 'in_progress' && (
                            <button
                              onClick={() => { setWithdrawId(req.id); setWithdrawReason(''); }}
                              style={{ ...outlineBtn, borderColor: '#FCA5A5', background: '#FEF2F2', color: '#DC2626' }}
                            >
                              <i className="fas fa-rotate-left" style={{ fontSize: 10 }} />
                              Withdraw
                            </button>
                          )}
                        </div>
                      </div>

                      {/* Clarification banner */}
                      {needsInput && req.clarificationMessage && (
                        <div style={{
                          marginTop: 10, padding: '10px 14px',
                          background: '#FEF3C7', border: '1px solid #FDE68A', borderRadius: 7,
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
                          marginTop: 10, padding: 14,
                          background: '#fff', border: '1px solid #FDE68A', borderRadius: 8,
                        }}>
                          <label style={labelStyle}>
                            Your response (optional)
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
                              style={outlineBtn}
                            >
                              Cancel
                            </button>
                          </div>
                        </div>
                      )}

                      {/* Progress / approver chips */}
                      <div style={{ marginTop: 10, display: 'flex', gap: 8, flexWrap: 'wrap' }}>
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
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>

      {/* ── Withdraw modal ───────────────────────────────────────────────────── */}
      {withdrawId && (
        <div style={{
          position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 9999,
        }}>
          <div style={{ background: '#fff', borderRadius: 12, padding: 28, width: 420 }}>
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

// ── Style constants ───────────────────────────────────────────────────────────

const outlineBtn: React.CSSProperties = {
  padding: '5px 12px', borderRadius: 6,
  border: '1px solid #D1D5DB', background: '#fff',
  fontSize: 12, fontWeight: 500, color: '#374151',
  cursor: 'pointer',
  display: 'flex', alignItems: 'center', gap: 5,
};

const filterGroupStyle: React.CSSProperties = {
  marginBottom: 8,
};

const filterLabelStyle: React.CSSProperties = {
  fontSize: 10, fontWeight: 700, color: '#9CA3AF',
  textTransform: 'uppercase', letterSpacing: '0.07em',
  display: 'block', marginBottom: 6,
};

const dateRangeLabelStyle: React.CSSProperties = {
  fontSize: 10, color: '#9CA3AF', fontWeight: 600,
  display: 'block', marginBottom: 3,
};

const selectStyle: React.CSSProperties = {
  width: '100%', fontSize: 13, padding: '0px 9px',
  height: 31, boxSizing: 'border-box',
  borderRadius: 7, border: '1px solid #E5E7EB',
  background: '#F9FAFB', color: '#6B7280',
  cursor: 'pointer', appearance: 'auto',
};

const activeSelectStyle: React.CSSProperties = {
  borderColor: '#3B82F6', color: '#1D4ED8', background: '#EFF6FF',
  fontWeight: 500,
};

const dateInputStyle: React.CSSProperties = {
  width: '100%', fontSize: 11, padding: '4px 6px',
  borderRadius: 6, border: '1px solid #E5E7EB',
  background: '#F9FAFB', color: '#374151',
  boxSizing: 'border-box', display: 'block',
};

const hrStyle: React.CSSProperties = {
  border: 'none', borderTop: '1px solid #F3F4F6', margin: '8px 0',
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
