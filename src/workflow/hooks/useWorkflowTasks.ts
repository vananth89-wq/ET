/**
 * useWorkflowTasks — pending approval tasks for the current user
 *
 * Queries the vw_wf_pending_tasks view and subscribes to Realtime so the
 * inbox updates immediately when a new task is assigned.
 *
 * Usage:
 *   const { tasks, loading, error, refresh } = useWorkflowTasks();
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../contexts/AuthContext';

// ─── Types ────────────────────────────────────────────────────────────────────

export type SlaStatus = 'on_track' | 'due_soon' | 'overdue';

export interface WorkflowTask {
  taskId:            string;
  instanceId:        string;
  stepName:          string;
  stepOrder:         number;
  templateCode:      string;
  templateName:      string;
  moduleCode:        string;
  recordId:          string;
  metadata:          Record<string, unknown>;
  submittedById:     string;
  submittedByName:   string | null;
  submittedByEmail:  string | null;
  dueAt:             string | null;
  taskCreatedAt:     string;
  slaStatus:         SlaStatus;
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useWorkflowTasks() {
  const { user } = useAuth();

  const [tasks,   setTasks]   = useState<WorkflowTask[]>([]);
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!user) { setTasks([]); return; }

    setLoading(true);
    setError(null);

    const { data, error: err } = await supabase
      .from('vw_wf_pending_tasks')
      .select('*')
      .order('task_created_at', { ascending: true });

    if (err) {
      setError(err.message);
    } else {
      setTasks(
        (data ?? []).map(r => ({
          taskId:           r.task_id,
          instanceId:       r.instance_id,
          stepName:         r.step_name,
          stepOrder:        r.step_order,
          templateCode:     r.template_code,
          templateName:     r.template_name,
          moduleCode:       r.module_code,
          recordId:         r.record_id,
          metadata:         (r.metadata ?? {}) as Record<string, unknown>,
          submittedById:    r.submitted_by,
          submittedByName:  r.submitted_by_name,
          submittedByEmail: r.submitted_by_email,
          dueAt:            r.due_at,
          taskCreatedAt:    r.task_created_at,
          slaStatus:        (r.sla_status as SlaStatus) ?? 'on_track',
        }))
      );
    }

    setLoading(false);
  }, [user]);

  useEffect(() => { load(); }, [load]);

  // Real-time: refresh when new tasks appear or existing tasks change
  useEffect(() => {
    if (!user) return;

    const channel = supabase
      .channel('wf_tasks_inbox')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'workflow_tasks' },
        () => load()
      )
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [user, load]);

  // ── Actions ──────────────────────────────────────────────────────────────────

  const approve = useCallback(async (taskId: string, notes?: string) => {
    const { error: err } = await supabase.rpc('wf_approve', {
      p_task_id: taskId,
      p_notes:   notes ?? null,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [load]);

  const reject = useCallback(async (taskId: string, reason: string) => {
    const { error: err } = await supabase.rpc('wf_reject', {
      p_task_id: taskId,
      p_reason:  reason,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [load]);

  const reassign = useCallback(async (
    taskId: string,
    newProfileId: string,
    reason?: string,
  ) => {
    const { error: err } = await supabase.rpc('wf_reassign', {
      p_task_id:        taskId,
      p_new_profile_id: newProfileId,
      p_reason:         reason ?? null,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [load]);

  const returnToInitiator = useCallback(async (
    taskId: string,
    message: string,
  ) => {
    const { error: err } = await supabase.rpc('wf_return_to_initiator', {
      p_task_id: taskId,
      p_message: message,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [load]);

  const returnToPreviousStep = useCallback(async (
    taskId: string,
    reason?: string,
  ) => {
    const { error: err } = await supabase.rpc('wf_return_to_previous_step', {
      p_task_id: taskId,
      p_reason:  reason ?? null,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [load]);

  return {
    tasks,
    loading,
    error,
    pendingCount: tasks.length,
    refresh: load,
    approve,
    reject,
    reassign,
    returnToInitiator,
    returnToPreviousStep,
  };
}
