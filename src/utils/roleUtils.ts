// ─────────────────────────────────────────────────────────────────────────────
// Role derivation utilities
// Priority: Dept Head > Manager > Employee
// ─────────────────────────────────────────────────────────────────────────────

export interface RoleEmployee {
  employeeId: string;
  managerId?: string;
  role?: string;
}

export interface RoleDept {
  headId?: string;
}

/** Derive a single employee's role from the current state of all employees + departments. */
export function deriveRole(
  empId: string,
  allEmployees: RoleEmployee[],
  allDepts: RoleDept[]
): string {
  if (allDepts.some(d => d.headId === empId))                                  return 'Dept Head';
  if (allEmployees.some(e => e.managerId === empId && e.employeeId !== empId)) return 'Manager';
  return 'Employee';
}

/**
 * Re-evaluate and update roles for the given employee IDs.
 * Returns a new array with only the affected employees updated.
 */
export function recomputeRoles<T extends RoleEmployee>(
  empIds: (string | undefined | null)[],
  list: T[],
  depts: RoleDept[]
): T[] {
  const ids = new Set(empIds.filter((id): id is string => !!id));
  if (!ids.size) return list;
  return list.map(emp =>
    ids.has(emp.employeeId)
      ? { ...emp, role: deriveRole(emp.employeeId, list, depts) }
      : emp
  );
}
