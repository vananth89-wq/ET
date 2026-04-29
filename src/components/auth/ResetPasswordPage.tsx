import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';

export default function ResetPasswordPage() {
  const [password, setPassword] = useState('');
  const [confirm,  setConfirm]  = useState('');
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);
  const [done,     setDone]     = useState(false);
  // checking = true while we wait for detectSessionInUrl to finish processing the token/code
  const [checking, setChecking] = useState(true);

  const navigate = useNavigate();

  // ── Wait for Supabase to establish the recovery session ──────────────────
  // detectSessionInUrl: true handles both flows automatically:
  //   • PKCE  → code=... in query params → exchangeCodeForSession (internal)
  //   • Hash  → access_token=... in fragment → setSession (internal)
  // Both fire onAuthStateChange when done. We must NOT call exchangeCodeForSession
  // ourselves — the code is single-use and would already be consumed by the time
  // our useEffect runs.
  useEffect(() => {
    let resolved = false;
    const subRef = { current: null as ReturnType<typeof supabase.auth.onAuthStateChange>['data']['subscription'] | null };

    const EXPIRED_MSG =
      'This reset link has expired or has already been used. ' +
      'Please request a new one from the login page.';

    // Safety net: if no auth event arrives in 8 s, show expired error
    let timer: ReturnType<typeof setTimeout>;

    function resolve(err?: string) {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      subRef.current?.unsubscribe();
      if (err) setError(err);
      setChecking(false);
    }

    // ── Check for server-side error in the URL hash ───────────────────────
    // Supabase redirects here with #error=... when the token is invalid or
    // expired before the client even gets to process it.
    const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ''));
    if (hashParams.get('error')) {
      const desc = hashParams.get('error_description') ?? '';
      const msg = desc || EXPIRED_MSG;
      setError(msg);
      setChecking(false);
      return;
    }

    timer = setTimeout(() => resolve(EXPIRED_MSG), 8_000);

    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, session) => {
      if (resolved) return;

      if (event === 'PASSWORD_RECOVERY') {
        // Explicit recovery event — session is definitely a recovery session
        resolve();
        return;
      }

      if (event === 'INITIAL_SESSION') {
        // onAuthStateChange replays this immediately on subscribe.
        // If detectSessionInUrl already processed the token before we
        // subscribed, session will be non-null here.
        if (session) {
          resolve(); // session is ready, show the form
        }
        // If session is null, init is still in progress — keep waiting
        // for PASSWORD_RECOVERY to arrive (timer is the fallback).
        return;
      }

      if (event === 'SIGNED_IN' && session) {
        // Some Supabase versions fire SIGNED_IN instead of PASSWORD_RECOVERY
        // for recovery flows.
        resolve();
      }
    });

    subRef.current = subscription;

    return () => {
      resolved = true;
      clearTimeout(timer);
      subscription.unsubscribe();
    };
  }, []);

  // ── Submit ───────────────────────────────────────────────────────────────
  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (password.length < 8) {
      setError('Password must be at least 8 characters.');
      return;
    }
    if (password !== confirm) {
      setError('Passwords do not match.');
      return;
    }

    setLoading(true);

    // Verify the session is still alive before calling updateUser
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) {
      setLoading(false);
      setError(
        'Your session expired while the page was open. ' +
        'Please request a new reset link from the login page.'
      );
      return;
    }

    const { error: err } = await supabase.auth.updateUser({ password });
    setLoading(false);

    if (err) {
      setError(err.message);
    } else {
      setDone(true);
      setTimeout(() => navigate('/'), 2500);
    }
  }

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <div className="login-page">
      <div className="login-card">
        <div className="login-logo-wrap">
          <img src="/logo.png" alt="Prowess" className="login-logo" />
        </div>

        <h1 className="login-title">Set New Password</h1>

        {done ? (
          <div className="login-sent">
            <i className="fa-solid fa-circle-check" style={{ fontSize: 32, color: '#2E7D32', marginBottom: 8 }} />
            <p>Password updated successfully! Redirecting…</p>
          </div>

        ) : checking ? (
          <div className="login-sent">
            <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 28, color: '#64748b', marginBottom: 8 }} />
            <p style={{ color: '#64748b' }}>Verifying reset link…</p>
          </div>

        ) : error && !password ? (
          // Session init failed — show error, no form
          <div className="login-sent">
            <i className="fa-solid fa-circle-exclamation" style={{ fontSize: 32, color: '#dc2626', marginBottom: 8 }} />
            <div className="login-error">
              <i className="fa-solid fa-circle-exclamation" /> {error}
            </div>
            <button
              type="button"
              className="login-btn-secondary"
              style={{ marginTop: 16 }}
              onClick={() => navigate('/login')}
            >
              ← Back to sign in
            </button>
          </div>

        ) : (
          <form onSubmit={handleSubmit} className="login-form" noValidate>
            <div className="login-field">
              <label htmlFor="rp-password">New Password</label>
              <input
                id="rp-password"
                type="password"
                placeholder="At least 8 characters"
                value={password}
                onChange={e => setPassword(e.target.value)}
                required
                disabled={loading}
                autoFocus
              />
            </div>

            <div className="login-field">
              <label htmlFor="rp-confirm">Confirm Password</label>
              <input
                id="rp-confirm"
                type="password"
                placeholder="Repeat your new password"
                value={confirm}
                onChange={e => setConfirm(e.target.value)}
                required
                disabled={loading}
              />
            </div>

            {error && (
              <div className="login-error">
                <i className="fa-solid fa-circle-exclamation" /> {error}
              </div>
            )}

            <button
              type="submit"
              className="login-btn"
              disabled={loading || !password || !confirm}
            >
              {loading
                ? <><i className="fa-solid fa-spinner fa-spin" /> Updating…</>
                : 'Update Password'
              }
            </button>

            <button
              type="button"
              className="login-btn-secondary"
              style={{ marginTop: 8 }}
              onClick={() => navigate('/login')}
            >
              ← Back to sign in
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
