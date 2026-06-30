/**
 * WorkflowReview — Full-page approver read-only view of an expense report.
 *
 * Reached via "Open Full View ↗" from the ApproverInbox panel, or linked
 * directly from email notifications. The approver can review all line items,
 * attachments, and history without constraint, then act from sticky headers
 * at both top and bottom.
 *
 * Route: /workflow/review/:id   (id = expense_report.id / record_id)
 * Guard: workflow.approve permission
 */

import { useState, useEffect, useRef } from 'react';
import { useParams, useNavigate, useSearchParams } from 'react-router-dom';
import { useApproverReportDetail } from '../hooks/useApproverReportDetail';
import { useWorkflowInstance }      from '../hooks/useWorkflowInstance';
import { useWorkflowTasks }         from '../hooks/useWorkflowTasks';
import { WorkflowTimeline }         from '../components/WorkflowTimeline';
import { WorkflowStatusBadge }      from '../components/WorkflowStatusBadge';
import { usePermissions }           from '../../hooks/usePermissions';
import { usePicklistValues }        from '../../hooks/usePicklistValues';
import { COUNTRIES }                from '../../components/admin/AddEmployee';
import { PHONE_CODES }             from '../../constants/phoneCodes';
import { fmtAmount } from '../../utils/currency';
import { validatePassportNumber, validatePassportValidity, passportNumberPlaceholder, passportNumberHint, passportValidityHint } from '../../utils/validatePassport';
import { validateIdentityNumber, idNumberPlaceholder, idNumberHint, defaultExpiryDate, idValidityLabel } from '../../utils/validateIdentity';
import { supabase } from '../../lib/supabase';
import BankAccountsPortlet  from '../../components/shared/BankAccountsPortlet';
import ConfirmationModal    from '../../components/shared/ConfirmationModal';
import DependentsPortlet   from '../../components/shared/DependentsPortlet';
import EducationPortlet    from '../../components/shared/EducationPortlet';
import TerminationForm     from '../../components/shared/TerminationForm';

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmtDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(iso));
}

