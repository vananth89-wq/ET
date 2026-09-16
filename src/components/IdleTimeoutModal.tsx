import { useEffect } from 'react';

// ─── Types ────────────────────────────────────────────────────────────────────

interface IdleTimeoutModalProps {
  secondsLeft: number;
  onStayLoggedIn: () => void;
  onLogOut: () => void;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatCountdown(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return m > 0
    ? `${m}:${String(s).padStart(2, '0')}`
    : `${s}`;
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * Full-screen overlay shown when the user has been idle for 28 minutes.
 * Counts down 2 minutes; user can either extend the session or log out now.
 */
export function IdleTimeoutModal({
  secondsLeft,
  onStayLoggedIn,
  onLogOut,
}: IdleTimeoutModalProps) {
  // Prevent background scroll while modal is open
  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prev;
    };
  }, []);

  const countdown = formatCountdown(secondsLeft);
  const isUrgent  = secondsLeft <= 30;

  return (
    <div style={styles.overlay}>
      <div style={styles.card} role="dialog" aria-modal="true" aria-labelledby="idle-title">
        {/* Icon */}
        <div style={styles.iconWrap}>
          <i
            className="fa fa-clock-o"
            style={{ fontSize: 32, color: isUrgent ? '#e53e3e' : '#d97706' }}
            aria-hidden="true"
          />
        </div>

        {/* Title */}
        <h2 id="idle-title" style={styles.title}>
          Session Expiring Soon
        </h2>

        {/* Body */}
        <p style={styles.body}>
          You've been inactive for a while. To keep your session secure,
          you'll be automatically signed out in:
        </p>

        {/* Countdown */}
        <div
          style={{
            ...styles.countdown,
            color: isUrgent ? '#e53e3e' : '#1a56db',
            borderColor: isUrgent ? '#fbd5d5' : '#e1effe',
            backgroundColor: isUrgent ? '#fff5f5' : '#eff6ff',
          }}
          aria-live="polite"
          aria-atomic="true"
        >
          <span style={styles.countdownLabel}>seconds remaining</span>
          <span style={styles.countdownNumber}>{countdown}</span>
          <span style={styles.countdownLabel}>
            {secondsLeft === 1 ? 'second' : 'seconds'}
          </span>
        </div>

        {/* Actions */}
        <div style={styles.actions}>
          <button
            style={styles.primaryBtn}
            onClick={onStayLoggedIn}
            autoFocus
          >
            Stay Logged In
          </button>
          <button
            style={styles.secondaryBtn}
            onClick={onLogOut}
          >
            Log Out Now
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = {
  overlay: {
    position: 'fixed' as const,
    inset: 0,
    zIndex: 9999,
    backgroundColor: 'rgba(0, 0, 0, 0.55)',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    padding: '16px',
    backdropFilter: 'blur(2px)',
  },

  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    boxShadow: '0 20px 60px rgba(0,0,0,0.25)',
    padding: '36px 32px 28px',
    maxWidth: 420,
    width: '100%',
    textAlign: 'center' as const,
    fontFamily: 'inherit',
  },

  iconWrap: {
    marginBottom: 16,
  },

  title: {
    margin: '0 0 12px',
    fontSize: 20,
    fontWeight: 700,
    color: '#111827',
    lineHeight: 1.3,
  },

  body: {
    margin: '0 0 24px',
    fontSize: 14,
    color: '#6b7280',
    lineHeight: 1.6,
  },

  countdown: {
    display: 'flex',
    flexDirection: 'column' as const,
    alignItems: 'center',
    gap: 4,
    border: '2px solid',
    borderRadius: 10,
    padding: '16px 24px',
    marginBottom: 28,
    transition: 'color 0.3s, border-color 0.3s, background-color 0.3s',
  },

  countdownLabel: {
    fontSize: 11,
    fontWeight: 600,
    textTransform: 'uppercase' as const,
    letterSpacing: '0.07em',
    color: '#9ca3af',
  },

  countdownNumber: {
    fontSize: 48,
    fontWeight: 800,
    lineHeight: 1,
    fontVariantNumeric: 'tabular-nums',
    letterSpacing: '-0.02em',
  },

  actions: {
    display: 'flex',
    flexDirection: 'column' as const,
    gap: 10,
  },

  primaryBtn: {
    padding: '11px 20px',
    borderRadius: 8,
    border: 'none',
    backgroundColor: '#1a56db',
    color: '#fff',
    fontSize: 14,
    fontWeight: 600,
    cursor: 'pointer',
    transition: 'background-color 0.15s',
  },

  secondaryBtn: {
    padding: '11px 20px',
    borderRadius: 8,
    border: '1px solid #e5e7eb',
    backgroundColor: '#fff',
    color: '#6b7280',
    fontSize: 14,
    fontWeight: 500,
    cursor: 'pointer',
    transition: 'background-color 0.15s',
  },
} as const;
