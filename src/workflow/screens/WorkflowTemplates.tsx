/**
 * WorkflowTemplates — Enterprise Workflow Designer
 *
 * Layout
 * ──────────────────────────────────────────────────────
 *  LEFT PANEL (300px)           RIGHT PANEL (flex)
 *  ┌─────────────────────┐      ┌──────────────────────────────────────┐
 *  │ 🔍 Search           │      │ Template header  [Clone][Publish][⋮] │
 *  │ + New Template      │      │ Description · Module · Version       │
 *  │─────────────────────│      │──────────────────────────────────────│
 *  │ ▸ Expense Approval  │      │  ①  Manager Approval   48h  [Edit]  │
 *  │   v2  ● Active      │      │  │                                   │
 *  │   v1  ○ Draft       │      │  ②  Finance Approval   72h  [Edit]  │
 *  │ ▸ Leave Approval    │      │  │                                   │
 *  │   v1  ○ Draft       │      │  [+ Add Step]                        │
 *  └─────────────────────┘      └──────────────────────────────────────┘
 *
 * Route: /admin/workflow/templates  (requires workflow.admin)
 */

import { useState, useEffect, useCallback, useRef } from 'react';
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

// ─── Types ────────────────────────────────────────────────────────────────────

interface UserOption {
  profileId: string;
  name:      string;
  email:     string;
  jobTitle:  string | null;
}

interface RoleOption {
  code: string;
  name: string;
}

interface WfTemplate {
  id:            string;
  code:          string;
  name:          string;
  description:   string | null;
  moduleCode:    string;
  isActive:      boolean;
  version:       number;
  parentVersion: number | null;
  effectiveFrom: string | null;
  publishedAt:   string | null;
  createdAt:     string;
}

interface WfStep {
  id:                 string;
  stepOrder:          number;
  name:               string;
  approverType:       string;
  approverRole:       string | null;
  approverProfileId:  string | null;
  slaHours:           number | null;
  reminderAfterHours: number | null;
  escalationAfterHours: number | null;
  allowDelegation:    boolean;
  isMandatory:        boolean;
  isActive:           boolean;
}

interface WfCondition {
  id:        string;
  stepId:    string;
  fieldPath: string;
  operator:  string;
  value:     string;
  skipStep:  boolean;
}

type ConditionDraft = Omit<WfCondition, 'id' | 'stepId'>;

// ─── Constants ────────────────────────────────────────────────────────────────

const APPROVER_TYPES = [
  { value: 'MANAGER',       label: 'Line Manager',    icon: 'fa-user-tie'     },
  { value: 'DEPT_HEAD',     label: 'Department Head', icon: 'fa-building'     },
  { value: 'ROLE',          label: 'Role',            icon: 'fa-users-gear'   },
  { value: 'SPECIFIC_USER', label: 'Specific User',   icon: 'fa-user-check'   },
  { value: 'SELF',          label: 'Self (Submitter)', icon: 'fa-user-circle' },
  { value: 'RULE_BASED',    label: 'Dynamic Rule',    icon: 'fa-diagram-next' },
];

const MODULES = [
  { value: 'expense_reports',  label: 'Expense Reports'  },
  { value: 'leave_requests',   label: 'Leave Requests'   },
  { value: 'travel_requests',  label: 'Travel Requests'  },
  { value: 'purchase_orders',  label: 'Purchase Orders'  },
  { value: 'employee_changes', label: 'Employee Changes' },
  { value: 'general',          label: 'General'          },
];

// Metadata fields available for condition evaluation (keyed by module)
const CONDITION_FIELDS: Record<string, { value: string; label: string; type: 'numeric' | 'text' }[]> = {
  expense_reports: [
    { value: 'total_amount',  label: 'Total Amount',   type: 'numeric' },
    { value: 'currency_id',   label: 'Currency',       type: 'text'    },
    { value: 'dept_id',       label: 'Department ID',  type: 'text'    },
    { value: 'work_country',  label: 'Work Country',   type: 'text'    },
    { value: 'employee_id',   label: 'Employee ID',    type: 'text'    },
  ],
  _default: [
    { value: 'dept_id',      label: 'Department ID', type: 'text'    },
    { value: 'work_country', label: 'Work Country',  type: 'text'    },
    { value: 'employee_id',  label: 'Employee ID',   type: 'text'    },
  ],
};

const CONDITION_OPERATORS = [
  { value: 'gt',      label: '>  greater than',        types: ['numeric'] },
  { value: 'gte',     label: '≥  at least',            types: ['numeric'] },
  { value: 'lt',      label: '<  less than',           types: ['numeric'] },
  { value: 'lte',     label: '≤  at most',             types: ['numeric'] },
  { value: 'eq',      label: '=  equals',              types: ['numeric', 'text'] },
  { value: 'neq',     label: '≠  not equals',          types: ['numeric', 'text'] },
  { value: 'in',      label: '∈  is one of (CSV)',     types: ['text'] },
  { value: 'not_in',  label: '∉  is not one of (CSV)', types: ['text'] },
];

const EMPTY_CONDITION: ConditionDraft = {
  fieldPath: 'total_amount',
  operator:  'gte',
  value:     '',
  skipStep:  true,
};

const EMPTY_STEP: Omit<WfStep, 'id' | 'stepOrder' | 'isActive'> = {
  name: '',
  approverType: 'MANAGER',
  approverRole: null,
  approverProfileId: null,
  slaHours: null,
  reminderAfterHours: null,
  escalationAfterHours: null,
  allowDelegation: true,
  isMandatory: true,
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtDate(iso: string | null) {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(iso));
}

function approverLabel(step: WfStep, resolvedName?: string) {
  const type = APPROVER_TYPES.find(t => t.value === step.approverType);
  const base = type?.label ?? step.approverType;
  if (step.approverType === 'ROLE' && step.approverRole) return `${base} · ${step.approverRole}`;
  if (step.approverType === 'SPECIFIC_USER') return resolvedName ? `${base} · ${resolvedName}` : base;
  if (step.approverType === 'RULE_BASED' && step.approverRole) return `${base} · ${step.approverRole}`;
  return base;
}

function approverIcon(type: string) {
  return APPROVER_TYPES.find(t => t.value === type)?.icon ?? 'fa-user';
}

function moduleLabel(code: string) {
  return MODULES.find(m => m.value === code)?.label ?? code.replace(/_/g, ' ');
}

// Group templates by code, sorted: active first then by version desc within each group
function groupTemplates(templates: WfTemplate[]): Map<string, WfTemplate[]> {
  const map = new Map<string, WfTemplate[]>();
  for (const t of templates) {
    if (!map.has(t.code)) map.set(t.code, []);
    map.get(t.code)!.push(t);
  }
  // Sort each group: active first, then by version desc
  for (const [, group] of map) {
    group.sort((a, b) => {
      if (a.isActive !== b.isActive) return a.isActive ? -1 : 1;
      return b.version - a.version;
    });
  }
  return map;
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function StatusBadge({ isActive, draft }: { isActive: boolean; draft?: boolean }) {
  if (draft)     return <Pill label="Draft"    bg={C.amberL}  color={C.amber}  />;
  if (isActive)  return <Pill label="Active"   bg={C.greenL}  color={C.green}  />;
  return              <Pill label="Inactive" bg="#F3F4F6"   color={C.faint}  />;
}

function Pill({ label, bg, color }: { label: string; bg: string; color: string }) {
  return (
    <span style={{
      fontSize: 10, fontWeight: 700, borderRadius: 4,
      padding: '2px 7px', background: bg, color,
      letterSpacing: '0.04em', textTransform: 'uppercase',
    }}>
      {label}
    </span>
  );
}

function Btn({
  label, icon, onClick, variant = 'ghost', disabled, small,
}: {
  label: string; icon?: string; onClick?: () => void;
  variant?: 'primary' | 'danger' | 'success' | 'ghost' | 'outline';
  disabled?: boolean; small?: boolean;
}) {
  const styles: Record<string, React.CSSProperties> = {
    primary: { background: C.blue,   color: '#fff', border: 'none' },
    danger:  { background: C.redL,   color: C.red,  border: `1px solid #FECACA` },
    success: { background: C.greenL, color: C.green,border: `1px solid #BBF7D0` },
    ghost:   { background: '#fff',   color: C.text, border: `1px solid ${C.border}` },
    outline: { background: 'transparent', color: C.blue, border: `1px solid ${C.blue}` },
  };
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      style={{
        ...styles[variant],
        display: 'inline-flex', alignItems: 'center', gap: 5,
        padding: small ? '4px 10px' : '6px 13px',
        borderRadius: 6, fontWeight: 600,
        fontSize: small ? 11 : 12,
        cursor: disabled ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.6 : 1,
        whiteSpace: 'nowrap',
      }}
    >
      {icon && <i className={`fas ${icon}`} style={{ fontSize: small ? 9 : 11 }} />}
      {label}
    </button>
  );
}

