/**
 * AdminReports — the report catalog at /admin/reports.
 *
 * Thin by design: it lists whatever `REPORTS` declares and renders the one you
 * pick. All report-specific code lives in ./reports/<Report>.tsx.
 *
 * Route gate: reports_admin.view (App.tsx). Each row carries its own gate on
 * top of that, and a row you cannot open is shown locked rather than hidden —
 * an administrator on this screen needs to see that the report exists and which
 * permission unlocks it.
 */

import { Suspense, useMemo, useState } from 'react';
import { usePermissions } from '../../hooks/usePermissions';
import { REPORTS } from './reports/registry';
import type { ReportDef } from './reports/registry';

// ─────────────────────────────────────────────────────────────────────────────
// Catalog
// ─────────────────────────────────────────────────────────────────────────────

export default function AdminReports() {
  const { can } = usePermissions();
  const [search, setSearch] = useState('');
  const [activeCode, setActiveCode] = useState<string | null>(null);

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase();
    return REPORTS
      .filter(r => r.active)
      .filter(r => !q
        || r.name.toLowerCase().includes(q)
        || r.description.toLowerCase().includes(q)
        || r.permission.toLowerCase().includes(q));
  }, [search]);

  const active: ReportDef | undefined = activeCode
    ? REPORTS.find(r => r.code === activeCode)
    : undefined;

  // Re-check the gate at render time, not just at click time — a permission can
  // change under a long-lived tab, and the catalog is not a security boundary.
  if (active && can(active.permission)) {
    const Report = active.Component;
    return (
      <Suspense fallback={
        <div style={{ padding: 48, textAlign: 'center', color: '#94a3b8' }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 22, marginRight: 10 }} />
          Loading report…
        </div>
      }>
        <Report onBack={() => setActiveCode(null)} />
      </Suspense>
    );
  }

  return (
    <div className="ar-panel">
      <div className="rpt-title-bar">
        <div>
          <div className="rpt-title">Reports</div>
          <div className="rpt-subtitle">View and manage available reports</div>
        </div>
      </div>

      <div className="rpt-list-toolbar">
        <div className="rpt-list-search">
          <i className="fa-solid fa-magnifying-glass" />
          <input
            className="rpt-list-search-inp"
            placeholder="Search reports…"
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <div className="rpt-list-toolbar-right">
          <span className="rpt-list-count">{rows.length} report{rows.length !== 1 ? 's' : ''}</span>
        </div>
      </div>

      <div className="rpt-list-table-frame">
        {rows.length === 0 ? (
          <div className="rpt-list-empty">
            <i className="fa-solid fa-file-chart-column" />
            <p>{search ? 'No reports match your search.' : 'No reports are available.'}</p>
          </div>
        ) : (
          <table className="rpt-list-table">
            <thead>
              <tr>
                <th>REPORT NAME</th>
                <th>DESCRIPTION</th>
                <th>PERMISSION</th>
                <th>ACCESS</th>
                <th>ACTION</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(rpt => {
                const allowed = can(rpt.permission);
                return (
                  <tr key={rpt.code} className="rpt-list-row" style={allowed ? undefined : { opacity: 0.62 }}>
                    <td>
                      <div className="rpt-name-cell">
                        <div className="rpt-name-icon"><i className={`fa-solid ${rpt.icon}`} /></div>
                        <div className="rpt-name-text">{rpt.name}</div>
                      </div>
                    </td>
                    <td className="rpt-list-td-desc">
                      <span className="rpt-card-desc">{rpt.description}</span>
                    </td>
                    <td>
                      <span
                        className="rpt-role-badge"
                        title="The permission that unlocks this report. Grant it under Security → Permission Matrix → Reports."
                        style={{ fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: 11, textTransform: 'none' }}
                      >
                        {rpt.permission}
                      </span>
                    </td>
                    <td>
                      <span className={`rpt-list-status ${allowed ? 'rpt-list-status-active' : 'rpt-list-status-inactive'}`}>
                        <i className={`fa-solid ${allowed ? 'fa-circle-check' : 'fa-lock'}`} />
                        {' '}{allowed ? 'Granted' : 'Not granted'}
                      </span>
                    </td>
                    <td className="rpt-list-td-action">
                      {allowed ? (
                        <button className="rpt-list-view-btn" onClick={() => setActiveCode(rpt.code)}>
                          View <i className="fa-solid fa-arrow-right" />
                        </button>
                      ) : (
                        <span
                          className="rpt-list-status rpt-list-status-inactive"
                          title={`Ask an administrator to grant ${rpt.permission}.`}
                          style={{ cursor: 'default' }}
                        >
                          No access
                        </span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
