/**
 * useProfileWorkflowGates
 *
 * Two batched queries — one for active assignments, one for pending counts —
 * covering all profile section module codes at once.
 * Returns a Set of active module codes and a per-module pending count map.
 * Two DB round-trips instead of 14 (7 assignment + 7 count queries).
 *
 * Usage:
 *   const { activeGates, pendingCounts } = useProfileWorkflowGates();
 *   const personalGated   = activeGates.has('profile_personal');
 *   const personalPending = pendingCounts['profile_personal'] ?? 0;
 */

import { useState, useEffect } from 'react';
import { supabase }            from '../../lib/supabase';

export const PROFILE_MODULE_CODES = [
  'profile_personal',
  'profile_contact',
  'profile_employment',
  'profile_address',
  'profile_passport',
  'profile_identification',
  'profile_emergency_contact',
] as const;

export type ProfileModuleCode = typeof PROFILE_MODULE_CODES[number];

interface ProfileWorkflowGatesResult {
  /** Set of module codes that have an active workflow assignment */
  activeGates:   Set<string>;
  /** Number of in-flight pending_change rows per module code */
  pendingCounts: Record<string, number>;
  loading:       boolean;
}

export function useProfileWorkflowGates(): ProfileWorkflowGatesResult {
  const [activeGates,   setActiveGates]   = useState<Set<string>>(new Set());
  const [pendingCounts, setPendingCounts] = useState<Record<string, number>>({});
  const [loading,       setLoading]       = useState(true);

  useEffect(() => {
    const today = new Date().toISOString().slice(0, 10);
    const codes  = [...PROFILE_MODULE_CODES];

    Promise.all([
      // 1. Which modules have an active assignment?
      supabase
        .from('workflow_assignments')
        .select('module_code')
        .in('module_code', codes)
        .eq('is_active', true)
        .lte('effective_from', today)
        .or(`effective_to.is.null,effective_to.gte.${today}`),

      // 2. Pending change rows for all profile modules (status = 'pending')
      supabase
        .from('workflow_pending_changes')
        .select('module_code')
        .in('module_code', codes)
        .eq('status', 'pending'),
    ]).then(([assignRes, pendRes]) => {
      // Build active set
      const activeCodes = new Set(
        (assignRes.data ?? []).map((r: any) => r.module_code as string)
      );

      // Tally pending counts per module
      const counts: Record<string, number> = {};
      for (const row of (pendRes.data ?? []) as { module_code: string }[]) {
        counts[row.module_code] = (counts[row.module_code] ?? 0) + 1;
      }

      setActiveGates(activeCodes);
      setPendingCounts(counts);
      setLoading(false);
    });
  }, []);

  return { activeGates, pendingCounts, loading };
}
