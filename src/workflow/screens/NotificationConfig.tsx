/**
 * NotificationConfig — Manage workflow notification templates
 *
 * Access: wf_notification_config.view (read) / wf_notification_config.edit (write)
 *
 * Layout: master-detail split view
 *  - Left panel (320px): search, category filter tabs, scrollable template list
 *  - Right panel: full editor with token bar + footer delete link
 */

import { useState, useEffect, useRef } from 'react';
import { supabase }       from '../../lib/supabase';
import { usePermissions } from '../../hooks/usePermissions';

// ─── Types ────────────────────────────────────────────────────────────────────

interface NotifTemplate {
  id:         string;
  code:       string;
  title_tmpl: string;
  body_tmpl:  string;
  updated_at: string;
}

const EMPTY_DRAFT = { code: '', title_tmpl: '', body_tmpl: '' };

// ─── Category helpers ─────────────────────────────────────────────────────────

type Category = 'task' | 'sla' | 'approval' | 'returned' | 'admin' | 'general';

interface CatMeta {
  label:   string;
  color:   string;
  bg:      string;
  border:  string;
  pillBg:  string;
  pillTxt: string;
  icon:    string;
}

const CAT: Record<Category, CatMeta> = {
  task:     { label: 'Task',     color: '#1D4ED8', bg: '#EFF6FF', border: '#BFDBFE', pillBg: '#DBEAFE', pillTxt: '#1E40AF', icon: 'fa-inbox'        },
  sla:      { label: 'SLA',      color: '#B45309', bg: '#FFFBEB', border: '#FDE68A', pillBg: '#FEF3C7', pillTxt: '#92400E', icon: 'fa-clock'        },
  approval: { label: 'Approval', color: '#15803D', bg: '#F0FDF4', border: '#BBF7D0', pillBg: '#DCFCE7', pillTxt: '#166534', icon: 'fa-circle-check' },
  returned: { label: 'Returned', color: '#B91C1C', bg: '#FEF2F2', border: '#FECACA', pillBg: '#FEE2E2', pillTxt: '#991B1B', icon: 'fa-rotate-left'  },
  admin:    { label: 'Admin',    color: '#6D28D9', bg: '#F5F3FF', border: '#DDD6FE', pillBg: '#EDE9FE', pillTxt: '#5B21B6', icon: 'fa-shield-halved'},
  general:  { label: 'General',  color: '#4B5563', bg: '#F9FAFB', border: '#E5E7EB', pillBg: '#F3F4F6', pillTxt: '#374151', icon: 'fa-envelope'     },
};

function getCategory(code: string): Category {
  if (code.includes('sla'))                                                           return 'sla';
  if (code.includes('task') || code.includes('reassign'))                             return 'task';
  if (code.includes('force') || code.includes('admin') || code.includes('escalat'))  return 'admin';
  if (code.includes('reject') || code.includes('return') || code.includes('withdraw') ||
      code.includes('declin') || code.includes('clarif'))                             return 'returned';
  if (code.includes('complet') || code.includes('approv') || code.includes('advanced') ||
      code.includes('submit') || code.includes('resubmit'))                           return 'approval';
  return 'general';
}

const ALL_CATEGORIES: Array<Category | 'all'> = ['all', 'task', 'sla', 'approval', 'returned', 'admin', 'general'];

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

// ─── Token reference ──────────────────────────────────────────────────────────

const TOKENS = [
  { token: '{{step_name}}',      description: 'Name of the workflow step'             },
  { token: '{{submitter_name}}', description: 'Full name of the person who submitted'  },
  { token: '{{approver_name}}',  description: 'Full name of the assigned approver'    },
  { token: '{{reason}}',         description: 'Rejection or clarification reason'     },
  { token: '{{record_label}}',   description: 'Label of the record being approved'    },
  { token: '{{response}}',       description: "Approver's response text"              },
  { token: '{{hours_elapsed}}',  description: 'Hours elapsed since SLA deadline'      },
  { token: '{{message}}',        description: 'Custom message from the workflow'       },
];

// ─── Shared colours ───────────────────────────────────────────────────────────