function fmtDateTime(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

function attIcon(mime: string) {
  if (mime === 'application/pdf') return 'fa-file-pdf';
  if (mime.startsWith('image/'))  return 'fa-file-image';
  return 'fa-file';
}

function attFmtSize(bytes: number) {
  if (bytes < 1024)    return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

// Attachment row used by profile_bank and profile_dependents review sections.
// Reads either field-shape pair (storage_path / file_path, file_type / mime_type)
// and fetches a 1-hour signed URL from the hr-attachments bucket on mount.
// The optional `docTypeLabel` is used by dependents to surface the document type
// (Birth Certificate, Marriage Certificate, etc.); bank passes "Proof of Account".
function WfrAttachmentRow({ att, docTypeLabel }: {
  att: Record<string, unknown>;
  docTypeLabel: string;
}) {
  const [url, setUrl] = useState<string | null>(null);

  useEffect(() => {
    const path = (att.storage_path ?? att.file_path) as string | undefined;
    if (!path) return;
    supabase.storage.from('hr-attachments')
      .createSignedUrl(path, 3600)
      .then(({ data }) => { if (data?.signedUrl) setUrl(data.signedUrl); });
  }, [att.storage_path, att.file_path]);

  const mime     = String(att.file_type ?? att.mime_type ?? '');
  const isPdf    = mime === 'application/pdf' || String(att.file_name ?? att.original_file_name ?? '').toLowerCase().endsWith('.pdf');
  const isImage  = mime.startsWith('image/');
  const icon     = isPdf ? 'fa-file-pdf' : isImage ? 'fa-file-image' : 'fa-file';
  const iconColor = isPdf ? '#EF4444' : '#6366F1';
  const sizeKb   = att.file_size ? ((att.file_size as number) / 1024).toFixed(0) : null;
  const fileName = String(att.original_file_name ?? att.file_name ?? 'Attachment');

  const btnStyle: React.CSSProperties = {
    width: 30, height: 30, borderRadius: 6,
    background: '#F3F4F6', border: '1px solid #E5E7EB',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    cursor: 'pointer', textDecoration: 'none', flexShrink: 0, color: '#374151',
  };

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: '8px 10px',
      background: '#F9FAFB', border: '1px solid #E5E7EB',
      borderRadius: 7, fontSize: 12.5,
    }}>
      <i className={`fa-regular ${icon}`} style={{ color: iconColor, fontSize: 16, flexShrink: 0 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {fileName}
        </div>
        <div style={{ color: '#9CA3AF', fontSize: 11, marginTop: 1 }}>
          {docTypeLabel}{sizeKb ? ` · ${sizeKb} KB` : ''}
        </div>
      </div>
      {url && (
        <div style={{ display: 'flex', gap: 6, flexShrink: 0 }}>
          <a href={url} target="_blank" rel="noreferrer" style={btnStyle} title="View">
            <i className="fa-solid fa-eye" style={{ fontSize: 13 }} />
          </a>
          <a href={url} download={fileName} target="_blank" rel="noreferrer" style={btnStyle} title="Download">
            <i className="fa-solid fa-download" style={{ fontSize: 13 }} />
          </a>
        </div>
      )}
    </div>
  );
}

interface Person { id: string; name: string; title: string | null }

// ── Note limits ───────────────────────────────────────────────────────────────
const NOTE_MAX  = 1000;  // hard cap (also enforced DB-side)
const NOTE_WARN =  700;  // counter turns amber
const NOTE_HARD =  950;  // counter/border turns red

// ─────────────────────────────────────────────────────────────────────────────
// Bottom Action Bar — Workday-style: full-width textarea + 3-button row
// ─────────────────────────────────────────────────────────────────────────────

interface ActionBarProps {
  taskId:                 string;
  stepOrder:              number;
  comment:                string;
  onCommentChange:        (v: string) => void;
  loading:                boolean;
  error:                  string | null;
  onApprove:              () => void;
  onReject:               () => void;
  mode:                   'idle' | 'reassign' | 'return_init' | 'return_prev';
  onModeChange:           (m: 'idle' | 'reassign' | 'return_init' | 'return_prev') => void;
  onConfirmSecondary:     () => void;
  reassignTarget:         Person | null;
  onReassignTargetChange: (p: Person | null) => void;
  // Pattern A: Update button — shown when step allow_edit is ON and a form route exists
  onUpdate?:              () => void;
  // True when hire sections are in edit mode — button label flips to "Done Editing"
  isHireEditMode?:        boolean;
  isSavingHireEdits?:     boolean;
  onCancelHireEdit?:      () => void;
  // Initiator mode — hides Approve/Reject/More, shows Resubmit instead
  isInitiator?:           boolean;
  onResubmit?:            () => void;
  // Initiator + rejected mode — shows Discard Record button instead of Resubmit
  onWithdraw?:            () => void;
}

function ActionBar({
  taskId: _taskId, stepOrder, comment, onCommentChange, loading, error,
  onApprove, onReject, mode, onModeChange, onConfirmSecondary,
  reassignTarget, onReassignTargetChange, onUpdate, isHireEditMode,
  isSavingHireEdits, onCancelHireEdit, isInitiator, onResubmit, onWithdraw,
}: ActionBarProps) {
  const [showMore,  setShowMore]  = useState(false);
  const [query,     setQuery]     = useState('');
  const [results,   setResults]   = useState<Person[]>([]);
  const searchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const moreRef     = useRef<HTMLDivElement>(null);

  // People search for Reassign
  useEffect(() => {
    if (mode !== 'reassign' || query.length < 2) { setResults([]); return; }
    if (searchTimer.current) clearTimeout(searchTimer.current);
    searchTimer.current = setTimeout(async () => {
      const { data } = await supabase
        .from('profiles')
        .select('id, employees!inner(name, job_title)')
        .ilike('employees.name', `%${query}%`)
        .eq('is_active', true)
        .limit(8);
      setResults((data ?? []).map((p: any) => ({
        id: p.id, name: p.employees?.name ?? '—', title: p.employees?.job_title ?? null,
      })));
    }, 300);
  }, [query, mode]);

  // Outside-click-to-close for More dropdown
  useEffect(() => {
    if (!showMore) return;
    function handleOutside(e: MouseEvent) {
      if (moreRef.current && !moreRef.current.contains(e.target as Node)) {
        setShowMore(false);
      }
    }
    document.addEventListener('mousedown', handleOutside);
    return () => document.removeEventListener('mousedown', handleOutside);
  }, [showMore]);

  const placeholder =
    mode === 'reassign'    ? 'Reason for reassigning (optional)…' :
    mode === 'return_init' ? 'Message to submitter (required)…'   :
    mode === 'return_prev' ? 'Reason for returning (optional)…'   :
                             'Add a note — sent with your decision…';

  return (
    <div className="wfr-action-bar">
      {/* Reassign person search — shown above textarea when in reassign mode */}
      {mode === 'reassign' && (
        <div>
          <label className="wfr-reassign-label">Reassign to *</label>
          {reassignTarget ? (
            <div className="wfr-reassign-chip">
              <div>
                <div className="wfr-reassign-chip-name">{reassignTarget.name}</div>
                {reassignTarget.title && <div className="wfr-reassign-chip-title">{reassignTarget.title}</div>}
              </div>
              <button
                className="wfr-reassign-chip-remove"
                onClick={() => { onReassignTargetChange(null); setQuery(''); }}
              >×</button>
            </div>
          ) : (
            <div className="wfr-search-wrapper">
              <input
                value={query} onChange={e => setQuery(e.target.value)}
                placeholder="Search by name…" autoFocus
                className="wfr-search-input"
              />
              {results.length > 0 && (
                <div className="wfr-search-dropdown">
                  {results.map(p => (
                    <button key={p.id}
                      className="wfr-search-result-btn"
                      onClick={() => { onReassignTargetChange(p); setQuery(''); setResults([]); }}
                      onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')}
                      onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                    >
                      <div className="wfr-search-result-name">{p.name}</div>
                      {p.title && <div className="wfr-search-result-title">{p.title}</div>}
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>
      )}

      {/* Row 1: label + full-width textarea */}
      <div>
        <div className="wfr-action-note-label">
          {mode === 'idle'
            ? isInitiator ? 'Add a response (optional)' : 'Add a note — sent with your decision'
            : placeholder}
        </div>
        <textarea
          value={comment} onChange={e => onCommentChange(e.target.value.slice(0, NOTE_MAX))}
          placeholder={mode === 'idle'
            ? isInitiator ? 'Optional: provide context for the approver…' : 'Optional: add context for the submitter…'
            : placeholder}
          rows={2}
          maxLength={NOTE_MAX}
          className="wfr-action-textarea"
          style={{ border: `1px solid ${error ? '#FECACA' : comment.length >= NOTE_HARD ? '#EF4444' : '#D1D5DB'}` }}
        />
        {/* Character counter — only visible once typing starts */}
        {comment.length > 0 && (
          <div className={
            comment.length >= NOTE_HARD  ? 'wfr-note-counter wfr-note-counter--danger' :
            comment.length >= NOTE_WARN  ? 'wfr-note-counter wfr-note-counter--warn'   :
                                           'wfr-note-counter'
          }>
            {comment.length} / {NOTE_MAX}
          </div>
        )}
      </div>

      {/* Row 2: action buttons */}
      {mode === 'idle' ? (
        <div className="wfr-btn-row">
          {/* Approve — approver only */}
          {!isInitiator && (
            <button onClick={onApprove}
              disabled={loading || comment.length >= NOTE_HARD || !!isHireEditMode}
              title={isHireEditMode ? 'Save or cancel your edits before approving' : undefined}
              className="wfr-btn-approve"
              style={{
                background: (loading || comment.length >= NOTE_HARD || isHireEditMode) ? '#9CA3AF' : '#16A34A',
                cursor: (loading || comment.length >= NOTE_HARD || isHireEditMode) ? 'not-allowed' : 'pointer',
              }}>
              {loading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-check" />}
              Approve
            </button>
          )}

          {/* Reject — approver only */}
          {!isInitiator && (
            <button onClick={onReject}
              disabled={loading || comment.length >= NOTE_HARD || !!isHireEditMode}
              title={isHireEditMode ? 'Save or cancel your edits before rejecting' : undefined}
              className="wfr-btn-reject"
              style={{ cursor: (loading || comment.length >= NOTE_HARD || isHireEditMode) ? 'not-allowed' : 'pointer' }}>
              <i className="fas fa-times" /> Reject
            </button>
          )}

          {/* Update / Done Editing + Cancel — Pattern A */}
          {onUpdate && (
            <>
              <button onClick={onUpdate} disabled={loading || isSavingHireEdits}
                className={isHireEditMode ? 'wfr-btn-done-editing' : 'wfr-btn-update'}
                style={{ cursor: (loading || isSavingHireEdits) ? 'not-allowed' : 'pointer' }}>
                {isSavingHireEdits
                  ? <><i className="fas fa-spinner fa-spin" /> Saving…</>
                  : isHireEditMode
                    ? <><i className="fas fa-check" /> Done Editing</>
                    : <><i className="fas fa-pen-to-square" /> Update</>}
              </button>
              {isHireEditMode && onCancelHireEdit && (
                <button onClick={onCancelHireEdit} disabled={isSavingHireEdits}
                  className="wfr-btn-cancel-edit"
                  style={{ cursor: isSavingHireEdits ? 'not-allowed' : 'pointer' }}>
                  <i className="fas fa-times" /> Cancel
                </button>
              )}
            </>
          )}

          {/* Resubmit — initiator sent-back only */}
          {isInitiator && onResubmit && (
            <button onClick={onResubmit}
              disabled={loading || comment.length >= NOTE_HARD || !!isHireEditMode}
              title={isHireEditMode ? 'Save or cancel your edits before resubmitting' : undefined}
              className="wfr-btn-approve"
              style={{
                background: (loading || comment.length >= NOTE_HARD || isHireEditMode) ? '#9CA3AF' : '#B45309',
                cursor: (loading || comment.length >= NOTE_HARD || isHireEditMode) ? 'not-allowed' : 'pointer',
              }}>
              {loading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-paper-plane" />}
              Resubmit
            </button>
          )}

          {/* Discard Record — initiator rejected only */}
          {isInitiator && onWithdraw && (
            <button onClick={onWithdraw}
              disabled={loading}
              className="wfr-btn-reject"
              style={{
                background: loading ? '#9CA3AF' : '#DC2626',
                cursor: loading ? 'not-allowed' : 'pointer',
              }}>
              {loading ? <i className="fas fa-spinner fa-spin" /> : <i className="fas fa-trash-can" />}
              Discard Record
            </button>
          )}

          {/* More — approver only */}
          {!isInitiator && <div ref={moreRef} className="wfr-btn-more-wrapper">
            <button
              onClick={() => setShowMore(v => !v)} disabled={loading}
              className="wfr-btn-more"
              style={{
                background: showMore ? '#F3F4F6' : '#FAFAFA',
                cursor: loading ? 'not-allowed' : 'pointer',
              }}>
              More
              <i className="fas fa-chevron-down" style={{
                fontSize: 10,
                transition: 'transform 0.15s',
                transform: showMore ? 'rotate(180deg)' : 'none',
              }} />
            </button>
            {showMore && (
              <div className="wfr-more-dropdown">
                {/* Reassign */}
                <button
                  className="wfr-more-item wfr-more-item--reassign"
                  onClick={() => { onModeChange('reassign'); setShowMore(false); }}
                  onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')}
                  onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                >
                  <div className="wfr-more-item-accent wf-accent--purple" />
                  <div className="wfr-more-item-body">
                    <div className="wfr-more-item-icon wfr-icon-bg--purple">
                      <i className="fas fa-arrow-right-arrow-left wf-icon-color--purple" />
                    </div>
                    <div>
                      <div className="wfr-more-item-title wfr-item-title--purple">Reassign</div>
                      <div className="wfr-more-item-sub wfr-item-sub--purple">Transfer to another approver</div>
                    </div>
                  </div>
                </button>

                {/* Send Back */}
                <button
                  className="wfr-more-item wfr-more-item--sendback"
                  onClick={() => { onModeChange('return_init'); setShowMore(false); }}
                  style={{ borderBottom: stepOrder > 1 ? '1px solid #F3F4F6' : 'none' }}
                  onMouseEnter={e => (e.currentTarget.style.background = '#FFFBEB')}
                  onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                >
                  <div className="wfr-more-item-accent wf-accent--amber" />
                  <div className="wfr-more-item-body">
                    <div className="wfr-more-item-icon wfr-icon-bg--amber">
                      <i className="fas fa-comment-dots wf-icon-color--amber" />
                    </div>
                    <div>
                      <div className="wfr-more-item-title wfr-item-title--amber">Send Back</div>
                      <div className="wfr-more-item-sub wfr-item-sub--amber">Request clarification from submitter</div>
                    </div>
                  </div>
                </button>

                {/* Send Back to Previous Step — only if stepOrder > 1 */}
                {stepOrder > 1 && (
                  <button
                    className="wfr-more-item wfr-more-item--returnprev"
                    onClick={() => { onModeChange('return_prev'); setShowMore(false); }}
                    onMouseEnter={e => (e.currentTarget.style.background = '#F9FAFB')}
                    onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                  >
                    <div className="wfr-more-item-accent wf-accent--gray" />
                    <div className="wfr-more-item-body">
                      <div className="wfr-more-item-icon wfr-icon-bg--gray">
                        <i className="fas fa-backward-step wf-icon-color--gray" />
                      </div>
                      <div>
                        <div className="wfr-more-item-title wfr-item-title--gray">Send Back to Previous Step</div>
                        <div className="wfr-more-item-sub wfr-item-sub--gray">Return to the prior approval step</div>
                      </div>
                    </div>
                  </button>
                )}
              </div>
            )}
          </div>}
        </div>
      ) : (
        /* Secondary action mode (Reassign / Send Back / Send Back to Previous Step) */
        <div className="wfr-secondary-btn-row">
          <button onClick={onConfirmSecondary} disabled={loading}
            className="wfr-secondary-confirm-btn"
            style={{
              background: mode === 'reassign' ? '#7C3AED' : mode === 'return_init' ? '#B45309' : '#374151',
              cursor: loading ? 'not-allowed' : 'pointer',
            }}>
            {loading && <i className="fas fa-spinner fa-spin" />}
            {mode === 'reassign'    && 'Confirm Reassign'}
            {mode === 'return_init' && 'Send Back'}
            {mode === 'return_prev' && 'Send Back to Previous Step'}
          </button>
          <button
            className="wfr-secondary-cancel-btn"
            onClick={() => { onModeChange('idle'); onReassignTargetChange(null); }}
          >
            Cancel
          </button>
        </div>
      )}

      {error && (
        <p className="wfr-action-error">
          <i className="fas fa-triangle-exclamation" style={{ marginRight: 4 }} />{error}
        </p>
      )}
    </div>
  );
}

// ── Employee typeahead search input ──────────────────────────────────────────
function EmpSearchInput({
  value, options, onSelect,
}: {
  value:    string;
  options:  { id: string; name: string }[];
  onSelect: (id: string, name: string) => void;
}) {
  const [query,  setQuery]  = useState('');
  const [open,   setOpen]   = useState(false);
  const [active, setActive] = useState(false); // true when user is actively searching
  const ref = useRef<HTMLDivElement>(null);

  // Derive display name from current UUID value
  const displayName = options.find(o => o.id === value)?.name ?? '';

  const filtered = query.trim()
    ? options.filter(o => o.name.toLowerCase().includes(query.toLowerCase()))
    : options;

  // Close on outside click
  useEffect(() => {
    function handler(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
        setActive(false);
        setQuery('');
      }
    }
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <input
        className="wfr-field-input"
        type="text"
        placeholder="Search employee…"
        value={active ? query : displayName}
        onFocus={() => { setActive(true); setOpen(true); setQuery(''); }}
        onChange={e => { setQuery(e.target.value); setOpen(true); }}
      />
      {open && filtered.length > 0 && (
        <div className="wfr-emp-search-dropdown">
          {filtered.slice(0, 8).map(o => (
            <div
              key={o.id}
              className="wfr-emp-search-option"
              onMouseDown={() => {
                onSelect(o.id, o.name);
                setOpen(false);
                setActive(false);
                setQuery('');
              }}
            >
              {o.name}
            </div>
          ))}
        </div>
      )}
      {open && filtered.length === 0 && query.trim() && (
        <div className="wfr-emp-search-dropdown">
          <div className="wfr-emp-search-empty">No employees found</div>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Screen
// ─────────────────────────────────────────────────────────────────────────────

export default function WorkflowReview() {
  const { id: recordId } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const autoEdit    = searchParams.get('edit')   === '1';
  const isInitiator = searchParams.get('role')   === 'initiator';
  const urlModule   = searchParams.get('module') ?? '';

  const { can } = usePermissions();

  // ── Derive module from the active task — must come before any hook that needs it ──
  // Tasks load asynchronously; we stabilise moduleCode with a ref so hooks that
  // use it as a dependency don't thrash on every render while tasks are loading.
  const { tasks, approve, reject, reassign, returnToInitiator, returnToPreviousStep } = useWorkflowTasks();

  // Find the task for this record (the one assigned to current user)
  const myTask = tasks.find(t => t.recordId === recordId) ?? null;

  // Derive the module code from the task once it's available.
  // Default to '' (not 'expense_reports') so the expense-report detail hook
  // does NOT fire while tasks are still loading — avoids spurious 406 errors
  // when the record is actually an employee_hire UUID.
  const moduleCode = myTask?.moduleCode ?? (isInitiator ? urlModule : '');

  // Expense report detail — only fetched when we have confirmed module = expense_reports.
  // Passing null suppresses the fetch for all other modules (and during loading).
  const { detail, loading, error, refetch: refetchDetail } = useApproverReportDetail(
    moduleCode === 'expense_reports' ? (recordId ?? null) : null
  );

  const wf = useWorkflowInstance(moduleCode, recordId ?? null);

  // For the initiator view: the pending task at the current step, used to
  // show "Step N — StepName (with: AssigneeName)" in the summary grid.
  const currentStepTask = (isInitiator && wf.instance)
    ? (wf.tasks.find(t => t.stepOrder === wf.instance!.currentStep && t.status === 'pending') ?? null)
    : null;

  // ── WF Edit Gate: fetch allow_edit from the active step ───────────────────
  const [stepAllowEdit, setStepAllowEdit] = useState(false);
  useEffect(() => {
    if (!myTask) { setStepAllowEdit(false); return; }
    supabase
      .from('workflow_tasks')
      .select('workflow_steps ( allow_edit )')
      .eq('id', myTask.taskId)
      .maybeSingle()
      .then(({ data }) => {
        const ae = (data as any)?.workflow_steps?.allow_edit ?? false;
        setStepAllowEdit(ae);
      });
  }, [myTask?.taskId]);

  // ── edit_route: fetched from module_codes — drives Pattern A vs Pattern B ──
  // Pattern A (edit_route set)  → Update button navigates to the full edit form.
  // Pattern B (edit_route null) → inline proposed-changes edit (profile modules).
  const [editRoute, setEditRoute] = useState<string | null | undefined>(undefined);
  useEffect(() => {
    if (!moduleCode) return;
    supabase
      .from('module_codes')
      .select('edit_route')
      .eq('code', moduleCode)
      .maybeSingle()
      .then(({ data }) => setEditRoute((data as any)?.edit_route ?? null));
  }, [moduleCode]);

  // Edit gate: step must have allow_edit ON, user must be the active assignee,
  // and hold the module's edit permission.
  //
  // IMPORTANT: workflow module_codes and RBP permission module codes use different
  // naming conventions. Map workflow → permission before calling can():
  //   'employee_hire' (workflow engine) → 'hire_employee' (permission catalog / PermissionMatrix)
  //   'expense_reports' → 'expense_reports' (same in both namespaces)
  const WORKFLOW_TO_PERM_MODULE: Record<string, string> = {
    'employee_hire': 'hire_employee',
  };
  const permModule = WORKFLOW_TO_PERM_MODULE[moduleCode] ?? moduleCode;
  // Initiator can edit inline only when the instance is sent back (awaiting_clarification).
  // Rejected instances are read-only — the initiator can only Withdraw.
  const isInitiatorEditable = isInitiator && wf.instance?.status === 'awaiting_clarification';
  const canEditMidFlight = isInitiatorEditable || (stepAllowEdit && !!myTask && can(`${permModule}.edit`));

  // ── Profile Bank Change Review — set-snapshot model (Phase 4+) ────────────
  const isProfileBankModule = moduleCode === 'profile_bank';
  type WfrBankItem = Record<string, unknown>;
  const [bankProposedItems,  setBankProposedItems]  = useState<WfrBankItem[]>([]);
  const [bankCurrentItems,   setBankCurrentItems]   = useState<WfrBankItem[]>([]);
  const [bankEffectiveFrom,  setBankEffectiveFrom]  = useState('');
  const [bankChangeLoading,  setBankChangeLoading]  = useState(false);
  const [bankChangeError,    setBankChangeError]    = useState<string | null>(null);

  // ── Profile Dependents Change Review — set-snapshot model (Phase 3) ─
  const isProfileDependentsModule = moduleCode === 'profile_dependents';

  type WfrDepProposedItem = {
    dependent_code:    string | null;
    relationship_type: string;
    dependent_name:    string;
    date_of_birth:     string;
    gender:            string;
    insurance_eligible: boolean;
    attachments?:      Record<string, unknown>[];
  };
  type WfrDepCurrentItem = {
    id:                string;
    dependent_code:    string;
    relationship_type: string;
    dependent_name:    string;
    date_of_birth:     string;
    gender:            string;
    insurance_eligible: boolean;
    attachments:       Record<string, unknown>[];
  };
  type WfrDepDiffStatus = 'new' | 'amended' | 'removed' | 'unchanged';
  type WfrDepDiffItem   = {
    status:        WfrDepDiffStatus;
    proposed:      WfrDepProposedItem | null;
    current:       WfrDepCurrentItem  | null;
    code:          string | null;
    changedFields: string[];
  };

  const [depProposedItems, setDepProposedItems] = useState<WfrDepProposedItem[]>([]);
  const [depCurrentItems,  setDepCurrentItems]  = useState<WfrDepCurrentItem[]>([]);
  const [depEffectiveFrom, setDepEffectiveFrom] = useState('');
  const [depChangeLoading, setDepChangeLoading] = useState(false);
  const [depChangeError,   setDepChangeError]   = useState<string | null>(null);
  useEffect(() => {
    if (!isProfileBankModule || !wf.instance?.id) return;
    let mounted = true;
    setBankChangeLoading(true);
    setBankChangeError(null);

    (async () => {
      try {
        // 1. Load proposed_data from workflow_pending_changes
        const { data: wpcRow, error: wpcErr } = await supabase
          .from('workflow_pending_changes')
          .select('proposed_data')
          .eq('instance_id', wf.instance!.id)
          .maybeSingle();

        if (!mounted) return;
        if (wpcErr) throw new Error(wpcErr.message);
        if (!wpcRow) throw new Error('No pending change record found.');

        const pd = wpcRow.proposed_data as any;
        const proposed: WfrBankItem[] = Array.isArray(pd?.items) ? pd.items : [];
        const effFrom = pd?.effective_from ?? '';
        const empId   = pd?.employee_id ?? '';

        // 2. Load current active set for diff
        let current: WfrBankItem[] = [];
        if (empId) {
          const { data: setData } = await supabase
            .rpc('get_employee_bank_account_set', { p_employee_id: empId });
          const sd = setData as { ok: boolean; set: any; items: WfrBankItem[] } | null;
          current = sd?.items ?? [];
        }

        if (!mounted) return;
        setBankProposedItems(proposed);
        setBankCurrentItems(current);
        setBankEffectiveFrom(effFrom);
      } catch (e: any) {
        if (mounted) setBankChangeError(e.message ?? 'Failed to load bank change details.');
      } finally {
        if (mounted) setBankChangeLoading(false);
      }
    })();

    return () => { mounted = false; };
  }, [isProfileBankModule, wf.instance?.id]);

  useEffect(() => {
    if (!isProfileDependentsModule || !wf.instance?.id) return;
    let mounted = true;
    setDepChangeLoading(true);
    setDepChangeError(null);

    (async () => {
      try {
        const { data: wpcRow, error: wpcErr } = await supabase
          .from('workflow_pending_changes')
          .select('proposed_data')
          .eq('instance_id', wf.instance!.id)
          .maybeSingle();

        if (!mounted) return;
        if (wpcErr) throw new Error(wpcErr.message);
        if (!wpcRow) throw new Error('No pending change record found.');

        const pd = wpcRow.proposed_data as any;
        const proposed: WfrDepProposedItem[] = Array.isArray(pd?.items) ? pd.items : [];
        const effFrom = pd?.effective_from ?? '';
        const empId   = pd?.employee_id ?? '';

        let current: WfrDepCurrentItem[] = [];
        if (empId) {
          const { data: setData } = await supabase
            .rpc('get_employee_dependent_set', { p_employee_id: empId });
          const sd = setData as { ok: boolean; set: any; items: WfrDepCurrentItem[] } | null;
          current = sd?.items ?? [];
        }

        if (!mounted) return;
        setDepProposedItems(proposed);
        setDepCurrentItems(current);
        setDepEffectiveFrom(effFrom);
      } catch (e) {
        if (mounted) setDepChangeError((e as Error).message);
      } finally {
        if (mounted) setDepChangeLoading(false);
      }
    })();

    return () => { mounted = false; };
  }, [isProfileDependentsModule, wf.instance?.id]);
  // ── Job Relationships Change Review — set-snapshot model ─────────────────
  const isJobRelationshipsModule  = moduleCode === 'profile_job_relationships';
  const isProfileEducationModule  = moduleCode === 'profile_education';
  const isTerminationModule       = moduleCode === 'termination' || moduleCode === 'termination_reversal';

  type WfrJRItem = {
    relationship_code:   string;
    manager_employee_id: string;
    manager_name?:       string;
    manager_employee_code?: string;
  };

  const JR_CODE_ORDER_WFR = ['PM01', 'PM02', 'PM03', 'OM01', 'OM02', 'OM03'];
  const JR_DEFAULT_LABELS: Record<string, string> = {
    PM01: 'Project Manager', PM02: 'Programme Manager', PM03: 'Practice Manager',
    OM01: 'Operations Manager', OM02: 'Operations Lead', OM03: 'Operations Coordinator',
  };

  const [jrProposedItems,   setJrProposedItems]   = useState<WfrJRItem[]>([]);
  const [jrCurrentItems,    setJrCurrentItems]    = useState<WfrJRItem[]>([]);
  const [jrEffectiveFrom,   setJrEffectiveFrom]   = useState('');
  const [jrChangeLoading,   setJrChangeLoading]   = useState(false);
  const [jrChangeError,     setJrChangeError]     = useState<string | null>(null);

  useEffect(() => {
    if (!isJobRelationshipsModule || !wf.instance?.id) return;
    let mounted = true;
    setJrChangeLoading(true);
    setJrChangeError(null);

    (async () => {
      try {
        const { data: wpcRow, error: wpcErr } = await supabase
          .from('workflow_pending_changes')
          .select('proposed_data, current_data')
          .eq('instance_id', wf.instance!.id)
          .maybeSingle();

        if (wpcErr) throw new Error(wpcErr.message);
        if (!wpcRow) { if (mounted) setJrChangeLoading(false); return; }

        const proposed = wpcRow.proposed_data as { effective_from?: string; items?: WfrJRItem[] } | null;
        const current  = wpcRow.current_data  as { items?: WfrJRItem[] } | null;

        if (mounted) {
          setJrProposedItems(proposed?.items ?? []);
          setJrCurrentItems(current?.items ?? []);
          setJrEffectiveFrom(proposed?.effective_from ?? '');
          setJrChangeLoading(false);
        }
      } catch (err: unknown) {
        if (mounted) {
          setJrChangeError(err instanceof Error ? err.message : 'Failed to load job relationship change data.');
          setJrChangeLoading(false);
        }
      }
    })();

    return () => { mounted = false; };
  }, [isJobRelationshipsModule, wf.instance?.id]);

  // ── Profile Education Change Review ─────────────────────────────────────────
  const [eduProposedData,  setEduProposedData]  = useState<Record<string, unknown> | null>(null);
  const [eduCurrentData,   setEduCurrentData]   = useState<Record<string, unknown> | null>(null);
  const [eduChangeLoading, setEduChangeLoading] = useState(false);
  const [eduChangeError,   setEduChangeError]   = useState<string | null>(null);

  useEffect(() => {
    if (!isProfileEducationModule || !wf.instance?.id) return;
    let mounted = true;
    setEduChangeLoading(true);
    setEduChangeError(null);

    (async () => {
      try {
        const { data: wpcRow, error: wpcErr } = await supabase
          .from('workflow_pending_changes')
          .select('proposed_data, current_data')
          .eq('instance_id', wf.instance!.id)
          .maybeSingle();

        if (wpcErr) throw new Error(wpcErr.message);
        if (mounted) {
          setEduProposedData((wpcRow?.proposed_data as Record<string, unknown>) ?? null);
          setEduCurrentData((wpcRow?.current_data  as Record<string, unknown>) ?? null);
          setEduChangeLoading(false);
        }
      } catch (err: unknown) {
        if (mounted) {
          setEduChangeError(err instanceof Error ? err.message : 'Failed to load education change data.');
          setEduChangeLoading(false);
        }
      }
    })();

    return () => { mounted = false; };
  }, [isProfileEducationModule, wf.instance?.id]);

  // ── Termination Review — loaded when module_code = 'termination' ────────────
  type WfrTermRecord = Record<string, unknown>;
  const [termRecord,      setTermRecord]      = useState<WfrTermRecord | null>(null);
  const [termLoading,     setTermLoading]     = useState(false);
  const [termError,       setTermError]       = useState<string | null>(null);

  // Inline edit state — active only when isInitiatorEditable (sent-back, SELF path)
  const [termAmending,       setTermAmending]       = useState(false);
  const [termAmendError,     setTermAmendError]     = useState<string | null>(null);

  // Approver mid-flight edit state (Update button in full view)
  const [termApproverEditing,    setTermApproverEditing]    = useState(false);
  const [termApproverLwd,        setTermApproverLwd]        = useState('');
  const [termApproverWaiver,     setTermApproverWaiver]     = useState(false);
  const [termApproverWaiverReason, setTermApproverWaiverReason] = useState('');
  const [termApproverSaving,     setTermApproverSaving]     = useState(false);
  const [termApproverError,      setTermApproverError]      = useState<string | null>(null);

  // Reassign direct reports edit state
  type ReassignRow = { employee_id: string; employee_name?: string; new_manager_id: string | null; new_manager_name?: string | null };
  const [reassignEditing,  setReassignEditing]  = useState(false);
  const [reassignDraft,    setReassignDraft]    = useState<ReassignRow[]>([]);
  const [reassignSaving,   setReassignSaving]   = useState(false);
  const [reassignError,    setReassignError]    = useState<string | null>(null);
  const [reassignSearch,   setReassignSearch]   = useState<Record<number, string>>({});
  const [reassignResults,  setReassignResults]  = useState<Record<number, { id: string; name: string }[]>>({});

  useEffect(() => {
    if (!isTerminationModule || !wf.instance?.id) return;
    let mounted = true;
    setTermLoading(true);
    setTermError(null);

    (async () => {
      try {
        // record_id is the termination_id or reversal_id
        const { data: termRow } = await supabase
          .from('employee_terminations')
          .select('*')
          .eq('id', wf.instance!.recordId)
          .maybeSingle();

        if (termRow) {
          if (mounted) { setTermRecord(termRow); setTermLoading(false); }
          return;
        }

        // Try reversal table
        const { data: revRow, error: revErr } = await supabase
          .from('employee_termination_reversals')
          .select('*, employee_terminations!inner(*)')
          .eq('id', wf.instance!.recordId)
          .maybeSingle();

        if (revErr) throw new Error(revErr.message);
        if (mounted) { setTermRecord(revRow ?? null); setTermLoading(false); }
      } catch (err: unknown) {
        if (mounted) {
          setTermError(err instanceof Error ? err.message : 'Failed to load termination record.');
          setTermLoading(false);
        }
      }
    })();

    return () => { mounted = false; };
  }, [isTerminationModule, wf.instance?.id]);

  // ── Employee Hire Review — loaded when module_code = 'employee_hire' ──────
  // get_employee_hire_review returns structured sections so WorkflowReview can
  // render them dynamically without hardcoding fields.
  const isHireModule = moduleCode === 'employee_hire';
  type HireField   = { label: string; value: string; raw_value?: string | null; key?: string; editable?: boolean; input_type?: string; required?: boolean };
  type HireSection = { section: string; fields: HireField[]; attachments?: Record<string, unknown>[] };
  const [hireSections,    setHireSections]    = useState<HireSection[]>([]);
  const [hireLoading,     setHireLoading]     = useState(false);
  const [hireError,       setHireError]       = useState<string | null>(null);
  // Section-level edit state — Set supports multiple sections open simultaneously
  const [editingSections, setEditingSections] = useState<Set<string>>(new Set());
  const [sectionEdits,    setSectionEdits]    = useState<Record<string, string>>({});
  // fieldErrors holds inline validation messages (country-first guard etc.) — NOT save errors
  const [fieldErrors,     setFieldErrors]     = useState<Record<string, string>>({});
  const [editError,       setEditError]       = useState<string | null>(null);
  // Batch-save state for Done Editing
  const [isSavingHireEdits, setIsSavingHireEdits] = useState(false);
  // Ref to trigger saving all open inline bank account forms (wired from BankAccountsPortlet)
  const bankSaveAllRef = useRef<(() => Promise<boolean>) | null>(null);
  // Ref to trigger saving all open inline dependent forms (wired from DependentsPortlet)
  const depSaveAllRef  = useRef<(() => Promise<boolean>) | null>(null);
  // Ref to trigger saving all open inline education forms (wired from EducationPortlet)
  const eduSaveAllRef  = useRef<(() => Promise<boolean>) | null>(null);
  const [saveFailures,      setSaveFailures]      = useState<{ section: string; label: string; error: string }[]>([]);
  // Hire-module completeness violations — shown when approver tries to activate with missing required fields
  const [hireViolations,  setHireViolations]  = useState<{ section: string; label: string }[]>([]);
  // Picklist data for section edit dropdowns (loaded once when hire module active)
  const { picklistValues: hirePl } = usePicklistValues(true);

  // ── Identity "Add ID" form — local state, saved immediately on Add ────────
  const [newIdForm, setNewIdForm] = useState({ country: '', id_type: '', record_type: '', id_number: '', expiry: '' });
  const [newIdErrors, setNewIdErrors] = useState<Record<string, string>>({});
  const [savingNewId, setSavingNewId] = useState(false);
  const [idCountryPending, setIdCountryPending] = useState<string | null>(null);
  // Department + employee lists for dept_select / emp_select dropdowns
  const [deptOptions, setDeptOptions] = useState<{ id: string; name: string }[]>([]);
  const [empOptions,  setEmpOptions]  = useState<{ id: string; name: string }[]>([]);
  // Employee name + submission date for the nav-bar center (hire module only)
  const [hireName,        setHireName]        = useState('');
  const [hireSubmittedAt, setHireSubmittedAt] = useState<string | null>(null);
  const [hireDate,        setHireDate]        = useState<string | null>(null);
  // Modal for invite email / profile-link failures at final approval
  const [inviteErrorModal, setInviteErrorModal] = useState<{
    open: boolean; title: string; message: string;
  }>({ open: false, title: '', message: '' });
  // ── Delete primary ID — auto-demote secondary modal ─────────────────────
  const [deletePrimaryModal, setDeletePrimaryModal] = useState<{
    open: boolean;
    primaryId: string;
    secondaryRecords: Array<{ raw_country: string; raw_id_type: string; raw_id_number: string; raw_expiry: string }>;
  } | null>(null);

  useEffect(() => {
    if (!isHireModule || !recordId) {
      setHireSections([]); setHireName(''); setHireSubmittedAt(null); setHireDate(null); setHireError(null); return;
    }
    setHireLoading(true);
    setHireError(null);
    Promise.all([
      supabase.rpc('get_employee_hire_review', { p_employee_id: recordId }),
      supabase.from('employees').select('name, submitted_at, created_at, hire_date').eq('id', recordId).maybeSingle(),
    ]).then(([{ data, error: rpcErr }, { data: emp }]) => {
      if (rpcErr) {
        setHireError(rpcErr.message);
      } else if (data) {
        const sections = data as HireSection[];
        setHireSections(sections);
        // If navigated with ?edit=1 (e.g. from inbox Update button), open all sections immediately
        if (autoEdit) {
          const edits: Record<string, string> = {};
          sections.forEach(sec => sec.fields.forEach(f => {
            if (f.editable && f.key) edits[f.key] = f.raw_value ?? (f.value === '—' ? '' : f.value);
          }));
          setSectionEdits(edits);
          setEditingSections(new Set(sections.map(s => s.section)));
        }
      }
      if (emp) {
        setHireName((emp as any).name ?? '');
        // Use submitted_at (stamped by submit_hire) for accuracy.
        // Fall back to created_at for legacy records pre-mig 254.
        setHireSubmittedAt((emp as any).submitted_at ?? (emp as any).created_at ?? null);
        setHireDate((emp as any).hire_date ?? null);
      }
      setHireLoading(false);
    });
  }, [isHireModule, recordId, autoEdit]);

  // Fetch departments and employees for dept_select / emp_select dropdowns
  useEffect(() => {
    if (!isHireModule) return;
    supabase.from('departments').select('id, name').order('name')
      .then(({ data }) => setDeptOptions((data ?? []) as { id: string; name: string }[]));
    supabase.from('employees').select('id, name')
      .eq('status', 'Active')
      .neq('id', recordId ?? '')
      .order('name')
      .then(({ data }) => setEmpOptions((data ?? []) as { id: string; name: string }[]));
  }, [isHireModule, recordId]);


  // ── Section-level edit handlers ──────────────────────────────────────────

  /** Open a single section in edit mode (adds it to the Set). */
  function enterSectionEdit(sec: { section: string; fields: HireField[] }) {
    const edits: Record<string, string> = {};
    sec.fields.forEach(f => {
      if (f.editable && f.key) {
        edits[f.key] = f.raw_value ?? (f.value === '—' ? '' : f.value);
      }
    });
    setSectionEdits(prev => ({ ...prev, ...edits }));
    setEditingSections(prev => new Set([...prev, sec.section]));
    setEditError(null);
  }

  /** Open ALL sections in edit mode at once — triggered by the Update button. */
  function enterAllEdit() {
    const edits: Record<string, string> = {};
    hireSections.forEach(sec => {
      sec.fields.forEach(f => {
        if (f.editable && f.key) {
          edits[f.key] = f.raw_value ?? (f.value === '—' ? '' : f.value);
        }
      });
    });
    setSectionEdits(edits);
    setEditingSections(new Set(hireSections.map(s => s.section)));
    setEditError(null);
  }

  // ── Hire field completeness validation ───────────────────────────────────
  // Conditional sections: only enforce required fields when at least one
  // field in the section already has a value (i.e. the employee filled it).
  // If the whole section was left blank on submission, skip it — approvers
  // should not be blocked from approving when optional sections were skipped.
  // Address and Emergency Contact are optional on the hire form; Passport and
  // Identity Documents are optional too.
  const CONDITIONAL_SECTION_PREFIXES = ['Passport', 'Identity Document', 'Address', 'Emergency Contact'];

  function validateHireFields(): { section: string; label: string; formatError?: string }[] {
    const violations: { section: string; label: string; formatError?: string }[] = [];
    for (const sec of hireSections) {
      const isConditional = CONDITIONAL_SECTION_PREFIXES.some(p => sec.section.startsWith(p));
      if (isConditional) {
        // Skip section entirely if no field has been filled
        const hasAnyValue = sec.fields.some(f => {
          const effective = (f.key && sectionEdits[f.key] !== undefined)
            ? sectionEdits[f.key]
            : (f.raw_value ?? '');
          return effective && effective.trim() !== '' && effective !== '—';
        });
        if (!hasAnyValue) continue;
      }
      for (const f of sec.fields) {
        if (!f.required) continue;
        const effective = (f.key && sectionEdits[f.key] !== undefined)
          ? sectionEdits[f.key]
          : (f.raw_value ?? '');
        if (!effective || effective.trim() === '' || effective === '—') {
          violations.push({ section: sec.section, label: f.label });
          continue;
        }
        // Format validation for ID number fields
        if (f.key === 'id_number') {
          const countryField = sec.fields.find(ff => ff.key === 'country');
          const idTypeField  = sec.fields.find(ff => ff.key === 'id_type');
          const countryVal   = countryField ? ((sectionEdits[countryField.key!] ?? countryField.raw_value) ?? '') : '';
          const idTypeVal    = idTypeField  ? ((sectionEdits[idTypeField.key!]  ?? idTypeField.raw_value)  ?? '') : '';
          const cName  = hirePl.find(p => String(p.id) === String(countryVal))?.value ?? String(countryVal);
          const tName  = hirePl.find(p => String(p.id) === String(idTypeVal))?.value  ?? String(idTypeVal);
          const fmtErr = validateIdentityNumber(cName, tName, effective.trim());
          if (fmtErr) violations.push({ section: sec.section, label: f.label, formatError: fmtErr });
        }
        // Format validation for passport number fields
        if (f.key === 'passport_number') {
          const countryField = sec.fields.find(ff => ff.key === 'country');
          const countryVal   = countryField ? ((sectionEdits[countryField.key!] ?? countryField.raw_value) ?? '') : '';
          const cName  = hirePl.find(p => String(p.id) === String(countryVal))?.value ?? String(countryVal);
          const fmtErr = validatePassportNumber(cName, effective.trim());
          if (fmtErr) violations.push({ section: sec.section, label: f.label, formatError: fmtErr });
        }
      }
    }
    return violations;
  }

  /** Resolve a raw value to its display label for optimistic UI update. */
  function resolveDisplayLabel(fieldKey: string, rawValue: string, inputType?: string): string {
    if (!rawValue) return rawValue;
    if (inputType === 'dept_select') return deptOptions.find(d => d.id === rawValue)?.name ?? rawValue;
    if (inputType === 'emp_select')  return empOptions.find(e => e.id === rawValue)?.name  ?? rawValue;
    if (inputType !== 'select') return rawValue;
    const col = fieldKey.split('.').pop() ?? '';
    // Text-stored selects — value IS the display label
    if (['record_type', 'nationality', 'gender'].includes(col)) {
      return rawValue.charAt(0).toUpperCase() + rawValue.slice(1);
    }
    // UUID-stored selects — look up in hirePl
    return hirePl.find(p => String(p.id) === rawValue)?.value ?? rawValue;
  }

  /** Batch-save all changed fields on Done Editing. */
  async function handleDoneEditing() {
    if (!recordId) return;

    // ── Auto-flush pending identity add form ─────────────────────────────────
    // If the approver filled the add-ID form but never clicked "+ Add ID",
    // save it now exactly like AddEmployee's flushPendingIdRecord().
    const hasNewIdData = newIdForm.country || newIdForm.id_type || newIdForm.record_type || newIdForm.id_number || newIdForm.expiry;
    if (hasNewIdData) {
      const errs: Record<string, string> = {};
      if (!newIdForm.country)     errs.country     = 'Country is required.';
      if (!newIdForm.id_type)     errs.id_type     = 'ID Type is required.';
      if (!newIdForm.record_type) errs.record_type = 'Record Type is required.';
      if (!newIdForm.id_number)   errs.id_number   = 'ID Number is required.';
      if (newIdForm.id_number) {
        const _cn = hirePl.find(p => String(p.id) === newIdForm.country)?.value ?? '';
        const _tn = hirePl.find(p => String(p.id) === newIdForm.id_type)?.value ?? '';
        const _fe = validateIdentityNumber(_cn, _tn, newIdForm.id_number);
        if (_fe) errs.id_number = _fe;
      }
      if (newIdForm.expiry) {
        const today = new Date().toISOString().slice(0, 10);
        if (newIdForm.expiry <= today) errs.expiry = 'Expiry Date must be a future date.';
      }
      if (Object.keys(errs).length) {
        // Block Done Editing and highlight the incomplete add form
        setNewIdErrors(errs);
        document.getElementById('wfr-identity-add-form')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
        return;
      }
      // Complete record — insert before proceeding with the rest of Done Editing.
      // uq_identity_records_emp_type (mig 446) prevents duplicate (employee, id_type).
      // We surface a friendly message instead of a raw Postgres unique-violation error.
      const { error: idInsErr } = await supabase.from('identity_records').insert({
        employee_id: recordId,
        country:     newIdForm.country     || null,
        id_type:     newIdForm.id_type     || null,
        record_type: newIdForm.record_type || null,
        id_number:   newIdForm.id_number   || null,
        expiry:      newIdForm.expiry      || null,
      });
      if (idInsErr) {
        const isUniqueViolation = idInsErr.code === '23505';
        const friendlyMsg = isUniqueViolation
          ? 'An ID record of this type already exists for this employee. Remove the existing record before adding a new one.'
          : idInsErr.message;
        setNewIdErrors({ _root: friendlyMsg });
        document.getElementById('wfr-identity-add-form')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
        return;
      }
      setNewIdForm({ country: '', id_type: '', record_type: '', id_number: '', expiry: '' });
      setNewIdErrors({});
    }

    // ── Save open inline bank account forms ─────────────────────────────────
    if (bankSaveAllRef.current) {
      const bankOk = await bankSaveAllRef.current();
      if (!bankOk) return;
    }

    // ── Save open inline dependent forms ────────────────────────────────────
    if (depSaveAllRef.current) {
      const depOk = await depSaveAllRef.current();
      if (!depOk) return;
    }

    // ── Save open inline education forms ────────────────────────────────────
    if (eduSaveAllRef.current) {
      const eduOk = await eduSaveAllRef.current();
      if (!eduOk) return;
    }

    // ── Employment date cross-validation ────────────────────────────────────
    {
      const empSection = hireSections.find(s => s.section.toLowerCase().startsWith('employ'));
      if (empSection) {
        const getEmpVal = (col: string) => {
          const f = empSection.fields.find(fd => fd.key === `emp.${col}`);
          return (f?.key && sectionEdits[f.key] !== undefined) ? sectionEdits[f.key] : (f?.raw_value ?? '');
        };
        const hireDate = getEmpVal('hire_date');
        const endDate  = getEmpVal('end_date');
        if (endDate && endDate !== '9999-12-31' && hireDate && endDate < hireDate) {
          setFieldErrors(prev => ({ ...prev, 'emp.end_date': 'End Date cannot be before Hire Date.' }));
          return;
        }
        const probEnd = getEmpVal('probation_end_date');
        if (probEnd && hireDate && probEnd < hireDate) {
          setFieldErrors(prev => ({ ...prev, 'emp.probation_end_date': 'Probation End Date cannot be before Hire Date.' }));
          return;
        }
      }
    }

    // ── Passport format + validity validation ────────────────────────────────
    {
      const passSection = hireSections.find(s => s.section.startsWith('Passport'));
      if (passSection) {
        const hasAnyValue = passSection.fields.some(f => {
          const v = (f.key && sectionEdits[f.key] !== undefined) ? sectionEdits[f.key] : (f.raw_value ?? '');
          return v && v.trim() !== '' && v !== '—';
        });
        if (hasAnyValue) {
          const getVal = (col: string) => {
            const f = passSection.fields.find(fd => fd.key === `passport.${col}`);
            return (f?.key && sectionEdits[f.key] !== undefined) ? sectionEdits[f.key] : (f?.raw_value ?? '');
          };
          const passCountryId   = getVal('country');
          const passNumber      = getVal('passport_number');
          const passIssueDate   = getVal('issue_date');
          const passExpiryDate  = getVal('expiry_date');
          const passCountryName = hirePl.find(p => String(p.id) === passCountryId)?.value ?? '';

          if (passNumber) {
            const numErr = validatePassportNumber(passCountryName, passNumber);
            if (numErr) {
              setFieldErrors(prev => ({ ...prev, 'passport.passport_number': numErr }));
              return;
            }
          }
          if (passExpiryDate) {
            const todayStr = new Date().toISOString().slice(0, 10);
            if (passExpiryDate <= todayStr) {
              setFieldErrors(prev => ({ ...prev, 'passport.expiry_date': 'Expiry Date must be a future date.' }));
              return;
            }
          }
          if (passIssueDate && passExpiryDate) {
            const valErr = validatePassportValidity(passCountryName, passIssueDate, passExpiryDate);
            if (valErr) {
              setFieldErrors(prev => ({ ...prev, 'passport.expiry_date': valErr }));
              return;
            }
          }
        }
      }
    }

    setIsSavingHireEdits(true);
    const failures: { section: string; label: string; error: string }[] = [];

    // Track whether work_country was saved — it atomically updates base_currency_id
    // on the DB side (mig 248), so we need a full re-fetch to reflect the new
    // currency in the Base Currency row rather than patching it locally.
    let workCountrySaved = false;

    for (const sec of hireSections) {
      for (const f of sec.fields) {
        if (!f.key || !f.editable) continue;
        const newValue = sectionEdits[f.key];
        if (newValue === undefined) continue;            // field never entered edit state
        if (newValue === (f.raw_value ?? '')) continue; // no change

        try {
          const { error } = await supabase.rpc('update_hire_field', {
            p_employee_id: recordId,
            p_field_key:   f.key,
            p_new_value:   newValue,
          });
          if (error) throw error;

          if (f.key === 'emp.work_country') {
            workCountrySaved = true;
          } else {
            // Patch local hireSections so read view reflects the saved value.
            // work_country is handled below by a full re-fetch.
            const displayLabel = resolveDisplayLabel(f.key, newValue, f.input_type);
            setHireSections(prev => prev.map(s => ({
              ...s,
              fields: s.fields.map(field =>
                field.key === f.key
                  ? { ...field, raw_value: newValue, value: displayLabel || '—' }
                  : field
              ),
            })));
          }
        } catch (e) {
          failures.push({ section: sec.section, label: f.label, error: (e as Error).message });
        }
      }
    }

    setIsSavingHireEdits(false);

    if (failures.length > 0) {
      setSaveFailures(failures);
      // Keep edit mode open so the approver can retry
    } else {
      setSectionEdits({});
      setEditingSections(new Set());
      setFieldErrors({});

      // Always re-fetch after Done Editing so newly-inserted identity records
      // (and any work_country-derived currency change) are reflected in the read view.
      const { data } = await supabase.rpc('get_employee_hire_review', { p_employee_id: recordId });
      if (data) setHireSections(data as HireSection[]);
    }
  }

  /** Discard all local edits and exit edit mode without touching the DB. */
  function handleCancelEdit() {
    setSectionEdits({});
    setEditingSections(new Set());
    setFieldErrors({});
    setHireViolations([]);
    setEditError(null);
    setNewIdForm({ country: '', id_type: '', record_type: '', id_number: '', expiry: '' });
    setNewIdErrors({});
  }

  /** Immediately insert a new identity record via SECURITY DEFINER RPC and reload. */
  async function handleAddIdRecord() {
    if (!recordId) return;
    const errs: Record<string, string> = {};
    if (!newIdForm.country)     errs.country     = 'Country is required.';
    if (!newIdForm.id_type)     errs.id_type     = 'ID Type is required.';
    if (!newIdForm.record_type) errs.record_type = 'Record Type is required.';
    if (!newIdForm.id_number)   errs.id_number   = 'ID Number is required.';
    if (newIdForm.id_number) {
      const _cn = hirePl.find(p => String(p.id) === newIdForm.country)?.value ?? '';
      const _tn = hirePl.find(p => String(p.id) === newIdForm.id_type)?.value ?? '';
      const _fe = validateIdentityNumber(_cn, _tn, newIdForm.id_number);
      if (_fe) errs.id_number = _fe;
    }
    if (newIdForm.expiry) {
      const today = new Date().toISOString().slice(0, 10);
      if (newIdForm.expiry <= today) errs.expiry = 'Expiry Date must be a future date.';
    }
    if (Object.keys(errs).length) { setNewIdErrors(errs); return; }
    setSavingNewId(true);
    try {
      const { error } = await supabase.rpc('add_hire_identity_record', {
        p_employee_id: recordId,
        p_country:     newIdForm.country     || null,
        p_id_type:     newIdForm.id_type     || null,
        p_record_type: newIdForm.record_type || null,
        p_id_number:   newIdForm.id_number   || null,
        p_expiry:      newIdForm.expiry      || null,
      });
      if (error) throw error;
      const { data } = await supabase.rpc('get_employee_hire_review', { p_employee_id: recordId });
      if (data) setHireSections(data as HireSection[]);
      setNewIdForm({ country: '', id_type: '', record_type: '', id_number: '', expiry: '' });
      setNewIdErrors({});
    } catch (e) {
      setNewIdErrors({ _root: (e as Error).message });
    } finally {
      setSavingNewId(false);
    }
  }

  /** Immediately delete an identity record via SECURITY DEFINER RPC and reload. */
  async function handleDeleteIdRecord(idRecordId: string, currentExistingRecords?: { id: string; raw_record_type: string; raw_country: string; raw_id_type: string; raw_id_number: string; raw_expiry: string }[]) {
    if (!recordId) return;

    // If deleting a primary and secondary exists — show demote modal instead
    if (currentExistingRecords) {
      const target = currentExistingRecords.find(r => r.id === idRecordId);
      const secondaries = currentExistingRecords.filter(r => r.id !== idRecordId && r.raw_record_type === 'secondary');
      if (target?.raw_record_type === 'primary' && secondaries.length > 0) {
        setDeletePrimaryModal({
          open: true,
          primaryId: idRecordId,
          secondaryRecords: secondaries,
        });
        return;
      }
    }

    const { error } = await supabase.rpc('delete_hire_identity_record', {
      p_employee_id: recordId,
      p_record_id:   idRecordId,
    });
    if (error) {
      setInviteErrorModal({ open: true, title: 'Delete Error', message: error.message.replace(/^ERROR:\s*/i, '') });
      return;
    }
    const { data } = await supabase.rpc('get_employee_hire_review', { p_employee_id: recordId });
    if (data) setHireSections(data as HireSection[]);
  }

  /** Extract the identity record UUID from a section's field keys (null for the id.new.* placeholder). */
  function identityRecordId(sec: HireSection): string | null {
    const anyKey = sec.fields.find(f => f.key?.startsWith('id.'))?.key;
    if (!anyKey) return null;
    const parts = anyKey.split('.');
    return parts[1] === 'new' ? null : parts[1];
  }

  // ── Country-first guard for conditional sections ─────────────────────────
  // Returns the country key that must be filled before `fieldKey` can be edited,
  // or null if the field is the country itself (or not in a conditional section).
  function getCountryKeyForField(fieldKey: string): string | null {
    if (fieldKey === 'passport.country') return null;
    if (fieldKey.startsWith('passport.')) return 'passport.country';
    if (fieldKey.startsWith('id.')) {
      const parts = fieldKey.split('.');
      if (parts.length === 3 && parts[2] !== 'country') return `id.${parts[1]}.country`;
    }
    return null;
  }

  /** Called by every field's onChange — updates local state only; DB write happens on Done Editing. */
  function handleFieldChange(fieldKey: string, newValue: string) {
    // ── Country-first guard ───────────────────────────────────────────────
    const countryKey = getCountryKeyForField(fieldKey);
    if (countryKey) {
      const countryValue = sectionEdits[countryKey] !== undefined
        ? sectionEdits[countryKey]
        : (hireSections.flatMap(s => s.fields).find(f => f.key === countryKey)?.raw_value ?? '');
      if (!countryValue || countryValue.trim() === '' || countryValue === '—') {
        setFieldErrors(prev => ({ ...prev, [fieldKey]: 'Please select a Country first.' }));
        return; // block update and auto-save
      }
    }

    // If this IS a country field being set, clear any country-first errors on sibling fields
    if (newValue && (fieldKey === 'passport.country' || (fieldKey.startsWith('id.') && fieldKey.endsWith('.country')))) {
      const prefix = fieldKey === 'passport.country' ? 'passport.' : fieldKey.replace('.country', '.');
      setFieldErrors(prev => {
        const n = { ...prev };
        Object.keys(n).forEach(k => {
          if (k.startsWith(prefix) && n[k] === 'Please select a Country first.') delete n[k];
        });
        return n;
      });
    }

    setSectionEdits(prev => ({ ...prev, [fieldKey]: newValue }));

    // ── Date cross-field validation (inline) ─────────────────────────────
    const today = new Date().toISOString().slice(0, 10);

    // emp.end_date must not be before emp.hire_date
    if (fieldKey === 'emp.end_date' && newValue && newValue !== '9999-12-31') {
      const hireDateField = hireSections.flatMap(s => s.fields).find(f => f.key === 'emp.hire_date');
      const hireDateVal = (sectionEdits['emp.hire_date'] !== undefined ? sectionEdits['emp.hire_date'] : hireDateField?.raw_value) ?? '';
      if (hireDateVal && newValue < hireDateVal)
        setFieldErrors(prev => ({ ...prev, [fieldKey]: 'End Date cannot be before Hire Date.' }));
      else
        setFieldErrors(prev => ({ ...prev, [fieldKey]: '' }));
    }
    // Re-validate end_date when hire_date changes
    if (fieldKey === 'emp.hire_date' && newValue) {
      const endDateVal = sectionEdits['emp.end_date'] ?? (hireSections.flatMap(s => s.fields).find(f => f.key === 'emp.end_date')?.raw_value ?? '');
      if (endDateVal && endDateVal !== '9999-12-31' && endDateVal < newValue)
        setFieldErrors(prev => ({ ...prev, 'emp.end_date': 'End Date cannot be before Hire Date.' }));
      else
        setFieldErrors(prev => ({ ...prev, 'emp.end_date': '' }));
    }
    // passport/identity expiry must be a future date
    if ((fieldKey === 'passport.expiry_date' || fieldKey.endsWith('.expiry_date')) && newValue && newValue <= today)
      setFieldErrors(prev => ({ ...prev, [fieldKey]: 'Expiry Date must be a future date.' }));

    // Clear any completeness violations for this field as the approver fills it
    setHireViolations(prev => prev.filter(v => {
      const sec = hireSections.find(s => s.fields.some(f => f.key === fieldKey));
      return !(sec && v.section === sec.section && v.label === (sec.fields.find(f => f.key === fieldKey)?.label ?? ''));
    }));
  }

  // ── Picklist option renderer (needs hirePl from hook) ────────────────────
  function renderPicklistOptions(fieldKey: string, plCode: string | null, currentRaw: string) {
    const col = fieldKey.split('.').pop() ?? '';

    // Department select — options from departments table
    if (col === 'dept_id') {
      return deptOptions.map(d => <option key={d.id} value={d.id}>{d.name}</option>);
    }
    // Manager select — options from employees table
    if (col === 'manager_id') {
      return empOptions.map(e => <option key={e.id} value={e.id}>{e.name}</option>);
    }

    // Static options — nationality (stored as country name text)
    if (col === 'nationality') {
      return COUNTRIES.map(c => <option key={c} value={c}>{c}</option>);
    }
    // Static options — gender (stored as text)
    if (col === 'gender') {
      return ['Male', 'Female'].map(g => <option key={g} value={g}>{g}</option>);
    }
    // Record Type — stored as plain text ('primary', 'secondary'), not a UUID.
    // Use static text options so the stored value round-trips correctly.
    if (col === 'record_type') {
      return ['primary', 'secondary'].map(rt => (
        <option key={rt} value={rt}>{rt.charAt(0).toUpperCase() + rt.slice(1)}</option>
      ));
    }
    // ID Type — filter by the sibling country field for THIS identity record.
    // Use getCountryKeyForField to get e.g. 'id.new.country' or 'id.<uuid>.country',
    // then check sectionEdits first (live edit) and fall back to raw_value (on load).
    // Fall back to ALL ID_TYPE values if no country is selected yet, so an already-
    // stored UUID still pre-selects correctly.
    if (col === 'id_type') {
      const countryKey = getCountryKeyForField(fieldKey);
      const parentId   = countryKey
        ? (sectionEdits[countryKey] ?? hireSections.flatMap(s => s.fields).find(f => f.key === countryKey)?.raw_value ?? '')
        : '';
      const filtered   = hirePl.filter(
        p => p.picklistId === 'ID_TYPE' && (!parentId || String(p.parentValueId) === parentId)
      );
      const opts = filtered.length > 0 ? filtered : hirePl.filter(p => p.picklistId === 'ID_TYPE');
      return opts.map(p => <option key={String(p.id)} value={String(p.id)}>{p.value}</option>);
    }
    // Work Location — filter by selected work_country; fall back to all LOCATION values
    if (col === 'work_location') {
      const wcKey    = Object.keys(sectionEdits).find(k => k.endsWith('work_country'));
      const parentId = wcKey ? sectionEdits[wcKey] : '';
      const filtered = hirePl.filter(
        p => p.picklistId === 'LOCATION' && (!parentId || String(p.parentValueId) === parentId)
      );
      const opts = filtered.length > 0 ? filtered : hirePl.filter(p => p.picklistId === 'LOCATION');
      return opts.map(p => <option key={String(p.id)} value={String(p.id)}>{p.value}</option>);
    }
    // Generic picklist (UUID-keyed options)
    if (plCode) {
      return hirePl
        .filter(p => p.picklistId === plCode)
        .map(p => <option key={String(p.id)} value={String(p.id)}>{p.value}</option>);
    }
    return null;
  }

  // ── Shared action state (both top + bottom bars share it) ─────────────────
  const [comment,        setComment]        = useState('');
  const [mode,           setMode]           = useState<'idle' | 'reassign' | 'return_init' | 'return_prev'>('idle');
  const [actionLoading,  setActionLoading]  = useState(false);
  const [actionError,    setActionError]    = useState<string | null>(null);
  const [actionSuccess,  setActionSuccess]  = useState<string | null>(null);
  const [reassignTarget, setReassignTarget] = useState<Person | null>(null);

  // Reset on mode change
  useEffect(() => {
    setActionError(null);
  }, [mode]);

  // fn may return a string to override successMsg (used when the message depends
  // on async state resolved inside fn, e.g. final vs. intermediate approval).
  async function run(fn: () => Promise<string | void>, successMsg: string) {
    setActionLoading(true); setActionError(null);
    try {
      const override = await fn();
      setActionSuccess(override ?? successMsg);
      setComment(''); setMode('idle'); setReassignTarget(null);
      // Go back to inbox after a moment — reopen the same task by passing its id
      setTimeout(() => navigate(myTask ? `/workflow/inbox?task=${myTask.taskId}` : '/workflow/inbox'), 1800);
    } catch (e) {
      setActionError((e as Error).message);
    } finally {
      setActionLoading(false);
    }
  }

  function handleApprove() {
    if (!myTask) return;
    // ── Hire module: validate required fields before allowing activation ──────
    if (isHireModule) {
      const violations = validateHireFields();
      if (violations.length > 0) {
        setHireViolations(violations);
        return;
      }
    }
    setHireViolations([]);

    run(async () => {
      // ── profile_bank: check the 20th-of-month approval cutoff via RPC ───────
      // The trigger is the authoritative guard; this pre-check gives a cleaner
      // UX message before an RPC roundtrip. We ask the DB whether the current
      // approver is exempt (is_bank_exception) and block client-side if not.
      if (isProfileBankModule) {
        const dayOfMonth = new Date().getDate();
        if (dayOfMonth > 20) {
          const { data: gates } = await supabase.rpc('get_profile_workflow_gates');
          const isBankException = (gates as any)?.is_bank_exception ?? false;
          if (!isBankException) {
            throw new Error(
              `Bank account changes cannot be approved after the 20th of the month (today is the ${dayOfMonth}th). ` +
              'Only bank_exceptions, admin, or hr role holders may approve after this date.'
            );
          }
        }
      }

      await approve(myTask.taskId, comment.trim() || undefined);

      // ── Check if this was the final approval step ─────────────────────────
      // Done once and reused for both OTP dispatch and toast message.
      // DB-side activation (status=Active, locked=false, invite record) is
      // handled by wf_sync_module_status → wf_activate_employee (mig 224).
      // We only need to fire the OTP magic-link here because Supabase Auth
      // cannot be called from PostgreSQL.
      let isFinalStep = false;
      if (isHireModule && recordId) {
        const { data: inst } = await supabase
          .from('workflow_instances')
          .select('status')
          .eq('module_code', 'employee_hire')
          .eq('record_id', recordId)
          .eq('status', 'approved')
          .limit(1)
          .maybeSingle();
        isFinalStep = inst !== null;

        if (isFinalStep) {
          // Final approval — send the welcome / magic-link email
          const { data: empRow } = await supabase
            .from('employees')
            .select('business_email, name')
            .eq('id', recordId)
            .maybeSingle();
          const email = (empRow as any)?.business_email;
          if (email) {
            const { error: otpErr } = await supabase.auth.signInWithOtp({
              email,
              options: {
                shouldCreateUser: true,
                emailRedirectTo: `${window.location.origin}/reset-password`,
                data: { full_name: (empRow as any)?.name },
              },
            });
            if (otpErr) {
              setInviteErrorModal({
                open: true,
                title: 'Invite Email Not Sent',
                message: `The employee was activated successfully, but the welcome email could not be sent.\n\nReason: ${otpErr.message}\n\nThe employee can still sign in by requesting a magic link from the login page. You may also retry by re-activating from the hire record.`,
              });
            } else {
              // Retry link_profile_to_employee up to 4 times with backoff.
              // auth.users row may not be immediately visible cross-transaction.
              let linkData: { ok?: boolean; reason?: string } | null = null;
              let linkErr: { message: string } | null = null;
              for (let attempt = 0; attempt < 4; attempt++) {
                if (attempt > 0) await new Promise(r => setTimeout(r, 800 * attempt));
                const result = await supabase.rpc('link_profile_to_employee', { p_email: email });
                linkErr = result.error as { message: string } | null;
                linkData = result.data as { ok?: boolean; reason?: string } | null;
                if (!linkErr && linkData?.ok) break;
                // Stop retrying if it's a non-transient failure
                const reason = linkData?.reason ?? '';
                if (!reason.includes('auth user not found') && !reason.includes('profile row not yet')) break;
              }
              const linkReason = linkData?.reason ?? '';
              if (linkErr || (linkReason && !linkData?.ok)) {
                const detail = linkErr?.message ?? linkReason;
                setInviteErrorModal({
                  open: true,
                  title: 'Profile Link Issue',
                  message: `The employee was activated and the welcome email was sent, but linking the auth profile failed.\n\nReason: ${detail}\n\nPlease go to Admin → Security → Password Reset and verify the employee appears. If not, ask the employee to click "Forgot password" on the login page.`,
                });
              }
            }
          }
        }
      }

      // Return dynamic message so run() can display the correct toast
      if (isHireModule) {
        return isFinalStep ? 'Hire approved — employee activated!' : 'Approved — awaiting next step';
      }
    });
  }

  function handleReject() {
    if (!myTask) return;
    if (!comment.trim()) { setActionError('Rejection reason is required.'); return; }
    run(() => reject(myTask.taskId, comment.trim()),
      isHireModule ? 'Hire request rejected' : 'Rejected successfully');
  }

  function handleConfirmSecondary() {
    if (!myTask) return;
    if (mode === 'reassign') {
      if (!reassignTarget) { setActionError('Select a person to reassign to.'); return; }
      run(() => reassign(myTask.taskId, reassignTarget.id, comment.trim() || undefined), 'Task reassigned');
    } else if (mode === 'return_init') {
      if (!comment.trim()) { setActionError('A message to the initiator is required.'); return; }
      run(() => returnToInitiator(myTask.taskId, comment.trim()), 'Returned for clarification');
    } else if (mode === 'return_prev') {
      run(() => returnToPreviousStep(myTask.taskId, comment.trim() || undefined), 'Returned to previous step');
    }
  }

  // ── Initiator: resubmit after edits ────────────────────────────────────────
  async function handleInitiatorResubmit() {
    if (!wf.instance) { setActionError('Workflow instance not loaded. Please try again.'); return; }
    // Hire module: validate required fields before allowing resubmit
    if (isHireModule) {
      const violations = validateHireFields();
      if (violations.length > 0) {
        setHireViolations(violations);
        return;
      }
    }
    setHireViolations([]);
    setActionLoading(true);
    setActionError(null);
    try {
      await wf.resubmit(comment.trim() || undefined);
      setActionSuccess('Resubmitted for approval');
      setComment('');
      setMode('idle');
      setTimeout(() => navigate('/workflow/inbox?tab=sent_back'), 1800);
    } catch (e) {
      setActionError((e as Error).message);
    } finally {
      setActionLoading(false);
    }
  }

  // ── Initiator: withdraw (discard) a rejected hire ─────────────────────────
  async function handleInitiatorWithdraw() {
    if (!wf.instance) { setActionError('Workflow instance not loaded. Please try again.'); return; }
    setActionLoading(true);
    setActionError(null);
    try {
      const { error: err } = await supabase.rpc('wf_withdraw', {
        p_instance_id: wf.instance.id,
        p_reason:      comment.trim() || null,
      });
      if (err) throw new Error(err.message);
      setActionSuccess('Hire record discarded');
      setComment('');
      setTimeout(() => navigate('/workflow/inbox?tab=sent_back'), 1800);
    } catch (e) {
      setActionError((e as Error).message);
    } finally {
      setActionLoading(false);
    }
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  const lineItems = detail?.lineItems ?? [];
  const allAttachments = lineItems.flatMap(li => (li.attachments ?? []).map(a => ({ ...a, categoryName: li.categoryName })));
  const baseCurr = detail?.baseCurrencyCode ?? '';

  const actionBarProps = {
    taskId:                 myTask?.taskId ?? '',
    stepOrder:              myTask?.stepOrder ?? 1,
    comment,
    onCommentChange:        setComment,
    loading:                actionLoading,
    error:                  actionError,
    onApprove:              handleApprove,
    onReject:               handleReject,
    mode,
    onModeChange:           setMode,
    onConfirmSecondary:     handleConfirmSecondary,
    reassignTarget,
    onReassignTargetChange: setReassignTarget,
    // Pattern A: Update button
    // • Hire module  → puts ALL sections into inline edit mode at once (no navigation)
    //   When already editing, the button becomes "Done Editing" and closes all sections.
    // • Other modules → navigates to full edit form (Pattern A original behaviour)
    isSavingHireEdits,
    onCancelHireEdit: isHireModule && editingSections.size > 0
      ? handleCancelEdit
      : isTerminationModule && termApproverEditing
        ? () => { setTermApproverEditing(false); setTermApproverError(null); }
        : undefined,
    isInitiator,
    onResubmit: isInitiator && wf.instance?.status === 'awaiting_clarification'
      ? handleInitiatorResubmit : undefined,
    onWithdraw: isInitiator && wf.instance?.status === 'rejected'
      ? handleInitiatorWithdraw : undefined,
    onUpdate: canEditMidFlight
      ? isHireModule
        ? editingSections.size > 0
          ? handleDoneEditing
          : enterAllEdit
        : isTerminationModule
          ? termApproverEditing
            ? undefined  // Update button hidden while editing; Cancel handles close
            : () => {
                setTermApproverLwd(String((termRecord as any)?.last_working_date ?? ''));
                setTermApproverWaiver(Boolean((termRecord as any)?.notice_period_waived));
                setTermApproverWaiverReason(String((termRecord as any)?.notice_period_waiver_reason ?? ''));
                setTermApproverError(null);
                setTermApproverEditing(true);
              }
          : editRoute && recordId
            ? () => {
                const base = editRoute.replace(':id', recordId);
                const sep  = base.includes('?') ? '&' : '?';
                navigate(`${base}${sep}returnTo=${encodeURIComponent(`/workflow/review/${recordId}`)}`);
              }
            : undefined
      : undefined,
    isHireEditMode: (isHireModule && editingSections.size > 0) || (isTerminationModule && termApproverEditing),
  };

  return (
    <div className="wfr-root">

      {/* ── Sticky top nav + action bar ──────────────────────────────────── */}
      <div className="wfr-sticky-header">

        {/* Nav bar */}
        <div className="wfr-nav-bar">
          <button className="wfr-back-btn" onClick={() => navigate(
            isInitiator ? '/workflow/inbox?tab=sent_back'
            : myTask    ? `/workflow/inbox?task=${myTask.taskId}`
            : '/workflow/inbox'
          )}>
            <i className="fas fa-arrow-left" />
            {isInitiator ? 'Back to Sent Back' : 'Back to Inbox'}
          </button>

          <div className="wfr-nav-center">
            {isHireModule && hireName ? (
              <>
                <div className="wfr-nav-title">{hireName}</div>
                <div className="wfr-nav-subtitle">
                  New Hire Request
                  {hireSubmittedAt && <> · {fmtDate(hireSubmittedAt)}</>}
                  {myTask && <> · Step {myTask.stepOrder} — {myTask.stepName}</>}
                  {isInitiator && wf.instance?.status === 'rejected'
                    ? <> · Rejected</>
                    : isInitiator && <> · Sent Back for Clarification</>}
                </div>
              </>
            ) : detail ? (
              <>
                <div className="wfr-nav-title">{detail.name}</div>
                <div className="wfr-nav-subtitle">
                  Submitted by {detail.employeeName ?? '—'}
                  {detail.submittedAt && <> · {fmtDate(detail.submittedAt)}</>}
                </div>
              </>
            ) : isTerminationModule ? (
              <>
                <div className="wfr-nav-title">
                  {myTask?.subjectEmployeeName ?? myTask?.submittedByName ?? 'Termination Request'}
                </div>
                <div className="wfr-nav-subtitle">
                  {(termRecord as any)?.termination_initiation_type === 'SELF' ? 'Resignation' : 'Termination'}
                  {myTask && <> · Step {myTask.stepOrder} — {myTask.stepName}</>}
                  {wf.instance?.createdAt && <> · {fmtDate(wf.instance.createdAt)}</>}
                </div>
              </>
            ) : null}
          </div>

          <div className="wfr-nav-actions">
            {detail && (
              <span className="wfr-nav-total">
                {baseCurr} {detail.totalConverted.toLocaleString('en-IN', { minimumFractionDigits: 2 })}
              </span>
            )}
            <WorkflowStatusBadge
              status={(isInitiator ? wf.instance?.status : undefined) ?? 'pending'}
              size="sm"
            />
          </div>
        </div>

      </div>

      {/* ── Success banner ────────────────────────────────────────────────── */}
      {actionSuccess && (
        <div className="wfr-success-banner">
          <i className="fas fa-circle-check" />
          {actionSuccess} — returning to inbox…
        </div>
      )}

      {/* ── Main content — scrollable area between top bar and action bar ── */}
      <div className="wfr-scroll-area">
      <div className="wfr-content">

        {/* Loading */}
        {loading && (
          <div className="wfr-loading">
            <i className="fas fa-spinner fa-spin wfr-loading-icon" />
            Loading report…
          </div>
        )}

        {/* Error */}
        {error && !loading && (
          <div className="wfr-error">
            <i className="fas fa-triangle-exclamation wfr-error-icon" />
            <strong>Could not load report</strong>
            <p style={{ margin: '8px 0 0' }}>{error}</p>
          </div>
        )}

        {/* ── Employee Hire Review (module_code = employee_hire) ──────────── */}
        {isHireModule && (
          <>
            {hireLoading && (
              <div className="wfr-loading">
                <i className="fas fa-spinner fa-spin wfr-loading-icon" />
                Loading employee details…
              </div>
            )}
            {hireError && !hireLoading && (
              <div className="wfr-error">
                <i className="fas fa-triangle-exclamation wfr-error-icon" />
                <strong>Could not load hire details</strong>
                <p style={{ margin: '8px 0 0' }}>{hireError}</p>
              </div>
            )}
            {!hireLoading && !hireError && hireSections.length > 0 && (
              <>
                {/* Hire header card */}
                <div className="wfr-card">
                  <div className="wfr-card-header">
                    <i className="fas fa-user-plus wfr-card-header-icon" />
                    <span className="wfr-card-header-label">New Hire Request</span>
                    {myTask && (() => {
                      const SLA_CFG = {
                        on_track: { color: '#16A34A', bg: '#F0FDF4', border: '#BBF7D0', label: 'On Track'  },
                        due_soon: { color: '#D97706', bg: '#FFFBEB', border: '#FDE68A', label: 'Due Soon'  },
                        overdue:  { color: '#DC2626', bg: '#FEF2F2', border: '#FECACA', label: 'Overdue'   },
                      };
                      const sla = SLA_CFG[myTask.slaStatus];
                      return (
                        <span style={{ marginLeft: 'auto', fontSize: 11, fontWeight: 700, color: sla.color, background: sla.bg, border: `0.5px solid ${sla.border}`, borderRadius: 4, padding: '2px 8px', display: 'inline-flex', alignItems: 'center', gap: 5 }}>
                          <span style={{ width: 6, height: 6, borderRadius: '50%', background: sla.color, display: 'inline-block' }} />
                          {sla.label}
                        </span>
                      );
                    })()}
                  </div>
                  <div className="wfr-summary-grid">
                    <SummaryItem label="Employee"     value={hireName || '—'} />
                    <SummaryItem label="Submitted on" value={hireSubmittedAt ? fmtDate(hireSubmittedAt) : '—'} />
                    <SummaryItem label="Current step" value={
                      myTask
                        ? `Step ${myTask.stepOrder} — ${myTask.stepName}`
                        : isInitiator && wf.instance
                          ? `Step ${wf.instance.currentStep}${currentStepTask ? ` — ${currentStepTask.stepName}` : ''}`
                          : '—'
                    } sub={
                      !myTask && currentStepTask?.assigneeName
                        ? `with: ${currentStepTask.assigneeName}`
                        : undefined
                    } />
                    <SummaryItem label="Sections"     value={String(hireSections.length)} last />
                  </div>
                </div>

                {/* ── Initiator: send-back note callout ───────────────────────────── */}
                {isInitiator && wf.instance?.status === 'awaiting_clarification' && (() => {
                  const sendBackEvent = [...wf.history]
                    .reverse()
                    .find(h => h.action === 'returned_to_initiator');
                  if (!sendBackEvent?.notes) return null;
                  return (
                    <div style={{
                      background: '#FFFBEB', border: '1px solid #FDE68A',
                      borderLeft: '4px solid #D97706', borderRadius: 8,
                      padding: '12px 16px', marginBottom: 12, display: 'flex', gap: 12,
                    }}>
                      <i className="fas fa-comment-dots" style={{ color: '#D97706', fontSize: 16, marginTop: 2, flexShrink: 0 }} />
                      <div>
                        <div style={{ fontWeight: 600, fontSize: 13, color: '#92400E', marginBottom: 4 }}>
                          Approver note{sendBackEvent.actorName ? ` from ${sendBackEvent.actorName}` : ''}
                        </div>
                        <div style={{ fontSize: 13, color: '#78350F', lineHeight: 1.5 }}>{sendBackEvent.notes}</div>
                      </div>
                    </div>
                  );
                })()}

                {/* ── Initiator: rejection callout ────────────────────────────────── */}
                {isInitiator && wf.instance?.status === 'rejected' && (() => {
                  const rejectEvent = [...wf.history]
                    .reverse()
                    .find(h => h.action === 'rejected');
                  return (
                    <div style={{
                      background: '#FEF2F2', border: '1px solid #FECACA',
                      borderLeft: '4px solid #DC2626', borderRadius: 8,
                      padding: '12px 16px', marginBottom: 12, display: 'flex', gap: 12,
                    }}>
                      <i className="fas fa-circle-xmark" style={{ color: '#DC2626', fontSize: 16, marginTop: 2, flexShrink: 0 }} />
                      <div>
                        <div style={{ fontWeight: 600, fontSize: 13, color: '#991B1B', marginBottom: 4 }}>
                          Rejection reason{rejectEvent?.actorName ? ` from ${rejectEvent.actorName}` : ''}
                        </div>
                        <div style={{ fontSize: 13, color: '#7F1D1D', lineHeight: 1.5 }}>
                          {rejectEvent?.notes
                            ? rejectEvent.notes
                            : <em style={{ color: '#9CA3AF' }}>No reason provided.</em>}
                        </div>
                        <div style={{ marginTop: 8, fontSize: 12, color: '#B91C1C' }}>
                          This hire request has been rejected and is read-only. Use the <strong>Discard Record</strong> button below to remove it.
                        </div>
                      </div>
                    </div>
                  );
                })()}

                {/* Stacked employee sections — MyProfile-style with section Edit button */}
                {editError && (
                  <div className="wfr-error-banner" style={{ marginBottom: 10, fontSize: 13 }}>
                    <i className="fas fa-triangle-exclamation" /> {editError}
                    <button onClick={() => setEditError(null)} style={{ marginLeft: 10, background: 'none', border: 'none', cursor: 'pointer', color: 'inherit' }}>✕</button>
                  </div>
                )}
                <div className="mp-sections">
                  {(() => {
                    const nodes: React.ReactNode[] = [];
                    let identityRendered = false;
                    let bankRendered     = false;
                    let depRendered      = false;
                    let eduRendered      = false;

                    for (const sec of hireSections) {
                      // ── Bank Accounts — rendered via BankAccountsPortlet ──────────────
                      if (sec.section.startsWith('Bank Account')) {
                        if (bankRendered) continue;
                        bankRendered = true;
                        nodes.push(
                          <div key="bank-accounts" className="mp-section">
                            <div className="emp-section-label" style={{ marginBottom: 12, paddingBottom: 0, borderBottom: 'none' }}>
                              <i className="fas fa-building-columns" />
                              Bank Accounts
                            </div>
                            <BankAccountsPortlet
                              employeeId={recordId!}
                              isNewHire={true}
                              hireDate={hireDate ?? undefined}
                              canEdit={canEditMidFlight && can('bank_accounts.edit') && editingSections.size > 0}
                              readOnly={!canEditMidFlight}
                              editMode={canEditMidFlight && editingSections.size > 0}
                              reviewMode={true}
                              saveAllRef={bankSaveAllRef}
                            />
                          </div>
                        );
                        continue;
                      }

                      // ── Dependents — rendered via DependentsPortlet ───────────────────
                      if (sec.section.startsWith('Dependent')) {
                        if (depRendered) continue;
                        depRendered = true;
                        nodes.push(
                          <div key="dependents" className="mp-section">
                            <div className="emp-section-label" style={{ marginBottom: 12, paddingBottom: 0, borderBottom: 'none' }}>
                              <i className="fas fa-people-group" />
                              Dependents
                            </div>
                            <DependentsPortlet
                              employeeId={recordId!}
                              isNewHire={true}
                              hireDate={hireDate ?? undefined}
                              canEdit={canEditMidFlight && can('dependents.edit') && editingSections.size > 0}
                              canDelete={false}
                              readOnly={!canEditMidFlight}
                              editMode={canEditMidFlight && editingSections.size > 0}
                              reviewMode={true}
                              saveAllRef={depSaveAllRef}
                            />
                          </div>
                        );
                        continue;
                      }

                      // ── Education — rendered via EducationPortlet ─────────────────────
                      if (sec.section.startsWith('Education')) {
                        if (eduRendered) continue;
                        eduRendered = true;
                        nodes.push(
                          <div key="education" className="mp-section">
                            <div className="emp-section-label" style={{ marginBottom: 12, paddingBottom: 0, borderBottom: 'none' }}>
                              <i className="fas fa-graduation-cap" />
                              Education
                            </div>
                            <EducationPortlet
                              employeeId={recordId!}
                              isNewHire={true}
                              canEdit={canEditMidFlight && can('education.edit') && editingSections.size > 0}
                              canDelete={false}
                              canCreate={canEditMidFlight && can('education.create') && editingSections.size > 0}
                              readOnly={!canEditMidFlight}
                              editMode={canEditMidFlight && editingSections.size > 0}
                              saveTriggerRef={eduSaveAllRef}
                            />
                          </div>
                        );
                        continue;
                      }

                      // ── Identity Document — table + add form (multi-record) ──────────
                      // Section names from DB: 'Identity Document' (no records) or
                      // 'Identity Document 1', 'Identity Document 2' … (with records).
                      // Use startsWith to match all variants.
                      if (sec.section.startsWith('Identity Document')) {
                        if (identityRendered) continue; // already rendered the block
                        identityRendered = true;

                        const allIdentitySecs = hireSections.filter(s => s.section.startsWith('Identity Document'));
                        const isEditMode = [...editingSections].some(s => s.startsWith('Identity Document'));

                        // Collect existing (non-placeholder) records
                        const existingRecords = allIdentitySecs
                          .map(s => {
                            const recId = identityRecordId(s);
                            if (!recId) return null; // skip id.new.* placeholder
                            const gf = (col: string) => s.fields.find(f => f.key === `id.${recId}.${col}`);
                            return {
                              id:              recId,
                              record_type:     gf('record_type')?.value     ?? '—',
                              country:         gf('country')?.value         ?? '—',
                              id_type:         gf('id_type')?.value         ?? '—',
                              id_number:       gf('id_number')?.value       ?? '—',
                              expiry:          gf('expiry')?.value          ?? '—',
                              // raw values (UUIDs) for pre-filling the edit form
                              raw_record_type: gf('record_type')?.raw_value ?? '',
                              raw_country:     gf('country')?.raw_value     ?? '',
                              raw_id_type:     gf('id_type')?.raw_value     ?? '',
                              raw_id_number:   gf('id_number')?.raw_value   ?? gf('id_number')?.value ?? '',
                              raw_expiry:      gf('expiry')?.raw_value      ?? gf('expiry')?.value    ?? '',
                            };
                          })
                          .filter(Boolean) as { id: string; record_type: string; country: string; id_type: string; id_number: string; expiry: string; raw_record_type: string; raw_country: string; raw_id_type: string; raw_id_number: string; raw_expiry: string }[];

                        const idTypeOpts = hirePl.filter(
                          p => p.picklistId === 'ID_TYPE' && (!newIdForm.country || String(p.parentValueId) === newIdForm.country)
                        );

                        nodes.push(
                          <div key="identity-document" className="mp-section">
                            <div className="wfr-hire-sec-header">
                              <div className="emp-section-label" style={{ marginBottom: 0, borderBottom: 'none', paddingBottom: 0 }}>
                                <i className="fas fa-id-card-clip" />
                                Identity Document
                              </div>
                            </div>
                            <div style={{ marginTop: 12 }} />

                            {/* Existing records table */}
                            {existingRecords.length > 0 ? (
                              <table className="emp-id-table" style={{ marginBottom: 20 }}>
                                <thead>
                                  <tr>
                                    <th>Type</th><th>Country</th><th>ID Type</th>
                                    <th>ID Number</th><th>Expiry</th><th>Record</th>
                                    {isEditMode && <th />}
                                  </tr>
                                </thead>
                                <tbody>
                                  {existingRecords.map(r => (
                                    <tr key={r.id}>
                                      <td>{r.record_type !== '—' ? r.record_type.charAt(0).toUpperCase() + r.record_type.slice(1) : '—'}</td>
                                      <td>{r.country}</td>
                                      <td>{r.id_type}</td>
                                      <td>{r.id_number}</td>
                                      <td>{r.expiry}</td>
                                      <td>
                                        {r.record_type !== '—' && (
                                          <span style={{ fontSize: 11, background: '#EFF6FF', color: '#1D4ED8', borderRadius: 4, padding: '2px 6px' }}>
                                            {r.record_type.charAt(0).toUpperCase() + r.record_type.slice(1)}
                                          </span>
                                        )}
                                      </td>
                                      {isEditMode && (
                                        <td>
                                          <div style={{ display: 'flex', gap: 4 }}>
                                            <button
                                              style={{ background: 'none', border: '1px solid #E5E7EB', borderRadius: 5, color: '#6B7280', cursor: 'pointer', padding: '2px 7px' }}
                                              title="Edit this record"
                                              onClick={() => {
                                                handleDeleteIdRecord(r.id, existingRecords);
                                                setNewIdForm({
                                                  country:     r.raw_country,
                                                  id_type:     r.raw_id_type,
                                                  record_type: r.raw_record_type,
                                                  id_number:   r.raw_id_number,
                                                  expiry:      r.raw_expiry,
                                                });
                                                setTimeout(() => document.getElementById('wfr-identity-add-form')?.scrollIntoView({ behavior: 'smooth', block: 'center' }), 100);
                                              }}
                                            >
                                              <i className="fa-solid fa-pen" style={{ fontSize: 11 }} />
                                            </button>
                                            <button
                                              style={{ background: 'none', border: 'none', color: '#EF4444', cursor: 'pointer', padding: '2px 6px' }}
                                              title="Remove this record"
                                              onClick={() => handleDeleteIdRecord(r.id, existingRecords)}
                                            >
                                              <i className="fa-solid fa-trash" />
                                            </button>
                                          </div>
                                        </td>
                                      )}
                                    </tr>
                                  ))}
                                </tbody>
                              </table>
                            ) : (
                              !isEditMode && (
                                <p style={{ color: '#9CA3AF', fontSize: 13, marginBottom: 16 }}>No identity documents recorded.</p>
                              )
                            )}

                            {/* Add-ID form — visible in edit mode */}
                            {isEditMode && (
                              <div id="wfr-identity-add-form" style={{ background: '#F9FAFB', borderRadius: 8, padding: '14px 16px', border: '1px solid #E5E7EB' }}>
                                <div className="ev-field-grid ev-grid-4" style={{ marginBottom: 12 }}>
                                  {/* Country */}
                                  <div>
                                    <div className="ev-field-label">Country</div>
                                    <select className="wfr-field-input" value={newIdForm.country}
                                      onChange={e => {
                                        const next = e.target.value;
                                        const hasFilled = newIdForm.id_type || newIdForm.record_type || newIdForm.id_number || newIdForm.expiry;
                                        if (hasFilled && next !== newIdForm.country) {
                                          setIdCountryPending(next);
                                        } else {
                                          setNewIdForm(f => ({ ...f, country: next, id_type: '' }));
                                          setNewIdErrors({});
                                        }
                                      }}>
                                      <option value="">— select —</option>
                                      {hirePl.filter(p => p.picklistId === 'ID_COUNTRY')
                                        .map(p => <option key={String(p.id)} value={String(p.id)}>{p.value}</option>)}
                                    </select>
                                    {newIdErrors.country && <span className="wfr-field-error">{newIdErrors.country}</span>}
                                  </div>

                                  {/* ID Type — filtered by country */}
                                  <div>
                                    <div className="ev-field-label">ID Type</div>
                                    <select className="wfr-field-input" value={newIdForm.id_type}
                                      disabled={!newIdForm.country}
                                      onChange={e => {
                                        const val = e.target.value;
                                        // Auto-default expiry based on type validity
                                        const countryName = hirePl.find(p => String(p.id) === newIdForm.country)?.value ?? '';
                                        const typeName    = hirePl.find(p => String(p.id) === val)?.value ?? '';
                                        const def = val ? defaultExpiryDate(countryName, typeName) : null;
                                        setNewIdForm(f => ({ ...f, id_type: val, expiry: def ?? f.expiry }));
                                        setNewIdErrors(err => ({ ...err, id_type: '' }));
                                      }}>
                                      <option value="">{newIdForm.country ? '— select —' : '— Select Country First —'}</option>
                                      {idTypeOpts.map(p => <option key={String(p.id)} value={String(p.id)}>{p.value}</option>)}
                                    </select>
                                    {newIdErrors.id_type && <span className="wfr-field-error">{newIdErrors.id_type}</span>}
                                  </div>

                                  {/* Record Type */}
                                  <div>
                                    <div className="ev-field-label">Record Type</div>
                                    <select className="wfr-field-input" value={newIdForm.record_type}
                                      onChange={e => {
                                        setNewIdForm(f => ({ ...f, record_type: e.target.value }));
                                        setNewIdErrors(err => ({ ...err, record_type: '' }));
                                      }}>
                                      <option value="">— select —</option>
                                      <option value="primary"
                                        disabled={existingRecords.some(r => r.record_type === 'primary')}>
                                        {existingRecords.some(r => r.record_type === 'primary')
                                          ? '⭐ Primary (already assigned)' : '⭐ Primary'}
                                      </option>
                                      <option value="secondary"
                                        disabled={!existingRecords.some(r => r.raw_record_type === 'primary')}>
                                        {!existingRecords.some(r => r.raw_record_type === 'primary')
                                          ? 'Secondary (add primary first)' : 'Secondary'}
                                      </option>
                                    </select>
                                    {newIdErrors.record_type && <span className="wfr-field-error">{newIdErrors.record_type}</span>}
                                  </div>

                                  {/* ID Number */}
                                  <div>
                                    <div className="ev-field-label">ID Number</div>
                                    <input className="wfr-field-input" type="text" value={newIdForm.id_number}
                                      placeholder={idNumberPlaceholder(
                                        hirePl.find(p => String(p.id) === newIdForm.country)?.value ?? '',
                                        hirePl.find(p => String(p.id) === newIdForm.id_type)?.value ?? '',
                                      )}
                                      onChange={e => {
                                        const val = e.target.value;
                                        setNewIdForm(f => ({ ...f, id_number: val }));
                                        const countryName = hirePl.find(p => String(p.id) === newIdForm.country)?.value ?? '';
                                        const typeName    = hirePl.find(p => String(p.id) === newIdForm.id_type)?.value ?? '';
                                        const err = val ? validateIdentityNumber(countryName, typeName, val) : '';
                                        setNewIdErrors(prev => ({ ...prev, id_number: err ?? '' }));
                                      }} />
                                    {!newIdErrors.id_number && newIdForm.id_type && (() => {
                                      const hint = idNumberHint(
                                        hirePl.find(p => String(p.id) === newIdForm.country)?.value ?? '',
                                        hirePl.find(p => String(p.id) === newIdForm.id_type)?.value ?? '',
                                      );
                                      return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />{hint}</div> : null;
                                    })()}
                                    {newIdErrors.id_number && <span className="wfr-field-error">{newIdErrors.id_number}</span>}
                                  </div>

                                  {/* Expiry — spans 2 columns */}
                                  <div style={{ gridColumn: 'span 2' }}>
                                    <div className="ev-field-label">Expiry Date</div>
                                    <input className="wfr-field-input" type="date" min="1900-01-01" max="2100-12-31" value={newIdForm.expiry}
                                      onChange={e => {
                                        const v = e.target.value;
                                        setNewIdForm(f => ({ ...f, expiry: v }));
                                        const today = new Date().toISOString().slice(0, 10);
                                        if (v && v <= today) setNewIdErrors(prev => ({ ...prev, expiry: 'Expiry Date must be a future date.' }));
                                        else setNewIdErrors(prev => ({ ...prev, expiry: '' }));
                                      }} />
                                    {newIdErrors.expiry && <span className="wfr-field-error">{newIdErrors.expiry}</span>}
                                    {newIdForm.id_type && (() => {
                                      const lbl = idValidityLabel(
                                        hirePl.find(p => String(p.id) === newIdForm.country)?.value ?? '',
                                        hirePl.find(p => String(p.id) === newIdForm.id_type)?.value ?? '',
                                      );
                                      return lbl ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-clock" style={{ marginRight: 4 }} />{lbl}</div> : null;
                                    })()}
                                  </div>
                                </div>

                                {newIdErrors._root && (
                                  <p style={{ color: '#EF4444', fontSize: 12, margin: '0 0 8px' }}>{newIdErrors._root}</p>
                                )}

                                <button className="emp-id-add-btn" onClick={handleAddIdRecord} disabled={savingNewId}>
                                  {savingNewId
                                    ? <><i className="fas fa-spinner fa-spin" /> Adding…</>
                                    : <><i className="fas fa-plus" /> Add ID</>}
                                </button>
                              </div>
                            )}
                          </div>
                        );
                        continue;
                      }

                      // ── All other sections — portlet-style card with field grid ─────────
                      const isEditMode = editingSections.has(sec.section);
                      nodes.push(
                        <div key={sec.section} className="mp-section">
                          <div className="wfr-sec-card">
                            {/* Card header — matches portlet header style */}
                            <div style={{
                              display: 'flex', alignItems: 'center', gap: 10,
                              padding: '12px 14px', margin: '-20px -22px 16px',
                              borderBottom: '1px solid #F3F4F6',
                              background: '#FAFAFA', borderRadius: '10px 10px 0 0',
                            }}>
                              <i className={`fas ${hireSectionIcon(sec.section)}`}
                                style={{ color: '#6366F1', fontSize: 15, flexShrink: 0 }} />
                              <span style={{ fontWeight: 600, fontSize: 13, color: '#111827' }}>
                                {sec.section}
                              </span>
                              {/* Edit button in header */}
                              {(() => {
                                const editBtn = isEditMode
                                  ? null
                                  : canEditMidFlight && !isInitiator && sec.fields.some(f => f.editable) ? (
                                    <button className="wfr-sec-edit-btn" style={{ marginLeft: 'auto' }}
                                      onClick={() => enterSectionEdit(sec)}>
                                      <i className="fas fa-pen" /> Edit
                                    </button>
                                  ) : null;
                                return editBtn;
                              })()}
                            </div>

                          {/* Full Name banner — shown above the grid for Personal Info */}
                          {sec.fields.find(f => f.key === 'emp.full_name') && (() => {
                            const fn = sec.fields.find(f => f.key === 'emp.full_name')!;
                            return fn.value && fn.value !== '—' ? (
                              <div style={{ marginBottom: 16, padding: '8px 12px',
                                background: '#F5F3FF', borderRadius: 8, border: '1px solid #DDD6FE',
                                display: 'flex', alignItems: 'center', gap: 10 }}>
                                <i className="fa-solid fa-user" style={{ color: '#7C3AED', fontSize: 14 }} />
                                <div>
                                  <div style={{ fontSize: 10, fontWeight: 700, color: '#7C3AED',
                                    textTransform: 'uppercase', letterSpacing: '0.05em' }}>Full Name</div>
                                  <div style={{ fontWeight: 600, fontSize: 15, color: '#1E1B4B' }}>{fn.value}</div>
                                </div>
                              </div>
                            ) : null;
                          })()}

                          {/* Field grid — 4 columns matches AddEmployee form layout */}
                          <div className="ev-field-grid ev-grid-4">
                            {sec.fields.filter(f => f.key !== 'emp.full_name').map((f, fIdx) => {
                              const val    = isEditMode && f.editable && f.key ? sectionEdits[f.key] ?? '' : '';
                              const plCode = fieldPicklistCode(f.key);
                              const isOrphan = fIdx === sec.fields.filter(f => f.key !== 'emp.full_name').length - 1 && sec.fields.filter(f => f.key !== 'emp.full_name').length % 4 === 1;
                              return (
                                <div key={f.label} style={isOrphan ? { gridColumn: 'span 2' } : undefined}>
                                  <div className="ev-field-label">
                                    {f.label}
                                    {f.required && <span className="wfr-required-star"> *</span>}
                                  </div>
                                  {isEditMode && f.editable && f.key ? (
                                    <div style={{ position: 'relative' }}>
                                    {f.input_type === 'emp_select' ? (
                                      <EmpSearchInput
                                        value={val}
                                        options={empOptions}
                                        onSelect={(id, _name) => handleFieldChange(f.key!, id)}
                                      />
                                    ) : f.input_type === 'phone_code' ? (
                                      <select
                                        className="wfr-field-input"
                                        value={val}
                                        onChange={e => handleFieldChange(f.key!, e.target.value)}
                                      >
                                        <option value="">— select —</option>
                                        {PHONE_CODES.map(pc => (
                                          <option key={pc.code} value={pc.code}>
                                            {pc.flag} {pc.code}
                                          </option>
                                        ))}
                                      </select>
                                    ) : (f.input_type === 'select' || f.input_type === 'dept_select') ? (
                                      <select
                                        className="wfr-field-input"
                                        value={val}
                                        onChange={e => handleFieldChange(f.key!, e.target.value)}
                                      >
                                        <option value="">— select —</option>
                                        {renderPicklistOptions(f.key, plCode, val)}
                                      </select>
                                    ) : (
                                      <>
                                      <input
                                        className="wfr-field-input"
                                        type={f.input_type ?? 'text'}
                                        value={val}
                                        onChange={e => handleFieldChange(f.key!, e.target.value)}
                                        placeholder={f.key === 'passport.passport_number' ? (() => {
                                          const passSection = hireSections.find(s => s.section.startsWith('Passport'));
                                          const countryField = passSection?.fields.find(fd => fd.key === 'passport.country');
                                          const countryId = (countryField?.key && sectionEdits[countryField.key] !== undefined) ? sectionEdits[countryField.key] : (countryField?.raw_value ?? '');
                                          const countryName = hirePl.find(p => String(p.id) === countryId)?.value ?? '';
                                          return passportNumberPlaceholder(countryName);
                                        })() : undefined}
                                      />
                                      {!fieldErrors[f.key] && (f.key === 'passport.passport_number' || f.key === 'passport.expiry_date') && (() => {
                                        const passSection = hireSections.find(s => s.section.startsWith('Passport'));
                                        const countryField = passSection?.fields.find(fd => fd.key === 'passport.country');
                                        const countryId = (countryField?.key && sectionEdits[countryField.key] !== undefined) ? sectionEdits[countryField.key] : (countryField?.raw_value ?? '');
                                        const countryName = hirePl.find(p => String(p.id) === countryId)?.value ?? '';
                                        const hint = f.key === 'passport.passport_number'
                                          ? passportNumberHint(countryName)
                                          : passportValidityHint(countryName);
                                        return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className={`fa-solid ${f.key === 'passport.expiry_date' ? 'fa-clock' : 'fa-circle-info'}`} style={{ marginRight: 4 }} />{hint}</div> : null;
                                      })()}
                                      </>
                                    )}
                                    {fieldErrors[f.key] && (
                                      <span className="wfr-field-error">{fieldErrors[f.key]}</span>
                                    )}
                                    </div>
                                  ) : (
                                    <div className={`ev-field-value${f.value === '—' ? ' ev-empty' : ''}`}>
                                      {f.value === '—' ? 'Not provided' : f.value}
                                    </div>
                                  )}
                                </div>
                              );
                            })}
                          </div>

                          {/* Attachments — bank proof, dependent docs, education certs */}
                          {Array.isArray(sec.attachments) && sec.attachments.length > 0 && (
                            <div style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 8 }}>
                              {sec.attachments.map((att, aIdx) => (
                                <WfrAttachmentRow
                                  key={String((att as any).file_path ?? (att as any).storage_path ?? aIdx)}
                                  att={att as Record<string, unknown>}
                                  docTypeLabel={String((att as any).document_type ?? (att as any).doc_type ?? 'Document')}
                                />
                              ))}
                            </div>
                          )}
                          </div>{/* end wfr-sec-card */}
                        </div>
                      );
                    }

                    return nodes;
                  })()}
                </div>

                {/* Approval History */}
                {wf.instance && (() => {
                  const visibleEvents = wf.history.filter(h => h.action !== 'step_advanced' && h.action !== 'completed').length
                    + (wf.instance.status === 'in_progress' ? wf.tasks.filter(t => t.status === 'pending').length : 0)
                    + (wf.instance.status === 'awaiting_clarification' ? 1 : 0);
                  return (
                    <Section title="Approval History" icon="fa-clock-rotate-left">
                      <div className="wfr-history-scroll" style={{ maxHeight: visibleEvents > 3 ? 230 : undefined }}>
                        <WorkflowTimeline
                          history={wf.history}
                          tasks={wf.tasks}
                          currentStep={wf.instance.currentStep}
                          status={wf.instance.status}
                        />
                      </div>
                    </Section>
                  );
                })()}
              </>
            )}
          </>
        )}

        {detail && !isHireModule && (
          <>
            {/* ── Report summary card ──────────────────────────────────── */}
            <div className="wfr-card">
              {/* Card header with SLA badge */}
              <div className="wfr-card-header">
                <i className="fas fa-circle-info wfr-card-header-icon" />
                <span className="wfr-card-header-label">Summary</span>
                {myTask && (() => {
                  const SLA_CFG = {
                    on_track: { color: '#16A34A', bg: '#F0FDF4', border: '#BBF7D0', label: 'On Track'  },
                    due_soon: { color: '#D97706', bg: '#FFFBEB', border: '#FDE68A', label: 'Due Soon'  },
                    overdue:  { color: '#DC2626', bg: '#FEF2F2', border: '#FECACA', label: 'Overdue'   },
                  };
                  const sla = SLA_CFG[myTask.slaStatus];
                  return (
                    <span style={{ marginLeft: 'auto', fontSize: 11, fontWeight: 700, color: sla.color, background: sla.bg, border: `0.5px solid ${sla.border}`, borderRadius: 4, padding: '2px 8px', display: 'inline-flex', alignItems: 'center', gap: 5 }}>
                      <span style={{ width: 6, height: 6, borderRadius: '50%', background: sla.color, display: 'inline-block' }} />
                      {sla.label}
                    </span>
                  );
                })()}
              </div>
              {/* Horizontal 5-col meta grid */}
              <div className="wfr-summary-grid">
                <SummaryItem label="Submitted by"  value={detail.employeeName ?? '—'} />
                <SummaryItem label="Submitted on"  value={detail.submittedAt ? fmtDateTime(detail.submittedAt) : '—'} />
                <SummaryItem label="Base currency" value={detail.baseCurrencyCode} />
                <SummaryItem label="Total amount"  value={`${baseCurr} ${detail.totalConverted.toLocaleString('en-IN', { minimumFractionDigits: 2 })}`} highlight />
                <SummaryItem label="Current step"  value={
                  myTask
                    ? `Step ${myTask.stepOrder} — ${myTask.stepName}`
                    : isInitiator && wf.instance
                      ? `Step ${wf.instance.currentStep}${currentStepTask ? ` — ${currentStepTask.stepName}` : ''}`
                      : '—'
                } sub={
                  !myTask && currentStepTask?.assigneeName
                    ? `with: ${currentStepTask.assigneeName}`
                    : undefined
                } last />
              </div>
            </div>

            {/* ── Initiator: send-back note callout ───────────────────────── */}
            {isInitiator && wf.instance?.status === 'awaiting_clarification' && (() => {
              const sendBackEvent = [...wf.history]
                .reverse()
                .find(h => h.action === 'returned_to_initiator');
              if (!sendBackEvent?.notes) return null;
              return (
                <div style={{
                  background: '#FFFBEB', border: '1px solid #FDE68A',
                  borderLeft: '4px solid #D97706', borderRadius: 8,
                  padding: '12px 16px', marginBottom: 12, display: 'flex', gap: 12,
                }}>
                  <i className="fas fa-comment-dots" style={{ color: '#D97706', fontSize: 16, marginTop: 2, flexShrink: 0 }} />
                  <div>
                    <div style={{ fontWeight: 600, fontSize: 13, color: '#92400E', marginBottom: 4 }}>
                      Approver note{sendBackEvent.actorName ? ` from ${sendBackEvent.actorName}` : ''}
                    </div>
                    <div style={{ fontSize: 13, color: '#78350F', lineHeight: 1.5 }}>{sendBackEvent.notes}</div>
                  </div>
                </div>
              );
            })()}

            {/* ── Line Items ───────────────────────────────────────────── */}
            <Section title="Line Items" icon="fa-list" count={lineItems.length}>
              {/* TWO-TABLE layout: header is a separate table outside the scroll div so it
                  is always visible regardless of scroll position. Both tables share identical
                  colgroup widths so columns stay perfectly aligned.
                  (position:sticky on <th> was unreliable here due to multiple overflow:auto
                  ancestors in the layout — wfr-root, wfr-scroll-area — confusing Chrome.) */}

              {/* ① Fixed header — never scrolls */}
              <table className="wf-table" style={{ tableLayout: 'fixed' }}>
                <colgroup>
                  <col style={{ width: '4%' }} /><col style={{ width: '14%' }} />
                  <col style={{ width: '10%' }} /><col style={{ width: '12%' }} />
                  <col style={{ width: '13%' }} /><col style={{ width: '13%' }} />
                  <col /><col style={{ width: '10%' }} />
                </colgroup>
                <thead className="wf-thead">
                  <tr className="wf-thead-row">
                    {['#', 'Category', 'Date', 'Project', 'Amount', 'Converted', 'Note', 'Attachments',
                    ].map(h => <th key={h} className="wfr-th">{h}</th>)}
                  </tr>
                </thead>
              </table>

              {/* ② Scrollable body */}
              <div className="wfr-table-scroll" style={{ maxHeight: lineItems.length > 5 ? 220 : undefined }}>
                <table className="wf-table" style={{ tableLayout: 'fixed' }}>
                  <colgroup>
                    <col style={{ width: '4%' }} /><col style={{ width: '14%' }} />
                    <col style={{ width: '10%' }} /><col style={{ width: '12%' }} />
                    <col style={{ width: '13%' }} /><col style={{ width: '13%' }} />
                    <col /><col style={{ width: '10%' }} />
                  </colgroup>
                  <tbody>
                    {lineItems.map((li, i) => (
                      <tr key={li.id} style={{ borderBottom: i < lineItems.length - 1 ? '1px solid #F3F4F6' : 'none' }}>
                        <td className="wf-td-num">{i + 1}</td>
                        <td className="wf-td-main">{li.categoryName || '—'}</td>
                        <td className="wf-td-date">{fmtDate(li.date)}</td>
                        <td className="wf-td-muted">{li.projectName || '—'}</td>
                        <td className="wf-td-amount">{fmtAmount(li.amount, li.currencyCode)}</td>
                        <td className="wf-td-converted">{fmtAmount(li.convertedAmount, baseCurr)}</td>
                        <td className="wf-td-note">
                          <span className="wf-note-text">{li.note || '—'}</span>
                        </td>
                        <td className="wf-td-att">
                          {!li.attachments?.length ? (
                            <span className="wf-att-empty">—</span>
                          ) : li.attachments.length === 1 ? (
                            <a href={li.attachments[0].dataUrl} target="_blank" rel="noopener noreferrer"
                              title={li.attachments[0].name} className="wf-att-link">
                              <i className="fas fa-paperclip wf-att-icon" /> 1
                            </a>
                          ) : (
                            <div className="wf-att-multi">
                              {li.attachments.map(att => (
                                <a key={att.id} href={att.dataUrl} target="_blank" rel="noopener noreferrer"
                                  title={att.name} className="wf-att-link wf-att-link--multi">
                                  <i className={`fas ${att.type === 'application/pdf' ? 'fa-file-pdf' : att.type.startsWith('image/') ? 'fa-file-image' : 'fa-file'} wf-att-icon`}
                                    style={{ color: att.type === 'application/pdf' ? '#DC2626' : '#2563EB' }} />
                                  <span className="wf-att-name">{att.name}</span>
                                </a>
                              ))}
                            </div>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot>
                    <tr className="wf-tfoot-row">
                      <td colSpan={5} className="wf-tfoot-label">Total</td>
                      <td className="wf-tfoot-value">{fmtAmount(detail.totalConverted, baseCurr)}</td>
                      <td /><td />
                    </tr>
                  </tfoot>
                </table>
              </div>
            </Section>

            {/* Attachments are shown inline per line item — no separate flat section */}

            {/* ── Approval History ─────────────────────────────────────── */}
            {wf.instance && (() => {
              // Count visible events (same filter WorkflowTimeline applies)
              const visibleEvents = wf.history.filter(h => h.action !== 'step_advanced' && h.action !== 'completed').length
                + (wf.instance.status === 'in_progress' ? wf.tasks.filter(t => t.status === 'pending').length : 0)
                + (wf.instance.status === 'awaiting_clarification' ? 1 : 0);
              return (
                <Section title="Approval History" icon="fa-clock-rotate-left">
                  <div
                    className="wfr-history-scroll"
                    style={{ maxHeight: visibleEvents > 3 ? 230 : undefined }}
                  >
                    <WorkflowTimeline
                      history={wf.history}
                      tasks={wf.tasks}
                      currentStep={wf.instance.currentStep}
                      status={wf.instance.status}
                    />
                  </div>
                </Section>
              );
            })()}
          </>
        )}
        {/* ── Profile Bank Change Review (module_code = profile_bank) ──────── */}
        {isProfileBankModule && (
          <>
            {bankChangeLoading && (
              <div className="wfr-loading">
                <i className="fas fa-spinner fa-spin wfr-loading-icon" />
                Loading bank change details…
              </div>
            )}
            {bankChangeError && !bankChangeLoading && (
              <div className="wfr-error">
                <i className="fas fa-triangle-exclamation wfr-error-icon" />
                <strong>Could not load bank change details</strong>
                <p style={{ margin: '8px 0 0' }}>{bankChangeError}</p>
              </div>
            )}
            {!bankChangeLoading && !bankChangeError && (() => {
              // Build set-snapshot diff keyed by bank_account_group_id
              type BankDiffStatus = 'new' | 'amended' | 'removed' | 'unchanged';
              type BankDiffItem = {
                status: BankDiffStatus;
                proposed: WfrBankItem | null;
                current: WfrBankItem | null;
                groupId: string | null;
                changedFields: string[];
              };

              const BANK_CMP_FIELDS = [
                'bank_name', 'account_holder_name', 'account_number',
                'country_code', 'currency_code', 'branch_name', 'branch_code',
                'ifsc_code', 'iban', 'swift_bic', 'is_primary',
              ];
              const BANK_FIELD_LABELS: Record<string, string> = {
                bank_name: 'Bank Name', account_holder_name: 'Account Holder',
                account_number: 'Account Number', country_code: 'Country',
                currency_code: 'Currency', branch_name: 'Branch Name',
                branch_code: 'Branch Code', ifsc_code: 'IFSC Code',
                iban: 'IBAN', swift_bic: 'SWIFT / BIC', is_primary: 'Primary',
              };

              const currentByGroup = new Map(bankCurrentItems.map(c => [String(c.bank_account_group_id ?? ''), c]));
              const proposedGroupIds = new Set(
                bankProposedItems.filter(p => p.bank_account_group_id).map(p => String(p.bank_account_group_id))
              );

              const bankDiff: BankDiffItem[] = [];
              // NEW items (no group_id)
              for (const p of bankProposedItems.filter(p => !p.bank_account_group_id))
                bankDiff.push({ status: 'new', proposed: p, current: null, groupId: null, changedFields: [] });
              // Existing items
              for (const p of bankProposedItems.filter(p => p.bank_account_group_id)) {
                const gid = String(p.bank_account_group_id);
                const c = currentByGroup.get(gid);
                if (!c) { bankDiff.push({ status: 'new', proposed: p, current: null, groupId: gid, changedFields: [] }); continue; }
                const changed = BANK_CMP_FIELDS.filter(f => String((p as any)[f] ?? '') !== String((c as any)[f] ?? ''));
                bankDiff.push({ status: changed.length > 0 ? 'amended' : 'unchanged', proposed: p, current: c, groupId: gid, changedFields: changed });
              }
              // REMOVED items (in current, not in proposed)
              for (const c of bankCurrentItems)
                if (!proposedGroupIds.has(String(c.bank_account_group_id ?? '')))
                  bankDiff.push({ status: 'removed', proposed: null, current: c, groupId: String(c.bank_account_group_id ?? ''), changedFields: [] });

              const counts = {
                added:     bankDiff.filter(d => d.status === 'new').length,
                amended:   bankDiff.filter(d => d.status === 'amended').length,
                removed:   bankDiff.filter(d => d.status === 'removed').length,
                unchanged: bankDiff.filter(d => d.status === 'unchanged').length,
              };

              const fmtBankVal = (key: string, val: unknown): string => {
                if (val == null || val === '') return '—';
                if (key === 'is_primary') return (val === true || val === 'true') ? 'Yes' : 'No';
                if (key === 'account_number') return String(val).length > 4
                  ? '•'.repeat(String(val).length - 4) + String(val).slice(-4)
                  : String(val);
                return String(val);
              };

              const ssBankStyle = (s: BankDiffStatus) => ({
                new:       { border: '#BBF7D0', bg: '#F0FDF4', color: '#059669', badgeBg: '#ECFDF5', label: 'NEW'       },
                amended:   { border: '#FDE68A', bg: '#FFFBEB', color: '#D97706', badgeBg: '#FFFBEB', label: 'AMENDED'   },
                removed:   { border: '#FECACA', bg: '#FEF2F2', color: '#DC2626', badgeBg: '#FEF2F2', label: 'REMOVED'   },
                unchanged: { border: '#E5E7EB', bg: '#fff',    color: '#6B7280', badgeBg: '#F3F4F6', label: 'UNCHANGED' },
              }[s]);

              return (
                <>
                  {/* Summary card */}
                  <div className="wfr-card">
                    <div className="wfr-card-header">
                      <i className="fas fa-building-columns wfr-card-header-icon" />
                      <span className="wfr-card-header-label">Bank Accounts Change</span>
                      {bankEffectiveFrom && (
                        <span style={{ marginLeft: 8, fontSize: 11, color: '#6366F1', fontWeight: 600 }}>
                          Effective {new Date(bankEffectiveFrom + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}
                        </span>
                      )}
                    </div>
                    <div style={{ padding: '10px 16px 14px', display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                      {counts.added   > 0 && <span style={{ background: '#ECFDF5', color: '#059669', border: '1px solid #BBF7D0', borderRadius: 6, padding: '4px 12px', fontSize: 12, fontWeight: 600 }}>+{counts.added} added</span>}
                      {counts.amended > 0 && <span style={{ background: '#FFFBEB', color: '#D97706', border: '1px solid #FDE68A', borderRadius: 6, padding: '4px 12px', fontSize: 12, fontWeight: 600 }}>{counts.amended} amended</span>}
                      {counts.removed > 0 && <span style={{ background: '#FEF2F2', color: '#DC2626', border: '1px solid #FECACA', borderRadius: 6, padding: '4px 12px', fontSize: 12, fontWeight: 600 }}>−{counts.removed} removed</span>}
                      {counts.unchanged > 0 && <span style={{ background: '#F3F4F6', color: '#6B7280', border: '1px solid #E5E7EB', borderRadius: 6, padding: '4px 12px', fontSize: 12 }}>{counts.unchanged} unchanged</span>}
                    </div>
                  </div>

                  {/* Per-item diff cards */}
                  <Section title="Proposed Bank Accounts" icon="fa-building-columns">
                    {bankDiff.map((item, idx) => {
                      const data = item.proposed ?? item.current;
                      if (!data) return null;
                      const ss = ssBankStyle(item.status);
                      return (
                        <div key={idx} style={{
                          border: `1.5px solid ${ss.border}`, borderRadius: 10, marginBottom: 10,
                          background: ss.bg, overflow: 'hidden', opacity: item.status === 'removed' ? 0.85 : 1,
                        }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', borderBottom: '1px solid rgba(0,0,0,0.05)' }}>
                            <i className="fa-solid fa-building-columns" style={{ color: ss.color, fontSize: 15, flexShrink: 0 }} />
                            <div style={{ flex: 1, minWidth: 0 }}>
                              <div style={{ fontWeight: 600, fontSize: 13.5, color: '#111827',
                                textDecoration: item.status === 'removed' ? 'line-through' : 'none',
                                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                {String(data.bank_name || '—')}
                              </div>
                              {data.account_holder_name && (
                                <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
                                  {String(data.account_holder_name)}
                                </div>
                              )}
                            </div>
                            {data.is_primary && (
                              <span style={{ background: '#EEF2FF', color: '#4F46E5', borderRadius: 5, padding: '2px 7px', fontSize: 10, fontWeight: 700 }}>Primary</span>
                            )}
                            <span style={{ background: ss.badgeBg, color: ss.color, borderRadius: 5, padding: '2px 8px', fontSize: 10, fontWeight: 700 }}>{ss.label}</span>
                          </div>
                          <div style={{ padding: '10px 14px 14px' }}>
                            <div className="ev-field-grid ev-grid-4">
                              {BANK_CMP_FIELDS.filter(f => f !== 'is_primary').map(key => {
                                const val    = item.proposed ? (item.proposed as any)[key] : (item.current as any)[key];
                                const oldVal = item.current  ? (item.current  as any)[key] : undefined;
                                const changed = item.status === 'amended' && item.changedFields.includes(key);
                                const display = fmtBankVal(key, val);
                                if (display === '—' && !changed) return null;
                                return (
                                  <div key={key}>
                                    <div className="ev-field-label">{BANK_FIELD_LABELS[key]}</div>
                                    <div style={{ fontSize: 13, color: '#111827', fontWeight: changed ? 600 : 400,
                                      background: changed ? '#FEFCE8' : 'transparent',
                                      borderRadius: changed ? 4 : 0, padding: changed ? '2px 6px' : 0 }}>
                                      {display === '—'
                                        ? <span style={{ color: '#9CA3AF', fontStyle: 'italic' }}>Not provided</span>
                                        : display}
                                    </div>
                                    {changed && oldVal !== undefined && (
                                      <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 2, textDecoration: 'line-through' }}>
                                        was: {fmtBankVal(key, oldVal)}
                                      </div>
                                    )}
                                  </div>
                                );
                              })}
                            </div>
                          </div>
                        </div>
                      );
                    })}
                    {bankDiff.length === 0 && (
                      <div style={{ textAlign: 'center', color: '#9CA3AF', fontSize: 13, padding: '16px 0' }}>
                        No bank account items in this change request.
                      </div>
                    )}
                  </Section>

                  {/* Approval History */}
                  {wf.instance && (() => {
                    const visibleEvents = wf.history.filter(h => h.action !== 'step_advanced' && h.action !== 'completed').length
                      + (wf.instance.status === 'in_progress' ? wf.tasks.filter(t => t.status === 'pending').length : 0)
                      + (wf.instance.status === 'awaiting_clarification' ? 1 : 0);
                    return (
                      <Section title="Approval History" icon="fa-clock-rotate-left">
                        <div className="wfr-history-scroll" style={{ maxHeight: visibleEvents > 3 ? 230 : undefined }}>
                          <WorkflowTimeline
                            history={wf.history}
                            tasks={wf.tasks}
                            currentStep={wf.instance.currentStep}
                            status={wf.instance.status}
                          />
                        </div>
                      </Section>
                    );
                  })()}
                </>
              );
            })()}
          </>
        )}

        {/* ── Profile Dependents Change Review (module_code = profile_dependents) ── */}
        {isProfileDependentsModule && (
          <>
            {depChangeLoading && (
              <div className="wfr-loading">
                <i className="fas fa-spinner fa-spin wfr-loading-icon" />
                Loading dependent change details…
              </div>
            )}
            {depChangeError && !depChangeLoading && (
              <div className="wfr-error">
                <i className="fas fa-triangle-exclamation wfr-error-icon" />
                <strong>Could not load dependent change details</strong>
                <p style={{ margin: '8px 0 0' }}>{depChangeError}</p>
              </div>
            )}
            {!depChangeLoading && !depChangeError && (() => {
              // Compute set-snapshot diff
              const currentByCode = new Map(depCurrentItems.map(c => [c.dependent_code, c]));
              const proposedCodes = new Set(
                depProposedItems.filter(p => p.dependent_code).map(p => p.dependent_code as string)
              );
              const DEP_CMP_FIELDS = ['dependent_name', 'relationship_type', 'date_of_birth', 'gender', 'insurance_eligible'];

              const diff: WfrDepDiffItem[] = [];
              for (const p of depProposedItems.filter(p => !p.dependent_code))
                diff.push({ status: 'new', proposed: p, current: null, code: null, changedFields: [] });
              for (const p of depProposedItems.filter(p => p.dependent_code)) {
                const c = currentByCode.get(p.dependent_code!);
                if (!c) { diff.push({ status: 'new', proposed: p, current: null, code: p.dependent_code, changedFields: [] }); continue; }
                const changed = DEP_CMP_FIELDS.filter(f => String((p as any)[f] ?? '') !== String((c as any)[f] ?? ''));
                diff.push({ status: changed.length > 0 ? 'amended' : 'unchanged', proposed: p, current: c, code: p.dependent_code, changedFields: changed });
              }
              for (const c of depCurrentItems)
                if (!proposedCodes.has(c.dependent_code))
                  diff.push({ status: 'removed', proposed: null, current: c, code: c.dependent_code, changedFields: [] });

              const counts = {
                added: diff.filter(d => d.status === 'new').length,
                amended: diff.filter(d => d.status === 'amended').length,
                removed: diff.filter(d => d.status === 'removed').length,
                unchanged: diff.filter(d => d.status === 'unchanged').length,
              };

              // Picklist helpers
              const relPv = hirePl.filter(p => p.picklistId === 'DEPENDENT_RELATIONSHIP_TYPE');
              const docPvDep = hirePl.filter(p => p.picklistId === 'DEPENDENT_DOCUMENT_TYPE');
              const relLbls = relPv.reduce<Record<string, string>>((acc, r) => {
                if (r.refId) acc[String(r.refId)] = r.value;
                if (r.id)   acc[String(r.id)]    = r.value;
                return acc;
              }, {});

              const fmtDepField = (key: string, val: unknown): string => {
                if (val == null || val === '') return '—';
                if (key === 'insurance_eligible') return (val === true || val === 'true') ? 'Yes' : 'No';
                if (key === 'relationship_type')  return relLbls[String(val)] ?? String(val);
                if (/^\d{4}-\d{2}-\d{2}/.test(String(val)))
                  return new Date(String(val) + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
                return String(val);
              };

              const DEP_FIELD_LABELS_WFR: Record<string, string> = {
                dependent_name: 'Dependent Name', relationship_type: 'Relationship',
                date_of_birth: 'Date of Birth', gender: 'Gender', insurance_eligible: 'Insurance Eligible',
              };

              const ssWfr = (s: WfrDepDiffStatus) => ({
                new:       { border: '#BBF7D0', bg: '#F0FDF4', color: '#059669', badgeBg: '#ECFDF5', label: 'NEW'       },
                amended:   { border: '#FDE68A', bg: '#FFFBEB', color: '#D97706', badgeBg: '#FFFBEB', label: 'AMENDED'   },
                removed:   { border: '#FECACA', bg: '#FEF2F2', color: '#DC2626', badgeBg: '#FEF2F2', label: 'REMOVED'   },
                unchanged: { border: '#E5E7EB', bg: '#fff',    color: '#6B7280', badgeBg: '#F3F4F6', label: 'UNCHANGED' },
              }[s]);

              return (
                <>
                  {/* Summary card */}
                  <div className="wfr-card">
                    <div className="wfr-card-header">
                      <i className="fas fa-people-group wfr-card-header-icon" />
                      <span className="wfr-card-header-label">Dependents Change</span>
                      {depEffectiveFrom && (
                        <span style={{ marginLeft: 8, fontSize: 11, color: '#6366F1', fontWeight: 600 }}>
                          Effective {fmtDepField('date_of_birth', depEffectiveFrom)}
                        </span>
                      )}
                    </div>
                    <div style={{ padding: '10px 16px 14px', display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                      {counts.added   > 0 && <span style={{ background: '#ECFDF5', color: '#059669', border: '1px solid #BBF7D0', borderRadius: 6, padding: '4px 12px', fontSize: 12, fontWeight: 600 }}>+{counts.added} added</span>}
                      {counts.amended > 0 && <span style={{ background: '#FFFBEB', color: '#D97706', border: '1px solid #FDE68A', borderRadius: 6, padding: '4px 12px', fontSize: 12, fontWeight: 600 }}>{counts.amended} amended</span>}
                      {counts.removed > 0 && <span style={{ background: '#FEF2F2', color: '#DC2626', border: '1px solid #FECACA', borderRadius: 6, padding: '4px 12px', fontSize: 12, fontWeight: 600 }}>−{counts.removed} removed</span>}
                      {counts.unchanged > 0 && <span style={{ background: '#F3F4F6', color: '#6B7280', border: '1px solid #E5E7EB', borderRadius: 6, padding: '4px 12px', fontSize: 12 }}>{counts.unchanged} unchanged</span>}
                    </div>
                  </div>

                  {/* Per-item diff cards */}
                  <Section title="Proposed Dependents" icon="fa-people-group">
                    {diff.map((item, idx) => {
                      const data = item.proposed ?? item.current;
                      if (!data) return null;
                      const ss   = ssWfr(item.status);
                      const name = String((data as any).dependent_name || '');
                      const dob  = String((data as any).date_of_birth  || '');
                      const gen  = String((data as any).gender         || '');
                      return (
                        <div key={idx} style={{
                          border: `1.5px solid ${ss.border}`, borderRadius: 10, marginBottom: 10,
                          background: ss.bg, overflow: 'hidden', opacity: item.status === 'removed' ? 0.85 : 1,
                        }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', borderBottom: '1px solid rgba(0,0,0,0.05)' }}>
                            <i className="fa-solid fa-person" style={{ color: ss.color, fontSize: 15, flexShrink: 0 }} />
                            <div style={{ flex: 1, minWidth: 0 }}>
                              <div style={{ fontWeight: 600, fontSize: 13.5, color: '#111827',
                                textDecoration: item.status === 'removed' ? 'line-through' : 'none',
                                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                {name || '—'}
                              </div>
                              {dob && <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>{fmtDepField('date_of_birth', dob)}{gen ? ` · ${gen}` : ''}</div>}
                            </div>
                            <span style={{ background: ss.badgeBg, color: ss.color, borderRadius: 5, padding: '2px 8px', fontSize: 10, fontWeight: 700 }}>{ss.label}</span>
                          </div>
                          <div style={{ padding: '10px 14px 14px' }}>
                            <div className="ev-field-grid ev-grid-4">
                              {Object.entries(DEP_FIELD_LABELS_WFR).map(([key, label]) => {
                                const val    = item.proposed ? (item.proposed as any)[key] : (item.current as any)[key];
                                const oldVal = item.current  ? (item.current  as any)[key] : undefined;
                                const changed = item.status === 'amended' && item.changedFields.includes(key);
                                return (
                                  <div key={key}>
                                    <div className="ev-field-label">{label}</div>
                                    <div style={{ fontSize: 13, color: '#111827', fontWeight: changed ? 600 : 400,
                                      background: changed ? '#FEFCE8' : 'transparent',
                                      borderRadius: changed ? 4 : 0, padding: changed ? '2px 6px' : 0 }}>
                                      {fmtDepField(key, val)}
                                    </div>
                                    {changed && oldVal !== undefined && (
                                      <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 2, textDecoration: 'line-through' }}>
                                        was: {fmtDepField(key, oldVal)}
                                      </div>
                                    )}
                                  </div>
                                );
                              })}
                            </div>
                            {item.status !== 'removed' && (() => {
                              const atts = Array.isArray((item.proposed as any)?.attachments)
                                ? ((item.proposed as any).attachments as Record<string, unknown>[]) : [];
                              if (!atts.length) return null;
                              return (
                                <div style={{ marginTop: 14, paddingTop: 12, borderTop: '1px solid #F3F4F6' }}>
                                  <div className="ev-field-label" style={{ marginBottom: 6 }}>Documents</div>
                                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                                    {atts.map((att, i) => {
                                      const dPv = docPvDep.find(p =>
                                        String(p.refId) === String(att.document_type) || String(p.id) === String(att.document_type)
                                      );
                                      return <WfrAttachmentRow key={String(att.file_path ?? i)} att={att} docTypeLabel={dPv?.value ?? String(att.document_type ?? 'Document')} />;
                                    })}
                                  </div>
                                </div>
                              );
                            })()}
                          </div>
                        </div>
                      );
                    })}
                    {diff.length === 0 && (
                      <div style={{ textAlign: 'center', color: '#9CA3AF', fontSize: 13, padding: '16px 0' }}>
                        No dependent items in this change request.
                      </div>
                    )}
                  </Section>

                  {wf.instance && (() => {
                    const visibleEvents = wf.history.filter(h => h.action !== 'step_advanced' && h.action !== 'completed').length
                      + (wf.instance.status === 'in_progress' ? wf.tasks.filter(t => t.status === 'pending').length : 0)
                      + (wf.instance.status === 'awaiting_clarification' ? 1 : 0);
                    return (
                      <Section title="Approval History" icon="fa-clock-rotate-left">
                        <div className="wfr-history-scroll" style={{ maxHeight: visibleEvents > 3 ? 230 : undefined }}>
                          <WorkflowTimeline
                            history={wf.history}
                            tasks={wf.tasks}
                            currentStep={wf.instance.currentStep}
                            status={wf.instance.status}
                          />
                        </div>
                      </Section>
                    );
                  })()}
                </>
              );
            })()}
          </>
        )}

        {/* ── Job Relationships Change Review (module_code = profile_job_relationships) ── */}
        {isJobRelationshipsModule && (
          <>
            {jrChangeLoading && (
              <div className="wfr-loading">
                <i className="fas fa-spinner fa-spin wfr-loading-icon" />
                Loading job relationship change details…
              </div>
            )}
            {jrChangeError && !jrChangeLoading && (
              <div className="wfr-error">
                <i className="fas fa-triangle-exclamation wfr-error-icon" />
                <strong>Could not load job relationship change details</strong>
                <p style={{ margin: '8px 0 0' }}>{jrChangeError}</p>
              </div>
            )}
            {!jrChangeLoading && !jrChangeError && (
              <Section title="Job Relationship Changes" icon="fa-sitemap">
                {jrEffectiveFrom && (
                  <div style={{ fontSize: 12.5, color: '#6B7280', marginBottom: 12 }}>
                    <i className="fa-solid fa-calendar-day" style={{ marginRight: 5 }} />
                    Effective from: <strong>{jrEffectiveFrom}</strong>
                  </div>
                )}
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
                  <thead>
                    <tr style={{ background: '#F9FAFB' }}>
                      <th style={{ padding: '8px 12px', textAlign: 'left', fontSize: 11.5, fontWeight: 600, color: '#6B7280' }}>Role</th>
                      <th style={{ padding: '8px 12px', textAlign: 'left', fontSize: 11.5, fontWeight: 600, color: '#6B7280' }}>Proposed</th>
                      <th style={{ padding: '8px 12px', textAlign: 'left', fontSize: 11.5, fontWeight: 600, color: '#6B7280' }}>Current</th>
                    </tr>
                  </thead>
                  <tbody>
                    {JR_CODE_ORDER_WFR.map(code => {
                      const proposed = jrProposedItems.find(i => i.relationship_code === code);
                      const current  = jrCurrentItems.find(i => i.relationship_code === code);
                      const changed  = proposed?.manager_employee_id !== current?.manager_employee_id;
                      if (!proposed && !current) return null;
                      return (
                        <tr key={code} style={{
                          borderTop: '1px solid #F3F4F6',
                          background: changed ? '#FEFCE8' : 'transparent',
                        }}>
                          <td style={{ padding: '8px 12px', fontWeight: 500, color: '#374151' }}>
                            {JR_DEFAULT_LABELS[code] ?? code}
                            <span style={{ marginLeft: 6, fontSize: 11, color: '#9CA3AF' }}>{code}</span>
                          </td>
                          <td style={{ padding: '8px 12px', color: proposed ? '#111827' : '#9CA3AF', fontStyle: proposed ? 'normal' : 'italic' }}>
                            {proposed
                              ? (proposed.manager_name
                                  ? <>{proposed.manager_name} <span style={{ color: '#9CA3AF' }}>({proposed.manager_employee_code})</span></>
                                  : proposed.manager_employee_id)
                              : '— Removed —'
                            }
                          </td>
                          <td style={{ padding: '8px 12px', color: current ? '#6B7280' : '#9CA3AF', fontStyle: current ? 'normal' : 'italic' }}>
                            {current
                              ? (current.manager_name
                                  ? <>{current.manager_name} <span style={{ color: '#9CA3AF' }}>({current.manager_employee_code})</span></>
                                  : current.manager_employee_id)
                              : '— Unassigned —'
                            }
                          </td>
                        </tr>
                      );
                    })}
                    {jrProposedItems.length === 0 && jrCurrentItems.length === 0 && (
                      <tr>
                        <td colSpan={3} style={{ padding: '16px 12px', color: '#9CA3AF', fontSize: 13, fontStyle: 'italic', textAlign: 'center' }}>
                          No job relationship assignments in this change request.
                        </td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </Section>
            )}
          </>
        )}

        {/* ── Profile Education Change Review (module_code = profile_education) ── */}
        {isProfileEducationModule && (
          <>
            {eduChangeLoading && (
              <div className="wfr-loading">
                <i className="fas fa-spinner fa-spin wfr-loading-icon" />
                Loading education change details…
              </div>
            )}
            {eduChangeError && !eduChangeLoading && (
              <div className="wfr-error">
                <i className="fas fa-triangle-exclamation wfr-error-icon" />
                <strong>Could not load education change details</strong>
                <p style={{ margin: '8px 0 0' }}>{eduChangeError}</p>
              </div>
            )}
            {!eduChangeLoading && !eduChangeError && eduProposedData && (
              <Section title="Education Change" icon="fa-graduation-cap">
                {/* Removal notice */}
                {eduProposedData._operation === 'remove' ? (
                  <div style={{
                    padding: '12px 14px', background: '#FEF2F2',
                    border: '1.5px solid #FECACA', borderRadius: 8,
                    fontSize: 13, color: '#B91C1C',
                    display: 'flex', alignItems: 'center', gap: 8,
                  }}>
                    <i className="fa-solid fa-trash-can" />
                    This request removes an existing education record.
                  </div>
                ) : (
                  <>
                    {/* Summary card */}
                    <div className="wfr-card">
                      <div className="wfr-card-header">
                        <i className="fas fa-graduation-cap wfr-card-header-icon" />
                        <span className="wfr-card-header-label">
                          {eduCurrentData ? 'Edit Education Record' : 'New Education Record'}
                        </span>
                        {eduProposedData.is_highest_qualification && (
                          <span style={{ marginLeft: 8, fontSize: 11, color: '#F59E0B', fontWeight: 600 }}>
                            ⭐ Highest Qualification
                          </span>
                        )}
                      </div>
                      <div style={{ padding: '10px 16px 14px', display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: '8px 16px' }}>
                        {[
                          ['Education Level', 'education_level'],
                          ['Degree',          'degree'],
                          ['Institution',     'institution'],

                          ['Start Date',      'start_date'],
                          ['End Date',        'end_date'],
                          ['Status',          'completion_status'],
                          ['Grade / GPA',     'grade_or_gpa'],
                        ].map(([label, key]) => {
                          const proposed = eduProposedData[key];
                          const current  = eduCurrentData?.[key];
                          const changed  = eduCurrentData != null && proposed !== current;
                          const display  = proposed == null || proposed === ''
                            ? null
                            : (key === 'start_date' || key === 'end_date')
                              ? new Date(String(proposed) + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
                              : String(proposed);
                          if (!display && !changed) return null;
                          return (
                            <div key={key}>
                              <div style={{ fontSize: 10.5, color: '#9CA3AF', fontWeight: 600, textTransform: 'uppercase', letterSpacing: 0.4 }}>
                                {label}
                              </div>
                              <div style={{
                                fontSize: 13, fontWeight: changed ? 600 : 400,
                                color: '#111827',
                                background: changed ? '#FEFCE8' : 'transparent',
                                borderRadius: changed ? 4 : 0,
                                padding: changed ? '2px 5px' : 0,
                              }}>
                                {display ?? <span style={{ color: '#9CA3AF', fontStyle: 'italic' }}>—</span>}
                              </div>
                              {changed && current != null && current !== '' && (
                                <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 2, textDecoration: 'line-through' }}>
                                  was: {String(current)}
                                </div>
                              )}
                            </div>
                          );
                        })}
                      </div>
                    </div>

                    {/* Attachments */}
                    {Array.isArray(eduProposedData.attachments) &&
                     (eduProposedData.attachments as Record<string, unknown>[]).filter(a => !a._removed).length > 0 && (
                      <Section title="Documents" icon="fa-paperclip">
                        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                          {(eduProposedData.attachments as Record<string, unknown>[])
                            .filter(a => !a._removed)
                            .map((att, i) => (
                              <WfrAttachmentRow
                                key={String(att.file_path ?? i)}
                                att={att as Parameters<typeof WfrAttachmentRow>[0]['att']}
                                docTypeLabel={String(att.document_type ?? 'Document')}
                              />
                            ))}
                        </div>
                      </Section>
                    )}
                  </>
                )}
              </Section>
            )}
          </>
        )}

        {/* ── Termination Review (module_code = 'termination') ────────────── */}
        {isTerminationModule && (
          <>
            {termLoading && (
              <div className="wfr-loading">
                <i className="fas fa-spinner fa-spin wfr-loading-icon" />
                Loading termination details…
              </div>
            )}
            {termError && !termLoading && (
              <div className="wfr-error">
                <i className="fas fa-triangle-exclamation wfr-error-icon" />
                <strong>Could not load termination details</strong>
                <p style={{ margin: '8px 0 0' }}>{termError}</p>
              </div>
            )}
            {!termLoading && !termError && termRecord && (() => {
              const isReversal = !!(termRecord as any).reversal_reason;
              const fmtD = (v: unknown) => v
                ? new Date(String(v) + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
                : '—';

              // Dual-read: support both old key (termination_date) and new (separation_date)
              // for in-flight workflow instances created before mig 498.
              const sepDate = (termRecord as any).separation_date ?? (termRecord as any).termination_date;
              const origDate = (termRecord as any).employee_terminations?.separation_date
                             ?? (termRecord as any).employee_terminations?.termination_date;

              const TERM_FIELDS: [string, string][] = isReversal ? [
                ['Reversal Reason',  String((termRecord as any).reversal_reason ?? '—')],
                ['Comments',         String((termRecord as any).comments ?? '—')],
                ['Original Date',    fmtD(origDate)],
              ] : [
                ['Separation Date',  fmtD(sepDate)],
                ['Reason Code',      String((termRecord as any).termination_reason_code ?? '—')],
                ['Initiated By',     String((termRecord as any).termination_initiation_type ?? '—').replace(/_/g, ' ')],
                ['Last Working Day', fmtD((termRecord as any).last_working_date)],
                ['Notice Expiry',    fmtD((termRecord as any).notice_expiry_date)],
                ['Notice Waived',    (termRecord as any).notice_period_waived ? 'Yes' : 'No'],
                ['Eligible Rehire',  (termRecord as any).eligible_for_rehire ? 'Yes' : 'No'],
                ['Regrettable',      (termRecord as any).regrettable_termination == null ? '—' : (termRecord as any).regrettable_termination ? 'Yes' : 'No'],
                ['Comments',         String((termRecord as any).comments ?? '—')],
              ];

              // Inline edit: shown when initiator is sent back AND it's a SELF termination.
              // Reversals are always read-only (single-field, rare, withdraw+resubmit is fine).
              const canAmendInline = isInitiatorEditable
                && !isReversal
                && (termRecord as any).termination_initiation_type === 'SELF';

              return (
                <Section title={isReversal ? 'Termination Reversal' : 'Termination'} icon={isReversal ? 'fa-rotate-left' : 'fa-user-slash'}>

                  {/* ── Inline edit form (sent-back SELF initiator) ── */}
                  {canAmendInline ? (
                    <div className="wfr-card">
                      <div className="wfr-card-header">
                        <i className="fas fa-pen wfr-card-header-icon" />
                        <span className="wfr-card-header-label">Amend Your Request</span>
                        <span style={{ marginLeft: 8, fontSize: 11, color: '#D97706', fontWeight: 600,
                          background: '#FFFBEB', border: '1px solid #FDE68A', borderRadius: 4, padding: '2px 8px' }}>
                          Sent Back for Clarification
                        </span>
                      </div>
                      <div style={{ padding: '14px 16px 16px' }}>
                        {termAmendError && (
                          <div style={{ background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 6,
                            padding: '8px 12px', marginBottom: 12, color: '#DC2626', fontSize: 13 }}>
                            <i className="fas fa-triangle-exclamation" style={{ marginRight: 6 }} />
                            {termAmendError}
                          </div>
                        )}
                        <TerminationForm
                          noticePeriodDays={(termRecord as any).notice_period_days_snapshot ?? 30}
                          submitting={termAmending}
                          submitLabel="Save & Resubmit"
                          hideCancel={true}
                          initialValues={{
                            resignation_date:        (termRecord as any).separation_date ?? '',
                            termination_reason_code: (termRecord as any).termination_reason_code ?? '',
                            comments:                (termRecord as any).comments ?? '',
                          }}
                          onCancel={() => {}}
                          onSubmit={async (data) => {
                            setTermAmending(true);
                            setTermAmendError(null);
                            try {
                              const { data: result, error: rpcErr } = await supabase.rpc(
                                'update_termination',
                                {
                                  p_termination_id:   wf.instance!.recordId,
                                  p_termination_data: {
                                    separation_date:         data.resignation_date,
                                    termination_reason_code: data.termination_reason_code,
                                    comments:                data.comments,
                                  },
                                }
                              );
                              if (rpcErr) throw new Error(rpcErr.message);
                              if (result && !result.ok) throw new Error(result.error ?? 'Update failed.');

                              // Refresh the displayed record
                              const { data: refreshed } = await supabase
                                .from('employee_terminations')
                                .select('*')
                                .eq('id', wf.instance!.recordId)
                                .maybeSingle();
                              if (refreshed) setTermRecord(refreshed);

                              // Trigger resubmit automatically after successful amendment
                              await wf.resubmit('Amended and resubmitted after clarification.');
                              setActionSuccess('Resubmitted for approval');
                              setTimeout(() => navigate('/workflow/inbox?tab=sent_back'), 1800);
                            } catch (e) {
                              setTermAmendError((e as Error).message);
                            } finally {
                              setTermAmending(false);
                            }
                          }}
                        />
                      </div>
                    </div>
                  ) : (
                    /* ── Read-only / approver edit view ── */
                    <>
                      <div className="wfr-card">
                        <div className="wfr-card-header">
                          <i className={`fas ${isReversal ? 'fa-rotate-left' : 'fa-user-slash'} wfr-card-header-icon`} />
                          <span className="wfr-card-header-label">
                            {isReversal ? 'Reverse Termination Request' : 'Termination Request'}
                          </span>
                        </div>
                        {/* ── Read-only fields — always visible ── */}
                        <div style={{ padding: '10px 16px 14px', display: 'flex', flexDirection: 'column', gap: 8 }}>
                          {TERM_FIELDS.map(([label, value]) => (
                            <div key={label} style={{ display: 'flex', gap: 8, fontSize: 13 }}>
                              <span style={{ minWidth: 170, color: '#6B7280', flexShrink: 0 }}>{label}</span>
                              <span style={{ color: '#111827', fontWeight: 500 }}>{value}</span>
                            </div>
                          ))}
                        </div>
                        {/* ── Approver mid-flight edit — shown below read-only fields ── */}
                        {termApproverEditing && !isReversal && (
                          <div style={{ borderTop: '1px solid #E5E7EB', padding: '14px 16px 16px' }}>
                            {termApproverError && (
                              <div style={{ background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 6,
                                padding: '8px 12px', marginBottom: 12, color: '#DC2626', fontSize: 13 }}>
                                <i className="fas fa-triangle-exclamation" style={{ marginRight: 6 }} />
                                {termApproverError}
                              </div>
                            )}
                            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                              <div>
                                <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: '#374151', marginBottom: 4 }}>
                                  Last Working Day <span style={{ color: '#DC2626' }}>*</span>
                                </label>
                                <input type="date" value={termApproverLwd}
                                  onChange={e => setTermApproverLwd(e.target.value)}
                                  style={{ border: '1px solid #D1D5DB', borderRadius: 6, padding: '7px 10px', fontSize: 13, width: '100%', maxWidth: 220 }} />
                              </div>
                              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                                <input type="checkbox" id="wfr-waiver" checked={termApproverWaiver}
                                  onChange={e => setTermApproverWaiver(e.target.checked)}
                                  style={{ accentColor: '#1D4ED8', width: 15, height: 15 }} />
                                <label htmlFor="wfr-waiver" style={{ fontSize: 13, color: '#374151', cursor: 'pointer' }}>
                                  Waive notice period
                                </label>
                              </div>
                              {termApproverWaiver && (
                                <div>
                                  <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: '#374151', marginBottom: 4 }}>
                                    Waiver Reason <span style={{ color: '#DC2626' }}>*</span>
                                  </label>
                                  <input type="text" value={termApproverWaiverReason}
                                    onChange={e => setTermApproverWaiverReason(e.target.value)}
                                    placeholder="Reason for waiving notice period…"
                                    style={{ border: '1px solid #D1D5DB', borderRadius: 6, padding: '7px 10px', fontSize: 13, width: '100%' }} />
                                </div>
                              )}
                              <div style={{ display: 'flex', gap: 8, marginTop: 4 }}>
                                <button
                                  disabled={termApproverSaving}
                                  onClick={async () => {
                                    if (!termApproverLwd) { setTermApproverError('Last Working Day is required.'); return; }
                                    setTermApproverSaving(true); setTermApproverError(null);
                                    try {
                                      const { data: r, error: rpcErr } = await supabase.rpc('update_termination_lwd', {
                                        p_termination_id:              wf.instance!.recordId,
                                        p_last_working_date:           termApproverLwd,
                                        p_notice_period_waiver_reason: termApproverWaiver ? (termApproverWaiverReason || null) : null,
                                      });
                                      if (rpcErr) throw new Error(rpcErr.message);
                                      const result = r as { ok: boolean; error?: string };
                                      if (!result?.ok) throw new Error(result?.error ?? 'Update failed');
                                      const { data: updated } = await supabase.from('employee_terminations').select('*').eq('id', wf.instance!.recordId).maybeSingle();
                                      if (updated) setTermRecord(updated);
                                      setTermApproverEditing(false);
                                    } catch (e) {
                                      setTermApproverError((e as Error).message);
                                    } finally {
                                      setTermApproverSaving(false);
                                    }
                                  }}
                                  style={{ background: '#1D4ED8', color: '#fff', border: 'none', borderRadius: 6,
                                    padding: '8px 16px', fontSize: 13, fontWeight: 600, cursor: termApproverSaving ? 'not-allowed' : 'pointer', opacity: termApproverSaving ? 0.7 : 1 }}>
                                  {termApproverSaving ? <><i className="fas fa-spinner fa-spin" style={{ marginRight: 6 }} />Saving…</> : 'Save Changes'}
                                </button>
                                <button onClick={() => { setTermApproverEditing(false); setTermApproverError(null); }}
                                  style={{ background: '#fff', color: '#374151', border: '1px solid #D1D5DB', borderRadius: 6,
                                    padding: '8px 16px', fontSize: 13, fontWeight: 500, cursor: 'pointer' }}>
                                  Cancel
                                </button>
                              </div>
                            </div>
                          </div>
                        )}
                      </div>
                      {/* ── Reassign direct reports panel ── */}
                      {!isReversal && can('termination.reassign.view') && (
                        <div className="wfr-card" style={{ marginTop: 12 }}>
                          <div className="wfr-card-header" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                              <i className="fas fa-sitemap wfr-card-header-icon" />
                              <span className="wfr-card-header-label">Direct Report Reassignments</span>
                            </div>
                            {can('termination.reassign.edit') && !reassignEditing && (
                              <button
                                onClick={() => {
                                  const rows: ReassignRow[] = Array.isArray((termRecord as any)?.direct_report_reassignments)
                                    ? (termRecord as any).direct_report_reassignments
                                    : [];
                                  setReassignDraft(rows.map(r => ({ ...r })));
                                  setReassignSearch({});
                                  setReassignResults({});
                                  setReassignError(null);
                                  setReassignEditing(true);
                                }}
                                style={{ fontSize: 12, color: '#1D4ED8', background: 'none', border: 'none', cursor: 'pointer', fontWeight: 500 }}>
                                <i className="fas fa-pen" style={{ marginRight: 4, fontSize: 11 }} />Edit
                              </button>
                            )}
                          </div>

                          {/* Read-only view */}
                          {!reassignEditing && (
                            <div style={{ padding: '10px 16px 14px', display: 'flex', flexDirection: 'column', gap: 8 }}>
                              {Array.isArray((termRecord as any)?.direct_report_reassignments)
                                && (termRecord as any).direct_report_reassignments.length > 0
                                ? ((termRecord as any).direct_report_reassignments as ReassignRow[]).map((r, i) => (
                                    <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                                      <span style={{ color: '#374151', fontWeight: 500 }}>{r.employee_name ?? r.employee_id}</span>
                                      <i className="fas fa-arrow-right" style={{ color: '#9CA3AF', fontSize: 10 }} />
                                      <span style={{ color: r.new_manager_name || r.new_manager_id ? '#1D4ED8' : '#9CA3AF', fontWeight: 500 }}>
                                        {r.new_manager_name ?? r.new_manager_id ?? 'Not assigned'}
                                      </span>
                                    </div>
                                  ))
                                : <div style={{ fontSize: 13, color: '#6B7280' }}>No direct report reassignments recorded.</div>
                              }
                            </div>
                          )}

                          {/* Edit view */}
                          {reassignEditing && (
                            <div style={{ padding: '10px 16px 16px', display: 'flex', flexDirection: 'column', gap: 12 }}>
                              {reassignError && (
                                <div style={{ background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 6,
                                  padding: '8px 12px', color: '#DC2626', fontSize: 13 }}>
                                  <i className="fas fa-triangle-exclamation" style={{ marginRight: 6 }} />{reassignError}
                                </div>
                              )}
                              {reassignDraft.length === 0 && (
                                <div style={{ fontSize: 13, color: '#6B7280' }}>No direct reports to reassign.</div>
                              )}
                              {reassignDraft.map((row, i) => (
                                <div key={i} style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: '10px 12px', background: '#F9FAFB', borderRadius: 6 }}>
                                  <div style={{ fontSize: 13, fontWeight: 600, color: '#374151' }}>{row.employee_name ?? row.employee_id}</div>
                                  <label style={{ fontSize: 11, color: '#6B7280', fontWeight: 500 }}>New Manager</label>
                                  {/* If already assigned, show chip with option to change */}
                                  {row.new_manager_id && !reassignSearch[i] ? (
                                    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                                      <span style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 500 }}>{row.new_manager_name ?? row.new_manager_id}</span>
                                      <button onClick={() => setReassignSearch(s => ({ ...s, [i]: ' ' }))}
                                        style={{ fontSize: 11, color: '#6B7280', background: 'none', border: 'none', cursor: 'pointer', textDecoration: 'underline' }}>
                                        Change
                                      </button>
                                    </div>
                                  ) : (
                                    <div style={{ position: 'relative' }}>
                                      <input
                                        type="text"
                                        value={reassignSearch[i] ?? ''}
                                        placeholder="Search employee…"
                                        onChange={async e => {
                                          const q = e.target.value;
                                          setReassignSearch(s => ({ ...s, [i]: q }));
                                          if (q.length < 2) { setReassignResults(r => ({ ...r, [i]: [] })); return; }
                                          const { data } = await supabase
                                            .from('employees')
                                            .select('id, name')
                                            .ilike('name', `%${q}%`)
                                            .eq('is_active', true)
                                            .limit(8);
                                          setReassignResults(r => ({ ...r, [i]: data ?? [] }));
                                        }}
                                        style={{ width: '100%', border: '1px solid #D1D5DB', borderRadius: 6, padding: '7px 10px', fontSize: 13 }}
                                      />
                                      {(reassignResults[i] ?? []).length > 0 && (
                                        <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, background: '#fff',
                                          border: '1px solid #E5E7EB', borderRadius: 6, zIndex: 50, boxShadow: '0 4px 12px rgba(0,0,0,.1)', maxHeight: 180, overflowY: 'auto' }}>
                                          {(reassignResults[i] ?? []).map(emp => (
                                            <div key={emp.id}
                                              onClick={() => {
                                                setReassignDraft(d => d.map((r2, j) => j === i
                                                  ? { ...r2, new_manager_id: emp.id, new_manager_name: emp.name }
                                                  : r2));
                                                setReassignSearch(s => { const n = { ...s }; delete n[i]; return n; });
                                                setReassignResults(r => { const n = { ...r }; delete n[i]; return n; });
                                              }}
                                              style={{ padding: '8px 12px', fontSize: 13, cursor: 'pointer', color: '#374151' }}
                                              onMouseEnter={e => (e.currentTarget.style.background = '#F3F4F6')}
                                              onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}>
                                              {emp.name}
                                            </div>
                                          ))}
                                        </div>
                                      )}
                                    </div>
                                  )}
                                </div>
                              ))}
                              <div style={{ display: 'flex', gap: 8, marginTop: 4 }}>
                                <button
                                  disabled={reassignSaving}
                                  onClick={async () => {
                                    setReassignSaving(true); setReassignError(null);
                                    try {
                                      const { data: r, error: rpcErr } = await supabase.rpc('update_termination_reassignments', {
                                        p_termination_id: wf.instance!.recordId,
                                        p_reassignments:  reassignDraft,
                                      });
                                      if (rpcErr) throw new Error(rpcErr.message);
                                      if (!(r as any)?.ok) throw new Error((r as any)?.error ?? 'Save failed');
                                      const { data: updated } = await supabase.from('employee_terminations').select('*').eq('id', wf.instance!.recordId).maybeSingle();
                                      if (updated) setTermRecord(updated);
                                      setReassignEditing(false);
                                    } catch (e) {
                                      setReassignError((e as Error).message);
                                    } finally {
                                      setReassignSaving(false);
                                    }
                                  }}
                                  style={{ background: '#1D4ED8', color: '#fff', border: 'none', borderRadius: 6,
                                    padding: '8px 16px', fontSize: 13, fontWeight: 600, cursor: reassignSaving ? 'not-allowed' : 'pointer', opacity: reassignSaving ? 0.7 : 1 }}>
                                  {reassignSaving ? <><i className="fas fa-spinner fa-spin" style={{ marginRight: 6 }} />Saving…</> : 'Save'}
                                </button>
                                <button onClick={() => { setReassignEditing(false); setReassignError(null); }}
                                  style={{ background: '#fff', color: '#374151', border: '1px solid #D1D5DB', borderRadius: 6,
                                    padding: '8px 16px', fontSize: 13, fontWeight: 500, cursor: 'pointer' }}>
                                  Cancel
                                </button>
                              </div>
                            </div>
                          )}
                        </div>
                      )}
                    </>
                  )}
                </Section>
              );
            })()}
          </>
        )}

      </div>{/* end maxWidth container */}
      </div>{/* end scrollable area */}

      {/* ── Save-failure modal ───────────────────────────────────────────── */}
      {saveFailures.length > 0 && (
        <div className="wfr-modal-overlay" onClick={() => setSaveFailures([])}>
          <div className="wfr-modal" onClick={e => e.stopPropagation()}>
            <div className="wfr-modal-header">
              <i className="fas fa-circle-exclamation" />
              <span>Some fields could not be saved</span>
              <button className="wfr-modal-close" onClick={() => setSaveFailures([])}>
                <i className="fas fa-times" />
              </button>
            </div>
            <p className="wfr-modal-body">
              The following fields failed to save. Please try again, or contact support if the issue persists.
            </p>
            <ul className="wfr-modal-failure-list">
              {saveFailures.map((f, i) => (
                <li key={i}>
                  <span className="wfr-modal-failure-section">{f.section}</span> — {f.label}
                  <span className="wfr-modal-failure-error">{f.error}</span>
                </li>
              ))}
            </ul>
            <div className="wfr-modal-footer">
              <button className="wfr-modal-btn-primary" onClick={() => setSaveFailures([])}>
                Close &amp; Try Again
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Hire required-field violations modal ────────────────────────── */}
      {isHireModule && hireViolations.length > 0 && (
        <div className="modal-overlay" onClick={() => setHireViolations([])}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-circle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>Required Fields Incomplete</h3>
            </div>
            <div className="modal-body">
              <p style={{ marginBottom: 12 }}>
                Please fill in the following required fields before submitting:
              </p>
              <ul style={{ margin: 0, paddingLeft: 20, display: 'flex', flexDirection: 'column', gap: 6 }}>
                {hireViolations.map((v, i) => (
                  <li key={i} style={{ color: '#92400E', fontWeight: 600 }}>
                    <i className="fa-solid fa-circle-dot" style={{ marginRight: 8, color: '#D97706' }} />
                    <strong>{v.section}</strong> — {v.label}
                    {v.formatError && (
                      <span style={{ display: 'block', fontWeight: 400, fontSize: 12, color: '#B45309', marginTop: 2 }}>
                        {v.formatError}
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            </div>
            <div className="modal-actions">
              <button
                className="emp-btn-primary"
                style={{ padding: '9px 28px', fontSize: 13.5 }}
                onClick={() => setHireViolations([])}
              >
                OK, I'll fix it
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Bottom action bar — always anchored at bottom ────────────────── */}
      {/* Show for approvers (myTask) OR for initiators viewing a sent-back hire */}
      {(myTask || isInitiator) && (detail || (isHireModule && hireSections.length > 0) || (isProfileBankModule && bankChangeData) || isProfileDependentsModule || isJobRelationshipsModule || isProfileEducationModule || isTerminationModule) && (
        <div className="wfr-action-bar-wrapper">
          <ActionBar {...actionBarProps} />
        </div>
      )}

      {/* No task — read-only notice */}
      {!isInitiator && !myTask && !loading && (detail || (isHireModule && hireSections.length > 0) || (isProfileBankModule && bankChangeData) || isProfileDependentsModule || isJobRelationshipsModule || isProfileEducationModule || isTerminationModule) && (
        <div className="wfr-readonly-notice">
          <i className="fas fa-circle-info" />
          {isHireModule
            ? 'You are viewing this hire request in read-only mode — this task is not currently assigned to you.'
            : isProfileBankModule
              ? 'You are viewing this bank account change request in read-only mode — this task is not currently assigned to you.'
              : isProfileDependentsModule
                ? 'You are viewing this dependent change request in read-only mode — this task is not currently assigned to you.'
                : isJobRelationshipsModule
                  ? 'You are viewing this job relationship change request in read-only mode — this task is not currently assigned to you.'
                  : isProfileEducationModule
                    ? 'You are viewing this education change request in read-only mode — this task is not currently assigned to you.'
                    : isTerminationModule
                      ? 'You are viewing this termination request in read-only mode — this task is not currently assigned to you.'
                      : 'You are viewing this report in read-only mode — this task is not currently assigned to you.'
          }
        </div>
      )}

      {/* ── Invite email / profile-link error modal ──────────────────────── */}
      {inviteErrorModal.open && (
        <div className="modal-overlay" onClick={() => setInviteErrorModal(m => ({ ...m, open: false }))}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-triangle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>{inviteErrorModal.title}</h3>
            </div>
            <div className="modal-body" style={{ whiteSpace: 'pre-line' }}>
              {inviteErrorModal.message}
            </div>
            <div className="modal-actions">
              <button
                className="emp-btn-primary"
                style={{ padding: '9px 28px', fontSize: 13.5 }}
                onClick={() => setInviteErrorModal(m => ({ ...m, open: false }))}
              >
                OK
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Identity country-change confirmation ─────────────────────────── */}
      <ConfirmationModal
        isOpen={idCountryPending !== null}
        title="Change Identity Country?"
        message="Changing the Country will clear the ID Type, Record Type, ID Number, and Expiry Date. Do you want to continue?"
        confirmText="Yes, Clear"
        cancelText="Cancel"
        destructive={false}
        onConfirm={() => {
          if (idCountryPending !== null) {
            setNewIdForm({ country: idCountryPending, id_type: '', record_type: '', id_number: '', expiry: '' });
            setNewIdErrors({});
          }
          setIdCountryPending(null);
        }}
        onCancel={() => setIdCountryPending(null)}
      />

      {/* ── Delete primary ID — auto-demote secondary modal ─────────────── */}
      <ConfirmationModal
        isOpen={!!deletePrimaryModal?.open}
        title="Delete Primary ID Record?"
        message="This employee also has a secondary ID record. Deleting the primary will automatically promote the secondary to primary."
        warning="The secondary record will become the new primary. You can add a new secondary record afterwards if needed."
        confirmText="Delete & Promote"
        cancelText="Cancel"
        destructive={false}
        onConfirm={async () => {
          if (!deletePrimaryModal || !recordId) return;
          // Promote the first secondary to primary; keep remaining as secondary
          const promoted = (deletePrimaryModal.secondaryRecords ?? []).map((s, idx) => ({
            country:     s.raw_country,
            id_type:     s.raw_id_type,
            record_type: idx === 0 ? 'primary' : 'secondary',
            id_number:   s.raw_id_number,
            expiry:      s.raw_expiry || null,
          }));
          const { error } = await supabase.rpc('replace_identity_records', {
            p_employee_id: recordId,
            p_records:     promoted,
          });
          if (error) {
            const msg = error.message
              .replace(/^replace_identity_records:\s*/i, '')
              .replace(/^ERROR:\s*/i, '');
            setInviteErrorModal({ open: true, title: 'Identity Record Error', message: msg });
          } else {
            const { data } = await supabase.rpc('get_employee_hire_review', { p_employee_id: recordId });
            if (data) setHireSections(data as HireSection[]);
          }
          setDeletePrimaryModal(null);
        }}
        onCancel={() => setDeletePrimaryModal(null)}
      />
    </div>
  );
}

// ── Small helpers ─────────────────────────────────────────────────────────────

// Pick a FontAwesome icon for each hire review section by name prefix.
function hireSectionIcon(section: string): string {
  const s = section.toLowerCase();
  if (s.startsWith('personal'))  return 'fa-circle-user';
  if (s.startsWith('contact'))   return 'fa-phone';
  if (s.startsWith('employ'))    return 'fa-briefcase';
  if (s.startsWith('address'))   return 'fa-location-dot';
  if (s.startsWith('passport'))  return 'fa-passport';
  if (s.startsWith('emergency')) return 'fa-phone-volume';
  if (s.startsWith('identity'))  return 'fa-id-card-clip';
  if (s.startsWith('bank'))      return 'fa-building-columns';
  if (s.startsWith('dependent')) return 'fa-people-group';
  if (s.startsWith('education')) return 'fa-graduation-cap';
  return 'fa-id-card';
}

// Map a field key to the picklist code needed to populate a <select>.
// Returns null for static-option fields (nationality, gender) or non-picklist fields.
function fieldPicklistCode(key?: string): string | null {
  if (!key) return null;
  const col = key.split('.').pop() ?? '';
  if (col === 'marital_status') return 'MARITAL_STATUS';
  if (col === 'designation')    return 'DESIGNATION';
  if (col === 'work_country')   return 'ID_COUNTRY';
  if (col === 'work_location')  return 'LOCATION';
  if (col === 'country')        return 'ID_COUNTRY';        // passport + identity record country (UUID FK)
  if (col === 'id_type')        return 'ID_TYPE';
  if (col === 'record_type')    return 'RECORD_TYPE';       // static text; handled before generic lookup
  if (col === 'relationship')   return 'RELATIONSHIP_TYPE'; // emergency contact relationship (UUID FK)
  return null; // nationality / gender use static options handled in renderPicklistOptions
}

// Card wrapper with a section header — replaces bare Section titles.
function Section({ title, icon, count, children }: {
  title: string; icon: string; count?: number; children: React.ReactNode;
}) {
  return (
    <div className="wfr-section">
      <div className="wfr-section-header">
        <i className={`fas ${icon} wfr-card-header-icon`} />
        <span className="wfr-card-header-label">{title}</span>
        {count !== undefined && (
          <span className="wfr-card-header-count">{count}</span>
        )}
      </div>
      {children}
    </div>
  );
}

// SummaryItem — one cell in the horizontal meta grid.
// Rendered side-by-side with vertical dividers between cells.
function SummaryItem({ label, value, sub, highlight, last }: {
  label: string; value: string; sub?: string; highlight?: boolean; last?: boolean;
}) {
  return (
    <div className={`wfr-summary-item${last ? ' wfr-summary-item--last' : ''}`}>
      <div className="wfr-summary-label">{label}</div>
      <div className={highlight ? 'wfr-summary-value--highlight' : 'wfr-summary-value'}>{value}</div>
      {sub && <div className="wfr-summary-sub">{sub}</div>}
    </div>
  );
}
