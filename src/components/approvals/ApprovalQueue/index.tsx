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

import { useState, useMemo }    from 'react';
import { useNavigate }           from 'react-router-dom';
import { usePermissions }        from '../../../hooks/usePermissions';
import { useExpenseData }        from '../../../hooks/useExpenseData';
import { fmtAmount }             from '../../../utils/currency';
import StatusBadge               from '../../shared/StatusBadge';
import type { ExpenseReport, ExpenseStatus } from '../../../types';

// ─── Constants ────────────────────────────────────────────────────────────────

const PAGE_SIZE = 15;

// Statuses where a report is still pending action (not terminal)
const TERMINAL_STATUSES: ExpenseStatus[] = ['approved', 'rejected', 'cancelled'];

// ─── Helpers ──────────────────────────────────────────────────────────────────

function getInitials(name: string): string {
  return name
    .split(' ')
    .slice(0, 2)
    .map(p => p[0]?.toUpperCase() ?? '')
    .join('');
}

const AVATAR_COLORS = ['aq-av-blue', 'aq-av-teal', 'aq-av-amber', 'aq-av-purple', 'aq-av-coral'];
function avatarColor(name: string): string {
  const idx = (name.charCodeAt(0) || 0) % AVATAR_COLORS.length;
  return AVATAR_COLORS[idx];
}

function isActionable(status: ExpenseStatus): boolean {
  return !TERMINAL_STATUSES.includes(status);
}

function reportTotal(report: ExpenseReport): number {
  return report.lineItems.reduce((sum, li) => sum + (li.convertedAmount ?? 0), 0);
}

function formatDate(iso?: string): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

// ─── Migration banner ─────────────────────────────────────────────────────────