const C = {
  navy:   '#18345B',
  border: '#E5E7EB',
  bg:     '#F9FAFB',
  text:   '#111827',
  muted:  '#6B7280',
  faint:  '#9CA3AF',
  red:    '#DC2626',
  redL:   '#FEF2F2',
  green:  '#16A34A',
  greenL: '#DCFCE7',
};

// ─── Right panel: Template editor ─────────────────────────────────────────────

function TemplateEditor({
  draft, setDraft, isNew, saving, canEdit, updatedAt,
  onSave, onDelete, onDuplicate,
}: {
  draft:       typeof EMPTY_DRAFT;
  setDraft:    React.Dispatch<React.SetStateAction<typeof EMPTY_DRAFT>>;
  isNew:       boolean;
  saving:      boolean;
  canEdit:     boolean;
  updatedAt?:  string;
  onSave:      () => void;
  onDelete:    () => void;
  onDuplicate: () => void;
}) {
  const bodyRef  = useRef<HTMLTextAreaElement>(null);
  const titleRef = useRef<HTMLInputElement>(null);
  const [insertedToken, setInsertedToken] = useState<string | null>(null);
  const [activeField,   setActiveField]   = useState<'title' | 'body'>('body');

  function insertToken(token: string) {
    const el = (activeField === 'body' ? bodyRef.current : titleRef.current) as HTMLInputElement | HTMLTextAreaElement | null;
    if (!el) {
      if (activeField === 'body') setDraft(d => ({ ...d, body_tmpl:  d.body_tmpl  + token }));
      else                        setDraft(d => ({ ...d, title_tmpl: d.title_tmpl + token }));
      return;
    }
    const start = el.selectionStart ?? el.value.length;
    const end   = el.selectionEnd   ?? el.value.length;
    const next  = el.value.slice(0, start) + token + el.value.slice(end);
    if (activeField === 'body') setDraft(d => ({ ...d, body_tmpl: next }));
    else                        setDraft(d => ({ ...d, title_tmpl: next }));
    setTimeout(() => { el.focus(); el.setSelectionRange(start + token.length, start + token.length); }, 0);
    setInsertedToken(token);
    setTimeout(() => setInsertedToken(null), 1200);
  }

  const cat     = getCategory(draft.code);
  const meta    = CAT[cat];
  const canSave = canEdit && !saving && !!draft.code && !!draft.title_tmpl && !!draft.body_tmpl;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>

      {/* ── Editor header ── */}
      <div style={{
        padding: '14px 18px',
        borderBottom: `1px solid ${C.border}`,
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        flexShrink: 0, gap: 10,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9, minWidth: 0 }}>
          <div style={{
            width: 32, height: 32, borderRadius: 8,
            background: meta.bg, display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
          }}>
            <i className={`fas ${meta.icon}`} style={{ color: meta.color, fontSize: 14 }} />
          </div>
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: C.text }}>
              {isNew ? 'New template' : 'Edit template'}
            </div>
            {!isNew && draft.code && (
              <code style={{ fontSize: 11, color: meta.color, display: 'block' }}>{draft.code}</code>
            )}
          </div>
        </div>
        <div style={{ display: 'flex', gap: 7, flexShrink: 0, alignItems: 'center' }}>
          {!isNew && canEdit && (
            <button
              onClick={onDuplicate}
              title="Duplicate this template"
              style={iconBtn}
            >
              <i className="fas fa-copy" />
            </button>
          )}
          {canEdit && (
            <button
              onClick={onSave}
              disabled={!canSave}
              style={{ ...primaryBtn, opacity: canSave ? 1 : 0.5, cursor: canSave ? 'pointer' : 'not-allowed' }}
            >
              {saving
                ? <><i className="fas fa-spinner fa-spin" style={{ marginRight: 6 }} />Saving…</>
                : 'Save changes'}
            </button>
          )}
        </div>
      </div>

      {/* ── Scrollable fields ── */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '18px 20px 10px' }}>

        {/* Event code — read-only for existing, editable for new */}
        <div style={{ marginBottom: 15 }}>
          <label style={labelSt}>Event code</label>
          <input
            style={{ ...inputSt, fontFamily: 'monospace', fontSize: 12, opacity: isNew ? 1 : 0.65 }}
            value={draft.code}
            onChange={e => isNew && setDraft(d => ({ ...d, code: e.target.value.toLowerCase().replace(/[^a-z0-9._-]/g, '') }))}
            placeholder="e.g. wf.task_assigned"
            readOnly={!isNew}
          />
          {isNew && (
            <div style={{ fontSize: 11, color: C.faint, marginTop: 4 }}>
              Lowercase letters, digits, dots, hyphens and underscores only. Cannot be changed after creation.
            </div>
          )}
        </div>

        {/* Notification title */}
        <div style={{ marginBottom: 15 }}>
          <label style={labelSt}>
            Notification title <span style={{ color: C.red, marginLeft: 2 }}>*</span>
            <span style={{ marginLeft: 'auto', fontSize: 10, fontWeight: 400, opacity: 0.6 }}>
              {draft.title_tmpl.length} chars
            </span>
          </label>
          <input
            ref={titleRef}
            style={inputSt}
            value={draft.title_tmpl}
            onChange={e => setDraft(d => ({ ...d, title_tmpl: e.target.value }))}
            onFocus={() => setActiveField('title')}
            placeholder="e.g. New approval task: {{step_name}}"
            readOnly={!canEdit}
          />
        </div>

        {/* Message body */}
        <div style={{ marginBottom: 12 }}>
          <label style={labelSt}>
            Message body <span style={{ color: C.red, marginLeft: 2 }}>*</span>
            <span style={{ marginLeft: 'auto', fontSize: 10, fontWeight: 400, opacity: 0.6 }}>
              {draft.body_tmpl.length} chars
            </span>
          </label>
          <textarea
            ref={bodyRef}
            style={{ ...inputSt, resize: 'vertical', minHeight: 110, lineHeight: 1.6, fontFamily: 'inherit' }}
            value={draft.body_tmpl}
            onChange={e => setDraft(d => ({ ...d, body_tmpl: e.target.value }))}
            onFocus={() => setActiveField('body')}
            rows={5}
            placeholder="Write the notification message. Use {{tokens}} to insert dynamic values."
            readOnly={!canEdit}
          />
        </div>

        {/* Last updated */}
        {!isNew && updatedAt && (
          <div style={{ fontSize: 11, color: C.faint }}>
            <i className="fas fa-clock" style={{ marginRight: 4 }} />
            Last updated {fmtDate(updatedAt)}
          </div>
        )}
      </div>

      {/* ── Token bar ── */}
      {canEdit && (
        <div style={{
          borderTop: `1px solid ${C.border}`,
          padding: '11px 18px',
          background: C.bg,
          flexShrink: 0,
        }}>
          <div style={{
            fontSize: 11, fontWeight: 600, color: C.muted,
            marginBottom: 7, display: 'flex', alignItems: 'center', gap: 5,
          }}>
            <i className="fas fa-code" style={{ fontSize: 10 }} />
            Available tokens — click to insert at cursor
            <span style={{ fontWeight: 400, opacity: 0.7, marginLeft: 4 }}>
              (editing: {activeField})
            </span>
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5 }}>
            {TOKENS.map(({ token, description }) => {
              const inserted = insertedToken === token;
              return (
                <button
                  key={token}
                  title={description}
                  onClick={() => insertToken(token)}
                  style={{
                    padding: '3px 9px', fontSize: 11, borderRadius: 99,
                    cursor: 'pointer', fontFamily: 'inherit',
                    background: inserted ? '#DCFCE7' : '#fff',
                    color:      inserted ? '#16A34A' : C.text,
                    border: `0.5px solid ${inserted ? '#BBF7D0' : C.border}`,
                    transition: 'all .15s',
                  }}
                >
                  {inserted ? '✓ inserted' : token}
                </button>
              );
            })}
          </div>
        </div>
      )}

      {/* ── Footer: delete link + category badge ── */}
      {!isNew && (
        <div style={{
          padding: '9px 18px',
          borderTop: `1px solid ${C.border}`,
          display: 'flex', justifyContent: 'space-between', alignItems: 'center',
          background: C.bg, flexShrink: 0,
        }}>
          {canEdit ? (
            <button
              onClick={onDelete}
              style={{
                background: 'none', border: 'none', cursor: 'pointer',
                fontSize: 12, color: C.red, display: 'flex', alignItems: 'center', gap: 5,
                fontFamily: 'inherit', padding: '3px 0', opacity: 0.8,
              }}
              onMouseEnter={e => (e.currentTarget.style.opacity = '1')}
              onMouseLeave={e => (e.currentTarget.style.opacity = '0.8')}
            >
              <i className="fas fa-trash" style={{ fontSize: 11 }} />
              Delete template
            </button>
          ) : <span />}
          <span style={{
            fontSize: 10, fontWeight: 600, padding: '2px 8px', borderRadius: 99,
            background: meta.pillBg, color: meta.pillTxt,
          }}>
            {meta.label}
          </span>
        </div>
      )}
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function NotificationConfig() {
  const { can } = usePermissions();
  const canEdit = can('wf_notification_config.edit');

  const [templates,     setTemplates]     = useState<NotifTemplate[]>([]);
  const [loading,       setLoading]       = useState(true);
  const [error,         setError]         = useState<string | null>(null);
  const [editing,       setEditing]       = useState<NotifTemplate | null>(null);
  const [isNew,         setIsNew]         = useState(false);
  const [draft,         setDraft]         = useState(EMPTY_DRAFT);
  const [saving,        setSaving]        = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<NotifTemplate | null>(null);
  const [search,        setSearch]        = useState('');
  const [activeTab,     setActiveTab]     = useState<Category | 'all'>('all');
  const [toast,         setToast]         = useState<{ type: 'ok' | 'err'; msg: string } | null>(null);
  const toastTimer = useRef<number | null>(null);

  function showToast(type: 'ok' | 'err', msg: string) {
    setToast({ type, msg });
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 4000);
  }

  // ── Load ─────────────────────────────────────────────────────────────────

  async function load() {
    setLoading(true); setError(null);
    const { data, error: err } = await supabase
      .from('workflow_notification_templates')
      .select('id, code, title_tmpl, body_tmpl, updated_at')
      .order('code');
    if (err) setError(err.message);
    else setTemplates(data ?? []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  // ── Open / select ─────────────────────────────────────────────────────────

  function openCreate() {
    setEditing(null);
    setIsNew(true);
    setDraft(EMPTY_DRAFT);
  }

  function openEdit(t: NotifTemplate) {
    setEditing(t);
    setIsNew(false);
    setDraft({ code: t.code, title_tmpl: t.title_tmpl, body_tmpl: t.body_tmpl });
  }

  function openDuplicate() {
    if (!editing) return;
    const src = editing;
    setEditing(null);
    setIsNew(true);
    setDraft({ code: src.code + '_copy', title_tmpl: src.title_tmpl, body_tmpl: src.body_tmpl });
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  async function handleSave() {
    setSaving(true);
    if (isNew) {
      const { data, error: err } = await supabase
        .from('workflow_notification_templates')
        .insert({ code: draft.code, title_tmpl: draft.title_tmpl, body_tmpl: draft.body_tmpl })
        .select('id, code, title_tmpl, body_tmpl, updated_at')
        .single();
      if (err) { showToast('err', err.message); }
      else {
        showToast('ok', 'Template created');
        setTemplates(prev => [...prev, data].sort((a, b) => a.code.localeCompare(b.code)));
        openEdit(data);
      }
    } else if (editing) {
      const { error: err } = await supabase
        .from('workflow_notification_templates')
        .update({ title_tmpl: draft.title_tmpl, body_tmpl: draft.body_tmpl })
        .eq('id', editing.id);
      if (err) { showToast('err', err.message); }
      else {
        showToast('ok', 'Template saved');
        const now = new Date().toISOString();
        setTemplates(prev => prev.map(t =>
          t.id === editing.id
            ? { ...t, title_tmpl: draft.title_tmpl, body_tmpl: draft.body_tmpl, updated_at: now }
            : t
        ));
        setEditing(prev => prev
          ? { ...prev, title_tmpl: draft.title_tmpl, body_tmpl: draft.body_tmpl, updated_at: now }
          : prev
        );
      }
    }
    setSaving(false);
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  async function handleDelete(t: NotifTemplate) {
    const { error: err } = await supabase
      .from('workflow_notification_templates')
      .delete()
      .eq('id', t.id);
    if (err) { showToast('err', err.message); }
    else {
      showToast('ok', 'Template deleted');
      setTemplates(prev => prev.filter(x => x.id !== t.id));
      setEditing(null);
      setIsNew(false);
      setDraft(EMPTY_DRAFT);
    }
    setConfirmDelete(null);
  }

  // ── Filter ────────────────────────────────────────────────────────────────

  const filtered = templates.filter(t => {
    const q = search.toLowerCase();
    const matchSearch = !q || t.code.includes(q) || t.title_tmpl.toLowerCase().includes(q);
    const matchTab    = activeTab === 'all' || getCategory(t.code) === activeTab;
    return matchSearch && matchTab;
  });

  const counts = templates.reduce<Record<string, number>>((acc, t) => {
    const cat = getCategory(t.code);
    acc[cat] = (acc[cat] ?? 0) + 1;
    return acc;
  }, {});

  const showEditor = isNew || editing !== null;

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div style={{ fontFamily: 'inherit', display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0 }}>

      {/* ── Page header ── */}
      <div style={{
        padding: '16px 24px 14px',
        background: '#fff',
        borderBottom: `1px solid ${C.border}`,
        display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        flexShrink: 0,
      }}>
        <div>
          <h1 style={{
            fontSize: 18, fontWeight: 700, color: C.navy, margin: 0,
            display: 'flex', alignItems: 'center', gap: 9,
          }}>
            <div style={{
              width: 32, height: 32, borderRadius: 8, background: '#EFF6FF',
              display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
            }}>
              <i className="fas fa-envelope-open-text" style={{ color: '#2563EB', fontSize: 14 }} />
            </div>
            Manage notifications
          </h1>
          <p style={{ fontSize: 12, color: C.muted, margin: '5px 0 0 41px' }}>
            Configure message templates sent by the workflow engine.
          </p>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {/* Category summary chips */}
          {(['task','sla','approval','returned','admin'] as Category[]).map(cat => {
            const m = CAT[cat];
            const n = counts[cat] ?? 0;
            if (!n) return null;
            return (
              <span key={cat} style={{
                display: 'inline-flex', alignItems: 'center', gap: 4,
                padding: '3px 9px', borderRadius: 20, fontSize: 11, fontWeight: 600,
                background: m.bg, color: m.color, border: `1px solid ${m.border}`,
              }}>
                <i className={`fas ${m.icon}`} style={{ fontSize: 9 }} />
                {n} {m.label}
              </span>
            );
          })}
          {canEdit && (
            <button onClick={openCreate} style={primaryBtn}>
              <i className="fas fa-plus" style={{ marginRight: 6 }} />
              New template
            </button>
          )}
        </div>
      </div>

      {/* ── View-only banner ── */}
      {!canEdit && (
        <div style={{
          margin: '12px 24px 0', padding: '9px 14px', borderRadius: 8,
          background: '#FFFBEB', border: `1px solid #FDE68A`,
          display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: '#92400E',
          flexShrink: 0,
        }}>
          <i className="fas fa-eye" style={{ color: '#D97706' }} />
          You have read-only access. Contact an admin to make changes.
        </div>
      )}

      {/* ── Error ── */}
      {error && (
        <div style={{
          margin: '12px 24px 0', padding: '9px 14px', borderRadius: 8,
          background: C.redL, border: `1px solid #FECACA`,
          display: 'flex', gap: 8, alignItems: 'center', fontSize: 13, color: C.red,
          flexShrink: 0,
        }}>
          <i className="fas fa-circle-exclamation" />
          {error}
        </div>
      )}

      {/* ── Split view ── */}
      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>

        {/* ── Left panel ── */}
        <div style={{
          width: 320, minWidth: 320,
          display: 'flex', flexDirection: 'column',
          borderRight: `1px solid ${C.border}`,
          background: C.bg,
          minHeight: 0,
        }}>

          {/* Search */}
          <div style={{ padding: '12px 14px 0', flexShrink: 0 }}>
            <div style={{ fontSize: 12, fontWeight: 600, color: C.muted, marginBottom: 9 }}>
              Templates
            </div>
            <div style={{ position: 'relative', marginBottom: 9 }}>
              <i className="fas fa-magnifying-glass" style={{
                position: 'absolute', left: 9, top: '50%', transform: 'translateY(-50%)',
                color: C.faint, fontSize: 12, pointerEvents: 'none',
              }} />
              <input
                value={search}
                onChange={e => setSearch(e.target.value)}
                placeholder="Search by code or title…"
                style={{ ...inputSt, paddingLeft: 28, fontSize: 12 }}
              />
            </div>
          </div>

          {/* Category filter tabs */}
          <div style={{
            display: 'flex', gap: 4, padding: '0 14px 9px',
            flexWrap: 'wrap', borderBottom: `1px solid ${C.border}`, flexShrink: 0,
          }}>
            {ALL_CATEGORIES.map(cat => {
              const isAll  = cat === 'all';
              const meta   = isAll ? null : CAT[cat as Category];
              const count  = isAll ? templates.length : (counts[cat] ?? 0);
              const active = activeTab === cat;
              return (
                <button
                  key={cat}
                  onClick={() => setActiveTab(cat)}
                  style={{
                    padding: '3px 10px', borderRadius: 99, fontSize: 11,
                    cursor: 'pointer', fontFamily: 'inherit',
                    border: '0.5px solid transparent',
                    background: active ? (meta ? meta.color : C.navy) : 'transparent',
                    color:      active ? '#fff' : C.muted,
                  }}
                >
                  {isAll ? 'All' : meta!.label} {count}
                </button>
              );
            })}
          </div>

          {/* Template list */}
          <div style={{ flex: 1, overflowY: 'auto' }}>
            {loading ? (
              <div style={{ padding: '32px 14px', textAlign: 'center', fontSize: 12, color: C.faint }}>
                <i className="fas fa-spinner fa-spin" style={{ marginRight: 6 }} />
                Loading…
              </div>
            ) : filtered.length === 0 ? (
              <div style={{ padding: '32px 14px', textAlign: 'center', fontSize: 12, color: C.faint }}>
                No templates found
              </div>
            ) : filtered.map(t => {
              const meta  = CAT[getCategory(t.code)];
              const isSel = editing?.id === t.id;
              return (
                <div
                  key={t.id}
                  onClick={() => openEdit(t)}
                  style={{
                    padding: '10px 14px', cursor: 'pointer',
                    borderBottom: `0.5px solid ${C.border}`,
                    borderLeft: `2px solid ${isSel ? meta.color : 'transparent'}`,
                    background: isSel ? '#fff' : 'transparent',
                    display: 'flex', flexDirection: 'column', gap: 4,
                    transition: 'background 0.1s',
                  }}
                  onMouseEnter={e => { if (!isSel) (e.currentTarget as HTMLDivElement).style.background = '#fff'; }}
                  onMouseLeave={e => { if (!isSel) (e.currentTarget as HTMLDivElement).style.background = 'transparent'; }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span style={{
                      fontSize: 10, fontWeight: 600, padding: '2px 7px', borderRadius: 99,
                      background: meta.pillBg, color: meta.pillTxt,
                      whiteSpace: 'nowrap', flexShrink: 0,
                    }}>
                      {meta.label}
                    </span>
                    <code style={{
                      fontSize: 11, color: C.muted,
                      overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                      flex: 1, minWidth: 0,
                    }}>
                      {t.code}
                    </code>
                  </div>
                  <div style={{
                    fontSize: 13, color: C.text,
                    overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  }}>
                    {t.title_tmpl}
                  </div>
                </div>
              );
            })}
          </div>

          {/* List footer: count */}
          <div style={{
            padding: '8px 14px', borderTop: `0.5px solid ${C.border}`,
            fontSize: 11, color: C.faint, flexShrink: 0,
          }}>
            {filtered.length} template{filtered.length !== 1 ? 's' : ''}
          </div>
        </div>

        {/* ── Right panel ── */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0, minWidth: 0 }}>
          {showEditor ? (
            <TemplateEditor
              draft={draft}
              setDraft={setDraft}
              isNew={isNew}
              saving={saving}
              canEdit={canEdit}
              updatedAt={editing?.updated_at}
              onSave={handleSave}
              onDelete={() => editing && setConfirmDelete(editing)}
              onDuplicate={openDuplicate}
            />
          ) : (
            <div style={{
              flex: 1, display: 'flex', flexDirection: 'column',
              alignItems: 'center', justifyContent: 'center',
              color: C.faint, gap: 10,
            }}>
              <i className="fas fa-envelope-open" style={{ fontSize: 32, opacity: 0.3 }} />
              <p style={{ fontSize: 13 }}>Select a template to edit</p>
            </div>
          )}
        </div>
      </div>

      {/* ── Delete confirm modal ── */}
      {confirmDelete && (
        <div style={{
          position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', zIndex: 300,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <div style={{
            background: '#fff', borderRadius: 12, padding: 28, maxWidth: 420, width: '90%',
            boxShadow: '0 8px 40px rgba(0,0,0,0.18)',
          }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}>
              <div style={{
                width: 40, height: 40, borderRadius: 10,
                background: C.redL, display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>
                <i className="fas fa-trash" style={{ color: C.red, fontSize: 16 }} />
              </div>
              <h3 style={{ margin: 0, fontSize: 16, color: C.navy }}>Delete template?</h3>
            </div>
            <p style={{ fontSize: 13, color: C.muted, margin: '0 0 6px' }}>
              <code style={{ color: '#2563EB', background: '#EFF6FF', padding: '1px 6px', borderRadius: 3 }}>
                {confirmDelete.code}
              </code>
            </p>
            <p style={{ fontSize: 13, color: C.muted, margin: '0 0 22px' }}>
              This template will be permanently deleted. Workflow steps referencing this code will stop receiving notifications.
            </p>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button onClick={() => setConfirmDelete(null)} style={ghostBtn}>Cancel</button>
              <button
                onClick={() => handleDelete(confirmDelete)}
                style={{ ...primaryBtn, background: C.red }}
              >
                <i className="fas fa-trash" style={{ marginRight: 6 }} />
                Delete
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Toast ── */}
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
    </div>
  );
}

// ─── Shared styles ────────────────────────────────────────────────────────────

const labelSt: React.CSSProperties = {
  display: 'flex', fontSize: 11, fontWeight: 600,
  color: '#6B7280', marginBottom: 5, alignItems: 'center',
};

const inputSt: React.CSSProperties = {
  width: '100%', padding: '7px 10px', boxSizing: 'border-box',
  border: `1px solid #E5E7EB`, borderRadius: 7,
  fontSize: 13, outline: 'none', fontFamily: 'inherit',
  background: '#fff', color: '#111827',
};

const primaryBtn: React.CSSProperties = {
  display: 'inline-flex', alignItems: 'center',
  padding: '7px 14px', borderRadius: 7, fontSize: 12, fontWeight: 600,
  background: '#18345B', color: '#fff', border: 'none', cursor: 'pointer',
};

const ghostBtn: React.CSSProperties = {
  display: 'inline-flex', alignItems: 'center',
  padding: '7px 14px', borderRadius: 7, fontSize: 12, fontWeight: 600,
  background: '#fff', color: '#374151', border: `1px solid #E5E7EB`, cursor: 'pointer',
};

const iconBtn: React.CSSProperties = {
  padding: '6px 8px', background: 'transparent',
  border: `0.5px solid #E5E7EB`, color: '#6B7280',
  borderRadius: 7, cursor: 'pointer', fontSize: 13, lineHeight: 1,
};
