import type {
  ExportDay, ExportEntry, ExportWeek, ExportProject,
  ExportProjectActivity, ExportProjectBreakdown, ExportNonProjectType,
  ExportMonthSplit,
} from '../types';

/**
 * Pure shaping functions. Nothing here touches Supabase or React — give it rows,
 * get back the arrays the PDF pages render. That means every number in the file
 * can be reproduced in a test without a browser.
 */

/**
 * Compact hours for table density: "7h 30m". The on-screen helper in
 * MyTimesheet formats the same minutes as "7 hr 30 min", which is right for a
 * card and too wide for a column three of which have to fit across A4.
 * Deliberately a separate function rather than a shared one — the two have
 * different jobs, and importing from index.tsx would be a circular dependency.
 */
export function fmtHM(minutes: number): string {
  if (!minutes) return '—';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

/**
 * "2h 00m" — the column form.
 *
 * fmtHM's compact output is right when hours stand alone, and wrong the moment
 * they stack: a run of "2h", "45m", "1h 30m" has three different shapes and
 * stops reading as a column. This pads every value to the same one so the
 * figures line up and can be added by eye.
 */
export function fmtHMWide(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${h}h ${String(m).padStart(2, '0')}m`;
}

/**
 * "8:00" — the matrix cell form on the Summary report.
 *
 * A third format, and the narrowest of the three on purpose. fmtHM gives "8h"
 * and fmtHMWide "8h 00m"; at ten columns across A4 a cell is about 44pt wide
 * and "5h 45m" does not fit — it renders as "5h…", which is worse than useless
 * in a column of figures someone is adding up. Clock notation says the same
 * thing in four characters and stacks into a column that can be read down.
 */
export function fmtHMClock(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${h}:${String(m).padStart(2, '0')}`;
}

export function fmtHours(minutes: number): string {
  return (minutes / 60).toFixed(1);
}

export const DOW_LABEL = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

export function fmtDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return `${d} ${MONTHS[m - 1]} ${y}`;
}

const DOW_FULL = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
const MONTH_FULL = ['January','February','March','April','May','June',
                    'July','August','September','October','November','December'];

/** "Sunday, 2 August 2026" — the day-group heading on page 2. */
export function fmtDateLong(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const dow = new Date(y, m - 1, d).getDay();
  return `${DOW_FULL[dow]}, ${d} ${MONTH_FULL[m - 1]} ${y}`;
}

/** "AUGUST 2026" — the section rule on page 2. */
export function fmtMonthYear(iso: string): string {
  const [y, m] = iso.split('-').map(Number);
  return `${MONTH_FULL[m - 1].toUpperCase()} ${y}`;
}

export function fmtDateShort(iso: string): string {
  const [, m, d] = iso.split('-').map(Number);
  const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return `${d} ${MONTHS[m - 1]}`;
}

export function fmtStamp(iso: string | null): string {
  if (!iso) return '—';
  const dt = new Date(iso);
  if (Number.isNaN(dt.getTime())) return '—';
  return `${fmtDate(dt.toISOString().slice(0, 10))}, ${String(dt.getHours()).padStart(2, '0')}:${String(dt.getMinutes()).padStart(2, '0')}`;
}

/** "16–22 Aug", or "30 Aug – 5 Sep" when the week straddles a month end. */
function weekLabel(a: string, b: string): string {
  if (a === b) return fmtDateShort(a);
  const [, ma, da] = a.split('-').map(Number);
  const [, mb, db] = b.split('-').map(Number);
  const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return ma === mb
    ? `${da}–${db} ${MONTHS[ma - 1]}`
    : `${da} ${MONTHS[ma - 1]} – ${db} ${MONTHS[mb - 1]}`;
}

/**
 * Weeks run Sunday-to-Saturday to match the on-screen calendar, and a week is
 * included only if it has at least one day inside the month — so a month never
 * opens or closes with an empty row.
 */
