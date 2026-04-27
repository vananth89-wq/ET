import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  useCallback,
  type ReactNode,
} from 'react';
import type { Session, User } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';
import type { Database } from '../types/database';
import { mapEmployee, type Employee } from '../hooks/useEmployees';

// ─── Types ────────────────────────────────────────────────────────────────────

// RoleType is now a plain string matching roles.code (admin, finance, ess, etc.)
// The role_type enum has been removed from the DB in favour of user_roles → roles.code.
type RoleType    = string;
type ProfileRow  = Database['public']['Tables']['profiles']['Row'];

export interface AuthContextValue {
  /** Supabase session (null = signed out, undefined = loading) */
  session:  Session | null;
  /** Supabase auth user */
  user:     User | null;
  /** Profile row from public.profiles */
  profile:  ProfileRow | null;
  /** All roles assigned to this user */
  roles:    RoleType[];
  /**
   * Linked employee record, mapped to camelCase frontend shape.
   * null = not yet linked (or still loading — check profileLoading).
   */
  employee: Employee | null;
  /** True while the initial session check is in flight */
  loading:  boolean;
  /**
   * True while profile/roles/employee are being fetched for an authenticated
   * user. Distinct from `loading` (which gates ProtectedRoute): this prevents
   * role-gated pages and profile pages from flashing "Access Denied" or
   * "Profile not linked" before user data has arrived.
   */
  profileLoading: boolean;

  /** Convenience helpers */
  hasRole:    (role: RoleType) => boolean;
  hasAnyRole: (roles: RoleType[]) => boolean;
  isAdmin:    boolean;
  isFinance:  boolean;
  isManager:  boolean;

  /**
   * Re-trigger profile/roles/employee fetch for the current user.
   * Use when profile data failed to load (e.g. after a DB timeout).
   */
  refetchProfile: () => void;

  /** Sign out and clear all state */
  signOut: () => Promise<void>;
}

// ─── Context ──────────────────────────────────────────────────────────────────

const AuthContext = createContext<AuthContextValue | null>(null);

// ─── Provider ─────────────────────────────────────────────────────────────────

