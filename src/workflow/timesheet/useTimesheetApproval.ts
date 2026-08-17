/**
 * useTimesheetApproval — one read for a whole timesheet under approval.
 *
 * Calls time_approval_payload (mig 742), which gates once and returns the
 * header, employee, schedule, holiday calendar and every entry with its project
 * and activity names already resolved. The approval screens therefore never
 * touch timesheet_headers, timesheet_entries, projects, time_types, employees,
 * the schedule or the calendar directly — six of those eight tables have no
 * approver-shaped RLS policy, so reading them here would render an approver
 * outside the management chain a screen full of blanks.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import { buildMonth } from './model';
import type { TsPayload, MonthModel } from './model';

interface Result {
  payload:  TsPayload | null;
  month:    MonthModel | null;
  loading:  boolean;
  /** Set when the RPC refused or failed — render it, do not swallow it. */
  error:    string | null;
  reload:   () => void;
}

export function useTimesheetApproval(headerId: string | null | undefined): Result {
  const [payload, setPayload] = useState<TsPayload | null>(null);
  const [month,   setMonth]   = useState<MonthModel | null>(null);
  const [loading, setLoading] = useState<boolean>(!!headerId);
  const [error,   setError]   = useState<string | null>(null);
  const [nonce,   setNonce]   = useState(0);

  const reload = useCallback(() => setNonce(n => n + 1), []);

  useEffect(() => {
    if (!headerId) { setPayload(null); setMonth(null); setLoading(false); setError(null); return; }

    let alive = true;
    setLoading(true);
    setError(null);

    (async () => {
      const { data, error: err } = await supabase.rpc('time_approval_payload', { p_header_id: headerId });
      if (!alive) return;

      if (err) {
        setError(err.message);
        setPayload(null); setMonth(null); setLoading(false);
        return;
      }

      const p = data as TsPayload | null;

      if (!p || !p.ok) {
        setError(
          p?.error === 'PERMISSION_DENIED'
            ? 'You do not have access to this timesheet.'
            : p?.error === 'NOT_FOUND'
              ? 'That timesheet no longer exists.'
              : 'This timesheet could not be loaded.'
        );
        setPayload(null); setMonth(null); setLoading(false);
        return;
      }

      setPayload(p);
      setMonth(buildMonth(p));
      setLoading(false);
    })();

    return () => { alive = false; };
  }, [headerId, nonce]);

  return { payload, month, loading, error, reload };
}
