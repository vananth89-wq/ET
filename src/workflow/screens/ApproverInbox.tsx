/**
 * ApproverInbox
 *
 * The central approval action screen for users with workflow.approve permission.
 * Shows all pending tasks assigned to the current user with:
 *   - KPI summary bar (Total · Overdue · Due Soon · On Track)
 *   - SLA-based filter chips
 *   - Inline Approve / Reject actions
 *   - Task detail panel
 *
 * Route: /workflow/inbox
 */

import { useState, useMemo } from 'react';
import { useWorkflowTasks }      from '../hooks/useWorkflowTasks';
import { WorkflowActions }       from '../components/WorkflowActions';
import { WorkflowStatusBadge }   from '../components/WorkflowStatusBadge';
import type { SlaStatus }        from '../hooks/useWorkflowTasks';

// ── Helpers ───────────────────────────────────────────────────────────────────

function formatDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

function relativeTime(iso: string) {
  const diffMs  = Date.now() - new Date(iso).getTime();
  const diffMin = Math.floor(diffMs / 60_000);
  if (diffMin < 60)  return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr  < 24)  return `${diffHr}h ago`;
  return `${Math.floor(diffHr / 24)}d ago`;
}

const SLA_CONFIG: Record<SlaStatus, { color: string; bg: string; border: string; label: string }> = {
  on_track: { color: '#16A34A', bg: '#F0FDF4', border: '#BBF7D0', label: 'On Track'  },
  due_soon: { color: '#D97706', bg: '#FFFBEB', border: '#FDE68A', label: 'Due Soon'  },
  overdue:  { color: '#DC2626', bg: '#FEF2F2', border: '#FECACA', label: 'Overdue'   },
};

// ── KPI Card ──────────────────────────────────────────────────────────────────

interface KpiProps {
  label:    string;
  value:    number;
  color:    string;
  bg:       string;
  border:   string;
  icon:     string;
  onClick?: () => void;
  active?:  boolean;
}

