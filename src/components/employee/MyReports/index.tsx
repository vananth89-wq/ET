import { useState, useMemo, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import type { ExpenseStatus, ExpenseReport } from '../../../types';
import { useExpenseData } from '../../../hooks/useExpenseData';
import { useAuth } from '../../../contexts/AuthContext';
import { useCurrencies } from '../../../hooks/useCurrencies';
import { usePermissions } from '../../../hooks/usePermissions';

import { fmtAmount } from '../../../utils/currency';
import StatusBadge from '../../shared/StatusBadge';
import AgeBadge from '../../shared/AgeBadge';

type Filter = 'all' | ExpenseStatus;

export default function MyReports() {
  const navigate = useNavigate();
  const { reports, createReport, deleteReport } = useExpenseData();
  const { employee: authEmployee } = useAuth();
  const { currencies } = useCurrencies();
  const { can } = usePermissions();
  const [filter, setFilter] = useState<Filter>('all');
  const [showCreate, setShowCreate] = useState(false);
  const [newName, setNewName] = useState('');
  const [newDesc, setNewDesc] = useState('');
  const [nameError, setNameError] = useState(false);
  const [pendingDelete, setPendingDelete] = useState<string | null>(null);
  const [createError,  setCreateError]  = useState<string | null>(null);
  const [creating,     setCreating]     = useState(false);
  const nameRef = useRef<HTMLInputElement>(null);

  // Filter to current employee's reports
  const myEmployeeId = authEmployee?.employeeId ?? '';
  const myReports = myEmployeeId
    ? reports.filter(r => r.employeeId === myEmployeeId)
    : reports;

  const filtered = useMemo(() =>
    filter === 'all' ? myReports : myReports.filter(r => r.status === filter),
    [myReports, filter]
  );

  // KPI values
  const totalReports = myReports.length;
  const pendingAmt = myReports
    .filter(r => r.status === 'submitted')
    .reduce((s, r) => s + r.lineItems.reduce((a, li) => a + (li.convertedAmount || 0), 0), 0);
  const approvedAmt = myReports
    .filter(r => r.status === 'approved')
    .reduce((s, r) => s + r.lineItems.reduce((a, li) => a + (li.convertedAmount || 0), 0), 0);

  // Filter chips — only show statuses that have at least 1 report, plus All
  const statusCounts: Record<string, number> = {};
  myReports.forEach(r => { statusCounts[r.status] = (statusCounts[r.status] || 0) + 1; });

  const chips: { key: Filter; label: string; count: number }[] = [
    { key: 'all', label: 'All', count: myReports.length },
    ...(['draft', 'submitted', 'approved', 'rejected'] as ExpenseStatus[])
      .filter(s => (statusCounts[s] || 0) > 0)
      .map(s => ({ key: s as Filter, label: s.charAt(0).toUpperCase() + s.slice(1), count: statusCounts[s] || 0 })),
  ];

  function openCreate() {
    const months = ['January','February','March','April','May','June',
                    'July','August','September','October','November','December'];
    const d = new Date();
    setNewName(`${months[d.getMonth()]} ${d.getFullYear()} Expenses`);
    setNewDesc('');
    setNameError(false);
    setShowCreate(true);
    setTimeout(() => { nameRef.current?.select(); }, 50);
  }

  async function handleCreate() {
    const name = newName.trim();
    if (!name) { setNameError(true); nameRef.current?.focus(); return; }

    const employeeId       = authEmployee?.employeeId ?? '';
    const employeeName     = authEmployee?.name ?? '';
    // Resolve currency code from the employee's baseCurrencyId UUID
    const baseCurrency     = currencies.find(c => c.id === authEmployee?.baseCurrencyId);
    const baseCurrencyCode = baseCurrency?.code ?? 'INR';

    setShowCreate(false);
    setNewName('');
    setNewDesc('');
    setCreateError(null);
    setCreating(true);

    try {
      const reportId = await createReport({
        employeeId,
        employeeName,
        name,
        status: 'draft',
        baseCurrencyCode,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      navigate(`/expense/report/${reportId}`);
    } catch (err: any) {
      setCreateError(err.message ?? 'Failed to create report. Please try again.');
    } finally {
      setCreating(false);
    }
  }

  function handleDelete() {
    if (pendingDelete) { deleteReport(pendingDelete); setPendingDelete(null); }
  }

  const rowTotal = (r: ExpenseReport): number =>
    r.lineItems.reduce((s: number, li) => s + (li.convertedAmount || 0), 0);

  const fmtLastUpdated = (iso: string) => iso ? iso.slice(0, 10) : '—';

  return (
    <div className="exp-my-reports">

      {/* ── Header ─────────────────────────────────────── */}
      <div className="exp-panel-header">
        <h2 className="exp-panel-title">
          <i className="fa-solid fa-wallet" /> My Reports
        </h2>
        {can('expense.create') && (
          <button className="exp-btn-new-report" onClick={openCreate} disabled={creating}>
            {creating
              ? <><i className="fa-solid fa-spinner fa-spin" /> Creating…</>
              : <><i className="fa-solid fa-plus" /> New Report</>
            }
          </button>
        )}
      </div>

      {/* ── Create Error ──────────────────────────────── */}
      {createError && (
        <div style={{
          background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 8,
          padding: '12px 16px', marginBottom: 16, color: '#991B1B',
          display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <i className="fa-solid fa-circle-exclamation" />
          <span>{createError}</span>
          <button
            onClick={() => setCreateError(null)}
            style={{ marginLeft: 'auto', background: 'none', border: 'none', cursor: 'pointer', color: '#991B1B' }}
          >
            <i className="fa-solid fa-xmark" />
          </button>
        </div>
      )}

      {/* ── KPI Strip (3 cards) ────────────────────────── */}
      <div className="exp-kpi-strip" style={{ marginBottom: 20 }}>
        <div className="exp-kpi-card">
          <div className="exp-kpi-icon" style={{ background: '#1976D218', color: '#1976D2' }}>
            <i className="fa-solid fa-file-lines" />
          </div>
          <div className="exp-kpi-text">
            <div className="exp-kpi-value">{totalReports}</div>
            <div className="exp-kpi-label">Total Reports</div>
          </div>
        </div>

        <div className="exp-kpi-card">
          <div className="exp-kpi-icon" style={{ background: '#F59E0B18', color: '#F59E0B' }}>
            <i className="fa-solid fa-clock" />
          </div>
          <div className="exp-kpi-text">
            <div className="exp-kpi-value">{fmtAmount(pendingAmt, 'INR')}</div>
            <div className="exp-kpi-label">Pending Approval</div>
          </div>
        </div>

        <div className="exp-kpi-card">
          <div className="exp-kpi-icon" style={{ background: '#2E7D3218', color: '#2E7D32' }}>
            <i className="fa-solid fa-circle-check" />
          </div>
          <div className="exp-kpi-text">
            <div className="exp-kpi-value">{fmtAmount(approvedAmt, 'INR')}</div>
            <div className="exp-kpi-label">Approved</div>
          </div>
        </div>
      </div>

      {/* ── Filter Chips ───────────────────────────────── */}
      <div className="exp-filter-chips" style={{ marginBottom: 16 }}>
        {chips.map(c => (
          <button
            key={c.key}
            className={`exp-filter-chip ${filter === c.key ? 'exp-filter-chip--active' : ''}`}
            onClick={() => setFilter(c.key)}
          >
            {c.label} <span className="exp-chip-count">{c.count}</span>
          </button>
        ))}
      </div>

      {/* ── Table ──────────────────────────────────────── */}
      <div className="exp-report-table-wrap">
        <table className="exp-report-table">
          <thead>
            <tr>
              <th>Report Name</th>
              <th>Status</th>
              <th>Total</th>
              <th>Last Updated</th>
            </tr>
          </thead>
          <tbody>
            {filtered.length === 0 ? (
              <tr>
                <td colSpan={4} style={{ textAlign: 'center', padding: '32px', color: '#94a3b8' }}>
                  No reports found.
                </td>
              </tr>
            ) : filtered.map(r => (
              <tr
                key={r.id}
                className="exp-report-row"
                style={{ cursor: 'pointer' }}
                onClick={() => navigate(`/expense/report/${r.id}`)}
              >
                <td>
                  <div className="exp-report-name-cell">
                    <span className="exp-report-name-text">{r.name}</span>
                    {r.status === 'draft' && can('expense.delete') && (
                      <>
                        <button
                          className="exp-rename-btn"
                          title="Edit report"
                          onClick={e => { e.stopPropagation(); navigate(`/expense/report/${r.id}`); }}
                        >
                          <i className="fa-solid fa-pen" />
                        </button>
                        <button
                          className="exp-delete-report-btn"
                          title="Delete report"
                          onClick={e => { e.stopPropagation(); setPendingDelete(r.id); }}
                        >
                          <i className="fa-solid fa-trash" />
                        </button>
                      </>
                    )}
                  </div>
                </td>
                <td>
                  <div className="exp-status-age-wrap">
                    <StatusBadge status={r.status} />
                    <AgeBadge updatedAt={r.updatedAt} status={r.status} />
                  </div>
                </td>
                <td><strong>{fmtAmount(rowTotal(r), r.baseCurrencyCode)}</strong></td>
                <td style={{ color: '#64748b' }}>{fmtLastUpdated(r.updatedAt)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* ── Create Modal ───────────────────────────────── */}
      {showCreate && (
        <div className="exp-modal-overlay exp-modal--open" onClick={() => setShowCreate(false)}>
          <div className="exp-modal-card" onClick={e => e.stopPropagation()}>

            {/* Header */}
            <div className="exp-modal-header">
              <div className="exp-modal-header-left">
                <div className="exp-modal-icon">
                  <i className="fa-solid fa-file-circle-plus" />
                </div>
                <h3 className="exp-modal-title">New Expense Report</h3>
              </div>
              <button className="exp-modal-close" onClick={() => setShowCreate(false)}>
                <i className="fa-solid fa-xmark" />
              </button>
            </div>

            {/* Body */}
            <div className="exp-modal-body">
              <div className="exp-modal-field">
                <label className="exp-modal-label">
                  Report Name <span className="exp-modal-req">*</span>
                </label>
                <input
                  ref={nameRef}
                  className={`exp-modal-input${nameError ? ' exp-modal-input--error' : ''}`}
                  value={newName}
                  onChange={e => { setNewName(e.target.value); setNameError(false); }}
                  placeholder="e.g. April 2026 Expenses"
                  onKeyDown={e => { if (e.key === 'Enter') handleCreate(); if (e.key === 'Escape') setShowCreate(false); }}
                />
                {nameError && (
                  <div className="exp-modal-err">
                    <i className="fa-solid fa-circle-exclamation" /> Report name is required.
                  </div>
                )}
              </div>
              <div className="exp-modal-field">
                <label className="exp-modal-label">
                  Description <span className="exp-modal-optional">optional</span>
                </label>
                <textarea
                  className="exp-modal-input exp-modal-textarea"
                  value={newDesc}
                  onChange={e => setNewDesc(e.target.value)}
                  placeholder="e.g. Business travel expenses for Q2 client visit..."
                  rows={3}
                />
              </div>
              <p className="exp-modal-hint">
                <i className="fa-solid fa-keyboard" />
                Press <kbd>Enter</kbd> to create · <kbd>Esc</kbd> to cancel
              </p>
            </div>

            {/* Footer */}
            <div className="exp-modal-footer">
              <button className="exp-modal-btn exp-modal-btn--cancel" onClick={() => setShowCreate(false)}>
                Cancel
              </button>
              <button className="exp-modal-btn exp-modal-btn--create" onClick={handleCreate}>
                <i className="fa-solid fa-file-circle-plus" /> Create Report
              </button>
            </div>

          </div>
        </div>
      )}

      {/* ── Delete Confirm ─────────────────────────────── */}
      {pendingDelete && (
        <div className="exp-modal-overlay exp-modal--open" onClick={() => setPendingDelete(null)}>
          <div className="exp-modal-box" onClick={e => e.stopPropagation()}>
            <h3 className="exp-modal-title">
              <i className="fa-solid fa-triangle-exclamation" /> Delete Report?
            </h3>
            <p style={{ color: '#64748b', marginBottom: 24 }}>This action cannot be undone.</p>
            <div className="exp-modal-actions">
              <button className="exp-btn-cancel-item" onClick={() => setPendingDelete(null)}>Cancel</button>
              <button
                className="exp-btn-save-item"
                style={{ background: '#D32F2F' }}
                onClick={handleDelete}
              >Delete</button>
            </div>
          </div>
        </div>
      )}

    </div>
  );
}
