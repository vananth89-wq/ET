/**
 * NotificationConfig — Manage workflow notification templates
 *
 * Access: wf_notification_config.view (read) / wf_notification_config.edit (write)
 *
 * Features:
 *  - List all notification templates
 *  - Create new template
 *  - Edit existing template (slide-out panel)
 *  - Copy (duplicate with _copy suffix)
 *  - Delete
 *  - Token reference panel — all available {{tokens}} with click-to-copy
 */

import { useState, useEffect, useRef } from 'react';
import { supabase }        from '../../lib/supabase';
import { usePermissions }  from '../../hooks/usePermissions';

// ─── Types ────────────────────────────────────────────────────────────────────

interface NotifTemplate {
  id:         string;
  code:       string;
  title_tmpl: string;
  body_tmpl:  string;
  updated_at: string;
}

const EMPTY_DRAFT = { code: '', title_tmpl: '', body_tmpl: '' };

// ─── Token reference ──────────────────────────────────────────────────────────

const TOKENS: { token: string; description: string }[] = [
  { token: '{{step_name}}',      description: 'Name of the workflow step'           },
  { token: '{{submitter_name}}', description: 'Full name of the person who submitted' },
  { token: '{{approver_name}}',  description: 'Full name of the assigned approver'  },
  { token: '{{reason}}',         description: 'Rejection or clarification reason'   },
  { token: '{{record_label}}',   description: 'Label of the record being approved'  },
  { token: '{{response}}',       description: "Approver's response text"            },
  { token: '{{hours_elapsed}}',  description: 'Hours elapsed since SLA deadline'    },
  { token: '{{message}}',        description: 'Custom message from the workflow'     },
];

// ─── Token panel ──────────────────────────────────────────────────────────────

function TokenPanel({ onInsert }: { onInsert: (token: string) => void }) {
  const [copied, setCopied] = useState<string | null>(null);

  function handleCopy(token: string) {
    navigator.clipboard.writeText(token).catch(() => null);
    setCopied(token);
    setTimeout(() => setCopied(null), 1500);
    onInsert(token);
  }

  return (
    <div style={{
      width: 240, flexShrink: 0, background: '#F8FAFC', border: '1px solid #E2E8F0',
      borderRadius: 10, padding: '14px 12px', alignSelf: 'flex-start', position: 'sticky', top: 0,
    }}>
      <div style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.08em', color: '#64748B', marginBottom: 10 }}>
        Available Tokens
      </div>
      <div style={{ fontSize: 11, color: '#94A3B8', marginBottom: 12 }}>
        Click to copy · paste into title or body
      </div>
      {TOKENS.map(({ token, description }) => (
        <div
          key={token}
          onClick={() => handleCopy(token)}
          style={{
            padding: '7px 10px', borderRadius: 6, marginBottom: 6, cursor: 'pointer',
            background: copied === token ? '#EFF6FF' : '#fff',
            border: `1px solid ${copied === token ? '#BFDBFE' : '#E2E8F0'}`,
            transition: 'all .15s',
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 2 }}>
            <code style={{ fontSize: 11, color: '#1D4ED8', fontWeight: 600 }}>{token}</code>
            {copied === token
              ? <i className="fa-solid fa-check" style={{ fontSize: 10, color: '#16A34A' }} />
              : <i className="fa-regular fa-copy" style={{ fontSize: 10, color: '#94A3B8' }} />
            }
          </div>
          <div style={{ fontSize: 11, color: '#64748B' }}>{description}</div>
        </div>
      ))}
    </div>
  );
}

// ─── Edit / Create panel ──────────────────────────────────────────────────────

interface PanelProps {
  draft:     typeof EMPTY_DRAFT;
  setDraft:  React.Dispatch<React.SetStateAction<typeof EMPTY_DRAFT>>;
  isNew:     boolean;
  saving:    boolean;
  onSave:    () => void;
  onCancel:  () => void;
}

