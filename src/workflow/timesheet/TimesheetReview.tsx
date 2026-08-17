/**
 * TimesheetReview — the pieces an approver reads.
 *
 * The same components serve the inbox panel (a subset, compact) and the full
 * review page (all of them). They mirror the Summary and Detail PDF exports on
 * purpose: an approver should be looking at exactly what the employee prints
 * and what lands in the archive, not at a third rendering of the same month.
 *
 * Inline styles throughout, matching the rest of the app.
 */

import React from 'react';
import { hm, hLabel } from './model';
import type { MonthModel, MonthDay, TsPayload, Exception } from './model';

// ── shared bits ──────────────────────────────────────────────────────────────

export function TsSectionHead({ title, sub, right }: {
  title: string; sub?: string; right?: React.ReactNode;
}) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 9, margin: '0 0 11px' }}>
      <span style={{ width: 3, height: 14, background: '#2B54CE', borderRadius: 2, flexShrink: 0 }} />
      <span style={{ fontSize: 11.5, fontWeight: 800, color: '#1F3B73', textTransform: 'uppercase', letterSpacing: '0.11em' }}>
        {title}
      </span>
      {sub && <span style={{ fontSize: 10.5, color: '#9CA3AF' }}>{sub}</span>}
      <span style={{ flex: 1, borderTop: '1px solid #E8EDF5', marginLeft: 6 }} />
      {right}
    </div>
  );
}

export function TsEmployeeStrip({ payload }: { payload: TsPayload }) {
  const cells: [string, string][] = [
    ['Employee',         `${payload.employee?.name ?? '—'}${payload.employee?.employee_code ? ` · ${payload.employee.employee_code}` : ''}`],
    ['Department',       payload.header.department_name ?? '—'],
    ['Manager',          payload.employee?.manager_name ?? '—'],
    ['Work schedule',    payload.schedule?.name ?? '—'],
    ['Holiday calendar', payload.holiday_calendar?.name ?? '—'],
  ];
  return (
    <div style={{
      display: 'flex', flexWrap: 'wrap', border: '1px solid #E8EDF5', borderRadius: 8,
      background: '#FCFDFF', marginBottom: 14, overflow: 'hidden',
    }}>
      {cells.map(([l, v], i) => (
        <div key={l} style={{
          padding: '8px 14px', flex: 1, minWidth: 130,
          borderRight: i < cells.length - 1 ? '1px solid #EEF2F8' : 'none',
        }}>
          <div style={{ fontSize: 9, fontWeight: 700, color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.07em' }}>{l}</div>
          <div style={{ fontSize: 12.5, color: '#1F3B73', fontWeight: 600, marginTop: 2 }}>{v}</div>
        </div>
      ))}
    </div>
  );
}

export function TsKpiTiles({ month }: { month: MonthModel }) {
  const tiles: [string, string, string, string | number, string][] = [
    ['Planned hours',   'fa-clock',                  '#2F6BE8', (month.planned  / 60).toFixed(1), 'hrs this month'],
    ['Recorded hours',  'fa-arrow-trend-up',         '#12A594', (month.recorded / 60).toFixed(1), 'hrs logged'],
    ['Over planned',    'fa-arrow-up-from-bracket',  '#F0A020', (month.over     / 60).toFixed(1), "hrs beyond the day's schedule"],
    ['Utilisation',     'fa-chart-pie',              '#147A5C', `${month.utilisation}%`,          'of planned'],
    ['Working days',    'fa-calendar',               '#2A4A9E', month.workingDays,                'scheduled this month'],
    ['Days recorded',   'fa-calendar-check',         '#12A594', month.daysRecorded,               'days with time against them'],
    ['Leave days',      'fa-folder-open',            '#F0A020', month.leaveDays,                  'days absent'],
    ['Public holidays', 'fa-star',                   '#16A34A', month.holidayCount,               'days this month'],
  ];
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 9, marginBottom: 16 }}>
      {tiles.map(([label, icon, color, value, sub]) => (
        <div key={label} style={{
          border: '1px solid #E8EDF5', borderTop: `3px solid ${color}`, borderRadius: 7,
          padding: '10px 12px', background: '#fff',
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 9, fontWeight: 700,
                        color: '#94A3B8', textTransform: 'uppercase', letterSpacing: '0.07em' }}>
            <i className={`fas ${icon}`} style={{ color, fontSize: 10 }} />{label}
          </div>
          <div style={{ fontSize: 24, fontWeight: 800, lineHeight: 1.1, marginTop: 5, color,
                        fontVariantNumeric: 'tabular-nums' }}>{value}</div>
          <div style={{ fontSize: 10, color: '#9CA3AF', marginTop: 2 }}>{sub}</div>
        </div>
      ))}
    </div>
  );
}

const CHIP_TONE: Record<Exception['tone'], { bg: string; bd: string; fg: string }> = {
  red:    { bg: '#FEF2F2', bd: '#FECACA', fg: '#B91C1C' },
  amber:  { bg: '#FFFBEB', bd: '#FDE68A', fg: '#92400E' },
  blue:   { bg: '#EFF6FF', bd: '#BFDBFE', fg: '#1D4ED8' },
  violet: { bg: '#F5F3FF', bd: '#DDD6FE', fg: '#6D28D9' },
};

