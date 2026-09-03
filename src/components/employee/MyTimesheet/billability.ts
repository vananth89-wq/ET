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
 *     project set, type is not P001  -> internal     (836)
 *     project set, P001, no activity -> billable     (nobody was ever asked)
 *     project set, P001, row is true -> billable
 *     project set, P001, otherwise   -> non_billable
 *     no project, related project    -> support      (836)
 *     no project at all              -> internal     (836)
 *
 * MIG 836 SPLIT non_billable INTO THREE. It was absorbing four unrelated facts
 * -- an hour somebody declined to charge, an internal project, help given
 * elsewhere, and Training -- so the figure said nothing. `non_billable` now
 * means only what its name says: a client project, and a person answered no.
 *
 * `billable` and the denominator are deliberately UNTOUCHED by that split.
 * Billable share is still billable over worked, and worked is still all of
 * these, so the number Finance quotes reads the same before and after.
 */

/** The three words `project_billability()` (mig 825) returns. */
export type ProjectClass = 'billable' | 'non_billable' | 'unclassified';

export interface BillSplit {
  billable:     number;
  /** A client project, and somebody answered no. Mig 836 narrowed this. */
  nonBillable:  number;
  /** Never chargeable by nature: Internal and Overhead projects, plus
   *  attendance types that carry no project at all -- Training, On-Site Visit. */
  internal:     number;
  /** Help given to a project you are not staffed on (801). Its own bucket
   *  since 836; it used to be swept into nonBillable, where it was invisible. */
  support:      number;
  unclassified: number;
  /** Leave. Excluded from `worked`, and therefore from the share's denominator. */
  absence:      number;
  /** Every worked bucket summed. The share's denominator, unchanged by 836. */
  worked:       number;
}

export const EMPTY_SPLIT: BillSplit = {
  billable: 0, nonBillable: 0, internal: 0, support: 0,
  unclassified: 0, absence: 0, worked: 0,
};

/** The minimum an entry has to expose to be classified. */
export interface BillEntry {
  entry_kind:    string;
  hours_minutes: number;
  /** NULL on cross-project help (801) and on every non-project time type. */
  project_id?:   string | null;
  /** Set only on help given to another project. What tells `support` apart
   *  from `internal` once project_id is NULL for both. */
  related_project_id?: string | null;
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

  const put = (k: 'billable' | 'nonBillable' | 'internal' | 'support' | 'unclassified',
               v: number) => {
    out[k] += v; out.worked += v;
  };

  // No project at all. Two different facts, and 836 stopped merging them: help
  // given to another project names the project it helped (801) and everything
  // else -- Training, On-Site Visit -- names nothing.
  if (!e.project_id) {
    put(e.related_project_id ? 'support' : 'internal', mins);
    return out;
  }
  // A project id this screen has never heard of, which happens when a project
  // was created after the page loaded its list. Unclassified rather than a
  // guess: we do not know what it is worth, and inventing an answer is how a
  // number nobody chose gets into a share.
  if (!cls)                    { put('unclassified', mins); return out; }
  if (cls === 'unclassified')  { put('unclassified', mins); return out; }
  // Internal and Overhead. The billable question is only put on a P001
  // project, so these rows carry NULL and always did -- calling them
  // non-billable reported a decision nobody was ever asked to make.
  if (cls !== 'billable')      { put('internal',     mins); return out; }

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
    total.internal     += s.internal;
    total.support      += s.support;
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