export function buildWeeks(days: ExportDay[]): ExportWeek[] {
  if (!days.length) return [];
  const weeks: ExportWeek[] = [];
  let bucket: ExportDay[] = [];

  const flush = () => {
    if (!bucket.length) return;
    const first = bucket[0];
    const last  = bucket[bucket.length - 1];
    weeks.push({
      // "16 Aug – 22 Aug" wrapped onto two lines in a 52pt column and pushed
      // its row out of alignment. A week inside one month only needs the month
      // once, which is also how the on-screen panel reads.
      label:   weekLabel(first.date, last.date),
      start:   first.date,
      end:     last.date,
      days:    bucket.map(d => ({ dow: d.dow, minutes: d.minutes, planned: d.planned })),
      total:   bucket.reduce((s, d) => s + d.minutes, 0),
      planned: bucket.reduce((s, d) => s + d.planned, 0),
      leave:   bucket.reduce((s, d) => s + (d.leaveMinutes ?? 0), 0),
      holidays: bucket.filter(d => d.holidayCosts).length,
    });
    bucket = [];
  };

  for (const d of days) {
    if (d.dow === 0 && bucket.length) flush();
    bucket.push(d);
  }
  flush();
  return weeks;
}

/**
 * Projects by hours descending. A project with no hours is not listed at all.
 *
 * `denominator` is the month's recorded minutes, NOT the project subtotal.
 * Dividing by the subtotal made AMPTJ read 41% on a report whose own header
 * said the month was 80 hours — 41% of something the reader could not see. The
 * share now means what a reader assumes it means.
 */
export function buildProjects(entries: ExportEntry[], denominator: number): ExportProject[] {
  const byName = new Map<string, { minutes: number; days: Set<string> }>();
  for (const e of entries) {
    if (!e.project || e.minutes <= 0) continue;
    const row = byName.get(e.project) ?? { minutes: 0, days: new Set<string>() };
    row.minutes += e.minutes;
    row.days.add(e.date);
    byName.set(e.project, row);
  }
  return [...byName.entries()]
    .map(([name, r]) => ({
      name,
      minutes: r.minutes,
      pctOfTotal: denominator ? (r.minutes / denominator) * 100 : 0,
      daysActive: r.days.size,
    }))
    .sort((a, b) => b.minutes - a.minutes);
}

/**
 * The hours an entry should display.
 *
 * Activity rows are the source of truth since mig 727, but an entry created
 * before it has names and no rows — so fall through to the parent. The two can
 * never disagree on a current entry: a trigger keeps the parent equal to the sum.
 */
export function entryMinutes(
  parentMinutes: number,
  activities: Array<{ minutes: number }> | undefined | null,
): number {
  if (activities && activities.length) return activities.reduce((s, a) => s + a.minutes, 0);
  return parentMinutes ?? 0;
}

/**
 * Whole percentages that actually total 100.
 *
 * Rounding each share independently is what produced 102% on a five-project
 * month: five values each rounding up, and a reader who adds a column of
 * printed numbers and gets the wrong answer stops trusting the ones they did
 * not check. Largest-remainder gives every entry its floor, then hands the
 * leftover points to whichever shares were cut hardest.
 *
 * Only meaningful when `values` sums to `total`. Where it does not — the
 * activity chart, measured against the month — the remainder is a real fact and
 * is printed as its own row instead.
 */