export function TsExceptionChips({ month }: { month: MonthModel }) {
  if (!month.exceptions.length) {
    return (
      <div style={{ marginBottom: 16 }}>
        <span style={{
          display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 11.5, fontWeight: 600,
          borderRadius: 7, padding: '5px 10px', background: '#F0FDF4', border: '1px solid #BBF7D0', color: '#15803D',
        }}>
          <i className="fas fa-circle-check" />
          No exceptions — every working day accounted for
        </span>
      </div>
    );
  }
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 16 }}>
      {month.exceptions.map((e, i) => {
        const t = CHIP_TONE[e.tone];
        return (
          <span key={`${e.id}-${i}`} style={{
            display: 'flex', alignItems: 'center', gap: 6, fontSize: 11.5, fontWeight: 600,
            borderRadius: 7, padding: '5px 10px', background: t.bg, border: `1px solid ${t.bd}`, color: t.fg,
          }}>
            <i className={`fas ${e.icon}`} />{e.text}
          </span>
        );
      })}
    </div>
  );
}

// ── calendar ─────────────────────────────────────────────────────────────────

const CELL_STYLE: Record<string, { bg: string; bd: string; num: string; hrs: string; dot: string | null }> = {
  work:    { bg: '#EEF3FD', bd: '#DCE6FA', num: '#1F3B73', hrs: '#2B54CE', dot: '#2B54CE' },
  leave:   { bg: '#EFF6FF', bd: '#D8E7FB', num: '#1E40AF', hrs: '#3B82F6', dot: '#93C5FD' },
  holiday: { bg: '#F4EFFE', bd: '#E4D9FC', num: '#5B21B6', hrs: '#7C3AED', dot: '#7C3AED' },
  over:    { bg: '#FDEEEF', bd: '#FBD5D8', num: '#B91C1C', hrs: '#B91C1C', dot: '#DC2626' },
  missing: { bg: '#FEF7E8', bd: '#FBE3B4', num: '#B45309', hrs: '#B45309', dot: '#F0A020' },
  weekoff: { bg: '#F4F6F9', bd: '#EDF0F5', num: '#B7BFCC', hrs: '#B7BFCC', dot: null },
  future:  { bg: '#FCFDFE', bd: '#F1F4F8', num: '#CBD3DE', hrs: '#CBD3DE', dot: null },
};

function cellVariant(d: MonthDay): keyof typeof CELL_STYLE {
  if (d.kind === 'holiday') return 'holiday';
  if (d.tone === 'over')    return d.kind === 'missing' ? 'missing' : 'over';
  if (d.kind === 'missing') return 'missing';
  if (d.kind === 'weekoff') return 'weekoff';
  if (d.kind === 'leave')   return 'leave';
  if (d.recorded > 0)       return 'work';
  return 'future';
}

