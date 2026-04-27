/**
 * PermissionCatalog
 *
 * Read-only admin screen that shows the full permission catalog:
 * every permission in the system, grouped by module, with a badge for
 * each role that currently holds that permission.
 *
 * Purpose:
 *  - Gives admins full visibility into what permissions exist.
 *  - Answers "which roles can do X?" at a glance.
 *  - Serves as reference documentation for the permission model.
 *
 * To edit role→permission assignments, use Role Management (/admin/permissions/roles).
 */

import { useState, useEffect, useMemo } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';
import { PermTooltip } from './permissionTooltips';

// ─── Types ────────────────────────────────────────────────────────────────────

interface Module {
  id:         string;
  code:       string;
  name:       string;
  sort_order: number;
}

interface Permission {
  id:          string;
  module_id:   string | null;
  code:        string;
  name:        string;
  description: string | null;
  sort_order:  number;
}

interface Role {
  id:   string;
  code: string;
  name: string;
}

// ─── Role badge colours — consistent visual identity per role ─────────────────
const ROLE_COLOURS: Record<string, { bg: string; text: string }> = {
  admin:    { bg: '#FEF3C7', text: '#92400E' },
  manager:  { bg: '#DBEAFE', text: '#1E40AF' },
  finance:  { bg: '#D1FAE5', text: '#065F46' },
  employee: { bg: '#F3F4F6', text: '#374151' },
};

