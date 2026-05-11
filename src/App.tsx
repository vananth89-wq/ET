/**
 * App.tsx — root layout and routing
 *
 * Key architectural decisions:
 *
 *  - AppShell mounts ONCE and persists across all authenticated routes.
 *    Only the <Outlet /> content area changes on navigation — no full teardown.
 *
 *  - Sidebar navigation items are permission-gated via can() from usePermissions.
 *    Never check role names directly in layout code.
 *
 *  - Route guards use <ProtectedRoute requiredPermission="..."> (new system).
 *    The legacy requiredRoles prop is still supported during the transition.
 *
 *  - NAV_ITEMS config drives the admin sidebar declaratively.
 *    Adding a new admin page = add one entry to the array. No scattered if-blocks.
 */

import { useRef, useState, useEffect }                            from 'react';
import { Routes, Route, Navigate, NavLink, Outlet,
         useLocation, useNavigate }                               from 'react-router-dom';
import { useAuth }                                                from './contexts/AuthContext';
import { usePermissions }                                         from './hooks/usePermissions';
import ProtectedRoute                                             from './components/auth/ProtectedRoute';
import LoginPage                                                  from './components/auth/LoginPage';
import ResetPasswordPage                                          from './components/auth/ResetPasswordPage';
import MyReports                                                  from './components/employee/MyReports';
import MyProfile                                                  from './components/employee/MyProfile';
import ReportDetail                                               from './components/employee/ReportDetail';
import AdminReports                                               from './components/admin/AdminReports';
import ExchangeRates                                              from './components/admin/ExchangeRates';
import Projects                                                   from './components/admin/Projects';
import Departments                                                from './components/admin/Departments';
import OrgChartAdmin                                              from './components/admin/OrgChart';
import ReferenceData                                              from './components/admin/ReferenceData';
import EmployeeDetails                                            from './components/admin/EmployeeDetails';
import InactiveEmployees                                          from './components/admin/InactiveEmployees';
import AddEmployee                                                from './components/admin/AddEmployee';
import EmpOrgChart                                                from './components/employee/EmpOrgChart';
import ApproverInbox                                             from './workflow/screens/ApproverInbox';
import WorkflowReview                                           from './workflow/screens/WorkflowReview';
import WorkflowMyRequests                                        from './workflow/screens/WorkflowMyRequests';
import WorkflowTemplates                                         from './workflow/screens/WorkflowTemplates';
import WorkflowDelegations                                       from './workflow/screens/WorkflowDelegations';
import WorkflowAssignments                                       from './workflow/screens/WorkflowAssignments';
import WorkflowPerformanceDashboard                              from './workflow/screens/WorkflowPerformanceDashboard';
import WorkflowOperations                                        from './workflow/screens/WorkflowOperations';
import WorkflowAnalytics                                         from './workflow/screens/WorkflowAnalytics';
import NotificationMonitor                                       from './workflow/screens/NotificationMonitor';
import NotificationConfig                                        from './workflow/screens/NotificationConfig';
import JobsAdmin                                                 from './admin/screens/JobsAdmin';
import ExpenseAnalytics                                          from './components/admin/analytics/ExpenseAnalytics';
import PermissionCatalog                                          from './components/admin/permissions/PermissionCatalog';
import RoleAssignments                                            from './components/admin/permissions/RoleAssignments';
import RbpTroubleshoot                                            from './components/admin/permissions/RbpTroubleshoot';
import TargetGroups                                               from './components/admin/permissions/TargetGroups';
import PermissionMatrix                                           from './components/admin/permissions/PermissionMatrix';
import ComingSoon                                                 from './components/shared/ComingSoon';
import NotificationBell                                           from './components/shared/NotificationBell';
import { ErrorBoundary }                                          from './components/shared/ErrorBoundary';
import { usePicklistValues }                                      from './hooks/usePicklistValues';
import { supabase }                                               from './lib/supabase';

// ─── Admin sidebar navigation config ─────────────────────────────────────────
//
// Each entry declares the route path, label, icon, and the permission code
// required to see the item. Adding a new admin page only requires adding one
// entry here — no scattered if/can() blocks elsewhere in the sidebar.
//
// Groups: items with the same `group` value are rendered inside a SidebarGroup
// collapsible section. Items without a group are rendered at the top level.

