/**
 * useWorkflowParticipants
 *
 * Calls the SECURITY DEFINER RPC get_workflow_participants() to resolve the
 * active workflow template's steps into a structured participant list for
 * WorkflowSubmitModal.
 *
 * Why RPC instead of direct table queries?
 * ─────────────────────────────────────────
 * Migration 153 tightened workflow_steps SELECT to user_can('wf_templates','view').
 * ESS users do not have that permission, so direct client queries returned []
 * silently — showing "No approvers" in the modal even when a template existed.
 *
 * The SECURITY DEFINER function bypasses RLS on workflow_steps, profiles, and
 * employees (all needed to resolve approver names) and returns only the
 * display-safe routing data for the requested module. Equivalent to the
 * routing-preview service pattern used by SuccessFactors and Workday.
 *
 * profileId (optional)
 * ────────────────────
 * When supplied (= auth.uid() from AuthContext → profile.id), the RPC also
 * resolves manager-type steps: it walks submitter → employee → manager_id →
 * manager's employee row and returns the actual manager's name + title.
 * Without it the function falls back to 'Direct Manager' / 'Resolved at
 * submission time' — safe and backward-compatible.
 *
 * Returns two lists:
 *   approvers      — regular approval steps (isCC = false), ordered by stepOrder
 *   ccParticipants — CC / notification-only steps (isCC = true)
 */

import { useState, useEffect } from 'react';
import { supabase }            from '../../lib/supabase';

export interface WfParticipant {
  stepOrder:            number;
  stepName:             string;
  approverType:         string;   // 'SPECIFIC_USER' | 'MANAGER' | 'ROLE' | 'DEPT_HEAD' | 'RULE_BASED' | 'SELF'
  approverRole:         string | null;
  resolvedName?:        string;
  resolvedDesignation?: string;
  isCC:                 boolean;
  /** True when the RPC resolved the step to a specific named employee.
   *  profile → always true.
   *  role    → true if an active role holder was found.
   *  manager → true if p_profile_id was supplied and the submitter has a manager.
   *  self    → always false. */
  hasResolvedPerson?:   boolean;
}

interface UseWorkflowParticipantsResult {
  loading:        boolean;
  approvers:      WfParticipant[];
  ccParticipants: WfParticipant[];
}

export function useWorkflowParticipants(
  moduleCode: string,
  profileId?: string | null,
): UseWorkflowParticipantsResult {
  const [loading,        setLoading]        = useState(false);
  const [approvers,      setApprovers]      = useState<WfParticipant[]>([]);
  const [ccParticipants, setCcParticipants] = useState<WfParticipant[]>([]);

  useEffect(() => {
    if (!moduleCode) return;

    let cancelled = false;
    setLoading(true);
    setApprovers([]);
    setCcParticipants([]);

    supabase
      .rpc('get_workflow_participants', {
        p_module_code: moduleCode,
        // Pass profile_id so the RPC can resolve manager-type steps.
        // null is fine — the DB param defaults to NULL and degrades gracefully.
        p_profile_id: profileId ?? null,
      })
      .then(({ data, error }) => {
        if (cancelled) return;

        if (error) {
          console.error('[useWorkflowParticipants] RPC error:', error);
          setLoading(false);
          return;
        }

        const participants = (data ?? []) as WfParticipant[];
        setApprovers(participants.filter(p => !p.isCC));
        setCcParticipants(participants.filter(p => p.isCC));
        setLoading(false);
      });

    return () => { cancelled = true; };
  }, [moduleCode, profileId]);

  return { loading, approvers, ccParticipants };
}
