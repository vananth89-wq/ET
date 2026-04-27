import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';

// ─── Raw DB row (satellite tables embedded via PostgREST FK join) ─────────────
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type EmployeeRow = any;

// ─── Frontend shape (camelCase — matches what existing components expect) ────
export interface Employee {
  // DB identity
  id:               string;   // UUID primary key
  employeeId:       string;   // human-readable EMP001, etc.
  // Personal (from employee_personal satellite table)
  name:             string;
  businessEmail:    string | null;
  personalEmail:    string | null;
  mobile:           string | null;
  nationality:      string | null;
  maritalStatus:    string | null;
  photo:            string | null;
  countryCode:      string | null;
  // Job (core employees fields)
  designation:      string | null;
  jobTitle:         string | null;
  deptId:           string | null;
  managerId:        string | null;
  baseCurrencyId:   string | null;
  status:           string;
  hireDate:         string | null;
  endDate:          string | null;
  probationEndDate: string | null;  // from employee_employment satellite table
  workLocation:     string | null;
  workCountry:      string | null;
  // Auth role (from profile_roles via profiles)
  role:             string | null;
  // Timestamps
  createdAt:        string;
  updatedAt:        string;
  deletedAt:        string | null;
  // Legacy fields (kept for compatibility with older components)
  [key: string]: unknown;
}

// ─── Mapper: DB row (with embedded satellite tables) → frontend Employee ─────
// Row shape when fetched with:
//   .select('*, employee_personal(*), employee_contact(*), employee_employment(*)')
export function mapEmployee(row: EmployeeRow): Employee {
  // Satellite table rows are null when no record exists yet for that employee
  const personal:   EmployeeRow = row.employee_personal   ?? {};
  const contact:    EmployeeRow = row.employee_contact    ?? {};
  const employment: EmployeeRow = row.employee_employment ?? {};

  return {
    id:               row.id,
    employeeId:       row.employee_id,
    name:             row.name,
    businessEmail:    row.business_email,
    // Contact satellite
    personalEmail:    contact.personal_email  ?? null,
    mobile:           contact.mobile          ?? null,
    countryCode:      contact.country_code    ?? null,
    // Personal satellite
    nationality:      personal.nationality    ?? null,
    maritalStatus:    personal.marital_status ?? null,
    photo:            personal.photo_url      ?? null,
    // Core employment fields
    designation:      row.designation,
    jobTitle:         row.job_title,
    deptId:           row.dept_id,
    managerId:        row.manager_id,
    baseCurrencyId:   row.base_currency_id,
    status:           row.status,
    hireDate:         row.hire_date,
    endDate:          row.end_date,
    workLocation:     row.work_location,
    workCountry:      row.work_country,
    // Employment satellite
    probationEndDate: employment.probation_end_date ?? null,
    // Timestamps
    createdAt:        row.created_at,
    updatedAt:        row.updated_at,
    deletedAt:        row.deleted_at,
    role:             null,   // populated by useEmployees join; null when called standalone
  };
}

// ─── Hook ─────────────────────────────────────────────────────────────────────
interface UseEmployeesResult {
  employees: Employee[];
  loading:   boolean;
  error:     string | null;
  refetch:   () => void;
}

export function useEmployees(includeDeleted = false): UseEmployeesResult {
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading,   setLoading]   = useState(true);
  const [error,     setError]     = useState<string | null>(null);
  const [tick,      setTick]      = useState(0);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    async function load() {
      try {
        // Fetch employees and department_heads in parallel.
        // Role is derived dynamically:
        //   "Department Manager" → employee.id in department_heads
        //   "Manager"            → another employee has this id as their manager_id
        //   "Employee"           → neither
        let query = supabase
          .from('employees')
          .select('*, employee_personal(*), employee_contact(*), employee_employment(*)')
          .order('name', { ascending: true });

        if (!includeDeleted) {
          query = query.is('deleted_at', null);
        }

        // Only fetch department_heads records that are active today:
        //   from_date <= today AND (to_date IS NULL OR to_date >= today)
        const today = new Date().toISOString().slice(0, 10);

        const [{ data, error: err }, { data: deptHeadRows }, { data: deptRows }] = await Promise.all([
          query,
          supabase
            .from('department_heads')
            .select('employee_id')
            .lte('from_date', today)
            .or(`to_date.is.null,to_date.gte.${today}`),
          // Fallback: departments.head_employee_id covers employees who are set as dept heads
          // but don't yet have a corresponding department_heads history row (existing data).
          // Use select('*') because database.ts types for departments are outdated and don't
          // include head_employee_id — it exists in the real DB but not in the TS schema.
          supabase
            .from('departments')
            .select('*')
            .is('deleted_at', null),
        ]);

        if (err) throw err;

        const rows = data ?? [];

        // Build a Set of employee UUIDs who are department heads.
        // Union of the history table + the denormalized head_employee_id on departments
        // so that existing data without department_heads rows still resolves correctly.
        const deptHeadIds = new Set<string>([
          ...(deptHeadRows ?? []).map(r => r.employee_id),
          // Cast to any[] since database.ts for departments is outdated (missing columns)
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          ...((deptRows ?? []) as any[])
            .map((r: { head_employee_id?: string | null }) => r.head_employee_id)
            .filter((id): id is string => !!id),
        ]);

        // Build a Set of employee IDs that are someone's manager
        const managerIds = new Set(rows.map(r => r.manager_id).filter(Boolean) as string[]);

        if (mounted) {
          setEmployees(rows.map((row) => {
            let role: string;
            if (deptHeadIds.has(row.id)) {
              role = 'Department Manager';
            } else if (managerIds.has(row.id)) {
              role = 'Manager';
            } else {
              role = 'Employee';
            }
            return { ...mapEmployee(row), role };
          }));
        }
      } catch (err: unknown) {
        if (mounted) {
          const msg = err instanceof Error ? err.message : String(err);
          setError(msg);
          setEmployees([]);
        }
      } finally {
        if (mounted) setLoading(false);
      }
    }

    load();
    return () => { mounted = false; };
  }, [includeDeleted, tick]);

  return { employees, loading, error, refetch };
}
