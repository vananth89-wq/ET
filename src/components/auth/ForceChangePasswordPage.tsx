/**
 * ForceChangePasswordPage
 *
 * Shown when a user logs in after an admin has set a temporary password.
 * Inherits full branding from Theme Manager (same RPC as LoginPage).
 * Matches the visual language of the login experience.
 */

import { useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../contexts/AuthContext';

// ── Inline SVG icons (no extra bundle weight on this pre-nav page) ───────────

const ShieldCheckIcon = () => (
  <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
    <polyline points="9 12 11 14 15 10" />
  </svg>
);

const EyeIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" /><circle cx="12" cy="12" r="3" />
  </svg>
);

const EyeOffIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24" />
    <line x1="1" y1="1" x2="23" y2="23" />
  </svg>
);

const BadgeCheckIcon = () => (
  <svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z" />
    <path d="m9 12 2 2 4-4" />
  </svg>
);

const InfoIcon = () => (
  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <circle cx="12" cy="12" r="10" /><line x1="12" y1="16" x2="12" y2="12" /><line x1="12" y1="8" x2="12.01" y2="8" />
  </svg>
);

// ── Theme ────────────────────────────────────────────────────────────────────

interface ThemeSettings {
  login_brand_logo: string | null;
  login_card_logo:  string | null;
  login_tagline:    string | null;
  app_name:         string | null;
  favicon:          string | null;
}

const THEME_DEFAULTS: ThemeSettings = {
  login_brand_logo: null,
  login_card_logo:  null,
  login_tagline:    'Empowering people. Simplifying work.',
  app_name:         'Prowess Workforce',
  favicon:          null,
};

// ── Password helpers ─────────────────────────────────────────────────────────

interface PwChecks { length: boolean; upper: boolean; lower: boolean; number: boolean; special: boolean; }

function checkPassword(pw: string): PwChecks {
  return {
    length:  pw.length >= 8,
    upper:   /[A-Z]/.test(pw),
    lower:   /[a-z]/.test(pw),
    number:  /[0-9]/.test(pw),
    special: /[^A-Za-z0-9]/.test(pw),
  };
}

function strengthInfo(pw: string) {
  const score = Object.values(checkPassword(pw)).filter(Boolean).length;
  if (pw.length === 0) return { label: '',            score: 0, color: '#E5E7EB' };
  if (score <= 1)      return { label: 'Weak',        score: 1, color: '#EF4444' };
  if (score === 2)     return { label: 'Fair',        score: 2, color: '#F97316' };
  if (score === 3)     return { label: 'Good',        score: 3, color: '#EAB308' };
  if (score === 4)     return { label: 'Strong',      score: 4, color: '#22C55E' };
  return               { label: 'Very Strong',  score: 5, color: '#16A34A' };
}

// ── Component ────────────────────────────────────────────────────────────────

