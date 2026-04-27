/**
 * NotificationBell — header bell icon with unread badge + dropdown list
 *
 * Renders in AppHeader for all authenticated users.
 * Clicking the bell opens a dropdown showing the 50 most recent notifications.
 * Unread notifications are highlighted; clicking one marks it as read and
 * navigates to its link (if any).
 * "Mark all as read" clears the badge in one click.
 */

import { useRef, useEffect, useState } from 'react';
import { useNavigate }                 from 'react-router-dom';
import { useNotifications }            from '../../../hooks/useNotifications';
import type { AppNotification }        from '../../../hooks/useNotifications';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function timeAgo(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins  = Math.floor(diff / 60000);
  const hours = Math.floor(diff / 3600000);
  const days  = Math.floor(diff / 86400000);
  if (mins  <  1) return 'just now';
  if (mins  < 60) return `${mins}m ago`;
  if (hours < 24) return `${hours}h ago`;
  if (days  <  7) return `${days}d ago`;
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' });
}

// ─── Single notification row ──────────────────────────────────────────────────

function NotificationRow({
  n,
  onRead,
}: {
  n:      AppNotification;
  onRead: (id: string, link: string | null) => void;
}) {
  return (
    <button
      type="button"
      className={`notif-row ${n.isRead ? 'notif-row-read' : 'notif-row-unread'}`}
      onClick={() => onRead(n.id, n.link)}
    >
      {!n.isRead && <span className="notif-dot" />}
      <div className="notif-content">
        <div className="notif-title">{n.title}</div>
        {n.body && <div className="notif-body">{n.body}</div>}
        <div className="notif-time">{timeAgo(n.createdAt)}</div>
      </div>
    </button>
  );
}

// ─── Bell component ───────────────────────────────────────────────────────────

export default function NotificationBell() {
  const navigate                              = useNavigate();
  const { notifications, unreadCount,
          markAsRead, markAllAsRead, loading } = useNotifications();
  const [open, setOpen]                       = useState(false);
  const wrapRef                               = useRef<HTMLDivElement>(null);

  // Close dropdown on outside click
  useEffect(() => {
    function onClickOutside(e: MouseEvent) {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener('mousedown', onClickOutside);
    return () => document.removeEventListener('mousedown', onClickOutside);
  }, []);

  async function handleRowClick(id: string, link: string | null) {
    await markAsRead([id]);
    setOpen(false);
    if (link) navigate(link);
  }

  async function handleMarkAll() {
    await markAllAsRead();
  }

  return (
    <div className="notif-bell-wrap" ref={wrapRef}>
      {/* ── Bell button ─────────────────────────────────────────────── */}
      <button
        type="button"
        className={`notif-bell-btn ${open ? 'open' : ''}`}
        onClick={() => setOpen(o => !o)}
        aria-label={`Notifications${unreadCount > 0 ? ` (${unreadCount} unread)` : ''}`}
      >
        <i className="fa-solid fa-bell" />
        {unreadCount > 0 && (
          <span className="notif-badge">
            {unreadCount > 99 ? '99+' : unreadCount}
          </span>
        )}
      </button>

      {/* ── Dropdown ────────────────────────────────────────────────── */}
      {open && (
        <div className="notif-dropdown">
          {/* Header */}
          <div className="notif-dropdown-header">
            <span className="notif-dropdown-title">Notifications</span>
            {unreadCount > 0 && (
              <button
                type="button"
                className="notif-mark-all"
                onClick={handleMarkAll}
              >
                Mark all as read
              </button>
            )}
          </div>

          {/* List */}
          <div className="notif-list">
            {loading ? (
              <div className="notif-empty">
                <span className="spinner-sm" /> Loading…
              </div>
            ) : notifications.length === 0 ? (
              <div className="notif-empty">
                <i className="fa-solid fa-bell-slash" style={{ fontSize: 22, color: 'var(--text-tertiary, #9CA3AF)', marginBottom: 8 }} />
                <div>No notifications yet</div>
              </div>
            ) : (
              notifications.map(n => (
                <NotificationRow key={n.id} n={n} onRead={handleRowClick} />
              ))
            )}
          </div>
        </div>
      )}
    </div>
  );
}
