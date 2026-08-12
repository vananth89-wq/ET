/**
 * The shape the PDF renderer consumes. Deliberately flat and pre-computed: the
 * PDF components do no querying and no arithmetic beyond layout, so what you see
 * on screen and what lands in the file cannot drift.
 *
 * Every field here has a real source in this system. The original brief also
 * asked for Time In / Time Out / Break and a submitted-by/approved-by name;
 * none of those exist — timesheets are duration-only by design and
 * timesheet_headers carries submitted_at / approved_at with no _by columns.
 */

export type ExportEntryKind = 'work' | 'leave' | 'holiday';

export interface ExportActivity {
  name:    string;
  minutes: number;
}

/** Null once the sheet's current approval covers this row. */
export type ExportChangeMark = 'added' | 'edited' | null;

export interface ExportEntry {
  date:       string;          // ISO yyyy-mm-dd
  /** Whether this row post-dates the approval printed on the report. */
  changeMark: ExportChangeMark;
  dayLabel:   string;          // 'Mon'
  kind:       ExportEntryKind;
  typeName:   string;          // the time type, e.g. 'Work'
  project:    string | null;
  minutes:    number;
  notes:      string | null;
  activities: ExportActivity[];
  isWeekend:  boolean;         // planned = 0 and not a holiday
  isHoliday:  boolean;
}

/** One cell of the month grid on page 1. */
export interface ExportDay {
  date:      string;
  day:       number;
  dow:       number;           // 0 = Sun
  minutes:   number;
  planned:   number;
  /** Of `minutes`, how many are leave. Needed to split a week's bar: a week
   *  spent entirely on annual leave otherwise reads 40h / 40h, complete, and
   *  indistinguishable from a week of solid work. */
  leaveMinutes: number;
  /** A holiday that fell on a day this schedule would otherwise have worked —
   *  the only kind that reduces a week's target and therefore the only kind
   *  worth annotating. One landing on a Saturday costs nothing. */
  holidayCosts: boolean;
  isHoliday: boolean;
  /** The holiday's name, so a day header can say WHICH holiday rather than
   *  just that the day was one. Null on every ordinary day. */
  holidayName: string | null;
  isLeave:   boolean;
  isWeekend: boolean;
}

export interface ExportWeek {
  label:   string;             // '4–10 Aug'
  /** Minutes of the week's total that are leave. */
  leave:    number;
  /** Holidays that actually cost this week hours. */
  holidays: number;
  /** ISO bounds. A week cannot be called "short" without knowing whether it has
   *  actually happened — see Page3, and the calendar's `future` day state. */
  start:   string;
  end:     string;
  days:    Array<{ dow: number; minutes: number; planned: number }>;
  total:   number;
  planned: number;
}

export interface ExportProject {
  name:       string;
  minutes:    number;
  pctOfTotal: number;
  daysActive: number;
}

/** One activity line inside a project card on page 3. */
export interface ExportProjectActivity {
  name:    string;
  minutes: number;
  /** false only for the synthetic "Not itemised" remainder row. */
  itemised: boolean;
}

/**
 * A project with its activities nested underneath.
 *
 * Replaces the flat project chart. The two used to be separate lists on
 * separate pages against separate denominators — projects totalled 46h,
 * activities 63h, the month 80h — and no arrangement of captions made that
 * read as anything but three answers to one question. Nesting makes the
 * arithmetic visible: activities sum to their project, projects sum to
 * projectTotalMinutes, and what is left over is non-project time, named.
 */
export interface ExportProjectBreakdown {
  name:       string;
  minutes:    number;
  daysActive: number;
  /** Of PROJECT time, not of the month. Whole numbers that total 100 across
   *  the set — largest-remainder, so five round-ups cannot make it 102. */
  pctOfProjectTime: number;
  activities: ExportProjectActivity[];
}

