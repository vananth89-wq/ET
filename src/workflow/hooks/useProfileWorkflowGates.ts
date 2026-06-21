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
  'profile_bank',
  'profile_dependents',
] as const;

export type ProfileModuleCode = typeof PROFILE_MODULE_CODES[number];

interface ProfileWorkflowGatesResult {
  /** Set of module codes for which a workflow assignment resolves for this user */
  activeGates:   Set<string>;
  /** Number of in-flight pending_change rows per module code (this user only) */
  pendingCounts: Record<string, number>;
  /**
   * Active workflow instance_id per module code (mig 207).
   * Present when status is in_progress or awaiting_clarification.
   * Used to open WorkflowParticipantsModal from the "View approval progress" link.
   */
  instanceIds:   Record<string, string>;
  /**
   * True when the caller has bank_exceptions, admin, or hr role (mig 299).
   * When true, the 15th-submission and 20th-approval cutoffs do not apply.
   * Used by BankAccountsPortlet to hide the cutoff banner for exempt users.
   */
  isBankException: boolean;
  loading:       boolean;
  /** Re-fetch gates — call on edit-mode entry to avoid stale data */
  refetch:       () => void;
}

/**
 * employeeId — optional; when provided (employee mode), pending counts are
 * scoped to the viewed employee's record_id rather than submitted_by=auth.uid().
 * Corresponds to the p_employee_id param added in mig 507.
 */
export function useProfileWorkflowGates(employeeId?: string | null): ProfileWorkflowGatesResult {
  const [activeGates,     setActiveGates]     = useState<Set<string>>(new Set());
  const [pendingCounts,   setPendingCounts]   = useState<Record<string, number>>({});
  const [instanceIds,     setInstanceIds]     = useState<Record<string, string>>({});
  const [isBankException, setIsBankException] = useState(false);
  const [loading,         setLoading]         = useState(true);
  const [tick,            setTick]            = useState(0);

  const fetch = useCallback(async () => {
    setLoading(true);

    const rpcArgs = employeeId ? { p_employee_id: employeeId } : {};
    const { data, error } = await supabase.rpc('get_profile_workflow_gates', rpcArgs);

    if (error || !data) {
      // On failure keep previous state rather than wiping gates
      console.warn('[useProfileWorkflowGates] RPC error:', error?.message);
      setLoading(false);
      return;
    }

    const gatedArr: string[]                  = data.gated_modules    ?? [];
    const pendingObj: Record<string, number>  = data.pending_counts   ?? {};
    const instanceObj: Record<string, string> = data.instance_ids     ?? {};
    const bankExempt: boolean                 = data.is_bank_exception ?? false;

    setActiveGates(new Set(gatedArr));
    setPendingCounts(pendingObj);
    setInstanceIds(instanceObj);
    setIsBankException(bankExempt);
    setLoading(false);
  }, [employeeId]);

  // Re-run whenever tick increments or employeeId changes
  useEffect(() => { fetch(); }, [fetch, tick]);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  return { activeGates, pendingCounts, instanceIds, isBankException, loading, refetch };
}
