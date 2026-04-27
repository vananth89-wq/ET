/**
 * ProtectedRoute
 *
 * A route wrapper that enforces two levels of access control:
 *
 *  1. Authentication  — user must be logged in (always checked)
 *  2. Authorization   — user must have the required access (optional)
 *
 * Authorization can be expressed in two ways:
 *
 *  requiredPermission  (preferred — new permissions system)
 *    A single permission code string, e.g. 'expense.approve'.
 *    Uses the PermissionContext can() helper.
 *    Migrate all routes to this as Phase 1 rolls out.
 *
 *  requiredRoles  (legacy — old role-type enum system)
 *    An array of role_type values, e.g. ['admin', 'finance'].
 *    Uses the AuthContext hasAnyRole() helper.
 *    Kept for backward compatibility during the transition period.
 *    Will be removed in a future phase once all routes are migrated.
 *
 * Both props can coexist on the same route during migration; either check
 * passing is sufficient (OR logic — not both required simultaneously).
 */

import { Navigate, useLocation } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { usePermissions } from '../../hooks/usePermissions';
import type { Database } from '../../types/database';

type RoleType = Database['public']['Enums']['role_type'];

interface ProtectedRouteProps {
  children: React.ReactNode;

  /**
   * NEW (preferred): a single permission code the user must hold.
   * Example: requiredPermission="employee.create"
   */
  requiredPermission?: string;

  /**
   * Like requiredPermission but accepts an array — the user must hold
   * AT LEAST ONE of the listed permission codes.
   * Example: requiredAnyPermission={['expense.view_team','expense.view_org']}
   */
  requiredAnyPermission?: string[];

  /**
   * LEGACY: user must have at least one of these role_type values.
   * Example: requiredRoles={['admin', 'finance']}
   * @deprecated Migrate to requiredPermission when possible.
   */
  requiredRoles?: RoleType[];
}

export default function ProtectedRoute({
  children,
  requiredPermission,
  requiredAnyPermission,
  requiredRoles,
}: ProtectedRouteProps) {
  const { session, loading, profileLoading, roles, hasAnyRole, refetchProfile } = useAuth();
  const { can, canAny, permissionsLoading } = usePermissions();
  const location = useLocation();

  // ── Step 1: Wait for session verification ──────────────────────────────────
  // loading is true only on the very first render (cold page load / refresh)
  // while Supabase confirms the stored session against the server.
  if (loading) {
    return (
      <div className="auth-loading">
        <i className="fa-solid fa-spinner fa-spin" />
        <span>Loading…</span>
      </div>
    );
  }

  // ── Step 2: Enforce authentication ─────────────────────────────────────────
  // No session = not logged in. Redirect to /login and remember the intended
  // path so the user lands back here after signing in.
  if (!session) {
    return <Navigate to="/login" state={{ from: location }} replace />;
  }

  // ── Step 3: Wait for authorization data to load ─────────────────────────────
  // For routes that have an access requirement, we must wait for both:
  //   - profileLoading  (profile_roles from AuthContext)
  //   - permissionsLoading (user_roles → permissions from PermissionContext)
  // Without this guard, the route flashes "Access Denied" for a brief moment
  // on page refresh while data is still being fetched in the background.
  const hasAccessRequirement =
    requiredPermission ||
    (requiredAnyPermission && requiredAnyPermission.length > 0) ||
    (requiredRoles && requiredRoles.length > 0);
  const isStillLoading       = profileLoading || permissionsLoading;

  if (hasAccessRequirement && isStillLoading) {
    return (
      <div className="auth-loading">
        <i className="fa-solid fa-spinner fa-spin" />
        <span>Loading…</span>
      </div>
    );
  }

  // ── Step 4: Handle the "loading finished but no data" edge case ─────────────
  // If we required roles but the roles array is empty after loading completed,
  // the Supabase fetch likely timed out. Offer a retry instead of "Access Denied"
  // so the user isn't permanently locked out by a transient DB issue.
  if (requiredRoles && requiredRoles.length > 0 && !profileLoading && roles.length === 0) {
    return (
      <div className="auth-denied">
        <i className="fa-solid fa-triangle-exclamation" style={{ color: '#F59E0B' }} />
        <h2>Could not load permissions</h2>
        <p>Your role information could not be fetched. This is usually temporary.</p>
        <button
          onClick={refetchProfile}
          disabled={profileLoading}
          style={{
            marginTop: 12, padding: '8px 20px', borderRadius: 6,
            border: '1px solid #D1D5DB', background: '#F9FAFB',
            cursor: profileLoading ? 'not-allowed' : 'pointer',
            fontSize: 13, display: 'inline-flex', alignItems: 'center', gap: 6, color: '#374151',
          }}
        >
          {profileLoading
            ? <><i className="fa-solid fa-spinner fa-spin" /> Loading…</>
            : <><i className="fa-solid fa-rotate-right" /> Try again</>}
        </button>
      </div>
    );
  }

  // ── Step 5: Enforce authorization ──────────────────────────────────────────
  // Check the new permission system first (preferred). Fall through to the
  // legacy role check if no permission is specified. A route passes if EITHER
  // check succeeds — this allows gradual migration without breaking anything.
  const passesPermissionCheck    = requiredPermission              ? can(requiredPermission)              : true;
  const passesAnyPermissionCheck = requiredAnyPermission?.length   ? canAny(requiredAnyPermission)        : true;
  const passesRoleCheck          = requiredRoles?.length           ? hasAnyRole(requiredRoles)            : true;

  // If a specific check was requested and it failed → deny access
  const denied =
    (requiredPermission            && !passesPermissionCheck)    ||
    (requiredAnyPermission?.length && !passesAnyPermissionCheck) ||
    (requiredRoles?.length         && !passesRoleCheck);

  if (denied) {
    return (
      <div className="auth-denied">
        <i className="fa-solid fa-lock" />
        <h2>Access Denied</h2>
        <p>You don't have permission to view this page.</p>
        <p className="auth-denied-hint">
          Contact your administrator if you believe this is a mistake.
        </p>
      </div>
    );
  }

  // ── All checks passed — render the protected content ───────────────────────
  return <>{children}</>;
}
