/**
 * ApprovalQueue — Submitted expense reports visible to the current user.
 *
 * Access: requires expense_reports.view permission.
 * Scope (own / team / org) is determined entirely by RLS + target groups
 * configured in the Permission Matrix — no role checks in this component.
 *
 * Draft reports are excluded (they belong in MyReports).
 * All other statuses are shown; the user can filter by status chip.
 *
 * Actual approve/reject actions have moved to the Workflow Approver Inbox.
 * This screen is read-only historical view + navigation shortcut to the inbox.
 */

import { useState, useMemo } from 'react';
import { useNavigate }       from 'react-router-dom';
import { usePermissions }    from '../../../hooks/usePermissions';
import { useExpenseData }    from '../../../hooks/useExpenseData';
import { fmtAmount }         from '../../../utils/currency';
import StatusBadge           from '../../shared/StatusBadge';
import type { ExpenseReport, ExpenseStatus } from '../../../types';

// ─── Migration banner ─────────────────────────────────────────────────────────
// Actual approve / reject actions now live in the Workflow Approver Inbox.
// This component is kept for read-only historical viewing + inbox shortcut.

function WorkflowMigrationBanner() {
  const navigate = useNavigate();
  return (
    <div style={{
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      gap: 16, padding: '14px 18px', borderRadius: 10, marginBottom: 20,
      background: '#EFF6FF', border: '1px solid #BFDBFE',
    }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
        <i className="fas fa-diagram-next" style={{ color: '#2F77B5', fontSize: 16, marginTop: 2, flexShrink: 0 }} />
        <div>
          <div style={{ fontSize: 13, fontWeight: 700, color: '#18345B' }}>
            Approvals have moved to the Workflow Engine
          </div>
          <div style={{ fontSize: 12, color: '#6B7280', marginTop: 2 }}>
            New approval tasks are managed in the Approver Inbox. This screen shows read-only report history.
          </div>
        </div>
      </div>
      <button
        onClick={() => navigate('/admin/workflow/inbox')}
        style={{
          flexShrink: 0, padding: '7px 16px', borderRadius: 6, border: 'none',
          background: '#2F77B5', color: '#fff', fontSize: 12, fontWeight: 600,
          cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap',
        }}
      >
        <i className="fas fa-inbox" style={{ fontSize: 11 }} />
        Go to Approver Inbox
      </button>
    </div>
  );
}

// ─── Statuses excluded from this queue ───────────────────────────────────────
// Drafts belong in MyReports. Everything else (submitted, in-approval, etc.)
// is shown here. RLS controls which employees' reports the user can see.

// ─── Helpers ─────────────────────────────────────────────────────────────────

function reportTotal(report: ExpenseReport): number {
  return report.lineItems.reduce((sum, li) => sum + (li.convertedAmount ?? 0), 0);
}

function formatDate(iso?: string): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function ApprovalQueue() {
  const navigate                           = useNavigate();
  const { can }                            = usePermissions();
  const { reports, loading, error,
          refetch }                        = useExpenseData();

  const [statusFilter, setStatusFilter]    = useState<ExpenseStatus | 'all'>('all');

  // ── Access gate ───────────────────────────────────────────────────────────
  // expense_reports.view is the only requirement. Scope (which employees'
  // reports are visible) is enforced by RLS + Permission Matrix target groups.
  const canAccessQueue = can('expense_reports.view');
  const canAct         = can('expense_reports.edit');

  // ── Filter reports — exclude drafts, show everything else ─────────────────
  // Status chips populate dynamically from whatever statuses appear in the
  // data — no hardcoded workflow stage names.
  const queueReports = useMemo(() => {
    return reports.filter(r => r.status !== 'draft');
  }, [reports]);

  const filtered = useMemo(() => {
    if (statusFilter === 'all') return queueReports;
    return queueReports.filter(r => r.status === statusFilter);
  }, [queueReports, statusFilter]);

  // Status counts + unique statuses present in the data (drives filter chips)
  const { statusCounts, uniqueStatuses } = useMemo(() => {
    const counts: Partial<Record<ExpenseStatus, number>> = {};
    queueReports.forEach(r => { counts[r.status] = (counts[r.status] ?? 0) + 1; });
    const unique = Object.keys(counts) as ExpenseStatus[];
    return { statusCounts: counts, uniqueStatuses: unique };
  }, [queueReports]);

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
            Expense reports within your scope — use the Approver Inbox to take action.
          </p>
        </div>
        <button className="btn btn-ghost btn-sm" onClick={refetch} title="Refresh">
          <i className="fa-solid fa-rotate-right" />
        </button>
      </div>

      {/* ── Migration banner ─────────────────────────────────────────────── */}
      <WorkflowMigrationBanner />

      {/* ── Error banner ─────────────────────────────────────────────────── */}
      {error && (
        <div className="form-error-banner" style={{ marginBottom: 16 }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
          {error}
        </div>
      )}

      {/* ── KPI bar ──────────────────────────────────────────────────────── */}
      <div className="kpi-row" style={{ marginBottom: 20 }}>
        {uniqueStatuses.map(st => (
          <div key={st} className="kpi-card">
            <div className="kpi-value">{statusCounts[st] ?? 0}</div>
            <div className="kpi-label">
              <StatusBadge status={st} />
            </div>
          </div>
        ))}
        <div className="kpi-card">
          <div className="kpi-value">{queueReports.length}</div>
          <div className="kpi-label">Total</div>
        </div>
      </div>

      {/* ── Filter chips — driven by statuses present in data ────────────── */}
      {uniqueStatuses.length > 1 && (
        <div className="filter-chips" style={{ marginBottom: 16 }}>
          <button
            className={`filter-chip ${statusFilter === 'all' ? 'active' : ''}`}
            onClick={() => setStatusFilter('all')}
          >
            All <span className="chip-count">{queueReports.length}</span>
          </button>
          {uniqueStatuses.map(st => (
            <button
              key={st}
              className={`filter-chip ${statusFilter === st ? 'active' : ''}`}
              onClick={() => setStatusFilter(st)}
            >
              {st.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())}
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

            // Show the inbox shortcut if the user has edit permission.
            // The workflow engine enforces what actions are actually available.
            const canActOnThis = canAct;

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
                        className="btn btn-primary btn-sm"
                        onClick={() => navigate('/admin/workflow/inbox')}
                        title="Open Approver Inbox to act on this report"
                      >
                        <i className="fa-solid fa-inbox" /> Open Inbox
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

    </div>
  );
}
