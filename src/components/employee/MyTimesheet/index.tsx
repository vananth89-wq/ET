/**
 * MyTimesheet — Employee self-service timesheet (v2).
 *
 * Schema facts (from migrations 703–706):
 *   timesheet_headers.period          → DATE, always 1st of month (e.g. 2026-08-01)
 *   timesheet_headers.external_code   → NOT NULL UNIQUE — format: {employee_code}_{YYYYMM}
 *   timesheet_headers.work_schedule_id → snapshotted from employee_employment
 *   timesheet_headers.planned_minutes → integer (minutes)
 *   timesheet_entries.hours_minutes   → integer (minutes, must be > 0)
 *   timesheet_entries constraint: project entries need project_id only;
 *                                 all others (time_type/holiday/leave) need time_type_id only
 *   employee_employment.work_schedule_id    → assigned work schedule
 *   employee_employment.holiday_calendar_id → assigned holiday calendar
 *   time_work_schedule_lines.day_number     → 1–7 (day 1 = schedule.start_day_of_week)
 */

import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { useParams, useSearchParams }                 from 'react-router-dom';
import { useAuth }                                    from '../../../contexts/AuthContext';
import { supabase }                                   from '../../../lib/supabase';
import ErrorBanner                                    from '../../shared/ErrorBanner';
import ActivityAutocomplete                           from './ActivityAutocomplete';
import SummarySection                                 from './SummarySection';
import type { ActivityHistoryItem }                   from './ActivityAutocomplete';
import { ExportPDFButton }                            from './ExportPDF';
import { assembleExportData }                         from './ExportPDF/assemble';
import type { AssembleRow }                           from './ExportPDF/assemble';
import type { TimesheetExportData }                    from './ExportPDF/types';
// buildWeeks / buildProjects / buildProjectActivities / buildNonProjectTypes /
// buildMonthSplit moved behind assembleExportData -- this page no longer derives
// any part of the report itself, so an approver's copy cannot diverge from it.
import { entryMinutes }                               from './ExportPDF/utils/dataTransforms';
import { loadLogoDataUrl }                            from './ExportPDF/logo';

// ─── Types ────────────────────────────────────────────────────────────────────

interface TimesheetHeader {
  id:                  string;
  employee_id:         string;
  period:              string;   // 'YYYY-MM-01'
  external_code:       string;
  status:              'to_be_submitted' | 'to_be_approved' | 'approved';
  work_schedule_id:    string | null;
  holiday_calendar_id: string | null;
  planned_minutes:     number;
  recorded_minutes:    number;
  submitted_at:        string | null;
  approved_at:         string | null;
  /** Mig 731: when an entry or activity under this header last changed.
   *  Compared with approved_at to answer "is there anything to resubmit?" */
  content_changed_at:  string | null;
}

/** Mig 727: one activity with its own duration. These rows are the source of
 *  truth for a project entry; the parent's hours_minutes and activities[] are
 *  mirrors a database trigger keeps in step. */
interface TimesheetEntryActivity {
  id:            string;
  activity_name: string;
  hours_minutes: number;
  display_order: number;
  /** save_timesheet_entry deletes every activity row for an entry and
   *  re-inserts them on any save, so this moves whenever the entry was saved —
   *  including the case where the parent row does not, because the sum and the
   *  name list came out identical. The most reliable "this was touched" signal
   *  we have. */
  created_at?:   string;
}

interface TimesheetEntry {
  id:            string;
  header_id:     string;
  entry_date:    string;
  entry_kind:    'project' | 'time_type' | 'holiday' | 'leave';
  project_id:    string | null;
  time_type_id:  string | null;
  hours_minutes: number;
  notes:         string | null;
  activities:    string[] | null;
  is_system_generated: boolean;
  created_at:    string;
  updated_at:    string;
  // joined
  timesheet_entry_activities?: TimesheetEntryActivity[] | null;
  time_types?:  { name: string; code: string; category: string; requires_project: boolean } | { name: string; code: string; category: string; requires_project: boolean }[];
  projects?:    { name: string } | { name: string }[];
}

/** One editable activity line. Held as STRINGS on purpose: a half-typed "1" in
 *  the hours box must stay "1" rather than collapsing to 0 while the person is
 *  still typing. */
type ActRow = { name: string; h: string; m: string };

const rowMinutes = (r: ActRow) =>
  (parseInt(r.h || '0', 10) || 0) * 60 + (parseInt(r.m || '0', 10) || 0);

/** A row with no name is the empty line at the bottom of the list, not data. */
const namedRows = (rows: ActRow[]) => rows.filter(r => r.name.trim() !== '');

const actTotal = (rows: ActRow[]) =>
  namedRows(rows).reduce((sum, r) => sum + rowMinutes(r), 0);

/** Rows -> the payload save_timesheet_entry and bulk_create both expect. */
const actPayload = (rows: ActRow[]) =>
  namedRows(rows).map(r => ({ name: r.name.trim(), minutes: rowMinutes(r) }));

/** Returns the message to show, or null when the rows are usable. Every branch
 *  names the offending activity — "Add hours" with no subject is a puzzle. */
function validateActRows(rows: ActRow[]): string | null {
  const named = namedRows(rows);
  if (!named.length) return 'Add at least one activity.';

  const noHours = named.find(r => rowMinutes(r) <= 0);
  if (noHours) return `Add hours for "${noHours.name.trim()}".`;

  if (rows.some(r => !r.name.trim() && rowMinutes(r) > 0))
    return 'One line has hours but no activity name.';

  const seen = new Set<string>();
  for (const r of named) {
    const key = r.name.trim().toLowerCase();
    if (seen.has(key))
      return `"${r.name.trim()}" is listed twice — combine the hours into one line.`;
    seen.add(key);
  }

  const totalMins = named.reduce((sum, r) => sum + rowMinutes(r), 0);
  if (totalMins > 960) return 'Total hours cannot exceed 16h in a single day.';

  return null;
}

/** Entry -> editable rows.
 *
 *  An entry written before mig 727 has activity NAMES on the parent and no rows
 *  at all. Rather than let a migration invent a split, its names are surfaced
 *  here with the whole duration on the first one, so the person who actually
 *  did the work reallocates it — and only when they were editing anyway. */
function entryToActRows(ent: TimesheetEntry): ActRow[] {
  const rows = (ent.timesheet_entry_activities ?? []) as TimesheetEntryActivity[];
  if (rows.length) {
    return [...rows]
      .sort((a, b) => a.display_order - b.display_order)
      .map(r => ({
        name: r.activity_name,
        h: String(Math.floor(r.hours_minutes / 60)),
        m: String(r.hours_minutes % 60),
      }));
  }
  const names = (ent.activities ?? []).filter(Boolean);
  if (!names.length) return [{ name: '', h: '', m: '' }];
  return names.map((n, i) => ({
    name: n,
    h: i === 0 ? String(Math.floor(ent.hours_minutes / 60)) : '',
    m: i === 0 ? String(ent.hours_minutes % 60) : '',
  }));
}

interface ScheduleLine {
  day_number:      number;   // 1–7
  planned_minutes: number;
}

interface WorkSchedule {
  id:                string;
  name:              string;
  code:              string;
  start_day_of_week: number;  // 0=Sun 1=Mon … 6=Sat
  lines:             ScheduleLine[];
}

interface HolidayEntry {
  holiday_date: string;   // 'YYYY-MM-DD'
  holiday_name: string;
}

interface TimeType {
  id:               string;
  name:             string;
  code:             string;
  category:         'attendance' | 'absence';
  requires_project: boolean;
  allows_half_day:  boolean;   // absence only — mig 718
  allows_future:    boolean;   // either category, per type — mig 729
  is_active:        boolean;
}

interface MemberSpell { from: string; to: string | null }
interface Project {
  id:         string;
  name:       string;
  active:     boolean;
  start_date: string;
  end_date:   string;
  /** Mig 787. Every membership stint overlapping the period being recorded.
   *  NULL/absent means the project was reached some other way -- already booked,
   *  or the all-projects fallback -- and carries no membership restriction. */
  member_spells?: MemberSpell[] | null;
  has_entries?:   boolean;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const MONTH_NAMES = [
  'January','February','March','April','May','June',
  'July','August','September','October','November','December',
];
const DAY_ABBR = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

function pad2(n: number) { return String(n).padStart(2, '0'); }

/** `?period=YYYY-MM` -> {y, m}, or null for anything malformed. Strict on
 *  purpose, and forgiving in what it does about it: a bad value falls back to
 *  the current month rather than erroring, because in practice it is a stale
 *  bookmark or a mistyped URL, not an attack. */
function parsePeriod(raw: string | null): { y: number; m: number } | null {
  if (!raw) return null;
  const m = /^(\d{4})-(\d{2})$/.exec(raw);
  if (!m) return null;
  const y = Number(m[1]), mo = Number(m[2]);
  if (mo < 1 || mo > 12 || y < 1970 || y > 2999) return null;
  return { y, m: mo };
}
const periodKey = (y: number, m: number) => `${y}-${pad2(m)}`;

/** How far ahead the calendar goes. Advance dating is a property of the TIME
 *  TYPE (allows_future, mig 729) -- Training and planned leave may be dated
 *  forward, project work may not -- and three months covers the furthest
 *  anything is realistically scheduled. The point of a ceiling at all is that
 *  the arrows should not take you somewhere nothing can ever be written: before
 *  this, forty clicks reached 2030, and loadPeriod filed an empty header for
 *  every month on the way. */
const FUTURE_MONTHS = 3;

// "2026-08-04" -> "4 Aug", for chips and toasts
function fmtChip(iso: string) {
  const [, m, d] = iso.split('-');
  return `${parseInt(d, 10)} ${MONTH_NAMES[parseInt(m, 10) - 1].slice(0, 3)}`;
}
function isoDate(y: number, m: number, d: number) { return `${y}-${pad2(m)}-${pad2(d)}`; }
function daysInMonth(y: number, m: number) { return new Date(y, m, 0).getDate(); }
function firstDow(y: number, m: number) { return new Date(y, m - 1, 1).getDay(); }

function fmtMins(mins: number): string {
  if (!mins) return '0 min';
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h === 0) return `${m} min`;
  return m === 0 ? `${h} hr` : `${h} hr ${m} min`;
}


/** Convert day-of-week (0=Sun) → day_number for a given schedule start_day_of_week */
function dowToDayNumber(dow: number, startDow: number): number {
  return ((dow - startDow + 7) % 7) + 1;
}

/** Calculate total planned minutes for a month from schedule + holidays */
function calcPlannedMinutes(
  year: number,
  month: number,
  schedule: WorkSchedule,
  holidayDates: string[],
): number {
  const total = daysInMonth(year, month);
  let mins = 0;
  for (let d = 1; d <= total; d++) {
    const dow       = new Date(year, month - 1, d).getDay();
    const dayNum    = dowToDayNumber(dow, schedule.start_day_of_week);
    const line      = schedule.lines.find(l => l.day_number === dayNum);
    const planned   = line?.planned_minutes ?? 0;
    const dateStr   = isoDate(year, month, d);
    const isHoliday = holidayDates.includes(dateStr);
    mins += isHoliday ? 0 : planned;
  }
  return mins;
}

/** Planned minutes for a single day from the schedule */
function plannedForDay(dow: number, schedule: WorkSchedule): number {
  const dayNum = dowToDayNumber(dow, schedule.start_day_of_week);
  return schedule.lines.find(l => l.day_number === dayNum)?.planned_minutes ?? 0;
}

function getEntryBadge(ent: TimesheetEntry): { code: string; bg: string; color: string; accentColor: string; projectName?: string } {
  if (ent.entry_kind === 'holiday') {
    return { code: 'HOL', bg: '#EDE9FE', color: '#5B21B6', accentColor: '#7C3AED' };
  }
  if (ent.entry_kind === 'leave') {
    const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
    return { code: t?.code ?? 'LV', bg: '#FEF3C7', color: '#92400E', accentColor: '#F59E0B' };
  }
  if (ent.entry_kind === 'time_type') {
    const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
    const code = t?.code ?? 'WK';
    if (ent.project_id) {
      const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
      return { code, bg: '#D1FAE5', color: '#065F46', accentColor: '#10B981', projectName: p?.name };
    }
    return { code, bg: '#D1FAE5', color: '#065F46', accentColor: '#10B981' };
  }
  // entry_kind === 'project'
  const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
  const name = p?.name ?? 'Project';
  const abbreviated = name.length > 4 ? name.slice(0, 4).toUpperCase() : name.toUpperCase();
  return { code: abbreviated, bg: '#DBEAFE', color: '#1E40AF', accentColor: '#3B82F6', projectName: name };
}

interface Toast {
  id:      number;
  msg:     string;
  // 'warn' is amber: the write SUCCEEDED and the employee should know
  // something about it anyway — a day over the soft line (mig 738). Reporting
  // that in the green toast would bury it; reporting it in the red one would
  // say the save failed, which it did not.
  kind:    'ok' | 'bad' | 'warn';
  undoIds?: string[];        // entry ids to delete if the user hits Undo
}

// ─── Day-cell status ──────────────────────────────────────────────────────────
// Single source of truth for BOTH the day-cell metric and the progress bar, so
// the two can never contradict each other (e.g. "8 / 8h" beside an amber bar).
type DayStatus = 'empty' | 'part' | 'done' | 'over';

function dayStatus(recorded: number, planned: number): DayStatus {
  if (recorded === 0)      return 'empty';
  if (planned <= 0)        return 'done';
  if (recorded >  planned) return 'over';
  if (recorded >= planned) return 'done';   // exact minutes, never a rounded display value
  return 'part';
}

// Display rounding must never cross a status threshold: 479 min must not render
// "8" beside a blue bar, and 481 min must not render "8" beside a red one.
function fmtDayHours(minutes: number, status: DayStatus): string {
  const raw = minutes / 60;
  const v = status === 'part' ? Math.floor(raw * 10) / 10
          : status === 'over' ? Math.ceil (raw * 10) / 10
          :                     Math.round(raw * 10) / 10;
  return Number.isInteger(v) ? String(v) : v.toFixed(1);
}

// Calendar cell label: the project name when there is one, else the time type.
// The panel shows project and time type separately; the cell only has room for one.
function getCellLabel(ent: TimesheetEntry): string {
  const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
  if (p?.name) return p.name;
  const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
  return t?.name ?? '';
}

/**
 * Does this entry post-date the approval printed on the report?
 *
 * Three signals, because no single one covers the ground:
 *   * created_at  — the row did not exist when the sheet was approved.
 *   * updated_at  — the row was changed afterwards.
 *   * the newest ACTIVITY row's created_at — save_timesheet_entry deletes and
 *     re-inserts every activity line on any save, so this moves even when the
 *     parent does not. Moving an hour from Code Review to Testing leaves the
 *     entry's sum and name list identical, mig 727's sync skips the parent
 *     UPDATE, and updated_at never budges — while the breakdown, the thing 727
 *     exists to record, changed.
 *
 * What it CANNOT see is a deletion: a row removed after approval is not here to
 * mark. That is why the header-level flag drives the status chip and the stamp,
 * and this only decorates the rows that survive.
 */
function changeMarkFor(e: TimesheetEntry, approvedAt: string | null): 'added' | 'edited' | null {
  if (!approvedAt) return null;                     // nothing to measure against
  const appr = Date.parse(approvedAt);
  if (Number.isNaN(appr)) return null;

  const created = Date.parse(e.created_at ?? '');
  if (!Number.isNaN(created) && created > appr) return 'added';

  const stamps = [
    Date.parse(e.updated_at ?? ''),
    ...(e.timesheet_entry_activities ?? []).map(a => Date.parse(a.created_at ?? '')),
  ].filter(n => !Number.isNaN(n));

  return stamps.some(t => t > appr) ? 'edited' : null;
}

// ─── Style constants ──────────────────────────────────────────────────────────


const STATUS_META: Record<string, { label: string; bg: string; color: string }> = {
  to_be_submitted: { label: 'To Be Submitted', bg: '#FFF7ED', color: '#C2410C' },
  to_be_approved:  { label: 'Pending Approval', bg: '#EFF6FF', color: '#1D4ED8' },
  approved:        { label: 'Approved',          bg: '#ECFDF5', color: '#065F46' },
};

// ─── Component ────────────────────────────────────────────────────────────────

/** Read-only card for a public holiday.
 *  Holidays are master data, never attendance rows — nothing is stored and
 *  nothing is generated. This is derived from `holidayByDate` at render time.
 *
 *  `plannedMinutes` is the schedule's raw value for the weekday. The month
 *  total (plannedMinutesForMonth) deliberately excludes holidays, so printing a
 *  bare "8h" here would not add up against the header. The row says so instead.
 */
function HolidayCard({ name, plannedMinutes }: { name: string; plannedMinutes: number }) {
  const row = (label: string, value: string) => (
    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, fontSize: 12, color: '#6B7280' }}>
      <span>{label}</span>
      <span style={{ color: '#374151', fontWeight: 600, textAlign: 'right' }}>{value}</span>
    </div>
  );
  return (
    <div style={{
      border: '1px solid #E9D5FF', background: '#FAF5FF', borderRadius: 10,
      padding: '12px 14px', marginBottom: 8, display: 'flex', flexDirection: 'column', gap: 8,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 14, fontWeight: 700, color: '#5B21B6' }}>
        <span aria-hidden="true">🎉</span> Public Holiday
      </div>
      <div style={{ fontSize: 16, fontWeight: 700, color: '#111827', lineHeight: 1.3 }}>{name}</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 4, paddingTop: 8, borderTop: '1px solid #F3E8FF' }}>
        {plannedMinutes > 0 && row('Scheduled hours', `${Math.round(plannedMinutes / 60)}h — not required`)}
        {row('Source', 'Holiday Calendar')}
        {row('Status', 'Read-only')}
      </div>
      <div style={{ fontSize: 11, color: '#9CA3AF', fontStyle: 'italic', lineHeight: 1.45 }}>
        Automatically derived from your assigned Holiday Calendar.
      </div>
    </div>
  );
}

/**
 * The Prowess mark, inlined as a data URL for the PDF export.
 *
 * Honours the admin-configured `nav_logo` exactly as AppHeader does, so
 * rebranding the app rebrands the report without a second setting. Falls back
 * to the bundled /logo.png, and to null if anything at all goes wrong -- the
 * report simply prints without a logo, which is still a correct report.
 *
 * The bytes are inlined rather than passed as a URL because a themed nav_logo
 * can be cross-origin, and react-pdf fetching one inside the renderer fails
 * silently: a blank band and no error to chase. Fetching here, where the
 * session already has credentials, also leaves the downloaded PDF
 * self-contained.
 */

