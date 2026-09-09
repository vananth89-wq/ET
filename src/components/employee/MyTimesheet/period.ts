/**
 * A timesheet period, when a period is not necessarily a calendar month.
 *
 * MIG 837. `timesheet_headers.period` is the FIRST DAY of the period, which is
 * the 1st only when the configured cycle starts on the 1st. On a 26-to-25 cycle
 * the period 2026-07-26 -> 2026-08-25 is **called August**, because that is the
 * month it ends in and the month payroll pays it in.
 *
 * WHY THIS FILE EXISTS
 *   The screen used to work the window out for itself -- `daysInMonth(y, m)`,
 *   `isoDate(y, m, 1)`, a grid seeded from the 1st. That was a dozen small
 *   copies of one rule, and the moment the rule stops being "calendar month"
 *   every copy is a place for the client and the database to disagree about
 *   which sheet a day belongs to. There is one rule here, it is pure, and every
 *   function below mirrors its SQL counterpart in 837 exactly:
 *
 *     periodOf        <-> timesheet_period_of(date, start_day)
 *     periodEnd       <-> timesheet_period_end(period)
 *     periodLabel     <-> timesheet_period_label(period)
 *     periodFromLabel <-> timesheet_period_from_label(label, start_day)
 *
 *   Two definitions of one fact are two places for it to drift, so if one of
 *   these changes the other has to change in the same commit. They are checked
 *   against each other over every day from 2024 to 2027 -- see the test plan.
 *
 * WHY THE START DAY IS CAPPED AT 28 (enforced in the database, assumed here)
 *   Month arithmetic clamps. A 31st anchor lands on 28 February and never
 *   climbs back, so the cycle silently loses a day. Below 29 every month has the
 *   day, and `addMonths` below can stay this simple because of it.
 *
 * DATES ARE STRINGS
 *   'YYYY-MM-DD' throughout, never Date objects across a boundary. Date is used
 *   internally at LOCAL NOON so that adding days can never trip over a daylight
 *   saving change and land on the previous evening.
 */

const pad2 = (n: number) => String(n).padStart(2, '0');

const toDate = (iso: string): Date => {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d, 12);
};
const toIso = (dt: Date): string =>
  `${dt.getFullYear()}-${pad2(dt.getMonth() + 1)}-${pad2(dt.getDate())}`;

export const addDays = (iso: string, n: number): string => {
  const dt = toDate(iso);
  dt.setDate(dt.getDate() + n);
  return toIso(dt);
};

/** Safe for day-of-month <= 28 only, which every period anchor is. */
export const addMonths = (iso: string, n: number): string => {
  const dt = toDate(iso);
  dt.setMonth(dt.getMonth() + n);
  return toIso(dt);
};

export const firstOfMonth = (y: number, m: number) => `${y}-${pad2(m)}-01`;

/** The cycle a database that has never heard of 837 behaves as. */
export const DEFAULT_PERIOD_START_DAY = 1;

/**
 * Which period does this date belong to?
 *
 * Shift back so the cycle's start day lands on the 1st, truncate to the month,
 * shift forward again. At startDay 1 this is exactly "the 1st of that month",
 * which is why nothing about a calendar-month sheet changes meaning.
 */
export function periodOf(iso: string, startDay: number): string {
  const shifted = addDays(iso, -(startDay - 1));
  const [y, m] = shifted.split('-').map(Number);
  return addDays(firstOfMonth(y, m), startDay - 1);
}

/** The last day of the period, inclusive. */
export const periodEnd = (periodStart: string): string =>
  addDays(addMonths(periodStart, 1), -1);

/** The month a period is CALLED: the one it ends in. */
export function periodLabel(periodStart: string): { year: number; month: number } {
  const [y, m] = periodEnd(periodStart).split('-').map(Number);
  return { year: y, month: m };
}

/** The anchor of the period called {year, month}. Inverse of periodLabel. */
export function periodFromLabel(year: number, month: number, startDay: number): string {
  const label = firstOfMonth(year, month);
  return startDay === 1 ? label : addDays(addMonths(label, -1), startDay - 1);
}

/** Every date in the period, in order. 28-31 of them. */
export function periodDays(periodStart: string): string[] {
  const end = periodEnd(periodStart);
  const out: string[] = [];
  for (let d = periodStart; d <= end; d = addDays(d, 1)) out.push(d);
  return out;
}

/**
 * The whole window, computed once and passed down instead of recomputed.
 *
 * `days` is the list the calendar grid renders. On a 26-to-25 cycle it crosses a
 * calendar-month boundary in the middle, which is exactly why the grid can no
 * longer be built from a month number.
 */
export type PeriodWindow = {
  /** The anchor -- what goes in timesheet_headers.period. */
  start: string;
  /** Inclusive. */
  end: string;
  days: string[];
  /** The month it is called, which is what the URL and every heading show. */
  labelYear: number;
  labelMonth: number;
  startDay: number;
  /** True when the period is not a calendar month, so the UI knows to say so. */
  spansTwoMonths: boolean;
};

export function buildPeriodWindow(
  labelYear: number, labelMonth: number, startDay: number,
): PeriodWindow {
  const start = periodFromLabel(labelYear, labelMonth, startDay);
  const end   = periodEnd(start);
  return {
    start, end,
    days: periodDays(start),
    labelYear, labelMonth, startDay,
    spansTwoMonths: start.slice(0, 7) !== end.slice(0, 7),
  };
}
