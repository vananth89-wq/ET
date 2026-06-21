/**
 * useRecentlyViewed
 *
 * Manages a per-user, per-device "Recently Viewed Employees" list in localStorage.
 * Key: `prowess.recentlyViewed.${userId}` — scoped per user so switching accounts
 * on the same device doesn't bleed history.
 *
 * - Max 10 entries, sorted by viewed_at DESC.
 * - Self-profile views are NOT added (call addEntry only in employee mode).
 * - Cleared on logout (call clearAll from auth logout flow).
 */

import { useState, useCallback, useEffect } from 'react';
import { useAuth } from '../contexts/AuthContext';

export interface RecentlyViewedEntry {
  employee_id:   string;
  employee_code: string;
  full_name:     string;
  email:         string | null;
  viewed_at:     string;  // ISO timestamp
}

const MAX_ENTRIES = 10;

function storageKey(userId: string): string {
  return `prowess.recentlyViewed.${userId}`;
}

function readEntries(userId: string): RecentlyViewedEntry[] {
  try {
    const raw = localStorage.getItem(storageKey(userId));
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function writeEntries(userId: string, entries: RecentlyViewedEntry[]): void {
  try {
    localStorage.setItem(storageKey(userId), JSON.stringify(entries));
  } catch {
    // localStorage full or unavailable — fail silently
  }
}

interface UseRecentlyViewedResult {
  entries:    RecentlyViewedEntry[];
  addEntry:   (entry: Omit<RecentlyViewedEntry, 'viewed_at'>) => void;
  removeEntry:(employeeId: string) => void;
  clearAll:   () => void;
}

export function useRecentlyViewed(): UseRecentlyViewedResult {
  const { employee: authEmployee } = useAuth();
  const userId = authEmployee?.id ?? '';

  const [entries, setEntries] = useState<RecentlyViewedEntry[]>(() =>
    userId ? readEntries(userId) : []
  );

  // Re-read from storage when user changes (e.g. account switch)
  useEffect(() => {
    setEntries(userId ? readEntries(userId) : []);
  }, [userId]);

  const addEntry = useCallback((entry: Omit<RecentlyViewedEntry, 'viewed_at'>) => {
    if (!userId) return;
    setEntries(prev => {
      // Deduplicate by employee_id, move to front
      const filtered = prev.filter(e => e.employee_id !== entry.employee_id);
      const next: RecentlyViewedEntry[] = [
        { ...entry, viewed_at: new Date().toISOString() },
        ...filtered,
      ].slice(0, MAX_ENTRIES);
      writeEntries(userId, next);
      return next;
    });
  }, [userId]);

  const removeEntry = useCallback((employeeId: string) => {
    if (!userId) return;
    setEntries(prev => {
      const next = prev.filter(e => e.employee_id !== employeeId);
      writeEntries(userId, next);
      return next;
    });
  }, [userId]);

  const clearAll = useCallback(() => {
    if (!userId) return;
    localStorage.removeItem(storageKey(userId));
    setEntries([]);
  }, [userId]);

  return { entries, addEntry, removeEntry, clearAll };
}

/** Clears all recently-viewed entries for a given user ID (call on logout). */
export function clearRecentlyViewedForUser(userId: string): void {
  try {
    localStorage.removeItem(storageKey(userId));
  } catch {
    // ignore
  }
}
