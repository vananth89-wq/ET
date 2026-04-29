/**
 * RoleManagement
 *
 * Interactive admin screen for managing which permissions are assigned to
 * each role. Displays a grid: roles as columns, permissions as rows grouped
 * by module. Each cell is a checkbox — toggling it grants or revokes the
 * permission for that role.
 *
 * Safety guardrails:
 *  - System roles (is_system = true) cannot be deleted from this screen.
 *  - Every change is written to audit_log for traceability.
 *  - Optimistic UI: the checkbox toggles immediately while the DB write
 *    happens in the background. If the write fails, it reverts and shows
 *    a toast error.
 *
 * This screen requires the security.manage_roles permission (admin only).
 */

import React, { useState, useEffect, useMemo, useCallback } from 'react';
import { supabase }    from '../../../lib/supabase';
import { useAuth }     from '../../../contexts/AuthContext';
import ErrorBanner     from '../../shared/ErrorBanner';
import { PermTooltip } from './permissionTooltips';

// ─── Employee permission sub-groups ──────────────────────────────────────────
// Client-side grouping within the Employee module: separators are rendered
// between each portlet group so the grid is visually scannable.
// Order matters — groups are rendered top-to-bottom in this order.

// ─── Reference module sub-groups ─────────────────────────────────────────────
// Three visually distinct sections inside the Reference module: one for
// picklist management, one for projects, one for exchange rates.

const REFERENCE_SUBGROUPS: { label: string; codes: string[] }[] = [
  {
    label: 'Reference Data',
    codes: [
      'reference.view',
      'reference.create',
      'reference.edit',
      'reference.delete',
    ],
  },
  {
    label: 'Projects',
    codes: [
      'project.view',
      'project.create',
      'project.edit',
      'project.delete',
    ],
  },
  {
    label: 'Exchange Rates',
    codes: [
      'exchange_rate.view',
      'exchange_rate.create',
      'exchange_rate.edit',
      'exchange_rate.delete',
    ],
  },
];

// ─── Department permission sub-groups ────────────────────────────────────────

const DEPARTMENT_SUBGROUPS: { label: string; codes: string[] }[] = [
  {
    label: 'Admin Actions',
    codes: [
      'department.create',
      'department.edit',
      'department.delete',
      'department.manage_heads',
    ],
  },
  {
    label: 'Visibility',
    codes: [
      'department.view',
      'department.view_members',
      'department.view_orgchart',
    ],
  },
];

// ─── Employee permission sub-groups ──────────────────────────────────────────

const EMPLOYEE_SUBGROUPS: { label: string; codes: string[] }[] = [
  {
    label: 'Admin Actions',
    codes: [
      'employee.create',
      'employee.edit',
      'employee.delete',
      'employee.view_directory',
      'employee.view_orgchart_admin',
    ],
  },
  {
    label: 'Personal',
    codes: ['employee.view_own_personal', 'employee.edit_own_personal'],
  },
  {
    label: 'Contact',
    codes: ['employee.view_own_contact', 'employee.edit_own_contact'],
  },
  {
    label: 'Employment',
    codes: ['employee.view_own_employment', 'employee.edit_own_employment'],
  },
  {
    label: 'Address',
    codes: ['employee.view_own_address', 'employee.edit_own_address'],
  },
  {
    label: 'Passport',
    codes: ['employee.view_own_passport', 'employee.edit_own_passport'],
  },
  {
    label: 'Identity Documents',
    codes: ['employee.view_own_identity', 'employee.edit_own_identity'],
  },
  {
    label: 'Emergency Contacts',
    codes: ['employee.view_own_emergency', 'employee.edit_own_emergency'],
  },
  {
    label: 'Org Chart',
    codes: ['employee.view_orgchart'],
  },
];

// ─── Module border styling ───────────────────────────────────────────────────
// Applied at <td> level because border-collapse:collapse makes <tr> borders
// unreliable across browsers. A 2px border forms the enclosing box; the
// sub-group and permission row left/right borders stay inside it.
const MODULE_BORDER = '2px solid #BFDBFE';   // blue-200

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

type RoleType = 'protected' | 'system' | 'custom';

const ROLE_TYPE_ORDER: Record<RoleType, number> = {
  system:    0,   // ESS → Manager → Dept Head
  custom:    1,   // Finance → HR → (future custom roles)
  protected: 2,   // Administrator — always last
};

