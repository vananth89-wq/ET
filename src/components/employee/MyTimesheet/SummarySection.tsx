/**
 * Monthly Summary — the block below the calendar.
 *
 * Everything here is DERIVED from state the page already holds. No query, no
 * table, no endpoint: if a number here disagrees with the calendar above it,
 * that is a bug, not a refresh problem.
 *
 * Deliberately standalone — it takes plain values and one callback rather than
 * importing from index.tsx, which imports this. The few date helpers are
 * duplicated below for the same reason; a shared module would be the right fix
 * if a third consumer ever appears.
 */
import { useMemo } from 'react';

/** Structurally compatible with MyTimesheet's TimesheetEntry, without coupling
 *  to it. Only the fields this panel reads are named. */
interface SumEntry {
  entry_date:    string;
  entry_kind:    'project' | 'time_type' | 'holiday' | 'leave';
  hours_minutes: number;
  projects?:  { name: string } | { name: string }[];
  time_types?: { name: string } | { name: string }[];
}

const MONTHS = ['January','February','March','April','May','June',
                'July','August','September','October','November','December'];
const M3 = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const D3 = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

const pad2 = (n: number) => String(n).padStart(2, '0');
const iso  = (y: number, m: number, d: number) => `${y}-${pad2(m)}-${pad2(d)}`;
const dim  = (y: number, m: number) => new Date(y, m, 0).getDate();

/** Hours to one decimal, trailing ".0" dropped: 8, 6.5, 33.8. */
function h1(mins: number): string {
  const v = mins / 60;
  return (Math.round(v * 10) / 10).toString();
}

const C = {
  blue: '#2563EB', green: '#059669', amber: '#B45309', ink: '#111827',
  ink2: '#374151', ink3: '#6B7280', ink4: '#9CA3AF', rule: '#E5E7EB',
  hair: '#F1F2F5', track: '#F1F2F5',
};
/** Donut + legend colours by rank, so a project keeps one colour throughout. */
const RANK = ['#2563EB', '#7C3AED', '#0F766E', '#10B981', '#F59E0B', '#F97316', '#64748B'];

// ─── Small presentational pieces ─────────────────────────────────────────────

function Kpi({ label, value, unit, sub, tone }: {
  label: string; value: string; unit?: string; sub: string; tone: string;
}) {
  return (
    <div style={{ padding: '14px 16px', borderRight: `1px solid ${C.hair}` }}>
      <div style={{ fontSize: 10.5, fontWeight: 700, letterSpacing: '0.06em', color: C.ink4, textTransform: 'uppercase' }}>
        {label}
      </div>
      <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: '-0.02em', marginTop: 5, lineHeight: 1, color: tone }}>
        {value}{unit && <span style={{ fontSize: 12, fontWeight: 700, marginLeft: 2 }}>{unit}</span>}
      </div>
      <div style={{ fontSize: 11, color: '#98A2B3', marginTop: 5 }}>{sub}</div>
    </div>
  );
}

function Bar({ pct, color }: { pct: number; color: string }) {
  return (
    <div style={{ height: 8, borderRadius: 99, background: C.track, overflow: 'hidden' }}>
      <div style={{ height: 8, borderRadius: 99, width: `${Math.min(100, pct)}%`, background: color,
                    transition: 'width 0.4s ease-out' }} />
    </div>
  );
}

function Tag({ text, bg, fg }: { text: string; bg: string; fg: string }) {
  return (
    <span style={{ display: 'inline-block', fontSize: 10, fontWeight: 700, padding: '2px 7px',
                   borderRadius: 5, marginTop: 6, background: bg, color: fg }}>{text}</span>
  );
}

const panelSt: React.CSSProperties = {
  background: '#fff', border: `1px solid ${C.rule}`, borderRadius: 12, padding: 18,
};
const pTitleSt: React.CSSProperties = {
  fontSize: 13, fontWeight: 750, color: C.ink, marginBottom: 14,
  display: 'flex', justifyContent: 'space-between', alignItems: 'baseline',
};

// ─── The section ─────────────────────────────────────────────────────────────

export interface SummarySectionProps {
  year: number;
  month: number;                              // 1-12
  entries: SumEntry[];
  plannedMinutes: number;                     // header.planned_minutes
  /** Mirrors the calendar's own rule: 0 on a weekend or a holiday. */
  plannedFor: (dateStr: string) => number;
  todayIso: string;
  /** Chip click and the back link both come through here. */
  onJumpToDate: (dateStr: string | null) => void;
}

