/**
 * WorkflowActions
 *
 * All approver actions for a pending workflow task:
 *   1. Approve          — with optional notes
 *   2. Reject           — requires reason
 *   3. Reassign         — inline people search + optional reason
 *   4. Return to Initiator — requires a clarification message to the submitter
 *   5. Return to Previous Step — optional reason; only shown when stepOrder > 1
 *
 * Usage:
 *   <WorkflowActions
 *     taskId={task.taskId}
 *     stepOrder={task.stepOrder}
 *     onApprove={approve}
 *     onReject={reject}
 *     onReassign={reassign}
 *     onReturnToInitiator={returnToInitiator}
 *     onReturnToPreviousStep={returnToPreviousStep}
 *   />
 */

import { useState, useRef, useEffect } from 'react';
import { supabase } from '../../lib/supabase';

// ─── Types ─────────────────────────────────────────────────────────────────────

type ActionMode =
  | 'idle'
  | 'approve'
  | 'reject'
  | 'reassign'
  | 'return_initiator'
  | 'return_prev';

interface PersonResult {
  id:    string;
  name:  string;
  email: string;
  title: string | null;
}

interface WorkflowActionsProps {
  taskId:                  string;
  stepOrder:               number;
  onApprove:               (taskId: string, notes?: string)                 => Promise<void>;
  onReject:                (taskId: string, reason: string)                 => Promise<void>;
  onReassign:              (taskId: string, profileId: string, reason?: string) => Promise<void>;
  onReturnToInitiator:     (taskId: string, message: string)               => Promise<void>;
  onReturnToPreviousStep:  (taskId: string, reason?: string)               => Promise<void>;
}

// ─── Component ──────────────────────────────────────────────────────────────────