interface Role {
  id:         string;
  code:       string;
  name:       string;
  is_system:  boolean;
  role_type:  RoleType;
  sort_order: number;
}

// ─── Toast ────────────────────────────────────────────────────────────────────

interface Toast { id: string; message: string; type: 'success' | 'error'; }

function useToasts() {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const add = useCallback((message: string, type: Toast['type'] = 'success') => {
    const id = `t_${Date.now()}`;
    setToasts(prev => [...prev, { id, message, type }]);
    setTimeout(() => setToasts(prev => prev.filter(t => t.id !== id)), 3000);
  }, []);

  const dismiss = useCallback((id: string) => {
    setToasts(prev => prev.filter(t => t.id !== id));
  }, []);

  return { toasts, add, dismiss };
}

function ToastContainer({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: string) => void }) {
  if (!toasts.length) return null;
  return (
    <div style={{ position: 'fixed', bottom: 24, right: 24, zIndex: 9999, display: 'flex', flexDirection: 'column', gap: 8 }}>
      {toasts.map(t => (
        <div key={t.id} style={{
          display: 'flex', alignItems: 'center', gap: 10,
          padding: '10px 16px', borderRadius: 8, fontSize: 14,
          background: t.type === 'success' ? '#D1FAE5' : '#FEE2E2',
          color:      t.type === 'success' ? '#065F46' : '#991B1B',
          boxShadow: '0 2px 8px rgba(0,0,0,0.12)',
          minWidth: 280,
        }}>
          <i className={`fa-solid ${t.type === 'success' ? 'fa-circle-check' : 'fa-circle-xmark'}`} />
          <span style={{ flex: 1 }}>{t.message}</span>
          <button onClick={() => onDismiss(t.id)} style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}>
            <i className="fa-solid fa-xmark" style={{ fontSize: 12, opacity: 0.6 }} />
          </button>
        </div>
      ))}
    </div>
  );
}

// ─── SubGroupHeader ───────────────────────────────────────────────────────────
// Renders a visually distinct section separator row inside a module block.

