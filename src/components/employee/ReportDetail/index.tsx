import { useState, useMemo, useRef } from 'react';
import { useParams, useNavigate, useSearchParams } from 'react-router-dom';
import { useExpenseData } from '../../../hooks/useExpenseData';
import { useCurrenciesLookup } from '../../../hooks/useCurrencies';
import { useExchangeRates } from '../../../hooks/useExchangeRates';
import { usePicklistValues } from '../../../hooks/usePicklistValues';
import { useProjects, useProjectsLookup } from '../../../hooks/useProjects';
import { usePermissions } from '../../../hooks/usePermissions';
import { useWorkflowInstance } from '../../../workflow/hooks/useWorkflowInstance';
import type { LineItem, Attachment } from '../../../types';
import { fmtAmount, lookupRate } from '../../../utils/currency';
import { fmtDate } from '../../../utils/dates';
import StatusBadge from '../../shared/StatusBadge';
import ApprovalFlow from '../../shared/ApprovalFlow';
import { WorkflowTimeline } from '../../../workflow/components/WorkflowTimeline';
import AttachmentModal from './AttachmentModal';

const ATT_ALLOWED = ['application/pdf', 'image/jpeg', 'image/png'];
const ATT_MAX     = 5 * 1024 * 1024;

function attFileIcon(type: string) {
  if (type === 'application/pdf') return 'fa-file-pdf';
  if (type.startsWith('image/'))  return 'fa-file-image';
  return 'fa-file';
}
function attFmtSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

const NOTE_REQUIRED_ABOVE = 10000;

