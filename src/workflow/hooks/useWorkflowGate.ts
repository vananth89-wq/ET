/**
 * useWorkflowGate — checks whether a workflow assignment is active for a module,
 * and how many change requests are currently pending approval.
 *
 * Usage in any screen:
 *
 *   const { hasWorkflow, pendingCount, loading } = useWorkflowGate('department_edit');
 *
 *   // Show a banner when hasWorkflow is true, intercept save to submit workflow.
 *   // When pendingCount > 0 the banner also surfaces how many are in flight.
 *
 * When an admin configures a workflow assignment for this module in the
 * Workflow Assignments screen, hasWorkflow automatically becomes true and the
 * screen's save action should route through the workflow engine.
 */

import { useState, useEffect } from 'react';
import { supabase }            from '../../lib/supabase';

interface WorkflowGateResult {
  hasWorkflow:  boolean;
  loading:      boolean;
  templateId:   string | null;   // resolved template UUID if assigned, else null
  pendingCount: number;          // in-flight change requests for this module
}

export function useWorkflowGate(moduleCode: string): WorkflowGateResult {
  const [hasWorkflow,  setHasWorkflow]  = useState(false);
  const [loading,      setLoading]      = useState(true);
  const [templateId,   setTemplateId]   = useState<string | null>(null);
  const [pendingCount, setPendingCount] = useState(0);

  useEffect(() => {
    if (!moduleCode) { setLoading(false); return; }

    const today = new Date().toISOString().slice(0, 10);

    // Run both queries in parallel — assignment check + pending count
    Promise.all([
      supabase
        .from('workflow_assignments')
        .select('wf_template_id')
        .eq('module_code', moduleCode)
        .eq('is_active', true)
        .lte('effective_from', today)
        .or(`effective_to.is.null,effective_to.gte.${today}`)
        .limit(1),
      supabase
        .rpc('get_pending_count', { p_module_code: moduleCode }),
    ]).then(([assignmentRes, countRes]) => {
      const found = (assignmentRes.data ?? []).length > 0;
      setHasWorkflow(found);
      setTemplateId(found ? (assignmentRes.data![0].wf_template_id as string) : null);
      setPendingCount((countRes.data as number) ?? 0);
      setLoading(false);
    });
  }, [moduleCode]);

  return { hasWorkflow, loading, templateId, pendingCount };
}
