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
  gender:           string | null;
  dob:              string | null;
  photo:            string | null;
  countryCode:      string | null;
  // Job (core employees fields)
  designation:      string | null;
  jobTitle:         string | null;
  deptId:           string | null;
  managerId:        string | null;
  baseCurrencyId:   string | null;
  status:           string;
  locked:           boolean;        // true while record is Pending / in workflow
  createdBy:        string | null;  // auth.uid() of the HR Analyst who created the record
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
//   .select('*, employee_personal(*), employee_contact(*), employee_employment!employee_id(*)')
// FK hint !employee_id required since mig 351 added manager_id → employees (two FKs to same table).
export function mapEmployee(row: EmployeeRow): Employee {
  // employee_personal is now multi-row (effective-dated, mig 315).
  // PostgREST returns an array; pick the currently-active open-ended slice.
  const personalRaw = row.employee_personal;
  const personal: EmployeeRow = Array.isArray(personalRaw)
    ? (personalRaw.find((p: EmployeeRow) =>
        p.effective_to === '9999-12-31' && p.is_active === true)
       ?? personalRaw[0]
       ?? {})
    : (personalRaw ?? {});
  const contact:    EmployeeRow = row.employee_contact ?? {};
  // employee_employment is now multi-row (effective-dated, mig 351).
  // PostgREST returns an array; pick the currently-active open-ended slice.
  const employmentRaw = row.employee_employment;
  const employment: EmployeeRow = Array.isArray(employmentRaw)
    ? (employmentRaw.find((e: EmployeeRow) =>
        e.effective_to === '9999-12-31' && e.is_active === true)
       ?? employmentRaw[0]
       ?? {})
    : (employmentRaw ?? {});

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
    gender:           personal.gender         ?? null,
    dob:              personal.dob            ?? null,
    photo:            personal.photo_url      ?? null,
    // Core employment fields — prefer satellite over base table (mig 456).
    // upsert_employment_info no longer mirrors these to employees base for
    // Draft/Pending records; satellite is authoritative during hire pipeline.
    // Falls back to base table for legacy records pre-dating mig 351.
    designation:      employment.designation      ?? row.designation,
    jobTitle:         employment.job_title         ?? row.job_title,
    deptId:           employment.dept_id           ?? row.dept_id,
    managerId:        employment.manager_id        ?? row.manager_id,
    baseCurrencyId:   employment.base_currency_id  ?? row.base_currency_id,
    status:           row.status,
    locked:           row.locked ?? false,
    hireDate:         employment.hire_date         ?? row.hire_date,
    endDate:          employment.end_date          ?? row.end_date,
    workLocation:     employment.work_location     ?? row.work_location,
    workCountry:      employment.work_country      ?? row.work_country,
    // Employment satellite (satellite-only fields)
    probationEndDate: employment.probation_end_date ?? null,
    // Hire pipeline ownership (mig 253+; null for legacy records)
    createdBy:        row.created_by ?? null,
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
          // employee_employment!employee_id disambiguates the FK hint:
          // mig 351 added manager_id → employees, creating two FKs to the same table.
          // PostgREST requires the hint to know which FK to join on.
          .select('*, employee_personal(*), employee_contact(*), employee_employment!employee_id(*)')
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
