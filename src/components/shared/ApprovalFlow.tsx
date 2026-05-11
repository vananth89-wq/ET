import { Fragment, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import type { WorkflowInstance, WorkflowTaskRow } from '../../workflow/hooks/useWorkflowInstance';

// Strip common suffixes to shorten step names for the progress bar
// e.g. "Manager Approval" → "Manager", "Finance Review" → "Finance"
function shortenName(name: string): string {
  return name
    .replace(/\s+approval$/i, '')
    .replace(/\s+review$/i, '')
    .replace(/\s+sign[-\s]?off$/i, '')
    .replace(/\s+check$/i, '')
    .replace(/\s+verification$/i, '')
    .trim();
}

type StepState = 'done' | 'active' | 'pending' | 'rejected';

interface StepNode {
  key:   string;
  label: string;
  state: StepState;
}

interface Props {
  instance: WorkflowInstance | null;
  tasks:    WorkflowTaskRow[];
}

export default function ApprovalFlow({ instance, tasks }: Props) {
  // For draft state (no instance yet) — fetch template steps to show pending flow.
  //
  // WHY RPC instead of direct workflow_steps query?
  // ────────────────────────────────────────────────
  // Migration 153 tightened workflow_steps SELECT to user_can('wf_templates','view').
  // ESS users don't have that permission, so a direct .from('workflow_steps') query
  // silently returns [] — the draft progress bar showed no steps for ESS users.
  // get_workflow_participants() is SECURITY DEFINER and bypasses that RLS, returning
  // only the display-safe step names needed for the progress bar.
  const [templateSteps, setTemplateSteps] = useState<{ key: string; label: string }[]>([]);

  useEffect(() => {
    if (instance || tasks.length > 0) {
      setTemplateSteps([]);
      return;
    }

    let cancelled = false;

    supabase
      .rpc('get_workflow_participants', { p_module_code: 'expense_reports' })
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) {
          console.error('[ApprovalFlow] RPC error:', error);
          return;
        }
        const participants = (data ?? []) as {
          stepOrder: number;
          stepName:  string;
          isCC:      boolean;
        }[];
        setTemplateSteps(
          participants
            .filter(p => !p.isCC)                         // exclude CC/notification steps
            .sort((a, b) => a.stepOrder - b.stepOrder)    // RPC already orders, defensive sort
            .map(p => ({
              key:   String(p.stepOrder),
              label: shortenName(p.stepName),
            }))
        );
      });

    return () => { cancelled = true; };
  }, [instance, tasks.length]);

  // ── Build the submitted node ──────────────────────────────────────
  const submittedNode: StepNode = {
    key:   'submitted',
    label: 'Submitted',
    state: instance ? 'done' : 'pending',
  };

  // ── Build step nodes ──────────────────────────────────────────────
  let stepNodes: StepNode[];

  if (tasks.length > 0) {
    // Instance exists — derive state from actual task statuses.
    // Group by step_order and take the latest task (handles re-delegations).
    const byStep = new Map<number, WorkflowTaskRow>();
    for (const t of tasks) {
      const existing = byStep.get(t.stepOrder);
      if (!existing || t.createdAt > existing.createdAt) {
        byStep.set(t.stepOrder, t);
      }
    }

    stepNodes = [...byStep.entries()]
      .sort(([a], [b]) => a - b)
      .map(([order, task]): StepNode => {
        let state: StepState = 'pending';
        if (instance?.status === 'approved') {
          state = 'done';
        } else if (task.status === 'approved') {
          state = 'done';
        } else if (task.status === 'rejected') {
          state = 'rejected';
        } else if (instance && order === instance.currentStep) {
          state = 'active';
        }
        return { key: task.stepId, label: shortenName(task.stepName), state };
      });
  } else {
    // No instance yet — show template steps all as pending
    stepNodes = templateSteps.map(s => ({ ...s, state: 'pending' as StepState }));
  }

  const nodes: StepNode[] = [submittedNode, ...stepNodes];

  // ── Render ────────────────────────────────────────────────────────
  return (
    <div className="exp-flow-steps">
      {nodes.map((node, i) => {
        const icon =
          node.state === 'done'     ? 'fa-circle-check' :
          node.state === 'active'   ? 'fa-circle-dot'   :
          node.state === 'rejected' ? 'fa-circle-xmark' :
                                      'fa-circle';

        const nextState = nodes[i + 1]?.state;
        const connectorDone =
          nextState === 'done' || nextState === 'rejected'
            ? ' exp-flow-connector--done' : '';

        return (
          <Fragment key={node.key}>
            <div className={`exp-flow-step exp-flow-step--${node.state}`}>
              <i className={`fa-solid ${icon}`} />
              <span>{node.label}</span>
            </div>
            {i < nodes.length - 1 && (
              <div className={`exp-flow-connector${connectorDone}`} />
            )}
          </Fragment>
        );
      })}
    </div>
  );
}
