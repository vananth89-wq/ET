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

import { useState, useEffect, useCallback, useMemo } from 'react';
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

function getEntryLabel(ent: TimesheetEntry): string {
  const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
  const p = Array.isArray(ent.projects)   ? ent.projects[0]   : ent.projects;
  const tName = t?.name ?? (ent.entry_kind === 'project' ? '' : ent.entry_kind);
  return p?.name ? (tName ? `${tName} · ${p.name}` : p.name) : tName;
}

function getEntryCode(ent: TimesheetEntry): string {
  if (ent.entry_kind === 'project') {
    const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
    return p?.name ?? '';
  }
  const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
  return t?.code ?? '';
}

function getEntryBadge(ent: TimesheetEntry): { code: string; bg: string; color: string; projectName?: string } {
  if (ent.entry_kind === 'holiday') {
    return { code: 'HOL', bg: '#EDE9FE', color: '#5B21B6' };
  }
  if (ent.entry_kind === 'leave') {
    const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
    return { code: t?.code ?? 'LV', bg: '#FEF3C7', color: '#92400E' };
  }
  if (ent.entry_kind === 'time_type') {
    const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
    const code = t?.code ?? 'WK';
    if (ent.project_id) {
      const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
      return { code, bg: '#D1FAE5', color: '#065F46', projectName: p?.name };
    }
    return { code, bg: '#D1FAE5', color: '#065F46' };
  }
  // entry_kind === 'project'
  const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
  const name = p?.name ?? 'Project';
  const abbreviated = name.length > 4 ? name.slice(0, 4).toUpperCase() : name.toUpperCase();
  return { code: abbreviated, bg: '#DBEAFE', color: '#1E40AF', projectName: name };
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
        supabase.from('time_types').select('id, name, code, category, requires_project, is_active').eq('is_active', true).order('category').order('name'),
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
            <button
              onClick={() => setConfirmSubmit(true)}
              disabled={entries.length === 0}
              style={{
                marginLeft: 'auto', padding: '7px 18px', borderRadius: 7, border: 'none',
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
                  if (!day) return <div key={`b-${idx}`} style={{ minHeight: 108 }} />;

                  const dateStr    = isoDate(year, month, day);
                  const dow        = (startDow + day - 1) % 7;
                  const isToday    = dateStr === todayIso;
                  const isSelected = dateStr === selectedDate;
                  const dayEnts    = entriesByDate[dateStr] ?? [];
                  const dayPlanned = schedule ? plannedForDay(dow, schedule) : 0;
                  const isOffDay   = dayPlanned === 0;
                  const recorded   = dayEnts.reduce((s, e) => s + e.hours_minutes, 0);

                  return (
                    <div
                      key={dateStr}
                      onClick={() => { setSelectedDate(dateStr); setPanelOpen(true); cancelForm(); setExpandedEntries(new Set()); }}
                      style={{
                        minHeight: 108,
                        borderRadius: 10,
                        border: isSelected
                          ? '1.5px solid #3B82F6'
                          : isToday ? '1.5px solid #3B82F6'
                          : '1.5px solid #E5E7EB',
                        background: isSelected ? '#EFF6FF' : isOffDay ? '#F8FAFC' : '#fff',
                        boxShadow: isSelected ? '0 0 0 3px rgba(59,130,246,0.15)' : undefined,
                        cursor: isOffDay ? 'default' : 'pointer',
                        display: 'flex',
                        flexDirection: 'column',
                        overflow: 'hidden',
                        transition: 'box-shadow 0.15s, border-color 0.15s',
                      }}
                    >
                      {/* Day number */}
                      <div style={{ padding: '5px 6px 2px', flexShrink: 0 }}>
                        <span style={{
                          fontSize: 11, fontWeight: 700,
                          color: isToday ? '#fff' : isOffDay ? '#CBD5E1' : '#374151',
                          background: isToday ? '#3B82F6' : 'transparent',
                          borderRadius: '50%', width: 22, height: 22,
                          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                        }}>
                          {day}
                        </span>
                      </div>

                      {/* Entries area */}
                      {isOffDay ? (
                        <div style={{ flex: 1, padding: '2px 6px' }}>
                          <span style={{ fontSize: 8.5, color: '#CBD5E1', fontStyle: 'italic' }}>Non-working</span>
                        </div>
                      ) : dayEnts.length === 0 ? (
                        <div style={{
                          flex: 1, display: 'flex', flexDirection: 'column',
                          alignItems: 'center', justifyContent: 'center', gap: 2,
                          opacity: 0.5,
                        }}>
                          <span style={{ fontSize: 10, color: '#6B7280', fontWeight: 600 }}>＋ Add Time</span>
                          <span style={{ fontSize: 9, color: '#9CA3AF' }}>0 / {Math.round(dayPlanned/60)}h</span>
                        </div>
                      ) : (
                        <div style={{ flex: 1, padding: '0 5px 3px', overflow: 'hidden' }}>
                          {dayEnts.slice(0, 3).map(ent => {
                            const badge = getEntryBadge(ent);
                            const hrs   = Math.round(ent.hours_minutes / 60 * 10) / 10;
                            const label = badge.projectName ?? getEntryLabel(ent).split(' · ').pop() ?? '';
                            return (
                              <div
                                key={ent.id}
                                onClick={e => { e.stopPropagation(); setSelectedDate(dateStr); setPanelOpen(true); openEdit(ent); }}
                                style={{
                                  display: 'flex', alignItems: 'center', gap: 4,
                                  padding: '2px 3px', borderRadius: 5,
                                  transition: 'background 0.1s',
                                }}
                                onMouseEnter={e => (e.currentTarget.style.background = '#F0F9FF')}
                                onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}
                              >
                                <span style={{
                                  flexShrink: 0, fontSize: 7.5, fontWeight: 800,
                                  padding: '1.5px 4px', borderRadius: 3,
                                  background: badge.bg, color: badge.color,
                                  letterSpacing: '0.04em', whiteSpace: 'nowrap',
                                }}>
                                  {badge.code}
                                </span>
                                <span style={{
                                  fontSize: 10, color: '#374151', fontWeight: 600,
                                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', flex: 1,
                                  minWidth: 0,
                                }}>
                                  {label}
                                </span>
                                <span style={{ fontSize: 9.5, color: '#6B7280', fontWeight: 700, flexShrink: 0 }}>
                                  {hrs}h
                                </span>
                              </div>
                            );
                          })}
                          {dayEnts.length > 3 && (
                            <div
                              onClick={e => { e.stopPropagation(); setSelectedDate(dateStr); setPanelOpen(true); cancelForm(); }}
                              style={{ fontSize: 9, color: '#6366F1', fontWeight: 700, padding: '1px 3px', cursor: 'pointer' }}
                            >
                              +{dayEnts.length - 3} more
                            </div>
                          )}
                        </div>
                      )}

                      {/* Progress bar — only for working days */}
                      {!isOffDay && (
                        <div style={{ padding: '3px 6px 6px', flexShrink: 0 }}>
                          {(() => {
                            const pct     = dayPlanned > 0 ? Math.min(recorded / dayPlanned, 1) : 0;
                            const isOver  = dayPlanned > 0 && recorded > dayPlanned;
                            const isDone  = dayPlanned > 0 && recorded >= dayPlanned;
                            const planHr  = Math.round(dayPlanned / 60);
                            const recHr   = Math.round(recorded / 60 * 10) / 10;
                            const fillColor = dayEnts.length === 0 ? 'transparent'
                              : isOver  ? '#6366F1'
                              : isDone  ? '#10B981'
                              : '#34D399';
                            const lblColor = dayEnts.length === 0 ? '#D1D5DB'
                              : isOver  ? '#6366F1'
                              : isDone  ? '#10B981'
                              : '#1F2937';
                            const lblText = dayEnts.length === 0
                              ? `0 / ${planHr}h`
                              : isDone && !isOver
                                ? `${recHr} / ${planHr}h ✓`
                                : `${recHr} / ${planHr}h`;
                            return (
                              <>
                                <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 3 }}>
                                  <span style={{ fontSize: 13, fontWeight: 800, color: lblColor, lineHeight: 1 }}>
                                    {lblText}
                                  </span>
                                </div>
                                <div style={{ height: 5, background: '#F1F5F9', borderRadius: 99, overflow: 'hidden' }}>
                                  <div style={{
                                    height: '100%', borderRadius: 99,
                                    width: `${pct * 100}%`,
                                    background: fillColor,
                                    transition: 'width 0.4s ease-out',
                                  }} />
                                </div>
                              </>
                            );
                          })()}
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

              {/* Day stats */}
              <div style={{ display: 'flex', gap: 16, marginTop: 8 }}>
                {schedule && (() => {
                  const dow = new Date(selectedDate + 'T00:00:00').getDay();
                  const planned = plannedForDay(dow, schedule);
                  return planned > 0 ? (
                    <div style={{ fontSize: 11, color: '#6B7280' }}>
                      Planned: <strong style={{ color: '#374151' }}>{fmtMins(planned)}</strong>
                    </div>
                  ) : (
                    <div style={{ fontSize: 11, color: '#9CA3AF' }}>Non-working day</div>
                  );
                })()}
                {holidayByDate[selectedDate] && (
                  <div style={{ fontSize: 11, color: '#5B21B6', fontWeight: 600 }}>
                    🎉 {holidayByDate[selectedDate]}
                  </div>
                )}
                <div style={{ fontSize: 11, color: '#6B7280', marginLeft: 'auto' }}>
                  Recorded: <strong style={{ color: '#111827' }}>
                    {fmtMins(dayEntries.reduce((s,e) => s + e.hours_minutes, 0))}
                  </strong>
                </div>
              </div>
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
            <div style={{ flex: 1, padding: '10px 14px' }}>
              {dayEntries.length === 0 && !addingEntry && (
                <div style={{ color: '#9CA3AF', fontSize: 12, textAlign: 'center', padding: '20px 0' }}>
                  <i className="fa-regular fa-clock" style={{ fontSize: 20, display: 'block', marginBottom: 6 }} />
                  No entries for this day
                </div>
              )}

              {dayEntries.map(ent => {
                const badge    = getEntryBadge(ent);
                const isOpen   = expandedEntries.has(ent.id);
                const isEditing = editingEntry?.id === ent.id;
                return (
                  <div key={ent.id} style={{
                    border: isEditing ? '2px solid #2563EB' : '1px solid #E5E7EB',
                    borderRadius: 10, marginBottom: 7, overflow: 'hidden',
                    transition: 'box-shadow 0.15s',
                  }}>
                    {/* Top row: badge + code + hours + actions */}
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '9px 12px 4px', gap: 8 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                        <span style={{
                          fontSize: 8, fontWeight: 800, textTransform: 'uppercase',
                          letterSpacing: '0.05em', padding: '2px 6px', borderRadius: 4,
                          background: badge.bg, color: badge.color, whiteSpace: 'nowrap',
                        }}>
                          {badge.code}
                        </span>
                        <code style={{ fontSize: 9, color: '#9CA3AF', fontWeight: 700 }}>{getEntryCode(ent)}</code>
                        {ent.is_system_generated && (
                          <span style={{ fontSize: 9, color: '#9CA3AF', background: '#F3F4F6', padding: '1px 4px', borderRadius: 3 }}>auto</span>
                        )}
                      </div>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                        <span style={{ fontSize: 13, fontWeight: 800, color: '#3B82F6', marginRight: 2 }}>{fmtMins(ent.hours_minutes)}</span>
                        {editable && !ent.is_system_generated && (
                          <>
                            <button onClick={() => openEdit(ent)} style={iconBtnSt} title="Edit">
                              <i className="fa-solid fa-pen" style={{ fontSize: 10 }} />
                            </button>
                            <button onClick={() => handleDeleteEntry(ent.id)} style={{ ...iconBtnSt, color: '#DC2626', borderColor: '#FEE2E2' }} title="Delete">
                              <i className="fa-solid fa-trash" style={{ fontSize: 10 }} />
                            </button>
                          </>
                        )}
                      </div>
                    </div>

                    {/* Inline edit form — replaces card body when editing this entry */}
                    {isEditing ? (
                      <div style={{ borderTop: '1px solid #BFDBFE', background: '#EFF6FF', padding: '10px 12px 12px' }}>
                        {/* Time type picker */}
                        <div style={{ marginBottom: 8 }}>
                          <Label>{form.ttCategory === 'absence' ? 'Leave / Absence Type' : 'Attendance Type'}</Label>
                          <select value={form.typeId} onChange={e => { setForm(f => ({ ...f, typeId: e.target.value, projId: '' })); setFormErr(''); }} style={selectSt}>
                            <option value="">— Select —</option>
                            {timeTypes.filter(t => !form.ttCategory || t.category === form.ttCategory).map(t => (
                              <option key={t.id} value={t.id}>{t.name} ({t.code})</option>
                            ))}
                          </select>
                        </div>
                        {/* Project picker */}
                        {form.typeId && timeTypes.find(t => t.id === form.typeId)?.requires_project && (
                          <div style={{ marginBottom: 8 }}>
                            <Label>Project</Label>
                            <select value={form.projId} onChange={e => { setForm(f => ({ ...f, projId: e.target.value })); setFormErr(''); }} style={selectSt}>
                              <option value="">— Select —</option>
                              {projects.filter(p => !selectedDate || (p.start_date <= selectedDate && p.end_date >= selectedDate)).map(p => (
                                <option key={p.id} value={p.id}>{p.name}</option>
                              ))}
                            </select>
                          </div>
                        )}
                        {/* Activities */}
                        {(() => {
                          const selTT = timeTypes.find(t => t.id === form.typeId);
                          if (!selTT?.requires_project) return null;
                          return (
                            <div style={{ marginBottom: 8 }}>
                              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
                                <Label>Activities</Label>
                                <button type="button" onClick={() => setForm(f => ({ ...f, activities: [...f.activities, ''] }))} style={{ background: 'none', border: 'none', color: '#2563EB', fontSize: 11, fontWeight: 700, cursor: 'pointer', padding: '0 2px' }}>+ Add</button>
                              </div>
                              {form.activities.map((act, idx) => (
                                <div key={idx} style={{ display: 'flex', gap: 5, marginBottom: 5 }}>
                                  <div style={{ flex: 1 }}>
                                    <ActivityAutocomplete value={act} onChange={val => setForm(f => { const acts = [...f.activities]; acts[idx] = val; return { ...f, activities: acts }; })} onFavoriteToggle={handleFavoriteToggle} history={activityHistory} inputStyle={inputSt} />
                                  </div>
                                  {form.activities.length > 1 && (
                                    <button type="button" onClick={() => setForm(f => ({ ...f, activities: f.activities.filter((_, i) => i !== idx) }))} style={{ background: 'none', border: '1px solid #FEE2E2', borderRadius: 5, color: '#DC2626', cursor: 'pointer', padding: '0 7px', fontSize: 13 }}>×</button>
                                  )}
                                </div>
                              ))}
                            </div>
                          );
                        })()}
                        {/* Duration */}
                        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                          <div><Label>Hours</Label><input type="number" min="0" max="23" placeholder="0" value={form.hours} onChange={e => { setForm(f => ({ ...f, hours: e.target.value })); setFormErr(''); }} style={inputSt} /></div>
                          <div><Label>Minutes</Label><input type="number" min="0" max="59" placeholder="0" value={form.mins} onChange={e => { setForm(f => ({ ...f, mins: e.target.value })); setFormErr(''); }} style={inputSt} /></div>
                        </div>
                        {/* Notes */}
                        <div style={{ marginBottom: 10 }}>
                          <Label>Notes (optional)</Label>
                          <textarea rows={2} placeholder="Optional…" value={form.notes} onChange={e => setForm(f => ({ ...f, notes: e.target.value }))} style={{ ...inputSt, resize: 'vertical', fontFamily: 'inherit' }} />
                        </div>
                        {formErr && (
                          <div style={{ fontSize: 12, color: '#DC2626', marginBottom: 8, display: 'flex', gap: 5, alignItems: 'center' }}>
                            <i className="fa-solid fa-circle-exclamation" /> {formErr}
                          </div>
                        )}
                        <div style={{ display: 'flex', gap: 7 }}>
                          <button onClick={handleSaveEntry} disabled={saving} style={{ flex: 1, padding: '7px 0', borderRadius: 6, border: 'none', background: '#1D4ED8', color: '#fff', fontSize: 12, fontWeight: 600, cursor: saving ? 'not-allowed' : 'pointer', opacity: saving ? 0.7 : 1 }}>
                            {saving ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</> : 'Update'}
                          </button>
                          <button onClick={cancelForm} disabled={saving} style={{ padding: '7px 14px', borderRadius: 6, border: '1px solid #E5E7EB', background: '#fff', color: '#374151', fontSize: 12, cursor: 'pointer' }}>Cancel</button>
                        </div>
                      </div>
                    ) : (
                    <>
                    {/* Name row + chevron */}
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '2px 12px 9px', gap: 8 }}>
                      <span style={{ fontSize: 13, fontWeight: 700, color: '#1F2937', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1, minWidth: 0 }}>
                        {getEntryLabel(ent)}
                      </span>
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

              {/* Add new entry form — only shown when adding, not when editing (edit is inline in the card) */}
              {addingEntry && !editingEntry && (
                <div style={{
                  border: '1px dashed #93C5FD', borderRadius: 8, padding: 12,
                  background: '#EFF6FF', marginTop: 8,
                }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: '#1D4ED8', marginBottom: 10 }}>
                    {editingEntry ? 'Edit Entry' : 'Add Entry'}
                  </div>

                  {/* Time type picker — filtered by attendance or absence based on button clicked */}
                  <div style={{ marginBottom: 8 }}>
                    <Label>{form.ttCategory === 'absence' ? 'Leave / Absence Type' : 'Attendance Type'}</Label>
                    <select
                      value={form.typeId}
                      onChange={e => { setForm(f => ({ ...f, typeId: e.target.value, projId: '' })); setFormErr(''); }}
                      style={selectSt}
                    >
                      <option value="">— Select —</option>
                      {timeTypes
                        .filter(t => !form.ttCategory || t.category === form.ttCategory)
                        .map(t => (
                          <option key={t.id} value={t.id}>{t.name} ({t.code})</option>
                        ))
                      }
                    </select>
                  </div>

                  {/* Project picker — only when selected time type requires_project */}
                  {form.typeId && timeTypes.find(t => t.id === form.typeId)?.requires_project && (
                    <div style={{ marginBottom: 8 }}>
                      <Label>Project</Label>
                      <select
                        value={form.projId}
                        onChange={e => { setForm(f => ({ ...f, projId: e.target.value })); setFormErr(''); }}
                        style={selectSt}
                      >
                        <option value="">— Select —</option>
                        {projects
                          .filter(p => {
                            if (!selectedDate) return true;
                            return p.start_date <= selectedDate && p.end_date >= selectedDate;
                          })
                          .map(p => (
                            <option key={p.id} value={p.id}>{p.name}</option>
                          ))}
                      </select>
                    </div>
                  )}

                  {/* Activities — shown when selected time type requires a project */}
                  {(() => {
                    const selTT = timeTypes.find(t => t.id === form.typeId);
                    const show  = !!selTT?.requires_project;
                    if (!show) return null;
                    return (
                      <div style={{ marginBottom: 8 }}>
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
                    );
                  })()}

                  {/* Duration */}
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
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
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 8 }}>
                  <button
                    onClick={openAddAttendance}
                    style={{
                      width: '100%', padding: '11px 0', borderRadius: 8, border: 'none',
                      background: '#DCFCE7', color: '#166534',
                      fontSize: 13, fontWeight: 700, cursor: 'pointer',
                      display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
                    }}
                  >
                    🕐 Add Attendance
                  </button>
                  <button
                    onClick={openAddAbsence}
                    style={{
                      width: '100%', padding: '11px 0', borderRadius: 8, border: 'none',
                      background: '#FEF9C3', color: '#854D0E',
                      fontSize: 13, fontWeight: 700, cursor: 'pointer',
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

const iconBtnSt: React.CSSProperties = {
  background: 'none', border: '1px solid #E5E7EB', borderRadius: 4,
  padding: '3px 7px', cursor: 'pointer', color: '#374151',
};

const selectSt: React.CSSProperties = {
  width: '100%', padding: '6px 8px', borderRadius: 6,
  border: '1px solid #D1D5DB', fontSize: 12, background: '#fff',
};

const inputSt: React.CSSProperties = {
  width: '100%', padding: '6px 8px', borderRadius: 6,
  border: '1px solid #D1D5DB', fontSize: 12, boxSizing: 'border-box',
};