interface NavItem {
  path:       string;
  label:      string;
  icon:       string;
  permission: string;        // permission code from the permissions table
  group?:     string;        // collapsible group label (optional)
  groupIcon?: string;        // icon for the group header
}

const ADMIN_NAV: NavItem[] = [
  // ── Employees group ──────────────────────────────────────────────────────
  { group: 'Employees',    groupIcon: 'fa-users',
    path: '/admin/emp-org-chart',     label: 'Org Chart',         icon: 'fa-diagram-project', permission: 'org_chart.view'              },
  { group: 'Employees',    groupIcon: 'fa-users',
    path: '/admin/employee-details',  label: 'Employee Details',  icon: 'fa-table-list',      permission: 'employee_details.edit'       },
  { group: 'Employees',    groupIcon: 'fa-users',
    path: '/admin/inactive-employees', label: 'Inactive Employees', icon: 'fa-user-slash',    permission: 'inactive_employees.view'     },
  { group: 'Employees',    groupIcon: 'fa-users',
    path: '/admin/add-employee',      label: 'Add New Employee',  icon: 'fa-user-plus',       permission: 'hire_employee.create'        },

  // ── Organization group ───────────────────────────────────────────────────
  { group: 'Organization', groupIcon: 'fa-sitemap',
    path: '/admin/departments',       label: 'Departments',       icon: 'fa-sitemap',         permission: 'departments.edit'            },
  { group: 'Organization', groupIcon: 'fa-sitemap',
    path: '/admin/org-chart',         label: 'Org Chart',         icon: 'fa-diagram-project', permission: 'org_chart.view'              },

  // ── Top-level items ───────────────────────────────────────────────────────
  { path: '/admin/projects',          label: 'Projects',          icon: 'fa-folder',             permission: 'projects_mgmt.view'       },
{ path: '/admin/reference-data',    label: 'Reference Data',    icon: 'fa-list',               permission: 'picklists.view'           },
  { path: '/admin/exchange-rates',    label: 'Exchange Rates',    icon: 'fa-arrow-right-arrow-left', permission: 'exchange_rates_mgmt.view' },
  { path: '/admin/reports',           label: 'Reports',           icon: 'fa-file-chart-column',  permission: 'reports_admin.view'       },

  // ── Workflow group ────────────────────────────────────────────────────────
  { group: 'Workflow',     groupIcon: 'fa-diagram-next',
    path: '/admin/workflow/operations',          label: 'Manage Workflow',            icon: 'fa-gauge-high',        permission: 'wf_manage.view'               },
  { group: 'Workflow',     groupIcon: 'fa-diagram-next',
    path: '/admin/workflow/templates',           label: 'Manage Workflow Templates',  icon: 'fa-layer-group',       permission: 'wf_templates.view'            },
  { group: 'Workflow',     groupIcon: 'fa-diagram-next',
    path: '/admin/workflow/notification-config', label: 'Manage Notifications',       icon: 'fa-bell-slash',        permission: 'wf_notification_config.view'  },
  { group: 'Workflow',     groupIcon: 'fa-diagram-next',
    path: '/admin/workflow/delegations',         label: 'Manage Delegations',         icon: 'fa-right-left',        permission: 'wf_delegations.view'          },
  { group: 'Workflow',     groupIcon: 'fa-diagram-next',
    path: '/admin/workflow/assignments',         label: 'Manage Assignments',         icon: 'fa-network-wired',     permission: 'wf_assignments.view'          },
  { group: 'Workflow',     groupIcon: 'fa-diagram-next',
    path: '/admin/workflow/performance',         label: 'Performance',                icon: 'fa-chart-line',        permission: 'wf_performance.view'          },
  { group: 'Workflow',     groupIcon: 'fa-diagram-next',
    path: '/admin/workflow/analytics',           label: 'Analytics',                  icon: 'fa-chart-bar',         permission: 'wf_analytics.view'            },
  { group: 'Workflow',     groupIcon: 'fa-diagram-next',
    path: '/admin/workflow/notifications',       label: 'Notification Monitor',       icon: 'fa-bell',              permission: 'wf_notifications.view'        },
  // ── Jobs group ───────────────────────────────────────────────────────────
  { group: 'Jobs',         groupIcon: 'fa-gears',
    path: '/admin/jobs',                    label: 'Background Jobs',      icon: 'fa-clock-rotate-left', permission: 'jobs_manage.view'        },

  // ── Security group ────────────────────────────────────────────────────────
  { group: 'Security',     groupIcon: 'fa-lock',
    path: '/admin/permissions/matrix',      label: 'Permission Matrix',    icon: 'fa-table-cells',       permission: 'sec_permission_matrix.view' },
  { group: 'Security',     groupIcon: 'fa-lock',
    path: '/admin/permissions/assignments', label: 'Role Assignments',     icon: 'fa-users-gear',        permission: 'sec_role_assignments.view' },
  { group: 'Security',     groupIcon: 'fa-lock',
    path: '/admin/permissions/target-groups', label: 'Target Groups',      icon: 'fa-people-group',      permission: 'sec_target_groups.view'   },
  { group: 'Security',     groupIcon: 'fa-lock',
    path: '/admin/permissions/catalog',     label: 'Permission Catalog',   icon: 'fa-key',               permission: 'sec_permission_catalog.view' },
  { group: 'Security',     groupIcon: 'fa-lock',
    path: '/admin/permissions/rbp',         label: 'RBP Troubleshooting',  icon: 'fa-magnifying-glass-chart', permission: 'sec_rbp_troubleshoot.view' },
];