export default function ReportDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { getReport, loading: reportLoading, updateReport, addLineItem, updateLineItem, deleteLineItem, submitReport, recallReport, addAttachment, deleteAttachment, syncReportLineItems } = useExpenseData();
  const { rates: exchangeRates } = useExchangeRates();
  const { picklistValues } = usePicklistValues(true);
  const { projects: rawProjects } = useProjectsLookup();
  const { currencies } = useCurrenciesLookup();

  const [searchParams] = useSearchParams();
  const resumeInstanceId = searchParams.get('resume_instance');

  const { can } = usePermissions();
  const report = getReport(id!);

  // ── Workflow instance for this report ────────────────────────────
  const wf = useWorkflowInstance('expense_reports', id ?? null);

  const [showWithdrawConfirm, setShowWithdrawConfirm] = useState(false);
  const [withdrawReason, setWithdrawReason]           = useState('');
  const [withdrawing, setWithdrawing]                 = useState(false);
  const [resubmitResponse, setResubmitResponse]       = useState('');
  const [resubmitting, setResubmitting]               = useState(false);
  const [draftSaving, setDraftSaving]                 = useState(false);
  const [draftSavedMsg, setDraftSavedMsg]             = useState<string | null>(null);
  const [attItemId, setAttItemId] = useState<string | null>(null);
  const [editItem, setEditItem] = useState<LineItem | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [showSubmitConfirm, setShowSubmitConfirm] = useState(false);
  const [pendingDeleteItem, setPendingDeleteItem] = useState<string | null>(null);

  // Form state
  const [form, setForm] = useState<Partial<LineItem>>({});
  const [rateError, setRateError] = useState('');
  const [formErrors, setFormErrors] = useState<Record<string, string>>({});
  const [dupWarning, setDupWarning] = useState(false);
  const [attError, setAttError] = useState('');
  const [showAttWarning, setShowAttWarning] = useState(false);
  const [_pendingSave, setPendingSave] = useState(false);
  const [warnFiles, setWarnFiles] = useState<Attachment[]>([]);
  // Stores the original File objects keyed by Attachment.id — needed for actual storage upload
  const [warnRawFiles, setWarnRawFiles] = useState<Map<string, File>>(new Map());
  const [warnDragging, setWarnDragging] = useState(false);
  const [warnAttError, setWarnAttError] = useState('');
  const formFileRef = useRef<HTMLInputElement>(null);
  const warnFileRef = useRef<HTMLInputElement>(null);

  const today = new Date().toISOString().slice(0, 10);

  // ── Dropdown data ───────────────────────────────────────────────
  const categories = useMemo(() =>
    picklistValues.filter((v: any) => v.picklistId === 'Expense_Category' && v.active !== false)
      .sort((a: any, b: any) => a.value.localeCompare(b.value)),
    [picklistValues]
  );

  const currencyOptions = useMemo(() =>
    currencies.map(c => ({
      code:  c.code,
      label: `${c.code} \u2013 ${c.name} (${c.symbol})`,
    })),
    [currencies]
  );

  const availableProjects = useMemo(() => {
    if (!form.date) return rawProjects;
    return rawProjects.filter((p: any) =>
      form.date! >= (p.startDate || '') && form.date! <= (p.endDate || '9999-12-31')
    );
  }, [rawProjects, form.date]);

  if (reportLoading) return (
    <div className="auth-loading">
      <i className="fa-solid fa-spinner fa-spin" />
      <span>Loading report…</span>
    </div>
  );

  if (!report) return (
    <div style={{ padding: 40, color: '#64748b' }}>
      Report not found. <button onClick={() => navigate('/expense')}>Back</button>
    </div>
  );

  // editable: show add/edit/delete controls for line items and attachments.
  // awaiting_clarification lives on workflow_instances.status (not expense_reports.status
  // which stays 'submitted'), so we read it from the already-loaded wf.instance.
  const isAwaitingClarification = wf.instance?.status === 'awaiting_clarification';
  const editable  = (
    report.status === 'draft' ||
    report.status === 'rejected' ||
    isAwaitingClarification
  ) && can('expense_reports.edit');

  // canSubmit: only for draft/rejected — awaiting_clarification uses Respond & Resubmit
  // !wf.loading guard prevents the button flashing enabled before workflow data arrives
  const canSubmit = !wf.loading
    && (report.status === 'draft' || report.status === 'rejected')
    && can('expense_reports.edit');
  const total = report.lineItems.reduce((s, li) => s + (li.convertedAmount || 0), 0);
  const attItem = attItemId ? report.lineItems.find(li => li.id === attItemId) ?? null : null;

  // ── Form helpers ────────────────────────────────────────────────
  function openForm(item?: LineItem) {
    if (item) {
      setEditItem(item);
      setForm({ ...item });
    } else {
      setEditItem(null);
      setForm({ currencyCode: report!.baseCurrencyCode, date: today });
    }
    setRateError('');
    setFormErrors({});
    setDupWarning(false);
    setShowForm(true);
  }

  function closeForm() {
    setShowForm(false);
    setEditItem(null);
    setForm({});
    setRateError('');
    setFormErrors({});
    setDupWarning(false);
    setAttError('');
    setWarnFiles([]);
    setWarnRawFiles(new Map());
    setWarnAttError('');
    setWarnDragging(false);
    // Reconcile local state with DB — catches any optimistic items that failed
    // to persist (e.g. RLS block) but whose local-state rollback didn't fire.
    if (report) syncReportLineItems(report.id);
  }

  function handleFormFiles(files: FileList | File[]) {
    setAttError('');
    Array.from(files).forEach(f => {
      if (!ATT_ALLOWED.includes(f.type)) { setAttError('Only PDF, JPG, PNG files are allowed.'); return; }
      if (f.size > ATT_MAX) { setAttError('File exceeds 5 MB limit.'); return; }
      const reader = new FileReader();
      reader.onload = ev => {
        const att: Attachment = {
          id: `att_${Date.now()}_${Math.random().toString(36).slice(2)}`,
          name: f.name, type: f.type, size: f.size,
          dataUrl: ev.target!.result as string,
        };
        setForm(prev => ({ ...prev, attachments: [...(prev.attachments ?? []), att] }));
      };
      reader.readAsDataURL(f);
    });
  }

  function removeFormAttachment(attId: string) {
    setForm(prev => ({ ...prev, attachments: (prev.attachments ?? []).filter(a => a.id !== attId) }));
  }

  function handleWarnFiles(files: FileList | File[]) {
    setWarnAttError('');
    Array.from(files).forEach(f => {
      if (!ATT_ALLOWED.includes(f.type)) { setWarnAttError('Only PDF, JPG, PNG files are allowed.'); return; }
      if (f.size > ATT_MAX) { setWarnAttError('File exceeds 5 MB limit.'); return; }
      const attId = `att_${Date.now()}_${Math.random().toString(36).slice(2)}`;
      // Keep the raw File reference so we can actually upload it later
      setWarnRawFiles(prev => new Map(prev).set(attId, f));
      const reader = new FileReader();
      reader.onload = ev => {
        const att: Attachment = {
          id: attId,
          name: f.name, type: f.type, size: f.size,
          dataUrl: ev.target!.result as string,
        };
        setWarnFiles(prev => [...prev, att]);
      };
      reader.readAsDataURL(f);
    });
  }

  function commitWithWarnFiles() {
    // Capture pending files before clearing state
    const rawFiles = new Map(warnRawFiles);
    setWarnFiles([]);
    setWarnRawFiles(new Map());
    setShowAttWarning(false);
    setPendingSave(false);

    // All values are read directly from `form` — no setForm callback needed.
    // Putting side-effects (addLineItem) inside a setState callback causes
    // React Strict Mode to double-invoke the updater, creating duplicate records.
    const isDuplicate = report!.lineItems.some(li =>
      li.id !== editItem?.id &&
      li.date === form.date &&
      li.category === form.category &&
      li.amount === form.amount
    );
    const exchangeRate = form.currencyCode === report!.baseCurrencyCode ? 1 : (form.exchangeRate || 1);
    const converted    = (form.amount || 0) * exchangeRate;
    const catEntry  = categories.find((c: any) => String(c.id) === String(form.category));
    const projEntry = rawProjects.find((p: any) => String(p.id) === String(form.projectId));

    // Upload each file to storage after the line item row exists
    const uploadFiles = async (targetItemId: string) => {
      for (const [, file] of rawFiles) {
        try {
          await addAttachment(report!.id, targetItemId, file);
        } catch (err: any) {
          setFormErrors(fe => ({ ...fe, _save: `Attachment upload failed: ${err.message}` }));
        }
      }
    };

    if (editItem) {
      updateLineItem(report!.id, editItem.id, {
        ...form,
        categoryName: catEntry ? catEntry.value : form.categoryName,
        projectName:  projEntry ? projEntry.name : form.projectName,
        exchangeRate, convertedAmount: converted,
      } as Partial<LineItem>);
      uploadFiles(editItem.id);
      setDupWarning(isDuplicate);
      if (!isDuplicate) closeForm();
    } else {
      const newItemId = crypto.randomUUID();
      addLineItem(report!.id, {
        id:              newItemId,
        category:        form.category!,
        categoryName:    catEntry ? catEntry.value : form.category,
        date:            form.date!,
        projectId:       form.projectId,
        projectName:     projEntry ? projEntry.name : undefined,
        amount:          form.amount!,
        currencyCode:    form.currencyCode!,
        exchangeRate,
        convertedAmount: converted,
        note:            form.note,
        attachments:     [],
      }).then(async () => {
        await uploadFiles(newItemId);
        setDupWarning(isDuplicate);
        if (!isDuplicate) closeForm();
      }).catch(err => setFormErrors(fe => ({ ...fe, _save: err.message })));
    }
  }

  // Auto-fill rate — accepts explicit values since setState is async
  function doAutoFill(currencyCode: string, date: string) {
    const base = report!.baseCurrencyCode;
    if (!currencyCode || !date) return;
    if (currencyCode === base) {
      setForm(f => ({ ...f, exchangeRate: 1 }));
      setRateError('');
      return;
    }
    const rate = lookupRate(exchangeRates, currencyCode, base, date);
    if (rate) {
      setForm(f => ({ ...f, exchangeRate: rate }));
      setRateError('');
    } else {
      setForm(f => ({ ...f, exchangeRate: undefined }));
      setRateError(`No rate found for ${currencyCode} → ${base} on ${date}`);
    }
  }

  // Computed converted amount for live preview
  const convertedPreview = (() => {
    const amt  = form.amount ?? 0;
    const rate = form.currencyCode === report.baseCurrencyCode ? 1 : (form.exchangeRate ?? 0);
    if (amt > 0 && rate > 0) return (amt * rate).toFixed(2);
    return '';
  })();

  function commitSave() {
    const isDuplicate = report!.lineItems.some(li =>
      li.id !== editItem?.id &&
      li.date === form.date &&
      li.category === form.category &&
      li.amount === form.amount
    );
    setDupWarning(isDuplicate);

    const exchangeRate = form.currencyCode === report!.baseCurrencyCode ? 1 : (form.exchangeRate || 1);
    const converted    = (form.amount || 0) * exchangeRate;
    const catEntry  = categories.find((c: any) => String(c.id) === String(form.category));
    const projEntry = rawProjects.find((p: any) => String(p.id) === String(form.projectId));

    if (editItem) {
      updateLineItem(report!.id, editItem.id, {
        ...form,
        categoryName: catEntry ? catEntry.value : form.categoryName,
        projectName:  projEntry ? projEntry.name : form.projectName,
        exchangeRate,
        convertedAmount: converted,
      } as Partial<LineItem>);
      if (!isDuplicate) closeForm();
    } else {
      const item: LineItem = {
        id:              crypto.randomUUID(),
        category:        form.category!,
        categoryName:    catEntry ? catEntry.value : form.category,
        date:            form.date!,
        projectId:       form.projectId,
        projectName:     projEntry ? projEntry.name : undefined,
        amount:          form.amount!,
        currencyCode:    form.currencyCode!,
        exchangeRate,
        convertedAmount: converted,
        note:            form.note,
        attachments:     form.attachments ?? [],
      };
      addLineItem(report!.id, item)
        .then(() => { if (!isDuplicate) closeForm(); })
        .catch(err => setFormErrors(fe => ({ ...fe, _save: err.message })));
      return; // closeForm handled in .then()
    }
  }

  function saveItem() {
    const errors: Record<string, string> = {};

    if (!form.category)
      errors.category = 'Category is required.';

    if (!form.date)
      errors.date = 'Expense date is required.';
    else if (form.date > today)
      errors.date = 'Expense date cannot be in the future.';

    if (!form.currencyCode)
      errors.currencyCode = 'Currency is required.';

    if (form.amount == null || isNaN(form.amount))
      errors.amount = 'Amount is required.';
    else if (form.amount <= 0)
      errors.amount = 'Amount must be greater than zero.';

    if (form.currencyCode && form.currencyCode !== report!.baseCurrencyCode) {
      if (!form.exchangeRate || form.exchangeRate <= 0)
        errors.exchangeRate = `Exchange rate required when currency differs from ${report!.baseCurrencyCode}.`;
    }

    if ((form.amount ?? 0) > NOTE_REQUIRED_ABOVE && !form.note?.trim())
      errors.note = `A note is required for expenses over ${NOTE_REQUIRED_ABOVE.toLocaleString()}.`;

    setFormErrors(errors);
    if (Object.keys(errors).length > 0) return;

    // Soft-warn if no attachment
    if ((form.attachments ?? []).length === 0) {
      setPendingSave(true);
      setShowAttWarning(true);
      return;
    }

    commitSave();
  }

  // ── Banners ─────────────────────────────────────────────────────
  const canWithdraw = report.status === 'submitted' && can('expense_reports.edit') && wf.instance?.status === 'in_progress';

  // ── Status badge label — reflects workflow state, not just report.status ──
  // expense_reports.status stays "submitted" throughout the approval chain,
  // so we override the badge text to show the real workflow position.
  const wfStatusLabel: string | undefined = (() => {
    if (report.status !== 'submitted') return undefined; // draft / approved / rejected speak for themselves
    switch (wf.instance?.status) {
      case 'in_progress':            return 'In Review';
      case 'awaiting_clarification': return 'Action Required';
      case 'approved':               return 'Approved';
      case 'rejected':               return 'Rejected';
      case 'withdrawn':              return 'Withdrawn';
      default:                       return undefined; // no instance yet — fall back to "Submitted"
    }
  })();

  const bannerCls: Record<string, string> = {
    draft:            'exp-status-banner--draft',
    submitted:        'exp-status-banner--submitted',
    manager_approved: 'exp-status-banner--submitted',
    approved:         'exp-status-banner--approved',
    rejected:         'exp-status-banner--rejected',
  };
  const bannerMsg: Record<string, string> = {
    draft:            `This report is in <strong>Draft</strong>. You can add or edit line items. Submit when ready.`,
    submitted:        `This report is <strong>In Review</strong> — awaiting approval from your approvers.`,
    manager_approved: `This report is <strong>In Review</strong> — awaiting final approval.`,
    approved:         `This report has been fully <strong>Approved</strong>.`,
    rejected:         `This report has been <strong>Rejected</strong>. Please review the feedback and resubmit.`,
  };

  async function handleWithdraw() {
    if (!report) return;
    setWithdrawing(true);
    try {
      await recallReport(report.id, withdrawReason.trim() || undefined);
      setShowWithdrawConfirm(false);
      setWithdrawReason('');
      wf.refresh();
    } catch (e) {
      // error surfaced by recallReport
    } finally {
      setWithdrawing(false);
    }
  }

  async function handleResubmit() {
    if (!wf.instance) return;
    setResubmitting(true);
    try {
      await wf.resubmit(resubmitResponse.trim() || undefined);
      setResubmitResponse('');
      // If we arrived here via the Update flow (sent-back tab), go back there
      if (resumeInstanceId) {
        navigate('/workflow/inbox?tab=sent_back');
      }
    } catch (e) {
      // error surfaced by resubmit
    } finally {
      setResubmitting(false);
    }
  }

  // ── Derive send-back context ─────────────────────────────────────
  // Find the most recent clarification_requested event so we can show
  // the approver's message in the Action Required banner.
  const sendBackEvent = wf.instance?.status === 'awaiting_clarification'
    ? [...wf.history].reverse().find(h => h.action === 'returned_to_initiator')
    : undefined;

  return (
    <div className="exp-detail-wrap">

      {/* ── Object Header ──────────────────────────────────────────── */}
      <div className="exp-report-header">
        <div className="exp-obj-row-title">
          <div className="exp-obj-title-area">
            <button className="exp-btn-back" onClick={() => navigate('/expense')}>
              <i className="fa-solid fa-arrow-left" />
            </button>
            <div className="exp-report-name-wrap">
              <span className="exp-report-label">Expense Report</span>
              <input
                className={`exp-report-name-input${!editable ? ' exp-readonly' : ''}`}
                value={report.name}
                readOnly={!editable}
                onChange={e => updateReport(report!.id, { name: e.target.value })}
                placeholder="Report Name"
              />
            </div>
          </div>
          <div className="exp-obj-right-panel">
            <StatusBadge status={report.status} label={wfStatusLabel} />
            <ApprovalFlow instance={wf.instance} tasks={wf.tasks} />
          </div>
        </div>

        <div className="exp-obj-row-attrs">
          <div className="exp-obj-attr">
            <span className="exp-obj-attr-label">Submitted</span>
            <span className="exp-obj-attr-value">{fmtDate(report.submittedAt)}</span>
          </div>
          <div className="exp-obj-attr">
            <span className="exp-obj-attr-label">Approved</span>
            <span className="exp-obj-attr-value">{fmtDate(report.approvedAt)}</span>
          </div>
          <div className="exp-obj-attr">
            <span className="exp-obj-attr-label">Base Currency</span>
            <span className="exp-obj-attr-value"><span className="er-currency-badge">{report.baseCurrencyCode}</span></span>
          </div>
          <div className="exp-obj-attr">
            <span className="exp-obj-attr-label">Approved By</span>
            <span className="exp-obj-attr-value">{report.approvedBy ?? '—'}</span>
          </div>
        </div>
      </div>

      <div className="exp-detail-body">

        {/* ── Status Banner / Send-Back Callout ─────────────────── */}
        {wf.instance?.status === 'awaiting_clarification' ? (
          <div style={{
            border: '1.5px solid #F59E0B', borderRadius: 10, background: '#FFFBEB',
            padding: '16px 20px', display: 'flex', flexDirection: 'column', gap: 12,
          }}>
            {/* Header */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <i className="fa-solid fa-triangle-exclamation" style={{ color: '#D97706', fontSize: 16 }} />
              <span style={{ fontWeight: 700, fontSize: 14, color: '#92400E' }}>
                Action Required — Approver has requested clarification
              </span>
            </div>

            {/* Approver's message */}
            {sendBackEvent?.notes && (
              <div style={{
                background: '#FEF3C7', border: '1px solid #FDE68A', borderRadius: 7,
                padding: '10px 14px', fontSize: 13, color: '#78350F', lineHeight: 1.5,
              }}>
                <span style={{ fontWeight: 600, display: 'block', marginBottom: 4, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', color: '#B45309' }}>
                  {sendBackEvent.actorName ?? 'Approver'} says:
                </span>
                {sendBackEvent.notes}
              </div>
            )}

            {/* Response area */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <label style={{ fontSize: 12, fontWeight: 600, color: '#92400E' }}>
                Your response
              </label>
              <textarea
                rows={3}
                value={resubmitResponse}
                onChange={e => setResubmitResponse(e.target.value)}
                placeholder="Explain your clarification or attach any missing documents above, then respond…"
                disabled={resubmitting}
                style={{
                  width: '100%', padding: '9px 12px', borderRadius: 7, resize: 'vertical',
                  border: '1px solid #FCD34D', background: '#FFFDF0', fontSize: 13,
                  fontFamily: 'inherit', outline: 'none', boxSizing: 'border-box',
                  opacity: resubmitting ? 0.6 : 1,
                }}
              />
            </div>

            {/* Respond button */}
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 6 }}>
              {showForm && (
                <span style={{ fontSize: 12, color: '#B45309' }}>
                  <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 5 }} />
                  Save or cancel the open line item before resubmitting.
                </span>
              )}
              <button
                onClick={handleResubmit}
                disabled={resubmitting || showForm}
                style={{
                  padding: '9px 20px', borderRadius: 7, border: 'none',
                  background: (resubmitting || showForm) ? '#D97706' : '#F59E0B',
                  color: '#fff', fontWeight: 700, fontSize: 13,
                  cursor: (resubmitting || showForm) ? 'not-allowed' : 'pointer',
                  display: 'flex', alignItems: 'center', gap: 7,
                  opacity: (resubmitting || showForm) ? 0.5 : 1,
                }}
              >
                <i className="fa-solid fa-paper-plane" style={{ fontSize: 12 }} />
                {resubmitting ? 'Sending…' : 'Respond & Resubmit'}
              </button>
            </div>
          </div>
        ) : (
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div
              className={`exp-status-banner ${bannerCls[report.status] ?? 'exp-status-banner--draft'}`}
              style={{ flex: 1, margin: 0 }}
              dangerouslySetInnerHTML={{ __html: `<i class="fa-solid fa-circle-info"></i> ${bannerMsg[report.status] ?? ''}` }}
            />
            {canWithdraw && (
              <button
                onClick={() => setShowWithdrawConfirm(true)}
                style={{
                  flexShrink: 0, padding: '7px 14px', borderRadius: 6,
                  border: '1px solid #FCA5A5', background: '#FEF2F2',
                  fontSize: 12, fontWeight: 600, color: '#DC2626', cursor: 'pointer',
                  display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap',
                }}
              >
                <i className="fa-solid fa-rotate-left" style={{ fontSize: 11 }} />
                Withdraw
              </button>
            )}
          </div>
        )}

        {/* ── Workflow Timeline ────────────────────────────────── */}
        {wf.instance && (
          <WorkflowTimeline
            history={wf.history}
            tasks={wf.tasks}
            currentStep={wf.instance.currentStep ?? 1}
            status={wf.instance.status}
          />
        )}

        {/* ── Line Items Section ────────────────────────────────── */}
        <div className="exp-line-items-section">
          <div className="exp-line-items-header">
            <span className="exp-section-title">
              <i className="fa-solid fa-list-check" /> Expense Line Items
            </span>
            {editable && !showForm && (
              <button className="exp-btn-add-item" onClick={() => openForm()}>
                <i className="fa-solid fa-plus" /> Add Expense
              </button>
            )}
          </div>

          {/* ── Inline Add/Edit Form ───────────────────────────── */}
          {showForm && (
            <div className="exp-item-form-wrap">
              <div className="exp-item-form">

                {/* Duplicate warning — non-blocking */}
                {dupWarning && (
                  <div className="exp-dup-warning" style={{ display: 'flex', marginBottom: 12 }}>
                    <i className="fa-solid fa-triangle-exclamation" />
                    <span>Possible duplicate — a similar expense with the same date, category, and amount already exists.</span>
                  </div>
                )}

                <div className="exp-item-form-grid">

                  {/* Category */}
                  <div className={`form-group${formErrors.category ? ' form-group--error' : ''}`}>
                    <label htmlFor="fi-category">Category <span style={{ color: '#e53e3e' }}>*</span></label>
                    <select
                      id="fi-category"
                      value={form.category || ''}
                      onChange={e => {
                        setForm(f => ({ ...f, category: e.target.value }));
                        setFormErrors(fe => ({ ...fe, category: '' }));
                      }}
                    >
                      <option value="">-- Select --</option>
                      {categories.map((c: any) => (
                        <option key={c.id} value={String(c.id)}>{c.value}</option>
                      ))}
                    </select>
                    {formErrors.category && <span className="exp-field-error">{formErrors.category}</span>}
                  </div>

                  {/* Date */}
                  <div className={`form-group${formErrors.date ? ' form-group--error' : ''}`}>
                    <label htmlFor="fi-date">Date <span style={{ color: '#e53e3e' }}>*</span></label>
                    <input
                      id="fi-date"
                      type="date"
                      max={today}
                      value={form.date || ''}
                      onChange={e => {
                        const date = e.target.value;
                        setForm(f => ({ ...f, date }));
                        setFormErrors(fe => ({ ...fe, date: '' }));
                        if (form.currencyCode) doAutoFill(form.currencyCode, date);
                      }}
                    />
                    {formErrors.date && <span className="exp-field-error">{formErrors.date}</span>}
                  </div>

                  {/* Project */}
                  <div className="form-group">
                    <label htmlFor="fi-project">Project</label>
                    <select
                      id="fi-project"
                      value={form.projectId || ''}
                      onChange={e => setForm(f => ({ ...f, projectId: e.target.value || undefined }))}
                    >
                      <option value="">-- None --</option>
                      {availableProjects.map((p: any) => (
                        <option key={p.id} value={String(p.id)}>{p.name}</option>
                      ))}
                    </select>
                  </div>

                  {/* Currency */}
                  <div className={`form-group${formErrors.currencyCode ? ' form-group--error' : ''}`}>
                    <label htmlFor="fi-currency">Currency <span style={{ color: '#e53e3e' }}>*</span></label>
                    <select
                      id="fi-currency"
                      value={form.currencyCode || report.baseCurrencyCode}
                      onChange={e => {
                        const code = e.target.value;
                        setForm(f => ({ ...f, currencyCode: code }));
                        setFormErrors(fe => ({ ...fe, currencyCode: '', exchangeRate: '' }));
                        if (form.date) doAutoFill(code, form.date);
                      }}
                    >
                      <option value="">-- Select --</option>
                      {currencyOptions.map(c => (
                        <option key={c.code} value={c.code}>{c.label}</option>
                      ))}
                    </select>
                    {formErrors.currencyCode && <span className="exp-field-error">{formErrors.currencyCode}</span>}
                  </div>

                  {/* Amount */}
                  <div className={`form-group${formErrors.amount ? ' form-group--error' : ''}`}>
                    <label htmlFor="fi-amount">Amount <span style={{ color: '#e53e3e' }}>*</span></label>
                    <input
                      id="fi-amount"
                      type="number"
                      placeholder="e.g. 500"
                      min="0.01"
                      step="any"
                      value={form.amount ?? ''}
                      onChange={e => {
                        setForm(f => ({ ...f, amount: e.target.value === '' ? undefined : parseFloat(e.target.value) }));
                        setFormErrors(fe => ({ ...fe, amount: '' }));
                      }}
                    />
                    {formErrors.amount && <span className="exp-field-error">{formErrors.amount}</span>}
                  </div>

                  {/* Exchange Rate */}
                  <div className={`form-group exp-rate-group${formErrors.exchangeRate ? ' form-group--error' : ''}`}>
                    <label htmlFor="fi-rate">
                      Exchange Rate
                      <span className="exp-rate-hint">
                        {form.currencyCode && form.currencyCode !== report.baseCurrencyCode
                          ? ` (${form.currencyCode} → ${report.baseCurrencyCode})`
                          : ''}
                      </span>
                    </label>
                    <input
                      id="fi-rate"
                      type="number"
                      className="exp-rate-input"
                      placeholder="Auto-filled"
                      readOnly
                      value={form.currencyCode === report.baseCurrencyCode ? 1 : (form.exchangeRate ?? '')}
                    />
                    {rateError && <div className="exp-rate-error">{rateError}</div>}
                    {formErrors.exchangeRate && <span className="exp-field-error">{formErrors.exchangeRate}</span>}
                  </div>

                  {/* Converted (Base) */}
                  <div className="form-group">
                    <label htmlFor="fi-converted">
                      Converted to {report.baseCurrencyCode} <span className="exp-base-tag">(Base)</span>
                    </label>
                    <input
                      id="fi-converted"
                      type="number"
                      className="exp-rate-input"
                      placeholder="Auto-calculated"
                      readOnly
                      value={convertedPreview}
                    />
                  </div>

                  {/* Note — spans 2 columns */}
                  <div className={`form-group exp-note-group${formErrors.note ? ' form-group--error' : ''}`}>
                    <label htmlFor="fi-note">
                      Note
                      {(form.amount ?? 0) > NOTE_REQUIRED_ABOVE &&
                        <span style={{ color: '#e53e3e', fontSize: 11, marginLeft: 6 }}>required for this amount</span>}
                    </label>
                    <input
                      id="fi-note"
                      type="text"
                      placeholder="Optional note"
                      value={form.note || ''}
                      onChange={e => {
                        setForm(f => ({ ...f, note: e.target.value }));
                        setFormErrors(fe => ({ ...fe, note: '' }));
                      }}
                    />
                    {formErrors.note && <span className="exp-field-error">{formErrors.note}</span>}
                  </div>

                  {/* Attachment */}
                  <div className="form-group exp-att-form-group">
                    <label><i className="fa-solid fa-paperclip" style={{ marginRight: 5 }} />Attachment</label>
                    <div className="exp-att-form-row">
                      <button
                        type="button"
                        className="exp-att-form-upload-btn"
                        onClick={() => formFileRef.current?.click()}
                      >
                        <i className="fa-solid fa-cloud-arrow-up" /> Upload File
                      </button>
                      <span className="exp-att-form-hint">PDF, JPG, PNG · max 5 MB</span>
                      <input
                        ref={formFileRef}
                        type="file"
                        accept=".pdf,.jpg,.jpeg,.png"
                        multiple
                        hidden
                        onChange={e => e.target.files && handleFormFiles(e.target.files)}
                      />
                    </div>
                    {attError && <span className="exp-field-error">{attError}</span>}
                    {(form.attachments ?? []).length > 0 && (
                      <div className="exp-att-form-list">
                        {(form.attachments ?? []).map(a => (
                          <div key={a.id} className="exp-att-form-item">
                            <i className={`fa-solid ${attFileIcon(a.type)} exp-att-form-icon`} />
                            <span className="exp-att-form-name">{a.name}</span>
                            <span className="exp-att-form-size">{attFmtSize(a.size)}</span>
                            <button
                              type="button"
                              className="exp-att-form-remove"
                              title="Remove"
                              onClick={() => removeFormAttachment(a.id)}
                            >
                              <i className="fa-solid fa-xmark" />
                            </button>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>

                </div>{/* /.exp-item-form-grid */}

                {formErrors._save && (
                  <div className="login-error" style={{ marginBottom: 8 }}>
                    <i className="fa-solid fa-circle-exclamation" /> {formErrors._save}
                  </div>
                )}

                <div className="exp-item-form-actions">
                  <button className="exp-btn-save-item" onClick={saveItem}>
                    <i className="fa-solid fa-floppy-disk" /> Save
                  </button>
                  <button className="exp-btn-cancel-item" onClick={closeForm}>Cancel</button>
                  {dupWarning && (
                    <button
                      className="exp-btn-save-item"
                      style={{ marginLeft: 'auto', background: '#b45309' }}
                      onClick={() => { setDupWarning(false); closeForm(); }}
                    >
                      Save Anyway
                    </button>
                  )}
                </div>

              </div>
            </div>
          )}

          {/* ── Line Items Table ───────────────────────────────── */}
          <div className="exp-items-table-wrap">
            <table className="exp-items-table">
              <thead>
                <tr>
                  <th>#</th><th>Category</th><th>Date</th><th>Project</th>
                  <th>Amount</th><th>Rate</th><th>Converted ({report.baseCurrencyCode})</th>
                  <th>Note</th><th>Attachment</th><th>Action</th>
                </tr>
              </thead>
              <tbody>
                {report.lineItems.length === 0 ? (
                  <tr>
                    <td colSpan={10} className="exp-items-empty-state">
                      <div className="exp-items-empty-icon"><i className="fa-solid fa-receipt" /></div>
                      <p className="exp-items-empty-msg">
                        No expenses yet.{editable && <><br />Add your first expense to get started.</>}
                      </p>
                      {editable && !showForm && (
                        <button className="exp-items-empty-cta" onClick={() => openForm()}>
                          <i className="fa-solid fa-plus" /> Add Expense
                        </button>
                      )}
                    </td>
                  </tr>
                ) : report.lineItems.map((li, i) => (
                  <tr key={li.id}>
                    <td>{i + 1}</td>
                    <td>{li.categoryName || li.category}</td>
                    <td>{fmtDate(li.date)}</td>
                    <td>{li.projectName || (li.projectId ? `#${li.projectId}` : '—')}</td>
                    <td>{fmtAmount(li.amount, li.currencyCode)}</td>
                    <td>{li.currencyCode !== report.baseCurrencyCode ? li.exchangeRate?.toFixed(4) : '—'}</td>
                    <td><strong>{fmtAmount(li.convertedAmount, report.baseCurrencyCode)}</strong></td>
                    <td>{li.note || '—'}</td>
                    <td className="exp-att-cell">
                      <button
                        className={`exp-att-btn ${(li.attachments?.length ?? 0) > 0 ? 'exp-att-btn--has' : ''}`}
                        onClick={() => setAttItemId(li.id)}
                      >
                        <i className="fa-solid fa-paperclip" />
                        {(li.attachments?.length ?? 0) > 0 && <span className="exp-att-count">{li.attachments!.length}</span>}
                      </button>
                    </td>
                    <td className="exp-item-actions-cell">
                      {editable && (
                        <>
                          <button className="ref-btn-edit exp-item-edit-btn" title="Edit" onClick={() => { closeForm(); openForm(li); }}>
                            <i className="fa-solid fa-pen-to-square" />
                          </button>
                          <button className="ref-btn-delete exp-item-delete-btn" title="Delete" onClick={() => setPendingDeleteItem(li.id)}>
                            <i className="fa-solid fa-trash" />
                          </button>
                        </>
                      )}
                      {!editable && <span style={{ color: '#aaa', fontSize: 12 }}>Locked</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>{/* /.exp-line-items-section */}

        {/* ── Footer ───────────────────────────────────────────── */}
        <div className="exp-report-footer">
          <div className="exp-total-section">
            <span className="exp-total-label">Total</span>
            <span className="exp-total-amount">{report.baseCurrencyCode} {total.toLocaleString('en-IN', { minimumFractionDigits: 2 })}</span>
          </div>
          <div className="exp-footer-actions">
            {editable && !isAwaitingClarification && (
              <button
                className="exp-btn-save-draft"
                disabled={draftSaving}
                onClick={async () => {
                  setDraftSaving(true);
                  try {
                    await updateReport(report.id, { name: report.name });
                    setDraftSavedMsg('Draft saved');
                    setTimeout(() => setDraftSavedMsg(null), 3000);
                  } catch {
                    setDraftSavedMsg('Save failed — please try again');
                    setTimeout(() => setDraftSavedMsg(null), 4000);
                  } finally {
                    setDraftSaving(false);
                  }
                }}
              >
                {draftSaving
                  ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                  : <><i className="fa-solid fa-floppy-disk" /> Save Draft</>}
              </button>
            )}
            {canSubmit && (
              <button className="exp-btn-submit" onClick={() => setShowSubmitConfirm(true)}
                disabled={report.lineItems.length === 0}>
                <i className="fa-solid fa-paper-plane" /> Submit
              </button>
            )}
          </div>
        </div>

      </div>{/* /.exp-detail-body */}

      {/* ── Draft saved toast ────────────────────────────────────────── */}
      {draftSavedMsg && (
        <div style={{
          position: 'fixed', bottom: 28, left: '50%', transform: 'translateX(-50%)',
          zIndex: 9999,
          background: draftSavedMsg.startsWith('Save failed') ? '#FEE2E2' : '#D1FAE5',
          color:      draftSavedMsg.startsWith('Save failed') ? '#991B1B'  : '#065F46',
          border:     `1px solid ${draftSavedMsg.startsWith('Save failed') ? '#FCA5A5' : '#6EE7B7'}`,
          borderRadius: 8, padding: '10px 20px',
          fontSize: 13, fontWeight: 600,
          display: 'flex', alignItems: 'center', gap: 8,
          boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
          pointerEvents: 'none',
        }}>
          <i className={`fa-solid ${draftSavedMsg.startsWith('Save failed') ? 'fa-circle-exclamation' : 'fa-circle-check'}`} />
          {draftSavedMsg}
        </div>
      )}

      {/* ── Withdraw Confirm Modal ───────────────────────────────────── */}
      {showWithdrawConfirm && (
        <div className="exp-modal-overlay exp-modal--open" onClick={() => setShowWithdrawConfirm(false)}>
          <div className="exp-modal-box" onClick={e => e.stopPropagation()}>
            <h3 className="exp-modal-title">
              <i className="fa-solid fa-rotate-left" style={{ color: '#DC2626', marginRight: 8 }} />
              Withdraw Report?
            </h3>
            <p style={{ color: '#64748b', marginBottom: 16 }}>
              This will cancel the approval process and return the report to draft so you can make changes.
            </p>
            <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: '#374151', marginBottom: 6 }}>
              Reason (optional)
            </label>
            <textarea
              value={withdrawReason}
              onChange={e => setWithdrawReason(e.target.value)}
              placeholder="Why are you withdrawing this report?"
              rows={3}
              style={{
                width: '100%', padding: '8px 10px', border: '1px solid #D1D5DB',
                borderRadius: 6, fontSize: 13, resize: 'vertical', outline: 'none',
                fontFamily: 'inherit', boxSizing: 'border-box', marginBottom: 16,
              }}
            />
            <div className="exp-modal-actions">
              <button className="exp-btn-cancel-item" onClick={() => { setShowWithdrawConfirm(false); setWithdrawReason(''); }} disabled={withdrawing}>
                Cancel
              </button>
              <button
                onClick={handleWithdraw}
                disabled={withdrawing}
                style={{
                  padding: '7px 16px', borderRadius: 6, border: 'none',
                  background: '#DC2626', color: '#fff', fontWeight: 600, fontSize: 13,
                  cursor: withdrawing ? 'not-allowed' : 'pointer', opacity: withdrawing ? 0.7 : 1,
                }}
              >
                {withdrawing ? 'Withdrawing…' : 'Confirm Withdraw'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Submit Confirm Modal ──────────────────────────────────── */}
      {showSubmitConfirm && (
        <div className="exp-modal-overlay exp-modal--open" onClick={() => setShowSubmitConfirm(false)}>
          <div className="exp-modal-box" onClick={e => e.stopPropagation()}>
            <h3 className="exp-modal-title"><i className="fa-solid fa-paper-plane" /> Submit Report?</h3>
            <p style={{ color: '#64748b', marginBottom: 24 }}>Once submitted you cannot edit this report unless it is rejected.</p>
            <div className="exp-modal-actions">
              <button className="exp-btn-cancel-item" onClick={() => setShowSubmitConfirm(false)}>Cancel</button>
              <button className="exp-btn-submit" onClick={() => { submitReport(report.id); setShowSubmitConfirm(false); }}>Submit</button>
            </div>
          </div>
        </div>
      )}

      {/* ── Delete Line Item Confirm Modal ────────────────────────── */}
      {pendingDeleteItem && (
        <div className="exp-modal-overlay exp-modal--open" onClick={() => setPendingDeleteItem(null)}>
          <div className="exp-modal-box" onClick={e => e.stopPropagation()}>
            <h3 className="exp-modal-title">Delete Line Item?</h3>
            <p style={{ color: '#64748b', marginBottom: 24 }}>This action cannot be undone.</p>
            <div className="exp-modal-actions">
              <button className="exp-btn-cancel-item" onClick={() => setPendingDeleteItem(null)}>Cancel</button>
              <button className="exp-btn-save-item" style={{ background: '#D32F2F' }}
                onClick={() => { deleteLineItem(report.id, pendingDeleteItem); setPendingDeleteItem(null); }}>
                Delete
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── No-Attachment Advisory Modal ─────────────────────────── */}
      {showAttWarning && (
        <div className="exp-modal-overlay exp-modal--open"
          onClick={() => { setShowAttWarning(false); setPendingSave(false); setWarnFiles([]); setWarnRawFiles(new Map()); setWarnAttError(''); }}>
          <div className="exp-modal-box exp-rwarn-box" onClick={e => e.stopPropagation()}>

            {/* Header */}
            <div className="exp-rwarn-header">
              <div className="exp-rwarn-title-row">
                <i className="fa-solid fa-triangle-exclamation exp-rwarn-title-icon" />
                <span className="exp-rwarn-title">No Receipt Attached</span>
              </div>
              <button className="exp-att-modal-close"
                onClick={() => { setShowAttWarning(false); setPendingSave(false); setWarnFiles([]); setWarnRawFiles(new Map()); setWarnAttError(''); }}>
                <i className="fa-solid fa-xmark" />
              </button>
            </div>

            {/* Body */}
            <p className="exp-rwarn-body">
              Claims without receipts may be delayed or rejected. Attach a receipt for faster approval.
            </p>

            {/* Drop zone */}
            <div
              className={`exp-rwarn-dropzone${warnDragging ? ' exp-rwarn-dropzone--drag' : ''}`}
              onClick={() => warnFileRef.current?.click()}
              onDragOver={e => { e.preventDefault(); setWarnDragging(true); }}
              onDragLeave={() => setWarnDragging(false)}
              onDrop={e => { e.preventDefault(); setWarnDragging(false); handleWarnFiles(e.dataTransfer.files); }}
            >
              <i className="fa-solid fa-cloud-arrow-up exp-rwarn-drop-icon" />
              <span className="exp-rwarn-drop-text">
                Drop receipt here or <u>browse files</u>
              </span>
              <span className="exp-rwarn-drop-hint">PDF, JPG, PNG · max 5 MB</span>
              <input ref={warnFileRef} type="file" accept=".pdf,.jpg,.jpeg,.png" multiple hidden
                onChange={e => e.target.files && handleWarnFiles(e.target.files)} />
            </div>

            {/* Uploaded files in modal */}
            {warnAttError && <div className="exp-att-error" style={{ marginTop: 6 }}>{warnAttError}</div>}
            {warnFiles.length > 0 && (
              <div className="exp-rwarn-file-list">
                {warnFiles.map(a => (
                  <div key={a.id} className="exp-att-form-item">
                    <i className={`fa-solid ${attFileIcon(a.type)} exp-att-form-icon`} />
                    <span className="exp-att-form-name">{a.name}</span>
                    <span className="exp-att-form-size">{attFmtSize(a.size)}</span>
                    <button type="button" className="exp-att-form-remove"
                      onClick={() => {
                        setWarnFiles(prev => prev.filter(f => f.id !== a.id));
                        setWarnRawFiles(prev => { const m = new Map(prev); m.delete(a.id); return m; });
                      }}>
                      <i className="fa-solid fa-xmark" />
                    </button>
                  </div>
                ))}
              </div>
            )}

            {/* Actions */}
            <div className="exp-rwarn-actions">
              <button
                className="exp-btn-save-item exp-rwarn-btn-attach"
                disabled={warnFiles.length === 0}
                onClick={commitWithWarnFiles}
              >
                <i className="fa-solid fa-paperclip" /> Attach &amp; Save
              </button>
              <div className="exp-rwarn-proceed-wrap">
                <button
                  className="exp-rwarn-btn-proceed"
                  onClick={() => { setShowAttWarning(false); setPendingSave(false); setWarnFiles([]); commitSave(); }}
                >
                  Proceed without receipt
                </button>
                <span className="exp-rwarn-risk-hint">
                  <i className="fa-solid fa-circle-exclamation" /> May affect claim approval
                </span>
              </div>
            </div>

          </div>
        </div>
      )}

      {/* ── Attachment Modal ──────────────────────────────────────── */}
      {attItem && (
        <AttachmentModal
          item={attItem}
          readOnly={!editable}
          onClose={() => setAttItemId(null)}
          onAdd={async file => { await addAttachment(report!.id, attItem.id, file); }}
          onDelete={attId => deleteAttachment(report.id, attItem.id, attId)}
        />
      )}

    </div>
  );
}