function WorkflowMigrationBanner() {
  const navigate = useNavigate();
  return (
    <div className="aq-banner">
      <div className="aq-banner-body">
        <i className="fa-solid fa-diagram-next aq-banner-icon" aria-hidden="true" />
        <div>
          <div className="aq-banner-title">Approvals have moved to the Workflow Engine</div>
          <div className="aq-banner-sub">
            New approval tasks are managed in the Approver Inbox. This screen shows read-only report history.
          </div>
        </div>
      </div>
      <button className="btn btn-primary btn-sm" onClick={() => navigate('/admin/workflow/inbox')}>
        <i className="fa-solid fa-inbox" /> Go to Approver Inbox
      </button>
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function ApprovalQueue() {
  const navigate                        = useNavigate();
  const { can }                         = usePermissions();
  const { reports, loading, error,
          refetch }                     = useExpenseData();

  const [statusFilter, setStatusFilter] = useState<ExpenseStatus | 'all'>('all');
  const [searchTerm, setSearchTerm]     = useState('');
  const [page, setPage]                 = useState(1);

  // ── Access gate ────────────────────────────────────────────────────────────
  const canAccessQueue = can('expense_reports.view');
  const canAct         = can('expense_reports.edit');

  // ── Base set — exclude drafts ───────────────────────────────────────────────
  const queueReports = useMemo(
    () => reports.filter(r => r.status !== 'draft'),
    [reports],
  );

  // ── KPI counts ─────────────────────────────────────────────────────────────
  const { statusCounts, uniqueStatuses, grandTotal } = useMemo(() => {
    const counts: Partial<Record<ExpenseStatus, number>> = {};
    let total = 0;
    queueReports.forEach(r => {
      counts[r.status] = (counts[r.status] ?? 0) + 1;
      total += reportTotal(r);
    });
    const unique = Object.keys(counts) as ExpenseStatus[];
    return { statusCounts: counts, uniqueStatuses: unique, grandTotal: total };
  }, [queueReports]);

  // ── Filtered + searched + paginated ────────────────────────────────────────
  const filtered = useMemo(() => {
    let rows = statusFilter === 'all'
      ? queueReports
      : queueReports.filter(r => r.status === statusFilter);

    const q = searchTerm.trim().toLowerCase();
    if (q) {
      rows = rows.filter(r =>
        r.name.toLowerCase().includes(q) ||
        (r.employeeName ?? r.employeeId ?? '').toLowerCase().includes(q),
      );
    }
    return rows;
  }, [queueReports, statusFilter, searchTerm]);

  const totalPages  = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, totalPages);
  const pageRows    = filtered.slice((currentPage - 1) * PAGE_SIZE, currentPage * PAGE_SIZE);

  function changeFilter(f: ExpenseStatus | 'all') {
    setStatusFilter(f);
    setPage(1);
  }

  // ── Guard ──────────────────────────────────────────────────────────────────
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

  // ── Render ─────────────────────────────────────────────────────────────────
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
        <div className="aq-header-actions">
          <button className="btn btn-ghost btn-sm" onClick={refetch} title="Refresh">
            <i className="fa-solid fa-rotate-right" /> Refresh
          </button>
          <button
            className="btn btn-primary btn-sm"
            onClick={() => navigate('/admin/workflow/inbox')}
          >
            <i className="fa-solid fa-inbox" /> Open Approver Inbox
          </button>
        </div>
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

      {/* ── KPI cards ────────────────────────────────────────────────────── */}
      <div className="aq-kpi-row">
        {uniqueStatuses.map(st => {
          const count = statusCounts[st] ?? 0;
          const pct   = queueReports.length ? Math.round((count / queueReports.length) * 100) : 0;
          return (
            <div key={st} className="aq-kpi-card" onClick={() => changeFilter(st)}>
              <div className="aq-kpi-value">{count}</div>
              <div className="aq-kpi-label"><StatusBadge status={st} /></div>
              <div className="aq-kpi-bar">
                <div className="aq-kpi-fill" style={{ width: `${pct}%` }} />
              </div>
            </div>
          );
        })}
        <div className="aq-kpi-card">
          <div className="aq-kpi-value" style={{ fontSize: 18 }}>
            {fmtAmount(grandTotal, reports[0]?.baseCurrencyCode ?? 'USD')}
          </div>
          <div className="aq-kpi-label" style={{ marginTop: 4 }}>Total value</div>
          <div className="aq-kpi-bar">
            <div className="aq-kpi-fill aq-kpi-fill--neutral" style={{ width: '100%' }} />
          </div>
        </div>
      </div>

      {/* ── Filter chips + search ─────────────────────────────────────────── */}
      <div className="aq-controls">
        <div className="aq-chips">
          <button
            className={`aq-chip${statusFilter === 'all' ? ' aq-chip--active' : ''}`}
            onClick={() => changeFilter('all')}
          >
            All <span className="aq-chip-count">{queueReports.length}</span>
          </button>
          {uniqueStatuses.map(st => (
            <button
              key={st}
              className={`aq-chip${statusFilter === st ? ' aq-chip--active' : ''}`}
              onClick={() => changeFilter(st)}
            >
              {st.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())}
              <span className="aq-chip-count">{statusCounts[st] ?? 0}</span>
            </button>
          ))}
        </div>
        <div className="aq-search">
          <i className="fa-solid fa-magnifying-glass aq-search-icon" aria-hidden="true" />
          <input
            type="text"
            placeholder="Search reports or employees…"
            value={searchTerm}
            onChange={e => { setSearchTerm(e.target.value); setPage(1); }}
          />
        </div>
      </div>

      {/* ── Content ──────────────────────────────────────────────────────── */}
      {loading ? (
        <div className="loading-state">
          <span className="spinner" /> Loading approvals…
        </div>
      ) : filtered.length === 0 ? (
        <div className="empty-state">
          <i className="fa-solid fa-check-circle empty-state-icon" style={{ color: 'var(--success)' }} />
          <div className="empty-state-title">All clear!</div>
          <div className="empty-state-subtitle">
            {searchTerm ? 'No reports match your search.' : 'No expenses waiting for approval.'}
          </div>
        </div>
      ) : (
        <>
          <div className="aq-table-wrap">
            <table className="aq-table">
              <thead>
                <tr>
                  <th className="aq-col-report">Report</th>
                  <th className="aq-col-status">Status</th>
                  <th className="aq-col-items">Items</th>
                  <th className="aq-col-total">Total</th>
                  <th className="aq-col-action">Action</th>
                </tr>
              </thead>
              <tbody>
                {pageRows.map(report => {
                  const total       = reportTotal(report);
                  const itemCount   = report.lineItems.length;
                  const submittedOn = formatDate(report.submittedAt);
                  const empName     = report.employeeName ?? report.employeeId ?? '—';
                  const initials    = getInitials(empName);
                  const avColor     = avatarColor(empName);
                  const actionable  = isActionable(report.status);

                  return (
                    <tr key={report.id} className="aq-row">
                      <td className="aq-cell-report">
                        <div className="aq-reporter">
                          <div className={`aq-avatar ${avColor}`}>{initials}</div>
                          <div className="aq-report-info">
                            <span
                              className="aq-report-name"
                              onClick={() => navigate(`/expense/report/${report.id}`)}
                              role="button"
                              tabIndex={0}
                              onKeyDown={e => e.key === 'Enter' && navigate(`/expense/report/${report.id}`)}
                            >
                              {report.name}
                            </span>
                            <span className="aq-report-meta">
                              {empName} · {submittedOn}
                            </span>
                          </div>
                        </div>
                      </td>
                      <td className="aq-cell-status">
                        <StatusBadge status={report.status} />
                      </td>
                      <td className="aq-cell-items">{itemCount}</td>
                      <td className="aq-cell-total">
                        {fmtAmount(total, report.baseCurrencyCode)}
                      </td>
                      <td className="aq-cell-action">
                        <div className="aq-actions">
                          <button
                            className="btn btn-ghost btn-sm aq-btn-eye"
                            onClick={() => navigate(`/expense/report/${report.id}`)}
                            title="View report"
                            aria-label="View report"
                          >
                            <i className="fa-solid fa-eye" />
                          </button>
                          {canAct && actionable && (
                            <button
                              className="btn btn-primary btn-sm"
                              onClick={() => navigate('/admin/workflow/inbox')}
                              title="Open Approver Inbox to act on this report"
                            >
                              <i className="fa-solid fa-inbox" /> Review
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {/* ── Pagination ───────────────────────────────────────────────── */}
          {totalPages > 1 && (
            <div className="aq-pagination">
              <span className="aq-pg-info">
                Showing {(currentPage - 1) * PAGE_SIZE + 1}–{Math.min(currentPage * PAGE_SIZE, filtered.length)} of {filtered.length}
              </span>
              <div className="aq-pg-buttons">
                <button
                  className="aq-pg-btn"
                  disabled={currentPage === 1}
                  onClick={() => setPage(p => p - 1)}
                  aria-label="Previous page"
                >
                  <i className="fa-solid fa-chevron-left" />
                </button>
                {Array.from({ length: totalPages }, (_, i) => i + 1).map(p => (
                  <button
                    key={p}
                    className={`aq-pg-btn${p === currentPage ? ' aq-pg-btn--active' : ''}`}
                    onClick={() => setPage(p)}
                    aria-label={`Page ${p}`}
                  >
                    {p}
                  </button>
                ))}
                <button
                  className="aq-pg-btn"
                  disabled={currentPage === totalPages}
                  onClick={() => setPage(p => p + 1)}
                  aria-label="Next page"
                >
                  <i className="fa-solid fa-chevron-right" />
                </button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}
