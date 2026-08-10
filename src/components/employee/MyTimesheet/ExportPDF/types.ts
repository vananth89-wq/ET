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
  isLeave:   boolean;
  isWeekend: boolean;
}

export interface ExportWeek {
  label:   string;             // '4–10 Aug'
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
  overtimeMinutes: number;      // max(0, recorded - planned) — see dataTransforms
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
}
