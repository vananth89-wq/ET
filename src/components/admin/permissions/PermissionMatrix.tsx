/**
 * PermissionMatrix  —  RBP Phase 4 (permission_sets architecture)
 *
 * Left panel  — list of named permission sets.
 *               "+ New" button creates a new set.
 *               Each row shows the set name, assigned role badge,
 *               and target group badge.
 *
 * Right panel — two tabs per selected set:
 *
 *   Permissions  — matrix table (V/C/E/D/H per module, toggles for binary
 *                  admin features, Reports checklist, Org Chart toggle).
 *                  Writes permission_set_items on Save.
 *
 *   Assignments  — two cards:
 *                  1. "Grant access to" — role dropdown
 *                  2. "Define target population" — chips (driven by role category)
 *                  Writes permission_set_assignments on Save.
 *
 * Data flow
 * ─────────
 *   Save permissions → DELETE permission_set_items WHERE permission_set_id = X
 *                    → INSERT permission_set_items (permission_set_id, permission_id)
 *
 *   Save assignments → DELETE permission_set_assignments WHERE permission_set_id = X
 *                    → INSERT permission_set_assignments (permission_set_id, role_id, target_group_id)
 *
 *   Load set list → SELECT permission_sets with permission_set_assignments JOIN roles + target_groups
 *   Load items    → SELECT permission_set_items WHERE permission_set_id = X
 *   Load assign   → SELECT permission_set_assignments WHERE permission_set_id = X (maybeSingle)
 *
 * Enforcement bridge: migration 102 makes get_my_permissions() UNION both
 * role_permissions and permission_set_assignments, so UI gates work immediately.
 */

import React, {
  useState, useEffect, useCallback, useRef,
} from 'react';
import { supabase }        from '../../../lib/supabase';
import ErrorBanner         from '../../shared/ErrorBanner';
import { usePermissions }  from '../../../hooks/usePermissions';

// ─── Layout config ────────────────────────────────────────────────────────────

const ACTIONS = ['view', 'create', 'edit', 'delete', 'history'] as const;
type Action = typeof ACTIONS[number];
const ACTION_LABELS: Record<Action, string> = {
  view: 'View', create: 'Create', edit: 'Edit', delete: 'Delete', history: 'History',
};
const ACTION_HINTS: Record<Action, string> = {
  view:    'Can read and see records within their target group scope',
  create:  'Can add new records (e.g. hire employee, raise expense)',
  edit:    'Can update existing records and add child entries (e.g. passport, address)',
  delete:  'Can permanently remove or deactivate records',
  history: 'Can view the full audit trail and change history for records',
};

interface ModuleRow   { code: string; label: string; availableActions: Action[]; actionHints?: Partial<Record<Action, string>>; rowHint?: string; }
interface MatrixGroup { groupLabel: string; rows: ModuleRow[]; }

const EV_GROUPS: MatrixGroup[] = [
  { groupLabel: 'Expense', rows: [
    { code: 'expense_reports', label: 'Expense reports', availableActions: ['view','create','edit','delete','history'],
      rowHint: "Employee's own expense reports — create, submit and track reimbursement claims" },
  ]},
  { groupLabel: 'Employee info', rows: [
    { code: 'employee_details',   label: 'Employee master',   availableActions: ['view','edit'],
      rowHint: 'Controls which employees this user can see — sets the scope for all employee info portlets' },
    { code: 'personal_info',      label: 'Personal info',     availableActions: ['view','edit'],
      rowHint: 'Legal name, gender, date of birth and other personal details' },
    { code: 'contact_info',       label: 'Contact',           availableActions: ['view','edit'],
      rowHint: 'Work email, personal email, phone numbers and messaging handles' },
    { code: 'employment',         label: 'Employment',        availableActions: ['view','edit'],
      rowHint: 'Job title, department, employment type, contract type and start date' },
    { code: 'address',            label: 'Address',           availableActions: ['view','edit'],
      rowHint: 'Home, postal and work addresses' },
    { code: 'passport',           label: 'Passport',          availableActions: ['view','edit'],
      rowHint: 'Passport details — number, issuing country, expiry date and visa information' },
    { code: 'identity_documents', label: 'Identity docs',     availableActions: ['view','edit'],
      rowHint: 'National ID, driving licence and other government-issued identity documents' },
    { code: 'emergency_contacts', label: 'Emergency contact', availableActions: ['view','edit'],
      rowHint: 'Emergency contact names, relationships and phone numbers' },
  ]},
];

const ADMIN_GROUPS: MatrixGroup[] = [
  { groupLabel: 'Employee', rows: [
    { code: 'hire_employee', label: 'Hire employee', availableActions: ['view','create','edit','delete','history'],
      rowHint: 'New hire pipeline — create Draft employees, complete onboarding and activate them',
      actionHints: {
        view:    'See the hire pipeline — Draft and Incomplete employee records',
        create:  'Submit a new hire — inserts a Draft employee record',
        edit:    'Edit a pending hire / draft record before activation',
        delete:  'Cancel a hire — removes the Draft/Incomplete record',
        history: 'View the hire audit trail for a candidate',
      },
    },
    { code: 'employee_details', label: 'Manage employees', availableActions: ['delete','history'],
      rowHint: 'Administrative control over active employee records — hard delete and change history',
      actionHints: {
        delete:  'Permanently delete an active employee record',
        history: 'View the full change history for an employee',
      },
    },
    { code: 'inactive_employees', label: 'Inactive employees', availableActions: ['view','create','edit','delete','history'],
      rowHint: 'Manage deactivated employees — deactivate active, reactivate inactive, or permanently remove',
      actionHints: {
        view:    'See the list of deactivated employees',
        create:  'Deactivate an active employee (Active → Inactive)',
        edit:    'Reactivate an inactive employee (Inactive → Active)',
        delete:  'Permanently delete an inactive employee record',
        history: 'View deactivation and reactivation audit trail',
      },
    },
  ]},
  { groupLabel: 'Department', rows: [
    { code: 'departments', label: 'Manage department', availableActions: ['view','create','edit','delete'],
      rowHint: 'Create and manage the department structure used across the organisation' },
  ]},
  { groupLabel: 'Reference data', rows: [
    { code: 'picklists', label: 'Picklist', availableActions: ['view','create','edit','delete'],
      rowHint: 'Manage dropdown options and reference values used in forms across the system' },
  ]},
  { groupLabel: 'Projects', rows: [
    { code: 'projects_mgmt', label: 'Project', availableActions: ['view','create','edit','delete'],
      rowHint: 'Create and manage projects that employees and expenses can be assigned to' },
  ]},
  { groupLabel: 'Exchange rate', rows: [
    { code: 'exchange_rates_mgmt', label: 'Exchange rate', availableActions: ['view','create','edit','delete'],
      rowHint: 'Manage currency exchange rates used for expense report conversions' },
  ]},
];

interface ToggleItem  { code: string; label: string; hint?: string; actions?: Action[]; }
interface ToggleGroup { groupLabel: string; items: ToggleItem[]; useMatrixLayout?: boolean; }

// Employee-facing workflow toggles — placed after Org Chart, before Admin Related
interface EvToggleGroup { groupLabel: string; hint: string; items: ToggleItem[]; }

const EV_TOGGLE_GROUPS: EvToggleGroup[] = [
  { groupLabel: 'Employee Workflow', hint: 'Feature toggles — no target group required', items: [
    { code: 'wf_my_requests', label: 'View my requests'  },
    { code: 'wf_inbox',       label: 'Approver inbox'    },
  ]},
];

// sec_admin_access is rendered as a standalone row above the Security group — see AdminAccessRow
const SEC_ADMIN_ACCESS_HINT = 'Top-level gate — required to access the entire Admin area. Without this, all other security permissions are unreachable.';

