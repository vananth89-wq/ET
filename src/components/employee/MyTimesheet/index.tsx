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
import { useAuth }                                    from '../../../contexts/AuthContext';
import { supabase }                                   from '../../../lib/supabase';
import ErrorBanner                                    from '../../shared/ErrorBanner';
import ActivityAutocomplete                           from './ActivityAutocomplete';
import type { ActivityHistoryItem }                   from './ActivityAutocomplete';

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
  // joined
  time_types?:  { name: string; code: string; category: string; requires_project: boolean } | { name: string; code: string; category: string; requires_project: boolean }[];
  projects?:    { name: string } | { name: string }[];
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
  is_active:        boolean;
}

interface Project {
  id:         string;
  name:       string;
  active:     boolean;
  start_date: string;
  end_date:   string;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const MONTH_NAMES = [
  'January','February','March','April','May','June',
  'July','August','September','October','November','December',
];
const DAY_ABBR = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

function pad2(n: number) { return String(n).padStart(2, '0'); }

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
  kind:    'ok' | 'bad';
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

// ─── Style constants ──────────────────────────────────────────────────────────


const STATUS_META: Record<string, { label: string; bg: string; color: string }> = {
  to_be_submitted: { label: 'To Be Submitted', bg: '#FFF7ED', color: '#C2410C' },
  to_be_approved:  { label: 'Pending Approval', bg: '#EFF6FF', color: '#1D4ED8' },
  approved:        { label: 'Approved',          bg: '#ECFDF5', color: '#065F46' },
};

// ─── Component ────────────────────────────────────────────────────────────────

export default function MyTimesheet() {
  const { employee } = useAuth();

  // Period
  const today = new Date();
  const [year,  setYear]  = useState(today.getFullYear());
  const [month, setMonth] = useState(today.getMonth() + 1);

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
  const [createErr,   setCreateErr]   = useState<{ msg: string; dates: string[] } | null>(null);
  const [creating,    setCreating]    = useState(false);

  // Copy Day — 'idle' | 'pick' (choose a source) | 'paste' (choose targets)
  const [copyMode,  setCopyMode]  = useState<'idle' | 'pick' | 'paste'>('idle');
  const [clipboard, setClipboard] = useState<{ from: string; entries: TimesheetEntry[] } | null>(null);

  // Toasts
  const [toasts, setToasts] = useState<Toast[]>([]);

  // Loading states
  const [loading,      setLoading]      = useState(true);
  const [error,        setError]        = useState<string | null>(null);
  const [saving,       setSaving]       = useState(false);
  const [submitting,   setSubmitting]   = useState(false);

  // Panel
  const [selectedDate,   setSelectedDate]   = useState<string | null>(null);
  const [panelOpen,      setPanelOpen]      = useState(false);
  const [addingEntry,    setAddingEntry]    = useState(false);
  const [editingEntry,   setEditingEntry]   = useState<TimesheetEntry | null>(null);
  const [confirmSubmit,  setConfirmSubmit]  = useState(false);

  // Hovered calendar day - drives the cell hover state and the empty-day CTA
  const [hoverDate, setHoverDate] = useState<string | null>(null);

  // Expand/collapse per entry card in the panel
  const [expandedEntries, setExpandedEntries] = useState<Set<string>>(new Set());

  // Activity history for smart autocomplete
  const [activityHistory, setActivityHistory] = useState<ActivityHistoryItem[]>([]);

  // Entry form
  const emptyForm = { kind: 'time_type' as 'time_type' | 'project', typeId: '', projId: '', hours: '', mins: '', notes: '', activities: [''], ttCategory: '' as '' | 'attendance' | 'absence' };
  const [form,    setForm]    = useState(emptyForm);
  const [formErr, setFormErr] = useState('');

  // ── Fetch employee code + reference data once ───────────────────────────
  useEffect(() => {
    if (!employee?.id) return;
    (async () => {
      const [empRes, ttRes, prRes, actRes] = await Promise.all([
        supabase.from('employees').select('employee_id').eq('id', employee.id).single(),
        supabase.from('time_types').select('id, name, code, category, requires_project, allows_half_day, is_active').eq('is_active', true).eq('is_system_managed', false).order('category').order('name'),
        supabase.from('projects').select('id, name, active, start_date, end_date').eq('active', true).order('name'),
        supabase.rpc('get_employee_activities', { p_employee_id: employee.id }),
      ]);
      if (empRes.data) setEmpCode(empRes.data.employee_id ?? '');
      if (ttRes.data)  setTimeTypes(ttRes.data as TimeType[]);
      if (prRes.data)  setProjects(prRes.data as Project[]);
      if (actRes.data) setActivityHistory(actRes.data as ActivityHistoryItem[]);
    })();
  }, [employee?.id]);

  // ── Load / auto-create header + entries for the period ─────────────────
  const loadPeriod = useCallback(async () => {
    if (!employee?.id || !empCode) return;
    setLoading(true);
    setError(null);

    const periodDate = `${year}-${pad2(month)}-01`;

    // 1. Find existing header
    let { data: hdr, error: hErr } = await supabase
      .from('timesheet_headers')
      .select('id, employee_id, period, external_code, status, work_schedule_id, holiday_calendar_id, planned_minutes, recorded_minutes, submitted_at, approved_at')
      .eq('employee_id', employee.id)
      .eq('period', periodDate)
      .maybeSingle();

    if (hErr) { setError(hErr.message); setLoading(false); return; }

    let headerId: string;

    if (!hdr) {
      // 2a. Need work schedule + holiday calendar from employee_employment
      const { data: emp } = await supabase
        .from('employee_employment')
        .select('work_schedule_id, holiday_calendar_id, department_id, departments(name)')
        .eq('employee_id', employee.id)
        .is('effective_to', null)
        .single();

      const wsId  = emp?.work_schedule_id    ?? null;
      const hcId  = emp?.holiday_calendar_id ?? null;
      const deptId   = emp?.department_id ?? null;
      const deptName = (emp?.departments as any)?.name ?? null;

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
        const { data: hdData } = await supabase
          .from('time_holidays')
          .select('holiday_date, time_holidays_pool:holiday_id(holiday_name)')
          .eq('calendar_id', hcId)
          .gte('holiday_date', periodDate)
          .lte('holiday_date', isoDate(year, month, daysInMonth(year, month)));
        if (hdData) {
          hdDates = hdData.map((h: any) => h.holiday_date);
        }
      }

      if (ws) plannedMins = calcPlannedMinutes(year, month, ws, hdDates);

      // 2d. Create header
      const externalCode = `${empCode}_${year}${pad2(month)}`;
      const { data: created, error: cErr } = await supabase
        .from('timesheet_headers')
        .insert({
          employee_id:         employee.id,
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
        .select('id, employee_id, period, external_code, status, work_schedule_id, holiday_calendar_id, planned_minutes, recorded_minutes, submitted_at, approved_at')
        .single();

      if (cErr) { setError(cErr.message); setLoading(false); return; }
      hdr = created;

      if (ws) { setSchedule(ws); }
      setHolidays(
        hdDates.map((d) => ({ holiday_date: d, holiday_name: `Holiday` }))
      );
    }

    setHeader(hdr as TimesheetHeader);
    headerId = hdr!.id;

    // 3. Load work schedule if not already loaded
    if (!schedule && hdr!.work_schedule_id) {
      const { data: wsData } = await supabase
        .from('time_work_schedules')
        .select('id, name, code, start_day_of_week, time_work_schedule_lines(day_number, planned_minutes)')
        .eq('id', hdr!.work_schedule_id)
        .single();
      if (wsData) {
        setSchedule({
          id: wsData.id, name: wsData.name, code: wsData.code,
          start_day_of_week: wsData.start_day_of_week,
          lines: (wsData.time_work_schedule_lines ?? []) as ScheduleLine[],
        });
      }
    }

    // 4. Load holiday calendar entries for this period
    if (!holidays.length && hdr!.holiday_calendar_id) {
      const { data: hdData } = await supabase
        .from('time_holidays')
        .select('holiday_date, holiday_pool:holiday_id(holiday_name)')
        .eq('calendar_id', hdr!.holiday_calendar_id)
        .gte('holiday_date', periodDate)
        .lte('holiday_date', isoDate(year, month, daysInMonth(year, month)));
      if (hdData) {
        setHolidays(hdData.map((h: any) => ({
          holiday_date: h.holiday_date,
          holiday_name: (Array.isArray(h.holiday_pool) ? h.holiday_pool[0] : h.holiday_pool)?.holiday_name ?? 'Holiday',
        })));
      }
    }

    // 5. Load entries
    const { data: ents, error: eErr } = await supabase
      .from('timesheet_entries')
      .select(`
        id, header_id, entry_date, entry_kind, project_id, time_type_id,
        hours_minutes, notes, activities, is_system_generated,
        time_types ( name, code, category, requires_project ),
        projects ( name )
      `)
      .eq('header_id', headerId)
      .order('entry_date')
      .order('created_at');

    if (eErr) { setError(eErr.message); setLoading(false); return; }
    setEntries((ents ?? []) as unknown as TimesheetEntry[]);
    setLoading(false);
  }, [employee?.id, empCode, year, month]);

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

  // ── Toasts ────────────────────────────────────────────────────────────
  const toastSeq = useRef(0);
  function pushToast(msg: string, kind: 'ok' | 'bad' = 'ok', undoIds?: string[]) {
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

  async function reloadEntries() {
    if (!header) return;
    const { data: ents } = await supabase
      .from('timesheet_entries')
      .select(`id, header_id, entry_date, entry_kind, project_id, time_type_id, hours_minutes, notes, activities, is_system_generated, time_types(name,code,category,requires_project), projects(name)`)
      .eq('header_id', header.id)
      .order('entry_date').order('created_at');
    const list = (ents ?? []) as unknown as TimesheetEntry[];
    setEntries(list);
    setHeader(h => h ? { ...h, recorded_minutes: list.reduce((s, e) => s + e.hours_minutes, 0) } : h);
  }

  // ── Date-scope rules — shared by Create and Copy ──────────────────────
  // A date may receive attendance when it is inside this month, not in the
  // future, and empty. Non-working days ARE allowed: weekend work is real work.
  function dateBlockedReason(dateStr: string): string | null {
    if (dateStr.slice(0, 7) !== `${year}-${pad2(month)}`) return 'Outside this timesheet month';
    if (dateStr > todayIso)                               return 'Future date — attendance cannot be recorded in advance';
    if ((entriesByDate[dateStr] ?? []).length > 0)        return 'Already has attendance';
    return null;
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
        setFormErr(`${proj.name} is not active on ${culprit ? fmtChip(culprit) : 'one of the selected dates'} — pick a project again.`);
      }
    }
  }

  async function submitCreate() {
    if (!header) return;
    const dates = [...createDates].sort();
    if (!dates.length) { setFormErr('Select at least one date.'); return; }
    if (!form.typeId)  { setFormErr('Please select a time type.'); return; }

    const tt = timeTypes.find(t => t.id === form.typeId);
    if (tt?.requires_project && !form.projId) { setFormErr('Please select a project for this time type.'); return; }

    const hrs = parseInt(form.hours || '0', 10);
    const mins = parseInt(form.mins || '0', 10);
    if (isNaN(hrs) || isNaN(mins) || (hrs === 0 && mins === 0)) { setFormErr('Duration must be greater than 0.'); return; }

    setCreating(true); setFormErr(''); setCreateErr(null);
    const acts = form.activities.map(a => a.trim()).filter(Boolean);
    const { data, error: rpcErr } = await supabase.rpc('bulk_create_timesheet_entries', {
      p_header_id: header.id,
      p_dates: dates,
      p_entry: {
        time_type_id:  form.typeId,
        project_id:    tt?.requires_project ? form.projId : null,
        hours_minutes: hrs * 60 + mins,
        notes:         form.notes.trim() || null,
        activities:    acts.length ? acts : null,
      },
    });
    setCreating(false);

    if (rpcErr) { setFormErr(rpcErr.message); return; }
    if (!data?.ok) {
      // Dates come back on the scope errors so the user can drop them in one click
      if (Array.isArray(data?.dates) && data.dates.length) setCreateErr({ msg: data.message, dates: data.dates });
      else setFormErr(data?.message ?? 'Could not create entries.');
      return;
    }

    setCreateOpen(false);
    await reloadEntries();
    if (acts.length && employee?.id) supabase.rpc('record_activity_usages', { p_employee_id: employee.id, p_activity_names: acts });
    pushToast(
      `Created on ${data.created} ${data.created === 1 ? 'day' : 'days'} — ${dates.map(fmtChip).join(', ')}`,
      'ok',
      data.entry_ids,
    );
  }

  // ── Copy Day ──────────────────────────────────────────────────────────
  function exitCopyMode() { setCopyMode('idle'); setClipboard(null); }

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
    const skipped = (entriesByDate[dateStr] ?? []).length - work.length;
    setClipboard({ from: dateStr, entries: work });
    setCopyMode('paste');
    pushToast(`Copied ${fmtChip(dateStr)} — ${work.length} ${work.length === 1 ? 'entry' : 'entries'}${skipped ? ' (leave not copied)' : ''}`);
  }

