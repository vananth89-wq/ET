/**
 * Timesheet approval — the month model.
 *
 * One place that turns time_approval_payload() into everything the approval
 * screens draw: the calendar, the day × project matrix, the weekly rollup, the
 * project split, and the list of things an approver should look at before
 * saying yes.
 *
 * Deliberately independent of ExportPDF/utils/dataTransforms.ts. That module
 * builds from MyTimesheet's in-memory state, which an approver never has; this
 * one builds from a single RPC payload. They agree on vocabulary — planned,
 * recorded, over, missing, week off, not due — because the approver and the
 * employee must be reading the same month.
 */

// The Summary report's own label heuristic, imported rather than reimplemented
// so the screen and the PDF cannot drift on how AMPTJ, WISAYAH and QCC print.
import { displayLabel } from '../../components/employee/MyTimesheet/ExportPDF/utils/summaryMatrix';
export { displayLabel };

// ── Payload shape (mirrors time_approval_payload, mig 742) ───────────────────

export interface TsPayloadEntry {
  id:                     string;
  entry_date:             string;          // YYYY-MM-DD
  entry_kind:             'project' | 'time_type' | 'holiday' | 'leave';
  hours_minutes:          number;
  notes:                  string | null;
  /** Names only. Kept for anything already reading it; MIG 745 added the split. */
  activities:             string[];
  /** MIG 745: the same activities WITH their minutes. Absent on an older API. */
  /** `billable` since mig 826 — true / false, or null where the question was
   *  never asked (which is every activity outside a billable project). */
  activity_rows?:         { name: string; minutes: number; billable?: boolean | null }[] | null;
  project_id:             string | null;
  project_name:           string | null;
  /** Mig 826. What the BOOKED project is worth, decided server-side by
   *  project_billability(). Null where there is no booked project — including
   *  cross-project help (801), whose hours are not chargeable to the project
   *  its label names. Absent on a payload from before 826. */
  project_class?:         'billable' | 'non_billable' | 'unclassified' | null;
  time_type_id:           string | null;
  time_type_name:         string | null;
  is_system_generated:    boolean;
  created_at:             string;
  updated_at:             string;
  /** 'ADDED' | 'EDITED' when the row post-dates the last approval, else null. */
  changed_after_approval: 'ADDED' | 'EDITED' | null;
  /** Minutes as at the last approval, when this entry has changed since (mig 743). */
  previous_hours_minutes: number | null;
}

/** An entry that no longer exists, recovered from timesheet_entry_audit. */
export interface TsRemoved {
  id:             string;
  entry_id:       string;
  entry_date:     string;
  entry_kind:     string;
  hours_minutes:  number;
  notes:          string | null;
  activities:     string[];
  /** MIG 745. Always minutes 0 -- a deleted entry's activity rows went with it. */
  /** Deleted rows never carry an answer: an entry's activity rows cascade with
   *  it and the audit row kept only the legacy names. Absent, i.e. null. */
  activity_rows?: { name: string; minutes: number; billable?: boolean | null }[] | null;
  project_name:   string | null;
  time_type_name: string | null;
  removed_at:     string;
  removed_by:     string | null;
}

export interface TsPayload {
  ok:    boolean;
  error?: string;
  header: {
    id:                   string;
    employee_id:          string;
    period:               string;          // YYYY-MM-01
    external_code:        string;
    status:               'to_be_submitted' | 'to_be_approved' | 'approved';
    planned_minutes:      number;
    recorded_minutes:     number;
    submitted_at:         string | null;
    approved_at:          string | null;
    workflow_instance_id: string | null;
    department_name:      string | null;
    country_code:         string | null;
    /** MIG 745. The stamp that catches a deletion, which leaves no row to mark. */
    content_changed_at?:  string | null;
    last_approved_at:     string | null;
  };
  employee: { id: string; name: string | null; employee_code: string | null;
              job_title: string | null; manager_name: string | null } | null;
  holiday_calendar: { id: string; name: string | null } | null;
  schedule: { id: string; name: string | null; code: string | null;
              max_daily_minutes: number | null; start_day_of_week: number | null;
              lines: { day_number: number; planned_minutes: number }[] } | null;
  holidays: { date: string; name: string }[];
  entries:  TsPayloadEntry[];
  /** Deleted since the last approval. Empty before mig 743 deploys. */
  removed:  TsRemoved[];
  deletions_visible: boolean;
}

