/**
 * RoleAssignments
 *
 * Two-panel admin screen for role-centric user access management.
 *
 * Left panel  — Scrollable role list, grouped by type badge:
 *               SYSTEM / CUSTOM / PROTECTED. Shows user count per role.
 *               "Create Role" button opens a modal for CUSTOM roles.
 *
 * Right panel — Details for the selected role:
 *   • SYSTEM roles    : read-only member list + "Sync Now" button that calls
 *                       sync_system_roles() to refresh membership from employee data.
 *   • CUSTOM roles    : editable member list with employee search + assign/remove.
 *   • PROTECTED roles : editable member list with last-admin guard.
 *
 * Dual-write: every manual grant/revoke writes to BOTH user_roles (new) AND
 * profile_roles (legacy) for roles that have an equivalent enum value, so the
 * existing AuthContext (which still reads profile_roles) stays consistent until
 * Phase 3 migration is complete.
 *
 * Safety guardrails:
 *   - System role membership cannot be edited manually from this screen.
 *   - Removing the last admin is blocked at the DB level (trigger) and in the UI.
 *   - Every change is logged to audit_log for traceability.
 */

import { useState, useEffect, useMemo, useCallback, useRef } from 'react';
import { supabase }  from '../../../lib/supabase';
import { useAuth }   from '../../../contexts/AuthContext';
import ErrorBanner   from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

type RoleType    = 'system' | 'custom' | 'protected';
type RightTab    = 'members' | 'history';

interface Role {
  id:          string;
  code:        string;
  name:        string;
  description: string | null;
  role_type:   RoleType;
  is_system:   boolean;
  memberCount: number;  // populated client-side after fetching counts
}

/** One row from the audit_log for this role. */
interface AuditEntry {
  id:          string;
  action:      string;
  employee:    string;   // from metadata.employee
  changedBy:   string;   // resolved from user_id → profiles → employees
  createdAt:   string;   // ISO timestamp
}

/** A user currently assigned to the selected role. */
interface AssignedUser {
  assignment_id: string;    // user_roles.id
  profile_id:    string;
  employee_id:   string | null;
  name:          string;
  status:        string;
  dept_name:     string | null;
  photo_url:     string | null;
}

/** Employee search result (used when adding someone to a role). */
interface EmployeeResult {
  employee_id:  string;
  profile_id:   string;
  name:         string;
  status:       string;
  dept_name:    string | null;
  photo_url:    string | null;
  already_has:  boolean;   // true if already in the selected role
}

/**
 * Active employee who has no Supabase auth account yet.
 * Shown in a "Not in system" panel for system roles so admins can invite them.
 */
interface UnlinkedEmployee {
  employee_id:    string;
  name:           string;
  business_email: string | null;
  dept_name:      string | null;
  photo_url:      string | null;
}

// ─── Legacy role_type enum mapping ───────────────────────────────────────────
//
// Until AuthContext is migrated off the old profile_roles enum system we
// must mirror every manual grant/revoke into profile_roles.  This map
// says which profile_roles.role enum value corresponds to each roles.code.
// Roles not listed here have no enum equivalent and only get user_roles entries.

// Only remaining roles that still need a mirror write to profile_roles.
// 'employee' and 'manager' have been removed — ESS/MSS are now the canonical
// system roles and their profile_roles sync is handled by sync_system_roles().
const LEGACY_ROLE_MAP: Record<string, 'finance' | 'admin'> = {
  admin:   'admin',
  finance: 'finance',
};

// ─── Badge styling ────────────────────────────────────────────────────────────

const TYPE_BADGE: Record<RoleType, { label: string; bg: string; color: string }> = {
  system:    { label: 'SYSTEM',    bg: '#DBEAFE', color: '#1E40AF' },
  custom:    { label: 'CUSTOM',    bg: '#D1FAE5', color: '#065F46' },
  protected: { label: 'PROTECTED', bg: '#FEF3C7', color: '#92400E' },
};

function TypeBadge({ type }: { type: RoleType }) {
  const s = TYPE_BADGE[type];
  return (
    <span style={{
      display: 'inline-block', padding: '2px 8px', borderRadius: 12,
      fontSize: 10, fontWeight: 700, letterSpacing: '0.05em',
      background: s.bg, color: s.color,
    }}>
      {s.label}
    </span>
  );
}

// ─── Toast ────────────────────────────────────────────────────────────────────

interface Toast { id: string; message: string; type: 'success' | 'error'; }

function useToasts() {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const add = useCallback((message: string, type: Toast['type'] = 'success') => {
    const id = `t_${Date.now()}`;
    setToasts(prev => [...prev, { id, message, type }]);
    setTimeout(() => setToasts(prev => prev.filter(t => t.id !== id)), 3500);
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
          boxShadow: '0 2px 8px rgba(0,0,0,0.12)', minWidth: 300,
        }}>
          <i className={`fa-solid ${t.type === 'success' ? 'fa-circle-check' : 'fa-circle-xmark'}`} />
          <span style={{ flex: 1 }}>{t.message}</span>
          <button onClick={() => onDismiss(t.id)}
            style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}>
            <i className="fa-solid fa-xmark" style={{ fontSize: 12, opacity: 0.6 }} />
          </button>
        </div>
      ))}
    </div>
  );
}

// ─── Confirm dialog ───────────────────────────────────────────────────────────

