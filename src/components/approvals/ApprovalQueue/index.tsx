/**
 * ApprovalQueue — Pending expense approvals for Manager / DeptHead / Finance / Admin
 *
 * What it shows depends on the caller's permissions:
 *
 *   Manager / DeptHead (expense.view_team)
 *     → reports with status = 'submitted' within their scope
 *     → Actions: Approve (→ manager_approved) | Reject
 *
 *   Finance / Admin (expense.view_org)
 *     → reports with status = 'manager_approved'  (and 'submitted' for Admin skip)
 *     → Actions: Approve (→ approved) | Reject
 *
 * The component uses useExpenseData which already fetches only the reports
 * the current user can see via RLS — no client-side permission filtering needed.
 *
 * Action errors surface as an inline error banner so the user knows if the
 * server rejected the action (e.g. out-of-scope employee, wrong state).
 */

import { useState, useMemo } from 'react';
import { useNavigate }       from 'react-router-dom';
import { usePermissions }    from '../../../hooks/usePermissions';
import { useExpenseData }    from '../../../hooks/useExpenseData';
import { fmtAmount }         from '../../../utils/currency';
import StatusBadge           from '../../shared/StatusBadge';
import type { ExpenseReport, ExpenseStatus } from '../../../types';

// ─── Types ────────────────────────────────────────────────────────────────────

type ActionType = 'approve' | 'reject';

interface ActionModal {
  report:     ExpenseReport;
  actionType: ActionType;
}

// ─── Status pills the queue shows for each permission level ──────────────────

const MANAGER_STATUSES: ExpenseStatus[]  = ['submitted'];
const FINANCE_STATUSES:  ExpenseStatus[] = ['manager_approved'];
const ADMIN_STATUSES:    ExpenseStatus[] = ['submitted', 'manager_approved'];

// ─── Helpers ─────────────────────────────────────────────────────────────────

function reportTotal(report: ExpenseReport): number {
  return report.lineItems.reduce((sum, li) => sum + (li.convertedAmount ?? 0), 0);
}

function formatDate(iso?: string): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

// ─── Approve / Reject modal ───────────────────────────────────────────────────

interface ModalProps {
  modal:      ActionModal;
  onClose:    () => void;
  onConfirm:  (notes: string) => Promise<void>;
}

