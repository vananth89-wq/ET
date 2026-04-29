/**
 * WorkflowDelegations
 *
 * Two-panel delegation manager:
 *
 *  My Delegations (all users with workflow.approve)
 *  ── Active delegations I have set up
 *  ── + New Delegation button → slide-in form
 *
 *  All Delegations (workflow.admin only — tab toggle)
 *  ── Full org-wide list with filter / deactivate
 *
 * DB: workflow_delegations
 *   delegator_id  → person who delegates (always the logged-in user for self-service)
 *   delegate_id   → person who will receive tasks
 *   template_id   → NULL = all templates, or scoped to one
 *   from_date / to_date
 *   reason
 *   is_active
 *
 * RLS already in place:
 *   SELECT  → admin | delegator | delegate
 *   INSERT  → delegator = auth.uid() | admin
 *   ALL     → admin
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import WorkflowGateBanner from '../components/WorkflowGateBanner';
import { usePermissions } from '../../contexts/PermissionContext';
import { useAuth } from '../../contexts/AuthContext';

// ─── Tokens ───────────────────────────────────────────────────────────────────
const C = {
  navy:   '#18345B',
  blue:   '#2F77B5',
  blueL:  '#EFF6FF',
  border: '#E5E7EB',
  bg:     '#F9FAFB',
  text:   '#111827',
  muted:  '#6B7280',
  faint:  '#9CA3AF',
  green:  '#16A34A',
  greenL: '#DCFCE7',
  red:    '#DC2626',
  redL:   '#FEF2F2',
  amber:  '#D97706',
  amberL: '#FEF9C3',
};

// ─── Types ────────────────────────────────────────────────────────────────────

interface Delegation {
  id:           string;
  delegatorId:  string;
  delegatorName: string;
  delegateId:   string;
  delegateName: string;
  templateId:   string | null;
  templateName: string | null;
  fromDate:     string;
  toDate:       string;
  reason:       string | null;
  isActive:     boolean;
  createdAt:    string;
}

interface ProfileOption {
  profileId:  string;
  employeeId: string | null;  // employee.id — used as delegator reference for circular check
  name:       string;
  email:      string;
  jobTitle:   string | null;
  managerId:  string | null;  // employee.manager_id — used for circular delegation check
}

interface TemplateOption {
  id:   string;
  name: string;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function today() {
  return new Date().toISOString().slice(0, 10);
}

function fmtDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  }).format(new Date(iso));
}

function statusBadge(d: Delegation) {
  const now = today();
  if (!d.isActive)            return { label: 'Inactive', bg: C.border,  fg: C.muted  };
  if (d.toDate < now)         return { label: 'Expired',  bg: C.amberL,  fg: C.amber  };
  if (d.fromDate > now)       return { label: 'Upcoming', bg: C.blueL,   fg: C.blue   };
  return                             { label: 'Active',   bg: C.greenL,  fg: C.green  };
}

// ─── Shared input style ───────────────────────────────────────────────────────

const iStyle: React.CSSProperties = {
  width: '100%', padding: '8px 10px', borderRadius: 6,
  border: `1px solid ${C.border}`, fontSize: 13,
  background: '#fff', outline: 'none', boxSizing: 'border-box',
};

// ─── Component ────────────────────────────────────────────────────────────────

interface Props {
  adminView?: boolean; // true → show All Delegations only; false → show My Delegations only
}

export default function WorkflowDelegations({ adminView = false }: Props) {
  const { can }              = usePermissions();
  const { profile, employee } = useAuth();
  const isAdmin               = can('workflow.admin');

  // Lock tab based on view mode — no toggle shown
  const [tab, setTab]               = useState<'mine' | 'all'>(adminView ? 'all' : 'mine');
  const [delegations, setDelegations] = useState<Delegation[]>([]);
  const [loading, setLoading]       = useState(false);
  const [showForm, setShowForm]     = useState(false);
  const [toast, setToast]           = useState<{ type: 'ok' | 'err'; msg: string } | null>(null);

  // Form state
  const [delegateQuery,   setDelegateQuery]   = useState('');
  const [delegateResults, setDelegateResults] = useState<ProfileOption[]>([]);
  const [delegateLoading, setDelegateLoading] = useState(false);
  const [selectedDelegate, setSelectedDelegate] = useState<ProfileOption | null>(null);
  const [fromDate, setFromDate]     = useState(today());
  const [toDate,   setToDate]       = useState('');
  const [reason,   setReason]       = useState('');
  const [templateId, setTemplateId] = useState<string>('');
  const [templates, setTemplates]   = useState<TemplateOption[]>([]);
  const [formError, setFormError]   = useState<string | null>(null);
  const [saving,   setSaving]       = useState(false);
  // Circular delegation warning — shown when the chosen delegate is a direct
  // report of the delegator (they may end up approving their own requests).
  const [circularWarning, setCircularWarning] = useState<string | null>(null);

  // Admin form: delegator search
  const [delegatorQuery,   setDelegatorQuery]   = useState('');
  const [delegatorResults, setDelegatorResults] = useState<ProfileOption[]>([]);
  const [delegatorLoading, setDelegatorLoading] = useState(false);
  const [selectedDelegator, setSelectedDelegator] = useState<ProfileOption | null>(null);

  // ── Toast ────────────────────────────────────────────────────────────────

  function showToast(type: 'ok' | 'err', msg: string) {
    setToast({ type, msg });
    setTimeout(() => setToast(null), 4000);
  }

  // ── Load delegations ─────────────────────────────────────────────────────

  const loadDelegations = useCallback(async () => {
    setLoading(true);
    let query = supabase
      .from('workflow_delegations')
      .select(`
        id, delegator_id, delegate_id, template_id,
        from_date, to_date, reason, is_active, created_at,
        delegator:profiles!delegator_id(
          employees!inner(name)
        ),
        delegate:profiles!delegate_id(
          employees!inner(name)
        ),
        template:workflow_templates(name)
      `)
      .order('created_at', { ascending: false });

    if (tab === 'mine' && profile?.id) {
      query = query.eq('delegator_id', profile.id);
    }

    const { data, error } = await query;
    setLoading(false);

    if (error) { showToast('err', error.message); return; }

    setDelegations((data ?? []).map((r: any) => ({
      id:           r.id,
      delegatorId:  r.delegator_id,
      delegatorName: r.delegator?.employees?.name ?? '—',
      delegateId:   r.delegate_id,
      delegateName: r.delegate?.employees?.name ?? '—',
      templateId:   r.template_id,
      templateName: r.template?.name ?? null,
      fromDate:     r.from_date,
      toDate:       r.to_date,
      reason:       r.reason,
      isActive:     r.is_active,
      createdAt:    r.created_at,
    })));
  }, [tab, profile?.id]);

  useEffect(() => { loadDelegations(); }, [loadDelegations]);

  // ── Load templates for dropdown ──────────────────────────────────────────

  useEffect(() => {
    supabase
      .from('workflow_templates')
      .select('id, name')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => setTemplates((data ?? []).map(t => ({ id: t.id, name: t.name }))));
  }, []);

  // ── User search — delegate ───────────────────────────────────────────────

  let delegateTimer: ReturnType<typeof setTimeout>;
  function searchDelegate(q: string) {
    setDelegateQuery(q);
    clearTimeout(delegateTimer);
    if (!q.trim()) { setDelegateResults([]); return; }
    delegateTimer = setTimeout(async () => {
      setDelegateLoading(true);
      const { data } = await supabase
        .from('profiles')
        .select('id, employees!inner(id, name, business_email, job_title, manager_id)')
        .ilike('employees.name', `%${q}%`)
        .eq('is_active', true)
        .limit(6);
      setDelegateLoading(false);
      setDelegateResults((data ?? []).map((p: any) => ({
        profileId:  p.id,
        employeeId: p.employees?.id ?? null,
        name:       p.employees?.name ?? '—',
        email:      p.employees?.business_email ?? '',
        jobTitle:   p.employees?.job_title ?? null,
        managerId:  p.employees?.manager_id ?? null,
      })));
    }, 280);
  }

  // ── User search — delegator (admin form only) ────────────────────────────

  let delegatorTimer: ReturnType<typeof setTimeout>;
  function searchDelegator(q: string) {
    setDelegatorQuery(q);
    clearTimeout(delegatorTimer);
    if (!q.trim()) { setDelegatorResults([]); return; }
    delegatorTimer = setTimeout(async () => {
      setDelegatorLoading(true);
      const { data } = await supabase
        .from('profiles')
        .select('id, employees!inner(id, name, business_email, job_title, manager_id)')
        .ilike('employees.name', `%${q}%`)
        .eq('is_active', true)
        .limit(6);
      setDelegatorLoading(false);
      setDelegatorResults((data ?? []).map((p: any) => ({
        profileId:  p.id,
        employeeId: p.employees?.id ?? null,
        name:       p.employees?.name ?? '—',
        email:      p.employees?.business_email ?? '',
        jobTitle:   p.employees?.job_title ?? null,
        managerId:  p.employees?.manager_id ?? null,
      })));
    }, 280);
  }

  // ── Reset form ────────────────────────────────────────────────────────────

  function resetForm() {
    setSelectedDelegate(null);
    setDelegateQuery('');
    setDelegateResults([]);
    setSelectedDelegator(null);
    setDelegatorQuery('');
    setDelegatorResults([]);
    setFromDate(today());
    setToDate('');
    setReason('');
    setTemplateId('');
    setFormError(null);
    setCircularWarning(null);
  }

  // ── Circular delegation check ─────────────────────────────────────────────
  // Fires when a delegate is picked. Warns if the delegate is a direct report
  // of the delegator — they could end up approving their own requests.

  function checkCircularRisk(delegate: ProfileOption) {
    // Determine the effective delegator's employee ID:
    //   - Self-service mode: current user's employee record
    //   - Admin mode:        the selected delegator's employee record
    const delegatorEmpId = (isAdmin && selectedDelegator)
      ? selectedDelegator.employeeId
      : (employee?.id ?? null);

    if (delegatorEmpId && delegate.managerId === delegatorEmpId) {
      setCircularWarning(
        `${delegate.name} reports directly to you (or the selected delegator). ` +
        `If they have pending submissions in workflows where you are the approver, ` +
        `they will be approving their own requests. Proceed only if intentional.`
      );
    } else {
      setCircularWarning(null);
    }
  }

  // ── Save delegation ───────────────────────────────────────────────────────

  async function saveDelegation() {
    if (!selectedDelegate) { showToast('err', 'Please select a delegate.'); return; }
    if (!toDate)            { showToast('err', 'Please set an end date.'); return; }
    if (toDate < fromDate)  { showToast('err', 'End date must be on or after start date.'); return; }

    // For admin creating on behalf of someone: use selectedDelegator; otherwise auth.uid() is used by RLS
    const delegatorId = isAdmin && selectedDelegator ? selectedDelegator.profileId : profile?.id;
    if (!delegatorId) { showToast('err', 'Could not determine delegator.'); return; }
    if (delegatorId === selectedDelegate.profileId) {
      showToast('err', 'You cannot delegate to yourself.'); return;
    }

    setSaving(true);
    const { data: inserted, error } = await supabase
      .from('workflow_delegations')
      .insert({
        delegator_id: delegatorId,
        delegate_id:  selectedDelegate.profileId,
        template_id:  templateId || null,
        from_date:    fromDate,
        to_date:      toDate,
        reason:       reason || null,
        is_active:    true,
        created_by:   profile?.id,
      })
      .select('id')
      .single();
    setSaving(false);

    if (error) {
      if (error.message.includes('wf_delegations_no_overlap')) {
        setFormError(
          'An active delegation already exists for this person covering this period and template scope. ' +
          'Please adjust the dates or deactivate the existing delegation first.'
        );
      } else {
        showToast('err', error.message);
      }
      return;
    }
    setFormError(null);

    // Notify the delegate — fire-and-forget, don't block on failure
    if (inserted?.id) {
      supabase.rpc('notify_delegation_created', { p_delegation_id: inserted.id })
        .then(({ error: notifyErr }) => {
          if (notifyErr) console.warn('Delegation notification failed:', notifyErr.message);
        });
    }

    showToast('ok', 'Delegation created. Your delegate has been notified.');
    setShowForm(false);
    resetForm();
    loadDelegations();
  }

  // ── Deactivate ────────────────────────────────────────────────────────────

  async function deactivate(id: string) {
    const { error } = await supabase
      .from('workflow_delegations')
      .update({ is_active: false })
      .eq('id', id);
    if (error) showToast('err', error.message);
    else { showToast('ok', 'Delegation deactivated.'); loadDelegations(); }
  }

  // ── Render ────────────────────────────────────────────────────────────────

  const shown = tab === 'mine'
    ? delegations
    : delegations; // all already loaded by query

  return (
    <div style={{ padding: '28px 32px', maxWidth: 1100, margin: '0 auto' }}>

      {/* Workflow gate banner — shown when delegation creation itself requires approval */}
      <WorkflowGateBanner moduleCode="delegations" actionLabel="delegation requests" />

      {/* ── Header ── */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 24 }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 22, fontWeight: 700, color: C.navy }}>
            <i className="fa-solid fa-right-left" style={{ marginRight: 10, color: C.blue }} />
            Approval Delegations
          </h1>
          <p style={{ margin: '4px 0 0', fontSize: 13, color: C.muted }}>
            {adminView
              ? 'Org-wide view of all active and past approval delegations.'
              : 'Temporarily hand over your approval tasks to a colleague while you\'re away.'}
          </p>
        </div>
        <button
          onClick={() => { resetForm(); setShowForm(true); }}
          style={{
            padding: '9px 18px', borderRadius: 7, border: 'none',
            background: C.blue, color: '#fff', fontWeight: 600,
            fontSize: 13, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 7,
          }}
        >
          <i className="fa-solid fa-plus" />
          {adminView ? 'Add Delegation' : 'New Delegation'}
        </button>
      </div>

      {/* ── Table ── */}
      {loading ? (
        <div style={{ textAlign: 'center', color: C.muted, padding: 60 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 22, marginBottom: 10 }} /><br />
          Loading delegations…
        </div>
      ) : shown.length === 0 ? (
        <div style={{
          textAlign: 'center', color: C.muted, padding: '60px 20px',
          border: `2px dashed ${C.border}`, borderRadius: 10,
        }}>
          <i className="fa-solid fa-right-left" style={{ fontSize: 28, marginBottom: 12, display: 'block', color: C.faint }} />
          <div style={{ fontWeight: 600, marginBottom: 6 }}>No delegations found</div>
          <div style={{ fontSize: 13 }}>{adminView ? 'No delegations found in the system.' : <>Click <strong>New Delegation</strong> to set one up.</>}</div>
        </div>
      ) : (
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
            <thead>
              <tr style={{ background: C.bg }}>
                {adminView && (
                  <Th>Delegator</Th>
                )}
                <Th>Delegate (receives tasks)</Th>
                <Th>Scope</Th>
                <Th>From</Th>
                <Th>To</Th>
                <Th>Reason</Th>
                <Th>Status</Th>
                <Th>Actions</Th>
              </tr>
            </thead>
            <tbody>
              {shown.map(d => {
                const badge = statusBadge(d);
                const canDeactivate = d.isActive && (adminView ? isAdmin : d.delegatorId === profile?.id);
                return (
                  <tr key={d.id} style={{ borderBottom: `1px solid ${C.border}` }}>
                    {adminView && (
                      <Td>
                        <span style={{ fontWeight: 600, color: C.navy }}>{d.delegatorName}</span>
                      </Td>
                    )}
                    <Td>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div style={{
                          width: 28, height: 28, borderRadius: '50%',
                          background: C.blue, color: '#fff',
                          display: 'flex', alignItems: 'center', justifyContent: 'center',
                          fontSize: 11, fontWeight: 700, flexShrink: 0,
                        }}>
                          {d.delegateName.charAt(0).toUpperCase()}
                        </div>
                        <span style={{ fontWeight: 600, color: C.navy }}>{d.delegateName}</span>
                      </div>
                    </Td>
                    <Td>
                      {d.templateName
                        ? <span style={{ background: C.blueL, color: C.blue, padding: '2px 8px', borderRadius: 99, fontWeight: 600, fontSize: 11 }}>{d.templateName}</span>
                        : <span style={{ color: C.muted, fontStyle: 'italic' }}>All templates</span>
                      }
                    </Td>
                    <Td>{fmtDate(d.fromDate)}</Td>
                    <Td>{fmtDate(d.toDate)}</Td>
                    <Td style={{ maxWidth: 200 }}>
                      <span style={{ color: d.reason ? C.text : C.faint, fontStyle: d.reason ? 'normal' : 'italic' }}>
                        {d.reason ?? '—'}
                      </span>
                    </Td>
                    <Td>
                      <span style={{
                        padding: '3px 10px', borderRadius: 99, fontSize: 11,
                        fontWeight: 700, background: badge.bg, color: badge.fg,
                      }}>
                        {badge.label}
                      </span>
                    </Td>
                    <Td>
                      {canDeactivate && (
                        <button
                          onClick={() => deactivate(d.id)}
                          style={{
                            padding: '4px 12px', borderRadius: 5, border: `1px solid ${C.border}`,
                            background: '#fff', color: C.red, cursor: 'pointer', fontSize: 12, fontWeight: 600,
                          }}
                          title="Deactivate this delegation"
                        >
                          Deactivate
                        </button>
                      )}
                    </Td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* ── New Delegation Modal ── */}
      {showForm && (
        <div style={{
          position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.4)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          zIndex: 1000,
        }}>
          <div style={{
            background: '#fff', borderRadius: 12, padding: 28, width: 520,
            maxHeight: '90vh', overflowY: 'auto', boxShadow: '0 20px 60px rgba(0,0,0,0.2)',
          }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
              <h2 style={{ margin: 0, fontSize: 17, fontWeight: 700, color: C.navy }}>
                <i className="fa-solid fa-right-left" style={{ marginRight: 8, color: C.blue }} />
                New Delegation
              </h2>
              <button
                onClick={() => { setShowForm(false); resetForm(); }}
                style={{ border: 'none', background: 'none', cursor: 'pointer', fontSize: 18, color: C.muted }}
              >×</button>
            </div>

            {/* Delegator — read-only chip for employees, searchable for admins */}
            <FormRow
              label="Delegating On Behalf Of"
              hint={adminView ? 'Leave blank to use yourself' : 'You'}
            >
              {!adminView ? (
                /* Employee view: always shows the logged-in user, read-only */
                <div style={{
                  display: 'flex', alignItems: 'center', gap: 10,
                  padding: '8px 10px', border: `1px solid ${C.border}`,
                  borderRadius: 6, background: C.bg,
                }}>
                  <div style={{
                    width: 28, height: 28, borderRadius: '50%',
                    background: C.navy, color: '#fff',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    fontSize: 11, fontWeight: 700, flexShrink: 0,
                  }}>
                    {(employee?.name ?? 'U').charAt(0).toUpperCase()}
                  </div>
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 600, color: C.navy }}>
                      {employee?.name ?? '—'}
                    </div>
                    <div style={{ fontSize: 11, color: C.muted }}>You · read-only</div>
                  </div>
                  <i className="fa-solid fa-lock" style={{ marginLeft: 'auto', color: C.faint, fontSize: 11 }} />
                </div>
              ) : (
                /* Admin view: search for any employee */
                <div style={{ position: 'relative' }}>
                  {selectedDelegator ? (
                    <UserChip user={selectedDelegator} onClear={() => { setSelectedDelegator(null); setDelegatorQuery(''); setDelegatorResults([]); }} />
                  ) : (
                    <>
                      <input
                        value={delegatorQuery}
                        onChange={e => searchDelegator(e.target.value)}
                        placeholder="Search by name (or leave blank for yourself)…"
                        style={iStyle}
                      />
                      {delegatorLoading && <Spinner />}
                      {delegatorResults.length > 0 && (
                        <UserDropdown results={delegatorResults} onSelect={u => { setSelectedDelegator(u); setDelegatorQuery(u.name); setDelegatorResults([]); }} />
                      )}
                    </>
                  )}
                </div>
              )}
            </FormRow>

            {/* Delegate (receives tasks) */}
            <FormRow label="Delegate *" hint="Who will handle approvals in your absence">
              <div style={{ position: 'relative' }}>
                {selectedDelegate ? (
                  <UserChip user={selectedDelegate} onClear={() => { setSelectedDelegate(null); setDelegateQuery(''); setDelegateResults([]); setCircularWarning(null); }} />
                ) : (
                  <>
                    <input
                      value={delegateQuery}
                      onChange={e => searchDelegate(e.target.value)}
                      placeholder="Search by name…"
                      style={iStyle}
                    />
                    {delegateLoading && <Spinner />}
                    {delegateResults.length > 0 && (
                      <UserDropdown results={delegateResults} onSelect={u => { setSelectedDelegate(u); setDelegateQuery(u.name); setDelegateResults([]); checkCircularRisk(u); }} />
                    )}
                  </>
                )}
              </div>
            </FormRow>

            {/* Circular delegation warning */}
            {circularWarning && (
              <div style={{
                display: 'flex', alignItems: 'flex-start', gap: 10,
                background: C.amberL, border: `1px solid ${C.amber}`,
                borderRadius: 8, padding: '10px 14px', marginBottom: 14,
                fontSize: 12, color: '#92400E',
              }}>
                <i className="fa-solid fa-triangle-exclamation"
                   style={{ color: C.amber, flexShrink: 0, marginTop: 1 }} />
                <div>
                  <strong>Circular approval risk</strong> — {circularWarning}
                </div>
              </div>
            )}

            {/* Date range */}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 14 }}>
              <FormRow label="From *" compact>
                <input type="date" value={fromDate} min={today()}
                  onChange={e => setFromDate(e.target.value)} style={iStyle} />
              </FormRow>
              <FormRow label="To *" compact>
                <input type="date" value={toDate} min={fromDate}
                  onChange={e => setToDate(e.target.value)} style={iStyle} />
              </FormRow>
            </div>

            {/* Template scope */}
            <FormRow label="Scope" hint="Leave blank to delegate all approval types">
              <select value={templateId} onChange={e => setTemplateId(e.target.value)} style={iStyle}>
                <option value="">All templates</option>
                {templates.map(t => (
                  <option key={t.id} value={t.id}>{t.name}</option>
                ))}
              </select>
            </FormRow>

            {/* Reason */}
            <FormRow label="Reason" hint="e.g. Annual leave 5–12 May">
              <input
                value={reason}
                onChange={e => setReason(e.target.value)}
                placeholder="Optional note"
                style={iStyle}
              />
            </FormRow>

            {/* Info box */}
            <div style={{
              background: C.blueL, border: `1px solid ${C.blue}`, borderRadius: 8,
              padding: '10px 14px', fontSize: 12, color: C.blue, marginBottom: 20,
              display: 'flex', gap: 8,
            }}>
              <i className="fa-solid fa-circle-info" style={{ marginTop: 1, flexShrink: 0 }} />
              <span>
                New workflow tasks assigned to you during this period will be automatically
                routed to your delegate instead. SELF-type steps are never delegated.
              </span>
            </div>

            {/* Inline form error */}
            {formError && (
              <div style={{
                background: C.redL, border: `1px solid ${C.red}`, borderRadius: 8,
                padding: '10px 14px', fontSize: 12, color: C.red, marginBottom: 16,
                display: 'flex', gap: 8, alignItems: 'flex-start',
              }}>
                <i className="fa-solid fa-circle-exclamation" style={{ marginTop: 1, flexShrink: 0 }} />
                <span>{formError}</span>
              </div>
            )}

            {/* Actions */}
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button
                onClick={() => { setShowForm(false); resetForm(); }}
                style={{
                  padding: '9px 18px', borderRadius: 6, border: `1px solid ${C.border}`,
                  background: '#fff', color: C.text, cursor: 'pointer', fontWeight: 500, fontSize: 13,
                }}
              >Cancel</button>
              <button
                onClick={saveDelegation}
                disabled={saving}
                style={{
                  padding: '9px 18px', borderRadius: 6, border: 'none',
                  background: saving ? C.faint : C.blue, color: '#fff',
                  cursor: saving ? 'not-allowed' : 'pointer', fontWeight: 600, fontSize: 13,
                  display: 'flex', alignItems: 'center', gap: 7,
                }}
              >
                {saving
                  ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                  : <><i className="fa-solid fa-check" /> Create Delegation</>
                }
              </button>
            </div>
          </div>
        </div>
      )}

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

function Th({ children }: { children: React.ReactNode }) {
  return (
    <th style={{
      padding: '10px 14px', textAlign: 'left', fontWeight: 600,
      fontSize: 11, color: '#6B7280', textTransform: 'uppercase',
      letterSpacing: '0.05em', borderBottom: '1px solid #E5E7EB',
    }}>{children}</th>
  );
}

function Td({ children, style }: { children: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <td style={{
      padding: '12px 14px', verticalAlign: 'middle',
      fontSize: 13, color: '#111827', ...style,
    }}>{children}</td>
  );
}

function FormRow({
  label, hint, children, compact,
}: {
  label: string; hint?: string; children: React.ReactNode; compact?: boolean;
}) {
  return (
    <div style={{ marginBottom: compact ? 0 : 14 }}>
      <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: '#374151', marginBottom: 4 }}>
        {label}
        {hint && <span style={{ fontWeight: 400, color: '#9CA3AF', marginLeft: 6 }}>— {hint}</span>}
      </label>
      {children}
    </div>
  );
}

