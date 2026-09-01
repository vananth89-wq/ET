/**
 * Which of an employee's hours are chargeable — the client-side statement of a
 * rule the database already owns.
 *
 * THE RULE LIVES IN THE DATABASE. `timesheet_report_utilisation` (mig 820,
 * re-grained to activity rows by 822) is where it is enforced and where the
 * Utilisation report reads it. This module exists because the Monthly Summary
 * and the monthly PDF are built entirely from rows the page already holds — no
 * query, no endpoint — and they still have to reach the same answer as that
 * report for the same hour. Two screens disagreeing about revenue is worse than
 * either being wrong, because the disagreement is what gets argued about.
 *
 * So it is written ONCE here rather than twice on two surfaces, and it is
 * written to mirror 822's CASE branch for branch. If that migration's
 * precedence ever changes, this is the file that changes with it.
 *
 *     absence                        -> absence      (leave is not worked time)
 *     project set, no type on it     -> unclassified (never assumed to be either)
 *     project set, type is not P001  -> non_billable
 *     project set, P001, no activity -> billable     (nobody was ever asked)
 *     project set, P001, row is true -> billable
 *     project set, P001, otherwise   -> non_billable
 *     no project at all              -> non_billable (a payer means a project)
 *
 * The last line is what puts cross-project help (mig 801) on the right side
 * without naming it: those entries leave `project_id` NULL by design, so they
 * fall out here exactly as they fall out of the report.
 */

/** The three words `project_billability()` (mig 825) returns. */
export type ProjectClass = 'billable' | 'non_billable' | 'unclassified';

export interface BillSplit {
  billable:     number;
  nonBillable:  number;
  unclassified: number;
  /** Leave. Excluded from `worked`, and therefore from the share's denominator. */
  absence:      number;
  /** billable + nonBillable + unclassified. The share's denominator. */
  worked:       number;
}

export const EMPTY_SPLIT: BillSplit = {
  billable: 0, nonBillable: 0, unclassified: 0, absence: 0, worked: 0,
};

/** The minimum an entry has to expose to be classified. */
export interface BillEntry {
  entry_kind:    string;
  hours_minutes: number;
  /** NULL on cross-project help (801) and on every non-project time type. */
  project_id?:   string | null;
  activities:    Array<{ hours_minutes: number | null; is_billable?: boolean | null }>;
}

/**
 * One entry's minutes, split.
 *
 * THE UN-ITEMISED REMAINDER FOLLOWS THE PROJECT. An entry whose activity rows
 * total less than the entry itself is a pre-727 row that carries names without
 * a split; those minutes were never offered the billable question, so the older
 * rule stands and the project answers — the same reasoning as 822's
 * `WHEN a.id IS NULL THEN 'billable'`, applied to the part of an entry that
 * has no row rather than the whole of one that has none.
 *
 * The four buckets always sum to `hours_minutes`. That is what lets the tile
 * built from them sit beside Recorded without the two contradicting each other.
 */
export function splitEntry(e: BillEntry, cls: ProjectClass | null): BillSplit {
  const out = { ...EMPTY_SPLIT };
  const mins = e.hours_minutes;
  if (mins <= 0) return out;

  if (e.entry_kind === 'leave') { out.absence = mins; out.worked = 0; return out; }

  const put = (k: 'billable' | 'nonBillable' | 'unclassified', v: number) => {
    out[k] += v; out.worked += v;
  };

  // No project, or a project this screen has never heard of. Both mean nobody
  // to charge. An id with no classification is the more interesting case: it
  // happens when a project was created after this page loaded its list, and
  // guessing "billable" there would put a number nobody chose into a share.
  if (!e.project_id || !cls)   { put('nonBillable',  mins); return out; }
  if (cls === 'unclassified')  { put('unclassified', mins); return out; }
  if (cls !== 'billable')      { put('nonBillable',  mins); return out; }

  const rows = e.activities ?? [];
  let itemised = 0;
  let billable = 0;
  for (const a of rows) {
    const m = a.hours_minutes ?? 0;
    if (m <= 0) continue;
    itemised += m;
    // IS TRUE, never a default. NULL means the question was never asked, and an
    // hour nobody was asked about is not an hour anybody agreed to pay for.
    if (a.is_billable === true) billable += m;
  }

  const gap = Math.max(0, mins - itemised);
  put('billable',    billable + gap);
  put('nonBillable', itemised - billable);
  return out;
}

/** Every entry, summed. */
export function splitEntries(
  entries: BillEntry[],
  classOf: (projectId: string | null | undefined) => ProjectClass | null,
): BillSplit {
  const total = { ...EMPTY_SPLIT };
  for (const e of entries) {
    const s = splitEntry(e, classOf(e.project_id));
    total.billable     += s.billable;
    total.nonBillable  += s.nonBillable;
    total.unclassified += s.unclassified;
    total.absence      += s.absence;
    total.worked       += s.worked;
  }
  return total;
}

/**
 * Billable hours over WORKED hours, as a whole percent — or null when the
 * month has no worked time at all.
 *
 * Absence is out of the denominator, matching the Utilisation report's tile.
 * Including it would make a fortnight of annual leave read as a fortnight of
 * lost revenue, which is not what leave is.
 */
export function billableSharePct(s: BillSplit): number | null {
  if (s.worked <= 0) return null;
  return Math.round((s.billable / s.worked) * 100);
}
