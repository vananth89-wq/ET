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
 *                                 non-project entries need time_type_id; project_id optional (requires_project types)
 *   employee_employment.work_schedule_id    → assigned work schedule
 *   employee_employment.holiday_calendar_id → assigned holiday calendar
 *   time_work_schedule_lines.day_number     → 1–7 (day 1 = schedule.start_day_of_week)
 */

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useAuth }                                    from '../../../contexts/AuthContext';
import { supabase }                                   from '../../../lib/supabase';
import ErrorBanner                                    from '../../shared/ErrorBanner';
import ActivityAutocomplete from './ActivityAutocomplete';
import type { ActivityHistoryItem } from './ActivityAutocomplete';

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
  is_system_generated: boolean;
  activities:  string[] | null;
  // joined
  time_types?:  { name: string; code: string; category: string } | { name: string; code: string; category: string }[];
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
  id:        string;
  name:      string;
  code:      string;
  category:         'attendance' | 'absence';
  requires_project: boolean;
  is_active:        boolean;
}

interface Project {
  id:         string;
  name:       string;
  start_date: string;   // 'YYYY-MM-DD'
  end_date:   string;   // 'YYYY-MM-DD'
  active:     boolean;
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

function fmtMinsFull(mins: number): string {
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return `${pad2(h)}:${pad2(m)}`;
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
  if (ent.entry_kind === 'project') {
    const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
    return p?.name ?? 'Project';
  }
  const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
  const label = t?.name ?? ent.entry_kind;
  // For time_type entries that also carry a project (requires_project types)
  if (ent.project_id && ent.entry_kind === 'time_type') {
    const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
    if (p?.name) return `${label} · ${p.name}`;
  }
  return label;
}

function getEntryCode(ent: TimesheetEntry): string {
  if (ent.entry_kind === 'project') {
    const p = Array.isArray(ent.projects) ? ent.projects[0] : ent.projects;
    return p?.name ?? '';
  }
  const t = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
  return t?.code ?? '';
}

// ─── Style constants ──────────────────────────────────────────────────────────

const KIND_CHIP: Record<string, { bg: string; color: string }> = {
  project:   { bg: '#DBEAFE', color: '#1E40AF' },
  time_type: { bg: '#D1FAE5', color: '#065F46' },
  holiday:   { bg: '#EDE9FE', color: '#5B21B6' },
  leave:     { bg: '#FEF3C7', color: '#92400E' },
};

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

  // Activity history
  const [activityHistory, setActivityHistory] = useState<ActivityHistoryItem[]>([]);

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

  // Entry form
  const emptyForm = { kind: 'time_type' as 'time_type' | 'project', typeId: '', projId: '', activities: [''] as string[], hours: '', mins: '', notes: '' };
  const [form,    setForm]    = useState(emptyForm);
  const [formErr, setFormErr] = useState('');
  const [formCategory, setFormCategory] = useState<'attendance' | 'absence'>('attendance');