function Spinner() {
  return (
    <div style={{ position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)', color: '#9CA3AF' }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 13 }} />
    </div>
  );
}

function UserChip({ user, onClear }: { user: ProfileOption; onClear: () => void }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: '8px 10px', border: '1px solid #2F77B5',
      borderRadius: 6, background: '#EFF6FF',
    }}>
      <div style={{
        width: 28, height: 28, borderRadius: '50%',
        background: '#2F77B5', color: '#fff',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 11, fontWeight: 700, flexShrink: 0,
      }}>
        {user.name.charAt(0).toUpperCase()}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: '#18345B' }}>{user.name}</div>
        <div style={{ fontSize: 11, color: '#6B7280', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {user.jobTitle ? `${user.jobTitle} · ` : ''}{user.email}
        </div>
      </div>
      <button
        onClick={onClear}
        style={{ border: 'none', background: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 14 }}
        title="Clear"
      >×</button>
    </div>
  );
}

function UserDropdown({ results, onSelect }: { results: ProfileOption[]; onSelect: (u: ProfileOption) => void }) {
  return (
    <div style={{
      position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 200,
      background: '#fff', border: '1px solid #E5E7EB', borderRadius: 8,
      boxShadow: '0 8px 30px rgba(0,0,0,0.12)', marginTop: 4, overflow: 'hidden',
    }}>
      {results.map(u => (
        <button
          key={u.profileId}
          onClick={() => onSelect(u)}
          style={{
            display: 'flex', alignItems: 'center', gap: 10,
            width: '100%', padding: '10px 14px', border: 'none',
            background: 'none', cursor: 'pointer', textAlign: 'left',
            borderBottom: '1px solid #F3F4F6',
          }}
          onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
          onMouseLeave={e => (e.currentTarget.style.background = 'none')}
        >
          <div style={{
            width: 28, height: 28, borderRadius: '50%',
            background: '#2F77B5', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 11, fontWeight: 700, flexShrink: 0,
          }}>
            {u.name.charAt(0).toUpperCase()}
          </div>
          <div>
            <div style={{ fontSize: 13, fontWeight: 600, color: '#111827' }}>{u.name}</div>
            <div style={{ fontSize: 11, color: '#6B7280' }}>
              {u.jobTitle ? `${u.jobTitle} · ` : ''}{u.email}
            </div>
          </div>
        </button>
      ))}
    </div>
  );
}
