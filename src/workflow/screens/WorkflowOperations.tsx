/**
 * WorkflowOperations — Admin Control Tower
 *
 * System-wide view of all active pending workflow tasks.
 * Admins monitor, identify bottlenecks, reassign stuck tasks,
 * force-advance, or decline requests.
 *
 * Route: /admin/workflow/operations  (requires workflow.admin)
 *
 * Layout:
 *   ┌─────────────────────────────────────────────────────────┐
 *   │  Header + KPI bar (4 cards)                             │
 *   │  Filter bar                                             │
 *   │  Paginated table  │  Details side panel (when selected) │
 *   └─────────────────────────────────────────────────────────┘
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';

// ─── Types ────────────────────────────────────────────────────────────────────

type SlaStatus = 'normal' | 'overdue' | 'critical';
type InstanceStatus = 'in_progress' | 'awaiting_clarification';

interface OpsRow {
  task_id:           string;
  instance_id:       string;
  display_id:        string;
  template_id:       string;
  template_code:     string;
  template_name:     string;
  module_code:       string;
  record_id:         string;
  instance_status:   InstanceStatus;
  step_order:        number;
  step_name:         string;
  sla_hours:         number | null;
  assignee_id:       string;
  assignee_name:     string;
  assignee_job_title:string | null;
  submitter_id:      string;
  submitter_name:    string;
  department_id:     string | null;
  department_name:   string | null;
  submitted_at:      string;
  pending_since:     string;
  due_at:            string | null;
  age_hours:         number;
  age_days:          number;
  sla_status:        SlaStatus;
}

interface WorkflowStep {
  id:         string;
  step_order: number;
  name:       string;
}

interface PersonResult {
  profileId: string;
  name:      string;
  jobTitle:  string | null;
}

type ActionMode = 'idle' | 'reassign' | 'force_advance' | 'decline';

type SortKey = 'age_days' | 'sla_status' | 'submitter_name' | 'assignee_name' | 'template_name';
type SortDir = 'asc' | 'desc';

const PAGE_SIZE = 25;

// ─── Colours ──────────────────────────────────────────────────────────────────

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

// ─── SLA helpers ─────────────────────────────────────────────────────────────

function slaColor(s: SlaStatus) {
  if (s === 'critical') return C.red;
  if (s === 'overdue')  return C.amber;
  return C.green;
}
function slaBg(s: SlaStatus) {
  if (s === 'critical') return C.redL;
  if (s === 'overdue')  return C.amberL;
  return C.greenL;
}
function slaLabel(s: SlaStatus) {
  if (s === 'critical') return 'Critical';
  if (s === 'overdue')  return 'Overdue';
  return 'Normal';
}

// Sort overdue/critical to top
function slaWeight(s: SlaStatus) {
  if (s === 'critical') return 0;
  if (s === 'overdue')  return 1;
  return 2;
}

function fmtDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

function fmtAge(days: number) {
  if (days === 0) return '< 1 day';
  if (days === 1) return '1 day';
  return `${days} days`;
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function KpiCard({ label, value, icon, color, bg }: {
  label: string; value: number; icon: string; color: string; bg: string;
}) {
  return (
    <div style={{
      flex: 1, minWidth: 140,
      background: '#fff', borderRadius: 8,
      border: `1px solid ${C.border}`,
      padding: '14px 18px',
      display: 'flex', alignItems: 'center', gap: 12,
    }}>
      <div style={{
        width: 36, height: 36, borderRadius: 8,
        background: bg, display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <i className={`fas ${icon}`} style={{ fontSize: 15, color }} />
      </div>
      <div>
        <div style={{ fontSize: 22, fontWeight: 800, color: C.navy, lineHeight: 1 }}>
          {value}
        </div>
        <div style={{ fontSize: 11, color: C.muted, marginTop: 2, fontWeight: 500 }}>
          {label}
        </div>
      </div>
    </div>
  );
}

function SlaBadge({ status }: { status: SlaStatus }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 4,
      fontSize: 10, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.04em',
      borderRadius: 4, padding: '2px 7px',
      background: slaBg(status), color: slaColor(status),
    }}>
      <i className={`fas ${status === 'normal' ? 'fa-check' : 'fa-triangle-exclamation'}`}
         style={{ fontSize: 8 }} />
      {slaLabel(status)}
    </span>
  );
}

function Th({ label, sortKey, currentKey, dir, onSort }: {
  label: string; sortKey?: SortKey;
  currentKey: SortKey; dir: SortDir; onSort: (k: SortKey) => void;
}) {
  const active = sortKey && currentKey === sortKey;
  return (
    <th
      onClick={() => sortKey && onSort(sortKey)}
      style={{
        padding: '10px 12px', textAlign: 'left', fontSize: 11, fontWeight: 700,
        color: active ? C.blue : C.muted, background: C.bg,
        textTransform: 'uppercase', letterSpacing: '0.05em',
        borderBottom: `1px solid ${C.border}`,
        cursor: sortKey ? 'pointer' : 'default',
        whiteSpace: 'nowrap', userSelect: 'none',
      }}
    >
      {label}
      {active && (
        <i className={`fas fa-arrow-${dir === 'asc' ? 'up' : 'down'}`}
           style={{ marginLeft: 5, fontSize: 9 }} />
      )}
    </th>
  );
}

// ─── Deep-link helper ─────────────────────────────────────────────────────────
// Returns the frontend route for a given module + record, or null if unknown.
// Extend the switch as new modules are onboarded.

function recordLink(moduleCode: string, recordId: string): string | null {
  switch (moduleCode) {
    case 'expense_reports': return `/expense/report/${recordId}`;
    default:                return null;
  }
}

// ─── Main Component ───────────────────────────────────────────────────────────

export default function WorkflowOperations() {
  const [rows,        setRows]        = useState<OpsRow[]>([]);
  const [total,       setTotal]       = useState(0);
  const [page,        setPage]        = useState(0);
  const [loading,     setLoading]     = useState(false);
  const [error,       setError]       = useState<string | null>(null);

  // Filters
  const [fTemplate,   setFTemplate]   = useState('');
  const [fDept,       setFDept]       = useState('');
  const [fSla,        setFSla]        = useState<SlaStatus | ''>('');
  const [fAssignee,   setFAssignee]   = useState('');

  // Sort
  const [sortKey,     setSortKey]     = useState<SortKey>('sla_status');
  const [sortDir,     setSortDir]     = useState<SortDir>('asc');

  // Filter options
  const [templates,   setTemplates]   = useState<{ code: string; name: string }[]>([]);
  const [departments, setDepartments] = useState<{ id: string; name: string }[]>([]);

  // Selected row + side panel
  const [selectedRow, setSelectedRow] = useState<OpsRow | null>(null);
  const [history,     setHistory]     = useState<any[]>([]);
  const [remainSteps, setRemainSteps] = useState<WorkflowStep[]>([]);

  // Action state
  const [actionMode,  setActionMode]  = useState<ActionMode>('idle');
  const [actionReason,setActionReason]= useState('');
  const [targetStep,  setTargetStep]  = useState<number | ''>('');
  const [actioning,   setActioning]   = useState(false);

  // Reassign people search
  const [personQuery,  setPersonQuery]  = useState('');
  const [personResults,setPersonResults]= useState<PersonResult[]>([]);
  const [personLoading,setPersonLoading]= useState(false);
  const [selectedPerson,setSelectedPerson]= useState<PersonResult | null>(null);
  const personTimer = useRef<number | null>(null);

  const navigate = useNavigate();

  // Bulk selection
  const [selectedIds,    setSelectedIds]    = useState<Set<string>>(new Set());
  const [bulkMode,       setBulkMode]       = useState<'idle' | 'decline' | 'reassign'>('idle');
  const [bulkReason,     setBulkReason]     = useState('');
  const [bulkActioning,  setBulkActioning]  = useState(false);

  // Bulk reassign uses same person picker state as single reassign
  const [bulkPerson,     setBulkPerson]     = useState<PersonResult | null>(null);
  const [bulkPersonQuery,setBulkPersonQuery]= useState('');
  const [bulkPersonRes,  setBulkPersonRes]  = useState<PersonResult[]>([]);
  const [bulkPersonLoad, setBulkPersonLoad] = useState(false);
  const bulkPersonTimer = useRef<number | null>(null);

  const [toast, setToast] = useState<{ type: 'ok' | 'err'; msg: string } | null>(null);
  const toastTimer = useRef<number | null>(null);

  function showToast(type: 'ok' | 'err', msg: string) {
    setToast({ type, msg });
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 4000);
  }

  // ── Filter options ──────────────────────────────────────────────────────────

  useEffect(() => {
    Promise.all([
      supabase.from('workflow_templates').select('code, name').order('name'),
      supabase.from('departments').select('id, name').order('name'),
    ]).then(([tplRes, deptRes]) => {
      setTemplates((tplRes.data ?? []).map(t => ({ code: t.code, name: t.name })));
      setDepartments((deptRes.data ?? []).map(d => ({ id: d.id, name: d.name })));
    });
  }, []);

  // ── Data load ───────────────────────────────────────────────────────────────

  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);

    const from = page * PAGE_SIZE;
    const to   = from + PAGE_SIZE - 1;

    let q = supabase
      .from('vw_wf_operations')
      .select('*', { count: 'exact' })
      .range(from, to);

    if (fTemplate) q = q.eq('template_code', fTemplate);
    if (fDept)     q = q.eq('department_id', fDept);
    if (fSla)      q = q.eq('sla_status', fSla);
    if (fAssignee) q = q.ilike('assignee_name', `%${fAssignee}%`);

    // Apply sort
    const ascending = sortDir === 'asc';
    if (sortKey === 'sla_status') {
      // Sort by age_days desc as secondary when sorting by SLA (most overdue first)
      q = q.order('sla_status', { ascending }).order('age_days', { ascending: false });
    } else {
      q = q.order(sortKey, { ascending });
    }

    const { data, error: err, count } = await q;
    setLoading(false);

    if (err) { setError(err.message); return; }
    setRows((data ?? []) as OpsRow[]);
    setTotal(count ?? 0);
  }, [page, fTemplate, fDept, fSla, fAssignee, sortKey, sortDir]);

  useEffect(() => {
    setPage(0);
  }, [fTemplate, fDept, fSla, fAssignee, sortKey, sortDir]);

  useEffect(() => { loadData(); }, [loadData]);

  // ── KPIs — 4 parallel COUNT queries (no full-table fetch) ───────────────────
  // "Awaiting Submitter" counts workflow_instances directly because
  // awaiting_clarification instances have no pending tasks and never appear
  // in vw_wf_operations.

  const [kpis, setKpis] = useState({ total: 0, overdue: 0, critical: 0, blocked: 0 });

  useEffect(() => {
    async function fetchKpis() {
      const [totalRes, overdueRes, criticalRes, blockedRes] = await Promise.all([
        supabase.from('vw_wf_operations').select('*', { count: 'exact', head: true }),
        supabase.from('vw_wf_operations').select('*', { count: 'exact', head: true }).eq('sla_status', 'overdue'),
        supabase.from('vw_wf_operations').select('*', { count: 'exact', head: true }).eq('sla_status', 'critical'),
        supabase.from('workflow_instances').select('*', { count: 'exact', head: true }).eq('status', 'awaiting_clarification'),
      ]);
      setKpis({
        total:    totalRes.count    ?? 0,
        overdue:  overdueRes.count  ?? 0,
        critical: criticalRes.count ?? 0,
        blocked:  blockedRes.count  ?? 0,
      });
    }
    fetchKpis();
  }, [rows]); // refresh whenever the table data refreshes

  // ── Sort toggle ─────────────────────────────────────────────────────────────

  function toggleSort(key: SortKey) {
    if (key === sortKey) {
      setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    } else {
      setSortKey(key);
      setSortDir('asc');
    }
  }

  // ── Row selection + side panel ──────────────────────────────────────────────

  async function selectRow(row: OpsRow) {
    setSelectedRow(row);
    setActionMode('idle');
    setActionReason('');
    setTargetStep('');
    setSelectedPerson(null);
    setPersonQuery('');
    setPersonResults([]);

    // Load audit history — use LEFT join on employees so system-generated
    // events (actor_id = null) still appear; show "System" for those rows.
    const { data: logData } = await supabase
      .from('workflow_action_log')
      .select(`
        id, action, step_order, notes, created_at,
        actor:profiles!workflow_action_log_actor_id_fkey(
          id, employees(name)
        )
      `)
      .eq('instance_id', row.instance_id)
      .order('created_at', { ascending: true });

    setHistory(
      (logData ?? []).map((l: any) => ({
        id:        l.id,
        action:    l.action,
        stepOrder: l.step_order,
        notes:     l.notes,
        createdAt: l.created_at,
        actorName: l.actor?.employees?.name ?? (l.actor ? '—' : 'System'),
      }))
    );

    // Load remaining steps (after current step) — template_id is in the view row
    const { data: stepsData } = await supabase
      .from('workflow_steps')
      .select('id, step_order, name')
      .eq('template_id', row.template_id)
      .gt('step_order', row.step_order)
      .eq('is_active', true)
      .order('step_order');

    setRemainSteps((stepsData ?? []) as WorkflowStep[]);
  }

  // ── People search ───────────────────────────────────────────────────────────

  function searchPerson(q: string) {
    setPersonQuery(q);
    setSelectedPerson(null);
    if (personTimer.current) clearTimeout(personTimer.current);
    if (!q.trim()) { setPersonResults([]); return; }
    personTimer.current = window.setTimeout(async () => {
      setPersonLoading(true);
      const { data } = await supabase
        .from('profiles')
        .select('id, employees!inner(name, job_title)')
        .ilike('employees.name', `%${q}%`)
        .eq('is_active', true)
        .limit(8);
      setPersonLoading(false);
      setPersonResults(
        (data ?? []).map((p: any) => ({
          profileId: p.id,
          name:      p.employees?.name ?? '—',
          jobTitle:  p.employees?.job_title ?? null,
        }))
      );
    }, 300);
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  async function doReassign() {
    if (!selectedRow || !selectedPerson) return;
    setActioning(true);
    try {
      const { error: err } = await supabase.rpc('wf_reassign', {
        p_task_id:        selectedRow.task_id,
        p_new_profile_id: selectedPerson.profileId,
        p_reason:         actionReason || null,
      });
      if (err) throw new Error(err.message);
      showToast('ok', `Reassigned to ${selectedPerson.name}`);
      setActionMode('idle');
      setSelectedRow(null);
      await loadData();
    } catch (e) {
      showToast('err', (e as Error).message);
    } finally {
      setActioning(false);
    }
  }

  async function doForceAdvance() {
    if (!selectedRow || !targetStep || !actionReason.trim()) return;
    setActioning(true);
    try {
      const { error: err } = await supabase.rpc('wf_force_advance', {
        p_instance_id:       selectedRow.instance_id,
        p_target_step_order: Number(targetStep),
        p_reason:            actionReason,
      });
      if (err) throw new Error(err.message);
      showToast('ok', `Workflow advanced to step ${targetStep}`);
      setActionMode('idle');
      setSelectedRow(null);
      await loadData();
    } catch (e) {
      showToast('err', (e as Error).message);
    } finally {
      setActioning(false);
    }
  }

  // ── Bulk people search ──────────────────────────────────────────────────────

  function searchBulkPerson(q: string) {
    setBulkPersonQuery(q);
    setBulkPerson(null);
    if (bulkPersonTimer.current) clearTimeout(bulkPersonTimer.current);
    if (!q.trim()) { setBulkPersonRes([]); return; }
    bulkPersonTimer.current = window.setTimeout(async () => {
      setBulkPersonLoad(true);
      const { data } = await supabase
        .from('profiles')
        .select('id, employees!inner(name, job_title)')
        .ilike('employees.name', `%${q}%`)
        .eq('is_active', true)
        .limit(8);
      setBulkPersonLoad(false);
      setBulkPersonRes(
        (data ?? []).map((p: any) => ({
          profileId: p.id,
          name:      p.employees?.name ?? '—',
          jobTitle:  p.employees?.job_title ?? null,
        }))
      );
    }, 300);
  }

  // ── Bulk actions ────────────────────────────────────────────────────────────

  function toggleSelectAll() {
    if (selectedIds.size === rows.length && rows.length > 0) {
      setSelectedIds(new Set());
    } else {
      setSelectedIds(new Set(rows.map(r => r.task_id)));
    }
  }

  function toggleSelectRow(taskId: string) {
    setSelectedIds(prev => {
      const next = new Set(prev);
      if (next.has(taskId)) next.delete(taskId);
      else next.add(taskId);
      return next;
    });
  }

  function clearBulk() {
    setSelectedIds(new Set());
    setBulkMode('idle');
    setBulkReason('');
    setBulkPerson(null);
    setBulkPersonQuery('');
    setBulkPersonRes([]);
  }

  async function doBulkApprove() {
    if (selectedIds.size === 0) return;
    setBulkActioning(true);
    try {
      const { data, error: err } = await supabase.rpc('wf_bulk_approve', {
        p_task_ids: Array.from(selectedIds),
        p_notes: null,
      });
      if (err) throw new Error(err.message);
      const result = data as { succeeded: string[]; failed: { task_id: string; error: string }[] };
      const s = result.succeeded?.length ?? 0;
      const f = result.failed?.length ?? 0;
      const errHint = f > 0 ? ` — ${result.failed[0].error.slice(0, 60)}` : '';
      showToast(f > 0 && s === 0 ? 'err' : 'ok', `Approved ${s} task${s !== 1 ? 's' : ''}${f > 0 ? ` (${f} failed${errHint})` : ''}`);
      clearBulk();
      await loadData();
    } catch (e) {
      showToast('err', (e as Error).message);
    } finally {
      setBulkActioning(false);
    }
  }

  async function doBulkDecline() {
    if (selectedIds.size === 0 || !bulkReason.trim()) return;
    setBulkActioning(true);
    try {
      const { data, error: err } = await supabase.rpc('wf_bulk_decline', {
        p_task_ids: Array.from(selectedIds),
        p_reason:   bulkReason,
      });
      if (err) throw new Error(err.message);
      const result = data as { succeeded: string[]; failed: { task_id: string; error: string }[] };
      const s = result.succeeded?.length ?? 0;
      const f = result.failed?.length ?? 0;
      const errHint = f > 0 ? ` — ${result.failed[0].error.slice(0, 60)}` : '';
      showToast(f > 0 && s === 0 ? 'err' : 'ok', `Declined ${s} task${s !== 1 ? 's' : ''}${f > 0 ? ` (${f} failed${errHint})` : ''}`);
      clearBulk();
      await loadData();
    } catch (e) {
      showToast('err', (e as Error).message);
    } finally {
      setBulkActioning(false);
    }
  }

  async function doBulkReassign() {
    if (selectedIds.size === 0 || !bulkPerson) return;
    setBulkActioning(true);
    try {
      const { data, error: err } = await supabase.rpc('wf_bulk_reassign', {
        p_task_ids:       Array.from(selectedIds),
        p_new_profile_id: bulkPerson.profileId,
        p_reason:         bulkReason || null,
      });
      if (err) throw new Error(err.message);
      const result = data as { succeeded: string[]; failed: { task_id: string; error: string }[] };
      const s = result.succeeded?.length ?? 0;
      const f = result.failed?.length ?? 0;
      const errHint = f > 0 ? ` — ${result.failed[0].error.slice(0, 60)}` : '';
      showToast(f > 0 && s === 0 ? 'err' : 'ok', `Reassigned ${s} task${s !== 1 ? 's' : ''} to ${bulkPerson.name}${f > 0 ? ` (${f} failed${errHint})` : ''}`);
      clearBulk();
      await loadData();
    } catch (e) {
      showToast('err', (e as Error).message);
    } finally {
      setBulkActioning(false);
    }
  }

  async function doDecline() {
    if (!selectedRow || !actionReason.trim()) return;
    setActioning(true);
    try {
      const { error: err } = await supabase.rpc('wf_admin_decline', {
        p_instance_id: selectedRow.instance_id,
        p_reason:      actionReason,
      });
      if (err) throw new Error(err.message);
      showToast('ok', 'Request returned to submitter');
      setActionMode('idle');
      setSelectedRow(null);
      await loadData();
    } catch (e) {
      showToast('err', (e as Error).message);
    } finally {
      setActioning(false);
    }
  }

  // ── Pagination ──────────────────────────────────────────────────────────────

  const totalPages = Math.ceil(total / PAGE_SIZE);

  // ── Render ───────────────────────────────────────────────────────────────────

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, fontFamily: 'inherit' }}>

      {/* Toast */}
      {toast && (
        <div style={{
          position: 'fixed', bottom: 24, right: 28, zIndex: 9999,
          padding: '10px 18px', borderRadius: 8, fontSize: 13,
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

      {/* ── Header ─────────────────────────────────────────────────────────── */}
      <div style={{ padding: '20px 28px 0', background: '#fff', borderBottom: `1px solid ${C.border}` }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
          <div>
            <h1 style={{ fontSize: 20, fontWeight: 800, color: C.navy, margin: 0 }}>
              Workflow Operations
            </h1>
            <p style={{ fontSize: 13, color: C.muted, margin: '4px 0 0' }}>
              Monitor and manage workflow execution across the system.
            </p>
          </div>
          <button
            onClick={loadData}
            style={{
              display: 'inline-flex', alignItems: 'center', gap: 6,
              padding: '7px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600,
              background: '#fff', color: C.text, border: `1px solid ${C.border}`,
              cursor: 'pointer',
            }}
          >
            <i className="fas fa-rotate-right" style={{ fontSize: 11 }} />
            Refresh
          </button>
        </div>

        {/* KPI bar */}
        <div style={{ display: 'flex', gap: 12, paddingBottom: 16, flexWrap: 'wrap' }}>
          <KpiCard label="Total Pending"  value={kpis.total}    icon="fa-inbox"                  color={C.blue}   bg={C.blueL}   />
          <KpiCard label="Overdue"        value={kpis.overdue}  icon="fa-clock"                  color={C.amber}  bg={C.amberL}  />
          <KpiCard label="Critical"       value={kpis.critical} icon="fa-triangle-exclamation"   color={C.red}    bg={C.redL}    />
          <KpiCard label="Awaiting Submitter" value={kpis.blocked} icon="fa-comment-dots"        color={C.purple} bg={C.purpleL} />
        </div>
      </div>

      {/* ── Body (table + side panel) ───────────────────────────────────────── */}
      <div style={{ flex: 1, display: 'flex', minHeight: 0, overflow: 'hidden' }}>

        {/* Left: filter + table */}
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>

          {/* Filter bar */}
          <div style={{
            display: 'flex', gap: 8, padding: '12px 16px',
            background: '#fff', borderBottom: `1px solid ${C.border}`,
            flexWrap: 'wrap',
          }}>
            {/* Template */}
            <select
              value={fTemplate}
              onChange={e => setFTemplate(e.target.value)}
              style={selStyle}
            >
              <option value="">All Templates</option>
              {templates.map(t => (
                <option key={t.code} value={t.code}>{t.name}</option>
              ))}
            </select>

            {/* Department */}
            <select
              value={fDept}
              onChange={e => setFDept(e.target.value)}
              style={selStyle}
            >
              <option value="">All Departments</option>
              {departments.map(d => (
                <option key={d.id} value={d.id}>{d.name}</option>
              ))}
            </select>

            {/* SLA Status */}
            <select
              value={fSla}
              onChange={e => setFSla(e.target.value as SlaStatus | '')}
              style={selStyle}
            >
              <option value="">All Statuses</option>
              <option value="normal">Normal</option>
              <option value="overdue">Overdue</option>
              <option value="critical">Critical</option>
            </select>

            {/* Assignee name search */}
            <div style={{ position: 'relative' }}>
              <i className="fas fa-magnifying-glass" style={{
                position: 'absolute', left: 9, top: '50%', transform: 'translateY(-50%)',
                color: C.faint, fontSize: 11, pointerEvents: 'none',
              }} />
              <input
                value={fAssignee}
                onChange={e => setFAssignee(e.target.value)}
                placeholder="Filter by assignee…"
                style={{ ...selStyle, paddingLeft: 28 }}
              />
            </div>

            {(fTemplate || fDept || fSla || fAssignee) && (
              <button
                onClick={() => { setFTemplate(''); setFDept(''); setFSla(''); setFAssignee(''); }}
                style={{
                  padding: '6px 12px', borderRadius: 6, fontSize: 12, fontWeight: 600,
                  background: C.redL, color: C.red, border: `1px solid #FECACA`,
                  cursor: 'pointer',
                }}
              >
                <i className="fas fa-xmark" style={{ marginRight: 4 }} />
                Clear
              </button>
            )}

            <span style={{ marginLeft: 'auto', fontSize: 12, color: C.muted, alignSelf: 'center' }}>
              {total} task{total !== 1 ? 's' : ''}
            </span>
          </div>

          {/* Bulk action bar — visible when rows are selected */}
          {selectedIds.size > 0 && (
            <div style={{
              display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap',
              padding: '10px 16px', background: C.navy, borderBottom: `1px solid ${C.border}`,
            }}>
              <span style={{ fontSize: 12, fontWeight: 700, color: '#fff' }}>
                {selectedIds.size} selected
              </span>
              <button
                onClick={doBulkApprove}
                disabled={bulkActioning}
                style={{ ...bulkBtnStyle, background: C.green, color: '#fff' }}
              >
                <i className="fas fa-circle-check" style={{ fontSize: 11 }} />
                Approve All
              </button>
              <button
                onClick={() => setBulkMode('decline')}
                style={{ ...bulkBtnStyle, background: C.red, color: '#fff' }}
              >
                <i className="fas fa-hand" style={{ fontSize: 11 }} />
                Decline All
              </button>
              <button
                onClick={() => setBulkMode('reassign')}
                style={{ ...bulkBtnStyle, background: '#7C3AED', color: '#fff' }}
              >
                <i className="fas fa-arrows-rotate" style={{ fontSize: 11 }} />
                Reassign All
              </button>
              <button
                onClick={clearBulk}
                style={{ ...bulkBtnStyle, background: 'rgba(255,255,255,0.12)', color: '#fff', marginLeft: 'auto' }}
              >
                <i className="fas fa-xmark" style={{ fontSize: 11 }} />
                Clear
              </button>
            </div>
          )}

          {/* Bulk decline modal */}
          {bulkMode === 'decline' && (
            <div style={{
              margin: '10px 16px', border: `1px solid ${C.red}44`, borderRadius: 8,
              background: C.redL, overflow: 'hidden',
            }}>
              <div style={{
                padding: '10px 14px', borderBottom: `1px solid ${C.red}33`,
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
              }}>
                <span style={{ fontSize: 12, fontWeight: 700, color: C.red }}>
                  Decline {selectedIds.size} Task{selectedIds.size !== 1 ? 's' : ''}
                </span>
                <button onClick={() => setBulkMode('idle')} style={clearBtnStyle}>×</button>
              </div>
              <div style={{ padding: '12px 14px' }}>
                <label style={labelStyle}>Reason * <span style={{ fontWeight: 400, textTransform: 'none', color: C.red }}>mandatory</span></label>
                <textarea
                  value={bulkReason}
                  onChange={e => setBulkReason(e.target.value)}
                  placeholder="Explain why these requests are being declined…"
                  rows={2}
                  style={{ ...iStyle, resize: 'vertical', marginBottom: 10 }}
                  autoFocus
                />
                <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                  <button onClick={() => setBulkMode('idle')} style={{ padding: '6px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600, background: '#fff', color: '#374151', border: '1px solid #E5E7EB', cursor: 'pointer' }}>Cancel</button>
                  <button
                    onClick={doBulkDecline}
                    disabled={!bulkReason.trim() || bulkActioning}
                    style={{ padding: '6px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600, background: C.red, color: '#fff', border: 'none', cursor: !bulkReason.trim() || bulkActioning ? 'not-allowed' : 'pointer', opacity: !bulkReason.trim() || bulkActioning ? 0.65 : 1 }}
                  >
                    {bulkActioning ? <><i className="fas fa-spinner fa-spin" style={{ marginRight: 5 }} />Working…</> : `Decline ${selectedIds.size}`}
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* Bulk reassign modal */}
          {bulkMode === 'reassign' && (
            <div style={{
              margin: '10px 16px', border: '1px solid #7C3AED44', borderRadius: 8,
              background: C.purpleL, overflow: 'hidden',
            }}>
              <div style={{
                padding: '10px 14px', borderBottom: '1px solid #7C3AED33',
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
              }}>
                <span style={{ fontSize: 12, fontWeight: 700, color: '#7C3AED' }}>
                  Reassign {selectedIds.size} Task{selectedIds.size !== 1 ? 's' : ''}
                </span>
                <button onClick={() => setBulkMode('idle')} style={clearBtnStyle}>×</button>
              </div>
              <div style={{ padding: '12px 14px' }}>
                <label style={labelStyle}>New Assignee *</label>
                {bulkPerson ? (
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '7px 10px', border: '1px solid #7C3AED', borderRadius: 6, background: '#F5F3FF', marginBottom: 8 }}>
                    <Avatar name={bulkPerson.name} color="#7C3AED" />
                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: 13, fontWeight: 600, color: C.navy }}>{bulkPerson.name}</div>
                      {bulkPerson.jobTitle && <div style={{ fontSize: 11, color: C.muted }}>{bulkPerson.jobTitle}</div>}
                    </div>
                    <button onClick={() => { setBulkPerson(null); setBulkPersonQuery(''); }} style={clearBtnStyle}>×</button>
                  </div>
                ) : (
                  <div style={{ position: 'relative', marginBottom: 8 }}>
                    <i className="fas fa-magnifying-glass" style={{ position: 'absolute', left: 9, top: '50%', transform: 'translateY(-50%)', color: C.faint, fontSize: 11 }} />
                    <input
                      value={bulkPersonQuery}
                      onChange={e => searchBulkPerson(e.target.value)}
                      placeholder="Search by name…"
                      style={{ ...iStyle, paddingLeft: 28 }}
                      autoFocus
                    />
                    {bulkPersonLoad && <i className="fas fa-spinner fa-spin" style={{ position: 'absolute', right: 9, top: '50%', transform: 'translateY(-50%)', color: C.faint, fontSize: 11 }} />}
                    {bulkPersonRes.length > 0 && (
                      <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 50, background: '#fff', border: `1px solid ${C.border}`, borderRadius: 6, boxShadow: '0 4px 16px rgba(0,0,0,0.12)', marginTop: 3, maxHeight: 180, overflowY: 'auto' }}>
                        {bulkPersonRes.map(p => (
                          <button key={p.profileId} onClick={() => { setBulkPerson(p); setBulkPersonQuery(p.name); setBulkPersonRes([]); }}
                            style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', border: 'none', background: 'none', cursor: 'pointer', textAlign: 'left' }}
                            onMouseEnter={e => (e.currentTarget.style.background = C.purpleL)}
                            onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                          >
                            <Avatar name={p.name} color={C.navy} size={26} />
                            <div>
                              <div style={{ fontSize: 13, fontWeight: 600, color: C.text }}>{p.name}</div>
                              {p.jobTitle && <div style={{ fontSize: 11, color: C.muted }}>{p.jobTitle}</div>}
                            </div>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                )}
                <label style={labelStyle}>Reason (optional)</label>
                <textarea
                  value={bulkReason}
                  onChange={e => setBulkReason(e.target.value)}
                  placeholder="Why are you reassigning these tasks?"
                  rows={2}
                  style={{ ...iStyle, resize: 'vertical', marginBottom: 10 }}
                />
                <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                  <button onClick={() => setBulkMode('idle')} style={{ padding: '6px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600, background: '#fff', color: '#374151', border: '1px solid #E5E7EB', cursor: 'pointer' }}>Cancel</button>
                  <button
                    onClick={doBulkReassign}
                    disabled={!bulkPerson || bulkActioning}
                    style={{ padding: '6px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600, background: '#7C3AED', color: '#fff', border: 'none', cursor: !bulkPerson || bulkActioning ? 'not-allowed' : 'pointer', opacity: !bulkPerson || bulkActioning ? 0.65 : 1 }}
                  >
                    {bulkActioning ? <><i className="fas fa-spinner fa-spin" style={{ marginRight: 5 }} />Working…</> : `Reassign ${selectedIds.size}`}
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* Table */}
          <div style={{ flex: 1, overflowY: 'auto' }}>
            {loading ? (
              <div style={{ padding: 48, textAlign: 'center', color: C.faint, fontSize: 13 }}>
                <i className="fas fa-spinner fa-spin" style={{ marginRight: 8 }} />Loading…
              </div>
            ) : error ? (
              <div style={{ padding: 24, color: C.red, fontSize: 13 }}>{error}</div>
            ) : rows.length === 0 ? (
              <div style={{
                padding: '60px 24px', textAlign: 'center', color: C.faint,
              }}>
                <i className="fas fa-circle-check" style={{ fontSize: 32, display: 'block', marginBottom: 10, color: C.green }} />
                <p style={{ margin: 0, fontSize: 14, fontWeight: 600, color: C.green }}>All clear</p>
                <p style={{ margin: '4px 0 0', fontSize: 13 }}>No pending tasks match the current filters.</p>
              </div>
            ) : (
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                <thead>
                  <tr>
                    {/* Select-all checkbox */}
                    <th style={{ padding: '10px 8px 10px 14px', background: C.bg, borderBottom: `1px solid ${C.border}`, width: 32 }}>
                      <input
                        type="checkbox"
                        checked={selectedIds.size === rows.length && rows.length > 0}
                        ref={el => { if (el) el.indeterminate = selectedIds.size > 0 && selectedIds.size < rows.length; }}
                        onChange={toggleSelectAll}
                        style={{ cursor: 'pointer' }}
                      />
                    </th>
                    <Th label="ID"           currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Employee"     sortKey="submitter_name" currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Template"     sortKey="template_name"  currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Stage"        currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Assigned To"  sortKey="assignee_name"  currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Pending Since" currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Age"          sortKey="age_days"       currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Status"       sortKey="sla_status"     currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                  </tr>
                </thead>
                <tbody>
                  {rows.map(row => {
                    const isSelected = selectedRow?.task_id === row.task_id;
                    const isChecked  = selectedIds.has(row.task_id);
                    const rowBg = isChecked
                      ? '#EFF6FF'
                      : isSelected
                        ? C.blueL
                        : row.sla_status === 'critical'
                          ? '#FFF5F5'
                          : row.sla_status === 'overdue'
                            ? '#FFFBEB'
                            : '#fff';
                    const leftBorder = row.sla_status === 'critical'
                      ? `3px solid ${C.red}`
                      : row.sla_status === 'overdue'
                        ? `3px solid ${C.amber}`
                        : isChecked ? `3px solid ${C.blue}` : '3px solid transparent';

                    return (
                      <tr
                        key={row.task_id}
                        onClick={() => selectRow(row)}
                        style={{
                          background: rowBg,
                          borderLeft: leftBorder,
                          borderBottom: `1px solid ${C.border}`,
                          cursor: 'pointer',
                        }}
                        onMouseEnter={e => { if (!isSelected && !isChecked) e.currentTarget.style.background = '#F8FAFF'; }}
                        onMouseLeave={e => { if (!isSelected && !isChecked) e.currentTarget.style.background = rowBg; }}
                      >
                        {/* Checkbox cell — click stops propagation so row click doesn't fire */}
                        <td style={{ ...tdStyle, paddingLeft: 14, paddingRight: 4, width: 32 }}
                          onClick={e => { e.stopPropagation(); toggleSelectRow(row.task_id); }}
                        >
                          <input
                            type="checkbox"
                            checked={isChecked}
                            onChange={() => toggleSelectRow(row.task_id)}
                            style={{ cursor: 'pointer' }}
                          />
                        </td>
                        <td style={tdStyle}>
                          <span style={{ fontFamily: 'monospace', fontSize: 11, color: C.blue, fontWeight: 600 }}>
                            {row.display_id}
                          </span>
                          {row.instance_status === 'awaiting_clarification' && (
                            <span style={{
                              marginLeft: 6, fontSize: 9, fontWeight: 700,
                              background: C.purpleL, color: C.purple,
                              borderRadius: 3, padding: '1px 5px', textTransform: 'uppercase',
                            }}>
                              Blocked
                            </span>
                          )}
                        </td>
                        <td style={tdStyle}>
                          <div style={{ fontWeight: 600, color: C.navy }}>{row.submitter_name}</div>
                          {row.department_name && (
                            <div style={{ fontSize: 10, color: C.faint }}>{row.department_name}</div>
                          )}
                        </td>
                        <td style={tdStyle}>
                          <span style={{
                            fontSize: 11, fontWeight: 600, background: C.blueL,
                            color: C.blue, borderRadius: 4, padding: '2px 7px',
                          }}>
                            {row.template_name}
                          </span>
                        </td>
                        <td style={tdStyle}>
                          <div style={{ color: C.text }}>Step {row.step_order}</div>
                          <div style={{ fontSize: 10, color: C.faint }}>{row.step_name}</div>
                        </td>
                        <td style={tdStyle}>
                          <div style={{ color: C.navy }}>{row.assignee_name}</div>
                          {row.assignee_job_title && (
                            <div style={{ fontSize: 10, color: C.faint }}>{row.assignee_job_title}</div>
                          )}
                        </td>
                        <td style={{ ...tdStyle, color: C.muted }}>{fmtDate(row.pending_since)}</td>
                        <td style={{ ...tdStyle, fontWeight: 600, color: row.age_days >= 7 ? C.red : C.text }}>
                          {fmtAge(row.age_days)}
                        </td>
                        <td style={tdStyle}><SlaBadge status={row.sla_status} /></td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
          </div>

          {/* Pagination */}
          {totalPages > 1 && (
            <div style={{
              display: 'flex', justifyContent: 'space-between', alignItems: 'center',
              padding: '10px 16px', borderTop: `1px solid ${C.border}`,
              background: '#fff', fontSize: 12, color: C.muted,
            }}>
              <span>{page * PAGE_SIZE + 1}–{Math.min((page + 1) * PAGE_SIZE, total)} of {total}</span>
              <div style={{ display: 'flex', gap: 6 }}>
                <PageBtn label="‹ Prev" disabled={page === 0}              onClick={() => setPage(p => p - 1)} />
                <PageBtn label="Next ›" disabled={page >= totalPages - 1}  onClick={() => setPage(p => p + 1)} />
              </div>
            </div>
          )}
        </div>

        {/* ── Right: Details side panel ─────────────────────────────────────── */}
        {selectedRow && (
          <div style={{
            width: 400, flexShrink: 0, borderLeft: `1px solid ${C.border}`,
            background: '#fff', display: 'flex', flexDirection: 'column',
            overflowY: 'auto',
          }}>
            {/* Panel header */}
            <div style={{
              padding: '16px 18px', borderBottom: `1px solid ${C.border}`,
              display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start',
            }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 700, fontSize: 14, color: C.navy }}>
                  {selectedRow.display_id}
                </div>
                <div style={{ fontSize: 12, color: C.muted, marginTop: 2 }}>
                  {selectedRow.submitter_name} · {selectedRow.template_name}
                </div>
                {recordLink(selectedRow.module_code, selectedRow.record_id) && (
                  <button
                    onClick={() => navigate(recordLink(selectedRow.module_code, selectedRow.record_id)!)}
                    style={{
                      marginTop: 6, display: 'inline-flex', alignItems: 'center', gap: 4,
                      fontSize: 11, fontWeight: 600, color: C.blue,
                      background: C.blueL, border: `1px solid #BFDBFE`,
                      borderRadius: 5, padding: '3px 8px', cursor: 'pointer',
                    }}
                  >
                    <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 9 }} />
                    View Request
                  </button>
                )}
              </div>
              <button
                onClick={() => { setSelectedRow(null); setActionMode('idle'); }}
                style={{ background: 'none', border: 'none', cursor: 'pointer', color: C.faint, fontSize: 18, lineHeight: 1, flexShrink: 0 }}
              >×</button>
            </div>

            {/* Summary chips */}
            <div style={{ padding: '12px 18px', borderBottom: `1px solid ${C.border}`, display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <SlaBadge status={selectedRow.sla_status} />
              <Chip icon="fa-list-ol"   label={`Step ${selectedRow.step_order}: ${selectedRow.step_name}`} />
              <Chip icon="fa-user-tie"  label={selectedRow.assignee_name} />
              <Chip icon="fa-hourglass" label={fmtAge(selectedRow.age_days)} />
              {selectedRow.due_at && (
                <Chip icon="fa-clock" label={`Due ${fmtDate(selectedRow.due_at)}`}
                      color={selectedRow.sla_status !== 'normal' ? C.red : C.muted} />
              )}
            </div>

            {/* Action buttons */}
            {actionMode === 'idle' && (
              <div style={{ padding: '12px 18px', borderBottom: `1px solid ${C.border}`, display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <ActionBtn label="Reassign"     icon="fa-arrows-rotate"    color="#2563EB" onClick={() => setActionMode('reassign')} />
                {remainSteps.length > 0 && (
                  <ActionBtn label="Force Advance" icon="fa-forward-step"  color="#7C3AED" onClick={() => setActionMode('force_advance')} />
                )}
                <ActionBtn label="Decline"      icon="fa-hand"             color="#DC2626" onClick={() => setActionMode('decline')} />
              </div>
            )}

            {/* ── Reassign panel ─────────────────────────────────────────────── */}
            {actionMode === 'reassign' && (
              <ActionPanel
                title="Reassign Task"
                color="#2563EB"
                bg="#EFF6FF"
                onCancel={() => setActionMode('idle')}
                onConfirm={doReassign}
                confirmLabel="Reassign"
                loading={actioning}
                disabled={!selectedPerson}
              >
                {/* People search */}
                <label style={labelStyle}>New Assignee *</label>
                {selectedPerson ? (
                  <div style={{
                    display: 'flex', alignItems: 'center', gap: 10,
                    padding: '7px 10px', border: `1px solid #2563EB`,
                    borderRadius: 6, background: C.blueL, marginBottom: 8,
                  }}>
                    <Avatar name={selectedPerson.name} color="#2563EB" />
                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: 13, fontWeight: 600, color: C.navy }}>{selectedPerson.name}</div>
                      {selectedPerson.jobTitle && <div style={{ fontSize: 11, color: C.muted }}>{selectedPerson.jobTitle}</div>}
                    </div>
                    <button onClick={() => { setSelectedPerson(null); setPersonQuery(''); }} style={clearBtnStyle}>×</button>
                  </div>
                ) : (
                  <div style={{ position: 'relative', marginBottom: 8 }}>
                    <i className="fas fa-magnifying-glass" style={{ position: 'absolute', left: 9, top: '50%', transform: 'translateY(-50%)', color: C.faint, fontSize: 11 }} />
                    <input
                      value={personQuery}
                      onChange={e => searchPerson(e.target.value)}
                      placeholder="Search by name…"
                      style={{ ...iStyle, paddingLeft: 28 }}
                      autoFocus
                    />
                    {personLoading && <i className="fas fa-spinner fa-spin" style={{ position: 'absolute', right: 9, top: '50%', transform: 'translateY(-50%)', color: C.faint, fontSize: 11 }} />}
                    {personResults.length > 0 && (
                      <div style={{
                        position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 50,
                        background: '#fff', border: `1px solid ${C.border}`,
                        borderRadius: 6, boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
                        marginTop: 3, maxHeight: 200, overflowY: 'auto',
                      }}>
                        {personResults.map(p => (
                          <button key={p.profileId} onClick={() => { setSelectedPerson(p); setPersonQuery(p.name); setPersonResults([]); }}
                            style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', border: 'none', background: 'none', cursor: 'pointer', textAlign: 'left' }}
                            onMouseEnter={e => (e.currentTarget.style.background = C.blueL)}
                            onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                          >
                            <Avatar name={p.name} color={C.navy} size={26} />
                            <div>
                              <div style={{ fontSize: 13, fontWeight: 600, color: C.text }}>{p.name}</div>
                              {p.jobTitle && <div style={{ fontSize: 11, color: C.muted }}>{p.jobTitle}</div>}
                            </div>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                )}
                <label style={labelStyle}>Reason (optional)</label>
                <textarea
                  value={actionReason}
                  onChange={e => setActionReason(e.target.value)}
                  placeholder="Why are you reassigning this task?"
                  rows={2}
                  style={{ ...iStyle, resize: 'vertical', marginBottom: 0 }}
                />
              </ActionPanel>
            )}

            {/* ── Force Advance panel ─────────────────────────────────────────── */}
            {actionMode === 'force_advance' && (
              <ActionPanel
                title="Force Advance"
                color="#7C3AED"
                bg={C.purpleL}
                onCancel={() => setActionMode('idle')}
                onConfirm={doForceAdvance}
                confirmLabel="Force Advance"
                loading={actioning}
                disabled={!targetStep || !actionReason.trim()}
              >
                <div style={{
                  padding: '8px 10px', borderRadius: 6, fontSize: 12, marginBottom: 10,
                  background: '#FEF3C7', border: '1px solid #FDE68A', color: C.amber,
                  display: 'flex', gap: 7, alignItems: 'flex-start',
                }}>
                  <i className="fas fa-triangle-exclamation" style={{ marginTop: 1 }} />
                  <span>All pending tasks before the selected step will be skipped. Full audit trail will be logged.</span>
                </div>
                <label style={labelStyle}>Jump to Step *</label>
                <select
                  value={targetStep}
                  onChange={e => setTargetStep(e.target.value ? Number(e.target.value) : '')}
                  style={{ ...iStyle, marginBottom: 8 }}
                >
                  <option value="">— Select step —</option>
                  {remainSteps.map(s => (
                    <option key={s.id} value={s.step_order}>
                      Step {s.step_order}: {s.name}
                    </option>
                  ))}
                </select>
                <label style={labelStyle}>Reason * <span style={{ fontWeight: 400, textTransform: 'none', color: C.red }}>mandatory</span></label>
                <textarea
                  value={actionReason}
                  onChange={e => setActionReason(e.target.value)}
                  placeholder="Mandatory — explain why this step is being skipped…"
                  rows={3}
                  style={{ ...iStyle, resize: 'vertical', marginBottom: 0 }}
                />
              </ActionPanel>
            )}

            {/* ── Decline panel ───────────────────────────────────────────────── */}
            {actionMode === 'decline' && (
              <ActionPanel
                title="Decline & Return to Submitter"
                color="#DC2626"
                bg={C.redL}
                onCancel={() => setActionMode('idle')}
                onConfirm={doDecline}
                confirmLabel="Decline"
                loading={actioning}
                disabled={!actionReason.trim()}
              >
                <div style={{
                  padding: '8px 10px', borderRadius: 6, fontSize: 12, marginBottom: 10,
                  background: C.redL, border: '1px solid #FECACA', color: C.red,
                  display: 'flex', gap: 7, alignItems: 'flex-start',
                }}>
                  <i className="fas fa-circle-info" style={{ marginTop: 1 }} />
                  <span>The request will be returned to {selectedRow.submitter_name}. They can resubmit with corrections or withdraw.</span>
                </div>
                <label style={labelStyle}>Reason * <span style={{ fontWeight: 400, textTransform: 'none', color: C.red }}>mandatory</span></label>
                <textarea
                  value={actionReason}
                  onChange={e => setActionReason(e.target.value)}
                  placeholder="Mandatory — explain why this request is being declined…"
                  rows={3}
                  style={{ ...iStyle, resize: 'vertical', marginBottom: 0 }}
                />
              </ActionPanel>
            )}

            {/* ── Audit trail ─────────────────────────────────────────────────── */}
            <div style={{ padding: '14px 18px', flex: 1 }}>
              <p style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.06em', margin: '0 0 12px' }}>
                Audit Trail
              </p>
              {history.length === 0 ? (
                <p style={{ fontSize: 12, color: C.faint, fontStyle: 'italic' }}>No events yet.</p>
              ) : (
                <div style={{ position: 'relative', paddingLeft: 24 }}>
                  <div style={{ position: 'absolute', left: 8, top: 6, bottom: 6, width: 2, background: C.border }} />
                  {history.map((h: any) => (
                    <div key={h.id} style={{ marginBottom: 14, position: 'relative' }}>
                      <div style={{
                        position: 'absolute', left: -24, width: 16, height: 16,
                        borderRadius: '50%', background: '#fff',
                        border: `2px solid ${actionColorForLog(h.action)}`,
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                      }}>
                        <i className={`fas ${actionIconForLog(h.action)}`} style={{ fontSize: 7, color: actionColorForLog(h.action) }} />
                      </div>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
                        <span style={{ fontSize: 12, fontWeight: 600, color: C.navy }}>
                          {actionLabelForLog(h.action)}
                        </span>
                        {h.actorName && <span style={{ fontSize: 11, color: C.muted }}>by {h.actorName}</span>}
                        {h.stepOrder && (
                          <span style={{ fontSize: 10, background: C.bg, color: C.faint, borderRadius: 3, padding: '1px 5px' }}>
                            Step {h.stepOrder}
                          </span>
                        )}
                      </div>
                      <div style={{ fontSize: 11, color: C.faint, marginTop: 1 }}>{fmtDate(h.createdAt)}</div>
                      {h.notes && (
                        <div style={{
                          marginTop: 4, fontSize: 11, color: C.text,
                          background: C.bg, border: `1px solid ${C.border}`,
                          borderRadius: 5, padding: '5px 8px',
                        }}>
                          {h.notes}
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Log label/icon/color helpers ─────────────────────────────────────────────

const LOG_CONFIG: Record<string, { icon: string; color: string; label: string }> = {
  submitted:              { icon: 'fa-paper-plane',    color: '#2563EB', label: 'Submitted'              },
  approved:               { icon: 'fa-circle-check',   color: '#16A34A', label: 'Approved'               },
  rejected:               { icon: 'fa-circle-xmark',   color: '#DC2626', label: 'Rejected'               },
  reassigned:             { icon: 'fa-arrows-rotate',  color: '#7C3AED', label: 'Reassigned'             },
  withdrawn:              { icon: 'fa-rotate-left',    color: '#6B7280', label: 'Withdrawn'              },
  completed:              { icon: 'fa-flag-checkered', color: '#16A34A', label: 'Completed'              },
  step_advanced:          { icon: 'fa-chevron-right',  color: '#2563EB', label: 'Forwarded'              },
  force_advanced:         { icon: 'fa-forward-step',   color: '#7C3AED', label: 'Force Advanced'         },
  admin_declined:         { icon: 'fa-hand',           color: '#DC2626', label: 'Admin Declined'         },
  returned_to_initiator:  { icon: 'fa-comment-dots',   color: '#D97706', label: 'Returned for Clarif.'  },
  resubmitted:            { icon: 'fa-reply',          color: '#2563EB', label: 'Resubmitted'            },
  returned_to_previous_step: { icon: 'fa-backward-step', color: '#374151', label: 'Returned to Prev Step'},
};

function actionIconForLog(action: string)  { return LOG_CONFIG[action]?.icon  ?? 'fa-circle'; }
function actionColorForLog(action: string) { return LOG_CONFIG[action]?.color ?? '#9CA3AF'; }
function actionLabelForLog(action: string) { return LOG_CONFIG[action]?.label ?? action; }

// ─── Shared sub-components ────────────────────────────────────────────────────

function Chip({ icon, label, color = '#6B7280' }: { icon: string; label: string; color?: string }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      fontSize: 11, color, background: '#F3F4F6',
      borderRadius: 5, padding: '3px 8px',
    }}>
      <i className={`fas ${icon}`} style={{ fontSize: 9 }} />
      {label}
    </span>
  );
}

function Avatar({ name, color, size = 28 }: { name: string; color: string; size?: number }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: '50%',
      background: color, color: '#fff', flexShrink: 0,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontSize: size * 0.4, fontWeight: 700,
    }}>
      {name.charAt(0).toUpperCase()}
    </div>
  );
}

function ActionBtn({ label, icon, color, onClick }: { label: string; icon: string; color: string; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 5,
        padding: '6px 12px', borderRadius: 6, fontSize: 12, fontWeight: 600,
        background: `${color}11`, color, border: `1px solid ${color}33`,
        cursor: 'pointer',
      }}
      onMouseEnter={e => (e.currentTarget.style.background = `${color}22`)}
      onMouseLeave={e => (e.currentTarget.style.background = `${color}11`)}
    >
      <i className={`fas ${icon}`} style={{ fontSize: 11 }} />
      {label}
    </button>
  );
}

function ActionPanel({ title, color, bg, children, onCancel, onConfirm, confirmLabel, loading, disabled }: {
  title: string; color: string; bg: string; children: React.ReactNode;
  onCancel: () => void; onConfirm: () => void;
  confirmLabel: string; loading?: boolean; disabled?: boolean;
}) {
  return (
    <div style={{
      margin: '0 18px 14px',
      border: `1px solid ${color}44`, borderRadius: 8,
      background: bg, overflow: 'hidden',
    }}>
      <div style={{
        padding: '10px 14px', borderBottom: `1px solid ${color}33`,
        display: 'flex', justifyContent: 'space-between', alignItems: 'center',
      }}>
        <span style={{ fontSize: 12, fontWeight: 700, color }}>{title}</span>
        <button onClick={onCancel} style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 16, lineHeight: 1 }}>×</button>
      </div>
      <div style={{ padding: '12px 14px' }}>
        {children}
        <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end', marginTop: 10 }}>
          <button onClick={onCancel} style={{ padding: '6px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600, background: '#fff', color: '#374151', border: '1px solid #E5E7EB', cursor: 'pointer' }}>
            Cancel
          </button>
          <button
            onClick={onConfirm}
            disabled={disabled || loading}
            style={{
              padding: '6px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600,
              background: color, color: '#fff', border: 'none',
              cursor: disabled || loading ? 'not-allowed' : 'pointer',
              opacity: disabled || loading ? 0.65 : 1,
            }}
          >
            {loading ? <><i className="fas fa-spinner fa-spin" style={{ marginRight: 5 }} />Working…</> : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}

function PageBtn({ label, onClick, disabled }: { label: string; onClick: () => void; disabled: boolean }) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      style={{
        padding: '5px 12px', borderRadius: 5, fontSize: 12, fontWeight: 600,
        background: '#fff', color: disabled ? '#D1D5DB' : C.text,
        border: `1px solid ${C.border}`,
        cursor: disabled ? 'not-allowed' : 'pointer',
      }}
    >
      {label}
    </button>
  );
}

// ─── Shared styles ────────────────────────────────────────────────────────────

const tdStyle: React.CSSProperties = {
  padding: '10px 12px', verticalAlign: 'middle',
  borderBottom: `1px solid ${C.border}`,
};

const selStyle: React.CSSProperties = {
  padding: '6px 10px', fontSize: 12, borderRadius: 6,
  border: `1px solid ${C.border}`, background: '#fff',
  color: C.text, outline: 'none', cursor: 'pointer',
};

const iStyle: React.CSSProperties = {
  width: '100%', padding: '7px 10px',
  border: `1px solid ${C.border}`, borderRadius: 6,
  fontSize: 12, outline: 'none', fontFamily: 'inherit',
  background: '#fff', boxSizing: 'border-box', color: C.text,
};

const labelStyle: React.CSSProperties = {
  display: 'block', fontSize: 10, fontWeight: 700,
  color: '#6B7280', textTransform: 'uppercase',
  letterSpacing: '0.05em', marginBottom: 5,
};

const clearBtnStyle: React.CSSProperties = {
  background: 'none', border: 'none', cursor: 'pointer',
  color: '#9CA3AF', fontSize: 16, padding: '0 2px', lineHeight: 1,
};

const bulkBtnStyle: React.CSSProperties = {
  display: 'inline-flex', alignItems: 'center', gap: 5,
  padding: '6px 12px', borderRadius: 6, fontSize: 12, fontWeight: 600,
  border: 'none', cursor: 'pointer',
};