function Divider() {
  return <div style={{ borderTop: `1px solid ${C.border}`, margin: '16px 0' }} />;
}

// ─── Main Component ───────────────────────────────────────────────────────────

export default function WorkflowTemplates() {
  const [templates,    setTemplates]    = useState<WfTemplate[]>([]);
  const [selectedId,   setSelectedId]   = useState<string | null>(null);
  const [steps,        setSteps]        = useState<WfStep[]>([]);
  const [search,       setSearch]       = useState('');
  const [expandedCode, setExpandedCode] = useState<Set<string>>(new Set());

  const [loadingTpl,   setLoadingTpl]   = useState(false);
  const [loadingSteps, setLoadingSteps] = useState(false);
  const [saving,       setSaving]       = useState(false);

  // Modals
  const [showNewTpl,   setShowNewTpl]   = useState(false);
  const [showStepModal,setShowStepModal]= useState(false);
  const [editingStepId,setEditingStepId]= useState<string | null>(null);

  // Forms
  const [newTpl, setNewTpl] = useState({
    name: '', code: '', moduleCode: 'expense_reports',
    description: '', effectiveFrom: '',
  });
  const [stepDraft, setStepDraft] = useState<typeof EMPTY_STEP & { stepOrder: number }>({
    ...EMPTY_STEP, stepOrder: 1,
  });

  const [toast, setToast] = useState<{ type: 'ok' | 'err'; msg: string } | null>(null);
  const toastTimer = useRef<number | null>(null);

  // Roles for approver dropdown (loaded once on mount)
  const [roleOptions, setRoleOptions] = useState<RoleOption[]>([]);

  // Condition counts per step (shown as chips on step cards)
  const [conditionCounts, setConditionCounts] = useState<Map<string, number>>(new Map());

  // Conditions (inside step modal)
  const [conditions,        setConditions]        = useState<WfCondition[]>([]);
  const [conditionDraft,    setConditionDraft]    = useState<ConditionDraft>(EMPTY_CONDITION);
  const [showCondForm,      setShowCondForm]      = useState(false);
  // In-memory conditions collected while adding a brand-new step (no step ID yet)
  const [pendingConditions, setPendingConditions] = useState<ConditionDraft[]>([]);

  // Specific-user search (inside step modal)
  const [userQuery,   setUserQuery]   = useState('');
  const [userResults, setUserResults] = useState<UserOption[]>([]);
  const [userLoading, setUserLoading] = useState(false);
  const [selectedUser,setSelectedUser]= useState<UserOption | null>(null);
  const userSearchTimer = useRef<number | null>(null);

  function showToast(type: 'ok' | 'err', msg: string) {
    setToast({ type, msg });
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 4000);
  }

  // ── User search for SPECIFIC_USER steps ────────────────────────────────────

  function searchUsers(q: string) {
    setUserQuery(q);
    if (userSearchTimer.current) clearTimeout(userSearchTimer.current);
    if (!q.trim()) { setUserResults([]); return; }
    userSearchTimer.current = window.setTimeout(async () => {
      setUserLoading(true);
      const { data } = await supabase
        .from('profiles')
        .select('id, employees!inner(name, business_email, job_title)')
        .ilike('employees.name', `%${q}%`)
        .eq('is_active', true)
        .limit(8);
      setUserLoading(false);
      if (data) {
        setUserResults(data.map((p: any) => ({
          profileId: p.id,
          name:      p.employees?.name      ?? '—',
          email:     p.employees?.business_email ?? '',
          jobTitle:  p.employees?.job_title  ?? null,
        })));
      }
    }, 280);
  }

  function selectUser(u: UserOption) {
    setSelectedUser(u);
    setUserQuery(u.name);
    setUserResults([]);
    setStepDraft(d => ({ ...d, approverProfileId: u.profileId }));
  }

  function clearUserSelection() {
    setSelectedUser(null);
    setUserQuery('');
    setUserResults([]);
    setStepDraft(d => ({ ...d, approverProfileId: null }));
  }

  // Reset user search when modal opens/closes or type changes
  function resetUserSearch() {
    setUserQuery('');
    setUserResults([]);
    setSelectedUser(null);
    setUserLoading(false);
  }

  // ── Data loading ────────────────────────────────────────────────────────────

  const loadTemplates = useCallback(async () => {
    setLoadingTpl(true);
    const { data, error } = await supabase
      .from('workflow_templates')
      .select('*')
      .order('code')
      .order('version', { ascending: false });

    if (error) showToast('err', error.message);
    else {
      const mapped: WfTemplate[] = (data ?? []).map(t => ({
        id:            t.id,
        code:          t.code,
        name:          t.name,
        description:   t.description,
        moduleCode:    t.module_code,
        isActive:      t.is_active,
        version:       t.version,
        parentVersion: t.parent_version,
        effectiveFrom: t.effective_from,
        publishedAt:   t.published_at,
        createdAt:     t.created_at,
      }));
      setTemplates(mapped);
      // Auto-expand all groups
      setExpandedCode(new Set(mapped.map(t => t.code)));
    }
    setLoadingTpl(false);
  }, []);

  useEffect(() => { loadTemplates(); }, [loadTemplates]);

  // Load non-system roles for the approver dropdown (refreshes automatically
  // when the component mounts — always reflects the latest roles in the DB)
  useEffect(() => {
    supabase
      .from('roles')
      .select('code, name')
      .eq('is_system', false)
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => {
        setRoleOptions((data ?? []).map(r => ({ code: r.code, name: r.name })));
      });
  }, []);

  const loadSteps = useCallback(async (templateId: string) => {
    setLoadingSteps(true);
    const { data, error } = await supabase
      .from('workflow_steps')
      .select('*')
      .eq('template_id', templateId)
      .order('step_order');

    if (error) showToast('err', error.message);
    else {
      const mapped = (data ?? []).map(s => ({
        id:                   s.id,
        stepOrder:            s.step_order,
        name:                 s.name,
        approverType:         s.approver_type,
        approverRole:         s.approver_role,
        approverProfileId:    s.approver_profile_id,
        slaHours:             s.sla_hours,
        reminderAfterHours:   s.reminder_after_hours,
        escalationAfterHours: s.escalation_after_hours,
        allowDelegation:      s.allow_delegation,
        isMandatory:          s.is_mandatory,
        isActive:             s.is_active,
      }));
      setSteps(mapped);

      // Fetch condition counts so step cards can show a badge
      const stepIds = mapped.map(s => s.id);
      if (stepIds.length > 0) {
        const { data: condData } = await supabase
          .from('workflow_step_conditions')
          .select('step_id')
          .in('step_id', stepIds);

        const counts = new Map<string, number>();
        (condData ?? []).forEach((c: { step_id: string }) => {
          counts.set(c.step_id, (counts.get(c.step_id) ?? 0) + 1);
        });
        setConditionCounts(counts);
      } else {
        setConditionCounts(new Map());
      }
    }
    setLoadingSteps(false);
  }, []);

  useEffect(() => {
    if (selectedId) loadSteps(selectedId);
    else setSteps([]);
  }, [selectedId, loadSteps]);

  const selected = templates.find(t => t.id === selectedId) ?? null;

  // ── Actions ─────────────────────────────────────────────────────────────────

  async function createTemplate() {
    if (!newTpl.name.trim() || !newTpl.code.trim()) {
      showToast('err', 'Name and Code are required.'); return;
    }
    setSaving(true);
    const { error } = await supabase.from('workflow_templates').insert({
      name:          newTpl.name.trim(),
      code:          newTpl.code.trim().toUpperCase().replace(/\s+/g, '_'),
      module_code:   newTpl.moduleCode,
      description:   newTpl.description.trim() || null,
      effective_from:newTpl.effectiveFrom || null,
      is_active:     false,
      version:       1,
    });
    setSaving(false);
    if (error) { showToast('err', error.message); return; }
    showToast('ok', 'Template created as Draft.');
    setShowNewTpl(false);
    setNewTpl({ name: '', code: '', moduleCode: 'expense_reports', description: '', effectiveFrom: '' });
    await loadTemplates();
  }

  async function cloneTemplate() {
    if (!selectedId) return;
    setSaving(true);
    const { data, error } = await supabase.rpc('wf_clone_template', { p_template_id: selectedId });
    setSaving(false);
    if (error) { showToast('err', error.message); return; }
    showToast('ok', 'New draft version created.');
    await loadTemplates();
    if (data) setSelectedId(data as string);
  }

  async function publishTemplate() {
    if (!selectedId) return;
    if (!confirm('Publish this version as the active template? The current active version will be deactivated.')) return;
    setSaving(true);
    const { error } = await supabase.rpc('wf_publish_template', { p_template_id: selectedId });
    setSaving(false);
    if (error) { showToast('err', error.message); return; }
    showToast('ok', 'Template published and is now active.');
    await loadTemplates();
  }

  async function toggleTemplateActive() {
    if (!selected) return;
    if (selected.isActive) {
      if (!confirm('Deactivate this template? No new submissions will be accepted until another version is published.')) return;
      const { error } = await supabase.from('workflow_templates')
        .update({ is_active: false, updated_at: new Date().toISOString() })
        .eq('id', selected.id);
      if (error) showToast('err', error.message);
      else { showToast('ok', 'Template deactivated.'); await loadTemplates(); }
    }
  }

  async function saveStep() {
    if (!selectedId || !stepDraft.name.trim()) {
      showToast('err', 'Step name is required.'); return;
    }
    setSaving(true);

    // Validation: SPECIFIC_USER requires a profile to be selected
    if (stepDraft.approverType === 'SPECIFIC_USER' && !stepDraft.approverProfileId) {
      showToast('err', 'Please select a user for this step.'); setSaving(false); return;
    }

    const roleValue       = stepDraft.approverType === 'ROLE' || stepDraft.approverType === 'RULE_BASED'
      ? (stepDraft.approverRole ?? null) : null;
    const profileIdValue  = stepDraft.approverType === 'SPECIFIC_USER'
      ? (stepDraft.approverProfileId ?? null) : null;

    if (editingStepId) {
      // Update
      const { error } = await supabase.from('workflow_steps').update({
        name:                  stepDraft.name.trim(),
        approver_type:         stepDraft.approverType,
        approver_role:         roleValue,
        approver_profile_id:   profileIdValue,
        sla_hours:             stepDraft.slaHours,
        reminder_after_hours:  stepDraft.reminderAfterHours,
        escalation_after_hours:stepDraft.escalationAfterHours,
        allow_delegation:      stepDraft.allowDelegation,
        is_mandatory:          stepDraft.isMandatory,
      }).eq('id', editingStepId);
      if (error) { showToast('err', error.message); setSaving(false); return; }
    } else {
      // Add
      const { error } = await supabase.rpc('wf_add_step', {
        p_template_id:         selectedId,
        p_step_order:          stepDraft.stepOrder,
        p_name:                stepDraft.name.trim(),
        p_approver_type:       stepDraft.approverType,
        p_approver_role:       roleValue,
        p_approver_profile_id: profileIdValue,
        p_sla_hours:           stepDraft.slaHours,
        p_reminder_hours:      stepDraft.reminderAfterHours,
        p_escalation_hours:    stepDraft.escalationAfterHours,
        p_allow_delegation:    stepDraft.allowDelegation,
        p_is_mandatory:        stepDraft.isMandatory,
      });
      if (error) { showToast('err', error.message); setSaving(false); return; }

      // If conditions were queued, look up the new step ID and persist them
      if (pendingConditions.length > 0) {
        const { data: newStep } = await supabase
          .from('workflow_steps')
          .select('id')
          .eq('template_id', selectedId)
          .eq('step_order', stepDraft.stepOrder)
          .single();

        if (newStep) {
          await supabase.from('workflow_step_conditions').insert(
            pendingConditions.map(c => ({
              step_id:    newStep.id,
              field_path: c.fieldPath,
              operator:   c.operator,
              value:      c.value,
              skip_step:  c.skipStep,
            }))
          );
        }
        setPendingConditions([]);
      }
    }

    setSaving(false);
    showToast('ok', editingStepId ? 'Step updated.' : 'Step added.');
    setShowStepModal(false);
    setEditingStepId(null);
    resetUserSearch();
    await loadSteps(selectedId);
  }

  async function deleteStep(stepId: string, stepName: string) {
    if (!confirm(`Delete step "${stepName}"? This cannot be undone.`)) return;
    const { error } = await supabase.rpc('wf_delete_step', { p_step_id: stepId });
    if (error) showToast('err', error.message);
    else { showToast('ok', 'Step deleted.'); if (selectedId) await loadSteps(selectedId); }
  }

  async function loadConditions(stepId: string) {
    const { data } = await supabase
      .from('workflow_step_conditions')
      .select('*')
      .eq('step_id', stepId)
      .order('created_at');
    setConditions((data ?? []).map((r: any) => ({
      id:        r.id,
      stepId:    r.step_id,
      fieldPath: r.field_path,
      operator:  r.operator,
      value:     r.value,
      skipStep:  r.skip_step,
    })));
  }

  async function addCondition() {
    if (!conditionDraft.value.trim()) { showToast('err', 'Condition value is required.'); return; }

    if (editingStepId) {
      // Edit mode: write straight to DB
      const { error } = await supabase.from('workflow_step_conditions').insert({
        step_id:    editingStepId,
        field_path: conditionDraft.fieldPath,
        operator:   conditionDraft.operator,
        value:      conditionDraft.value.trim(),
        skip_step:  conditionDraft.skipStep,
      });
      if (error) { showToast('err', error.message); return; }
      await loadConditions(editingStepId);
    } else {
      // Add mode: queue in memory; will be saved once the step ID is known
      setPendingConditions(prev => [...prev, { ...conditionDraft, value: conditionDraft.value.trim() }]);
    }

    setShowCondForm(false);
    setConditionDraft(EMPTY_CONDITION);
  }

  async function deleteCondition(condId: string) {
    const { error } = await supabase
      .from('workflow_step_conditions')
      .delete()
      .eq('id', condId);
    if (error) { showToast('err', error.message); return; }
    if (editingStepId) await loadConditions(editingStepId);
  }

  function deletePendingCondition(idx: number) {
    setPendingConditions(prev => prev.filter((_, i) => i !== idx));
  }

  function openAddStep() {
    const nextOrder = steps.length > 0 ? Math.max(...steps.map(s => s.stepOrder)) + 1 : 1;
    setStepDraft({ ...EMPTY_STEP, stepOrder: nextOrder });
    setEditingStepId(null);
    setConditions([]);
    setPendingConditions([]);
    setShowCondForm(false);
    setConditionDraft(EMPTY_CONDITION);
    resetUserSearch();
    setShowStepModal(true);
  }

  function openEditStep(step: WfStep) {
    setStepDraft({
      name:                step.name,
      approverType:        step.approverType,
      approverRole:        step.approverRole,
      approverProfileId:   step.approverProfileId,
      slaHours:            step.slaHours,
      reminderAfterHours:  step.reminderAfterHours,
      escalationAfterHours:step.escalationAfterHours,
      allowDelegation:     step.allowDelegation,
      isMandatory:         step.isMandatory,
      stepOrder:           step.stepOrder,
    });
    setEditingStepId(step.id);
    // If editing a SPECIFIC_USER step, pre-load the user name
    if (step.approverType === 'SPECIFIC_USER' && step.approverProfileId) {
      setUserQuery('Loading…');
      setSelectedUser(null);
      setUserResults([]);
      supabase
        .from('profiles')
        .select('id, employees!inner(name, business_email, job_title)')
        .eq('id', step.approverProfileId)
        .single()
        .then(({ data }) => {
          if (data) {
            const u: UserOption = {
              profileId: data.id,
              name:      (data as any).employees?.name ?? '—',
              email:     (data as any).employees?.business_email ?? '',
              jobTitle:  (data as any).employees?.job_title ?? null,
            };
            setSelectedUser(u);
            setUserQuery(u.name);
          }
        });
    } else {
      resetUserSearch();
    }
    setConditions([]);
    setShowCondForm(false);
    setConditionDraft(EMPTY_CONDITION);
    loadConditions(step.id);
    setShowStepModal(true);
  }

  // ── Filtered view ───────────────────────────────────────────────────────────

  const filteredTemplates = search.trim()
    ? templates.filter(t =>
        t.name.toLowerCase().includes(search.toLowerCase()) ||
        t.code.toLowerCase().includes(search.toLowerCase()) ||
        t.moduleCode.toLowerCase().includes(search.toLowerCase()))
    : templates;

  const groups = groupTemplates(filteredTemplates);

  // ── Render ───────────────────────────────────────────────────────────────────

  return (
    <div style={{ display: 'flex', height: '100%', minHeight: 0, fontFamily: 'inherit' }}>

      {/* ════════════════════════════════════════════════════════
          LEFT PANEL — Template list
      ════════════════════════════════════════════════════════ */}
      <div style={{
        width: 300, flexShrink: 0,
        borderRight: `1px solid ${C.border}`,
        display: 'flex', flexDirection: 'column',
        background: '#fff',
      }}>
        {/* Panel header */}
        <div style={{ padding: '20px 16px 12px', borderBottom: `1px solid ${C.border}` }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <span style={{ fontWeight: 700, fontSize: 13, color: C.navy }}>Templates</span>
            <Btn label="New" icon="fa-plus" variant="primary" small onClick={() => setShowNewTpl(true)} />
          </div>
          <input
            value={search}
            onChange={e => setSearch(e.target.value)}
            placeholder="Search templates…"
            style={{
              width: '100%', padding: '6px 10px', fontSize: 12,
              border: `1px solid ${C.border}`, borderRadius: 6,
              outline: 'none', boxSizing: 'border-box', color: C.text,
            }}
          />
        </div>

        {/* Template groups */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '8px 0' }}>
          {loadingTpl ? (
            <div style={{ padding: 24, textAlign: 'center', color: C.faint, fontSize: 12 }}>
              <i className="fas fa-spinner fa-spin" /> Loading…
            </div>
          ) : groups.size === 0 ? (
            <div style={{ padding: 24, textAlign: 'center', color: C.faint, fontSize: 12 }}>
              No templates found.
            </div>
          ) : (
            Array.from(groups.entries()).map(([code, versions]) => {
              const isExpanded = expandedCode.has(code);
              const activeVersion = versions.find(v => v.isActive);
              const groupName = versions[0].name;

              return (
                <div key={code}>
                  {/* Group header */}
                  <div
                    onClick={() => setExpandedCode(prev => {
                      const next = new Set(prev);
                      isExpanded ? next.delete(code) : next.add(code);
                      return next;
                    })}
                    style={{
                      display: 'flex', alignItems: 'center', gap: 6,
                      padding: '8px 14px', cursor: 'pointer',
                      userSelect: 'none',
                    }}
                  >
                    <i
                      className={`fas fa-chevron-${isExpanded ? 'down' : 'right'}`}
                      style={{ fontSize: 9, color: C.faint, width: 10 }}
                    />
                    <i className="fas fa-diagram-next" style={{ fontSize: 11, color: C.blue }} />
                    <span style={{ fontWeight: 600, fontSize: 12, color: C.navy, flex: 1 }}>
                      {groupName}
                    </span>
                    {activeVersion && (
                      <span style={{
                        fontSize: 9, fontWeight: 700, borderRadius: 3,
                        padding: '1px 5px', background: C.greenL, color: C.green,
                      }}>
                        v{activeVersion.version} live
                      </span>
                    )}
                  </div>

                  {/* Version rows */}
                  {isExpanded && versions.map(v => (
                    <div
                      key={v.id}
                      onClick={() => setSelectedId(v.id)}
                      style={{
                        display: 'flex', alignItems: 'center', gap: 8,
                        padding: '7px 14px 7px 32px',
                        background: selectedId === v.id ? C.blueL : 'transparent',
                        borderLeft: selectedId === v.id ? `3px solid ${C.blue}` : '3px solid transparent',
                        cursor: 'pointer',
                        borderBottom: `1px solid ${C.border}`,
                      }}
                    >
                      <div style={{
                        width: 8, height: 8, borderRadius: '50%', flexShrink: 0,
                        background: v.isActive ? C.green : v.parentVersion != null ? C.amber : C.faint,
                      }} />
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 12, fontWeight: 600, color: C.text }}>
                          Version {v.version}
                          {v.parentVersion != null && (
                            <span style={{ fontWeight: 400, color: C.faint, marginLeft: 4 }}>
                              (cloned v{v.parentVersion})
                            </span>
                          )}
                        </div>
                        <div style={{ fontSize: 10, color: C.faint, marginTop: 1 }}>
                          {v.isActive
                            ? `Published ${fmtDate(v.publishedAt)}`
                            : v.effectiveFrom
                              ? `Effective ${fmtDate(v.effectiveFrom)}`
                              : 'Draft'}
                        </div>
                      </div>
                      <StatusBadge isActive={v.isActive} draft={!v.isActive && !v.publishedAt} />
                    </div>
                  ))}
                </div>
              );
            })
          )}
        </div>
      </div>

      {/* ════════════════════════════════════════════════════════
          RIGHT PANEL — Template detail + steps
      ════════════════════════════════════════════════════════ */}
      <div style={{ flex: 1, minWidth: 0, overflowY: 'auto', background: C.bg, padding: 28 }}>

        {/* Toast */}
        {toast && (
          <div style={{
            position: 'fixed', bottom: 24, right: 28,
            padding: '10px 18px', borderRadius: 8, fontSize: 13, zIndex: 9999,
            background: toast.type === 'ok' ? C.greenL : C.redL,
            border: `1px solid ${toast.type === 'ok' ? '#BBF7D0' : '#FECACA'}`,
            color: toast.type === 'ok' ? C.green : C.red,
            boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
            display: 'flex', alignItems: 'center', gap: 8,
          }}>
            <i className={`fas ${toast.type === 'ok' ? 'fa-circle-check' : 'fa-triangle-exclamation'}`} />
            {toast.msg}
          </div>
        )}

        {!selected ? (
          <div style={{
            display: 'flex', flexDirection: 'column', alignItems: 'center',
            justifyContent: 'center', height: 400, color: C.faint, gap: 12,
          }}>
            <i className="fas fa-diagram-next" style={{ fontSize: 40, color: C.border }} />
            <p style={{ fontSize: 14, margin: 0 }}>Select a template version to view and edit</p>
            <Btn label="New Template" icon="fa-plus" variant="outline" onClick={() => setShowNewTpl(true)} />
          </div>
        ) : (
          <>
            {/* ── Template header card ─────────────────────────────────────── */}
            <div style={{
              background: '#fff', borderRadius: 10, border: `1px solid ${C.border}`,
              padding: '20px 24px', marginBottom: 20,
            }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 16 }}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                    <h2 style={{ fontSize: 18, fontWeight: 700, color: C.navy, margin: 0 }}>
                      {selected.name}
                    </h2>
                    <span style={{
                      fontSize: 11, fontWeight: 700, color: C.blue,
                      background: C.blueL, borderRadius: 4, padding: '2px 8px',
                    }}>
                      v{selected.version}
                    </span>
                    <StatusBadge isActive={selected.isActive} draft={!selected.isActive && !selected.publishedAt} />
                  </div>
                  <p style={{ fontSize: 13, color: C.muted, margin: '6px 0 0' }}>
                    {selected.description ?? 'No description'}
                  </p>
                  <div style={{ display: 'flex', gap: 16, marginTop: 10, flexWrap: 'wrap' }}>
                    <MetaTag icon="fa-cube"       label={moduleLabel(selected.moduleCode)} />
                    <MetaTag icon="fa-code"        label={selected.code} mono />
                    {selected.effectiveFrom && (
                      <MetaTag icon="fa-calendar"  label={`Effective ${fmtDate(selected.effectiveFrom)}`} />
                    )}
                    {selected.publishedAt && (
                      <MetaTag icon="fa-rocket"    label={`Published ${fmtDate(selected.publishedAt)}`} />
                    )}
                    {selected.parentVersion && (
                      <MetaTag icon="fa-code-branch" label={`Cloned from v${selected.parentVersion}`} />
                    )}
                  </div>
                </div>

                {/* Action buttons */}
                <div style={{ display: 'flex', gap: 8, flexShrink: 0, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
                  <Btn
                    label="Clone"
                    icon="fa-code-branch"
                    variant="ghost"
                    disabled={saving}
                    onClick={cloneTemplate}
                  />
                  {!selected.isActive && (
                    <Btn
                      label="Publish"
                      icon="fa-rocket"
                      variant="success"
                      disabled={saving || steps.filter(s => s.isActive).length === 0}
                      onClick={publishTemplate}
                    />
                  )}
                  {selected.isActive && (
                    <Btn
                      label="Deactivate"
                      icon="fa-ban"
                      variant="danger"
                      disabled={saving}
                      onClick={toggleTemplateActive}
                    />
                  )}
                </div>
              </div>

              {/* Publish guard */}
              {!selected.isActive && steps.filter(s => s.isActive).length === 0 && (
                <div style={{
                  marginTop: 12, padding: '8px 12px', borderRadius: 6,
                  background: C.amberL, border: `1px solid #FDE68A`,
                  fontSize: 12, color: C.amber, display: 'flex', alignItems: 'center', gap: 7,
                }}>
                  <i className="fas fa-triangle-exclamation" />
                  Add at least one active step before publishing.
                </div>
              )}
            </div>

            {/* ── Steps timeline ────────────────────────────────────────────── */}
            <div style={{
              background: '#fff', borderRadius: 10, border: `1px solid ${C.border}`,
              padding: '20px 24px',
            }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
                <h3 style={{ fontSize: 14, fontWeight: 700, color: C.navy, margin: 0 }}>
                  Approval Steps
                  <span style={{
                    marginLeft: 8, fontSize: 11, fontWeight: 600, color: C.blue,
                    background: C.blueL, borderRadius: 10, padding: '1px 8px',
                  }}>
                    {steps.filter(s => s.isActive).length} active
                  </span>
                </h3>
                <Btn label="Add Step" icon="fa-plus" variant="primary" onClick={openAddStep} />
              </div>

              {loadingSteps ? (
                <div style={{ textAlign: 'center', padding: 32, color: C.faint, fontSize: 13 }}>
                  <i className="fas fa-spinner fa-spin" /> Loading steps…
                </div>
              ) : steps.length === 0 ? (
                <div style={{
                  textAlign: 'center', padding: '36px 24px',
                  border: `2px dashed ${C.border}`, borderRadius: 8, color: C.faint,
                }}>
                  <i className="fas fa-list-check" style={{ fontSize: 24, display: 'block', marginBottom: 10 }} />
                  <p style={{ margin: 0, fontSize: 13 }}>No steps yet.</p>
                  <p style={{ margin: '4px 0 0', fontSize: 12 }}>
                    Click <strong>Add Step</strong> to define the approval flow.
                  </p>
                </div>
              ) : (
                <div>
                  {steps.map((step, idx) => (
                    <div key={step.id} style={{ display: 'flex', gap: 16, marginBottom: 4 }}>
                      {/* Connector */}
                      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', width: 36, flexShrink: 0 }}>
                        <div style={{
                          width: 36, height: 36, borderRadius: '50%', flexShrink: 0,
                          background: step.isActive ? C.blue : C.border,
                          color: step.isActive ? '#fff' : C.faint,
                          display: 'flex', alignItems: 'center', justifyContent: 'center',
                          fontWeight: 700, fontSize: 14, boxShadow: step.isActive ? '0 2px 8px rgba(47,119,181,0.3)' : 'none',
                        }}>
                          {step.stepOrder}
                        </div>
                        {idx < steps.length - 1 && (
                          <div style={{ width: 2, flex: 1, minHeight: 20, background: C.border, margin: '4px 0' }} />
                        )}
                      </div>

                      {/* Step card */}
                      <div style={{
                        flex: 1, marginBottom: idx < steps.length - 1 ? 4 : 0,
                        border: `1px solid ${step.isActive ? C.border : '#F3F4F6'}`,
                        borderRadius: 8, padding: '14px 16px',
                        background: step.isActive ? '#fff' : '#FAFAFA',
                        opacity: step.isActive ? 1 : 0.65,
                      }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                          <div>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                              <span style={{ fontWeight: 700, fontSize: 14, color: C.navy }}>
                                {step.name}
                              </span>
                              {!step.isMandatory && (
                                <Pill label="Optional" bg={C.purpleL} color={C.purple} />
                              )}
                              {!step.isActive && (
                                <Pill label="Disabled" bg="#F3F4F6" color={C.faint} />
                              )}
                            </div>

                            {/* Step meta chips */}
                            <div style={{ display: 'flex', gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
                              <StepChip
                                icon={approverIcon(step.approverType)}
                                label={approverLabel(step)}
                                color={C.blue}
                                bg={C.blueL}
                              />
                              {step.slaHours != null && (
                                <StepChip icon="fa-clock" label={`SLA ${step.slaHours}h`} />
                              )}
                              {step.reminderAfterHours != null && (
                                <StepChip icon="fa-bell" label={`Remind ${step.reminderAfterHours}h`} color={C.amber} bg={C.amberL} />
                              )}
                              {step.escalationAfterHours != null && (
                                <StepChip icon="fa-arrow-trend-up" label={`Escalate ${step.escalationAfterHours}h`} color={C.red} bg={C.redL} />
                              )}
                              {step.allowDelegation && (
                                <StepChip icon="fa-rotate" label="Delegation OK" />
                              )}
                              {(conditionCounts.get(step.id) ?? 0) > 0 && (
                                <StepChip
                                  icon="fa-filter"
                                  label={`${conditionCounts.get(step.id)} condition${conditionCounts.get(step.id) === 1 ? '' : 's'}`}
                                  color={C.purple}
                                  bg={C.purpleL}
                                />
                              )}
                            </div>
                          </div>

                          {/* Step actions */}
                          <div style={{ display: 'flex', gap: 6, flexShrink: 0, marginLeft: 12 }}>
                            <Btn label="Edit"   icon="fa-pen"   variant="ghost" small onClick={() => openEditStep(step)} />
                            <Btn label="Delete" icon="fa-trash" variant="danger" small onClick={() => deleteStep(step.id, step.name)} />
                          </div>
                        </div>
                      </div>
                    </div>
                  ))}

                  {/* End cap */}
                  <div style={{ display: 'flex', gap: 16, alignItems: 'center', marginTop: 4 }}>
                    <div style={{
                      width: 36, height: 36, borderRadius: '50%',
                      background: C.greenL, border: `2px solid ${C.green}`,
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      flexShrink: 0,
                    }}>
                      <i className="fas fa-flag-checkered" style={{ fontSize: 14, color: C.green }} />
                    </div>
                    <span style={{ fontSize: 12, fontWeight: 600, color: C.green }}>
                      Approved — workflow complete
                    </span>
                  </div>
                </div>
              )}
            </div>
          </>
        )}
      </div>

      {/* ════════════════════════════════════════════════════════
          MODAL — New Template
      ════════════════════════════════════════════════════════ */}
      {showNewTpl && (
        <Modal
          title="New Workflow Template"
          icon="fa-diagram-next"
          onClose={() => setShowNewTpl(false)}
          onConfirm={createTemplate}
          confirmLabel="Create Template"
          saving={saving}
        >
          <ModalRow label="Template Name *">
            <input
              value={newTpl.name}
              onChange={e => {
                const name = e.target.value;
                setNewTpl(d => ({
                  ...d,
                  name,
                  code: name.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_|_$/g, ''),
                }));
              }}
              placeholder="e.g. Expense Approval"
              style={iStyle}
            />
          </ModalRow>
          <ModalRow label="Template Code *" hint="Auto-generated · editable">
            <input
              value={newTpl.code}
              onChange={e => setNewTpl(d => ({ ...d, code: e.target.value.toUpperCase().replace(/[^A-Z0-9_]/g, '') }))}
              placeholder="EXPENSE_APPROVAL"
              style={{ ...iStyle, fontFamily: 'monospace' }}
            />
          </ModalRow>
          <ModalRow label="Linked Module *">
            <select value={newTpl.moduleCode} onChange={e => setNewTpl(d => ({ ...d, moduleCode: e.target.value }))} style={iStyle}>
              {MODULES.map(m => <option key={m.value} value={m.value}>{m.label}</option>)}
            </select>
          </ModalRow>
          <ModalRow label="Description">
            <textarea
              value={newTpl.description}
              onChange={e => setNewTpl(d => ({ ...d, description: e.target.value }))}
              placeholder="Describe the purpose of this workflow…"
              rows={3}
              style={{ ...iStyle, resize: 'vertical' }}
            />
          </ModalRow>
          <ModalRow label="Effective From">
            <input
              type="date"
              value={newTpl.effectiveFrom}
              onChange={e => setNewTpl(d => ({ ...d, effectiveFrom: e.target.value }))}
              style={iStyle}
            />
          </ModalRow>
          <div style={{
            padding: '10px 12px', borderRadius: 6, background: C.blueL,
            border: `1px solid #BFDBFE`, fontSize: 12, color: '#1D4ED8',
            display: 'flex', gap: 8, alignItems: 'flex-start',
          }}>
            <i className="fas fa-info-circle" style={{ marginTop: 1 }} />
            <span>New templates are created as <strong>Draft</strong>. Add steps, then publish to make them active.</span>
          </div>
        </Modal>
      )}

      {/* ════════════════════════════════════════════════════════
          MODAL — Add / Edit Step
      ════════════════════════════════════════════════════════ */}
      {showStepModal && (
        <Modal
          title={editingStepId ? 'Edit Step' : 'Add Approval Step'}
          icon="fa-list-check"
          onClose={() => { setShowStepModal(false); setEditingStepId(null); resetUserSearch(); }}
          onConfirm={saveStep}
          confirmLabel={editingStepId ? 'Save Changes' : 'Add Step'}
          saving={saving}
          wide
        >
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
            <ModalRow label="Step Name *" span={2}>
              <input
                value={stepDraft.name}
                onChange={e => setStepDraft(d => ({ ...d, name: e.target.value }))}
                placeholder="e.g. Manager Approval"
                style={iStyle}
              />
            </ModalRow>

            <ModalRow label="Sequence Number">
              <input
                type="number" min={1}
                value={stepDraft.stepOrder}
                onChange={e => setStepDraft(d => ({ ...d, stepOrder: Number(e.target.value) }))}
                style={iStyle}
              />
            </ModalRow>

            <ModalRow label="Approver Type *">
              <select
                value={stepDraft.approverType}
                onChange={e => {
                  const t = e.target.value;
                  setStepDraft(d => ({ ...d, approverType: t, approverRole: null, approverProfileId: null }));
                  if (t !== 'SPECIFIC_USER') resetUserSearch();
                }}
                style={iStyle}
              >
                {APPROVER_TYPES.map(t => (
                  <option key={t.value} value={t.value}>{t.label}</option>
                ))}
              </select>
            </ModalRow>

            {stepDraft.approverType === 'ROLE' && (
              <ModalRow label="Role *" hint="Select an existing role">
                {roleOptions.length > 0 ? (
                  <select
                    value={stepDraft.approverRole ?? ''}
                    onChange={e => setStepDraft(d => ({ ...d, approverRole: e.target.value || null }))}
                    style={iStyle}
                  >
                    <option value="">— choose a role —</option>
                    {roleOptions.map(r => (
                      <option key={r.code} value={r.code}>{r.name}</option>
                    ))}
                  </select>
                ) : (
                  /* Fallback: no custom roles exist yet — allow freetext entry */
                  <input
                    value={stepDraft.approverRole ?? ''}
                    onChange={e => setStepDraft(d => ({ ...d, approverRole: e.target.value }))}
                    placeholder="No custom roles found — type role code"
                    style={{ ...iStyle, fontFamily: 'monospace' }}
                  />
                )}
              </ModalRow>
            )}

            {stepDraft.approverType === 'RULE_BASED' && (
              <ModalRow label="Rule Description" hint="Documents the routing logic" span={2}>
                <input
                  value={stepDraft.approverRole ?? ''}
                  onChange={e => setStepDraft(d => ({ ...d, approverRole: e.target.value }))}
                  placeholder="e.g. Route to dept head if amount > 10,000"
                  style={iStyle}
                />
              </ModalRow>
            )}

            {stepDraft.approverType === 'SPECIFIC_USER' && (
              <ModalRow label="Select User *" hint="Search by name" span={2}>
                <div style={{ position: 'relative' }}>
                  {/* Selected user chip */}
                  {selectedUser ? (
                    <div style={{
                      display: 'flex', alignItems: 'center', gap: 10,
                      padding: '8px 10px', border: `1px solid ${C.blue}`,
                      borderRadius: 6, background: C.blueL,
                    }}>
                      <div style={{
                        width: 30, height: 30, borderRadius: '50%',
                        background: C.blue, color: '#fff',
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                        fontSize: 12, fontWeight: 700, flexShrink: 0,
                      }}>
                        {selectedUser.name.charAt(0).toUpperCase()}
                      </div>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 13, fontWeight: 600, color: C.navy }}>{selectedUser.name}</div>
                        <div style={{ fontSize: 11, color: C.muted, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                          {selectedUser.jobTitle ? `${selectedUser.jobTitle} · ` : ''}{selectedUser.email}
                        </div>
                      </div>
                      <button
                        onClick={clearUserSelection}
                        style={{
                          border: 'none', background: 'none', cursor: 'pointer',
                          color: C.muted, fontSize: 14, padding: '0 2px', lineHeight: 1,
                        }}
                        title="Clear selection"
                      >
                        <i className="fas fa-xmark" />
                      </button>
                    </div>
                  ) : (
                    <>
                      <div style={{ position: 'relative' }}>
                        <i className="fas fa-magnifying-glass" style={{
                          position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)',
                          color: C.faint, fontSize: 12, pointerEvents: 'none',
                        }} />
                        <input
                          value={userQuery}
                          onChange={e => searchUsers(e.target.value)}
                          placeholder="Type a name to search…"
                          style={{ ...iStyle, paddingLeft: 30 }}
                          autoComplete="off"
                        />
                        {userLoading && (
                          <i className="fas fa-spinner fa-spin" style={{
                            position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)',
                            color: C.faint, fontSize: 12,
                          }} />
                        )}
                      </div>
                      {userResults.length > 0 && (
                        <div style={{
                          position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 50,
                          background: '#fff', border: `1px solid ${C.border}`,
                          borderRadius: 6, boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
                          marginTop: 3, maxHeight: 240, overflowY: 'auto',
                        }}>
                          {userResults.map(u => (
                            <button
                              key={u.profileId}
                              onClick={() => selectUser(u)}
                              style={{
                                width: '100%', display: 'flex', alignItems: 'center', gap: 10,
                                padding: '9px 12px', border: 'none', background: 'none',
                                cursor: 'pointer', textAlign: 'left',
                                borderBottom: `1px solid ${C.border}`,
                              }}
                              onMouseEnter={e => (e.currentTarget.style.background = C.blueL)}
                              onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                            >
                              <div style={{
                                width: 28, height: 28, borderRadius: '50%',
                                background: C.navy, color: '#fff',
                                display: 'flex', alignItems: 'center', justifyContent: 'center',
                                fontSize: 11, fontWeight: 700, flexShrink: 0,
                              }}>
                                {u.name.charAt(0).toUpperCase()}
                              </div>
                              <div>
                                <div style={{ fontSize: 13, fontWeight: 600, color: C.text }}>{u.name}</div>
                                <div style={{ fontSize: 11, color: C.muted }}>
                                  {u.jobTitle ? `${u.jobTitle} · ` : ''}{u.email}
                                </div>
                              </div>
                            </button>
                          ))}
                        </div>
                      )}
                      {!userLoading && userQuery.length > 1 && userResults.length === 0 && (
                        <div style={{
                          position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 50,
                          background: '#fff', border: `1px solid ${C.border}`,
                          borderRadius: 6, padding: '10px 14px',
                          fontSize: 12, color: C.muted, marginTop: 3,
                        }}>
                          No matching employees found.
                        </div>
                      )}
                    </>
                  )}
                </div>
              </ModalRow>
            )}
          </div>

          <Divider />
          <p style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.06em', margin: '0 0 12px' }}>
            SLA &amp; Escalation
          </p>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 14 }}>
            <ModalRow label="SLA (hours)" hint="Deadline for action">
              <input
                type="number" min={1}
                value={stepDraft.slaHours ?? ''}
                onChange={e => setStepDraft(d => ({ ...d, slaHours: e.target.value ? Number(e.target.value) : null }))}
                placeholder="48"
                style={iStyle}
              />
            </ModalRow>
            <ModalRow label="Remind After (hours)" hint="Send reminder if not acted">
              <input
                type="number" min={1}
                value={stepDraft.reminderAfterHours ?? ''}
                onChange={e => setStepDraft(d => ({ ...d, reminderAfterHours: e.target.value ? Number(e.target.value) : null }))}
                placeholder="24"
                style={iStyle}
              />
            </ModalRow>
            <ModalRow label="Escalate After (hours)" hint="Auto-escalate if overdue">
              <input
                type="number" min={1}
                value={stepDraft.escalationAfterHours ?? ''}
                onChange={e => setStepDraft(d => ({ ...d, escalationAfterHours: e.target.value ? Number(e.target.value) : null }))}
                placeholder="72"
                style={iStyle}
              />
            </ModalRow>
          </div>

          <Divider />
          <p style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.06em', margin: '0 0 12px' }}>
            Behaviour
          </p>
          <div style={{ display: 'flex', gap: 24 }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', fontSize: 13, color: C.text }}>
              <input
                type="checkbox"
                checked={stepDraft.isMandatory}
                onChange={e => setStepDraft(d => ({ ...d, isMandatory: e.target.checked }))}
              />
              <span>
                <strong>Mandatory</strong>
                <span style={{ color: C.faint, marginLeft: 4 }}>— cannot be skipped by submitter</span>
              </span>
            </label>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', fontSize: 13, color: C.text }}>
              <input
                type="checkbox"
                checked={stepDraft.allowDelegation}
                onChange={e => setStepDraft(d => ({ ...d, allowDelegation: e.target.checked }))}
              />
              <span>
                <strong>Allow Delegation</strong>
                <span style={{ color: C.faint, marginLeft: 4 }}>— approver can hand off</span>
              </span>
            </label>
          </div>

          {/* ── Skip Conditions — available for both new and existing steps ── */}
          {(() => {
            // In edit mode: use DB-persisted conditions; in add mode: use in-memory pending list
            const displayConditions: Array<{
              key: string; fieldPath: string; operator: string; value: string; skipStep: boolean;
              dbId?: string; pendingIdx?: number;
            }> = editingStepId
              ? conditions.map(c => ({ key: c.id, fieldPath: c.fieldPath, operator: c.operator, value: c.value, skipStep: c.skipStep, dbId: c.id }))
              : pendingConditions.map((c, i) => ({ key: `pending-${i}`, fieldPath: c.fieldPath, operator: c.operator, value: c.value, skipStep: c.skipStep, pendingIdx: i }));

            const selectedTpl   = templates.find(t => t.id === selectedId);
            const availableFields = CONDITION_FIELDS[selectedTpl?.moduleCode ?? ''] ?? CONDITION_FIELDS['_default'];
            const selectedField   = availableFields.find(f => f.value === conditionDraft.fieldPath) ?? availableFields[0];
            const availableOps    = CONDITION_OPERATORS.filter(o => o.types.includes(selectedField?.type ?? 'text'));

            return (
              <>
                <Divider />
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
                  <div>
                    <p style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.06em', margin: 0 }}>
                      Skip Conditions
                    </p>
                    <p style={{ fontSize: 11, color: C.faint, margin: '3px 0 0' }}>
                      If ALL conditions match the submission data, this step is automatically skipped.
                      {!editingStepId && pendingConditions.length > 0 && (
                        <span style={{ color: C.amber, marginLeft: 6 }}>· Will be saved when you click Add Step</span>
                      )}
                    </p>
                  </div>
                  <Btn
                    label="+ Add"
                    small
                    variant="outline"
                    onClick={() => { setShowCondForm(true); setConditionDraft(EMPTY_CONDITION); }}
                  />
                </div>

                {/* Conditions list */}
                {displayConditions.length > 0 && (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 10 }}>
                    {displayConditions.map(c => {
                      const opLabel    = CONDITION_OPERATORS.find(o => o.value === c.operator)?.label ?? c.operator;
                      const fieldLabel = Object.values(CONDITION_FIELDS).flat().find(f => f.value === c.fieldPath)?.label ?? c.fieldPath;
                      const isPending  = c.pendingIdx !== undefined;
                      return (
                        <div key={c.key} style={{
                          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                          background: isPending ? C.purpleL : C.blueL,
                          border: `1px solid ${isPending ? '#DDD6FE' : '#BFDBFE'}`,
                          borderRadius: 7, padding: '7px 12px', fontSize: 12,
                        }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                            <i className="fas fa-filter" style={{ color: isPending ? C.purple : C.blue, fontSize: 10 }} />
                            <span style={{ fontWeight: 600, color: C.navy }}>{fieldLabel}</span>
                            <span style={{ color: C.muted }}>{opLabel.split(' ')[0]}</span>
                            <span style={{
                              background: '#fff', border: `1px solid ${C.border}`,
                              borderRadius: 4, padding: '1px 7px', fontFamily: 'monospace',
                              fontSize: 11, color: C.text,
                            }}>{c.value}</span>
                            <span style={{
                              fontSize: 10, fontWeight: 700, borderRadius: 4,
                              padding: '1px 6px', textTransform: 'uppercase', letterSpacing: '0.04em',
                              background: c.skipStep ? C.amberL : '#F3F4F6',
                              color: c.skipStep ? C.amber : C.faint,
                            }}>
                              {c.skipStep ? 'Skip step' : 'Condition'}
                            </span>
                            {isPending && (
                              <span style={{ fontSize: 10, color: C.purple, fontStyle: 'italic' }}>pending save</span>
                            )}
                          </div>
                          <button
                            onClick={() => c.dbId ? deleteCondition(c.dbId) : deletePendingCondition(c.pendingIdx!)}
                            style={{ background: 'none', border: 'none', cursor: 'pointer', color: C.faint, fontSize: 14, padding: '0 2px', lineHeight: 1 }}
                            title="Remove condition"
                          >&times;</button>
                        </div>
                      );
                    })}
                  </div>
                )}

                {displayConditions.length === 0 && !showCondForm && (
                  <div style={{ fontSize: 12, color: C.faint, fontStyle: 'italic', marginBottom: 8 }}>
                    No conditions — this step always runs.
                  </div>
                )}

                {/* Add condition inline form */}
                {showCondForm && (
                  <div style={{
                    background: C.bg, border: `1px solid ${C.border}`,
                    borderRadius: 8, padding: '12px 14px', marginBottom: 8,
                  }}>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr auto', gap: 8, alignItems: 'end' }}>
                      {/* Field */}
                      <div>
                        <label style={{ fontSize: 10, fontWeight: 600, color: C.muted, display: 'block', marginBottom: 4, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Field</label>
                        <select
                          value={conditionDraft.fieldPath}
                          onChange={e => {
                            const newField = availableFields.find(f => f.value === e.target.value);
                            const defaultOp = newField?.type === 'numeric' ? 'gte' : 'eq';
                            setConditionDraft(d => ({ ...d, fieldPath: e.target.value, operator: defaultOp }));
                          }}
                          style={{ ...iStyle, fontSize: 12 }}
                        >
                          {availableFields.map(f => (
                            <option key={f.value} value={f.value}>{f.label}</option>
                          ))}
                        </select>
                      </div>
                      {/* Operator */}
                      <div>
                        <label style={{ fontSize: 10, fontWeight: 600, color: C.muted, display: 'block', marginBottom: 4, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Operator</label>
                        <select
                          value={conditionDraft.operator}
                          onChange={e => setConditionDraft(d => ({ ...d, operator: e.target.value }))}
                          style={{ ...iStyle, fontSize: 12 }}
                        >
                          {availableOps.map(o => (
                            <option key={o.value} value={o.value}>{o.label}</option>
                          ))}
                        </select>
                      </div>
                      {/* Value */}
                      <div>
                        <label style={{ fontSize: 10, fontWeight: 600, color: C.muted, display: 'block', marginBottom: 4, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                          Value
                          {selectedField?.type === 'text' && (conditionDraft.operator === 'in' || conditionDraft.operator === 'not_in') && (
                            <span style={{ fontWeight: 400, textTransform: 'none', letterSpacing: 0, marginLeft: 4 }}>· comma-separated</span>
                          )}
                        </label>
                        <input
                          value={conditionDraft.value}
                          onChange={e => setConditionDraft(d => ({ ...d, value: e.target.value }))}
                          placeholder={selectedField?.type === 'numeric' ? 'e.g. 500' : 'e.g. SGD'}
                          style={{ ...iStyle, fontSize: 12 }}
                        />
                      </div>
                      {/* Actions */}
                      <div style={{ display: 'flex', gap: 4 }}>
                        <Btn label="Add" variant="primary" small onClick={addCondition} />
                        <Btn label="✕" variant="ghost" small onClick={() => setShowCondForm(false)} />
                      </div>
                    </div>
                    {/* Skip toggle */}
                    <label style={{ display: 'flex', alignItems: 'center', gap: 7, cursor: 'pointer', fontSize: 12, color: C.text, marginTop: 10 }}>
                      <input
                        type="checkbox"
                        checked={conditionDraft.skipStep}
                        onChange={e => setConditionDraft(d => ({ ...d, skipStep: e.target.checked }))}
                      />
                      <span>
                        <strong>Skip this step</strong>
                        <span style={{ color: C.faint, marginLeft: 5 }}>when condition matches (uncheck to use as a routing rule only)</span>
                      </span>
                    </label>
                  </div>
                )}
              </>
            );
          })()}
        </Modal>
      )}
    </div>
  );
}

// ─── Shared sub-components ────────────────────────────────────────────────────

function MetaTag({ icon, label, mono }: { icon: string; label: string; mono?: boolean }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      fontSize: 12, color: C.muted,
    }}>
      <i className={`fas ${icon}`} style={{ fontSize: 10, color: C.faint }} />
      <span style={mono ? { fontFamily: 'monospace', fontSize: 11 } : {}}>{label}</span>
    </span>
  );
}

function StepChip({
  icon, label, color = C.muted, bg = '#F3F4F6',
}: { icon: string; label: string; color?: string; bg?: string }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      fontSize: 11, fontWeight: 500, color,
      background: bg, borderRadius: 5, padding: '3px 8px',
    }}>
      <i className={`fas ${icon}`} style={{ fontSize: 9 }} />
      {label}
    </span>
  );
}

