/**
 * Presentational controls shared by the report screens. Components only —
 * plain helpers live in reportShared.ts so Fast Refresh keeps working.
 */

import type { CSSProperties, ReactNode } from 'react';

export function MonthRange({ from, to, onFrom, onTo }: {
  from: string; to: string; onFrom: (v: string) => void; onTo: (v: string) => void;
}) {
  return (
    <div className="er-chip er-chip-date">
      <i className="fa-solid fa-calendar-days er-chip-icon" />
      <span className="er-date-lbl">Period</span>
      <input type="month" className="er-date-inp" value={from} max={to || undefined}
             onChange={e => onFrom(e.target.value)} />
      <span className="er-date-sep">–</span>
      <input type="month" className="er-date-inp" value={to} min={from || undefined}
             onChange={e => onTo(e.target.value)} />
    </div>
  );
}

export function Pager({ page, pageSize, total, onPage, onPageSize }: {
  page: number; pageSize: number; total: number;
  onPage: (p: number) => void; onPageSize: (n: number) => void;
}) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  return (
    <div className="er-pagination">
      <button className="er-pg-btn" type="button" disabled={page <= 1}
              onClick={() => onPage(Math.max(1, page - 1))}>
        <i className="fa-solid fa-chevron-left" />
      </button>
      <span className="er-pg-info">Page {page} of {pages}</span>
      <button className="er-pg-btn" type="button" disabled={page >= pages}
              onClick={() => onPage(Math.min(pages, page + 1))}>
        <i className="fa-solid fa-chevron-right" />
      </button>
      <select className="er-pg-size" value={pageSize}
              onChange={e => { onPageSize(Number(e.target.value)); onPage(1); }}>
        {[25, 50, 100, 250].map(n => <option key={n} value={n}>{n} / page</option>)}
      </select>
    </div>
  );
}

export function ReportHeader({ icon, title, onBack, children }: {
  icon: string; title: string; onBack: () => void; children?: ReactNode;
}) {
  return (
    <div className="rpt-detail-header">
      <button className="rpt-back-btn" onClick={onBack}>
        <i className="fa-solid fa-arrow-left" /> Back to Reports
      </button>
      <h2 className="rpt-detail-title" style={{ margin: 0 }}>
        <i className={`fa-solid ${icon}`} /> {title}
      </h2>
      {children}
    </div>
  );
}

/** Shown instead of the table, so an empty grid is never mistaken for "no data". */
export function ReportStatus({ loading, error, empty, emptyText }: {
  loading: boolean; error: string | null; empty: boolean; emptyText: string;
}) {
  if (loading) return (
    <div style={{ padding: 48, textAlign: 'center', color: '#94a3b8' }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 20, marginRight: 10 }} />
      Running the report…
    </div>
  );
  if (error) return (
    <div style={{ margin: 20, padding: '14px 16px', borderRadius: 8,
                  background: '#FEF2F2', border: '1px solid #FECACA', color: '#991B1B', fontSize: 13 }}>
      <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 8 }} />
      {error}
    </div>
  );
  if (empty) return (
    <div style={{ padding: 48, textAlign: 'center', color: '#94a3b8' }}>
      <i className="fa-solid fa-inbox" style={{ fontSize: 24, display: 'block', marginBottom: 8 }} />
      {emptyText}
    </div>
  );
  return null;
}

/**
 * One KPI tile. Value is pre-formatted — this does not know what it is showing.
 *
 * Give it `onClick` and it becomes a filter: see the number, get the rows, one
 * click. A tile you cannot click is a number the reader then has to reproduce by
 * hand with the filter controls, and it looks pressable either way — so a
 * non-interactive tile reads as broken rather than as absent.
 *
 * `active` marks the tile whose filter is currently applied, and clicking it
 * again is expected to clear that filter — so the ring is a toggle state, not
 * just a highlight.
 */
export function Kpi({ label, value, tone, onClick, active, hint }: {
  label: string; value: string; tone?: string;
  onClick?: () => void; active?: boolean; hint?: string;
}) {
  const body = (
    <>
      <div style={{ fontSize: 20, fontWeight: 700, color: tone || '#18345B', lineHeight: 1.2 }}>{value}</div>
      <div style={{ fontSize: 11, color: '#7A8CA6', marginTop: 3,
                    textTransform: 'uppercase', letterSpacing: '.05em' }}>{label}</div>
    </>
  );

  const base: CSSProperties = {
    background: '#fff', borderRadius: 10, padding: '12px 16px', minWidth: 128,
    boxShadow: active ? '0 0 0 2px #2B54CE, 0 2px 10px rgba(24,52,91,0.10)'
                      : '0 2px 10px rgba(24,52,91,0.07)',
    flex: '0 0 auto',
  };

  if (!onClick) return <div style={base}>{body}</div>;

  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={!!active}
      title={hint ?? (active ? `Showing only ${label.toLowerCase()} — click to clear`
                             : `Show only ${label.toLowerCase()}`)}
      style={{
        ...base,
        border: `1px solid ${active ? '#2B54CE' : 'transparent'}`,
        textAlign: 'left', cursor: 'pointer', font: 'inherit',
        transition: 'box-shadow 120ms ease, transform 120ms ease',
      }}
      onMouseEnter={e => { e.currentTarget.style.transform = 'translateY(-1px)'; }}
      onMouseLeave={e => { e.currentTarget.style.transform = ''; }}
    >
      {body}
    </button>
  );
}

/**
 * Says out loud that the controls no longer match what is on screen.
 *
 * Filters deliberately wait for Apply so a half-built multi-select does not fire
 * a query per tick — but without this, a report showing stale rows beside changed
 * controls is indistinguishable from a report that ignored you.
 */
export function PendingFilters({ show, onApply }: { show: boolean; onApply: () => void }) {
  if (!show) return null;
  return (
    <button
      type="button"
      onClick={onApply}
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 6, cursor: 'pointer',
        fontSize: 11.5, fontWeight: 600, color: '#92400E', background: '#FFFBEB',
        border: '1px solid #FDE68A', borderRadius: 6, padding: '4px 9px', whiteSpace: 'nowrap',
      }}
    >
      <i className="fa-solid fa-circle-exclamation" />
      Filters changed — Apply to update
    </button>
  );
}

/**
 * How many employees the caller is allowed to see.
 *
 * Rendered only when the answer is "not everyone". A report showing a subset
 * without saying so is how a manager concludes the company logged 40 hours
 * last month.
 */
export function ScopeBadge({ scope }: { scope?: { mode?: string; employee_count?: number | null } }) {
  if (!scope || scope.mode === 'all') return null;
  const n = scope.employee_count ?? 0;
  return (
    <span title="Your permissions scope this report to a subset of employees."
          style={{ fontSize: 11, fontWeight: 600, color: '#7c3aed', background: '#f3e8ff',
                   border: '1px solid #ddd6fe', borderRadius: 6, padding: '3px 8px', whiteSpace: 'nowrap' }}>
      <i className="fa-solid fa-users" style={{ marginRight: 4 }} />
      {scope.mode === 'none' ? 'No employees in scope' : `${n} employee${n === 1 ? '' : 's'} in scope`}
    </span>
  );
}
