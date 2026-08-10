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

export interface ExportEntry {
  date:       string;          // ISO yyyy-mm-dd
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
  isHoliday: boolean;
  /** The holiday's name, so a day header can say WHICH holiday rather than
   *  just that the day was one. Null on every ordinary day. */
  holidayName: string | null;
  isLeave:   boolean;
  isWeekend: boolean;
}

export interface ExportWeek {
  label:   string;             // '4–10 Aug'
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

export interface ExportActivityTotal {
  name:       string;
  minutes:    number;
  pctOfTotal: number;
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
  activities: ExportActivityTotal[];

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
