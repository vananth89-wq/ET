import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import type { Database } from '../types/database';

type DepartmentRow = Database['public']['Tables']['departments']['Row'];

// ─── Frontend shape ───────────────────────────────────────────────────────────
export interface Department {
  id:             string;   // UUID
  deptId:         string;   // human-readable e.g. DEPT001
  name:           string;
  deletedAt:      string | null;
  parentDeptId:   string | null;  // UUID FK → departments.id
  headEmployeeId: string | null;  // UUID FK → employees.id
  startDate:      string | null;  // ISO date string
  endDate:        string | null;  // ISO date string (9999-12-31 = open-ended)
}

function mapDepartment(
  row: DepartmentRow & Record<string, unknown>,
  idToCode?: Map<string, string>,
): Department {
  const parentUUID = (row.parent_dept_id as string | null) ?? null;
  return {
    id:             row.id,
    deptId:         row.dept_id,
    name:           row.name,
    deletedAt:      row.deleted_at,
    // Translate parent UUID → parent dept_id code so tree builders that key by
    // deptId can resolve parent relationships without needing UUID lookups.
    parentDeptId:   parentUUID && idToCode ? (idToCode.get(parentUUID) ?? null) : parentUUID,
    headEmployeeId: (row.head_employee_id as string | null) ?? null,
    startDate:      (row.start_date       as string | null) ?? null,
    endDate:        (row.end_date         as string | null) ?? null,
  };
}

// ─── Hook ─────────────────────────────────────────────────────────────────────
interface UseDepartmentsResult {
  departments: Department[];
  loading:     boolean;
  error:       string | null;
  refetch:     () => void;
}

export function useDepartments(includeDeleted = false): UseDepartmentsResult {
  const [departments, setDepartments] = useState<Department[]>([]);
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState<string | null>(null);
  const [tick,        setTick]        = useState(0);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    async function load() {
      try {
        let query = supabase
          .from('departments')
          .select('*')
          .order('name', { ascending: true });

        if (!includeDeleted) {
          query = query.is('deleted_at', null);
        }

        const { data, error: err } = await query;
        if (err) throw err;

        // Build id → dept_id (code) map so parentDeptId can be stored as a code
        // instead of a UUID. The tree builder (OrgChart) keys its docMap by deptId
        // (the human-readable code), so parentDeptId must also be the code to allow
        // parent lookups to work correctly.
        const rows = data ?? [];
        const idToCode = new Map(rows.map(r => [r.id, r.dept_id as string]));

        if (mounted) setDepartments(rows.map(row => mapDepartment(row, idToCode)));
      } catch (err: unknown) {
        if (mounted) {
          const msg = err instanceof Error ? err.message : String(err);
          setError(msg);
          setDepartments([]);
        }
      } finally {
        if (mounted) setLoading(false);
      }
    }

    load();
    return () => { mounted = false; };
  }, [includeDeleted, tick]);

  return { departments, loading, error, refetch };
}
