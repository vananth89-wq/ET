/**
 * TerminationPortlet
 *
 * Self-contained portlet for employee termination. Used in:
 *   • MyProfile/index.tsx  — ESS self-service (SELF path only)
 *   • EmployeeEditPanel.tsx — HR/Admin/Manager view + initiation
 *
 * Surfaces:
 *   – Read view: shows current termination state + workflow status badge
 *   – Submit form: TerminationForm (SELF) or TerminationHRForm (HR/Admin/Manager)
 *   – Reversal form: TerminationReversalForm (HR/Admin only, when status=APPROVED)
 *   – Withdraw button: while status=PENDING
 *   – Impact modal: TerminationImpactModal (HR/Admin path before submit)
 *   – Confirm dialog: TerminationConfirmDialog (both paths before submit)
 *
 * Design spec: docs/termination-design.md §6
 */

import { useState, useCallback } from 'react';
import { supabase }              from '../../lib/supabase';
import { useAuth }               from '../../contexts/AuthContext';
import ConfirmationModal         from './ConfirmationModal';
import { useTerminationData }    from '../../hooks/useTerminationData';
import TerminationForm           from './TerminationForm';
import TerminationHRForm, { type HRFormState } from './TerminationHRForm';
import TerminationReversalForm   from './TerminationReversalForm';
import TerminationConfirmDialog  from './TerminationConfirmDialog';
import TerminationImpactModal    from '../admin/TerminationImpactModal';
import WorkflowParticipantsModal from '../../workflow/components/WorkflowParticipantsModal';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export interface TerminationPortletProps {
  employeeId:       string;
  employeeName?:    string;
  /** true for ESS self-service (MyProfile); false for HR/Admin */
  isSelfService?:   boolean;
  /** Employee's contractual notice period in days — used in self-service form */
  noticePeriodDays?: number;
  readOnly?:        boolean;
  canEdit?:         boolean;
  canHistory?:      boolean;
  canDelete?:       boolean;
  pendingCount?:    number;
  onChanged?:       () => void;
  sectionTitle?: {
    icon:            string;
    text:            string;
    pending?:        number;
    onViewProgress?: () => void;
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function fmtDate(v?: string | null): string {
  if (!v) return '—';
  // Pure date strings (YYYY-MM-DD) need T00:00:00 appended to avoid timezone
  // rollback to the previous day. Full ISO timestamps (contain T / Z / +) must
  // be parsed directly — appending T00:00:00 produces an invalid string.
  const d = /[TZ+]/.test(v) ? new Date(v) : new Date(v + 'T00:00:00');
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

const STATUS_STYLE: Record<string, { bg: string; color: string; label: string }> = {
  PENDING:   { bg: '#FEF9C3', color: '#854D0E', label: 'Pending Approval' },
  APPROVED:  { bg: '#DCFCE7', color: '#15803D', label: 'Approved'         },
  REJECTED:  { bg: '#FEE2E2', color: '#DC2626', label: 'Rejected'         },
  WITHDRAWN: { bg: '#F3F4F6', color: '#6B7280', label: 'Withdrawn'        },
  REVERSED:  { bg: '#EDE9FE', color: '#6D28D9', label: 'Reversed'         },
  DRAFT:     { bg: '#F3F4F6', color: '#6B7280', label: 'Draft'            },
};

function StatusBadge({ status }: { status: string }) {
  const st = STATUS_STYLE[status] ?? STATUS_STYLE.DRAFT;
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '3px 10px', borderRadius: 20, fontSize: 12, fontWeight: 600, background: st.bg, color: st.color }}>
      {st.label}
    </span>
  );
}

