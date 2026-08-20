/**
 * VerifyEmailChangePage
 *
 * Landing page for the one-time link in "Confirm this address for your Prowess
 * sign-in". Public — no session required, and that is the point: the person
 * confirming may no longer be able to read the mailbox they currently sign in
 * with, so requiring a login here would make the flow unusable in exactly the
 * case it exists for.
 *
 * The page holds no logic of its own. It hands the token to
 * confirm-email-change, which asks Postgres whether it is valid; nothing about
 * the token's state is decided in the browser.
 */

import { useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';

type State =
  | { kind: 'working' }
  | { kind: 'done';   email: string; name: string }
  | { kind: 'failed'; message: string };

export default function VerifyEmailChangePage() {
  const [state, setState] = useState<State>({ kind: 'working' });
  const navigate = useNavigate();
  // A one-time token must be spent once. React 18 mounts effects twice in dev,
  // and the second call would report "already used" over a change that in fact
  // succeeded.
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;

    const token = new URLSearchParams(window.location.search).get('token') ?? '';
    if (!token) {
      setState({ kind: 'failed', message: 'This link is missing its confirmation code. Open it directly from the email rather than copying part of it.' });
      return;
    }

    const url  = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/confirm-email-change`;
    const anon = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

    fetch(url, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json', apikey: anon, Authorization: `Bearer ${anon}` },
      body:    JSON.stringify({ token }),
    })
      .then(async res => {
        const data = await res.json().catch(() => ({}));
        if (data?.ok) setState({ kind: 'done', email: data.email, name: data.employee_name });
        else          setState({ kind: 'failed', message: data?.error ?? 'This link could not be confirmed.' });
      })
      .catch(() => setState({
        kind: 'failed',
        message: 'We could not reach Prowess to confirm this. Check your connection and open the link again.',
      }));
  }, []);

  return (
    <div className="login-page">
      <div className="login-card">
        <div className="login-logo-wrap">
          <img src="/logo.png" alt="Prowess" className="login-logo" />
        </div>

        {state.kind === 'working' && (
          <div className="login-sent">
            <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 28, color: '#64748b', marginBottom: 8 }} />
            <p style={{ color: '#64748b' }}>Confirming your address…</p>
          </div>
        )}

        {state.kind === 'done' && (
          <>
            <h1 className="login-title">Address confirmed</h1>
            <div className="login-sent">
              <i className="fa-solid fa-circle-check" style={{ fontSize: 32, color: '#2E7D32', marginBottom: 8 }} />
              <p style={{ color: '#334155', lineHeight: 1.6 }}>
                {state.name ? `${state.name}, from` : 'From'} now on, sign in as{' '}
                <b>{state.email}</b>.
              </p>
              <p style={{ color: '#64748b', fontSize: 13, marginTop: 10, lineHeight: 1.6 }}>
                Your password has not changed. If you are signed in somewhere on the old
                address, sign out and back in.
              </p>
            </div>
            <button
              className="login-btn"
              style={{ marginTop: 14 }}
              onClick={() => navigate('/login')}
            >
              Go to sign in
            </button>
          </>
        )}

        {state.kind === 'failed' && (
          <>
            <h1 className="login-title">We could not confirm this</h1>
            <div className="login-sent">
              <i className="fa-solid fa-circle-exclamation" style={{ fontSize: 30, color: '#B45309', marginBottom: 8 }} />
              <p style={{ color: '#334155', lineHeight: 1.6 }}>{state.message}</p>
              <p style={{ color: '#64748b', fontSize: 13, marginTop: 10, lineHeight: 1.6 }}>
                Nothing has changed — your existing sign-in address still works.
              </p>
            </div>
            <button
              className="login-btn"
              style={{ marginTop: 14 }}
              onClick={() => navigate('/login')}
            >
              Back to sign in
            </button>
          </>
        )}
      </div>
    </div>
  );
}