export function TsCalendar({ month }: { month: MonthModel }) {
  const firstDow = month.days[0]?.dow ?? 0;
  const cells: (MonthDay | null)[] = [
    ...Array.from({ length: firstDow }, () => null),
    ...month.days,
  ];
  while (cells.length % 7) cells.push(null);
  const rows: (MonthDay | null)[][] = [];
  for (let i = 0; i < cells.length; i += 7) rows.push(cells.slice(i, i + 7));

  const legend: [string, keyof typeof CELL_STYLE][] = [
    ['Working', 'work'], ['Leave', 'leave'], ['Holiday', 'holiday'],
    ['Over planned', 'over'], ['Missing', 'missing'], ['Week off', 'weekoff'], ['Not yet due', 'future'],
  ];

  return (
    <>
      <table style={{ width: '100%', borderCollapse: 'separate', borderSpacing: 5, marginBottom: 6 }}>
        <thead>
          <tr>
            {['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map(d => (
              <th key={d} style={{ fontSize: 9.5, fontWeight: 700, color: '#94A3B8', textTransform: 'uppercase',
                                   letterSpacing: '0.09em', paddingBottom: 2, textAlign: 'center' }}>{d}</th>
            ))}
            <th style={{ fontSize: 9.5, fontWeight: 700, color: '#94A3B8', textTransform: 'uppercase',
                         letterSpacing: '0.09em', textAlign: 'right', paddingRight: 4 }}>Week</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, ri) => {
            const wk = month.weeks.find(w => row.some(d => d && w.days.includes(d)));
            const show = wk && wk.recorded > 0;
            return (
              <tr key={ri}>
                {row.map((d, ci) => {
                  if (!d) return <td key={ci} style={{ width: '12.4%' }}><div style={{ minHeight: 46 }} /></td>;
                  const v = CELL_STYLE[cellVariant(d)];
                  const overBy = d.planned === 0 ? d.recorded : Math.max(0, d.recorded - d.planned);
                  return (
                    <td key={ci} style={{ width: '12.4%', verticalAlign: 'top' }}>
                      <div style={{
                        borderRadius: 7, padding: '6px 7px 7px', minHeight: 46, position: 'relative',
                        background: v.bg, border: `1px solid ${v.bd}`,
                      }}>
                        <div style={{ fontSize: 12, fontWeight: 700, lineHeight: 1, color: v.num }}>{d.day}</div>
                        {d.kind === 'holiday' ? (
                          <div style={{ fontSize: 10.5, marginTop: 3, fontWeight: 700, color: v.hrs }}>HOL</div>
                        ) : d.kind === 'missing' ? (
                          <div style={{ fontSize: 10.5, marginTop: 3, fontWeight: 600, color: v.hrs }}>—</div>
                        ) : d.recorded > 0 ? (
                          <>
                            <div style={{ fontSize: 10.5, marginTop: 3, fontWeight: 600, color: v.hrs }}>
                              {hLabel(d.recorded)}{d.kind === 'leave' ? ' LV' : ''}
                            </div>
                            {overBy > 0 && (
                              <div style={{ fontSize: 10, fontWeight: 800, marginTop: 1, color: '#DC2626' }}>
                                +{hLabel(overBy)}
                              </div>
                            )}
                          </>
                        ) : null}
                        {v.dot && (
                          <span style={{ position: 'absolute', bottom: 6, left: '50%', transform: 'translateX(-50%)',
                                         width: 5, height: 5, borderRadius: '50%', background: v.dot }} />
                        )}
                      </div>
                    </td>
                  );
                })}
                <td style={{ textAlign: 'right', paddingRight: 2, verticalAlign: 'middle', width: '11%' }}>
                  {show && (
                    <>
                      <div style={{ fontSize: 11.5, fontWeight: 800, fontVariantNumeric: 'tabular-nums',
                                    color: wk!.recorded > wk!.planned ? '#DC2626' : '#1F3B73' }}>
                        {hLabel(wk!.recorded)} / {hLabel(wk!.planned)}
                      </div>
                      <div style={{ fontSize: 9.5, color: '#94A3B8', marginTop: 1 }}>
                        {wk!.recorded > wk!.planned ? `${hLabel(wk!.recorded - wk!.planned)} over`
                          : wk!.recorded < wk!.planned ? `${hLabel(wk!.planned - wk!.recorded)} short`
                          : 'on plan'}
                      </div>
                    </>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 7, margin: '8px 0 16px' }}>
        {legend.map(([label, k]) => {
          const v = CELL_STYLE[k];
          return (
            <span key={label} style={{
              fontSize: 10, fontWeight: 600, borderRadius: 20, padding: '3px 11px',
              background: v.bg, border: `1px solid ${v.bd}`, color: v.hrs,
            }}>{label}</span>
          );
        })}
      </div>
    </>
  );
}

// ── matrix: one row skeleton for every day of the month ──────────────────────

const TONE_COLOR: Record<string, string> = {
  met: '#16A34A', short: '#D97706', over: '#DC2626', none: '#CBD5E1',
};

const ROW_TINT: Record<DayTintKey, { bg: string; dow: string; num: string }> = {
  work:    { bg: 'transparent', dow: '#8A97A9', num: '#1F3B73' },
  weekoff: { bg: '#F7F9FC',     dow: '#B4BDC9', num: '#8794A6' },
  holiday: { bg: '#FAF7FE',     dow: '#AE94DD', num: '#6D28D9' },
  missing: { bg: '#FEF5F5',     dow: '#E0A0A0', num: '#B91C1C' },
  future:  { bg: '#FDFEFF',     dow: '#CBD3DE', num: '#AEB8C6' },
};
type DayTintKey = 'work' | 'weekoff' | 'holiday' | 'missing' | 'future';

function rowTintKey(d: MonthDay): DayTintKey {
  if (d.kind === 'holiday') return 'holiday';
  if (d.kind === 'missing') return 'missing';
  if (d.planned === 0)      return 'weekoff';
  if (d.kind === 'future')  return 'future';
  return 'work';
}

function DayTag({ d }: { d: MonthDay }) {
  const base: React.CSSProperties = {
    display: 'inline-block', fontSize: 8.5, fontWeight: 700, letterSpacing: '0.05em',
    textTransform: 'uppercase', borderRadius: 3, padding: '1px 6px', marginLeft: 8, verticalAlign: 1,
  };
  if (d.kind === 'holiday')
    return <span style={{ ...base, background: '#F1E9FD', color: '#7C3AED', textTransform: 'none',
                          letterSpacing: '0.01em', fontSize: 9, fontWeight: 600 }}>{d.holidayName}</span>;
  if (d.kind === 'missing') return <span style={{ ...base, background: '#FEE2E2', color: '#B91C1C' }}>Missing</span>;
  if (d.planned === 0)      return <span style={{ ...base, background: '#EDF0F5', color: '#8794A6' }}>Week off</span>;
  if (d.kind === 'future')  return <span style={{ ...base, background: '#F4F6F9', color: '#B4BDC9' }}>Not due</span>;
  if (d.kind === 'leave')   return <span style={{ ...base, background: '#E4EFFD', color: '#2563EB' }}>Leave</span>;
  return null;
}

