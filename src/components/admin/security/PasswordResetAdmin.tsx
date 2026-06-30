/**
 * PasswordResetAdmin — Enterprise IAM-grade UX
 * Requires: sec_password_reset.view  — page access
 *           sec_password_reset.edit  — perform resets
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { supabase } from '../../../lib/supabase';
import { usePermissions } from '../../../hooks/usePermissions';

// ─── Types ────────────────────────────────────────────────────────────────────

interface Employee {
  id:             string;   // employees.id
  profile_id:     string;   // profiles.id = auth.users.id
  name:           string;
  business_email: string;
  job_title:      string | null;
  dept_name:      string | null;
  employee_id:    string | null;
  status:         string;
}

interface AuditRow {
  id:            string;
  actor_name:    string | null;
  target_name:   string | null;
  target_email:  string;
  action:        'set_password' | 'send_reset_link';
  force_change:  boolean;
  success:       boolean;
  error_message: string | null;
  created_at:    string;
}

type Mode = 'set_password' | 'send_reset_link';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function generatePassword(length = 12): string {
  const upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const lower   = 'abcdefghjkmnpqrstuvwxyz';
  const digits  = '23456789';
  const special = '!@#$%&*';
  const all     = upper + lower + digits + special;
  const required = [
    upper  [Math.floor(Math.random() * upper.length)],
    lower  [Math.floor(Math.random() * lower.length)],
    digits [Math.floor(Math.random() * digits.length)],
    special[Math.floor(Math.random() * special.length)],
  ];
  const rest = Array.from({ length: length - 4 }, () =>
    all[Math.floor(Math.random() * all.length)]
  );
  return [...required, ...rest].sort(() => Math.random() - 0.5).join('');
}

function initials(name: string) {
  return name.split(' ').slice(0, 2).map(w => w[0]).join('').toUpperCase();
}

function formatAuditDate(iso: string): string {
  const d    = new Date(iso);
  const now  = new Date();
  const diff = now.getTime() - d.getTime();
  const days = Math.floor(diff / 86_400_000);
  if (days === 0) return 'Today';
  if (days === 1) return 'Yesterday';
  if (days < 7)  return `${days} days ago`;
  return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
}

function groupByDate(rows: AuditRow[]): { label: string; rows: AuditRow[] }[] {
  const map = new Map<string, AuditRow[]>();
  rows.forEach(r => {
    const key = formatAuditDate(r.created_at);
    if (!map.has(key)) map.set(key, []);
    map.get(key)!.push(r);
  });
  return Array.from(map.entries()).map(([label, rows]) => ({ label, rows }));
}

function passwordChecks(p: string) {
  return {
    upper:   /[A-Z]/.test(p),
    lower:   /[a-z]/.test(p),
    digit:   /[0-9]/.test(p),
    special: /[^A-Za-z0-9]/.test(p),
    length:  p.length >= 8,
  };
}

function strengthInfo(p: string): { label: string; color: string; bg: string; pct: number } {
  const c = passwordChecks(p);
  const score = Object.values(c).filter(Boolean).length;
  if (score <= 1) return { label: 'Very Weak',  color: '#EF4444', bg: '#FEE2E2', pct: 15  };
  if (score === 2) return { label: 'Weak',       color: '#F97316', bg: '#FFEDD5', pct: 35  };
  if (score === 3) return { label: 'Fair',       color: '#EAB308', bg: '#FEF9C3', pct: 55  };
  if (score === 4) return { label: 'Strong',     color: '#22C55E', bg: '#DCFCE7', pct: 80  };
  return                  { label: 'Very Strong', color: '#16A34A', bg: '#DCFCE7', pct: 100 };
}

// ─── Sub-components ───────────────────────────────────────────────────────────

const Check = ({ ok, label }: { ok: boolean; label: string }) => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12 }}>
    <div style={{
      width: 16, height: 16, borderRadius: '50%', flexShrink: 0,
      background: ok ? '#DCFCE7' : '#F1F5F9',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      transition: 'all .2s',
    }}>
      <i className="fa-solid fa-check" style={{ fontSize: 8, color: ok ? '#16A34A' : '#CBD5E1' }} />
    </div>
    <span style={{ color: ok ? '#374151' : '#9CA3AF', transition: 'color .2s' }}>{label}</span>
  </div>
);

// ─── Component ────────────────────────────────────────────────────────────────

export default function PasswordResetAdmin() {
  const { can } = usePermissions();
  const canReset = can('sec_password_reset.edit');

  // Employee search
  const [empSearch,      setEmpSearch]      = useState('');
  const [employees,      setEmployees]      = useState<Employee[]>([]);
  const [unlinked,       setUnlinked]       = useState<Employee[]>([]);
  const [empLoading,     setEmpLoading]     = useState(false);
  const [showDropdown,   setShowDropdown]   = useState(false);
  const [selected,       setSelected]       = useState<Employee | null>(null);
  const [relinking,      setRelinking]      = useState<string | null>(null);
  const [relinkResult,   setRelinkResult]   = useState<{ empId: string; ok: boolean; msg: string } | null>(null);
  const searchRef = useRef<HTMLDivElement>(null);

  // Form
  const [mode,         setMode]         = useState<Mode>('set_password');
  const [tempPassword, setTempPassword] = useState(generatePassword());
  const [showPassword, setShowPassword] = useState(false);
  // force_change is always true — employees must set a new password on first login
  const [copied,       setCopied]       = useState(false);

  // Execution
  const [confirming,   setConfirming]   = useState(false);
  const [executing,    setExecuting]    = useState(false);
  const [result,       setResult]       = useState<{ ok: boolean; text: string } | null>(null);

  // Audit
  const [auditRows,    setAuditRows]    = useState<AuditRow[]>([]);
  const [auditLoading, setAuditLoading] = useState(false);
  const [filterAction, setFilterAction] = useState<'all' | 'set_password' | 'send_reset_link'>('all');
  const [filterName,   setFilterName]   = useState('');

  // ── Outside click ────────────────────────────────────────────────────────────
  useEffect(() => {
    const handle = (e: MouseEvent) => {
      if (searchRef.current && !searchRef.current.contains(e.target as Node))
        setShowDropdown(false);
    };
    document.addEventListener('mousedown', handle);
    return () => document.removeEventListener('mousedown', handle);
  }, []);

  // ── Search employees ─────────────────────────────────────────────────────────
  const loadEmployees = useCallback(async (q: string) => {
    if (q.trim().length < 2) { setEmployees([]); setShowDropdown(false); return; }
    setEmpLoading(true);
    const { data } = await supabase
      .from('employees')
      .select('id, name, business_email, job_title, employee_id, status, departments:departments!employees_dept_id_fkey(name)')
      .is('deleted_at', null)
      .ilike('name', `%${q.trim()}%`)
      .order('name')
      .limit(20);

    const empIds = (data ?? []).map(e => e.id);
    const { data: profiles } = await supabase
      .from('profiles').select('id, employee_id').in('employee_id', empIds).not('employee_id', 'is', null);

    // Map employee_id → profile.id (= auth.users.id) for passing to the Edge Function
    const profileIdByEmpId = Object.fromEntries(
      (profiles ?? []).map(p => [p.employee_id as string, p.id as string])
    );
    const linked = new Set((profiles ?? []).map(p => p.employee_id));
    const mapRow = (e: typeof data extends (infer T)[] | null ? T : never) => ({
      id:             e.id,
      profile_id:     profileIdByEmpId[e.id] ?? '',
      name:           e.name,
      business_email: e.business_email as string,
      job_title:      e.job_title as string | null,
      dept_name:      (e.departments as any)?.name ?? null,
      employee_id:    e.employee_id as string | null,
      status:         e.status as string,
    });
    setEmployees((data ?? []).filter(e => linked.has(e.id)).map(mapRow));
    setUnlinked((data ?? []).filter(e => !linked.has(e.id)).map(mapRow));
    setShowDropdown(true);
    setEmpLoading(false);
  }, []);

  useEffect(() => {
    const t = setTimeout(() => loadEmployees(empSearch), 300);
    return () => clearTimeout(t);
  }, [empSearch, loadEmployees]);

  // ── Audit ─────────────────────────────────────────────────────────────────────
  const loadAudit = useCallback(async () => {
    setAuditLoading(true);
    const { data } = await supabase.rpc('get_password_reset_audit', { p_limit: 50 });
    setAuditRows((data ?? []) as AuditRow[]);
    setAuditLoading(false);
  }, []);

  useEffect(() => { loadAudit(); }, [loadAudit]);

  // ── Execute ───────────────────────────────────────────────────────────────────
  async function executeReset() {
    if (!selected) return;
    setExecuting(true);
    setResult(null);
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) { setResult({ ok: false, text: 'Session expired — please refresh.' }); setExecuting(false); return; }

    const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string;
    const body = mode === 'set_password'
      ? { mode, target_profile_id: selected.profile_id, new_password: tempPassword, force_change: true }
      : { mode: 'send_reset_link', target_profile_id: selected.profile_id };

    try {
      const res  = await fetch(`${supabaseUrl}/functions/v1/admin-password-reset`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.access_token}` },
        body: JSON.stringify(body),
      });
      const json = await res.json();
      if (json.ok) {
        setResult({
          ok: true,
          text: mode === 'set_password'
            ? `Temporary password set for ${selected.name}. They will be prompted to change it on next login.`
            : `Reset link sent to ${selected.business_email}.`,
        });
        setSelected(null); setEmpSearch(''); setTempPassword(generatePassword()); setConfirming(false);
        loadAudit();
      } else {
        setResult({ ok: false, text: json.error ?? 'Reset failed.' });
      }
    } catch (e) {
      setResult({ ok: false, text: e instanceof Error ? e.message : 'Network error' });
    }
    setExecuting(false);
  }

  async function copyPassword() {
    await navigator.clipboard.writeText(tempPassword);
    setCopied(true);
    setTimeout(() => setCopied(false), 2500);
  }

  // ── Relink / Resend Invite ────────────────────────────────────────────────────
  async function handleRelink(emp: Employee) {
    if (!emp.business_email) return;
    setRelinking(emp.id);
    setRelinkResult(null);

    // 1. Resend OTP (creates auth user if missing, else refreshes)
    const { error: otpErr } = await supabase.auth.signInWithOtp({
      email: emp.business_email,
      options: { shouldCreateUser: true, emailRedirectTo: `${window.location.origin}/reset-password` },
    });
    if (otpErr) {
      setRelinkResult({ empId: emp.id, ok: false, msg: `Could not send invite: ${otpErr.message}` });
      setRelinking(null);
      return;
    }

    // 2. Retry link_profile_to_employee with backoff
    let linkData: { ok?: boolean; reason?: string } | null = null;
    let linkErr: { message: string } | null = null;
    for (let attempt = 0; attempt < 5; attempt++) {
      if (attempt > 0) await new Promise(r => setTimeout(r, 800 * attempt));
      const result = await supabase.rpc('link_profile_to_employee', { p_email: emp.business_email });
      linkErr = result.error as { message: string } | null;
      linkData = result.data as { ok?: boolean; reason?: string } | null;
      if (!linkErr && linkData?.ok) break;
      const reason = linkData?.reason ?? '';
      if (!reason.includes('auth user not found') && !reason.includes('profile row not yet')) break;
    }

    if (!linkErr && linkData?.ok) {
      setRelinkResult({ empId: emp.id, ok: true, msg: `Invite sent and profile linked for ${emp.name}. They will now appear in this search.` });
      // Refresh the search so they move from unlinked → linked
      loadEmployees(empSearch);
    } else {
      const detail = linkErr?.message ?? linkData?.reason ?? 'Unknown error';
      setRelinkResult({ empId: emp.id, ok: false, msg: `Invite sent but profile link failed: ${detail}` });
    }
    setRelinking(null);
  }

  // ── Derived ───────────────────────────────────────────────────────────────────
  const pwChecks  = passwordChecks(tempPassword);
  const pwStrength = strengthInfo(tempPassword);
  const canSubmit  = !!selected && canReset && (mode === 'send_reset_link' || tempPassword.length >= 8);

  const filteredAudit = auditRows.filter(r => {
    const matchAction = filterAction === 'all' || r.action === filterAction;
    const matchName   = !filterName.trim() || (r.target_name ?? r.target_email).toLowerCase().includes(filterName.toLowerCase());
    return matchAction && matchName;
  });
  const grouped = groupByDate(filteredAudit);

  // ─────────────────────────────────────────────────────────────────────────────

  return (
    <div style={{ padding: '0 0 48px', background: '#F8FAFC', minHeight: '100%' }}>

      {/* ── Page header ────────────────────────────────────────────────────────── */}
      <div style={{ marginBottom: 24 }}>
        <h2 style={{ margin: '0 0 4px', fontSize: 22, fontWeight: 700, color: '#0F172A', letterSpacing: '-0.3px' }}>
          Password Reset
        </h2>
        <p style={{ margin: 0, fontSize: 14, color: '#64748B' }}>
          Reset employee passwords or send a secure recovery link.
        </p>
      </div>

      {/* ── Security warning banner ─────────────────────────────────────────────── */}
      <div style={{
        marginBottom: 28, padding: '14px 18px', borderRadius: 14,
        background: '#FFFBEB', border: '1px solid #F59E0B',
        display: 'flex', alignItems: 'flex-start', gap: 12,
      }}>
        <div style={{
          width: 32, height: 32, borderRadius: 8, flexShrink: 0,
          background: '#FEF3C7', display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <i className="fa-solid fa-triangle-exclamation" style={{ color: '#D97706', fontSize: 14 }} />
        </div>
        <div>
          <div style={{ fontWeight: 700, fontSize: 13, color: '#92400E', marginBottom: 3 }}>
            Security-Sensitive Action
          </div>
          <div style={{ fontSize: 12, color: '#B45309', lineHeight: 1.6 }}>
            All password resets are logged with <strong>actor</strong>, <strong>timestamp</strong>, <strong>IP address</strong>, and <strong>reset type</strong>. Only reset passwords when absolutely necessary.
          </div>
        </div>
      </div>

      {/* ── Result banner ──────────────────────────────────────────────────────── */}
      {result && (
        <div style={{
          marginBottom: 20, padding: '14px 18px', borderRadius: 12,
          background: result.ok ? '#F0FDF4' : '#FEF2F2',
          border: `1px solid ${result.ok ? '#BBF7D0' : '#FECACA'}`,
          display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <i className={`fa-solid ${result.ok ? 'fa-circle-check' : 'fa-circle-exclamation'}`}
             style={{ fontSize: 16, color: result.ok ? '#16A34A' : '#DC2626', flexShrink: 0 }} />
          <span style={{ fontSize: 13, color: result.ok ? '#15803D' : '#DC2626', fontWeight: 500 }}>{result.text}</span>
          <button type="button" onClick={() => setResult(null)}
            style={{ marginLeft: 'auto', background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', padding: 2 }}>
            <i className="fa-solid fa-xmark" />
          </button>
        </div>
      )}

      {/* ── Stacked layout: form top, audit trail bottom ───────────────────────── */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>

        {/* ════════════════════════════════════════════════════════════════════════
            Reset Form
        ════════════════════════════════════════════════════════════════════════ */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16, maxWidth: 720 }}>

          {/* ── 1. Employee search ──────────────────────────────────────────────── */}
          <div style={{
            background: '#fff', borderRadius: 16,
            border: '1px solid #E5E7EB',
            boxShadow: '0 2px 10px rgba(0,0,0,0.04)',
          }}>
            <div style={{ padding: '18px 22px 14px', borderBottom: '1px solid #F1F5F9' }}>
              <div style={{ fontSize: 11, fontWeight: 700, color: '#94A3B8', letterSpacing: '0.08em', textTransform: 'uppercase' }}>
                Step 1 — Select Employee
              </div>
            </div>
            <div style={{ padding: '18px 22px' }}>
              {!selected ? (
                /* Search input */
                <div ref={searchRef} style={{ position: 'relative' }}>
                  <div style={{ position: 'relative' }}>
                    <i className="fa-solid fa-magnifying-glass" style={{
                      position: 'absolute', left: 13, top: '50%', transform: 'translateY(-50%)',
                      color: '#9CA3AF', fontSize: 13, pointerEvents: 'none',
                    }} />
                    <input
                      type="text"
                      placeholder="Search employee by name…"
                      value={empSearch}
                      onChange={e => { setEmpSearch(e.target.value); setResult(null); }}
                      onFocus={() => employees.length > 0 && setShowDropdown(true)}
                      autoComplete="off"
                      style={{
                        width: '100%', boxSizing: 'border-box',
                        height: 44, paddingLeft: 38, paddingRight: 40,
                        borderRadius: 10, border: '1.5px solid #E5E7EB',
                        fontSize: 14, color: '#0F172A',
                        background: '#F8FAFC', outline: 'none',
                        transition: 'border-color .15s, box-shadow .15s',
                      }}
                      onFocusCapture={e => {
                        (e.target as HTMLInputElement).style.borderColor = '#3B82F6';
                        (e.target as HTMLInputElement).style.boxShadow = '0 0 0 3px rgba(59,130,246,.12)';
                        (e.target as HTMLInputElement).style.background = '#fff';
                      }}
                      onBlurCapture={e => {
                        (e.target as HTMLInputElement).style.borderColor = '#E5E7EB';
                        (e.target as HTMLInputElement).style.boxShadow = 'none';
                        (e.target as HTMLInputElement).style.background = '#F8FAFC';
                      }}
                    />
                    {empLoading && (
                      <i className="fa-solid fa-spinner fa-spin" style={{
                        position: 'absolute', right: 13, top: '50%', transform: 'translateY(-50%)',
                        color: '#94A3B8', fontSize: 13,
                      }} />
                    )}
                  </div>
                  <p style={{ margin: '6px 0 0', fontSize: 12, color: '#94A3B8' }}>
                    Type at least 2 characters to search
                  </p>

                  {/* Dropdown */}
                  {showDropdown && (
                    <div style={{
                      position: 'absolute', top: 50, left: 0, right: 0, zIndex: 99,
                      background: '#fff', borderRadius: 12,
                      border: '1px solid #E5E7EB',
                      boxShadow: '0 12px 32px rgba(0,0,0,.12)',
                      maxHeight: 320, overflowY: 'auto',
                    }}>
                      {employees.length === 0 && unlinked.length === 0 ? (
                        <div style={{ padding: '16px', fontSize: 13, color: '#94A3B8', textAlign: 'center' }}>
                          No employees found
                        </div>
                      ) : (
                        <>
                          {employees.map((emp, i) => (
                            <button key={emp.id} type="button"
                              onMouseDown={e => e.preventDefault()}
                              onClick={() => { setSelected(emp); setShowDropdown(false); setEmpSearch(''); }}
                              style={{
                                width: '100%', textAlign: 'left', padding: '10px 16px',
                                border: 'none', borderBottom: '1px solid #F1F5F9',
                                background: 'none', cursor: 'pointer',
                                display: 'flex', alignItems: 'center', gap: 12, transition: 'background .1s',
                              }}
                              onMouseEnter={e => (e.currentTarget.style.background = '#F8FAFC')}
                              onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                            >
                              <div style={{
                                width: 36, height: 36, borderRadius: '50%', flexShrink: 0,
                                background: 'linear-gradient(135deg, #3B82F6, #1D4ED8)',
                                display: 'flex', alignItems: 'center', justifyContent: 'center',
                                fontSize: 13, fontWeight: 700, color: '#fff',
                              }}>
                                {initials(emp.name)}
                              </div>
                              <div style={{ minWidth: 0 }}>
                                <div style={{ fontWeight: 600, fontSize: 13, color: '#0F172A' }}>{emp.name}</div>
                                <div style={{ fontSize: 11, color: '#94A3B8' }}>
                                  {emp.business_email}{emp.dept_name ? ` · ${emp.dept_name}` : ''}
                                </div>
                              </div>
                            </button>
                          ))}
                          {unlinked.length > 0 && (
                            <>
                              <div style={{ padding: '8px 16px 4px', fontSize: 10, fontWeight: 700, color: '#F59E0B', letterSpacing: '0.06em', textTransform: 'uppercase', background: '#FFFBEB', borderTop: employees.length > 0 ? '1px solid #FDE68A' : undefined }}>
                                No login account yet — invite not sent
                              </div>
                              {unlinked.map(emp => (
                                <div key={emp.id} style={{
                                  padding: '10px 16px', borderBottom: '1px solid #F1F5F9',
                                  display: 'flex', alignItems: 'center', gap: 12,
                                }}>
                                  <div style={{
                                    width: 36, height: 36, borderRadius: '50%', flexShrink: 0,
                                    background: 'linear-gradient(135deg, #F59E0B, #D97706)',
                                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                                    fontSize: 13, fontWeight: 700, color: '#fff',
                                  }}>
                                    {initials(emp.name)}
                                  </div>
                                  <div style={{ minWidth: 0, flex: 1 }}>
                                    <div style={{ fontWeight: 600, fontSize: 13, color: '#0F172A' }}>{emp.name}</div>
                                    <div style={{ fontSize: 11, color: '#94A3B8' }}>
                                      {emp.business_email}{emp.dept_name ? ` · ${emp.dept_name}` : ''}
                                    </div>
                                    {relinkResult?.empId === emp.id && (
                                      <div style={{ fontSize: 11, color: relinkResult.ok ? '#16A34A' : '#DC2626', marginTop: 2 }}>
                                        {relinkResult.msg}
                                      </div>
                                    )}
                                  </div>
                                  {canReset && (
                                    <button type="button"
                                      onMouseDown={e => e.preventDefault()}
                                      onClick={() => handleRelink(emp)}
                                      disabled={relinking === emp.id}
                                      style={{
                                        flexShrink: 0, padding: '5px 12px', fontSize: 11, fontWeight: 600,
                                        border: '1px solid #F59E0B', borderRadius: 6, cursor: 'pointer',
                                        background: relinking === emp.id ? '#FDE68A' : '#FFFBEB', color: '#92400E',
                                      }}
                                    >
                                      {relinking === emp.id ? <i className="fa-solid fa-spinner fa-spin" /> : 'Resend Invite'}
                                    </button>
                                  )}
                                </div>
                              ))}
                            </>
                          )}
                        </>
                      )}
                    </div>
                  )}
                </div>
              ) : (
                /* Employee summary card */
                <div style={{
                  borderRadius: 14, border: '1.5px solid #BFDBFE',
                  background: 'linear-gradient(135deg, #EFF6FF 0%, #F0F9FF 100%)',
                  padding: 18, position: 'relative',
                  boxShadow: '0 2px 10px rgba(59,130,246,0.08)',
                }}>
                  <button type="button"
                    onClick={() => { setSelected(null); setResult(null); setEmpSearch(''); }}
                    style={{
                      position: 'absolute', top: 12, right: 12,
                      background: '#fff', border: '1px solid #E5E7EB',
                      borderRadius: 8, cursor: 'pointer', width: 28, height: 28,
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      color: '#64748B', fontSize: 12, boxShadow: '0 1px 3px rgba(0,0,0,0.06)',
                    }}
                    title="Change employee"
                  >
                    <i className="fa-solid fa-xmark" />
                  </button>

                  <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 14 }}>
                    <div style={{
                      width: 48, height: 48, borderRadius: '50%',
                      background: 'linear-gradient(135deg, #3B82F6, #1D4ED8)',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      fontSize: 17, fontWeight: 700, color: '#fff', flexShrink: 0,
                      boxShadow: '0 4px 12px rgba(59,130,246,0.3)',
                    }}>
                      {initials(selected.name)}
                    </div>
                    <div>
                      <div style={{ fontWeight: 700, fontSize: 16, color: '#0F172A', marginBottom: 1 }}>
                        {selected.name}
                      </div>
                      {selected.employee_id && (
                        <div style={{ fontSize: 11, fontWeight: 600, color: '#3B82F6', letterSpacing: '0.04em' }}>
                          {selected.employee_id}
                        </div>
                      )}
                    </div>
                  </div>

                  <div style={{
                    display: 'grid', gridTemplateColumns: '1fr 1fr',
                    gap: 10, borderTop: '1px solid #DBEAFE', paddingTop: 14,
                  }}>
                    {[
                      { icon: 'fa-briefcase',    label: 'Role',       val: selected.job_title ?? '—' },
                      { icon: 'fa-envelope',     label: 'Email',      val: selected.business_email },
                      { icon: 'fa-building',     label: 'Department', val: selected.dept_name ?? '—' },
                      { icon: 'fa-circle-check', label: 'Status',     val: selected.status, green: true },
                    ].map(item => (
                      <div key={item.label}>
                        <div style={{ fontSize: 10, fontWeight: 600, color: '#93C5FD', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 2 }}>
                          {item.label}
                        </div>
                        <div style={{
                          fontSize: 12, fontWeight: 600, color: item.green ? '#16A34A' : '#1E3A5F',
                          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                          display: 'flex', alignItems: 'center', gap: 4,
                        }}>
                          {item.green && <span style={{ width: 6, height: 6, borderRadius: '50%', background: '#22C55E', flexShrink: 0 }} />}
                          {item.val}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </div>

          {/* ── 2. Reset method ─────────────────────────────────────────────────── */}
          <div style={{
            background: '#fff', borderRadius: 16,
            border: '1px solid #E5E7EB',
            boxShadow: '0 2px 10px rgba(0,0,0,0.04)',
          }}>
            <div style={{ padding: '18px 22px 14px', borderBottom: '1px solid #F1F5F9' }}>
              <div style={{ fontSize: 11, fontWeight: 700, color: '#94A3B8', letterSpacing: '0.08em', textTransform: 'uppercase' }}>
                Step 2 — Choose Reset Method
              </div>
            </div>
            <div style={{ padding: '16px 22px', display: 'flex', flexDirection: 'column', gap: 10 }}>
              {([
                {
                  value: 'set_password' as Mode,
                  icon: 'fa-lock',
                  title: 'Temporary Password',
                  desc: 'Create a temporary password and share it with the employee.',
                  color: '#2563EB',
                  bg: '#EFF6FF',
                  border: '#BFDBFE',
                },
                {
                  value: 'send_reset_link' as Mode,
                  icon: 'fa-envelope',
                  title: 'Send Reset Link',
                  desc: 'Employee receives a secure reset link via email. Expires in 24 hours.',
                  color: '#7C3AED',
                  bg: '#F5F3FF',
                  border: '#DDD6FE',
                },
              ]).map(opt => {
                const active = mode === opt.value;
                return (
                  <button key={opt.value} type="button"
                    onClick={() => setMode(opt.value)}
                    style={{
                      width: '100%', textAlign: 'left', padding: '14px 16px', borderRadius: 12,
                      border: `2px solid ${active ? opt.border : '#E5E7EB'}`,
                      background: active ? opt.bg : '#fff',
                      cursor: 'pointer', display: 'flex', alignItems: 'flex-start', gap: 12,
                      transition: 'all .15s ease',
                      boxShadow: active ? `0 0 0 3px ${opt.color}18` : 'none',
                    }}
                    onMouseEnter={e => { if (!active) (e.currentTarget.style.borderColor = '#93C5FD'); }}
                    onMouseLeave={e => { if (!active) (e.currentTarget.style.borderColor = '#E5E7EB'); }}
                  >
                    <div style={{
                      width: 38, height: 38, borderRadius: 10, flexShrink: 0,
                      background: active ? opt.color : '#F1F5F9',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      transition: 'all .15s',
                    }}>
                      <i className={`fa-solid ${opt.icon}`} style={{ color: active ? '#fff' : '#94A3B8', fontSize: 14 }} />
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <span style={{ fontWeight: 700, fontSize: 13, color: '#0F172A' }}>{opt.title}</span>
                        {active && (
                          <span style={{
                            padding: '1px 8px', borderRadius: 20, fontSize: 10, fontWeight: 700,
                            background: opt.color, color: '#fff', letterSpacing: '0.04em',
                          }}>
                            SELECTED
                          </span>
                        )}
                      </div>
                      <div style={{ fontSize: 12, color: '#64748B', marginTop: 3, lineHeight: 1.5 }}>{opt.desc}</div>
                    </div>
                    <div style={{
                      width: 18, height: 18, borderRadius: '50%', flexShrink: 0, marginTop: 2,
                      border: `2px solid ${active ? opt.color : '#D1D5DB'}`,
                      background: active ? opt.color : '#fff',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      transition: 'all .15s',
                    }}>
                      {active && <div style={{ width: 6, height: 6, borderRadius: '50%', background: '#fff' }} />}
                    </div>
                  </button>
                );
              })}
            </div>
          </div>

          {/* ── 3. Password + security options ─────────────────────────────────── */}
          {mode === 'set_password' && (
            <div style={{
              background: '#fff', borderRadius: 16,
              border: '1px solid #E5E7EB',
              boxShadow: '0 2px 10px rgba(0,0,0,0.04)',
            }}>
              <div style={{ padding: '18px 22px 14px', borderBottom: '1px solid #F1F5F9' }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: '#94A3B8', letterSpacing: '0.08em', textTransform: 'uppercase' }}>
                  Step 3 — Configure Password
                </div>
              </div>
              <div style={{ padding: '18px 22px' }}>

                {/* Password field */}
                <div style={{ marginBottom: 18 }}>
                  <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: '#374151', marginBottom: 8 }}>
                    Temporary Password
                  </label>
                  <div style={{
                    display: 'flex', alignItems: 'center', gap: 0,
                    border: '1.5px solid #E5E7EB', borderRadius: 10, overflow: 'hidden',
                    background: '#fff', transition: 'border-color .15s, box-shadow .15s',
                  }}
                    onFocusCapture={e => {
                      (e.currentTarget as HTMLDivElement).style.borderColor = '#3B82F6';
                      (e.currentTarget as HTMLDivElement).style.boxShadow = '0 0 0 3px rgba(59,130,246,.12)';
                    }}
                    onBlurCapture={e => {
                      (e.currentTarget as HTMLDivElement).style.borderColor = '#E5E7EB';
                      (e.currentTarget as HTMLDivElement).style.boxShadow = 'none';
                    }}
                  >
                    <input
                      type={showPassword ? 'text' : 'password'}
                      value={tempPassword}
                      onChange={e => setTempPassword(e.target.value)}
                      style={{
                        flex: 1, height: 44, padding: '0 12px',
                        border: 'none', outline: 'none', fontSize: 14,
                        fontFamily: showPassword ? 'monospace' : undefined,
                        letterSpacing: showPassword ? '0.06em' : undefined,
                        color: '#0F172A', background: 'transparent',
                      }}
                    />
                    <div style={{ display: 'flex', borderLeft: '1px solid #F1F5F9' }}>
                      {[
                        { icon: showPassword ? 'fa-eye-slash' : 'fa-eye', action: () => setShowPassword(v => !v), title: showPassword ? 'Hide' : 'Show' },
                        { icon: 'fa-arrows-rotate', action: () => { setTempPassword(generatePassword()); setCopied(false); }, title: 'Generate' },
                        { icon: copied ? 'fa-check' : 'fa-copy', action: copyPassword, title: copied ? 'Copied!' : 'Copy', green: copied },
                      ].map((btn, i) => (
                        <button key={i} type="button" onClick={btn.action} title={btn.title}
                          style={{
                            width: 42, height: 44, border: 'none',
                            borderLeft: i > 0 ? '1px solid #F1F5F9' : 'none',
                            background: btn.green ? '#F0FDF4' : 'transparent',
                            cursor: 'pointer', color: btn.green ? '#16A34A' : '#64748B',
                            display: 'flex', alignItems: 'center', justifyContent: 'center',
                            transition: 'all .15s',
                          }}
                          onMouseEnter={e => { (e.currentTarget as HTMLButtonElement).style.background = btn.green ? '#DCFCE7' : '#F8FAFC'; }}
                          onMouseLeave={e => { (e.currentTarget as HTMLButtonElement).style.background = btn.green ? '#F0FDF4' : 'transparent'; }}
                        >
                          <i className={`fa-solid ${btn.icon}`} style={{ fontSize: 13 }} />
                        </button>
                      ))}
                    </div>
                  </div>
                </div>

                {/* Strength bar */}
                <div style={{ marginBottom: 16 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
                    <span style={{ fontSize: 12, fontWeight: 600, color: '#374151' }}>Password Strength</span>
                    <span style={{
                      fontSize: 11, fontWeight: 700, color: pwStrength.color,
                      padding: '2px 8px', borderRadius: 20, background: pwStrength.bg,
                    }}>
                      {pwStrength.label}
                    </span>
                  </div>
                  <div style={{ height: 6, borderRadius: 6, background: '#F1F5F9', overflow: 'hidden' }}>
                    <div style={{
                      height: '100%', borderRadius: 6, background: pwStrength.color,
                      width: `${pwStrength.pct}%`, transition: 'all .4s ease',
                    }} />
                  </div>
                </div>

                {/* Checklist */}
                <div style={{
                  display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '6px 12px',
                  padding: '12px 14px', borderRadius: 10, background: '#F8FAFC',
                  border: '1px solid #E5E7EB', marginBottom: 18,
                }}>
                  <Check ok={pwChecks.upper}   label="Uppercase letter" />
                  <Check ok={pwChecks.lower}   label="Lowercase letter" />
                  <Check ok={pwChecks.digit}   label="Number" />
                  <Check ok={pwChecks.special} label="Special character" />
                  <Check ok={pwChecks.length}  label="Minimum 8 characters" />
                </div>

                {/* Force-change is always on — no UI needed */}
              </div>
            </div>
          )}

          {/* ── Primary action ──────────────────────────────────────────────────── */}
          <button
            type="button"
            onClick={() => setConfirming(true)}
            disabled={!canSubmit}
            style={{
              width: '100%', height: 48, borderRadius: 12, fontSize: 15, fontWeight: 700,
              border: 'none', cursor: canSubmit ? 'pointer' : 'not-allowed',
              background: canSubmit ? '#2563EB' : '#CBD5E1',
              color: canSubmit ? '#fff' : '#94A3B8',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
              transition: 'all .2s ease',
              boxShadow: canSubmit ? '0 4px 14px rgba(37,99,235,0.35)' : 'none',
              letterSpacing: '0.01em',
            }}
            onMouseEnter={e => { if (canSubmit) { (e.currentTarget.style.background = '#1D4ED8'); (e.currentTarget.style.transform = 'translateY(-1px)'); (e.currentTarget.style.boxShadow = '0 8px 20px rgba(37,99,235,0.4)'); } }}
            onMouseLeave={e => { if (canSubmit) { (e.currentTarget.style.background = '#2563EB'); (e.currentTarget.style.transform = 'translateY(0)'); (e.currentTarget.style.boxShadow = '0 4px 14px rgba(37,99,235,0.35)'); } }}
          >
            <i className="fa-solid fa-lock-open" />
            {mode === 'set_password' ? 'Create Temporary Password' : 'Send Reset Link'}
          </button>

          {!canReset && (
            <p style={{ textAlign: 'center', fontSize: 12, color: '#94A3B8', margin: 0 }}>
              <i className="fa-solid fa-lock" style={{ marginRight: 5 }} />
              View-only access. Contact a super-admin to enable resets.
            </p>
          )}
        </div>

        {/* ════════════════════════════════════════════════════════════════════════
            Audit Trail (full width, below form)
        ════════════════════════════════════════════════════════════════════════ */}
        <div style={{
          background: '#fff', borderRadius: 16,
          border: '1px solid #E5E7EB',
          boxShadow: '0 2px 10px rgba(0,0,0,0.04)',
          overflow: 'hidden',
        }}>
          {/* Header */}
          <div style={{
            padding: '18px 22px', borderBottom: '1px solid #F1F5F9',
            display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          }}>
            <div>
              <div style={{ fontWeight: 700, fontSize: 15, color: '#0F172A' }}>
                <i className="fa-solid fa-clock-rotate-left" style={{ color: '#7C3AED', marginRight: 8 }} />
                Audit Trail
              </div>
              <div style={{ fontSize: 12, color: '#94A3B8', marginTop: 2 }}>Complete log of password reset actions</div>
            </div>
            <button type="button" onClick={loadAudit} disabled={auditLoading}
              style={{
                padding: '7px 14px', borderRadius: 8, fontSize: 12, fontWeight: 600,
                border: '1.5px solid #E5E7EB', background: '#fff',
                color: '#374151', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6,
                transition: 'all .15s',
              }}
              onMouseEnter={e => (e.currentTarget.style.background = '#F8FAFC')}
              onMouseLeave={e => (e.currentTarget.style.background = '#fff')}
            >
              <i className={`fa-solid fa-arrows-rotate ${auditLoading ? 'fa-spin' : ''}`} />
              Refresh
            </button>
          </div>

          {/* Filters */}
          <div style={{
            padding: '12px 22px', borderBottom: '1px solid #F1F5F9',
            display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap',
          }}>
            {/* Name filter */}
            <div style={{ position: 'relative', flex: '0 0 180px' }}>
              <i className="fa-solid fa-magnifying-glass" style={{
                position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
                color: '#9CA3AF', fontSize: 11, pointerEvents: 'none',
              }} />
              <input
                type="text"
                placeholder="Filter by employee…"
                value={filterName}
                onChange={e => setFilterName(e.target.value)}
                style={{
                  width: '100%', boxSizing: 'border-box',
                  height: 34, paddingLeft: 28, paddingRight: 10,
                  borderRadius: 8, border: '1.5px solid #E5E7EB',
                  fontSize: 12, color: '#374151', outline: 'none',
                  background: '#F8FAFC', transition: 'border-color .15s',
                }}
                onFocus={e => (e.target.style.borderColor = '#93C5FD')}
                onBlur={e => (e.target.style.borderColor = '#E5E7EB')}
              />
            </div>

            {/* Action filter */}
            <select
              value={filterAction}
              onChange={e => setFilterAction(e.target.value as any)}
              style={{
                height: 34, padding: '0 10px', borderRadius: 8,
                border: '1.5px solid #E5E7EB', fontSize: 12, color: '#374151',
                background: '#F8FAFC', outline: 'none', cursor: 'pointer',
              }}
            >
              <option value="all">All Types</option>
              <option value="set_password">Temp Password</option>
              <option value="send_reset_link">Reset Link</option>
            </select>

            {/* Count */}
            <span style={{ fontSize: 12, color: '#94A3B8', marginLeft: 'auto' }}>
              {filteredAudit.length} {filteredAudit.length === 1 ? 'entry' : 'entries'}
            </span>
          </div>

          {/* Timeline */}
          <div style={{ padding: '0 22px', maxHeight: 560, overflowY: 'auto' }}>
            {auditLoading ? (
              <div style={{ textAlign: 'center', padding: '48px 0', color: '#94A3B8' }}>
                <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 22 }} />
              </div>
            ) : grouped.length === 0 ? (
              <div style={{ textAlign: 'center', padding: '56px 0', color: '#94A3B8' }}>
                <div style={{
                  width: 56, height: 56, borderRadius: '50%', background: '#F1F5F9',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  margin: '0 auto 16px',
                }}>
                  <i className="fa-solid fa-shield-halved" style={{ fontSize: 22, color: '#CBD5E1' }} />
                </div>
                <div style={{ fontWeight: 700, fontSize: 14, color: '#475569', marginBottom: 4 }}>No resets yet</div>
                <div style={{ fontSize: 12 }}>Actions will appear here after the first reset.</div>
              </div>
            ) : grouped.map(group => (
              <div key={group.label}>
                {/* Date label */}
                <div style={{
                  position: 'sticky', top: 0, zIndex: 2,
                  padding: '10px 0 8px',
                  background: '#fff',
                }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <div style={{ flex: 1, height: 1, background: '#F1F5F9' }} />
                    <span style={{
                      fontSize: 11, fontWeight: 700, color: '#94A3B8',
                      letterSpacing: '0.06em', textTransform: 'uppercase',
                      padding: '2px 10px', borderRadius: 20,
                      background: '#F8FAFC', border: '1px solid #E5E7EB',
                    }}>
                      {group.label}
                    </span>
                    <div style={{ flex: 1, height: 1, background: '#F1F5F9' }} />
                  </div>
                </div>

                {/* Entries */}
                {group.rows.map((row, i) => (
                  <div key={row.id} style={{
                    display: 'flex', gap: 14, paddingBottom: i < group.rows.length - 1 ? 16 : 20,
                    paddingTop: 4,
                  }}>
                    {/* Timeline line + dot */}
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', flexShrink: 0 }}>
                      <div style={{
                        width: 32, height: 32, borderRadius: 10,
                        background: row.success
                          ? (row.action === 'set_password' ? '#EFF6FF' : '#F5F3FF')
                          : '#FEF2F2',
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                        border: `1.5px solid ${row.success ? (row.action === 'set_password' ? '#BFDBFE' : '#DDD6FE') : '#FECACA'}`,
                      }}>
                        <i className={`fa-solid ${row.success ? (row.action === 'set_password' ? 'fa-lock' : 'fa-envelope') : 'fa-xmark'}`}
                           style={{
                             fontSize: 12,
                             color: row.success ? (row.action === 'set_password' ? '#2563EB' : '#7C3AED') : '#EF4444',
                           }} />
                      </div>
                      {i < group.rows.length - 1 && (
                        <div style={{ width: 2, flex: 1, marginTop: 4, background: '#F1F5F9', borderRadius: 2 }} />
                      )}
                    </div>

                    {/* Content */}
                    <div style={{ flex: 1, minWidth: 0, paddingTop: 4 }}>
                      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 8 }}>
                        <div style={{ minWidth: 0 }}>
                          <div style={{ fontSize: 13, color: '#374151', lineHeight: 1.5 }}>
                            <strong style={{ color: '#0F172A' }}>{row.actor_name ?? 'Unknown'}</strong>
                            {' '}
                            <span style={{ color: '#64748B' }}>
                              {row.action === 'set_password' ? 'set temp password for' : 'sent reset link to'}
                            </span>
                            {' '}
                            <strong style={{ color: '#0F172A' }}>{row.target_name ?? row.target_email}</strong>
                          </div>
                          <div style={{ display: 'flex', gap: 6, marginTop: 5, flexWrap: 'wrap' }}>
                            {row.force_change && (
                              <span style={{
                                fontSize: 10, fontWeight: 700, padding: '2px 8px', borderRadius: 20,
                                background: '#FFF7ED', color: '#C2410C', border: '1px solid #FED7AA',
                              }}>
                                FORCE CHANGE
                              </span>
                            )}
                            {!row.success && (
                              <span style={{
                                fontSize: 10, fontWeight: 700, padding: '2px 8px', borderRadius: 20,
                                background: '#FEF2F2', color: '#DC2626', border: '1px solid #FECACA',
                              }}>
                                FAILED
                              </span>
                            )}
                            {row.error_message && (
                              <span style={{ fontSize: 11, color: '#EF4444' }}>{row.error_message}</span>
                            )}
                          </div>
                        </div>
                        <div style={{
                          fontSize: 11, color: '#94A3B8', whiteSpace: 'nowrap',
                          flexShrink: 0, paddingTop: 2, fontVariantNumeric: 'tabular-nums',
                        }}>
                          {formatTime(row.created_at)}
                        </div>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* ── Confirm dialog ─────────────────────────────────────────────────────── */}
      {confirming && selected && (
        <div className="modal-overlay" onClick={() => !executing && setConfirming(false)}>
          <div className="modal-box" onClick={e => e.stopPropagation()} style={{ maxWidth: 440 }}>
            <div style={{ display: 'flex', gap: 14, marginBottom: 20 }}>
              <div style={{
                width: 46, height: 46, borderRadius: 12, flexShrink: 0,
                background: '#FEF3C7', display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>
                <i className="fa-solid fa-triangle-exclamation" style={{ color: '#D97706', fontSize: 20 }} />
              </div>
              <div>
                <h3 style={{ margin: '0 0 5px', fontSize: 16, fontWeight: 700, color: '#0F172A' }}>
                  Confirm Password Reset
                </h3>
                <p style={{ margin: 0, fontSize: 13, color: '#64748B', lineHeight: 1.55 }}>
                  {mode === 'set_password'
                    ? <><strong>Set a temporary password</strong> for <strong>{selected.name}</strong>. They must change it on next login.</>

                    : <><strong>Send a reset link</strong> to <strong>{selected.name}</strong> ({selected.business_email}).</>
                  }
                </p>
              </div>
            </div>

            <div style={{
              padding: '12px 16px', borderRadius: 10, marginBottom: 22,
              background: '#F8FAFC', border: '1px solid #E5E7EB',
              fontSize: 12, color: '#64748B', display: 'flex', alignItems: 'center', gap: 8,
            }}>
              <i className="fa-solid fa-shield" style={{ color: '#2563EB' }} />
              This action will be permanently recorded in the audit trail.
            </div>

            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button type="button" className="btn-secondary" onClick={() => setConfirming(false)} disabled={executing}
                style={{ borderRadius: 10 }}>
                Cancel
              </button>
              <button type="button" className="btn-danger" onClick={executeReset} disabled={executing}
                style={{ borderRadius: 10, minWidth: 130 }}>
                {executing
                  ? <><i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Processing…</>
                  : <><i className="fa-solid fa-lock-open" style={{ marginRight: 6 }} />{mode === 'set_password' ? 'Set Password' : 'Send Link'}</>
                }
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