  async function pasteInto(dateStr: string) {
    if (!header || !clipboard) return;
    const blocked = dateBlockedReason(dateStr);
    if (blocked) {
      pushToast(blocked === 'Already has attendance'
        ? 'Attendance already exists for this day. Paste is only allowed into empty days.'
        : `${blocked}.`, 'bad');
      return;
    }
    const rows = clipboard.entries.map(e => ({
      header_id:     header.id,
      entry_date:    dateStr,
      entry_kind:    e.entry_kind,
      time_type_id:  e.time_type_id,
      project_id:    e.project_id,
      hours_minutes: e.hours_minutes,
      notes:         e.notes,
      activities:    e.activities,
    }));
    const { data, error: insErr } = await supabase.from('timesheet_entries').insert(rows).select('id');
    if (insErr) { pushToast(insErr.message, 'bad'); return; }
    await supabase.rpc('recalc_timesheet_recorded_minutes', { p_header_id: header.id });
    await reloadEntries();
    pushToast(`Pasted into ${fmtChip(dateStr)} — ${rows.length} ${rows.length === 1 ? 'entry' : 'entries'}`,
      'ok', (data ?? []).map(r => r.id));
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
    setSelectedDate(null); setPanelOpen(false);
    setSchedule(null); setHolidays([]);
    setAddingEntry(false); setEditingEntry(null);
    setForm(emptyForm); setFormErr('');
    setExpandedEntries(new Set());
  }
  function prevMonth() {
    month === 1 ? goToPeriod(year - 1, 12) : goToPeriod(year, month - 1);
  }
  function nextMonth() {
    month === 12 ? goToPeriod(year + 1, 1) : goToPeriod(year, month + 1);
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
  const editable   = status === 'to_be_submitted';
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
    setFormErr('');
    setAddingEntry(true);
  }
  function openAddAttendance() { openAdd({ kind: 'time_type', ttCategory: 'attendance' }); }
  function openAddAbsence()    { openAdd({ kind: 'time_type', ttCategory: 'absence' }); }