export default function ForceChangePasswordPage() {
  const [theme,    setTheme]    = useState<ThemeSettings>(THEME_DEFAULTS);
  const [password, setPassword] = useState('');
  const [confirm,  setConfirm]  = useState('');
  const [showPw,   setShowPw]   = useState(false);
  const [showCfm,  setShowCfm]  = useState(false);
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);
  const [success,  setSuccess]  = useState(false);

  const navigate = useNavigate();
  const { user, employee } = useAuth();
  const pwRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    supabase.rpc('get_theme_settings').then(({ data }) => {
      if (data) setTheme({ ...THEME_DEFAULTS, ...data });
    });
  }, []);

  useEffect(() => {
    if (!theme.favicon) return;
    let link = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
    if (!link) { link = document.createElement('link'); link.rel = 'icon'; document.head.appendChild(link); }
    link.href = theme.favicon;
  }, [theme.favicon]);

  useEffect(() => { pwRef.current?.focus(); }, []);

  useEffect(() => {
    if (!success) return;
    const t = setTimeout(() => navigate('/', { replace: true }), 3000);
    return () => clearTimeout(t);
  }, [success, navigate]);

  const checks    = checkPassword(password);
  const allChecks = Object.values(checks).every(Boolean);
  const pwMatch   = password === confirm && confirm.length > 0;
  const canSubmit = allChecks && pwMatch && !loading;
  const strength  = strengthInfo(password);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!canSubmit) return;
    setLoading(true);
    setError(null);
    const { error: pwErr } = await supabase.auth.updateUser({ password });
    if (pwErr) { setError(pwErr.message); setLoading(false); return; }
    await supabase.auth.updateUser({ data: { force_password_change: false } });
    setSuccess(true);
    setLoading(false);
  }

  const cardLogo = theme.login_card_logo ?? '/logo.png';
  const appName  = theme.app_name        ?? THEME_DEFAULTS.app_name!;
  const tagline  = theme.login_tagline   ?? THEME_DEFAULTS.login_tagline!;

  // ── Success ───────────────────────────────────────────────────────────────
  if (success) {
    return (
      <div style={S.page}>
        <div style={S.card}>
          <div style={{ textAlign: 'center', padding: '16px 0' }}>
            <div style={{ color: '#16A34A', display: 'flex', justifyContent: 'center', marginBottom: 16 }}>
              <BadgeCheckIcon />
            </div>
            <h2 style={{ margin: '0 0 8px', fontSize: 22, fontWeight: 700, color: '#0F172A' }}>
              Password Updated Successfully
            </h2>
            <p style={{ margin: '0 0 28px', fontSize: 14, color: '#64748B', lineHeight: 1.6 }}>
              Your password has been changed successfully.
            </p>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, fontSize: 13, color: '#94A3B8' }}>
              <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 12 }} />
              Redirecting to {appName}…
            </div>
          </div>
        </div>
      </div>
    );
  }

  // ── Form ──────────────────────────────────────────────────────────────────
  return (
    <div style={S.page}>
      <div style={S.card}>

        {/* Logo + tagline */}
        <div style={{ textAlign: 'center', marginBottom: 24 }}>
          <img
            src={cardLogo}
            alt={appName}
            style={{ height: 38, objectFit: 'contain', marginBottom: 6 }}
            onError={e => { (e.target as HTMLImageElement).style.display = 'none'; }}
          />
          <p style={{ margin: 0, fontSize: 12, color: '#94A3B8' }}>{tagline}</p>
        </div>

        {/* Icon + heading */}
        <div style={{ textAlign: 'center', marginBottom: 22 }}>
          <div style={{
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            width: 64, height: 64, borderRadius: '50%',
            background: 'linear-gradient(135deg, #EFF6FF 0%, #DBEAFE 100%)',
            color: '#2563EB', marginBottom: 14,
          }}>
            <ShieldCheckIcon />
          </div>
          <h1 style={{ margin: '0 0 8px', fontSize: 20, fontWeight: 700, color: '#0F172A' }}>
            Set Your New Password
          </h1>
          <p style={{ margin: 0, fontSize: 13, color: '#64748B', lineHeight: 1.55 }}>
            For security reasons, you must create a new password<br />before accessing {appName}.
          </p>
        </div>

        {/* User context */}
        {(employee || user) && (
          <div style={{
            background: '#F8FAFC', borderRadius: 10, padding: '11px 14px',
            marginBottom: 16, border: '1px solid #E2E8F0',
            display: 'flex', alignItems: 'center', gap: 12,
          }}>
            <div style={{
              width: 36, height: 36, borderRadius: '50%', flexShrink: 0,
              background: 'linear-gradient(135deg, #2563EB, #7C3AED)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              color: '#fff', fontWeight: 700, fontSize: 14,
            }}>
              {(employee?.name ?? user?.email ?? '?')[0].toUpperCase()}
            </div>
            <div style={{ minWidth: 0 }}>
              {employee?.name && (
                <div style={{ fontWeight: 600, fontSize: 13, color: '#0F172A', marginBottom: 1 }}>
                  {employee.name}
                </div>
              )}
              <div style={{ fontSize: 11, color: '#64748B', display: 'flex', gap: 8 }}>
                {employee?.employeeId && <span>{employee.employeeId}</span>}
                <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {user?.email}
                </span>
              </div>
            </div>
          </div>
        )}

        {/* Security notice */}
        <div style={{
          background: '#EFF6FF', border: '1px solid #BFDBFE', borderRadius: 10,
          padding: '11px 14px', marginBottom: 20,
          display: 'flex', gap: 10, alignItems: 'flex-start',
        }}>
          <span style={{ color: '#2563EB', flexShrink: 0, marginTop: 1 }}><InfoIcon /></span>
          <div>
            <div style={{ fontWeight: 600, fontSize: 12, color: '#1D4ED8', marginBottom: 2 }}>Security Notice</div>
            <p style={{ margin: 0, fontSize: 12, color: '#3B82F6', lineHeight: 1.5 }}>
              Your administrator assigned a temporary password. You must create a new password before continuing. This will permanently replace the temporary password.
            </p>
          </div>
        </div>

        {/* Requirements checklist */}
        <div style={{ marginBottom: 18 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: '#94A3B8', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>
            Password Requirements
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '5px 16px' }}>
            {([
              { key: 'length',  label: 'Minimum 8 characters' },
              { key: 'upper',   label: 'One uppercase letter' },
              { key: 'lower',   label: 'One lowercase letter' },
              { key: 'number',  label: 'One number' },
              { key: 'special', label: 'One special character' },
            ] as const).map(({ key, label }) => {
              const met   = checks[key];
              const typed = password.length > 0;
              return (
                <div key={key} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12 }}>
                  <span style={{
                    width: 16, height: 16, borderRadius: '50%', flexShrink: 0,
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    fontSize: 9, fontWeight: 700, transition: 'all .2s',
                    background: met ? '#DCFCE7' : typed ? '#FEE2E2' : '#F1F5F9',
                    color:      met ? '#16A34A' : typed ? '#DC2626' : '#94A3B8',
                  }}>
                    {met ? '✓' : typed ? '✕' : '○'}
                  </span>
                  <span style={{ color: met ? '#16A34A' : '#64748B', transition: 'color .2s' }}>{label}</span>
                </div>
              );
            })}
          </div>
        </div>

        <form onSubmit={handleSubmit} noValidate>

          {/* New password */}
          <div style={{ marginBottom: 14 }}>
            <label style={S.label}>New Password <span style={{ color: '#EF4444' }}>*</span></label>
            <div style={S.inputWrap}>
              <input
                ref={pwRef}
                type={showPw ? 'text' : 'password'}
                value={password}
                onChange={e => setPassword(e.target.value)}
                placeholder="Enter new password"
                autoComplete="new-password"
                style={S.input}
              />
              <button type="button" onClick={() => setShowPw(v => !v)} style={S.eyeBtn} tabIndex={-1} aria-label="Toggle visibility">
                {showPw ? <EyeOffIcon /> : <EyeIcon />}
              </button>
            </div>
            {password.length > 0 && (
              <div style={{ marginTop: 8 }}>
                <div style={{ display: 'flex', gap: 3, marginBottom: 4 }}>
                  {[1,2,3,4,5].map(i => (
                    <div key={i} style={{
                      flex: 1, height: 4, borderRadius: 2, transition: 'background .3s',
                      background: i <= strength.score ? strength.color : '#E5E7EB',
                    }} />
                  ))}
                </div>
                <div style={{ fontSize: 11, fontWeight: 600, color: strength.color }}>{strength.label}</div>
              </div>
            )}
          </div>

          {/* Confirm password */}
          <div style={{ marginBottom: 20 }}>
            <label style={S.label}>Confirm Password <span style={{ color: '#EF4444' }}>*</span></label>
            <div style={S.inputWrap}>
              <input
                type={showCfm ? 'text' : 'password'}
                value={confirm}
                onChange={e => setConfirm(e.target.value)}
                placeholder="Repeat your new password"
                autoComplete="new-password"
                style={S.input}
              />
              <button type="button" onClick={() => setShowCfm(v => !v)} style={S.eyeBtn} tabIndex={-1} aria-label="Toggle visibility">
                {showCfm ? <EyeOffIcon /> : <EyeIcon />}
              </button>
            </div>
            {confirm.length > 0 && (
              <div style={{ marginTop: 5, fontSize: 12, display: 'flex', alignItems: 'center', gap: 5,
                color: pwMatch ? '#16A34A' : '#EF4444' }}>
                {pwMatch ? '✓ Passwords match' : '✕ Passwords do not match'}
              </div>
            )}
          </div>

          {/* Error */}
          {error && (
            <div style={{
              marginBottom: 16, padding: '10px 14px', borderRadius: 8,
              background: '#FEF2F2', border: '1px solid #FECACA',
              color: '#DC2626', fontSize: 13, display: 'flex', gap: 8, alignItems: 'center',
            }}>
              <i className="fa-solid fa-circle-exclamation" />{error}
            </div>
          )}

          {/* Submit */}
          <button
            type="submit"
            disabled={!canSubmit}
            style={{
              width: '100%', height: 48, borderRadius: 10, border: 'none',
              background: canSubmit
                ? 'linear-gradient(135deg, #2563EB 0%, #1D4ED8 100%)'
                : '#E2E8F0',
              color:  canSubmit ? '#fff' : '#94A3B8',
              fontSize: 14, fontWeight: 700,
              cursor: canSubmit ? 'pointer' : 'not-allowed',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
              transition: 'all .2s',
              boxShadow: canSubmit ? '0 4px 14px rgba(37,99,235,0.28)' : 'none',
            }}
          >
            {loading
              ? <><i className="fa-solid fa-spinner fa-spin" /> Updating Password…</>
              : 'Set Password & Continue'
            }
          </button>
        </form>

        {/* Help */}
        <div style={{ textAlign: 'center', marginTop: 22, paddingTop: 18, borderTop: '1px solid #F1F5F9' }}>
          <p style={{ margin: 0, fontSize: 12, color: '#94A3B8' }}>
            Need help?{' '}
            <span style={{ color: '#64748B' }}>Contact your HR Administrator or IT Support.</span>
          </p>
        </div>

      </div>
    </div>
  );
}

