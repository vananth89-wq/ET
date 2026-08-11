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
  /** Mig 727's itemised rows. Already loaded with every entry by the page
   *  above; this panel simply never read them until the project breakdown. */
  timesheet_entry_activities?: Array<{
    activity_name: string; hours_minutes: number; display_order: number;
  }> | null;
  /** Legacy names with no hours against them, from before 727. */
  activities?: string[] | null;
}

const MONTHS = ['January','February','March','April','May','June',
                'July','August','September','October','November','December'];
const M3 = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const D3 = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

const pad2 = (n: number) => String(n).padStart(2, '0');
const iso  = (y: number, m: number, d: number) => `${y}-${pad2(m)}-${pad2(d)}`;
const dim  = (y: number, m: number) => new Date(y, m, 0).getDate();

/**
 * Whole percentages that total 100.
 *
 * Rounding each share on its own is how a four-project month printed 45 + 30 +
 * 18 + 6 = 99, and a column of numbers that does not add up undermines the ones
 * beside it that do. Largest-remainder: everyone gets their floor, the leftover
 * points go to whichever shares were cut hardest.
 *
 * Duplicated from the PDF's dataTransforms rather than imported, for the same
 * reason the date helpers above are — this panel deliberately depends on
 * nothing. A shared module is the right fix if a third consumer appears.
 */
function wholePercents(values: number[], total: number): number[] {
  if (total <= 0 || values.length === 0) return values.map(() => 0);
  const exact  = values.map(v => (v / total) * 100);
  const out    = exact.map(Math.floor);
  let leftover = 100 - out.reduce((s, n) => s + n, 0);
  const byFrac = exact
    .map((e, i) => ({ i, frac: e - Math.floor(e) }))
    .sort((a, b) => b.frac - a.frac);
  for (let k = 0; k < byFrac.length && leftover > 0; k++, leftover--) out[byFrac[k].i] += 1;
  return out;
}

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

/**
 * Work and leave, side by side in one track.
 *
 * Leave carries real hours — `timesheet_entries` has CHECK (hours_minutes > 0),
 * so a leave row can never be zero — and those hours land in the week's total.
 * Without the split a week spent entirely on annual leave reads 40h / 40h,
 * green, "Complete", indistinguishable from a week of solid work. The total is
 * right either way; the composition was the part you could not see.
 */
function SplitBar({ workPct, leavePct, workColor }: {
  workPct: number; leavePct: number; workColor: string;
}) {
  return (
    <div style={{ display: 'flex', height: 8, borderRadius: 99, background: C.track, overflow: 'hidden' }}>
      <div style={{ height: 8, width: `${workPct}%`, background: workColor,
                    transition: 'width 0.4s ease-out' }} />
      {/* A lighter tint of the calendar's leave blue: same family, visibly
          subordinate — hours accounted for rather than hours worked. */}
      <div style={{ height: 8, width: `${leavePct}%`, background: '#93C5FD',
                    transition: 'width 0.4s ease-out' }} />
    </div>
  );
}

