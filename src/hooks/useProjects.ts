import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';

// ─── Frontend shapes ──────────────────────────────────────────────────────────

// Full shape — used by admin Projects management screen (queries base table)
export interface Project {
  id:        string;   // UUID
  name:      string;
  startDate: string;
  endDate:   string;
  active:    boolean;
}

// Lookup shape — used by transactional dropdowns (queries vw_projects_lookup)
// No `active` field: the view already filters to active=true centrally.
export interface ProjectLookup {
  id:        string;   // UUID — always store this FK, never the name
  name:      string;
  startDate: string;   // for date-aware filtering in expense line item form
  endDate:   string;
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


// ─── Lookup hook (transactional dropdowns) ────────────────────────────────────
// Queries vw_projects_lookup — requires projects.lookup permission (ESS has it).
// Returns active projects only. Use this in expense forms, not useProjects().

interface UseProjectsLookupResult {
  projects: ProjectLookup[];
  loading:  boolean;
  error:    string | null;
}

export function useProjectsLookup(): UseProjectsLookupResult {
  const [projects, setProjects] = useState<ProjectLookup[]>([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    supabase
      .from('vw_projects_lookup')
      .select('id, name, start_date, end_date')
      .order('name', { ascending: true })
      .then(({ data, error: err }) => {
        if (!mounted) return;
        if (err) {
          setError(err.message);
          setProjects([]);
        } else {
          setProjects(
            (data ?? []).map(row => ({
              id:        row.id,
              name:      row.name,
              startDate: row.start_date ?? '',
              endDate:   row.end_date   ?? '',
            }))
          );
        }
        setLoading(false);
      });

    return () => { mounted = false; };
  }, []);

  return { projects, loading, error };
}
