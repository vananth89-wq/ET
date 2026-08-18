import { assembleExportData } from '../../components/employee/MyTimesheet/ExportPDF/assemble';
import type { AssembleRow } from '../../components/employee/MyTimesheet/ExportPDF/assemble';
import type { TimesheetExportData } from '../../components/employee/MyTimesheet/ExportPDF/types';
import { loadLogoDataUrl } from '../../components/employee/MyTimesheet/ExportPDF/logo';
import { entryMinutes } from '../../components/employee/MyTimesheet/ExportPDF/utils/dataTransforms';
import type { TsPayload, TsPayloadEntry } from './model';

/**
 * The approver's copy of the employee's report.
 *
 * This file does NO arithmetic about the month. Every figure the PDF prints is
 * decided by assembleExportData(), the same function the employee's own export
 * calls -- so the document an approver downloads and the one the employee filed
 * are the same document, not two implementations that happen to agree today.
 *
 * All this does is translate. time_approval_payload returns one blob; the
 * assembler wants rows plus two schedule questions. That mapping is the only
 * thing genuinely particular to the approval side, and it is deliberately kept
 * dull: no filtering, no re-derivation, nothing that could quietly disagree with
 * the screen the approver is looking at while they click the button.
 */
export async function buildApprovalExportData(p: TsPayload): Promise<TimesheetExportData> {
  const [y, m] = p.header.period.split('-').map(Number);
  const totalDays = new Date(y, m, 0).getDate();

  const holidayByDate: Record<string, string> = {};
  for (const h of p.holidays ?? []) holidayByDate[h.date] = h.name;

  // The schedule arrives as lines keyed by day_number, counted from the
  // schedule's own start day -- the same wrap the timesheet page applies.
  const startDow  = p.schedule?.start_day_of_week ?? 0;
  const plannedBy = new Map<number, number>();
  for (const l of p.schedule?.lines ?? []) plannedBy.set(l.day_number, l.planned_minutes);

  const plannedForDow = (dow: number) =>
    p.schedule ? (plannedBy.get(((dow - startDow + 7) % 7) + 1) ?? 0) : 0;

  const plannedForDate = (iso: string) => {
    // A holiday plans nothing. Same rule as the employee page, and the reason
    // the calendar can call a worked holiday "over" rather than "on plan".
    if (holidayByDate[iso]) return 0;
    const [yy, mm, dd] = iso.split('-').map(Number);
    return plannedForDow(new Date(yy, mm - 1, dd).getDay());
  };

  const kindOf = (e: TsPayloadEntry): AssembleRow['kind'] =>
    e.entry_kind === 'leave' ? 'leave' : e.entry_kind === 'holiday' ? 'holiday' : 'work';

  /**
   * MIG 745 added `activity_rows` beside the legacy `activities` names. An
   * approval screen loaded against an older database still gets only the names,
   * and those report at zero minutes -- exactly what the employee's export does
   * with a pre-727 entry, so the two stay identical either way.
   */
  const activitiesOf = (e: { activity_rows?: Array<{ name: string; minutes: number }> | null;
                             activities?: string[] | null }) =>
    (e.activity_rows?.length
      ? e.activity_rows.map(a => ({ name: a.name, minutes: a.minutes }))
      : (e.activities ?? []).filter(Boolean).map(n => ({ name: n, minutes: 0 })));
  // NOTE: the zero-minute fallback above is for DISPLAY only. Never hand the
  // result to entryMinutes() -- see the call below.

  const rows: AssembleRow[] = (p.entries ?? []).map(e => {
    const acts = activitiesOf(e);
    return {
      date:       e.entry_date,
      kind:       kindOf(e),
      typeName:   e.time_type_name ?? (e.entry_kind === 'holiday' ? 'Holiday' : '—'),
      project:    e.project_name ?? null,
      // entryMinutes() treats ANY non-empty activity list as the source of
      // truth and sums it. `acts` is a DISPLAY list: for a pre-727 entry it
      // holds the legacy names at minutes 0, so passing it here summed to zero
      // and threw the parent's real hours away -- the entry printed as a dash
      // and the day and month totals on page 2 silently lost those hours while
      // page 1's calendar, which reads rawMinutes, still showed them. Pass only
      // GENUINE rows; absent ones must fall through to the parent.
      minutes:    entryMinutes(e.hours_minutes, e.activity_rows ?? null),
      rawMinutes: e.hours_minutes,
      notes:      e.notes,
      activities: acts,
      // The payload already answers this against the LAST approval, which is
      // the same question the employee page asks of approved_at. Shouting caps
      // are the RPC's convention, not the report's.
      changeMark: e.changed_after_approval === 'ADDED' ? 'added'
                : e.changed_after_approval === 'EDITED' ? 'edited'
                : null,
    };
  });

  return assembleExportData({
    year: y, month: m, totalDays,
    plannedForDate,
    plannedForDow,
    hasSchedule: !!p.schedule,
    holidayByDate,
    rows,
    header: {
      id:               p.header.id,
      status:           p.header.status,
      plannedMinutes:   p.header.planned_minutes,
      // The header's own figure, not a sum of the rows -- the same choice the
      // employee page makes, so both reports quote the month the same way.
      recordedMinutes:  p.header.recorded_minutes,
      submittedAt:      p.header.submitted_at,
      approvedAt:       p.header.approved_at,
      contentChangedAt: p.header.content_changed_at ?? null,
      referenceId:      p.header.external_code,
    },
    labels: {
      // The SUBJECT of the timesheet, never the approver reading it.
      employeeName:    p.employee?.name ?? '—',
      employeeCode:    p.employee?.employee_code ?? '—',
      department:      p.header.department_name ?? '—',
      holidayCalendar: p.holiday_calendar?.name ?? '—',
      manager:         p.employee?.manager_name ?? '—',
      workSchedule:    p.schedule ? `${p.schedule.name ?? '—'} (${p.schedule.code ?? '—'})` : '—',
    },
    logoDataUrl: await loadLogoDataUrl(),
    generatedAt: new Date().toISOString(),
  });
}