// ── Derived model ────────────────────────────────────────────────────────────

export type DayKind = 'work' | 'weekoff' | 'holiday' | 'leave' | 'missing' | 'future';
export type Tone    = 'met' | 'short' | 'over' | 'none';

export interface MonthColumn {
  key:   string;
  label: string;
  color: string;
  /** Leave and other absence types sort to the right of real project work. */
  isAbsence: boolean;
  /** Backed by a project rather than a bare time type. "By project & activity"
   *  and the donut's project palette both need this — without it, Training
   *  reads as a project because it merely is not an absence. */
  isProject: boolean;
}

export interface MonthDay {
  date:      string;             // YYYY-MM-DD
  day:       number;             // 1..31
  dow:       number;             // 0=Sun
  dowLabel:  string;
  planned:   number;             // minutes
  recorded:  number;             // minutes
  byColumn:  Record<string, number>;
  entries:   TsPayloadEntry[];
  kind:      DayKind;
  tone:      Tone;
  holidayName: string | null;
  /** Entries deleted from this day since the last approval. */
  removed:   TsRemoved[];
  /** Any entry on this day added, edited or deleted since the last approval. */
  changed:   boolean;
}

export interface MonthWeek {
  n:        number;
  fromDay:  number;
  toDay:    number;
  planned:  number;
  recorded: number;
  byColumn: Record<string, number>;
  days:     MonthDay[];
  tag:      string;
  tagTone:  'neutral' | 'over' | 'progress' | 'good' | 'bad';
  holidays: number;
}

export interface Exception {
  id:    'changed' | 'removed' | 'missing' | 'weekoff' | 'overday' | 'overcap' | 'leave' | 'inprogress';
  tone:  'red' | 'amber' | 'blue' | 'violet';
  icon:  string;
  /** Short label for the chip. */
  text:  string;
  /** Longer sentence for the decision checklist. */
  detail: string;
  /** Only these are worth ticking before approving. */
  checkable: boolean;
}

export interface MonthModel {
  periodLabel:  string;
  days:         MonthDay[];
  weeks:        MonthWeek[];
  columns:      MonthColumn[];
  planned:      number;
  recorded:     number;
  over:         number;
  utilisation:  number;
  workingDays:  number;
  daysRecorded: number;
  leaveDays:    number;
  holidayCount: number;
  byColumn:     Record<string, number>;
  /** Project → activity totals, plus the unitemised remainder. */
  byProject:    { key: string; label: string; color: string; days: number;
                  minutes: number; share: number;
                  rows: { label: string; minutes: number; unitemised: boolean }[] }[];
  exceptions:   Exception[];
  changedCount: number;
  removedCount: number;
  /** Minutes that were signed off and are no longer on the sheet. */
  removedMinutes: number;
  isReapproval: boolean;
  /** Last day of the month that has already happened; 0 when the month is over. */
  todayDay:     number;
}

// ── Palette ──────────────────────────────────────────────────────────────────
// Fixed order so a project keeps its colour between the calendar, the matrix
// and the donut on the same screen.
const PALETTE = [
  '#2F6BE8', '#7C4DE0', '#0E9F6E', '#F0A020', '#DB2777',
  '#0891B2', '#65A30D', '#9333EA', '#E11D48', '#0F766E',
];
const ABSENCE_COLOR     = '#93C5FD';
/** Bare time types — Training, Induction — are not projects and must not take a
 *  project's colour, or the donut invites the wrong reading. */
const NON_PROJECT_COLOR = '#94A3B8';

/**
 * ALLCAPS project codes are shouted; words are not.
 *
 * Re-exported from the Summary report's own helper rather than reimplemented,
 * so the screen and the PDF cannot drift on how AMPTJ, WISAYAH and QCC print.
 */


const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

