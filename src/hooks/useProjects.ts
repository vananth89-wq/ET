import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';

// ─── Frontend shape ───────────────────────────────────────────────────────────
export interface Project {
  id:        string;   // UUID
  name:      string;
  startDate: string;
  endDate:   string;
  active:    boolean;
}

// ─── Hook ─────────────────────────────────────────────────────────────────────
interface UseProjectsResult {
  projects: Project[];
  loading:  boolean;
  error:    string | null;
  refetch:  () => void;
}

export function useProjects(activeOnly = false): UseProjectsResult {
  const [projects, setProjects] = useState<Project[]>([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState<string | null>(null);
  const [tick,     setTick]     = useState(0);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    async function load() {
      try {
        let query = supabase
          .from('projects')
          .select('id, name, start_date, end_date, active')
          .order('name', { ascending: true });

        if (activeOnly) {
          query = query.eq('active', true);
        }

        const { data, error: err } = await query;
        if (err) throw err;

        if (mounted) {
          setProjects(
            (data ?? []).map(row => ({
              id:        row.id,
              name:      row.name,
              startDate: row.start_date ?? '',
              endDate:   row.end_date   ?? '',
              active:    row.active,
            }))
          );
        }
      } catch (err: unknown) {
        if (mounted) {
          const msg = err instanceof Error ? err.message : String(err);
          setError(msg);
          setProjects([]);
        }
      } finally {
        if (mounted) setLoading(false);
      }
    }

    load();
    return () => { mounted = false; };
  }, [activeOnly, tick]);

  return { projects, loading, error, refetch };
}