function Pips({ pct, tone }: { pct: number; tone: string }) {
  const n = 10;
  const filled = Math.min(n, Math.max(0, Math.round(pct / (pct > 100 ? pct / n : 10))));
  const c = TONE_COLOR[tone] ?? '#D97706';
  return (
    <>
      <span style={{ display: 'inline-flex', gap: 1, verticalAlign: 'middle', marginRight: 5 }}>
        {Array.from({ length: n }, (_, i) => (
          <i key={i} style={{ width: 2.5, height: 9, borderRadius: 1, display: 'block',
                              background: i < filled ? c : '#E7ECF3' }} />
        ))}
      </span>
      <span style={{ fontSize: 9.5, fontWeight: 700, color: c }}>{pct}%</span>
    </>
  );
}

export function TsMatrix({ month }: { month: MonthModel }) {
  const td: React.CSSProperties = { padding: 0, textAlign: 'center', fontSize: 10.5,
                                    borderBottom: '1px solid #F4F7FB', height: 21 };
  const dayCell: React.CSSProperties = { ...td, textAlign: 'left', paddingLeft: 11, whiteSpace: 'nowrap' };

  return (
    <div style={{ border: '1px solid #E8EDF5', borderRadius: 8, overflow: 'hidden', marginBottom: 16, background: '#fff' }}>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontVariantNumeric: 'tabular-nums', minWidth: 520 }}>
          <thead>
            <tr>
              <th style={{ textAlign: 'left', paddingLeft: 11, width: 172, background: '#fff',
                           borderBottom: '1.5px solid #DDE4EF', padding: '5px 3px 6px', fontSize: 9.5,
                           fontWeight: 700, color: '#64748B', textTransform: 'uppercase', letterSpacing: '0.055em' }}>Day</th>
              {month.columns.map(c => (
                <th key={c.key} style={{ background: '#fff', borderBottom: '1.5px solid #DDE4EF', padding: '5px 3px 6px',
                                         fontSize: 9.5, fontWeight: 700, color: '#64748B', textTransform: 'uppercase',
                                         letterSpacing: '0.055em', verticalAlign: 'bottom' }}>
                  <span style={{ display: 'block', width: 5, height: 5, borderRadius: '50%', margin: '0 auto 3px', background: c.color }} />
                  {c.label}
                </th>
              ))}
              <th style={{ background: '#fff', borderBottom: '1.5px solid #DDE4EF', padding: '5px 3px 6px', fontSize: 9.5,
                           fontWeight: 700, color: '#94A3B8', textTransform: 'uppercase' }}>Total</th>
              <th style={{ background: '#fff', borderBottom: '1.5px solid #DDE4EF', padding: '5px 8px 6px 3px', fontSize: 9.5,
                           fontWeight: 700, color: '#94A3B8', textTransform: 'uppercase', width: 70 }}>Complete</th>
            </tr>
          </thead>
          <tbody>
            {month.days.map(d => {
              const tint = ROW_TINT[rowTintKey(d)];
              const week = (d.dow === 6 || d.day === month.days.length)
                ? month.weeks.find(w => w.days.includes(d)) : null;
              return (
                <React.Fragment key={d.date}>
                  <tr>
                    <td style={{ ...dayCell, background: tint.bg, color: tint.dow }}>
                      {d.dowLabel}
                      <em style={{ color: tint.num, fontWeight: 700, fontStyle: 'normal', marginLeft: 3 }}>{d.day}</em>
                      <DayTag d={d} />
                    </td>
                    {month.columns.map(c => (
                      <td key={c.key} style={{ ...td, background: tint.bg,
                                               color: d.byColumn[c.key] ? '#334155' : '#DEE5EE' }}>
                        {d.byColumn[c.key] ? hm(d.byColumn[c.key]) : '·'}
                      </td>
                    ))}
                    <td style={{ ...td, background: tint.bg === 'transparent' ? '#FCFDFE' : tint.bg,
                                 fontWeight: 700, color: TONE_COLOR[d.tone] }}>
                      {d.recorded ? hm(d.recorded) : '—'}
                    </td>
                    <td style={{ ...td, background: tint.bg, width: 70 }} />
                  </tr>
                  {week && (
                    <tr>
                      <td style={{ ...dayCell, background: '#F3F6FC', height: 20, fontWeight: 800, color: '#2B54CE',
                                   borderTop: '1px solid #E4EBF6', borderBottom: '1px solid #E4EBF6', fontSize: 10 }}>
                        Week {week.n}
                        <span style={{ color: '#9AA9C4', fontWeight: 500, marginLeft: 6, fontSize: 9 }}>
                          {week.fromDay}–{week.toDay}
                        </span>
                      </td>
                      {month.columns.map(c => (
                        <td key={c.key} style={{ ...td, background: '#F3F6FC', height: 20, fontWeight: 700,
                                                 color: '#3E5A8C', fontSize: 10, borderTop: '1px solid #E4EBF6',
                                                 borderBottom: '1px solid #E4EBF6' }}>
                          {week.byColumn[c.key] ? hm(week.byColumn[c.key]) : ''}
                        </td>
                      ))}
                      <td style={{ ...td, background: '#F3F6FC', height: 20, fontWeight: 700, color: '#3E5A8C',
                                   fontSize: 10, borderTop: '1px solid #E4EBF6', borderBottom: '1px solid #E4EBF6' }}>
                        {week.recorded ? hLabel(week.recorded) : '—'}
                      </td>
                      <td style={{ ...td, background: '#F3F6FC', height: 20, borderTop: '1px solid #E4EBF6',
                                   borderBottom: '1px solid #E4EBF6', paddingRight: 8, width: 70 }}>
                        {week.planned > 0 && (
                          <Pips
                            pct={Math.round((week.recorded / week.planned) * 100)}
                            tone={week.recorded > week.planned ? 'over'
                              : week.recorded === week.planned ? 'met' : 'short'}
                          />
                        )}
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              );
            })}
            <tr>
              <td style={{ ...dayCell, background: '#1F3B73', color: '#A9BEE2', height: 26, border: 'none',
                           textTransform: 'uppercase', letterSpacing: '0.09em', fontSize: 9.5, fontWeight: 700 }}>
                Month total
              </td>
              {month.columns.map(c => (
                <td key={c.key} style={{ ...td, background: '#1F3B73', color: '#fff', fontWeight: 800,
                                         fontSize: 11, height: 26, border: 'none' }}>
                  {month.byColumn[c.key] ? hm(month.byColumn[c.key]) : '—'}
                </td>
              ))}
              <td style={{ ...td, background: '#1F3B73', color: '#fff', fontWeight: 800, fontSize: 11, height: 26, border: 'none' }}>
                {hLabel(month.recorded)}
              </td>
              <td style={{ ...td, background: '#1F3B73', height: 26, border: 'none', paddingRight: 8, width: 70 }}>
                <Pips pct={month.utilisation} tone="short" />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div style={{ display: 'flex', gap: 15, alignItems: 'center', padding: '7px 11px', background: '#FCFDFE',
                    borderTop: '1px solid #F1F4F8', fontSize: 9.5, color: '#94A3B8', flexWrap: 'wrap' }}>
        {([['Met', '#16A34A'], ['Short', '#D97706'], ['Over', '#DC2626'], ['Missing', '#B91C1C'],
           ['Holiday', '#8B5CF6'], ['Week off', '#94A3B8'], ['Not due', '#CBD5E1']] as [string, string][]).map(([l, c]) => (
          <span key={l}><b style={{ color: c, fontSize: 11 }}>•</b> {l}</span>
        ))}
        <span style={{ marginLeft: 'auto' }}>every day of the month · h:mm</span>
      </div>
    </div>
  );
}

