/**
 * Report helpers — formatting, fetching, exporting. No components.
 *
 * Split from reportControls.tsx because a file that exports both components and
 * plain functions breaks React Fast Refresh, which is what
 * react-refresh/only-export-components was telling us.
 */

import { useCallback, useRef, useState } from 'react';
import { supabase } from '../../../lib/supabase';

// ─── Formatting ──────────────────────────────────────────────────────────────

/** 450 -> "7h 30m". Minutes are how the whole time module stores duration. */
export function fmtHM(minutes: number | null | undefined): string {
  const m = Math.trunc(Math.abs(minutes ?? 0));
  const sign = (minutes ?? 0) < 0 ? '-' : '';
  return `${sign}${Math.floor(m / 60)}h ${String(m % 60).padStart(2, '0')}m`;
}

/** Decimal hours for spreadsheets — 450 -> 7.5. A person reads h/m; Excel sums decimals. */
export function toDecimalHours(minutes: number | null | undefined): number {
  return Math.round(((minutes ?? 0) / 60) * 100) / 100;
}

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export function fmtDate(v: string | null | undefined): string {
  if (!v) return '—';
  const d = new Date(v.length === 10 ? v + 'T00:00:00' : v);
  if (isNaN(d.getTime())) return String(v);
  return `${String(d.getDate()).padStart(2, '0')}-${MONTHS[d.getMonth()]}-${d.getFullYear()}`;
}

export function fmtPeriod(v: string | null | undefined): string {
  if (!v) return '—';
  const d = new Date(v.slice(0, 10) + 'T00:00:00');
  if (isNaN(d.getTime())) return String(v);
  return `${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}

/** '2026-08' -> '2026-08-01', which is what the RPCs expect. */
export function fromMonthInput(m: string): string { return `${m}-01`; }

export function currentMonthInput(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

/** The month before this one, as <input type="month"> wants it. */
export function lastMonthInput(): string {
  const d = new Date();
  d.setDate(1);
  d.setMonth(d.getMonth() - 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

// ─── Calling a report RPC ────────────────────────────────────────────────────

export interface RpcState<T> { data: T | null; loading: boolean; error: string | null; }

/**
 * Calls a report RPC and normalises every way it can go wrong into one string.
 *
 * ALWAYS destructures `error`. A swallowed PostgREST error is indistinguishable
 * from an empty result, and that is exactly how a bug hid for a week in this
 * codebase. The RPCs also answer {ok:false,...} for refusals they handle
 * themselves, so both shapes are unwrapped here rather than at every call site.
 *
 * Requests are sequenced: a slow first response can no longer overwrite a fast
 * second one, which is what makes rapid Apply clicks show the wrong page.
 */
export function useReportRpc<T>(fn: string) {
  const [state, setState] = useState<RpcState<T>>({ data: null, loading: false, error: null });
  const seq = useRef(0);

  const run = useCallback(async (filters: Record<string, unknown>) => {
    const mine = ++seq.current;
    setState(s => ({ ...s, loading: true, error: null }));

    const { data, error } = await supabase.rpc(fn, { p_filters: filters });
    if (mine !== seq.current) return;                    // a newer request has started

    if (error) { setState({ data: null, loading: false, error: error.message }); return; }

    const payload = data as unknown as { ok?: boolean; message?: string; error?: string };
    if (payload && payload.ok === false) {
      setState({ data: null, loading: false,
                 error: payload.message || payload.error || 'The report was refused.' });
      return;
    }
    setState({ data: data as T, loading: false, error: null });
  }, [fn]);

  return { ...state, run };
}

// ─── Excel export ────────────────────────────────────────────────────────────

export interface Sheet { name: string; rows: Record<string, unknown>[]; }

/**
 * Writes a real .xlsx.
 *
 * `xlsx` is imported dynamically so it stays out of the main bundle — the same
 * treatment @react-pdf/renderer gets in the timesheet exporter. The Expense
 * report writes a .csv while calling itself Excel; that is not repeated here.
 */
export async function exportXlsx(sheets: Sheet[], filename: string): Promise<void> {
  const XLSX = await import('xlsx');
  const wb = XLSX.utils.book_new();
  for (const s of sheets) {
    const ws = XLSX.utils.json_to_sheet(s.rows.length ? s.rows : [{ '': 'No rows' }]);
    XLSX.utils.book_append_sheet(wb, ws, s.name.slice(0, 31));
  }
  XLSX.writeFile(wb, filename);
}