// ─── SidebarProfileCard ───────────────────────────────────────────────────────

function SidebarProfileCard() {
  const { employee, refetchProfile }     = useAuth();
  const { picklistValues: picklistVals } = usePicklistValues();
  const fileRef                          = useRef<HTMLInputElement>(null);
  const [localPhoto, setLocalPhoto]      = useState<string | null>(null);

  const displayName = employee?.name || 'Employee';

  // Resolve designation label from Supabase picklist values
  const rawDesignation   = employee?.designation as string | null | undefined;
  const designationLabel = (() => {
    if (!rawDesignation) return null;
    const match = picklistVals.find(v =>
      v.picklistId === 'DESIGNATION' &&
      (v.id === rawDesignation || v.refId === rawDesignation || v.value === rawDesignation),
    );
    return match ? match.value : rawDesignation;
  })();

  const email  = (employee?.businessEmail as string | null) || null;
  const mobile = (employee?.mobile        as string | null) || null;
  const photo  = localPhoto
    || (employee?.photo as string | null)
    || `https://ui-avatars.com/api/?name=${encodeURIComponent(displayName)}&background=2F77B5&color=fff&size=80`;

  async function handlePhotoUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file || !employee?.id) return;
    e.target.value = '';

    if (!file.type.startsWith('image/') || file.size > 5 * 1024 * 1024) return;

    try {
      const ext  = file.name.split('.').pop() ?? 'jpg';
      const path = `employees/${employee.id}/avatar.${ext}`;

      const { error: upErr } = await supabase.storage
        .from('avatars')
        .upload(path, file, { contentType: file.type, upsert: true });
      if (upErr) throw upErr;

      const { data: urlData } = supabase.storage.from('avatars').getPublicUrl(path);
      const publicUrl = urlData.publicUrl + `?t=${Date.now()}`;

      const { error: dbErr } = await supabase
        .from('employee_personal')
        .upsert({ employee_id: employee.id, photo_url: publicUrl }, { onConflict: 'employee_id' });
      if (dbErr) throw dbErr;

      setLocalPhoto(publicUrl);
      refetchProfile();
    } catch (err) {
      console.error('[SidebarProfileCard] Photo upload failed:', err);
    }
  }

  return (
    <div className="profile-card">
      <div className="profile-photo-wrapper">
        <img className="profile-photo" src={photo} alt={displayName} />
        <div className="photo-overlay" title="Change photo" onClick={() => fileRef.current?.click()}>
          <i className="fa-solid fa-camera" />
        </div>
        <input ref={fileRef} type="file" accept="image/*" hidden onChange={handlePhotoUpload} />
      </div>
      <div className="profile-info">
        <div className="profile-name">{displayName}</div>
        <div className="profile-designation">{designationLabel || '—'}</div>
        <div className="profile-email"><i className="fa-solid fa-envelope" />{email  || '—'}</div>
        <div className="profile-mobile"><i className="fa-solid fa-phone"   />{mobile || '—'}</div>
      </div>
    </div>
  );
}

