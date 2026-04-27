/**
 * PermissionContext
 *
 * Answers the question: WHAT can the current user do?
 * (AuthContext answers: WHO is the current user?)
 *
 * This context loads the full list of permission codes for the logged-in user
 * once on login, caches them in a Set for O(1) lookups, and exposes three
 * simple helpers — can / canAny / canAll — that every component uses instead
 * of checking role names directly.
 *
 * Design principles:
 *  - Never check role names in UI code. Always use can('permission.code').
 *  - Permissions are loaded via the get_my_permissions() Postgres RPC, which
 *    joins user_roles → role_permissions → permissions server-side.
 *  - The Set<string> is rebuilt whenever the user changes (login / logout).
 *  - permissionsLoading prevents route guards from flashing "Access Denied"
 *    while the initial fetch is in flight.
 */

import {
  createContext,
  useContext,
  useEffect,
  useState,
  useCallback,
  type ReactNode,
} from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from './AuthContext';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface PermissionContextValue {
  /**
   * Full list of permission codes the current user holds.
   * Example: ['expense.create', 'expense.submit', 'employee.view_own']
   * Use this for display purposes (e.g. Permission Catalog screen).
   * For runtime checks, use can() — it is faster (Set lookup).
   */
  permissions: string[];

  /**
   * True while permissions are being fetched from Supabase.
   * Always check this before rendering permission-gated UI to avoid flashes.
   */
  permissionsLoading: boolean;

  /**
   * Returns true if the user has the given permission code.
   * This is the primary way to gate any UI element or action.
   *
   * @example
   *   const { can } = usePermissions();
   *   if (can('expense.approve')) { ... }
   */
  can: (permission: string) => boolean;

  /**
   * Returns true if the user has AT LEAST ONE of the given permissions.
   * Useful for showing sections accessible by multiple roles.
   *
   * @example
   *   canAny(['expense.approve', 'expense.final_approve'])
   */
  canAny: (permissions: string[]) => boolean;

  /**
   * Returns true if the user has ALL of the given permissions.
   * Useful for features that require combined capabilities.
   *
   * @example
   *   canAll(['report.view', 'report.export'])
   */
  canAll: (permissions: string[]) => boolean;
}

// ─── Context ──────────────────────────────────────────────────────────────────

const PermissionContext = createContext<PermissionContextValue | null>(null);

// ─── Provider ─────────────────────────────────────────────────────────────────

export function PermissionProvider({ children }: { children: ReactNode }) {
  // useAuth() is safe here because PermissionProvider is rendered INSIDE
  // AuthProvider (see main.tsx). It subscribes to user changes automatically.
  const { user, profileLoading } = useAuth();

  // Permissions stored as both an array (for display/iteration) and a Set
  // (for O(1) has() lookups used by can / canAny / canAll).
  const [permissions,        setPermissions]        = useState<string[]>([]);
  const [permissionSet,      setPermissionSet]      = useState<Set<string>>(new Set());
  const [permissionsLoading, setPermissionsLoading] = useState(false);

  // ── Load permissions ────────────────────────────────────────────────────────
  //
  // Runs whenever the authenticated user changes (login / logout / token refresh).
  // We defer until AuthContext finishes loading profile/roles to avoid a race
  // condition where permissions load before user_roles backfill completes.
  useEffect(() => {
    // No user logged in — clear all state immediately
    if (!user) {
      setPermissions([]);
      setPermissionSet(new Set());
      setPermissionsLoading(false);
      return;
    }

    // AuthContext is still fetching profile/roles — wait for it to settle
    // before querying permissions, so user_roles rows are guaranteed to exist.
    if (profileLoading) return;

    let mounted = true;

    async function loadPermissions() {
      setPermissionsLoading(true);

      try {
        // Call the get_my_permissions() PostgreSQL function.
        // It joins: user_roles → role_permissions → permissions
        // and returns the distinct permission codes for the current user,
        // excluding any user_roles rows that have already expired.
        const { data, error } = await supabase.rpc('get_my_permissions');

        if (!mounted) return;

        if (error) {
          console.error('[Permissions] Failed to load permissions:', error.message);
          setPermissions([]);
          setPermissionSet(new Set());
          return;
        }

        // data is string[] | null — normalise to always be an array
        const codes = (data as string[] | null) ?? [];
        setPermissions(codes);
        setPermissionSet(new Set(codes));
      } catch (err) {
        console.error('[Permissions] Unexpected error loading permissions:', err);
        if (mounted) {
          setPermissions([]);
          setPermissionSet(new Set());
        }
      } finally {
        if (mounted) setPermissionsLoading(false);
      }
    }

    loadPermissions();

    // Cleanup: ignore stale responses if the user changes mid-flight
    return () => { mounted = false; };
  }, [user, profileLoading]);

  // ── Capability helpers ──────────────────────────────────────────────────────
  // All wrapped in useCallback so they are stable references across renders,
  // preventing unnecessary re-renders in memoized child components.

  /** True if the user holds this exact permission code. */
  const can = useCallback(
    (permission: string) => permissionSet.has(permission),
    [permissionSet],
  );

  /** True if the user holds at least one of the given permission codes. */
  const canAny = useCallback(
    (ps: string[]) => ps.some(p => permissionSet.has(p)),
    [permissionSet],
  );

  /** True if the user holds every one of the given permission codes. */
  const canAll = useCallback(
    (ps: string[]) => ps.every(p => permissionSet.has(p)),
    [permissionSet],
  );

  // ── Context value ───────────────────────────────────────────────────────────

  const value: PermissionContextValue = {
    permissions,
    permissionsLoading,
    can,
    canAny,
    canAll,
  };

  return (
    <PermissionContext.Provider value={value}>
      {children}
    </PermissionContext.Provider>
  );
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

/**
 * usePermissions — access the current user's capability helpers.
 *
 * Must be used inside <PermissionProvider> (already set up in main.tsx).
 *
 * @example
 *   const { can, canAny, permissionsLoading } = usePermissions();
 *   if (can('expense.approve')) { ... }
 */
export function usePermissions(): PermissionContextValue {
  const ctx = useContext(PermissionContext);
  if (!ctx) {
    throw new Error(
      'usePermissions() must be called inside a <PermissionProvider>. ' +
      'Make sure PermissionProvider wraps your component tree in main.tsx.',
    );
  }
  return ctx;
}
