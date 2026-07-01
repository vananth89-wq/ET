/**
 * WorkflowPerformanceDashboard
 *
 * HR / admin screen surfacing approver performance metrics:
 *   - Summary KPI cards (submitted, completed, in-progress, avg completion time)
 *   - Step bottleneck bars (avg hours per step vs SLA), grouped by template
 *   - Approver table (sortable, colour-coded by avg response time)
 *   - Currently overdue tasks
 *
 * Route:  /admin/workflow/performance
 * Access: workflow.admin only
 */

import { useState, useEffect, useCallback, useMemo } from 'react';
import { supabase } from '../../lib/supabase';

// ─── Types ─────────────────────────────────────────────────────────────────────

interface WorkflowSummary {
  submittedCount:      number;
  completedCount:      number;
  rejectedCount:       number;
  withdrawnCount:      number;
  inProgressCount:     number;
  avgCompletionHours:  number | null;
  avgStepHours:        number | null;
}

interface ApproverRow {
  approverId:      string;
  approverName:    string;
  departmentName:  string | null;
  jobTitle:        string | null;
  totalActioned:   number;
  approvedCount:   number;
  rejectedCount:   number;
  returnedCount:   number;
  reassignedCount: number;
  pendingCount:    number;
  overdueCount:    number;
  avgHours:        number | null;
  medianHours:     number | null;
  approvalRate:    number | null;
}

interface StepRow {
  templateCode:  string;
  templateName:  string;
  stepOrder:     number;
  stepName:      string;
  totalTasks:    number;
  avgHours:      number | null;
  medianHours:   number | null;
  overdueCount:  number;
  slaHours:      number | null;
}

interface OverdueTask {
  taskId:           string;
  instanceId:       string;
  stepName:         string;
  templateName:     string;
  assignedToName:   string | null;
  submittedByName:  string | null;
  dueAt:            string;
  hoursOverdue:     number;
}

type SortKey = keyof Pick<
  ApproverRow,
  'approverName' | 'totalActioned' | 'approvalRate' | 'avgHours' | 'overdueCount' | 'pendingCount'
>;
type SortDir = 'asc' | 'desc';

type RangeKey = '7d' | '30d' | '90d';

const RANGES: { key: RangeKey; label: string }[] = [
  { key: '7d',  label: 'Last 7 days'  },
  { key: '30d', label: 'Last 30 days' },
  { key: '90d', label: 'Last 90 days' },
];

function rangeToFrom(key: RangeKey): Date {
  const d = new Date();
  d.setDate(d.getDate() - (key === '7d' ? 7 : key === '30d' ? 30 : 90));
  return d;
}

/**
 * Safely convert a value from Postgres to a JS number.
 * Postgres numeric NaN serialises as the JSON string "NaN" — guard against that.
 */
function safeNum(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const n = Number(v);
  return isNaN(n) ? null : n;
}

function fmtHours(h: number | null): string {
  if (h === null || h === undefined || isNaN(h)) return '—';
  if (h < 1)  return `${Math.round(h * 60)}m`;
  if (h < 24) return `${h.toFixed(1)}h`;
  return `${(h / 24).toFixed(1)}d`;
}

function formatDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

