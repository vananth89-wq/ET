/**
 * RbpTroubleshoot
 *
 * Admin tool for diagnosing Role-Based Permissions.
 *
 * Tab 1 — User Lookup:
 *   Search any user → see active roles (with granted date) and every permission
 *   grouped by module. Modules are collapsible. Results are filterable.
 *
 * Tab 2 — Permission Lookup:
 *   Enter a permission code → see every user who holds it and which role grants it.
 *
 * Access gate: workflow.rbp_troubleshoot (React + DB SECURITY DEFINER RPCs).
 */

import { useState, useRef, useEffect, useCallback, useMemo } from 'react';
import { supabase } from '../../../lib/supabase';

// ─── Types ───────────────────────────────────────────────────────────────────

interface PermissionOption {
  code:        string;
  name:        string;
  module_code: string;
  module_name: string;
  module_sort: number;
}

interface UserResult {
  profile_id:  string;
  employee_id: string;
  name:        string;
  email:       string;
  designation: string;
  status:      string;
  role_codes:  string;
}

interface RoleRow {
  role_code:         string;
  role_name:         string;
  assignment_source: string;
  granted_at:        string | null;
}

interface PermRow {
  user_name:        string;
  user_email:       string;
  user_employee_id: string;
  user_designation: string;
  user_status:      string;
  module_code:      string;
  module_name:      string;
  module_sort:      number;
  permission_code:  string;
  permission_name:  string;
  permission_desc:  string;
  via_roles:        string;
}

interface ModuleGroup {
  module_code: string;
  module_name: string;
  module_sort: number;
  perms:       PermRow[];
}

interface ReverseRow {
  profile_id:    string;
  employee_id:   string;
  name:          string;
  email:         string;
  designation:   string;
  status:        string;
  via_role_code: string;
  via_role_name: string;
  granted_at:    string | null;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

const STATUS_COLORS: Record<string, { bg: string; color: string }> = {
  Active:   { bg: '#DCFCE7', color: '#15803D' },
  Inactive: { bg: '#FEE2E2', color: '#DC2626' },
  Draft:    { bg: '#F3F4F6', color: '#6B7280' },
};

const MODULE_ICONS: Record<string, string> = {
  expense:      'fa-receipt',
  employee:     'fa-user',
  organization: 'fa-sitemap',
  reference:    'fa-database',
  report:       'fa-chart-bar',
  security:     'fa-shield-halved',
  workflow:     'fa-code-branch',
  department:   'fa-building',
};

const SOURCE_LABEL: Record<string, string> = {
  system: 'System',
  manual: 'Manual',
  sync:   'Sync',
};

function groupByModule(rows: PermRow[]): ModuleGroup[] {
  const map = new Map<string, ModuleGroup>();
  for (const row of rows) {
    if (!map.has(row.module_code)) {
      map.set(row.module_code, {
        module_code: row.module_code,
        module_name: row.module_name,
        module_sort: row.module_sort,
        perms: [],
      });
    }
    map.get(row.module_code)!.perms.push(row);
  }
  return [...map.values()].sort((a, b) => a.module_sort - b.module_sort);
}

function fmtDate(iso: string | null): string {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('en-GB', { month: 'short', year: 'numeric' })
    .format(new Date(iso));
}

function initials(name: string): string {
  return name.split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase();
}

// ─── Sub-components ──────────────────────────────────────────────────────────

function SearchBox({
  value, onChange, onClear, searching, placeholder,
}: {
  value: string; onChange: (v: string) => void; onClear: () => void;
  searching: boolean; placeholder: string;
}) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 7,
      background: '#fff', border: '1px solid #D1D5DB',
      borderRadius: 6, padding: '0 10px', height: 34,
      boxShadow: '0 1px 2px rgba(0,0,0,0.04)',
    }}>
      <i className={`fas ${searching ? 'fa-spinner fa-spin' : 'fa-search'}`}
         style={{ color: '#9CA3AF', fontSize: 12, flexShrink: 0 }} />
      <input
        type="text" value={value}
        onChange={e => onChange(e.target.value)}
        placeholder={placeholder}
        style={{ flex: 1, border: 'none', outline: 'none',
          fontSize: 13, color: '#111827', background: 'transparent' }}
      />
      {value && (
        <button onClick={onClear}
          style={{ background: 'none', border: 'none', cursor: 'pointer',
            color: '#C4C4C4', fontSize: 11, padding: 0, lineHeight: 1, flexShrink: 0 }}>
          <i className="fas fa-times" />
        </button>
      )}
    </div>
  );
}

// ─── Main Component ───────────────────────────────────────────────────────────