  // ── Fetch employee code + reference data once ───────────────────────────
  useEffect(() => {
    if (!employee?.id) return;
    (async () => {
      const [empRes, ttRes, prRes] = await Promise.all([
        supabase.from('employees').select('employee_id').eq('id', employee.id).single(),
        supabase.from('time_types').select('id, name, code, category, requires_project, is_active').eq('is_active', true).order('category').order('name'),
        supabase.from('projects').select('id, name, start_date, end_date, active').eq('active', true).order('name'),
      ]);
      if (empRes.data) setEmpCode(empRes.data.employee_id ?? '');
      if (ttRes.data)  setTimeTypes(ttRes.data as TimeType[]);
      if (prRes.data)  setProjects(prRes.data as Project[]);
      // Load activity history for this employee
      const { data: actData } = await supabase.rpc('get_employee_activities', { p_employee_id: employee.id });
      if (actData) setActivityHistory(actData as ActivityHistoryItem[]);
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
      // effective-dating uses '9999-12-31' as the "open-ended" sentinel, not NULL
      const { data: emp } = await supabase
        .from('employee_employment')
        .select('work_schedule_id, holiday_calendar_id, department_id, departments(name)')
        .eq('employee_id', employee.id)
        .eq('is_active', true)
        .eq('effective_to', '9999-12-31')
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
        time_types ( name, code, category ),
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
  function openAdd(category: 'attendance' | 'absence') {
    setEditingEntry(null);
    setForm({ ...emptyForm, kind: 'time_type' });
    setFormCategory(category);
    setFormErr('');
    setAddingEntry(true);
  }

  function openEdit(ent: TimesheetEntry) {
    setEditingEntry(ent);
    const totalM = ent.hours_minutes;
    setForm({
      kind:   'time_type',
      typeId: ent.time_type_id ?? '',
      projId: ent.project_id  ?? '',
      hours:  String(Math.floor(totalM / 60)),
      mins:   String(totalM % 60),
      notes:      ent.notes ?? '',
      activities: (ent.activities && ent.activities.length > 0) ? [...ent.activities] : [''],
    });
    setFormErr('');
    const _tt = Array.isArray(ent.time_types) ? ent.time_types[0] : ent.time_types;
    const _cat: 'attendance' | 'absence' =
      _tt?.category === 'absence' ? 'absence' : 'attendance';
    setFormCategory(_cat);
    setAddingEntry(true);
  }

  function cancelForm() {
    setAddingEntry(false);
    setEditingEntry(null);
    setForm(emptyForm);
    setFormErr('');
  }

  async function handleFavoriteToggle(name: string, currentIsFav: boolean): Promise<{ ok: boolean; message?: string }> {
    if (!employee?.id) return { ok: false };
    const { data } = await supabase.rpc('toggle_activity_favorite', {
      p_employee_id:   employee.id,
      p_activity_name: name,
    });
    if (data?.ok) {
      setActivityHistory(prev =>
        prev.map(a => a.activity_name === name ? { ...a, is_favorite: !currentIsFav } : a)
      );
    }
    return data ?? { ok: false };
  }

  async function handleSaveEntry() {
    if (!header || !selectedDate) return;

    // Validate
    if (!form.typeId) { setFormErr('Please select a time type.'); return; }
    const _selType = timeTypes.find(t => t.id === form.typeId);
    if (_selType?.requires_project && !form.projId) { setFormErr('Please select a project — required for this attendance type.'); return; }
    const _activities = form.activities.map(a => a.trim()).filter(Boolean);
    if (_selType?.requires_project && form.projId && _activities.length === 0) { setFormErr('Please add at least one activity.'); return; }
    const hrs  = parseInt(form.hours || '0', 10);
    const mins = parseInt(form.mins  || '0', 10);
    if (isNaN(hrs) || isNaN(mins) || (hrs === 0 && mins === 0)) {
      setFormErr('Duration must be greater than 0.'); return;
    }
    if (mins < 0 || mins > 59) { setFormErr('Minutes must be 0–59.'); return; }
    if (hrs < 0 || hrs > 23)   { setFormErr('Hours must be 0–23.'); return; }

    const totalMins = hrs * 60 + mins;
    const selectedTimeType = _selType;
    // Map absence → 'leave', attendance → 'time_type', project → 'project'
    const entryKind: TimesheetEntry['entry_kind'] =
      selectedTimeType?.category === 'absence' ? 'leave' : 'time_type';

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
          project_id:    (selectedTimeType?.requires_project && form.projId) ? form.projId : null,
          activities:    (selectedTimeType?.requires_project && form.projId) ? _activities : null,
          hours_minutes: totalMins,
          notes:         form.notes.trim() || null,
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
          project_id:    (selectedTimeType?.requires_project && form.projId) ? form.projId : null,
          activities:    (selectedTimeType?.requires_project && form.projId) ? _activities : null,
          hours_minutes: totalMins,
          notes:         form.notes.trim() || null,
          created_by:    (await supabase.auth.getUser()).data.user?.id ?? null,
        });

      if (insErr) { setFormErr(insErr.message); setSaving(false); return; }
    }

    // Reload entries then sync recorded_minutes
    const { data: ents } = await supabase
      .from('timesheet_entries')
      .select(`id, header_id, entry_date, entry_kind, project_id, time_type_id, hours_minutes, notes, activities, is_system_generated, time_types(name,code,category), projects(name)`)
      .eq('header_id', header.id)
      .order('entry_date').order('created_at');

    newEntries = (ents ?? []) as unknown as TimesheetEntry[];
    setEntries(newEntries);
    await syncRecordedMinutes(header.id, newEntries);
    setHeader(h => h ? { ...h, recorded_minutes: newEntries.reduce((s,e) => s + e.hours_minutes, 0) } : h);

    // Record activity usages in history
    const savedActivities = _activities ?? [];
    if (savedActivities.length > 0 && employee?.id) {
      supabase.rpc('record_activity_usages', {
        p_employee_id:    employee.id,
        p_activity_names: savedActivities,
      }).then(({ data }) => {
        if (data?.ok) {
          // Refresh local history optimistically
          setActivityHistory(prev => {
            const next = [...prev];
            for (const name of savedActivities) {
              const idx = next.findIndex(a => a.activity_name === name);
              if (idx >= 0) {
                next[idx] = { ...next[idx], usage_count: next[idx].usage_count + 1, last_used_at: new Date().toISOString() };
              } else {
                next.push({ id: crypto.randomUUID(), activity_name: name, usage_count: 1, last_used_at: new Date().toISOString(), is_favorite: false, created_at: new Date().toISOString() } as ActivityHistoryItem & { created_at: string });
              }
            }
            return next;
          });
        }
      });
    }

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
                  if (!day) return <div key={`b-${idx}`} style={{ minHeight: 80 }} />;

                  const dateStr    = isoDate(year, month, day);
                  const dow        = (startDow + day - 1) % 7;
                  const isToday    = dateStr === todayIso;
                  const isSelected = dateStr === selectedDate;
                  const dayEnts    = entriesByDate[dateStr] ?? [];
                  const holiday    = holidayByDate[dateStr];
                  const dayPlanned = schedule ? plannedForDay(dow, schedule) : 0;
                  const isOffDay   = dayPlanned === 0;
                  const recorded   = dayEnts.reduce((s, e) => s + e.hours_minutes, 0);

                  return (
                    <div
                      key={dateStr}
                      onClick={() => { setSelectedDate(dateStr); setPanelOpen(true); cancelForm(); }}
                      style={{
                        minHeight: 80, borderRadius: 7, padding: '6px 7px', cursor: 'pointer',
                        border: isSelected
                          ? '2px solid #2563EB'
                          : isToday ? '2px solid #93C5FD'
                          : '1px solid #E5E7EB',
                        background: isSelected ? '#EFF6FF' : isOffDay ? '#F9FAFB' : '#fff',
                        boxShadow: isSelected ? '0 0 0 3px #BFDBFE55' : undefined,
                        transition: 'border-color 0.1s',
                      }}
                    >
                      {/* Day number + recorded time */}
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 3 }}>
                        <span style={{
                          fontSize: 12, fontWeight: isToday ? 700 : 500,
                          color: isToday ? '#fff' : isOffDay ? '#9CA3AF' : '#374151',
                          background: isToday ? '#2563EB' : 'transparent',
                          borderRadius: '50%', width: 20, height: 20,
                          display: 'flex', alignItems: 'center', justifyContent: 'center',
                        }}>
                          {day}
                        </span>
                        {recorded > 0 && (
                          <span style={{ fontSize: 10, color: '#6B7280', fontVariantNumeric: 'tabular-nums' }}>
                            {fmtMinsFull(recorded)}
                          </span>
                        )}
                      </div>

                      {/* Holiday label */}
                      {holiday && (
                        <div style={{ fontSize: 9, fontWeight: 600, color: '#5B21B6', background: '#EDE9FE', borderRadius: 3, padding: '1px 4px', marginBottom: 2, overflow: 'hidden', whiteSpace: 'nowrap', textOverflow: 'ellipsis' }}>
                          {holiday}
                        </div>
                      )}

                      {/* Non-working / off-day label */}
                      {!holiday && isOffDay && (
                        <div style={{ fontSize: 9, color: '#D1D5DB', fontStyle: 'italic' }}>
                          Non-working
                        </div>
                      )}

                      {/* Entry chips */}
                      {dayEnts.slice(0, 2).map(ent => (
                        <div key={ent.id} style={{
                          fontSize: 9, fontWeight: 600, marginBottom: 2,
                          background: KIND_CHIP[ent.entry_kind]?.bg ?? '#F3F4F6',
                          color:      KIND_CHIP[ent.entry_kind]?.color ?? '#374151',
                          borderRadius: 3, padding: '1px 4px',
                          overflow: 'hidden', whiteSpace: 'nowrap', textOverflow: 'ellipsis',
                        }}>
                          {getEntryLabel(ent)}
                        </div>
                      ))}
                      {dayEnts.length > 2 && (
                        <div style={{ fontSize: 9, color: '#6B7280' }}>+{dayEnts.length - 2} more</div>
                      )}
                    </div>
                  );
                })}
              </div>

              {/* Legend */}
              <div style={{ display: 'flex', gap: 16, marginTop: 16, flexWrap: 'wrap' }}>
                {[
                  { kind: 'time_type', label: 'Attendance' },
                  { kind: 'leave',     label: 'Leave / Absence' },
                  { kind: 'project',   label: 'Project' },
                  { kind: 'holiday',   label: 'Holiday' },
                ].map(({ kind, label }) => (
                  <div key={kind} style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11, color: '#6B7280' }}>
                    <div style={{ width: 10, height: 10, borderRadius: 2, background: KIND_CHIP[kind]?.bg }} />
                    {label}
                  </div>
                ))}
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

            {/* Entries */}
            <div style={{ flex: 1, padding: '10px 14px' }}>
              {dayEntries.length === 0 && !addingEntry && (
                <div style={{ color: '#9CA3AF', fontSize: 12, textAlign: 'center', padding: '20px 0' }}>
                  <i className="fa-regular fa-clock" style={{ fontSize: 20, display: 'block', marginBottom: 6 }} />
                  No entries for this day
                </div>
              )}

              {dayEntries.map(ent => (
                <div key={ent.id} style={{
                  border: editingEntry?.id === ent.id ? '2px solid #2563EB' : '1px solid #F3F4F6',
                  borderRadius: 8, padding: '9px 10px', marginBottom: 7, background: '#FAFAFA',
                }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 5, marginBottom: 3, flexWrap: 'wrap' }}>
                        <span style={{
                          fontSize: 9, fontWeight: 700, padding: '1px 6px', borderRadius: 99,
                          background: KIND_CHIP[ent.entry_kind]?.bg, color: KIND_CHIP[ent.entry_kind]?.color,
                          textTransform: 'uppercase', letterSpacing: '0.04em',
                        }}>
                          {ent.entry_kind.replace('_', ' ')}
                        </span>
                        <code style={{ fontSize: 10, color: '#9CA3AF' }}>{getEntryCode(ent)}</code>
                        {ent.is_system_generated && (
                          <span style={{ fontSize: 9, color: '#9CA3AF', background: '#F3F4F6', padding: '1px 4px', borderRadius: 3 }}>auto</span>
                        )}
                      </div>
                      <div style={{ fontSize: 13, fontWeight: 600, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                        {getEntryLabel(ent)}
                      </div>
                      {ent.notes && <div style={{ fontSize: 11, color: '#6B7280', marginTop: 2 }}>{ent.notes}</div>}
                    </div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginLeft: 8, flexShrink: 0 }}>
                      <span style={{ fontSize: 13, fontWeight: 700, color: '#1D4ED8' }}>{fmtMins(ent.hours_minutes)}</span>
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
                </div>
              ))}

              {/* Add / Edit entry form */}
              {addingEntry && (
                <div style={{
                  border: '1px dashed #93C5FD', borderRadius: 8, padding: 12,
                  background: '#EFF6FF', marginTop: 8,
                }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: '#1D4ED8', marginBottom: 10 }}>
                    {editingEntry
                    ? 'Edit Entry'
                    : formCategory === 'absence' ? 'Add Absence' : 'Add Attendance'}
                  </div>

                  {/* Attendance or Absence time-type picker */}
                  <div style={{ marginBottom: 8 }}>
                    <Label>
                      {formCategory === 'attendance' ? 'Attendance Type' : 'Absence / Leave Type'}
                    </Label>
                    <select
                      value={form.typeId}
                      onChange={e => { setForm(f => ({ ...f, typeId: e.target.value, projId: '', activities: [''] })); setFormErr(''); }}
                      style={selectSt}
                    >
                      <option value="">— Select —</option>
                      {timeTypes
                        .filter(t => t.category === formCategory)
                        .map(t => (
                          <option key={t.id} value={t.id}>{t.name} ({t.code})</option>
                        ))}
                    </select>
                  </div>

                  {/* Project picker — visible only when selected attendance type requires_project */}
                  {formCategory === 'attendance' && timeTypes.find(t => t.id === form.typeId)?.requires_project && (
                    <div style={{ marginBottom: 8 }}>
                      <Label>Project <span style={{ color: '#DC2626' }}>*</span></Label>
                      <select
                        value={form.projId}
                        onChange={e => { setForm(f => ({ ...f, projId: e.target.value, activities: [''] })); setFormErr(''); }}
                        style={selectSt}
                      >
                        <option value="">— Select project —</option>
                        {projects
                          .filter(p =>
                            !!selectedDate &&
                            (!p.start_date || p.start_date <= selectedDate) &&
                            (!p.end_date   || p.end_date   >= selectedDate)
                          )
                          .map(p => (
                            <option key={p.id} value={p.id}>{p.name}</option>
                          ))}
                      </select>
                    </div>
                  )}

                  {/* Activity list — visible when project is selected on a requires_project type */}
                  {formCategory === 'attendance' && timeTypes.find(t => t.id === form.typeId)?.requires_project && form.projId && (
                    <div style={{ marginBottom: 8 }}>
                      <Label>
                        Activities <span style={{ color: '#DC2626' }}>*</span>
                        <span style={{ color: '#9CA3AF', fontWeight: 400, marginLeft: 4 }}>(what did you work on?)</span>
                      </Label>
                      {form.activities.map((act, idx) => (
                        <div key={idx} style={{ display: 'flex', gap: 5, marginBottom: 5, alignItems: 'center' }}>
                          <ActivityAutocomplete
                            value={act}
                            onChange={val => {
                              const next = [...form.activities];
                              next[idx] = val;
                              setForm(f => ({ ...f, activities: next }));
                              setFormErr('');
                            }}
                            onFavoriteToggle={handleFavoriteToggle}
                            history={activityHistory}
                            placeholder={`Activity ${idx + 1}`}
                            inputStyle={{ ...inputSt, marginBottom: 0 }}
                          />
                          {form.activities.length > 1 && (
                            <button
                              type="button"
                              onClick={() => setForm(f => ({ ...f, activities: f.activities.filter((_, i) => i !== idx) }))}
                              style={{ flexShrink: 0, width: 26, height: 26, borderRadius: 6, border: '1px solid #FECACA', background: '#FEF2F2', color: '#DC2626', cursor: 'pointer', fontSize: 13, display: 'flex', alignItems: 'center', justifyContent: 'center' }}
                              title="Remove activity"
                            >
                              <i className="fa-solid fa-xmark" />
                            </button>
                          )}
                        </div>
                      ))}
                      <button
                        type="button"
                        onClick={() => setForm(f => ({ ...f, activities: [...f.activities, ''] }))}
                        style={{ marginTop: 2, padding: '4px 10px', borderRadius: 6, border: '1px dashed #93C5FD', background: 'transparent', color: '#1D4ED8', fontSize: 11, fontWeight: 600, cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 5 }}
                      >
                        <i className="fa-solid fa-plus" /> Add Activity
                      </button>
                    </div>
                  )}

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

              {/* Add entry buttons — Attendance / Absence / Project */}
              {editable && !addingEntry && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 8 }}>
                  <button
                    onClick={() => openAdd('attendance')}
                    style={{
                      width: '100%', padding: '8px 0', borderRadius: 7,
                      border: '1px solid #D1FAE5', background: '#ECFDF5',
                      color: '#065F46', fontSize: 12, fontWeight: 600, cursor: 'pointer',
                      display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
                    }}
                  >
                    <i className="fa-solid fa-clock" /> Add Attendance
                  </button>
                  <button
                    onClick={() => openAdd('absence')}
                    style={{
                      width: '100%', padding: '8px 0', borderRadius: 7,
                      border: '1px solid #FEF3C7', background: '#FFFBEB',
                      color: '#92400E', fontSize: 12, fontWeight: 600, cursor: 'pointer',
                      display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
                    }}
                  >
                    <i className="fa-solid fa-umbrella-beach" /> Add Absence
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
