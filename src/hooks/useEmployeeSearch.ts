/**
 * useEmployeeSearch
 *
 * Debounced wrapper around the search_employees RPC.
 * Fires after 300ms of no typing, minimum 2 characters.
 *
 * Usage:
 *   const { results, loading, error } = useEmployeeSearch(query, includeInactive);
 */

import { useState, useEffect, useRef } from 'react';
import { supabase }                    from '../lib/supabase';

export interface EmployeeSearchResult {
  employee_id:   string;
  employee_code: string;
  full_name:     string;
  email:         string | null;
  status:        string;
  manager_id:    string | null;
  avatar_url:    string | null;
  similarity:    number;
  /**
   * MIG 740. Whether the SIGNED-IN user may open this person's timesheet, and
   * whether they may change it — user_can('timesheet', …, this employee),
   * evaluated per row by the RPC.
   *
   * It cannot be worked out in the browser. The client permission list is flat:
   * it knows you hold `timesheet.view`, not that the grant is scoped to your
   * direct reports. And the search scope is a DIFFERENT grant from the
   * timesheet scope — HR Analyst searches the whole org and holds no timesheet
   * permission at all — so a row appearing here says nothing about access to
   * the sheet behind it.
   *
   * Optional so a client running against a pre-740 database degrades to "no
   * button" rather than a type error.
   */
  can_view_timesheet?: boolean;
  can_edit_timesheet?: boolean;
}

interface UseEmployeeSearchResult {
  results:  EmployeeSearchResult[];
  loading:  boolean;
  error:    string | null;
}

const DEBOUNCE_MS  = 300;
const MIN_QUERY_LEN = 2;

export function useEmployeeSearch(
  query:           string,
  includeInactive: boolean = false,
): UseEmployeeSearchResult {
  const [results, setResults] = useState<EmployeeSearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState<string | null>(null);

  const timerRef     = useRef<ReturnType<typeof setTimeout> | null>(null);
  const controllerRef = useRef<AbortController | null>(null);

  useEffect(() => {
    // Clear previous timer
    if (timerRef.current) clearTimeout(timerRef.current);

    const trimmed = query.trim();

    if (trimmed.length < MIN_QUERY_LEN) {
      setResults([]);
      setLoading(false);
      setError(null);
      return;
    }

    setLoading(true);
    setError(null);

    timerRef.current = setTimeout(async () => {
      // Cancel any in-flight request
      controllerRef.current?.abort();
      controllerRef.current = new AbortController();

      try {
        const { data, error: rpcError } = await supabase.rpc('search_employees', {
          p_query:            trimmed,
          p_limit:            10,
          p_include_inactive: includeInactive,
        });

        if (rpcError) {
          setError(rpcError.message);
          setResults([]);
        } else {
          setResults((data as EmployeeSearchResult[]) ?? []);
          setError(null);
        }
      } catch (err) {
        if (err instanceof Error && err.name !== 'AbortError') {
          setError('Search failed — please retry.');
          setResults([]);
        }
      } finally {
        setLoading(false);
      }
    }, DEBOUNCE_MS);

    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, [query, includeInactive]);

  return { results, loading, error };
}
