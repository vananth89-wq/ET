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
  /**
   * migs 754 and 755. All are nullable and mean it.
   *
   * projectTypeId null is "not classified", NOT "billable" — defaulting it
   * would make billable utilisation a number computed from a value nobody
   * chose. budgetHours null is a project with no budget, which shows
   * consumption without a percentage rather than against a fake denominator.
   * managerId null grants nobody Project Manager access; it fails closed.
   */
  projectTypeId:   string | null;
  /** Label and stable code, embedded so an INACTIVE picklist value still
   *  renders instead of showing blank. Reports match on typeRefId. */
  projectTypeName: string | null;
  typeRefId:       string | null;
  managerId:       string | null;
  /** Embedded from employees, so the screen never has to load the whole
   *  directory just to print one name. */
  managerName:     string | null;
  budgetHours:     number | null;
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

/**
 * PostgREST returns an embedded to-one relation as an object, but the generated
 * types widen it to object-or-array. These unwrap it in one place rather than
 * casting at four call sites.
 */
function pt(v: unknown): { value: string; ref_id: string | null } | null {
  const o = Array.isArray(v) ? v[0] : v;
  return (o ?? null) as { value: string; ref_id: string | null } | null;
}
function mgr(v: unknown): { name: string; employee_id: string } | null {
  const o = Array.isArray(v) ? v[0] : v;
  return (o ?? null) as { name: string; employee_id: string } | null;
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
          .select(`
            id, name, start_date, end_date, active, manager_id, budget_hours,
            project_type_id,
            project_type:picklist_values!projects_project_type_id_fkey ( value, ref_id ),
            manager:employees!projects_manager_id_fkey ( name, employee_id )
          `)
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
              projectTypeId:   row.project_type_id ?? null,
              projectTypeName: pt(row.project_type)?.value  ?? null,
              typeRefId:       pt(row.project_type)?.ref_id ?? null,
              managerId:       row.manager_id ?? null,
              managerName:     mgr(row.manager)
                                 ? `${mgr(row.manager)!.name} (${mgr(row.manager)!.employee_id})`
                                 : null,
              budgetHours: row.budget_hours === null || row.budget_hours === undefined
                             ? null : Number(row.budget_hours),
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