function EditPanel({ draft, setDraft, isNew, saving, onSave, onCancel }: PanelProps) {
  const bodyRef = useRef<HTMLTextAreaElement>(null);

  function insertToken(token: string) {
    const el = bodyRef.current;
    if (!el) {
      setDraft(d => ({ ...d, body_tmpl: d.body_tmpl + token }));
      return;
    }
    const start = el.selectionStart ?? el.value.length;
    const end   = el.selectionEnd   ?? el.value.length;
    const next  = el.value.slice(0, start) + token + el.value.slice(end);
    setDraft(d => ({ ...d, body_tmpl: next }));
    setTimeout(() => { el.focus(); el.setSelectionRange(start + token.length, start + token.length); }, 0);
  }

  return (
    <div style={{ display: 'flex', gap: 20 }}>
      {/* ── Form ── */}
      <div style={{ flex: 1 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
          <h3 style={{ margin: 0, fontSize: 16, fontWeight: 700, color: '#0F172A' }}>
            {isNew ? 'New Template' : 'Edit Template'}
          </h3>
          <button className="btn btn-ghost btn-sm" onClick={onCancel}>
            <i className="fa-solid fa-xmark" /> Cancel
          </button>
        </div>

        <div className="form-group" style={{ marginBottom: 16 }}>
          <label className="form-label">Code <span style={{ color: '#EF4444' }}>*</span></label>
          <input
            className="form-input"
            value={draft.code}
            onChange={e => setDraft(d => ({ ...d, code: e.target.value.toLowerCase().replace(/[^a-z0-9._-]/g, '') }))}
            placeholder="e.g. wf.step_approved"
            disabled={!isNew}
            style={{ opacity: isNew ? 1 : 0.6 }}
          />
          <div style={{ fontSize: 11, color: '#94A3B8', marginTop: 4 }}>
            Unique identifier. Lowercase, dots, hyphens, underscores only. Cannot be changed after creation.
          </div>
        </div>

        <div className="form-group" style={{ marginBottom: 16 }}>
          <label className="form-label">Title <span style={{ color: '#EF4444' }}>*</span></label>
          <input
            className="form-input"
            value={draft.title_tmpl}
            onChange={e => setDraft(d => ({ ...d, title_tmpl: e.target.value }))}
            placeholder="e.g. New approval task: {{step_name}}"
          />
        </div>

        <div className="form-group" style={{ marginBottom: 20 }}>
          <label className="form-label">Body <span style={{ color: '#EF4444' }}>*</span></label>
          <textarea
            ref={bodyRef}
            className="form-input"
            value={draft.body_tmpl}
            onChange={e => setDraft(d => ({ ...d, body_tmpl: e.target.value }))}
            rows={6}
            placeholder="Write the notification message here. Use {{tokens}} from the panel."
            style={{ resize: 'vertical', fontFamily: 'inherit' }}
          />
          <div style={{ fontSize: 11, color: '#94A3B8', marginTop: 4 }}>
            Click a token on the right to insert it at the cursor position.
          </div>
        </div>

        <div style={{ display: 'flex', gap: 10 }}>
          <button
            className="btn btn-primary"
            onClick={onSave}
            disabled={saving || !draft.code || !draft.title_tmpl || !draft.body_tmpl}
          >
            {saving ? <><span className="spinner" style={{ width: 12, height: 12 }} /> Saving…</> : 'Save template'}
          </button>
          <button className="btn btn-ghost" onClick={onCancel}>Cancel</button>
        </div>
      </div>

      {/* ── Token panel ── */}
      <TokenPanel onInsert={insertToken} />
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function NotificationConfig() {
  const { can }                                      = usePermissions();
  const canEdit                                      = can('wf_notification_config.edit');

  const [templates, setTemplates]                    = useState<NotifTemplate[]>([]);
  const [loading, setLoading]                        = useState(true);
  const [error, setError]                            = useState<string | null>(null);
  const [editing, setEditing]                        = useState<NotifTemplate | null>(null);
  const [isNew, setIsNew]                            = useState(false);
  const [draft, setDraft]                            = useState(EMPTY_DRAFT);
  const [saving, setSaving]                          = useState(false);
  const [confirmDelete, setConfirmDelete]            = useState<NotifTemplate | null>(null);
  const [search, setSearch]                          = useState('');
  const [toast, setToast]                            = useState<{ type: 'ok' | 'err'; msg: string } | null>(null);
  const toastTimer                                   = useRef<number | null>(null);

  function showToast(type: 'ok' | 'err', msg: string) {
    setToast({ type, msg });
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 4000);
  }

  // ── Load ─────────────────────────────────────────────────────────────────

  async function load() {
    setLoading(true); setError(null);
    const { data, error } = await supabase
      .from('workflow_notification_templates')
      .select('id, code, title_tmpl, body_tmpl, updated_at')
      .order('code');
    if (error) setError(error.message);
    else setTemplates(data ?? []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  // ── Actions ───────────────────────────────────────────────────────────────

  function openCreate() {
    setEditing(null); setIsNew(true);
    setDraft(EMPTY_DRAFT);
  }

  function openEdit(t: NotifTemplate) {
    setEditing(t); setIsNew(false);
    setDraft({ code: t.code, title_tmpl: t.title_tmpl, body_tmpl: t.body_tmpl });
  }

  function openCopy(t: NotifTemplate) {
    setEditing(null); setIsNew(true);
    setDraft({ code: t.code + '_copy', title_tmpl: t.title_tmpl, body_tmpl: t.body_tmpl });
  }

  async function handleSave() {
    setSaving(true);
    if (isNew) {
      const { error } = await supabase
        .from('workflow_notification_templates')
        .insert({ code: draft.code, title_tmpl: draft.title_tmpl, body_tmpl: draft.body_tmpl });
      if (error) { showToast('err', error.message); }
      else { showToast('ok', 'Template created'); closePanel(); load(); }
    } else if (editing) {
      const { error } = await supabase
        .from('workflow_notification_templates')
        .update({ title_tmpl: draft.title_tmpl, body_tmpl: draft.body_tmpl })
        .eq('id', editing.id);
      if (error) { showToast('err', error.message); }
      else { showToast('ok', 'Template saved'); closePanel(); load(); }
    }
    setSaving(false);
  }

  async function handleDelete(t: NotifTemplate) {
    const { error } = await supabase
      .from('workflow_notification_templates')
      .delete()
      .eq('id', t.id);
    if (error) showToast('err', error.message);
    else { showToast('ok', 'Template deleted'); load(); }
    setConfirmDelete(null);
  }

  function closePanel() { setEditing(null); setIsNew(false); setDraft(EMPTY_DRAFT); }

  // ── Filter ────────────────────────────────────────────────────────────────

  const filtered = templates.filter(t =>
    t.code.includes(search.toLowerCase()) ||
    t.title_tmpl.toLowerCase().includes(search.toLowerCase())
  );

  // ── Render ────────────────────────────────────────────────────────────────

  const showPanel = isNew || editing !== null;

  return (
    <div className="page-container">
      {/* ── Header ── */}
      <div className="page-header">
        <div>
          <h1 className="page-title">
            <i className="fa-solid fa-envelope-open-text" style={{ marginRight: 10 }} />
            Manage Notifications
          </h1>
          <p className="page-subtitle">
            Configure notification templates used by the workflow engine. Use <code>{'{{tokens}}'}</code> for dynamic values.
          </p>
        </div>
        {canEdit && !showPanel && (
          <button className="btn btn-primary" onClick={openCreate}>
            <i className="fa-solid fa-plus" /> New Template
          </button>
        )}
      </div>

      {/* ── View-only banner ── */}
      {!canEdit && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10, padding: '10px 16px',
          background: '#FFFBEB', border: '1px solid #FDE68A', borderRadius: 8, marginBottom: 20,
        }}>
          <i className="fa-solid fa-eye" style={{ color: '#D97706' }} />
          <span style={{ fontSize: 13, color: '#92400E' }}>
            You have read-only access. Contact an admin to make changes.
          </span>
        </div>
      )}

      {/* ── Edit / Create panel ── */}
      {showPanel && canEdit && (
        <div className="card" style={{ padding: 24, marginBottom: 24 }}>
          <EditPanel
            draft={draft}
            setDraft={setDraft}
            isNew={isNew}
            saving={saving}
            onSave={handleSave}
            onCancel={closePanel}
          />
        </div>
      )}

      {/* ── Search ── */}
      {!showPanel && (
        <div style={{ marginBottom: 16 }}>
          <div style={{ position: 'relative', maxWidth: 320 }}>
            <i className="fa-solid fa-magnifying-glass" style={{
              position: 'absolute', left: 12, top: '50%', transform: 'translateY(-50%)',
              color: '#94A3B8', fontSize: 13,
            }} />
            <input
              className="form-input"
              style={{ paddingLeft: 36 }}
              placeholder="Search by code or title…"
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
        </div>
      )}

      {/* ── Error ── */}
      {error && (
        <div className="form-error-banner" style={{ marginBottom: 16 }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} /> {error}
        </div>
      )}

      {/* ── Table ── */}
      {loading ? (
        <div className="loading-state"><span className="spinner" /> Loading templates…</div>
      ) : filtered.length === 0 ? (
        <div className="empty-state">
          <i className="fa-solid fa-envelope empty-state-icon" />
          <div className="empty-state-title">{search ? 'No templates match your search' : 'No templates yet'}</div>
          {!search && canEdit && (
            <div className="empty-state-subtitle">Create your first notification template to get started.</div>
          )}
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ background: '#F8FAFC', borderBottom: '1px solid #E2E8F0' }}>
                <th style={{ padding: '10px 16px', textAlign: 'left', fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.07em', color: '#64748B' }}>Code</th>
                <th style={{ padding: '10px 16px', textAlign: 'left', fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.07em', color: '#64748B' }}>Title</th>
                <th style={{ padding: '10px 16px', textAlign: 'left', fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.07em', color: '#64748B' }}>Body preview</th>
                <th style={{ padding: '10px 16px', textAlign: 'left', fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.07em', color: '#64748B' }}>Updated</th>
                {canEdit && <th style={{ padding: '10px 16px', width: 120 }} />}
              </tr>
            </thead>
            <tbody>
              {filtered.map((t, i) => (
                <tr
                  key={t.id}
                  style={{ borderBottom: i < filtered.length - 1 ? '1px solid #F1F5F9' : 'none' }}
                >
                  <td style={{ padding: '12px 16px', verticalAlign: 'top' }}>
                    <code style={{ fontSize: 12, color: '#1D4ED8', background: '#EFF6FF', padding: '2px 6px', borderRadius: 4 }}>
                      {t.code}
                    </code>
                  </td>
                  <td style={{ padding: '12px 16px', verticalAlign: 'top', fontSize: 13, color: '#0F172A', maxWidth: 220 }}>
                    {t.title_tmpl}
                  </td>
                  <td style={{ padding: '12px 16px', verticalAlign: 'top', fontSize: 12, color: '#64748B', maxWidth: 300 }}>
                    <div style={{ overflow: 'hidden', textOverflow: 'ellipsis', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' }}>
                      {t.body_tmpl}
                    </div>
                  </td>
                  <td style={{ padding: '12px 16px', verticalAlign: 'top', fontSize: 12, color: '#94A3B8', whiteSpace: 'nowrap' }}>
                    {new Date(t.updated_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}
                  </td>
                  {canEdit && (
                    <td style={{ padding: '12px 16px', verticalAlign: 'top' }}>
                      <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                        <button
                          className="btn btn-ghost btn-sm"
                          onClick={() => openEdit(t)}
                          title="Edit"
                        >
                          <i className="fa-solid fa-pen" />
                        </button>
                        <button
                          className="btn btn-ghost btn-sm"
                          onClick={() => openCopy(t)}
                          title="Duplicate"
                        >
                          <i className="fa-solid fa-copy" />
                        </button>
                        <button
                          className="btn btn-ghost btn-sm"
                          onClick={() => setConfirmDelete(t)}
                          title="Delete"
                          style={{ color: '#EF4444' }}
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
        </div>
      )}

      {/* ── Delete confirm modal ── */}
      {confirmDelete && (
        <div style={{
          position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', zIndex: 1000,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <div className="card" style={{ padding: 28, maxWidth: 420, width: '90%' }}>
            <h3 style={{ margin: '0 0 10px', fontSize: 16, color: '#0F172A' }}>Delete template?</h3>
            <p style={{ fontSize: 13, color: '#64748B', margin: '0 0 20px' }}>
              <code style={{ color: '#1D4ED8' }}>{confirmDelete.code}</code> will be permanently deleted.
              Workflow steps referencing this template will lose their notification.
            </p>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button className="btn btn-ghost" onClick={() => setConfirmDelete(null)}>Cancel</button>
              <button
                className="btn btn-danger"
                onClick={() => handleDelete(confirmDelete)}
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Toast ── */}
      {toast && (
        <div style={{
          position: 'fixed', bottom: 24, right: 28,
          padding: '10px 18px', borderRadius: 8, fontSize: 13, zIndex: 9999,
          background: toast.type === 'ok' ? '#F0FDF4' : '#FEF2F2',
          border: `1px solid ${toast.type === 'ok' ? '#BBF7D0' : '#FECACA'}`,
          color: toast.type === 'ok' ? '#15803D' : '#DC2626',
          boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
          display: 'flex', alignItems: 'center', gap: 8,
        }}>
          <i className={`fas ${toast.type === 'ok' ? 'fa-circle-check' : 'fa-triangle-exclamation'}`} />
          {toast.msg}
        </div>
      )}
    </div>
  );
}
