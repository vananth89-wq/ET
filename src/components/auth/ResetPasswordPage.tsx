import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';

export default function ResetPasswordPage() {
  const [password, setPassword] = useState('');
  const [confirm,  setConfirm]  = useState('');
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);
  const [done,     setDone]     = useState(false);

  // Detect whether this is a first-time account activation (type=signup / type=magiclink)
  // vs a password recovery request — so we can show friendlier messaging.
  const urlType  = new URLSearchParams(window.location.search).get('type') ?? '';
  const isNewUser = urlType === 'signup' || urlType === 'magiclink';
  // checking = true while we wait for detectSessionInUrl to finish processing the token/code
  const [checking, setChecking] = useState(true);

  const navigate = useNavigate();

  // ── Establish the recovery session ───────────────────────────────────────
  // With PKCE flow, Supabase sends the email link directly to the app:
  //   /reset-password?token_hash=XXX&type=recovery
  // We call verifyOtp() with those params — the token is only consumed here
  // in the browser, so email link scanners can't pre-consume it.
  //
  // Fallback: if the URL has a hash-based #error= (e.g. from an old link
  // sent before PKCE was enabled), we show the error immediately.
  useEffect(() => {
    let resolved = false;
    const subRef = { current: null as ReturnType<typeof supabase.auth.onAuthStateChange>['data']['subscription'] | null };

    const EXPIRED_MSG =
      'This reset link has expired or has already been used. ' +
      'Please request a new one from the login page.';

    let timer: ReturnType<typeof setTimeout>;

    function resolve(err?: string) {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      subRef.current?.unsubscribe();
      if (err) setError(err);
      setChecking(false);
    }

    // ── 1. Hash-based error (old implicit flow links) ─────────────────────
    const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ''));
    if (hashParams.get('error')) {
      const desc = hashParams.get('error_description') ?? '';
      setError(desc || EXPIRED_MSG);
      setChecking(false);
      return;
    }

    // ── 2. PKCE flow — token_hash in query params ─────────────────────────
    const searchParams = new URLSearchParams(window.location.search);
    const tokenHash = searchParams.get('token_hash');
    const type      = searchParams.get('type');

    if (tokenHash && type) {
      // Exchange the token_hash for a session. This is the only step that
      // consumes the token — email scanners can't do this.
      supabase.auth.verifyOtp({ token_hash: tokenHash, type: type as 'recovery' })
        .then(({ error: err }) => {
          if (err) {
            resolve(EXPIRED_MSG);
          } else {
            resolve(); // session established, show the form
          }
        });
      return;
    }

    // ── 3. Fallback — wait for auth event (implicit flow / detectSessionInUrl)
    timer = setTimeout(() => resolve(EXPIRED_MSG), 8_000);

    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, session) => {
      if (resolved) return;

      if (event === 'PASSWORD_RECOVERY') {
        resolve();
        return;
      }

      if (event === 'INITIAL_SESSION') {
        if (session) resolve();
        return;
      }

      if (event === 'SIGNED_IN' && session) {
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

        <h1 className="login-title">
          {isNewUser ? '👋 Welcome! Set Your Password' : 'Set New Password'}
        </h1>
        {isNewUser && (
          <p style={{ textAlign: 'center', color: '#64748b', fontSize: 14, marginBottom: 16, marginTop: -4 }}>
            Your account is ready. Choose a password to get started.
          </p>
        )}

        {done ? (
          <div className="login-sent">
            <i className="fa-solid fa-circle-check" style={{ fontSize: 32, color: '#2E7D32', marginBottom: 8 }} />
            <p>{isNewUser ? 'All set! Taking you to your dashboard…' : 'Password updated successfully! Redirecting…'}</p>
          </div>

        ) : checking ? (
          <div className="login-sent">
            <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 28, color: '#64748b', marginBottom: 8 }} />
            <p style={{ color: '#64748b' }}>{isNewUser ? 'Activating your account…' : 'Verifying reset link…'}</p>
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
                ? <><i className="fa-solid fa-spinner fa-spin" /> {isNewUser ? 'Activating…' : 'Updating…'}</>
                : isNewUser ? 'Activate My Account' : 'Update Password'
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