// ── weekly progress ──────────────────────────────────────────────────────────

const WEEK_TAG: Record<MonthWeekTone, [string, string, string]> = {
  neutral:  ['#64748B', '#F1F5F9', '#E2E8F0'],
  over:     ['#B45309', '#FFFBEB', '#FDE68A'],
  progress: ['#1D4ED8', '#EFF6FF', '#BFDBFE'],
  good:     ['#15803D', '#F0FDF4', '#BBF7D0'],
  bad:      ['#B91C1C', '#FEF2F2', '#FECACA'],
};
type MonthWeekTone = 'neutral' | 'over' | 'progress' | 'good' | 'bad';

export function TsWeeklyProgress({ month }: { month: MonthModel }) {
  return (
    <div>
      {month.weeks.map(w => {
        const pct = w.planned ? Math.min(100, Math.round((w.recorded / w.planned) * 100)) : 0;
        const [fg, bg, bd] = WEEK_TAG[w.tagTone];
        return (
          <div key={w.n} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '8px 0',
                                  borderBottom: '1px solid #F4F7FB' }}>
            <div style={{ width: 88, flexShrink: 0, fontSize: 12, fontWeight: 700, color: '#1F3B73' }}>
              Week {w.n}
              {w.holidays > 0 && (
                <small style={{ display: 'block', fontWeight: 500, color: '#D97706', fontSize: 10 }}>
                  {w.holidays} holiday
                </small>
              )}
            </div>
            <div style={{ flex: 1, height: 9, borderRadius: 5, background: '#EEF2F7', position: 'relative', overflow: 'hidden' }}>
              {w.planned > 0 && (
                <i style={{ position: 'absolute', left: 0, top: 0, bottom: 0, borderRadius: 5,
                            width: `${pct}%`, background: w.recorded > w.planned ? '#F0A020' : '#2F6BE8' }} />
              )}
            </div>
            <div style={{ width: 90, textAlign: 'right', fontSize: 12, fontWeight: 800, flexShrink: 0,
                          fontVariantNumeric: 'tabular-nums',
                          color: w.recorded ? (w.recorded > w.planned ? '#B45309' : '#1F3B73') : '#C0C8D4' }}>
              {w.recorded ? hLabel(w.recorded) : '—'}{' '}
              <span style={{ color: '#B0B9C7', fontWeight: 600 }}>/ {hLabel(w.planned)}</span>
            </div>
            <div style={{ width: 108, textAlign: 'center', flexShrink: 0 }}>
              <span style={{ fontSize: 10, fontWeight: 700, borderRadius: 20, padding: '2px 9px',
                             color: fg, background: bg, border: `1px solid ${bd}` }}>{w.tag}</span>
            </div>
            <div style={{ width: 62, textAlign: 'right', fontSize: 10.5, color: '#A6AFBD', flexShrink: 0 }}>
              {w.fromDay}–{w.toDay}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ── month split ──────────────────────────────────────────────────────────────

export function TsMonthSplit({ month }: { month: MonthModel }) {
  const items = month.columns
    .filter(c => month.byColumn[c.key])
    .map(c => ({ ...c, minutes: month.byColumn[c.key],
                 pct: Math.round((month.byColumn[c.key] / (month.recorded || 1)) * 100) }))
    .sort((a, b) => b.minutes - a.minutes);

  const R = 54, C = 2 * Math.PI * R;
  let acc = 0;

  return (
    <div style={{ display: 'flex', gap: 26, alignItems: 'center', flexWrap: 'wrap' }}>
      <svg width={140} height={140} viewBox="0 0 140 140" style={{ flexShrink: 0 }}>
        {items.map(it => {
          const f = it.minutes / (month.recorded || 1);
          const el = (
            <circle key={it.key} cx={70} cy={70} r={R} fill="none" stroke={it.color} strokeWidth={22}
                    strokeDasharray={`${(C * f).toFixed(2)} ${(C * (1 - f)).toFixed(2)}`}
                    strokeDashoffset={(-C * acc).toFixed(2)} transform="rotate(-90 70 70)" />
          );
          acc += f;
          return el;
        })}
        <circle cx={70} cy={70} r={43} fill="#fff" />
        <text x={70} y={66} textAnchor="middle" fontSize={19} fontWeight={800} fill="#1F3B73">
          {hLabel(month.recorded)}
        </text>
        <text x={70} y={82} textAnchor="middle" fontSize={9} fill="#9CA3AF" letterSpacing={1}>RECORDED</text>
      </svg>
      <div style={{ flex: 1, minWidth: 240, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '5px 26px' }}>
        {items.map(it => (
          <div key={it.key} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12 }}>
            <span style={{ width: 8, height: 8, borderRadius: '50%', background: it.color, flexShrink: 0 }} />
            <span style={{ flex: 1, color: '#334155' }}>{it.label}</span>
            <span style={{ fontWeight: 800, color: '#1F3B73', fontVariantNumeric: 'tabular-nums' }}>{hLabel(it.minutes)}</span>
            <span style={{ width: 34, textAlign: 'right', color: '#9CA3AF', fontSize: 11 }}>{it.pct}%</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── by project & activity ────────────────────────────────────────────────────

export function TsByProject({ month }: { month: MonthModel }) {
  if (!month.byProject.length) {
    return <p style={{ fontSize: 12, color: '#94A3B8', margin: 0 }}>No project time recorded this month.</p>;
  }
  return (
    <>
      {month.byProject.map(p => {
        const max = Math.max(...p.rows.map(r => r.minutes), 1);
        return (
          <div key={p.key} style={{ border: '1px solid #E8EDF5', borderRadius: 9, padding: '11px 14px 12px',
                                    marginBottom: 9, background: '#fff' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: 9 }}>
              <span style={{ width: 9, height: 9, borderRadius: '50%', background: p.color }} />
              <span style={{ fontSize: 13, fontWeight: 800, color: '#1F3B73', flex: 1 }}>{p.label}</span>
              <span style={{ fontSize: 10.5, color: '#A6AFBD' }}>{p.days} day{p.days === 1 ? '' : 's'}</span>
              <span style={{ fontSize: 13, fontWeight: 800, color: '#1F3B73', fontVariantNumeric: 'tabular-nums' }}>
                {hm(p.minutes)}
              </span>
              <span style={{ fontSize: 11, color: '#9CA3AF', width: 34, textAlign: 'right' }}>{p.share}%</span>
            </div>
            {p.rows.map((r, i) => (
              <div key={`${r.label}-${i}`} style={{ marginBottom: 7 }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, fontSize: 11.5, marginBottom: 3 }}>
                  <span style={{ color: '#C0C8D4', width: 14, flexShrink: 0 }}>{i + 1}.</span>
                  <span style={{ flex: 1, color: r.unitemised ? '#A6AFBD' : '#475569' }}>{r.label}</span>
                  <span style={{ fontWeight: r.unitemised ? 500 : 700, color: r.unitemised ? '#A6AFBD' : '#1F3B73',
                                 fontVariantNumeric: 'tabular-nums' }}>{hm(r.minutes)}</span>
                </div>
                <div style={{ height: 3, borderRadius: 2, background: '#F1F4F8', marginLeft: 22, overflow: 'hidden' }}>
                  <i style={{ display: 'block', height: '100%', borderRadius: 2,
                              width: `${Math.round((r.minutes / max) * 100)}%`,
                              background: r.unitemised ? '#E2E8F0' : p.color }} />
                </div>
              </div>
            ))}
          </div>
        );
      })}
      <p style={{ fontSize: 11, color: '#A6AFBD', margin: '2px 0 0' }}>
        An entry credits only its first named activity, so "Not itemised" absorbs the rest —
        the data does not split an entry's minutes across activities.
      </p>
    </>
  );
}

// ── daily detail ─────────────────────────────────────────────────────────────

export function TsDailyDetail({ month, payload, changedOnly }: {
  month: MonthModel; payload: TsPayload; changedOnly: boolean;
}) {
  const shown = month.days.filter(d =>
    changedOnly ? d.changed
                : (d.entries.length > 0 || d.removed.length > 0 || d.kind === 'missing' || d.kind === 'holiday'));

  const colorFor = (d: MonthDay, e: typeof d.entries[number]) => {
    const key = e.entry_kind === 'project' && e.project_id ? `p:${e.project_id}`
      : e.time_type_id ? `t:${e.time_type_id}` : 'other';
    return month.columns.find(c => c.key === key)?.color ?? '#94A3B8';
  };

  return (
    <>
      {payload.header.last_approved_at && (
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', background: '#FFFBEB',
                      border: '1px solid #FDE68A', borderRadius: 8, padding: '10px 13px', marginBottom: 14 }}>
          <i className="fas fa-circle-info" style={{ color: '#D97706', fontSize: 13, marginTop: 2 }} />
          <div>
            <div style={{ fontSize: 12, fontWeight: 700, color: '#92400E' }}>
              ADDED / EDITED mark entries recorded after the approval of{' '}
              {new Date(payload.header.last_approved_at).toLocaleString('en-GB',
                { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}.
            </div>
            {payload.deletions_visible ? (
              month.removedCount > 0 && (
                <div style={{ fontSize: 11.5, color: '#78350F', marginTop: 2, lineHeight: 1.5 }}>
                  {month.removedCount} {month.removedCount === 1 ? 'entry has' : 'entries have'} been
                  removed since then, totalling {hLabel(month.removedMinutes)} — shown struck through
                  on the day they were taken from.
                </div>
              )
            ) : (
              <div style={{ fontSize: 11.5, color: '#78350F', marginTop: 2, lineHeight: 1.5 }}>
                Deleted entries cannot be shown — this sheet predates the entry audit trail.
              </div>
            )}
          </div>
        </div>
      )}

      {!shown.length && (
        <div style={{ textAlign: 'center', padding: '36px 16px', color: '#9CA3AF', fontSize: 13 }}>
          Nothing changed since the last approval.
        </div>
      )}

      {shown.map(d => {
        const pill =
          d.kind === 'holiday' ? { bg: '#F4EFFE', fg: '#7C3AED', text: `Holiday · ${d.holidayName}` } :
          d.kind === 'missing' ? { bg: '#FEF7E8', fg: '#B45309', text: `No entry · planned ${hLabel(d.planned)}` } :
          d.planned === 0      ? { bg: '#FDEEEF', fg: '#B91C1C', text: `${hLabel(d.recorded)} · week off` } :
          d.recorded > d.planned ? { bg: '#FDEEEF', fg: '#B91C1C', text: `${hLabel(d.recorded)} / ${hLabel(d.planned)}` } :
                                 { bg: '#EEF3FD', fg: '#2B54CE', text: `${hLabel(d.recorded)} / ${hLabel(d.planned)}` };

        return (
          <div key={d.date} style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                          paddingBottom: 5, borderBottom: '1px solid #E8EDF5', marginBottom: 8 }}>
              <span style={{ fontSize: 14, fontWeight: 700, color: '#1F2937' }}>
                {new Date(d.date + 'T00:00:00').toLocaleDateString('en-GB',
                  { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })}
              </span>
              <span style={{ fontSize: 10.5, fontWeight: 700, borderRadius: 20, padding: '3px 10px',
                             background: pill.bg, color: pill.fg }}>{pill.text}</span>
            </div>

            {d.kind === 'missing' && !d.removed.length ? (
              <div style={{ border: '1px dashed #FBD5D8', background: '#FEF6F6', borderRadius: 7,
                            padding: '9px 12px', fontSize: 12, color: '#B91C1C', fontWeight: 600 }}>
                <i className="fas fa-circle-exclamation" style={{ marginRight: 7 }} />
                No entry recorded — {hLabel(d.planned)} was scheduled.
              </div>
            ) : d.kind === 'holiday' && !d.entries.length ? (
              <div style={{ border: '1px dashed #E4D9FC', background: '#FAF7FE', borderRadius: 7,
                            padding: '9px 12px', fontSize: 12, color: '#6D28D9', fontWeight: 600 }}>
                <i className="fas fa-star" style={{ marginRight: 7 }} />{d.holidayName}
              </div>
            ) : (
              <>
                {d.entries.map(e => (
                  <div key={e.id} style={{
                    display: 'flex', border: '1px solid ' + (e.changed_after_approval ? '#FCE9BE' : '#E8EDF5'),
                    borderLeft: `3px solid ${e.changed_after_approval ? '#D97706' : colorFor(d, e)}`,
                    borderRadius: 7, padding: '9px 12px', marginBottom: 7,
                    background: e.changed_after_approval ? '#FFFCF3' : '#fff', alignItems: 'flex-start',
                  }}>
                    <div style={{ width: 160, flexShrink: 0 }}>
                      <div style={{ fontSize: 12.5, fontWeight: 700, color: '#1F2937' }}>
                        {e.project_name ?? e.time_type_name ?? '—'}
                      </div>
                      <div style={{ fontSize: 10, color: '#A6AFBD', marginTop: 1, textTransform: 'capitalize' }}>
                        {e.entry_kind.replace('_', ' ')}
                      </div>
                      {e.changed_after_approval && (
                        <span style={{ display: 'inline-block', fontSize: 8.5, fontWeight: 800,
                                       letterSpacing: '0.07em', borderRadius: 3, padding: '1px 5px', marginTop: 5,
                                       background: '#FEF3C7', color: '#92400E' }}>
                          {e.changed_after_approval}
                        </span>
                      )}
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      {(e.activities ?? []).length
                        ? e.activities.map((a, i) => (
                            <div key={i} style={{ fontSize: 12, color: '#374151', padding: '1px 0' }}>{a}</div>
                          ))
                        : <div style={{ fontSize: 12, color: '#B4BDC9' }}>—</div>}
                      {e.notes && (
                        <div style={{ fontSize: 11, color: '#94A3B8', fontStyle: 'italic', marginTop: 3 }}>{e.notes}</div>
                      )}
                    </div>
                    <div style={{ width: 78, textAlign: 'right', flexShrink: 0 }}>
                      <div style={{ fontSize: 13, fontWeight: 800, color: '#1F2937',
                                    fontVariantNumeric: 'tabular-nums' }}>
                        {hLabel(e.hours_minutes)}
                      </div>
                      {e.previous_hours_minutes != null && e.previous_hours_minutes !== e.hours_minutes && (
                        <div style={{ fontSize: 10.5, color: '#B45309', marginTop: 2,
                                      fontVariantNumeric: 'tabular-nums' }}>
                          was {hLabel(e.previous_hours_minutes)}
                        </div>
                      )}
                    </div>
                  </div>
                ))}
                {/* What is no longer here. Struck through and dimmed, on the day
                    it came off, so the absence is as legible as the presence. */}
                {d.removed.map(r => (
                  <div key={r.id} style={{
                    display: 'flex', border: '1px dashed #FBD5D8', borderLeft: '3px solid #DC2626',
                    borderRadius: 7, padding: '9px 12px', marginBottom: 7, background: '#FEF6F6',
                    alignItems: 'flex-start',
                  }}>
                    <div style={{ width: 160, flexShrink: 0 }}>
                      <div style={{ fontSize: 12.5, fontWeight: 700, color: '#991B1B',
                                    textDecoration: 'line-through' }}>
                        {r.project_name ?? r.time_type_name ?? '—'}
                      </div>
                      <span style={{ display: 'inline-block', fontSize: 8.5, fontWeight: 800,
                                     letterSpacing: '0.07em', borderRadius: 3, padding: '1px 5px', marginTop: 5,
                                     background: '#FEE2E2', color: '#B91C1C' }}>
                        REMOVED
                      </span>
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      {(r.activities ?? []).length
                        ? r.activities.map((a, i) => (
                            <div key={i} style={{ fontSize: 12, color: '#B08585', padding: '1px 0',
                                                  textDecoration: 'line-through' }}>{a}</div>
                          ))
                        : <div style={{ fontSize: 12, color: '#D9AFAF' }}>—</div>}
                      <div style={{ fontSize: 11, color: '#B08585', marginTop: 3 }}>
                        Deleted {new Date(r.removed_at).toLocaleString('en-GB',
                          { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}
                        {r.removed_by ? ` by ${r.removed_by}` : ''}
                      </div>
                    </div>
                    <div style={{ width: 70, textAlign: 'right', fontSize: 13, fontWeight: 800, color: '#B91C1C',
                                  fontVariantNumeric: 'tabular-nums', flexShrink: 0, textDecoration: 'line-through' }}>
                      {hLabel(r.hours_minutes)}
                    </div>
                  </div>
                ))}

                <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 14, alignItems: 'center',
                              background: '#F2F6FD', borderRadius: 7, padding: '8px 14px', fontSize: 11,
                              fontWeight: 700, color: '#3E5A8C', letterSpacing: '0.06em', textTransform: 'uppercase' }}>
                  {d.removed.length > 0 && (
                    <span style={{ color: '#B91C1C', letterSpacing: 0, textTransform: 'none', fontWeight: 600 }}>
                      was {hLabel(d.recorded + d.removed.reduce((a, r) => a + r.hours_minutes, 0))} before removals
                    </span>
                  )}
                  Daily total <b style={{ fontSize: 14, color: '#1F3B73', letterSpacing: 0 }}>{hLabel(d.recorded)}</b>
                </div>
              </>
            )}
          </div>
        );
      })}

      {!changedOnly && shown.length > 0 && (
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: '#EAF1FD',
                      border: '1px solid #D5E2FA', borderRadius: 8, padding: '12px 16px', fontSize: 12,
                      fontWeight: 700, color: '#2B54CE', letterSpacing: '0.05em', textTransform: 'uppercase', marginTop: 4 }}>
          <span>Month total · {payload.entries.length} entries across {month.daysRecorded} days</span>
          <b style={{ fontSize: 17, color: '#1F3B73', letterSpacing: 0 }}>{hLabel(month.recorded)}</b>
        </div>
      )}
    </>
  );
}