function Tag({ text, bg, fg, mt = 6 }: { text: string; bg: string; fg: string; mt?: number }) {
  return (
    <span style={{ display: 'inline-block', fontSize: 10, fontWeight: 700, padding: '2px 7px',
                   borderRadius: 5, marginTop: mt, background: bg, color: fg,
                   whiteSpace: 'nowrap' }}>{text}</span>
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
  /** Only to EXPLAIN a week's reduced target. Holidays are master data in
   *  time_calendar_entries, never attendance rows: they contribute no recorded
   *  hours and no planned hours, so there is nothing of them to put in a bar —
   *  but a week that silently reads /32h instead of /40h looks like a fault. */
  holidayByDate: Record<string, string>;
  todayIso: string;
  /** Chip click and the back link both come through here. */
  onJumpToDate: (dateStr: string | null) => void;
}

export default function SummarySection({
  year, month, entries, plannedMinutes, plannedFor, holidayByDate, todayIso, onJumpToDate,
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
        leave:   entries.filter(e => e.entry_date === date && e.entry_kind === 'leave')
                        .reduce((s, e) => s + e.hours_minutes, 0),
        isHol:   !!holidayByDate[date],
      };
    });

    const working  = days.filter(x => x.planned > 0);
    const recorded = days.reduce((s, x) => s + x.minutes, 0);
    // Days, not entries. Since mig 726 one day holds several entries, so
    // counting rows would have made a three-project Monday read as three days.
    const logged   = days.filter(x => x.minutes > 0).length;
    // A claim about the PAST only, and today is not past. You cannot have
    // missed a day that has not ended — flagging it turns a normal morning into
    // an outstanding item. Mig 729 rules out the rest of the month for the same
    // reason: most types cannot be recorded in advance at all.
    const missing  = working.filter(x => x.minutes === 0 && x.date < todayIso);
    /** Today, if it is a working day with nothing on it yet. Reported neutrally
     *  beside the chips rather than counted among them. */
    const todayOpen = working.find(x => x.date === todayIso && x.minutes === 0) ?? null;
    const aheadN   = working.filter(x => x.date > todayIso).length;

    /**
     * Which weekdays this schedule actually works.
     *
     * plannedFor() returns 0 for a holiday AND for a weekend, so a day's own
     * planned figure cannot say which it was. Reading it across the month can:
     * if any NON-holiday day sharing this weekday is planned, the weekday is a
     * working one. Needed because a holiday that lands on a Saturday costs the
     * week nothing, and a "1 holiday" note against an unchanged /40h target
     * explains a reduction that never happened — the note's only job.
     */
    const workingDows = new Set(days.filter(x => !x.isHol && x.planned > 0).map(x => x.dow));

    // Sun–Sat buckets, matching the calendar rows above.
    type Wk = { label: string; start: string; end: string; planned: number; minutes: number;
                leave: number; holidays: number; missing: typeof days };
    const weeks: Wk[] = [];
    let bucket: typeof days = [];
    const flush = () => {
      if (!bucket.length) return;
      const f = bucket[0], l = bucket[bucket.length - 1];
      weeks.push({
        label: f.day === l.day ? `${f.day} ${M3[month - 1]}`
                               : `${f.day}–${l.day} ${M3[month - 1]}`,
        start: f.date, end: l.date,
        planned:  bucket.reduce((s, x) => s + x.planned, 0),
        minutes:  bucket.reduce((s, x) => s + x.minutes, 0),
        leave:    bucket.reduce((s, x) => s + x.leave, 0),
        holidays: bucket.filter(x => x.isHol && workingDows.has(x.dow)).length,
        missing:  bucket.filter(x => x.planned > 0 && x.minutes === 0 && x.date < todayIso),
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

    // ── Project → activities ────────────────────────────────────────────
    // PROJECT-BEARING ENTRIES ONLY. Training, leave and any other time with no
    // project against it are absent here on purpose: they have no project to
    // sit under, and inventing a card for each would make this block a second,
    // worse version of the donut above — which is exactly why the donut stays.
    // The two answer different questions and say so in their headings.
    type Act  = { name: string; minutes: number; itemised: boolean };
    type Proj = { name: string; minutes: number; days: number; acts: Act[] };

    const projMap = new Map<string, { minutes: number; days: Set<string>; acts: Map<string, Act> }>();
    for (const e of entries) {
      if (e.hours_minutes <= 0) continue;
      const p = Array.isArray(e.projects) ? e.projects[0] : e.projects;
      if (!p?.name) continue;

      const row = projMap.get(p.name) ?? { minutes: 0, days: new Set<string>(), acts: new Map() };
      row.minutes += e.hours_minutes;
      row.days.add(e.entry_date);

      const add = (name: string, minutes: number, itemised: boolean) => {
        const cur = row.acts.get(name);
        if (cur) { cur.minutes += minutes; cur.itemised = cur.itemised && itemised; }
        else row.acts.set(name, { name, minutes, itemised });
      };

      const rows = e.timesheet_entry_activities ?? [];
      const itemisedTotal = rows.reduce((s, a) => s + (a.hours_minutes ?? 0), 0);

      for (const a of rows) {
        if ((a.hours_minutes ?? 0) > 0) add(a.activity_name, a.hours_minutes, true);
      }

      // The safety net. Every entry saved through the app is itemised, so this
      // should never draw — but a card whose lines total less than its own
      // header is the failure that made the PDF's two summaries disagree, and
      // an unexplained gap is worse than a named one. Covers a pre-727 entry
      // (names, no hours) and anything written straight to the table.
      const gap = e.hours_minutes - itemisedTotal;
      if (gap > 0) add('Not itemised', gap, false);

      projMap.set(p.name, row);
    }

    const projectActs: Proj[] = [...projMap.entries()]
      .map(([name, r]) => ({
        name, minutes: r.minutes, days: r.days.size,
        acts: [...r.acts.values()].sort((a, b) =>
          // "Not itemised" is a caveat, not a finding: it sits last whatever
          // its size, so the real work reads first.
          a.itemised === b.itemised ? b.minutes - a.minutes : a.itemised ? -1 : 1),
      }))
      .sort((a, b) => b.minutes - a.minutes);

    const projectTotal = projectActs.reduce((s, p) => s + p.minutes, 0);

    return {
      days, working, recorded, logged, missing, todayOpen, aheadN, weeks, projects,
      projectActs, projectTotal,
      // Clamped: past plan this is negative, and "−12h to log" is not a thing.
      remaining: Math.max(0, plannedMinutes - recorded),
      over:      Math.max(0, recorded - plannedMinutes),
      attain:    plannedMinutes > 0 ? (recorded / plannedMinutes) * 100 : 0,
      avgPerDay: logged > 0 ? recorded / logged : 0,
    };
  }, [year, month, entries, plannedMinutes, plannedFor, todayIso]);

  const pace = d.aheadN > 0 ? d.remaining / d.aheadN : 0;
  const donutTotal = d.projects.reduce((s, p) => s + p.minutes, 0);
  const donutPcts  = wholePercents(d.projects.map(p => p.minutes), donutTotal);
  const projPcts   = wholePercents(d.projectActs.map(p => p.minutes), d.projectTotal);

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
            const over  = w.planned > 0 && w.minutes > w.planned;
            const work  = w.minutes - w.leave;

            // Fill is capped at the track; the overshoot is named in the tag
            // instead. Work and leave then split that fill by their real share,
            // so the two segments always sum to the bar and never to more.
            const fill    = Math.min(100, pct);
            const workPct  = w.minutes > 0 ? fill * (work / w.minutes)     : 0;
            const leavePct = w.minutes > 0 ? fill * (w.leave / w.minutes)  : 0;

            // A week is only judged once it is over. Same rule as the calendar's
            // future days and the PDF's weekly cards — and OVER is its own state,
            // amber and named. It used to fall into `pct >= 100` and print
            // "Complete" in green while sitting eight hours beyond the plan.
            const tag = w.planned === 0 ? { t: 'Non-working',   bg: '#F3F4F6', fg: C.ink3 }
                      : start           ? { t: 'Not yet due',   bg: '#F3F4F6', fg: C.ink3 }
                      : over            ? { t: `Over by ${h1(w.minutes - w.planned)}h`,
                                                                bg: '#FEF6DC', fg: '#92400E' }
                      : !done           ? { t: 'In progress',   bg: '#EFF6FF', fg: '#1D4ED8' }
                      : pct >= 100      ? { t: 'Complete',      bg: '#ECFDF5', fg: '#047857' }
                      : pct > 0         ? { t: 'Partial',       bg: '#FEF6DC', fg: '#92400E' }
                      :                   { t: 'Nothing logged', bg: '#FEF6DC', fg: '#92400E' };

            const workColor = over ? '#F59E0B' : pct >= 100 ? '#10B981' : C.blue;

            /* ONE LINE PER WEEK.
               Four weeks used to occupy three stacked rows each — label, bar,
               tag — which is most of a screen for four numbers. Everything that
               was in those rows is still here except the "incl. Xh leave"
               caption: the bar's second segment already IS that fact, and the
               words were only naming it.

               The holiday note stays. It is the only thing explaining why a
               week reads /32h while its neighbours read /40h, and without it a
               short week looks like an arithmetic fault rather than a public
               holiday. */
            return (
              <div key={w.start} style={{
                display: 'flex', alignItems: 'center', gap: 12,
                padding: '7px 0',
                borderTop: i === 0 ? 'none' : `1px solid ${C.hair}`,
              }}>
                {/* WEEK NUMBER LEFT, DATE FAR RIGHT.
                    They used to sit side by side — "Wk 1  1 – 1 Aug" — two
                    labels competing for the same job at the same moment. Moving
                    them apart lets the number anchor the row and turns the date
                    into a reference you read only when you want it.

                    Fixed width, so every bar starts at the same x and the weeks
                    can be compared by bar length alone, which is the whole
                    point of drawing bars. */}
                <div style={{ width: 104, flexShrink: 0, fontSize: 12.5, lineHeight: 1.35 }}>
                  <span style={{ fontWeight: 700, color: C.ink2 }}>Week {i + 1}</span>
                  {/* Only holidays that actually cost this week hours. One that
                      falls on a weekend leaves the target untouched, and a note
                      against an unchanged /40h explains nothing. */}
                  {w.holidays > 0 && (
                    <div style={{ fontSize: 10.5, fontWeight: 600, color: '#7C3AED' }}>
                      {w.holidays} {w.holidays === 1 ? 'holiday' : 'holidays'}
                    </div>
                  )}
                </div>

                <div style={{ flex: 1, minWidth: 70 }}>
                  <SplitBar workPct={workPct} leavePct={leavePct} workColor={workColor} />
                </div>

                <div style={{ width: 84, flexShrink: 0, textAlign: 'right', fontSize: 12,
                              fontWeight: 700, color: w.minutes > 0 ? C.ink2 : C.ink4 }}>
                  {w.minutes > 0 ? `${h1(w.minutes)}h` : '—'}
                  <em style={{ fontStyle: 'normal', fontWeight: 500, color: C.ink4 }}>
                    {' '}/ {h1(w.planned)}h
                  </em>
                </div>

                {/* Fixed width and right-aligned content, so the pills form a
                    column instead of ragging against the hours beside them. */}
                <div style={{ width: 90, flexShrink: 0, display: 'flex', justifyContent: 'flex-end' }}>
                  <Tag text={tag.t} bg={tag.bg} fg={tag.fg} mt={0} />
                </div>

                <div style={{ width: 72, flexShrink: 0, textAlign: 'right',
                              fontSize: 11.5, color: C.ink4 }}>
                  {w.label}
                </div>
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
                Nothing outstanding. Every working day before today has time against it.
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

            {/* Today is not missing — it has not finished. Neutral, and below
                the chips rather than counted among them. */}
            {d.todayOpen && (
              <button
                onClick={() => onJumpToDate(d.todayOpen!.date)}
                style={{
                  marginTop: d.missing.length ? 9 : 0, background: 'none', border: 'none',
                  padding: 0, font: 'inherit', fontSize: 11.5, color: C.ink3,
                  cursor: 'pointer', textAlign: 'left', display: 'block',
                }}
              >
                Today ({D3[d.todayOpen.dow]} {d.todayOpen.day} {M3[month - 1]}) has nothing logged yet —
                <span style={{ color: C.blue, fontWeight: 600 }}> open it</span>
              </button>
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
                      {donutPcts[i]}%
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

      {/* ── By project & activity ─────────────────────────────────────────
          PROJECT TIME ONLY, and the heading says so.

          The donut above answers "where did the month go?" and includes the
          non-project time — training, leave — that has no project to sit
          under. This answers the next question down: within the project work,
          what was actually done. Two blocks, two denominators, each stated
          rather than assumed. That distinction is the whole reason the donut
          stays; without it this would be a second, worse version of it.

          Percentages are of PROJECT time, so they total 100 inside this block.
          Reading them against the month would leave a silent remainder equal
          to the donut's grey slice, which is the arithmetic that made the
          PDF's two summaries disagree. */}
      {d.projectActs.length > 0 && (
        <div style={{ ...panelSt, marginTop: 14 }}>
          <div style={pTitleSt}>
            By Project &amp; Activity
            <em style={{ fontStyle: 'normal', fontSize: 11, fontWeight: 600, color: C.ink4 }}>
              {h1(d.projectTotal)}h of project time · {d.projectActs.length}{' '}
              {d.projectActs.length === 1 ? 'project' : 'projects'}
            </em>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 12 }}>
            {d.projectActs.map((p, i) => {
              const colour  = RANK[Math.min(i, RANK.length - 1)];
              // Each activity bar is scaled to the LARGEST activity in its own
              // card, not to the project total. Scaling to the total makes a
              // four-way split render as four stubs and the reader compares
              // nothing; within a card the question is which activity dominated.
              const widest  = Math.max(...p.acts.map(a => a.minutes), 1);

              return (
                <div key={p.name} style={{
                  border: `1px solid ${C.rule}`, borderRadius: 10, overflow: 'hidden',
                  background: '#fff',
                }}>
                  <div style={{
                    display: 'flex', alignItems: 'center', gap: 8,
                    padding: '10px 12px', background: '#FBFCFD',
                    borderBottom: `1px solid ${C.hair}`,
                  }}>
                    <span style={{ width: 9, height: 9, borderRadius: 3, flex: 'none', background: colour }} />
                    <span style={{ flex: 1, fontSize: 13, fontWeight: 750, color: C.ink }}>{p.name}</span>
                    <span style={{ fontSize: 13, fontWeight: 750, color: C.ink }}>{h1(p.minutes)}h</span>
                    <span style={{ fontSize: 11, fontWeight: 600, color: C.ink4 }}>
                      {projPcts[i]}%
                    </span>
                  </div>

                  <div style={{ padding: '4px 12px 10px' }}>
                    {p.acts.map((a, j) => (
                      <div key={a.name} style={{ paddingTop: 8 }}>
                        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                          <span style={{ fontSize: 11, color: C.ink4, width: 14, flex: 'none' }}>
                            {j + 1}.
                          </span>
                          <span style={{
                            flex: 1, fontSize: 12.5, minWidth: 0,
                            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                            // The caveat row is muted and italic so it never
                            // reads as something somebody typed.
                            color: a.itemised ? C.ink2 : C.ink4,
                            fontStyle: a.itemised ? 'normal' : 'italic',
                          }}>{a.name}</span>
                          <span style={{ fontSize: 12.5, fontWeight: 700,
                                         color: a.itemised ? C.ink : C.ink3 }}>
                            {h1(a.minutes)}h
                          </span>
                        </div>
                        <div style={{ marginTop: 4, marginLeft: 22, height: 3, borderRadius: 99,
                                      background: C.track, overflow: 'hidden' }}>
                          <div style={{
                            height: 3, borderRadius: 99,
                            width: `${(a.minutes / widest) * 100}%`,
                            background: a.itemised ? colour : '#D1D5DB',
                          }} />
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