// ─── UserMenu ─────────────────────────────────────────────────────────────────

function UserMenu() {
  const navigate = useNavigate();
  const loc      = useLocation();
  const { signOut, user }   = useAuth();
  const { canAny }          = usePermissions();
  const [open,    setOpen]  = useState(false);
  const menuRef             = useRef<HTMLDivElement>(null);
  const isAdminPath         = loc.pathname.startsWith('/admin');

  // Change-password modal state
  const [showPwd,   setShowPwd]   = useState(false);
  const [pwdNext,   setPwdNext]   = useState('');
  const [pwdConf,   setPwdConf]   = useState('');
  const [pwdSaving, setPwdSaving] = useState(false);
  const [pwdErr,    setPwdErr]    = useState<string | null>(null);
  const [pwdOk,     setPwdOk]     = useState(false);

  // A user can access the admin section if they hold the dedicated portal gate.
  const canAccessAdmin = canAny(['sec_admin_access.view']);

  // Close dropdown when clicking outside
  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, []);

  async function handleSignOut() {
    setOpen(false);
    await signOut();
    navigate('/login', { replace: true });
  }

  function openChangePwd() {
    setOpen(false);
    setPwdNext(''); setPwdConf(''); setPwdErr(null); setPwdOk(false);
    setShowPwd(true);
  }

  async function handleChangePwd() {
    if (!pwdNext.trim())          { setPwdErr('Please enter a new password.');    return; }
    if (pwdNext.length < 8)       { setPwdErr('Password must be ≥ 8 characters.'); return; }
    if (pwdNext !== pwdConf)      { setPwdErr('Passwords do not match.');          return; }
    setPwdSaving(true); setPwdErr(null);
    try {
      const { error } = await supabase.auth.updateUser({ password: pwdNext });
      if (error) throw error;
      setPwdOk(true);
      setTimeout(() => setShowPwd(false), 2000);
    } catch (e: unknown) {
      setPwdErr(e instanceof Error ? e.message : 'Could not update password.');
    } finally {
      setPwdSaving(false);
    }
  }

  if (!user) return null;

  const initials = (user.email ?? '?').split('@')[0].slice(0, 2).toUpperCase();

  const inputSt: React.CSSProperties = {
    width: '100%', padding: '8px 10px', borderRadius: 6,
    border: '1px solid #D1D5DB', fontSize: 13, outline: 'none',
    boxSizing: 'border-box', marginTop: 4,
  };

  return (
    <>
      <div className="user-menu-wrap" ref={menuRef}>
        {/* Trigger */}
        <button
          type="button"
          className={`user-menu-trigger ${open ? 'open' : ''}`}
          onClick={() => setOpen(o => !o)}
        >
          <span className="user-avatar">{initials}</span>
          <span className="user-menu-email">{user.email}</span>
          <i className={`fa-solid fa-chevron-${open ? 'up' : 'down'} user-menu-chevron`} />
        </button>

        {/* Dropdown */}
        {open && (
          <div className="user-menu-dropdown">
            {/* User info */}
            <div className="user-menu-info">
              <span className="user-avatar user-avatar-lg">{initials}</span>
              <div>
                <div className="user-menu-name">{user.email?.split('@')[0]}</div>
                <div className="user-menu-email-full">{user.email}</div>
              </div>
            </div>

            <div className="user-menu-divider" />

            {/* Admin ↔ Employee view switch */}
            {canAccessAdmin && (
              <>
                {isAdminPath ? (
                  <button type="button" className="user-menu-item"
                    onClick={() => { setOpen(false); navigate('/profile'); }}>
                    <i className="fa-solid fa-arrow-left" /> Employee View
                  </button>
                ) : (
                  <button type="button" className="user-menu-item"
                    onClick={() => { setOpen(false); navigate('/admin/employee-details'); }}>
                    <i className="fa-solid fa-shield-halved" /> Admin View
                  </button>
                )}
                <div className="user-menu-divider" />
              </>
            )}

            {/* Change Password */}
            <button type="button" className="user-menu-item" onClick={openChangePwd}>
              <i className="fa-solid fa-key" /> Change Password
            </button>

            <div className="user-menu-divider" />

            <button type="button" className="user-menu-item user-menu-item-danger" onClick={handleSignOut}>
              <i className="fa-solid fa-right-from-bracket" /> Sign Out
            </button>
          </div>
        )}
      </div>

      {/* Change Password modal */}
      {showPwd && (
        <div
          style={{
            position: 'fixed', inset: 0, zIndex: 99999,
            background: 'rgba(0,0,0,0.35)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}
          onClick={e => { if (e.target === e.currentTarget) setShowPwd(false); }}
        >
          <div style={{
            background: '#fff', borderRadius: 12, padding: '28px 32px',
            width: 360, boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
          }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
              <div style={{ fontWeight: 700, fontSize: 16, color: '#111827', display: 'flex', alignItems: 'center', gap: 8 }}>
                <i className="fa-solid fa-key" style={{ color: '#2563EB' }} /> Change Password
              </div>
              <button onClick={() => setShowPwd(false)} style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 18, lineHeight: 1 }}>
                <i className="fa-solid fa-xmark" />
              </button>
            </div>

            {pwdOk ? (
              <div style={{ textAlign: 'center', padding: '16px 0', color: '#059669' }}>
                <i className="fa-solid fa-circle-check" style={{ fontSize: 32, marginBottom: 10, display: 'block' }} />
                <div style={{ fontWeight: 600 }}>Password updated!</div>
              </div>
            ) : (
              <>
                <div style={{ marginBottom: 14 }}>
                  <label style={{ fontSize: 12, fontWeight: 600, color: '#374151' }}>New Password</label>
                  <input
                    type="password"
                    value={pwdNext}
                    placeholder="Min 8 characters"
                    autoComplete="new-password"
                    onChange={e => { setPwdNext(e.target.value); setPwdErr(null); }}
                    style={inputSt}
                  />
                </div>
                <div style={{ marginBottom: 18 }}>
                  <label style={{ fontSize: 12, fontWeight: 600, color: '#374151' }}>Confirm Password</label>
                  <input
                    type="password"
                    value={pwdConf}
                    placeholder="Re-enter new password"
                    autoComplete="new-password"
                    onChange={e => { setPwdConf(e.target.value); setPwdErr(null); }}
                    onKeyDown={e => { if (e.key === 'Enter') handleChangePwd(); }}
                    style={inputSt}
                  />
                </div>

                {pwdErr && (
                  <div style={{ color: '#DC2626', fontSize: 12, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 5 }}>
                    <i className="fa-solid fa-circle-exclamation" /> {pwdErr}
                  </div>
                )}

                <button
                  onClick={handleChangePwd}
                  disabled={pwdSaving}
                  style={{
                    width: '100%', padding: '9px 0', borderRadius: 7,
                    border: 'none', background: '#2563EB', color: '#fff',
                    fontWeight: 700, fontSize: 14, cursor: pwdSaving ? 'not-allowed' : 'pointer',
                    opacity: pwdSaving ? 0.7 : 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7,
                  }}
                >
                  {pwdSaving
                    ? <><i className="fa-solid fa-spinner fa-spin" /> Updating…</>
                    : <><i className="fa-solid fa-check" /> Update Password</>}
                </button>
              </>
            )}
          </div>
        </div>
      )}
    </>
  );
}

