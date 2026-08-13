import type { ExportDay, ExportEntry, TimesheetExportData } from '../types';

/**
 * The model behind the Summary report's one table: every day of the month down
 * the side, every project and time type the employee actually used across the
 * top, hours in the cells.
 *
 * Pure. It takes the same `TimesheetExportData` the Detail report renders and
 * returns rows and columns — no querying, no formatting, no react-pdf. That is
 * deliberate: the arithmetic on this page has to reconcile with the calendar on
 * page 1 and the project breakdown on page 3, and the only way to be sure of
 * that is to derive all three from one source and be able to test this one
 * without a renderer.
 *
 * WHAT IT DOES NOT DO
 *   It does not decide row heights. Fitting the table to the page is layout,
 *   and lives in Page2Summary — see the note there about why that calculation
 *   cannot be shared with the HTML mock it came from.
 */

/** Beyond this many projects the tail is clubbed into "Other". Ten columns is
 *  what fits A4 with figures still readable at 7.5pt; eight projects leaves
 *  room for a couple of non-project types and Leave. */
export const MAX_PROJECT_COLUMNS = 8;

export interface MatrixColumn {
  key:       string;
  label:     string;
  minutes:   number;      // month total, used for ordering and the total row
  isProject: boolean;
  isLeave:   boolean;
}

/** Green / amber / red / nothing. The vocabulary the whole page is coloured by. */
export type MatrixTone = 'met' | 'short' | 'over' | 'missing' | 'none';

export interface MatrixDayRow {
  kind:      'day';
  date:      string;
  label:     string;            // 'Wed 1'
  tag:       string | null;     // 'week off' | 'missing' | a holiday's name
  cells:     number[];          // parallel to columns
  total:     number;
  planned:   number;
  tone:      MatrixTone;
  /** Alternating fill, counted over rendered day rows only so a weekend band
   *  between two days does not reset the rhythm. */
  zebra:     boolean;
}

export interface MatrixBandRow {
  kind:  'band';
  lead:  string;                // 'Weekend' | 'Holiday'
  text:  string;                // 'Fri 3 – Sat 4' | 'Thu 16 · Republic Day'
  isHoliday: boolean;
}

export interface MatrixWeekRow {
  kind:    'week';
  label:   string;              // 'Week 3'
  range:   string;              // '12–18 Jul'
  cells:   number[];
  total:   number;
  planned: number;
  /** Null when the week has no planned hours at all — a percentage of zero is
   *  not 0%, it is undefined, and printing 0% would read as a failure. */
  pct:     number | null;
  tone:    MatrixTone;
}

export interface MatrixMonthRow {
  kind:    'month';
  cells:   number[];
  total:   number;
  planned: number;
  pct:     number;
}

export type MatrixRow = MatrixDayRow | MatrixBandRow | MatrixWeekRow | MatrixMonthRow;