function Row({ label, value }: { label: string; value?: string | null }) {
  return (
    <div style={{ display: 'flex', gap: 8, fontSize: 13, paddingBottom: 6 }}>
      <span style={{ minWidth: 180, color: '#6B7280', flexShrink: 0 }}>{label}</span>
      <span style={{ color: '#111827', fontWeight: 500 }}>{value || '—'}</span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Component
// ─────────────────────────────────────────────────────────────────────────────

type ViewMode = 'read' | 'submit' | 'reversal';

export default function TerminationPortlet({
  employeeId,
  employeeName = 'this employee',
  isSelfService = false,
  noticePeriodDays = 30,
  readOnly = false,
  canEdit = false,
  canHistory = false,
  canDelete = false,
  pendingCount: _pendingCount,
  onChanged,
  sectionTitle,
}: TerminationPortletProps) {

  const { isAdmin }                                        = useAuth();
  const { termination, reversal, loading, error, refetch } = useTerminationData(employeeId);

  const [mode,                 setMode]                 = useState<ViewMode>('read');
  const [formData,             setFormData]             = useState<HRFormState | null>(null);
  const [showConfirm,          setShowConfirm]          = useState(false);
  const [showImpact,           setShowImpact]           = useState(false);
  const [submitting,           setSubmitting]           = useState(false);
  const [apiError,             setApiError]             = useState('');
  const [submitError,          setSubmitError]          = useState<string | null>(null);
  const [participantsOpen,     setParticipantsOpen]     = useState(false);
  const [reversalParticipantsOpen, setReversalParticipantsOpen] = useState(false);
  const [pendingReassignments, setPendingReassignments] = useState<import('../admin/TerminationImpactModal').ManagerReassignment[]>([]);
  const [rerunning,            setRerunning]            = useState(false);
  const [rerunResult,          setRerunResult]          = useState<{ ok: boolean; msg: string } | null>(null);

  const isPending    = termination?.workflow_status === 'PENDING';
  const pendingCount = isPending ? 1 : 0;

  // Show "Re-run finalization" when: super admin + APPROVED + not yet executed + LWD is past
  const today = new Date().toISOString().slice(0, 10);
  const showRerunButton = isAdmin
    && !isSelfService
    && termination?.workflow_status === 'APPROVED'
    && termination?.scheduled_executed === false
    && !!termination?.last_working_date
    && termination.last_working_date <= today;

  async function handleRerunFinalize() {
    if (!termination) return;
    setRerunning(true);
    setRerunResult(null);
    try {
      const { data, error } = await supabase.functions.invoke('apply-termination-approval', {
        body: { termination_id: termination.id },
      });
      if (error) {
        // Try to extract the real error message from the response body
        const detail = (data as any)?.error ?? error?.message ?? 'Re-run failed. Check Edge Function logs.';
        setRerunResult({ ok: false, msg: detail });
        return;
      }
      const result = data as { ok: boolean; finalize?: { ok: boolean; error?: string; dr_errors?: unknown[] } };
      if (result?.finalize?.ok === false) {
        setRerunResult({ ok: false, msg: result.finalize.error ?? 'Finalization failed — check DR reassignments.' });
      } else {
        setRerunResult({ ok: true, msg: 'Finalization re-run complete. Manager reassignments applied.' });
        refetch();
      }
    } catch (err: any) {
      setRerunResult({ ok: false, msg: err?.message ?? 'Re-run failed. Check Edge Function logs.' });
    } finally {
      setRerunning(false);
    }
  }

  // ── Submit flow ────────────────────────────────────────────────────────────

  async function handleFormReady(data: HRFormState) {
    setFormData(data);
    if (!isSelfService) {
      // HR path: check impact first; only show Impact modal if there are affected employees
      const { data: impact, error: impactErr } = await supabase.rpc('get_termination_deactivation_impact', {
        p_employee_id: employeeId,
      });
      // On RPC error, null result, or {ok:false}, show the Impact modal as a safety fallback
      if (impactErr || !impact || !(impact as any).ok) {
        setShowImpact(true);
        return;
      }
      const hasImpact = ((impact as any).direct_report_count ?? 0) + ((impact as any).jr_assignment_count ?? 0) > 0;
      if (hasImpact) {
        setShowImpact(true);   // show impact warning first
      } else {
        setShowConfirm(true);  // no impact — go straight to WorkflowSubmitModal
      }
    } else {
      setShowConfirm(true);   // Self path: go straight to confirm
    }
  }

  function handleSelfFormReady(data: Parameters<React.ComponentProps<typeof TerminationForm>['onSubmit']>[0]) {
    // Convert TerminationForm's state to submission payload shape
    setFormData({
      separation_date:             data.resignation_date,   // field key in FormState is resignation_date (maps to separation_date)
      termination_reason_code:     data.termination_reason_code,
      last_working_date:           data.last_working_date,
      notice_period_waived:        false,
      notice_period_waiver_reason: '',
      eligible_for_rehire:         true,
      regrettable_termination:     null,
      comments:                    data.comments,
    });
    setShowConfirm(true);
  }

  function handleImpactConfirm(reassignments: import('../admin/TerminationImpactModal').ManagerReassignment[]) {
    setPendingReassignments(reassignments);
    setShowImpact(false);
    setShowConfirm(true);
  }

  async function handleConfirmedSubmit(comment: string) {
    if (!formData) return;
    setSubmitting(true);
    setApiError('');
    setSubmitError(null);

    const { data, error: err } = await supabase.rpc('submit_termination', {
      p_employee_id:      employeeId,
      p_termination_data: formData,
      p_attachments:      [],
      p_comment:          comment?.trim() || null,
      p_reassignments:    pendingReassignments.length > 0 ? pendingReassignments : [],
    });

    setSubmitting(false);
    const result = data as { ok: boolean; error?: string } | null;

    if (err || !result?.ok) {
      const msg = err?.message ?? result?.error ?? 'Submission failed.';
      setSubmitError(msg);
      return;
    }

    setShowConfirm(false);
    setMode('read');
    refetch();
    onChanged?.();
  }

  // ── Withdraw ───────────────────────────────────────────────────────────────

  const [showWithdrawConfirm, setShowWithdrawConfirm] = useState(false);
  const [withdrawLoading,     setWithdrawLoading]     = useState(false);
  const [withdrawError,       setWithdrawError]       = useState<string | null>(null);

  async function handleWithdraw() {
    if (!termination) return;
    setWithdrawLoading(true);
    setWithdrawError(null);
    const { data, error: err } = await supabase.rpc('withdraw_termination', {
      p_termination_id: termination.id,
    });
    setWithdrawLoading(false);
    const result = data as { ok: boolean; error?: string } | null;
    if (err || !result?.ok) {
      setWithdrawError(err?.message ?? result?.error ?? 'Withdraw failed.');
      return;
    }
    setShowWithdrawConfirm(false);
    refetch();
    onChanged?.();
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  const [showDeleteConfirm,  setShowDeleteConfirm]  = useState(false);
  const [deleteLoading,      setDeleteLoading]      = useState(false);
  const [deleteError,        setDeleteError]        = useState<string | null>(null);

  async function handleDeleteTermination() {
    if (!termination) return;
    setDeleteLoading(true);
    setDeleteError(null);
    const { data, error: err } = await supabase.rpc('delete_termination_record', {
      p_record_id:   termination.id,
      p_employee_id: employeeId,
    });
    setDeleteLoading(false);
    const result = data as { ok: boolean; error?: string } | null;
    if (err || !result?.ok) {
      setDeleteError(err?.message ?? result?.error ?? 'Delete failed.');
      return;
    }
    setShowDeleteConfirm(false);
    refetch();
    onChanged?.();
  }

  // ── Withdraw Reversal ──────────────────────────────────────────────────────

  const [showWithdrawReversalConfirm, setShowWithdrawReversalConfirm] = useState(false);
  const [withdrawReversalLoading,     setWithdrawReversalLoading]     = useState(false);
  const [withdrawReversalError,       setWithdrawReversalError]       = useState<string | null>(null);

  async function handleWithdrawReversal() {
    if (!reversal) return;
    setWithdrawReversalLoading(true);
    setWithdrawReversalError(null);
    const { data, error: err } = await supabase.rpc('withdraw_termination_reversal', {
      p_reversal_id: reversal.id,
    });
    setWithdrawReversalLoading(false);
    const result = data as { ok: boolean; error?: string } | null;
    if (err || !result?.ok) {
      setWithdrawReversalError(err?.message ?? result?.error ?? 'Withdraw failed.');
      return;
    }
    setShowWithdrawReversalConfirm(false);
    refetch();
    onChanged?.();
  }

  // ── Reversal submit ────────────────────────────────────────────────────────

  async function handleReversalSubmit(reversalData: { reversal_reason: string; comments: string }) {
    if (!termination) return;
    setSubmitting(true);
    setApiError('');
    const { data, error: err } = await supabase.rpc('submit_termination_reversal', {
      p_termination_id: termination.id,
      p_reversal_data:  reversalData,
      p_attachments:    [],
    });
    setSubmitting(false);
    const result = data as { ok: boolean; error?: string } | null;
    if (err || !result?.ok) {
      setApiError(err?.message ?? result?.error ?? 'Reversal submission failed.');
      return;
    }
    setMode('read');
    refetch();
    onChanged?.();
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  const showSubmitButton = canEdit && !readOnly && !termination;
  const showWithdrawButton = canEdit && !readOnly && termination?.workflow_status === 'PENDING';
  const showReversalButton = canEdit && !readOnly && !isSelfService && termination?.workflow_status === 'APPROVED' && !reversal;

  return (
    <div className="termination-portlet">
      {/* Section title — matches MyProfile SectionTitle style exactly */}
      {sectionTitle && (
        <div className="ev-section-title" style={{ display: 'flex', alignItems: 'flex-start', flexDirection: 'column', gap: 6, marginBottom: 12 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className={`fa-solid ${sectionTitle.icon}`} />
            {sectionTitle.text}
            {isPending && (
              <span style={{
                display: 'inline-flex', alignItems: 'center', gap: 4,
                background: '#FEF3C7', color: '#B45309',
                border: '1px solid #F59E0B', borderRadius: 10,
                padding: '2px 8px', fontSize: 11, fontWeight: 600, lineHeight: 1.4,
              }}>
                <i className="fa-solid fa-hourglass-half" style={{ fontSize: 10 }} />
                Workflow Pending Approval
              </span>
            )}
          </div>
          {isPending && termination?.workflow_instance_id && (
            <button
              onClick={() => setParticipantsOpen(true)}
              style={{
                background: 'none', border: 'none', padding: 0, cursor: 'pointer',
                display: 'flex', alignItems: 'center', gap: 4,
                fontSize: 12, color: '#185FA5',
                textDecoration: 'underline', textUnderlineOffset: '2px',
              }}
            >
              <i className="fa-solid fa-users" style={{ fontSize: 11 }} />
              View approval progress
              <i className="fa-solid fa-arrow-right" style={{ fontSize: 10 }} />
            </button>
          )}
        </div>
      )}

      {/* Error banner */}
      {apiError && (
        <div style={{ padding: '10px 14px', background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 8, color: '#DC2626', fontSize: 13, marginBottom: 12 }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{apiError}
          <button onClick={() => setApiError('')} style={{ float: 'right', background: 'none', border: 'none', cursor: 'pointer', color: '#DC2626' }}>✕</button>
        </div>
      )}

      {loading && (
        <div style={{ padding: '16px 0', textAlign: 'center', color: '#6B7280', fontSize: 13 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
        </div>
      )}

      {error && !loading && (
        <div style={{ color: '#DC2626', fontSize: 13 }}><i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{error}</div>
      )}

      {/* ── READ VIEW ──────────────────────────────────────────────────────── */}
      {!loading && !error && mode === 'read' && (
        <>
          {!termination ? (
            <div style={{ padding: '14px 16px', background: '#F9FAFB', borderRadius: 8, border: '1px solid #E5E7EB', fontSize: 13, color: '#6B7280', marginBottom: 12 }}>
              No termination on record.
            </div>
          ) : (
            <div style={{ background: '#F9FAFB', borderRadius: 8, border: '1px solid #E5E7EB', padding: '14px 16px', marginBottom: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: isPending ? 8 : 12 }}>
                <div style={{ fontSize: 14, fontWeight: 700, color: '#111827' }}>
                  <i className="fa-solid fa-user-slash" style={{ marginRight: 6, color: '#DC2626' }} />
                  Termination — {fmtDate(termination.separation_date)}
                </div>
                <StatusBadge status={termination.workflow_status} />
              </div>

              {/* Pending workflow banner — shown inline when no sectionTitle (e.g. EmployeeEditPanel) */}
              {isPending && termination.workflow_instance_id && !sectionTitle && (
                <div style={{
                  display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                  background: '#FFFBEB', border: '1px solid #FCD34D', borderRadius: 6,
                  padding: '8px 12px', marginBottom: 12, gap: 8,
                }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: '#92400E' }}>
                    <i className="fa-solid fa-hourglass-half" style={{ fontSize: 11 }} />
                    Awaiting approver action
                  </div>
                  <button
                    onClick={() => setParticipantsOpen(true)}
                    style={{
                      background: 'none', border: 'none', padding: 0, cursor: 'pointer',
                      display: 'flex', alignItems: 'center', gap: 4,
                      fontSize: 12, color: '#185FA5', fontWeight: 600,
                      textDecoration: 'underline', textUnderlineOffset: '2px',
                    }}
                  >
                    <i className="fa-solid fa-users" style={{ fontSize: 11 }} />
                    View approval progress
                    <i className="fa-solid fa-arrow-right" style={{ fontSize: 10 }} />
                  </button>
                </div>
              )}
              <Row label="Reason" value={termination.termination_reason_code} />
              <Row label="Initiation Type" value={termination.termination_initiation_type?.replace(/_/g, ' ')} />
              <Row label="Separation Date" value={fmtDate(termination.separation_date)} />
              {termination.notice_expiry_date && <Row label="Notice Expiry" value={fmtDate(termination.notice_expiry_date)} />}
              {termination.last_working_date  && <Row label="Last Working Date"  value={fmtDate(termination.last_working_date)} />}
              {termination.notice_period_waived && <Row label="Notice Period Waived" value="Yes" />}
              {!isSelfService && termination.eligible_for_rehire !== undefined && (
                <Row label="Eligible for Rehire" value={termination.eligible_for_rehire ? 'Yes' : 'No'} />
              )}
              {!isSelfService && termination.regrettable_termination !== null && (
                <Row label="Regrettable" value={termination.regrettable_termination ? 'Yes' : 'No'} />
              )}
              <Row label="Comments" value={termination.comments} />
              {termination.approved_at && <Row label="Approved At" value={fmtDate(termination.approved_at)} />}
            </div>
          )}

          {/* Active reversal */}
          {reversal && (
            <div style={{ background: '#F5F3FF', borderRadius: 8, border: '1px solid #DDD6FE', padding: '12px 16px', marginBottom: 12 }}>
              <div style={{ fontSize: 13, fontWeight: 700, color: '#6D28D9', marginBottom: 8 }}>
                <i className="fa-solid fa-rotate-left" style={{ marginRight: 6 }} />Reversal — {reversal.workflow_status}
              </div>
              <Row label="Reason" value={reversal.reversal_reason} />
              <Row label="Comments" value={reversal.comments} />
              <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 8 }}>
                {reversal.workflow_status === 'PENDING' && reversal.workflow_instance_id && (
                  <button
                    onClick={() => setReversalParticipantsOpen(true)}
                    style={{
                      background: 'none', border: 'none', padding: 0, cursor: 'pointer',
                      display: 'flex', alignItems: 'center', gap: 4,
                      fontSize: 12, color: '#6D28D9',
                      textDecoration: 'underline', textUnderlineOffset: '2px',
                    }}
                  >
                    <i className="fa-solid fa-users" style={{ fontSize: 11 }} />
                    View approval progress
                    <i className="fa-solid fa-arrow-right" style={{ fontSize: 10 }} />
                  </button>
                )}
                {canDelete && reversal.workflow_status === 'PENDING' && !readOnly && (
                  <button
                    onClick={() => { setWithdrawReversalError(null); setShowWithdrawReversalConfirm(true); }}
                    style={{ padding: '6px 12px', fontSize: 12, borderRadius: 6, background: '#F3F4F6', color: '#374151', border: '1px solid #D1D5DB', cursor: 'pointer', fontWeight: 600 }}
                  >
                    <i className="fa-solid fa-xmark" style={{ marginRight: 5 }} />
                    Withdraw Reversal
                  </button>
                )}
              </div>
            </div>
          )}

          {/* Action buttons */}
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {showSubmitButton && mode === 'read' && (
              <button onClick={() => { setApiError(''); setMode('submit'); }}
                style={{ padding: '8px 16px', fontSize: 13, borderRadius: 6, background: isSelfService ? '#2563EB' : '#DC2626', color: '#fff', border: 'none', cursor: 'pointer', fontWeight: 600 }}>
                <i className={`fa-solid ${isSelfService ? 'fa-file-signature' : 'fa-user-slash'}`} style={{ marginRight: 6 }} />
                {isSelfService ? 'Submit Separation' : 'Initiate Termination'}
              </button>
            )}
            {showWithdrawButton && (
              <button onClick={() => { setWithdrawError(null); setShowWithdrawConfirm(true); }}
                style={{ padding: '8px 16px', fontSize: 13, borderRadius: 6, background: '#F3F4F6', color: '#374151', border: '1px solid #D1D5DB', cursor: 'pointer' }}>
                <i className="fa-solid fa-xmark" style={{ marginRight: 6 }} />Withdraw
              </button>
            )}
            {canDelete && termination && !readOnly && !reversal && (
              <button
                onClick={() => { setDeleteError(null); setShowDeleteConfirm(true); }}
                style={{ padding: '8px 16px', fontSize: 13, borderRadius: 6, background: '#FEF2F2', color: '#DC2626', border: '1px solid #FCA5A5', cursor: 'pointer', fontWeight: 600 }}
              >
                <i className="fa-solid fa-trash-can" style={{ marginRight: 6 }} />Delete
              </button>
            )}
            {showReversalButton && (
              <button onClick={() => { setApiError(''); setMode('reversal'); }}
                style={{ padding: '8px 16px', fontSize: 13, borderRadius: 6, background: '#7C3AED', color: '#fff', border: 'none', cursor: 'pointer', fontWeight: 600 }}>
                <i className="fa-solid fa-rotate-left" style={{ marginRight: 6 }} />Reverse Termination
              </button>
            )}
            {showRerunButton && (
              <button
                onClick={handleRerunFinalize}
                disabled={rerunning}
                style={{ padding: '8px 16px', fontSize: 13, borderRadius: 6, background: '#D97706', color: '#fff', border: 'none', cursor: rerunning ? 'not-allowed' : 'pointer', fontWeight: 600, opacity: rerunning ? 0.7 : 1 }}
              >
                <i className={`fa-solid ${rerunning ? 'fa-spinner fa-spin' : 'fa-person-walking-arrow-right'}`} style={{ marginRight: 6 }} />
                {rerunning ? 'Running…' : 'Re-run Finalization'}
              </button>
            )}
          </div>
          {rerunResult && (
            <div style={{ marginTop: 8, padding: '8px 12px', borderRadius: 6, fontSize: 13,
              background: rerunResult.ok ? '#ECFDF5' : '#FEF2F2',
              color:      rerunResult.ok ? '#065F46'  : '#991B1B',
              border:     `1px solid ${rerunResult.ok ? '#A7F3D0' : '#FCA5A5'}`,
            }}>
              <i className={`fa-solid ${rerunResult.ok ? 'fa-circle-check' : 'fa-triangle-exclamation'}`} style={{ marginRight: 6 }} />
              {rerunResult.msg}
            </div>
          )}
        </>
      )}

      {/* ── SUBMIT FORM ────────────────────────────────────────────────────── */}
      {mode === 'submit' && (
        <div style={{ background: '#F9FAFB', borderRadius: 8, border: '1px solid #E5E7EB', padding: 16 }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: '#111827', marginBottom: 14 }}>
            {isSelfService ? 'Submit Separation' : 'Initiate Termination'}
          </div>
          {isSelfService ? (
            <TerminationForm
              onSubmit={handleSelfFormReady}
              onCancel={() => { setMode('read'); setApiError(''); }}
              submitting={submitting}
              noticePeriodDays={noticePeriodDays}
            />
          ) : (
            <TerminationHRForm
              onSubmit={handleFormReady}
              onCancel={() => { setMode('read'); setApiError(''); }}
              submitting={submitting}
              noticePeriodDays={noticePeriodDays}
            />
          )}
        </div>
      )}

      {/* ── REVERSAL FORM ──────────────────────────────────────────────────── */}
      {mode === 'reversal' && termination && (
        <div style={{ background: '#F9FAFB', borderRadius: 8, border: '1px solid #E5E7EB', padding: 16 }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: '#7C3AED', marginBottom: 14 }}>
            <i className="fa-solid fa-rotate-left" style={{ marginRight: 6 }} />Reverse Termination
          </div>
          <TerminationReversalForm
            originalTerminationDate={termination.separation_date}
            onSubmit={handleReversalSubmit}
            onCancel={() => { setMode('read'); setApiError(''); }}
            submitting={submitting}
          />
        </div>
      )}

      {/* ── IMPACT MODAL (HR path) ─────────────────────────────────────────── */}
      {showImpact && (
        <TerminationImpactModal
          employeeId={employeeId}
          employeeName={employeeName}
          onConfirm={handleImpactConfirm}
          onCancel={() => setShowImpact(false)}
        />
      )}

      {/* ── CONFIRM DIALOG ─────────────────────────────────────────────────── */}
      {showConfirm && formData && (
        <TerminationConfirmDialog
          isSelf={isSelfService}
          terminationDate={formData.separation_date}
          employeeName={employeeName}
          subjectEmployeeId={isSelfService ? null : employeeId}
          onConfirm={handleConfirmedSubmit}
          onCancel={() => { setShowConfirm(false); setSubmitError(null); }}
          submitting={submitting}
          submitError={submitError}
        />
      )}

      {/* ── WORKFLOW PARTICIPANTS MODAL ────────────────────────────────────── */}
      <WorkflowParticipantsModal
        open={participantsOpen}
        onClose={() => setParticipantsOpen(false)}
        instanceId={termination?.workflow_instance_id ?? null}
        title="Termination Approval Progress"
      />
      <WorkflowParticipantsModal
        open={reversalParticipantsOpen}
        onClose={() => setReversalParticipantsOpen(false)}
        instanceId={reversal?.workflow_instance_id ?? null}
        title="Reversal Approval Progress"
      />

      {/* ── WITHDRAW CONFIRMATION ──────────────────────────────────────────── */}
      <ConfirmationModal
        isOpen={showWithdrawConfirm}
        title="Withdraw Termination"
        message="Withdraw this termination submission? The request will be cancelled and can be resubmitted."
        confirmText="Withdraw"
        cancelText="Cancel"
        destructive={false}
        loading={withdrawLoading}
        warning={withdrawError ?? undefined}
        onConfirm={handleWithdraw}
        onCancel={() => { setShowWithdrawConfirm(false); setWithdrawError(null); }}
      />

      {/* ── DELETE CONFIRMATION ────────────────────────────────────────────── */}
      <ConfirmationModal
        isOpen={showDeleteConfirm}
        title="Delete Termination Record"
        message="Permanently delete this termination record? This action cannot be undone."
        confirmText="Delete"
        cancelText="Cancel"
        destructive={true}
        loading={deleteLoading}
        warning={deleteError ?? undefined}
        onConfirm={handleDeleteTermination}
        onCancel={() => { setShowDeleteConfirm(false); setDeleteError(null); }}
      />

      {/* ── WITHDRAW REVERSAL CONFIRMATION ─────────────────────────────────── */}
      <ConfirmationModal
        isOpen={showWithdrawReversalConfirm}
        title="Withdraw Reversal"
        message="Withdraw this pending reversal? You can submit a new reversal afterwards."
        confirmText="Withdraw"
        cancelText="Cancel"
        destructive={false}
        loading={withdrawReversalLoading}
        warning={withdrawReversalError ?? undefined}
        onConfirm={handleWithdrawReversal}
        onCancel={() => { setShowWithdrawReversalConfirm(false); setWithdrawReversalError(null); }}
      />
    </div>
  );
}
