/**
 * useNotifications — real-time in-app notifications
 *
 * Loads the 50 most recent notifications for the current user on mount,
 * then subscribes to Supabase Realtime so new notifications appear instantly
 * without a page refresh.
 *
 * Usage:
 *   const { notifications, unreadCount, markAsRead, markAllAsRead } = useNotifications();
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface AppNotification {
  id:        string;
  title:     string;
  body:      string | null;
  link:      string | null;
  isRead:    boolean;
  createdAt: string;
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useNotifications() {
  const { user } = useAuth();

  const [notifications, setNotifications] = useState<AppNotification[]>([]);
  const [loading,       setLoading]        = useState(false);

  const unreadCount = notifications.filter(n => !n.isRead).length;

  // ── Map DB row → frontend type ─────────────────────────────────────────────
  function mapRow(r: any): AppNotification {
    return {
      id:        r.id,
      title:     r.title,
      body:      r.body      ?? null,
      link:      r.link      ?? null,
      isRead:    r.is_read,
      createdAt: r.created_at,
    };
  }

  // ── Initial load ───────────────────────────────────────────────────────────
  const load = useCallback(async () => {
    if (!user) { setNotifications([]); return; }
    setLoading(true);
    const { data } = await supabase
      .from('notifications')
      .select('id, title, body, link, is_read, created_at')
      .order('created_at', { ascending: false })
      .limit(50);
    setNotifications((data ?? []).map(mapRow));
    setLoading(false);
  }, [user]);

  // ── Realtime subscription ──────────────────────────────────────────────────
  useEffect(() => {
    load();
    if (!user) return;

    const channel = supabase
      .channel(`notifications:${user.id}`)
      .on(
        'postgres_changes',
        {
          event:  'INSERT',
          schema: 'public',
          table:  'notifications',
          filter: `profile_id=eq.${user.id}`,
        },
        payload => {
          // Prepend the new notification so it appears at the top
          setNotifications(prev => [mapRow(payload.new), ...prev].slice(0, 50));
        },
      )
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [user, load]);

  // ── Mark one or many as read ───────────────────────────────────────────────
  const markAsRead = useCallback(async (ids: string[]) => {
    if (ids.length === 0) return;
    // Optimistic update
    setNotifications(prev =>
      prev.map(n => ids.includes(n.id) ? { ...n, isRead: true } : n),
    );
    await supabase
      .from('notifications')
      .update({ is_read: true })
      .in('id', ids);
  }, []);

  // ── Mark all as read ───────────────────────────────────────────────────────
  const markAllAsRead = useCallback(async () => {
    const ids = notifications.filter(n => !n.isRead).map(n => n.id);
    await markAsRead(ids);
  }, [notifications, markAsRead]);

  return {
    notifications,
    unreadCount,
    loading,
    markAsRead,
    markAllAsRead,
    refetch: load,
  };
}