export function hm(minutes: number): string {
  const m = Math.max(0, Math.round(minutes));
  return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`;
}

export function hLabel(minutes: number): string {
  if (!minutes) return '0h';
  return minutes % 60 === 0 ? `${minutes / 60}h` : `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

/** Local YYYY-MM-DD — never toISOString, which shifts across the date line. */
function iso(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// ── Builder ──────────────────────────────────────────────────────────────────

export function buildMonth(p: TsPayload, now: Date = new Date()): MonthModel {
  const [y, mo] = p.header.period.split('-').map(Number);
  const first   = new Date(y, mo - 1, 1);
  const nDays   = new Date(y, mo, 0).getDate();

  // schedule: day_number 1..7 where 1 = Sunday, so day_number = getDay() + 1
  const plannedByDow = new Map<number, number>();
  (p.schedule?.lines ?? []).forEach(l => plannedByDow.set(l.day_number - 1, l.planned_minutes));

  const holidayByDate = new Map(p.holidays.map(h => [h.date, h.name]));

  // ── columns ────────────────────────────────────────────────────────────────
  // Deliberately identical to ExportPDF/utils/summaryMatrix.ts columnFor(). This
  // table is the Summary report on screen; if the two disagree about what a
  // column is, one of them is lying to an approver.
  //
  // entry_kind is NOT consulted for the project test, and that is the whole
  // point. Migration 705 made project and time-type entries mutually exclusive;
  // 715 relaxed the constraint so a time type with requires_project carries a
  // project too, and 719 records the convention that followed -- "an absence is
  // 'leave', everything else is 'time_type' (a project entry is 'time_type'
  // with BOTH ids set)". Nothing writes entry_kind = 'project' any more, so
  // testing for it collapsed every project into one column named after its
  // time type: a month of AMPTJ, Wisayah and QCC printed as a single "Work".
  //
  // All leave collapses into ONE column, matching the report: four columns
  // saying "not at work" crowd out the projects, which are what the table
  // exists to show. Page 3 of the export still names each leave type.
  const colTotals = new Map<string, { label: string; isAbsence: boolean; isProject: boolean; minutes: number }>();
  const columnFor = (e: TsPayloadEntry): { key: string; label: string; isAbsence: boolean; isProject: boolean } | null => {
    if (e.entry_kind === 'holiday') return null;
    if (e.entry_kind === 'leave')   return { key: 'leave', label: 'Leave', isAbsence: true,  isProject: false };
    if (e.project_id)               return { key: `p:${e.project_id}`,
                                             label: e.project_name ?? 'Project',
                                             isAbsence: false, isProject: true };
    if (e.time_type_id)             return { key: `t:${e.time_type_id}`,
                                             label: e.time_type_name ?? 'Time type',
                                             isAbsence: false, isProject: false };
    return { key: 'other', label: 'Other', isAbsence: false, isProject: false };
  };

  p.entries.forEach(e => {
    const c = columnFor(e);
    if (!c) return;
    const cur = colTotals.get(c.key)
             ?? { label: c.label, isAbsence: c.isAbsence, isProject: c.isProject, minutes: 0 };
    cur.minutes += e.hours_minutes;
    colTotals.set(c.key, cur);
  });

  // Projects first in size order, then bare time types, then leave last. The
  // palette walks projects only, so a Training column cannot take a colour an
  // approver would read as a project.
  let projectIdx = 0;
  const columns: MonthColumn[] = [...colTotals.entries()]
    .sort((a, b) =>
      (Number(a[1].isAbsence) - Number(b[1].isAbsence)) ||
      (Number(b[1].isProject) - Number(a[1].isProject)) ||
      (b[1].minutes - a[1].minutes))
    .map(([key, v]) => ({
      key,
      label: displayLabel(v.label),
      isAbsence: v.isAbsence,
      isProject: v.isProject,
      color: v.isAbsence  ? ABSENCE_COLOR
           : v.isProject  ? PALETTE[projectIdx++ % PALETTE.length]
                          : NON_PROJECT_COLOR,
    }));

  // ── days ───────────────────────────────────────────────────────────────────
  const entriesByDate = new Map<string, TsPayloadEntry[]>();
  p.entries.forEach(e => {
    const list = entriesByDate.get(e.entry_date) ?? [];
    list.push(e);
    entriesByDate.set(e.entry_date, list);
  });

  // Removals are attached to the day they were taken from, so the daily detail
  // shows the gap where the hours used to be rather than in a separate list the
  // approver has to reconcile by date themselves.
  const removedByDate = new Map<string, TsRemoved[]>();
  (p.removed ?? []).forEach(r => {
    const list = removedByDate.get(r.entry_date) ?? [];
    list.push(r);
    removedByDate.set(r.entry_date, list);
  });

  // "Today" only bites inside this month. A past month has nothing not-yet-due;
  // a future month has nothing missing.
  const monthStart = first;
  const monthEnd   = new Date(y, mo - 1, nDays);
  const todayDay =
    now < monthStart ? 0 :
    now > monthEnd   ? nDays :
    now.getDate();

  const days: MonthDay[] = [];
  for (let d = 1; d <= nDays; d++) {
    const date  = new Date(y, mo - 1, d);
    const dow   = date.getDay();
    const key   = iso(date);
    const es    = entriesByDate.get(key) ?? [];
    const holidayName = holidayByDate.get(key) ?? null;

    const schedPlanned = plannedByDow.get(dow) ?? 0;
    const planned      = holidayName ? 0 : schedPlanned;
    const recorded     = es.reduce((a, e) => a + e.hours_minutes, 0);

    const byColumn: Record<string, number> = {};
    es.forEach(e => {
      const c = columnFor(e);
      if (!c) return;
      byColumn[c.key] = (byColumn[c.key] ?? 0) + e.hours_minutes;
    });

    const isFuture   = d > todayDay;
    const leaveOnly  = recorded > 0 && es.every(e => e.entry_kind === 'leave');
    const isMissing  = planned > 0 && recorded === 0 && !isFuture;

    let kind: DayKind;
    if (holidayName)        kind = 'holiday';
    else if (isMissing)     kind = 'missing';
    else if (planned === 0) kind = 'weekoff';
    else if (isFuture && recorded === 0) kind = 'future';
    else if (leaveOnly)     kind = 'leave';
    else                    kind = 'work';

    let tone: Tone = 'none';
    if (recorded > 0) {
      if (planned === 0)            tone = 'over';   // week off or holiday worked
      else if (recorded > planned)  tone = 'over';
      else if (recorded === planned) tone = 'met';
      else                          tone = 'short';
    } else if (isMissing) {
      tone = 'over';
    }

    const removedHere = removedByDate.get(key) ?? [];

    days.push({
      date: key, day: d, dow, dowLabel: DOW[dow],
      planned, recorded, byColumn, entries: es, kind, tone,
      holidayName,
      removed: removedHere,
      changed: es.some(e => !!e.changed_after_approval) || removedHere.length > 0,
    });
  }

  // ── weeks (Sun–Sat, matching the calendar) ────────────────────────────────
  const weeks: MonthWeek[] = [];
  let cur: MonthWeek | null = null;
  days.forEach(day => {
    if (day.dow === 0 || !cur) {
      cur = { n: weeks.length + 1, fromDay: day.day, toDay: day.day, planned: 0,
              recorded: 0, byColumn: {}, days: [], tag: '', tagTone: 'neutral', holidays: 0 };
      weeks.push(cur);
    }
    cur.days.push(day);
    cur.toDay    = day.day;
    cur.planned  += day.planned;
    cur.recorded += day.recorded;
    if (day.kind === 'holiday') cur.holidays++;
    Object.entries(day.byColumn).forEach(([k, v]) => { cur!.byColumn[k] = (cur!.byColumn[k] ?? 0) + v; });
  });
  weeks.forEach(w => {
    const allFuture  = w.days.every(d => d.day > todayDay);
    const someFuture = w.days.some(d => d.day > todayDay);
    if (w.planned === 0)          { w.tag = 'Non-working';       w.tagTone = 'neutral'; }
    else if (allFuture)           { w.tag = 'Not yet due';       w.tagTone = 'neutral'; }
    else if (w.recorded > w.planned) { w.tag = `Over by ${hLabel(w.recorded - w.planned)}`; w.tagTone = 'over'; }
    else if (someFuture)          { w.tag = 'In progress';       w.tagTone = 'progress'; }
    else if (w.recorded === 0)    { w.tag = 'Nothing recorded';  w.tagTone = 'bad'; }
    else if (w.recorded < w.planned) { w.tag = 'Partial';        w.tagTone = 'progress'; }
    else                          { w.tag = 'Complete';          w.tagTone = 'good'; }
  });

  // ── totals ────────────────────────────────────────────────────────────────
  const byColumn: Record<string, number> = {};
  days.forEach(d => Object.entries(d.byColumn).forEach(([k, v]) => { byColumn[k] = (byColumn[k] ?? 0) + v; }));

  const planned      = days.reduce((a, d) => a + d.planned, 0);
  const recorded     = days.reduce((a, d) => a + d.recorded, 0);
  const workingDays  = days.filter(d => d.planned > 0).length;
  const daysRecorded = days.filter(d => d.recorded > 0).length;
  const leaveDays    = days.filter(d => d.entries.some(e => e.entry_kind === 'leave')).length;

  const missingDays  = days.filter(d => d.kind === 'missing');
  const weekOffWorked = days.filter(d => d.planned === 0 && d.recorded > 0 && d.kind !== 'holiday');
  const holidayWorked = days.filter(d => d.kind === 'holiday' && d.recorded > 0);
  const overDays     = days.filter(d => d.planned > 0 && d.recorded > d.planned);

  // Overtime, on the verdict already settled for the PDF: anything beyond the
  // day's schedule counts, and a day with no schedule is all overtime.
  const over = days.reduce((a, d) => {
    if (d.planned === 0) return a + d.recorded;
    return a + Math.max(0, d.recorded - d.planned);
  }, 0);

  const cap = p.schedule?.max_daily_minutes ?? null;
  const overCapDays = cap ? days.filter(d => d.recorded > cap) : [];

  // ── by project & activity ─────────────────────────────────────────────────
  // isProject, not !isAbsence: before the columnFor fix a bare time type such as
  // Training satisfied "not an absence" and was listed here as though it were a
  // project, with an activity breakdown it can never have.
  const byProject = columns
    .filter(c => c.isProject && byColumn[c.key])
    .map(c => {
      const acts = new Map<string, number>();
      const dayset = new Set<string>();
      let itemised = 0;
      p.entries.forEach(e => {
        const col = columnFor(e);
        if (!col || col.key !== c.key) return;
        dayset.add(e.entry_date);
        const names = (e.activities ?? []).filter(Boolean);
        if (!names.length) return;
        // The entry's minutes are not split per activity anywhere in the data,
        // so an entry with two activities credits each with the whole entry and
        // would double-count. Credit the first named activity only, and let the
        // remainder fall into "Not itemised" — an honest under-claim beats a
        // total that does not add up.
        acts.set(names[0], (acts.get(names[0]) ?? 0) + e.hours_minutes);
        itemised += e.hours_minutes;
      });
      const total = byColumn[c.key];
      const rows = [...acts.entries()]
        .sort((a, b) => b[1] - a[1])
        .map(([label, minutes]) => ({ label, minutes, unitemised: false }));
      if (total - itemised > 0) rows.push({ label: 'Not itemised', minutes: total - itemised, unitemised: true });
      return { key: c.key, label: c.label, color: c.color, days: dayset.size,
               minutes: total, share: Math.round((total / (recorded || 1)) * 100), rows };
    })
    .sort((a, b) => b.minutes - a.minutes);

  // ── exceptions ────────────────────────────────────────────────────────────
  const changedCount = p.entries.filter(e => !!e.changed_after_approval).length;
  const isReapproval = changedCount > 0 && !!p.header.last_approved_at;
  const notDue       = nDays - todayDay;
  const list = (ds: MonthDay[]) => ds.map(d => d.day).join(', ');

  const removedList    = p.removed ?? [];
  const removedMinutes = removedList.reduce((a, r) => a + r.hours_minutes, 0);
  const removedDays    = [...new Set(removedList.map(r => Number(r.entry_date.slice(8, 10))))].sort((a, b) => a - b);

  const exceptions: Exception[] = [];

  // Loudest first, and above the changed-entry line: everything else on this
  // list is visible somewhere in the tables below. A removal is the one thing
  // that is only knowable from here.
  if (removedList.length) exceptions.push({
    id: 'removed', tone: 'red', icon: 'fa-trash-can', checkable: true,
    text: `${removedList.length} ${removedList.length === 1 ? 'entry' : 'entries'} removed — ${removedDays.join(', ')}`,
    detail: `${removedList.length} ${removedList.length === 1 ? 'entry' : 'entries'} totalling ` +
            `${hLabel(removedMinutes)} ${removedList.length === 1 ? 'was' : 'were'} deleted after the last approval ` +
            `(${removedDays.join(', ')}) — the hours are no longer on this sheet`,
  });

  if (isReapproval) exceptions.push({
    id: 'changed', tone: 'amber', icon: 'fa-pen', checkable: true,
    text: `${changedCount} entries changed since the last approval`,
    detail: `${changedCount} ${changedCount === 1 ? 'entry' : 'entries'} recorded after the approval of ` +
            `${new Date(p.header.last_approved_at!).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}` +
            ` — ${list(days.filter(d => d.changed))}`,
  });
  if (missingDays.length) exceptions.push({
    id: 'missing', tone: 'red', icon: 'fa-circle-exclamation', checkable: true,
    text: `${missingDays.length} missing day${missingDays.length > 1 ? 's' : ''} — ${list(missingDays)}`,
    detail: `${missingDays.length} working day${missingDays.length > 1 ? 's have' : ' has'} no entry — ` +
            `${list(missingDays)}, ${hLabel(missingDays.reduce((a, d) => a + d.planned, 0))} scheduled in total`,
  });
  if (weekOffWorked.length) exceptions.push({
    id: 'weekoff', tone: 'amber', icon: 'fa-calendar-week', checkable: true,
    text: `Week off worked — ${list(weekOffWorked)}`,
    detail: `${hLabel(weekOffWorked.reduce((a, d) => a + d.recorded, 0))} recorded on days with no schedule ` +
            `(${list(weekOffWorked)}) — all of it counts as overtime`,
  });
  if (holidayWorked.length) exceptions.push({
    id: 'weekoff', tone: 'amber', icon: 'fa-star', checkable: true,
    text: `Holiday worked — ${list(holidayWorked)}`,
    detail: `Time recorded on a public holiday (${list(holidayWorked)})`,
  });
  if (overCapDays.length) exceptions.push({
    id: 'overcap', tone: 'red', icon: 'fa-gauge-high', checkable: true,
    text: `Over the daily cap — ${list(overCapDays)}`,
    detail: `${list(overCapDays)} exceed the ${hLabel(cap!)} daily maximum on this schedule`,
  });
  else if (overDays.length) exceptions.push({
    id: 'overday', tone: 'amber', icon: 'fa-gauge-high', checkable: true,
    text: `Over the day's schedule — ${list(overDays)}`,
    detail: `${list(overDays)} recorded more than the day's planned hours`,
  });
  if (leaveDays) exceptions.push({
    id: 'leave', tone: 'blue', icon: 'fa-umbrella-beach', checkable: false,
    text: `${leaveDays} leave day${leaveDays > 1 ? 's' : ''}`,
    detail: `${leaveDays} day${leaveDays > 1 ? 's' : ''} recorded as leave`,
  });
  if (notDue > 0) exceptions.push({
    id: 'inprogress', tone: 'violet', icon: 'fa-hourglass-half', checkable: false,
    text: `Month in progress — ${notDue} day${notDue > 1 ? 's' : ''} not yet due`,
    detail: `${notDue} day${notDue > 1 ? 's are' : ' is'} still in the future and cannot be missing`,
  });

  return {
    periodLabel: first.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' }),
    days, weeks, columns,
    planned, recorded, over,
    utilisation: planned ? Math.round((recorded / planned) * 100) : 0,
    workingDays, daysRecorded, leaveDays,
    holidayCount: p.holidays.length,
    byColumn, byProject, exceptions, changedCount, isReapproval, todayDay,
    removedCount: removedList.length, removedMinutes,
  };
}
