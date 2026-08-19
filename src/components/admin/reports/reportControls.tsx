/**
 * Presentational controls shared by the report screens. Components only —
 * plain helpers live in reportShared.ts so Fast Refresh keeps working.
 */

import type { CSSProperties, ReactNode } from 'react';
import { STATE_FILL } from './reportShared';

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


export interface StatusSegment { key: string; label: string; value: number; }

/**
 * One thin stacked bar: the part-to-whole a pie would claim to give, in ~12px
 * instead of ~200, and readable at a glance.
 *
 * Why not a pie: 4 against 5 is ten degrees of arc — unreadable without labels,
 * at which point the labels are doing the work — and a zero slice vanishes,
 * silently deleting the fact that nobody is waiting on a manager. This bar
 * simply omits zero segments too, but the KPI tiles above it still show the 0,
 * which is where that fact belongs.
 *
 * Colour is never the only channel: the tiles directly above carry the same
 * colours WITH labels and counts, every segment has a tooltip, and the table
 * below is the full text view.
 *
 * Segments are separated by a 2px surface GAP, not by borders — a stroke around
 * a mark reads as part of the mark.
 */
export function StatusBar({ segments, total, onSelect, activeKey }: {
  segments: StatusSegment[];
  total: number;
  onSelect?: (key: string) => void;
  activeKey?: string | null;
}) {
  const shown = segments.filter(s => s.value > 0);
  if (!total || shown.length === 0) return null;

  const summary = shown.map(s => `${s.label} ${s.value}`).join(', ');

  return (
    <div style={{ padding: '4px 20px 0' }}>
      <div
        role="img"
        aria-label={`Timesheet states across ${total} employees: ${summary}.`}
        style={{ display: 'flex', gap: 2, height: 12, borderRadius: 6, overflow: 'hidden' }}
      >
        {shown.map(seg => {
          const pct = (seg.value / total) * 100;
          const dim = activeKey != null && activeKey !== seg.key;
          const style: CSSProperties = {
            width: `${pct}%`, minWidth: 3, background: STATE_FILL[seg.key] ?? '#94A3B8',
            opacity: dim ? 0.32 : 1, border: 'none', padding: 0,
            cursor: onSelect ? 'pointer' : 'default',
            transition: 'opacity 120ms ease',
          };
          const title = `${seg.label}: ${seg.value} of ${total} (${pct.toFixed(0)}%)`;
          return onSelect
            ? <button key={seg.key} type="button" title={title} aria-label={title}
                      onClick={() => onSelect(seg.key)} style={style} />
            : <div key={seg.key} title={title} style={style} />;
        })}
      </div>
    </div>
  );
}

/**
 * A single ratio against a target. A meter, not a two-slice pie.
 *
 * The fill takes a status colour because here the colour genuinely MEANS
 * good or bad — that is what the status scale is reserved for. The number and
 * the caption carry it too, so nothing depends on hue alone.
 */
