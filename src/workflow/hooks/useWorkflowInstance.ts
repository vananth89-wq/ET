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
      const { data: instData, error: instErr } = await supabase
        .from('workflow_instances')
        .select(`
          *,
          workflow_templates (code, name)
        `)
        .eq('module_code', moduleCode)
        .eq('record_id',   recordId)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (instErr) throw new Error(instErr.message);

      if (!instData) {
        setInstance(null);
        setTasks([]);
        setHistory([]);
        return;
      }

      const tpl = instData.workflow_templates as { code: string; name: string } | null;

      setInstance({
        id:           instData.id,
        templateCode: tpl?.code ?? '',
        templateName: tpl?.name ?? '',
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
      const { data: taskData } = await supabase
        .from('workflow_tasks')
        .select(`
          *,
          workflow_steps (name),
          assignee:profiles!workflow_tasks_assigned_to_fkey (
            id,
            employees!inner (name)
          )
        `)
        .eq('instance_id', instData.id)
        .order('step_order', { ascending: true })
        .order('created_at', { ascending: true });

      setTasks(
        (taskData ?? []).map(t => ({
          id:           t.id,
          stepId:       t.step_id,
          stepOrder:    t.step_order,
          stepName:     (t.workflow_steps as { name: string } | null)?.name ?? `Step ${t.step_order}`,
          assignedTo:   t.assigned_to,
          assigneeName: (t.assignee as any)?.employees?.name ?? null,
          status:       t.status,
          notes:        t.notes,
          dueAt:        t.due_at,
          actedAt:      t.acted_at,
          createdAt:    t.created_at,
        }))
      );

      // ── Load action log ────────────────────────────────────────────────────
      const { data: logData } = await supabase
        .from('workflow_action_log')
        .select(`
          *,
          actor:profiles!workflow_action_log_actor_id_fkey (
            id,
            employees!inner (name)
          )
        `)
        .eq('instance_id', instData.id)
        .order('created_at', { ascending: true });

      setHistory(
        (logData ?? []).map(l => ({
          id:        l.id,
          actorId:   l.actor_id,
          actorName: (l.actor as any)?.employees?.name ?? null,
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
   */
  const resubmit = useCallback(async (response?: string) => {
    if (!instance) throw new Error('No active workflow instance');
    if (instance.status !== 'awaiting_clarification') {
      throw new Error('Instance is not awaiting clarification');
    }

    const { error: err } = await supabase.rpc('wf_resubmit', {
      p_instance_id: instance.id,
      p_response:    response ?? null,
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
