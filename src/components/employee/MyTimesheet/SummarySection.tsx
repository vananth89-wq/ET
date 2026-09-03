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
import { splitEntry, EMPTY_SPLIT, billableSharePct } from './billability';
import type { ProjectClass, BillSplit } from './billability';

/** Structurally compatible with MyTimesheet's TimesheetEntry, without coupling
 *  to it. Only the fields this panel reads are named. */
interface SumEntry {
  entry_date:    string;
  entry_kind:    'project' | 'time_type' | 'holiday' | 'leave';
  hours_minutes: number;
  /** The BOOKED project. NULL on cross-project help (801), where the id the
   *  employee chose lives in related_project_id instead. */
  project_id?: string | null;
  projects?:  { name: string } | { name: string }[];
  /** mig 801/827/829. Help given: the project HELPED, the short word its time
   *  type wants after it, and who asked. These hours are the employee's own
   *  work and belong in their month; they are deliberately not the helped
   *  project's, which is why they are grouped apart from it everywhere. */
  related_project_id?: string | null;
  related_projects?: { name: string } | { name: string }[];
  help_requester?: { name: string } | { name: string }[];
  time_types?: SumType | SumType[];
  /** Mig 727's itemised rows. Already loaded with every entry by the page
   *  above; this panel simply never read them until the project breakdown.
   *  `is_billable` since 821 — true, false, or NULL for "never asked". */
  timesheet_entry_activities?: Array<{
    activity_name: string; hours_minutes: number; display_order: number;
    is_billable?: boolean | null;
  }> | null;
  /** Legacy names with no hours against them, from before 727. */
  activities?: string[] | null;
}

interface SumType {
  name: string;
  related_project_label?: string | null;
}

/** One value of the pair, whichever shape PostgREST returned. */
const one = <T,>(v: T | T[] | undefined | null): T | null =>
  (Array.isArray(v) ? v[0] : v) ?? null;

/**
 * "AMPTJ (Support)" for a help entry, null for anything else.
 *
 * The same rule as MyTimesheet's entryDisplayName, and the word comes from the
 * TIME TYPE (827) rather than from here. Restated because this panel depends on
 * nothing — the same reason its date helpers are duplicated — but if the rule
 * changes, both change.
 */
function supportLabel(e: SumEntry): string | null {
  if (e.project_id || !e.related_project_id) return null;
  const name = one(e.related_projects)?.name;
  if (!name) return null;
  const t = one(e.time_types);
  const word = (t?.related_project_label ?? '').trim() || (t?.name ?? '').trim();
  return word ? `${name} (${word})` : name;
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
  hair: '#F1F2F5',
  /* The bar TRACK, no longer the same value as the hairline. They were one hex
   * doing two jobs, and only one of them wants to be darker: every fill that
   * sits on this is measured against it. */
  track: '#E9EEF3',
};
/** Donut + legend colours by rank, so a project keeps one colour throughout. */
/* The last entry was #64748B until BILL_SLATE took that exact hex. RANK[6] is
 * the ink EVERY 7th-and-beyond project takes, so a month with seven projects
 * would have drawn one of them in the colour that means "not billable"
 * everywhere else on the same screen. Changed now because it is free to change
 * now: nobody has seven projects in a month yet, so nothing on screen moves. */
const RANK = ['#2563EB', '#7C3AED', '#0F766E', '#10B981', '#F59E0B', '#F97316', '#A21CAF'];
/** Non-project time: a neutral ramp, deliberately quieter than the projects. */
const NEUTRAL = ['#94A3B8', '#CBD5E1', '#B8C0CC', '#DDE3EA'];
/** Leave is the exception — it keeps the tint the weekly bars already use for
 *  it, so the segment in a bar and the slice in the donut are the same fact. */
const LEAVE_BLUE = '#93C5FD';
/** Chargeable time. Deliberately the same green the Utilisation report's
 *  Billable share tile uses, so the two read as one fact in two places. */
const BILL_GREEN = '#0F8A6A';
/** The chargeable bar's other two inks. Amber for unclassified rather than a
 *  second grey: it is a question nobody has answered yet, not a settled "no",
 *  and the two should not look alike. */
/* NOT-CHARGEABLE TIME, WHEREVER IT IS DRAWN -- the month's Chargeable bar and
 * every project card below it. It was #B8C0CC, which measures 1.6:1 against
 * the #F1F2F5 track these bars sit on: under the 3:1 floor for a non-text
 * graphic, and on a 4px bar the segment simply was not there. The activity
 * bars had the same fault one shade lighter.
 *
 * SLATE RATHER THAN A WARNING COLOUR. Non-billable hours are not a failure --
 * internal rework, training, a fixed-price overrun are all legitimate. Drawing
 * them in red would put quiet pressure on the person filling the sheet to
 * record fewer of them, and the honesty of that number is the only thing this
 * whole feature rests on.
 *
 * Close to RANK[6] (#64748B), which is the colour a 7th-and-beyond project
 * takes. Accepted: seven projects on one month's sheet is rare, and the
 * project's own ink appears only in the card's header dot once a card has a
 * chargeability story to tell. */
