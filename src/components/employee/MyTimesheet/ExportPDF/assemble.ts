import type {
  TimesheetExportData, ExportDay, ExportEntry, ExportEntryKind, ExportChangeMark,
} from './types';

/** Kept in step with the report's own field rather than restated here. */
type HeaderStatus = TimesheetExportData['status'];
import {
  buildWeeks, buildProjects, buildProjectActivities, buildHelpGiven,
  buildNonProjectTypes, buildMonthSplit,
} from './utils/dataTransforms';
import { splitEntry, EMPTY_SPLIT } from '../billability';
import type { ProjectClass } from '../billability';

/**
 * The report, assembled once.
 *
 * TWO surfaces need this document and they must produce the SAME one: the
 * employee's own timesheet page, and an approver reviewing that month in the
 * workflow inbox. They do not share a data source -- MyTimesheet holds rows it
 * loaded itself, the approval screen holds a single time_approval_payload blob
 * -- so what they share has to be the assembly, not the fetching.
 *
 * Everything below is PURE. No Supabase, no React, no `window`. Callers hand in
 * rows that have already been read and normalised; this decides what the report
 * says about them. That is the whole point: two callers, one set of rules, so a
 * figure an approver signs off cannot differ from the one the employee filed.
 *
 * What deliberately stays OUTSIDE this function:
 *   - fetching, because the two callers legitimately fetch differently
 *   - the three label lookups (department, holiday calendar, manager) and the
 *     logo, which each caller resolves and passes in
 *   - the schedule, which arrives as two closures rather than a schedule object,
 *     because the two sides model a work schedule differently and only ever need
 *     the answers: how many minutes were planned for this date, and for this
 *     weekday.
 */

const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June',
                     'July', 'August', 'September', 'October', 'November', 'December'];
const DAY_ABBR = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];


/** One recorded row, already normalised by whichever surface loaded it. */
export interface AssembleRow {
  date:     string;                       // ISO yyyy-mm-dd
  kind:     ExportEntryKind;
  typeName: string;
  project:  string | null;
  /** Help given to another project (801), which 836 made its own bucket.
   *  Optional so a caller written before 836 still compiles; false is the
   *  right default, because everything that is not help is not help. */
  isSupport?: boolean;
  /** Who asked for it (829). Optional for the same reason. */
  requester?: string | null;
  /**
   * What the entry DISPLAYS -- post-727 that is the sum of its activity rows.
   * Callers apply `entryMinutes()` before handing the row over.
   */
  minutes:  number;
  /**
   * What the entry ROW stores. Day totals and the month's recorded figure are
   * built from this, and the two can differ on a pre-727 entry whose activity
   * names carry no split. Keeping both is what stops a day's cells from
   * disagreeing with the total printed beside them.
   */
  rawMinutes: number;
  notes:      string | null;
  activities: Array<{ name: string; minutes: number; billable?: boolean | null }>;
  changeMark: ExportChangeMark;
  /**
   * What the BOOKED project is worth (mig 825). Null where there is no booked
   * project. Every caller must read this off `project_id`, never off the
   * project NAME it puts in `project` — that label falls back to the project
   * that was HELPED (801), whose hours are not chargeable to it.
   */
  projectClass?: ProjectClass | null;
}

export interface AssembleInput {
  year:      number;
  month:     number;                      // 1-12
  totalDays: number;
  /** Mig 837: every date in the period, in order. The report used to walk
   *  1..totalDays off `month`, which cannot describe 26 Jul - 25 Aug -- it would
   *  have printed July's days under an August heading. `year` and `month` stay
   *  because they are what the period is CALLED, not what it contains. */
  days:      string[];

  /** Planned minutes for a specific date. Must already return 0 on a holiday. */
  plannedForDate: (iso: string) => number;
  /** Planned minutes for a weekday, ignoring holidays. Decides weekend vs working. */
  plannedForDow:  (dow: number) => number;
  /**
   * False when the month has no schedule attached. Without one, nothing can be
   * called a weekend -- a day with no plan is a day we know nothing about, and
   * the original code guarded every weekend test on the schedule existing.
   */
  hasSchedule: boolean;

