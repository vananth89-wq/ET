/**
 * useTerminationData
 *
 * Fetches the current termination record + active reversal (if any) for one employee.
 * Wraps get_employee_terminations() RPC (mig 489).
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';

export interface TerminationAttachment {
  id: string;
  file_name: string;
  original_file_name: string;
  file_path: string;
  file_size_bytes: number | null;
  mime_type: string | null;
  uploaded_at: string;
}

export interface TerminationRecord {
  id: string;
  employee_id: string;
  separation_date: string;
  notice_expiry_date: string | null;
  notice_period_days_snapshot: number;
  termination_reason_code: string;
  termination_initiation_type: 'SELF' | 'MANAGER_INITIATED' | 'HR_INITIATED' | 'ADMIN_INITIATED' | 'SYSTEM_INITIATED';
  last_working_date: string | null;
  notice_period_waived: boolean;
  notice_period_waiver_reason: string | null;
  eligible_for_rehire: boolean;
  regrettable_termination: boolean | null;
  comments: string;
  workflow_status: 'DRAFT' | 'PENDING' | 'APPROVED' | 'REJECTED' | 'WITHDRAWN' | 'REVERSED';
  workflow_instance_id: string | null;
  approved_at: string | null;
  approved_by: string | null;
  final_settlement_processed: boolean;
  final_settlement_date: string | null;
  submitted_at: string | null;
  created_at: string;
  updated_at: string;
  attachments: TerminationAttachment[];
}

export interface ReversalRecord {
  id: string;
  termination_id: string;
  reversal_reason: string;
  comments: string;
  workflow_status: 'DRAFT' | 'PENDING' | 'APPROVED' | 'REJECTED' | 'WITHDRAWN';
  workflow_instance_id: string | null;
  approved_at: string | null;
  created_at: string;
}

interface UseTerminationDataResult {
  termination: TerminationRecord | null;
  reversal: ReversalRecord | null;
  loading: boolean;
  error: string;
  refetch: () => void;
}

export function useTerminationData(employeeId: string | null): UseTerminationDataResult {
  const [termination, setTermination] = useState<TerminationRecord | null>(null);
  const [reversal,    setReversal]    = useState<ReversalRecord | null>(null);
  const [loading,     setLoading]     = useState(false);
  const [error,       setError]       = useState('');
  const [tick,        setTick]        = useState(0);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  useEffect(() => {
    if (!employeeId) return;
    let cancelled = false;

    (async () => {
      setLoading(true);
      setError('');

      const { data, error: err } = await supabase.rpc('get_employee_terminations', {
        p_employee_id: employeeId,
      });

      if (cancelled) return;

      if (err) {
        setError(err.message);
        setLoading(false);
        return;
      }

      const payload = data as { ok: boolean; termination: TerminationRecord | null; reversal: ReversalRecord | null } | null;

      if (!payload?.ok) {
        setError('Failed to load termination data');
      } else {
        setTermination(payload.termination ?? null);
        setReversal(payload.reversal ?? null);
      }
      setLoading(false);
    })();

    return () => { cancelled = true; };
  }, [employeeId, tick]);

  return { termination, reversal, loading, error, refetch };
}