function KpiCard({ label, value, color, bg, border, icon, onClick, active }: KpiProps) {
  return (
    <div
      onClick={onClick}
      style={{
        flex:         '1 1 0',
        minWidth:     120,
        background:   active ? bg : '#fff',
        border:       `1.5px solid ${active ? color : '#E5E7EB'}`,
        borderRadius: 10,
        padding:      '16px 20px',
        cursor:       onClick ? 'pointer' : 'default',
        transition:   'all 0.15s',
        boxShadow:    active ? `0 0 0 3px ${border}` : '0 1px 3px rgba(0,0,0,0.06)',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
        <span style={{
          fontSize: 11, fontWeight: 700, color: active ? color : '#9CA3AF',
          textTransform: 'uppercase', letterSpacing: '0.06em',
        }}>
          {label}
        </span>
        <i className={`fas ${icon}`} style={{ fontSize: 14, color: active ? color : '#D1D5DB' }} />
      </div>
      <div style={{ fontSize: 28, fontWeight: 800, color: active ? color : '#111827', lineHeight: 1 }}>
        {value}
      </div>
    </div>
  );
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function ApproverInbox() {
  const {
    tasks, loading, error, pendingCount, refresh,
    approve, reject, reassign, returnToInitiator, returnToPreviousStep,
  } = useWorkflowTasks();

  const [selectedId,  setSelectedId]  = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [filter,      setFilter]      = useState<'all' | SlaStatus>('all');

  const selected = tasks.find(t => t.taskId === selectedId) ?? null;

  // ── Derived KPI counts (zero extra queries — all from tasks array) ──────────
  const kpi = useMemo(() => ({
    total:    tasks.length,
    overdue:  tasks.filter(t => t.slaStatus === 'overdue').length,
    dueSoon:  tasks.filter(t => t.slaStatus === 'due_soon').length,
    onTrack:  tasks.filter(t => t.slaStatus === 'on_track').length,
  }), [tasks]);

  const filtered = useMemo(() =>
    filter === 'all' ? tasks : tasks.filter(t => t.slaStatus === filter),
    [tasks, filter]
  );

  // ── Actions ──────────────────────────────────────────────────────────────────

  async function handleApprove(taskId: string, notes?: string) {
    setActionError(null);
    try {
      await approve(taskId, notes);
      setSelectedId(null);
    } catch (e) {
      setActionError((e as Error).message);
      throw e;
    }
  }

  async function handleReject(taskId: string, reason: string) {
    setActionError(null);
    try {
      await reject(taskId, reason);
      setSelectedId(null);
    } catch (e) {
      setActionError((e as Error).message);
      throw e;
    }
  }

  async function handleReassign(taskId: string, profileId: string, reason?: string) {
    setActionError(null);
    try {
      await reassign(taskId, profileId, reason);
      setSelectedId(null);
    } catch (e) {
      setActionError((e as Error).message);
      throw e;
    }
  }

  async function handleReturnToInitiator(taskId: string, message: string) {
    setActionError(null);
    try {
      await returnToInitiator(taskId, message);
      setSelectedId(null);
    } catch (e) {
      setActionError((e as Error).message);
      throw e;
    }
  }

  async function handleReturnToPreviousStep(taskId: string, reason?: string) {
    setActionError(null);
    try {
      await returnToPreviousStep(taskId, reason);
      setSelectedId(null);
    } catch (e) {
      setActionError((e as Error).message);
      throw e;
    }
  }

  // ── Render ────────────────────────────────────────────────────────────────────

  return (
    <div style={{ padding: '32px 40px', maxWidth: 1100, margin: '0 auto' }}>

      {/* ── Header ─────────────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, color: '#18345B', margin: 0 }}>
            Workflow Inbox
          </h1>
          <p style={{ fontSize: 13, color: '#6B7280', marginTop: 4 }}>
            {loading
              ? 'Loading tasks…'
              : pendingCount === 0
              ? 'All caught up — no pending tasks.'
              : `${pendingCount} task${pendingCount === 1 ? '' : 's'} waiting for your action`}
          </p>
        </div>

        <button
          onClick={refresh}
          style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '7px 14px', borderRadius: 7,
            border: '1px solid #D1D5DB', background: '#fff',
            fontSize: 13, fontWeight: 500, color: '#374151', cursor: 'pointer',
          }}
        >
          <i className="fas fa-arrows-rotate" style={{ fontSize: 12 }} />
          Refresh
        </button>
      </div>

      {/* ── KPI Cards ──────────────────────────────────────────────────────── */}
      {!loading && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 24, flexWrap: 'wrap' }}>
          <KpiCard
            label="Total Pending"
            value={kpi.total}
            icon="fa-inbox"
            color="#2F77B5"
            bg="#EFF6FF"
            border="#BFDBFE"
            active={filter === 'all'}
            onClick={() => setFilter('all')}
          />
          <KpiCard
            label="Overdue"
            value={kpi.overdue}
            icon="fa-circle-exclamation"
            color={SLA_CONFIG.overdue.color}
            bg={SLA_CONFIG.overdue.bg}
            border={SLA_CONFIG.overdue.border}
            active={filter === 'overdue'}
            onClick={() => setFilter('overdue')}
          />
          <KpiCard
            label="Due Soon"
            value={kpi.dueSoon}
            icon="fa-hourglass-half"
            color={SLA_CONFIG.due_soon.color}
            bg={SLA_CONFIG.due_soon.bg}
            border={SLA_CONFIG.due_soon.border}
            active={filter === 'due_soon'}
            onClick={() => setFilter('due_soon')}
          />
          <KpiCard
            label="On Track"
            value={kpi.onTrack}
            icon="fa-circle-check"
            color={SLA_CONFIG.on_track.color}
            bg={SLA_CONFIG.on_track.bg}
            border={SLA_CONFIG.on_track.border}
            active={filter === 'on_track'}
            onClick={() => setFilter('on_track')}
          />
        </div>
      )}

      {/* ── Loading ─────────────────────────────────────────────────────────── */}
      {loading && (
        <div style={{ textAlign: 'center', padding: '64px 0', color: '#9CA3AF' }}>
          <i className="fas fa-spinner fa-spin" style={{ fontSize: 28, marginBottom: 14, display: 'block' }} />
          Loading tasks…
        </div>
      )}

      {/* ── Error ───────────────────────────────────────────────────────────── */}
      {error && !loading && (
        <div style={{
          padding: '12px 16px', borderRadius: 8,
          background: '#FEF2F2', border: '1px solid #FECACA',
          color: '#DC2626', fontSize: 13, marginBottom: 16,
        }}>
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 8 }} />
          {error}
        </div>
      )}

      {/* ── Task list ───────────────────────────────────────────────────────── */}
      {!loading && !error && (
        <div style={{ display: 'flex', gap: 20, alignItems: 'flex-start' }}>

          {/* Left: task list */}
          <div style={{ flex: 1, minWidth: 0 }}>
            {filtered.length === 0 ? (
              /* ── Empty state ─────────────────────────────────────────────── */
              <div style={{
                textAlign: 'center', padding: '56px 24px',
                background: '#fff', borderRadius: 12,
                border: '1px solid #E5E7EB',
              }}>
                <div style={{
                  width: 64, height: 64, borderRadius: '50%',
                  background: '#F0FDF4', border: '2px solid #BBF7D0',
                  display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                  marginBottom: 16,
                }}>
                  <i className="fas fa-check" style={{ fontSize: 24, color: '#16A34A' }} />
                </div>
                <div style={{ fontSize: 16, fontWeight: 700, color: '#111827', marginBottom: 6 }}>
                  {filter === 'all' ? "You're all caught up" : `No ${SLA_CONFIG[filter as SlaStatus]?.label ?? filter} tasks`}
                </div>
                <div style={{ fontSize: 13, color: '#6B7280', maxWidth: 320, margin: '0 auto' }}>
                  {filter === 'all'
                    ? 'No approval tasks are pending at the moment. New requests will appear here automatically.'
                    : `There are no tasks in this category right now.`}
                </div>
                {filter !== 'all' && (
                  <button
                    onClick={() => setFilter('all')}
                    style={{
                      marginTop: 16, padding: '7px 18px', borderRadius: 7,
                      border: '1px solid #D1D5DB', background: '#F9FAFB',
                      fontSize: 13, fontWeight: 500, color: '#374151', cursor: 'pointer',
                    }}
                  >
                    View all tasks
                  </button>
                )}
              </div>
            ) : (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                {filtered.map(task => {
                  const sla        = SLA_CONFIG[task.slaStatus];
                  const isSelected = task.taskId === selectedId;

                  return (
                    <div
                      key={task.taskId}
                      onClick={() => setSelectedId(isSelected ? null : task.taskId)}
                      style={{
                        background:  '#fff',
                        border:      `1px solid ${isSelected ? '#2F77B5' : '#E5E7EB'}`,
                        borderRadius: 10,
                        padding:     '14px 18px',
                        cursor:      'pointer',
                        transition:  'border-color 0.15s',
                        boxShadow:   isSelected ? '0 0 0 2px rgba(47,119,181,0.15)' : 'none',
                      }}
                    >
                      {/* Task header */}
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                            <span style={{ fontWeight: 700, fontSize: 14, color: '#18345B' }}>
                              {task.templateName}
                            </span>
                            <span style={{
                              fontSize: 11, background: '#EFF6FF', color: '#1D4ED8',
                              borderRadius: 4, padding: '1px 7px', fontWeight: 600,
                            }}>
                              Step {task.stepOrder}: {task.stepName}
                            </span>
                          </div>
                          <div style={{ fontSize: 12, color: '#6B7280', marginTop: 4 }}>
                            Submitted by{' '}
                            <strong style={{ color: '#374151' }}>
                              {task.submittedByName ?? task.submittedByEmail ?? 'Unknown'}
                            </strong>
                            {' · '}{relativeTime(task.taskCreatedAt)}
                          </div>
                        </div>

                        {/* SLA indicator */}
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0, marginLeft: 12 }}>
                          <span style={{
                            width: 8, height: 8, borderRadius: '50%',
                            background: sla.color, display: 'inline-block',
                          }} />
                          <span style={{ fontSize: 11, color: sla.color, fontWeight: 600 }}>
                            {sla.label}
                          </span>
                          {task.dueAt && (
                            <span style={{ fontSize: 11, color: '#9CA3AF' }}>
                              · Due {formatDate(task.dueAt)}
                            </span>
                          )}
                        </div>
                      </div>

                      {/* Metadata preview */}
                      {task.metadata && Object.keys(task.metadata).length > 0 && (
                        <div style={{ marginTop: 10, display: 'flex', gap: 16, flexWrap: 'wrap' }}>
                          {task.moduleCode === 'expense_reports' && (
                            <>
                              {task.metadata.name && (
                                <MetaChip icon="fa-file-invoice" label={task.metadata.name as string} />
                              )}
                              {task.metadata.total_amount !== undefined && (
                                <MetaChip
                                  icon="fa-coins"
                                  label={`${task.metadata.currency_code ?? ''} ${
                                    Number(task.metadata.total_amount).toLocaleString('en-US', { minimumFractionDigits: 2 })
                                  }`}
                                />
                              )}
                            </>
                          )}
                        </div>
                      )}

                      {/* Expanded: action panel */}
                      {isSelected && (
                        <div
                          style={{ marginTop: 14, paddingTop: 14, borderTop: '1px solid #E5E7EB' }}
                          onClick={e => e.stopPropagation()}
                        >
                          <WorkflowActions
                            taskId={task.taskId}
                            stepOrder={task.stepOrder}
                            onApprove={handleApprove}
                            onReject={handleReject}
                            onReassign={handleReassign}
                            onReturnToInitiator={handleReturnToInitiator}
                            onReturnToPreviousStep={handleReturnToPreviousStep}
                          />
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          {/* Right: detail panel when a task is selected */}
          {selected && (
            <div style={{
              width: 280, flexShrink: 0,
              background: '#fff', borderRadius: 10,
              border: '1px solid #E5E7EB', padding: '18px 20px',
              position: 'sticky', top: 24,
            }}>
              <h3 style={{ fontSize: 13, fontWeight: 700, color: '#18345B', marginBottom: 12 }}>
                Task Detail
              </h3>
              <InfoRow label="Template" value={selected.templateName} />
              <InfoRow label="Module"   value={selected.moduleCode.replace(/_/g, ' ')} />
              <InfoRow label="Step"     value={`${selected.stepOrder} — ${selected.stepName}`} />
              <InfoRow label="Status">
                <WorkflowStatusBadge status="pending" size="sm" />
              </InfoRow>
              <InfoRow label="Submitted by" value={selected.submittedByName ?? selected.submittedByEmail ?? '—'} />
              <InfoRow label="Submitted"    value={formatDate(selected.taskCreatedAt)} />
              {selected.dueAt && (
                <InfoRow label="Due by" value={formatDate(selected.dueAt)} />
              )}
              <InfoRow label="SLA">
                <span style={{
                  display: 'inline-flex', alignItems: 'center', gap: 5,
                  fontSize: 12, fontWeight: 600,
                  color: SLA_CONFIG[selected.slaStatus].color,
                }}>
                  <span style={{
                    width: 7, height: 7, borderRadius: '50%',
                    background: SLA_CONFIG[selected.slaStatus].color,
                    display: 'inline-block',
                  }} />
                  {SLA_CONFIG[selected.slaStatus].label}
                </span>
              </InfoRow>
            </div>
          )}
        </div>
      )}

      {/* Global action error toast */}
      {actionError && (
        <div style={{
          position: 'fixed', bottom: 24, right: 24,
          background: '#FEF2F2', border: '1px solid #FECACA',
          color: '#DC2626', borderRadius: 8, padding: '12px 18px',
          fontSize: 13, boxShadow: '0 4px 12px rgba(0,0,0,0.12)',
          zIndex: 9999, display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <i className="fas fa-triangle-exclamation" />
          {actionError}
          <button
            onClick={() => setActionError(null)}
            style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#DC2626', fontSize: 16 }}
          >×</button>
        </div>
      )}
    </div>
  );
}

// ── Small helpers ─────────────────────────────────────────────────────────────

function MetaChip({ icon, label }: { icon: string; label: string }) {
  return (
    <span style={{
      display: 'flex', alignItems: 'center', gap: 5,
      fontSize: 12, color: '#374151',
      background: '#F9FAFB', borderRadius: 5, padding: '3px 8px',
      border: '1px solid #E5E7EB',
    }}>
      <i className={`fas ${icon}`} style={{ fontSize: 10, color: '#6B7280' }} />
      {label}
    </span>
  );
}

function InfoRow({
  label, value, children,
}: {
  label: string; value?: string; children?: React.ReactNode;
}) {
  return (
    <div style={{ marginBottom: 10 }}>
      <div style={{ fontSize: 11, color: '#9CA3AF', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
        {label}
      </div>
      <div style={{ fontSize: 13, color: '#111827', marginTop: 2 }}>
        {children ?? value ?? '—'}
      </div>
    </div>
  );
}
