/**
 * useWorkflowInstanceRouting
 *
 * Calls get_workflow_instance_routing(p_instance_id) — a SECURITY DEFINER RPC
 * that returns the full step-by-step routing chain for an in-flight workflow
 * instance, with live per-step status (completed / active / pending).
 *
 * Used by WorkflowParticipantsModal, which is opened from the "View participants"
 * link in the approver task detail panel.
 *
 * Security: the RPC allows the submitter OR any past/present task holder.
 * Both the employee and all approvers can open this view.
 */

import { useState, useEffect } from 'react';
import { supabase }            from '../../lib/supabase';
import type { WfRoleMember }   from './useWorkflowParticipants';

export type RoutingStepStatus = 'completed' | 'active' | 'pending';

export interface RoutingStep {
  stepOrder:            number;
  stepName:             string;
  approverType:         string;
  approverRole:         string | null;
  isCC:                 boolean;
  approvalMode:         'ALL_OF' | null;
  /** Live status derived from instance.current_step */
  status:               RoutingStepStatus;
  /** Display name for the approver slot */
  resolvedName?:        string;
  resolvedDesignation?: string;
  /** Most recent approver's name (completed steps only) */
  approvedByName?:      string | null;
  /** Timestamp of that approval */
  approvedAt?:          string | null;
  /** Active role members for ROLE steps (same as WfParticipant.roleMembers) */
  roleMembers?:         WfRoleMember[] | null;
}

interface UseWorkflowInstanceRoutingResult {
  loading: boolean;
  error:   string | null;
  steps:   RoutingStep[];
}

export function useWorkflowInstanceRouting(
  instanceId: string | null | undefined,
): UseWorkflowInstanceRoutingResult {
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState<string | null>(null);
  const [steps,   setSteps]   = useState<RoutingStep[]>([]);

  useEffect(() => {
    if (!instanceId) {
      setSteps([]);
      return;
    }

    let cancelled = false;
    setLoading(true);
    setError(null);
    setSteps([]);

    supabase
      .rpc('get_workflow_instance_routing', { p_instance_id: instanceId })
      .then(({ data, error: rpcError }) => {
        if (cancelled) return;

        if (rpcError) {
          console.error('[useWorkflowInstanceRouting] RPC error:', rpcError);
          setError(rpcError.message);
          setLoading(false);
          return;
        }

        setSteps((data ?? []) as RoutingStep[]);
        setLoading(false);
      });

    return () => { cancelled = true; };
  }, [instanceId]);

  return { loading, error, steps };
}
