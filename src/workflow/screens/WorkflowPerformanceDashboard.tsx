/**
 * WorkflowPerformanceDashboard
 *
 * HR / admin screen surfacing approver performance metrics:
 *   - Summary KPI cards (submitted, completed, in-progress, avg completion time)
 *   - Step bottleneck bars (avg hours per step vs SLA)
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

function fmtHours(h: number | null): string {
  if (h === null || h === undefined) return '—';
  if (h < 1)   return `${Math.round(h * 60)}m`;
  if (h < 24)  return `${h.toFixed(1)}h`;
  return `${(h / 24).toFixed(1)}d`;
}

function formatDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

// ─── Row colour by avg hours ───────────────────────────────────────────────────
// Green < 24h · Amber 24–72h · Red > 72h
function rowBg(avgHours: number | null): string {
  if (avgHours === null) return 'transparent';
  if (avgHours <= 24)   return '#F0FDF4';
  if (avgHours <= 72)   return '#FFFBEB';
  return '#FEF2F2';
}
function rowBorderLeft(avgHours: number | null): string {
  if (avgHours === null) return 'transparent';
  if (avgHours <= 24)   return '#16A34A';
  if (avgHours <= 72)   return '#D97706';
  return '#DC2626';
}

// ─── Bar colour vs SLA ────────────────────────────────────────────────────────
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

  const [summary,  setSummary]  = useState<WorkflowSummary | null>(null);
  const [approvers, setApprovers] = useState<ApproverRow[]>([]);
  const [steps,    setSteps]    = useState<StepRow[]>([]);
  const [overdue,  setOverdue]  = useState<OverdueTask[]>([]);

  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState<string | null>(null);

  // Approver table sort
  const [sortKey, setSortKey] = useState<SortKey>('avgHours');
  const [sortDir, setSortDir] = useState<SortDir>('desc');

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
        // Overdue tasks: pending tasks past due_at, with approver + submitter names
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
        avgCompletionHours: s.avg_completion_hours !== null ? Number(s.avg_completion_hours) : null,
        avgStepHours:       s.avg_step_hours       !== null ? Number(s.avg_step_hours)       : null,
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
          avgHours:        r.avg_hours    !== null ? Number(r.avg_hours)    : null,
          medianHours:     r.median_hours !== null ? Number(r.median_hours) : null,
          approvalRate:    r.approval_rate !== null ? Number(r.approval_rate) : null,
        }))
      );

      setSteps(
        (stepRes.data ?? []).map((r: any) => ({
          templateCode: r.template_code,
          templateName: r.template_name,
          stepOrder:    Number(r.step_order),
          stepName:     r.step_name,
          totalTasks:   Number(r.total_tasks   ?? 0),
          avgHours:     r.avg_hours    !== null ? Number(r.avg_hours)    : null,
          medianHours:  r.median_hours !== null ? Number(r.median_hours) : null,
          overdueCount: Number(r.overdue_count ?? 0),
          slaHours:     r.sla_hours !== null ? Number(r.sla_hours) : null,
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

  // ── Max avg hours across steps (for bar scaling) ────────────────────────────
  const maxStepHours = useMemo(
    () => Math.max(1, ...steps.map(s => s.avgHours ?? 0)),
    [steps]
  );

  // ─── Render ────────────────────────────────────────────────────────────────

  return (
    <div style={{ padding: '32px 40px', maxWidth: 1200, margin: '0 auto' }}>

      {/* ── Header ──────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 28 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: '#18345B', margin: 0 }}>
            Approver Performance
          </h1>
          <p style={{ fontSize: 13, color: '#6B7280', marginTop: 4 }}>
            Bottleneck analysis and approver response times
          </p>
        </div>

        {/* Filters */}
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          {/* Template filter */}
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

          {/* Date range chips */}
          <div style={{ display: 'flex', gap: 4 }}>
            {RANGES.map(r => (
              <button
                key={r.key}
                onClick={() => setRange(r.key)}
                style={{
                  padding: '6px 12px', borderRadius: 6, border: 'none',
                  background: range === r.key ? '#18345B' : '#F3F4F6',
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
        <div style={{ textAlign: 'center', padding: '64px 0', color: '#9CA3AF' }}>
          <i className="fas fa-spinner fa-spin" style={{ fontSize: 28, display: 'block', marginBottom: 12 }} />
          Loading performance data…
        </div>
      )}

      {!loading && (
        <>
          {/* ── KPI Cards ────────────────────────────────────────────────────── */}
          <div style={{ display: 'flex', gap: 12, marginBottom: 28, flexWrap: 'wrap' }}>
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
            />
            <KpiCard
              label="In Progress"
              value={summary?.inProgressCount ?? 0}
              icon="fa-hourglass-half"
              color="#D97706" bg="#FFFBEB" border="#FDE68A"
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
          </div>

          {/* ── Step Bottleneck Bars ──────────────────────────────────────────── */}
          {steps.length > 0 && (
            <Section title="Step Bottlenecks" icon="fa-chart-bar"
              subtitle="Average time spent at each approval step">
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                {steps.map(step => {
                  const pct = step.avgHours !== null
                    ? Math.min(100, (step.avgHours / maxStepHours) * 100)
                    : 0;
                  const color = barColor(step.avgHours, step.slaHours);

                  return (
                    <div key={`${step.templateCode}-${step.stepOrder}`}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 4 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                          <span style={{
                            fontSize: 11, background: '#EFF6FF', color: '#1D4ED8',
                            borderRadius: 4, padding: '1px 6px', fontWeight: 600,
                          }}>
                            {step.templateName} · Step {step.stepOrder}
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
                            {fmtHours(step.avgHours)} avg
                          </span>
                          <span style={{ fontSize: 11, color: '#9CA3AF' }}>
                            {step.totalTasks} tasks
                          </span>
                        </div>
                      </div>
                      {/* Bar */}
                      <div style={{
                        height: 8, background: '#F3F4F6', borderRadius: 4, overflow: 'hidden',
                      }}>
                        <div style={{
                          height: '100%',
                          width: `${pct}%`,
                          background: color,
                          borderRadius: 4,
                          transition: 'width 0.4s ease',
                        }} />
                      </div>
                      {/* SLA line marker */}
                      {step.slaHours && step.avgHours !== null && (
                        <div style={{
                          position: 'relative', height: 0,
                        }}>
                          <div style={{
                            position: 'absolute',
                            left: `${Math.min(100, (step.slaHours / maxStepHours) * 100)}%`,
                            top: -8,
                            width: 2,
                            height: 8,
                            background: '#9CA3AF',
                            borderRadius: 1,
                          }} />
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
              <div style={{ marginTop: 12, display: 'flex', gap: 16, flexWrap: 'wrap' }}>
                <Legend color="#16A34A" label="Within SLA" />
                <Legend color="#D97706" label="≤1.5× SLA" />
                <Legend color="#DC2626" label=">1.5× SLA" />
                <span style={{ fontSize: 11, color: '#9CA3AF' }}>
                  Grey tick = SLA boundary
                </span>
              </div>
            </Section>
          )}

          {/* ── Approver Table ────────────────────────────────────────────────── */}
          {approvers.length > 0 ? (
            <Section
              title="Approver Breakdown"
              icon="fa-users"
              subtitle="Colour: green < 24h avg · amber 24–72h · red > 72h"
            >
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                  <thead>
                    <tr style={{ background: '#F9FAFB', borderBottom: '1px solid #E5E7EB' }}>
                      <Th label="Approver"     sortKey="approverName"  current={sortKey} dir={sortDir} onSort={toggleSort} />
                      <Th label="Actioned"     sortKey="totalActioned" current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                      <Th label="Approval %"   sortKey="approvalRate"  current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                      <Th label="Avg Time"     sortKey="avgHours"      current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                      <Th label="Pending"      sortKey="pendingCount"  current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                      <Th label="Overdue Now"  sortKey="overdueCount"  current={sortKey} dir={sortDir} onSort={toggleSort} align="center" />
                    </tr>
                  </thead>
                  <tbody>
                    {sortedApprovers.map(a => (
                      <tr
                        key={a.approverId}
                        style={{
                          background:      rowBg(a.avgHours),
                          borderBottom:    '1px solid #F3F4F6',
                          borderLeft:      `3px solid ${rowBorderLeft(a.avgHours)}`,
                        }}
                      >
                        <td style={{ padding: '10px 14px' }}>
                          <div style={{ fontWeight: 600, color: '#111827' }}>{a.approverName}</div>
                          <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 1 }}>
                            {[a.jobTitle, a.departmentName].filter(Boolean).join(' · ')}
                          </div>
                        </td>
                        <td style={{ padding: '10px 14px', textAlign: 'center', color: '#374151' }}>
                          {a.totalActioned}
                          {a.totalActioned > 0 && (
                            <div style={{ fontSize: 10, color: '#9CA3AF', marginTop: 1 }}>
                              {a.approvedCount}✓ {a.rejectedCount}✗ {a.returnedCount > 0 ? `${a.returnedCount}↩` : ''}
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
                          ) : '—'}
                        </td>
                        <td style={{ padding: '10px 14px', textAlign: 'center' }}>
                          <span style={{ fontWeight: 700, color: rowBorderLeft(a.avgHours) }}>
                            {fmtHours(a.avgHours)}
                          </span>
                          {a.medianHours !== null && (
                            <div style={{ fontSize: 10, color: '#9CA3AF', marginTop: 1 }}>
                              med {fmtHours(a.medianHours)}
                            </div>
                          )}
                        </td>
                        <td style={{ padding: '10px 14px', textAlign: 'center' }}>
                          <span style={{
                            fontWeight: 600,
                            color: a.pendingCount > 5 ? '#D97706' : '#374151',
                          }}>
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
                            <span style={{ color: '#9CA3AF' }}>—</span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </Section>
          ) : !loading && (
            <Section title="Approver Breakdown" icon="fa-users" subtitle="">
              <div style={{ textAlign: 'center', padding: '32px 0', color: '#9CA3AF' }}>
                <i className="fas fa-users" style={{ fontSize: 28, display: 'block', marginBottom: 10 }} />
                No approver activity in this period.
              </div>
            </Section>
          )}

          {/* ── Overdue Tasks ─────────────────────────────────────────────────── */}
          {overdue.length > 0 && (
            <Section
              title={`Overdue Right Now (${overdue.length})`}
              icon="fa-circle-exclamation"
              titleColor="#DC2626"
              subtitle="Pending tasks that have already breached their SLA deadline"
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
                      </div>
                    </div>
                    <div style={{ textAlign: 'right', flexShrink: 0 }}>
                      <div style={{ fontWeight: 700, fontSize: 13, color: '#DC2626' }}>
                        {t.hoursOverdue}h overdue
                      </div>
                      <div style={{ fontSize: 11, color: '#9CA3AF' }}>
                        Due {formatDate(t.dueAt)}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </Section>
          )}
        </>
      )}
    </div>
  );
}

// ── Small helpers ──────────────────────────────────────────────────────────────

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
      boxShadow: '0 1px 3px rgba(0,0,0,0.06)',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8 }}>
        <span style={{
          fontSize: 11, fontWeight: 700, color,
          textTransform: 'uppercase', letterSpacing: '0.06em',
        }}>
          {label}
        </span>
        <i className={`fas ${icon}`} style={{ fontSize: 14, color }} />
      </div>
      <div style={{ fontSize: 26, fontWeight: 800, color, lineHeight: 1 }}>{value}</div>
      {subtitle && (
        <div style={{ fontSize: 11, color, opacity: 0.7, marginTop: 3 }}>{subtitle}</div>
      )}
    </div>
  );
}

function Section({
  title, icon, subtitle, children, titleColor,
}: {
  title: string; icon: string; subtitle?: string;
  children: React.ReactNode; titleColor?: string;
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
        </div>
        {subtitle && (
          <p style={{ fontSize: 12, color: '#9CA3AF', margin: '3px 0 0 22px' }}>{subtitle}</p>
        )}
      </div>
      {children}
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
        fontSize: 11, fontWeight: 700, color: active ? '#18345B' : '#9CA3AF',
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