function Modal({
  title, icon, children, onClose, onConfirm, confirmLabel, saving, wide,
}: {
  title: string; icon: string; children: React.ReactNode;
  onClose: () => void; onConfirm: () => void;
  confirmLabel: string; saving?: boolean; wide?: boolean;
}) {
  return (
    <div style={{
      position: 'fixed', inset: 0, background: 'rgba(15,23,42,0.5)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      zIndex: 9998, padding: 24,
    }}>
      <div style={{
        background: '#fff', borderRadius: 12, width: wide ? 640 : 480,
        maxWidth: '100%', maxHeight: '90vh', overflowY: 'auto',
        boxShadow: '0 24px 80px rgba(0,0,0,0.22)',
      }}>
        {/* Modal header */}
        <div style={{
          display: 'flex', justifyContent: 'space-between', alignItems: 'center',
          padding: '18px 24px', borderBottom: `1px solid ${C.border}`,
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <div style={{
              width: 32, height: 32, borderRadius: 8,
              background: C.blueL, display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <i className={`fas ${icon}`} style={{ fontSize: 14, color: C.blue }} />
            </div>
            <span style={{ fontWeight: 700, fontSize: 15, color: C.navy }}>{title}</span>
          </div>
          <button
            onClick={onClose}
            style={{ background: 'none', border: 'none', cursor: 'pointer', color: C.faint, fontSize: 18, lineHeight: 1 }}
          >×</button>
        </div>

        {/* Modal body */}
        <div style={{ padding: '20px 24px' }}>{children}</div>

        {/* Modal footer */}
        <div style={{
          display: 'flex', justifyContent: 'flex-end', gap: 8,
          padding: '14px 24px', borderTop: `1px solid ${C.border}`,
          background: C.bg, borderRadius: '0 0 12px 12px',
        }}>
          <Btn label="Cancel" variant="ghost" onClick={onClose} disabled={saving} />
          <Btn label={saving ? 'Saving…' : confirmLabel} variant="primary" onClick={onConfirm} disabled={saving} />
        </div>
      </div>
    </div>
  );
}

function ModalRow({
  label, hint, children, span,
}: { label: string; hint?: string; children: React.ReactNode; span?: number }) {
  return (
    <div style={{ gridColumn: span ? `span ${span}` : undefined }}>
      <label style={{
        fontSize: 11, fontWeight: 600, color: C.muted, display: 'block',
        marginBottom: 5, textTransform: 'uppercase', letterSpacing: '0.05em',
      }}>
        {label}
        {hint && <span style={{ fontWeight: 400, textTransform: 'none', letterSpacing: 0, marginLeft: 6 }}>· {hint}</span>}
      </label>
      {children}
    </div>
  );
}

const iStyle: React.CSSProperties = {
  width: '100%', padding: '7px 10px',
  border: `1px solid ${C.border}`, borderRadius: 6,
  fontSize: 13, outline: 'none', fontFamily: 'inherit',
  background: '#fff', boxSizing: 'border-box', color: C.text,
};
