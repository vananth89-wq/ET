/**
 * usePermissionsForEmployee
 *
 * Returns a `canFor(permissionCode)` function that answers:
 * "Can the current user perform this action on THIS specific employee?"
 *
 * Self mode  (isSelf=true):  re-uses the existing client-side permission Set
 *   from PermissionContext — zero extra network calls, O(1) lookups.
 *
 * Employee mode (isSelf=false):  calls check_permission_for_target() for each
 *   permission code in the provided list (via Promise.all — one round-trip per
 *   code, but all fired in parallel). Result is cached in a Set until employeeId
 *   or isSelf changes.
 *
 * Usage:
 *   const { canFor, loading } = usePermissionsForEmployee(viewedEmployeeId, isSelf);
 *   const canEdit = canFor('personal_info.edit');
 *
 * The permissionCodes list should include every code that MyProfile calls canFor()
 * with. Pass it as a stable reference (useMemo or module-level constant) to avoid
 * triggering unnecessary re-fetches.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase }                          from '../lib/supabase';
import { usePermissions }                    from './usePermissions';

// ─── All permission codes used in MyProfile ────────────────────────────────
// Keep this list in sync with any new can() calls added to MyProfile.
// Used as the default fetch list in employee mode.
export const MYPROFILE_PERMISSION_CODES: string[] = [
  // Section visibility (SECTIONS array + explicit guards)
  'personal_info.view',
  'contact_info.view',
  'employment.view',
  'address.view',
  'passport.view',
  'identity_documents.view',
  'emergency_contacts.view',
  'bank_accounts.view',
  'dependents.view',
  'job_relationships.view',
  'education.view',
  'termination.view',
  // Edit permissions
  'personal_info.create',
  'personal_info.edit',
  'personal_info.history',
  'contact_info.edit',
  'employment.create',
  'employment.edit',
  'employment.history',
  'address.edit',
  'passport.edit',
  'identity_documents.edit',
  'emergency_contacts.edit',
  'bank_accounts.create',
  'bank_accounts.edit',
  'bank_accounts.delete',
  'dependents.edit',
  'dependents.delete',
  'job_relationships.edit',
  'job_relationships.create',
  'job_relationships.delete',
  'job_relationships.history',
  'education.edit',
  'education.create',
  'education.delete',
  'termination.edit',
  'termination.history',
  // Delete permissions
  'personal_info.delete',
  'contact_info.delete',
  'employment.delete',
  'address.delete',
  'passport.delete',
  'identity_documents.delete',
  'emergency_contacts.delete',
  'termination.delete',
];

// ─── Hook ──────────────────────────────────────────────────────────────────

interface UsePermissionsForEmployeeResult {
  /**
   * Returns true if the current user has the given permission for the
   * viewed employee. In self mode this is an O(1) client-side Set lookup.
   * In employee mode this reads from a prefetched Set (available after loading).
   */
  canFor:  (permissionCode: string) => boolean;
  /** True while the employee-mode permission batch is being fetched */
  loading: boolean;
}

export function usePermissionsForEmployee(
  employeeId: string,
  isSelf:     boolean,
  permissionCodes: string[] = MYPROFILE_PERMISSION_CODES,
): UsePermissionsForEmployeeResult {
  const { can, permissionsLoading } = usePermissions();

  // Employee-mode: Set of granted permission codes for this target
  const [permSet,  setPermSet]  = useState<Set<string>>(new Set());
  const [loading,  setLoading]  = useState(!isSelf);

  useEffect(() => {
    if (isSelf || !employeeId) {
      // Self mode — no fetch needed, client-side Set is authoritative
      setLoading(false);
      return;
    }

    let cancelled = false;
    setLoading(true);

    const checks = permissionCodes.map(code => {
      const [module, action] = code.split('.');
      return supabase
        .rpc('check_permission_for_target', {
          p_module:             module,
          p_action:             action ?? null,
          p_target_employee_id: employeeId,
        })
        .then(({ data }) => ({ code, granted: data === true }));
    });

    Promise.all(checks).then(results => {
      if (cancelled) return;
      const granted = new Set(
        results.filter(r => r.granted).map(r => r.code)
      );
      setPermSet(granted);
      setLoading(false);
    }).catch(err => {
      if (cancelled) return;
      console.warn('[usePermissionsForEmployee] batch fetch error:', err);
      setLoading(false);
    });

    return () => { cancelled = true; };
  }, [employeeId, isSelf, permissionCodes]);

  const canFor = useCallback(
    (permissionCode: string): boolean => {
      if (isSelf) return can(permissionCode);
      return permSet.has(permissionCode);
    },
    [isSelf, can, permSet],
  );

  return {
    canFor,
    loading: isSelf ? permissionsLoading : loading,
  };
}