// Returns true if Supabase has written any session to localStorage.
// This is synchronous — no network call — so we can use it to skip the
// loading screen on page refresh when the user is already logged in.
function hasStoredSession(): boolean {
  try {
    return Object.keys(localStorage).some(k => k.endsWith('-auth-token'));
  } catch {
    return false;
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session,  setSession]  = useState<Session | null>(null);
  const [user,     setUser]     = useState<User | null>(null);
  const [profile,  setProfile]  = useState<ProfileRow | null>(null);
  const [roles,    setRoles]    = useState<RoleType[]>([]);
  const [employee, setEmployee] = useState<Employee | null>(null);

  // Track the currently-loaded user ID in a ref so the onAuthStateChange
  // callback can read it without it being a dependency (which would recreate
  // the listener on every user change and cause a second SIGNED_IN flood).
  const loadedUserIdRef = useRef<string | null>(null);

  // Start with loading=false if there's already a stored session so the user
  // stays on the same page during a refresh. Auth verification happens in the
  // background; if the session is bad, onAuthStateChange fires SIGNED_OUT and
  // ProtectedRoute redirects to login with the original path preserved.
  const [loading,        setLoading]        = useState(() => !hasStoredSession());
  // profileLoading tracks whether roles+employee are still being fetched.
  // Starts true if a session exists (we know a fetch will happen), false
  // otherwise (no user = no fetch needed). Cleared after loadUserData finishes.
  const [profileLoading, setProfileLoading] = useState(() => hasStoredSession());

  // Fetch profile + roles + employee for an authenticated user.
  // A 10-second safety timeout ensures profileLoading always clears even if
  // the Supabase requests hang (e.g. idle DB transactions holding locks).
  // The DB-level fix is the idle_in_transaction_session_timeout migration;
  // this timeout is a client-side safety net so the UI never spins forever.
  const loadUserData = useCallback(async (userId: string) => {
    setProfileLoading(true);

    // Safety valve: clear profileLoading after 10s regardless of DB state.
    // The async work may still complete afterward and update state correctly.
    const safetyTimer = setTimeout(() => {
      console.warn('[Auth] Profile load timed out after 10s — clearing loading state');
      setProfileLoading(false);
    }, 10_000);

    try {
      // Run all fetches in parallel — faster than sequential awaits.
      // Roles now come from user_roles → roles.code (single source of truth).
      const [profileResult, roleResult] = await Promise.all([
        supabase.from('profiles').select('*').eq('id', userId).single(),
        supabase
          .from('user_roles')
          .select('roles(code)')
          .eq('profile_id', userId)
          .eq('is_active', true),
      ]);

      if (profileResult.error || !profileResult.data) {
        console.error('[Auth] Profile fetch error:', profileResult.error?.message);
        setProfile(null);
        setRoles([]);
        setEmployee(null);
        return;
      }

      const profileData = profileResult.data;
      setProfile(profileData);

      if (roleResult.error) {
        console.error('[Auth] Roles fetch error:', roleResult.error.message);
        setRoles([]);
      } else {
        // Each row: { roles: { code: 'admin' } }
        setRoles(
          (roleResult.data ?? [])
            .map(r => (r.roles as { code: string } | null)?.code)
            .filter((c): c is string => !!c)
        );
      }

      // Fetch linked employee only if profile has one
      if (profileData.employee_id) {
        const { data: empData, error: empErr } = await supabase
          .from('employees')
          .select('*, employee_personal(*), employee_contact(*), employee_employment(*)')
          .eq('id', profileData.employee_id)
          .single();

        if (empErr) {
          console.error('[Auth] Employee fetch error:', empErr.message);
          setEmployee(null);
        } else {
          setEmployee(empData ? mapEmployee(empData) : null);
        }
      } else {
        setEmployee(null);
      }
    } catch (err) {
      console.error('[Auth] Unexpected error loading user data:', err);
    } finally {
      clearTimeout(safetyTimer);
      setProfileLoading(false);
    }
  }, []);

  // Keep the ref in sync so the auth listener can read the current user ID
  // without needing it as a dependency (which would recreate the subscription).
  useEffect(() => {
    loadedUserIdRef.current = user?.id ?? null;
  }, [user]);

  // Clear all user state on sign-out
  const clearUserData = useCallback(() => {
    setSession(null);
    setUser(null);
    setProfile(null);
    setRoles([]);
    setEmployee(null);
    setProfileLoading(false);
    loadedUserIdRef.current = null;
  }, []);

  // Bootstrap: subscribe to auth state changes.
  // onAuthStateChange fires INITIAL_SESSION immediately on mount with whatever
  // session Supabase finds in storage, then makes a network call only when the
  // token needs refreshing. We don't block the UI on that network call — if the
  // user already has a stored session, loading=false was set above and they stay
  // on the same page. If the token refresh eventually fails, SIGNED_OUT fires
  // and ProtectedRoute sends them to /login with their path preserved.
  useEffect(() => {
    let mounted = true;

    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (_event, s) => {
        if (!mounted) return;

        // ─── TOKEN_REFRESHED: JWT silently renewed ────────────────────────────
        // Only update the session (fresh access token for API calls).
        // Skip all other state — nothing user-facing changed.
        if (_event === 'TOKEN_REFRESHED') {
          setSession(s);
          return;
        }

        // ─── SIGNED_IN for an already-loaded user = tab regained focus ────────
        // Supabase fires SIGNED_IN (not TOKEN_REFRESHED) on every tab focus via
        // _onVisibilityChanged → _recoverAndRefresh → _notifyAllSubscribers.
        // When it's the same user that's already loaded, re-running loadUserData
        // causes a full profile/roles/employee re-fetch and makes the UI flash
        // as if the page reloaded. Skip it — only reload for a genuine new login
        // (different user ID, or no user was loaded yet).
        if (_event === 'SIGNED_IN' && s?.user?.id && s.user.id === loadedUserIdRef.current) {
          setSession(s); // keep session fresh for API calls
          return;
        }

        setSession(s);
        setUser(s?.user ?? null);

        if (s?.user) {
          // ─── Why setTimeout(0)? ───────────────────────────────────────────────
          // supabase-js holds an internal auth lock while firing onAuthStateChange
          // (during _initialize on page-refresh, and during signInWithPassword on
          // fresh login). loadUserData → supabase.from() → auth.getSession() tries
          // to acquire the same lock → deadlock → REST calls hang forever.
          // setTimeout(0) defers loadUserData to the next event-loop tick, after
          // the lock is released, breaking the deadlock entirely.
          setTimeout(() => {
            if (mounted) loadUserData(s.user.id);
          }, 0);
        } else {
          clearUserData();
        }
        // Clear loading immediately — we have a definitive session answer now
        setLoading(false);
      }
    );

    return () => {
      mounted = false;
      subscription.unsubscribe();
    };
  }, [loadUserData, clearUserData]);

  // ── Helpers ─────────────────────────────────────────────────────────────────

  const hasRole    = useCallback((role: RoleType) => roles.includes(role), [roles]);
  const hasAnyRole = useCallback((rs: RoleType[]) => rs.some(r => roles.includes(r)), [roles]);

  // Re-fetch profile data for the current user on demand (e.g. after a timeout)
  const refetchProfile = useCallback(() => {
    if (user?.id) loadUserData(user.id);
  }, [user, loadUserData]);

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
    clearUserData();
  }, [clearUserData]);

  const value: AuthContextValue = {
    session,
    user,
    profile,
    roles,
    employee,
    loading,
    profileLoading,
    hasRole,
    hasAnyRole,
    isAdmin:   roles.includes('admin'),
    isFinance: roles.includes('finance'),
    isManager: roles.includes('manager'),
    refetchProfile,
    signOut,
  };

  return (
    <AuthContext.Provider value={value}>
      {children}
    </AuthContext.Provider>
  );
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>');
  return ctx;
}
