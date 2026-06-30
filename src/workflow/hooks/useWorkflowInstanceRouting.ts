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

export type RoutingStepStatus = 'completed' | 'active' | 'pending' | 'skipped';

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

export interface WorkflowInstanceMeta {
  status:      string;
  moduleCode:  string;
  recordId:    string;
}

interface UseWorkflowInstanceRoutingResult {
  loading:      boolean;
  error:        string | null;
  steps:        RoutingStep[];
  instanceMeta: WorkflowInstanceMeta | null;
  /** True when all steps are terminal but instance is still in_progress */
  isStalled:    boolean;
}

export function useWorkflowInstanceRouting(
  instanceId: string | null | undefined,
): UseWorkflowInstanceRoutingResult {
  const [loading,      setLoading]      = useState(false);
  const [error,        setError]        = useState<string | null>(null);
  const [steps,        setSteps]        = useState<RoutingStep[]>([]);
  const [instanceMeta, setInstanceMeta] = useState<WorkflowInstanceMeta | null>(null);

  useEffect(() => {
    if (!instanceId) {
      setSteps([]);
      setInstanceMeta(null);
      return;
    }

    let cancelled = false;
    setLoading(true);
    setError(null);
    setSteps([]);
    setInstanceMeta(null);

    Promise.all([
      supabase.rpc('get_workflow_instance_routing', { p_instance_id: instanceId }),
      supabase
        .from('workflow_instances')
        .select('status, module_code, record_id')
        .eq('id', instanceId)
        .single(),
    ]).then(([routingRes, metaRes]) => {
      if (cancelled) return;

      if (routingRes.error) {
        console.error('[useWorkflowInstanceRouting] RPC error:', routingRes.error);
        setError(routingRes.error.message);
        setLoading(false);
        return;
      }

      setSteps((routingRes.data ?? []) as RoutingStep[]);

      if (!metaRes.error && metaRes.data) {
        setInstanceMeta({
          status:     metaRes.data.status,
          moduleCode: metaRes.data.module_code,
          recordId:   metaRes.data.record_id,
        });
      }

      setLoading(false);
    });

    return () => { cancelled = true; };
  }, [instanceId]);

  // Stalled = instance is still in_progress but every non-CC step is terminal
  const isStalled = !!(
    instanceMeta?.status === 'in_progress' &&
    steps.length > 0 &&
    steps.filter(s => !s.isCC).every(s => s.status === 'completed' || s.status === 'skipped')
  );

  return { loading, error, steps, instanceMeta, isStalled };
}