  function openEdit(ent: TimesheetEntry) {
    setEditingEntry(ent);
    const totalM = ent.hours_minutes;
    const acts = ent.activities && ent.activities.length > 0 ? ent.activities : [''];
    const tt = timeTypes.find(t => t.id === ent.time_type_id);
    setForm({
      kind:       'time_type',
      typeId:     ent.time_type_id ?? '',
      projId:     ent.project_id  ?? '',
      hours:      String(Math.floor(totalM / 60)),
      mins:       String(totalM % 60),
      notes:      ent.notes ?? '',
      activities: acts,
      ttCategory: (tt?.category === 'absence' ? 'absence' : 'attendance') as '' | 'attendance' | 'absence',
    });
    setFormErr('');
    setAddingEntry(true);
  }

  function cancelForm() {
    setAddingEntry(false);
    setEditingEntry(null);
    setForm(emptyForm);
    setFormErr('');
  }

  async function handleSaveEntry() {
    if (!header || !selectedDate) return;

    // Validate
    if (!form.typeId) { setFormErr('Please select a time type.'); return; }
    const hrs  = parseInt(form.hours || '0', 10);
    const mins = parseInt(form.mins  || '0', 10);
    if (isNaN(hrs) || isNaN(mins) || (hrs === 0 && mins === 0)) {
      setFormErr('Duration must be greater than 0.'); return;
    }
    if (mins < 0 || mins > 59) { setFormErr('Minutes must be 0–59.'); return; }
    if (hrs < 0 || hrs > 23)   { setFormErr('Hours must be 0–23.'); return; }

    const totalMins = hrs * 60 + mins;
    const selectedTimeType = timeTypes.find(t => t.id === form.typeId);
    const needsProject = !!selectedTimeType?.requires_project;
    if (needsProject && !form.projId) { setFormErr('Please select a project for this time type.'); return; }
    // Map absence → 'leave', else 'time_type' (project entries always stay time_type with project_id set)
    const entryKind: TimesheetEntry['entry_kind'] =
      selectedTimeType?.category === 'absence' ? 'leave' : 'time_type';

    // Collect non-empty activities
    const showActivities = needsProject;
    const cleanActivities = showActivities
      ? form.activities.map(a => a.trim()).filter(a => a.length > 0)
      : null;

    setSaving(true);
    setFormErr('');

    let newEntries: TimesheetEntry[];

    if (editingEntry) {
      // Update existing
      const { error: updErr } = await supabase
        .from('timesheet_entries')
        .update({
          entry_kind:    entryKind,
          time_type_id:  form.typeId || null,
          project_id:    needsProject ? form.projId || null : null,
          hours_minutes: totalMins,
          notes:         form.notes.trim() || null,
          activities:    cleanActivities && cleanActivities.length > 0 ? cleanActivities : null,
        })
        .eq('id', editingEntry.id);

      if (updErr) { setFormErr(updErr.message); setSaving(false); return; }
    } else {
      // Insert new
      const { error: insErr } = await supabase
        .from('timesheet_entries')
        .insert({
          header_id:     header.id,
          entry_date:    selectedDate,
          entry_kind:    entryKind,
          time_type_id:  form.typeId || null,
          project_id:    needsProject ? form.projId || null : null,
          hours_minutes: totalMins,
          notes:         form.notes.trim() || null,
          activities:    cleanActivities && cleanActivities.length > 0 ? cleanActivities : null,
          created_by:    (await supabase.auth.getUser()).data.user?.id ?? null,
        });

      if (insErr) { setFormErr(insErr.message); setSaving(false); return; }
    }

    // Record activity usages in history (fire-and-forget)
    if (cleanActivities && cleanActivities.length > 0 && employee?.id) {
      supabase.rpc('record_activity_usages', {
        p_employee_id:    employee.id,
        p_activity_names: cleanActivities,
      }).then(({ data }) => {
        // Refresh local history so autocomplete is up-to-date immediately
        if (data?.ok) {
          supabase.rpc('get_employee_activities', { p_employee_id: employee!.id })
            .then(({ data: hist }) => { if (hist) setActivityHistory(hist as ActivityHistoryItem[]); });
        }
      });
    }

    // Reload entries then sync recorded_minutes
    const { data: ents } = await supabase
      .from('timesheet_entries')
      .select(`id, header_id, entry_date, entry_kind, project_id, time_type_id, hours_minutes, notes, activities, is_system_generated, time_types(name,code,category,requires_project), projects(name)`)
      .eq('header_id', header.id)
      .order('entry_date').order('created_at');

    newEntries = (ents ?? []) as unknown as TimesheetEntry[];
    setEntries(newEntries);
    await syncRecordedMinutes(header.id, newEntries);
    setHeader(h => h ? { ...h, recorded_minutes: newEntries.reduce((s,e) => s + e.hours_minutes, 0) } : h);

    setSaving(false);
    cancelForm();
  }