export function WorkflowActions({
  taskId,
  stepOrder,
  onApprove,
  onReject,
  onReassign,
  onReturnToInitiator,
  onReturnToPreviousStep,
}: WorkflowActionsProps) {

  const [mode,    setMode]    = useState<ActionMode>('idle');
  const [text,    setText]    = useState('');
  const [loading, setLoading] = useState(false);
  const [errMsg,  setErrMsg]  = useState<string | null>(null);

  // Reassign — people search
  const [query,        setQuery]        = useState('');
  const [searchResults, setSearchResults] = useState<PersonResult[]>([]);
  const [searching,    setSearching]    = useState(false);
  const [selectedPerson, setSelectedPerson] = useState<PersonResult | null>(null);
  const searchTimeout = useRef<ReturnType<typeof setTimeout> | null>(null);

  function reset() {
    setMode('idle');
    setText('');
    setErrMsg(null);
    setQuery('');
    setSearchResults([]);
    setSelectedPerson(null);
  }

  // ── People search (debounced) ──────────────────────────────────────────────
  useEffect(() => {
    if (mode !== 'reassign') return;
    if (query.length < 2) { setSearchResults([]); return; }

    if (searchTimeout.current) clearTimeout(searchTimeout.current);
    searchTimeout.current = setTimeout(async () => {
      setSearching(true);
      const { data } = await supabase
        .from('profiles')
        .select('id, employees!inner(name, business_email, job_title)')
        .ilike('employees.name', `%${query}%`)
        .eq('is_active', true)
        .limit(8);

      setSearchResults(
        (data ?? []).map((p: any) => ({
          id:    p.id,
          name:  p.employees?.name  ?? '—',
          email: p.employees?.business_email ?? '',
          title: p.employees?.job_title ?? null,
        }))
      );
      setSearching(false);
    }, 300);
  }, [query, mode]);

  // ── Action handlers ────────────────────────────────────────────────────────

  async function handle(fn: () => Promise<void>) {
    setLoading(true);
    setErrMsg(null);
    try {
      await fn();
      reset();
    } catch (e) {
      setErrMsg((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  async function handleApprove() {
    await handle(() => onApprove(taskId, text.trim() || undefined));
  }

  async function handleReject() {
    if (!text.trim()) { setErrMsg('A rejection reason is required.'); return; }
    await handle(() => onReject(taskId, text.trim()));
  }

  async function handleReassign() {
    if (!selectedPerson) { setErrMsg('Select a person to reassign to.'); return; }
    await handle(() => onReassign(taskId, selectedPerson.id, text.trim() || undefined));
  }

  async function handleReturnToInitiator() {
    if (!text.trim()) { setErrMsg('A message to the initiator is required.'); return; }
    await handle(() => onReturnToInitiator(taskId, text.trim()));
  }

  async function handleReturnToPrevious() {
    await handle(() => onReturnToPreviousStep(taskId, text.trim() || undefined));
  }

  // ── Idle: action buttons ───────────────────────────────────────────────────

  if (mode === 'idle') {
    return (
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <ActionBtn
          color="#16A34A"
          icon="fa-check"
          label="Approve"
          onClick={() => { setMode('approve'); setText(''); setErrMsg(null); }}
        />
        <ActionBtn
          color="#DC2626"
          icon="fa-times"
          label="Reject"
          onClick={() => { setMode('reject'); setText(''); setErrMsg(null); }}
        />
        <ActionBtn
          color="#7C3AED"
          icon="fa-arrow-right-arrow-left"
          label="Reassign"
          onClick={() => { setMode('reassign'); setText(''); setQuery(''); setSelectedPerson(null); setErrMsg(null); }}
        />
        <ActionBtn
          color="#B45309"
          icon="fa-rotate-left"
          label="Return for Clarification"
          onClick={() => { setMode('return_initiator'); setText(''); setErrMsg(null); }}
        />
        {stepOrder > 1 && (
          <ActionBtn
            color="#374151"
            icon="fa-backward-step"
            label="Return to Previous Step"
            onClick={() => { setMode('return_prev'); setText(''); setErrMsg(null); }}
          />
        )}
      </div>
    );
  }

  // ── Expanded panel ─────────────────────────────────────────────────────────

  const panelConfig = {
    approve:          { borderColor: '#BBF7D0', confirmColor: '#16A34A', confirmLabel: 'Confirm Approve',        loadLabel: 'Approving…'     },
    reject:           { borderColor: '#FECACA', confirmColor: '#DC2626', confirmLabel: 'Confirm Reject',         loadLabel: 'Rejecting…'     },
    reassign:         { borderColor: '#DDD6FE', confirmColor: '#7C3AED', confirmLabel: 'Confirm Reassign',       loadLabel: 'Reassigning…'   },
    return_initiator: { borderColor: '#FDE68A', confirmColor: '#B45309', confirmLabel: 'Send for Clarification', loadLabel: 'Sending…'       },
    return_prev:      { borderColor: '#E5E7EB', confirmColor: '#374151', confirmLabel: 'Return to Previous',     loadLabel: 'Returning…'     },
  }[mode]!;

  return (
    <div style={{
      background:   '#F9FAFB',
      border:       `1px solid ${panelConfig.borderColor}`,
      borderRadius: 8,
      padding:      12,
    }}>

      {/* Panel header */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
        <span style={{ fontSize: 12, fontWeight: 700, color: '#374151', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
          {mode === 'approve'          && 'Approve Request'}
          {mode === 'reject'           && 'Reject Request'}
          {mode === 'reassign'         && 'Reassign Task'}
          {mode === 'return_initiator' && 'Return for Clarification'}
          {mode === 'return_prev'      && 'Return to Previous Step'}
        </span>
        <button
          onClick={reset}
          disabled={loading}
          style={{
            background: 'none', border: 'none', cursor: 'pointer',
            color: '#9CA3AF', fontSize: 16, lineHeight: 1, padding: 2,
          }}
        >×</button>
      </div>

      {/* ── Reassign: people search ─────────────────────────────────────────── */}
      {mode === 'reassign' && (
        <div style={{ marginBottom: 10 }}>
          <label style={labelStyle}>Reassign to *</label>

          {selectedPerson ? (
            /* Selected person pill */
            <div style={{
              display: 'flex', alignItems: 'center', justifyContent: 'space-between',
              padding: '7px 10px', borderRadius: 6,
              border: '1px solid #DDD6FE', background: '#F5F3FF',
            }}>
              <div>
                <div style={{ fontSize: 13, fontWeight: 600, color: '#5B21B6' }}>{selectedPerson.name}</div>
                {selectedPerson.title && (
                  <div style={{ fontSize: 11, color: '#7C3AED' }}>{selectedPerson.title}</div>
                )}
              </div>
              <button
                onClick={() => { setSelectedPerson(null); setQuery(''); }}
                style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#7C3AED', fontSize: 14 }}
              >×</button>
            </div>
          ) : (
            /* Search input */
            <div style={{ position: 'relative' }}>
              <input
                value={query}
                onChange={e => setQuery(e.target.value)}
                placeholder="Search by name…"
                style={inputStyle}
                autoFocus
              />
              {searching && (
                <div style={{ position: 'absolute', right: 8, top: '50%', transform: 'translateY(-50%)' }}>
                  <i className="fas fa-spinner fa-spin" style={{ fontSize: 11, color: '#9CA3AF' }} />
                </div>
              )}
              {searchResults.length > 0 && (
                <div style={{
                  position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20,
                  background: '#fff', border: '1px solid #D1D5DB', borderRadius: 6,
                  boxShadow: '0 4px 12px rgba(0,0,0,0.10)', overflow: 'hidden', marginTop: 2,
                }}>
                  {searchResults.map(p => (
                    <button
                      key={p.id}
                      onClick={() => { setSelectedPerson(p); setQuery(''); setSearchResults([]); }}
                      style={{
                        display: 'block', width: '100%', textAlign: 'left',
                        padding: '9px 12px', border: 'none', background: 'none',
                        cursor: 'pointer', borderBottom: '1px solid #F3F4F6',
                      }}
                      onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')}
                      onMouseLeave={e => (e.currentTarget.style.background = 'none')}
                    >
                      <div style={{ fontSize: 13, fontWeight: 600, color: '#111827' }}>{p.name}</div>
                      <div style={{ fontSize: 11, color: '#6B7280' }}>{p.title ?? p.email}</div>
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>
      )}

      {/* ── Text input (notes / reason / message) ──────────────────────────── */}
      <div style={{ marginBottom: errMsg ? 0 : 8 }}>
        <label style={labelStyle}>
          {mode === 'approve'          && 'Notes (optional)'}
          {mode === 'reject'           && 'Rejection reason *'}
          {mode === 'reassign'         && 'Reason (optional)'}
          {mode === 'return_initiator' && 'Clarification message *'}
          {mode === 'return_prev'      && 'Reason (optional)'}
        </label>
        <textarea
          value={text}
          onChange={e => setText(e.target.value)}
          placeholder={
            mode === 'approve'          ? 'Add any comments for your decision…'        :
            mode === 'reject'           ? 'Describe why this request is being rejected…' :
            mode === 'reassign'         ? 'Optional reason for reassigning…'            :
            mode === 'return_initiator' ? 'Explain what information or action you need from the initiator…' :
                                         'Optional reason for returning to the previous step…'
          }
          rows={3}
          style={textareaStyle}
        />
      </div>

      {errMsg && (
        <p style={{ fontSize: 12, color: '#DC2626', margin: '6px 0 8px' }}>{errMsg}</p>
      )}

      {/* ── Confirm / Cancel ────────────────────────────────────────────────── */}
      <div style={{ display: 'flex', gap: 8 }}>
        <button
          onClick={
            mode === 'approve'          ? handleApprove          :
            mode === 'reject'           ? handleReject           :
            mode === 'reassign'         ? handleReassign         :
            mode === 'return_initiator' ? handleReturnToInitiator :
                                          handleReturnToPrevious
          }
          disabled={loading}
          style={{
            padding: '6px 14px', borderRadius: 6, border: 'none',
            background: panelConfig.confirmColor,
            color: '#fff', fontWeight: 600, fontSize: 13,
            cursor: loading ? 'not-allowed' : 'pointer',
            opacity: loading ? 0.7 : 1,
          }}
        >
          {loading ? panelConfig.loadLabel : panelConfig.confirmLabel}
        </button>
        <button
          onClick={reset}
          disabled={loading}
          style={{
            padding: '6px 12px', borderRadius: 6,
            border: '1px solid #D1D5DB', background: '#fff',
            fontWeight: 500, fontSize: 13, cursor: 'pointer',
            color: '#374151',
          }}
        >
          Cancel
        </button>
      </div>
    </div>
  );
}

// ── Small helpers ──────────────────────────────────────────────────────────────

interface ActionBtnProps {
  color:   string;
  icon:    string;
  label:   string;
  onClick: () => void;
}

function ActionBtn({ color, icon, label, onClick }: ActionBtnProps) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex', alignItems: 'center', gap: 5,
        padding: '6px 12px', borderRadius: 6,
        border: `1px solid ${color}22`,
        background: `${color}11`,
        color,
        fontWeight: 600, fontSize: 12,
        cursor: 'pointer',
        transition: 'background 0.1s',
        whiteSpace: 'nowrap',
      }}
      onMouseEnter={e => { (e.currentTarget as HTMLElement).style.background = `${color}22`; }}
      onMouseLeave={e => { (e.currentTarget as HTMLElement).style.background = `${color}11`; }}
    >
      <i className={`fas ${icon}`} style={{ fontSize: 11 }} />
      {label}
    </button>
  );
}

const labelStyle: React.CSSProperties = {
  fontSize: 11, fontWeight: 600, color: '#6B7280',
  textTransform: 'uppercase', letterSpacing: '0.05em',
  display: 'block', marginBottom: 5,
};

const inputStyle: React.CSSProperties = {
  width: '100%', padding: '7px 10px',
  border: '1px solid #D1D5DB', borderRadius: 6,
  fontSize: 13, outline: 'none',
  fontFamily: 'inherit', boxSizing: 'border-box',
};

const textareaStyle: React.CSSProperties = {
  width: '100%', padding: '8px 10px',
  border: '1px solid #D1D5DB', borderRadius: 6,
  fontSize: 13, resize: 'vertical', outline: 'none',
  fontFamily: 'inherit', boxSizing: 'border-box',
};