function formatTime(d: Date) {
  return new Intl.DateTimeFormat('en-GB', {
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).format(d);
}

// ─── Colour helpers ────────────────────────────────────────────────────────────

function rowBg(avgHours: number | null): string {
  if (avgHours === null) return 'transparent';
  if (avgHours <= 24)   return '#F0FDF4';
  if (avgHours <= 72)   return '#FFFBEB';
  return '#FEF2F2';
}
function rowAccent(avgHours: number | null): string {
  if (avgHours === null) return '#E5E7EB';
  if (avgHours <= 24)   return '#16A34A';
  if (avgHours <= 72)   return '#D97706';
  return '#DC2626';
}

function barColor(avgHours: number | null, slaHours: number | null): string {
  if (avgHours === null) return '#D1D5DB';
  if (slaHours === null) return avgHours <= 24 ? '#16A34A' : avgHours <= 72 ? '#D97706' : '#DC2626';
  if (avgHours <= slaHours)       return '#16A34A';
  if (avgHours <= slaHours * 1.5) return '#D97706';
  return '#DC2626';
}

// ─── Component ─────────────────────────────────────────────────────────────────

export default function WorkflowPerformanceDashboard() {
  const [range,         setRange]         = useState<RangeKey>('30d');
  const [templateCode,  setTemplateCode]  = useState<string>('');
  const [templates,     setTemplates]     = useState<{ code: string; name: string }[]>([]);

  const [summary,   setSummary]   = useState<WorkflowSummary | null>(null);
  const [approvers, setApprovers] = useState<ApproverRow[]>([]);
  const [steps,     setSteps]     = useState<StepRow[]>([]);
  const [overdue,   setOverdue]   = useState<OverdueTask[]>([]);

  const [loading,      setLoading]      = useState(false);
  const [error,        setError]        = useState<string | null>(null);
  const [lastUpdated,  setLastUpdated]  = useState<Date | null>(null);

  // Approver table sort
  const [sortKey, setSortKey] = useState<SortKey>('avgHours');
  const [sortDir, setSortDir] = useState<SortDir>('desc');

  // Collapsed template groups in bottleneck section
  const [collapsedTemplates, setCollapsedTemplates] = useState<Set<string>>(new Set());

  // ── Load templates once ────────────────────────────────────────────────────
  useEffect(() => {
    supabase
      .from('workflow_templates')
      .select('code, name')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => setTemplates(data ?? []));
  }, []);

  // ── Load all data ──────────────────────────────────────────────────────────
  const load = useCallback(async () => {
    setLoading(true);
    setError(null);

    const from = rangeToFrom(range).toISOString();
    const to   = new Date().toISOString();
    const tpl  = templateCode || null;

    try {
      const [summaryRes, approverRes, stepRes, overdueRes] = await Promise.all([
        supabase.rpc('get_workflow_summary', {
          p_from: from, p_to: to, p_template_code: tpl,
        }),
        supabase.rpc('get_approver_performance', {
          p_from: from, p_to: to, p_template_code: tpl,
        }),
        supabase.rpc('get_step_bottlenecks', {
          p_from: from, p_to: to, p_template_code: tpl,
        }),
        supabase
          .from('vw_wf_pending_tasks')
          .select('task_id, instance_id, step_name, template_name, submitted_by_name, due_at')
          .not('due_at', 'is', null)
          .lt('due_at', new Date().toISOString())
          .order('due_at', { ascending: true })
          .limit(50),
      ]);

      if (summaryRes.error) throw new Error(summaryRes.error.message);
      if (approverRes.error) throw new Error(approverRes.error.message);
      if (stepRes.error)    throw new Error(stepRes.error.message);

      const s = summaryRes.data?.[0] ?? null;
      setSummary(s ? {
        submittedCount:     Number(s.submitted_count     ?? 0),
        completedCount:     Number(s.completed_count     ?? 0),
        rejectedCount:      Number(s.rejected_count      ?? 0),
        withdrawnCount:     Number(s.withdrawn_count     ?? 0),
        inProgressCount:    Number(s.in_progress_count   ?? 0),
        avgCompletionHours: safeNum(s.avg_completion_hours),
        avgStepHours:       safeNum(s.avg_step_hours),
      } : null);

      setApprovers(
        (approverRes.data ?? []).map((r: any) => ({
          approverId:      r.approver_id,
          approverName:    r.approver_name,
          departmentName:  r.department_name,
          jobTitle:        r.job_title,
          totalActioned:   Number(r.total_actioned   ?? 0),
          approvedCount:   Number(r.approved_count   ?? 0),
          rejectedCount:   Number(r.rejected_count   ?? 0),
          returnedCount:   Number(r.returned_count   ?? 0),
          reassignedCount: Number(r.reassigned_count ?? 0),
          pendingCount:    Number(r.pending_count    ?? 0),
          overdueCount:    Number(r.overdue_count    ?? 0),
          avgHours:        safeNum(r.avg_hours),
          medianHours:     safeNum(r.median_hours),
          approvalRate:    safeNum(r.approval_rate),
        }))
      );

      setSteps(
        (stepRes.data ?? []).map((r: any) => ({
          templateCode: r.template_code,
          templateName: r.template_name,
          stepOrder:    Number(r.step_order),
          stepName:     r.step_name,
          totalTasks:   Number(r.total_tasks   ?? 0),
          avgHours:     safeNum(r.avg_hours),
          medianHours:  safeNum(r.median_hours),
          overdueCount: Number(r.overdue_count ?? 0),
          slaHours:     safeNum(r.sla_hours),
        }))
      );

      const now = Date.now();
      setOverdue(
        (overdueRes.data ?? []).map((r: any) => ({
          taskId:          r.task_id,
          instanceId:      r.instance_id,
          stepName:        r.step_name,
          templateName:    r.template_name,
          assignedToName:  r.assigned_to_name ?? null,
          submittedByName: r.submitted_by_name ?? null,
          dueAt:           r.due_at,
          hoursOverdue:    Math.round((now - new Date(r.due_at).getTime()) / 3_600_000),
        }))
      );

      setLastUpdated(new Date());
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [range, templateCode]);

  useEffect(() => { load(); }, [load]);

  // ── Sorted approvers ────────────────────────────────────────────────────────
  const sortedApprovers = useMemo(() => {
    return [...approvers].sort((a, b) => {
      const av = a[sortKey] ?? (sortDir === 'asc' ? Infinity : -Infinity);
      const bv = b[sortKey] ?? (sortDir === 'asc' ? Infinity : -Infinity);
      if (typeof av === 'string' && typeof bv === 'string')
        return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
      return sortDir === 'asc' ? (av as number) - (bv as number) : (bv as number) - (av as number);
    });
  }, [approvers, sortKey, sortDir]);

  function toggleSort(key: SortKey) {
    if (sortKey === key) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortKey(key); setSortDir('desc'); }
  }

  // ── Steps grouped by template ───────────────────────────────────────────────
  const stepsByTemplate = useMemo(() => {
    const map = new Map<string, { templateName: string; steps: StepRow[] }>();
    for (const s of steps) {
      if (!map.has(s.templateCode)) map.set(s.templateCode, { templateName: s.templateName, steps: [] });
      map.get(s.templateCode)!.steps.push(s);
    }
    return [...map.entries()];
  }, [steps]);

  // ── Max avg hours across steps (for bar scaling) ────────────────────────────
  const maxStepHours = useMemo(() => {
    const valid = steps.map(s => s.avgHours).filter((h): h is number => h !== null);
    return Math.max(1, ...valid);
  }, [steps]);

  // Derived KPIs
  const completionRate = summary && summary.submittedCount > 0
    ? Math.round((summary.completedCount / summary.submittedCount) * 100)
    : null;

  const totalOverdue = overdue.length;

  // ─── Render ────────────────────────────────────────────────────────────────

  return (
    <div style={{ padding: '32px 40px', maxWidth: 1200, margin: '0 auto' }}>

      {/* ── Header ──────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: '#18345B', margin: 0 }}>
            Approver Performance
          </h1>
          <p style={{ fontSize: 13, color: '#6B7280', marginTop: 4, margin: 0 }}>
            Bottleneck analysis and approver response times
          </p>
        </div>

        {/* Filters + refresh */}
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <select
            value={templateCode}
            onChange={e => setTemplateCode(e.target.value)}
            style={selectStyle}
          >
            <option value="">All workflows</option>
            {templates.map(t => (
              <option key={t.code} value={t.code}>{t.name}</option>
            ))}
          </select>

          <div style={{ display: 'flex', gap: 4, background: '#F3F4F6', borderRadius: 8, padding: 3 }}>
            {RANGES.map(r => (
              <button
                key={r.key}
                onClick={() => setRange(r.key)}
                style={{
                  padding: '5px 11px', borderRadius: 6, border: 'none',
                  background: range === r.key ? '#18345B' : 'transparent',
                  color:      range === r.key ? '#fff'    : '#6B7280',
                  fontWeight: 600, fontSize: 12, cursor: 'pointer',
                  transition: 'all 0.15s',
                }}
              >
                {r.label}
              </button>
            ))}
          </div>

          <button
            onClick={load}
            disabled={loading}
            style={{
              display: 'flex', alignItems: 'center', gap: 6,
              padding: '6px 12px', borderRadius: 6,
              border: '1px solid #D1D5DB', background: '#fff',
              fontSize: 12, fontWeight: 500, color: '#374151',
              cursor: loading ? 'not-allowed' : 'pointer',
              opacity: loading ? 0.7 : 1,
            }}
          >
            <i className={`fas fa-arrows-rotate ${loading ? 'fa-spin' : ''}`} style={{ fontSize: 11 }} />
            Refresh
          </button>
        </div>
      </div>

      {/* Last updated */}
      {lastUpdated && !loading && (
        <div style={{ fontSize: 11, color: '#9CA3AF', marginBottom: 16 }}>
          Last updated {formatTime(lastUpdated)}
        </div>
      )}

      {/* ── Error ────────────────────────────────────────────────────────────── */}
      {error && (
        <div style={{
          padding: '10px 14px', borderRadius: 8, marginBottom: 20,
          background: '#FEF2F2', border: '1px solid #FECACA', color: '#DC2626', fontSize: 13,
        }}>
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 8 }} />
          {error}
        </div>
      )}

      {/* ── Loading skeleton ─────────────────────────────────────────────────── */}
      {loading && (
        <>
          <div style={{ display: 'flex', gap: 12, marginBottom: 28 }}>
            {[1,2,3,4,5].map(i => (
              <div key={i} style={{
                flex: '1 1 0', height: 90, borderRadius: 10,
                background: 'linear-gradient(90deg, #F3F4F6 25%, #E5E7EB 50%, #F3F4F6 75%)',
                backgroundSize: '200% 100%',
                animation: 'shimmer 1.4s infinite',
              }} />
            ))}
          </div>
          <div style={{ height: 200, borderRadius: 12, background: '#F9FAFB', border: '1px solid #E5E7EB' }} />
          <style>{`@keyframes shimmer { 0%{background-position:200% 0} 100%{background-position:-200% 0} }`}</style>
        </>
      )}

      {!loading && (
        <>
          {/* ── KPI Cards ────────────────────────────────────────────────────── */}
          <div style={{ display: 'flex', gap: 12, marginBottom: 20, flexWrap: 'wrap' }}>
            <KpiCard
              label="Submitted"
              value={summary?.submittedCount ?? 0}
              icon="fa-paper-plane"
              color="#2F77B5" bg="#EFF6FF" border="#BFDBFE"
            />
            <KpiCard
              label="Completed"
              value={summary?.completedCount ?? 0}
              icon="fa-circle-check"
              color="#16A34A" bg="#F0FDF4" border="#BBF7D0"
              subtitle={completionRate !== null ? `${completionRate}% completion rate` : undefined}
            />
            <KpiCard
              label="In Progress"
              value={summary?.inProgressCount ?? 0}
              icon="fa-hourglass-half"
              color="#D97706" bg="#FFFBEB" border="#FDE68A"
              subtitle={
                (summary?.rejectedCount || summary?.withdrawnCount)
                  ? `${summary?.rejectedCount ?? 0} rejected · ${summary?.withdrawnCount ?? 0} withdrawn`
                  : undefined
              }
            />
            <KpiCard
              label="Avg Completion"
              value={fmtHours(summary?.avgCompletionHours ?? null)}
              icon="fa-clock"
              color="#7C3AED" bg="#F5F3FF" border="#DDD6FE"
              subtitle="end-to-end"
            />
            <KpiCard
              label="Avg Step Time"
              value={fmtHours(summary?.avgStepHours ?? null)}
              icon="fa-forward-step"
              color="#0891B2" bg="#ECFEFF" border="#A5F3FC"
              subtitle="per approval"
            />
            {totalOverdue > 0 && (
              <KpiCard
                label="Overdue Now"
                value={totalOverdue}
                icon="fa-circle-exclamation"
                color="#DC2626" bg="#FEF2F2" border="#FECACA"
                subtitle="breached SLA"
              />
            )}
          </div>

          {/* ── Step Bottlenecks ──────────────────────────────────────────────── */}
          <Section title="Step Bottlenecks" icon="fa-chart-bar"
            subtitle="Average time per approval step, grouped by workflow">

            {steps.length === 0 ? (
              <EmptyState icon="fa-chart-bar" message="No step data for this period." />
            ) : (
              <>
                {stepsByTemplate.map(([tplCode, group]) => {
                  const isCollapsed = collapsedTemplates.has(tplCode);
                  const hasOverdue  = group.steps.some(s => s.overdueCount > 0);

                  return (
                    <div key={tplCode} style={{ marginBottom: 20 }}>
                      {/* Template header */}
                      <button
                        onClick={() => setCollapsedTemplates(prev => {
                          const next = new Set(prev);
                          next.has(tplCode) ? next.delete(tplCode) : next.add(tplCode);
                          return next;
                        })}
                        style={{
                          display: 'flex', alignItems: 'center', gap: 8,
                          background: '#F8FAFC', border: '1px solid #E5E7EB',
                          borderRadius: 8, padding: '7px 12px', cursor: 'pointer',
                          width: '100%', marginBottom: isCollapsed ? 0 : 12,
                        }}
                      >
                        <i
                          className={`fas fa-chevron-${isCollapsed ? 'right' : 'down'}`}
                          style={{ fontSize: 10, color: '#9CA3AF', width: 10 }}
                        />
                        <span style={{ fontWeight: 700, fontSize: 13, color: '#18345B' }}>
                          {group.templateName}
                        </span>
                        <span style={{ fontSize: 11, color: '#9CA3AF', marginLeft: 'auto' }}>
                          {group.steps.length} step{group.steps.length !== 1 ? 's' : ''}
                        </span>
                        {hasOverdue && (
                          <span style={{
                            fontSize: 11, background: '#FEF2F2', color: '#DC2626',
                            borderRadius: 4, padding: '1px 6px', fontWeight: 600,
                          }}>
                            overdue
                          </span>
                        )}
                      </button>

                      {!isCollapsed && (
                        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                          {group.steps.map(step => {
                            const pct = step.avgHours !== null
                              ? Math.min(100, (step.avgHours / maxStepHours) * 100)
                              : 0;
                            const slaPct = step.slaHours !== null
                              ? Math.min(100, (step.slaHours / maxStepHours) * 100)
                              : null;
                            const color = barColor(step.avgHours, step.slaHours);

                            return (
                              <div key={`${step.templateCode}-${step.stepOrder}`}
                                style={{ paddingLeft: 22 }}>
                                <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 5 }}>
                                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                                    <span style={{
                                      fontSize: 10, background: '#EFF6FF', color: '#1D4ED8',
                                      borderRadius: 4, padding: '1px 6px', fontWeight: 700,
                                    }}>
                                      Step {step.stepOrder}
                                    </span>
                                    <span style={{ fontSize: 13, fontWeight: 600, color: '#111827' }}>
                                      {step.stepName}
                                    </span>
                                    {step.overdueCount > 0 && (
                                      <span style={{
                                        fontSize: 11, background: '#FEF2F2', color: '#DC2626',
                                        borderRadius: 4, padding: '1px 6px', fontWeight: 600,
                                        display: 'flex', alignItems: 'center', gap: 3,
                                      }}>
                                        <i className="fas fa-circle-exclamation" style={{ fontSize: 9 }} />
                                        {step.overdueCount} overdue
                                      </span>
                                    )}
                                  </div>
                                  <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                                    {step.slaHours && (
                                      <span style={{ fontSize: 11, color: '#9CA3AF' }}>
                                        SLA: {fmtHours(step.slaHours)}
                                      </span>
                                    )}
                                    <span style={{ fontSize: 13, fontWeight: 700, color }}>
                                      {step.avgHours !== null ? `${fmtHours(step.avgHours)} avg` : 'No data'}
                                    </span>
                                    {step.medianHours !== null && (
                                      <span style={{ fontSize: 11, color: '#9CA3AF' }}>
                                        med {fmtHours(step.medianHours)}
                                      </span>
                                    )}
                                    <span style={{ fontSize: 11, color: '#9CA3AF' }}>
                                      {step.totalTasks} tasks
                                    </span>
                                  </div>
                                </div>

                                {/* Bar track */}
                                <div style={{ position: 'relative', height: 8, background: '#F3F4F6', borderRadius: 4, overflow: 'visible' }}>
                                  <div style={{
                                    height: '100%',
                                    width: `${pct}%`,
                                    background: color,
                                    borderRadius: 4,
                                    transition: 'width 0.4s ease',
                                  }} />
                                  {/* SLA marker */}
                                  {slaPct !== null && (
                                    <div style={{
                                      position: 'absolute',
                                      left: `${slaPct}%`,
                                      top: -3, bottom: -3,
                                      width: 2,
                                      background: '#9CA3AF',
                                      borderRadius: 1,
                                    }} />
                                  )}
                                </div>
                              </div>
                            );
                          })}
                        </div>
                      )}
                    </div>
                  );
                })}

                <div style={{ marginTop: 4, display: 'flex', gap: 16, flexWrap: 'wrap' }}>
                  <Legend color="#16A34A" label="Within SLA" />
                  <Legend color="#D97706" label="≤ 1.5× SLA" />
                  <Legend color="#DC2626" label="> 1.5× SLA" />
                  <span style={{ fontSize: 11, color: '#9CA3AF', display: 'flex', alignItems: 'center', gap: 4 }}>
                    <span style={{ display: 'inline-block', width: 2, height: 12, background: '#9CA3AF', borderRadius: 1 }} />
                    SLA boundary
                  </span>
                </div>
              </>
            )}
          </Section>

          {/* ── Approver Table ────────────────────────────────────────────────── */}
          <Section
            title="Approver Breakdown"
            icon="fa-users"
            subtitle="Green < 24h · Amber 24–72h · Red > 72h average response time"
            badge={approvers.length > 0 ? String(approvers.length) : undefined}
          >
            {approvers.length === 0 ? (
              <EmptyState icon="fa-users" message="No approver activity in this period." />
            ) : (
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                  <thead>
                    <tr style={{ background: '#F9FAFB', borderBottom: '2px solid #E5E7EB' }}>
                      <Th label="Approver"    sortKey="approverName"  current={sortKey} dir={sortDir} onSort={toggleSort} />
                      <Th label="Actioned"    sortKey="totalActioned" current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                      <Th label="Approval %"  sortKey="approvalRate"  current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                      <Th label="Avg Time"    sortKey="avgHours"      current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                      <Th label="Pending"     sortKey="pendingCount"  current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                      <Th label="Overdue"     sortKey="overdueCount"  current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                    </tr>
                  </thead>
                  <tbody>
                    {sortedApprovers.map(a => (
                      <tr
                        key={a.approverId}
                        style={{
                          background:   rowBg(a.avgHours),
                          borderBottom: '1px solid #F3F4F6',
                          borderLeft:   `3px solid ${rowAccent(a.avgHours)}`,
                        }}
                      >
                        <td style={{ padding: '10px 14px' }}>
                          <div style={{ fontWeight: 600, color: '#111827' }}>{a.approverName}</div>
                          <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 1 }}>
                            {[a.jobTitle, a.departmentName].filter(Boolean).join(' · ')}
                          </div>
                        </td>
                        <td style={{ padding: '10px 14px', textAlign: 'center', color: '#374151' }}>
                          <div style={{ fontWeight: 600 }}>{a.totalActioned}</div>
                          {a.totalActioned > 0 && (
                            <div style={{ fontSize: 10, color: '#9CA3AF', marginTop: 2 }}>
                              {a.approvedCount > 0 && <span style={{ color: '#16A34A' }}>{a.approvedCount} ✓ </span>}
                              {a.rejectedCount > 0 && <span style={{ color: '#DC2626' }}>{a.rejectedCount} ✗ </span>}
                              {a.returnedCount > 0 && <span>{a.returnedCount} ↩</span>}
                            </div>
                          )}
                        </td>
                        <td style={{ padding: '10px 14px', textAlign: 'center' }}>
                          {a.approvalRate !== null ? (
                            <span style={{
                              fontWeight: 700,
                              color: a.approvalRate >= 80 ? '#16A34A' : a.approvalRate >= 50 ? '#D97706' : '#DC2626',
                            }}>
                              {a.approvalRate.toFixed(0)}%
                            </span>
                          ) : <span style={{ color: '#9CA3AF' }}>—</span>}
                        </td>
                        <td style={{ padding: '10px 14px', textAlign: 'center' }}>
                          <span style={{ fontWeight: 700, color: rowAccent(a.avgHours) }}>
                            {fmtHours(a.avgHours)}
                          </span>
                          {a.medianHours !== null && (
                            <div style={{ fontSize: 10, color: '#9CA3AF', marginTop: 1 }}>
                              med {fmtHours(a.medianHours)}
                            </div>
                          )}
                        </td>
                        <td style={{ padding: '10px 14px', textAlign: 'center' }}>
                          <span style={{ fontWeight: 600, color: a.pendingCount > 5 ? '#D97706' : '#374151' }}>
                            {a.pendingCount}
                          </span>
                        </td>
                        <td style={{ padding: '10px 14px', textAlign: 'center' }}>
                          {a.overdueCount > 0 ? (
                            <span style={{
                              fontWeight: 700, color: '#DC2626',
                              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 4,
                            }}>
                              <i className="fas fa-circle-exclamation" style={{ fontSize: 11 }} />
                              {a.overdueCount}
                            </span>
                          ) : (
                            <span style={{ color: '#D1D5DB' }}>—</span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Section>

          {/* ── Overdue Tasks ─────────────────────────────────────────────────── */}
          {overdue.length > 0 ? (
            <Section
              title={`Overdue Right Now`}
              icon="fa-circle-exclamation"
              titleColor="#DC2626"
              subtitle="Pending tasks that have already breached their SLA deadline"
              badge={String(overdue.length)}
              badgeColor="#DC2626"
            >
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {overdue.map(t => (
                  <div
                    key={t.taskId}
                    style={{
                      display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                      padding: '10px 14px', borderRadius: 8,
                      background: '#FEF2F2', border: '1px solid #FECACA',
                      flexWrap: 'wrap', gap: 8,
                    }}
                  >
                    <div style={{ flex: 1, minWidth: 200 }}>
                      <div style={{ fontWeight: 600, fontSize: 13, color: '#111827' }}>
                        {t.templateName}
                      </div>
                      <div style={{ fontSize: 12, color: '#6B7280', marginTop: 2 }}>
                        Step: {t.stepName}
                        {t.submittedByName && ` · Submitted by ${t.submittedByName}`}
                        {t.assignedToName && ` · Assigned to ${t.assignedToName}`}
                      </div>
                    </div>
                    <div style={{ textAlign: 'right', flexShrink: 0 }}>
                      <div style={{ fontWeight: 700, fontSize: 13, color: '#DC2626' }}>
                        {t.hoursOverdue < 24
                          ? `${t.hoursOverdue}h overdue`
                          : `${(t.hoursOverdue / 24).toFixed(1)}d overdue`}
                      </div>
                      <div style={{ fontSize: 11, color: '#9CA3AF' }}>
                        Due {formatDate(t.dueAt)}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </Section>
          ) : summary && (
            <Section title="Overdue Right Now" icon="fa-circle-check" titleColor="#16A34A" subtitle="">
              <EmptyState icon="fa-circle-check" iconColor="#16A34A" message="No overdue tasks — all steps within SLA." />
            </Section>
          )}
        </>
      )}
    </div>
  );
}

// ── Sub-components ─────────────────────────────────────────────────────────────

function KpiCard({
  label, value, icon, color, bg, border, subtitle,
}: {
  label: string; value: string | number; icon: string;
  color: string; bg: string; border: string; subtitle?: string;
}) {
  return (
    <div style={{
      flex: '1 1 0', minWidth: 130,
      background: bg,
      border: `1.5px solid ${border}`,
      borderRadius: 10, padding: '16px 20px',
      boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8 }}>
        <span style={{
          fontSize: 10, fontWeight: 700, color,
          textTransform: 'uppercase', letterSpacing: '0.07em',
        }}>
          {label}
        </span>
        <i className={`fas ${icon}`} style={{ fontSize: 13, color, opacity: 0.7 }} />
      </div>
      <div style={{ fontSize: 26, fontWeight: 800, color, lineHeight: 1 }}>{value}</div>
      {subtitle && (
        <div style={{ fontSize: 11, color, opacity: 0.65, marginTop: 4 }}>{subtitle}</div>
      )}
    </div>
  );
}

function Section({
  title, icon, subtitle, children, titleColor, badge, badgeColor,
}: {
  title: string; icon: string; subtitle?: string;
  children: React.ReactNode; titleColor?: string;
  badge?: string; badgeColor?: string;
}) {
  return (
    <div style={{
      background: '#fff', borderRadius: 12,
      border: '1px solid #E5E7EB', padding: '20px 24px',
      marginBottom: 20,
    }}>
      <div style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className={`fas ${icon}`} style={{ fontSize: 14, color: titleColor ?? '#18345B' }} />
          <span style={{ fontWeight: 700, fontSize: 15, color: titleColor ?? '#18345B' }}>
            {title}
          </span>
          {badge && (
            <span style={{
              fontSize: 11, fontWeight: 700,
              background: badgeColor ? `${badgeColor}18` : '#EFF6FF',
              color: badgeColor ?? '#2F77B5',
              borderRadius: 12, padding: '1px 8px',
            }}>
              {badge}
            </span>
          )}
        </div>
        {subtitle && (
          <p style={{ fontSize: 12, color: '#9CA3AF', margin: '3px 0 0 22px' }}>{subtitle}</p>
        )}
      </div>
      {children}
    </div>
  );
}

function EmptyState({
  icon, message, iconColor,
}: {
  icon: string; message: string; iconColor?: string;
}) {
  return (
    <div style={{ textAlign: 'center', padding: '32px 0', color: '#9CA3AF' }}>
      <i className={`fas ${icon}`} style={{ fontSize: 26, display: 'block', marginBottom: 10, color: iconColor ?? '#D1D5DB' }} />
      <span style={{ fontSize: 13 }}>{message}</span>
    </div>
  );
}

function Th({
  label, sortKey, current, dir, onSort, align = 'left',
}: {
  label: string; sortKey: SortKey;
  current: SortKey; dir: SortDir;
  onSort: (k: SortKey) => void;
  align?: 'left' | 'center';
}) {
  const active = current === sortKey;
  return (
    <th
      onClick={() => onSort(sortKey)}
      style={{
        padding: '10px 14px', textAlign: align,
        fontSize: 11, fontWeight: 700,
        color: active ? '#18345B' : '#9CA3AF',
        textTransform: 'uppercase', letterSpacing: '0.05em',
        cursor: 'pointer', userSelect: 'none', whiteSpace: 'nowrap',
      }}
    >
      {label}
      {active && (
        <i className={`fas fa-chevron-${dir === 'asc' ? 'up' : 'down'}`}
           style={{ marginLeft: 4, fontSize: 9 }} />
      )}
    </th>
  );
}

function Legend({ color, label }: { color: string; label: string }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11, color: '#6B7280' }}>
      <div style={{ width: 10, height: 10, borderRadius: 2, background: color }} />
      {label}
    </div>
  );
}

const selectStyle: React.CSSProperties = {
  padding: '6px 10px', borderRadius: 6, border: '1px solid #D1D5DB',
  background: '#fff', fontSize: 12, color: '#374151',
  cursor: 'pointer', outline: 'none',
};