const TOGGLE_GROUPS: ToggleGroup[] = [
  { groupLabel: 'Security', useMatrixLayout: true, items: [
    { code: 'sec_role_assignments',   label: 'Role assignments',   hint: 'View: see members of each role. Edit: add / remove members and create custom roles.', actions: ['view', 'edit'] as Action[] },
    { code: 'sec_permission_matrix',  label: 'Permission matrix',  hint: 'View: open the Permission Matrix tab. Edit: also allows saving changes to permission sets, items and assignments.', actions: ['view', 'edit'] as Action[] },
    { code: 'sec_target_groups',      label: 'Target groups',      hint: 'View: see custom target groups and their criteria. Edit: create, modify and delete groups.', actions: ['view', 'edit'] as Action[] },
    { code: 'sec_permission_catalog', label: 'Permission catalog', hint: 'Controls the Permission Catalog tab — read-only reference view of all permissions in the system grouped by module.' },
    { code: 'sec_rbp_troubleshoot',   label: 'RBP troubleshoot',   hint: 'Controls the RBP Troubleshooting tab — inspect what permissions any user currently has and trace why.' },
  ]},
  { groupLabel: 'Workflow Admin', useMatrixLayout: true, items: [
    { code: 'wf_manage',                label: 'Manage Workflow',            actions: ['view', 'edit'] as Action[], hint: 'View: open the Workflow Operations page. Edit: trigger, cancel and configure running workflows.' },
    { code: 'wf_templates',             label: 'Manage Workflow Templates',  actions: ['view', 'edit'] as Action[], hint: 'View: browse workflow templates. Edit: create, modify and delete templates and their steps.' },
    { code: 'wf_notification_config',   label: 'Manage Notifications',       actions: ['view', 'edit'] as Action[], hint: 'View: open the Manage Notifications page. Edit: create, modify and delete notification templates.' },
    { code: 'wf_delegations',           label: 'Manage Delegations',         actions: ['view', 'edit'] as Action[], hint: 'View: see all delegation rules. Edit: create and remove delegation entries.' },
    { code: 'wf_assignments',           label: 'Manage Assignments',         actions: ['view', 'edit'] as Action[], hint: 'View: see workflow role assignments. Edit: assign and unassign approvers.' },
    { code: 'wf_performance',           label: 'Performance',                hint: 'View-only: workflow performance dashboard — cycle times, SLA metrics and bottleneck analysis.' },
    { code: 'wf_analytics',             label: 'Analytics',                  hint: 'View-only: workflow analytics charts — volume trends, approval rates and turnaround distributions.' },
    { code: 'wf_notifications',         label: 'Notification Monitor',       hint: 'View-only: notification queue monitor — see sent, pending and failed notification events.' },
  ]},
  { groupLabel: 'Jobs', items: [
    { code: 'jobs_manage', label: 'Manage jobs' },
  ]},
];

const REPORTS_CODE = 'reports_admin';

// ─── Target population config ─────────────────────────────────────────────────

interface TpChip { label: string; tgCode: string | null; special?: boolean; }
type RoleCategory = 'ess' | 'mss' | 'hr';

const ROLE_CAT_INFO: Record<RoleCategory, { badge: string; bg: string; color: string }> = {
  ess: { badge: 'ESS — employee self-service',  bg: '#DBEAFE', color: '#1E40AF' },
  mss: { badge: 'MSS — manager self-service',   bg: '#D1FAE5', color: '#065F46' },
  hr:  { badge: 'HR / Custom role',             bg: '#EDE9FE', color: '#5B21B6' },
};

const TP_OPTIONS: Record<RoleCategory, TpChip[]> = {
  ess: [
    { label: 'Self',     tgCode: 'self'     },
    { label: 'Everyone', tgCode: 'everyone' },
  ],
  mss: [
    { label: 'Direct L1',  tgCode: 'direct_l1'      },
    { label: 'Direct L2',  tgCode: 'direct_l2'      },
    { label: 'Same dept',  tgCode: 'same_department' },
    { label: 'Everyone',   tgCode: 'everyone'        },
  ],
  hr: [
    { label: 'Everyone',              tgCode: 'everyone'        },
    { label: 'Same dept',             tgCode: 'same_department' },
    { label: 'Same country',          tgCode: 'same_country'    },
    { label: 'Select target group →', tgCode: null, special: true },
  ],
};

function getRoleCategory(code: string, name: string): RoleCategory {
  const lc = (code + name).toLowerCase();
  if (lc.includes('employee') || lc.includes('ess')) return 'ess';
  if (lc.includes('manager') || lc.includes('mss') || lc.includes('dept') || lc.includes('head')) return 'mss';
  return 'hr';
}

// ─── Types ────────────────────────────────────────────────────────────────────

interface PermissionSet {
  id: string;
  name: string;
  description: string | null;
  created_at: string;
  // enriched after load
  roleId:   string | null;
  roleName: string | null;
  tgLabel:  string | null;
  tgId:     string | null;
}

interface Role {
  id: string; code: string; name: string; sort_order: number;
}

interface Permission {
  id: string; code: string; action: string | null; module_id: string | null;
}

interface Module {
  id: string; code: string; name: string;
}

interface TargetGroup {
  id: string; code: string; label: string; scope_type: string; is_system: boolean;
}

// ─── Toast ────────────────────────────────────────────────────────────────────

interface Toast { id: string; message: string; type: 'success' | 'error'; }
function useToasts() {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const add = useCallback((message: string, type: Toast['type'] = 'success') => {
    const id = `t_${Date.now()}`;
    setToasts(p => [...p, { id, message, type }]);
    setTimeout(() => setToasts(p => p.filter(t => t.id !== id)), 3500);
  }, []);
  const dismiss = useCallback((id: string) => setToasts(p => p.filter(t => t.id !== id)), []);
  return { toasts, add, dismiss };
}