function ConfirmDialog({
  user, roleName, onConfirm, onCancel,
}: {
  user:     AssignedUser;
  roleName: string;
  onConfirm: () => void;
  onCancel:  () => void;
}) {
  return (
    <div style={{
      position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)',
      display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000,
    }}>
      <div style={{
        background: '#fff', borderRadius: 12, padding: 28,
        maxWidth: 400, width: '90%', boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 16 }}>
          <div style={{
            width: 40, height: 40, borderRadius: '50%',
            background: '#FEE2E2', display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <i className="fa-solid fa-triangle-exclamation" style={{ color: '#DC2626', fontSize: 16 }} />
          </div>
          <h3 style={{ margin: 0, fontSize: 16, fontWeight: 700, color: '#111827' }}>
            Remove role assignment?
          </h3>
        </div>
        <p style={{ margin: '0 0 20px', color: '#4B5563', fontSize: 14, lineHeight: 1.5 }}>
          Remove <strong>{user.name}</strong> from the <strong>{roleName}</strong> role?
          They will lose all permissions granted by this role immediately.
        </p>
        <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
          <button
            onClick={onCancel}
            style={{
              padding: '8px 18px', borderRadius: 6, border: '1px solid #D1D5DB',
              background: '#F9FAFB', cursor: 'pointer', fontSize: 14, color: '#374151',
            }}
          >
            Cancel
          </button>
          <button
            onClick={onConfirm}
            style={{
              padding: '8px 18px', borderRadius: 6, border: 'none',
              background: '#DC2626', cursor: 'pointer', fontSize: 14,
              color: '#fff', fontWeight: 600,
            }}
          >
            Remove
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Create Role modal ────────────────────────────────────────────────────────

interface NewRoleForm {
  name:        string;
  code:        string;
  description: string;
}

function CreateRoleModal({
  onSave, onCancel, saving,
}: {
  onSave:   (form: NewRoleForm) => void;
  onCancel: () => void;
  saving:   boolean;
}) {
  const [form, setForm] = useState<NewRoleForm>({ name: '', code: '', description: '' });
  const [codeManuallyEdited, setCodeManuallyEdited] = useState(false);

  // Auto-derive code from name unless the user has edited it manually
  function handleNameChange(value: string) {
    const derived = value.toLowerCase().replace(/\s+/g, '_').replace(/[^a-z0-9_]/g, '');
    setForm(prev => ({
      ...prev,
      name: value,
      code: codeManuallyEdited ? prev.code : derived,
    }));
  }

  function handleCodeChange(value: string) {
    setCodeManuallyEdited(true);
    setForm(prev => ({ ...prev, code: value.toLowerCase().replace(/[^a-z0-9_]/g, '') }));
  }

  const canSave = form.name.trim().length > 0 && form.code.trim().length > 0;

  return (
    <div style={{
      position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)',
      display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000,
    }}>
      <div style={{
        background: '#fff', borderRadius: 12, padding: 32, maxWidth: 480,
        width: '90%', boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
      }}>
        {/* Header */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 24 }}>
          <h3 style={{ margin: 0, fontSize: 18, fontWeight: 700, color: '#111827' }}>
            <i className="fa-solid fa-circle-plus" style={{ marginRight: 8, color: '#2563EB' }} />
            Create Custom Role
          </h3>
          <button onClick={onCancel} style={{ background: 'none', border: 'none', cursor: 'pointer' }}>
            <i className="fa-solid fa-xmark" style={{ fontSize: 18, color: '#6B7280' }} />
          </button>
        </div>

        {/* Form fields */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>Role Name *</span>
            <input
              type="text"
              value={form.name}
              onChange={e => handleNameChange(e.target.value)}
              placeholder="e.g. Finance Manager"
              style={{
                padding: '9px 12px', borderRadius: 6, border: '1px solid #D1D5DB',
                fontSize: 14, outline: 'none',
              }}
            />
          </label>

          <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>Role Code *</span>
            <input
              type="text"
              value={form.code}
              onChange={e => handleCodeChange(e.target.value)}
              placeholder="e.g. finance_manager"
              style={{
                padding: '9px 12px', borderRadius: 6, border: '1px solid #D1D5DB',
                fontSize: 14, fontFamily: 'monospace', outline: 'none',
              }}
            />
            <span style={{ fontSize: 11, color: '#9CA3AF' }}>
              Lowercase letters, numbers, and underscores only. Cannot be changed later.
            </span>
          </label>

          <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>Description</span>
            <textarea
              value={form.description}
              onChange={e => setForm(prev => ({ ...prev, description: e.target.value }))}
              placeholder="What access does this role provide?"
              rows={3}
              style={{
                padding: '9px 12px', borderRadius: 6, border: '1px solid #D1D5DB',
                fontSize: 14, resize: 'vertical', outline: 'none',
              }}
            />
          </label>
        </div>

        {/* Actions */}
        <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end', marginTop: 24 }}>
          <button
            onClick={onCancel}
            disabled={saving}
            style={{
              padding: '9px 20px', borderRadius: 6, border: '1px solid #D1D5DB',
              background: '#F9FAFB', cursor: 'pointer', fontSize: 14, color: '#374151',
            }}
          >
            Cancel
          </button>
          <button
            onClick={() => canSave && onSave(form)}
            disabled={!canSave || saving}
            style={{
              padding: '9px 20px', borderRadius: 6, border: 'none',
              background: canSave && !saving ? '#2563EB' : '#93C5FD',
              cursor: canSave && !saving ? 'pointer' : 'not-allowed',
              fontSize: 14, color: '#fff', fontWeight: 600,
              display: 'flex', alignItems: 'center', gap: 6,
            }}
          >
            {saving
              ? <><i className="fa-solid fa-spinner fa-spin" /> Creating…</>
              : 'Create Role'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── UserRow ──────────────────────────────────────────────────────────────────

function UserRow({
  user, canRemove, onRemove,
}: {
  user:      AssignedUser;
  canRemove: boolean;
  onRemove:  (user: AssignedUser) => void;
}) {
  const avatar = user.photo_url
    || `https://ui-avatars.com/api/?name=${encodeURIComponent(user.name)}&background=2F77B5&color=fff&size=40`;

  const isActive = user.status === 'Active';

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '10px 16px', borderBottom: '1px solid #F3F4F6',
    }}>
      {/* Avatar */}
      <img
        src={avatar}
        alt={user.name}
        style={{ width: 36, height: 36, borderRadius: '50%', objectFit: 'cover', flexShrink: 0 }}
      />

      {/* Name + dept */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600, fontSize: 14, color: '#111827', marginBottom: 2 }}>
          {user.name}
        </div>
        <div style={{ fontSize: 12, color: '#6B7280', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          {user.dept_name || 'No department'}
        </div>
      </div>

      {/* Status badge */}
      <span style={{
        padding: '2px 8px', borderRadius: 10, fontSize: 11, fontWeight: 600,
        background: isActive ? '#D1FAE5' : '#F3F4F6',
        color:      isActive ? '#065F46' : '#6B7280',
        flexShrink: 0,
      }}>
        {user.status}
      </span>

      {/* Remove button */}
      {canRemove && (
        <button
          onClick={() => onRemove(user)}
          title="Remove from role"
          style={{
            background: 'none', border: 'none', cursor: 'pointer',
            color: '#9CA3AF', padding: '4px 6px', borderRadius: 4,
            flexShrink: 0,
          }}
          onMouseEnter={e => (e.currentTarget.style.color = '#DC2626')}
          onMouseLeave={e => (e.currentTarget.style.color = '#9CA3AF')}
        >
          <i className="fa-solid fa-user-minus" style={{ fontSize: 14 }} />
        </button>
      )}
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function RoleAssignments() {
  const { profile } = useAuth();
  const { toasts, add: addToast, dismiss: dismissToast } = useToasts();

  // ── Top-level state ────────────────────────────────────────────────────────
  const [roles,        setRoles]        = useState<Role[]>([]);
  const [selectedRole, setSelectedRole] = useState<Role | null>(null);
  const [assignedUsers, setAssignedUsers] = useState<AssignedUser[]>([]);

  // Loading states
  const [loading,       setLoading]      = useState(true);
  const [usersLoading,  setUsersLoading] = useState(false);
  const [syncing,       setSyncing]      = useState(false);
  const [savingRole,    setSavingRole]   = useState(false);
  const [removingId,    setRemovingId]   = useState<string | null>(null);
  const [addingId,      setAddingId]     = useState<string | null>(null);

  // UI state
  const [roleSearch,    setRoleSearch]   = useState('');
  const [empSearch,     setEmpSearch]    = useState('');
  const [empResults,    setEmpResults]   = useState<EmployeeResult[]>([]);
  const [empSearching,  setEmpSearching] = useState(false);
  const [showCreate,    setShowCreate]   = useState(false);
  const [confirmUser,   setConfirmUser]  = useState<AssignedUser | null>(null);
  const [error,         setError]        = useState<string | null>(null);

  // Employees without system accounts — shown for system roles with invite buttons
  const [unlinkedEmployees, setUnlinkedEmployees] = useState<UnlinkedEmployee[]>([]);
  const [unlinkedLoading,   setUnlinkedLoading]   = useState(false);
  // Set of employee_ids currently being invited (shows spinner per row)
  const [inviting,          setInviting]          = useState<Set<string>>(new Set());

  // Right-panel tab
  const [rightTab,        setRightTab]       = useState<RightTab>('members');
  const [history,         setHistory]        = useState<AuditEntry[]>([]);
  const [historyLoading,  setHistoryLoading] = useState(false);

  // Debounce timer ref for employee search
  const empSearchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // ── Load roles + member counts ─────────────────────────────────────────────
  const loadRoles = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      // Fetch all roles
      const { data: rolesData, error: rolesErr } = await supabase
        .from('roles')
        .select('id, code, name, description, role_type, is_system')
        .order('name');
      if (rolesErr) throw rolesErr;

      // Fetch member counts via aggregation
      // Supabase doesn't support COUNT in select with groupBy directly,
      // so we fetch all user_roles and tally client-side.
      const { data: urData, error: urErr } = await supabase
        .from('user_roles')
        .select('role_id');
      if (urErr) throw urErr;

      // Build a count map: role_id → number of members
      const countMap = new Map<string, number>();
      for (const row of (urData ?? [])) {
        countMap.set(row.role_id, (countMap.get(row.role_id) ?? 0) + 1);
      }

      // Merge counts into roles
      const enriched: Role[] = (rolesData ?? []).map(r => ({
        ...r,
        role_type:   (r.role_type ?? 'custom') as RoleType,
        memberCount: countMap.get(r.id) ?? 0,
      }));

      setRoles(enriched);

      // Keep selectedRole in sync (update its memberCount)
      if (selectedRole) {
        const updated = enriched.find(r => r.id === selectedRole.id);
        if (updated) setSelectedRole(updated);
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [selectedRole]);

  useEffect(() => { loadRoles(); }, []);   // intentionally omit loadRoles dep to run once on mount

  // ── Load assigned users for the selected role ──────────────────────────────
  const loadAssignedUsers = useCallback(async (roleId: string) => {
    setUsersLoading(true);
    try {
      // user_roles → profiles → employees → departments (nested FK joins)
      const { data, error: err } = await supabase
        .from('user_roles')
        .select(`
          id,
          profile_id,
          profiles!user_roles_profile_id_fkey (
            id,
            employee_id,
            employees:employees!profiles_employee_id_fkey (
              id,
              name,
              status,
              dept_id,
              departments:departments!employees_dept_id_fkey (
                name
              )
            )
          )
        `)
        .eq('role_id', roleId);

      if (err) throw err;

      // Flatten nested structure into AssignedUser[]
      const users: AssignedUser[] = (data ?? []).map(row => {
        const profile = (row.profiles as Record<string, unknown> | null);
        const emp     = (profile?.employees as Record<string, unknown> | null);
        const dept    = (emp?.departments   as Record<string, unknown> | null);
        return {
          assignment_id: row.id,
          profile_id:    row.profile_id,
          employee_id:   profile?.employee_id as string | null ?? null,
          name:          (emp?.name as string) ?? '(No employee linked)',
          status:        (emp?.status as string) ?? 'Unknown',
          dept_name:     (dept?.name as string) ?? null,
          photo_url:     null,
        };
      });

      // Sort: active users first, then by name
      users.sort((a, b) => {
        if (a.status === 'Active' && b.status !== 'Active') return -1;
        if (b.status === 'Active' && a.status !== 'Active') return  1;
        return a.name.localeCompare(b.name);
      });

      setAssignedUsers(users);
    } catch (err: unknown) {
      addToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setUsersLoading(false);
    }
  }, [addToast]);

  // ── Load active employees who have no Supabase account yet ───────────────
  //
  // Shown only for system roles so admins can invite them directly.
  // Query: active non-deleted employees with no matching profiles row.

  const loadUnlinkedEmployees = useCallback(async () => {
    setUnlinkedLoading(true);
    try {
      const { data, error: err } = await supabase
        .from('employees')
        .select(`
          id,
          name,
          business_email,
          departments:departments!employees_dept_id_fkey (name)
        `)
        .eq('status', 'Active')
        .is('deleted_at', null)
        .order('name');
      if (err) throw err;

      // Filter to only those without a profile (no auth account)
      const allEmpIds   = (data ?? []).map(e => e.id);
      const { data: linkedProfiles } = await supabase
        .from('profiles')
        .select('employee_id')
        .in('employee_id', allEmpIds);

      const linkedIds = new Set((linkedProfiles ?? []).map(p => p.employee_id));

      const unlinked: UnlinkedEmployee[] = (data ?? [])
        .filter(e => !linkedIds.has(e.id))
        .map(e => ({
          employee_id:    e.id,
          name:           e.name,
          business_email: e.business_email as string | null,
          dept_name:      (e.departments as Record<string, unknown> | null)?.name as string | null ?? null,
          photo_url:      null,
        }));

      setUnlinkedEmployees(unlinked);
    } catch (err: unknown) {
      console.error('Failed to load unlinked employees:', err);
      setUnlinkedEmployees([]);
    } finally {
      setUnlinkedLoading(false);
    }
  }, []);

  // ── Load audit history for the selected role ──────────────────────────────
  //
  // Fetches audit_log rows where entity_type='user_roles' and entity_id=roleId,
  // then resolves the user_id (profile id of the admin who acted) into a name.

  const loadHistory = useCallback(async (roleId: string) => {
    setHistoryLoading(true);
    try {
      const { data: logData, error: logErr } = await supabase
        .from('audit_log')
        .select('id, action, user_id, metadata, created_at')
        .eq('entity_type', 'user_roles')
        .eq('entity_id', roleId)
        .in('action', ['role.member_added', 'role.member_removed'])
        .order('created_at', { ascending: false })
        .limit(100);

      if (logErr) throw logErr;

      if (!logData?.length) { setHistory([]); setHistoryLoading(false); return; }

      // Collect unique admin profile IDs so we can resolve their names
      const adminIds = [...new Set(logData.map(r => r.user_id).filter(Boolean))] as string[];

      const adminNameMap = new Map<string, string>();
      if (adminIds.length) {
        const { data: profData } = await supabase
          .from('profiles')
          .select('id, employee_id')
          .in('id', adminIds);

        const empIds = (profData ?? []).map(p => p.employee_id).filter(Boolean) as string[];
        if (empIds.length) {
          const { data: empData } = await supabase
            .from('employees')
            .select('id, name')
            .in('id', empIds);

          const empNameMap = new Map<string, string>();
          for (const e of (empData ?? [])) empNameMap.set(e.id, e.name);

          for (const p of (profData ?? [])) {
            if (p.employee_id) {
              adminNameMap.set(p.id, empNameMap.get(p.employee_id) ?? 'Unknown');
            }
          }
        }
      }

      const entries: AuditEntry[] = (logData).map(row => {
        const meta = (row.metadata ?? {}) as Record<string, string>;
        return {
          id:        row.id,
          action:    row.action,
          employee:  meta.employee ?? '(unknown)',
          changedBy: row.user_id ? (adminNameMap.get(row.user_id) ?? 'Unknown admin') : 'System',
          createdAt: row.created_at,
        };
      });

      setHistory(entries);
    } catch (err: unknown) {
      console.error('Failed to load role history:', err);
      setHistory([]);
    } finally {
      setHistoryLoading(false);
    }
  }, []);

  // ── Invite an employee to the system ──────────────────────────────────────
  //
  // Uses Supabase's magic-link OTP flow with shouldCreateUser: true.
  // Supabase creates an auth account and emails the employee a sign-in link.
  // When they click it, the handle_new_auth_user trigger fires, creates their
  // profile, links it to their employee record, and grants ESS automatically.

  async function inviteEmployee(emp: UnlinkedEmployee) {
    if (!emp.business_email) {
      addToast(`${emp.name} has no business email — add one in Employee Details first.`, 'error');
      return;
    }

    setInviting(prev => new Set(prev).add(emp.employee_id));
    try {
      // Step 1: Create the auth user and send the magic-link invite email.
      // The minimal trigger (handle_new_auth_user) creates a bare profile row.
      // Use VITE_APP_URL so the link works for teammates on other machines.
      // Set this to your LAN IP (http://192.168.x.x:5174) or deployed URL.
      const appUrl = import.meta.env.VITE_APP_URL || window.location.origin;

      const { error: inviteErr } = await supabase.auth.signInWithOtp({
        email: emp.business_email,
        options: {
          shouldCreateUser: true,
          emailRedirectTo:  `${appUrl}/profile`,
        },
      });
      if (inviteErr) throw inviteErr;

      // Step 2: Link the new profile to the employee record and grant ESS.
      // Runs outside the auth transaction so a failure here doesn't affect the invite.
      const { data: linkResult } = await supabase.rpc('link_profile_to_employee', {
        p_email: emp.business_email,
      });

      const linked = (linkResult as { ok?: boolean })?.ok ?? false;

      addToast(
        linked
          ? `Invite sent to ${emp.name} — account linked and ESS granted`
          : `Invite sent to ${emp.name} (${emp.business_email})`,
        'success',
      );

      // Audit log
      await supabase.from('audit_log').insert({
        action:      'user.invited',
        entity_type: 'employees',
        entity_id:   emp.employee_id,
        user_id:     profile?.id ?? null,
        metadata:    { name: emp.name, email: emp.business_email, linked },
      });

      // Refresh both panels — the employee should move from "Not in system"
      // to "Members" once the profile is linked and ESS granted.
      await loadAssignedUsers(selectedRole!.id);
      await loadUnlinkedEmployees();
      loadRoles();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      addToast(`Failed to invite ${emp.name}: ${msg}`, 'error');
    } finally {
      setInviting(prev => { const n = new Set(prev); n.delete(emp.employee_id); return n; });
    }
  }

  // Reload users and (for system roles) unlinked employees whenever the selected role changes
  useEffect(() => {
    if (selectedRole) {
      setEmpSearch('');
      setEmpResults([]);
      setRightTab('members');
      setHistory([]);
      loadAssignedUsers(selectedRole.id);
      if (selectedRole.role_type === 'system') {
        loadUnlinkedEmployees();
      } else {
        setUnlinkedEmployees([]);
      }
    } else {
      setAssignedUsers([]);
      setUnlinkedEmployees([]);
      setHistory([]);
    }
  }, [selectedRole?.id]);   // only re-run when the role ID changes

  // ── Employee search (debounced, 300ms) ─────────────────────────────────────
  //
  // Searches employees by name, then cross-references profiles to find the
  // profile_id. Flags employees already in the selected role.

  useEffect(() => {
    if (empSearchTimer.current) clearTimeout(empSearchTimer.current);

    if (!empSearch.trim() || !selectedRole) {
      setEmpResults([]);
      return;
    }

    empSearchTimer.current = setTimeout(async () => {
      setEmpSearching(true);
      try {
        // 1. Find employees matching the search query
        // Note: avoid FK hint on dept_id join — fetch dept separately to prevent
        // ambiguous constraint name causing a silent query failure.
        const { data: empData, error: empErr } = await supabase
          .from('employees')
          .select('id, name, status, dept_id')
          .ilike('name', `%${empSearch.trim()}%`)
          .is('deleted_at', null)
          .limit(12);
        if (empErr) throw empErr;

        if (!empData?.length) { setEmpResults([]); setEmpSearching(false); return; }

        // 2. Find their profiles (to get profile_id for user_roles insertion)
        const empIds = empData.map(e => e.id);
        const { data: profileData, error: profileErr } = await supabase
          .from('profiles')
          .select('id, employee_id')
          .in('employee_id', empIds);
        if (profileErr) throw profileErr;

        // 3. Fetch dept names for the unique dept_ids in results
        const deptIds = [...new Set(empData.map(e => e.dept_id).filter((id): id is string => id != null))];
        const deptMap = new Map<string, string>();
        if (deptIds.length) {
          const { data: deptData } = await supabase
            .from('departments')
            .select('id, name')
            .in('id', deptIds);
          for (const d of (deptData ?? [])) deptMap.set(d.id, d.name);
        }

        const profileMap = new Map<string, string>(); // employee_id → profile_id
        for (const p of (profileData ?? [])) {
          if (p.employee_id) profileMap.set(p.employee_id, p.id);
        }

        // Build the set of profile_ids already assigned to this role
        const assignedProfileIds = new Set(assignedUsers.map(u => u.profile_id));

        // 4. Combine into EmployeeResult[]
        const results: EmployeeResult[] = [];
        for (const emp of empData) {
          const profile_id = profileMap.get(emp.id);
          if (!profile_id) continue;   // no profile = no user account, skip
          results.push({
            employee_id: emp.id,
            profile_id,
            name:        emp.name,
            status:      emp.status,
            photo_url:   null,
            dept_name:   emp.dept_id ? (deptMap.get(emp.dept_id) ?? null) : null,
            already_has: assignedProfileIds.has(profile_id),
          });
        }

        setEmpResults(results);
      } catch (err: unknown) {
        addToast(err instanceof Error ? err.message : String(err), 'error');
      } finally {
        setEmpSearching(false);
      }
    }, 300);

    return () => {
      if (empSearchTimer.current) clearTimeout(empSearchTimer.current);
    };
  }, [empSearch, selectedRole?.id, assignedUsers]);

  // ── Assign user to the selected role ──────────────────────────────────────
  //
  // Writes to user_roles (new system) and, for roles with a legacy mapping,
  // also inserts into profile_roles so AuthContext stays consistent.

  async function assignUser(result: EmployeeResult) {
    if (!selectedRole || result.already_has) return;
    setAddingId(result.employee_id);

    try {
      // Insert into user_roles
      const { error: urErr } = await supabase
        .from('user_roles')
        .insert({
          profile_id: result.profile_id,
          role_id:    selectedRole.id,
          granted_by: profile?.id ?? null,
        });
      if (urErr) throw urErr;

      // Mirror to profile_roles if a legacy enum value exists for this role
      const legacyRole = LEGACY_ROLE_MAP[selectedRole.code];
      if (legacyRole) {
        await supabase
          .from('profile_roles')
          .insert({ profile_id: result.profile_id, role: legacyRole })
          .select()
          .single();
        // Silently ignore conflict if the row already exists
      }

      // Audit log
      await supabase.from('audit_log').insert({
        action:      'role.member_added',
        entity_type: 'user_roles',
        entity_id:   selectedRole.id,
        user_id:     profile?.id ?? null,
        metadata:    { role: selectedRole.name, employee: result.name, profile_id: result.profile_id },
      });

      addToast(`Added ${result.name} to ${selectedRole.name}`, 'success');

      // Clear history cache so the History tab reloads fresh next time
      setHistory([]);

      // Optimistically add to assigned list and clear search
      setAssignedUsers(prev => [{
        assignment_id: '',     // will be refreshed on next load
        profile_id:    result.profile_id,
        employee_id:   result.employee_id,
        name:          result.name,
        status:        result.status,
        dept_name:     result.dept_name,
        photo_url:     result.photo_url,
      }, ...prev]);

      setEmpSearch('');
      setEmpResults([]);

      // Refresh role list to update count
      loadRoles();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      addToast(`Failed to assign role: ${msg}`, 'error');
    } finally {
      setAddingId(null);
    }
  }

  // ── Remove user from selected role ────────────────────────────────────────
  //
  // Protected role (admin): last-admin guard is enforced at the DB level.
  // The frontend checks this first to give a friendly error before the DB rejects.

  async function removeUser(user: AssignedUser) {
    if (!selectedRole) return;

    // Last-admin guard: count current admins excluding this user
    if (selectedRole.role_type === 'protected' && selectedRole.code === 'admin') {
      const adminCount = assignedUsers.filter(u => u.status === 'Active').length;
      if (adminCount <= 1) {
        addToast('Cannot remove the last admin. Assign admin to another user first.', 'error');
        setConfirmUser(null);
        return;
      }
    }

    setRemovingId(user.assignment_id || user.profile_id);
    setConfirmUser(null);

    try {
      // Find the actual user_roles row (we may have an optimistic empty id)
      let assignmentId = user.assignment_id;
      if (!assignmentId) {
        const { data } = await supabase
          .from('user_roles')
          .select('id')
          .eq('profile_id', user.profile_id)
          .eq('role_id', selectedRole.id)
          .single();
        assignmentId = data?.id ?? '';
      }

      const { error: delErr } = await supabase
        .from('user_roles')
        .delete()
        .eq('id', assignmentId);
      if (delErr) throw delErr;

      // Mirror removal to profile_roles
      const legacyRole = LEGACY_ROLE_MAP[selectedRole.code];
      if (legacyRole) {
        await supabase
          .from('profile_roles')
          .delete()
          .eq('profile_id', user.profile_id)
          .eq('role', legacyRole);
      }

      // Audit log
      await supabase.from('audit_log').insert({
        action:      'role.member_removed',
        entity_type: 'user_roles',
        entity_id:   selectedRole.id,
        user_id:     profile?.id ?? null,
        metadata:    { role: selectedRole.name, employee: user.name, profile_id: user.profile_id },
      });

      addToast(`Removed ${user.name} from ${selectedRole.name}`, 'success');

      // Clear history cache so the History tab reloads fresh next time
      setHistory([]);

      // Optimistically remove from list
      setAssignedUsers(prev => prev.filter(u => u.profile_id !== user.profile_id));

      loadRoles();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      addToast(`Failed to remove: ${msg}`, 'error');
    } finally {
      setRemovingId(null);
    }
  }

  // ── Sync system role ───────────────────────────────────────────────────────

  async function syncSystemRole() {
    if (!selectedRole || selectedRole.role_type !== 'system') return;
    setSyncing(true);
    try {
      const { data, error: syncErr } = await supabase.rpc('sync_system_roles', {
        p_role_code: selectedRole.code,
      });
      if (syncErr) throw syncErr;

      const summary = (data ?? {}) as Record<string, { eligible: number; inserted: number; deleted: number }>;
      const entry   = summary[selectedRole.code];
      const msg     = entry
        ? `Sync complete — ${entry.eligible} eligible, ${entry.inserted} added, ${entry.deleted} removed`
        : 'Sync complete';

      addToast(msg, 'success');
      await loadAssignedUsers(selectedRole.id);
      await loadUnlinkedEmployees();   // refresh "not in system" panel too
      loadRoles();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      addToast(`Sync failed: ${msg}`, 'error');
    } finally {
      setSyncing(false);
    }
  }

  // ── Create new custom role ─────────────────────────────────────────────────

  async function createRole(form: NewRoleForm) {
    setSavingRole(true);
    try {
      const { data, error: insertErr } = await supabase
        .from('roles')
        .insert({
          code:        form.code.trim(),
          name:        form.name.trim(),
          description: form.description.trim() || null,
          role_type:   'custom',
          is_system:   false,
        })
        .select()
        .single();
      if (insertErr) throw insertErr;

      // Audit log
      await supabase.from('audit_log').insert({
        action:      'role.created',
        entity_type: 'roles',
        entity_id:   data.id,
        user_id:     profile?.id ?? null,
        metadata:    { code: form.code, name: form.name },
      });

      addToast(`Created role "${form.name}"`, 'success');
      setShowCreate(false);
      await loadRoles();

      // Auto-select the newly created role
      setSelectedRole({ ...data, role_type: 'custom', memberCount: 0 });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      addToast(`Failed to create role: ${msg}`, 'error');
    } finally {
      setSavingRole(false);
    }
  }

  // ── Filtered role list ─────────────────────────────────────────────────────

  const filteredRoles = useMemo(() => {
    if (!roleSearch.trim()) return roles;
    const q = roleSearch.toLowerCase();
    return roles.filter(r =>
      r.name.toLowerCase().includes(q) ||
      r.code.toLowerCase().includes(q),
    );
  }, [roles, roleSearch]);

  // Group filtered roles by type for the left panel
  const rolesByType = useMemo(() => {
    const groups: Record<RoleType, Role[]> = { system: [], custom: [], protected: [] };
    for (const r of filteredRoles) groups[r.role_type].push(r);
    return groups;
  }, [filteredRoles]);

  // ── Render helpers ─────────────────────────────────────────────────────────

  if (loading) {
    return (
      <div className="ar-panel" style={{ textAlign: 'center', padding: 40, color: '#6B7280' }}>
        <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 8 }} />
        Loading roles…
      </div>
    );
  }

  if (error) {
    return <ErrorBanner message={error} onRetry={loadRoles} />;
  }

  const canEditRole = selectedRole && selectedRole.role_type !== 'system';

  return (
    <div className="ar-panel" style={{ position: 'relative' }}>
      {/* ── Header ──────────────────────────────────────────────────────── */}
      <h2 className="page-title">Role Assignments</h2>
      <p className="page-subtitle">
        Select a role to view and manage its members. System roles are auto-managed
        and cannot be edited manually — use <strong>Sync Now</strong> to refresh
        membership from employee data.
      </p>

      {/* ── Two-panel layout ────────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 0, border: '1px solid #E5E7EB', borderRadius: 10, overflow: 'hidden', minHeight: 520 }}>

        {/* ── LEFT PANEL: role list ───────────────────────────────────────── */}
        <div style={{
          width: 280, flexShrink: 0,
          borderRight: '1px solid #E5E7EB',
          display: 'flex', flexDirection: 'column',
          background: '#FAFAFA',
        }}>
          {/* Search + Create button */}
          <div style={{ padding: '14px 14px 10px', borderBottom: '1px solid #E5E7EB' }}>
            <div style={{ position: 'relative', marginBottom: 10 }}>
              <i className="fa-solid fa-magnifying-glass" style={{
                position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
                color: '#9CA3AF', fontSize: 12,
              }} />
              <input
                type="text"
                placeholder="Search roles…"
                value={roleSearch}
                onChange={e => setRoleSearch(e.target.value)}
                style={{
                  width: '100%', padding: '7px 10px 7px 30px', borderRadius: 6,
                  border: '1px solid #D1D5DB', fontSize: 13, outline: 'none',
                  background: '#fff', boxSizing: 'border-box',
                }}
              />
            </div>
            <button
              onClick={() => setShowCreate(true)}
              style={{
                width: '100%', padding: '7px 12px', borderRadius: 6,
                border: '1px dashed #93C5FD', background: '#EFF6FF',
                color: '#2563EB', fontSize: 13, fontWeight: 600,
                cursor: 'pointer', display: 'flex', alignItems: 'center',
                justifyContent: 'center', gap: 6,
              }}
            >
              <i className="fa-solid fa-plus" style={{ fontSize: 11 }} />
              Create Custom Role
            </button>
          </div>

          {/* Role list — scrollable */}
          <div style={{ flex: 1, overflowY: 'auto' }}>
            {(['protected', 'system', 'custom'] as RoleType[]).map(type => {
              const group = rolesByType[type];
              if (!group.length) return null;
              const badge = TYPE_BADGE[type];
              return (
                <div key={type}>
                  {/* Group header */}
                  <div style={{
                    padding: '8px 14px 4px',
                    fontSize: 10, fontWeight: 700, letterSpacing: '0.07em',
                    color: badge.color, background: badge.bg + '55',
                    borderBottom: `1px solid ${badge.bg}`,
                    textTransform: 'uppercase',
                  }}>
                    {badge.label}
                  </div>

                  {/* Role cards */}
                  {group.map(role => {
                    const isSelected = selectedRole?.id === role.id;
                    return (
                      <button
                        key={role.id}
                        onClick={() => setSelectedRole(role)}
                        style={{
                          width: '100%', textAlign: 'left',
                          padding: '10px 14px',
                          background: isSelected ? '#EFF6FF' : 'transparent',
                          borderLeft: isSelected ? '3px solid #2563EB' : '3px solid transparent',
                          borderTop: 'none', borderRight: 'none',
                          borderBottom: '1px solid #F3F4F6',
                          cursor: 'pointer',
                          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                        }}
                      >
                        <div style={{ minWidth: 0 }}>
                          <div style={{
                            fontSize: 13, fontWeight: 600,
                            color: isSelected ? '#1D4ED8' : '#111827',
                            marginBottom: 2,
                            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                          }}>
                            {role.name}
                          </div>
                          <code style={{ fontSize: 10, color: '#9CA3AF', background: '#F3F4F6', padding: '1px 4px', borderRadius: 3 }}>
                            {role.code}
                          </code>
                        </div>
                        {/* Member count badge */}
                        <span style={{
                          marginLeft: 8, flexShrink: 0,
                          minWidth: 22, height: 22, borderRadius: 11,
                          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                          background: isSelected ? '#BFDBFE' : '#E5E7EB',
                          color:      isSelected ? '#1D4ED8' : '#4B5563',
                          fontSize: 11, fontWeight: 700,
                        }}>
                          {role.memberCount}
                        </span>
                      </button>
                    );
                  })}
                </div>
              );
            })}

            {filteredRoles.length === 0 && roleSearch && (
              <div style={{ padding: 24, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
                No roles match "{roleSearch}"
              </div>
            )}
          </div>
        </div>

        {/* ── RIGHT PANEL: role details ───────────────────────────────────── */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', background: '#fff', minWidth: 0 }}>
          {!selectedRole ? (
            /* Empty state — no role selected */
            <div style={{
              flex: 1, display: 'flex', flexDirection: 'column',
              alignItems: 'center', justifyContent: 'center',
              color: '#9CA3AF', padding: 40, textAlign: 'center',
            }}>
              <i className="fa-solid fa-user-shield" style={{ fontSize: 36, marginBottom: 12, opacity: 0.4 }} />
              <p style={{ margin: 0, fontSize: 14 }}>Select a role to view its members</p>
            </div>
          ) : (
            <>
              {/* Role header */}
              <div style={{
                padding: '16px 20px',
                borderBottom: '1px solid #E5E7EB',
                background: '#F9FAFB',
              }}>
                <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
                  <div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
                      <span style={{ fontSize: 16, fontWeight: 700, color: '#111827' }}>
                        {selectedRole.name}
                      </span>
                      <TypeBadge type={selectedRole.role_type} />
                    </div>
                    <code style={{ fontSize: 11, color: '#6B7280', background: '#F3F4F6', padding: '2px 6px', borderRadius: 4 }}>
                      {selectedRole.code}
                    </code>
                    {selectedRole.description && (
                      <p style={{ margin: '8px 0 0', fontSize: 13, color: '#6B7280', lineHeight: 1.4 }}>
                        {selectedRole.description}
                      </p>
                    )}
                  </div>

                  {/* Sync Now button — system roles only */}
                  {selectedRole.role_type === 'system' && (
                    <button
                      onClick={syncSystemRole}
                      disabled={syncing}
                      style={{
                        padding: '8px 14px', borderRadius: 6,
                        border: '1px solid #93C5FD', background: '#EFF6FF',
                        color: '#2563EB', fontSize: 13, fontWeight: 600,
                        cursor: syncing ? 'not-allowed' : 'pointer',
                        display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0,
                      }}
                    >
                      {syncing
                        ? <><i className="fa-solid fa-spinner fa-spin" /> Syncing…</>
                        : <><i className="fa-solid fa-rotate" /> Sync Now</>}
                    </button>
                  )}
                </div>

                {/* Info boxes */}
                {selectedRole.role_type === 'system' && (
                  <div style={{
                    marginTop: 12, padding: '8px 12px', borderRadius: 6,
                    background: '#EFF6FF', border: '1px solid #BFDBFE',
                    display: 'flex', gap: 8, alignItems: 'flex-start', fontSize: 12, color: '#1E40AF',
                  }}>
                    <i className="fa-solid fa-circle-info" style={{ marginTop: 1, flexShrink: 0 }} />
                    <span>
                      This role is automatically managed. Membership is derived from employee data.
                      Use <strong>Sync Now</strong> to refresh, or run the nightly sync job.
                    </span>
                  </div>
                )}
                {selectedRole.role_type === 'protected' && (
                  <div style={{
                    marginTop: 12, padding: '8px 12px', borderRadius: 6,
                    background: '#FFFBEB', border: '1px solid #FDE68A',
                    display: 'flex', gap: 8, alignItems: 'flex-start', fontSize: 12, color: '#92400E',
                  }}>
                    <i className="fa-solid fa-shield-halved" style={{ marginTop: 1, flexShrink: 0 }} />
                    <span>
                      Protected role — membership changes are logged. At least one active admin
                      must remain at all times.
                    </span>
                  </div>
                )}
              </div>

              {/* ── Tab bar: Members | History ───────────────────────── */}
              <div style={{
                display: 'flex', gap: 0, borderBottom: '1px solid #E5E7EB',
                background: '#fff', paddingLeft: 20,
              }}>
                {(['members', 'history'] as RightTab[]).map(tab => {
                  const active = rightTab === tab;
                  const label  = tab === 'members' ? 'Members' : 'History';
                  const icon   = tab === 'members' ? 'fa-users' : 'fa-clock-rotate-left';
                  return (
                    <button
                      key={tab}
                      onClick={() => {
                        setRightTab(tab);
                        if (tab === 'history' && selectedRole && !historyLoading && !history.length) {
                          loadHistory(selectedRole.id);
                        }
                      }}
                      style={{
                        padding: '10px 16px', border: 'none', background: 'transparent',
                        borderBottom: active ? '2px solid #2563EB' : '2px solid transparent',
                        color:    active ? '#2563EB' : '#6B7280',
                        fontWeight: active ? 700 : 400,
                        fontSize: 13, cursor: 'pointer',
                        display: 'flex', alignItems: 'center', gap: 6,
                        marginBottom: -1,
                      }}
                    >
                      <i className={`fa-solid ${icon}`} style={{ fontSize: 12 }} />
                      {label}
                    </button>
                  );
                })}
              </div>

              {/* ── History panel ────────────────────────────────────────── */}
              {rightTab === 'history' && (
                <div style={{ flex: 1, overflowY: 'auto' }}>
                  {historyLoading ? (
                    <div style={{ padding: 32, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
                      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
                      Loading history…
                    </div>
                  ) : history.length === 0 ? (
                    <div style={{
                      flex: 1, display: 'flex', flexDirection: 'column',
                      alignItems: 'center', justifyContent: 'center',
                      padding: 48, textAlign: 'center', color: '#9CA3AF',
                    }}>
                      <i className="fa-solid fa-clock-rotate-left" style={{ fontSize: 24, marginBottom: 10, opacity: 0.35 }} />
                      <p style={{ margin: 0, fontSize: 14 }}>No assignment history yet</p>
                      <p style={{ margin: '6px 0 0', fontSize: 12 }}>
                        Changes made from this screen will appear here.
                      </p>
                    </div>
                  ) : (
                    <div style={{ padding: '8px 0' }}>
                      {history.map((entry, idx) => {
                        const isAdd     = entry.action === 'role.member_added';
                        const iconCls   = isAdd ? 'fa-user-plus'  : 'fa-user-minus';
                        const iconColor = isAdd ? '#059669'        : '#DC2626';
                        const bgColor   = isAdd ? '#ECFDF5'        : '#FEF2F2';
                        const borderClr = isAdd ? '#A7F3D0'        : '#FECACA';
                        const label     = isAdd ? 'Added'          : 'Removed';

                        // Format timestamp
                        const date  = new Date(entry.createdAt);
                        const now   = Date.now();
                        const diffS = Math.floor((now - date.getTime()) / 1000);
                        let timeAgo: string;
                        if (diffS < 60)         timeAgo = 'just now';
                        else if (diffS < 3600)  timeAgo = `${Math.floor(diffS / 60)}m ago`;
                        else if (diffS < 86400) timeAgo = `${Math.floor(diffS / 3600)}h ago`;
                        else if (diffS < 604800)timeAgo = `${Math.floor(diffS / 86400)}d ago`;
                        else                    timeAgo = date.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });

                        return (
                          <div key={entry.id} style={{
                            display: 'flex', alignItems: 'flex-start', gap: 12,
                            padding: '10px 20px',
                            borderBottom: idx < history.length - 1 ? '1px solid #F3F4F6' : 'none',
                          }}>
                            {/* Icon dot */}
                            <div style={{
                              width: 32, height: 32, borderRadius: '50%', flexShrink: 0,
                              background: bgColor, border: `1px solid ${borderClr}`,
                              display: 'flex', alignItems: 'center', justifyContent: 'center',
                              marginTop: 2,
                            }}>
                              <i className={`fa-solid ${iconCls}`} style={{ fontSize: 12, color: iconColor }} />
                            </div>

                            {/* Text */}
                            <div style={{ flex: 1, minWidth: 0 }}>
                              <div style={{ fontSize: 14, color: '#111827', lineHeight: 1.4 }}>
                                <strong>{entry.employee}</strong>
                                {' '}
                                <span style={{ color: iconColor, fontWeight: 600 }}>{label.toLowerCase()}</span>
                                {isAdd ? ' to' : ' from'} this role
                              </div>
                              <div style={{ fontSize: 12, color: '#9CA3AF', marginTop: 2 }}>
                                by <span style={{ color: '#4B5563', fontWeight: 500 }}>{entry.changedBy}</span>
                                {' · '}
                                <span title={date.toLocaleString()}>{timeAgo}</span>
                              </div>
                            </div>

                            {/* Label badge */}
                            <span style={{
                              flexShrink: 0, padding: '2px 8px', borderRadius: 10,
                              fontSize: 11, fontWeight: 700,
                              background: bgColor, color: iconColor,
                              border: `1px solid ${borderClr}`,
                            }}>
                              {label}
                            </span>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>
              )}

              {/* ── Members tab content ──────────────────────────────────── */}
              {rightTab === 'members' && canEditRole && (
                <div style={{ padding: '12px 20px', borderBottom: '1px solid #F3F4F6', position: 'relative' }}>
                  <div style={{ position: 'relative' }}>
                    <i className="fa-solid fa-user-plus" style={{
                      position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
                      color: '#9CA3AF', fontSize: 13,
                    }} />
                    <input
                      type="text"
                      placeholder="Search employees to add…"
                      value={empSearch}
                      onChange={e => setEmpSearch(e.target.value)}
                      style={{
                        width: '100%', padding: '8px 10px 8px 34px',
                        borderRadius: 6, border: '1px solid #D1D5DB',
                        fontSize: 13, outline: 'none', boxSizing: 'border-box',
                      }}
                    />
                    {empSearching && (
                      <i className="fa-solid fa-spinner fa-spin" style={{
                        position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)',
                        color: '#9CA3AF', fontSize: 12,
                      }} />
                    )}
                  </div>

                  {/* No-results hint after searching */}
                  {!empSearching && empSearch.trim().length > 0 && empResults.length === 0 && (
                    <div style={{ marginTop: 6, fontSize: 12, color: '#9CA3AF', paddingLeft: 4 }}>
                      No employees with accounts found for "{empSearch.trim()}"
                    </div>
                  )}

                  {/* Search results dropdown */}
                  {empResults.length > 0 && (
                    <div style={{
                      position: 'absolute', top: '100%', left: 20, right: 20, zIndex: 100,
                      background: '#fff', border: '1px solid #E5E7EB', borderRadius: 8,
                      boxShadow: '0 4px 16px rgba(0,0,0,0.10)', overflow: 'hidden',
                    }}>
                      {empResults.map(emp => {
                        const avatar = emp.photo_url
                          || `https://ui-avatars.com/api/?name=${encodeURIComponent(emp.name)}&background=2F77B5&color=fff&size=32`;
                        const isLoading = addingId === emp.employee_id;

                        return (
                          <button
                            key={emp.employee_id}
                            onClick={() => !emp.already_has && assignUser(emp)}
                            disabled={emp.already_has || isLoading}
                            style={{
                              width: '100%', textAlign: 'left', padding: '8px 12px',
                              border: 'none', background: emp.already_has ? '#F9FAFB' : '#fff',
                              cursor: emp.already_has || isLoading ? 'default' : 'pointer',
                              display: 'flex', alignItems: 'center', gap: 10,
                              borderBottom: '1px solid #F3F4F6',
                            }}
                            onMouseEnter={e => { if (!emp.already_has && !isLoading) (e.currentTarget as HTMLButtonElement).style.background = '#F0F9FF'; }}
                            onMouseLeave={e => { (e.currentTarget as HTMLButtonElement).style.background = emp.already_has ? '#F9FAFB' : '#fff'; }}
                          >
                            <img src={avatar} alt={emp.name} style={{ width: 28, height: 28, borderRadius: '50%', objectFit: 'cover' }} />
                            <div style={{ flex: 1, minWidth: 0 }}>
                              <div style={{ fontSize: 13, fontWeight: 600, color: '#111827' }}>{emp.name}</div>
                              <div style={{ fontSize: 11, color: '#9CA3AF' }}>{emp.dept_name || 'No department'}</div>
                            </div>
                            {isLoading
                              ? <i className="fa-solid fa-spinner fa-spin" style={{ color: '#9CA3AF', fontSize: 12 }} />
                              : emp.already_has
                              ? <span style={{ fontSize: 11, color: '#10B981', fontWeight: 600 }}>Already assigned</span>
                              : <i className="fa-solid fa-plus" style={{ color: '#2563EB', fontSize: 12 }} />}
                          </button>
                        );
                      })}
                    </div>
                  )}
                </div>
              )}

              {/* Member list — shown only on Members tab */}
              {rightTab === 'members' && <div style={{ flex: 1, overflowY: 'auto' }}>
                {/* Count header */}
                <div style={{
                  padding: '8px 20px', borderBottom: '1px solid #F3F4F6',
                  display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                }}>
                  <span style={{ fontSize: 12, color: '#6B7280', fontWeight: 600 }}>
                    {assignedUsers.length} member{assignedUsers.length !== 1 ? 's' : ''}
                  </span>
                  {usersLoading && (
                    <i className="fa-solid fa-spinner fa-spin" style={{ color: '#9CA3AF', fontSize: 12 }} />
                  )}
                </div>

                {/* User rows */}
                {usersLoading ? (
                  <div style={{ padding: 24, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
                    <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
                    Loading members…
                  </div>
                ) : assignedUsers.length === 0 ? (
                  <div style={{
                    flex: 1, display: 'flex', flexDirection: 'column',
                    alignItems: 'center', justifyContent: 'center',
                    padding: 48, textAlign: 'center', color: '#9CA3AF',
                  }}>
                    <i className="fa-solid fa-users-slash" style={{ fontSize: 24, marginBottom: 10, opacity: 0.4 }} />
                    <p style={{ margin: 0, fontSize: 13 }}>No members assigned yet</p>
                    {canEditRole && (
                      <p style={{ margin: '6px 0 0', fontSize: 12 }}>
                        Use the search above to add employees to this role.
                      </p>
                    )}
                  </div>
                ) : (
                  assignedUsers.map(user => {
                    const isRemoving = removingId === (user.assignment_id || user.profile_id);
                    return isRemoving ? (
                      <div key={user.profile_id} style={{
                        padding: '10px 16px', borderBottom: '1px solid #F3F4F6',
                        display: 'flex', alignItems: 'center', gap: 10, opacity: 0.5,
                      }}>
                        <i className="fa-solid fa-spinner fa-spin" style={{ color: '#9CA3AF' }} />
                        <span style={{ fontSize: 13, color: '#9CA3AF' }}>Removing {user.name}…</span>
                      </div>
                    ) : (
                      <UserRow
                        key={user.profile_id}
                        user={user}
                        canRemove={!!canEditRole}
                        onRemove={u => setConfirmUser(u)}
                      />
                    );
                  })
                )}
              </div>}

              {/* ── "Not in system yet" panel — system roles only, Members tab ── */}
              {rightTab === 'members' && selectedRole.role_type === 'system' && (unlinkedEmployees.length > 0 || unlinkedLoading) && (
                <div style={{ borderTop: '2px dashed #E5E7EB' }}>
                  {/* Section header */}
                  <div style={{
                    padding: '8px 20px',
                    display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                    background: '#FFFBEB',
                  }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                      <i className="fa-solid fa-envelope-open-text" style={{ color: '#D97706', fontSize: 12 }} />
                      <span style={{ fontSize: 12, fontWeight: 700, color: '#92400E' }}>
                        NOT IN SYSTEM YET
                      </span>
                      {!unlinkedLoading && (
                        <span style={{
                          background: '#FDE68A', color: '#92400E',
                          borderRadius: 10, padding: '1px 7px', fontSize: 11, fontWeight: 700,
                        }}>
                          {unlinkedEmployees.length}
                        </span>
                      )}
                    </div>
                    <span style={{ fontSize: 11, color: '#B45309' }}>
                      Active employees with no login account
                    </span>
                  </div>

                  {/* Rows */}
                  {unlinkedLoading ? (
                    <div style={{ padding: '12px 20px', color: '#9CA3AF', fontSize: 13 }}>
                      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
                      Checking accounts…
                    </div>
                  ) : (
                    unlinkedEmployees.map(emp => {
                      const isInviting = inviting.has(emp.employee_id);
                      const avatar = emp.photo_url
                        || `https://ui-avatars.com/api/?name=${encodeURIComponent(emp.name)}&background=D97706&color=fff&size=40`;
                      return (
                        <div key={emp.employee_id} style={{
                          display: 'flex', alignItems: 'center', gap: 12,
                          padding: '10px 20px', borderBottom: '1px solid #FEF3C7',
                          background: '#FFFBEB',
                        }}>
                          <img
                            src={avatar}
                            alt={emp.name}
                            style={{ width: 34, height: 34, borderRadius: '50%', objectFit: 'cover', flexShrink: 0 }}
                          />
                          <div style={{ flex: 1, minWidth: 0 }}>
                            <div style={{ fontWeight: 600, fontSize: 14, color: '#111827' }}>
                              {emp.name}
                            </div>
                            <div style={{ fontSize: 12, color: '#6B7280' }}>
                              {emp.business_email
                                ? emp.business_email
                                : <span style={{ color: '#F87171' }}>No email — add one in Employee Details</span>}
                            </div>
                          </div>
                          <span style={{ fontSize: 11, color: '#9CA3AF', flexShrink: 0 }}>
                            {emp.dept_name || ''}
                          </span>
                          {/* Invite button */}
                          <button
                            onClick={() => inviteEmployee(emp)}
                            disabled={isInviting || !emp.business_email}
                            title={emp.business_email ? `Send invite to ${emp.business_email}` : 'No email address'}
                            style={{
                              padding: '6px 14px', borderRadius: 6, flexShrink: 0,
                              border: '1px solid #F59E0B',
                              background: emp.business_email ? '#FEF3C7' : '#F3F4F6',
                              color:      emp.business_email ? '#92400E'  : '#9CA3AF',
                              fontSize: 12, fontWeight: 600,
                              cursor: isInviting || !emp.business_email ? 'not-allowed' : 'pointer',
                              display: 'flex', alignItems: 'center', gap: 5,
                            }}
                          >
                            {isInviting
                              ? <><i className="fa-solid fa-spinner fa-spin" /> Sending…</>
                              : <><i className="fa-solid fa-paper-plane" /> Invite</>}
                          </button>
                        </div>
                      );
                    })
                  )}
                </div>
              )}
            </>
          )}
        </div>
      </div>

      {/* ── Modals ──────────────────────────────────────────────────────── */}

      {/* Create role modal */}
      {showCreate && (
        <CreateRoleModal
          saving={savingRole}
          onSave={createRole}
          onCancel={() => setShowCreate(false)}
        />
      )}

      {/* Remove confirmation dialog */}
      {confirmUser && selectedRole && (
        <ConfirmDialog
          user={confirmUser}
          roleName={selectedRole.name}
          onConfirm={() => removeUser(confirmUser)}
          onCancel={() => setConfirmUser(null)}
        />
      )}

      {/* Toast stack */}
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    </div>
  );
}