const BILL_SLATE = '#64748B';
const BILL_AMBER = '#E0A33A';
/** Fallback ink for a help card the donut did not draw. Normally these cards
 *  take the colour of their own slice above -- one thing, one colour, the rule
 *  this panel already holds for projects. */
const HELP_INK = '#7C3AED';

/** One colour rule, used by the donut and by its legend, so the two can never
 *  disagree about which slice is which. */
function sliceColor(p: { noProject: boolean; isLeave: boolean }, rank: number, otherRank: number) {
  if (p.isLeave)   return LEAVE_BLUE;
  if (p.noProject) return NEUTRAL[Math.min(otherRank, NEUTRAL.length - 1)];
  return RANK[Math.min(rank, RANK.length - 1)];
}

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
  /**
   * What a project is worth — billable, non_billable or unclassified, from
   * `project_billability()` (mig 825). NULL for an id this page has not heard
   * of, and for no id at all.
   *
   * A callback rather than the map itself, for the same reason `plannedFor` is
   * one: this panel depends on nothing it does not read.
   */
  classOfProject: (projectId: string | null | undefined) => ProjectClass | null;
}

export default function SummarySection({
  year, month, entries, plannedMinutes, plannedFor, holidayByDate, todayIso, onJumpToDate,
  classOfProject,
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

    // ── Project split ───────────────────────────────────────────────────
    // Non-project time is named by its TIME TYPE — Annual Leave, Training —
    // rather than collapsed into one grey "No project" slice.
    //
    // The lump was the reason a month with eight hours of leave in it could be
    // read end to end without the word appearing once: the hours were in
    // Recorded, in the day cell, and in the weekly bar's second segment, and
    // nowhere did anything say what they were. This is the block that exists to
    // cover non-project time, so it is the block that has to name it.
    const byName  = new Map<string, number>();
    const byOther = new Map<string, { minutes: number; isLeave: boolean }>();
    for (const e of entries) {
      if (e.hours_minutes <= 0) continue;
      const p = Array.isArray(e.projects) ? e.projects[0] : e.projects;
      if (p?.name) { byName.set(p.name, (byName.get(p.name) ?? 0) + e.hours_minutes); continue; }

      /* Help given, named per project HELPED -- "AMPTJ (Support)" -- rather
       * than collapsed into one slice called after the time type.
       *
       * This block read `e.projects`, which is NULL on a help entry, so all of
       * a month's help fell through to the time-type name below and became a
       * single grey slice. The PDF's donut had already learnt to group these
       * per project when the label was carried through, so the same month drew
       * one slice on screen and three in the file. Two shapes of one fact. */
      const help = supportLabel(e);
      if (help) { byName.set(help, (byName.get(help) ?? 0) + e.hours_minutes); continue; }

      const t = Array.isArray(e.time_types) ? e.time_types[0] : e.time_types;
      const key = t?.name ?? 'Other attendance';
      const cur = byOther.get(key);
      if (cur) { cur.minutes += e.hours_minutes; cur.isLeave = cur.isLeave || e.entry_kind === 'leave'; }
      else byOther.set(key, { minutes: e.hours_minutes, isLeave: e.entry_kind === 'leave' });
    }

    const projects = [
      ...[...byName.entries()]
        .map(([name, minutes]) => ({ name, minutes, noProject: false, isLeave: false }))
        .sort((a, b) => b.minutes - a.minutes),
      // Non-project groups come after the projects whatever their size, so the
      // donut's colour ranking still tracks project order and a project keeps
      // the same colour here and in the cards below.
      ...[...byOther.entries()]
        .map(([name, r]) => ({ name, minutes: r.minutes, noProject: true, isLeave: r.isLeave }))
        .sort((a, b) => b.minutes - a.minutes),
    ];

    const leaveMinutes = days.reduce((s, x) => s + x.leave, 0);
    const leaveDays    = days.filter(x => x.leave > 0).length;

    // ── Project → activities ────────────────────────────────────────────
    // PROJECT-BEARING ENTRIES ONLY. Training, leave and any other time with no
    // project against it are absent here on purpose: they have no project to
    // sit under, and inventing a card for each would make this block a second,
    // worse version of the donut above — which is exactly why the donut stays.
    // The two answer different questions and say so in their headings.
    type Act  = { name: string; minutes: number; itemised: boolean; billable: boolean | null };
    type Proj = { name: string; minutes: number; days: number; acts: Act[];
                  cls: ProjectClass | null; split: BillSplit };

    const projMap = new Map<string, {
      minutes: number; days: Set<string>; acts: Map<string, Act>;
      cls: ProjectClass | null; split: BillSplit;
    }>();
    for (const e of entries) {
      if (e.hours_minutes <= 0) continue;
      const p = Array.isArray(e.projects) ? e.projects[0] : e.projects;
      if (!p?.name) continue;

      const cls = classOfProject(e.project_id);
      const row = projMap.get(p.name)
        ?? { minutes: 0, days: new Set<string>(), acts: new Map(), cls, split: { ...EMPTY_SPLIT } };
      row.minutes += e.hours_minutes;
      row.days.add(e.entry_date);

      const s = splitEntry(
        { entry_kind: e.entry_kind, hours_minutes: e.hours_minutes, project_id: e.project_id,
          activities: e.timesheet_entry_activities ?? [] }, cls);
      row.split.billable     += s.billable;
      row.split.nonBillable  += s.nonBillable;
      row.split.unclassified += s.unclassified;
      row.split.absence      += s.absence;
      row.split.worked       += s.worked;

      /**
       * KEYED ON THE NAME **AND** THE ANSWER, since mig 824.
       *
       * "Testing" billable and "Testing" not billable are two rows in the
       * database and two different facts about the day — ten hours exploring a
       * ticket and two writing the fix. Folding them on the name alone, as this
       * did, would print one twelve-hour line and quietly contradict both the
       * day panel above and the Utilisation report. The key here has to be the
       * same key the unique index uses.
       */
      const add = (name: string, minutes: number, itemised: boolean, billable: boolean | null) => {
        const key = `${name}\u0000${billable === null ? '' : billable}`;
        const cur = row.acts.get(key);
        if (cur) { cur.minutes += minutes; cur.itemised = cur.itemised && itemised; }
        else row.acts.set(key, { name, minutes, itemised, billable });
      };

      const rows = e.timesheet_entry_activities ?? [];
      const itemisedTotal = rows.reduce((s2, a) => s2 + (a.hours_minutes ?? 0), 0);

      for (const a of rows) {
        if ((a.hours_minutes ?? 0) > 0) {
          add(a.activity_name, a.hours_minutes, true, a.is_billable ?? null);
        }
      }

      // The safety net. Every entry saved through the app is itemised, so this
      // should never draw — but a card whose lines total less than its own
      // header is the failure that made the PDF's two summaries disagree, and
      // an unexplained gap is worse than a named one. Covers a pre-727 entry
      // (names, no hours) and anything written straight to the table.
      const gap = e.hours_minutes - itemisedTotal;
      if (gap > 0) add('Not itemised', gap, false, null);

      projMap.set(p.name, row);
    }

    const projectActs: Proj[] = [...projMap.entries()]
      .map(([name, r]) => ({
        name, minutes: r.minutes, days: r.days.size, cls: r.cls, split: r.split,
        acts: [...r.acts.values()].sort((a, b) =>
          // "Not itemised" is a caveat, not a finding: it sits last whatever
          // its size, so the real work reads first.
          a.itemised === b.itemised ? b.minutes - a.minutes : a.itemised ? -1 : 1),
      }))
      .sort((a, b) => b.minutes - a.minutes);

    const projectTotal = projectActs.reduce((s, p) => s + p.minutes, 0);

    // ── Help given to other projects ────────────────────────────────────
    // A SEPARATE block, not extra cards in the one above. Merging 5h of help
    // into AMPTJ's card would report that AMPTJ got 63h when 58 are its own --
    // the exact claim these hours are kept out of the project's burn to avoid.
    // Same arrangement as the server side, where 810 reports support through
    // its own CTEs rather than by widening the ones that measure the project.
    type Help = { name: string; minutes: number; days: number;
                  askers: string[]; acts: Act[] };
    const helpMap = new Map<string, {
      minutes: number; days: Set<string>; askers: Set<string>; acts: Map<string, Act>;
    }>();
    for (const e of entries) {
      if (e.hours_minutes <= 0) continue;
      const label = supportLabel(e);
      if (!label) continue;

      const row = helpMap.get(label)
        ?? { minutes: 0, days: new Set<string>(), askers: new Set<string>(), acts: new Map() };
      row.minutes += e.hours_minutes;
      row.days.add(e.entry_date);
      const asker = one(e.help_requester)?.name;
      if (asker) row.askers.add(asker);

      // No billable key here, and none is possible: help is never chargeable to
      // the project it helped, so every one of these rows carries NULL and a
      // tag would be an answer nobody gave.
      const add = (name: string, minutes: number, itemised: boolean) => {
        const cur = row.acts.get(name);
        if (cur) { cur.minutes += minutes; cur.itemised = cur.itemised && itemised; }
        else row.acts.set(name, { name, minutes, itemised, billable: null });
      };
      const rows = e.timesheet_entry_activities ?? [];
      const itemisedTotal = rows.reduce((s2, a) => s2 + (a.hours_minutes ?? 0), 0);
      for (const a of rows) {
        if ((a.hours_minutes ?? 0) > 0) add(a.activity_name, a.hours_minutes, true);
      }
      const gap = e.hours_minutes - itemisedTotal;
      if (gap > 0) add('Not itemised', gap, false);

      helpMap.set(label, row);
    }

    const helpActs: Help[] = [...helpMap.entries()]
      .map(([name, r]) => ({
        name, minutes: r.minutes, days: r.days.size,
        askers: [...r.askers].sort(),
        acts: [...r.acts.values()].sort((a, b) =>
          a.itemised === b.itemised ? b.minutes - a.minutes : a.itemised ? -1 : 1),
      }))
      .sort((a, b) => b.minutes - a.minutes);

    const helpTotal = helpActs.reduce((s, h) => s + h.minutes, 0);

    // ── The month's billable split ──────────────────────────────────────
    // Every entry, not just the project-bearing ones, so the four buckets add
    // up to Recorded and the tile below cannot contradict the tile beside it.
    // The rule itself is in billability.ts, written once and shared with the
    // PDF, and written to mirror mig 822 branch for branch.
    const bill = { ...EMPTY_SPLIT };
    for (const e of entries) {
      const s = splitEntry(
        { entry_kind: e.entry_kind, hours_minutes: e.hours_minutes, project_id: e.project_id,
          activities: e.timesheet_entry_activities ?? [] },
        classOfProject(e.project_id));
      bill.billable     += s.billable;
      bill.nonBillable  += s.nonBillable;
      bill.unclassified += s.unclassified;
      bill.absence      += s.absence;
      bill.worked       += s.worked;
    }
    /* The tile is shown only when there is something for it to say. An
     * employee who never touches a billable project would otherwise read a
     * permanent "0%", which is not a finding about their month — it is a fact
     * about the projects they are on, and it belongs nowhere near a strip of
     * numbers measuring them. */
    const showBill = bill.billable > 0 || bill.unclassified > 0
                  || projectActs.some(p => p.cls === 'billable');

    return {
      days, working, recorded, logged, missing, todayOpen, aheadN, weeks, projects,
      projectActs, projectTotal, helpActs, helpTotal, leaveMinutes, leaveDays, bill, showBill,
      // Clamped: past plan this is negative, and "−12h to log" is not a thing.
      remaining: Math.max(0, plannedMinutes - recorded),
      over:      Math.max(0, recorded - plannedMinutes),
      attain:    plannedMinutes > 0 ? (recorded / plannedMinutes) * 100 : 0,
      avgPerDay: logged > 0 ? recorded / logged : 0,
    };
  }, [year, month, entries, plannedMinutes, plannedFor, todayIso, classOfProject]);

  const pace = d.aheadN > 0 ? d.remaining / d.aheadN : 0;
  const billShare = billableSharePct(d.bill);
  const donutTotal = d.projects.reduce((s, p) => s + p.minutes, 0);
  const donutPcts  = wholePercents(d.projects.map(p => p.minutes), donutTotal);
  // Projects and non-project groups are ranked separately so each walks its own
  // palette — otherwise the first non-project slice would take the next project
  // colour and read as a project.
  const donutColors = (() => {
    let r = 0, o = 0;
    return d.projects.map(p => sliceColor(p, p.noProject ? 0 : r++, p.noProject ? o++ : 0));
  })();
  const projPcts   = wholePercents(d.projectActs.map(p => p.minutes), d.projectTotal);
  /* ONE THING, ONE COLOUR. The help cards below name the same slices the donut
   * draws, so they take the donut's ink rather than a colour of their own --
   * this panel already holds that rule for projects and it is not worth less
   * for help. HELP_INK is the fallback for a slice the donut never drew, which
   * can only happen if a help entry has hours and no helped project name. */
  const donutInk = new Map(d.projects.map((p, i) => [p.name, donutColors[i]]));

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
        display: 'grid', gridTemplateColumns: `repeat(${d.showBill ? 7 : 6}, 1fr)`, background: '#fff',
        border: `1px solid ${C.rule}`, borderRadius: 12, overflow: 'hidden', marginBottom: 14,
      }}>
        <Kpi label="Recorded"  value={h1(d.recorded)} unit="h" tone={C.blue}
             sub={`of ${h1(plannedMinutes)}h planned`} />
        {d.over > 0
          ? <Kpi label="Over plan" value={h1(d.over)} unit="h" tone={C.amber} sub="beyond the month's target" />
          : <Kpi label="Remaining" value={h1(d.remaining)} unit="h"
                 tone={d.attain < 80 ? C.amber : C.green} sub="to log this month" />}
        {/* Hours over WORKED hours, never over recorded — absence is out of the
            denominator, or a fortnight of annual leave would read as a
            fortnight of lost revenue. Same denominator as the Utilisation
            report's tile, and the same three-word rule underneath, so the two
            cannot describe the same hour differently. */}
        {d.showBill && (
          <Kpi label="Billable" value={h1(d.bill.billable)} unit="h" tone={BILL_GREEN}
               sub={billShare === null
                 ? 'no worked hours yet this month'
                 : d.bill.unclassified > 0
                   ? `${billShare}% of ${h1(d.bill.worked)}h worked · ${h1(d.bill.unclassified)}h on a project with no type set`
                   : `${billShare}% of ${h1(d.bill.worked)}h worked`} />
        )}
        {/* Attainment used to sit here and say exactly what the labelled bar in
            the panel below says, under the same word, with a whole sentence of
            context this tile could not carry. Leave had no home at all: eight
            hours of it landed in Recorded, in a day cell and in a weekly bar
            segment without the word appearing once in this summary. */}
        <Kpi label="Leave" value={String(d.leaveDays)}
             tone={d.leaveDays ? '#1D4ED8' : C.ink4}
             sub={d.leaveDays === 0 ? 'no leave this month'
                : `${d.leaveDays === 1 ? 'day' : 'days'} · ${h1(d.leaveMinutes)}h recorded`} />
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
            <em style={{ fontStyle: 'normal', fontSize: 11, fontWeight: 600, color: C.ink4,
                         display: 'flex', alignItems: 'center', gap: 10 }}>
              {/* The bars have carried a leave segment since they were built and
                  nothing ever said so. One key for the panel, rather than the
                  per-row caption the compact layout had no room for. */}
              {d.leaveMinutes > 0 && (
                <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                  <span style={{ width: 8, height: 8, borderRadius: 2, background: LEAVE_BLUE }} />
                  leave
                </span>
              )}
              <span>Sun – Sat</span>
            </em>
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
            {/* Not "By Project" any more: it names Annual Leave and Training as
                their own slices, so a title claiming projects would be
                describing two thirds of what is on screen. */}
            By Project &amp; Type
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
                        stroke={donutColors[i]}
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
                                   background: donutColors[i] }} />
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

          {/* ── What of it can be invoiced ─────────────────────────────────
              A SECOND CHART, deliberately, rather than a second encoding on the
              donut above. The donut answers "where did the month go" and sums to
              RECORDED. This answers "what of it is chargeable" and is measured
              over WORKED — leave is out of the denominator, or a fortnight of
              annual leave would read as a fortnight of lost revenue. Two
              questions with two different totals cannot share one ring without
              one of them being read wrong, and the wrong reading is the one that
              reaches an invoice.

              Splitting the donut's slices instead would also have doubled a
              five-slice ring to nine and taken two colours per project out of a
              ramp whose whole rule is one project, one colour — held from the
              donut through the legend to the cards below.

              Shown on the same condition as the KPI tile, so the two cannot
              disagree about whether this month has a chargeable story at all. */}
          {d.showBill && d.bill.worked > 0 && (
            <div style={{ marginTop: 18, paddingTop: 15, borderTop: `1px solid ${C.hair}` }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 7 }}>
                <span style={{ fontSize: 12, fontWeight: 700, color: C.ink2 }}>Chargeable</span>
                <span style={{ fontSize: 11, color: C.ink4 }}>
                  of {h1(d.bill.worked)}h worked · leave excluded
                </span>
              </div>

              <div style={{ display: 'flex', height: 8, borderRadius: 99, background: C.track, overflow: 'hidden' }}>
                {([
                  ['billable',     d.bill.billable,     BILL_GREEN],
                  ['non_billable', d.bill.nonBillable,  BILL_SLATE],
                  ['unclassified', d.bill.unclassified, BILL_AMBER],
                ] as const).filter(([, mins]) => mins > 0).map(([key, mins, colour], i) => (
                  <div key={key} style={{
                    height: 8, background: colour,
                    width: `${(mins / d.bill.worked) * 100}%`,
                    /* A 2px white cut between segments, never before the first.
                       The two inks sit at nearly the same LIGHTNESS -- 1.1:1
                       against each other -- so the boundary is carried by hue
                       alone, and hue alone is what colour-blind vision and a
                       greyscale print both lose. Without it the bar reads as one
                       part-filled progress bar rather than two categories.

                       An inset shadow rather than a border or a gap because it
                       costs no layout: the widths still total exactly 100%, so a
                       3% sliver is still 3% wide. */
                    boxShadow: i > 0 ? '-2px 0 0 0 #FFFFFF' : undefined,
                    transition: 'width 0.4s ease-out',
                  }} />
                ))}
              </div>

              {/* The figures live in the key, not on the segments: a 4% sliver
                  has no room for a label, and the one that gets clipped is
                  always the one somebody wanted to read. */}
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 18px', marginTop: 9 }}>
                {([
                  ['Billable',       d.bill.billable,     BILL_GREEN],
                  ['Not billable',   d.bill.nonBillable,  BILL_SLATE],
                  ['Not classified', d.bill.unclassified, BILL_AMBER],
                ] as const).filter(([, mins]) => mins > 0).map(([label, mins, colour]) => (
                  <span key={label} style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                    <span style={{ width: 9, height: 9, borderRadius: 3, flex: 'none', background: colour }} />
                    <span style={{ fontSize: 12, color: C.ink3 }}>{label}</span>
                    <span style={{ fontSize: 12.5, fontWeight: 700, color: C.ink }}>{h1(mins)}h</span>
                    <span style={{ fontSize: 11.5, color: C.ink4 }}>
                      {Math.round((mins / d.bill.worked) * 100)}%
                    </span>
                  </span>
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

              /* THE SPLIT THE CARD IS ORGANISED BY.
               *
               * Two groups, and the test is `splitEntry`'s branch rather than the
               * raw flag, because those are not the same question:
               *
               *   - the un-itemised remainder (`itemised: false`) has no activity
               *     row and no answer, and the split counts it BILLABLE -- 822's
               *     `WHEN a.id IS NULL THEN 'billable'` applied to the part of an
               *     entry that has no row. Grouping it by its NULL flag would put
               *     it under "Not billable" while the bar above counted it the
               *     other way, and the card would contradict itself in 60px.
               *   - an itemised row with a NULL flag is counted NON-billable
               *     (`if (a.is_billable === true)`, never a COALESCE).
               *
               * So the two groups sum, provably, to p.split.billable and
               * p.split.nonBillable -- which is why the group headings can print
               * those figures rather than re-totalling the rows beneath them.
               *
               * Only a billable project gets grouped. Elsewhere there is nothing
               * to separate.
               *
               * THE BILLABLE GROUP KEEPS THE PROJECT'S OWN INK, and only the
               * non-billable one takes a chargeability colour. Painting both
               * groups green and slate was tried first and read as one anonymous
               * card repeated three times: every project's activities the same
               * green, and the only thing left saying which project you were
               * looking at was an 8px dot in the header. The bar at the top of
               * the card carries the shared green -- it is the same statement as
               * the month's Chargeable bar and the PDF, and it is what the two
               * have to agree on -- while the list below it is this project's
               * contents and says so.
               *
               * The heading dot therefore matches the bars beneath it rather
               * than the bar above it, which is what a heading dot is for.
               *
               * Known collision: a 7th-and-beyond project takes RANK[6]
               * (#64748B), which is close enough to BILL_SLATE that its two
               * groups would look alike. Rare enough to accept; the headings
               * still name them. */
              const grouped = p.cls === 'billable';
              const groups  = grouped
                ? ([
                    { key: 'billable', word: 'Billable',     ink: colour,     mins: p.split.billable,
                      acts: p.acts.filter(a => !a.itemised || a.billable === true) },
                    { key: 'non',      word: 'Not billable', ink: BILL_SLATE, mins: p.split.nonBillable,
                      acts: p.acts.filter(a => a.itemised && a.billable !== true) },
                  ]).filter(g => g.acts.length > 0)
                : [{ key: 'all', word: '', ink: colour, mins: p.minutes, acts: p.acts }];

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

                  {/* THE CARD'S OWN CHARGEABLE BAR -- the same three inks and the
                      same idiom as the month's bar above, one level down, so a
                      project card reads as a miniature of the panel it sits in.
                      It replaced two bare figures, which said nothing about the
                      proportion and left the reader to divide.

                      Built from `p.split`, NOT totalled from the rows listed
                      under it. The split is this file's mirror of mig 822 and is
                      what the Utilisation report and both PDFs read; a bar
                      totalled from the activity rows instead would be a fourth
                      opinion on revenue, which is the one thing this panel must
                      not add.

                      Only where somebody is paying. On an internal project the
                      question was never put to the employee, and a line saying
                      "Billable 0h" would read as a judgement on work that was
                      never meant to be charged for. */}
                  {p.cls === 'billable' && (() => {
                    const worked = p.split.worked > 0 ? p.split.worked : p.minutes;
                    const parts  = ([
                      ['Billable',       p.split.billable,     BILL_GREEN],
                      ['Not billable',   p.split.nonBillable,  BILL_SLATE],
                      ['Not classified', p.split.unclassified, BILL_AMBER],
                    ] as const);
                    // Floor-and-distribute, so the figures printed under the bar
                    // total 100 rather than 99 on a month that divides badly.
                    const pcts  = wholePercents(parts.map(([, m]) => m), worked);
                    const shown = parts
                      .map(([label, mins, ink], i) => ({ label, mins, ink, pct: pcts[i] }))
                      .filter(x => x.mins > 0);
                    return (
                      <div style={{ padding: '10px 12px 0' }}>
                        {/* 6px. Thinner than the month's 8px bar above it and
                            thicker than the 4px activity bars below, so the three
                            read in the order they contain each other. 4px is the
                            floor: at 4 this bar and the rows it summarises carry
                            the same weight. */}
                        <div style={{ display: 'flex', height: 6, borderRadius: 99,
                                      background: C.track, overflow: 'hidden' }}>
                          {shown.map((x, i) => (
                            <div key={x.label} style={{
                              height: 6, background: x.ink,
                              width: `${(x.mins / worked) * 100}%`,
                              boxShadow: i > 0 ? '-2px 0 0 0 #FFFFFF' : undefined,
                              transition: 'width 0.4s ease-out',
                            }} />
                          ))}
                        </div>
                        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '2px 14px',
                                      marginTop: 7, fontSize: 11.5 }}>
                          {shown.map(x => (
                            <span key={x.label} style={{ color: x.ink, fontWeight: 700 }}>
                              {x.label} {h1(x.mins)}h &middot; {x.pct}%
                            </span>
                          ))}
                        </div>
                      </div>
                    );
                  })()}
                  {p.cls === 'unclassified' && (
                    <div style={{ padding: '7px 12px 0', fontSize: 11.5, color: C.ink4 }}>
                      This project has no type set, so its hours are reported as
                      not classified rather than counted either way.
                    </div>
                  )}

                  <div style={{ padding: '4px 12px 10px' }}>
                    {groups.map(g => (
                      <div key={g.key}>
                        {/* Headings only when there is something to separate. A
                            project with nothing non-billable would otherwise carry
                            a "NOT BILLABLE 0h" rule with nothing under it -- a
                            heading whose only content is that a group is absent. */}
                        {groups.length > 1 && (
                          <div style={{ display: 'flex', alignItems: 'center', gap: 7,
                                        padding: '12px 0 1px' }}>
                            <span style={{ width: 7, height: 7, borderRadius: 2,
                                           flex: 'none', background: g.ink }} />
                            <span style={{ fontSize: 10.5, fontWeight: 700, letterSpacing: '0.05em',
                                           textTransform: 'uppercase', color: g.ink }}>{g.word}</span>
                            <span style={{ flex: 1, height: 1, background: C.hair }} />
                            <span style={{ fontSize: 11.5, fontWeight: 700, color: C.ink2 }}>
                              {h1(g.mins)}h
                            </span>
                          </div>
                        )}
                        {/* KEYED ON THE NAME AND THE ANSWER. Since mig 824 one name
                            can appear twice in this list with different answers, and
                            a key of `a.name` alone would collide and drop a row. The
                            grouping is what finally makes that legible: "Testing 2h"
                            under Billable and "Testing 6h" under Not billable are two
                            facts, where one flat list of both read as a duplicate. */}
                        {g.acts.map((a, j) => (
                          <div key={`${a.name}\u0000${a.billable}`} style={{ paddingTop: 8 }}>
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
                              {/* The per-row Billable / Not billable chip is gone: the
                                  heading above says it, and repeating it on every row
                                  was a column of the same two words.

                                  What the chip could say and a heading cannot is that
                                  nobody was ever ASKED. Those rows are counted as
                                  non-billable -- by mig 822 and by splitEntry, so the
                                  heading is not lying -- but NULL is not "no", and a
                                  row sitting under that heading for want of an answer
                                  should say which it is. They exist on rows written
                                  before 821, and on anything mass-created between 821
                                  and 824. */}
                              {p.cls === 'billable' && a.itemised && a.billable === null && (
                                <span style={{
                                  fontSize: 10, fontWeight: 600, color: C.ink4,
                                  whiteSpace: 'nowrap', flex: 'none', fontStyle: 'italic',
                                }}>never asked</span>
                              )}
                              <span style={{ fontSize: 12.5, fontWeight: 700,
                                             color: a.itemised ? C.ink : C.ink3 }}>
                                {h1(a.minutes)}h
                              </span>
                            </div>
                            {/* 4px, not 3. These bars sit on a #F1F2F5 track, and at
                                3px a low-contrast fill is not a short bar, it is no
                                bar at all. */}
                            <div style={{ marginTop: 4, marginLeft: 22, height: 4, borderRadius: 99,
                                          background: C.track, overflow: 'hidden' }}>
                              <div style={{
                                height: 4, borderRadius: 99,
                                width: `${(a.minutes / widest) * 100}%`,
                                // The group's ink, the un-itemised caveat row included:
                                // it is counted as billable, so drawing it in a pale
                                // grey under a green heading would contradict the bar
                                // above. The italic name is what marks it as a caveat.
                                background: g.ink,
                              }} />
                            </div>
                          </div>
                        ))}
                      </div>
                    ))}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* ── Help given to other projects ────────────────────────────────
          Its own block, and its own subtotal, because these hours are the
          employee's own work and are deliberately NOT the helped project's.
          Folding them into the cards above would report that project as having
          consumed hours it is explicitly not charged for -- which is the one
          claim mig 801 exists to deny, and the reason 810 reports support
          through separate CTEs rather than by widening the project's own.

          The requester is named here because this is the employee's own record
          of who asked, and because a card of hours with nobody attached is the
          state migration 829 was written to end. */}
      {d.helpActs.length > 0 && (
        <div style={{ ...panelSt, marginTop: 14 }}>
          <div style={pTitleSt}>
            Help given to other projects
            <em style={{ fontStyle: 'normal', fontSize: 11, fontWeight: 600, color: C.ink4 }}>
              {h1(d.helpTotal)}h · not counted towards those projects
            </em>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 12 }}>
            {d.helpActs.map(hp => {
              const widest = Math.max(...hp.acts.map(a => a.minutes), 1);
              return (
                <div key={hp.name} style={{
                  border: `1px solid ${C.rule}`, borderRadius: 10, overflow: 'hidden', background: '#fff',
                }}>
                  <div style={{
                    display: 'flex', alignItems: 'center', gap: 8,
                    padding: '10px 12px', background: '#FBFCFD',
                    borderBottom: `1px solid ${C.hair}`,
                  }}>
                    {/* The neutral ink, not a project colour. These are not a
                        project's hours and should not read as one. */}
                    <span style={{ width: 9, height: 9, borderRadius: 3, flex: 'none',
                                   background: donutInk.get(hp.name) ?? HELP_INK }} />
                    <span style={{ flex: 1, fontSize: 13, fontWeight: 750, color: C.ink }}>{hp.name}</span>
                    <span style={{ fontSize: 11.5, color: C.ink4 }}>
                      {hp.days} {hp.days === 1 ? 'day' : 'days'}
                    </span>
                    <span style={{ fontSize: 13, fontWeight: 750, color: C.ink }}>{h1(hp.minutes)}h</span>
                  </div>

                  {hp.askers.length > 0 && (
                    <div style={{ padding: '7px 12px 0', fontSize: 11.5, color: C.ink3 }}>
                      Requested by{' '}
                      <b style={{ color: C.ink2, fontWeight: 700 }}>{hp.askers.join(', ')}</b>
                    </div>
                  )}

                  <div style={{ padding: '4px 12px 10px' }}>
                    {hp.acts.map((a, j) => (
                      <div key={a.name} style={{ paddingTop: 8 }}>
                        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                          <span style={{ fontSize: 11, color: C.ink4, width: 14, flex: 'none' }}>{j + 1}.</span>
                          <span style={{
                            flex: 1, fontSize: 12.5, minWidth: 0,
                            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                            color: a.itemised ? C.ink2 : C.ink4,
                            fontStyle: a.itemised ? 'normal' : 'italic',
                          }}>{a.name}</span>
                          <span style={{ fontSize: 12.5, fontWeight: 700, color: a.itemised ? C.ink : C.ink3 }}>
                            {h1(a.minutes)}h
                          </span>
                        </div>
                        <div style={{ marginTop: 4, marginLeft: 22, height: 3, borderRadius: 99,
                                      background: C.track, overflow: 'hidden' }}>
                          <div style={{
                            height: 3, borderRadius: 99,
                            width: `${(a.minutes / widest) * 100}%`,
                            background: a.itemised ? (donutInk.get(hp.name) ?? HELP_INK) : '#D1D5DB',
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