import { useState, useEffect, type FormEvent } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { supabase } from '../../lib/supabase';

type Mode = 'password' | 'magic' | 'forgot';

interface ThemeSettings {
  login_brand_logo: string | null;
  login_card_logo:  string | null;
  login_tagline:    string | null;
  favicon:          string | null;
  app_name:         string | null;
}

const THEME_DEFAULTS: ThemeSettings = {
  login_brand_logo: null,
  login_card_logo:  null,
  login_tagline:    'Empowering people. Simplifying work.',
  favicon:          null,
  app_name:         'Prowess Workforce',
};

export default function LoginPage() {
  const [mode,     setMode]     = useState<Mode>('password');
  const [email,    setEmail]    = useState('');
  const [password, setPassword] = useState('');
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);
  const [sent,     setSent]     = useState(false);
  const [showPw,   setShowPw]   = useState(false);
  const [theme,    setTheme]    = useState<ThemeSettings>(THEME_DEFAULTS);

  // Load theme settings (runs before login, uses anon key)
  useEffect(() => {
    supabase.rpc('get_theme_settings').then(({ data }) => {
      if (data) {
        const merged = { ...THEME_DEFAULTS, ...data };
        setTheme(merged);
        if (merged.app_name) document.title = merged.app_name;
      }
    });
  }, []);

  // Apply favicon dynamically
  useEffect(() => {
    const url = theme.favicon;
    if (!url) return;
    let link = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
    if (!link) { link = document.createElement('link'); link.rel = 'icon'; document.head.appendChild(link); }
    link.href = url;
  }, [theme.favicon]);

  const navigate  = useNavigate();
  const location  = useLocation();
  const { session } = useAuth();

  // If already logged in, redirect immediately.
  // Only restore the previous path if it's a non-profile or self-profile path.
  // Never redirect to /profile/:someUUID — that would drop the user onto
  // another employee's page if their session expired while viewing one.
  useEffect(() => {
    if (session) {
      const from = (location.state as any)?.from?.pathname as string | undefined;
      const isOtherEmployeeProfile = from && /^\/profile\/[0-9a-f-]{36}/i.test(from);
      navigate(isOtherEmployeeProfile || !from ? '/home' : from, { replace: true });
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
      {/* ── Left brand area ── */}
      <div className="login-brand-area">
        <div className="login-brand-area-inner">
          <img
            src={theme.login_brand_logo ?? '/Lnadingpage.png'}
            alt="Prowess"
            className="login-brand-area-logo"
          />
          <div className="login-brand-area-divider" />
          <p className="login-brand-area-tagline">
            {theme.login_tagline ?? 'Empowering people. Simplifying work.'}
          </p>
        </div>
      </div>

      {/* ── Separator ── */}
      <div className="login-separator" />

      {/* ── Floating card ── */}
      <div className="login-card">
        {/* Logo */}
        <div className="login-logo-wrap">
          <img src={theme.login_card_logo ?? '/logo.png'} alt="Prowess" className="login-logo" />
        </div>

        <h1 className="login-title">Sign in to {theme.app_name ?? THEME_DEFAULTS.app_name}</h1>

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

          {/* Sent confirmation */}
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
            <form onSubmit={handleSubmit} className="login-form" noValidate>
              <p className="login-hint">
                Enter your work email and we'll send you a link to reset your password.
              </p>
              <div className="login-field">
                <label htmlFor="login-email">Work email</label>
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
                  : 'Send reset link'
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
              <div className="login-field">
                <label htmlFor="login-email">Work email</label>
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

              {mode === 'password' && (
                <div className="login-field">
                  <div className="login-field-header">
                    <label htmlFor="login-password">Password</label>
                    <button
                      type="button"
                      className="login-link"
                      onClick={() => { setMode('forgot'); setError(null); }}
                    >
                      Forgot password?
                    </button>
                  </div>
                  <div style={{ position: 'relative', display: 'block' }}>
                    <input
                      id="login-password"
                      type={showPw ? 'text' : 'password'}
                      autoComplete="current-password"
                      placeholder="••••••••"
                      value={password}
                      onChange={e => setPassword(e.target.value)}
                      required
                      disabled={loading}
                      style={{ paddingRight: 40, width: '100%', boxSizing: 'border-box' }}
                    />
                    <button
                      type="button"
                      onClick={() => setShowPw(v => !v)}
                      style={{
                        position: 'absolute', right: 12, top: '50%',
                        transform: 'translateY(-50%)',
                        background: 'none', border: 'none',
                        cursor: 'pointer', padding: 0,
                        color: '#94a3b8', lineHeight: 1,
                      }}
                      tabIndex={-1}
                      aria-label={showPw ? 'Hide password' : 'Show password'}
                    >
                      <i className={`fa-solid ${showPw ? 'fa-eye-slash' : 'fa-eye'}`} style={{ fontSize: 15 }} />
                    </button>
                  </div>
                </div>
              )}

              {error && (
                <div className="login-error">
                  <i className="fa-solid fa-circle-exclamation" /> {error}
                </div>
              )}

              <button type="submit" className="login-btn" disabled={loading || !email}>
                {loading
                  ? <><i className="fa-solid fa-spinner fa-spin" /> Signing in…</>
                  : mode === 'password' ? 'Sign in' : 'Send magic link'
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