export default function SummarySection({
  year, month, entries, plannedMinutes, plannedFor, todayIso, onJumpToDate,
}: SummarySectionProps) {

  const d = useMemo(() => {
    const total = dim(year, month);
    const days = Array.from({ length: total }, (_, i) => {
      const date = iso(year, month, i + 1);
      return {
        date, day: i + 1, dow: new Date(year, month - 1, i + 1).getDay(),
        planned: plannedFor(date),
        minutes: entries.filter(e => e.entry_date === date)
                        .reduce((s, e) => s + e.hours_minutes, 0),
      };
    });

    const working  = days.filter(x => x.planned > 0);
    const recorded = days.reduce((s, x) => s + x.minutes, 0);
    // Days, not entries. Since mig 726 one day holds several entries, so
    // counting rows would have made a three-project Monday read as three days.
    const logged   = days.filter(x => x.minutes > 0).length;
    // A claim about the PAST only. Mig 729 forbids recording most types in
    // advance, so flagging the rest of the month would be scolding someone for
    // obeying the rules.
    const missing  = working.filter(x => x.minutes === 0 && x.date <= todayIso);
    const aheadN   = working.filter(x => x.date > todayIso).length;

    // Sun–Sat buckets, matching the calendar rows above.
    type Wk = { label: string; start: string; end: string; planned: number; minutes: number;
                missing: typeof days };
    const weeks: Wk[] = [];
    let bucket: typeof days = [];
    const flush = () => {
      if (!bucket.length) return;
      const f = bucket[0], l = bucket[bucket.length - 1];
      weeks.push({
        label: `${f.day} – ${l.day} ${M3[month - 1]}`,
        start: f.date, end: l.date,
        planned: bucket.reduce((s, x) => s + x.planned, 0),
        minutes: bucket.reduce((s, x) => s + x.minutes, 0),
        missing: bucket.filter(x => x.planned > 0 && x.minutes === 0 && x.date <= todayIso),
      });
      bucket = [];
    };
    for (const x of days) { if (x.dow === 0 && bucket.length) flush(); bucket.push(x); }
    flush();

    // Project split. Time with no project — training, leave — is one grey slice
    // rather than an omission, so the donut still totals Recorded.
    const byName = new Map<string, number>();
    let noProject = 0;
    for (const e of entries) {
      if (e.hours_minutes <= 0) continue;
      const p = Array.isArray(e.projects) ? e.projects[0] : e.projects;
      if (p?.name) byName.set(p.name, (byName.get(p.name) ?? 0) + e.hours_minutes);
      else noProject += e.hours_minutes;
    }
    const projects = [...byName.entries()]
      .map(([name, minutes]) => ({ name, minutes, noProject: false }))
      .sort((a, b) => b.minutes - a.minutes);
    if (noProject > 0) projects.push({ name: 'No project', minutes: noProject, noProject: true });

    return {
      days, working, recorded, logged, missing, aheadN, weeks, projects,
      // Clamped: past plan this is negative, and "−12h to log" is not a thing.
      remaining: Math.max(0, plannedMinutes - recorded),
      over:      Math.max(0, recorded - plannedMinutes),
      attain:    plannedMinutes > 0 ? (recorded / plannedMinutes) * 100 : 0,
      avgPerDay: logged > 0 ? recorded / logged : 0,
    };
  }, [year, month, entries, plannedMinutes, plannedFor, todayIso]);

  const pace = d.aheadN > 0 ? d.remaining / d.aheadN : 0;
  const donutTotal = d.projects.reduce((s, p) => s + p.minutes, 0);

  return (
    <div style={{ marginTop: 26 }}>

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 14 }}>
        <div style={{ fontSize: 16, fontWeight: 750, color: C.ink }}>
          Monthly Summary <span style={{ fontWeight: 500, color: C.ink4 }}>— {MONTHS[month - 1]} {year}</span>
        </div>
        <button
          onClick={() => onJumpToDate(null)}
          style={{ background: 'none', border: 'none', padding: 0, fontSize: 12.5, fontWeight: 600,
                   color: C.blue, cursor: 'pointer', font: 'inherit' }}
        >↑ Back to calendar</button>
      </div>

      {/* ── KPI strip ─────────────────────────────────────────────────── */}
      <div style={{
        display: 'grid', gridTemplateColumns: 'repeat(6, 1fr)', background: '#fff',
        border: `1px solid ${C.rule}`, borderRadius: 12, overflow: 'hidden', marginBottom: 14,
      }}>
        <Kpi label="Recorded"  value={h1(d.recorded)} unit="h" tone={C.blue}
             sub={`of ${h1(plannedMinutes)}h planned`} />
        {d.over > 0
          ? <Kpi label="Over plan" value={h1(d.over)} unit="h" tone={C.amber} sub="beyond the month's target" />
          : <Kpi label="Remaining" value={h1(d.remaining)} unit="h"
                 tone={d.attain < 80 ? C.amber : C.green} sub="to log this month" />}
        <Kpi label="Attainment" value={d.attain.toFixed(1)} unit="%" tone="#475569" sub="of monthly target" />
        <Kpi label="Days Logged" value={String(d.logged)} tone={C.green}
             sub={`of ${d.working.length} working days`} />
        <Kpi label="Missing Entries" value={String(d.missing.length)}
             tone={d.missing.length ? C.amber : C.ink4}
             sub={d.missing.length === 1 ? 'past day needs time logged' : 'past days need time logged'} />
        <Kpi label="Avg / Day" value={h1(d.avgPerDay)} unit="h" tone="#475569" sub="on days present" />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>

        {/* ── Weekly progress ───────────────────────────────────────── */}
        <div style={panelSt}>
          <div style={pTitleSt}>
            Weekly Progress
            <em style={{ fontStyle: 'normal', fontSize: 11, fontWeight: 600, color: C.ink4 }}>Sun – Sat</em>
          </div>

          {d.weeks.map((w, i) => {
            const done  = w.end <= todayIso;
            const start = w.start > todayIso;
            const pct   = w.planned > 0 ? (w.minutes / w.planned) * 100 : 0;
            // A week is only judged once it is over. Same rule as the calendar's
            // future days and the PDF's weekly cards.
            const tag = w.planned === 0        ? { t: 'Non-working',  bg: '#F3F4F6', fg: C.ink3 }
                      : start                  ? { t: 'Not yet due',  bg: '#F3F4F6', fg: C.ink3 }
                      : !done                  ? { t: 'In progress',  bg: '#EFF6FF', fg: '#1D4ED8' }
                      : pct >= 100             ? { t: 'Complete',     bg: '#ECFDF5', fg: '#047857' }
                      : pct > 0                ? { t: 'Partial',      bg: '#FEF6DC', fg: '#92400E' }
                      :                          { t: 'Nothing logged', bg: '#FEF6DC', fg: '#92400E' };
            const color = pct >= 100 ? '#10B981' : done ? '#F59E0B' : C.blue;

            return (
              <div key={w.start} style={{ marginBottom: i === d.weeks.length - 1 ? 0 : 13 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 5 }}>
                  <span style={{ fontSize: 12.5, fontWeight: 700, color: C.ink2 }}>
                    Wk {i + 1}
                    <i style={{ fontStyle: 'normal', fontWeight: 500, color: C.ink4, marginLeft: 7 }}>{w.label}</i>
                  </span>
                  <span style={{ fontSize: 12, fontWeight: 700, color: C.ink2 }}>
                    {w.minutes > 0 ? `${h1(w.minutes)}h` : '—'}
                    <em style={{ fontStyle: 'normal', fontWeight: 500, color: C.ink4 }}>
                      {' '}/ {h1(w.planned)}h
                    </em>
                  </span>
                </div>
                <Bar pct={pct} color={color} />
                <Tag text={tag.t} bg={tag.bg} fg={tag.fg} />
              </div>
            );
          })}

          <div style={{ marginTop: 16, paddingTop: 14, borderTop: `1px solid ${C.hair}` }}>
            <div style={{ fontSize: 11, fontWeight: 700, letterSpacing: '0.05em', color: C.ink4,
                          textTransform: 'uppercase', marginBottom: 8 }}>
              Days needing time — past only
            </div>
            {d.missing.length === 0 ? (
              <div style={{ fontSize: 12, color: C.ink4 }}>
                Nothing outstanding. Every working day up to today has time against it.
              </div>
            ) : (
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                {d.missing.map(m => (
                  <button
                    key={m.date}
                    onClick={() => onJumpToDate(m.date)}
                    style={{
                      background: '#FEF6DC', border: '1px solid #F6E2A0', color: '#92400E',
                      fontSize: 11.5, fontWeight: 600, borderRadius: 6, padding: '4px 9px',
                      cursor: 'pointer', font: 'inherit',
                    }}
                    onMouseEnter={e => (e.currentTarget.style.background = '#FCEFC7')}
                    onMouseLeave={e => (e.currentTarget.style.background = '#FEF6DC')}
                  >
                    {D3[m.dow]} {m.day} {M3[month - 1]} · {h1(m.planned)}h
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>

        {/* ── By project ────────────────────────────────────────────── */}
        <div style={panelSt}>
          <div style={pTitleSt}>
            By Project
            <em style={{ fontStyle: 'normal', fontSize: 11, fontWeight: 600, color: C.ink4 }}>
              {h1(donutTotal)}h of {h1(d.recorded)}h recorded
            </em>
          </div>

          {d.projects.length === 0 ? (
            <div style={{ fontSize: 12, color: C.ink4 }}>No time recorded yet this month.</div>
          ) : (
            <div style={{ display: 'flex', gap: 18, alignItems: 'center' }}>
              {/* r = 15.9155 gives a circumference of exactly 100, so a segment's
                  dash length IS its percentage. -25 offset starts it at 12 o'clock. */}
              <svg width={132} height={132} viewBox="0 0 42 42" style={{ flexShrink: 0 }}>
                <circle cx="21" cy="21" r="15.9155" fill="none" stroke={C.track} strokeWidth="5" />
                {(() => {
                  let cum = 0;
                  return d.projects.map((p, i) => {
                    const pct = donutTotal > 0 ? (p.minutes / donutTotal) * 100 : 0;
                    const off = 25 - cum;
                    cum += pct;
                    return (
                      <circle key={p.name} cx="21" cy="21" r="15.9155" fill="none" strokeWidth="5"
                        stroke={p.noProject ? '#9CA3AF' : RANK[Math.min(i, RANK.length - 1)]}
                        strokeDasharray={`${pct} ${100 - pct}`} strokeDashoffset={off} />
                    );
                  });
                })()}
                <text x="21" y="20.6" textAnchor="middle" fontSize="7" fontWeight="800" fill={C.ink}>
                  {h1(d.recorded)}h
                </text>
                <text x="21" y="25.4" textAnchor="middle" fontSize="3.1" fontWeight="700" fill={C.ink4}>
                  RECORDED
                </text>
              </svg>

              <div style={{ flex: 1 }}>
                {d.projects.map((p, i) => (
                  <div key={p.name} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 9 }}>
                    <span style={{ width: 9, height: 9, borderRadius: 3, flex: 'none',
                                   background: p.noProject ? '#9CA3AF' : RANK[Math.min(i, RANK.length - 1)] }} />
                    <span style={{ flex: 1, fontSize: 12.5, fontWeight: 600,
                                   color: p.noProject ? C.ink4 : C.ink2 }}>{p.name}</span>
                    <span style={{ fontSize: 12.5, fontWeight: 700, color: p.noProject ? C.ink3 : C.ink }}>
                      {h1(p.minutes)}h
                    </span>
                    <span style={{ fontSize: 11.5, color: C.ink4, width: 34, textAlign: 'right' }}>
                      {donutTotal > 0 ? Math.round((p.minutes / donutTotal) * 100) : 0}%
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}

          <div style={{ marginTop: 18, paddingTop: 15, borderTop: `1px solid ${C.hair}` }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 6 }}>
              <span style={{ fontSize: 12, fontWeight: 700, color: C.ink2 }}>Attainment</span>
              <span style={{ fontSize: 12, fontWeight: 700, color: d.attain >= 100 ? C.green : C.blue }}>
                {d.attain.toFixed(1)}%
              </span>
            </div>
            <Bar pct={d.attain} color={d.attain >= 100 ? '#10B981' : C.blue} />
            <div style={{ fontSize: 11.5, color: '#98A2B3', marginTop: 8, lineHeight: 1.55 }}>
              {d.remaining === 0
                ? 'The month’s planned hours are fully recorded.'
                : d.aheadN === 0
                ? <>No working days left this month — <b style={{ color: C.ink2 }}>{h1(d.remaining)}h</b> of the plan is unrecorded.</>
                : <>On track if you log an average of <b style={{ color: C.ink2 }}>{h1(pace)}h/day</b> across
                   the <b style={{ color: C.ink2 }}>{d.aheadN} working {d.aheadN === 1 ? 'day' : 'days'}</b> left this month.</>}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
