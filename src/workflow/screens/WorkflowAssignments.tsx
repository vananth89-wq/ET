/**
 * WorkflowAssignments — Dynamic Workflow Assignment Manager
 *
 * Layout
 * ──────────────────────────────────────────────────────────────────────────
 *  LEFT PANEL (280px)             RIGHT PANEL (flex)
 *  ┌───────────────────────┐      ┌─────────────────────────────────────────┐
 *  │ 🔍 Search modules     │      │ Module header + active-transaction warn  │
 *  │───────────────────────│      │─────────────────────────────────────────│
 *  │ ● expense_reports  ✓  │      │ GLOBAL ASSIGNMENT                       │
 *  │ ○ leave_requests   !  │      │   Workflow ▾  From  To  [Save]          │
 *  │ ○ travel_requests  ✓  │      │─────────────────────────────────────────│
 *  └───────────────────────┘      │ ROLE-BASED ASSIGNMENTS                  │
 *                                 │   Role | Workflow | From | To | Pri | ✕ │
 *                                 │   [+ Add Role Assignment]               │
 *                                 │─────────────────────────────────────────│
 *                                 │ WORKFLOW PREVIEW (resolved steps)       │
 *                                 └─────────────────────────────────────────┘
 *
 * Route: /admin/workflow/assignments  (requires workflow.admin)
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';

// ─── Tokens ───────────────────────────────────────────────────────────────────
const C = {
  navy:    '#18345B',
  blue:    '#2F77B5',
  blueL:   '#EFF6FF',
  border:  '#E5E7EB',
  bg:      '#F9FAFB',
  text:    '#111827',
  muted:   '#6B7280',
  faint:   '#9CA3AF',
  green:   '#16A34A',
  greenL:  '#DCFCE7',
  red:     '#DC2626',
  redL:    '#FEF2F2',
  amber:   '#D97706',
  amberL:  '#FEF9C3',
  purple:  '#7C3AED',
  purpleL: '#F5F3FF',
};

const iStyle: React.CSSProperties = {
  width: '100%', padding: '7px 10px', borderRadius: 6,
  border: `1px solid ${C.border}`, fontSize: 13,
  background: '#fff', outline: 'none', boxSizing: 'border-box',
};

// ─── Types ────────────────────────────────────────────────────────────────────

interface ModuleInfo {
  moduleCode:    string;
  label:         string;               // humanised label
  templateCount: number;
  hasGlobal:     boolean;              // has at least one active GLOBAL assignment
}

interface WfTemplate {
  id:   string;
  code: string;
  name: string;
}

interface WfStep {
  id:           string;
  stepOrder:    number;
  name:         string;
  approverType: string;
  approverRole: string | null;
  slaHours:     number | null;
}

interface RoleOption {
  id:   string;
  code: string;
  name: string;
}

interface Assignment {
  id:             string;
  moduleCode:     string;
  wfTemplateId:   string;
  templateName:   string;
  assignmentType: string;
  entityId:       string | null;
  entityName:     string | null;      // role name for ROLE type
  priority:       number;
  effectiveFrom:  string;
  effectiveTo:    string | null;
  isActive:       boolean;
}

interface RoleRow {
  _key:          string;              // local draft key (assignment id or 'new-N')
  id:            string | null;       // null = new unsaved row
  roleId:        string;
  roleName:      string;
  wfTemplateId:  string;
  priority:      number;
  effectiveFrom: string;
  effectiveTo:   string;
  dirty:         boolean;
}

interface EmpOption {
  profileId: string;   // profiles.id (used as entity_id in workflow_assignments)
  name:      string;
  empCode:   string;
}

interface EmpRow {
  _key:          string;
  id:            string | null;
  profileId:     string;
  empName:       string;
  wfTemplateId:  string;
  priority:      number;
  effectiveFrom: string;
  effectiveTo:   string;
  dirty:         boolean;
}

// ─── System module registry ───────────────────────────────────────────────────
//
// All places in the system where a workflow can be attached.
// Add new entries here when a new submittable module is built.
// icon = Font Awesome solid class name (without fa-)

interface SystemModule {
  code:        string;
  label:       string;
  description: string;
  icon:        string;
  status:      'wired' | 'available';  // wired = trigger implemented, available = screen exists, trigger ready to wire
}

const SYSTEM_MODULES: SystemModule[] = [
  {
    code:        'expense_reports',
    label:       'Expense Reports',
    description: 'Employee expense submissions',
    icon:        'fa-wallet',
    status:      'wired',
  },
  {
    code:        'employee_edit',
    label:       'Employee — Edit Details',
    description: 'Admin edits to employee records requiring approval',
    icon:        'fa-user-pen',
    status:      'available',
  },
  {
    code:        'employee_onboarding',
    label:       'Employee — Add New',
    description: 'New employee creation and onboarding approval',
    icon:        'fa-user-plus',
    status:      'available',
  },
  {
    code:        'department_create',
    label:       'Department — Create',
    description: 'New department creation requiring approval',
    icon:        'fa-sitemap',
    status:      'available',
  },
  {
    code:        'department_edit',
    label:       'Department — Edit',
    description: 'Department structure or details changes',
    icon:        'fa-pen-to-square',
    status:      'available',
  },
  {
    code:        'project_create',
    label:       'Project — Create',
    description: 'New project creation requiring approval',
    icon:        'fa-folder-plus',
    status:      'available',
  },
  {
    code:        'project_edit',
    label:       'Project — Edit',
    description: 'Project details or budget changes',
    icon:        'fa-folder-pen',
    status:      'available',
  },
  {
    code:        'exchange_rate_update',
    label:       'Exchange Rates — Update',
    description: 'Currency exchange rate updates requiring approval',
    icon:        'fa-arrow-right-arrow-left',
    status:      'available',
  },
  {
    code:        'delegations',
    label:       'Delegations',
    description: 'Approval workflow delegation requests',
    icon:        'fa-right-left',
    status:      'available',
  },
  {
    code:        'profile_personal',
    label:       'Profile — Personal Info',
    description: 'Name, nationality, marital status changes',
    icon:        'fa-id-card',
    status:      'available',
  },
  {
    code:        'profile_contact',
    label:       'Profile — Contact Info',
    description: 'Mobile, email, personal contact changes',
    icon:        'fa-phone',
    status:      'available',
  },
  {
    code:        'profile_employment',
    label:       'Profile — Employment',
    description: 'Designation, department, work details changes',
    icon:        'fa-briefcase',
    status:      'available',
  },
  {
    code:        'profile_address',
    label:       'Profile — Address',
    description: 'Residential and permanent address changes',
    icon:        'fa-location-dot',
    status:      'available',
  },
  {
    code:        'profile_passport',
    label:       'Profile — Passport',
    description: 'Passport and visa details changes',
    icon:        'fa-passport',
    status:      'available',
  },
  {
    code:        'profile_identification',
    label:       'Profile — Identification',
    description: 'National ID, tax ID and other ID changes',
    icon:        'fa-fingerprint',
    status:      'available',
  },
  {
    code:        'profile_emergency_contact',
    label:       'Profile — Emergency Contact',
    description: 'Emergency contact details changes',
    icon:        'fa-heart-pulse',
    status:      'available',
  },
];

// ─── Helpers ──────────────────────────────────────────────────────────────────

function humanise(code: string) {
  return code
    .replace(/_/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase());
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

function fmtDate(iso: string | null) {
  if (!iso) return 'Open-ended';
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  }).format(new Date(iso));
}

const APPROVER_ICONS: Record<string, string> = {
  MANAGER:       'fa-user-tie',
  DEPT_HEAD:     'fa-building',
  ROLE:          'fa-users-gear',
  SPECIFIC_USER: 'fa-user-check',
  SELF:          'fa-user-circle',
  RULE_BASED:    'fa-diagram-next',
};

// ─── Component ────────────────────────────────────────────────────────────────

export default function WorkflowAssignments() {
  // ── Module list ─────────────────────────────────────────────────────────────
  const [modules,       setModules]       = useState<ModuleInfo[]>([]);
  const [selectedCode,  setSelectedCode]  = useState<string | null>(null);
  const [loadingMod,    setLoadingMod]    = useState(false);

  // ── Right panel data ────────────────────────────────────────────────────────
  const [templates,     setTemplates]     = useState<WfTemplate[]>([]);
  const [roles,         setRoles]         = useState<RoleOption[]>([]);
  const [activeCount,   setActiveCount]   = useState<number>(0);
  const [assignments,   setAssignments]   = useState<Assignment[]>([]);
  const [steps,         setSteps]         = useState<WfStep[]>([]);
  const [loadingRight,  setLoadingRight]  = useState(false);

  // ── GLOBAL draft ────────────────────────────────────────────────────────────
  const [globalId,        setGlobalId]        = useState<string | null>(null);
  const [globalTemplate,  setGlobalTemplate]  = useState('');
  const [globalFrom,      setGlobalFrom]      = useState(today());
  const [globalTo,        setGlobalTo]        = useState('');
  const [globalDirty,     setGlobalDirty]     = useState(false);
  const [globalSaving,    setGlobalSaving]    = useState(false);
  const [globalError,     setGlobalError]     = useState<string | null>(null);
  const [globalWarning,   setGlobalWarning]   = useState<string | null>(null);

  // ── ROLE rows draft ─────────────────────────────────────────────────────────
  const [roleRows,      setRoleRows]      = useState<RoleRow[]>([]);
  const [roleSaving,    setRoleSaving]    = useState(false);
  const [roleError,     setRoleError]     = useState<string | null>(null);

  // ── EMPLOYEE rows draft ──────────────────────────────────────────────────────
  const [empOptions,    setEmpOptions]    = useState<EmpOption[]>([]);
  const [empRows,       setEmpRows]       = useState<EmpRow[]>([]);
  const [empSaving,     setEmpSaving]     = useState(false);
  const [empError,      setEmpError]      = useState<string | null>(null);

  // ── Preview template id ─────────────────────────────────────────────────────
  const [previewTemplateId, setPreviewTemplateId] = useState<string | null>(null);

  // ── Toast ────────────────────────────────────────────────────────────────────
  const [toast, setToast] = useState<{ type: 'ok' | 'err'; msg: string } | null>(null);

  function showToast(type: 'ok' | 'err', msg: string) {
    setToast({ type, msg });
    setTimeout(() => setToast(null), 4500);
  }

  // ── Load module list ─────────────────────────────────────────────────────────

  const loadModules = useCallback(async () => {
    setLoadingMod(true);
    const { data: tplData } = await supabase
      .from('workflow_templates')
      .select('module_code')
      .eq('is_active', true);

    const { data: asnData } = await supabase
      .from('workflow_assignments')
      .select('module_code, assignment_type')
      .eq('is_active', true);

    setLoadingMod(false);

    const hasGlobalMap = new Set(
      (asnData ?? [])
        .filter((a: any) => a.assignment_type === 'GLOBAL')
        .map((a: any) => a.module_code as string)
    );

    const countMap = (tplData ?? []).reduce((acc: Record<string, number>, t: any) => {
      acc[t.module_code] = (acc[t.module_code] ?? 0) + 1;
      return acc;
    }, {});

    // Merge registry with live DB data — registry defines what's shown,
    // DB data fills in template counts and assignment status
    const list: ModuleInfo[] = SYSTEM_MODULES.map(sm => ({
      moduleCode:    sm.code,
      label:         sm.label,
      templateCount: countMap[sm.code] ?? 0,
      hasGlobal:     hasGlobalMap.has(sm.code),
    }));

    setModules(list);

    // Auto-select the first module on initial load (when nothing is selected yet)
    setSelectedCode(prev => prev ?? (list[0]?.moduleCode ?? null));
  }, []);

  useEffect(() => { loadModules(); }, [loadModules]);

  // Load employee dropdown once on mount
  useEffect(() => {
    supabase
      .from('employees')
      .select('profile_id, name, emp_code')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => {
        setEmpOptions((data ?? []).map((e: any) => ({
          profileId: e.profile_id,
          name:      e.name,
          empCode:   e.emp_code ?? '',
        })));
      });
  }, []);

  // ── Load right panel when module selected ───────────────────────────────────

  const loadRight = useCallback(async (moduleCode: string) => {
    setLoadingRight(true);
    setGlobalError(null);
    setGlobalWarning(null);
    setRoleError(null);

    const [tplRes, roleRes, asnRes, countRes] = await Promise.all([
      // Templates for this module
      supabase
        .from('workflow_templates')
        .select('id, code, name')
        .eq('module_code', moduleCode)
        .eq('is_active', true)
        .order('name'),

      // Non-system roles
      supabase
        .from('roles')
        .select('id, code, name')
        .eq('is_system', false)
        .eq('is_active', true)
        .order('name'),

      // Existing assignments for this module
      supabase
        .from('workflow_assignments')
        .select(`
          id, module_code, wf_template_id, assignment_type,
          entity_id, priority, effective_from, effective_to, is_active,
          template:workflow_templates(name),
          role:roles(name)
        `)
        .eq('module_code', moduleCode)
        .eq('is_active', true)
        .order('assignment_type')
        .order('priority'),

      // Active transaction count
      supabase.rpc('get_active_transaction_count', { p_module_code: moduleCode }),
    ]);

    setTemplates((tplRes.data ?? []).map((t: any) => ({ id: t.id, code: t.code, name: t.name })));
    setRoles((roleRes.data ?? []).map((r: any) => ({ id: r.id, code: r.code, name: r.name })));
    setActiveCount(countRes.data ?? 0);

    const mapped: Assignment[] = (asnRes.data ?? []).map((a: any) => ({
      id:             a.id,
      moduleCode:     a.module_code,
      wfTemplateId:   a.wf_template_id,
      templateName:   a.template?.name ?? '—',
      assignmentType: a.assignment_type,
      entityId:       a.entity_id,
      entityName:     a.role?.name ?? null,
      priority:       a.priority,
      effectiveFrom:  a.effective_from,
      effectiveTo:    a.effective_to,
      isActive:       a.is_active,
    }));
    setAssignments(mapped);

    // Populate GLOBAL draft
    const global = mapped.find(a => a.assignmentType === 'GLOBAL');
    setGlobalId(global?.id ?? null);
    setGlobalTemplate(global?.wfTemplateId ?? '');
    setGlobalFrom(global?.effectiveFrom ?? today());
    setGlobalTo(global?.effectiveTo ?? '');
    setGlobalDirty(false);

    // Populate ROLE rows draft
    setRoleRows(
      mapped
        .filter(a => a.assignmentType === 'ROLE')
        .map(a => ({
          _key:          a.id,
          id:            a.id,
          roleId:        a.entityId ?? '',
          roleName:      a.entityName ?? '',
          wfTemplateId:  a.wfTemplateId,
          priority:      a.priority,
          effectiveFrom: a.effectiveFrom,
          effectiveTo:   a.effectiveTo ?? '',
          dirty:         false,
        }))
    );

    // Populate EMPLOYEE rows draft
    // entity_id for EMPLOYEE = profiles.id; join employees for display name
    const empAsnData = await supabase
      .from('workflow_assignments')
      .select(`
        id, wf_template_id, entity_id, priority, effective_from, effective_to,
        emp:employees!employees_profile_id_fkey(name, emp_code)
      `)
      .eq('module_code', moduleCode)
      .eq('assignment_type', 'EMPLOYEE')
      .eq('is_active', true)
      .order('priority');

    setEmpRows(
      (empAsnData.data ?? []).map((a: any) => ({
        _key:          a.id,
        id:            a.id,
        profileId:     a.entity_id ?? '',
        empName:       a.emp?.name ?? a.entity_id ?? '',
        wfTemplateId:  a.wf_template_id,
        priority:      a.priority,
        effectiveFrom: a.effective_from,
        effectiveTo:   a.effective_to ?? '',
        dirty:         false,
      }))
    );
    setEmpError(null);

    // Default preview to GLOBAL template
    setPreviewTemplateId(global?.wfTemplateId ?? null);

    setLoadingRight(false);
  }, []);

  useEffect(() => {
    if (selectedCode) loadRight(selectedCode);
  }, [selectedCode, loadRight]);

  // Load steps when preview template changes
  useEffect(() => {
    if (!previewTemplateId) { setSteps([]); return; }
    supabase
      .from('workflow_steps')
      .select('id, step_order, name, approver_type, approver_role, sla_hours')
      .eq('template_id', previewTemplateId)
      .eq('is_active', true)
      .order('step_order')
      .then(({ data }) => setSteps((data ?? []).map((s: any) => ({
        id:           s.id,
        stepOrder:    s.step_order,
        name:         s.name,
        approverType: s.approver_type,
        approverRole: s.approver_role,
        slaHours:     s.sla_hours,
      }))));
  }, [previewTemplateId]);

  // ── Save GLOBAL ──────────────────────────────────────────────────────────────

  async function saveGlobal() {
    if (!selectedCode) return;
    if (!globalTemplate) { setGlobalError('Please select a workflow.'); return; }
    setGlobalError(null);
    setGlobalWarning(null);
    setGlobalSaving(true);

    const { data, error } = await supabase.rpc('save_workflow_assignment', {
      p_id:              globalId,
      p_module_code:     selectedCode,
      p_wf_template_id:  globalTemplate,
      p_assignment_type: 'GLOBAL',
      p_entity_id:       null,
      p_priority:        0,
      p_effective_from:  globalFrom,
      p_effective_to:    globalTo || null,
      p_reason:          null,
    });

    setGlobalSaving(false);

    if (error || !data?.ok) {
      setGlobalError(data?.error ?? error?.message ?? 'Save failed.');
      return;
    }
    if (data.warning) setGlobalWarning(data.warning);

    setGlobalId(data.assignment_id);
    setGlobalDirty(false);
    setPreviewTemplateId(globalTemplate);
    showToast('ok', 'Global assignment saved.');
    loadModules();
    loadRight(selectedCode);
  }

  // ── Deactivate GLOBAL ────────────────────────────────────────────────────────

  async function deactivateGlobal() {
    if (!globalId) return;
    setGlobalError(null);
    const { data, error } = await supabase.rpc('deactivate_workflow_assignment', {
      p_id: globalId,
    });
    if (error || !data?.ok) {
      setGlobalError(data?.error ?? error?.message ?? 'Deactivation failed.');
      return;
    }
    showToast('ok', 'Global assignment deactivated.');
    loadModules();
    if (selectedCode) loadRight(selectedCode);
  }

  // ── ROLE row helpers ─────────────────────────────────────────────────────────

  function addRoleRow() {
    const key = `new-${Date.now()}`;
    setRoleRows(r => [...r, {
      _key: key, id: null,
      roleId: '', roleName: '',
      wfTemplateId: globalTemplate || (templates[0]?.id ?? ''),
      priority: roleRows.length,
      effectiveFrom: today(), effectiveTo: '',
      dirty: true,
    }]);
  }

  function updateRoleRow(key: string, patch: Partial<RoleRow>) {
    setRoleRows(rows => rows.map(r =>
      r._key === key ? { ...r, ...patch, dirty: true } : r
    ));
    setRoleError(null);
  }

  async function removeRoleRow(row: RoleRow) {
    if (row.id) {
      const { data, error } = await supabase.rpc('deactivate_workflow_assignment', {
        p_id: row.id,
      });
      if (error || !data?.ok) {
        showToast('err', data?.error ?? error?.message ?? 'Remove failed.');
        return;
      }
    }
    setRoleRows(rows => rows.filter(r => r._key !== row._key));
    showToast('ok', 'Role assignment removed.');
    if (selectedCode) { loadModules(); loadRight(selectedCode); }
  }

  async function saveRoleRows() {
    if (!selectedCode) return;
    setRoleError(null);
    setRoleSaving(true);

    for (const row of roleRows.filter(r => r.dirty)) {
      if (!row.roleId)       { setRoleError('Please select a role for all rows.'); setRoleSaving(false); return; }
      if (!row.wfTemplateId) { setRoleError('Please select a workflow for all rows.'); setRoleSaving(false); return; }

      const { data, error } = await supabase.rpc('save_workflow_assignment', {
        p_id:              row.id,
        p_module_code:     selectedCode,
        p_wf_template_id:  row.wfTemplateId,
        p_assignment_type: 'ROLE',
        p_entity_id:       row.roleId,
        p_priority:        row.priority,
        p_effective_from:  row.effectiveFrom,
        p_effective_to:    row.effectiveTo || null,
        p_reason:          null,
      });

      if (error || !data?.ok) {
        setRoleError(data?.error ?? error?.message ?? 'Save failed.');
        setRoleSaving(false);
        return;
      }
    }

    setRoleSaving(false);
    showToast('ok', 'Role assignments saved.');
    loadModules();
    if (selectedCode) loadRight(selectedCode);
  }

  // ── EMPLOYEE row helpers ─────────────────────────────────────────────────────

  function addEmpRow() {
    const key = `new-${Date.now()}`;
    setEmpRows(r => [...r, {
      _key: key, id: null,
      profileId: '', empName: '',
      wfTemplateId: globalTemplate || (templates[0]?.id ?? ''),
      priority: empRows.length,
      effectiveFrom: today(), effectiveTo: '',
      dirty: true,
    }]);
  }

  function updateEmpRow(key: string, patch: Partial<EmpRow>) {
    setEmpRows(rows => rows.map(r =>
      r._key === key ? { ...r, ...patch, dirty: true } : r
    ));
    setEmpError(null);
  }

  async function removeEmpRow(row: EmpRow) {
    if (row.id) {
      const { data, error } = await supabase.rpc('deactivate_workflow_assignment', { p_id: row.id });
      if (error || !data?.ok) {
        showToast('err', data?.error ?? error?.message ?? 'Remove failed.');
        return;
      }
    }
    setEmpRows(rows => rows.filter(r => r._key !== row._key));
    showToast('ok', 'Employee override removed.');
    if (selectedCode) { loadModules(); loadRight(selectedCode); }
  }

  async function saveEmpRows() {
    if (!selectedCode) return;
    setEmpError(null);
    setEmpSaving(true);

    for (const row of empRows.filter(r => r.dirty)) {
      if (!row.profileId)    { setEmpError('Please select an employee for all rows.'); setEmpSaving(false); return; }
      if (!row.wfTemplateId) { setEmpError('Please select a workflow for all rows.');  setEmpSaving(false); return; }

      const { data, error } = await supabase.rpc('save_workflow_assignment', {
        p_id:              row.id,
        p_module_code:     selectedCode,
        p_wf_template_id:  row.wfTemplateId,
        p_assignment_type: 'EMPLOYEE',
        p_entity_id:       row.profileId,
        p_priority:        row.priority,
        p_effective_from:  row.effectiveFrom,
        p_effective_to:    row.effectiveTo || null,
        p_reason:          null,
      });

      if (error || !data?.ok) {
        setEmpError(data?.error ?? error?.message ?? 'Save failed.');
        setEmpSaving(false);
        return;
      }
    }

    setEmpSaving(false);
    showToast('ok', 'Employee overrides saved.');
    loadModules();
    if (selectedCode) loadRight(selectedCode);
  }

  // ── Selected module info ─────────────────────────────────────────────────────

  const selectedModule = modules.find(m => m.moduleCode === selectedCode);

  // ─── Render ──────────────────────────────────────────────────────────────────

  return (
    <div style={{ display: 'flex', height: 'calc(100vh - 60px)', overflow: 'hidden' }}>

      {/* ── LEFT PANEL ── */}
      <div style={{
        width: 280, flexShrink: 0, borderRight: `1px solid ${C.border}`,
        background: '#fff', display: 'flex', flexDirection: 'column',
      }}>
        <div style={{ padding: '16px 16px 12px' }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 10 }}>
            Modules
          </div>
          {loadingMod ? (
            <div style={{ padding: '8px 0', textAlign: 'center', color: C.muted }}>
              <i className="fa-solid fa-spinner fa-spin" />
            </div>
          ) : modules.length === 0 ? (
            <div style={{ fontSize: 12, color: C.muted, padding: '6px 0' }}>
              No modules found. Create a workflow template first.
            </div>
          ) : (
            <select
              value={selectedCode ?? ''}
              onChange={e => setSelectedCode(e.target.value || null)}
              style={{ ...iStyle, fontSize: 13 }}
            >
              <option value="">— select a module —</option>
              {SYSTEM_MODULES.map(sm => {
                const m = modules.find(x => x.moduleCode === sm.code);
                const configured = m?.hasGlobal ?? false;
                const hasTemplates = (m?.templateCount ?? 0) > 0;
                const statusIcon = configured ? '✓' : hasTemplates ? '⚠' : '○';
                const suffix = '';
                return (
                  <option key={sm.code} value={sm.code}>
                    {statusIcon}  {sm.label}{suffix}
                  </option>
                );
              })}
            </select>
          )}

          {/* Status badge + description for selected module */}
          {selectedCode && (() => {
            const sm  = SYSTEM_MODULES.find(x => x.code === selectedCode);
            const m   = modules.find(x => x.moduleCode === selectedCode);
            if (!sm) return null;
            return (
              <div style={{ marginTop: 10 }}>
                <div style={{ fontSize: 12, color: C.muted, marginBottom: 6 }}>
                  <i className={`fa-solid ${sm.icon}`} style={{ marginRight: 5, color: C.blue }} />
                  {sm.description}
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  {sm.status === 'available' && !m?.hasGlobal ? (
                    <span style={{
                      fontSize: 10, fontWeight: 700, padding: '2px 8px', borderRadius: 99,
                      background: C.amberL, color: C.amber,
                    }}>⚠ Not configured</span>
                  ) : (
                    <span style={{
                      fontSize: 10, fontWeight: 700, padding: '2px 8px', borderRadius: 99,
                      background: (m?.hasGlobal) ? C.greenL : C.amberL,
                      color:      (m?.hasGlobal) ? C.green  : C.amber,
                    }}>
                      {(m?.hasGlobal) ? '✓ Configured' : '⚠ Not configured'}
                    </span>
                  )}
                  <span style={{ fontSize: 11, color: C.faint }}>
                    {m?.templateCount ?? 0} template{(m?.templateCount ?? 0) !== 1 ? 's' : ''}
                  </span>
                </div>
              </div>
            );
          })()}
        </div>
      </div>

      {/* ── RIGHT PANEL ── */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 28px', background: C.bg }}>

        {!selectedCode ? (
          <div style={{ textAlign: 'center', color: C.muted, paddingTop: 80 }}>
            <i className="fa-solid fa-arrow-left" style={{ fontSize: 28, marginBottom: 12, display: 'block', color: C.faint }} />
            <div style={{ fontWeight: 600, fontSize: 15 }}>Select a module</div>
            <div style={{ fontSize: 13, marginTop: 4 }}>Choose a module from the left panel to configure its workflow.</div>
          </div>
        ) : loadingRight ? (
          <div style={{ textAlign: 'center', paddingTop: 80, color: C.muted }}>
            <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 22 }} />
          </div>
        ) : (
          <>
            {/* Header */}
            <div style={{ marginBottom: 20 }}>
              <h2 style={{ margin: 0, fontSize: 20, fontWeight: 700, color: C.navy }}>
                <i className="fa-solid fa-diagram-next" style={{ marginRight: 10, color: C.blue }} />
                {selectedModule?.label}
              </h2>
              <div style={{ fontSize: 12, color: C.muted, marginTop: 3 }}>
                Configure which workflow applies for new submissions in this module.
              </div>
            </div>

            {/* Active transaction warning */}
            {activeCount > 0 && (
              <div style={{
                background: C.amberL, border: `1px solid ${C.amber}`, borderRadius: 8,
                padding: '10px 14px', fontSize: 12, color: C.amber,
                display: 'flex', gap: 8, alignItems: 'flex-start', marginBottom: 20,
              }}>
                <i className="fa-solid fa-triangle-exclamation" style={{ marginTop: 1, flexShrink: 0 }} />
                <span>
                  <strong>{activeCount} transaction{activeCount !== 1 ? 's' : ''} currently in approval</strong> for this module.
                  Workflow is locked per submission — existing transactions are unaffected.
                  Only new submissions will use updated assignments.
                </span>
              </div>
            )}

            {/* ── GLOBAL ASSIGNMENT SECTION ── */}
            <Section title="Global Assignment" subtitle="Default workflow used when no role override matches.">
              {globalError && <InlineError msg={globalError} />}
              {globalWarning && <InlineWarning msg={globalWarning} />}

              <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr auto', gap: 12, alignItems: 'end' }}>
                <FieldCol label="Workflow *">
                  <select
                    value={globalTemplate}
                    onChange={e => { setGlobalTemplate(e.target.value); setGlobalDirty(true); setPreviewTemplateId(e.target.value); }}
                    style={iStyle}
                  >
                    <option value="">— select workflow —</option>
                    {templates.map(t => (
                      <option key={t.id} value={t.id}>{t.name}</option>
                    ))}
                  </select>
                </FieldCol>
                <FieldCol label="Effective From *">
                  <input type="date" value={globalFrom}
                    onChange={e => { setGlobalFrom(e.target.value); setGlobalDirty(true); }}
                    style={iStyle} />
                </FieldCol>
                <FieldCol label="Effective To">
                  <input type="date" value={globalTo} min={globalFrom}
                    onChange={e => { setGlobalTo(e.target.value); setGlobalDirty(true); }}
                    style={iStyle} />
                </FieldCol>
                <div style={{ display: 'flex', gap: 8, paddingBottom: 1 }}>
                  <Btn
                    label={globalSaving ? 'Saving…' : globalId ? 'Update' : 'Save'}
                    icon={globalSaving ? 'fa-spinner fa-spin' : 'fa-check'}
                    disabled={globalSaving || !globalDirty}
                    onClick={saveGlobal}
                    primary
                  />
                  {globalId && (
                    <Btn label="Remove" icon="fa-trash" onClick={deactivateGlobal} danger />
                  )}
                </div>
              </div>

              {/* Current global status */}
              {globalId && !globalDirty && (
                <div style={{ marginTop: 10, fontSize: 12, color: C.muted, display: 'flex', gap: 6, alignItems: 'center' }}>
                  <i className="fa-solid fa-circle-check" style={{ color: C.green }} />
                  Active · {fmtDate(globalFrom)} → {fmtDate(globalTo || null)}
                </div>
              )}
            </Section>

            {/* ── ROLE-BASED ASSIGNMENTS SECTION ── */}
            <Section title="Role-Based Assignments" subtitle="Override the global workflow for specific roles. Highest priority wins.">
              {roleError && <InlineError msg={roleError} />}

              {roleRows.length > 0 && (
                <div style={{ overflowX: 'auto', marginBottom: 14 }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                    <thead>
                      <tr style={{ background: C.bg }}>
                        {['Role', 'Workflow', 'From', 'To', 'Priority', ''].map(h => (
                          <th key={h} style={{
                            padding: '8px 10px', textAlign: 'left', fontSize: 11,
                            fontWeight: 700, color: C.muted, textTransform: 'uppercase',
                            letterSpacing: '0.05em', borderBottom: `1px solid ${C.border}`,
                          }}>{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {roleRows.map(row => (
                        <tr key={row._key} style={{ borderBottom: `1px solid ${C.border}` }}>
                          <td style={{ padding: '8px 10px' }}>
                            <select
                              value={row.roleId}
                              onChange={e => {
                                const r = roles.find(r => r.id === e.target.value);
                                updateRoleRow(row._key, { roleId: e.target.value, roleName: r?.name ?? '' });
                              }}
                              style={{ ...iStyle, minWidth: 140 }}
                            >
                              <option value="">— role —</option>
                              {roles.map(r => <option key={r.id} value={r.id}>{r.name}</option>)}
                            </select>
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <select
                              value={row.wfTemplateId}
                              onChange={e => updateRoleRow(row._key, { wfTemplateId: e.target.value })}
                              style={{ ...iStyle, minWidth: 160 }}
                            >
                              <option value="">— workflow —</option>
                              {templates.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
                            </select>
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <input type="date" value={row.effectiveFrom}
                              onChange={e => updateRoleRow(row._key, { effectiveFrom: e.target.value })}
                              style={{ ...iStyle, minWidth: 130 }} />
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <input type="date" value={row.effectiveTo} min={row.effectiveFrom}
                              onChange={e => updateRoleRow(row._key, { effectiveTo: e.target.value })}
                              style={{ ...iStyle, minWidth: 130 }} />
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <input type="number" min={0} value={row.priority}
                              onChange={e => updateRoleRow(row._key, { priority: Number(e.target.value) })}
                              style={{ ...iStyle, width: 60 }} />
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <button
                              onClick={() => removeRoleRow(row)}
                              style={{
                                border: 'none', background: 'none', cursor: 'pointer',
                                color: C.red, fontSize: 14, padding: '2px 4px',
                              }}
                              title="Remove this role assignment"
                            >
                              <i className="fa-solid fa-trash" />
                            </button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}

              <div style={{ display: 'flex', gap: 10 }}>
                <Btn label="+ Add Role Assignment" icon="fa-plus" onClick={addRoleRow} />
                {roleRows.some(r => r.dirty) && (
                  <Btn
                    label={roleSaving ? 'Saving…' : 'Save Role Assignments'}
                    icon={roleSaving ? 'fa-spinner fa-spin' : 'fa-check'}
                    disabled={roleSaving}
                    onClick={saveRoleRows}
                    primary
                  />
                )}
              </div>
            </Section>

            {/* ── EMPLOYEE OVERRIDES SECTION ── */}
            <Section title="Employee Overrides" subtitle="Override the workflow for specific employees. Takes highest priority over global and role assignments.">
              {empError && <InlineError msg={empError} />}

              {empRows.length > 0 && (
                <div style={{ overflowX: 'auto', marginBottom: 14 }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                    <thead>
                      <tr style={{ background: C.bg }}>
                        {['Employee', 'Workflow', 'From', 'To', 'Priority', ''].map(h => (
                          <th key={h} style={{
                            padding: '8px 10px', textAlign: 'left', fontSize: 11,
                            fontWeight: 700, color: C.muted, textTransform: 'uppercase',
                            letterSpacing: '0.05em', borderBottom: `1px solid ${C.border}`,
                          }}>{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {empRows.map(row => (
                        <tr key={row._key} style={{ borderBottom: `1px solid ${C.border}` }}>
                          <td style={{ padding: '8px 10px' }}>
                            {/* Searchable employee picker: type to filter, pick from list */}
                            <input
                              list={`emp-list-${row._key}`}
                              value={row.empName}
                              onChange={e => {
                                const typed = e.target.value;
                                // Try to find an exact match from the datalist
                                const match = empOptions.find(o =>
                                  `${o.name}${o.empCode ? ` (${o.empCode})` : ''}` === typed
                                );
                                updateEmpRow(row._key, {
                                  empName:   typed,
                                  profileId: match?.profileId ?? '',
                                });
                              }}
                              placeholder="Type to search employee…"
                              style={{ ...iStyle, minWidth: 200 }}
                            />
                            <datalist id={`emp-list-${row._key}`}>
                              {empOptions.map(o => (
                                <option
                                  key={o.profileId}
                                  value={`${o.name}${o.empCode ? ` (${o.empCode})` : ''}`}
                                />
                              ))}
                            </datalist>
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <select
                              value={row.wfTemplateId}
                              onChange={e => updateEmpRow(row._key, { wfTemplateId: e.target.value })}
                              style={{ ...iStyle, minWidth: 160 }}
                            >
                              <option value="">— workflow —</option>
                              {templates.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
                            </select>
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <input type="date" value={row.effectiveFrom}
                              onChange={e => updateEmpRow(row._key, { effectiveFrom: e.target.value })}
                              style={{ ...iStyle, minWidth: 130 }} />
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <input type="date" value={row.effectiveTo} min={row.effectiveFrom}
                              onChange={e => updateEmpRow(row._key, { effectiveTo: e.target.value })}
                              style={{ ...iStyle, minWidth: 130 }} />
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <input type="number" min={0} value={row.priority}
                              onChange={e => updateEmpRow(row._key, { priority: Number(e.target.value) })}
                              style={{ ...iStyle, width: 60 }} />
                          </td>
                          <td style={{ padding: '8px 10px' }}>
                            <button
                              onClick={() => removeEmpRow(row)}
                              style={{ border: 'none', background: 'none', cursor: 'pointer', color: C.red, fontSize: 14, padding: '2px 4px' }}
                              title="Remove this employee override"
                            >
                              <i className="fa-solid fa-trash" />
                            </button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}

              <div style={{ display: 'flex', gap: 10 }}>
                <Btn label="+ Add Employee Override" icon="fa-plus" onClick={addEmpRow} />
                {empRows.some(r => r.dirty) && (
                  <Btn
                    label={empSaving ? 'Saving…' : 'Save Employee Overrides'}
                    icon={empSaving ? 'fa-spinner fa-spin' : 'fa-check'}
                    disabled={empSaving}
                    onClick={saveEmpRows}
                    primary
                  />
                )}
              </div>
            </Section>

            {/* ── WORKFLOW PREVIEW SECTION ── */}
            <Section title="Workflow Preview" subtitle="Steps for the currently selected workflow.">
              {/* Template picker for preview */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16 }}>
                <span style={{ fontSize: 12, color: C.muted, flexShrink: 0 }}>Preview:</span>
                <select
                  value={previewTemplateId ?? ''}
                  onChange={e => setPreviewTemplateId(e.target.value || null)}
                  style={{ ...iStyle, maxWidth: 260 }}
                >
                  <option value="">— select template to preview —</option>
                  {templates.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
                </select>
              </div>

              {steps.length === 0 ? (
                <div style={{ fontSize: 13, color: C.faint, fontStyle: 'italic' }}>
                  {previewTemplateId ? 'No steps configured for this template.' : 'Select a template to preview its steps.'}
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 0 }}>
                  {steps.map((step, i) => (
                    <div key={step.id} style={{ display: 'flex', alignItems: 'stretch' }}>
                      {/* Connector line */}
                      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginRight: 14, width: 28 }}>
                        <div style={{
                          width: 28, height: 28, borderRadius: '50%',
                          background: C.blueL, border: `2px solid ${C.blue}`,
                          display: 'flex', alignItems: 'center', justifyContent: 'center',
                          fontSize: 11, fontWeight: 700, color: C.blue, flexShrink: 0,
                        }}>{i + 1}</div>
                        {i < steps.length - 1 && (
                          <div style={{ width: 2, flex: 1, background: C.border, margin: '4px 0' }} />
                        )}
                      </div>
                      {/* Step card */}
                      <div style={{
                        flex: 1, background: '#fff', border: `1px solid ${C.border}`,
                        borderRadius: 8, padding: '10px 14px', marginBottom: 8,
                      }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                          <i className={`fa-solid ${APPROVER_ICONS[step.approverType] ?? 'fa-user'}`}
                            style={{ color: C.blue, fontSize: 13 }} />
                          <span style={{ fontWeight: 600, fontSize: 13, color: C.navy }}>{step.name}</span>
                          <span style={{
                            marginLeft: 'auto', fontSize: 11, padding: '2px 8px',
                            borderRadius: 99, background: C.purpleL, color: C.purple, fontWeight: 600,
                          }}>{step.approverType.replace(/_/g, ' ')}</span>
                          {step.approverRole && (
                            <span style={{
                              fontSize: 11, padding: '2px 8px', borderRadius: 99,
                              background: C.blueL, color: C.blue, fontWeight: 600,
                            }}>{step.approverRole}</span>
                          )}
                          {step.slaHours && (
                            <span style={{ fontSize: 11, color: C.muted }}>
                              <i className="fa-regular fa-clock" style={{ marginRight: 3 }} />{step.slaHours}h SLA
                            </span>
                          )}
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </Section>
          </>
        )}
      </div>

      {/* ── Toast ── */}
      {toast && (
        <div style={{
          position: 'fixed', bottom: 24, right: 24, zIndex: 9999,
          background: toast.type === 'ok' ? C.greenL : C.redL,
          border: `1px solid ${toast.type === 'ok' ? C.green : C.red}`,
          color: toast.type === 'ok' ? C.green : C.red,
          padding: '12px 20px', borderRadius: 8, fontSize: 13, fontWeight: 600,
          boxShadow: '0 4px 20px rgba(0,0,0,0.12)',
          display: 'flex', alignItems: 'center', gap: 8,
        }}>
          <i className={`fa-solid ${toast.type === 'ok' ? 'fa-circle-check' : 'fa-circle-exclamation'}`} />
          {toast.msg}
        </div>
      )}
    </div>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function Section({ title, subtitle, children }: {
  title: string; subtitle?: string; children: React.ReactNode;
}) {
  return (
    <div style={{
      background: '#fff', border: `1px solid ${C.border}`, borderRadius: 10,
      padding: '18px 20px', marginBottom: 18,
    }}>
      <div style={{ marginBottom: 14 }}>
        <div style={{ fontSize: 14, fontWeight: 700, color: C.navy }}>{title}</div>
        {subtitle && <div style={{ fontSize: 12, color: C.muted, marginTop: 2 }}>{subtitle}</div>}
      </div>
      {children}
    </div>
  );
}

function FieldCol({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: '#374151', marginBottom: 4 }}>
        {label}
      </label>
      {children}
    </div>
  );
}

function Btn({ label, icon, onClick, primary, danger, disabled }: {
  label: string; icon?: string; onClick: () => void;
  primary?: boolean; danger?: boolean; disabled?: boolean;
}) {
  const bg = danger ? C.redL : primary ? C.blue : '#fff';
  const fg = danger ? C.red  : primary ? '#fff' : C.text;
  const bd = danger ? C.red  : primary ? C.blue : C.border;
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      style={{
        padding: '8px 14px', borderRadius: 6, border: `1px solid ${bd}`,
        background: disabled ? C.faint : bg, color: disabled ? '#fff' : fg,
        cursor: disabled ? 'not-allowed' : 'pointer', fontSize: 12,
        fontWeight: 600, display: 'flex', alignItems: 'center', gap: 6,
        whiteSpace: 'nowrap',
      }}
    >
      {icon && <i className={`fa-solid ${icon}`} />}
      {label}
    </button>
  );
}

function InlineError({ msg }: { msg: string }) {
  return (
    <div style={{
      background: C.redL, border: `1px solid ${C.red}`, borderRadius: 7,
      padding: '8px 12px', fontSize: 12, color: C.red,
      display: 'flex', gap: 8, marginBottom: 12,
    }}>
      <i className="fa-solid fa-circle-exclamation" style={{ flexShrink: 0, marginTop: 1 }} />
      <span>{msg}</span>
    </div>
  );
}

function InlineWarning({ msg }: { msg: string }) {
  return (
    <div style={{
      background: C.amberL, border: `1px solid ${C.amber}`, borderRadius: 7,
      padding: '8px 12px', fontSize: 12, color: C.amber,
      display: 'flex', gap: 8, marginBottom: 12,
    }}>
      <i className="fa-solid fa-triangle-exclamation" style={{ flexShrink: 0, marginTop: 1 }} />
      <span>{msg}</span>
    </div>
  );
}
