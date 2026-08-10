import type {
  ExportDay, ExportEntry, ExportWeek, ExportProject, ExportActivityTotal,
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
      label:   `${fmtDateShort(first.date)} – ${fmtDateShort(last.date)}`,
      start:   first.date,
      end:     last.date,
      days:    bucket.map(d => ({ dow: d.dow, minutes: d.minutes, planned: d.planned })),
      total:   bucket.reduce((s, d) => s + d.minutes, 0),
      planned: bucket.reduce((s, d) => s + d.planned, 0),
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

/** Projects by hours descending. A project with no hours is not listed at all. */
export function buildProjects(entries: ExportEntry[]): ExportProject[] {
  const byName = new Map<string, { minutes: number; days: Set<string> }>();
  for (const e of entries) {
    if (!e.project || e.minutes <= 0) continue;
    const row = byName.get(e.project) ?? { minutes: 0, days: new Set<string>() };
    row.minutes += e.minutes;
    row.days.add(e.date);
    byName.set(e.project, row);
  }
  const total = [...byName.values()].reduce((s, r) => s + r.minutes, 0);
  return [...byName.entries()]
    .map(([name, r]) => ({
      name,
      minutes: r.minutes,
      pctOfTotal: total ? (r.minutes / total) * 100 : 0,
      daysActive: r.days.size,
    }))
    .sort((a, b) => b.minutes - a.minutes);
}

/**
 * Activity totals across the month. Falls back to the parent entry when an entry
 * has no activity rows — an entry written before per-activity hours existed still
 * has names on it, and dropping those would silently under-report the month.
 */
export function buildActivityTotals(entries: ExportEntry[]): ExportActivityTotal[] {
  const byName = new Map<string, number>();
  for (const e of entries) {
    for (const a of e.activities) {
      // A legacy entry carries names with no hours against them. Counting those
      // as zero would put empty bars in the chart and imply a measurement that
      // was never taken.
      if (!a.name || a.minutes <= 0) continue;
      byName.set(a.name, (byName.get(a.name) ?? 0) + a.minutes);
    }
  }
  const total = [...byName.values()].reduce((s, m) => s + m, 0);
  return [...byName.entries()]
    .map(([name, minutes]) => ({ name, minutes, pctOfTotal: total ? (minutes / total) * 100 : 0 }))
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