export function wholePercents(values: number[], total: number): number[] {
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

/**
 * Projects with their activities nested underneath — page 3's chart.
 *
 * PROJECT-BEARING ENTRIES ONLY. Training, leave and anything else without a
 * project are absent by design: they have no project to sit under. They are not
 * lost — the page prints the non-project remainder as its own line, and the
 * activity chart on page 4 counts every activity whether or not it had a
 * project. Two blocks, two scopes, each stated in its heading.
 */
export function buildProjectActivities(entries: ExportEntry[]): ExportProjectBreakdown[] {
  const byProject = new Map<string, {
    minutes: number; days: Set<string>; acts: Map<string, ExportProjectActivity>;
  }>();

  for (const e of entries) {
    if (!e.project || e.minutes <= 0) continue;
    const row = byProject.get(e.project)
      ?? { minutes: 0, days: new Set<string>(), acts: new Map<string, ExportProjectActivity>() };
    row.minutes += e.minutes;
    row.days.add(e.date);

    const add = (name: string, minutes: number, itemised: boolean) => {
      const cur = row.acts.get(name);
      if (cur) { cur.minutes += minutes; cur.itemised = cur.itemised && itemised; }
      else row.acts.set(name, { name, minutes, itemised });
    };

    let itemised = 0;
    for (const a of e.activities) {
      if (a.minutes > 0) { add(a.name, a.minutes, true); itemised += a.minutes; }
    }

    // A pre-727 entry carries activity NAMES with no hours split, so `itemised`
    // lands short of the entry total. Printing the names against nothing would
    // imply a measurement that was never taken; dropping the difference would
    // leave a card whose lines do not add up to its own header. Named instead.
    const gap = e.minutes - itemised;
    if (gap > 0) add('Not itemised', gap, false);

    byProject.set(e.project, row);
  }

  const list = [...byProject.entries()]
    .map(([name, r]) => ({
      name,
      minutes:    r.minutes,
      daysActive: r.days.size,
      pctOfProjectTime: 0,
      activities: [...r.acts.values()].sort((a, b) =>
        // The caveat row sits last however big it is, so real work reads first.
        a.itemised === b.itemised ? b.minutes - a.minutes : a.itemised ? -1 : 1),
    }))
    .sort((a, b) => b.minutes - a.minutes);

  const total = list.reduce((s, p) => s + p.minutes, 0);
  const pcts  = wholePercents(list.map(p => p.minutes), total);
  list.forEach((p, i) => { p.pctOfProjectTime = pcts[i]; });

  return list;
}

/**
 * The other half of buildProjectActivities: everything with no project on it,
 * grouped by time type. Leave, training, and anything else that is real
 * attendance but belongs to no project.
 *
 * Together the two cover every recorded minute, which is the property page 3
 * relies on when it prints the month total underneath them both.
 */
export function buildNonProjectTypes(entries: ExportEntry[]): ExportNonProjectType[] {
  const byType = new Map<string, ExportNonProjectType>();
  for (const e of entries) {
    if (e.project || e.minutes <= 0) continue;
    const key = e.typeName || 'Other attendance';
    const cur = byType.get(key);
    if (cur) { cur.minutes += e.minutes; cur.isLeave = cur.isLeave || e.kind === 'leave'; }
    else byType.set(key, { name: key, minutes: e.minutes, isLeave: e.kind === 'leave' });
  }
  return [...byType.values()].sort((a, b) => b.minutes - a.minutes);
}

/**
 * The month split by project and by non-project time type — page 3's donut.
 *
 * Projects first, in size order, then the non-project types. The order is not
 * cosmetic: the donut and its legend walk two separate palettes, and a
 * non-project slice taking the next project colour would read as a project.
 *
 * Percentages use largest-remainder against the month, so the legend column
 * totals 100 rather than the 99 or 102 that independent rounding produces.
 */
export function buildMonthSplit(entries: ExportEntry[]): ExportMonthSplit[] {
  const proj  = new Map<string, number>();
  const other = new Map<string, { minutes: number; isLeave: boolean }>();

  for (const e of entries) {
    if (e.minutes <= 0) continue;
    if (e.project) { proj.set(e.project, (proj.get(e.project) ?? 0) + e.minutes); continue; }
    const key = e.typeName || 'Other attendance';
    const cur = other.get(key);
    if (cur) { cur.minutes += e.minutes; cur.isLeave = cur.isLeave || e.kind === 'leave'; }
    else other.set(key, { minutes: e.minutes, isLeave: e.kind === 'leave' });
  }

  const rows = [
    ...[...proj.entries()]
      .map(([name, minutes]) => ({ name, minutes, isLeave: false, isProject: true, pct: 0 }))
      .sort((a, b) => b.minutes - a.minutes),
    ...[...other.entries()]
      .map(([name, r]) => ({ name, minutes: r.minutes, isLeave: r.isLeave, isProject: false, pct: 0 }))
      .sort((a, b) => b.minutes - a.minutes),
  ];

  const total = rows.reduce((s, r) => s + r.minutes, 0);
  const pcts  = wholePercents(rows.map(r => r.minutes), total);
  rows.forEach((r, i) => { r.pct = pcts[i]; });
  return rows;
}