export default function MyTimesheet() {
  const { employee } = useAuth();

  // ── Whose timesheet is this? ─────────────────────────────────────────────
  // /my-timesheet has no param and means "mine". /timesheet/:employeeId means
  // somebody else's, reached from the header search. Everything below reads
  // `subjectId`; `employee.id` now only answers "who is looking".
  //
  // The database decides what looking gets you. `access` comes from
  // time_timesheet_access (mig 740) which is user_can() per employee, so the
  // page cannot disagree with RLS or with the write RPCs — and an administrator
  // changing a permission set or a target group is reflected on the next load
  // with no deploy. Nothing here branches on "is this person a manager".
  const { employeeId: routeEmployeeId } = useParams<{ employeeId?: string }>();
  const subjectId = routeEmployeeId ?? employee?.id ?? '';
  const isSelf    = !routeEmployeeId || routeEmployeeId === employee?.id;

  const [subjectName, setSubjectName] = useState('');
  const [access, setAccess] = useState<{
    can_view: boolean; can_edit: boolean; can_delete: boolean; can_create: boolean;
  } | null>(null);
  // Issue 3 fix — track whether the access RPC is still in flight so the Create
  // button never flickers between a guess (isSelf) and the real answer.
  const [accessLoading, setAccessLoading] = useState(true);

  useEffect(() => {
    if (!subjectId) return;
    let cancelled = false;
    setAccessLoading(true);
    (async () => {
      const { data } = await supabase.rpc('time_timesheet_access', { p_employee_id: subjectId });
      if (!cancelled) { setAccess(data as any); setAccessLoading(false); }
    })();
    return () => { cancelled = true; };
  }, [subjectId]);

  // Until the answer arrives, assume the historic behaviour for your own sheet
  // and assume nothing for anyone else's. Defaulting the other way would flash
  // a read-only calendar at every employee opening their own month.
  const mayEdit = access ? access.can_edit : isSelf;
  const mayView = access ? access.can_view : isSelf;

  // Period
  const today = new Date();
  // The month lives in the URL, not only in React state. Without it a refresh
  // threw you back to the current month, Back never stepped through months, and
  // no month could be bookmarked or sent to anyone. That bites hardest on the
  // PREVIOUS month -- with a one-month edit window it is exactly where people go
  // to finish things off, and it was the one they lost on every reload.
  const [searchParams, setSearchParams] = useSearchParams();
  const urlSeed = parsePeriod(searchParams.get('period'));
  const [year,  setYear]  = useState(urlSeed?.y ?? today.getFullYear());
  const [month, setMonth] = useState(urlSeed?.m ?? today.getMonth() + 1);
  /** Earliest month the employee may reach, as YYYY-MM -- their hire month.
   *  NULL until the employment row loads, and NULL means NO floor: failing open
   *  the way editFloor does, so a slow or refused read never traps someone. */
  const [minPeriod, setMinPeriod] = useState<string | null>(null);

  // Employee metadata
  const [empCode, setEmpCode] = useState<string>('');

  // Reference data
  const [timeTypes,  setTimeTypes]  = useState<TimeType[]>([]);
  const [projects,   setProjects]   = useState<Project[]>([]);

  // Timesheet data
  const [header,    setHeader]    = useState<TimesheetHeader | null>(null);
  const [entries,   setEntries]   = useState<TimesheetEntry[]>([]);
  const [schedule,  setSchedule]  = useState<WorkSchedule | null>(null);
  const [holidays,  setHolidays]  = useState<HolidayEntry[]>([]);

  // Create modal (multi-date attendance)
  const [createOpen,  setCreateOpen]  = useState(false);
  const [createDates, setCreateDates] = useState<Set<string>>(new Set());
  // dates[] renders as a list with a 'Deselect these N' button (hard errors).
  // kind 'notice' = amber, no list — the app corrected something on the user's behalf.
  const [createErr,   setCreateErr]   = useState<{ msg: string; dates: string[]; kind?: 'error' | 'notice' } | null>(null);
  const [creating,    setCreating]    = useState(false);

  // Copy Day — 'idle' | 'pick' (choose a source) | 'paste' (choose targets)
  const [copyMode,  setCopyMode]  = useState<'idle' | 'pick' | 'paste'>('idle');
  const [clipboard, setClipboard] = useState<{ from: string; entries: TimesheetEntry[] } | null>(null);
  // Selective copy: when a source day has multiple entries show a picker before
  // committing to the clipboard. copyPickerDate = null means the picker is closed.
  const [copyPickerDate, setCopyPickerDate] = useState<string | null>(null);
  const [copyPickerSel,  setCopyPickerSel]  = useState<Set<string>>(new Set());

  // Toasts
  const [toasts, setToasts] = useState<Toast[]>([]);

  // Loading states
  const [loading,      setLoading]      = useState(true);
  const [error,        setError]        = useState<string | null>(null);
  const [saving,       setSaving]       = useState(false);
  const [submitting,   setSubmitting]   = useState(false);
  const [withdrawing,  setWithdrawing]  = useState(false);
  /** First day of the earliest month this employee may still change, from
   *  time_employee_edit_floor() (mig 730). NULL = no configured limit. */
  const [editFloor,    setEditFloor]    = useState<string | null>(null);

  // Panel
  const [selectedDate,   setSelectedDate]   = useState<string | null>(null);
  const [panelOpen,      setPanelOpen]      = useState(false);
  const [addingEntry,    setAddingEntry]    = useState(false);
  const [editingEntry,   setEditingEntry]   = useState<TimesheetEntry | null>(null);
  const [confirmSubmit,   setConfirmSubmit]   = useState(false);
  const [confirmWithdraw, setConfirmWithdraw] = useState(false);

  // Hovered calendar day - drives the cell hover state and the empty-day CTA
  const [hoverDate, setHoverDate] = useState<string | null>(null);

  // ── Days / Summary ────────────────────────────────────────────────────
  // NOT a router and NOT a display toggle. Both blocks are always mounted in
  // one scroll flow; the tabs move the viewport and the scroll position moves
  // the tabs back. Someone who never touches a tab still reaches the summary
  // by scrolling, which is the whole point.
  const scrollRef  = useRef<HTMLDivElement | null>(null);
  const summaryRef = useRef<HTMLDivElement | null>(null);
  const [atSummary, setAtSummary] = useState(false);

  function scrollToSummary() {
    summaryRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
  function scrollToCalendar() {
    // The page header lives OUTSIDE the scrolling element, so scrollIntoView on
    // it does nothing. Scroll the container itself.
    scrollRef.current?.scrollTo({ top: 0, behavior: 'smooth' });
  }
  /** A missing-day chip: go back up and open that day, ready to record. */
  function jumpToDate(dateStr: string | null) {
    scrollToCalendar();
    if (dateStr) { setSelectedDate(dateStr); setPanelOpen(true); cancelForm(); }
  }

  // Expand/collapse per entry card in the panel
  const [expandedEntries, setExpandedEntries] = useState<Set<string>>(new Set());

  // Activity history for smart autocomplete
  const [activityHistory, setActivityHistory] = useState<ActivityHistoryItem[]>([]);

  // Entry form
  const emptyForm = { kind: 'time_type' as 'time_type' | 'project', typeId: '', projId: '', hours: '', mins: '', notes: '', actRows: [{ name: '', h: '', m: '' }] as ActRow[], ttCategory: '' as '' | 'attendance' | 'absence' };
  const [form,    setForm]    = useState(emptyForm);
  const [formErr, setFormErr] = useState('');
  /** What the edit form held when it opened. NULL while adding — there is
   *  nothing for a new entry to be unchanged from. */
  const [baselineForm, setBaselineForm] = useState<typeof emptyForm | null>(null);

  // ── Fetch employee code + reference data once ───────────────────────────
  useEffect(() => {
    if (!subjectId) return;
    (async () => {
      const [empRes, ttRes, actRes] = await Promise.all([
        supabase.from('employees').select('employee_id, name').eq('id', subjectId).single(),
        supabase.from('time_types').select('id, name, code, category, requires_project, allows_half_day, allows_future, is_active').eq('is_active', true).eq('is_system_managed', false).order('category').order('name'),
        supabase.rpc('get_employee_activities', { p_employee_id: subjectId }),
      ]);
      if (empRes.data) { setEmpCode(empRes.data.employee_id ?? ''); setSubjectName((empRes.data as any).name ?? ''); }
      if (ttRes.data)  setTimeTypes(ttRes.data as TimeType[]);
      if (actRes.data) setActivityHistory(actRes.data as ActivityHistoryItem[]);
    })();
  }, [subjectId]);

  // ── Projects offered for THIS period ────────────────────────────────────
  //
  // Deliberately its own effect, keyed on the period as well as the employee.
  // It used to sit in the reference-data fetch above, which runs once per
  // employee -- so the dropdown resolved membership as of TODAY and never
  // re-asked. Open a March timesheet in June, having rolled off the project in
  // April, and March's project was missing from the very period that needed it
  // (mig 786 header spells the case out).
  //
  // A stint counts when it overlaps the period at all, so joining mid-month
  // still offers the project for that whole month.
  useEffect(() => {
    if (!subjectId) return;
    let live = true;
    const from = `${year}-${pad2(month)}-01`;
    const to   = `${year}-${pad2(month)}-${pad2(new Date(year, month, 0).getDate())}`;
    (async () => {
      const { data } = await supabase.rpc('my_timesheet_projects', {
        p_employee_id: subjectId, p_period_start: from, p_period_end: to,
      });
      if (live && data) setProjects(data as Project[]);
    })();
    return () => { live = false; };
  }, [subjectId, year, month]);

  // ── Load / auto-create header + entries for the period ─────────────────
  const loadPeriod = useCallback(async () => {
    if (!subjectId || !empCode) return;
    setLoading(true);
    setError(null);

    const periodDate = `${year}-${pad2(month)}-01`;

    // 0. Resolve the employee's CURRENT schedule + holiday calendar.
    //    This used to live inside the "header does not exist" branch, which meant
    //    the header's snapshot of holiday_calendar_id was the only source of truth
    //    forever after. If HR assigned the calendar after the header was created,
    //    the timesheet never saw a single holiday. Resolve it every load instead.
    //
    //    effective_to: 11 other queries in this codebase use the '9999-12-31'
    //    sentinel; this one query used .is(null). Accept both so a row written
    //    under either convention still resolves.
    //    The column is dept_id. `department_id` is the name on timesheet_headers,
    //    not here -- and PostgREST rejects the ENTIRE request when the select
    //    list names a column that does not exist, so this query returned 400 on
    //    every load for every user and empRow was always null.
    //
    //    It survived because of two things at once. The error was discarded, so
    //    the 400 never reached the screen; and step 3 below reads
    //    `hdr.work_schedule_id ?? empWsId`, so anyone whose header was created
    //    while they already had a schedule never needed empWsId at all. Only an
    //    employee whose header predates their schedule assignment falls through
    //    to it -- and they get a month of non-working days with nothing to
    //    explain it.
    //
    //    .order is not decoration either: two open-ended rows and .limit(1)
    //    without it returns whichever the planner feels like.
    const { data: empRow, error: empErr } = await supabase
      .from('employee_employment')
      .select('work_schedule_id, holiday_calendar_id, dept_id, hire_date, departments(name)')
      .eq('employee_id', subjectId)
      .or('effective_to.is.null,effective_to.eq.9999-12-31')
      .order('effective_from', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (empErr) { setError(empErr.message); setLoading(false); return; }

    // The hire month is the floor for navigation. Read from the same row rather
    // than a second query -- it arrives one load late, which is why the clamp
    // fails open until it does.
    if (empRow?.hire_date) setMinPeriod(String(empRow.hire_date).slice(0, 7));

    const empWsId = empRow?.work_schedule_id    ?? null;
    const empHcId = empRow?.holiday_calendar_id ?? null;

    // 1. Find existing header
    let { data: hdr, error: hErr } = await supabase
      .from('timesheet_headers')
      .select('id, employee_id, period, external_code, status, work_schedule_id, holiday_calendar_id, planned_minutes, recorded_minutes, submitted_at, approved_at, content_changed_at')
      .eq('employee_id', subjectId)
      .eq('period', periodDate)
      .maybeSingle();

    if (hErr) { setError(hErr.message); setLoading(false); return; }

    let headerId: string;

    // Opening a month with no header creates one — right for the employee's own
    // visit, wrong for anybody else's. Nothing reads empty headers today, but
    // the moment a "who hasn't submitted" report exists, every manager who ever
    // glanced at a month becomes a false positive in it. Viewing reads.
    if (!hdr && !isSelf) {
      setHeader(null);
      setEntries([]);
      setLoading(false);
      return;
    }

    if (!hdr) {
      // 2a. Work schedule + holiday calendar come from the hoisted lookup above
      const wsId  = empWsId;
      const hcId  = empHcId;
      const deptId   = empRow?.dept_id ?? null;
      const deptName = (empRow?.departments as any)?.name ?? null;

      // 2b. Resolve planned_minutes from work schedule
      let plannedMins = 0;
      let ws: WorkSchedule | null = null;
      if (wsId) {
        const { data: wsData } = await supabase
          .from('time_work_schedules')
          .select('id, name, code, start_day_of_week, time_work_schedule_lines(day_number, planned_minutes)')
          .eq('id', wsId)
          .single();
        if (wsData) {
          ws = {
            id: wsData.id, name: wsData.name, code: wsData.code,
            start_day_of_week: wsData.start_day_of_week,
            lines: (wsData.time_work_schedule_lines ?? []) as ScheduleLine[],
          };
        }
      }

      // 2c. Resolve holiday dates for this period
      let hdDates: string[] = [];
      if (hcId) {
        const { data: hdData, error: hdErr } = await supabase
          .from('time_calendar_entries')
          .select('entry_date')
          .eq('calendar_id', hcId)
          .gte('entry_date', periodDate)
          .lte('entry_date', isoDate(year, month, daysInMonth(year, month)));
        if (hdErr) { setError(hdErr.message); setLoading(false); return; }
        hdDates = (hdData ?? []).map((h: any) => h.entry_date);
      }

      if (ws) plannedMins = calcPlannedMinutes(year, month, ws, hdDates);

      // 2d. Create header
      const externalCode = `${empCode}_${year}${pad2(month)}`;
      const { data: created, error: cErr } = await supabase
        .from('timesheet_headers')
        .insert({
          employee_id:         subjectId,
          period:              periodDate,
          external_code:       externalCode,
          status:              'to_be_submitted',
          work_schedule_id:    wsId,
          holiday_calendar_id: hcId,
          department_id:       deptId,
          department_name:     deptName,
          planned_minutes:     plannedMins,
          recorded_minutes:    0,
        })
        .select('id, employee_id, period, external_code, status, work_schedule_id, holiday_calendar_id, planned_minutes, recorded_minutes, submitted_at, approved_at, content_changed_at')
        .single();

      if (cErr) { setError(cErr.message); setLoading(false); return; }
      hdr = created;

      if (ws) { setSchedule(ws); }
      // Step 4 below re-reads the calendar with real names on this same pass,
      // so seeding placeholder names here would only flash "Holiday" and lose.
    }

    setHeader(hdr as TimesheetHeader);
    headerId = hdr!.id;

    // 3. Load work schedule. Keep a local copy — `schedule` state is not readable
    //    until the next render, and step 4b needs it to recompute planned minutes.
    let wsLive: WorkSchedule | null = schedule;
    const wsIdLive = hdr!.work_schedule_id ?? empWsId;
    if (!wsLive && wsIdLive) {
      const { data: wsData } = await supabase
        .from('time_work_schedules')
        .select('id, name, code, start_day_of_week, time_work_schedule_lines(day_number, planned_minutes)')
        .eq('id', wsIdLive)
        .maybeSingle();
      if (wsData) {
        wsLive = {
          id: wsData.id, name: wsData.name, code: wsData.code,
          start_day_of_week: wsData.start_day_of_week,
          lines: (wsData.time_work_schedule_lines ?? []) as ScheduleLine[],
        };
        setSchedule(wsLive);
      }
    }

    // 4. Load holiday calendar entries for this period.
    //    Employment wins over the header's snapshot: assigning a calendar after
    //    the header exists must still light up the timesheet. The old `!holidays.length`
    //    guard also made this load-once, so navigating July -> August kept July's
    //    dates on screen. It loads every period now, and clears when there are none.
    const calId = empHcId ?? hdr!.holiday_calendar_id;
    let hdRows: { holiday_date: string; holiday_name: string }[] = [];
    if (calId) {
      const { data: hdData, error: hdErr } = await supabase
        .from('time_calendar_entries')
        .select('entry_date, time_holidays!inner(holiday_name)')
        .eq('calendar_id', calId)
        .gte('entry_date', periodDate)
        .lte('entry_date', isoDate(year, month, daysInMonth(year, month)));
      // Surface it. Swallowing this error is exactly how the wrong table went
      // unnoticed: the query 400'd, data came back null, and the month simply
      // rendered as if the calendar were empty.
      if (hdErr) { setError(hdErr.message); setLoading(false); return; }
      hdRows = (hdData ?? []).map((h: any) => ({
        holiday_date: h.entry_date,
        holiday_name: (Array.isArray(h.time_holidays) ? h.time_holidays[0] : h.time_holidays)?.holiday_name ?? 'Holiday',
      }));
    }
    setHolidays(hdRows);

    // 4a. Heal a header that was created before the calendar was assigned, so the
    //     stored snapshot stops disagreeing with the employee's actual assignment.
    if (calId && hdr!.holiday_calendar_id !== calId) {
      await supabase.from('timesheet_headers').update({ holiday_calendar_id: calId }).eq('id', hdr!.id);
      hdr = { ...hdr!, holiday_calendar_id: calId } as typeof hdr;
      setHeader(hdr as TimesheetHeader);
    }

    // 4c. Same repair for the schedule. A header created before the employee had
    //     one stores NULL, and time_planned_minutes_for_date() -- which every
    //     entry trigger consults -- resolves the schedule through the HEADER, not
    //     through employment:
    //
    //       JOIN time_work_schedules ws ON ws.id = h.work_schedule_id
    //
    //     So without this the screen would show 8h working days from wsLive while
    //     the database still scored every date at 0 and refused each absence with
    //     "Leave cannot be recorded on a non-working day". A UI that disagrees
    //     with its own triggers is worse than one that shows nothing.
    //
    //     Only fills a NULL. A header that already names a schedule is left
    //     alone: re-assignment is mig 723's recalc trigger to handle, and racing
    //     it from the client would just make the two disagree.
    if (!hdr!.work_schedule_id && wsIdLive) {
      await supabase.from('timesheet_headers').update({ work_schedule_id: wsIdLive }).eq('id', hdr!.id);
      hdr = { ...hdr!, work_schedule_id: wsIdLive } as typeof hdr;
      setHeader(hdr as TimesheetHeader);
    }

    // 4b. planned_minutes is a creation-time snapshot. A holiday added to the
    //     calendar afterwards leaves it overstated (Aug 2026 read 176 hr when the
    //     16th made it 168). Recompute from the live schedule + holidays.
    //     Not while somebody is being asked to approve it — the total must not
    //     move underneath the approver. Approved sheets DO recompute, because
    //     with mig 730 approved is the normal resting state of every month that
    //     has been submitted, and freezing them would mean a holiday added in
    //     arrears leaves the planned figure permanently wrong.
    if (wsLive && hdr!.status !== 'to_be_approved') {
      const truePlanned = calcPlannedMinutes(year, month, wsLive, hdRows.map(h => h.holiday_date));
      if (truePlanned !== hdr!.planned_minutes) {
        await supabase.from('timesheet_headers').update({ planned_minutes: truePlanned }).eq('id', hdr!.id);
        hdr = { ...hdr!, planned_minutes: truePlanned } as typeof hdr;
        setHeader(hdr as TimesheetHeader);
      }
    }

    // 5. Load entries
    const { data: ents, error: eErr } = await supabase
      .from('timesheet_entries')
      .select(`
        id, header_id, entry_date, entry_kind, project_id, time_type_id,
        hours_minutes, notes, activities, is_system_generated, created_at, updated_at,
        timesheet_entry_activities ( id, activity_name, hours_minutes, display_order, created_at ),
        time_types ( name, code, category, requires_project ),
        projects ( name )
      `)
      .eq('header_id', headerId)
      .order('entry_date')
      .order('created_at');

    if (eErr) { setError(eErr.message); setLoading(false); return; }
    setEntries((ents ?? []) as unknown as TimesheetEntry[]);
    setLoading(false);
  }, [subjectId, empCode, year, month]);

  useEffect(() => {
    if (empCode) loadPeriod();
  }, [loadPeriod, empCode]);

  // ── Recalculate recorded_minutes on header after entry changes ──────────
  async function syncRecordedMinutes(headerId: string, allEntries: TimesheetEntry[]) {
    const total = allEntries.reduce((s, e) => s + (e.hours_minutes ?? 0), 0);
    await supabase
      .from('timesheet_headers')
      .update({ recorded_minutes: total })
      .eq('id', headerId);
  }

  // ── Activity history ──────────────────────────────────────────────────
  // Both save paths — the day panel and the Create modal — must do the same two
  // things after writing entries: show the new activity as a suggestion NOW,
  // and reconcile with the server. submitCreate previously did neither (it fired
  // record_activity_usages and never refreshed), so an activity typed in the
  // modal only appeared after a full page reload.
  //
  // The optimistic pass is what makes it feel instant; the RPC round-trip then
  // replaces it with the real row, server id and true usage_count included.
  function noteActivitiesUsed(names: string[]) {
    const clean = names.map(n => n.trim()).filter(Boolean);
    if (!clean.length || !subjectId) return;

    // Optimistic. Build new objects rather than mutating the ones in state —
    // `[...prev]` copies the array, not the items inside it.
    setActivityHistory(prev => {
      const now  = new Date().toISOString();
      const next = [...prev];
      for (const name of clean) {
        const i = next.findIndex(h => h.activity_name.toLowerCase() === name.toLowerCase());
        if (i >= 0) {
          next[i] = { ...next[i], usage_count: next[i].usage_count + 1, last_used_at: now };
        } else {
          next.push({
            id:            `optimistic-${Date.now()}-${name}`,
            activity_name: name,
            usage_count:   1,
            last_used_at:  now,
            is_favorite:   false,
          });
        }
      }
      return next;
    });

    // Reconcile. Deliberately not gated on data?.ok — record_activity_usages
    // returns ok:true unconditionally, so the guard only ever hid real errors.
    const empId = subjectId;
    supabase
      .rpc('record_activity_usages', { p_employee_id: empId, p_activity_names: clean })
      .then(() =>
        supabase.rpc('get_employee_activities', { p_employee_id: empId })
          .then(({ data: hist }) => { if (hist) setActivityHistory(hist as ActivityHistoryItem[]); }));
  }

  // ── Edit window ───────────────────────────────────────────────────────
  // The floor is a single config value, not per-month, so it is fetched once
  // rather than on every period change. The database enforces it either way
  // (trg_timesheet_entry_edit_window); this is only so the UI can say WHY a
  // month is read-only instead of presenting buttons that will be refused.
  useEffect(() => {
    let cancelled = false;
    supabase.rpc('time_employee_edit_floor').then(({ data, error: e }) => {
      if (cancelled) return;
      // A failure here must not lock the employee out of their own timesheet.
      // NULL already means "no limit", and the trigger is the real gate, so
      // failing open costs nothing: the write is still refused server-side.
      if (e) { setEditFloor(null); return; }
      setEditFloor(typeof data === 'string' ? data : null);
    });
    return () => { cancelled = true; };
  }, []);

  // ── Toasts ────────────────────────────────────────────────────────────
  const toastSeq = useRef(0);
  function pushToast(msg: string, kind: 'ok' | 'bad' | 'warn' = 'ok', undoIds?: string[]) {
    const id = ++toastSeq.current;
    setToasts(t => [...t, { id, msg, kind, undoIds }]);
    setTimeout(() => setToasts(t => t.filter(x => x.id !== id)), undoIds ? 7000 : 3800);
  }
  async function undoEntries(ids: string[], toastId: number) {
    setToasts(t => t.filter(x => x.id !== toastId));
    const { data } = await supabase.rpc('delete_timesheet_entries', { p_ids: ids });
    if (data?.ok) { await reloadEntries(); pushToast('Change reverted.'); }
    else pushToast(data?.message ?? 'Could not undo.', 'bad');
  }

  /**
   * THE reload. Entries plus the header fields a write can move.
   *
   * Returns the list because the callers that follow a write need it for the
   * recorded-minutes sync, and needing it is exactly why two of them grew their
   * own hand-written copy of this query instead of calling it. One of those
   * copies is why editing an approved entry did not re-enable Resubmit: the
   * change stamp was re-read here and nowhere else.
   */
  async function reloadEntries(): Promise<TimesheetEntry[]> {
    if (!header) return entries;
    const { data: ents } = await supabase
      .from('timesheet_entries')
      .select(`id, header_id, entry_date, entry_kind, project_id, time_type_id, hours_minutes, notes, activities, is_system_generated, created_at, updated_at, timesheet_entry_activities(id, activity_name, hours_minutes, display_order, created_at), time_types(name,code,category,requires_project), projects(name)`)
      .eq('header_id', header.id)
      .order('entry_date').order('created_at');
    const list = (ents ?? []) as unknown as TimesheetEntry[];
    setEntries(list);

    // content_changed_at is stamped by a trigger (mig 731), so the only way to
    // know its new value is to read it. Not computed locally from `list`:
    // a delete leaves nothing behind to compute from, and an activity reshuffle
    // that keeps the day's total can change the sheet without moving any number
    // this function can see.
    const { data: hdr } = await supabase
      .from('timesheet_headers')
      .select('content_changed_at')
      .eq('id', header.id)
      .single();

    setHeader(h => h ? {
      ...h,
      recorded_minutes:   list.reduce((s, e) => s + e.hours_minutes, 0),
      content_changed_at: hdr?.content_changed_at ?? h.content_changed_at,
    } : h);

    return list;
  }

  // ── Day occupancy — the client half of migration 726 ──────────────────
  /**
   * Planned minutes for a date. The mirror of time_planned_minutes_for_date()
   * (mig 723): holiday first, then the schedule line for that weekday.
   *
   * Returns 0 when the schedule has not loaded yet, which makes every caller
   * below fall OPEN rather than block a day it cannot measure. A day wrongly
   * offered is caught by the trigger; a day wrongly blocked just looks broken.
   */
  function plannedFor(dateStr: string): number {
    if (holidayByDate[dateStr]) return 0;
    if (!schedule)              return 0;
    const [y, m, d] = dateStr.split('-').map(Number);
    return plannedForDay(new Date(y, m - 1, d).getDay(), schedule);
  }

  /** Minutes of absence recorded on a date. */
  function absenceMinutes(dateStr: string): number {
    return (entriesByDate[dateStr] ?? [])
      .filter(e => e.entry_kind === 'leave')
      .reduce((s, e) => s + e.hours_minutes, 0);
  }

  /** Attendance = anything that is neither leave nor holiday. */
  function hasAttendance(dateStr: string): boolean {
    return (entriesByDate[dateStr] ?? [])
      .some(e => e.entry_kind !== 'leave' && e.entry_kind !== 'holiday');
  }

  /**
   * Rule (g) of mig 726 — absence already covers the whole planned day, so
   * there is no room for work in it. Instance-level: measured in minutes, not
   * read off the type's allows_half_day flag. A half-day-CAPABLE type recorded
   * for the full 8 hours fills the day just as completely as a full-day-only
   * one, and mig 721 rules (c)/(d) never looked at it.
   *
   * Returns the reason to show, or null when attendance is allowed.
   */
  function dayAbsenceBlock(dateStr: string): string | null {
    const planned = plannedFor(dateStr);
    if (planned <= 0) return null;            // holiday or non-working: nothing to fill
    if (absenceMinutes(dateStr) < planned) return null;
    const ent = (entriesByDate[dateStr] ?? []).find(e => e.entry_kind === 'leave');
    return `${ent ? getCellLabel(ent) : 'Absence'} covers the full day`;
  }

  // ── Date-scope rules — Create modal ───────────────────────────────────
  // A date may receive attendance when it is inside this month, not in the
  // future, and not already used up by absence. Non-working days ARE allowed:
  // weekend work is real work.
  //
  // A day that already holds OTHER entries is allowed too, since mig 726. The
  // clash is now (date, time type, project) — the picker cannot evaluate that
  // before the type and project are chosen, so the RPC reports it with the
  // offending dates instead and the user deselects them.
  function dateBlockedReason(dateStr: string): string | null {
    if (dateStr.slice(0, 7) !== `${year}-${pad2(month)}`) return 'Outside this timesheet month';

    // Mig 729: the TYPE decides whether a future date is legal, not the date.
    //
    // The picker sits ABOVE the type selector in the modal, so before a type is
    // chosen there is nothing to ask. Rather than grey everything out and make
    // Training impossible to mass-create, allow the date when anything in the
    // current category could take it. If the user then picks Work, the RPC
    // returns FUTURE_DATE with the offending dates and the existing
    // "Deselect these N dates" affordance clears them in one click.
    if (dateStr > todayIso) {
      const tt = form.typeId ? timeTypes.find(t => t.id === form.typeId) : undefined;
      const ok = tt
        ? tt.allows_future
        : timeTypes.some(t => (!form.ttCategory || t.category === form.ttCategory) && t.allows_future);
      if (!ok) {
        return tt ? `${tt.name} cannot be recorded in advance`
                  : 'Cannot be recorded in advance';
      }
    }

    return dayAbsenceBlock(dateStr);
  }

  /**
   * Mig 729 — nothing is recorded in advance unless the time type opts in.
   * Attendance never can: you cannot have worked tomorrow. An absence type may
   * set allows_future so planned leave can be booked ahead.
   *
   * Returns the reason to show, or null when the date is fine.
   */
  function futureBlock(dateStr: string, typeId?: string): string | null {
    if (dateStr <= todayIso) return null;
    const tt = typeId ? timeTypes.find(t => t.id === typeId) : undefined;
    if (tt?.allows_future) return null;
    return tt
      ? `${tt.name} cannot be recorded in advance`
      : 'This day is in the future — attendance cannot be recorded in advance';
  }

  /**
   * How many types of this category the admin has opened up for advance dating.
   * Zero means the corresponding button has nothing it could offer on a future
   * day, so it is withdrawn rather than opened onto an empty picker.
   */
  const typesAllowingFuture = (cat: 'attendance' | 'absence') =>
    timeTypes.filter(t => t.category === cat && t.allows_future).length;

  // Paste is now allowed into non-empty days. Mig 746 handles collision the same
  // way save_timesheet_entry does: APPEND for same project+type with activity
  // rows, ALREADY_EXISTS / LEGACY_NEEDS_SPLIT for others, and a 16h cap check.
  // The only client-side blocks are future dates (per type) and full-day absence.
  function pasteBlockedReason(dateStr: string): string | null {
    // A future target is allowed when EVERY type on the copied day may be dated
    // forward -- mig 737, and the same rule the day panel applies per entry via
    // futureBlock. This used to refuse any future day outright, on the reasoning
    // that Copy Day "cannot know" whether the types allow it. It can: the
    // clipboard holds the entries and timeTypes carries allows_future.
    //
    // All-or-nothing, matching the RPC. Naming the offending types is what makes
    // the refusal actionable -- "cannot paste into a future day" left the
    // employee with no idea which entry was the problem.
    if (dateStr > todayIso && clipboard) {
      const blocking = Array.from(new Set(
        clipboard.entries
          .filter(e => !timeTypes.find(t => t.id === e.time_type_id)?.allows_future)
          .map(e => timeTypes.find(t => t.id === e.time_type_id)?.name ?? 'That entry')
      ));
      if (blocking.length) return `${blocking.join(', ')} cannot be recorded in advance`;
    }
    return dateBlockedReason(dateStr);
  }

  // ── Create ────────────────────────────────────────────────────────────
  function openCreate() {
    const seed = selectedDate && !dateBlockedReason(selectedDate) ? [selectedDate] : [];
    setCreateDates(new Set(seed));
    setCreateErr(null);
    // Bulk create is overwhelmingly "a normal working day", so pre-fill one.
    // ttCategory='attendance' also scopes the type picker — leave is a day-panel
    // action, matching Copy Day's refusal to carry absence.
    setForm({ ...emptyForm, hours: '8', mins: '0', ttCategory: 'attendance' });
    setFormErr('');
    setCreateOpen(true);
  }
  function toggleCreateDate(dateStr: string) {
    const next = new Set(createDates);
    if (next.has(dateStr)) next.delete(dateStr); else next.add(dateStr);
    setCreateDates(next);
    setCreateErr(null);

    // Adding a date can push the chosen project outside its validity window.
    // Clear it rather than silently create entries against an inactive project,
    // and name the date that caused it — otherwise the reset looks like a bug.
    if (form.projId) {
      const proj = projects.find(p => p.id === form.projId);
      const dates = [...next].sort();
      if (proj && !projectActiveOn(proj, dates)) {
        const culprit = dates.find(d => !projectActiveOn(proj, [d]));
        setForm(f => ({ ...f, projId: '' }));
        // Top of the modal, not the form footer: the user just clicked a date up
        // here, and the Project field below may be scrolled out of view. Amber —
        // nothing failed, the app corrected something and is saying so.
        setCreateErr({
          kind: 'notice',
          dates: [],
          msg: `Project cleared — ${proj.name} is not active on ${culprit ? fmtChip(culprit) : 'one of the selected dates'}.`,
        });
      }
    }
  }

  async function submitCreate() {
    if (!header) return;
    const dates = [...createDates].sort();
    // The modal body scrolls and the footer is pinned, so a message at the end of
    // the form can be below the fold when Create is pressed. Everything goes to the
    // top banner, which is always in view.
    const fail = (msg: string) => { setCreateErr({ msg, dates: [] }); setFormErr(''); };

    if (!dates.length) { fail('Select at least one date.'); return; }
    if (!form.typeId)  { fail('Please select a time type.'); return; }

    const tt = timeTypes.find(t => t.id === form.typeId);
    if (tt?.requires_project && !form.projId) { fail('Please select a project for this time type.'); return; }
    // Project time takes its duration from the activity rows; everything else
    // still uses the Hours/Minutes boxes.
    let totalMins: number;
    if (tt?.requires_project) {
      const bad = validateActRows(form.actRows);
      if (bad) { fail(bad); return; }
      totalMins = actTotal(form.actRows);
      if (totalMins > 960) { fail('Total hours cannot exceed 16h in a single day.'); return; }
    } else {
      const hrs = parseInt(form.hours || '0', 10);
      const mins = parseInt(form.mins || '0', 10);
      if (isNaN(hrs) || isNaN(mins) || (hrs === 0 && mins === 0)) { fail('Duration must be greater than 0.'); return; }
      totalMins = hrs * 60 + mins;
    }

    setCreating(true); setFormErr(''); setCreateErr(null);
    const actRowsPayload = tt?.requires_project ? actPayload(form.actRows) : null;
    const acts = (actRowsPayload ?? []).map(a => a.name);
    const { data, error: rpcErr } = await supabase.rpc('bulk_create_timesheet_entries', {
      p_header_id: header.id,
      p_dates: dates,
      p_entry: {
        time_type_id:  form.typeId,
        project_id:    tt?.requires_project ? form.projId : null,
        hours_minutes: totalMins,
        notes:         form.notes.trim() || null,
        // Objects carry per-activity hours and switch the RPC into itemised
        // mode; a plain string array is still accepted for anything that is not
        // project time.
        activities:    actRowsPayload && actRowsPayload.length ? actRowsPayload : null,
      },
    });
    setCreating(false);

    if (rpcErr) { fail(rpcErr.message); return; }
    if (!data?.ok) {
      // Dates come back on the scope errors so the user can drop them in one click
      if (Array.isArray(data?.dates) && data.dates.length) setCreateErr({ msg: data.message, dates: data.dates });
      else fail(data?.message ?? 'Could not create entries.');
      return;
    }

    setCreateOpen(false);
    await reloadEntries();
    noteActivitiesUsed(acts);
    // APPEND is not creation and should not be reported as it: a day that
    // already held this project had its activity rows merged in.
    const parts: string[] = [];
    if (data.created)  parts.push(`created on ${data.created} ${data.created === 1 ? 'day' : 'days'}`);
    if (data.appended) parts.push(`added to ${data.appended} existing ${data.appended === 1 ? 'entry' : 'entries'}`);
    pushToast(
      `${parts.join(' · ') || 'Saved'} — ${dates.map(fmtChip).join(', ')}`,
      'ok',
      data.entry_ids,
    );

    // MIG 738's soft line, per date. A second toast rather than a clause on the
    // first: the green one is an Undo affordance and burying an amber fact in it
    // makes the fact easy to miss and the Undo easy to hit by accident.
    const longDays: string[] = Array.isArray(data.warned_dates) ? data.warned_dates : [];
    if (longDays.length) {
      pushToast(
        longDays.length === 1
          ? `${fmtChip(longDays[0])} is now more than 4 hours beyond its schedule.`
          : `${longDays.length} days are now more than 4 hours beyond their schedule — `
            + longDays.map(fmtChip).join(', '),
        'warn',
      );
    }
  }

  // ── Copy Day ──────────────────────────────────────────────────────────
  function exitCopyMode() { setCopyMode('idle'); setClipboard(null); setCopyPickerDate(null); setCopyPickerSel(new Set()); }

  // Only attendance travels. Leave is excluded entirely: an 8h leave pasted
  // onto a 4h-planned day would be longer than the day exists.
  const attendanceOf = (dateStr: string) =>
    (entriesByDate[dateStr] ?? []).filter(e => e.entry_kind !== 'leave' && e.entry_kind !== 'holiday');

  function copyDay(dateStr: string) {
    const work = attendanceOf(dateStr);
    if (!work.length) {
      pushToast((entriesByDate[dateStr] ?? []).length
        ? 'Only attendance can be copied. That day has no attendance on it.'
        : 'Nothing to copy — that day is empty.', 'bad');
      return;
    }
    if (work.length === 1) {
      // Single entry — copy immediately, no picker needed.
      const skipped = (entriesByDate[dateStr] ?? []).length - 1;
      setClipboard({ from: dateStr, entries: work });
      setCopyMode('paste');
      pushToast(`Copied ${fmtChip(dateStr)} — 1 entry${skipped ? ' (leave not copied)' : ''}`);
    } else {
      // Multiple entries — let the user choose which ones to carry.
      setCopyPickerDate(dateStr);
      setCopyPickerSel(new Set(work.map(e => e.id)));  // start with all ticked
    }
  }

  function confirmCopyPicker() {
    if (!copyPickerDate) return;
    const work = attendanceOf(copyPickerDate);
    const selected = work.filter(e => copyPickerSel.has(e.id));
    if (!selected.length) { pushToast('Select at least one entry to copy.', 'bad'); return; }
    const skipped = (entriesByDate[copyPickerDate] ?? []).length - selected.length;
    setClipboard({ from: copyPickerDate, entries: selected });
    setCopyMode('paste');
    setCopyPickerDate(null);
    setCopyPickerSel(new Set());
    pushToast(
      `Copied ${fmtChip(copyPickerDate)} — ${selected.length} ${selected.length === 1 ? 'entry' : 'entries'}${skipped ? ' (leave/unselected not copied)' : ''}`,
    );
  }

  async function pasteInto(dateStr: string) {
    if (!header || !clipboard) return;
    const blocked = pasteBlockedReason(dateStr);
    if (blocked) { pushToast(`${blocked}.`, 'bad'); return; }

    // ONE RPC, ONE TRANSACTION, AND THE ROWS COME FROM THE DATABASE — mig 735.
    // Mig 746 extends this to non-empty targets: same collision logic as
    // save_timesheet_entry (APPEND / ALREADY_EXISTS / LEGACY_NEEDS_SPLIT)
    // and a 16h cap check before any write lands.
    //
    // p_entry_ids carries the IDs the user selected in the picker (or all of
    // them when the day had only one entry and the picker was skipped). The RPC
    // treats NULL as "copy everything", but we always send the explicit list so
    // selective copy is honoured.
    const { data, error: rpcErr } = await supabase.rpc('paste_timesheet_day', {
      p_header_id: header.id,
      p_from_date: clipboard.from,
      p_to_date:   dateStr,
      p_entry_ids: clipboard.entries.map(e => e.id),
    });
    if (rpcErr)    { pushToast(rpcErr.message, 'bad'); return; }
    if (!data?.ok) { pushToast(data?.message ?? 'Could not paste that day.', 'bad'); return; }

    await reloadEntries();

    const parts: string[] = [];
    if (data.created)  parts.push(`${data.created} new ${data.created === 1 ? 'entry' : 'entries'}`);
    if (data.appended) parts.push(`${data.appended} merged`);
    pushToast(
      `Pasted into ${fmtChip(dateStr)} — ${parts.join(', ') || 'done'}`,
      'ok',
      (data.entry_ids ?? []) as string[],
    );

    // Soft-line warning: target day is now more than 4h above its schedule.
    if (data.warning) {
      pushToast(`${fmtChip(dateStr)} is now more than 4 hours beyond its schedule.`, 'warn');
    }
  }

  // ── Keyboard: C = create, D = copy mode, Esc = exit ───────────────────
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        if (createOpen) setCreateOpen(false);
        else if (copyMode !== 'idle') exitCopyMode();
        return;
      }
      if (createOpen) return;
      const el = e.target as HTMLElement | null;
      if (el && ['INPUT', 'SELECT', 'TEXTAREA'].includes(el.tagName)) return;
      if (!editable) return;
      if (e.key === 'c' || e.key === 'C') { exitCopyMode(); openCreate(); }
      if (e.key === 'd' || e.key === 'D') { setCopyMode(m => m === 'idle' ? 'pick' : 'idle'); setClipboard(null); }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  // ── Period navigation ─────────────────────────────────────────────────
  function goToPeriod(y: number, m: number) {
    setYear(y); setMonth(m);
    // replace, not push. Holding the arrow down should not bury the page the
    // employee arrived from under a dozen history entries.
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      next.set('period', periodKey(y, m));
      return next;
    }, { replace: true });
    setSelectedDate(null); setPanelOpen(false);
    setSchedule(null); setHolidays([]);
    setAddingEntry(false); setEditingEntry(null);
    setForm(emptyForm); setFormErr('');
    setExpandedEntries(new Set());
  }
  // Not memoised: `today` is a fresh Date every render, so a useMemo keyed on it
  // would never hit. Two arithmetic ops, and Date handles the year rollover that
  // a naive month + 3 gets wrong (Nov + 3 = Feb NEXT year).
  const maxPeriod = (() => {
    const d = new Date(today.getFullYear(), today.getMonth() + FUTURE_MONTHS, 1);
    return periodKey(d.getFullYear(), d.getMonth() + 1);
  })();
  const curPeriod = periodKey(year, month);
  const canPrev   = minPeriod == null || curPeriod > minPeriod;
  const canNext   = curPeriod < maxPeriod;

  function prevMonth() {
    if (!canPrev) return;
    month === 1 ? goToPeriod(year - 1, 12) : goToPeriod(year, month - 1);
  }
  function nextMonth() {
    if (!canNext) return;
    month === 12 ? goToPeriod(year + 1, 1) : goToPeriod(year, month + 1);
  }

  // A URL can name a month the arrows cannot reach -- a bookmark from March, a
  // link shared before someone joined, an autocompleted address. Snap it into
  // range rather than showing a month that will never hold anything. Runs once
  // the floor is known; until then minPeriod is NULL and only the ceiling binds.
  useEffect(() => {
    if (curPeriod > maxPeriod) {
      const d = new Date(today.getFullYear(), today.getMonth() + FUTURE_MONTHS, 1);
      goToPeriod(d.getFullYear(), d.getMonth() + 1);
    } else if (minPeriod && curPeriod < minPeriod) {
      goToPeriod(Number(minPeriod.slice(0, 4)), Number(minPeriod.slice(5, 7)));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [curPeriod, minPeriod, maxPeriod]);

  // ── Export PDF — the month as a four-page report ──────────────────────
  /**
   * Built ON CLICK rather than held in state. Two of the labels the report
   * carries -- the holiday calendar's NAME and the manager's name -- are not
   * needed anywhere else on this page. Loading them on every calendar render to
   * serve a button most people press once a month is the wrong trade, and it
   * keeps a failure in either lookup inside the export instead of breaking the
   * calendar.
   *
   * Everything numeric below comes from state that is already on screen, so the
   * PDF cannot disagree with the page that produced it.
   */
  async function buildExportData(): Promise<TimesheetExportData> {
    if (!header) throw new Error('this month has not finished loading');

    // Started here, awaited at the bottom, so it overlaps the label lookups
    // instead of adding its own round trip to the click.
    const logoPromise = loadLogoDataUrl();

    // The three labels the page does not already hold. Each falls back to a
    // dash rather than failing the export: a report reading "Manager: --" is
    // still a correct report; no report at all is not.
    let department   = '—';
    let calendarName = '—';
    let managerName  = '—';
    try {
      const { data: empRow } = await supabase
        .from('employee_employment')
        .select('holiday_calendar_id, departments(name)')
        .eq('employee_id', employee!.id)
        .or('effective_to.is.null,effective_to.eq.9999-12-31')
        .limit(1)
        .maybeSingle();

      const dept = Array.isArray(empRow?.departments) ? empRow?.departments[0] : empRow?.departments;
      if (dept?.name) department = dept.name;

      const calId = empRow?.holiday_calendar_id ?? header.holiday_calendar_id;
      const { data: me } = await supabase
        .from('employees').select('manager_id').eq('id', employee!.id).maybeSingle();

      const [calRes, mgrRes] = await Promise.all([
        calId
          ? supabase.from('time_holiday_calendars').select('name').eq('id', calId).maybeSingle()
          : Promise.resolve({ data: null }),
        me?.manager_id
          ? supabase.from('employees').select('name').eq('id', me.manager_id).maybeSingle()
          : Promise.resolve({ data: null }),
      ]);
      if ((calRes.data as { name?: string } | null)?.name) calendarName = (calRes.data as { name: string }).name;
      if ((mgrRes.data as { name?: string } | null)?.name) managerName  = (mgrRes.data as { name: string }).name;
    } catch {
      /* labels only -- every number below is already in hand */
    }

    // ── Hand the rows to the shared assembler ───────────────────────────
    // Everything below this line used to live here and now lives in
    // ExportPDF/assemble.ts, because an approver reviewing this month has to be
    // able to produce THE SAME document from a different data source. What is
    // left here is the part that is genuinely this page's: turning the rows it
    // already loaded into the neutral shape the assembler reads.
    const rows: AssembleRow[] = entries.map(e => {
      const t    = Array.isArray(e.time_types) ? e.time_types[0] : e.time_types;
      const p    = Array.isArray(e.projects)   ? e.projects[0]   : e.projects;
      const acts = (e.timesheet_entry_activities ?? []) as TimesheetEntryActivity[];

      const activities = acts.length
        ? [...acts].sort((a, b) => a.display_order - b.display_order)
            .map(r => ({ name: r.activity_name, minutes: r.hours_minutes }))
        // A pre-727 entry has names and no split. Reported at zero minutes so
        // the name still appears in the Activities column while the totals
        // chart refuses to invent a measurement nobody took.
        : (e.activities ?? []).filter(Boolean).map(n => ({ name: n, minutes: 0 }));

      return {
        date:       e.entry_date,
        kind:       e.entry_kind === 'leave' ? 'leave' : e.entry_kind === 'holiday' ? 'holiday' : 'work',
        typeName:   t?.name ?? (e.entry_kind === 'holiday' ? 'Holiday' : '—'),
        project:    p?.name ?? null,
        minutes:    entryMinutes(e.hours_minutes, acts.map(r => ({ minutes: r.hours_minutes }))),
        rawMinutes: e.hours_minutes,
        notes:      e.notes,
        activities,
        changeMark: changeMarkFor(e, header.status === 'approved' ? header.approved_at : null),
      };
    });

    return assembleExportData({
      year, month, totalDays,
      plannedForDate: plannedFor,
      plannedForDow:  dow => (schedule ? plannedForDay(dow, schedule) : 0),
      hasSchedule:    !!schedule,
      holidayByDate,
      rows,
      header: {
        id:               header.id,
        status:           header.status,
        plannedMinutes:   header.planned_minutes,
        recordedMinutes:  entries.reduce((s2, e) => s2 + e.hours_minutes, 0),
        submittedAt:      header.submitted_at,
        approvedAt:       header.approved_at,
        contentChangedAt: header.content_changed_at,
        referenceId:      header.external_code,
      },
      labels: {
        // The SUBJECT's name, not the viewer's. This is the line that would have
        // put "Vijey Ananth" on the cover of a PDF of Harikrishnan's month —
        // a document someone signs, with the wrong person on it.
        employeeName:    subjectName || employee?.name || '—',
        employeeCode:    empCode || '—',
        department,
        holidayCalendar: calendarName,
        manager:         managerName,
        workSchedule:    schedule ? `${schedule.name} (${schedule.code})` : '—',
      },
      logoDataUrl: await logoPromise,
      generatedAt: new Date().toISOString(),
    });
  }

  // ── Derived: entries indexed by date ─────────────────────────────────
  const entriesByDate = useMemo(() =>
    entries.reduce<Record<string, TimesheetEntry[]>>((acc, e) => {
      (acc[e.entry_date] ??= []).push(e);
      return acc;
    }, {}),
  [entries]);

  const holidayByDate = useMemo(() =>
    holidays.reduce<Record<string, string>>((acc, h) => {
      acc[h.holiday_date] = h.holiday_name; return acc;
    }, {}),
  [holidays]);

  const totalDays  = daysInMonth(year, month);
  const startDow   = firstDow(year, month);
  const todayIso   = isoDate(today.getFullYear(), today.getMonth() + 1, today.getDate());
  const status     = header?.status ?? 'to_be_submitted';
  const statusM    = STATUS_META[status];

  // ── What makes a month editable (mig 730) ────────────────────────────
  // It used to be `status === 'to_be_submitted'`, which meant submitting was a
  // one-way door: the sheet went to Pending Approval, nothing existed to
  // approve it, and the employee was locked out of their own month for ever.
  //
  // Now two independent things decide it:
  //   * PENDING — somebody has been asked to look at it. Withdraw first.
  //   * THE EDIT WINDOW — how many whole months back the employee may still
  //     change, from time_edit_config. This is the thing that closes a month,
  //     and it closes an APPROVED month too, which is the point: with no
  //     workflow configured, approved is the normal resting state, so if
  //     approved meant read-only nobody could ever correct anything.
  const monthStart   = isoDate(year, month, 1);
  const monthClosed  = editFloor != null && monthStart < editFloor;
  const pending      = status === 'to_be_approved';
  // mayEdit is user_can('timesheet','edit', subject) — see the top of this
  // component. For your own sheet it is the ESS grant and nothing changes; for
  // someone else's it is whatever the administrator configured, read fresh on
  // every load.
  const editable     = !pending && !monthClosed && mayEdit;

  // ── Is there anything to resubmit? (mig 731) ─────────────────────────
  // Only asked of an APPROVED month. A month that has never been filed always
  // has something to submit; a month waiting on an approver has no button at
  // all. But an approved month with nothing touched since would otherwise offer
  // Resubmit anyway, and taking it would stamp a fresh approval — and later
  // start a fresh workflow instance — over a sheet nobody had changed.
  //
  // content_changed_at is maintained by a trigger on entries AND on activity
  // lines, because a delete leaves no row behind to inspect and an activity
  // reshuffle can change the day without moving the day's total.
  // Parsed, not string-compared. PostgREST serialises timestamptz as
  // "…+00:00" while a client-side new Date().toISOString() ends in "Z", and the
  // two sort against each other by character: within the same second,
  // "…123456+00:00" reads as EARLIER than "…123Z" because '4' < 'Z'. Fine most
  // of the time and wrong exactly when the edit follows the approval closely,
  // which is the case this whole feature is about.
  const ts = (v: string | null | undefined) => (v ? Date.parse(v) : NaN);
  const changedSinceApproval =
    status !== 'approved'                ? true   // nothing to compare against
    : header?.approved_at == null        ? true   // approved with no stamp: fail open
    : header?.content_changed_at == null ? false
    : !(ts(header.content_changed_at) <= ts(header.approved_at));  // NaN-safe: unknown means show it

  const submitBlocked =
    entries.length === 0 ? 'Nothing is recorded on this timesheet yet.'
    : !changedSinceApproval ? 'Nothing has changed since this timesheet was approved.'
    : '';

  // Why it is locked, in the employee's words, for the panel notice.
  // Three locks now, and they have three different answers. Permission goes
  // first: when you may only read, the month's status and the edit window are
  // beside the point — telling somebody to "withdraw it to make changes" when
  // they could not change it either way is worse than saying nothing.
  const lockReason = !mayEdit
    ? 'You have view-only access to this timesheet.'
    : pending
      ? 'Waiting for approval — withdraw it to make changes.'
      : monthClosed
        ? `This month is closed for editing. The earliest month you can still change is ${
            editFloor ? `${MONTH_NAMES[Number(editFloor.slice(5, 7)) - 1]} ${editFloor.slice(0, 4)}` : '—'}.`
        : '';

  const dayEntries = selectedDate ? (entriesByDate[selectedDate] ?? []) : [];

  // Calendar cells
  const cells: (number | null)[] = [
    ...Array(startDow).fill(null),
    ...Array.from({ length: totalDays }, (_, i) => i + 1),
  ];
  while (cells.length % 7 !== 0) cells.push(null);

  // ── Entry form helpers ───────────────────────────────────────────────
  function openAdd(overrides?: Partial<typeof emptyForm>) {
    setEditingEntry(null);
    setForm({ ...emptyForm, ...overrides });
    setBaselineForm(null);   // adding: there is nothing to be unchanged from
    setFormErr('');
    setAddingEntry(true);
  }
  function openAddAttendance() { openAdd({ kind: 'time_type', ttCategory: 'attendance' }); }
  function openAddAbsence()    { openAdd({ kind: 'time_type', ttCategory: 'absence' }); }

  function openEdit(ent: TimesheetEntry) {
    setEditingEntry(ent);
    const totalM = ent.hours_minutes;
    const tt = timeTypes.find(t => t.id === ent.time_type_id);
    const opened = {
      kind:       'time_type' as const,
      typeId:     ent.time_type_id ?? '',
      projId:     ent.project_id  ?? '',
      hours:      String(Math.floor(totalM / 60)),
      mins:       String(totalM % 60),
      notes:      ent.notes ?? '',
      actRows:    entryToActRows(ent),
      ttCategory: (tt?.category === 'absence' ? 'absence' : 'attendance') as '' | 'attendance' | 'absence',
    };
    setForm(opened);
    // Keep what the form looked like on open, so Update can tell whether
    // anything was actually typed. Not derived from `editingEntry` at compare
    // time: entryToActRows() does real work (a pre-727 entry has names with no
    // hours) and re-running it to compare would be comparing the form against a
    // second interpretation of the entry rather than against itself.
    setBaselineForm(opened);
    setFormErr('');
    setAddingEntry(true);
  }

  function cancelForm() {
    setAddingEntry(false);
    setEditingEntry(null);
    setForm(emptyForm);
    setBaselineForm(null);
    setFormErr('');
  }

  /**
   * Has anything in the edit form actually moved?
   *
   * WHY THIS EXISTS
   *   save_timesheet_entry() rewrites an entry's activity rows by deleting them
   *   all and re-inserting, unconditionally. With mig 731 watching that table,
   *   opening an entry and pressing Update without typing anything stamped the
   *   timesheet as changed and lit up Resubmit — a change that never happened.
   *   The honest place to catch that is here, where both sides are already in
   *   hand, rather than diffing old against new inside a 250-line RPC.
   *
   *   It also saves a pointless round trip, which is the smaller half.
   *
   * Hours and minutes are compared as NUMBERS. The baseline is generated as
   * "3" and "0"; a person who selects the field and retypes "03" has changed
   * nothing, and a string compare would disagree.
   */
  const numEq = (a: string, b: string) =>
    (parseInt(a || '0', 10) || 0) === (parseInt(b || '0', 10) || 0);

  function formUnchanged(a: typeof emptyForm, b: typeof emptyForm): boolean {
    if (a.typeId !== b.typeId || a.projId !== b.projId) return false;
    if (!numEq(a.hours, b.hours) || !numEq(a.mins, b.mins)) return false;
    if ((a.notes ?? '').trim() !== (b.notes ?? '').trim()) return false;
    if (a.actRows.length !== b.actRows.length) return false;
    // Order matters: display_order is stored, so dragging two activities into a
    // different sequence IS a change even though the set is identical.
    return a.actRows.every((r, i) => {
      const s = b.actRows[i];
      return r.name.trim() === s.name.trim() && numEq(r.h, s.h) && numEq(r.m, s.m);
    });
  }

  const editUnchanged = !!editingEntry && !!baselineForm && formUnchanged(form, baselineForm);
  const saveBlocked   = editUnchanged ? 'Nothing has changed in this entry yet.' : '';

  async function handleSaveEntry() {
    if (!header || !selectedDate) return;

    if (!form.typeId) { setFormErr('Please select a time type.'); return; }

    const selectedTimeType = timeTypes.find(t => t.id === form.typeId);
    const needsProject = !!selectedTimeType?.requires_project;
    // Map absence → 'leave', else 'time_type' (project entries stay 'time_type'
    // with project_id set — never write entry_kind='project').
    const entryKind: TimesheetEntry['entry_kind'] =
      selectedTimeType?.category === 'absence' ? 'leave' : 'time_type';

    if (needsProject && !form.projId) { setFormErr('Please select a project for this time type.'); return; }

    // Mig 729 (h). Checked here so the message names the type, not just the date.
    if (!editingEntry) {
      const fut = futureBlock(selectedDate, form.typeId);
      if (fut) { setFormErr(`${fut}.`); return; }
    }

    // Project time is itemised: its duration is the sum of the activity rows.
    let totalMins: number;
    if (needsProject) {
      const bad = validateActRows(form.actRows);
      if (bad) { setFormErr(bad); return; }
      totalMins = actTotal(form.actRows);
    } else {
      const hrs  = parseInt(form.hours || '0', 10);
      const mins = parseInt(form.mins  || '0', 10);
      if (isNaN(hrs) || isNaN(mins) || (hrs === 0 && mins === 0)) {
        setFormErr('Duration must be greater than 0.'); return;
      }
      if (mins < 0 || mins > 59) { setFormErr('Minutes must be 0–59.'); return; }
      if (hrs < 0 || hrs > 23)   { setFormErr('Hours must be 0–23.'); return; }
      totalMins = hrs * 60 + mins;
    }

    // Day occupancy — the client half of mig 726 rules (f) and (g). Checked here
    // so the message names the day and the fix. Both are INSERT-only in the
    // database, so both are skipped when editing.
    if (!editingEntry) {
      if (entryKind === 'leave') {
        const planned = plannedFor(selectedDate);
        if (planned > 0 && totalMins >= planned && hasAttendance(selectedDate)) {
          setFormErr('Attendance is already recorded on this day, so an absence covering the whole day cannot be added. Reduce the hours, or remove the attendance first.');
          return;
        }
      } else {
        const block = dayAbsenceBlock(selectedDate);
        if (block) { setFormErr(`${block} — attendance cannot be added.`); return; }
      }
    }

    setSaving(true);
    setFormErr('');

    // ONE RPC, ONE TRANSACTION — mig 727. supabase-js sends every table call as
    // its own HTTP request, so writing the parent and then its activity rows
    // would be two transactions: a failure between them leaves an entry whose
    // rows do not add up to its own hours. save_timesheet_entry also checks the
    // header status, which no direct table write ever did.
    const cleanActivities = needsProject ? actPayload(form.actRows).map(a => a.name) : null;
    const { data: saveRes, error: saveErr } = await supabase.rpc('save_timesheet_entry', {
      p_header_id: header.id,
      p_entry_id:  editingEntry?.id ?? null,
      p_entry: {
        entry_date:    selectedDate,
        time_type_id:  form.typeId,
        project_id:    needsProject ? form.projId : null,
        notes:         form.notes.trim() || null,
        hours_minutes: needsProject ? null : totalMins,
      },
      p_activities: needsProject ? actPayload(form.actRows) : null,
    });

    if (saveErr)      { setFormErr(saveErr.message); setSaving(false); return; }
    if (!saveRes?.ok) { setFormErr(saveRes?.message ?? 'Could not save this entry.'); setSaving(false); return; }

    // Same treatment as the Create modal — one helper, one behaviour.
    if (cleanActivities) noteActivitiesUsed(cleanActivities);

    // This used to be a private copy of reloadEntries' query, inlined here
    // because it needed the list back. It drifted the moment reloadEntries
    // learned to re-read content_changed_at: saving an entry on an approved
    // month wrote the hours, moved the total, and left Resubmit greyed out
    // saying "No changes since approval" over a change that had just happened.
    const newEntries = await reloadEntries();
    await syncRecordedMinutes(header.id, newEntries);

    // An append is not a create and must not pass for one. Mig 733 folds a
    // second (day, type, project) into the entry already there -- summing an
    // activity the entry already had -- so without a word the panel would just
    // refresh and the employee would be left wondering where their hour went.
    // The Create modal has reported its appends separately since mig 728; this
    // is the same courtesy on the other button.
    if (saveRes.appended) {
      pushToast(
        `Added to ${saveRes.label ?? 'the existing entry'} on ${fmtChip(selectedDate)}`
        + ` \u2014 now ${fmtMins(saveRes.hours_minutes ?? 0)}`,
        'ok',
        saveRes.entry_id ? [saveRes.entry_id] : undefined,
      );
    }

    // MIG 738's soft line: the day is now more than 4h beyond its schedule.
    // The save stood — this is the moment to say so, rather than leaving it to
    // be discovered in a report by someone else. The hard 16h cap never gets
    // here; it comes back as DAILY_CAP above and the form shows the message.
    if (saveRes.warning) pushToast(saveRes.warning as string, 'warn');

    setSaving(false);
    cancelForm();
  }

  async function handleDeleteEntry(entryId: string) {
    if (!header) return;
    const { error: delErr } = await supabase.from('timesheet_entries').delete().eq('id', entryId);
    if (delErr) { setError(delErr.message); return; }

    // Filtering the list locally would save a round trip and is how this used to
    // work — but the header's change stamp only exists server-side, so a delete
    // that never re-read it left the sheet looking untouched. One path.
    const newEntries = await reloadEntries();
    await syncRecordedMinutes(header.id, newEntries);
    if (editingEntry?.id === entryId) cancelForm();
  }

  // ── Activity favourite toggle ────────────────────────────────────────
  async function handleFavoriteToggle(name: string, _currentIsFav: boolean): Promise<{ ok: boolean; message?: string }> {
    if (!subjectId) return { ok: false, message: 'Not logged in.' };
    // The subject's list, not the viewer's — the panel above it is theirs.
    const { data } = await supabase.rpc('toggle_activity_favorite', {
      p_employee_id:   subjectId,
      p_activity_name: name,
    });
    if (data?.ok) {
      setActivityHistory(prev => prev.map(h =>
        h.activity_name === name ? { ...h, is_favorite: data.is_favorite } : h
      ));
    }
    return { ok: data?.ok ?? false, message: data?.message };
  }

  // ── Entry expand/collapse ────────────────────────────────────────────
  function toggleEntryExpand(id: string) {
    setExpandedEntries(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }

  function toggleAllEntries(ents: TimesheetEntry[]) {
    const anyOpen = ents.some(e => expandedEntries.has(e.id));
    setExpandedEntries(anyOpen ? new Set() : new Set(ents.map(e => e.id)));
  }

  // ── Submit / withdraw ────────────────────────────────────────────────
  //
  // This was a bare column UPDATE that set status to 'to_be_approved' and did
  // nothing else — no workflow instance, no approver, no queue, no screen. The
  // sheet said "Pending Approval" and was pending nowhere.
  //
  // submit_timesheet() (mig 730) asks whether a workflow is actually assigned
  // to timesheet_headers. If none is, there is nobody to approve it, so it goes
  // straight to 'approved' — which is honest, where waiting for ever was not.
  // If one is, it goes to 'to_be_approved' and can be withdrawn.
  async function handleSubmit() {
    if (!header) return;
    setSubmitting(true);
    const { data, error: rpcErr } = await supabase.rpc('submit_timesheet', { p_header_id: header.id });
    setSubmitting(false);

    if (rpcErr) { setError(rpcErr.message); return; }
    if (!data?.ok) {
      // ALREADY_PENDING / EMPTY / NOT_YOURS / NOT_FOUND all carry a sentence
      // meant for the person reading it, so show that rather than the code.
      setConfirmSubmit(false);
      pushToast(data?.message ?? 'Could not submit this timesheet.', 'bad');
      // Somebody else may have moved it; re-read rather than guess.
      await refreshHeaderStatus();
      return;
    }

    setConfirmSubmit(false);
    const next = data.status as 'approved' | 'to_be_approved';
    // Optimistic status so the chip flips immediately, then the real timestamps.
    // The browser's clock must not set approved_at: content_changed_at comes
    // from the database, and comparing one machine's clock against another's is
    // how "nothing has changed" survives a change made seconds later.
    setHeader(h => h ? { ...h, status: next } : h);
    await refreshHeaderStatus();
    pushToast(
      next === 'approved'
        ? 'Timesheet submitted and approved — no approval workflow is configured.'
        : 'Timesheet submitted for approval.',
    );
  }

  async function handleWithdraw() {
    if (!header) return;
    setWithdrawing(true);
    const { data, error: rpcErr } = await supabase.rpc('withdraw_timesheet', { p_header_id: header.id });
    setWithdrawing(false);

    if (rpcErr) { setError(rpcErr.message); return; }
    setConfirmWithdraw(false);
    if (!data?.ok) {
      pushToast(data?.message ?? 'Could not withdraw this timesheet.', 'bad');
      await refreshHeaderStatus();
      return;
    }
    setHeader(h => h ? { ...h, status: 'to_be_submitted', submitted_at: null, approved_at: null } : h);
    pushToast('Withdrawn. You can edit and submit it again.');
  }

  /** Re-read just the three fields that submit/withdraw move, after a refusal.
   *  Cheaper and less disruptive than a full reload, and it stops the screen
   *  arguing with the database about what state the sheet is in. */
  async function refreshHeaderStatus() {
    if (!header) return;
    const { data } = await supabase
      .from('timesheet_headers')
      .select('status, submitted_at, approved_at, content_changed_at')
      .eq('id', header.id)
      .single();
    if (!data) return;
    setHeader(h => h ? { ...h, ...(data as Partial<TimesheetHeader>) } : h);
  }

  // ─────────────────────────────────────────────────────────────────────
  // Render
  // ─────────────────────────────────────────────────────────────────────

  // A project may be chosen only if BOTH windows cover every date given: the
  // project's own validity window, and — since mig 787 — the person's
  // membership stints. One date (day panel) and many dates (Create modal) use
  // the same rule.
  //
  // Until 787 the two were enforced at different resolutions: the project window
  // per day here, the membership window per MONTH in the RPC. A stint ending on
  // the 10th still offered the project for the whole month, and an entry on the
  // 25th went through. member_spells closes that.
  //
  // Two deliberate exemptions, both of which would otherwise break editing
  // rather than tighten anything:
  //   no spells -> the project was reached via the RPC's `booked` arm or the
  //                all-projects fallback, so there is no membership window to
  //                apply and nothing to check against.
  //
  // There used to be a second exemption here — `if (p.has_entries) return true`
  // — which skipped the membership check for the whole month as soon as the
  // person had booked to the project even once. It was a blunt way to guarantee
  // one thing: an entry that already exists must be able to name its own
  // project, or editing it finds the project gone from the select. Two later
  // changes made it both redundant and far too broad:
  //
  //   alreadyBookedOn() below does that job PER DATE, which is the actual
  //   requirement, and mig 788's guards stop a date change stranding entries in
  //   the first place — so the case it insured against can now only come from
  //   data that predates 788, which the per-date exemption still covers.
  //
  // With it gone, an allocation ending on the 15th actually ends on the 15th.
  function memberOn(p: Project, d: string) {
    const spells = p.member_spells;
    if (!spells || spells.length === 0) return true;
    return spells.some(s => s.from <= d && (!s.to || s.to >= d));
  }

  // An entry that ALREADY EXISTS on this date against this project must always
  // be able to name it, whatever the windows now say. Mig 788 stops new
  // stranding, but rows stranded before it exist and must stay editable --
  // otherwise the fix for bad data is unreachable from the screen that has it.
  function alreadyBookedOn(p: Project, d: string) {
    return entries.some(e => e.project_id === p.id && e.entry_date === d);
  }

  function projectActiveOn(p: Project, dates: string[]) {
    return dates.every(d =>
      alreadyBookedOn(p, d) || (
        (!p.start_date || p.start_date <= d) &&
        (!p.end_date   || p.end_date   >= d) &&
        memberOn(p, d)));
  }

  // ── Entry form fields ─────────────────────────────────────────────────
  // ONE definition, rendered in three places: the inline edit form inside an
  // entry card, the Add Entry form at the panel bottom, and the Create modal.
  // Callers own their own wrapper and action buttons — only the fields live here.
  //   projectDates — only offer projects active on EVERY one of these dates.
  //                  The day panel passes one; the Create modal passes all the
  //                  dates picked, so the list is the intersection. Empty = no filter.
  //   showErr      — the day panel shows formErr under the fields, right where
  //                  the fix is. The Create modal must not: its body scrolls and
  //                  a message at the end can sit below the fold, so every
  //                  failure there goes to the pinned banner above the body.
  function renderEntryFields(opts?: { projectDates?: string[]; gap?: number; showErr?: boolean }) {
    const gap          = opts?.gap ?? 8;
    const showErr      = opts?.showErr ?? true;
    const projectDates = opts?.projectDates ?? [];
    const selTT        = timeTypes.find(t => t.id === form.typeId);

    return (
      <>
        {/* Time type picker — filtered by attendance/absence when a category is set */}
        <div style={{ marginBottom: gap }}>
          <Label>{form.ttCategory === 'absence' ? 'Leave / Absence Type' : 'Attendance Type'}</Label>
          <select
            value={form.typeId}
            onChange={e => { setForm(f => ({ ...f, typeId: e.target.value, projId: '' })); setFormErr(''); }}
            style={selectSt}
          >
            <option value="">— Select —</option>
            {timeTypes
              .filter(t => !form.ttCategory || t.category === form.ttCategory)
              // Mig 726 rule (f): on a day that already has attendance, a
              // full-day-ONLY absence type can never be legal — rule (c) locks
              // it to the whole planned day and (f) then rejects it. Do not
              // offer a choice that must fail. Half-day-capable types stay,
              // because a part-day absence alongside work is legitimate.
              .filter(t => !(t.category === 'absence' && !t.allows_half_day
                             && !editingEntry && !!selectedDate && hasAttendance(selectedDate)))
              // Mig 729: on a future day only types that opt in are selectable.
              .filter(t => !(!editingEntry && !!selectedDate && selectedDate > todayIso
                             && !t.allows_future))
              .map(t => <option key={t.id} value={t.id}>{t.name} ({t.code})</option>)}
          </select>
        </div>

        {/* Project picker — only when the selected time type requires one */}
        {form.typeId && selTT?.requires_project && (
          <div style={{ marginBottom: gap }}>
            <Label>Project</Label>
            <select
              value={form.projId}
              onChange={e => { setForm(f => ({ ...f, projId: e.target.value })); setFormErr(''); }}
              style={selectSt}
            >
              <option value="">— Select —</option>
              {projects
                .filter(p => projectActiveOn(p, projectDates))
                .map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </div>
        )}

        {/* Activities with their own hours — mig 727. For project time these rows
            ARE the duration, which is why the Hours/Minutes pair below is gone
            rather than left read-only: a field you cannot change is still a
            field people try to change. */}
        {selTT?.requires_project && (() => {
          const total   = actTotal(form.actRows);
          const setRows = (fn: (rows: ActRow[]) => ActRow[]) =>
            setForm(f => ({ ...f, actRows: fn(f.actRows) }));
          const numSt   = { ...inputSt, width: 54, textAlign: 'center' as const, flex: '0 0 auto' };
          return (
            <div style={{ marginBottom: gap }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
                <Label>Activities &amp; hours *</Label>
                <button
                  type="button"
                  onClick={() => { setRows(rows => [...rows, { name: '', h: '', m: '' }]); setFormErr(''); }}
                  style={{ background: 'none', border: 'none', color: '#2563EB', fontSize: 11, fontWeight: 700, cursor: 'pointer', padding: '0 2px' }}
                >
                  + Add
                </button>
              </div>

              {form.actRows.map((row, idx) => (
                <div key={idx} style={{ display: 'flex', gap: 5, marginBottom: 5, alignItems: 'flex-start' }}>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <ActivityAutocomplete
                      value={row.name}
                      onChange={val => { setRows(rows => rows.map((r, i) => i === idx ? { ...r, name: val } : r)); setFormErr(''); }}
                      onFavoriteToggle={handleFavoriteToggle}
                      history={activityHistory}
                      inputStyle={inputSt}
                    />
                  </div>
                  <input
                    type="number" min="0" max="23" placeholder="h" aria-label="Hours"
                    value={row.h}
                    onChange={e => { const v = e.target.value; setRows(rows => rows.map((r, i) => i === idx ? { ...r, h: v } : r)); setFormErr(''); }}
                    style={numSt}
                  />
                  <input
                    type="number" min="0" max="59" placeholder="m" aria-label="Minutes"
                    value={row.m}
                    onChange={e => { const v = e.target.value; setRows(rows => rows.map((r, i) => i === idx ? { ...r, m: v } : r)); setFormErr(''); }}
                    style={numSt}
                  />
                  {form.actRows.length > 1 && (
                    <button
                      type="button"
                      aria-label={`Remove ${row.name.trim() || 'this activity'}`}
                      onClick={() => { setRows(rows => rows.filter((_, i) => i !== idx)); setFormErr(''); }}
                      style={{ background: 'none', border: '1px solid #FEE2E2', borderRadius: 5, color: '#DC2626', cursor: 'pointer', padding: '0 7px', fontSize: 13, alignSelf: 'stretch' }}
                    >
                      ×
                    </button>
                  )}
                </div>
              ))}

              {/* The running total IS the entry's duration. It belongs here,
                  beside the numbers that produce it. */}
              <div style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'baseline',
                marginTop: 6, paddingTop: 6, borderTop: '1px dashed #E5E7EB',
              }}>
                <span style={{ fontSize: 11, color: '#6B7280', fontWeight: 600 }}>Total for the day</span>
                <span style={{ fontSize: 13, fontWeight: 700, fontVariantNumeric: 'tabular-nums',
                               color: total > 960 ? '#DC2626' : total > 720 ? '#D97706' : total > 0 ? '#111827' : '#9CA3AF' }}>
                  {fmtMins(total)}{total > 960 ? ' · exceeds 16h cap' : ''}
                </span>
              </div>
            </div>
          );
        })()}

        {/* Duration — only for entries that are not itemised. */}
        {!selTT?.requires_project && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: gap }}>
          <div>
            <Label>Hours</Label>
            <input
              type="number" min="0" max="23" placeholder="0"
              value={form.hours}
              onChange={e => { setForm(f => ({ ...f, hours: e.target.value })); setFormErr(''); }}
              style={inputSt}
            />
          </div>
          <div>
            <Label>Minutes</Label>
            <input
              type="number" min="0" max="59" placeholder="0"
              value={form.mins}
              onChange={e => { setForm(f => ({ ...f, mins: e.target.value })); setFormErr(''); }}
              style={inputSt}
            />
          </div>
        </div>
        )}

        {/* Notes */}
        <div style={{ marginBottom: 10 }}>
          <Label>Notes (optional)</Label>
          <textarea
            rows={2} placeholder="Optional…"
            value={form.notes}
            onChange={e => setForm(f => ({ ...f, notes: e.target.value }))}
            style={{ ...inputSt, resize: 'vertical', fontFamily: 'inherit' }}
          />
        </div>

        {showErr && formErr && (
          <div style={{ fontSize: 12, color: '#DC2626', marginBottom: 8, display: 'flex', gap: 5, alignItems: 'center' }}>
            <i className="fa-solid fa-circle-exclamation" /> {formErr}
          </div>
        )}
      </>
    );
  }


  // ── Refused, and said so ───────────────────────────────────────────────
  // RLS would return nothing and the page would render an empty month, which
  // reads as "this person recorded no time" — the opposite of the truth. Only
  // shown once the answer is IN: `access === null` still means "asking".
  if (!isSelf && access && !mayView) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
                    height: '100vh', background: '#F9FAFB', gap: 12, padding: 24, textAlign: 'center' }}>
        <i className="fa-regular fa-eye-slash" style={{ fontSize: 28, color: '#9CA3AF' }} />
        <div style={{ fontSize: 16, fontWeight: 700, color: '#111827' }}>
          You do not have access to this timesheet
        </div>
        <div style={{ fontSize: 13, color: '#6B7280', maxWidth: 420 }}>
          Your permissions cover a different set of employees. An administrator can
          change that in Security → Permission Matrix.
        </div>
        <a href="/my-timesheet" style={{ marginTop: 4, color: '#1D4ED8', fontWeight: 600, fontSize: 13 }}>
          ← Return to your timesheet
        </a>
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100vh', overflow: 'hidden', background: '#F9FAFB' }}>

      {/* ── Page header ─────────────────────────────────────────────────── */}
      <div style={{ background: '#fff', borderBottom: '1px solid #E5E7EB', padding: '12px 24px', flexShrink: 0 }}>

        {/* Breadcrumb */}
        <div style={{ fontSize: 11, color: '#9CA3AF', marginBottom: 6, letterSpacing: '0.02em' }}>
          My Profile &nbsp;/&nbsp; Time Sheet
        </div>

        {/* Whose sheet this is. Same shape as the profile page's viewing
            banner, so the two read as one product. Only ever shown when you
            are looking at somebody else — your own timesheet says nothing,
            because it has nothing to say. */}
        {!isSelf && (
          <div style={{
            display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap',
            background: '#EFF6FF', border: '1px solid #BFDBFE', borderRadius: 9,
            padding: '10px 14px', marginBottom: 14, fontSize: 13,
          }}>
            <i className="fa-regular fa-eye" style={{ color: '#2563EB' }} />
            <span style={{ color: '#1E3A8A' }}>
              Viewing&nbsp;&nbsp;<b>{empCode}</b>
              {subjectName ? <> &nbsp;·&nbsp; <b>{subjectName}</b></> : null}
            </span>
            {!mayEdit && (
              <span style={{
                fontSize: 11, fontWeight: 700, letterSpacing: 0.3,
                background: '#E5E7EB', color: '#374151',
                borderRadius: 5, padding: '2px 8px',
              }}>
                READ ONLY
              </span>
            )}
          </div>
        )}

        {/* Period nav + title row */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          <button onClick={prevMonth} disabled={!canPrev} style={{ ...navBtnSt, opacity: canPrev ? 1 : 0.35, cursor: canPrev ? 'pointer' : 'not-allowed' }}
                  title={canPrev ? 'Previous month' : 'This is the first month of your employment'}>
            <i className="fa-solid fa-chevron-left" style={{ fontSize: 10 }} />
          </button>
          <h1 style={{ fontSize: 16, fontWeight: 700, color: '#111827', margin: 0, whiteSpace: 'nowrap' }}>
            Time Sheet for {MONTH_NAMES[month - 1]} 1 – {totalDays}, {year}
          </h1>
          <button onClick={nextMonth} disabled={!canNext} style={{ ...navBtnSt, opacity: canNext ? 1 : 0.35, cursor: canNext ? 'pointer' : 'not-allowed' }}
                  title={canNext ? 'Next month' : `Timesheets open ${FUTURE_MONTHS} months ahead`}>
            <i className="fa-solid fa-chevron-right" style={{ fontSize: 10 }} />
          </button>

          <span style={{ padding: '3px 12px', borderRadius: 99, fontSize: 12, fontWeight: 600, background: statusM.bg, color: statusM.color }}>
            {statusM.label}
          </span>

          {/* A greyed-out Resubmit with no visible reason reads as broken. The
              chip says the month is approved; this says why there is nothing
              to do about it. */}
          {status === 'approved' && !changedSinceApproval && entries.length > 0 && (
            <span style={{ fontSize: 12, color: '#9CA3AF' }}>
              No changes since approval
            </span>
          )}

          {(editable || accessLoading) && (
            <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8 }}>
              <button
                onClick={() => { if (!accessLoading) { exitCopyMode(); openCreate(); } }}
                disabled={accessLoading}
                style={{
                  padding: '7px 14px', borderRadius: 7, border: '1px solid #D0D5DD',
                  background: accessLoading ? '#F3F4F6' : '#fff',
                  color: accessLoading ? '#D1D5DB' : '#1F2937',
                  fontWeight: 600, fontSize: 13,
                  cursor: accessLoading ? 'default' : 'pointer',
                  display: 'flex', alignItems: 'center', gap: 6,
                  transition: 'background 0.15s, color 0.15s',
                }}
                title={accessLoading ? '' : 'Create attendance on one or more days (C)'}
              >
                <i className="fa-solid fa-plus" style={{ fontSize: 11 }} /> Create
              </button>
              <button
                onClick={() => { setCopyMode(m => m === 'idle' ? 'pick' : 'idle'); setClipboard(null); }}
                style={{
                  padding: '7px 14px', borderRadius: 7,
                  border: `1px solid ${copyMode === 'idle' ? '#D0D5DD' : copyMode === 'pick' ? '#2563EB' : '#6EE7B7'}`,
                  background: copyMode === 'idle' ? '#fff' : copyMode === 'pick' ? '#EFF6FF' : '#ECFDF5',
                  color:      copyMode === 'idle' ? '#1F2937' : copyMode === 'pick' ? '#1D4ED8' : '#047857',
                  fontWeight: 600, fontSize: 13, cursor: 'pointer',
                  display: 'flex', alignItems: 'center', gap: 6,
                }}
                title="Copy a day's attendance and paste it into empty days (D)"
              >
                <i className="fa-regular fa-clipboard" style={{ fontSize: 11 }} />
                {copyMode === 'idle' ? 'Copy Day' : copyMode === 'pick' ? 'Select a day…' : 'Pasting…'}
              </button>
            </div>
          )}

          <div style={{ marginLeft: editable ? 0 : 'auto' }}>
            <ExportPDFButton
              getData={buildExportData}
              onToast={(msg, kind) => pushToast(msg, kind)}
              disabled={!header || loading}
            />
          </div>

          {/* Submit stays available on an APPROVED month while its window is
              open, because editing an approved month is now allowed and a
              corrected month has to be re-filed. With no workflow it simply
              re-approves; with one it goes back into the queue. */}
          {/* The title sits on the wrapper, not the button: browsers suppress
              pointer events on a disabled control, so a tooltip attached to it
              never appears — which would leave a greyed-out button with no
              explanation at all. */}
          {editable && (
            <span title={submitBlocked || undefined} style={{ display: 'inline-flex' }}>
            <button
              onClick={() => setConfirmSubmit(true)}
              disabled={!!submitBlocked}
              style={{
                padding: '7px 18px', borderRadius: 7, border: 'none',
                background: submitBlocked ? '#E5E7EB' : '#1D4ED8',
                color:      submitBlocked ? '#9CA3AF' : '#fff',
                fontWeight: 600, fontSize: 13, cursor: submitBlocked ? 'not-allowed' : 'pointer',
                display: 'flex', alignItems: 'center', gap: 6,
              }}
              title={submitBlocked || undefined}
            >
              <i className="fa-solid fa-paper-plane" />
              {status === 'approved' ? 'Resubmit' : 'Submit for Approval'}
            </button>
            </span>
          )}

          {/* The way out of Pending Approval. Without it, submitting is still a
              one-way door — which is the bug this whole change exists to fix. */}
          {pending && mayEdit && (
            <button
              onClick={() => setConfirmWithdraw(true)}
              style={{
                padding: '7px 18px', borderRadius: 7, border: '1px solid #D0D5DD',
                background: '#fff', color: '#1F2937', fontWeight: 600, fontSize: 13,
                cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6,
              }}
              title="Take this timesheet back so you can change it"
            >
              <i className="fa-solid fa-rotate-left" style={{ fontSize: 11 }} /> Withdraw
            </button>
          )}
        </div>

        {/* Stats row */}
        <div style={{ display: 'flex', gap: 28, marginTop: 10, flexWrap: 'wrap' }}>
          <Stat label="Employee" value={subjectName || employee?.name || '—'} bold />
          {schedule && (
            <Stat label="Work Schedule" value={`${schedule.name} (${schedule.code})`} />
          )}
          <Stat label="Planned" value={header ? fmtMins(header.planned_minutes) : '—'} />
          <Stat
            label="Recorded"
            value={fmtMins(header?.recorded_minutes ?? entries.reduce((s,e) => s + e.hours_minutes, 0))}
            color={header && header.recorded_minutes >= header.planned_minutes && header.planned_minutes > 0 ? '#059669' : undefined}
          />
          {header?.submitted_at && (
            <Stat label="Submitted" value={new Date(header.submitted_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })} />
          )}
        </div>
        {/* Tabs — these SCROLL, they do not switch. Nothing is unmounted, so
            the summary stays reachable by scrolling whether or not anyone
            presses one, and the active tab follows the viewport. */}
        <div style={{ display: 'flex', gap: 22, marginTop: 12, marginBottom: -12 }}>
          {([['days', 'Days'], ['summary', 'Summary']] as const).map(([k, label]) => {
            const on = k === 'summary' ? atSummary : !atSummary;
            return (
              <button
                key={k}
                onClick={() => (k === 'summary' ? scrollToSummary() : scrollToCalendar())}
                style={{
                  background: 'none', border: 'none', padding: '0 0 9px', font: 'inherit',
                  fontSize: 13, fontWeight: on ? 700 : 500,
                  color: on ? '#1D4ED8' : '#6B7280', cursor: 'pointer',
                  borderBottom: `2px solid ${on ? '#2563EB' : 'transparent'}`,
                  transition: 'color 0.12s ease, border-color 0.12s ease',
                }}
              >{label}</button>
            );
          })}
        </div>
      </div>

      {error && <div style={{ padding: '8px 24px' }}><ErrorBanner message={error} onRetry={loadPeriod} /></div>}

      {/* No work schedule resolved — say so, at the top, without being clicked.
          A month with no schedule renders as 31 identical grey cells: planned
          hours sit at zero and every absence is refused by the entry trigger
          with "Leave cannot be recorded on a non-working day", which names a
          symptom and hides the cause. The employee cannot fix it themselves, so
          the notice has to point at who can.

          Deliberately not in the day panel next to lockReason: that one answers
          "why is this day locked" for somebody who has already clicked into a
          day. This answers "why is this whole month blank", and a blank month
          gives nobody a reason to click. */}
      {/* `header?.period === this month`, not just `header`. goToPeriod clears
          schedule synchronously, but loadPeriod -- and its setLoading(true) --
          only runs in the effect AFTER that render. So there is exactly one
          paint per month change where loading is still false from the previous
          load, schedule is null, and header still belongs to the month we just
          left. That painted this banner for a single frame on every navigation.
          Tying it to the header actually being for the month on screen means it
          can only appear once THIS month has loaded and genuinely has none. */}
      {!loading && !error && header?.period === `${year}-${pad2(month)}-01` && !schedule && (
        <div style={{ padding: '8px 24px' }}>
          <div style={{
            display: 'flex', gap: 10, alignItems: 'flex-start',
            padding: '10px 14px', borderRadius: 8,
            background: '#FFFBEB', border: '1px solid #FDE68A', color: '#92400E',
          }}>
            <i className="fa-solid fa-triangle-exclamation" style={{ marginTop: 2, flexShrink: 0 }} />
            <div style={{ fontSize: 12.5, lineHeight: 1.5 }}>
              <strong style={{ fontWeight: 700 }}>No work schedule assigned.</strong>{' '}
              Your timesheet cannot be filled in until HR assigns one. Until then every
              day counts as non-working, so planned hours stay at zero and absences
              cannot be recorded.
            </div>
          </div>
        </div>
      )}

      {/* ── Body ─────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>

        {/* ── Calendar ──────────────────────────────────────────────────── */}
        <div
          ref={scrollRef}
          onScroll={() => {
            const el = scrollRef.current, sum = summaryRef.current;
            if (!el || !sum) return;
            // "At the summary" once its top passes the upper third of the
            // viewport — the point where it is what you are actually reading.
            setAtSummary(sum.offsetTop - el.scrollTop < el.clientHeight / 3);
          }}
          style={{ flex: 1, overflowY: 'auto', padding: '16px 20px 40px' }}
        >
          {loading ? (
            <div style={{ textAlign: 'center', padding: 60, color: '#9CA3AF' }}>
              <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 22, display: 'block', marginBottom: 10 }} />
              Loading timesheet…
            </div>
          ) : (
            <>
              {/* Day-of-week headers */}
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 3, marginBottom: 3 }}>
                {DAY_ABBR.map(d => (
                  <div key={d} style={{ textAlign: 'center', fontSize: 11, fontWeight: 700, color: '#9CA3AF', letterSpacing: '0.05em', padding: '3px 0' }}>
                    {d.toUpperCase()}
                  </div>
                ))}
              </div>

              {/* Day cells */}
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 3 }}>
                {cells.map((day, idx) => {
                  if (!day) return <div key={`b-${idx}`} style={{ minHeight: 118 }} />;

                  const dateStr    = isoDate(year, month, day);
                  const dow        = (startDow + day - 1) % 7;
                  const isToday    = dateStr === todayIso;
                  const isSelected = dateStr === selectedDate;
                  const isPast     = dateStr < todayIso;
                  const dayEnts    = entriesByDate[dateStr] ?? [];
                  const dayPlanned = schedule ? plannedForDay(dow, schedule) : 0;
                  const isOffDay   = dayPlanned === 0;
                  const recorded   = dayEnts.reduce((s, e) => s + e.hours_minutes, 0);
                  const status     = dayStatus(recorded, dayPlanned);
                  const holidayName = holidayByDate[dateStr];
                  const isHoliday   = !!holidayName || dayEnts.some(e => e.entry_kind === 'holiday');
                  // A holiday can still be worked. Only take over the cell body when
                  // nothing was logged, otherwise real entries would be hidden.
                  const workEnts    = dayEnts.filter(e => e.entry_kind !== 'holiday');
                  const holidayOnly = isHoliday && workEnts.length === 0;
                  // The same courtesy for a NON-WORKING day, which it never got.
                  // Weekend work is real work -- Copy Day, dateBlockedReason and the
                  // mass-create picker all say so -- but every presentational branch
                  // below tested `isOffDay` alone, so pasted weekend hours were
                  // written, stored, and then drawn as an empty grey square. The cell
                  // only stands down when the day is off AND holds nothing.
                  const offDayEmpty = isOffDay && dayEnts.length === 0;

                  // Hover/focus affordance follows tabIndex: a weekend holiday is
                  // reachable, so it should respond like any other reachable cell.
                  // Declared after isHoliday — it reads it.
                  const isHovered   = hoverDate === dateStr && (!isOffDay || isHoliday || dayEnts.length > 0);

                  // Full-day absence: every entry is leave AND it covers the plan.
                  // A half day of leave stays a normal working day with a leave row.
                  const leaveName = (!isHoliday && dayEnts.length > 0 && dayPlanned > 0
                                     && dayEnts.every(e => e.entry_kind === 'leave')
                                     && recorded >= dayPlanned)
                    ? getCellLabel(dayEnts[0])
                    : null;

                  // Metric shows for any logged day, and for a PAST working day with
                  // nothing logged (-> "0/8h"). Never future, weekend, holiday or leave.
                  const showMetric = !offDayEmpty && !holidayOnly && !leaveName
                                     && (dayEnts.length > 0 || isPast);

                  // Copy Day roles. Non-working days participate — weekend work is real work.
                  const copySrcOk  = copyMode === 'pick'  && attendanceOf(dateStr).length > 0;
                  const copySrcNo  = copyMode === 'pick'  && !copySrcOk;
                  const pasteOk    = copyMode === 'paste' && !dateBlockedReason(dateStr);
                  const pasteNo    = copyMode === 'paste' && !pasteOk && clipboard?.from !== dateStr;
                  const isClipSrc  = clipboard?.from === dateStr;
                  // Hours on a day with no plan — a weekend, or a public holiday
                  // that was worked. Every one of those hours is time beyond the
                  // schedule, which is the same thing "over" means on a working
                  // day, so it carries the same red. This cell used to be blue on
                  // the reasoning that there is no target to exceed; that reads as
                  // "nothing to see" for the case most worth seeing, and it also
                  // disagreed with the OVER PLANNED KPI, which has always counted
                  // these hours (it sums each day's excess over ITS OWN plan).
                  const offPlanWork = (isOffDay || isHoliday) && recorded > 0;

                  // On a worked holiday the schedule's planned hours are not a target,
                  // so show the bare total rather than an "x / 8h" shortfall.
                  const metricColor = offPlanWork        ? '#DC2626'
                                    : isHoliday          ? '#7C3AED'
                                    : status === 'over'  ? '#DC2626'
                                    : status === 'done'  ? '#059669'
                                    : status === 'empty' ? '#D97706'
                                    :                      '#2563EB';

                  // Bar segments — derived from the same `status` as the metric above
                  const segments: { w: number; c: string }[] =
                    // Red, full width, and ahead of the holiday branch: an
                    // UNWORKED holiday is still purple, a worked one is overtime.
                      offPlanWork        ? [{ w: 100, c: '#EF4444' }]
                    : isHoliday          ? [{ w: 100, c: '#8B5CF6' }]
                    : leaveName          ? [{ w: 100, c: '#3B82F6' }]
                    : status === 'over'  ? [{ w: (dayPlanned / recorded) * 100, c: '#10B981' },
                                            { w: 100 - (dayPlanned / recorded) * 100, c: '#EF4444' }]
                    : status === 'done'  ? [{ w: 100, c: '#10B981' }]
                    : status === 'part'  ? [{ w: (recorded / dayPlanned) * 100, c: '#3B82F6' }]
                    :                      [];
                  // Track turns amber only once the day is actually overdue
                  const trackBg = (isHoliday || leaveName)                       ? '#F1F5F9'
                                : (status === 'empty' || status === 'part') && isPast ? '#FDE9AF'
                                : isPast                                        ? '#F1F5F9'
                                :                                                 '#F8FAFC';

                  return (
                    <div
                      key={dateStr}
                      role="button"
                      // A holiday or an entry outranks "non-working day": a public
                      // holiday falling on a weekend still has something to show, so
                      // it stays keyboard-reachable and announces by name.
                      tabIndex={isOffDay && !isHoliday && dayEnts.length === 0 ? -1 : 0}
                      aria-label={`${day} ${MONTH_NAMES[month - 1]}, ${
                        isHoliday   ? `public holiday${holidayName ? ' — ' + holidayName : ''}${isOffDay ? ', non-working day' : ''}`
                        : leaveName ? leaveName
                        : isOffDay  ? (dayEnts.length > 0
                            ? `${fmtDayHours(recorded, status)} logged on a non-working day, all of it beyond the schedule`
                            : 'non-working day')
                        : `${fmtDayHours(recorded, status)} of ${Math.round(dayPlanned / 60)} hours logged`}`}
                      onMouseEnter={() => setHoverDate(dateStr)}
                      onMouseLeave={() => setHoverDate(null)}
                      onFocus={() => setHoverDate(dateStr)}
                      onBlur={() => setHoverDate(null)}
                      onKeyDown={e => {
                        if (e.key === 'Enter' || e.key === ' ') {
                          e.preventDefault();
                          if (copyMode === 'pick')  { copyDay(dateStr); return; }
                          if (copyMode === 'paste') { pasteInto(dateStr); return; }
                          setSelectedDate(dateStr); setPanelOpen(true); cancelForm(); setExpandedEntries(new Set());
                        }
                      }}
                      onClick={() => {
                        if (copyMode === 'pick')  { copyDay(dateStr); return; }
                        if (copyMode === 'paste') { pasteInto(dateStr); return; }
                        setSelectedDate(dateStr); setPanelOpen(true); cancelForm(); setExpandedEntries(new Set());
                      }}
                      style={{
                        minHeight: 118,
                        borderRadius: 8,
                        opacity: (copySrcNo || pasteNo) ? 0.4 : 1,
                        border: `1px ${pasteOk ? 'dashed' : 'solid'} ${
                          isClipSrc   ? '#10B981'
                          : pasteOk    ? '#6EE7B7'
                          : copySrcOk  ? '#93C5FD'
                          : isSelected ? '#2563EB'
                          : isHoliday  ? '#EDE4FE'
                          : offDayEmpty ? 'transparent'
                          : isHovered  ? '#D0D5DD'
                          : leaveName  ? '#DBEAFE'
                          :              '#E5E7EB'}`,
                        // isHoliday BEFORE isOffDay. A holiday falling on a weekend
                        // still has something to say; the border, aria-label and tab
                        // order already gave it precedence (6c4cde1) — the background
                        // and the status bar below were simply missed.
                        background: pasteOk    ? '#F6FEFB'
                                  : copySrcOk  ? '#F8FBFF'
                                  : isHoliday  ? '#FAF5FF'
                                  : offDayEmpty ? '#F4F5F7'
                                  : leaveName  ? '#EFF6FF'
                                  : isHovered  ? '#FCFCFD'
                                  :              '#fff',
                        boxShadow: isClipSrc
                          ? '0 0 0 3px rgba(16,185,129,0.12)'
                          : isSelected
                          ? '0 0 0 3px rgba(37,99,235,0.08), 0 2px 8px -2px rgba(16,24,40,0.12)'
                          : isHovered ? '0 1px 2px rgba(16,24,40,0.06)' : undefined,
                        transform: isSelected ? 'translateY(-1px)' : undefined,
                        cursor: (copySrcNo || pasteNo) ? 'not-allowed' : 'pointer',
                        display: 'flex',
                        flexDirection: 'column',
                        overflow: 'hidden',
                        transition: 'background 0.12s ease, border-color 0.12s ease, box-shadow 0.12s ease, transform 0.12s ease',
                      }}
                    >
                      {/* Header — day number + hours metric */}
                      <div style={{
                        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                        padding: '12px 12px 0', gap: 6, height: 26, flexShrink: 0,
                      }}>
                        <span style={{
                          fontSize: 12, fontWeight: offDayEmpty ? 500 : 600, lineHeight: 1,
                          fontVariantNumeric: 'tabular-nums',
                          color: isToday ? '#fff'
                               : offDayEmpty ? '#C3C8D0'
                               : isHoliday ? '#7C3AED'
                               : leaveName ? '#1E40AF'
                               : '#475569',
                          background: isToday ? '#2563EB' : 'transparent',
                          borderRadius: '50%',
                          width: isToday ? 20 : undefined, height: isToday ? 20 : undefined,
                          margin: isToday ? '-3px 0' : undefined,
                          display: isToday ? 'inline-flex' : undefined,
                          alignItems: 'center', justifyContent: 'center',
                        }}>
                          {day}
                        </span>
                        {showMetric && (
                          <span style={{ display: 'flex', alignItems: 'baseline', gap: 1, lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>
                            <b style={{ fontSize: 14, fontWeight: 800, letterSpacing: '-0.03em', color: metricColor }}>
                              {fmtDayHours(recorded, status)}
                            </b>
                            <span style={{ fontSize: 10, fontWeight: 500, color: '#98A2B3' }}>
                              {isHoliday || isOffDay ? 'h' : `/${Math.round(dayPlanned / 60)}h`}
                            </span>
                          </span>
                        )}
                      </div>

                      {/* Body */}
                      <div style={{ flex: 1, padding: '6px 12px 7px', minHeight: 0, overflow: 'hidden' }}>
                        {holidayOnly ? (
                          <>
                            <span style={{
                              display: 'inline-block', fontSize: 8, fontWeight: 800, letterSpacing: '0.07em',
                              background: '#EDE9FE', color: '#5B21B6', padding: '2px 5px', borderRadius: 3, marginBottom: 3,
                            }}>HOLIDAY</span>
                            {holidayName && (
                              <div style={{ fontSize: 11, fontWeight: 700, color: '#7C3AED', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                {holidayName}
                              </div>
                            )}
                          </>
                        ) : leaveName ? (
                          <>
                            <span style={{
                              display: 'inline-block', fontSize: 8, fontWeight: 800, letterSpacing: '0.07em',
                              background: '#DBEAFE', color: '#1E40AF', padding: '2px 5px', borderRadius: 3, marginBottom: 3,
                            }}>LEAVE</span>
                            <div style={{ fontSize: 11, fontWeight: 700, color: '#1E40AF', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                              {leaveName}
                            </div>
                          </>
                        ) : offDayEmpty ? null
                          : (dateStr > todayIso && !timeTypes.some(t => t.allows_future)) ? null
                          : dayEnts.length === 0 ? (
                          <div style={{ height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                            {/* The one write affordance that was not gated: an
                                empty day still said "＋ Add time" on hover in a
                                read-only month. Nothing could actually be
                                written — the panel shows the lock notice
                                instead of a form — but inviting a click that
                                leads to a refusal is the same class of mistake
                                as offering a View Timesheet button that leads
                                to one. */}
                            <span style={{
                              fontSize: 11, fontWeight: 600, color: '#98A2B3',
                              opacity: (editable && (isHovered || isSelected)) ? 1 : 0,
                              transition: 'opacity 0.12s ease',
                            }}>
                              ＋ Add time
                            </span>
                          </div>
                        ) : (
                          <>
                            {dayEnts.slice(0, 3).map(ent => (
                              <div
                                key={ent.id}
                                onClick={e => { e.stopPropagation(); setSelectedDate(dateStr); setPanelOpen(true); openEdit(ent); }}
                                style={{
                                  display: 'flex', alignItems: 'center', flexWrap: 'nowrap', gap: 8,
                                  height: 15, padding: '0 3px', margin: '0 -3px',
                                  borderRadius: 3, whiteSpace: 'nowrap', transition: 'background 0.1s',
                                }}
                                onMouseEnter={e => (e.currentTarget.style.background = '#F1F5F9')}
                                onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}
                              >
                                <span style={{
                                  flex: '1 1 auto', minWidth: 0, fontSize: 11, fontWeight: 600,
                                  color: ent.entry_kind === 'leave' ? '#1E40AF' : '#1F2937',
                                  letterSpacing: '-0.01em',
                                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                                }}>
                                  {getCellLabel(ent)}
                                </span>
                                <span style={{
                                  flex: '0 0 34px', width: 34, textAlign: 'right',
                                  fontSize: 11, fontWeight: 600, color: '#667085',
                                  fontVariantNumeric: 'tabular-nums',
                                }}>
                                  {Math.round(ent.hours_minutes / 60 * 10) / 10}h
                                </span>
                              </div>
                            ))}
                            {dayEnts.length > 3 && (
                              <div
                                onClick={e => { e.stopPropagation(); setSelectedDate(dateStr); setPanelOpen(true); cancelForm(); }}
                                style={{ fontSize: 10, fontWeight: 700, color: '#6366F1', padding: '1px 3px 0', margin: '0 -3px', cursor: 'pointer' }}
                              >
                                +{dayEnts.length - 3} more
                              </div>
                            )}
                          </>
                        )}
                      </div>

                      {/* Status bar — one rounded pill, same source of truth as the metric.
                          A holiday keeps its purple bar even on a weekend: `segments`
                          already computes it, it was just never rendered on an off-day. */}
                      {(!offDayEmpty || isHoliday) && (
                        <div style={{ padding: '0 12px 9px', flexShrink: 0 }}>
                          <div style={{
                            display: 'flex', height: 6, borderRadius: 99,
                            background: trackBg, overflow: 'hidden',
                          }}>
                            {segments.map((seg, i) => (
                              <div key={i} style={{
                                width: `${seg.w}%`, height: '100%', background: seg.c,
                                borderTopLeftRadius:     i === 0 ? 99 : 0,
                                borderBottomLeftRadius:  i === 0 ? 99 : 0,
                                borderTopRightRadius:    i === segments.length - 1 ? 99 : 0,
                                borderBottomRightRadius: i === segments.length - 1 ? 99 : 0,
                                transition: 'width 0.4s ease-out',
                              }} />
                            ))}
                          </div>
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>

              {/* Legend */}
              <div style={{ display: 'flex', gap: 14, marginTop: 14, flexWrap: 'wrap', alignItems: 'center' }}>
                {[
                  { bg: '#D1FAE5', color: '#065F46', code: 'WK',  label: 'Work (project)' },
                  { bg: '#FEF3C7', color: '#92400E', code: 'SL',  label: 'Sick Leave' },
                  { bg: '#DBEAFE', color: '#1E40AF', code: 'AL',  label: 'Annual Leave' },
                  { bg: '#EDE9FE', color: '#5B21B6', code: 'HOL', label: 'Public Holiday' },
                ].map(({ bg, color, code, label }) => (
                  <div key={code} style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11, color: '#6B7280' }}>
                    <span style={{ fontSize: 8, fontWeight: 800, padding: '1.5px 4px', borderRadius: 3, background: bg, color, letterSpacing: '0.04em' }}>{code}</span>
                    {label}
                  </div>
                ))}
                <div style={{ marginLeft: 8, display: 'flex', gap: 10, fontSize: 11, color: '#6B7280' }}>
                  <span><span style={{ color: '#D1D5DB', fontWeight: 800 }}>▬</span> Partial</span>
                  <span><span style={{ color: '#10B981', fontWeight: 800 }}>▬</span> Complete</span>
                  <span><span style={{ color: '#6366F1', fontWeight: 800 }}>▬</span> Overtime</span>
                </div>
              </div>

              {/* ── Monthly Summary ─────────────────────────────────────
                  Same scroll flow as the calendar, never unmounted. Every
                  figure is derived from state already on this page, so it
                  cannot disagree with the grid above it. */}
              <div ref={summaryRef} id="summary-section">
                <SummarySection
                  year={year}
                  month={month}
                  entries={entries}
                  plannedMinutes={header?.planned_minutes ?? 0}
                  plannedFor={plannedFor}
                  holidayByDate={holidayByDate}
                  todayIso={todayIso}
                  onJumpToDate={jumpToDate}
                />
              </div>
            </>
          )}
        </div>

        {/* ── Day detail panel ──────────────────────────────────────────── */}
        {panelOpen && selectedDate && (
          <div style={{
            width: 340, minWidth: 300, borderLeft: '1px solid #E5E7EB',
            background: '#fff', display: 'flex', flexDirection: 'column',
            overflowY: 'auto', flexShrink: 0,
          }}>
            {/* Panel header */}
            <div style={{ padding: '12px 16px', borderBottom: '1px solid #F3F4F6' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 700, color: '#111827' }}>
                    {new Date(selectedDate + 'T00:00:00').toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}
                  </div>
                  {selectedDate === todayIso && (
                    <span style={{ fontSize: 11, color: '#2563EB', fontWeight: 600 }}>Today</span>
                  )}
                </div>
                <button onClick={() => { setPanelOpen(false); setSelectedDate(null); cancelForm(); }}
                  style={{ background: 'none', border: 'none', color: '#9CA3AF', cursor: 'pointer', fontSize: 16 }}>
                  <i className="fa-solid fa-xmark" />
                </button>
              </div>

              {/* Day progress summary */}
              {(() => {
                const recorded = dayEntries.reduce((s, e) => s + e.hours_minutes, 0);
                const dow      = new Date(selectedDate + 'T00:00:00').getDay();
                const planned  = schedule ? plannedForDay(dow, schedule) : 0;
                const holiday  = holidayByDate[selectedDate];

                // A holiday is not a target. Falling through to the normal bar
                // would say "0 / 8 hr — 8 hr remaining" on Diwali, telling the
                // employee they owe hours nobody expected — and contradicting
                // plannedMinutesForMonth(), which excludes holidays from the plan.
                // The HolidayCard below carries an unworked holiday on its own.
                if (holiday) {
                  if (recorded === 0) return null;
                  // Worked holiday: show the bare total, never a shortfall.
                  return (
                    <div style={{ marginTop: 12 }}>
                      <div style={{ height: 10, borderRadius: 99, overflow: 'hidden', background: '#F1F5F9', marginBottom: 8 }}>
                        <div style={{ width: '100%', height: '100%', background: '#8B5CF6' }} />
                      </div>
                      <div style={{ fontSize: 18, fontWeight: 700, color: '#111827', lineHeight: 1.3 }}>
                        {+(recorded / 60).toFixed(1)} hr
                      </div>
                      <div style={{ fontSize: 11, fontWeight: 500, color: '#5B21B6', lineHeight: 1.4 }}>
                        Logged on a public holiday
                      </div>
                    </div>
                  );
                }

                if (planned === 0) {
                  return (
                    <div style={{ marginTop: 10, fontSize: 12, color: '#9CA3AF', fontStyle: 'italic' }}>
                      Non-working day
                    </div>
                  );
                }

                const recHrs    = +(recorded / 60).toFixed(1);
                const planHrs   = Math.round(planned / 60);
                const isOver    = recorded > planned;
                const isDone    = recorded >= planned;
                const overHrs   = +((recorded - planned) / 60).toFixed(1);
                const remHrs    = +((planned - recorded) / 60).toFixed(1);

                // Segmented bar colours
                const loggedColor    = isDone ? '#10B981' : '#3B82F6';
                const remainingColor = '#FCD34D';
                const extraColor     = '#F87171';

                // Status text colour
                const statusColor = isOver ? '#DC2626' : isDone ? '#059669' : '#B45309';
                const statusText  = isOver
                  ? `+${overHrs} hr over plan`
                  : isDone
                  ? '✓ Day complete'
                  : `${remHrs} hr remaining`;

                return (
                  <div style={{ marginTop: 12 }}>
                    {/* Segmented progress bar */}
                    <div style={{ height: 10, borderRadius: 99, overflow: 'hidden', display: 'flex', gap: 2, marginBottom: 8 }}>
                      {isOver ? (
                        <>
                          <div style={{ flex: planHrs, height: '100%', borderRadius: 99, background: '#10B981', transition: 'flex 0.4s ease-out' }} />
                          <div style={{ flex: overHrs, height: '100%', borderRadius: 99, background: extraColor, transition: 'flex 0.4s ease-out' }} />
                        </>
                      ) : (
                        <>
                          <div style={{ flex: recHrs, height: '100%', borderRadius: 99, background: loggedColor, transition: 'flex 0.4s ease-out' }} />
                          {!isDone && <div style={{ flex: remHrs, height: '100%', borderRadius: 99, background: remainingColor }} />}
                        </>
                      )}
                    </div>
                    {/* Numbers */}
                    <div style={{ fontSize: 18, fontWeight: 700, color: '#111827', lineHeight: 1.3 }}>
                      {recHrs} / {planHrs} hr
                    </div>
                    {/* Status line */}
                    <div style={{ fontSize: 11, fontWeight: 500, color: statusColor, lineHeight: 1.4 }}>
                      {statusText}
                    </div>
                  </div>
                );
              })()}
            </div>

            {/* Expand All / Collapse All row — only when there are entries */}
            {dayEntries.length > 0 && (
              <div style={{ display: 'flex', justifyContent: 'flex-end', padding: '6px 16px 4px', borderBottom: '1px solid #F3F4F6' }}>
                <button
                  onClick={() => toggleAllEntries(dayEntries)}
                  style={{
                    display: 'flex', alignItems: 'center', gap: 5,
                    border: '1px solid #E5E7EB', borderRadius: 6,
                    padding: '3px 10px', cursor: 'pointer', fontSize: 11, fontWeight: 700,
                    color: dayEntries.some(e => expandedEntries.has(e.id)) ? '#3B82F6' : '#6B7280',
                    borderColor: dayEntries.some(e => expandedEntries.has(e.id)) ? '#BFDBFE' : '#E5E7EB',
                    background: dayEntries.some(e => expandedEntries.has(e.id)) ? '#EFF6FF' : 'none',
                    transition: 'all 0.15s',
                  }}
                >
                  <i className={`fa-solid fa-chevron-${dayEntries.some(e => expandedEntries.has(e.id)) ? 'up' : 'down'}`} style={{ fontSize: 9 }} />
                  {dayEntries.some(e => expandedEntries.has(e.id)) ? 'Collapse All' : 'Expand All'}
                </button>
              </div>
            )}

            {/* Entries */}
            <div style={{ flex: 1, padding: '5px 10px' }}>
              {/* Holiday first, then any real entries below it — a holiday can be
                  worked, and the Add buttons stay live so it can still be logged. */}
              {holidayByDate[selectedDate] && (
                <HolidayCard
                  name={holidayByDate[selectedDate]}
                  plannedMinutes={schedule ? plannedForDay(new Date(selectedDate + 'T00:00:00').getDay(), schedule) : 0}
                />
              )}

              {dayEntries.length === 0 && !addingEntry && !holidayByDate[selectedDate] && (
                <div style={{ color: '#9CA3AF', fontSize: 12, textAlign: 'center', padding: '20px 0' }}>
                  <i className="fa-regular fa-clock" style={{ fontSize: 20, display: 'block', marginBottom: 6 }} />
                  No entries for this day
                </div>
              )}

              <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
              {dayEntries.map(ent => {
                const badge    = getEntryBadge(ent);
                const isOpen   = expandedEntries.has(ent.id);
                const isEditing = editingEntry?.id === ent.id;
                // Same rule as the exported report, computed the same way, so
                // the screen and the PDF cannot mark different rows.
                const chg = status === 'approved'
                  ? changeMarkFor(ent, header?.approved_at ?? null) : null;
                return (
                  <div key={ent.id} style={{
                    border: isEditing ? '2px solid #2563EB'
                          : chg       ? '1px solid #F6E2A0'
                          :             '1px solid #E5E7EB',
                    borderRadius: 10, overflow: 'hidden',
                    background: chg && !isEditing ? '#FFFCF4' : '#fff',
                    transition: 'box-shadow 0.15s',
                  }}>
                    {/* Card header: single-line compact */}
                    {(() => {
                      const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
                      const p = Array.isArray(ent.projects)   ? ent.projects[0]   : ent.projects;
                      const primaryText = p?.name ?? t?.name ?? (ent.entry_kind === 'holiday' ? 'Holiday' : ent.entry_kind);
                      return (
                        <div style={{ display: 'flex', alignItems: 'center', padding: '0 10px 0 12px', height: 44, gap: 8 }}>
                          {/* Colored dot */}
                          <div style={{ width: 8, height: 8, borderRadius: '50%', background: badge.accentColor, flexShrink: 0 }} />
                          {/* Name */}
                          <div style={{ flex: 1, minWidth: 0, fontSize: 14, fontWeight: 700, color: '#111827', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                            {primaryText}
                            {ent.is_system_generated && <span style={{ fontSize: 9, color: '#9CA3AF', background: '#F3F4F6', padding: '1px 4px', borderRadius: 3, marginLeft: 6, fontWeight: 400 }}>auto</span>}
                            {/* Recorded after the approval this sheet still
                                carries. The tag says which, because a wash
                                alone would just look like a selected row. */}
                            {chg && (
                              <span
                                title={`This entry was ${chg} after the timesheet was approved.`}
                                style={{ fontSize: 9, fontWeight: 700, letterSpacing: '0.04em',
                                         color: '#92400E', background: '#FEF6DC',
                                         border: '1px solid #F6E2A0', padding: '1px 5px',
                                         borderRadius: 3, marginLeft: 6 }}>
                                {chg === 'added' ? 'ADDED' : 'EDITED'}
                              </span>
                            )}
                          </div>
                          {/* Right: hours + divider + actions + chevron */}
                          <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0 }}>
                            <span style={{ fontSize: 15, fontWeight: 700, color: '#3B82F6', lineHeight: 1, minWidth: 34, textAlign: 'right' }}>{fmtMins(ent.hours_minutes)}</span>
                            {(editable && !ent.is_system_generated) && (
                              <div style={{ width: 1, height: 24, background: '#E5E7EB', flexShrink: 0 }} />
                            )}
                            {editable && !ent.is_system_generated && (
                              <>
                                <button onClick={() => openEdit(ent)} title="Edit" style={{ width: 22, height: 22, border: '1px solid #E5E7EB', borderRadius: 6, background: '#F9FAFB', color: '#6B7280', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer', flexShrink: 0 }}>
                                  <i className="fa-solid fa-pen" style={{ fontSize: 10 }} />
                                </button>
                                <button onClick={() => handleDeleteEntry(ent.id)} title="Delete" style={{ width: 22, height: 22, border: '1px solid #FEE2E2', borderRadius: 6, background: '#FFF5F5', color: '#DC2626', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer', flexShrink: 0 }}>
                                  <i className="fa-solid fa-trash" style={{ fontSize: 10 }} />
                                </button>
                              </>
                            )}
                            <button
                              onClick={() => toggleEntryExpand(ent.id)}
                              title={isOpen ? 'Collapse' : 'Expand'}
                              style={{
                                width: 22, height: 22, flexShrink: 0,
                                border: `1px solid ${isOpen ? '#BFDBFE' : '#E5E7EB'}`,
                                borderRadius: 6,
                                background: isOpen ? '#EFF6FF' : '#F9FAFB',
                                color: isOpen ? '#3B82F6' : '#9CA3AF',
                                cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center',
                                fontSize: 9, userSelect: 'none', transition: 'all 0.15s',
                              }}
                            >
                              <i className={`fa-solid fa-chevron-${isOpen ? 'up' : 'down'}`} />
                            </button>
                          </div>
                        </div>
                      );
                    })()}

                    {/* Inline edit form — replaces card body when editing this entry */}
                    {isEditing ? (
                      <div style={{ borderTop: '1px solid #BFDBFE', background: '#EFF6FF', padding: '10px 12px 12px' }}>
                        {renderEntryFields({ projectDates: selectedDate ? [selectedDate] : [] })}
                        <div style={{ display: 'flex', gap: 7 }}>
                          {/* title on the wrapper — a disabled button never
                              receives hover, so a tooltip on it is invisible */}
                          <span title={saveBlocked || undefined} style={{ flex: 1, display: 'flex' }}>
                          <button onClick={handleSaveEntry} disabled={saving || !!saveBlocked} style={{ flex: 1, padding: '7px 0', borderRadius: 6, border: 'none', background: saveBlocked ? '#E5E7EB' : '#1D4ED8', color: saveBlocked ? '#9CA3AF' : '#fff', fontSize: 12, fontWeight: 600, cursor: (saving || saveBlocked) ? 'not-allowed' : 'pointer', opacity: saving ? 0.7 : 1 }}>
                            {saving ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</> : 'Update'}
                          </button>
                          </span>
                          <button onClick={cancelForm} disabled={saving} style={{ padding: '7px 14px', borderRadius: 6, border: '1px solid #E5E7EB', background: '#fff', color: '#374151', fontSize: 12, cursor: 'pointer' }}>Cancel</button>
                        </div>
                      </div>
                    ) : (
                    <>
                    {/* Collapsible detail */}
                    {isOpen && (
                      <div style={{ borderTop: '1px solid #F3F4F6', background: '#FAFAFA', padding: '10px 12px 12px' }}>
                        {(() => {
                          const rows  = [...((ent.timesheet_entry_activities ?? []) as TimesheetEntryActivity[])]
                                          .sort((a, b) => a.display_order - b.display_order);
                          const names = (ent.activities ?? []).filter(Boolean);
                          if (!rows.length && !names.length) return null;
                          return (
                            <div style={{ marginBottom: ent.notes ? 8 : 0 }}>
                              <div style={{ fontSize: 9, fontWeight: 800, color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.08em', marginBottom: 6 }}>
                                Activities
                              </div>
                              {rows.length > 0
                                ? rows.map(r => (
                                    <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 7, padding: '2px 0' }}>
                                      <span style={{ width: 5, height: 5, borderRadius: '50%', background: '#34D399', flexShrink: 0, display: 'inline-block' }} />
                                      <span style={{ fontSize: 12, color: '#374151', fontWeight: 500, flex: 1, minWidth: 0 }}>{r.activity_name}</span>
                                      <span style={{ fontSize: 11, color: '#6B7280', fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>{fmtMins(r.hours_minutes)}</span>
                                    </div>
                                  ))
                                /* Recorded before activities carried their own hours. Say so
                                   rather than showing a number that was never entered. */
                                : names.map((a, i) => (
                                    <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 7, padding: '2px 0' }}>
                                      <span style={{ width: 5, height: 5, borderRadius: '50%', background: '#D1D5DB', flexShrink: 0, display: 'inline-block' }} />
                                      <span style={{ fontSize: 12, color: '#374151', fontWeight: 500, flex: 1, minWidth: 0 }}>{a}</span>
                                      <span style={{ fontSize: 10, color: '#9CA3AF', fontStyle: 'italic' }}>hours not split</span>
                                    </div>
                                  ))}
                            </div>
                          );
                        })()}
                        {ent.notes && (
                          <div style={{
                            background: '#fff', border: '1px solid #E5E7EB', borderRadius: 6,
                            padding: '7px 10px', fontSize: 11, color: '#6B7280', lineHeight: 1.5,
                          }}>
                            📝 {ent.notes}
                          </div>
                        )}
                        {(!ent.activities || ent.activities.length === 0) && !ent.notes && (
                          <div style={{ fontSize: 11, color: '#CBD5E1', fontStyle: 'italic', textAlign: 'center', padding: '4px 0' }}>
                            No activities or notes
                          </div>
                        )}
                      </div>
                    )}
                    </>
                    )}
                  </div>
                );
              })}
              </div>

              {/* Add new entry form — only shown when adding, not when editing (edit is inline in the card) */}
              {addingEntry && !editingEntry && (
                <div style={{
                  border: '1px dashed #93C5FD', borderRadius: 8, padding: 12,
                  background: '#EFF6FF', marginTop: 8,
                }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: '#1D4ED8', marginBottom: 10 }}>
                    {editingEntry ? 'Edit Entry' : 'Add Entry'}
                  </div>

                  {/* Issue 2 fix — warn before silently appending to a day that
                      already has attendance. The save is not blocked; the user just
                      needs to know they are adding alongside existing entries, not
                      creating a fresh day. */}
                  {selectedDate && (entriesByDate[selectedDate] ?? []).length > 0 && (() => {
                    const n = (entriesByDate[selectedDate] ?? []).length;
                    return (
                      <div style={{
                        display: 'flex', alignItems: 'flex-start', gap: 8,
                        background: '#FFFBEB', border: '1px solid #FDE68A',
                        borderRadius: 6, padding: '8px 10px', marginBottom: 10,
                        fontSize: 12, color: '#92400E', lineHeight: 1.5,
                      }}>
                        <span style={{ fontSize: 13, marginTop: 1 }}>⚠️</span>
                        <span>
                          This day already has <b>{n === 1 ? '1 entry' : `${n} entries`}</b>.
                          {' '}Your new entry will be added alongside {n === 1 ? 'it' : 'them'}.
                        </span>
                      </div>
                    );
                  })()}

                  {renderEntryFields({ projectDates: selectedDate ? [selectedDate] : [] })}

                  <div style={{ display: 'flex', gap: 7 }}>
                    <span title={saveBlocked || undefined} style={{ flex: 1, display: 'flex' }}>
                    <button
                      onClick={handleSaveEntry} disabled={saving || !!saveBlocked}
                      style={{ flex: 1, padding: '7px 0', borderRadius: 6, border: 'none', background: saveBlocked ? '#E5E7EB' : '#1D4ED8', color: saveBlocked ? '#9CA3AF' : '#fff', fontSize: 12, fontWeight: 600, cursor: (saving || saveBlocked) ? 'not-allowed' : 'pointer', opacity: saving ? 0.7 : 1 }}
                    >
                      {saving
                        ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                        : editingEntry ? 'Update' : 'Save Entry'}
                    </button>
                    </span>
                    <button
                      onClick={cancelForm} disabled={saving}
                      style={{ padding: '7px 14px', borderRadius: 6, border: '1px solid #E5E7EB', background: '#fff', color: '#374151', fontSize: 12, cursor: 'pointer' }}
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              )}

              {/* Add Attendance / Add Absence buttons.
                  Prevention over validation: a button that leads to a certain
                  rejection is withdrawn and replaced by the reason, rather than
                  offered and then failed on save. There is no fix available at
                  the point of that error — the day simply is not available. */}
              {editable && !addingEntry && selectedDate && (() => {
                const absBlock = dayAbsenceBlock(selectedDate);          // mig 726 (g)
                const hasAbs   = absenceMinutes(selectedDate) > 0;       // mig 721 (b)
                const isFuture = selectedDate > todayIso;                // mig 729 (h)
                const noticeSt = {
                  padding: '8px 12px', borderRadius: 8, fontSize: 12, lineHeight: 1.45,
                  background: '#F9FAFB', border: '1px solid #E5E7EB', color: '#6B7280',
                  textAlign: 'center' as const,
                };
                return (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: dayEntries.length > 0 ? 6 : 8 }}>
                    {isFuture && !typesAllowingFuture('attendance') ? (
                      <div style={noticeSt}>
                        <i className="fa-regular fa-clock" style={{ marginRight: 5 }} />
                        No attendance type can be recorded in advance. An administrator can
                        allow it on a scheduled type such as Training.
                      </div>
                    ) : absBlock ? (
                      <div style={noticeSt}>
                        <i className="fa-solid fa-umbrella-beach" style={{ marginRight: 5 }} />
                        {absBlock} — attendance cannot be added.
                      </div>
                    ) : (
                      <button
                        onClick={openAddAttendance}
                        style={{
                          width: '100%', padding: '8px 0', borderRadius: 8, border: 'none',
                          background: '#DCFCE7', color: '#166534',
                          fontSize: 13, fontWeight: 600, cursor: 'pointer',
                          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
                        }}
                      >
                        🕐 Add Attendance
                      </button>
                    )}

                    {hasAbs ? (
                      <div style={noticeSt}>Only one absence is allowed per day.</div>
                    ) : isFuture && !typesAllowingFuture('absence') ? (
                      /* Nothing this button could offer on a future day. When at least
                         one type IS allowed the button stays and the picker narrows. */
                      <div style={noticeSt}>
                        No absence type can be recorded in advance. Ask an administrator to
                        enable it on the type, or book the leave through the leave module.
                      </div>
                    ) : (
                      <button
                        onClick={openAddAbsence}
                        style={{
                          width: '100%', padding: '8px 0', borderRadius: 8, border: 'none',
                          background: '#FEF9C3', color: '#854D0E',
                          fontSize: 13, fontWeight: 600, cursor: 'pointer',
                          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
                        }}
                      >
                        🏖 Add Absence
                      </button>
                    )}

                    {/* Not a blocker — a part-day absence alongside work is
                        legitimate. Say what is still possible, not just what
                        is not: the full-day types are already gone from the
                        picker, and this explains the gap. */}
                    {!hasAbs && hasAttendance(selectedDate) && (
                      <div style={{ ...noticeSt, textAlign: 'left' }}>
                        Attendance is recorded on this day, so only a part-day absence can be added.
                      </div>
                    )}
                  </div>
                );
              })()}

              {/* Locked notice. It used to read "Pending Approval — entries are
                  locked", which named the status without saying what to do
                  about it. There are two different locks now and they have two
                  different answers, so it says which one applies. */}
              {!editable && (
                <div style={{ marginTop: 14, padding: '8px 12px', background: '#F9FAFB', borderRadius: 6, fontSize: 12, color: '#6B7280', textAlign: 'center' }}>
                  <i className="fa-solid fa-lock" style={{ marginRight: 5 }} />
                  {lockReason}
                </div>
              )}
            </div>
          </div>
        )}
      </div>

      {/* ── Selective copy picker ─────────────────────────────────────────── */}
      {copyPickerDate && (() => {
        const work = attendanceOf(copyPickerDate);
        return (
          <div style={{
            position: 'fixed', inset: 0, zIndex: 900,
            background: 'rgba(16,24,40,0.35)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }} onClick={() => { setCopyPickerDate(null); setCopyPickerSel(new Set()); }}>
            <div style={{
              background: '#fff', borderRadius: 10, padding: '20px 22px',
              boxShadow: '0 8px 32px -4px rgba(16,24,40,0.22)',
              minWidth: 320, maxWidth: 440,
            }} onClick={e => e.stopPropagation()}>
              <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 4 }}>
                Select entries to copy
              </div>
              <div style={{ fontSize: 12, color: '#6B7280', marginBottom: 14 }}>
                From {fmtChip(copyPickerDate)} — choose which attendance to carry across.
              </div>

              {work.map(e => {
                const tt   = timeTypes.find(t => t.id === e.time_type_id);
                const proj = projects.find(p => p.id === e.project_id);
                const h    = Math.floor(e.hours_minutes / 60);
                const m    = e.hours_minutes % 60;
                const dur  = h ? `${h}h${m ? ` ${m}m` : ''}` : `${m}m`;
                const label = proj ? `${proj.name}` : (tt?.name ?? 'Entry');
                const acts  = e.activities?.join(', ') ?? '';
                const ticked = copyPickerSel.has(e.id);
                return (
                  <div key={e.id} onClick={() => {
                    setCopyPickerSel(prev => {
                      const next = new Set(prev);
                      if (next.has(e.id)) next.delete(e.id); else next.add(e.id);
                      return next;
                    });
                  }} style={{
                    display: 'flex', alignItems: 'flex-start', gap: 10,
                    padding: '8px 10px', borderRadius: 6, marginBottom: 6,
                    border: `1px solid ${ticked ? '#BFDBFE' : '#E5E7EB'}`,
                    background: ticked ? '#EFF6FF' : '#FAFAFA',
                    cursor: 'pointer', userSelect: 'none',
                  }}>
                    <div style={{
                      width: 16, height: 16, borderRadius: 3, flexShrink: 0, marginTop: 1,
                      border: `2px solid ${ticked ? '#2563EB' : '#D1D5DB'}`,
                      background: ticked ? '#2563EB' : '#fff',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                    }}>
                      {ticked && <i className="fa-solid fa-check" style={{ fontSize: 9, color: '#fff' }} />}
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontWeight: 600, fontSize: 13, color: '#111827' }}>
                        {label}
                        <span style={{ fontWeight: 400, color: '#6B7280', marginLeft: 6 }}>{dur}</span>
                      </div>
                      {acts && <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{acts}</div>}
                    </div>
                  </div>
                );
              })}

              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 16, gap: 8 }}>
                <button onClick={() => {
                  setCopyPickerSel(s => s.size === work.length ? new Set() : new Set(work.map(e => e.id)));
                }} style={{
                  fontSize: 12, color: '#6B7280', background: 'none', border: 'none',
                  cursor: 'pointer', padding: '4px 0',
                }}>
                  {copyPickerSel.size === work.length ? 'Deselect all' : 'Select all'}
                </button>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button onClick={() => { setCopyPickerDate(null); setCopyPickerSel(new Set()); }} style={{
                    padding: '7px 14px', borderRadius: 7, border: '1px solid #D0D5DD',
                    background: '#fff', color: '#374151', fontWeight: 600, fontSize: 13, cursor: 'pointer',
                  }}>Cancel</button>
                  <button onClick={confirmCopyPicker} disabled={copyPickerSel.size === 0} style={{
                    padding: '7px 14px', borderRadius: 7, border: 'none',
                    background: copyPickerSel.size > 0 ? '#2563EB' : '#93C5FD',
                    color: '#fff', fontWeight: 600, fontSize: 13,
                    cursor: copyPickerSel.size > 0 ? 'pointer' : 'default',
                  }}>
                    Copy {copyPickerSel.size > 0 ? `${copyPickerSel.size} ${copyPickerSel.size === 1 ? 'entry' : 'entries'}` : ''}
                  </button>
                </div>
              </div>
            </div>
          </div>
        );
      })()}

      {/* ── Copy-mode banner ──────────────────────────────────────────────── */}
      {copyMode !== 'idle' && (
        <div style={{
          position: 'fixed', top: 14, left: '50%', transform: 'translateX(-50%)', zIndex: 800,
          display: 'flex', alignItems: 'center', gap: 12, padding: '9px 14px', borderRadius: 9,
          fontSize: 13, fontWeight: 600, boxShadow: '0 4px 14px -4px rgba(16,24,40,0.18)',
          background: copyMode === 'pick' ? '#EFF6FF' : '#ECFDF5',
          border: `1px solid ${copyMode === 'pick' ? '#BFDBFE' : '#A7F3D0'}`,
          color: copyMode === 'pick' ? '#1D4ED8' : '#047857',
        }}>
          {copyMode === 'pick'
            ? '📋 Copy mode — click a day that has attendance'
            : `✓ Copied ${clipboard ? fmtChip(clipboard.from) : ''} (${clipboard?.entries.length ?? 0} ${clipboard?.entries.length === 1 ? 'entry' : 'entries'}) — click any day to paste`}
          <button onClick={exitCopyMode} style={{ border: 'none', background: 'none', font: 'inherit', fontWeight: 700, cursor: 'pointer', color: 'inherit', opacity: 0.75 }}>
            {copyMode === 'pick' ? 'Cancel' : 'Done'} (Esc)
          </button>
        </div>
      )}

      {/* ── Toasts ────────────────────────────────────────────────────────── */}
      <div style={{ position: 'fixed', left: '50%', bottom: 26, transform: 'translateX(-50%)', zIndex: 10000, display: 'flex', flexDirection: 'column', gap: 8, alignItems: 'center' }}>
        {toasts.map(t => (
          <div key={t.id} style={{
            display: 'flex', alignItems: 'center', gap: 12, borderRadius: 10, padding: '11px 14px',
            fontSize: 13, color: '#fff',
            background: t.kind === 'bad' ? '#B42318' : t.kind === 'warn' ? '#B45309' : '#111827',
            boxShadow: '0 10px 24px -6px rgba(16,24,40,0.35)', maxWidth: 520,
          }}>
            <span>{t.msg}</span>
            {t.undoIds && t.undoIds.length > 0 && (
              <button onClick={() => undoEntries(t.undoIds!, t.id)}
                style={{ border: 'none', background: 'none', color: '#93C5FD', font: 'inherit', fontWeight: 700, cursor: 'pointer' }}>
                Undo
              </button>
            )}
          </div>
        ))}
      </div>

      {/* ── Create attendance modal ───────────────────────────────────────── */}
      {createOpen && (
        <div
          style={{ position: 'fixed', inset: 0, zIndex: 9000, background: 'rgba(16,24,40,0.45)', display: 'flex', alignItems: 'flex-start', justifyContent: 'center', padding: '48px 20px', overflowY: 'auto' }}
          onClick={e => { if (e.target === e.currentTarget) setCreateOpen(false); }}
        >
          <div style={{ background: '#fff', borderRadius: 14, width: '100%', maxWidth: 560, boxShadow: '0 20px 48px -12px rgba(16,24,40,0.28)', overflow: 'hidden' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '18px 22px 14px', borderBottom: '1px solid #E5E7EB' }}>
              <h3 style={{ margin: 0, fontSize: 16, fontWeight: 700 }}>Create attendance</h3>
              <button onClick={() => setCreateOpen(false)} style={{ border: 'none', background: 'none', cursor: 'pointer', color: '#98A2B3', fontSize: 18 }}>✕</button>
            </div>

            <div style={{ padding: createErr ? '14px 22px 0' : 0 }}>
            {createErr && (() => {
              const notice = createErr.kind === 'notice';
              return (
                <div style={{
                  background: notice ? '#FFFBEB' : '#FEF3F2',
                  border: `1px solid ${notice ? '#FDE68A' : '#FECDCA'}`,
                  color: notice ? '#92400E' : '#912018',
                  borderRadius: 9, padding: '11px 13px', fontSize: 12.5,
                  display: 'flex', gap: 9, alignItems: 'flex-start',
                }}>
                  <i className={`fa-solid ${notice ? 'fa-circle-info' : 'fa-circle-exclamation'}`} style={{ marginTop: 2 }} />
                  <div style={{ flex: 1 }}>
                    <strong style={{ display: 'block' }}>{createErr.msg}</strong>
                    {createErr.dates.length > 0 && (
                      <>
                        <ul style={{ margin: '4px 0 0', paddingLeft: 17 }}>
                          {createErr.dates.map(d => <li key={d}>{fmtChip(d)}</li>)}
                        </ul>
                        <button
                          onClick={() => {
                            setCreateDates(prev => { const n = new Set(prev); createErr.dates.forEach(d => n.delete(d)); return n; });
                            setCreateErr(null);
                          }}
                          style={{ marginTop: 7, border: 'none', background: 'none', font: 'inherit', fontSize: 12, fontWeight: 700, color: '#B42318', cursor: 'pointer', textDecoration: 'underline', padding: 0 }}
                        >
                          Deselect {createErr.dates.length === 1 ? 'this date' : `these ${createErr.dates.length} dates`}
                        </button>
                      </>
                    )}
                  </div>
                </div>
              );
            })()}
            </div>

            <div style={{ padding: '18px 22px 4px', maxHeight: '62vh', overflowY: 'auto' }}>

              {/* Dates */}
              <div style={{ marginBottom: 16 }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
                  <Label>Dates *</Label>
                  <div style={{ display: 'flex', gap: 10 }}>
                    <button
                      onClick={() => {
                        const next = new Set(createDates);
                        for (let d = 1; d <= totalDays; d++) {
                          const ds = isoDate(year, month, d);
                          const dow = (startDow + d - 1) % 7;
                          const planned = schedule ? plannedForDay(dow, schedule) : 0;
                          if (planned > 0 && !dateBlockedReason(ds)) next.add(ds);
                        }
                        setCreateDates(next); setCreateErr(null);
                      }}
                      style={{ border: 'none', background: 'none', color: '#2563EB', font: 'inherit', fontSize: 11, fontWeight: 600, cursor: 'pointer', padding: 0 }}
                    >All open days to date</button>
                    <button onClick={() => { setCreateDates(new Set()); setCreateErr(null); }}
                      style={{ border: 'none', background: 'none', color: '#2563EB', font: 'inherit', fontSize: 11, fontWeight: 600, cursor: 'pointer', padding: 0 }}
                    >Clear</button>
                  </div>
                </div>

                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, alignItems: 'center', minHeight: 38, border: '1px solid #D0D5DD', borderRadius: 8, padding: '6px 8px' }}>
                  {createDates.size === 0
                    ? <span style={{ fontSize: 12.5, color: '#98A2B3' }}>Pick one or more dates below</span>
                    : [...createDates].sort().map(ds => (
                        <span key={ds} style={{ display: 'inline-flex', alignItems: 'center', gap: 5, background: '#EFF6FF', color: '#1E40AF', border: '1px solid #DBEAFE', borderRadius: 6, padding: '3px 5px 3px 8px', fontSize: 12, fontWeight: 600 }}>
                          {fmtChip(ds)}
                          <button onClick={() => toggleCreateDate(ds)} style={{ border: 'none', background: 'none', cursor: 'pointer', color: '#60A5FA', fontSize: 13, padding: '0 2px' }}>✕</button>
                        </span>
                      ))}
                </div>

                {/* Always-open month picker — never closes on selection */}
                <div style={{ border: '1px solid #E5E7EB', borderRadius: 8, marginTop: 8, overflow: 'hidden' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 10px', background: '#FCFCFD', borderBottom: '1px solid #E5E7EB' }}>
                    <b style={{ fontSize: 12.5, flex: 1 }}>{MONTH_NAMES[month - 1]} {year}</b>
                    <span style={{ fontSize: 10.5, fontWeight: 600, color: '#98A2B3', background: '#F1F5F9', borderRadius: 5, padding: '2px 7px' }}>Timesheet month</span>
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7,1fr)', gap: 2, padding: 8 }}>
                    {DAY_ABBR.map(d => <div key={d} style={{ textAlign: 'center', fontSize: 9, fontWeight: 700, color: '#98A2B3', padding: '2px 0' }}>{d[0]}</div>)}
                    {Array.from({ length: startDow }).map((_, i) => <div key={`b${i}`} />)}
                    {Array.from({ length: totalDays }).map((_, i) => {
                      const d = i + 1;
                      const ds = isoDate(year, month, d);
                      const reason = dateBlockedReason(ds);
                      const on = createDates.has(ds);
                      const dow = (startDow + d - 1) % 7;
                      const nonWorking = (schedule ? plannedForDay(dow, schedule) : 0) === 0;
                      return (
                        <button
                          key={ds} disabled={!!reason} title={reason ?? (nonWorking ? 'Non-working day — attendance may still be recorded' : '')}
                          onClick={() => toggleCreateDate(ds)}
                          style={{
                            position: 'relative', height: 32, borderRadius: 6, font: 'inherit', fontSize: 12, fontWeight: 600,
                            fontVariantNumeric: 'tabular-nums', cursor: reason ? 'not-allowed' : 'pointer',
                            border: ds === todayIso ? '1px solid #2563EB' : '1px solid transparent',
                            background: on ? '#2563EB' : 'transparent',
                            color: on ? '#fff' : reason === 'Already has attendance' ? '#98A2B3' : reason ? '#D8DEE7' : nonWorking ? '#CBD5E1' : '#1F2937',
                            display: 'flex', alignItems: 'center', justifyContent: 'center',
                          }}
                        >
                          {d}
                          {reason === 'Already has attendance' && (
                            <span style={{ position: 'absolute', bottom: 3, left: '50%', transform: 'translateX(-50%)', width: 4, height: 4, borderRadius: '50%', background: '#F59E0B' }} />
                          )}
                        </button>
                      );
                    })}
                  </div>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 14px', padding: '0 10px 9px', fontSize: 10.5, color: '#667085' }}>
                    <span><span style={{ display: 'inline-block', width: 4, height: 4, borderRadius: '50%', background: '#F59E0B', marginRight: 5, verticalAlign: 2 }} />Already has attendance</span>
                    <span>{timeTypes.some(t => t.allows_future)
                      ? 'Most types cannot be recorded in advance — the greyed days depend on the type'
                      : 'Greyed after today — cannot be recorded in advance'}</span>
                    <span>Weekends and holidays can be selected</span>
                  </div>
                </div>
              </div>

              {/* Attendance form — the same fields the day panel renders.
                  Projects are intersected across every selected date. */}
              <div style={{ border: '1px solid #BFDBFE', borderRadius: 10, background: '#F8FBFF', padding: 14, marginBottom: 4 }}>
                {renderEntryFields({ projectDates: [...createDates].sort(), gap: 10, showErr: false })}
              </div>
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '14px 22px 18px', borderTop: '1px solid #E5E7EB', background: '#FCFCFD' }}>
              <span style={{ fontSize: 12, color: '#667085' }}>
                {createDates.size === 0 ? 'No dates selected' : (
                  <>Creates <b style={{ color: '#1F2937' }}>1 entry</b> on <b style={{ color: '#1F2937' }}>{createDates.size}</b> {createDates.size === 1 ? 'day' : 'days'}</>
                )}
              </span>
              <span style={{ flex: 1 }} />
              <button onClick={() => setCreateOpen(false)} style={{ padding: '8px 14px', borderRadius: 8, border: '1px solid transparent', background: 'none', color: '#667085', fontSize: 13, fontWeight: 600, cursor: 'pointer' }}>Cancel</button>
              <button
                onClick={submitCreate}
                disabled={creating || createDates.size === 0}
                style={{
                  padding: '8px 16px', borderRadius: 8, border: 'none',
                  background: (creating || createDates.size === 0) ? '#E5E7EB' : '#2563EB',
                  color: (creating || createDates.size === 0) ? '#9CA3AF' : '#fff',
                  fontSize: 13, fontWeight: 600, cursor: (creating || createDates.size === 0) ? 'not-allowed' : 'pointer',
                }}
              >
                {creating ? 'Creating…' : 'Create'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Submit confirmation modal ─────────────────────────────────────── */}
      {confirmSubmit && (
        <div
          style={{ position: 'fixed', inset: 0, zIndex: 9999, background: 'rgba(0,0,0,0.35)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}
          onClick={() => setConfirmSubmit(false)}
        >
          <div
            style={{ background: '#fff', borderRadius: 12, padding: '28px 32px', width: 420, boxShadow: '0 8px 32px rgba(0,0,0,0.18)' }}
            onClick={e => e.stopPropagation()}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
              <i className="fa-solid fa-paper-plane" style={{ fontSize: 20, color: '#1D4ED8' }} />
              <h3 style={{ fontSize: 16, fontWeight: 700, color: '#111827', margin: 0 }}>
                {status === 'approved' ? 'Resubmit Timesheet' : 'Submit Timesheet'}
              </h3>
            </div>
            <p style={{ fontSize: 13, color: '#6B7280', lineHeight: 1.5, marginBottom: 8 }}>
              {status === 'approved' ? 'Resubmit your' : 'Submit your'}{' '}
              <strong>{MONTH_NAMES[month - 1]} {year}</strong> timesheet for approval?
            </p>
            <p style={{ fontSize: 13, color: '#6B7280', marginBottom: 16 }}>
              Total recorded: <strong style={{ color: '#111827' }}>{fmtMins(entries.reduce((s,e) => s + e.hours_minutes, 0))}</strong>
              &nbsp;across&nbsp;<strong>{entries.length}</strong> {entries.length === 1 ? 'entry' : 'entries'}.
            </p>
            {/* The old warning — "once submitted, entries cannot be added or
                edited" — was true and permanent, because nothing could approve
                the sheet and nothing could take it back. Both halves of what
                can actually happen are stated instead, and the toast afterwards
                says which one did. */}
            <div style={{ fontSize: 12, color: '#1D4ED8', background: '#EFF6FF', borderRadius: 6, padding: '8px 12px', marginBottom: 20, lineHeight: 1.5 }}>
              <i className="fa-solid fa-circle-info" style={{ marginRight: 5 }} />
              If an approval workflow is set up, this goes to an approver and locks
              until they act or you withdraw it. If not, it is approved straight away
              and stays editable while the month is still open.
            </div>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button
                onClick={() => setConfirmSubmit(false)}
                style={{ padding: '8px 18px', borderRadius: 7, border: '1px solid #E5E7EB', background: '#fff', color: '#374151', fontWeight: 500, fontSize: 13, cursor: 'pointer' }}
              >
                Cancel
              </button>
              <button
                onClick={handleSubmit} disabled={submitting}
                style={{ padding: '8px 20px', borderRadius: 7, border: 'none', background: '#1D4ED8', color: '#fff', fontWeight: 600, fontSize: 13, cursor: submitting ? 'not-allowed' : 'pointer', display: 'flex', alignItems: 'center', gap: 7 }}
              >
                {submitting ? <><i className="fa-solid fa-spinner fa-spin" /> Submitting…</> : <><i className="fa-solid fa-check" /> Confirm Submit</>}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Withdraw confirmation modal ───────────────────────────────────── */}
      {confirmWithdraw && (
        <div
          style={{ position: 'fixed', inset: 0, zIndex: 9999, background: 'rgba(0,0,0,0.35)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}
          onClick={() => setConfirmWithdraw(false)}
        >
          <div
            style={{ background: '#fff', borderRadius: 12, padding: '28px 32px', width: 420, boxShadow: '0 8px 32px rgba(0,0,0,0.18)' }}
            onClick={e => e.stopPropagation()}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
              <i className="fa-solid fa-rotate-left" style={{ fontSize: 20, color: '#B45309' }} />
              <h3 style={{ fontSize: 16, fontWeight: 700, color: '#111827', margin: 0 }}>Withdraw Timesheet</h3>
            </div>
            <p style={{ fontSize: 13, color: '#6B7280', lineHeight: 1.5, marginBottom: 16 }}>
              Take your <strong>{MONTH_NAMES[month - 1]} {year}</strong> timesheet back from
              approval so you can change it? It returns to <strong>To Be Submitted</strong> and
              you will need to submit it again.
            </p>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button
                onClick={() => setConfirmWithdraw(false)}
                style={{ padding: '8px 18px', borderRadius: 7, border: '1px solid #E5E7EB', background: '#fff', color: '#374151', fontWeight: 500, fontSize: 13, cursor: 'pointer' }}
              >
                Cancel
              </button>
              <button
                onClick={handleWithdraw} disabled={withdrawing}
                style={{ padding: '8px 20px', borderRadius: 7, border: 'none', background: '#B45309', color: '#fff', fontWeight: 600, fontSize: 13, cursor: withdrawing ? 'not-allowed' : 'pointer', display: 'flex', alignItems: 'center', gap: 7 }}
              >
                {withdrawing ? <><i className="fa-solid fa-spinner fa-spin" /> Withdrawing…</> : <><i className="fa-solid fa-rotate-left" /> Confirm Withdraw</>}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Mini sub-components ──────────────────────────────────────────────────────

function Stat({ label, value, bold, color }: { label: string; value: string; bold?: boolean; color?: string }) {
  return (
    <div>
      <div style={{ fontSize: 10, color: '#9CA3AF', fontWeight: 500, marginBottom: 1, textTransform: 'uppercase', letterSpacing: '0.04em' }}>{label}</div>
      <div style={{ fontSize: 13, fontWeight: bold ? 700 : 600, color: color ?? '#111827' }}>{value}</div>
    </div>
  );
}

function Label({ children }: { children: React.ReactNode }) {
  return <label style={{ fontSize: 11, fontWeight: 600, color: '#374151', display: 'block', marginBottom: 3 }}>{children}</label>;
}

// ─── Shared styles ────────────────────────────────────────────────────────────

const navBtnSt: React.CSSProperties = {
  background: 'none', border: '1px solid #E5E7EB', borderRadius: 6,
  width: 26, height: 26, cursor: 'pointer', color: '#374151',
  display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
};


const selectSt: React.CSSProperties = {
  width: '100%', padding: '6px 8px', borderRadius: 6,
  border: '1px solid #D1D5DB', fontSize: 12, background: '#fff',
};

const inputSt: React.CSSProperties = {
  width: '100%', padding: '6px 8px', borderRadius: 6,
  border: '1px solid #D1D5DB', fontSize: 12, boxSizing: 'border-box',
};
