/**
 * AdminReports — the report catalog at /admin/reports.
 *
 * Thin by design: it lists what `REPORTS` declares and frames the one you pick.
 * All report-specific code lives in ./reports/.
 *
 * Route gate: reports_admin.view (App.tsx). Each VIEW inside a report carries
 * its own permission (mig 745), so the row adapts to what the caller can
 * actually open rather than promising a choice they do not have.
 *
 * A row you cannot open is shown LOCKED, not hidden. An administrator on this
 * screen needs to see that the report exists and which permission unlocks it;
 * hiding it turns a permissions question into a "is it broken?" question.
 */

import { Suspense, useMemo, useState } from 'react';
import { usePermissions } from '../../hooks/usePermissions';
import { REPORTS } from './reports/registry';
import type { ReportDef, ReportView } from './reports/registry';
import ReportFrame from './reports/ReportFrame';

interface Row {
  report:    ReportDef;
  permitted: ReportView[];
  /** What the row calls itself: the report, or the single view the caller has. */
  title:     string;
  icon:      string;
  blurb:     string;
}

export default function AdminReports() {
  const { can } = usePermissions();
  const [search, setSearch] = useState('');
  const [openCode, setOpenCode] = useState<string | null>(null);

  const rows = useMemo<Row[]>(() => {
    const q = search.trim().toLowerCase();
    return REPORTS
      .filter(r => r.active)
      .map(r => {
        const permitted = r.views.filter(v => can(v.permission));
        const solo = permitted.length === 1 && r.views.length > 1 ? permitted[0] : null;
        const single = r.views.length === 1 ? r.views[0] : null;
        return {
          report:    r,
          permitted,
          title:     solo?.name ?? r.name,
          icon:      solo?.icon ?? r.icon,
          blurb:     solo?.description ?? single?.description ?? r.description,
        };
      })
      .filter(row => !q
        || row.title.toLowerCase().includes(q)
        || row.blurb.toLowerCase().includes(q)
        || row.report.views.some(v => v.permission.toLowerCase().includes(q)
                                   || v.name.toLowerCase().includes(q)));
  }, [search, can]);

  const open = openCode ? rows.find(r => r.report.code === openCode) : undefined;

  // Re-checked at render, not just at click: a permission can change under a
  // long-lived tab, and the catalog is not a security boundary — the RPCs are.
  if (open && open.permitted.length > 0) {
    return (
      <Suspense fallback={
        <div style={{ padding: 48, textAlign: 'center', color: '#94a3b8' }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 22, marginRight: 10 }} />
          Loading report…
        </div>
      }>
        <ReportFrame report={open.report} views={open.permitted} onBack={() => setOpenCode(null)} />
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
              {rows.map(row => {
                const allowed = row.permitted.length > 0;
                const total   = row.report.views.length;
                return (
                  <tr key={row.report.code} className="rpt-list-row"
                      style={allowed ? undefined : { opacity: 0.62 }}>
                    <td>
                      <div className="rpt-name-cell">
                        <div className="rpt-name-icon"><i className={`fa-solid ${row.icon}`} /></div>
                        <div className="rpt-name-text">{row.title}</div>
                      </div>
                    </td>
                    <td className="rpt-list-td-desc">
                      <span className="rpt-card-desc">{row.blurb}</span>
                    </td>
                    <td>
                      {/* Every permission that opens something here, so an
                          administrator can read off exactly what to grant. */}
                      <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                        {row.report.views.map(v => (
                          <span
                            key={v.code}
                            className="rpt-role-badge"
                            title={total > 1
                              ? `${v.name} — grant under Security → Permission Matrix → Reports.`
                              : 'Grant under Security → Permission Matrix.'}
                            style={{
                              fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
                              fontSize: 11, textTransform: 'none', whiteSpace: 'nowrap',
                              opacity: can(v.permission) ? 1 : 0.55,
                            }}
                          >
                            {v.permission}
                          </span>
                        ))}
                      </div>
                    </td>
                    <td>
                      <span className={`rpt-list-status ${allowed ? 'rpt-list-status-active' : 'rpt-list-status-inactive'}`}>
                        <i className={`fa-solid ${allowed ? 'fa-circle-check' : 'fa-lock'}`} />
                        {' '}
                        {!allowed
                          ? 'Not granted'
                          : total > 1
                            ? `${row.permitted.length} of ${total} views`
                            : 'Granted'}
                      </span>
                    </td>
                    <td className="rpt-list-td-action">
                      {allowed ? (
                        <button className="rpt-list-view-btn" onClick={() => setOpenCode(row.report.code)}>
                          View <i className="fa-solid fa-arrow-right" />
                        </button>
                      ) : (
                        <span
                          className="rpt-list-status rpt-list-status-inactive"
                          title={`Ask an administrator to grant ${row.report.views.map(v => v.permission).join(' or ')}.`}
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
