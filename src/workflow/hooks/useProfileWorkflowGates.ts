/**
 * useProfileWorkflowGates
 *
 * Single RPC call — get_profile_workflow_gates() — that uses the same
 * resolve_workflow_for_submission() resolver as submit_change_request.
 * This guarantees the UI gate always matches what the DB will find at
 * submission time, regardless of assignment type (GLOBAL/ROLE/EMPLOYEE).
 *
 * Returns:
 *   activeGates  — Set of module codes where a workflow resolves for this user
 *   pendingCounts — Per-module count of 'pending' workflow_pending_changes rows
 *   refetch      — Call this to re-fetch gates (e.g., on edit-mode entry)
 *
 * Usage:
 *   const { activeGates, pendingCounts, refetch } = useProfileWorkflowGates();
 *   const personalGated   = activeGates.has('profile_personal');
 *   const personalPending = pendingCounts['profile_personal'] ?? 0;
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase }                          from '../../lib/supabase';

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
  /** Set of module codes for which a workflow assignment resolves for this user */
  activeGates:   Set<string>;
  /** Number of in-flight pending_change rows per module code (this user only) */
  pendingCounts: Record<string, number>;
  loading:       boolean;
  /** Re-fetch gates — call on edit-mode entry to avoid stale data */
  refetch:       () => void;
}

export function useProfileWorkflowGates(): ProfileWorkflowGatesResult {
  const [activeGates,   setActiveGates]   = useState<Set<string>>(new Set());
  const [pendingCounts, setPendingCounts] = useState<Record<string, number>>({});
  const [loading,       setLoading]       = useState(true);
  const [tick,          setTick]          = useState(0);

  const fetch = useCallback(async () => {
    setLoading(true);

    const { data, error } = await supabase.rpc('get_profile_workflow_gates');

    if (error || !data) {
      // On failure keep previous state rather than wiping gates
      console.warn('[useProfileWorkflowGates] RPC error:', error?.message);
      setLoading(false);
      return;
    }

    const gatedArr: string[]            = data.gated_modules  ?? [];
    const pendingObj: Record<string, number> = data.pending_counts ?? {};

    setActiveGates(new Set(gatedArr));
    setPendingCounts(pendingObj);
    setLoading(false);
  }, []);

  // Re-run whenever tick increments (mount + every refetch() call)
  useEffect(() => { fetch(); }, [fetch, tick]);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  return { activeGates, pendingCounts, loading, refetch };
}