function ToastContainer({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: string) => void }) {
  if (!toasts.length) return null;
  return (
    <div style={{ position: 'fixed', bottom: 24, right: 24, zIndex: 9999, display: 'flex', flexDirection: 'column', gap: 8 }}>
      {toasts.map(t => (
        <div key={t.id} style={{
          display: 'flex', alignItems: 'center', gap: 10, padding: '10px 16px',
          borderRadius: 8, fontSize: 14, minWidth: 280,
          background: t.type === 'success' ? '#D1FAE5' : '#FEE2E2',
          color: t.type === 'success' ? '#065F46' : '#991B1B',
          boxShadow: '0 2px 8px rgba(0,0,0,.12)',
        }}>
          <i className={`fa-solid ${t.type === 'success' ? 'fa-circle-check' : 'fa-circle-xmark'}`} />
          <span style={{ flex: 1 }}>{t.message}</span>
          <button onClick={() => onDismiss(t.id)} style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}>
            <i className="fa-solid fa-xmark" style={{ fontSize: 12, opacity: .6 }} />
          </button>
        </div>
      ))}
    </div>
  );
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function PermissionMatrix() {
  const { toasts, add: addToast, dismiss: dismissToast } = useToasts();
  const { can } = usePermissions();
  const canEdit = can('sec_permission_matrix.edit');

  // ── Static data ────────────────────────────────────────────────────────────
  const [sets,         setSets]         = useState<PermissionSet[]>([]);
  const [roles,        setRoles]        = useState<Role[]>([]);
  const [allPerms,     setAllPerms]     = useState<Permission[]>([]);
  const [modules,      setModules]      = useState<Module[]>([]);
  const [targetGroups, setTargetGroups] = useState<TargetGroup[]>([]);
  const [loading,      setLoading]      = useState(true);
  const [error,        setError]        = useState<string | null>(null);

  // ── Selected set ───────────────────────────────────────────────────────────
  const [selectedSet,  setSelectedSet]  = useState<PermissionSet | null>(null);
  const [loadingItems, setLoadingItems] = useState(false);

  // ── New set creation ───────────────────────────────────────────────────────
  const [creatingNew,  setCreatingNew]  = useState(false);
  const [newSetName,   setNewSetName]   = useState('');
  const [creatingSaving, setCreatingSaving] = useState(false);
  const newSetInputRef = useRef<HTMLInputElement>(null);

  // ── Permissions state ─────────────────────────────────────────────────────
  const [grantedIds, setGrantedIds] = useState<Set<string>>(new Set());

  // ── Assignment state ───────────────────────────────────────────────────────
  const [assignRoleId,  setAssignRoleId]  = useState<string | null>(null);
  const [assignTgCode,  setAssignTgCode]  = useState<string | null>(null);
  const [customTgId,    setCustomTgId]    = useState<string | null>(null);
  const [showTgPicker,  setShowTgPicker]  = useState(false);

  // ── Inline name / description editing ─────────────────────────────────────
  const [editName, setEditName] = useState('');
  const [editDesc, setEditDesc] = useState('');

  // ── UI ─────────────────────────────────────────────────────────────────────
  const [activeTab,   setActiveTab]   = useState<'permissions' | 'assignments'>('permissions');
  const [dirty,       setDirty]       = useState(false);
  const [saving,      setSaving]      = useState(false);
  const [reportsOpen, setReportsOpen] = useState(false);

  const permByCode = useRef<Map<string, Permission>>(new Map());

  // ── Load static data ───────────────────────────────────────────────────────
  useEffect(() => { loadAll(); }, []);

  async function loadAll() {
    setLoading(true);
    try {
      const [setsRes, rolesRes, permsRes, tgsRes, modulesRes] = await Promise.all([
        supabase
          .from('permission_sets')
          .select(`id, name, description, created_at,
            permission_set_assignments(role_id, target_group_id,
              roles(name),
              target_groups(label, id))`)
          .order('name'),
        supabase.from('roles').select('id, code, name, sort_order').order('sort_order'),
        supabase.from('permissions').select('id, code, action, module_id').not('action', 'is', null),
        supabase.from('target_groups').select('id, code, label, scope_type, is_system').order('label'),
        supabase.from('modules').select('id, code, name').order('sort_order'),
      ]);

      if (setsRes.error)    throw setsRes.error;
      if (rolesRes.error)   throw rolesRes.error;
      if (permsRes.error)   throw permsRes.error;
      if (tgsRes.error)     throw tgsRes.error;
      if (modulesRes.error) throw modulesRes.error;

      const perms = (permsRes.data ?? []) as Permission[];
      const map   = new Map<string, Permission>();
      perms.forEach(p => map.set(p.code, p));
      permByCode.current = map;

      setAllPerms(perms);
      setRoles(rolesRes.data ?? []);
      setTargetGroups(tgsRes.data ?? []);
      setModules((modulesRes.data ?? []) as Module[]);

      // Normalise sets — pick first assignment row for badge display
      const normSets: PermissionSet[] = (setsRes.data ?? []).map((s: any) => {
        const asgn = (s.permission_set_assignments ?? [])[0] ?? null;
        return {
          id:          s.id,
          name:        s.name,
          description: s.description,
          created_at:  s.created_at,
          roleId:      asgn?.role_id   ?? null,
          roleName:    asgn?.roles?.name ?? null,
          tgLabel:     asgn?.target_groups?.label ?? null,
          tgId:        asgn?.target_group_id ?? null,
        };
      });
      setSets(normSets);

      // Auto-select first set
      if (normSets.length > 0) {
        await loadSetDetail(normSets[0], tgsRes.data ?? []);
        setSelectedSet(normSets[0]);
        setEditName(normSets[0].name);
        setEditDesc(normSets[0].description ?? '');
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Failed to load data');
    } finally {
      setLoading(false);
    }
  }

  // ── Load items + assignment for a set ──────────────────────────────────────
  async function loadSetDetail(set: PermissionSet, tgList?: TargetGroup[]) {
    setLoadingItems(true);
    try {
      const [itemsRes, asgnRes] = await Promise.all([
        supabase
          .from('permission_set_items')
          .select('permission_id')
          .eq('permission_set_id', set.id),
        supabase
          .from('permission_set_assignments')
          .select('role_id, target_group_id')
          .eq('permission_set_id', set.id)
          .maybeSingle(),
      ]);

      if (itemsRes.error) throw itemsRes.error;
      if (asgnRes.error)  throw asgnRes.error;

      setGrantedIds(new Set((itemsRes.data ?? []).map((r: any) => r.permission_id as string)));

      const asgn = asgnRes.data;
      setAssignRoleId(asgn?.role_id ?? null);

      const tgId = asgn?.target_group_id ?? null;
      const tgs  = tgList ?? targetGroups;
      if (tgId) {
        const tg = tgs.find(t => t.id === tgId);
        if (tg?.is_system) { setAssignTgCode(tg.code); setCustomTgId(null); }
        else               { setAssignTgCode(null);    setCustomTgId(tgId); }
      } else {
        setAssignTgCode(null);
        setCustomTgId(null);
      }

      setShowTgPicker(false);
      setDirty(false);
    } catch (e: unknown) {
      addToast('Failed to load set: ' + (e instanceof Error ? e.message : String(e)), 'error');
    } finally {
      setLoadingItems(false);
    }
  }

  function selectSet(set: PermissionSet) {
    setSelectedSet(set);
    setEditName(set.name);
    setEditDesc(set.description ?? '');
    setActiveTab('permissions');
    loadSetDetail(set);
  }

  function handleSelectSet(set: PermissionSet) {
    if (dirty && !window.confirm('You have unsaved changes. Switch and discard them?')) return;
    selectSet(set);
  }

  // ── Create new set ─────────────────────────────────────────────────────────
  function startCreating() {
    if (dirty && !window.confirm('You have unsaved changes. Discard them and create a new set?')) return;
    setCreatingNew(true);
    setNewSetName('');
    setTimeout(() => newSetInputRef.current?.focus(), 60);
  }

  async function confirmCreate() {
    const name = newSetName.trim();
    if (!name) return;
    setCreatingSaving(true);
    try {
      const { data, error: insErr } = await supabase
        .from('permission_sets')
        .insert({ name })
        .select('id, name, description, created_at')
        .single();
      if (insErr) throw insErr;

      const newSet: PermissionSet = {
        id: data.id, name: data.name,
        description: data.description, created_at: data.created_at,
        roleId: null, roleName: null, tgLabel: null, tgId: null,
      };
      setSets(prev => [...prev, newSet].sort((a, b) => a.name.localeCompare(b.name)));
      setCreatingNew(false);
      setNewSetName('');
      selectSet(newSet);
      addToast(`Created "${newSet.name}"`);
    } catch (e: unknown) {
      addToast('Create failed: ' + (e instanceof Error ? e.message : String(e)), 'error');
    } finally {
      setCreatingSaving(false);
    }
  }

  function cancelCreate() { setCreatingNew(false); setNewSetName(''); }

  // ── Permission lookup helpers ──────────────────────────────────────────────
  const permId = useCallback((moduleCode: string, action: Action): string | null => {
    return permByCode.current.get(`${moduleCode}.${action}`)?.id ?? null;
  }, []);

  const isGranted = useCallback((moduleCode: string, action: Action) => {
    const id = permId(moduleCode, action);
    return id ? grantedIds.has(id) : false;
  }, [grantedIds, permId]);

  const isItemToggled = useCallback((moduleCode: string) => {
    const id = permId(moduleCode, 'view');
    return id ? grantedIds.has(id) : false;
  }, [grantedIds, permId]);

  const togglePerm = useCallback((moduleCode: string, action: Action) => {
    const id = permId(moduleCode, action);
    if (!id) return;
    setGrantedIds(prev => {
      const n = new Set(prev);
      const turningOn = !n.has(id);
      turningOn ? n.add(id) : n.delete(id);
      if (turningOn && action === 'edit') {
        const viewId = permId(moduleCode, 'view');
        if (viewId) n.add(viewId);
      }
      if (!turningOn && action === 'view') {
        const editId = permId(moduleCode, 'edit');
        if (editId) n.delete(editId);
      }
      return n;
    });
    setDirty(true);
  }, [permId]);

  const toggleItem = useCallback((moduleCode: string) => {
    const id = permId(moduleCode, 'view');
    if (!id) return;
    setGrantedIds(prev => { const n = new Set(prev); n.has(id) ? n.delete(id) : n.add(id); return n; });
    setDirty(true);
  }, [permId]);

  // ── Lookup-specific helpers (action = 'lookup', not in ACTIONS array) ────────
  const isLookupGranted = useCallback((permissionId: string) => {
    return grantedIds.has(permissionId);
  }, [grantedIds]);

  const toggleLookupPerm = useCallback((permissionId: string) => {
    setGrantedIds(prev => { const n = new Set(prev); n.has(permissionId) ? n.delete(permissionId) : n.add(permissionId); return n; });
    setDirty(true);
  }, []);

  // ── Save ──────────────────────────────────────────────────────────────────
  async function handleSave() {
    if (!selectedSet) return;
    setSaving(true);
    try {
      const setId   = selectedSet.id;
      const rbpIds  = new Set(allPerms.map(p => p.id));

      // 0. Update name + description
      const trimmedName = editName.trim();
      if (!trimmedName) { addToast('Name cannot be empty', 'error'); setSaving(false); return; }
      const { error: nameErr } = await supabase
        .from('permission_sets')
        .update({ name: trimmedName, description: editDesc.trim() || null })
        .eq('id', setId);
      if (nameErr) throw nameErr;

      // 1. Overwrite permission_set_items
      const { error: delItemsErr } = await supabase
        .from('permission_set_items')
        .delete()
        .eq('permission_set_id', setId);
      if (delItemsErr) throw delItemsErr;

      const itemRows = Array.from(grantedIds)
        .filter(id => rbpIds.has(id))
        .map(permission_id => ({ permission_set_id: setId, permission_id }));

      if (itemRows.length > 0) {
        const { error: insItemsErr } = await supabase
          .from('permission_set_items')
          .insert(itemRows);
        if (insItemsErr) throw insItemsErr;
      }

      // 2. Overwrite permission_set_assignments
      const { error: delAsgnErr } = await supabase
        .from('permission_set_assignments')
        .delete()
        .eq('permission_set_id', setId);
      if (delAsgnErr) throw delAsgnErr;

      if (assignRoleId) {
        const resolvedTgId = assignTgCode
          ? (targetGroups.find(tg => tg.code === assignTgCode)?.id ?? null)
          : (customTgId ?? null);

        const { error: insAsgnErr } = await supabase
          .from('permission_set_assignments')
          .insert({ permission_set_id: setId, role_id: assignRoleId, target_group_id: resolvedTgId });
        if (insAsgnErr) throw insAsgnErr;
      }

      // Update left-panel badge
      const assignedRole = roles.find(r => r.id === assignRoleId) ?? null;
      const resolvedTgLabel = assignTgCode
        ? (targetGroups.find(tg => tg.code === assignTgCode)?.label ?? assignTgCode)
        : (customTgId ? (targetGroups.find(tg => tg.id === customTgId)?.label ?? null) : null);

      const trimmedNameFinal = editName.trim();
      setSets(prev => prev.map(s => s.id === setId
        ? { ...s, name: trimmedNameFinal, description: editDesc.trim() || null, roleId: assignRoleId, roleName: assignedRole?.name ?? null, tgLabel: resolvedTgLabel, tgId: customTgId }
        : s).sort((a, b) => a.name.localeCompare(b.name)));
      setSelectedSet(prev => prev ? { ...prev, name: trimmedNameFinal, description: editDesc.trim() || null, roleId: assignRoleId, roleName: assignedRole?.name ?? null, tgLabel: resolvedTgLabel, tgId: customTgId } : prev);

      setDirty(false);
      addToast('Permissions saved');
    } catch (e: unknown) {
      addToast(e instanceof Error ? e.message : 'Save failed', 'error');
    } finally {
      setSaving(false);
    }
  }

  function handleDiscard() {
    if (selectedSet) {
      setEditName(selectedSet.name);
      setEditDesc(selectedSet.description ?? '');
      loadSetDetail(selectedSet);
    }
    setDirty(false);
  }

  // ── Derived ────────────────────────────────────────────────────────────────

  // Lookup permissions — driven purely from DB data, no hardcoding.
  // Filters allPerms for action='lookup', looks up module name for display label.
  const moduleNameById = new Map(modules.map(m => [m.id, m.name]));
  const lookupPerms = allPerms
    .filter(p => p.action === 'lookup')
    .map(p => ({
      id:    p.id,
      code:  p.code,
      label: p.module_id ? (moduleNameById.get(p.module_id) ?? p.code) : p.code,
    }));

  const assignedRole  = roles.find(r => r.id === assignRoleId) ?? null;
  const roleCat       = assignedRole ? getRoleCategory(assignedRole.code, assignedRole.name) : 'hr';
  const tpOptions     = TP_OPTIONS[roleCat];
  const customTgs     = targetGroups.filter(tg => !tg.is_system);

  // ── Render helpers ─────────────────────────────────────────────────────────

  function SectionHeader({ label, amber }: { label: string; amber?: boolean }) {
    return (
      <tr>
        <td colSpan={6} style={{
          padding: '5px 14px',
          background: amber ? '#FFFBEB' : '#EFF6FF',
          color:      amber ? '#92400E' : '#1D4ED8',
          fontSize: 11, fontWeight: 500, letterSpacing: '.05em', textTransform: 'uppercase',
          borderTop:    `0.5px solid ${amber ? '#FDE68A' : '#BFDBFE'}`,
          borderBottom: `0.5px solid ${amber ? '#FDE68A' : '#BFDBFE'}`,
        }}>
          ▶&nbsp; {label}
        </td>
      </tr>
    );
  }

  function RowTooltip({ row }: { row: ModuleRow }) {
    const [visible, setVisible] = React.useState(false);
    // Only show actions that are available for this row
    const actionRows = row.availableActions.map(a => ({
      action: a,
      label:  ACTION_LABELS[a],
      hint:   row.actionHints?.[a] ?? ACTION_HINTS[a],
    }));

    return (
      <span
        style={{ position: 'relative', display: 'inline-flex', alignItems: 'center', flexShrink: 0 }}
        onMouseEnter={() => setVisible(true)}
        onMouseLeave={() => setVisible(false)}
      >
        {/* ⓘ badge */}
        <span style={{
          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          width: 14, height: 14, borderRadius: '50%',
          background: '#DBEAFE', color: '#1D4ED8',
          fontSize: 9, fontWeight: 700, cursor: 'help', userSelect: 'none',
        }}>i</span>

        {/* Tooltip card */}
        {visible && (
          <span style={{
            position: 'absolute',
            left: 20,
            top: '50%',
            transform: 'translateY(-50%)',
            background: '#fff',
            border: '1px solid #E2E8F0',
            borderRadius: 8,
            padding: '10px 12px',
            zIndex: 200,
            boxShadow: '0 8px 24px rgba(0,0,0,0.13)',
            pointerEvents: 'none',
            minWidth: 280,
          }}>
            {/* Arrow */}
            <span style={{
              position: 'absolute',
              left: -6, top: '50%', transform: 'translateY(-50%)',
              width: 0, height: 0,
              borderTop: '6px solid transparent',
              borderBottom: '6px solid transparent',
              borderRight: '6px solid #E2E8F0',
            }} />
            <span style={{
              position: 'absolute',
              left: -5, top: '50%', transform: 'translateY(-50%)',
              width: 0, height: 0,
              borderTop: '5px solid transparent',
              borderBottom: '5px solid transparent',
              borderRight: '5px solid #fff',
            }} />

            {/* Header */}
            <span style={{
              display: 'block',
              fontSize: 11, fontWeight: 700, color: '#1D4ED8',
              textTransform: 'uppercase', letterSpacing: '.06em',
              marginBottom: 8, paddingBottom: 6,
              borderBottom: '1px solid #EFF6FF',
            }}>
              {row.label}
            </span>

            {/* Action rows */}
            {actionRows.map(({ action, label, hint }) => (
              <span key={action} style={{
                display: 'flex', gap: 10, alignItems: 'flex-start',
                marginBottom: 5,
              }}>
                <span style={{
                  flexShrink: 0,
                  width: 46,
                  fontSize: 10, fontWeight: 600,
                  color: '#64748B',
                  textTransform: 'uppercase', letterSpacing: '.05em',
                  paddingTop: 1,
                }}>{label}</span>
                <span style={{
                  fontSize: 11, color: '#1E293B', lineHeight: 1.4,
                }}>{hint}</span>
              </span>
            ))}
          </span>
        )}
      </span>
    );
  }

  function SubHeader({ label }: { label: string }) {
    return (
      <tr>
        <td colSpan={6} style={{
          background: '#F1F5FF',
          padding: '6px 12px 6px 18px',
          borderTop: '1px solid #C7D9F8',
          borderBottom: '1px solid #C7D9F8',
        }}>
          <span style={{
            fontSize: 11, fontWeight: 600, letterSpacing: '.07em',
            textTransform: 'uppercase', color: '#2563EB',
          }}>
            {label}
          </span>
        </td>
      </tr>
    );
  }

  function CbCell({ moduleCode, action, availableActions, actionHints }: {
    moduleCode: string; action: Action; availableActions: Action[]; actionHints?: Partial<Record<Action, string>>;
  }) {
    if (!availableActions.includes(action)) {
      return <td style={tdStyle}><span style={{ color: '#E5E7EB', fontSize: 14 }}>—</span></td>;
    }
    const hint = actionHints?.[action] ?? ACTION_HINTS[action];
    return (
      <td style={tdStyle} title={hint}>
        <input type="checkbox" checked={isGranted(moduleCode, action)}
          onChange={() => !canEdit ? undefined : togglePerm(moduleCode, action)}
          disabled={!canEdit}
          style={{ width: 15, height: 15, accentColor: '#1D4ED8', cursor: canEdit ? 'pointer' : 'not-allowed', opacity: canEdit ? 1 : 0.5 }} />
      </td>
    );
  }

  function MatrixRow({ row }: { row: ModuleRow }) {
    return (
      <tr style={{ borderBottom: '0.5px solid #F1F5F9' }}
        onMouseEnter={e => (e.currentTarget.style.background = '#F8FAFF')}
        onMouseLeave={e => (e.currentTarget.style.background = '')}>
        <td style={{ ...tdStyle, paddingLeft: 26, textAlign: 'left', color: '#374151', fontSize: 13 }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
            {row.label}
            {(row.rowHint || row.actionHints) && <RowTooltip row={row} />}
          </span>
        </td>
        {ACTIONS.map(a => (
          <CbCell key={a} moduleCode={row.code} action={a}
            availableActions={row.availableActions} actionHints={row.actionHints} />
        ))}
      </tr>
    );
  }

  function LookupToggle({ permissionId, disabled }: { permissionId: string; disabled?: boolean }) {
    const on = isLookupGranted(permissionId);
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, opacity: disabled ? 0.5 : 1 }}>
        <label style={{ position: 'relative', width: 40, height: 22, display: 'inline-block', cursor: disabled ? 'not-allowed' : 'pointer', flexShrink: 0 }}>
          <input type="checkbox" checked={on} onChange={() => !disabled && toggleLookupPerm(permissionId)}
            disabled={disabled} style={{ opacity: 0, width: 0, height: 0 }} />
          <span style={{
            position: 'absolute', inset: 0, borderRadius: 22, transition: 'background .2s',
            background: on ? '#1D4ED8' : '#D1D5DB',
          }}>
            <span style={{
              position: 'absolute', width: 16, height: 16, top: 3,
              left: on ? 20 : 3, borderRadius: '50%', background: '#fff',
              transition: 'left .18s', boxShadow: '0 1px 3px rgba(0,0,0,.2)',
            }} />
          </span>
        </label>
        <span style={{ fontSize: 13, fontWeight: on ? 500 : 400, color: on ? '#1D4ED8' : '#9CA3AF' }}>
          {on ? 'On' : 'Off'}
        </span>
      </div>
    );
  }

  function Toggle({ moduleCode, disabled }: { moduleCode: string; disabled?: boolean }) {
    const on = isItemToggled(moduleCode);
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, opacity: disabled ? 0.5 : 1 }}>
        <label style={{ position: 'relative', width: 40, height: 22, display: 'inline-block', cursor: disabled ? 'not-allowed' : 'pointer', flexShrink: 0 }}>
          <input type="checkbox" checked={on} onChange={() => !disabled && toggleItem(moduleCode)}
            disabled={disabled} style={{ opacity: 0, width: 0, height: 0 }} />
          <span style={{
            position: 'absolute', inset: 0, borderRadius: 22, transition: 'background .2s',
            background: on ? '#1D4ED8' : '#D1D5DB',
          }}>
            <span style={{
              position: 'absolute', width: 16, height: 16, top: 3,
              left: on ? 20 : 3, borderRadius: '50%', background: '#fff',
              transition: 'left .18s', boxShadow: '0 1px 3px rgba(0,0,0,.2)',
            }} />
          </span>
        </label>
        <span style={{ fontSize: 13, fontWeight: on ? 500 : 400, color: on ? '#1D4ED8' : '#9CA3AF', minWidth: 30 }}>
          {on ? 'On' : 'Off'}
        </span>
      </div>
    );
  }

  function ToggleGroupRows({ tg }: { tg: ToggleGroup }) {
    return (
      <>
        <SubHeader label={tg.groupLabel} />
        {tg.items.map(item => {
          // Matrix-aligned layout: each action column gets a checkbox or a dash
          if (tg.useMatrixLayout) {
            const availableActions: Action[] = item.actions ?? ['view'];
            return (
              <tr key={item.code} style={{ borderBottom: '0.5px solid #EDEFF2' }}
                onMouseEnter={e => (e.currentTarget.style.background = '#F8FAFF')}
                onMouseLeave={e => (e.currentTarget.style.background = '')}>
                <td style={{ paddingLeft: 26, paddingTop: 9, paddingBottom: 9, textAlign: 'left', fontSize: 13, color: '#374151', verticalAlign: 'middle' }}>
                  {item.label}
                  {item.hint && (
                    <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2, fontWeight: 400 }}>
                      {item.hint}
                    </div>
                  )}
                </td>
                {ACTIONS.map(action => {
                  if (!availableActions.includes(action)) {
                    return <td key={action} style={tdStyle}><span style={{ color: '#E5E7EB', fontSize: 14 }}>—</span></td>;
                  }
                  return (
                    <td key={action} style={tdStyle}>
                      <input type="checkbox"
                        checked={isGranted(item.code, action)}
                        onChange={() => { if (canEdit) togglePerm(item.code, action); }}
                        disabled={!canEdit}
                        style={{ width: 15, height: 15, accentColor: '#1D4ED8', cursor: canEdit ? 'pointer' : 'not-allowed', opacity: canEdit ? 1 : 0.5 }}
                      />
                    </td>
                  );
                })}
              </tr>
            );
          }

          // Default toggle layout (Workflow Admin, Jobs, etc.)
          return (
            <tr key={item.code} style={{ borderBottom: '0.5px solid #EDEFF2' }}
              onMouseEnter={e => (e.currentTarget.style.background = '#F8FAFF')}
              onMouseLeave={e => (e.currentTarget.style.background = '')}>
              <td style={{ paddingLeft: 24, paddingTop: 9, paddingBottom: 9, textAlign: 'left', fontSize: 13, color: '#374151', verticalAlign: 'middle' }}>
                {item.label}
                {item.hint && (
                  <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2, fontWeight: 400 }}>
                    {item.hint}
                  </div>
                )}
              </td>
              <td colSpan={5} style={{ padding: '6px 16px', verticalAlign: 'middle' }}>
                <Toggle moduleCode={item.code} disabled={!canEdit} />
              </td>
            </tr>
          );
        })}
      </>
    );
  }

  // ── Main render ────────────────────────────────────────────────────────────

  if (loading) return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: 300, color: '#6B7280' }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 10 }} />Loading…
    </div>
  );
  if (error) return <ErrorBanner message={error} />;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0 }}>
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />

      <div style={{
        display: 'flex', flex: 1, minHeight: 0,
        border: '0.5px solid #BFDBFE', borderRadius: 10, overflow: 'hidden',
        background: 'var(--color-background-primary)',
        fontFamily: 'var(--font-sans)', fontSize: 13,
      }}>

        {/* ═══════════════════════════════════════════════════════════════════
            LEFT PANEL — permission sets list
        ═══════════════════════════════════════════════════════════════════ */}
        <div style={{
          width: 230, minWidth: 230, flexShrink: 0,
          borderRight: '0.5px solid #BFDBFE', background: '#EFF6FF',
          display: 'flex', flexDirection: 'column', overflowY: 'auto',
        }}>
          {/* Header with "+ New" button */}
          <div style={{
            padding: '8px 12px', background: '#DBEAFE',
            borderBottom: '0.5px solid #BFDBFE', flexShrink: 0,
            display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          }}>
            <span style={{ fontSize: 11, fontWeight: 500, color: '#1E40AF', textTransform: 'uppercase', letterSpacing: '.05em' }}>
              Permission Sets
            </span>
            {canEdit && (
              <button
                onClick={startCreating}
                title="Create new permission set"
                style={{
                  display: 'inline-flex', alignItems: 'center', gap: 4,
                  padding: '3px 9px', border: '0.5px solid #93C5FD',
                  borderRadius: 4, background: '#EFF6FF', color: '#1D4ED8',
                  fontSize: 11, fontWeight: 500, cursor: 'pointer',
                }}>
                <i className="fa-solid fa-plus" style={{ fontSize: 9 }} /> New
              </button>
            )}
          </div>

          {/* Inline create input */}
          {creatingNew && (
            <div style={{ padding: '8px 10px', background: '#DBEAFE', borderBottom: '0.5px solid #BFDBFE', flexShrink: 0 }}>
              <input
                ref={newSetInputRef}
                value={newSetName}
                onChange={e => setNewSetName(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter') confirmCreate(); if (e.key === 'Escape') cancelCreate(); }}
                placeholder="Set name…"
                style={{
                  width: '100%', padding: '5px 8px', fontSize: 12,
                  border: '0.5px solid #93C5FD', borderRadius: 4,
                  outline: 'none', marginBottom: 6,
                  background: 'var(--color-background-primary)',
                }}
              />
              <div style={{ display: 'flex', gap: 6 }}>
                <button onClick={confirmCreate} disabled={creatingSaving || !newSetName.trim()} style={{
                  flex: 1, padding: '4px 0', fontSize: 11, borderRadius: 4,
                  border: 'none', cursor: 'pointer',
                  background: creatingSaving || !newSetName.trim() ? '#9CA3AF' : '#1D4ED8',
                  color: '#fff', fontWeight: 500,
                }}>
                  {creatingSaving ? '…' : 'Create'}
                </button>
                <button onClick={cancelCreate} style={{
                  flex: 1, padding: '4px 0', fontSize: 11, borderRadius: 4,
                  border: '0.5px solid #D1D5DB', background: 'transparent',
                  color: '#6B7280', cursor: 'pointer',
                }}>
                  Cancel
                </button>
              </div>
            </div>
          )}

          {/* Sets list */}
          {sets.length === 0 && !creatingNew && (
            <div style={{ padding: '20px 14px', fontSize: 12, color: '#9CA3AF', textAlign: 'center' }}>
              No permission sets yet.<br />
              {canEdit && (
                <button onClick={startCreating} style={{ marginTop: 8, color: '#1D4ED8', background: 'none', border: 'none', cursor: 'pointer', fontSize: 12 }}>
                  + Create one
                </button>
              )}
            </div>
          )}

          {sets.map(set => {
            const active = selectedSet?.id === set.id;
            return (
              <div
                key={set.id}
                onClick={() => handleSelectSet(set)}
                style={{
                  padding: '9px 12px', cursor: 'pointer',
                  borderLeft: `3px solid ${active ? '#1D4ED8' : 'transparent'}`,
                  background: active ? '#DBEAFE' : 'transparent',
                  borderBottom: '0.5px solid #E0EEFF',
                }}
                onMouseEnter={e => { if (!active) (e.currentTarget as HTMLDivElement).style.background = '#E0EEFF'; }}
                onMouseLeave={e => { if (!active) (e.currentTarget as HTMLDivElement).style.background = 'transparent'; }}
              >
                {/* Set name */}
                <div style={{ fontSize: 13, fontWeight: active ? 600 : 400, color: active ? '#1D4ED8' : '#1e3a5f', marginBottom: 4, lineHeight: 1.2 }}>
                  {set.name}
                </div>
                {/* Role badge */}
                {set.roleName ? (
                  <span style={{
                    display: 'inline-block', fontSize: 10, padding: '1px 6px',
                    borderRadius: 10, background: '#D1FAE5', color: '#065F46',
                    fontWeight: 500, marginRight: 4,
                  }}>
                    {set.roleName}
                  </span>
                ) : (
                  <span style={{
                    display: 'inline-block', fontSize: 10, padding: '1px 6px',
                    borderRadius: 10, background: '#F3F4F6', color: '#9CA3AF',
                    fontWeight: 400,
                  }}>
                    Unassigned
                  </span>
                )}
                {/* Target group badge */}
                {set.tgLabel && (
                  <span style={{
                    display: 'inline-block', fontSize: 10, padding: '1px 6px',
                    borderRadius: 10, background: '#EDE9FE', color: '#5B21B6',
                    fontWeight: 500,
                  }}>
                    {set.tgLabel}
                  </span>
                )}
              </div>
            );
          })}
        </div>

        {/* ═══════════════════════════════════════════════════════════════════
            RIGHT PANEL
        ═══════════════════════════════════════════════════════════════════ */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, overflow: 'hidden' }}>

          {!selectedSet ? (
            <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 12, color: '#9CA3AF' }}>
              <i className="fa-solid fa-shield-halved" style={{ fontSize: 32, color: '#BFDBFE' }} />
              <p style={{ fontSize: 14 }}>Select a permission set to configure it</p>
            </div>
          ) : (
            <>
              {/* View-only banner */}
              {!canEdit && (
                <div style={{
                  padding: '6px 16px', background: '#FEF3C7', borderBottom: '0.5px solid #FDE68A',
                  display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0,
                }}>
                  <i className="fa-solid fa-eye" style={{ fontSize: 12, color: '#92400E' }} />
                  <span style={{ fontSize: 12, color: '#92400E', fontWeight: 500 }}>
                    View only — you don't have edit access to the Permission Matrix
                  </span>
                </div>
              )}

              {/* Header */}
              <div style={{ padding: '10px 16px 0', borderBottom: '0.5px solid #BFDBFE', flexShrink: 0 }}>
                {/* Name row */}
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
                  <input
                    value={editName}
                    onChange={e => { if (canEdit) { setEditName(e.target.value); setDirty(true); } }}
                    readOnly={!canEdit}
                    placeholder="Permission set name…"
                    style={{
                      fontSize: 15, fontWeight: 600,
                      color: 'var(--color-text-primary)',
                      border: 'none', borderBottom: canEdit ? '1.5px solid #BFDBFE' : 'none',
                      outline: 'none', background: 'transparent',
                      padding: '2px 4px', minWidth: 0, flex: 1,
                      fontFamily: 'inherit', cursor: canEdit ? 'text' : 'default',
                    }}
                    onFocus={e => { if (canEdit) e.target.style.borderBottomColor = '#1D4ED8'; }}
                    onBlur={e  => { if (canEdit) e.target.style.borderBottomColor = '#BFDBFE'; }}
                  />
                  {loadingItems && <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 12, color: '#93C5FD' }} />}
                  {selectedSet.roleName && (
                    <span style={{ fontSize: 10, padding: '2px 8px', borderRadius: 10, background: '#D1FAE5', color: '#065F46', fontWeight: 500, flexShrink: 0 }}>
                      → {selectedSet.roleName}
                    </span>
                  )}
                </div>
                {/* Editable description row */}
                <input
                  value={editDesc}
                  onChange={e => { if (canEdit) { setEditDesc(e.target.value); setDirty(true); } }}
                  readOnly={!canEdit}
                  placeholder={canEdit ? 'Add a description…' : ''}
                  style={{
                    width: '100%', fontSize: 12,
                    color: '#6B7280',
                    border: 'none', borderBottom: canEdit ? '1px solid transparent' : 'none',
                    outline: 'none', background: 'transparent',
                    padding: '2px 4px', marginBottom: 6,
                    fontFamily: 'inherit', boxSizing: 'border-box',
                    cursor: canEdit ? 'text' : 'default',
                  }}
                  onFocus={e => { if (canEdit) e.target.style.borderBottomColor = '#BFDBFE'; }}
                  onBlur={e  => { if (canEdit) e.target.style.borderBottomColor = 'transparent'; }}
                />
                <div style={{ display: 'flex', marginTop: 4 }}>
                  {(['permissions', 'assignments'] as const).map(tab => (
                    <button key={tab} onClick={() => setActiveTab(tab)} style={{
                      padding: '6px 16px', fontSize: 13, cursor: 'pointer',
                      border: 'none', background: 'transparent',
                      borderBottom: `2px solid ${activeTab === tab ? '#1D4ED8' : 'transparent'}`,
                      color: activeTab === tab ? '#1D4ED8' : '#6B7280',
                      fontWeight: activeTab === tab ? 500 : 400,
                    }}>
                      {tab === 'permissions' ? 'Permissions' : 'Assignments'}
                    </button>
                  ))}
                </div>
              </div>

              {/* ── Permissions tab ── */}
              {activeTab === 'permissions' && (
                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0, overflow: 'hidden' }}>

                  {/* Fixed column header */}
                  <table style={{ width: '100%', borderCollapse: 'separate', borderSpacing: 0, tableLayout: 'fixed', flexShrink: 0 }}>
                    <colgroup>
                      <col style={{ width: 210 }} />
                      {ACTIONS.map(a => <col key={a} style={{ width: 70 }} />)}
                    </colgroup>
                    <thead>
                      <tr>
                        <th style={{ ...thStyle, textAlign: 'left', paddingLeft: 14 }}>Module / Feature</th>
                        {ACTIONS.map(a => (
                          <th key={a} style={thStyle}>
                            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 4 }}>
                              {ACTION_LABELS[a]}
                              <span
                                title={ACTION_HINTS[a]}
                                style={{
                                  display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                                  width: 13, height: 13, borderRadius: '50%',
                                  background: 'rgba(255,255,255,0.25)', color: '#fff',
                                  fontSize: 9, fontWeight: 700, cursor: 'help',
                                  flexShrink: 0, lineHeight: 1,
                                }}
                              >i</span>
                            </div>
                          </th>
                        ))}
                      </tr>
                    </thead>
                  </table>

                  {/* Scrollable body */}
                  <div style={{ flex: 1, overflowY: 'auto' }}>
                    <table style={{ width: '100%', borderCollapse: 'separate', borderSpacing: 0, tableLayout: 'fixed' }}>
                      <colgroup>
                        <col style={{ width: 210 }} />
                        {ACTIONS.map(a => <col key={a} style={{ width: 70 }} />)}
                      </colgroup>
                      <tbody>
                        <SectionHeader label="Employee view related" />
                        {EV_GROUPS.map(grp => (
                          <React.Fragment key={grp.groupLabel}>
                            <SubHeader label={grp.groupLabel} />
                            {grp.rows.map(row => <MatrixRow key={row.code} row={row} />)}
                          </React.Fragment>
                        ))}

                        {/* ── 2.2 Org Chart — standalone feature toggle ── */}
                        <SubHeader label="Org Chart" />
                        <tr style={{ borderBottom: '0.5px solid #EDEFF2' }}
                          onMouseEnter={e => (e.currentTarget.style.background = '#F8FAFF')}
                          onMouseLeave={e => (e.currentTarget.style.background = '')}>
                          <td style={{ paddingLeft: 26, paddingTop: 10, paddingBottom: 10, textAlign: 'left', fontSize: 13, color: '#374151', verticalAlign: 'middle' }}>
                            Org Chart
                            <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2 }}>
                              Feature toggle — View only, no target group required
                            </div>
                          </td>
                          <td colSpan={5} style={{ padding: '8px 16px', verticalAlign: 'middle' }}>
                            <Toggle moduleCode="org_chart" disabled={!canEdit} />
                          </td>
                        </tr>

                        {/* ── 2.3 Employee Workflow — standalone feature toggles ── */}
                        {EV_TOGGLE_GROUPS.map(evtg => (
                          <React.Fragment key={evtg.groupLabel}>
                            <SubHeader label={evtg.groupLabel} />
                            {evtg.items.map(item => (
                              <tr key={item.code}
                                style={{ borderBottom: '0.5px solid #EDEFF2' }}
                                onMouseEnter={e => (e.currentTarget.style.background = '#F8FAFF')}
                                onMouseLeave={e => (e.currentTarget.style.background = '')}>
                                <td style={{ paddingLeft: 26, paddingTop: 10, paddingBottom: 10, textAlign: 'left', fontSize: 13, color: '#374151', verticalAlign: 'middle' }}>
                                  {item.label}
                                  <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2 }}>
                                    {evtg.hint}
                                  </div>
                                </td>
                                <td colSpan={5} style={{ padding: '8px 16px', verticalAlign: 'middle' }}>
                                  <Toggle moduleCode={item.code} disabled={!canEdit} />
                                </td>
                              </tr>
                            ))}
                          </React.Fragment>
                        ))}

                        {/* ── Reference Lookups — driven from DB, no hardcoding ── */}
                        {lookupPerms.length > 0 && (
                          <>
                            <SubHeader label="Reference Lookups" />
                            <tr>
                              <td colSpan={6} style={{ padding: '4px 26px 6px', fontSize: 11, color: '#9CA3AF' }}>
                                Controls which reference dropdowns this permission set can populate in transactional forms.
                                Uses the <code style={{ background: '#F1F5F9', padding: '1px 4px', borderRadius: 3 }}>lookup</code> action — separate from management permissions.
                              </td>
                            </tr>
                            {lookupPerms.map(perm => (
                              <tr key={perm.id}
                                style={{ borderBottom: '0.5px solid #EDEFF2' }}
                                onMouseEnter={e => (e.currentTarget.style.background = '#F0FDFF')}
                                onMouseLeave={e => (e.currentTarget.style.background = '')}>
                                <td style={{ paddingLeft: 26, paddingTop: 10, paddingBottom: 10, textAlign: 'left', fontSize: 13, color: '#374151', verticalAlign: 'middle' }}>
                                  {perm.label}
                                  <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2 }}>
                                    {perm.code}
                                  </div>
                                </td>
                                <td colSpan={5} style={{ padding: '6px 16px', verticalAlign: 'middle' }}>
                                  <LookupToggle permissionId={perm.id} disabled={!canEdit} />
                                </td>
                              </tr>
                            ))}
                          </>
                        )}

                        <SectionHeader label="Admin related" amber />
                        {ADMIN_GROUPS.map(grp => (
                          <React.Fragment key={grp.groupLabel}>
                            <SubHeader label={grp.groupLabel} />
                            {grp.rows.map(row => <MatrixRow key={row.code} row={row} />)}
                          </React.Fragment>
                        ))}

                        {/* ── Admin Access — top-level gate, rendered above Security group ── */}
                        <SubHeader label="Admin Access" />
                        <tr style={{ borderBottom: '0.5px solid #EDEFF2' }}
                          onMouseEnter={e => (e.currentTarget.style.background = '#F8FAFF')}
                          onMouseLeave={e => (e.currentTarget.style.background = '')}>
                          <td style={{ paddingLeft: 26, paddingTop: 9, paddingBottom: 9, textAlign: 'left', fontSize: 13, color: '#374151', verticalAlign: 'middle' }}>
                            Admin access
                            <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2, fontWeight: 400 }}>
                              {SEC_ADMIN_ACCESS_HINT}
                            </div>
                          </td>
                          <td colSpan={5} style={{ padding: '6px 16px', verticalAlign: 'middle' }}>
                            <Toggle moduleCode="sec_admin_access" disabled={!canEdit} />
                          </td>
                        </tr>

                        {TOGGLE_GROUPS.map(tg => <ToggleGroupRows key={tg.groupLabel} tg={tg} />)}

                        <SubHeader label="Reports" />
                        <tr>
                          <td colSpan={6} style={{ padding: '8px 14px 8px 26px' }}>
                            <button onClick={() => setReportsOpen(o => !o)} style={{
                              display: 'inline-flex', alignItems: 'center', gap: 5,
                              padding: '3px 10px', border: '0.5px dashed #93C5FD',
                              borderRadius: 4, background: '#EFF6FF', color: '#1D4ED8',
                              fontSize: 11, cursor: 'pointer',
                            }}>
                              <i className={`fa-solid fa-chevron-${reportsOpen ? 'down' : 'right'}`} style={{ fontSize: 10 }} />
                              {reportsOpen ? 'Hide reports' : '+ Add reports'}
                            </button>
                          </td>
                        </tr>
                        {reportsOpen && allPerms.filter(p => p.code.startsWith(REPORTS_CODE + '.')).map(p => (
                          <tr key={p.id} style={{ borderBottom: '0.5px solid #F1F5F9' }}>
                            <td colSpan={6} style={{ padding: '5px 14px 5px 36px' }}>
                              <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: canEdit ? 'pointer' : 'default', fontSize: 12, color: '#4B5563', opacity: canEdit ? 1 : 0.6 }}>
                                <input type="checkbox" checked={grantedIds.has(p.id)}
                                  onChange={() => {
                                    if (!canEdit) return;
                                    setGrantedIds(prev => { const n = new Set(prev); n.has(p.id) ? n.delete(p.id) : n.add(p.id); return n; });
                                    setDirty(true);
                                  }}
                                  disabled={!canEdit}
                                  style={{ width: 14, height: 14, accentColor: '#1D4ED8', cursor: canEdit ? 'pointer' : 'not-allowed' }} />
                                {p.code.endsWith('.view') ? 'Access reports' : 'Generate & export reports'}
                              </label>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}

              {/* ── Assignments tab ── */}
              {activeTab === 'assignments' && (
                <div style={{ flex: 1, overflow: 'auto', padding: 20, display: 'flex', flexDirection: 'column', gap: 16 }}>

                  {/* Card 1 — Grant access to (role selector) */}
                  <div style={cardStyle}>
                    <div style={cardHeaderStyle}>
                      <div style={cardIconStyle}><i className="fa-solid fa-user-shield" style={{ fontSize: 11, color: '#1D4ED8' }} /></div>
                      <span style={cardTitleStyle}>Grant access to</span>
                    </div>
                    <div style={{ padding: 16 }}>
                      <p style={{ fontSize: 12, color: '#6B7280', marginBottom: 12 }}>
                        Assign this permission set to a role. All users with that role will receive these permissions.
                      </p>
                      <select
                        value={assignRoleId ?? ''}
                        onChange={e => {
                          if (!canEdit) return;
                          setAssignRoleId(e.target.value || null);
                          setAssignTgCode(null);
                          setCustomTgId(null);
                          setShowTgPicker(false);
                          setDirty(true);
                        }}
                        disabled={!canEdit}
                        style={{
                          width: '100%', padding: '7px 10px', fontSize: 13,
                          border: '0.5px solid #BFDBFE', borderRadius: 6,
                          background: 'var(--color-background-primary)', color: '#1e3a5f',
                          appearance: 'auto', cursor: canEdit ? 'pointer' : 'not-allowed', outline: 'none',
                          opacity: canEdit ? 1 : 0.6,
                        }}
                      >
                        <option value="">— No role assigned —</option>
                        {roles.map(r => (
                          <option key={r.id} value={r.id}>{r.name}</option>
                        ))}
                      </select>

                      {assignedRole && (
                        <div style={{
                          marginTop: 10, display: 'flex', alignItems: 'center', gap: 8,
                          padding: '7px 12px', background: '#EFF6FF', borderRadius: 6,
                          border: '0.5px solid #BFDBFE', fontSize: 12,
                        }}>
                          <i className="fa-solid fa-circle-check" style={{ color: '#1D4ED8' }} />
                          <span style={{ color: '#1E40AF' }}>
                            Assigned to <strong>{assignedRole.name}</strong>
                          </span>
                          <span style={{
                            marginLeft: 'auto', fontSize: 10, padding: '2px 7px', borderRadius: 10,
                            background: ROLE_CAT_INFO[roleCat].bg, color: ROLE_CAT_INFO[roleCat].color, fontWeight: 500,
                          }}>
                            {ROLE_CAT_INFO[roleCat].badge}
                          </span>
                        </div>
                      )}
                    </div>
                  </div>

                  {/* Card 2 — Define target population */}
                  <div style={cardStyle}>
                    <div style={cardHeaderStyle}>
                      <div style={cardIconStyle}><i className="fa-solid fa-bullseye" style={{ fontSize: 11, color: '#1D4ED8' }} /></div>
                      <span style={cardTitleStyle}>Define target population</span>
                    </div>
                    <div style={{ padding: 16 }}>
                      {!assignRoleId ? (
                        <p style={{ fontSize: 12, color: '#9CA3AF', fontStyle: 'italic' }}>
                          Select a role above to configure the target population.
                        </p>
                      ) : (
                        <>
                          <p style={{ fontSize: 12, color: '#6B7280', marginBottom: 14 }}>
                            Select which employees this permission set applies to for <strong>{assignedRole?.name}</strong>.
                          </p>
                          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
                            {tpOptions.map(chip => {
                              const isSel = chip.tgCode !== null && assignTgCode === chip.tgCode;
                              return (
                                <button key={chip.label} onClick={() => {
                                  if (!canEdit) return;
                                  if (chip.special) { setShowTgPicker(v => !v); }
                                  else { setAssignTgCode(chip.tgCode); setCustomTgId(null); setShowTgPicker(false); }
                                  setDirty(true);
                                }} disabled={!canEdit} style={{
                                  padding: '5px 14px', borderRadius: 20, fontSize: 12,
                                  cursor: canEdit ? 'pointer' : 'not-allowed', fontWeight: 500, transition: 'all .15s',
                                  border: isSel ? '1.5px solid #1D4ED8' : chip.special ? '1px solid #FDE68A' : '1.5px solid #93C5FD',
                                  background: isSel ? '#1D4ED8' : chip.special ? '#FEF9C3' : '#DBEAFE',
                                  color: isSel ? '#fff' : chip.special ? '#92400E' : '#1E40AF',
                                  opacity: canEdit ? 1 : 0.6,
                                }}>
                                  {chip.label}
                                </button>
                              );
                            })}
                          </div>

                          {showTgPicker && (
                            <div style={{ marginTop: 14 }}>
                              <p style={{ fontSize: 11, color: '#6B7280', marginBottom: 6 }}>Custom groups:</p>
                              {customTgs.length === 0
                                ? <p style={{ fontSize: 12, color: '#9CA3AF', fontStyle: 'italic' }}>No custom groups. Create one in Target Groups first.</p>
                                : (
                                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                                    {customTgs.map(tg => (
                                      <button key={tg.id} onClick={() => { if (!canEdit) return; setCustomTgId(tg.id); setAssignTgCode(null); setDirty(true); }}
                                        disabled={!canEdit} style={{
                                        padding: '4px 12px', borderRadius: 20, fontSize: 12,
                                        cursor: canEdit ? 'pointer' : 'not-allowed',
                                        border: customTgId === tg.id ? '1px solid #1D4ED8' : '1px solid #BFDBFE',
                                        background: customTgId === tg.id ? '#DBEAFE' : 'var(--color-background-primary)',
                                        color: customTgId === tg.id ? '#1E40AF' : '#374151',
                                        fontWeight: customTgId === tg.id ? 500 : 400,
                                        opacity: canEdit ? 1 : 0.6,
                                      }}>
                                        {tg.label}
                                      </button>
                                    ))}
                                  </div>
                                )}
                            </div>
                          )}

                          {/* Current selection summary */}
                          {(assignTgCode || customTgId) ? (
                            <div style={{
                              marginTop: 16, padding: '10px 14px',
                              background: '#EFF6FF', borderRadius: 8,
                              border: '0.5px solid #BFDBFE',
                              fontSize: 12, color: '#1E40AF',
                              display: 'flex', alignItems: 'center', gap: 8,
                            }}>
                              <i className="fa-solid fa-circle-check" style={{ color: '#1D4ED8' }} />
                              <span>
                                Target group:{' '}
                                <strong>
                                  {assignTgCode
                                    ? (targetGroups.find(tg => tg.code === assignTgCode)?.label ?? assignTgCode)
                                    : (targetGroups.find(tg => tg.id === customTgId)?.label ?? 'Custom group')}
                                </strong>
                              </span>
                            </div>
                          ) : (
                            <div style={{
                              marginTop: 16, padding: '10px 14px',
                              background: '#FFFBEB', borderRadius: 8,
                              border: '0.5px solid #FDE68A',
                              fontSize: 12, color: '#92400E',
                              display: 'flex', alignItems: 'center', gap: 8,
                            }}>
                              <i className="fa-solid fa-triangle-exclamation" style={{ color: '#D97706' }} />
                              <span>No target group selected. Permissions will apply with no population scope.</span>
                            </div>
                          )}
                        </>
                      )}
                    </div>
                  </div>
                </div>
              )}

              {/* Footer — hidden in view-only mode */}
              {canEdit && (
                <div style={{
                  padding: '10px 16px', borderTop: '0.5px solid #BFDBFE',
                  background: '#F8FAFF', display: 'flex', alignItems: 'center', gap: 10, flexShrink: 0,
                }}>
                  <button onClick={handleSave} disabled={saving}
                    style={{
                      padding: '6px 18px', fontSize: 13, borderRadius: 6,
                      border: 'none', cursor: saving ? 'not-allowed' : 'pointer',
                      background: saving ? '#9CA3AF' : '#1D4ED8',
                      color: '#fff', fontWeight: 500,
                    }}>
                    {saving ? 'Saving…' : 'Save'}
                  </button>
                  <button onClick={handleDiscard} disabled={saving}
                    style={{
                      padding: '6px 14px', fontSize: 13, borderRadius: 6,
                      border: '0.5px solid #D1D5DB', background: 'transparent',
                      color: '#6B7280', cursor: 'pointer',
                    }}>
                    Discard
                  </button>
                  {dirty && (
                    <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 6 }}>
                      <span style={{ width: 7, height: 7, background: '#F59E0B', borderRadius: '50%', display: 'inline-block' }} />
                      <span style={{ fontSize: 12, color: '#92400E' }}>Unsaved changes</span>
                    </span>
                  )}
                </div>
              )}
            </>
          )}
        </div>

      </div>
    </div>
  );
}

// ─── Shared styles ────────────────────────────────────────────────────────────

const thStyle: React.CSSProperties = {
  position: 'sticky', top: 0, zIndex: 5,
  background: '#1D4ED8', color: '#fff',
  padding: '7px 6px', fontSize: 11, fontWeight: 500,
  textAlign: 'center', borderRight: '0.5px solid #3B6ED4',
};
const tdStyle: React.CSSProperties = {
  padding: '5px 6px', textAlign: 'center', verticalAlign: 'middle',
};
const cardStyle: React.CSSProperties = {
  border: '0.5px solid #BFDBFE', borderRadius: 8, overflow: 'hidden',
};
const cardHeaderStyle: React.CSSProperties = {
  background: '#EFF6FF', padding: '10px 14px',
  display: 'flex', alignItems: 'center', gap: 8,
  borderBottom: '0.5px solid #BFDBFE',
};
const cardIconStyle: React.CSSProperties = {
  width: 20, height: 20, borderRadius: 4, background: '#DBEAFE',
  display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
};
const cardTitleStyle: React.CSSProperties = {
  fontSize: 12, fontWeight: 500, color: '#1D4ED8',
  textTransform: 'uppercase', letterSpacing: '.04em',
};