function RoleBadge({ code, name }: { code: string; name: string }) {
  const colours = ROLE_COLOURS[code] ?? { bg: '#EDE9FE', text: '#5B21B6' };
  return (
    <span style={{
      display: 'inline-block',
      padding: '2px 10px',
      borderRadius: 12,
      fontSize: 12,
      fontWeight: 600,
      background: colours.bg,
      color: colours.text,
      marginRight: 4,
      marginBottom: 2,
    }}>
      {name}
    </span>
  );
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function PermissionCatalog() {
  const [modules,     setModules]     = useState<Module[]>([]);
  const [permissions, setPermissions] = useState<Permission[]>([]);
  const [roles,       setRoles]       = useState<Role[]>([]);
  // Set of "role_id|permission_id" strings for fast lookup
  const [grantedSet,  setGrantedSet]  = useState<Set<string>>(new Set());
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState<string | null>(null);
  const [search,      setSearch]      = useState('');

  // ── Load all data in parallel ─────────────────────────────────────────────
  async function load() {
    setLoading(true);
    setError(null);

    try {
      const [modsRes, permsRes, rolesRes, rpRes] = await Promise.all([
        supabase.from('modules').select('id, code, name, sort_order').eq('active', true).order('sort_order'),
        supabase.from('permissions').select('id, module_id, code, name, description, sort_order').order('sort_order').order('code'),
        supabase.from('roles').select('id, code, name').order('name'),
        supabase.from('role_permissions').select('role_id, permission_id'),
      ]);

      // Surface the first error encountered
      const firstError = modsRes.error ?? permsRes.error ?? rolesRes.error ?? rpRes.error;
      if (firstError) throw firstError;

      setModules(    (modsRes.data  ?? []) as Module[]);
      setPermissions((permsRes.data ?? []) as Permission[]);
      setRoles(      (rolesRes.data ?? []) as Role[]);

      // Build a Set<"role_id|permission_id"> for O(1) lookup in the grid
      const granted = new Set<string>(
        (rpRes.data ?? []).map(rp => `${rp.role_id}|${rp.permission_id}`),
      );
      setGrantedSet(granted);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(); }, []);

  // ── Filter permissions by search query ────────────────────────────────────
  const filteredPermissions = useMemo(() => {
    if (!search.trim()) return permissions;
    const q = search.toLowerCase();
    return permissions.filter(p =>
      p.code.toLowerCase().includes(q) ||
      p.name.toLowerCase().includes(q) ||
      (p.description ?? '').toLowerCase().includes(q),
    );
  }, [permissions, search]);

  // Group filtered permissions by module_id.
  // Insertion order preserves the sort_order from the DB query.
  const permsByModule = useMemo(() => {
    const map = new Map<string | null, Permission[]>();
    for (const p of filteredPermissions) {
      const key = p.module_id ?? '__unassigned__';
      if (!map.has(key)) map.set(key, []);
      map.get(key)!.push(p);
    }
    return map;
  }, [filteredPermissions]);

  // ── Render ────────────────────────────────────────────────────────────────

  if (loading) {
    return (
      <div className="ar-panel" style={{ textAlign: 'center', padding: 40, color: '#6B7280' }}>
        <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 8 }} />
        Loading permission catalog…
      </div>
    );
  }

  if (error) {
    return <ErrorBanner message={error} onRetry={load} />;
  }

  return (
    <div className="ar-panel">
      {/* ── Header ──────────────────────────────────────────────────────── */}
      <h2 className="page-title">Permission Catalog</h2>
      <p className="page-subtitle">
        All permissions in the system, grouped by module. Badges show which roles
        currently hold each permission. To edit assignments, use{' '}
        <a href="/admin/permissions/roles" style={{ color: '#2563EB' }}>Role Management</a>.
      </p>

      {/* ── Search ──────────────────────────────────────────────────────── */}
      <div style={{ marginBottom: 24 }}>
        <input
          type="text"
          placeholder="Search permissions by code or name…"
          value={search}
          onChange={e => setSearch(e.target.value)}
          style={{
            width: '100%', maxWidth: 400,
            padding: '8px 12px', borderRadius: 6,
            border: '1px solid #D1D5DB', fontSize: 14,
            outline: 'none',
          }}
        />
      </div>

      {/* ── Permission groups ────────────────────────────────────────────── */}
      {modules.map(mod => {
        const perms = permsByModule.get(mod.id) ?? [];
        if (perms.length === 0) return null; // hide module if search filters it out

        return (
          <div key={mod.id} style={{ marginBottom: 32 }}>
            {/* Module heading */}
            <div style={{
              display: 'flex', alignItems: 'center', gap: 10,
              marginBottom: 12, paddingBottom: 8,
              borderBottom: '2px solid #E5E7EB',
            }}>
              <span style={{
                background: '#EFF6FF', color: '#1D4ED8',
                padding: '2px 10px', borderRadius: 12,
                fontSize: 12, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.05em',
              }}>
                {mod.name}
              </span>
              <span style={{ color: '#9CA3AF', fontSize: 12 }}>
                {perms.length} permission{perms.length !== 1 ? 's' : ''}
              </span>
            </div>

            {/* Permissions table for this module */}
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14 }}>
              <thead>
                <tr style={{ background: '#F9FAFB' }}>
                  <th style={{ textAlign: 'left', padding: '8px 12px', color: '#6B7280', fontWeight: 600, fontSize: 12, width: '25%' }}>CODE</th>
                  <th style={{ textAlign: 'left', padding: '8px 12px', color: '#6B7280', fontWeight: 600, fontSize: 12, width: '25%' }}>NAME</th>
                  <th style={{ textAlign: 'left', padding: '8px 12px', color: '#6B7280', fontWeight: 600, fontSize: 12, width: '25%' }}>DESCRIPTION</th>
                  <th style={{ textAlign: 'left', padding: '8px 12px', color: '#6B7280', fontWeight: 600, fontSize: 12, width: '25%' }}>GRANTED TO</th>
                </tr>
              </thead>
              <tbody>
                {perms.map((perm, idx) => {
                  // Find all roles that have this permission
                  const grantedRoles = roles.filter(r =>
                    grantedSet.has(`${r.id}|${perm.id}`),
                  );

                  return (
                    <tr
                      key={perm.id}
                      style={{
                        background: idx % 2 === 0 ? '#FFFFFF' : '#F9FAFB',
                        borderBottom: '1px solid #F3F4F6',
                      }}
                    >
                      {/* Permission code — monospaced for readability */}
                      <td style={{ padding: '10px 12px' }}>
                        <code style={{
                          background: '#F3F4F6', color: '#374151',
                          padding: '2px 6px', borderRadius: 4, fontSize: 12,
                        }}>
                          {perm.code}
                        </code>
                      </td>
                      <td style={{ padding: '10px 12px', fontWeight: 500 }}>
                        <span style={{ display: 'inline-flex', alignItems: 'center' }}>
                          {perm.name}
                          <PermTooltip code={perm.code} />
                        </span>
                      </td>
                      <td style={{ padding: '10px 12px', color: '#6B7280', fontSize: 13 }}>
                        {perm.description || '—'}
                      </td>
                      <td style={{ padding: '10px 12px' }}>
                        {grantedRoles.length === 0 ? (
                          <span style={{ color: '#D1D5DB', fontSize: 12 }}>No roles assigned</span>
                        ) : (
                          grantedRoles.map(r => (
                            <RoleBadge key={r.id} code={r.code} name={r.name} />
                          ))
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        );
      })}

      {/* Permissions not assigned to any module */}
      {(() => {
        const unassigned = permsByModule.get('__unassigned__') ?? [];
        if (!unassigned.length) return null;
        return (
          <div style={{ marginBottom: 32 }}>
            <div style={{ marginBottom: 12, color: '#9CA3AF', fontSize: 13 }}>
              Unassigned ({unassigned.length})
            </div>
            {unassigned.map(perm => (
              <div key={perm.id} style={{ padding: '8px 0', borderBottom: '1px solid #F3F4F6' }}>
                <code style={{ fontSize: 12, background: '#F3F4F6', padding: '2px 6px', borderRadius: 4 }}>
                  {perm.code}
                </code>
                <span style={{ marginLeft: 12, color: '#6B7280' }}>{perm.name}</span>
              </div>
            ))}
          </div>
        );
      })()}

      {/* Empty state when search matches nothing */}
      {filteredPermissions.length === 0 && search && (
        <div style={{ textAlign: 'center', padding: 48, color: '#9CA3AF' }}>
          <i className="fa-solid fa-magnifying-glass" style={{ fontSize: 24, marginBottom: 12, display: 'block' }} />
          No permissions match <strong>"{search}"</strong>
        </div>
      )}
    </div>
  );
}