  async function handleDeleteEntry(entryId: string) {
    if (!header) return;
    const { error: delErr } = await supabase.from('timesheet_entries').delete().eq('id', entryId);
    if (delErr) { setError(delErr.message); return; }

    const newEntries = entries.filter(e => e.id !== entryId);
    setEntries(newEntries);
    await syncRecordedMinutes(header.id, newEntries);
    setHeader(h => h ? { ...h, recorded_minutes: newEntries.reduce((s,e) => s + e.hours_minutes, 0) } : h);
    if (editingEntry?.id === entryId) cancelForm();
  }

  // ── Activity favourite toggle ────────────────────────────────────────
  async function handleFavoriteToggle(name: string, _currentIsFav: boolean): Promise<{ ok: boolean; message?: string }> {
    if (!employee?.id) return { ok: false, message: 'Not logged in.' };
    const { data } = await supabase.rpc('toggle_activity_favorite', {
      p_employee_id:   employee.id,
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

  // ── Submit for approval ──────────────────────────────────────────────
  async function handleSubmit() {
    if (!header) return;
    setSubmitting(true);
    const { error: updErr } = await supabase
      .from('timesheet_headers')
      .update({ status: 'to_be_approved', submitted_at: new Date().toISOString() })
      .eq('id', header.id);
    setSubmitting(false);
    if (updErr) { setError(updErr.message); return; }
    setConfirmSubmit(false);
    setHeader(h => h ? { ...h, status: 'to_be_approved', submitted_at: new Date().toISOString() } : h);
  }

  // ─────────────────────────────────────────────────────────────────────
  // Render
  // ─────────────────────────────────────────────────────────────────────

  // A project may be chosen only if its validity window covers every date given.
  // One date (day panel) and many dates (Create modal) use the same rule.
  function projectActiveOn(p: Project, dates: string[]) {
    return dates.every(d => (!p.start_date || p.start_date <= d) && (!p.end_date || p.end_date >= d));
  }

  // ── Entry form fields ─────────────────────────────────────────────────
  // ONE definition, rendered in three places: the inline edit form inside an
  // entry card, the Add Entry form at the panel bottom, and the Create modal.
  // Callers own their own wrapper and action buttons — only the fields live here.
  //   projectDates — only offer projects active on EVERY one of these dates.
  //                  The day panel passes one; the Create modal passes all the
  //                  dates picked, so the list is the intersection. Empty = no filter.
  function renderEntryFields(opts?: { projectDates?: string[]; gap?: number }) {
    const gap          = opts?.gap ?? 8;
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

        {/* Activities — shown when the selected time type requires a project */}
        {selTT?.requires_project && (
          <div style={{ marginBottom: gap }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
              <Label>Activities</Label>
              <button
                type="button"
                onClick={() => setForm(f => ({ ...f, activities: [...f.activities, ''] }))}
                style={{ background: 'none', border: 'none', color: '#2563EB', fontSize: 11, fontWeight: 700, cursor: 'pointer', padding: '0 2px' }}
              >
                + Add
              </button>
            </div>
            {form.activities.map((act, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 5, marginBottom: 5 }}>
                <div style={{ flex: 1 }}>
                  <ActivityAutocomplete
                    value={act}
                    onChange={val => setForm(f => {
                      const acts = [...f.activities];
                      acts[idx] = val;
                      return { ...f, activities: acts };
                    })}
                    onFavoriteToggle={handleFavoriteToggle}
                    history={activityHistory}
                    inputStyle={inputSt}
                  />
                </div>
                {form.activities.length > 1 && (
                  <button
                    type="button"
                    onClick={() => setForm(f => ({ ...f, activities: f.activities.filter((_, i) => i !== idx) }))}
                    style={{ background: 'none', border: '1px solid #FEE2E2', borderRadius: 5, color: '#DC2626', cursor: 'pointer', padding: '0 7px', fontSize: 13 }}
                  >
                    ×
                  </button>
                )}
              </div>
            ))}
          </div>
        )}

        {/* Duration */}
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

        {formErr && (
          <div style={{ fontSize: 12, color: '#DC2626', marginBottom: 8, display: 'flex', gap: 5, alignItems: 'center' }}>
            <i className="fa-solid fa-circle-exclamation" /> {formErr}
          </div>
        )}
      </>
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

        {/* Period nav + title row */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          <button onClick={prevMonth} style={navBtnSt}>
            <i className="fa-solid fa-chevron-left" style={{ fontSize: 10 }} />
          </button>
          <h1 style={{ fontSize: 16, fontWeight: 700, color: '#111827', margin: 0, whiteSpace: 'nowrap' }}>
            Time Sheet for {MONTH_NAMES[month - 1]} 1 – {totalDays}, {year}
          </h1>
          <button onClick={nextMonth} style={navBtnSt}>
            <i className="fa-solid fa-chevron-right" style={{ fontSize: 10 }} />
          </button>

          <span style={{ padding: '3px 12px', borderRadius: 99, fontSize: 12, fontWeight: 600, background: statusM.bg, color: statusM.color }}>
            {statusM.label}
          </span>

          {editable && (
            <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8 }}>
              <button
                onClick={() => { exitCopyMode(); openCreate(); }}
                style={{
                  padding: '7px 14px', borderRadius: 7, border: '1px solid #D0D5DD',
                  background: '#fff', color: '#1F2937', fontWeight: 600, fontSize: 13,
                  cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6,
                }}
                title="Create attendance on one or more days (C)"
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

          {editable && (
            <button
              onClick={() => setConfirmSubmit(true)}
              disabled={entries.length === 0}
              style={{
                padding: '7px 18px', borderRadius: 7, border: 'none',
                background: entries.length === 0 ? '#E5E7EB' : '#1D4ED8',
                color: entries.length === 0 ? '#9CA3AF' : '#fff',
                fontWeight: 600, fontSize: 13, cursor: entries.length === 0 ? 'not-allowed' : 'pointer',
                display: 'flex', alignItems: 'center', gap: 6,
              }}
            >
              <i className="fa-solid fa-paper-plane" /> Submit for Approval
            </button>
          )}
        </div>

        {/* Stats row */}
        <div style={{ display: 'flex', gap: 28, marginTop: 10, flexWrap: 'wrap' }}>
          <Stat label="Employee" value={employee?.name ?? '—'} bold />
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
      </div>

      {error && <div style={{ padding: '8px 24px' }}><ErrorBanner message={error} onRetry={loadPeriod} /></div>}

      {/* ── Body ─────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>

        {/* ── Calendar ──────────────────────────────────────────────────── */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '16px 20px 40px' }}>
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
                  const isHovered  = hoverDate === dateStr && !isOffDay;

                  const holidayName = holidayByDate[dateStr];
                  const isHoliday   = !!holidayName || dayEnts.some(e => e.entry_kind === 'holiday');
                  // A holiday can still be worked. Only take over the cell body when
                  // nothing was logged, otherwise real entries would be hidden.
                  const workEnts    = dayEnts.filter(e => e.entry_kind !== 'holiday');
                  const holidayOnly = isHoliday && workEnts.length === 0;

                  // Full-day absence: every entry is leave AND it covers the plan.
                  // A half day of leave stays a normal working day with a leave row.
                  const leaveName = (!isHoliday && dayEnts.length > 0 && dayPlanned > 0
                                     && dayEnts.every(e => e.entry_kind === 'leave')
                                     && recorded >= dayPlanned)
                    ? getCellLabel(dayEnts[0])
                    : null;

                  // Metric shows for any logged day, and for a PAST working day with
                  // nothing logged (-> "0/8h"). Never future, weekend, holiday or leave.
                  const showMetric = !isOffDay && !holidayOnly && !leaveName
                                     && (dayEnts.length > 0 || isPast);

                  // Copy Day roles. Non-working days participate — weekend work is real work.
                  const copySrcOk  = copyMode === 'pick'  && attendanceOf(dateStr).length > 0;
                  const copySrcNo  = copyMode === 'pick'  && !copySrcOk;
                  const pasteOk    = copyMode === 'paste' && !dateBlockedReason(dateStr);
                  const pasteNo    = copyMode === 'paste' && !pasteOk && clipboard?.from !== dateStr;
                  const isClipSrc  = clipboard?.from === dateStr;
                  // On a worked holiday the schedule's planned hours are not a target,
                  // so show the bare total rather than an "x / 8h" shortfall.
                  const metricColor = isHoliday          ? '#7C3AED'
                                    : status === 'over'  ? '#DC2626'
                                    : status === 'done'  ? '#059669'
                                    : status === 'empty' ? '#D97706'
                                    :                      '#2563EB';

                  // Bar segments — derived from the same `status` as the metric above
                  const segments: { w: number; c: string }[] =
                      isHoliday          ? [{ w: 100, c: '#8B5CF6' }]
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
                      tabIndex={isOffDay ? -1 : 0}
                      aria-label={`${day} ${MONTH_NAMES[month - 1]}, ${
                        isOffDay   ? 'non-working day'
                        : isHoliday ? `public holiday${holidayName ? ' — ' + holidayName : ''}`
                        : leaveName ? leaveName
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
                          : isOffDay    ? 'transparent'
                          : isSelected ? '#2563EB'
                          : isHovered  ? '#D0D5DD'
                          : isHoliday  ? '#EDE4FE'
                          : leaveName  ? '#DBEAFE'
                          :              '#E5E7EB'}`,
                        background: pasteOk    ? '#F6FEFB'
                                  : copySrcOk  ? '#F8FBFF'
                                  : isOffDay   ? '#F4F5F7'
                                  : isHoliday  ? '#FAF5FF'
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
                          fontSize: 12, fontWeight: isOffDay ? 500 : 600, lineHeight: 1,
                          fontVariantNumeric: 'tabular-nums',
                          color: isToday ? '#fff'
                               : isOffDay ? '#C3C8D0'
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
                              {isHoliday ? 'h' : `/${Math.round(dayPlanned / 60)}h`}
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
                        ) : isOffDay ? null : dayEnts.length === 0 ? (
                          <div style={{ height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                            <span style={{
                              fontSize: 11, fontWeight: 600, color: '#98A2B3',
                              opacity: (isHovered || isSelected) ? 1 : 0,
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

                      {/* Status bar — one rounded pill, same source of truth as the metric */}
                      {!isOffDay && (
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

                if (planned === 0) {
                  return (
                    <div style={{ marginTop: 10, fontSize: 12, color: '#9CA3AF', fontStyle: 'italic' }}>
                      {holidayByDate[selectedDate]
                        ? <span>🎉 {holidayByDate[selectedDate]}</span>
                        : 'Non-working day'}
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
                    {holidayByDate[selectedDate] && (
                      <div style={{ fontSize: 11, color: '#5B21B6', fontWeight: 600, marginTop: 6 }}>
                        🎉 {holidayByDate[selectedDate]}
                      </div>
                    )}
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
              {dayEntries.length === 0 && !addingEntry && (
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
                return (
                  <div key={ent.id} style={{
                    border: isEditing ? '2px solid #2563EB' : '1px solid #E5E7EB',
                    borderRadius: 10, overflow: 'hidden',
                    background: '#fff',
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
                          <button onClick={handleSaveEntry} disabled={saving} style={{ flex: 1, padding: '7px 0', borderRadius: 6, border: 'none', background: '#1D4ED8', color: '#fff', fontSize: 12, fontWeight: 600, cursor: saving ? 'not-allowed' : 'pointer', opacity: saving ? 0.7 : 1 }}>
                            {saving ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</> : 'Update'}
                          </button>
                          <button onClick={cancelForm} disabled={saving} style={{ padding: '7px 14px', borderRadius: 6, border: '1px solid #E5E7EB', background: '#fff', color: '#374151', fontSize: 12, cursor: 'pointer' }}>Cancel</button>
                        </div>
                      </div>
                    ) : (
                    <>
                    {/* Collapsible detail */}
                    {isOpen && (
                      <div style={{ borderTop: '1px solid #F3F4F6', background: '#FAFAFA', padding: '10px 12px 12px' }}>
                        {ent.activities && ent.activities.length > 0 && (
                          <div style={{ marginBottom: ent.notes ? 8 : 0 }}>
                            <div style={{ fontSize: 9, fontWeight: 800, color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.08em', marginBottom: 6 }}>
                              Activities
                            </div>
                            {ent.activities.map((a, i) => (
                              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 7, padding: '2px 0' }}>
                                <span style={{ width: 5, height: 5, borderRadius: '50%', background: '#34D399', flexShrink: 0, display: 'inline-block' }} />
                                <span style={{ fontSize: 12, color: '#374151', fontWeight: 500 }}>{a}</span>
                              </div>
                            ))}
                          </div>
                        )}
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

                  {renderEntryFields({ projectDates: selectedDate ? [selectedDate] : [] })}

                  <div style={{ display: 'flex', gap: 7 }}>
                    <button
                      onClick={handleSaveEntry} disabled={saving}
                      style={{ flex: 1, padding: '7px 0', borderRadius: 6, border: 'none', background: '#1D4ED8', color: '#fff', fontSize: 12, fontWeight: 600, cursor: saving ? 'not-allowed' : 'pointer', opacity: saving ? 0.7 : 1 }}
                    >
                      {saving
                        ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                        : editingEntry ? 'Update' : 'Save Entry'}
                    </button>
                    <button
                      onClick={cancelForm} disabled={saving}
                      style={{ padding: '7px 14px', borderRadius: 6, border: '1px solid #E5E7EB', background: '#fff', color: '#374151', fontSize: 12, cursor: 'pointer' }}
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              )}

              {/* Add Attendance / Add Absence buttons */}
              {editable && !addingEntry && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: dayEntries.length > 0 ? 6 : 8 }}>
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
                </div>
              )}

              {/* Locked notice */}
              {!editable && (
                <div style={{ marginTop: 14, padding: '8px 12px', background: '#F9FAFB', borderRadius: 6, fontSize: 12, color: '#6B7280', textAlign: 'center' }}>
                  <i className="fa-solid fa-lock" style={{ marginRight: 5 }} />
                  {statusM.label} — entries are locked.
                </div>
              )}
            </div>
          </div>
        )}
      </div>

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
            : `✓ Copied ${clipboard ? fmtChip(clipboard.from) : ''} (${clipboard?.entries.length ?? 0} ${clipboard?.entries.length === 1 ? 'entry' : 'entries'}) — click any empty day to paste`}
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
            fontSize: 13, color: '#fff', background: t.kind === 'bad' ? '#B42318' : '#111827',
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

            <div style={{ padding: '18px 22px 4px', maxHeight: '62vh', overflowY: 'auto' }}>
              {createErr && (
                <div style={{ background: '#FEF3F2', border: '1px solid #FECDCA', color: '#912018', borderRadius: 9, padding: '11px 13px', fontSize: 12.5, marginBottom: 14 }}>
                  <strong style={{ display: 'block', marginBottom: 3 }}>{createErr.msg}</strong>
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
                </div>
              )}

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
                    <span>Greyed after today — cannot be recorded in advance</span>
                    <span>Weekends and holidays can be selected</span>
                  </div>
                </div>
              </div>

              {/* Attendance form — the same fields the day panel renders.
                  Projects are intersected across every selected date. */}
              <div style={{ border: '1px solid #BFDBFE', borderRadius: 10, background: '#F8FBFF', padding: 14, marginBottom: 4 }}>
                {renderEntryFields({ projectDates: [...createDates].sort(), gap: 10 })}
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
              <h3 style={{ fontSize: 16, fontWeight: 700, color: '#111827', margin: 0 }}>Submit Timesheet</h3>
            </div>
            <p style={{ fontSize: 13, color: '#6B7280', lineHeight: 1.5, marginBottom: 8 }}>
              Submit your <strong>{MONTH_NAMES[month - 1]} {year}</strong> timesheet for approval?
            </p>
            <p style={{ fontSize: 13, color: '#6B7280', marginBottom: 16 }}>
              Total recorded: <strong style={{ color: '#111827' }}>{fmtMins(entries.reduce((s,e) => s + e.hours_minutes, 0))}</strong>
              &nbsp;across&nbsp;<strong>{entries.length}</strong> {entries.length === 1 ? 'entry' : 'entries'}.
            </p>
            <div style={{ fontSize: 12, color: '#D97706', background: '#FFF7ED', borderRadius: 6, padding: '8px 12px', marginBottom: 20 }}>
              <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 5 }} />
              Once submitted, entries cannot be added or edited.
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