  /** ISO date -> holiday name. */
  holidayByDate: Record<string, string>;

  rows: AssembleRow[];

  header: {
    id:                 string;
    status:             HeaderStatus;
    plannedMinutes:     number;
    /**
     * Passed in rather than summed from `rows`. The month's recorded total is a
     * figure both surfaces already hold, and recomputing it here would let the
     * report disagree with the page that launched it.
     */
    recordedMinutes:    number;
    submittedAt:        string | null;
    approvedAt:         string | null;
    contentChangedAt:   string | null;
    referenceId:        string;
  };

  labels: {
    employeeName:    string;
    employeeCode:    string;
    department:      string;
    holidayCalendar: string;
    manager:         string;
    workSchedule:    string;
  };

  logoDataUrl: string | null;
  generatedAt: string;
}

export function assembleExportData(input: AssembleInput): TimesheetExportData {
  const { year, month, totalDays, days, plannedForDate, plannedForDow, hasSchedule,
          holidayByDate, rows, header, labels } = input;

  const rowsByDate = rows.reduce<Record<string, AssembleRow[]>>((acc, r) => {
    (acc[r.date] ??= []).push(r);
    return acc;
  }, {});

  // ── The period grid ─────────────────────────────────────────────────
  const monthDays: ExportDay[] = [];
  for (const date of days) {
    const [dy, dm, dd] = date.split('-').map(Number);
    const d         = dd;
    const dow       = new Date(dy, dm - 1, dd).getDay();
    const dayRows   = rowsByDate[date] ?? [];
    const isHoliday = !!holidayByDate[date];
    monthDays.push({
      date, day: d, dow,
      minutes:   dayRows.reduce((s, r) => s + r.rawMinutes, 0),
      planned:   plannedForDate(date),
      isHoliday,
      holidayName:  holidayByDate[date] ?? null,
      isLeave:      dayRows.some(r => r.kind === 'leave'),
      leaveMinutes: dayRows.filter(r => r.kind === 'leave')
                           .reduce((s, r) => s + r.rawMinutes, 0),
      // Computed from the schedule rather than inferred: a holiday only reduces
      // a week's target if it fell on a day this schedule works.
      holidayCosts: isHoliday && hasSchedule && plannedForDow(dow) > 0,
      // A holiday outranks a weekend, exactly as the calendar cell does.
      isWeekend: !isHoliday && hasSchedule && plannedForDow(dow) === 0,
    });
  }

  // ── The rows ────────────────────────────────────────────────────────
  const entries: ExportEntry[] = rows.map(r => {
    const dow       = new Date(`${r.date}T00:00:00`).getDay();
    const isHoliday = !!holidayByDate[r.date];
    return {
      date:       r.date,
      dayLabel:   DAY_ABBR[dow],
      kind:       r.kind,
      typeName:   r.typeName,
      project:    r.project,
      projectClass: r.projectClass ?? null,
      isSupport:    r.isSupport ?? false,
      requester:    r.requester ?? null,
      minutes:    r.minutes,
      notes:      r.notes,
      activities: r.activities.map(a => ({ ...a, billable: a.billable ?? null })),
      isHoliday,
      isWeekend:  !isHoliday && hasSchedule && plannedForDow(dow) === 0,
      changeMark: r.changeMark,
    };
  });

  // ── KPIs ────────────────────────────────────────────────────────────
  const recorded = header.recordedMinutes;
  const planned  = header.plannedMinutes;
  // "Present" counts days carrying real attendance -- neither leave nor the
  // system-generated holiday row. A day of leave is accounted for, not worked.
  const daysPresent = monthDays.filter(d =>
    (rowsByDate[d.date] ?? []).some(r => r.kind !== 'leave' && r.kind !== 'holiday')
  ).length;

  const apprAt = header.status === 'approved' ? header.approvedAt : null;

  return {
    employeeName:    labels.employeeName,
    employeeCode:    labels.employeeCode,
    department:      labels.department,
    holidayCalendar: labels.holidayCalendar,
    manager:         labels.manager,
    workSchedule:    labels.workSchedule,
    /* A period that is a calendar month reads exactly as it always did. One
     * that is not says so, because "1 - 31 August" over a grid starting on the
     * 26th of July is a caption that contradicts the page under it. */
    periodLabel:     days.length > 0 && days[0].slice(0, 7) !== days[days.length - 1].slice(0, 7)
      ? `${Number(days[0].slice(8))} ${MONTH_NAMES[Number(days[0].slice(5, 7)) - 1].slice(0, 3)}`
        + ` – ${Number(days[days.length - 1].slice(8))} ${MONTH_NAMES[Number(days[days.length - 1].slice(5, 7)) - 1].slice(0, 3)} ${year}`
      : `1 – ${totalDays} ${MONTH_NAMES[month - 1]} ${year}`,
    monthSlug:       `${MONTH_NAMES[month - 1].slice(0, 3)}${year}`,
    status:          header.status,

    plannedMinutes:  planned,
    recordedMinutes: recorded,
    // Beyond the DAY's planned hours, summed -- not the month-level shortfall.
    // A month 120 hours short overall would otherwise report zero while the
    // calendar on page 1 sits there flagging a 10-hour Monday in red.
    overtimeMinutes: monthDays.reduce((s, d) => s + Math.max(0, d.minutes - d.planned), 0),
    leaveDays:       monthDays.filter(d => d.isLeave).length,
    workingDays:     monthDays.filter(d => d.planned > 0).length,
    daysPresent,
    // The same function the Monthly Summary on screen calls, on the same rows.
    // Not a second implementation: a document that contradicts the page it was
    // exported from is worse than one that omits the figure entirely.
    billSplit:       entries.reduce((acc, e) => {
      const s = splitEntry({
        entry_kind:    e.kind === 'leave' ? 'leave' : 'work',
        hours_minutes: e.minutes,
        // The class already travels with the row, so the id is only needed here
        // as a "was there a booked project at all" flag.
        project_id:    e.projectClass ? e.project : null,
        // And the same for help: with no booked project, this is the only
        // thing separating support from Training (836).
        related_project_id: e.isSupport ? e.project : null,
        activities:    e.activities.map(a => ({ hours_minutes: a.minutes, is_billable: a.billable })),
      }, e.projectClass);
      return {
        billable:     acc.billable     + s.billable,
        nonBillable:  acc.nonBillable  + s.nonBillable,
        internal:     acc.internal     + s.internal,
        support:      acc.support      + s.support,
        unclassified: acc.unclassified + s.unclassified,
        absence:      acc.absence      + s.absence,
        worked:       acc.worked       + s.worked,
      };
    }, { ...EMPTY_SPLIT }),
    utilisationPct:  planned > 0 ? (recorded / planned) * 100 : 0,
    varianceMinutes: recorded - planned,

    monthDays,
    entries,
    weeks:      buildWeeks(monthDays),
    // Shares are of the MONTH, not of each chart's own subtotal.
    projects:   buildProjects(entries, recorded),
    projectActivities: buildProjectActivities(entries),
    helpGiven:         buildHelpGiven(entries),
    nonProjectTypes:   buildNonProjectTypes(entries),
    monthSplit:        buildMonthSplit(entries),

    // The HEADER stamp is what catches a deletion -- no row survives to be
    // marked, so a report showing no marks is not a report showing no changes.
    // The count below can therefore be lower than the truth, and the stamp says
    // "deletions only" when it is zero.
    changedSinceApproval: !!apprAt
      && !!header.contentChangedAt
      && Date.parse(header.contentChangedAt) > Date.parse(apprAt),
    changedEntryCount: entries.filter(x => x.changeMark).length,

    submittedAt: header.submittedAt,
    approvedAt:  header.approvedAt,
    referenceId: header.referenceId,

    generatedAt: input.generatedAt,
    documentId:  header.id,
    logoDataUrl: input.logoDataUrl,
  };
}
