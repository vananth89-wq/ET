/**
 * useTargetPopulation
 *
 * Resolves the target population for one or more module+action pairs using
 * the get_target_population() RPC (migration 096).
 *
 * Two call signatures:
 *
 * ── Single module (backward-compatible) ──────────────────────────────────────
 *   const { employeeIds, loading } = useTargetPopulation('expense_reports', 'view');
 *
 *   employeeIds === 'ALL'         → no population filter (everyone target group)
 *   employeeIds instanceof Set    → restricted to these UUIDs (may be empty = no access)
 *
 * ── Multi-module (new) ────────────────────────────────────────────────────────
 *   const { results, loading } = useTargetPopulation({
 *     active:   { module: 'employee_details',   action: 'view' },
 *     inactive: { module: 'inactive_employees', action: 'view' },
 *   });
 *
 *   results.active   → TargetResult
 *   results.inactive → TargetResult
 *
 * TargetResult
 * ────────────
 *   { mode: 'all' }
 *     Everyone target group — show all employees, no id filter.
 *
 *   { mode: 'scoped', ids: string[] }
 *     Restricted — filter to these employee UUIDs only.
 *
 *   { mode: 'none', reason: 'no_permission' | 'empty_group' }
 *     No access. no_permission = no matching role permission.
 *     empty_group = permission exists but target group has zero members.
 *
 * Runtime safety
 * ──────────────
 *   The runtime parser (parseTargetResult) treats any unknown shape as
 *   { mode: 'none', reason: 'no_permission' } — deny by default.
 *   This protects against future DB changes or unexpected RPC responses.
 */

import { useState, useEffect, useRef } from 'react';
import { supabase } from '../lib/supabase';

// ─── Types ────────────────────────────────────────────────────────────────────

export type TargetResult =
  | { mode: 'all' }
  | { mode: 'scoped'; ids: string[] }
  | { mode: 'none'; reason: 'no_permission' | 'empty_group' };

/** Map of key → TargetResult, returned by the multi-module overload. */
export type TargetResultMap<K extends string> = Record<K, TargetResult>;

/**
 * Legacy shape returned by the single-module overload.
 * 'ALL' = everyone, Set = scoped (empty = no access).
 * @deprecated Use TargetResult directly for new code.
 */
export type TargetPopulation = 'ALL' | Set<string>;

export interface UseTargetPopulationResult {
  /** Resolved target population (legacy shape). Starts as 'ALL' while loading. */
  employeeIds: TargetPopulation;
  /** Raw TargetResult from the new RPC. */
  result:  TargetResult;
  loading: boolean;
  error:   string | null;
}

export interface UseTargetPopulationMultiResult<K extends string> {
  results: TargetResultMap<K>;
  loading: boolean;
  error:   string | null;
}

export interface ModuleActionQuery {
  module: string;
  action: string;
}

// ─── Runtime parser ───────────────────────────────────────────────────────────

/**
 * Safely parses the raw JSONB response from get_target_population().
 * Unknown / malformed responses default to { mode: 'none', reason: 'no_permission' }
 * so that access is denied rather than accidentally granted.
 */
export function parseTargetResult(raw: unknown): TargetResult {
  if (typeof raw !== 'object' || raw === null) {
    return { mode: 'none', reason: 'no_permission' };
  }
  const r = raw as Record<string, unknown>;

  if (r.mode === 'all') {
    return { mode: 'all' };
  }

  if (r.mode === 'scoped' && Array.isArray(r.ids)) {
    return { mode: 'scoped', ids: r.ids as string[] };
  }

  if (r.mode === 'none') {
    const reason = r.reason === 'empty_group' ? 'empty_group' : 'no_permission';
    return { mode: 'none', reason };
  }

  // Unknown mode — deny by default
  return { mode: 'none', reason: 'no_permission' };
}

/** Converts a TargetResult to the legacy TargetPopulation shape. */
function toLegacyShape(result: TargetResult): TargetPopulation {
  if (result.mode === 'all')    return 'ALL';
  if (result.mode === 'scoped') return new Set<string>(result.ids);
  return new Set<string>(); // none → empty set = no access
}

