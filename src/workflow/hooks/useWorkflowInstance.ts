/**
 * useWorkflowInstance — load and manage a workflow instance for a specific
 * module record (e.g. an expense report).
 *
 * Pass the module_code and record_id; the hook finds the active (or most
 * recent) instance and exposes the full timeline with action RPCs.
 *
 * Usage:
 *   const {
 *     instance, tasks, history, loading,
 *     submit, withdraw
 *   } = useWorkflowInstance('expense_reports', reportId);
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../contexts/AuthContext';

// ─── Types ────────────────────────────────────────────────────────────────────

export type InstanceStatus =
  | 'in_progress'
  | 'approved'
  | 'rejected'
  | 'withdrawn'
  | 'cancelled'
  | 'awaiting_clarification';

export interface WorkflowInstance {
  id:              string;
  templateCode:    string;
  templateName:    string;
  moduleCode:      string;
  recordId:        string;
  submittedBy:     string;
  currentStep:     number;
  status:          InstanceStatus;
  metadata:        Record<string, unknown>;
  createdAt:       string;
  updatedAt:       string;
  completedAt:     string | null;
}

export interface WorkflowTaskRow {
  id:          string;
  stepId:      string;
  stepOrder:   number;
  stepName:    string;
  assignedTo:  string;
  assigneeName: string | null;
  status:      string;
  notes:       string | null;
  dueAt:       string | null;
  actedAt:     string | null;
  createdAt:   string;
}

export interface WorkflowActionLogRow {
  id:         string;
  actorId:    string;
  actorName:  string | null;
  action:     string;
  stepOrder:  number | null;
  notes:      string | null;
  createdAt:  string;
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useWorkflowInstance(
  moduleCode: string | null,
  recordId:   string | null,
) {
  const { user } = useAuth();

  const [instance, setInstance] = useState<WorkflowInstance | null>(null);
  const [tasks,    setTasks]    = useState<WorkflowTaskRow[]>([]);
  const [history,  setHistory]  = useState<WorkflowActionLogRow[]>([]);
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!user || !moduleCode || !recordId) {
      setInstance(null);
      setTasks([]);
      setHistory([]);
      return;
    }

    setLoading(true);
    setError(null);

    try {
      // ── Load most recent instance for this record ───────────────────────
      // Uses SECURITY DEFINER RPCs to avoid 500s caused by overlapping RLS
      // policy functions on workflow_instances for ESS employees.
      const { data: instRows, error: instErr } = await supabase
        .rpc('get_my_workflow_instance', {
          p_module_code: moduleCode,
          p_record_id:   recordId,
        });

      if (instErr) throw new Error(instErr.message);

      const instData = (instRows as any[])?.[0] ?? null;

      if (!instData) {
        setInstance(null);
        setTasks([]);
        setHistory([]);
        return;
      }

      setInstance({
        id:           instData.id,
        templateCode: instData.template_code ?? '',
        templateName: instData.template_name ?? '',
        moduleCode:   instData.module_code,
        recordId:     instData.record_id,
        submittedBy:  instData.submitted_by,
        currentStep:  instData.current_step,
        status:       instData.status as InstanceStatus,
        metadata:     (instData.metadata ?? {}) as Record<string, unknown>,
        createdAt:    instData.created_at,
        updatedAt:    instData.updated_at,
        completedAt:  instData.completed_at,
      });

      // ── Load tasks ─────────────────────────────────────────────────────────
      const { data: taskRows } = await supabase
        .rpc('get_my_workflow_tasks', { p_instance_id: instData.id });

      setTasks(
        ((taskRows as any[]) ?? []).map(t => ({
          id:           t.id,
          stepId:       t.step_id,
          stepOrder:    t.step_order,
          stepName:     t.step_name ?? `Step ${t.step_order}`,
          assignedTo:   t.assigned_to,
          assigneeName: t.assignee_name ?? null,
          status:       t.status,
          notes:        t.notes,
          dueAt:        t.due_at,
          actedAt:      t.acted_at,
          createdAt:    t.created_at,
        }))
      );

      // ── Load action log ────────────────────────────────────────────────────
      const { data: logRows } = await supabase
        .rpc('get_my_workflow_action_log', { p_instance_id: instData.id });

      setHistory(
        ((logRows as any[]) ?? []).map(l => ({
          id:        l.id,
          actorId:   l.actor_id,
          actorName: l.actor_name ?? null,
          action:    l.action,
          stepOrder: l.step_order,
          notes:     l.notes,
          createdAt: l.created_at,
        }))
      );
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [user, moduleCode, recordId]);

  useEffect(() => { load(); }, [load]);

  // ── Actions ────────────────────────────────────────────────────────────────

  const submit = useCallback(async (
    templateCode: string,
    metadata: Record<string, unknown>,
  ) => {
    if (!moduleCode || !recordId) throw new Error('moduleCode and recordId are required');

    const { data, error: err } = await supabase.rpc('wf_submit', {
      p_template_code: templateCode,
      p_module_code:   moduleCode,
      p_record_id:     recordId,
      p_metadata:      metadata as any,
    });
    if (err) throw new Error(err.message);
    await load();
    return data as string; // instance id
  }, [moduleCode, recordId, load]);

  const withdraw = useCallback(async (reason?: string) => {
    if (!instance) throw new Error('No active workflow instance');

    const { error: err } = await supabase.rpc('wf_withdraw', {
      p_instance_id: instance.id,
      p_reason:      reason ?? null,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [instance, load]);

  /**
   * resubmit — submitter responds to a clarification request and resumes the
   * workflow from the same step. Only callable when instance.status is
   * 'awaiting_clarification'.
   *
   * proposedData (optional): for profile_* modules, pass the updated field
   * values as a DB-column-keyed object so wf_resubmit can update
   * workflow_pending_changes.proposed_data before resuming (mig 181).
   */
  const resubmit = useCallback(async (
    response?: string,
    proposedData?: Record<string, string | null>,
  ) => {
    if (!instance) throw new Error('No active workflow instance');
    if (instance.status !== 'awaiting_clarification') {
      throw new Error('Instance is not awaiting clarification');
    }

    const { error: err } = await supabase.rpc('wf_resubmit', {
      p_instance_id:    instance.id,
      p_response:       response ?? null,
      p_proposed_data:  proposedData ?? null,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [instance, load]);

  return {
    instance,
    tasks,
    history,
    loading,
    error,
    refresh: load,
    submit,
    withdraw,
    resubmit,
  };
}