/**
 * Non-project attendance, named by its time type.
 *
 * The nested project section on page 3 cannot show these — they have no project
 * to sit under — so they used to arrive as a single "Non-project attendance"
 * line. That line was where a month's leave went to be unnamed: the hours were
 * in Recorded, in the calendar and in the weekly bars, and the word appeared
 * nowhere on the page except a KPI count of days.
 */
export interface ExportNonProjectType {
  name:     string;
  minutes:  number;
  /** Drawn in the calendar's leave ink, so the row and the day cells agree. */
  isLeave:  boolean;
}

/**
 * The whole month split by project AND by non-project time type — the donut on
 * page 3. Distinct from `projectActivities`, which covers project time only:
 * this is the block that accounts for leave and training, and its slices sum to
 * the month rather than to the project subtotal.
 */
export interface ExportMonthSplit {
  name:     string;
  minutes:  number;
  /** Whole numbers totalling 100 across the set — largest-remainder. */
  pct:      number;
  isLeave:  boolean;
  isProject: boolean;
}


export interface TimesheetExportData {
  // ── Employee ──────────────────────────────────────────────────────────
  employeeName:    string;
  employeeCode:    string;
  department:      string;
  holidayCalendar: string;
  manager:         string;
  workSchedule:    string;
  periodLabel:     string;      // '1 – 31 August 2026'
  monthSlug:       string;      // 'Aug2026' — used in the filename
  status:          'to_be_submitted' | 'to_be_approved' | 'approved';

  /** True when the header's content stamp is later than its approval — the
   *  only signal that catches DELETED entries, which cannot be marked in a
   *  document that only prints rows that still exist. */
  changedSinceApproval: boolean;
  /** How many rows carry a mark. Fewer than the real number of changes
   *  whenever something was deleted. */
  changedEntryCount: number;

  /** Page 3's nested breakdown. Project-bearing entries only. */
  projectActivities: ExportProjectBreakdown[];
  /** What page 3's nested breakdown deliberately excludes, named. */
  nonProjectTypes: ExportNonProjectType[];
  /** Page 3's donut: the whole month, projects and non-project types alike. */
  monthSplit: ExportMonthSplit[];

  // ── KPIs, all pre-computed ────────────────────────────────────────────
  plannedMinutes:  number;
  recordedMinutes: number;
  /**
   * Hours recorded beyond the DAY's planned hours, summed across the month —
   * NOT max(0, monthRecorded - monthPlanned).
   *
   * The month-level figure contradicts the calendar: a month that is 120 hours
   * short overall still reports zero, while the grid sits there flagging a
   * 10-hour Monday in red. Summing the daily excess is what the calendar shows,
   * and it is the only reading that survives someone checking one against the
   * other. `varianceMinutes` below is the signed month-level figure.
   */
  overtimeMinutes: number;
  leaveDays:       number;
  workingDays:     number;
  daysPresent:     number;
  utilisationPct:  number;
  varianceMinutes: number;      // recorded - planned, signed

  // ── Body ──────────────────────────────────────────────────────────────
  monthDays:  ExportDay[];
  entries:    ExportEntry[];
  weeks:      ExportWeek[];
  projects:   ExportProject[];

  // ── Approval ──────────────────────────────────────────────────────────
  submittedAt: string | null;
  approvedAt:  string | null;
  referenceId: string;          // timesheet_headers.external_code

  // ── Meta ──────────────────────────────────────────────────────────────
  generatedAt: string;
  documentId:  string;

  /**
   * The Prowess mark as a base64 data URL, or null.
   *
   * A data URL rather than a path: the admin-configurable `nav_logo` can live
   * on Supabase storage, and react-pdf fetching a cross-origin image inside the
   * renderer fails silently — you get a blank band with no error to chase.
   * Resolving it in the app, where the session already has credentials, and
   * inlining the bytes also keeps the PDF self-contained once downloaded.
   */
  logoDataUrl: string | null;
}
