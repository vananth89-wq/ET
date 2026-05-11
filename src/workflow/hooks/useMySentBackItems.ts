/**
 * useMySentBackItems — workflow instances sent back to the current user for clarification
 *
 * Queries vw_wf_my_requests filtered by status = 'awaiting_clarification'.
 * Subscribes to Realtime on workflow_instances so the Sent Back tab updates
 * immediately when an approver returns a request or the submitter responds.
 *
 * Usage:
 *   const { items, loading, sentBackCount, refresh, update, respond, withdraw } = useMySentBackItems();
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../contexts/AuthContext';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface SentBackItem {
  instanceId:           string;
  moduleCode:           string;
  recordId:             string;
  metadata:             Record<string, unknown>;
  templateCode:         string;
  templateName:         string;
  submittedAt:          string;
  updatedAt:            string;
  clarificationMessage: string;
  clarificationFrom:    string | null;
  clarificationAt:      string;
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useMySentBackItems() {
  const { user } = useAuth();

  const [items,   setItems]   = useState<SentBackItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!user) { setItems([]); return; }

    setLoading(true);
    setError(null);

    const { data, error: err } = await supabase
      .from('vw_wf_my_requests')
      .select('*')
      .eq('status', 'awaiting_clarification')
      .order('updated_at', { ascending: false });

    if (err) {
      setError(err.message);
    } else {
      setItems(
        (data ?? []).map(r => ({
          instanceId:           r.id,
          moduleCode:           r.module_code,
          recordId:             r.record_id,
          metadata:             (r.metadata ?? {}) as Record<string, unknown>,
          templateCode:         r.template_code,
          templateName:         r.template_name,
          submittedAt:          r.submitted_at,
          updatedAt:            r.updated_at,
          clarificationMessage: r.clarification_message ?? '',
          clarificationFrom:    r.clarification_from    ?? null,
          clarificationAt:      r.clarification_at      ?? r.updated_at,
        }))
      );
    }

    setLoading(false);
  }, [user]);

  useEffect(() => { load(); }, [load]);

  // Real-time: refresh when an instance status changes
  // (approver sends back → status becomes awaiting_clarification;
  //  submitter responds → status returns to in_progress)
  useEffect(() => {
    if (!user) return;

    const channel = supabase
      .channel('wf_sent_back_inbox')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'workflow_instances' },
        () => load()
      )
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [user, load]);

  // ── Actions ──────────────────────────────────────────────────────────────────

  /**
   * Unlocks the module record for editing (sets status → needs_update).
   * Returns module_code and record_id so the caller can navigate to the
   * correct edit form with ?resume_instance={instanceId}.
   */
  const update = useCallback(async (
    instanceId: string
  ): Promise<{ moduleCode: string; recordId: string }> => {
    const { data, error: err } = await supabase
      .rpc('wf_prepare_update', { p_instance_id: instanceId })
      .single();
    if (err) throw new Error(err.message);
    const row = data as { module_code: string; record_id: string };
    return { moduleCode: row.module_code, recordId: row.record_id };
  }, []);

  /** Submitter responds to clarification and resumes the workflow */
  const respond = useCallback(async (instanceId: string, response?: string) => {
    const { error: err } = await supabase.rpc('wf_resubmit', {
      p_instance_id: instanceId,
      p_response:    response ?? null,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [load]);

  /** Submitter withdraws the request entirely */
  const withdraw = useCallback(async (instanceId: string, reason?: string) => {
    const { error: err } = await supabase.rpc('wf_withdraw', {
      p_instance_id: instanceId,
      p_reason:      reason ?? null,
    });
    if (err) throw new Error(err.message);
    await load();
  }, [load]);

  return {
    items,
    loading,
    error,
    sentBackCount: items.length,
    refresh: load,
    update,
    respond,
    withdraw,
  };
}
