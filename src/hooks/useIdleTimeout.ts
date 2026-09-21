import { useEffect, useRef, useState } from 'react';

// ─── Config ───────────────────────────────────────────────────────────────────

/** Total idle time before auto-logout (30 minutes) */
const IDLE_TIMEOUT_MS = 30 * 60 * 1_000;

/** Show warning this many ms before logout (2 minutes) */
const WARNING_BEFORE_MS = 2 * 60 * 1_000;

/** Warning appears at 28 minutes of inactivity */
const WARN_AT_MS = IDLE_TIMEOUT_MS - WARNING_BEFORE_MS;

/** Warning countdown duration in seconds */
const WARNING_SECONDS = WARNING_BEFORE_MS / 1_000;

/** DOM events treated as "user is active" */
const ACTIVITY_EVENTS = [
  'mousemove',
  'mousedown',
  'keydown',
  'touchstart',
  'scroll',
] as const;

// ─── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Tracks user activity and calls `onTimeout` after 30 minutes of inactivity.
 * Shows a 2-minute warning countdown before auto-logout.
 *
 * Only active when `enabled` is true (i.e. the user is signed in).
 */
export function useIdleTimeout(onTimeout: () => void, enabled: boolean) {
  const [showWarning, setShowWarning] = useState(false);
  const [secondsLeft, setSecondsLeft] = useState(WARNING_SECONDS);

  // Keep onTimeout in a ref so it's always current without affecting effect deps.
  const onTimeoutRef = useRef(onTimeout);
  useEffect(() => {
    onTimeoutRef.current = onTimeout;
  }, [onTimeout]);

  // Stable ref to the reset function so the event handler doesn't need to
  // be recreated whenever component state changes.
  const resetRef = useRef<() => void>(() => {});

  const warnTimerId   = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const logoutTimerId = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const countdownId   = useRef<ReturnType<typeof setInterval> | undefined>(undefined);

  useEffect(() => {
    if (!enabled) {
      clearTimeout(warnTimerId.current);
      clearTimeout(logoutTimerId.current);
      clearInterval(countdownId.current);
      setShowWarning(false);
      return;
    }

    const doReset = () => {
      // Cancel any running timers
      clearTimeout(warnTimerId.current);
      clearTimeout(logoutTimerId.current);
      clearInterval(countdownId.current);
      setShowWarning(false);
      setSecondsLeft(WARNING_SECONDS);

      // 28-minute warning timer
      warnTimerId.current = setTimeout(() => {
        setShowWarning(true);
        setSecondsLeft(WARNING_SECONDS);

        // Tick down every second
        countdownId.current = setInterval(() => {
          setSecondsLeft(s => Math.max(0, s - 1));
        }, 1_000);
      }, WARN_AT_MS);

      // 30-minute logout timer
      logoutTimerId.current = setTimeout(() => {
        clearInterval(countdownId.current);
        setShowWarning(false);
        onTimeoutRef.current();
      }, IDLE_TIMEOUT_MS);
    };

    resetRef.current = doReset;
    doReset(); // Start timers immediately

    // Any user activity resets the timers
    const handleActivity = () => doReset();
    ACTIVITY_EVENTS.forEach(e =>
      window.addEventListener(e, handleActivity, { passive: true })
    );

    return () => {
      clearTimeout(warnTimerId.current);
      clearTimeout(logoutTimerId.current);
      clearInterval(countdownId.current);
      ACTIVITY_EVENTS.forEach(e =>
        window.removeEventListener(e, handleActivity)
      );
    };
  }, [enabled]); // Only re-run when enabled toggles

  /** Call this when the user clicks "Stay Logged In" */
  const stayLoggedIn = () => resetRef.current();

  return { showWarning, secondsLeft, stayLoggedIn };
}
