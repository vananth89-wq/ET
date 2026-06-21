/**
 * useBulkUploadJob
 *
 * Polls a bulk_upload_job row while status is in-flight (validating / processing).
 * Stops automatically on terminal status.
 */

import { useState, useEffect, useRef, useCallback } from 'react';
import { supabase } from '../lib/supabase';

export interface BulkUploadJob {
  id:                string;
  template_code:     string;
  uploaded_by:       string;
  uploaded_at:       string;
  file_name:         string;
  storage_path:      string;
  row_count:         number;
  valid_count:       number | null;
  warning_count:     number | null;
  error_count:       number | null;
  processed_count:   number;
  succeeded_count:   number;
  failed_count:      number;
  skipped_count:     number;
  status:            'validating' | 'awaiting_user' | 'processing' | 'completed' | 'partial' | 'cancelled' | 'failed';
  cancelled_at:      string | null;
  completed_at:      string | null;
  error_file_path:   string | null;
  notification_sent: boolean;
}

const TERMINAL_STATUSES = new Set(['completed', 'partial', 'cancelled', 'failed']);
const POLL_INTERVAL_MS  = 3000;

export function useBulkUploadJob(jobId: string | null) {
  const [job, setJob]       = useState<BulkUploadJob | null>(null);
  const [loading, setLoading] = useState(false);
  const timerRef            = useRef<ReturnType<typeof setTimeout> | null>(null);

  const fetch = useCallback(async (id: string) => {
    const { data } = await supabase
      .from('bulk_upload_job')
      .select('*')
      .eq('id', id)
      .single();

    if (data) setJob(data as BulkUploadJob);
    return data as BulkUploadJob | null;
  }, []);

  useEffect(() => {
    if (!jobId) { setJob(null); return; }

    setLoading(true);

    async function poll() {
      const latest = await fetch(jobId!);
      setLoading(false);

      if (!latest || TERMINAL_STATUSES.has(latest.status)) return;

      timerRef.current = setTimeout(poll, POLL_INTERVAL_MS);
    }

    poll();

    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, [jobId, fetch]);

  /** Manually refresh (e.g. after user clicks Cancel) */
  const refresh = useCallback(() => {
    if (jobId) fetch(jobId);
  }, [jobId, fetch]);

  return { job, loading, refresh };
}

/** Fetch recent uploads for a template, scoped to current user */
export async function fetchRecentUploads(
  templateCode: string,
  limit  = 25,
  offset = 0,
): Promise<{ jobs: BulkUploadJob[]; hasMore: boolean }> {
  // Fetch one extra to detect if a next page exists
  const { data } = await supabase
    .from('bulk_upload_job')
    .select('*')
    .eq('template_code', templateCode)
    .order('uploaded_at', { ascending: false })
    .range(offset, offset + limit);   // limit+1 rows

  const rows = (data ?? []) as BulkUploadJob[];
  return {
    jobs:    rows.slice(0, limit),
    hasMore: rows.length > limit,
  };
}
