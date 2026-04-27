import { useState, useEffect, type FormEvent } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { supabase } from '../../lib/supabase';

type Mode = 'password' | 'magic' | 'forgot';

export default function LoginPage() {
  const [mode,     setMode]     = useState<Mode>('password');
  const [email,    setEmail]    = useState('');
  const [password, setPassword] = useState('');
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);
  const [sent,     setSent]     = useState(false);

  const navigate  = useNavigate();
  const location  = useLocation();
  const { session } = useAuth();

  // If already logged in, redirect immediately
  useEffect(() => {
    if (session) {
      const from = (location.state as any)?.from?.pathname || '/profile';
      navigate(from, { replace: true });
    }
  }, [session, navigate, location]);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    if (mode === 'password') {
      const { error: err } = await supabase.auth.signInWithPassword({ email, password });
      if (err) setError(err.message);
      // On success, AuthContext listener will fire and redirect happens in App
    } else if (mode === 'magic') {
      const { error: err } = await supabase.auth.signInWithOtp({
        email,
        options: { shouldCreateUser: false }, // don't auto-create accounts
      });
      if (err) setError(err.message);
      else     setSent(true);
    } else {
      // Forgot password — send reset email
      const appUrl = import.meta.env.VITE_APP_URL || window.location.origin;
      const { error: err } = await supabase.auth.resetPasswordForEmail(email, {
        redirectTo: `${appUrl}/reset-password`,
      });
      if (err) setError(err.message);
      else     setSent(true);
    }

    setLoading(false);
  }

  return (
    <div className="login-page">
      <div className="login-card">
        {/* Logo */}
        <div className="login-logo-wrap">
          <img src="/logo.png" alt="Prowess" className="login-logo" />
        </div>

        <h1 className="login-title">Sign in to Prowess</h1>

        {/* Tab switcher */}
        <div className="login-tabs">
          <button
            type="button"
            className={`login-tab ${mode === 'password' ? 'active' : ''}`}
            onClick={() => { setMode('password'); setError(null); setSent(false); }}
          >
            Password
          </button>
          <button
            type="button"
            className={`login-tab ${mode === 'magic' ? 'active' : ''}`}
            onClick={() => { setMode('magic'); setError(null); setSent(false); }}
          >
            Magic Link
          </button>
        </div>

        {/* Sent confirmation (magic link or password reset) */}
        {sent ? (
          <div className="login-sent">
            <i className="fa-solid fa-envelope-circle-check" />
            {mode === 'forgot'
              ? <p>Check your inbox — we sent a password reset link to <strong>{email}</strong>.</p>
              : <p>Check your inbox — we sent a sign-in link to <strong>{email}</strong>.</p>
            }
            <button
              type="button"
              className="login-btn-secondary"
              onClick={() => { setSent(false); setEmail(''); setMode('password'); }}
            >
              Back to sign in
            </button>
          </div>
        ) : mode === 'forgot' ? (
          /* ── Forgot Password form ── */
          <form onSubmit={handleSubmit} className="login-form" noValidate>
            <p style={{ color: '#64748b', fontSize: 14, marginBottom: 16, textAlign: 'center' }}>
              Enter your work email and we'll send you a link to reset your password.
            </p>
            <div className="login-field">
              <label htmlFor="login-email">Work Email</label>
              <input
                id="login-email"
                type="email"
                autoComplete="email"
                placeholder="you@company.com"
                value={email}
                onChange={e => setEmail(e.target.value)}
                required
                disabled={loading}
              />
            </div>
            {error && (
              <div className="login-error">
                <i className="fa-solid fa-circle-exclamation" /> {error}
              </div>
            )}
            <button type="submit" className="login-btn" disabled={loading || !email}>
              {loading
                ? <><i className="fa-solid fa-spinner fa-spin" /> Sending…</>
                : 'Send Reset Link'
              }
            </button>
            <button
              type="button"
              className="login-btn-secondary"
              style={{ marginTop: 8 }}
              onClick={() => { setMode('password'); setError(null); }}
            >
              ← Back to sign in
            </button>
          </form>
        ) : (
          <form onSubmit={handleSubmit} className="login-form" noValidate>
            {/* Email */}
            <div className="login-field">
              <label htmlFor="login-email">Work Email</label>
              <input
                id="login-email"
                type="email"
                autoComplete="email"
                placeholder="you@company.com"
                value={email}
                onChange={e => setEmail(e.target.value)}
                required
                disabled={loading}
              />
            </div>

            {/* Password (only in password mode) */}
            {mode === 'password' && (
              <div className="login-field">
                <label htmlFor="login-password">Password</label>
                <input
                  id="login-password"
                  type="password"
                  autoComplete="current-password"
                  placeholder="••••••••"
                  value={password}
                  onChange={e => setPassword(e.target.value)}
                  required
                  disabled={loading}
                />
                <div style={{ textAlign: 'right', marginTop: 4 }}>
                  <button
                    type="button"
                    className="login-link"
                    onClick={() => { setMode('forgot'); setError(null); }}
                  >
                    Forgot password?
                  </button>
                </div>
              </div>
            )}

            {/* Error */}
            {error && (
              <div className="login-error">
                <i className="fa-solid fa-circle-exclamation" /> {error}
              </div>
            )}

            {/* Submit */}
            <button type="submit" className="login-btn" disabled={loading || !email}>
              {loading
                ? <><i className="fa-solid fa-spinner fa-spin" /> Signing in…</>
                : mode === 'password' ? 'Sign In' : 'Send Magic Link'
              }
            </button>
          </form>
        )}

        <p className="login-footer">
          Don't have access? Contact your administrator.
        </p>
      </div>
    </div>
  );
}