export default function RbpTroubleshoot() {
  const [activeTab, setActiveTab] = useState<'user' | 'permission'>('user');

  // ── User Lookup state ──────────────────────────────────────────────────────
  const [uQuery,      setUQuery]      = useState('');
  const [uResults,    setUResults]    = useState<UserResult[]>([]);
  const [uSearching,  setUSearching]  = useState(false);
  const [uSelected,   setUSelected]   = useState<UserResult | null>(null);
  const [uShowDrop,   setUShowDrop]   = useState(false);
  const [roles,       setRoles]       = useState<RoleRow[]>([]);
  const [permRows,    setPermRows]    = useState<PermRow[]>([]);
  const [uLoading,    setULoading]    = useState(false);
  const [uError,      setUError]      = useState<string | null>(null);
  const [permFilter,  setPermFilter]  = useState('');
  const [collapsed,   setCollapsed]   = useState<Set<string>>(new Set());
  const [checkCode,   setCheckCode]   = useState('');
  const [checkResult, setCheckResult] = useState<boolean | null>(null);

  // ── Permission Lookup state ────────────────────────────────────────────────
  const [pQuery,       setPQuery]       = useState('');
  const [pResults,     setPResults]     = useState<ReverseRow[]>([]);
  const [pLoading,     setPLoading]     = useState(false);
  const [pError,       setPError]       = useState<string | null>(null);
  const [pSearched,    setPSearched]    = useState(false);
  const [allPerms,     setAllPerms]     = useState<PermissionOption[]>([]);
  const [showPermDrop, setShowPermDrop] = useState(false);
  const permDropRef = useRef<HTMLDivElement>(null);

  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const dropRef     = useRef<HTMLDivElement>(null);

  // ── Fetch all permissions when Permission Lookup tab is activated ─────────
  useEffect(() => {
    if (activeTab !== 'permission' || allPerms.length > 0) return;
    supabase
      .from('permissions')
      .select('code, name, module_id, sort_order, modules!inner(code, name, sort_order)')
      .order('sort_order', { ascending: true })
      .then(({ data }) => {
        if (!data) return;
        setAllPerms(data.map((p: any) => ({
          code:        p.code,
          name:        p.name,
          module_code: p.modules.code,
          module_name: p.modules.name,
          module_sort: p.modules.sort_order ?? 99,
        })));
      });
  }, [activeTab, allPerms.length]);

  // Close permission dropdown on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (permDropRef.current && !permDropRef.current.contains(e.target as Node))
        setShowPermDrop(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  // ── User search autocomplete ───────────────────────────────────────────────
  const handleUQueryChange = useCallback((val: string) => {
    setUQuery(val);
    setUSelected(null);
    setPermRows([]); setRoles([]);
    setPermFilter(''); setCheckResult(null); setCollapsed(new Set());
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (val.trim().length < 2) { setUResults([]); setUShowDrop(false); return; }
    debounceRef.current = setTimeout(async () => {
      setUSearching(true);
      const { data } = await supabase.rpc('search_users_for_rbp', { p_query: val.trim() });
      setUSearching(false);
      setUResults((data ?? []) as UserResult[]);
      setUShowDrop(true);
    }, 300);
  }, []);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (dropRef.current && !dropRef.current.contains(e.target as Node))
        setUShowDrop(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  const handleUSelect = useCallback(async (user: UserResult) => {
    setUSelected(user);
    setUQuery(user.name);
    setUShowDrop(false); setUResults([]);
    setULoading(true); setUError(null);
    setPermRows([]); setRoles([]);
    setPermFilter(''); setCheckCode(''); setCheckResult(null); setCollapsed(new Set());

    const [permsRes, rolesRes] = await Promise.all([
      supabase.rpc('get_user_permissions', { p_profile_id: user.profile_id }),
      supabase.rpc('get_user_roles',       { p_profile_id: user.profile_id }),
    ]);
    setULoading(false);
    if (permsRes.error) { setUError(permsRes.error.message); return; }
    setPermRows((permsRes.data ?? []) as PermRow[]);
    setRoles((rolesRes.data ?? []) as RoleRow[]);
  }, []);

  const clearUser = useCallback(() => {
    setUQuery(''); setUSelected(null); setPermRows([]); setRoles([]);
    setUResults([]); setUShowDrop(false); setUError(null);
    setPermFilter(''); setCheckResult(null); setCollapsed(new Set());
  }, []);

  // ── Quick permission check ────────────────────────────────────────────────
  const handleCheck = useCallback(() => {
    if (!checkCode.trim() || permRows.length === 0) return;
    setCheckResult(permRows.some(r => r.permission_code === checkCode.trim().toLowerCase()));
  }, [checkCode, permRows]);

  // ── Collapsible modules ───────────────────────────────────────────────────
  const toggleModule = useCallback((code: string) => {
    setCollapsed(prev => {
      const next = new Set(prev);
      next.has(code) ? next.delete(code) : next.add(code);
      return next;
    });
  }, []);

  // ── Filtered + grouped permissions ────────────────────────────────────────
  const filteredModules = useMemo(() => {
    const q = permFilter.trim().toLowerCase();
    const rows = q
      ? permRows.filter(r =>
          r.module_name.toLowerCase().includes(q) ||
          r.permission_name.toLowerCase().includes(q) ||
          r.permission_code.toLowerCase().includes(q))
      : permRows;
    return groupByModule(rows);
  }, [permRows, permFilter]);

  const userSummary = permRows[0] ?? null;
  const totalPerms  = permRows.length;
  const statusStyle = userSummary
    ? (STATUS_COLORS[userSummary.user_status] ?? STATUS_COLORS.Draft)
    : STATUS_COLORS.Draft;

  // ── Permission autocomplete suggestions (client-side filter) ─────────────
  const permSuggestions = useMemo(() => {
    const q = pQuery.trim().toLowerCase();
    if (!q || q.length < 1) return [];
    return allPerms.filter(p =>
      p.code.toLowerCase().includes(q) ||
      p.name.toLowerCase().includes(q) ||
      p.module_name.toLowerCase().includes(q)
    ).slice(0, 20);
  }, [pQuery, allPerms]);

  // Group suggestions by module for the dropdown
  const permSuggestionsByModule = useMemo(() => {
    const map = new Map<string, { module_name: string; items: PermissionOption[] }>();
    for (const p of permSuggestions) {
      if (!map.has(p.module_code)) map.set(p.module_code, { module_name: p.module_name, items: [] });
      map.get(p.module_code)!.items.push(p);
    }
    return [...map.values()].sort((a, b) =>
      (permSuggestions.find(p => p.module_name === a.module_name)?.module_sort ?? 99) -
      (permSuggestions.find(p => p.module_name === b.module_name)?.module_sort ?? 99)
    );
  }, [permSuggestions]);

  const handlePermSelect = useCallback((perm: PermissionOption) => {
    setPQuery(perm.code);
    setShowPermDrop(false);
    setPSearched(false);
    // Auto-trigger lookup
    setPLoading(true); setPError(null); setPResults([]); setPSearched(true);
    supabase.rpc('get_users_by_permission', { p_permission_code: perm.code })
      .then(({ data, error: err }) => {
        setPLoading(false);
        if (err) { setPError(err.message); return; }
        setPResults((data ?? []) as ReverseRow[]);
      });
  }, []);

  // ── Permission Lookup (reverse) ───────────────────────────────────────────
  const handlePermLookup = useCallback(async () => {
    if (!pQuery.trim()) return;
    setPLoading(true); setPError(null); setPResults([]); setPSearched(true);
    const { data, error: err } = await supabase
      .rpc('get_users_by_permission', { p_permission_code: pQuery.trim().toLowerCase() });
    setPLoading(false);
    if (err) { setPError(err.message); return; }
    setPResults((data ?? []) as ReverseRow[]);
  }, [pQuery]);

  // ─── Render ──────────────────────────────────────────────────────────────

  return (
    <div style={{ maxWidth: 900, margin: '0 auto', padding: '4px 0 40px' }}>

      {/* ── Page header ── */}
      <div style={{ marginBottom: 20 }}>
        <h2 style={{ fontSize: 20, fontWeight: 700, color: '#111827', margin: 0 }}>
          <i className="fas fa-magnifying-glass-chart" style={{ marginRight: 8, color: '#2563EB' }} />
          RBP Troubleshooting
        </h2>
        <p style={{ fontSize: 13, color: '#6B7280', marginTop: 4 }}>
          Diagnose access issues by looking up any user's full permission picture,
          or find everyone who holds a specific permission.
        </p>
      </div>

      {/* ── Tabs ── */}
      <div style={{
        display: 'flex', gap: 0, marginBottom: 24,
        borderBottom: '2px solid #E5E7EB',
      }}>
        {([
          { key: 'user',       label: 'User Lookup',       icon: 'fa-user-magnifying-glass' },
          { key: 'permission', label: 'Permission Lookup',  icon: 'fa-key-skeleton' },
        ] as const).map(tab => (
          <button key={tab.key} onClick={() => setActiveTab(tab.key)}
            style={{
              background: 'none', border: 'none', cursor: 'pointer',
              padding: '8px 18px', fontSize: 13, fontWeight: 600,
              color: activeTab === tab.key ? '#2563EB' : '#6B7280',
              borderBottom: activeTab === tab.key ? '2px solid #2563EB' : '2px solid transparent',
              marginBottom: -2, display: 'flex', alignItems: 'center', gap: 7,
              transition: 'color 0.15s',
            }}>
            <i className={`fas ${tab.icon}`} style={{ fontSize: 12 }} />
            {tab.label}
          </button>
        ))}
      </div>

      {/* ══════════════════════════════════════════════════════════════════════
          TAB 1 — USER LOOKUP
      ══════════════════════════════════════════════════════════════════════ */}
      {activeTab === 'user' && (
        <>
          {/* Search bar */}
          <div ref={dropRef} style={{ position: 'relative', maxWidth: 400, marginBottom: 24 }}>
            <SearchBox
              value={uQuery} onChange={handleUQueryChange} onClear={clearUser}
              searching={uSearching} placeholder="Search by name, email, or employee ID…"
            />
            {uShowDrop && uResults.length > 0 && (
              <div style={{
                position: 'absolute', top: '100%', left: 0, right: 0,
                background: '#fff', border: '1px solid #E5E7EB',
                borderRadius: 8, boxShadow: '0 8px 24px rgba(0,0,0,0.12)',
                zIndex: 100, marginTop: 4, overflow: 'hidden',
              }}>
                {uResults.map(r => (
                  <button key={r.profile_id} onClick={() => handleUSelect(r)}
                    style={{
                      display: 'flex', alignItems: 'center', gap: 12,
                      width: '100%', padding: '9px 14px',
                      background: 'none', border: 'none', cursor: 'pointer',
                      textAlign: 'left', borderBottom: '1px solid #F3F4F6',
                    }}
                    onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                    onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                  >
                    <div style={{
                      width: 32, height: 32, borderRadius: '50%',
                      background: '#EFF6FF', color: '#2563EB',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      fontWeight: 700, fontSize: 12, flexShrink: 0,
                    }}>
                      {initials(r.name)}
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontWeight: 600, fontSize: 13, color: '#111827' }}>{r.name}</div>
                      <div style={{ fontSize: 12, color: '#6B7280' }}>
                        {r.employee_id} · {r.email || '—'}
                      </div>
                    </div>
                    <div style={{ fontSize: 11, color: '#9CA3AF', flexShrink: 0 }}>{r.role_codes}</div>
                  </button>
                ))}
              </div>
            )}
            {uShowDrop && !uSearching && uResults.length === 0 && uQuery.length >= 2 && !uSelected && (
              <div style={{
                position: 'absolute', top: '100%', left: 0, right: 0,
                background: '#fff', border: '1px solid #E5E7EB',
                borderRadius: 8, padding: '12px 16px',
                color: '#9CA3AF', fontSize: 13, marginTop: 4,
                boxShadow: '0 4px 12px rgba(0,0,0,0.08)',
              }}>
                No users found for "{uQuery}"
              </div>
            )}
          </div>

          {uError && (
            <div style={{ background: '#FEF2F2', border: '1px solid #FECACA',
              borderRadius: 8, padding: '12px 16px', color: '#DC2626',
              fontSize: 13, marginBottom: 24 }}>
              <i className="fas fa-circle-xmark" style={{ marginRight: 8 }} />{uError}
            </div>
          )}

          {uLoading && (
            <div style={{ textAlign: 'center', padding: '48px 0', color: '#9CA3AF' }}>
              <i className="fas fa-spinner fa-spin" style={{ fontSize: 24 }} />
              <p style={{ marginTop: 12, fontSize: 14 }}>Loading permissions…</p>
            </div>
          )}

          {/* User summary card */}
          {userSummary && !uLoading && (
            <>
              <div style={{
                background: '#fff', border: '1px solid #E5E7EB',
                borderRadius: 10, padding: '18px 22px', marginBottom: 16,
                boxShadow: '0 1px 4px rgba(0,0,0,0.05)',
              }}>
                {/* Identity row */}
                <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14, marginBottom: 16 }}>
                  <div style={{
                    width: 48, height: 48, borderRadius: '50%',
                    background: '#EFF6FF', color: '#2563EB',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    fontWeight: 700, fontSize: 17, flexShrink: 0,
                  }}>
                    {initials(userSummary.user_name)}
                  </div>
                  <div style={{ flex: 1 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                      <span style={{ fontSize: 16, fontWeight: 700, color: '#111827' }}>
                        {userSummary.user_name}
                      </span>
                      <span style={{
                        fontSize: 11, fontWeight: 600, padding: '2px 8px', borderRadius: 20,
                        background: statusStyle.bg, color: statusStyle.color,
                      }}>
                        {userSummary.user_status}
                      </span>
                    </div>
                    <div style={{ fontSize: 12, color: '#6B7280', marginTop: 2 }}>
                      {userSummary.user_employee_id}
                      {userSummary.user_designation ? ` · ${userSummary.user_designation}` : ''}
                      {userSummary.user_email ? ` · ${userSummary.user_email}` : ''}
                    </div>
                  </div>
                  <div style={{ textAlign: 'right', flexShrink: 0 }}>
                    <div style={{ fontSize: 24, fontWeight: 700, color: '#2563EB' }}>{totalPerms}</div>
                    <div style={{ fontSize: 11, color: '#9CA3AF' }}>permissions</div>
                  </div>
                </div>

                {/* Active roles with granted date (#6) */}
                <div style={{ marginBottom: 16 }}>
                  <div style={{ fontSize: 11, fontWeight: 600, color: '#9CA3AF',
                    textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>
                    Active Roles
                  </div>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
                    {roles.length === 0
                      ? <span style={{ fontSize: 13, color: '#9CA3AF' }}>No roles assigned</span>
                      : roles.map(r => (
                        <span key={r.role_code} style={{
                          display: 'inline-flex', alignItems: 'center', gap: 6,
                          background: '#EFF6FF', color: '#1D4ED8',
                          border: '1px solid #BFDBFE',
                          borderRadius: 6, padding: '5px 10px', fontSize: 12,
                        }}>
                          <i className="fas fa-user-tag" style={{ fontSize: 10 }} />
                          <span style={{ fontWeight: 600 }}>{r.role_code}</span>
                          <span style={{
                            fontSize: 10, color: '#60A5FA',
                            borderLeft: '1px solid #BFDBFE', paddingLeft: 6, marginLeft: 2,
                          }}>
                            {r.granted_at ? `since ${fmtDate(r.granted_at)}` : SOURCE_LABEL[r.assignment_source] ?? r.assignment_source}
                          </span>
                        </span>
                      ))
                    }
                  </div>
                </div>

                {/* Quick permission check */}
                <div style={{ paddingTop: 14, borderTop: '1px solid #F3F4F6' }}>
                  <div style={{ fontSize: 11, fontWeight: 600, color: '#9CA3AF',
                    textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>
                    Quick Permission Check
                  </div>
                  <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                    <input
                      type="text" value={checkCode}
                      onChange={e => { setCheckCode(e.target.value); setCheckResult(null); }}
                      onKeyDown={e => e.key === 'Enter' && handleCheck()}
                      placeholder="e.g. expense.edit_approval"
                      style={{
                        border: '1px solid #D1D5DB', borderRadius: 6,
                        padding: '0 12px', height: 32, fontSize: 13,
                        fontFamily: 'monospace', outline: 'none', width: 230,
                      }}
                    />
                    <button onClick={handleCheck} style={{
                      background: '#2563EB', color: '#fff', border: 'none',
                      borderRadius: 6, padding: '0 14px', height: 32,
                      fontSize: 13, fontWeight: 600, cursor: 'pointer',
                    }}>
                      Check
                    </button>
                    {checkResult === true && (
                      <span style={{
                        display: 'inline-flex', alignItems: 'center', gap: 6,
                        color: '#16A34A', fontWeight: 600, fontSize: 13,
                        background: '#DCFCE7', padding: '5px 12px', borderRadius: 6,
                      }}>
                        <i className="fas fa-circle-check" /> Has this permission
                      </span>
                    )}
                    {checkResult === false && (
                      <span style={{
                        display: 'inline-flex', alignItems: 'center', gap: 6,
                        color: '#DC2626', fontWeight: 600, fontSize: 13,
                        background: '#FEF2F2', padding: '5px 12px', borderRadius: 6,
                      }}>
                        <i className="fas fa-circle-xmark" /> Does not have this permission
                      </span>
                    )}
                  </div>
                </div>
              </div>

              {/* Permission breakdown header with filter (#4) */}
              <div style={{
                display: 'flex', alignItems: 'center', gap: 12,
                marginBottom: 12,
              }}>
                <div style={{ fontSize: 11, fontWeight: 600, color: '#9CA3AF',
                  textTransform: 'uppercase', letterSpacing: '0.05em', flex: 1 }}>
                  Permission Breakdown · {filteredModules.length} module{filteredModules.length !== 1 ? 's' : ''}
                  {permFilter && ` · ${filteredModules.reduce((n, m) => n + m.perms.length, 0)} match`}
                </div>
                {/* Filter input */}
                <div style={{
                  display: 'flex', alignItems: 'center', gap: 6,
                  background: '#fff', border: '1px solid #E5E7EB',
                  borderRadius: 6, padding: '0 9px', height: 30, width: 210,
                }}>
                  <i className="fas fa-filter" style={{ color: '#9CA3AF', fontSize: 11 }} />
                  <input
                    type="text" value={permFilter}
                    onChange={e => setPermFilter(e.target.value)}
                    placeholder="Filter permissions…"
                    style={{ flex: 1, border: 'none', outline: 'none',
                      fontSize: 12, color: '#374151', background: 'transparent' }}
                  />
                  {permFilter && (
                    <button onClick={() => setPermFilter('')}
                      style={{ background: 'none', border: 'none', cursor: 'pointer',
                        color: '#C4C4C4', fontSize: 10, padding: 0 }}>
                      <i className="fas fa-times" />
                    </button>
                  )}
                </div>
              </div>

              {/* Module cards — collapsible (#8) */}
              {filteredModules.length === 0 && (
                <div style={{ textAlign: 'center', padding: '32px 0', color: '#9CA3AF', fontSize: 13 }}>
                  No permissions match "{permFilter}"
                </div>
              )}
              {filteredModules.map(mod => {
                const isCollapsed = collapsed.has(mod.module_code);
                return (
                  <div key={mod.module_code} style={{
                    background: '#fff', border: '1px solid #E5E7EB',
                    borderRadius: 10, marginBottom: 10, overflow: 'hidden',
                    boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
                  }}>
                    {/* Module header — clickable to collapse */}
                    <button
                      onClick={() => toggleModule(mod.module_code)}
                      style={{
                        display: 'flex', alignItems: 'center', gap: 10,
                        width: '100%', padding: '11px 16px',
                        background: '#F8FAFC',
                        borderBottom: isCollapsed ? 'none' : '1px solid #E5E7EB',
                        border: 'none', cursor: 'pointer', textAlign: 'left',
                      }}
                    >
                      <div style={{
                        width: 26, height: 26, borderRadius: 6,
                        background: '#EFF6FF', color: '#2563EB',
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                        flexShrink: 0,
                      }}>
                        <i className={`fas ${MODULE_ICONS[mod.module_code] ?? 'fa-cube'}`}
                           style={{ fontSize: 11 }} />
                      </div>
                      <span style={{ fontWeight: 700, fontSize: 13, color: '#111827', flex: 1 }}>
                        {mod.module_name}
                      </span>
                      <span style={{
                        fontSize: 11, background: '#E0E7FF', color: '#3730A3',
                        borderRadius: 12, padding: '2px 8px', fontWeight: 600,
                      }}>
                        {mod.perms.length}
                      </span>
                      <i className={`fas fa-chevron-${isCollapsed ? 'down' : 'up'}`}
                         style={{ fontSize: 11, color: '#9CA3AF', marginLeft: 6 }} />
                    </button>

                    {/* Permissions table — hidden when collapsed */}
                    {!isCollapsed && (
                      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                        <thead>
                          <tr style={{ background: '#FAFAFA' }}>
                            <th style={{ padding: '7px 16px', textAlign: 'left', fontWeight: 600,
                              color: '#6B7280', fontSize: 11, textTransform: 'uppercase',
                              letterSpacing: '0.04em', width: '36%' }}>Permission</th>
                            <th style={{ padding: '7px 10px', textAlign: 'left', fontWeight: 600,
                              color: '#6B7280', fontSize: 11, textTransform: 'uppercase',
                              letterSpacing: '0.04em', width: '38%' }}>Description</th>
                            <th style={{ padding: '7px 16px 7px 10px', textAlign: 'left', fontWeight: 600,
                              color: '#6B7280', fontSize: 11, textTransform: 'uppercase',
                              letterSpacing: '0.04em' }}>Via Role(s)</th>
                          </tr>
                        </thead>
                        <tbody>
                          {mod.perms.map((p, i) => (
                            <tr key={p.permission_code}
                              style={{ borderTop: i === 0 ? 'none' : '1px solid #F3F4F6' }}>
                              <td style={{ padding: '9px 16px', verticalAlign: 'top' }}>
                                <div style={{ fontWeight: 600, color: '#111827', marginBottom: 2 }}>
                                  {p.permission_name}
                                </div>
                                <code style={{
                                  fontSize: 11, color: '#6B7280',
                                  background: '#F3F4F6', borderRadius: 4,
                                  padding: '1px 6px', fontFamily: 'monospace',
                                }}>
                                  {p.permission_code}
                                </code>
                              </td>
                              <td style={{ padding: '9px 10px', color: '#6B7280',
                                fontSize: 12, verticalAlign: 'top', lineHeight: 1.5 }}>
                                {p.permission_desc || '—'}
                              </td>
                              <td style={{ padding: '9px 16px 9px 10px', verticalAlign: 'top' }}>
                                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                                  {p.via_roles.split(', ').map(role => (
                                    <span key={role} style={{
                                      fontSize: 11, background: '#F0FDF4', color: '#15803D',
                                      border: '1px solid #BBF7D0', borderRadius: 4,
                                      padding: '2px 7px', fontWeight: 600,
                                    }}>
                                      {role}
                                    </span>
                                  ))}
                                </div>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}
                  </div>
                );
              })}
            </>
          )}

          {/* Empty state */}
          {!uSelected && !uLoading && !uError && (
            <div style={{ textAlign: 'center', padding: '60px 0', color: '#9CA3AF' }}>
              <i className="fas fa-user-magnifying-glass"
                 style={{ fontSize: 38, color: '#D1D5DB', marginBottom: 14, display: 'block' }} />
              <p style={{ fontSize: 15, fontWeight: 600, color: '#374151', margin: '0 0 5px' }}>
                Search for a user to inspect their permissions
              </p>
              <p style={{ fontSize: 13, margin: 0 }}>
                Enter a name, email address, or employee ID above.
              </p>
            </div>
          )}

          {/* No permissions */}
          {uSelected && !uLoading && permRows.length === 0 && !uError && (
            <div style={{
              background: '#FEF9C3', border: '1px solid #FDE68A',
              borderRadius: 10, padding: '18px 22px',
              display: 'flex', alignItems: 'flex-start', gap: 12,
            }}>
              <i className="fas fa-triangle-exclamation"
                 style={{ color: '#D97706', fontSize: 15, marginTop: 2 }} />
              <div>
                <div style={{ fontWeight: 600, color: '#92400E', fontSize: 14, marginBottom: 3 }}>
                  No permissions found
                </div>
                <div style={{ fontSize: 13, color: '#78350F' }}>
                  This user has no active roles, or none of their roles carry permissions.
                  Check Role Assignments to verify their setup.
                </div>
              </div>
            </div>
          )}
        </>
      )}

      {/* ══════════════════════════════════════════════════════════════════════
          TAB 2 — PERMISSION LOOKUP (reverse)
      ══════════════════════════════════════════════════════════════════════ */}
      {activeTab === 'permission' && (
        <>
          <div style={{ maxWidth: 540, marginBottom: 24 }}>
            <p style={{ fontSize: 13, color: '#6B7280', marginBottom: 12, marginTop: 0 }}>
              Type a permission name or code — pick from the list, or press Enter to look up.
            </p>
            <div style={{ display: 'flex', gap: 8 }}>
              {/* Autocomplete wrapper */}
              <div ref={permDropRef} style={{ position: 'relative', flex: 1 }}>
                <div style={{
                  display: 'flex', alignItems: 'center', gap: 7,
                  background: '#fff', border: '1px solid #D1D5DB',
                  borderRadius: 6, padding: '0 10px', height: 34,
                  boxShadow: '0 1px 2px rgba(0,0,0,0.04)',
                }}>
                  <i className="fas fa-key" style={{ color: '#9CA3AF', fontSize: 11, flexShrink: 0 }} />
                  <input
                    type="text" value={pQuery}
                    onChange={e => {
                      setPQuery(e.target.value);
                      setPSearched(false);
                      setShowPermDrop(true);
                    }}
                    onFocus={() => pQuery.length > 0 && setShowPermDrop(true)}
                    onKeyDown={e => {
                      if (e.key === 'Enter') { setShowPermDrop(false); handlePermLookup(); }
                      if (e.key === 'Escape') setShowPermDrop(false);
                    }}
                    placeholder="Type permission name or code…"
                    style={{
                      flex: 1, border: 'none', outline: 'none',
                      fontSize: 13, color: '#111827', background: 'transparent',
                      fontFamily: 'monospace',
                    }}
                  />
                  {pQuery && (
                    <button onClick={() => {
                      setPQuery(''); setPResults([]); setPSearched(false); setShowPermDrop(false);
                    }}
                      style={{ background: 'none', border: 'none', cursor: 'pointer',
                        color: '#C4C4C4', fontSize: 11, padding: 0, flexShrink: 0 }}>
                      <i className="fas fa-times" />
                    </button>
                  )}
                </div>

                {/* Suggestions dropdown — grouped by module */}
                {showPermDrop && permSuggestionsByModule.length > 0 && (
                  <div style={{
                    position: 'absolute', top: '100%', left: 0, right: 0,
                    background: '#fff', border: '1px solid #E5E7EB',
                    borderRadius: 8, boxShadow: '0 8px 24px rgba(0,0,0,0.12)',
                    zIndex: 100, marginTop: 4,
                    maxHeight: 320, overflowY: 'auto',
                  }}>
                  {permSuggestionsByModule.map(group => (
                    <div key={group.module_name}>
                      {/* Module group header */}
                      <div style={{
                        padding: '6px 12px 4px',
                        fontSize: 10, fontWeight: 700, color: '#9CA3AF',
                        textTransform: 'uppercase', letterSpacing: '0.06em',
                        background: '#FAFAFA',
                        borderBottom: '1px solid #F3F4F6',
                        position: 'sticky', top: 0,
                      }}>
                        {group.module_name}
                      </div>
                      {group.items.map(p => (
                        <button key={p.code}
                          onMouseDown={e => { e.preventDefault(); handlePermSelect(p); }}
                          style={{
                            display: 'flex', alignItems: 'flex-start', gap: 10,
                            width: '100%', padding: '8px 14px',
                            background: 'none', border: 'none', cursor: 'pointer',
                            textAlign: 'left', borderBottom: '1px solid #F9FAFB',
                          }}
                          onMouseEnter={e => (e.currentTarget.style.background = '#F0F9FF')}
                          onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                        >
                          <i className="fas fa-key"
                             style={{ color: '#93C5FD', fontSize: 10, marginTop: 3, flexShrink: 0 }} />
                          <div>
                            <div style={{ fontSize: 12, fontWeight: 600, color: '#111827' }}>
                              {p.name}
                            </div>
                            <code style={{
                              fontSize: 11, color: '#6B7280', fontFamily: 'monospace',
                            }}>
                              {p.code}
                            </code>
                          </div>
                        </button>
                      ))}
                    </div>
                  ))}
                  </div>
                )}

                {/* No matches hint */}
                {showPermDrop && pQuery.length > 1 && permSuggestions.length === 0 && allPerms.length > 0 && (
                  <div style={{
                    position: 'absolute', top: '100%', left: 0, right: 0,
                    background: '#fff', border: '1px solid #E5E7EB',
                    borderRadius: 8, padding: '10px 14px',
                    color: '#9CA3AF', fontSize: 12, marginTop: 4,
                    boxShadow: '0 4px 12px rgba(0,0,0,0.08)',
                  }}>
                    No permissions match "{pQuery}" — press Enter to look up anyway.
                  </div>
                )}
              </div>

              <button onClick={() => { setShowPermDrop(false); handlePermLookup(); }}
                disabled={!pQuery.trim() || pLoading}
                style={{
                  background: pQuery.trim() ? '#2563EB' : '#E5E7EB',
                  color: pQuery.trim() ? '#fff' : '#9CA3AF',
                  border: 'none', borderRadius: 6, padding: '0 16px',
                  height: 34, fontSize: 13, fontWeight: 600,
                  cursor: pQuery.trim() ? 'pointer' : 'default',
                  display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0,
                }}>
                {pLoading
                  ? <><i className="fas fa-spinner fa-spin" /> Looking up…</>
                  : <><i className="fas fa-search" /> Look up</>}
              </button>
            </div>
          </div>

          {pError && (
            <div style={{ background: '#FEF2F2', border: '1px solid #FECACA',
              borderRadius: 8, padding: '12px 16px', color: '#DC2626',
              fontSize: 13, marginBottom: 20 }}>
              <i className="fas fa-circle-xmark" style={{ marginRight: 8 }} />{pError}
            </div>
          )}

          {/* Results */}
          {pSearched && !pLoading && (
            pResults.length === 0 ? (
              <div style={{
                background: '#F9FAFB', border: '1px solid #E5E7EB',
                borderRadius: 10, padding: '28px 24px', textAlign: 'center',
              }}>
                <i className="fas fa-circle-xmark"
                   style={{ fontSize: 28, color: '#D1D5DB', display: 'block', marginBottom: 10 }} />
                <p style={{ fontSize: 14, fontWeight: 600, color: '#374151', margin: '0 0 4px' }}>
                  No users hold this permission
                </p>
                <p style={{ fontSize: 13, color: '#9CA3AF', margin: 0 }}>
                  Check the permission code or assign it to a role via Role Management.
                </p>
              </div>
            ) : (
              <div style={{
                background: '#fff', border: '1px solid #E5E7EB',
                borderRadius: 10, overflow: 'hidden',
                boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
              }}>
                {/* Result header */}
                <div style={{
                  padding: '10px 16px', background: '#F8FAFC',
                  borderBottom: '1px solid #E5E7EB',
                  display: 'flex', alignItems: 'center', gap: 10,
                }}>
                  <code style={{
                    fontSize: 13, color: '#1D4ED8', background: '#EFF6FF',
                    border: '1px solid #BFDBFE', borderRadius: 5,
                    padding: '2px 8px', fontFamily: 'monospace', fontWeight: 700,
                  }}>
                    {pQuery.trim()}
                  </code>
                  <span style={{
                    fontSize: 11, background: '#DCFCE7', color: '#15803D',
                    border: '1px solid #BBF7D0', borderRadius: 12,
                    padding: '2px 8px', fontWeight: 600,
                  }}>
                    {pResults.length} user{pResults.length !== 1 ? 's' : ''}
                  </span>
                </div>

                {/* Result rows */}
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                  <thead>
                    <tr style={{ background: '#FAFAFA' }}>
                      <th style={{ padding: '7px 16px', textAlign: 'left', fontWeight: 600,
                        color: '#6B7280', fontSize: 11, textTransform: 'uppercase',
                        letterSpacing: '0.04em', width: '40%' }}>User</th>
                      <th style={{ padding: '7px 10px', textAlign: 'left', fontWeight: 600,
                        color: '#6B7280', fontSize: 11, textTransform: 'uppercase',
                        letterSpacing: '0.04em', width: '30%' }}>Via Role</th>
                      <th style={{ padding: '7px 16px 7px 10px', textAlign: 'left', fontWeight: 600,
                        color: '#6B7280', fontSize: 11, textTransform: 'uppercase',
                        letterSpacing: '0.04em' }}>Role Granted</th>
                    </tr>
                  </thead>
                  <tbody>
                    {pResults.map((r, i) => (
                      <tr key={`${r.profile_id}-${r.via_role_code}`}
                        style={{ borderTop: i === 0 ? 'none' : '1px solid #F3F4F6' }}>
                        <td style={{ padding: '10px 16px', verticalAlign: 'middle' }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                            <div style={{
                              width: 30, height: 30, borderRadius: '50%',
                              background: '#EFF6FF', color: '#2563EB',
                              display: 'flex', alignItems: 'center', justifyContent: 'center',
                              fontWeight: 700, fontSize: 11, flexShrink: 0,
                            }}>
                              {initials(r.name)}
                            </div>
                            <div>
                              <div style={{ fontWeight: 600, color: '#111827' }}>{r.name}</div>
                              <div style={{ fontSize: 11, color: '#9CA3AF' }}>
                                {r.employee_id}{r.designation ? ` · ${r.designation}` : ''}
                              </div>
                            </div>
                          </div>
                        </td>
                        <td style={{ padding: '10px 10px', verticalAlign: 'middle' }}>
                          <span style={{
                            fontSize: 12, background: '#F0FDF4', color: '#15803D',
                            border: '1px solid #BBF7D0', borderRadius: 4,
                            padding: '3px 8px', fontWeight: 600,
                          }}>
                            {r.via_role_code}
                          </span>
                        </td>
                        <td style={{ padding: '10px 16px 10px 10px', verticalAlign: 'middle',
                          fontSize: 12, color: '#6B7280' }}>
                          {fmtDate(r.granted_at)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )
          )}

          {/* Empty state */}
          {!pSearched && !pLoading && (
            <div style={{ textAlign: 'center', padding: '60px 0', color: '#9CA3AF' }}>
              <i className="fas fa-key-skeleton"
                 style={{ fontSize: 38, color: '#D1D5DB', marginBottom: 14, display: 'block' }} />
              <p style={{ fontSize: 15, fontWeight: 600, color: '#374151', margin: '0 0 5px' }}>
                Who has a specific permission?
              </p>
              <p style={{ fontSize: 13, margin: 0 }}>
                Enter a permission code above to see every user and role that holds it.
              </p>
            </div>
          )}
        </>
      )}
    </div>
  );
}