// ─── Single-module hook ───────────────────────────────────────────────────────

export function useTargetPopulation(
  moduleCode?: string,
  actionCode?: string,
): UseTargetPopulationResult;

// ─── Multi-module hook ────────────────────────────────────────────────────────

export function useTargetPopulation<K extends string>(
  queries: Record<K, ModuleActionQuery>,
): UseTargetPopulationMultiResult<K>;

// ─── Implementation ───────────────────────────────────────────────────────────

export function useTargetPopulation<K extends string>(
  modulecodeOrQueries: string | Record<K, ModuleActionQuery> = 'expense_reports',
  actionCode = 'view',
): UseTargetPopulationResult | UseTargetPopulationMultiResult<K> {

  const isMulti = typeof modulecodeOrQueries === 'object';

  // ── Single-module state ────────────────────────────────────────────────────
  const [result,      setResult]      = useState<TargetResult>({ mode: 'all' });
  const [employeeIds, setEmployeeIds] = useState<TargetPopulation>('ALL');

  // ── Multi-module state ────────────────────────────────────────────────────
  const initialMulti = isMulti
    ? Object.fromEntries(
        Object.keys(modulecodeOrQueries).map(k => [k, { mode: 'none', reason: 'no_permission' } as TargetResult])
      ) as TargetResultMap<K>
    : ({} as TargetResultMap<K>);

  const [multiResults, setMultiResults] = useState<TargetResultMap<K>>(initialMulti);

  // ── Shared state ──────────────────────────────────────────────────────────
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState<string | null>(null);

  // Stable reference to queries object for useEffect dependency
  const queriesRef = useRef(modulecodeOrQueries);
  queriesRef.current = modulecodeOrQueries;

  const queryKey = isMulti
    ? JSON.stringify(modulecodeOrQueries)
    : `${modulecodeOrQueries}:${actionCode}`;

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    async function resolve() {
      try {
        if (!isMulti) {
          // ── Single-module path ─────────────────────────────────────────────
          const moduleCode = modulecodeOrQueries as string;
          const { data, error: rpcErr } = await supabase.rpc(
            'get_target_population',
            { p_module: moduleCode, p_action: actionCode },
          );

          if (rpcErr) throw rpcErr;
          if (!mounted) return;

          const parsed = parseTargetResult(data);
          setResult(parsed);
          setEmployeeIds(toLegacyShape(parsed));

        } else {
          // ── Multi-module path ──────────────────────────────────────────────
          const queries = queriesRef.current as Record<K, ModuleActionQuery>;
          const entries = Object.entries(queries) as [K, ModuleActionQuery][];

          // Fire all RPC calls in parallel
          const settled = await Promise.all(
            entries.map(async ([key, q]) => {
              const { data, error: rpcErr } = await supabase.rpc(
                'get_target_population',
                { p_module: q.module, p_action: q.action },
              );
              if (rpcErr) throw rpcErr;
              return [key, parseTargetResult(data)] as [K, TargetResult];
            })
          );

          if (!mounted) return;

          const resolved = Object.fromEntries(settled) as TargetResultMap<K>;
          setMultiResults(resolved);
        }

      } catch (err: unknown) {
        if (!mounted) return;
        const msg = err instanceof Error ? err.message : String(err);
        setError(msg);
        // On error: deny access (safe default)
        if (!isMulti) {
          const denied: TargetResult = { mode: 'none', reason: 'no_permission' };
          setResult(denied);
          setEmployeeIds(new Set<string>());
        }
      } finally {
        if (mounted) setLoading(false);
      }
    }

    resolve();
    return () => { mounted = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryKey]);

  if (isMulti) {
    return { results: multiResults, loading, error } as UseTargetPopulationMultiResult<K>;
  }

  return { employeeIds, result, loading, error } as UseTargetPopulationResult;
}
