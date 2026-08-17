/**
 * TsDecisionPrep — the four numbers and the short list of things worth knowing,
 * put where the approver lands rather than 4,000 pixels below the tables.
 *
 * The checklist is a prompt, not a gate. Nothing here disables the action bar:
 * an approver who has read the month can approve immediately, and one who has
 * not is told, once, what they are about to sign off. Blocking would be worse —
 * a queue that fights back gets clicked through faster, not more carefully.
 */

import { useState } from 'react';
import { hLabel } from './model';
import type { MonthModel } from './model';

export function TsDecisionPrep({ month }: { month: MonthModel }) {
  const checkable = month.exceptions.filter(e => e.checkable);
  const [seen, setSeen] = useState<Record<string, boolean>>({});
  const open = checkable.filter((e, i) => !seen[`${e.id}-${i}`]).length;

  const stats: [string, string, string][] = [
    ['Recorded', hLabel(month.recorded), '#1F3B73'],
    ['Planned',  hLabel(month.planned),  '#B0B9C7'],
    ['Complete', `${month.utilisation}%`, month.utilisation >= 100 ? '#16A34A' : '#D97706'],
    ['Over',     hLabel(month.over),      month.over > 0 ? '#DC2626' : '#16A34A'],
  ];

  return (
    <div style={{
      background: '#fff', border: '1px solid #E2E8F0', borderRadius: 12,
      overflow: 'hidden', marginBottom: 16, boxShadow: '0 2px 10px rgba(15,23,42,0.05)',
    }}>
      <div style={{ display: 'flex', borderBottom: checkable.length ? '1px solid #F1F5F9' : 'none', background: '#FCFDFE' }}>
        {stats.map(([label, value, color], i) => (
          <div key={label} style={{
            flex: 1, padding: '11px 8px', textAlign: 'center',
            borderRight: i < stats.length - 1 ? '1px solid #F1F5F9' : 'none',
          }}>
            <div style={{ fontSize: 18, fontWeight: 800, lineHeight: 1.1, color,
                          fontVariantNumeric: 'tabular-nums' }}>{value}</div>
            <div style={{ fontSize: 9, fontWeight: 700, color: '#A6AFBD', textTransform: 'uppercase',
                          letterSpacing: '0.07em', marginTop: 2 }}>{label}</div>
          </div>
        ))}
      </div>

      {checkable.length > 0 && (
        open === 0 ? (
          <div style={{ padding: '12px 16px', background: '#F6FDF9', display: 'flex', gap: 9, alignItems: 'flex-start' }}>
            <i className="fas fa-circle-check" style={{ color: '#16A34A', fontSize: 14, marginTop: 1 }} />
            <div>
              <div style={{ fontSize: 12, fontWeight: 700, color: '#15803D' }}>
                All {checkable.length} point{checkable.length === 1 ? '' : 's'} reviewed
              </div>
              <div style={{ fontSize: 11, color: '#3F8A5F', marginTop: 2 }}>
                Nothing outstanding on this timesheet.
              </div>
            </div>
          </div>
        ) : (
          <div style={{ padding: '11px 16px 12px', background: '#FFFDF7' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
              <b style={{ fontSize: 10, fontWeight: 800, color: '#92400E', textTransform: 'uppercase', letterSpacing: '0.07em' }}>
                <i className="fas fa-triangle-exclamation" style={{ marginRight: 6 }} />Worth a look
              </b>
              <span style={{ fontSize: 10, fontWeight: 700, color: '#B45309', background: '#FEF3C7',
                             borderRadius: 10, padding: '1px 8px' }}>
                {checkable.length - open} of {checkable.length} reviewed
              </span>
            </div>
            {checkable.map((e, i) => {
              const key = `${e.id}-${i}`;
              const done = !!seen[key];
              return (
                <label
                  key={key}
                  onClick={ev => { ev.preventDefault(); setSeen(s => ({ ...s, [key]: !s[key] })); }}
                  style={{
                    display: 'flex', alignItems: 'flex-start', gap: 9, fontSize: 11.5, lineHeight: 1.45,
                    padding: '4px 0', cursor: 'pointer', userSelect: 'none',
                    color: done ? '#A6AFBD' : '#78350F',
                    textDecoration: done ? 'line-through' : 'none',
                  }}
                >
                  <input type="checkbox" checked={done} readOnly
                         style={{ margin: '1px 0 0', accentColor: '#B45309', cursor: 'pointer', flexShrink: 0 }} />
                  <span>{e.detail}</span>
                </label>
              );
            })}
            <div style={{ fontSize: 10.5, color: '#B08A56', marginTop: 7 }}>
              Ticking is for your own reading — it does not block approval and is not recorded.
            </div>
          </div>
        )
      )}
    </div>
  );
}
