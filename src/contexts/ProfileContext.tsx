/**
 * ProfileContext — Phase 2 of Global Employee Search (mig 504–506)
 *
 * Provides the "viewed employee" identity to every component inside MyProfile,
 * whether in self mode (user views their own profile) or employee mode (HR/manager
 * views another employee's profile via /profile/:employeeId).
 *
 * Shape:
 *   viewedEmployeeId  — UUID of the employee being viewed
 *   isSelf            — true when viewedEmployeeId === currentUser's employee UUID
 *   viewedEmployee    — basic identity record (id, code, name, email, status, etc.)
 *   isLoading         — true while fetching the viewed employee record
 *   error             — fetch error, if any
 *
 * Usage:
 *   const { viewedEmployeeId, isSelf, viewedEmployee } = useProfileContext();
 *
 * The provider is mounted by the /profile/:employeeId? route wrapper in App.tsx.
 * When no :employeeId param is present, viewedEmployeeId defaults to the
 * current user's own employee UUID (self mode).
 */

import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react';
import { supabase } from '../lib/supabase';
import { useAuth }  from './AuthContext';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ViewedEmployee {
  id:            string;
  employee_code: string;
  full_name:     string;
  email:         string | null;
  status:        'Active' | 'Inactive' | string;
  manager_id:    string | null;
  avatar_url:    string | null;
}

export interface ProfileContextValue {
  /** UUID of the employee whose profile is being rendered */
  viewedEmployeeId: string;
  /** True when the viewer IS the viewed employee */
  isSelf:           boolean;
  /** Basic identity record for the viewed employee (null while loading) */
  viewedEmployee:   ViewedEmployee | null;
  /** True while fetching the viewed employee record */
  isLoading:        boolean;
  /** Fetch error, if any */
  error:            Error | null;
}

// ─── Context ──────────────────────────────────────────────────────────────────

const ProfileContext = createContext<ProfileContextValue | null>(null);

// ─── Provider ─────────────────────────────────────────────────────────────────

interface ProfileContextProviderProps {
  /**
   * The employee UUID from the route param (:employeeId).
   * When undefined / null, defaults to the current user's own employee UUID
   * (self mode — identical to today's MyProfile behaviour).
   */
  employeeId?: string | null;
  children:    ReactNode;
}

export function ProfileContextProvider({
  employeeId,
  children,
}: ProfileContextProviderProps) {
  const { employee: authEmployee } = useAuth();

  // Resolve the viewed UUID — fall back to self when no param
  const selfId          = authEmployee?.id ?? null;
  const viewedEmployeeId = employeeId ?? selfId ?? '';
  const isSelf          = !employeeId || employeeId === selfId;

  const [viewedEmployee, setViewedEmployee] = useState<ViewedEmployee | null>(null);
  const [isLoading,      setIsLoading]      = useState(false);
  const [error,          setError]          = useState<Error | null>(null);

  useEffect(() => {
    if (!viewedEmployeeId) return;

    // In self mode, we already have the full employee record from AuthContext.
    // Use it directly to avoid an extra round-trip.
    if (isSelf && authEmployee) {
      setViewedEmployee({
        id:            authEmployee.id,
        employee_code: authEmployee.employeeId,
        full_name:     authEmployee.name,
        email:         (authEmployee.businessEmail as string | null) ?? (authEmployee.email as string | null) ?? null,
        status:        (authEmployee.status as string) ?? 'Active',
        manager_id:    authEmployee.managerId ?? null,
        avatar_url:    authEmployee.photo ?? null,
      });
      setIsLoading(false);
      setError(null);
      return;
    }

    // Employee mode — fetch the basic identity record
    let cancelled = false;
    setIsLoading(true);
    setError(null);

    (async () => {
      const { data, error: fetchError } = await supabase
        .from('employees')
        .select('id, employee_id, name, business_email, status, manager_id')
        // photo_url was dropped from employees in mig 020 — lives on employee_personal satellite
        .eq('id', viewedEmployeeId)
        .maybeSingle();

      if (cancelled) return;

      if (fetchError) {
        setError(new Error(fetchError.message));
        setViewedEmployee(null);
      } else if (data) {
        setViewedEmployee({
          id:            data.id,
          employee_code: data.employee_id,
          full_name:     data.name,
          email:         data.business_email ?? null,
          status:        data.status,
          manager_id:    data.manager_id ?? null,
          avatar_url:    null,  // photo_url not on employees table (moved to employee_personal)
        });
      } else {
        setError(new Error('Employee not found.'));
        setViewedEmployee(null);
      }
      setIsLoading(false);
    })();

    return () => { cancelled = true; };
  }, [viewedEmployeeId, isSelf, authEmployee?.id]);

  const value: ProfileContextValue = {
    viewedEmployeeId,
    isSelf,
    viewedEmployee,
    isLoading,
    error,
  };

  return (
    <ProfileContext.Provider value={value}>
      {children}
    </ProfileContext.Provider>
  );
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useProfileContext(): ProfileContextValue {
  const ctx = useContext(ProfileContext);
  if (!ctx) {
    throw new Error(
      'useProfileContext must be used inside <ProfileContextProvider>. ' +
      'Make sure the /profile route wraps <MyProfile> with the provider.'
    );
  }
  return ctx;
}