function SubGroupHeader({
  label,
  colSpan,
  legacy = false,
}: {
  label:    string;
  colSpan:  number;
  legacy?:  boolean;
}) {
  return (
    <tr style={{ background: legacy ? '#FAFAFA' : '#EEF2FF' }}>
      <td
        colSpan={colSpan}
        style={{
          padding:      '6px 14px 6px 0',
          position:     'sticky',
          left:          0,
          background:    legacy ? '#FAFAFA' : '#EEF2FF',
          borderTop:    '1px solid #E0E7FF',
          borderBottom: '1px solid #E0E7FF',
          borderLeft:   MODULE_BORDER,
          borderRight:  MODULE_BORDER,
        }}
      >
        <div style={{
          display:      'flex',
          alignItems:   'center',
          gap:           8,
          paddingLeft:   18,
          borderLeft:   `3px solid ${legacy ? '#D1D5DB' : '#6366F1'}`,
        }}>
          <span style={{
            fontSize:       11,
            fontWeight:     700,
            letterSpacing: '0.07em',
            textTransform: 'uppercase',
            color:          legacy ? '#9CA3AF' : '#4338CA',
          }}>
            {label}
          </span>
        </div>
      </td>
    </tr>
  );
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function RoleManagement() {
  const { profile } = useAuth();
  const { toasts, add: addToast, dismiss: dismissToast } = useToasts();

  const [modules,     setModules]     = useState<Module[]>([]);
  const [permissions, setPermissions] = useState<Permission[]>([]);
  const [roles,       setRoles]       = useState<Role[]>([]);
  // Mutable set of "role_id|permission_id" strings — drives the checkbox state
  const [grantedSet,  setGrantedSet]  = useState<Set<string>>(new Set());
  // Track which cells are currently saving (shows a spinner instead of checkbox)
  const [saving,      setSaving]      = useState<Set<string>>(new Set());
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState<string | null>(null);
  const [search,      setSearch]      = useState('');

  // ── JS sticky header ──────────────────────────────────────────────────────
  // CSS position:sticky fails because the layout has no fixed-height scroll
  // container. Instead we translateY the thead to match the wrapper's scrollTop.
  //
  // We use STATE-based callback refs (not useRef + []) so the effect re-fires
  // when the DOM nodes actually appear — the component shows a loading spinner
  // first, so the nodes don't exist on the initial mount.
  const [wrapperEl, setWrapperEl] = useState<HTMLDivElement | null>(null);
  const [theadEl,   setTheadEl]   = useState<HTMLTableSectionElement | null>(null);

  useEffect(() => {
    if (!wrapperEl || !theadEl) return;

    // Sticky header — translate thead to follow vertical scroll
    const onScroll = () => {
      theadEl.style.transform = `translateY(${wrapperEl.scrollTop}px)`;
    };
    wrapperEl.addEventListener('scroll', onScroll, { passive: true });

    // Fill-to-bottom — measure the div's top edge and set height to reach
    // the bottom of the viewport exactly, so no empty space is left below.
    const fillHeight = () => {
      const top = wrapperEl.getBoundingClientRect().top;
      wrapperEl.style.height = `${window.innerHeight - top - 16}px`;
    };
    fillHeight();
    window.addEventListener('resize', fillHeight);

    return () => {
      wrapperEl.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', fillHeight);
    };
  }, [wrapperEl, theadEl]);

  // ── Inline description editing ────────────────────────────────────────────
  const [editingDescId,    setEditingDescId]    = useState<string | null>(null);
  const [editingDescValue, setEditingDescValue] = useState('');
  const [savingDesc,       setSavingDesc]       = useState(false);

  const startEditDesc = useCallback((perm: Permission) => {
    setEditingDescId(perm.id);
    setEditingDescValue(perm.description ?? '');
  }, []);

  const cancelEditDesc = useCallback(() => {
    setEditingDescId(null);
    setEditingDescValue('');
  }, []);

  const saveDescription = useCallback(async (permId: string) => {
    setSavingDesc(true);
    try {
      const trimmed = editingDescValue.trim() || null;
      const { error: err } = await supabase
        .from('permissions')
        .update({ description: trimmed } as any)
        .eq('id', permId);
      if (err) throw err;
      // Patch local state so the grid reflects the change immediately
      setPermissions(prev =>
        prev.map(p => p.id === permId ? { ...p, description: trimmed } : p),
      );
      setEditingDescId(null);
      addToast('Description updated', 'success');
    } catch (err: unknown) {
      addToast(`Failed: ${err instanceof Error ? err.message : String(err)}`, 'error');
    } finally {
      setSavingDesc(false);
    }
  }, [editingDescValue, addToast]);

  // ── Load all data ──────────────────────────────────────────────────────────
  async function load() {
    setLoading(true);
    setError(null);
    try {
      const [modsRes, permsRes, rolesRes, rpRes] = await Promise.all([
        supabase.from('modules').select('id, code, name, sort_order').eq('active', true).order('sort_order'),
        supabase.from('permissions').select('id, module_id, code, name, description, sort_order').order('sort_order').order('code'),
        supabase.from('roles').select('id, code, name, is_system, role_type, sort_order').eq('active', true).order('sort_order'),
        supabase.from('role_permissions').select('role_id, permission_id'),
      ]);

      const firstError = modsRes.error ?? permsRes.error ?? rolesRes.error ?? rpRes.error;
      if (firstError) throw firstError;

      setModules(    (modsRes.data  ?? []) as Module[]);
      setPermissions((permsRes.data ?? []) as Permission[]);
      // Sort columns: Protected → System → Custom, then by sort_order within each group
      const sortedRoles = ((rolesRes.data ?? []) as Role[]).sort((a, b) => {
        const typeDiff = ROLE_TYPE_ORDER[a.role_type ?? 'custom'] - ROLE_TYPE_ORDER[b.role_type ?? 'custom'];
        return typeDiff !== 0 ? typeDiff : a.sort_order - b.sort_order;
      });
      setRoles(sortedRoles);
      setGrantedSet(new Set(
        (rpRes.data ?? []).map(rp => `${rp.role_id}|${rp.permission_id}`),
      ));
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(); }, []);

  // ── Toggle a permission for a role ────────────────────────────────────────
  // Uses optimistic updates: flip the Set immediately, then write to DB.
  // If the write fails, revert the Set and show an error toast.
  async function togglePermission(roleId: string, permissionId: string, roleName: string, permName: string) {
    const key     = `${roleId}|${permissionId}`;
    const granted = grantedSet.has(key);

    // Mark this cell as saving (show spinner)
    setSaving(prev => new Set(prev).add(key));

    // Optimistically update the UI
    setGrantedSet(prev => {
      const next = new Set(prev);
      granted ? next.delete(key) : next.add(key);
      return next;
    });

    try {
      if (granted) {
        // Revoke: delete the row from role_permissions
        const { error } = await supabase
          .from('role_permissions')
          .delete()
          .eq('role_id', roleId)
          .eq('permission_id', permissionId);

        if (error) throw error;

        // Audit log: record the revocation
        await supabase.from('audit_log').insert({
          action:      'permission.revoked',
          entity_type: 'role_permissions',
          entity_id:   roleId,
          user_id:     profile?.id ?? null,
          metadata:    { role: roleName, permission: permName, permission_id: permissionId },
        });

        addToast(`Revoked "${permName}" from ${roleName}`, 'success');
      } else {
        // Grant: insert a new row into role_permissions
        const { error } = await supabase
          .from('role_permissions')
          .insert({ role_id: roleId, permission_id: permissionId });

        if (error) throw error;

        // Audit log: record the grant
        await supabase.from('audit_log').insert({
          action:      'permission.granted',
          entity_type: 'role_permissions',
          entity_id:   roleId,
          user_id:     profile?.id ?? null,
          metadata:    { role: roleName, permission: permName, permission_id: permissionId },
        });

        addToast(`Granted "${permName}" to ${roleName}`, 'success');
      }
    } catch (err: unknown) {
      // Revert the optimistic update on failure
      setGrantedSet(prev => {
        const next = new Set(prev);
        granted ? next.add(key) : next.delete(key);
        return next;
      });
      const msg = err instanceof Error ? err.message : String(err);
      addToast(`Failed to update permission: ${msg}`, 'error');
    } finally {
      setSaving(prev => { const next = new Set(prev); next.delete(key); return next; });
    }
  }

  // ── Filter permissions by search query ────────────────────────────────────
  const filteredPermissions = useMemo(() => {
    if (!search.trim()) return permissions;
    const q = search.toLowerCase();
    return permissions.filter(p =>
      p.code.toLowerCase().includes(q) ||
      p.name.toLowerCase().includes(q),
    );
  }, [permissions, search]);

  // Group filtered permissions by module
  const permsByModule = useMemo(() => {
    const map = new Map<string, Permission[]>();
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
        Loading roles and permissions…
      </div>
    );
  }

  if (error) {
    return <ErrorBanner message={error} onRetry={load} />;
  }

  // Column width for each role
  const roleColWidth = `${Math.max(100, Math.floor(40 / roles.length))}px`;

  return (
    <div className="ar-panel" style={{ position: 'relative' }}>
      {/* ── Header ──────────────────────────────────────────────────────── */}
      <h2 className="page-title">Role Management</h2>
      <p className="page-subtitle">
        Toggle checkboxes to grant or revoke permissions for each role.
        Every change is logged in the audit trail. System roles cannot be deleted.
      </p>

      {/* ── Legend ──────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 16, marginBottom: 20, flexWrap: 'wrap' }}>
        {roles.map(r => (
          <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13 }}>
            <span style={{
              width: 12, height: 12, borderRadius: 2,
              background: '#2563EB', display: 'inline-block',
            }} />
            <strong>{r.name}</strong>
            {r.is_system && (
              <span style={{ color: '#9CA3AF', fontSize: 11 }}>(system)</span>
            )}
          </div>
        ))}
      </div>

      {/* ── Search ──────────────────────────────────────────────────────── */}
      <div style={{ marginBottom: 20 }}>
        <input
          type="text"
          placeholder="Filter permissions…"
          value={search}
          onChange={e => setSearch(e.target.value)}
          style={{
            width: '100%', maxWidth: 360,
            padding: '8px 12px', borderRadius: 6,
            border: '1px solid #D1D5DB', fontSize: 14, outline: 'none',
          }}
        />
      </div>

      {/* ── Permission grid ──────────────────────────────────────────────── */}
      {/* Hard height (not maxHeight) forces this div to be the scroll container
          so position:sticky on <th> works within it.
          Calc breakdown: 100vh − 60px topbar − 28px app-main padding − ~220px
          for title/subtitle/legend/search above the table. */}
      <div ref={setWrapperEl} style={{ overflow: 'auto', minHeight: 300 }}>
        <table style={{ width: '100%', borderCollapse: 'separate', borderSpacing: 0, fontSize: 13 }}>

          {/* Header — JS translateY keeps it pinned as the wrapper scrolls */}
          <thead ref={setTheadEl} style={{ position: 'relative', zIndex: 10 }}>
            <tr style={{ background: '#1E3A5F', color: '#FFFFFF' }}>
              {/* Corner cell — also sticky left for horizontal scroll */}
              <th style={{
                textAlign: 'left', padding: '10px 14px',
                fontWeight: 600, fontSize: 12, letterSpacing: '0.04em',
                position: 'sticky', left: 0,
                background: '#1E3A5F', zIndex: 12,
                minWidth: 260,
                borderBottom: '2px solid #2D5F9E',
              }}>
                PERMISSION
              </th>
              {roles.map(role => (
                <th
                  key={role.id}
                  style={{
                    textAlign: 'center', padding: '10px 8px',
                    fontWeight: 600, fontSize: 12, letterSpacing: '0.04em',
                    background: '#1E3A5F',
                    width: roleColWidth, minWidth: 80,
                    borderBottom: '2px solid #2D5F9E',
                  }}
                  title={role.name}
                >
                  {role.name.toUpperCase()}
                </th>
              ))}
            </tr>
          </thead>

          <tbody>
            {modules.map(mod => {
              const perms = permsByModule.get(mod.id) ?? [];
              if (!perms.length) return null;

              const isEmployee   = mod.code === 'employee';
              const isDepartment = mod.code === 'organization';
              const isReference  = mod.code === 'reference';

              // ── Helper: render a single permission row ─────────────────
              // isLastInModule=true closes the module box with a bottom border.
              const renderPermRow = (
                perm: Permission,
                rowIdx: number,
                isSubGrouped = false,
                isLastInModule = false,
              ) => {
                const bg = isSubGrouped
                  ? (rowIdx % 2 === 0 ? '#FFFFFF' : '#FAFAFA')
                  : (rowIdx % 2 === 0 ? '#FFFFFF' : '#F9FAFB');
                const isEdit = perm.code.startsWith('employee.edit_own_');
                const bottomBorder = isLastInModule ? MODULE_BORDER : '1px solid #F3F4F6';

                return (
                  <tr
                    key={perm.id}
                    style={{ background: bg }}
                  >
                    {/* Permission name + code + editable description */}
                    <td style={{
                      padding: isSubGrouped ? '8px 14px 8px 26px' : '10px 14px',
                      position: 'sticky', left: 0, background: bg, zIndex: 1,
                      borderLeft:   MODULE_BORDER,
                      borderBottom: bottomBorder,
                    }}>
                      <div style={{
                        fontWeight: 500, marginBottom: 2,
                        color: isEdit ? '#1D4ED8' : '#111827',
                        display: 'flex', alignItems: 'center', gap: 6,
                      }}>
                        {isEdit && (
                          <span style={{ fontSize: 10, color: '#2563EB', opacity: 0.7 }}>✏</span>
                        )}
                        {perm.name}
                        <PermTooltip code={perm.code} />
                      </div>
                      <code style={{
                        fontSize: 11, color: '#9CA3AF',
                        background: '#F3F4F6', padding: '1px 5px', borderRadius: 3,
                      }}>
                        {perm.code}
                      </code>

                      {/* Inline description editor */}
                      {editingDescId === perm.id ? (
                        <div style={{ marginTop: 6 }}>
                          <textarea
                            autoFocus
                            value={editingDescValue}
                            onChange={e => setEditingDescValue(e.target.value)}
                            rows={2}
                            placeholder="Enter a plain-language description…"
                            onKeyDown={e => {
                              if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') saveDescription(perm.id);
                              if (e.key === 'Escape') cancelEditDesc();
                            }}
                            style={{
                              width: '100%', fontSize: 12, padding: '5px 7px',
                              borderRadius: 4, border: '1px solid #6366F1',
                              outline: 'none', resize: 'vertical',
                              fontFamily: 'inherit', color: '#374151',
                              boxSizing: 'border-box',
                            }}
                          />
                          <div style={{ display: 'flex', gap: 6, marginTop: 4 }}>
                            <button
                              onClick={() => saveDescription(perm.id)}
                              disabled={savingDesc}
                              style={{
                                fontSize: 11, padding: '3px 10px',
                                background: '#2563EB', color: '#fff',
                                border: 'none', borderRadius: 4, cursor: 'pointer',
                              }}
                            >
                              {savingDesc ? 'Saving…' : 'Save'}
                            </button>
                            <button
                              onClick={cancelEditDesc}
                              disabled={savingDesc}
                              style={{
                                fontSize: 11, padding: '3px 10px',
                                background: '#F3F4F6', color: '#374151',
                                border: '1px solid #D1D5DB', borderRadius: 4, cursor: 'pointer',
                              }}
                            >
                              Cancel
                            </button>
                          </div>
                        </div>
                      ) : (
                        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 4, marginTop: 5 }}>
                          <span style={{
                            fontSize: 12, color: perm.description ? '#6B7280' : '#D1D5DB',
                            fontStyle: perm.description ? 'normal' : 'italic',
                            lineHeight: 1.4, flex: 1,
                          }}>
                            {perm.description || 'No description — click ✎ to add one'}
                          </span>
                          <button
                            onClick={() => startEditDesc(perm)}
                            title="Edit description"
                            style={{
                              background: 'none', border: 'none', cursor: 'pointer',
                              padding: '1px 3px', color: '#9CA3AF', flexShrink: 0,
                              lineHeight: 1,
                            }}
                          >
                            <i className="fa-solid fa-pen" style={{ fontSize: 10 }} />
                          </button>
                        </div>
                      )}
                    </td>

                    {/* Checkbox cell per role */}
                    {roles.map((role, roleIdx) => {
                      const key        = `${role.id}|${perm.id}`;
                      const isGranted  = grantedSet.has(key);
                      const isSaving   = saving.has(key);
                      const isLastRole = roleIdx === roles.length - 1;

                      return (
                        <td key={role.id} style={{
                          textAlign: 'center', padding: '10px 8px',
                          borderRight:  isLastRole ? MODULE_BORDER : undefined,
                          borderBottom: bottomBorder,
                        }}>
                          {isSaving ? (
                            <i className="fa-solid fa-spinner fa-spin" style={{ color: '#9CA3AF', fontSize: 14 }} />
                          ) : (
                            <input
                              type="checkbox"
                              checked={isGranted}
                              onChange={() => togglePermission(role.id, perm.id, role.name, perm.name)}
                              title={`${isGranted ? 'Revoke' : 'Grant'} "${perm.name}" ${isGranted ? 'from' : 'to'} ${role.name}`}
                              style={{
                                width: 16, height: 16,
                                cursor: 'pointer',
                                accentColor: '#2563EB',
                              }}
                            />
                          )}
                        </td>
                      );
                    })}
                  </tr>
                );
              };

              // ── Build the employee module with portlet sub-groups ──────
              if (isEmployee) {
                const permByCode = new Map(perms.map(p => [p.code, p]));
                // Perms not matched by any sub-group (legacy / unrecognised) fall through
                const coveredCodes = new Set(EMPLOYEE_SUBGROUPS.flatMap(g => g.codes));
                const unmatched = perms.filter(p => !coveredCodes.has(p.code));

                // Determine which perm is the last one rendered — it closes the box
                let lastPerm: Permission | null = null;
                if (unmatched.length > 0) {
                  lastPerm = unmatched[unmatched.length - 1];
                } else {
                  for (let gi = EMPLOYEE_SUBGROUPS.length - 1; gi >= 0; gi--) {
                    const gp = EMPLOYEE_SUBGROUPS[gi].codes
                      .map(c => permByCode.get(c))
                      .filter((p): p is Permission => !!p);
                    if (gp.length) { lastPerm = gp[gp.length - 1]; break; }
                  }
                }

                const rows: React.ReactNode[] = [
                  // Module header — top + left + right of the enclosing box
                  <tr key={`mod-${mod.id}`} style={{ background: '#EFF6FF' }}>
                    <td colSpan={roles.length + 1} style={{
                      padding: '6px 14px', fontWeight: 700, fontSize: 12,
                      color: '#1D4ED8', textTransform: 'uppercase', letterSpacing: '0.06em',
                      position: 'sticky', left: 0, background: '#EFF6FF',
                      borderTop:   MODULE_BORDER,
                      borderLeft:  MODULE_BORDER,
                      borderRight: MODULE_BORDER,
                    }}>
                      {mod.name}
                    </td>
                  </tr>,
                ];

                let rowIdx = 0;
                for (const group of EMPLOYEE_SUBGROUPS) {
                  const groupPerms = group.codes
                    .map(c => permByCode.get(c))
                    .filter((p): p is Permission => !!p);

                  if (!groupPerms.length) continue;

                  rows.push(
                    <SubGroupHeader key={`subgrp-${group.label}`} label={group.label} colSpan={roles.length + 1} />,
                  );

                  for (const perm of groupPerms) {
                    rows.push(renderPermRow(perm, rowIdx++, true, perm.id === lastPerm?.id));
                  }
                }

                // Legacy / unrecognised employee permissions at the bottom
                if (unmatched.length > 0) {
                  rows.push(
                    <SubGroupHeader key="subgrp-legacy" label="Legacy" colSpan={roles.length + 1} legacy />,
                  );
                  unmatched.forEach((perm, i) =>
                    rows.push(renderPermRow(perm, rowIdx + i, false, perm.id === lastPerm?.id)),
                  );
                }

                // Spacer between modules
                rows.push(
                  <tr key={`spacer-${mod.id}`}>
                    <td colSpan={roles.length + 1} style={{ height: 14, background: 'transparent', border: 'none' }} />
                  </tr>,
                );

                return rows;
              }

              // ── Organisation module: department sub-groups ────────────
              if (isDepartment) {
                const permByCode = new Map(perms.map(p => [p.code, p]));
                const coveredCodes = new Set(DEPARTMENT_SUBGROUPS.flatMap(g => g.codes));
                const unmatched = perms.filter(p => !coveredCodes.has(p.code));

                // Determine the last rendered perm to close the box
                let lastPerm: Permission | null = null;
                if (unmatched.length > 0) {
                  lastPerm = unmatched[unmatched.length - 1];
                } else {
                  for (let gi = DEPARTMENT_SUBGROUPS.length - 1; gi >= 0; gi--) {
                    const gp = DEPARTMENT_SUBGROUPS[gi].codes
                      .map(c => permByCode.get(c))
                      .filter((p): p is Permission => !!p);
                    if (gp.length) { lastPerm = gp[gp.length - 1]; break; }
                  }
                }

                const rows: React.ReactNode[] = [
                  <tr key={`mod-${mod.id}`} style={{ background: '#EFF6FF' }}>
                    <td colSpan={roles.length + 1} style={{
                      padding: '6px 14px', fontWeight: 700, fontSize: 12,
                      color: '#1D4ED8', textTransform: 'uppercase', letterSpacing: '0.06em',
                      position: 'sticky', left: 0, background: '#EFF6FF',
                      borderTop:   MODULE_BORDER,
                      borderLeft:  MODULE_BORDER,
                      borderRight: MODULE_BORDER,
                    }}>
                      {mod.name}
                    </td>
                  </tr>,
                ];

                let rowIdx = 0;
                for (const group of DEPARTMENT_SUBGROUPS) {
                  const groupPerms = group.codes
                    .map(c => permByCode.get(c))
                    .filter((p): p is Permission => !!p);
                  if (!groupPerms.length) continue;

                  rows.push(
                    <SubGroupHeader key={`subgrp-dept-${group.label}`} label={group.label} colSpan={roles.length + 1} />,
                  );
                  for (const perm of groupPerms) {
                    rows.push(renderPermRow(perm, rowIdx++, true, perm.id === lastPerm?.id));
                  }
                }

                if (unmatched.length > 0) {
                  rows.push(
                    <SubGroupHeader key="subgrp-dept-legacy" label="Legacy" colSpan={roles.length + 1} legacy />,
                  );
                  unmatched.forEach((perm, i) =>
                    rows.push(renderPermRow(perm, rowIdx + i, false, perm.id === lastPerm?.id)),
                  );
                }

                // Spacer between modules
                rows.push(
                  <tr key={`spacer-${mod.id}`}>
                    <td colSpan={roles.length + 1} style={{ height: 14, background: 'transparent', border: 'none' }} />
                  </tr>,
                );

                return rows;
              }

              // ── Reference module: three sub-groups ───────────────────
              if (isReference) {
                const permByCode = new Map(perms.map(p => [p.code, p]));
                const coveredCodes = new Set(REFERENCE_SUBGROUPS.flatMap(g => g.codes));
                const unmatched = perms.filter(p => !coveredCodes.has(p.code));

                // Determine last rendered perm to close the module box
                let lastPerm: Permission | null = null;
                if (unmatched.length > 0) {
                  lastPerm = unmatched[unmatched.length - 1];
                } else {
                  for (let gi = REFERENCE_SUBGROUPS.length - 1; gi >= 0; gi--) {
                    const gp = REFERENCE_SUBGROUPS[gi].codes
                      .map(c => permByCode.get(c))
                      .filter((p): p is Permission => !!p);
                    if (gp.length) { lastPerm = gp[gp.length - 1]; break; }
                  }
                }

                const rows: React.ReactNode[] = [
                  <tr key={`mod-${mod.id}`} style={{ background: '#EFF6FF' }}>
                    <td colSpan={roles.length + 1} style={{
                      padding: '6px 14px', fontWeight: 700, fontSize: 12,
                      color: '#1D4ED8', textTransform: 'uppercase', letterSpacing: '0.06em',
                      position: 'sticky', left: 0, background: '#EFF6FF',
                      borderTop:   MODULE_BORDER,
                      borderLeft:  MODULE_BORDER,
                      borderRight: MODULE_BORDER,
                    }}>
                      {mod.name}
                    </td>
                  </tr>,
                ];

                let rowIdx = 0;
                for (const group of REFERENCE_SUBGROUPS) {
                  const groupPerms = group.codes
                    .map(c => permByCode.get(c))
                    .filter((p): p is Permission => !!p);
                  if (!groupPerms.length) continue;

                  rows.push(
                    <SubGroupHeader key={`subgrp-ref-${group.label}`} label={group.label} colSpan={roles.length + 1} />,
                  );
                  for (const perm of groupPerms) {
                    rows.push(renderPermRow(perm, rowIdx++, true, perm.id === lastPerm?.id));
                  }
                }

                if (unmatched.length > 0) {
                  rows.push(
                    <SubGroupHeader key="subgrp-ref-legacy" label="Legacy" colSpan={roles.length + 1} legacy />,
                  );
                  unmatched.forEach((perm, i) =>
                    rows.push(renderPermRow(perm, rowIdx + i, false, perm.id === lastPerm?.id)),
                  );
                }

                rows.push(
                  <tr key={`spacer-${mod.id}`}>
                    <td colSpan={roles.length + 1} style={{ height: 14, background: 'transparent', border: 'none' }} />
                  </tr>,
                );

                return rows;
              }

              // ── All other modules: flat list ───────────────────────────
              return [
                <tr key={`mod-${mod.id}`} style={{ background: '#EFF6FF' }}>
                  <td
                    colSpan={roles.length + 1}
                    style={{
                      padding: '6px 14px',
                      fontWeight: 700, fontSize: 12,
                      color: '#1D4ED8', textTransform: 'uppercase',
                      letterSpacing: '0.06em',
                      position: 'sticky', left: 0, background: '#EFF6FF',
                      borderTop:   MODULE_BORDER,
                      borderLeft:  MODULE_BORDER,
                      borderRight: MODULE_BORDER,
                    }}
                  >
                    {mod.name}
                  </td>
                </tr>,
                ...perms.map((perm, idx) =>
                  renderPermRow(perm, idx, false, idx === perms.length - 1),
                ),
                // Spacer between modules
                <tr key={`spacer-${mod.id}`}>
                  <td colSpan={roles.length + 1} style={{ height: 14, background: 'transparent', border: 'none' }} />
                </tr>,
              ];
            })}
          </tbody>
        </table>
      </div>

      {/* Empty state */}
      {filteredPermissions.length === 0 && search && (
        <div style={{ textAlign: 'center', padding: 48, color: '#9CA3AF' }}>
          <i className="fa-solid fa-magnifying-glass" style={{ fontSize: 24, marginBottom: 12, display: 'block' }} />
          No permissions match <strong>"{search}"</strong>
        </div>
      )}

      {/* Toast notifications */}
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    </div>
  );
}