// ── Style constants ───────────────────────────────────────────────────────────

const S = {
  page: {
    minHeight: '100vh',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    background: 'linear-gradient(135deg, #0F172A 0%, #1E3A5F 50%, #0F172A 100%)',
    padding: '24px 16px',
  } as React.CSSProperties,

  card: {
    width: '100%', maxWidth: 540,
    background: '#fff', borderRadius: 20,
    boxShadow: '0 25px 60px rgba(0,0,0,0.25), 0 8px 20px rgba(0,0,0,0.12)',
    padding: '36px 40px',
  } as React.CSSProperties,

  label: {
    display: 'block', fontSize: 13, fontWeight: 600,
    color: '#374151', marginBottom: 6,
  } as React.CSSProperties,

  inputWrap: {
    position: 'relative', display: 'flex', alignItems: 'center',
  } as React.CSSProperties,

  input: {
    width: '100%', height: 42, padding: '0 40px 0 12px',
    borderRadius: 8, border: '1.5px solid #E5E7EB',
    fontSize: 14, color: '#0F172A', background: '#fff',
    outline: 'none', boxSizing: 'border-box', transition: 'border-color .15s',
  } as React.CSSProperties,

  eyeBtn: {
    position: 'absolute', right: 12,
    background: 'none', border: 'none', cursor: 'pointer',
    padding: 0, color: '#94A3B8', display: 'flex', alignItems: 'center', lineHeight: 1,
  } as React.CSSProperties,
};