// ─── Employee sidebar nav config ─────────────────────────────────────────────
//
// The approval-queue link is only rendered when the user has expense.edit_approval.
// Checking here keeps
// the Sidebar render logic clean.

// ─── AppHeader ────────────────────────────────────────────────────────────────

function AppHeader() {
  return (
    <header className="header">
      <div className="header-content">
        <img src="/logo.png" alt="Prowess Logo" className="logo" />
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <NotificationBell />
        <UserMenu />
      </div>
    </header>
  );
}

// ─── SidebarGroup ─────────────────────────────────────────────────────────────

function SidebarGroup({ icon, label, children, defaultOpen = true }: {
  icon: string; label: string; children: React.ReactNode; defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="sidebar-group">
      <button
        className="sidebar-group-header"
        onClick={() => setOpen(o => !o)}
        type="button"
      >
        <i className={`fa-solid ${icon}`} />
        <span>{label}</span>
        <i className={`fa-solid fa-chevron-${open ? 'down' : 'right'} sidebar-group-chevron`} />
      </button>
      {open && <div className="sidebar-group-children">{children}</div>}
    </div>
  );
}

// ─── Sidebar ──────────────────────────────────────────────────────────────────

function Sidebar() {
  const loc         = useLocation();
  const { can } = usePermissions();
  const isAdmin     = loc.pathname.startsWith('/admin');

  // Filter the nav config to only items the user has permission to see
  const visibleItems = ADMIN_NAV.filter(item => can(item.permission));

  // Build the grouped structure for the admin sidebar:
  //   Map<groupLabel, { groupIcon, items[] }>
  // Items without a group are rendered at the top level (group = undefined).
  const groups = new Map<string, { icon: string; items: NavItem[] }>();
  const topLevel: NavItem[] = [];

  for (const item of visibleItems) {
    if (item.group) {
      if (!groups.has(item.group)) {
        groups.set(item.group, { icon: item.groupIcon ?? 'fa-folder', items: [] });
      }
      groups.get(item.group)!.items.push(item);
    } else {
      topLevel.push(item);
    }
  }

  return (
    <aside className="sidebar">
      {!isAdmin && <SidebarProfileCard />}

      <nav className="sidebar-nav">
        {!isAdmin ? (
          // ── Employee sidebar ──────────────────────────────────────────────
          <>
            <div className="sidebar-section-label">Employee</div>
            <NavLink to="/profile"  className={({ isActive }) => `sidebar-link ${isActive ? 'active' : ''}`}>
              <i className="fa-solid fa-id-badge" /> My Profile
            </NavLink>
            <NavLink to="/org-chart" className={({ isActive }) => `sidebar-link ${isActive ? 'active' : ''}`}>
              <i className="fa-solid fa-diagram-project" /> Org Chart
            </NavLink>
            <NavLink to="/expense"  className={({ isActive }) => `sidebar-link ${isActive ? 'active' : ''}`} end>
              <i className="fa-solid fa-wallet" /> My Expenses
            </NavLink>
            {can('wf_my_requests.view') && (
              <NavLink to="/workflow/my-requests" className={({ isActive }) => `sidebar-link ${isActive ? 'active' : ''}`}>
                <i className="fa-solid fa-list-check" /> My Requests
              </NavLink>
            )}
            {can('wf_inbox.view') && (
              <NavLink to="/workflow/inbox" className={({ isActive }) => `sidebar-link ${isActive ? 'active' : ''}`}>
                <i className="fa-solid fa-inbox" /> Workflow Inbox
              </NavLink>
            )}
            {can('wf_inbox.view') && (
              <NavLink to="/workflow/delegations" className={({ isActive }) => `sidebar-link ${isActive ? 'active' : ''}`}>
                <i className="fa-solid fa-right-left" /> My Delegations
              </NavLink>
            )}
          </>
        ) : (
          // ── Admin sidebar — driven by ADMIN_NAV config + permission check ──
          <>
            <div className="sidebar-section-label">Admin</div>

            {/* Render grouped items first */}
            {Array.from(groups.entries()).map(([groupLabel, { icon, items }]) => (
              <SidebarGroup
                key={groupLabel}
                icon={icon}
                label={groupLabel}
                defaultOpen={items.some(i => loc.pathname.startsWith(i.path))}
              >
                {items.map(item => (
                  <NavLink
                    key={item.path}
                    to={item.path}
                    className={({ isActive }) => `sidebar-link sidebar-sublink ${isActive ? 'active' : ''}`}
                  >
                    <i className={`fa-solid ${item.icon}`} /> {item.label}
                  </NavLink>
                ))}
              </SidebarGroup>
            ))}

            {/* Render top-level (ungrouped) items */}
            {topLevel.map(item => (
              <NavLink
                key={item.path}
                to={item.path}
                className={({ isActive }) => `sidebar-link ${isActive ? 'active' : ''}`}
              >
                <i className={`fa-solid ${item.icon}`} /> {item.label}
              </NavLink>
            ))}
          </>
        )}
      </nav>
    </aside>
  );
}