export interface SummaryMatrix {
  columns: MatrixColumn[];
  rows:    MatrixRow[];
  /** Counts the layout needs to size rows without walking `rows` again. */
  dayRows:   number;
  bandRows:  number;
  weekRows:  number;
  /** Working days in the past with nothing against them. Drives nothing on the
   *  page directly — every one of them is already marked in place — but it is
   *  what a caller would assert on in a test. */
  missingDays: number;
  totalMinutes:   number;
  plannedMinutes: number;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const dayNum = (iso: string) => Number(iso.slice(8, 10));
const monLbl = (iso: string) => MONTHS[Number(iso.slice(5, 7)) - 1];

/**
 * Which column an entry belongs in.
 *
 * Leave is clubbed into ONE column whatever the absence type — annual, sick,
 * casual all land together — because a month with four leave types would spend
 * four columns saying "not at work" and crowd out the projects, which are what
 * the table exists to show. Page 3 still names each type separately.
 *
 * A holiday's system-generated row carries no hours and gets no column: the day
 * itself becomes a band row.
 */
function columnFor(e: ExportEntry): { key: string; label: string; isProject: boolean; isLeave: boolean } | null {
  if (e.kind === 'holiday') return null;
  if (e.kind === 'leave')   return { key: 'leave',      label: 'Leave',    isProject: false, isLeave: true  };
  if (e.project)            return { key: `p:${e.project}`,  label: e.project,  isProject: true,  isLeave: false };
  return                           { key: `t:${e.typeName}`, label: e.typeName, isProject: false, isLeave: false };
}

/**
 * ALLCAPS project codes are shouted; words are not.
 *
 * The projects table stores names as they were typed, which in practice means
 * everything is upper case — AMPTJ, TASNEE, WISAYAH. Printing all of them that
 * way makes the header row a wall. An acronym is taken to be a short token, or
 * one with at most a single vowel; anything else is a word and gets title case.
 *
 * A heuristic, and it will be wrong occasionally. It is display-only — the key,
 * the ordering and every figure use the stored name — so being wrong costs a
 * cosmetic misreading of one label and nothing else. If projects ever grow a
 * display_name column, use it here and delete this.
 */
export function displayLabel(name: string): string {
  if (!name || name !== name.toUpperCase()) return name;
  if (/[^A-Z]/.test(name)) return name;                 // has spaces, digits, punctuation — leave it
  const vowels = (name.match(/[AEIOU]/g) ?? []).length;
  if (name.length <= 3 || vowels <= 1) return name;
  return name.charAt(0) + name.slice(1).toLowerCase();
}

function toneFor(recorded: number, planned: number, inPast: boolean): MatrixTone {
  if (planned <= 0) return recorded > 0 ? 'over' : 'none';   // work on a day off IS over target
  if (recorded === 0) return inPast ? 'missing' : 'none';
  if (recorded > planned) return 'over';
  if (recorded >= planned) return 'met';
  return 'short';
}

export function buildSummaryMatrix(data: TimesheetExportData): SummaryMatrix {
  const todayIso = data.generatedAt.slice(0, 10);

  // ── columns ───────────────────────────────────────────────────────────
  const seen = new Map<string, MatrixColumn>();
  const perDay = new Map<string, Map<string, number>>();

  for (const e of data.entries) {
    const col = columnFor(e);
    if (!col) continue;
    const existing = seen.get(col.key);
    if (existing) existing.minutes += e.minutes;
    else seen.set(col.key, { ...col, label: displayLabel(col.label), minutes: e.minutes });

    let row = perDay.get(e.date);
    if (!row) { row = new Map(); perDay.set(e.date, row); }
    row.set(col.key, (row.get(col.key) ?? 0) + e.minutes);
  }

  const byMinutes = (a: MatrixColumn, b: MatrixColumn) =>
    b.minutes - a.minutes || a.label.localeCompare(b.label);

  const all      = [...seen.values()];
  const projects = all.filter(c => c.isProject).sort(byMinutes);
  const types    = all.filter(c => !c.isProject && !c.isLeave).sort(byMinutes);
  const leave    = all.filter(c => c.isLeave);

  // The tail beyond MAX_PROJECT_COLUMNS is merged rather than dropped: a column
  // that quietly vanishes makes the row totals stop adding up, which is worse
  // than a coarse label.
  const kept   = projects.slice(0, MAX_PROJECT_COLUMNS);
  const tail   = projects.slice(MAX_PROJECT_COLUMNS);
  const merged: MatrixColumn[] = tail.length
    ? [{ key: 'other', label: 'Other', isProject: true, isLeave: false,
         minutes: tail.reduce((s, c) => s + c.minutes, 0) }]
    : [];
  const tailKeys = new Set(tail.map(c => c.key));

  const columns = [...kept, ...merged, ...types, ...leave];
  const index = new Map(columns.map((c, i) => [c.key, i]));

  const cellsFor = (date: string): number[] => {
    const out = new Array(columns.length).fill(0);
    const row = perDay.get(date);
    if (!row) return out;
    for (const [key, mins] of row) {
      const i = index.get(tailKeys.has(key) ? 'other' : key);
      if (i !== undefined) out[i] += mins;
    }
    return out;
  };

  // ── rows ──────────────────────────────────────────────────────────────
  const rows: MatrixRow[] = [];
  let dayRows = 0, bandRows = 0, weekRows = 0, missingDays = 0;
  const monthCells = new Array(columns.length).fill(0);
  let monthTotal = 0, monthPlanned = 0;

  // Weeks run Sunday to Saturday, the same rule buildWeeks() uses, so the week
  // numbering here matches the weekly bars on page 3 and the calendar rows on
  // page 1. Nothing enforces that agreement but this comment and one boundary
  // test — if buildWeeks ever changes, change this with it.
  const weeks: ExportDay[][] = [];
  let current: ExportDay[] = [];
  for (const d of data.monthDays) {
    current.push(d);
    if (d.dow === 6) { weeks.push(current); current = []; }
  }
  if (current.length) weeks.push(current);

  weeks.forEach((week, wi) => {
    const weekCells = new Array(columns.length).fill(0);
    let weekTotal = 0, weekPlanned = 0, zebra = false;
    let run: ExportDay[] = [];
    let runHoliday = false;

    const flushRun = () => {
      if (!run.length) return;
      const a = run[0], b = run[run.length - 1];
      const text = runHoliday
        ? `${DOW[a.dow]} ${dayNum(a.date)} · ${a.holidayName ?? 'Public holiday'}`
        : a === b
          ? `${DOW[a.dow]} ${dayNum(a.date)}`
          : `${DOW[a.dow]} ${dayNum(a.date)} – ${DOW[b.dow]} ${dayNum(b.date)}`;
      rows.push({ kind: 'band', lead: runHoliday ? 'Holiday' : 'Weekend', text, isHoliday: runHoliday });
      bandRows++;
      run = [];
    };

    for (const d of week) {
      const empty = d.minutes === 0;
      const nonWorking = d.isHoliday || d.planned <= 0;

      // A weekend or holiday with nothing on it is a band, not a row — it is
      // the single largest saving on this page and the reason a 31-day month
      // fits. One WITH hours stays a full row, because weekend work and a
      // worked holiday are exactly the things a reviewer is looking for.
      if (nonWorking && empty) {
        if (run.length && runHoliday !== d.isHoliday) flushRun();
        runHoliday = d.isHoliday;
        run.push(d);
        continue;
      }
      flushRun();

      const cells = cellsFor(d.date);
      for (let i = 0; i < cells.length; i++) {
        weekCells[i] += cells[i];
        monthCells[i] += cells[i];
      }
      weekTotal += d.minutes; monthTotal += d.minutes;
      weekPlanned += d.planned; monthPlanned += d.planned;

      const tone = toneFor(d.minutes, d.planned, d.date <= todayIso);
      if (tone === 'missing') missingDays++;

      zebra = !zebra;
      rows.push({
        kind: 'day',
        date: d.date,
        label: `${DOW[d.dow]} ${dayNum(d.date)}`,
        tag: d.isHoliday ? (d.holidayName ?? 'Public holiday')
           : tone === 'missing' ? 'missing'
           : d.planned <= 0 ? 'week off'
           : null,
        cells,
        total: d.minutes,
        planned: d.planned,
        tone,
        zebra,
      });
      dayRows++;
    }
    flushRun();

    const pct = weekPlanned > 0 ? Math.round((weekTotal / weekPlanned) * 100) : null;
    rows.push({
      kind: 'week',
      label: `Week ${wi + 1}`,
      range: `${dayNum(week[0].date)}–${dayNum(week[week.length - 1].date)} ${monLbl(week[0].date)}`,
      cells: weekCells,
      total: weekTotal,
      planned: weekPlanned,
      pct,
      // A week is judged on the days that have happened. Without this the last
      // week of the current month is always red-flagged as short, every month,
      // for the entirely ordinary reason that it is still in the future.
      tone: toneFor(weekTotal, weekPlanned, week[0].date <= todayIso),
    });
    weekRows++;
  });

  rows.push({
    kind: 'month',
    cells: monthCells,
    total: monthTotal,
    planned: monthPlanned,
    pct: monthPlanned > 0 ? Math.round((monthTotal / monthPlanned) * 100) : 0,
  });

  return {
    columns, rows, dayRows, bandRows, weekRows, missingDays,
    totalMinutes: monthTotal, plannedMinutes: monthPlanned,
  };
}