export function Meter({ label, value, of, caption, good = 95, fair = 80 }: {
  label: string; value: number; of: number; caption?: string;
  good?: number; fair?: number;
}) {
  const pct = of > 0 ? (value / of) * 100 : 0;
  const fill = pct >= good ? '#0ca30c' : pct >= fair ? '#c98500' : '#d03b3b';
  return (
    <div style={{ background: '#fff', borderRadius: 10, padding: '12px 16px', minWidth: 210,
                  boxShadow: '0 2px 10px rgba(24,52,91,0.07)', flex: '0 0 auto' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <div style={{ fontSize: 20, fontWeight: 700, color: fill, lineHeight: 1.2 }}>
          {of > 0 ? `${Math.round(pct)}%` : '—'}
        </div>
        <div style={{ fontSize: 12, color: '#7A8CA6' }}>{value} of {of}</div>
      </div>
      <div style={{ fontSize: 11, color: '#7A8CA6', margin: '3px 0 7px',
                    textTransform: 'uppercase', letterSpacing: '.05em' }}>{label}</div>
      <div role="img" aria-label={`${label}: ${value} of ${of}, ${Math.round(pct)} percent.`}
           style={{ height: 6, borderRadius: 3, background: '#EEF1F6', overflow: 'hidden' }}>
        <div style={{ width: `${Math.min(100, pct)}%`, height: '100%', background: fill }} />
      </div>
      {caption && <div style={{ fontSize: 10.5, color: '#9CA3AF', marginTop: 5 }}>{caption}</div>}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Charts — hand-built, no charting library
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Two bar charts do not justify pulling recharts in: that is a 397 kB chunk for
 * marks a handful of divs draw exactly. Plain HTML also prints properly, scales
 * with the container, and gives direct control over the 2px surface gaps and
 * the label rules below — all of which a chart library fights you on.
 *
 * SERIES COLOURS come from the validated categorical palette (slots 1 and 2).
 * They are NOT the status scale used by StatusBar: status colours mean
 * good/bad and are reserved for that. A series colour means identity.
 */
const SERIES_1 = '#2a78d6';
const SERIES_2 = '#eb6834';

export interface BarDatum { label: string; value: number; muted?: boolean; }

/**
 * Horizontal bars, ONE hue, nominal categories.
 *
 * Horizontal because project names are long — vertical forces rotated labels,
 * which fail both readability and screen readers.
 *
 * One hue for every bar, deliberately: colouring bars darker-where-bigger
 * re-encodes what bar length already shows and burns the only free channel on
 * information the chart is already carrying. A value ramp on nominal categories
 * is a documented anti-pattern, not a style choice.
 */
export function BarRows({ title, data, format, note }: {
  title: string;
  data: BarDatum[];
  format: (v: number) => string;
  note?: string;
}) {
  const max = Math.max(1, ...data.map(d => d.value));
  const total = data.reduce((a, d) => a + d.value, 0);

  return (
    <div style={{ background: '#fff', borderRadius: 10, padding: '14px 16px 12px',
                  boxShadow: '0 2px 10px rgba(24,52,91,0.07)', minWidth: 0 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: '#7A8CA6',
                    textTransform: 'uppercase', letterSpacing: '.05em', marginBottom: 10 }}>
        {title}
      </div>
      {data.length === 0 ? (
        <div style={{ fontSize: 12, color: '#94A3B8', padding: '8px 0' }}>Nothing recorded.</div>
      ) : (
        <div role="img"
             aria-label={`${title}. ${data.map(d => `${d.label} ${format(d.value)}`).join('; ')}.`}
             style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {data.map(d => (
            <div key={d.label} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <div title={d.label}
                   style={{ width: 132, flex: '0 0 132px', fontSize: 12, color: '#41464d',
                            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {d.label}
              </div>
              <div style={{ flex: 1, minWidth: 0, height: 10, background: '#F1F4F9', borderRadius: 5 }}>
                <div style={{ width: `${(d.value / max) * 100}%`, height: '100%', borderRadius: 5,
                              background: d.muted ? '#B6C2D4' : SERIES_1, minWidth: 2 }} />
              </div>
              {/* Value on every row is legible here because there are at most a
                  dozen. It is a table with bars, not a plot with a number on
                  every point. */}
              <div style={{ width: 78, flex: '0 0 78px', textAlign: 'right', fontSize: 12,
                            color: '#41464d', fontVariantNumeric: 'tabular-nums' }}>
                {format(d.value)}
              </div>
              <div style={{ width: 40, flex: '0 0 40px', textAlign: 'right', fontSize: 11, color: '#9CA3AF',
                            fontVariantNumeric: 'tabular-nums' }}>
                {total > 0 ? `${Math.round((d.value / total) * 100)}%` : ''}
              </div>
            </div>
          ))}
        </div>
      )}
      {note && <div style={{ fontSize: 10.5, color: '#9CA3AF', marginTop: 9 }}>{note}</div>}
    </div>
  );
}

export interface StackRow { label: string; a: number; b: number; }

/**
 * Stacked bars, two series. A legend is always present for two or more series,
 * so identity never rests on colour alone.
 *
 * Segments are separated by a 2px surface gap rather than a border — a stroke
 * drawn around a mark reads as part of the mark.
 */
export function StackedBars({ title, data, aLabel, bLabel, format }: {
  title: string; data: StackRow[]; aLabel: string; bLabel: string;
  format: (v: number) => string;
}) {
  const max = Math.max(1, ...data.map(d => d.a + d.b));

  return (
    <div style={{ background: '#fff', borderRadius: 10, padding: '14px 16px 12px',
                  boxShadow: '0 2px 10px rgba(24,52,91,0.07)', minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
                    gap: 12, marginBottom: 10, flexWrap: 'wrap' }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: '#7A8CA6',
                      textTransform: 'uppercase', letterSpacing: '.05em' }}>{title}</div>
        <div style={{ display: 'flex', gap: 12, fontSize: 11, color: '#41464d' }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
            <span style={{ width: 9, height: 9, borderRadius: 2, background: SERIES_1 }} />{aLabel}
          </span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
            <span style={{ width: 9, height: 9, borderRadius: 2, background: SERIES_2 }} />{bLabel}
          </span>
        </div>
      </div>
      {data.length === 0 ? (
        <div style={{ fontSize: 12, color: '#94A3B8', padding: '8px 0' }}>Nothing recorded.</div>
      ) : (
        <div role="img"
             aria-label={`${title}. ${data.map(d =>
               `${d.label}: ${aLabel} ${format(d.a)}, ${bLabel} ${format(d.b)}`).join('; ')}.`}
             style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {data.map(d => (
            <div key={d.label} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <div style={{ width: 92, flex: '0 0 92px', fontSize: 12, color: '#41464d',
                            whiteSpace: 'nowrap' }}>{d.label}</div>
              <div style={{ flex: 1, minWidth: 0, height: 10, display: 'flex', gap: 2 }}>
                <div title={`${aLabel} ${format(d.a)}`}
                     style={{ width: `${(d.a / max) * 100}%`, background: SERIES_1,
                              borderRadius: '5px 0 0 5px', minWidth: d.a > 0 ? 2 : 0 }} />
                <div title={`${bLabel} ${format(d.b)}`}
                     style={{ width: `${(d.b / max) * 100}%`, background: SERIES_2,
                              borderRadius: '0 5px 5px 0', minWidth: d.b > 0 ? 2 : 0 }} />
              </div>
              <div style={{ width: 78, flex: '0 0 78px', textAlign: 'right', fontSize: 12,
                            color: '#41464d', fontVariantNumeric: 'tabular-nums' }}>
                {format(d.a + d.b)}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
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
