/**
 * NotificationMonitor — Admin Notification Delivery Monitor
 *
 * Route: /admin/workflow/notifications  (requires workflow.admin)
 *
 * Surfaces every workflow notification with its in-app and email delivery
 * status. Admins can diagnose failures, retry individual notifications, and
 * view full payload + attempt history in the side panel.
 *
 * Layout:
 *   ┌──────────────────────────────────────────────────────────┐
 *   │  Header + KPI bar (4 cards)                              │
 *   │  Filter bar                                              │
 *   │  Paginated table  │  Details side panel (when selected)  │
 *   └──────────────────────────────────────────────────────────┘
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate }                               from 'react-router-dom';
import { supabase }                                  from '../../lib/supabase';

// ─── Types ────────────────────────────────────────────────────────────────────

type OverallStatus = 'delivered' | 'inapp_only' | 'partial' | 'failed' | 'pending';
type InAppStatus   = 'pending' | 'sent' | 'failed';
type EmailStatus   = 'pending' | 'sent' | 'failed' | 'skipped';

interface MonitorRow {
  queue_id:        string;
  notification_id: string | null;
  instance_id:     string | null;
  display_id:      string;
  template_code:   string;
  template_name:   string;
  recipient_id:    string;
  recipient_name:  string;
  recipient_email: string | null;
  recipient_dept:  string | null;
  module_code:     string | null;
  record_id:       string | null;
  inapp_status:    InAppStatus;
  inapp_error:     string | null;
  email_status:    EmailStatus | null;
  email_sent_at:   string | null;
  email_error:     string | null;
  retry_count:     number;
  max_retries:     number;
  payload:         Record<string, unknown>;
  created_at:      string;
  processed_at:    string | null;
  overall_status:  OverallStatus;
  can_retry:       boolean;
}

interface NotifAttempt {
  id:             string;
  queue_id:       string;
  attempt_number: number;
  channel:        'in_app' | 'email';
  status:         'sent' | 'failed';
  error_message:  string | null;
  attempted_at:   string;
  actor_name:     string | null;
}

type SortKey = 'created_at' | 'overall_status' | 'recipient_name' | 'template_name';
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
  gray:    '#6B7280',
  grayL:   '#F3F4F6',
};

// ─── Status config ────────────────────────────────────────────────────────────

const OVERALL_CFG: Record<OverallStatus, { label: string; color: string; bg: string; icon: string }> = {
  delivered:  { label: 'Delivered',    color: C.green,  bg: C.greenL,  icon: 'fa-circle-check'         },
  inapp_only: { label: 'In-App Only',  color: C.blue,   bg: C.blueL,   icon: 'fa-bell'                 },
  partial:    { label: 'Email Failed', color: C.amber,  bg: C.amberL,  icon: 'fa-triangle-exclamation' },
  failed:     { label: 'Failed',       color: C.red,    bg: C.redL,    icon: 'fa-circle-xmark'         },
  pending:    { label: 'Pending',      color: C.gray,   bg: C.grayL,   icon: 'fa-clock'                },
};

const INAPP_CFG: Record<InAppStatus, { label: string; color: string; bg: string }> = {
  sent:    { label: 'Delivered', color: C.green, bg: C.greenL },
  failed:  { label: 'Failed',    color: C.red,   bg: C.redL   },
  pending: { label: 'Pending',   color: C.gray,  bg: C.grayL  },
};

const EMAIL_CFG: Record<EmailStatus, { label: string; color: string; bg: string }> = {
  sent:    { label: 'Sent',    color: C.green,  bg: C.greenL  },
  failed:  { label: 'Failed',  color: C.red,    bg: C.redL    },
  pending: { label: 'Sending', color: C.amber,  bg: C.amberL  },
  skipped: { label: 'Skipped', color: C.gray,   bg: C.grayL   },
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

function recordLink(moduleCode: string | null, recordId: string | null): string | null {
  if (!moduleCode || !recordId) return null;
  switch (moduleCode) {
    case 'expense_reports': return `/expense/report/${recordId}`;
    default:                return null;
  }
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function KpiCard({ label, value, icon, color, bg }: {
  label: string; value: number; icon: string; color: string; bg: string;
}) {
  return (
    <div style={{
      flex: 1, minWidth: 130, background: '#fff',
      borderRadius: 8, border: `1px solid ${C.border}`,
      padding: '14px 18px', display: 'flex', alignItems: 'center', gap: 12,
    }}>
      <div style={{
        width: 36, height: 36, borderRadius: 8, background: bg,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <i className={`fas ${icon}`} style={{ fontSize: 15, color }} />
      </div>
      <div>
        <div style={{ fontSize: 22, fontWeight: 800, color: C.navy, lineHeight: 1 }}>{value}</div>
        <div style={{ fontSize: 11, color: C.muted, marginTop: 2, fontWeight: 500 }}>{label}</div>
      </div>
    </div>
  );
}

function OverallBadge({ status }: { status: OverallStatus }) {
  const cfg = OVERALL_CFG[status];
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 10,
      fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.04em',
      borderRadius: 4, padding: '2px 7px', background: cfg.bg, color: cfg.color,
    }}>
      <i className={`fas ${cfg.icon}`} style={{ fontSize: 8 }} />
      {cfg.label}
    </span>
  );
}

function ChannelPill({ label, cfg }: { label: string; cfg: { label: string; color: string; bg: string } }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 4,
      fontSize: 10, fontWeight: 600, borderRadius: 4, padding: '2px 7px',
      background: cfg.bg, color: cfg.color,
    }}>
      {label}: {cfg.label}
    </span>
  );
}

function Th({ label, sortKey, currentKey, dir, onSort }: {
  label: string; sortKey?: SortKey;
  currentKey: SortKey; dir: SortDir; onSort: (k: SortKey) => void;
}) {
  const active = sortKey && currentKey === sortKey;
  return (
    <th onClick={() => sortKey && onSort(sortKey)} style={{
      padding: '10px 12px', textAlign: 'left', fontSize: 11, fontWeight: 700,
      color: active ? C.blue : C.muted, background: C.bg,
      textTransform: 'uppercase', letterSpacing: '0.05em',
      borderBottom: `1px solid ${C.border}`,
      cursor: sortKey ? 'pointer' : 'default',
      whiteSpace: 'nowrap', userSelect: 'none',
    }}>
      {label}
      {active && <i className={`fas fa-arrow-${dir === 'asc' ? 'up' : 'down'}`} style={{ marginLeft: 5, fontSize: 9 }} />}
    </th>
  );
}

function PageBtn({ label, onClick, disabled }: { label: string; onClick: () => void; disabled: boolean }) {
  return (
    <button onClick={onClick} disabled={disabled} style={{
      padding: '5px 12px', borderRadius: 5, fontSize: 12, fontWeight: 600,
      background: '#fff', color: disabled ? '#D1D5DB' : C.text,
      border: `1px solid ${C.border}`, cursor: disabled ? 'not-allowed' : 'pointer',
    }}>
      {label}
    </button>
  );
}

// ─── Main Component ───────────────────────────────────────────────────────────

export default function NotificationMonitor() {
  const navigate = useNavigate();

  const [rows,    setRows]    = useState<MonitorRow[]>([]);
  const [total,   setTotal]   = useState(0);
  const [page,    setPage]    = useState(0);
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState<string | null>(null);

  // Filters
  const [fStatus,    setFStatus]    = useState('');
  const [fTemplate,  setFTemplate]  = useState('');
  const [fDateFrom,  setFDateFrom]  = useState('');
  const [fDateTo,    setFDateTo]    = useState('');
  const [fRecipient, setFRecipient] = useState('');

  // Sort
  const [sortKey, setSortKey] = useState<SortKey>('created_at');
  const [sortDir, setSortDir] = useState<SortDir>('desc');

  // Filter option lists
  const [templates, setTemplates] = useState<{ code: string; name: string }[]>([]);

  // Selected row + side panel
  const [selected, setSelected]   = useState<MonitorRow | null>(null);
  const [attempts, setAttempts]   = useState<NotifAttempt[]>([]);
  const [showPayload, setShowPayload] = useState(false);

  // Retry
  const [retrying, setRetrying] = useState(false);

  // KPIs
  const [kpis, setKpis] = useState({ total: 0, delivered: 0, issues: 0, pending: 0 });

  // Toast
  const [toast,     setToast]     = useState<{ type: 'ok' | 'err'; msg: string } | null>(null);
  const toastTimer                = useRef<number | null>(null);

  function showToast(type: 'ok' | 'err', msg: string) {
    setToast({ type, msg });
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 4500);
  }

  // ── Filter options ──────────────────────────────────────────────────────────

  useEffect(() => {
    supabase
      .from('workflow_notification_templates')
      .select('code, name')
      .order('name')
      .then(({ data }) =>
        setTemplates((data ?? []).map(t => ({ code: t.code, name: t.name }))),
      );
  }, []);

  // ── KPIs — 4 parallel COUNT queries ────────────────────────────────────────

  const fetchKpis = useCallback(async () => {
    const [totalRes, deliveredRes, issuesRes, pendingRes] = await Promise.all([
      supabase.from('vw_notification_monitor').select('*', { count: 'exact', head: true }),
      supabase.from('vw_notification_monitor').select('*', { count: 'exact', head: true })
        .in('overall_status', ['delivered', 'inapp_only']),
      supabase.from('vw_notification_monitor').select('*', { count: 'exact', head: true })
        .in('overall_status', ['failed', 'partial']),
      supabase.from('vw_notification_monitor').select('*', { count: 'exact', head: true })
        .eq('overall_status', 'pending'),
    ]);
    setKpis({
      total:     totalRes.count     ?? 0,
      delivered: deliveredRes.count ?? 0,
      issues:    issuesRes.count    ?? 0,
      pending:   pendingRes.count   ?? 0,
    });
  }, []);

  // ── Data load ───────────────────────────────────────────────────────────────

  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);
    const from = page * PAGE_SIZE;
    const to   = from + PAGE_SIZE - 1;

    let q = supabase
      .from('vw_notification_monitor')
      .select('*', { count: 'exact' })
      .range(from, to);

    if (fStatus)    q = q.eq('overall_status', fStatus);
    if (fTemplate)  q = q.eq('template_code', fTemplate);
    if (fDateFrom)  q = q.gte('created_at', fDateFrom + 'T00:00:00');
    if (fDateTo)    q = q.lte('created_at', fDateTo + 'T23:59:59');
    if (fRecipient) q = q.ilike('recipient_name', `%${fRecipient}%`);

    q = q.order(sortKey, { ascending: sortDir === 'asc' });

    const { data, error: err, count } = await q;
    setLoading(false);
    if (err) { setError(err.message); return; }
    setRows((data ?? []) as MonitorRow[]);
    setTotal(count ?? 0);
  }, [page, fStatus, fTemplate, fDateFrom, fDateTo, fRecipient, sortKey, sortDir]);

  useEffect(() => { setPage(0); }, [fStatus, fTemplate, fDateFrom, fDateTo, fRecipient, sortKey, sortDir]);
  useEffect(() => { loadData(); fetchKpis(); }, [loadData, fetchKpis]);

  // ── Sort toggle ─────────────────────────────────────────────────────────────

  function toggleSort(key: SortKey) {
    if (key === sortKey) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortKey(key); setSortDir('desc'); }
  }

  // ── Row selection ───────────────────────────────────────────────────────────

  async function selectRow(row: MonitorRow) {
    setSelected(row);
    setShowPayload(false);

    const { data } = await supabase
      .from('notification_attempts')
      .select(`
        id, queue_id, attempt_number, channel, status, error_message, attempted_at,
        actor:profiles!notification_attempts_actor_id_fkey(
          employees(name)
        )
      `)
      .eq('queue_id', row.queue_id)
      .order('attempted_at', { ascending: true });

    setAttempts(
      (data ?? []).map((a: any) => ({
        id:             a.id,
        queue_id:       a.queue_id,
        attempt_number: a.attempt_number,
        channel:        a.channel,
        status:         a.status,
        error_message:  a.error_message,
        attempted_at:   a.attempted_at,
        actor_name:     a.actor?.employees?.name ?? 'System (auto)',
      })),
    );
  }

  // ── Retry ───────────────────────────────────────────────────────────────────

  async function doRetry(row: MonitorRow, force = false) {
    setRetrying(true);
    try {
      const { error: err } = await supabase.rpc('wf_retry_notification', {
        p_queue_id: row.queue_id,
        p_force:    force,
      });
      if (err) throw new Error(err.message);
      showToast('ok', 'Notification queued for re-delivery');
      await loadData();
      await fetchKpis();
      // Refresh side panel
      const updated = rows.find(r => r.queue_id === row.queue_id);
      if (updated) await selectRow(updated);
      else setSelected(null);
    } catch (e) {
      showToast('err', (e as Error).message);
    } finally {
      setRetrying(false);
    }
  }

  // ── Pagination ──────────────────────────────────────────────────────────────

  const totalPages = Math.ceil(total / PAGE_SIZE);
  const hasFilters = !!(fStatus || fTemplate || fDateFrom || fDateTo || fRecipient);

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
              Notification Monitor
            </h1>
            <p style={{ fontSize: 13, color: C.muted, margin: '4px 0 0' }}>
              Track and manage workflow notification delivery across the system.
            </p>
          </div>
          <button
            onClick={() => { loadData(); fetchKpis(); }}
            style={{
              display: 'inline-flex', alignItems: 'center', gap: 6,
              padding: '7px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600,
              background: '#fff', color: C.text, border: `1px solid ${C.border}`, cursor: 'pointer',
            }}
          >
            <i className="fas fa-rotate-right" style={{ fontSize: 11 }} /> Refresh
          </button>
        </div>

        {/* KPI bar */}
        <div style={{ display: 'flex', gap: 12, paddingBottom: 16, flexWrap: 'wrap' }}>
          <KpiCard label="Total Sent"       value={kpis.total}     icon="fa-paper-plane"          color={C.blue}   bg={C.blueL}   />
          <KpiCard label="Delivered"        value={kpis.delivered} icon="fa-circle-check"          color={C.green}  bg={C.greenL}  />
          <KpiCard label="Failed / Partial" value={kpis.issues}    icon="fa-triangle-exclamation"  color={C.red}    bg={C.redL}    />
          <KpiCard label="Pending"          value={kpis.pending}   icon="fa-clock"                 color={C.amber}  bg={C.amberL}  />
        </div>
      </div>

      {/* ── Body ───────────────────────────────────────────────────────────── */}
      <div style={{ flex: 1, display: 'flex', minHeight: 0, overflow: 'hidden' }}>

        {/* Left: filters + table */}
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>

          {/* Filter bar */}
          <div style={{
            display: 'flex', gap: 8, padding: '12px 16px', flexWrap: 'wrap',
            background: '#fff', borderBottom: `1px solid ${C.border}`,
          }}>
            {/* Overall status */}
            <select value={fStatus} onChange={e => setFStatus(e.target.value)} style={selStyle}>
              <option value="">All Statuses</option>
              <option value="delivered">Delivered</option>
              <option value="inapp_only">In-App Only</option>
              <option value="partial">Email Failed</option>
              <option value="failed">Failed</option>
              <option value="pending">Pending</option>
            </select>

            {/* Template */}
            <select value={fTemplate} onChange={e => setFTemplate(e.target.value)} style={selStyle}>
              <option value="">All Templates</option>
              {templates.map(t => (
                <option key={t.code} value={t.code}>{t.name || t.code}</option>
              ))}
            </select>

            {/* Date from */}
            <input
              type="date"
              value={fDateFrom}
              onChange={e => setFDateFrom(e.target.value)}
              style={{ ...selStyle, colorScheme: 'light' }}
              title="From date"
            />

            {/* Date to */}
            <input
              type="date"
              value={fDateTo}
              onChange={e => setFDateTo(e.target.value)}
              style={{ ...selStyle, colorScheme: 'light' }}
              title="To date"
            />

            {/* Recipient search */}
            <div style={{ position: 'relative' }}>
              <i className="fas fa-magnifying-glass" style={{
                position: 'absolute', left: 9, top: '50%', transform: 'translateY(-50%)',
                color: C.faint, fontSize: 11, pointerEvents: 'none',
              }} />
              <input
                value={fRecipient}
                onChange={e => setFRecipient(e.target.value)}
                placeholder="Recipient name…"
                style={{ ...selStyle, paddingLeft: 28 }}
              />
            </div>

            {hasFilters && (
              <button
                onClick={() => { setFStatus(''); setFTemplate(''); setFDateFrom(''); setFDateTo(''); setFRecipient(''); }}
                style={{
                  padding: '6px 12px', borderRadius: 6, fontSize: 12, fontWeight: 600,
                  background: C.redL, color: C.red, border: `1px solid #FECACA`, cursor: 'pointer',
                }}
              >
                <i className="fas fa-xmark" style={{ marginRight: 4 }} />Clear
              </button>
            )}

            <span style={{ marginLeft: 'auto', fontSize: 12, color: C.muted, alignSelf: 'center' }}>
              {total} notification{total !== 1 ? 's' : ''}
            </span>
          </div>

          {/* Table */}
          <div style={{ flex: 1, overflowY: 'auto' }}>
            {loading ? (
              <div style={{ padding: 48, textAlign: 'center', color: C.faint, fontSize: 13 }}>
                <i className="fas fa-spinner fa-spin" style={{ marginRight: 8 }} />Loading…
              </div>
            ) : error ? (
              <div style={{ padding: 24, color: C.red, fontSize: 13 }}>{error}</div>
            ) : rows.length === 0 ? (
              <div style={{ padding: '60px 24px', textAlign: 'center', color: C.faint }}>
                <i className="fas fa-circle-check" style={{ fontSize: 32, display: 'block', marginBottom: 10, color: C.green }} />
                <p style={{ margin: 0, fontSize: 14, fontWeight: 600, color: C.green }}>All clear</p>
                <p style={{ margin: '4px 0 0', fontSize: 13 }}>No notifications match the current filters.</p>
              </div>
            ) : (
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                <thead>
                  <tr>
                    <Th label="ID"          currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Recipient"   sortKey="recipient_name"  currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Template"    sortKey="template_name"   currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="In-App"      currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Email"       currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Sent At"     sortKey="created_at"      currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Retries"     currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                    <Th label="Status"      sortKey="overall_status"  currentKey={sortKey} dir={sortDir} onSort={toggleSort} />
                  </tr>
                </thead>
                <tbody>
                  {rows.map(row => {
                    const isSelected = selected?.queue_id === row.queue_id;
                    const rowBg = isSelected ? C.blueL
                      : row.overall_status === 'failed'  ? '#FFF5F5'
                      : row.overall_status === 'partial' ? '#FFFBEB'
                      : '#fff';
                    const leftBorder = row.overall_status === 'failed'  ? `3px solid ${C.red}`
                      : row.overall_status === 'partial' ? `3px solid ${C.amber}`
                      : '3px solid transparent';

                    return (
                      <tr
                        key={row.queue_id}
                        onClick={() => selectRow(row)}
                        style={{ background: rowBg, borderLeft: leftBorder, borderBottom: `1px solid ${C.border}`, cursor: 'pointer' }}
                        onMouseEnter={e => { if (!isSelected) e.currentTarget.style.background = '#F8FAFF'; }}
                        onMouseLeave={e => { if (!isSelected) e.currentTarget.style.background = rowBg; }}
                      >
                        {/* ID */}
                        <td style={tdStyle}>
                          <span style={{ fontFamily: 'monospace', fontSize: 11, color: C.blue, fontWeight: 600 }}>
                            {row.display_id !== 'N/A' ? row.display_id : row.queue_id.slice(0, 8).toUpperCase()}
                          </span>
                        </td>

                        {/* Recipient */}
                        <td style={tdStyle}>
                          <div style={{ fontWeight: 600, color: C.navy }}>{row.recipient_name}</div>
                          {row.recipient_email && (
                            <div style={{ fontSize: 10, color: C.faint }}>{row.recipient_email}</div>
                          )}
                        </td>

                        {/* Template */}
                        <td style={tdStyle}>
                          <span style={{
                            fontSize: 11, fontWeight: 600, background: C.blueL,
                            color: C.blue, borderRadius: 4, padding: '2px 7px',
                          }}>
                            {row.template_name}
                          </span>
                        </td>

                        {/* In-App */}
                        <td style={tdStyle}>
                          {(() => {
                            const cfg = INAPP_CFG[row.inapp_status];
                            return (
                              <span style={{
                                fontSize: 10, fontWeight: 600, borderRadius: 4,
                                padding: '2px 7px', background: cfg.bg, color: cfg.color,
                              }}>
                                {cfg.label}
                              </span>
                            );
                          })()}
                        </td>

                        {/* Email */}
                        <td style={tdStyle}>
                          {row.email_status ? (() => {
                            const cfg = EMAIL_CFG[row.email_status];
                            return (
                              <span style={{
                                fontSize: 10, fontWeight: 600, borderRadius: 4,
                                padding: '2px 7px', background: cfg.bg, color: cfg.color,
                              }}>
                                {cfg.label}
                              </span>
                            );
                          })() : (
                            <span style={{ fontSize: 10, color: C.faint }}>—</span>
                          )}
                        </td>

                        {/* Sent At */}
                        <td style={{ ...tdStyle, color: C.muted }}>{fmtDate(row.created_at)}</td>

                        {/* Retries */}
                        <td style={{ ...tdStyle, textAlign: 'center' }}>
                          {row.retry_count > 0 ? (
                            <span style={{
                              fontSize: 11, fontWeight: 700,
                              color: row.retry_count >= row.max_retries ? C.red : C.amber,
                            }}>
                              {row.retry_count}/{row.max_retries}
                            </span>
                          ) : (
                            <span style={{ fontSize: 11, color: C.faint }}>—</span>
                          )}
                        </td>

                        {/* Overall status */}
                        <td style={tdStyle}><OverallBadge status={row.overall_status} /></td>
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
                <PageBtn label="‹ Prev" disabled={page === 0}             onClick={() => setPage(p => p - 1)} />
                <PageBtn label="Next ›" disabled={page >= totalPages - 1} onClick={() => setPage(p => p + 1)} />
              </div>
            </div>
          )}
        </div>

        {/* ── Right: side panel ────────────────────────────────────────────── */}
        {selected && (
          <div style={{
            width: 420, flexShrink: 0, borderLeft: `1px solid ${C.border}`,
            background: '#fff', display: 'flex', flexDirection: 'column', overflowY: 'auto',
          }}>
            {/* Panel header */}
            <div style={{
              padding: '16px 18px', borderBottom: `1px solid ${C.border}`,
              display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start',
            }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 700, fontSize: 14, color: C.navy }}>
                  {selected.display_id !== 'N/A' ? selected.display_id : selected.queue_id.slice(0, 8).toUpperCase()}
                </div>
                <div style={{ fontSize: 12, color: C.muted, marginTop: 2 }}>
                  {selected.recipient_name} · {selected.template_name}
                </div>
                {recordLink(selected.module_code, selected.record_id) && (
                  <button
                    onClick={() => navigate(recordLink(selected.module_code, selected.record_id)!)}
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
                onClick={() => setSelected(null)}
                style={{ background: 'none', border: 'none', cursor: 'pointer', color: C.faint, fontSize: 18, lineHeight: 1, flexShrink: 0 }}
              >×</button>
            </div>

            {/* Channel status cards */}
            <div style={{ padding: '14px 18px', borderBottom: `1px solid ${C.border}`, display: 'flex', gap: 10 }}>
              {/* In-App card */}
              <ChannelCard
                icon="fa-bell"
                label="In-App"
                cfg={INAPP_CFG[selected.inapp_status]}
                timestamp={selected.inapp_status === 'sent' ? selected.processed_at : null}
                error={selected.inapp_error}
              />
              {/* Email card */}
              <ChannelCard
                icon="fa-envelope"
                label="Email"
                cfg={selected.email_status ? EMAIL_CFG[selected.email_status] : { label: '—', color: C.faint, bg: C.grayL }}
                timestamp={selected.email_sent_at}
                error={selected.email_error}
              />
            </div>

            {/* Retry section */}
            {selected.can_retry && (
              <div style={{ padding: '12px 18px', borderBottom: `1px solid ${C.border}` }}>
                <div style={{
                  padding: '10px 12px', borderRadius: 7, fontSize: 12,
                  background: C.amberL, border: `1px solid #FDE68A`, color: C.amber,
                  display: 'flex', gap: 8, alignItems: 'flex-start', marginBottom: 10,
                }}>
                  <i className="fas fa-triangle-exclamation" style={{ marginTop: 1, flexShrink: 0 }} />
                  <span>
                    {selected.inapp_status === 'failed'
                      ? 'In-app delivery failed. Retry will re-render the template and re-create the notification (email will also re-trigger automatically).'
                      : 'Email delivery failed. Retry will re-fire the Edge Function for this notification.'}
                  </span>
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button
                    onClick={() => doRetry(selected)}
                    disabled={retrying}
                    style={{
                      flex: 1, padding: '8px 0', borderRadius: 6, fontSize: 12, fontWeight: 700,
                      background: C.blue, color: '#fff', border: 'none',
                      cursor: retrying ? 'not-allowed' : 'pointer', opacity: retrying ? 0.7 : 1,
                      display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
                    }}
                  >
                    {retrying
                      ? <><i className="fas fa-spinner fa-spin" />Retrying…</>
                      : <><i className="fas fa-rotate-right" />Retry</>}
                  </button>
                  {selected.retry_count >= selected.max_retries && (
                    <button
                      onClick={() => doRetry(selected, true)}
                      disabled={retrying}
                      style={{
                        padding: '8px 14px', borderRadius: 6, fontSize: 11, fontWeight: 600,
                        background: C.redL, color: C.red, border: `1px solid #FECACA`,
                        cursor: retrying ? 'not-allowed' : 'pointer',
                      }}
                      title="Force retry even though max retries exceeded"
                    >
                      Force
                    </button>
                  )}
                </div>
              </div>
            )}

            {/* Metadata */}
            <div style={{ padding: '12px 18px', borderBottom: `1px solid ${C.border}` }}>
              <Row label="Template"   value={selected.template_code} mono />
              <Row label="Recipient"  value={`${selected.recipient_name}${selected.recipient_email ? ` · ${selected.recipient_email}` : ''}`} />
              {selected.recipient_dept && <Row label="Department" value={selected.recipient_dept} />}
              <Row label="Sent"       value={fmtDate(selected.created_at)} />
              {selected.processed_at && <Row label="Processed"  value={fmtDate(selected.processed_at)} />}
              <Row label="Retries"    value={`${selected.retry_count} / ${selected.max_retries}`} />
              {selected.instance_id  && <Row label="Instance"   value={selected.instance_id.slice(0, 8) + '…'} mono />}
            </div>

            {/* Payload */}
            <div style={{ padding: '12px 18px', borderBottom: `1px solid ${C.border}` }}>
              <button
                onClick={() => setShowPayload(p => !p)}
                style={{
                  display: 'flex', alignItems: 'center', gap: 6, width: '100%',
                  background: 'none', border: 'none', cursor: 'pointer',
                  fontSize: 11, fontWeight: 700, color: C.muted,
                  textTransform: 'uppercase', letterSpacing: '0.06em', padding: 0,
                }}
              >
                <i className={`fas fa-chevron-${showPayload ? 'down' : 'right'}`} style={{ fontSize: 9 }} />
                Payload
              </button>
              {showPayload && (
                <pre style={{
                  marginTop: 8, fontSize: 11, background: C.bg, border: `1px solid ${C.border}`,
                  borderRadius: 6, padding: '10px 12px', overflowX: 'auto',
                  color: C.text, lineHeight: 1.6, maxHeight: 220, overflowY: 'auto',
                }}>
                  {JSON.stringify(selected.payload, null, 2)}
                </pre>
              )}
            </div>

            {/* Attempt history */}
            <div style={{ padding: '14px 18px', flex: 1 }}>
              <p style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.06em', margin: '0 0 12px' }}>
                Retry History
              </p>
              {attempts.length === 0 ? (
                <p style={{ fontSize: 12, color: C.faint, fontStyle: 'italic' }}>No retries yet.</p>
              ) : (
                <div style={{ position: 'relative', paddingLeft: 24 }}>
                  <div style={{ position: 'absolute', left: 8, top: 6, bottom: 6, width: 2, background: C.border }} />
                  {attempts.map(a => (
                    <div key={a.id} style={{ marginBottom: 14, position: 'relative' }}>
                      <div style={{
                        position: 'absolute', left: -24, width: 16, height: 16, borderRadius: '50%',
                        background: '#fff', border: `2px solid ${a.status === 'sent' ? C.green : C.red}`,
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                      }}>
                        <i className={`fas ${a.status === 'sent' ? 'fa-check' : 'fa-xmark'}`}
                           style={{ fontSize: 7, color: a.status === 'sent' ? C.green : C.red }} />
                      </div>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
                        <span style={{ fontSize: 12, fontWeight: 600, color: C.navy }}>
                          #{a.attempt_number} — {a.channel === 'in_app' ? 'In-App' : 'Email'}
                        </span>
                        <span style={{
                          fontSize: 10, fontWeight: 700, borderRadius: 3, padding: '1px 5px',
                          background: a.status === 'sent' ? C.greenL : C.redL,
                          color: a.status === 'sent' ? C.green : C.red,
                        }}>
                          {a.status === 'sent' ? 'Succeeded' : 'Failed'}
                        </span>
                      </div>
                      <div style={{ fontSize: 11, color: C.faint, marginTop: 1 }}>
                        {fmtDate(a.attempted_at)} · {a.actor_name}
                      </div>
                      {a.error_message && (
                        <div style={{
                          marginTop: 4, fontSize: 11, color: C.red,
                          background: C.redL, borderRadius: 5, padding: '5px 8px',
                          border: `1px solid #FECACA`,
                        }}>
                          {a.error_message}
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

// ─── ChannelCard ─────────────────────────────────────────────────────────────

function ChannelCard({ icon, label, cfg, timestamp, error }: {
  icon:      string;
  label:     string;
  cfg:       { label: string; color: string; bg: string };
  timestamp: string | null;
  error:     string | null;
}) {
  return (
    <div style={{
      flex: 1, borderRadius: 7, border: `1px solid ${C.border}`,
      padding: '10px 12px', background: C.bg,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 6 }}>
        <i className={`fas ${icon}`} style={{ fontSize: 12, color: C.muted }} />
        <span style={{ fontSize: 11, fontWeight: 700, color: C.muted, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
          {label}
        </span>
      </div>
      <div style={{
        display: 'inline-flex', alignItems: 'center',
        fontSize: 11, fontWeight: 700, borderRadius: 4, padding: '2px 8px',
        background: cfg.bg, color: cfg.color,
      }}>
        {cfg.label}
      </div>
      {timestamp && (
        <div style={{ fontSize: 10, color: C.faint, marginTop: 4 }}>
          {new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', day: '2-digit', month: 'short' }).format(new Date(timestamp))}
        </div>
      )}
      {error && (
        <div style={{
          marginTop: 6, fontSize: 10, color: C.red, background: C.redL,
          borderRadius: 4, padding: '4px 6px', border: `1px solid #FECACA`,
          wordBreak: 'break-word',
        }}>
          {error.length > 120 ? error.slice(0, 120) + '…' : error}
        </div>
      )}
    </div>
  );
}

// ─── Row ─────────────────────────────────────────────────────────────────────

function Row({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div style={{ display: 'flex', gap: 8, marginBottom: 6, fontSize: 12, alignItems: 'flex-start' }}>
      <span style={{ color: C.faint, minWidth: 76, flexShrink: 0, fontWeight: 500 }}>{label}</span>
      <span style={{ color: C.text, fontFamily: mono ? 'monospace' : 'inherit', wordBreak: 'break-all' }}>
        {value}
      </span>
    </div>
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
  color: '#111827', outline: 'none', cursor: 'pointer',
};