function ActionConfirmModal({ modal, onClose, onConfirm }: ModalProps) {
  const [notes,    setNotes]    = useState('');
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);

  const isReject  = modal.actionType === 'reject';
  const title     = isReject ? 'Reject Expense Report' : 'Approve Expense Report';
  const btnClass  = isReject ? 'btn-danger' : 'btn-primary';
  const btnLabel  = isReject ? 'Confirm Reject' : 'Confirm Approve';
  const notesLabel = isReject ? 'Rejection reason (required)' : 'Notes (optional)';

  async function handleConfirm() {
    if (isReject && !notes.trim()) {
      setError('Please enter a rejection reason.');
      return;
    }
    setLoading(true);
    setError(null);
    try {
      await onConfirm(notes.trim());
      onClose();
    } catch (err: any) {
      setError(err.message ?? 'Action failed. Please try again.');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal-box" onClick={e => e.stopPropagation()} style={{ maxWidth: 480 }}>
        <div className="modal-header">
          <h3>{title}</h3>
          <button className="modal-close" onClick={onClose} disabled={loading}>✕</button>
        </div>

        <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {/* Report summary */}
          <div style={{ background: 'var(--surface)', borderRadius: 8, padding: '12px 16px' }}>
            <div style={{ fontWeight: 600, marginBottom: 4 }}>{modal.report.name}</div>
            <div style={{ fontSize: 13, color: 'var(--text-secondary)' }}>
              {modal.report.employeeName ?? modal.report.employeeId}
              &nbsp;·&nbsp;
              <StatusBadge status={modal.report.status} />
              &nbsp;·&nbsp;
              {fmtAmount(reportTotal(modal.report), modal.report.baseCurrencyCode)}
            </div>
          </div>

          {/* Notes / reason */}
          <div>
            <label className="field-label">{notesLabel}</label>
            <textarea
              className="form-input"
              rows={3}
              value={notes}
              onChange={e => setNotes(e.target.value)}
              placeholder={isReject ? 'Explain why this report is being rejected…' : 'Any comments for the audit log…'}
              autoFocus
            />
          </div>

          {error && (
            <div className="form-error-banner">{error}</div>
          )}
        </div>

        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onClose} disabled={loading}>Cancel</button>
          <button className={`btn ${btnClass}`} onClick={handleConfirm} disabled={loading}>
            {loading ? <span className="spinner-sm" /> : null}
            {btnLabel}
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function ApprovalQueue() {
  const navigate                           = useNavigate();
  const { can, canAny }                    = usePermissions();
  const { reports, loading, error,
          approveReport, rejectReport,
          refetch }                        = useExpenseData();

  const [modal,       setModal]            = useState<ActionModal | null>(null);
  const [actionError, setActionError]      = useState<string | null>(null);
  const [statusFilter, setStatusFilter]    = useState<ExpenseStatus | 'all'>('all');

  // ── Determine which statuses to surface for this user ────────────────────
  const isAdmin      = can('security.manage_roles');   // admin has this
  const canApprove   = can('expense.edit_approval');    // all approvers share this permission
  const isFinance    = can('expense.view_org');
  // isManager = anyone who approves at the "submitted" stage:
  //   expense.view_direct → immediate direct reports (Manager role)
  //   expense.view_team   → full org subtree (DeptHead and above)
  const isManager    = canAny(['expense.view_direct', 'expense.view_team']);

  const queueStatuses: ExpenseStatus[] = isAdmin
    ? ADMIN_STATUSES
    : isFinance
    ? FINANCE_STATUSES
    : MANAGER_STATUSES;

  const canAccessQueue = canApprove && (isAdmin || isFinance || isManager);

  // ── Filter reports to approval queue ─────────────────────────────────────
  //
  // RLS already limits what the user can see. We just filter by the statuses
  // relevant to this approver's role.
  const queueReports = useMemo(() => {
    return reports.filter(r => queueStatuses.includes(r.status));
  }, [reports, queueStatuses]);

  const filtered = useMemo(() => {
    if (statusFilter === 'all') return queueReports;
    return queueReports.filter(r => r.status === statusFilter);
  }, [queueReports, statusFilter]);

  // Status counts for filter chips
  const statusCounts = useMemo(() => {
    const counts: Partial<Record<ExpenseStatus, number>> = {};
    queueReports.forEach(r => { counts[r.status] = (counts[r.status] ?? 0) + 1; });
    return counts;
  }, [queueReports]);

  // ── Action handlers ───────────────────────────────────────────────────────

  function openAction(report: ExpenseReport, actionType: ActionType) {
    setActionError(null);
    setModal({ report, actionType });
  }

  async function handleConfirm(notes: string) {
    if (!modal) return;
    if (modal.actionType === 'approve') {
      await approveReport(modal.report.id, notes || undefined);
    } else {
      await rejectReport(modal.report.id, notes);
    }
    setModal(null);
    refetch();
  }

  // ── Guard ─────────────────────────────────────────────────────────────────

  if (!canAccessQueue) {
    return (
      <div className="page-container">
        <div className="empty-state">
          <i className="fa-solid fa-ban empty-state-icon" />
          <div className="empty-state-title">Access Denied</div>
          <div className="empty-state-subtitle">You do not have permission to view the approval queue.</div>
        </div>
      </div>
    );
  }

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className="page-container">
      {/* ── Page header ──────────────────────────────────────────────────── */}
      <div className="page-header">
        <div>
          <h1 className="page-title">
            <i className="fa-solid fa-clock-rotate-left" style={{ marginRight: 10 }} />
            Approval Queue
          </h1>
          <p className="page-subtitle">
            {isAdmin
              ? 'All pending expenses — you can approve or reject at any stage.'
              : isFinance
              ? 'Manager-approved expenses awaiting final Finance sign-off.'
              : 'Submitted expenses from your team awaiting your approval.'}
          </p>
        </div>
        <button className="btn btn-ghost btn-sm" onClick={refetch} title="Refresh">
          <i className="fa-solid fa-rotate-right" />
        </button>
      </div>

      {/* ── Error banner ─────────────────────────────────────────────────── */}
      {(error || actionError) && (
        <div className="form-error-banner" style={{ marginBottom: 16 }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
          {error ?? actionError}
        </div>
      )}

      {/* ── KPI bar ──────────────────────────────────────────────────────── */}
      <div className="kpi-row" style={{ marginBottom: 20 }}>
        {queueStatuses.map(st => (
          <div key={st} className="kpi-card">
            <div className="kpi-value">{statusCounts[st] ?? 0}</div>
            <div className="kpi-label">
              <StatusBadge status={st} />
            </div>
          </div>
        ))}
        <div className="kpi-card">
          <div className="kpi-value">{queueReports.length}</div>
          <div className="kpi-label">Total pending</div>
        </div>
      </div>

      {/* ── Filter chips ─────────────────────────────────────────────────── */}
      {queueStatuses.length > 1 && (
        <div className="filter-chips" style={{ marginBottom: 16 }}>
          <button
            className={`filter-chip ${statusFilter === 'all' ? 'active' : ''}`}
            onClick={() => setStatusFilter('all')}
          >
            All <span className="chip-count">{queueReports.length}</span>
          </button>
          {queueStatuses.map(st => (
            <button
              key={st}
              className={`filter-chip ${statusFilter === st ? 'active' : ''}`}
              onClick={() => setStatusFilter(st)}
            >
              {st === 'manager_approved' ? 'Manager Approved' : st.charAt(0).toUpperCase() + st.slice(1)}
              <span className="chip-count">{statusCounts[st] ?? 0}</span>
            </button>
          ))}
        </div>
      )}

      {/* ── Content ──────────────────────────────────────────────────────── */}
      {loading ? (
        <div className="loading-state">
          <span className="spinner" /> Loading approvals…
        </div>
      ) : filtered.length === 0 ? (
        <div className="empty-state">
          <i className="fa-solid fa-check-circle empty-state-icon" style={{ color: 'var(--success)' }} />
          <div className="empty-state-title">All clear!</div>
          <div className="empty-state-subtitle">No expenses are waiting for your approval.</div>
        </div>
      ) : (
        <div className="approval-queue-list">
          {filtered.map(report => {
            const total       = reportTotal(report);
            const itemCount   = report.lineItems.length;
            const submittedOn = formatDate(report.submittedAt);

            // What actions are available for this report + this approver combo?
            // isManager covers both view_direct (Manager) and view_team (DeptHead+)
            const canActOnThis =
              canApprove && (
                isAdmin ||
                (isFinance  && report.status === 'manager_approved') ||
                (isManager  && report.status === 'submitted')
              );

            return (
              <div key={report.id} className="approval-card">
                {/* ── Card header ─────────────────────────────────────── */}
                <div className="approval-card-header">
                  <div className="approval-card-title">
                    <span
                      className="approval-report-name"
                      onClick={() => navigate(`/expense/report/${report.id}`)}
                      title="View report details"
                    >
                      {report.name}
                    </span>
                    <StatusBadge status={report.status} />
                  </div>
                  <div className="approval-card-actions">
                    {canActOnThis && (
                      <button
                        className="btn btn-success btn-sm"
                        onClick={() => openAction(report, 'approve')}
                      >
                        <i className="fa-solid fa-check" /> Approve
                      </button>
                    )}
                    {canActOnThis && (
                    <button
                      className="btn btn-danger btn-sm"
                      onClick={() => openAction(report, 'reject')}
                    >
                      <i className="fa-solid fa-xmark" /> Reject
                    </button>
                    )}
                    <button
                      className="btn btn-ghost btn-sm"
                      onClick={() => navigate(`/expense/report/${report.id}`)}
                      title="View full report"
                    >
                      <i className="fa-solid fa-eye" />
                    </button>
                  </div>
                </div>

                {/* ── Card body ───────────────────────────────────────── */}
                <div className="approval-card-meta">
                  <span>
                    <i className="fa-solid fa-user" style={{ marginRight: 4 }} />
                    {report.employeeName ?? report.employeeId}
                  </span>
                  <span>
                    <i className="fa-solid fa-calendar" style={{ marginRight: 4 }} />
                    Submitted {submittedOn}
                  </span>
                  <span>
                    <i className="fa-solid fa-receipt" style={{ marginRight: 4 }} />
                    {itemCount} item{itemCount !== 1 ? 's' : ''}
                  </span>
                  <span className="approval-total">
                    <i className="fa-solid fa-coins" style={{ marginRight: 4 }} />
                    {fmtAmount(total, report.baseCurrencyCode)}
                  </span>
                </div>

                {/* Show rejection reason if already rejected (shouldn't appear in
                    queue, but guard just in case) */}
                {report.rejectionReason && (
                  <div className="approval-rejection-note">
                    <i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />
                    {report.rejectionReason}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* ── Action modal ─────────────────────────────────────────────────── */}
      {modal && (
        <ActionConfirmModal
          modal={modal}
          onClose={() => setModal(null)}
          onConfirm={handleConfirm}
        />
      )}
    </div>
  );
}