// ─── AppShell ─────────────────────────────────────────────────────────────────
//
// Uses <Outlet /> so it mounts ONCE and persists across all child-route
// navigations. Only the <main> content area re-renders on each route change.

function AppShell() {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', minHeight: '100vh' }}>
      <AppHeader />
      <div className="app-shell">
        <Sidebar />
        <main className="app-main">
          {/* Page-level boundary: a crash in any route stays contained here.
              The header and sidebar remain fully functional. */}
          <ErrorBoundary scope="page">
            <Outlet />
          </ErrorBoundary>
        </main>
      </div>
    </div>
  );
}

// ─── App (routes) ─────────────────────────────────────────────────────────────

export default function App() {
  return (
    <Routes>
      {/* ── Public ────────────────────────────────────────────────────────── */}
      <Route path="/login"          element={<LoginPage />} />
      <Route path="/reset-password" element={<ResetPasswordPage />} />

      {/* ── Single persistent AppShell wrapping all authenticated routes ──── */}
      <Route element={<ProtectedRoute><AppShell /></ProtectedRoute>}>

        {/* Employee routes — any authenticated user */}
        <Route index                        element={<Navigate to="/profile" replace />} />
        <Route path="/profile"              element={
          <ProtectedRoute requiredPermission="personal_info.view"><MyProfile /></ProtectedRoute>
        } />
        <Route path="/org-chart"            element={<EmpOrgChart />} />
        <Route path="/expense"              element={
          <ProtectedRoute requiredPermission="expense_reports.view">
            <MyReports />
          </ProtectedRoute>
        } />
        <Route path="/expense/report/:id"   element={
          <ProtectedRoute requiredPermission="expense_reports.view">
            <ReportDetail />
          </ProtectedRoute>
        } />
        <Route path="/workflow/my-requests"  element={
          <ProtectedRoute requiredPermission="wf_my_requests.view">
            <WorkflowMyRequests />
          </ProtectedRoute>
        } />
        <Route path="/workflow/inbox"       element={
          <ProtectedRoute requiredPermission="wf_inbox.view">
            <ApproverInbox />
          </ProtectedRoute>
        } />
        <Route path="/workflow/review/:id" element={
          <ProtectedRoute requiredPermission="wf_inbox.view">
            <WorkflowReview />
          </ProtectedRoute>
        } />
        <Route path="/workflow/delegations" element={
          <ProtectedRoute requiredPermission="wf_inbox.view">
            <WorkflowDelegations />
          </ProtectedRoute>
        } />

        {/* ── Admin section — blanket gate + per-page permission ────────────
            The outer ProtectedRoute (sec_admin_access.view) blocks the entire /admin/*
            tree for users who have no admin-level access, even if they guess a
            URL directly. Each inner ProtectedRoute still enforces the specific
            page permission so roles with partial admin access only see what
            they're entitled to.                                               */}
        <Route path="/admin" element={
          <ProtectedRoute requiredPermission="sec_admin_access.view"><Outlet /></ProtectedRoute>
        }>
          {/* Redirect shortcuts */}
          <Route index                   element={<Navigate to="employee-details" replace />} />
          <Route path="employees"        element={<Navigate to="employee-details" replace />} />

          {/* Employee */}
          <Route path="emp-org-chart"    element={
            <ProtectedRoute requiredPermission="org_chart.view"><EmpOrgChart /></ProtectedRoute>
          } />
          <Route path="employee-details" element={
            <ProtectedRoute requiredPermission="employee_details.edit"><EmployeeDetails /></ProtectedRoute>
          } />
          <Route path="inactive-employees" element={
            <ProtectedRoute requiredPermission="inactive_employees.view"><InactiveEmployees /></ProtectedRoute>
          } />
          <Route path="add-employee"     element={
            <ProtectedRoute requiredPermission="hire_employee.create"><AddEmployee /></ProtectedRoute>
          } />

          {/* Organisation */}
          <Route path="departments"      element={
            <ProtectedRoute requiredPermission="departments.edit"><Departments /></ProtectedRoute>
          } />
          <Route path="org-chart"        element={
            <ProtectedRoute requiredPermission="org_chart.view"><OrgChartAdmin /></ProtectedRoute>
          } />

          {/* Reference / Finance */}
          <Route path="projects"         element={
            <ProtectedRoute requiredPermission="projects_mgmt.view"><Projects /></ProtectedRoute>
          } />
          <Route path="reference-data"   element={
            <ProtectedRoute requiredPermission="picklists.view"><ReferenceData /></ProtectedRoute>
          } />
          <Route path="exchange-rates"   element={
            <ProtectedRoute requiredPermission="exchange_rates_mgmt.view"><ExchangeRates /></ProtectedRoute>
          } />
          <Route path="reports"          element={
            <ProtectedRoute requiredPermission="reports_admin.view"><AdminReports /></ProtectedRoute>
          } />
          <Route path="analytics"        element={
            <ProtectedRoute requiredPermission="reports_admin.view"><ExpenseAnalytics /></ProtectedRoute>
          } />

          {/* Workflow */}
          <Route path="workflow/operations" element={
            <ProtectedRoute requiredPermission="wf_manage.view">
              <WorkflowOperations />
            </ProtectedRoute>
          } />
          <Route path="workflow/inbox"   element={
            <ProtectedRoute requiredPermission="wf_manage.view"><ApproverInbox /></ProtectedRoute>
          } />
          <Route path="workflow/templates" element={
            <ProtectedRoute requiredPermission="wf_templates.view">
              <WorkflowTemplates />
            </ProtectedRoute>
          } />
          <Route path="workflow/notification-config" element={
            <ProtectedRoute requiredPermission="wf_notification_config.view">
              <NotificationConfig />
            </ProtectedRoute>
          } />
          <Route path="workflow/delegations" element={
            <ProtectedRoute requiredPermission="wf_delegations.view">
              <WorkflowDelegations adminView />
            </ProtectedRoute>
          } />
          <Route path="workflow/assignments" element={
            <ProtectedRoute requiredPermission="wf_assignments.view">
              <WorkflowAssignments />
            </ProtectedRoute>
          } />
          <Route path="workflow/performance" element={
            <ProtectedRoute requiredPermission="wf_performance.view">
              <WorkflowPerformanceDashboard />
            </ProtectedRoute>
          } />
          <Route path="workflow/analytics" element={
            <ProtectedRoute requiredPermission="wf_analytics.view">
              <WorkflowAnalytics />
            </ProtectedRoute>
          } />
          <Route path="workflow/notifications" element={
            <ProtectedRoute requiredPermission="wf_notifications.view">
              <NotificationMonitor />
            </ProtectedRoute>
          } />
          {/* Jobs */}
          <Route path="jobs" element={
            <ProtectedRoute requiredPermission="jobs_manage.view">
              <JobsAdmin />
            </ProtectedRoute>
          } />

          {/* Security */}
          <Route path="permissions/matrix" element={
            <ProtectedRoute requiredPermission="sec_permission_matrix.view"><PermissionMatrix /></ProtectedRoute>
          } />
          <Route path="permissions/assignments" element={
            <ProtectedRoute requiredPermission="sec_role_assignments.view"><RoleAssignments /></ProtectedRoute>
          } />
          <Route path="permissions/target-groups" element={
            <ProtectedRoute requiredPermission="sec_target_groups.view"><TargetGroups /></ProtectedRoute>
          } />
          <Route path="permissions/catalog"     element={
            <ProtectedRoute requiredPermission="sec_permission_catalog.view"><PermissionCatalog /></ProtectedRoute>
          } />
          <Route path="permissions/rbp"         element={
            <ProtectedRoute requiredPermission="sec_rbp_troubleshoot.view"><RbpTroubleshoot /></ProtectedRoute>
          } />
        </Route>

      </Route>

      {/* ── Catch-all ─────────────────────────────────────────────────────── */}
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
