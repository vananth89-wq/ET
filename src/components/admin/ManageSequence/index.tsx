/**
 * ManageSequence — Employee ID Sequence Admin Page
 *
 * View section (manage_emp_sequence.view):
 *   - Current next value + raw last_value + is_called
 *   - Count of employees in EMP-XXXX (sequence) format
 *   - Count of employees in legacy EMPXXXX format
 *   - Refresh button
 *
 * Edit section (manage_emp_sequence.edit):
 *   - Input to advance the sequence FORWARD to a new next value
 *   - Client-side preview of the resulting EMP-XXXXXX id
 *   - Confirm dialog before applying
 *   - Server rejects going backward (would risk collisions)
 *
 * Backing RPCs (see migration 20260709682_emp_sequence_management.sql):
 *   get_emp_id_seq_status()               — read
 *   admin_set_emp_id_seq(p_new_next_value)— forward-only write
 */

import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../../lib/supabase';
import { usePermissions } from '../../../hooks/usePermissions';

// ─── Types ────────────────────────────────────────────────────────────────────

interface SeqStatus {
  last_value:                   number;
  is_called:                    boolean;
  next_value:                   number;
  next_formatted:               string;
  employees_with_seq_format:    number;
  employees_with_legacy_format: number;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatEmpId(n: number): string {
  if (!Number.isFinite(n) || n < 1) return '';
  return 'EMP-' + String(Math.floor(n)).padStart(4, '0');
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function ManageSequence() {
  const { can } = usePermissions();
  const canEdit = can('manage_emp_sequence.edit');

  const [status,      setStatus]      = useState<SeqStatus | null>(null);
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState<string | null>(null);

  // Edit form
  const [newValueStr, setNewValueStr] = useState('');
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [saving,      setSaving]      = useState(false);
  const [successMsg,  setSuccessMsg]  = useState<string | null>(null);
  const [editError,   setEditError]   = useState<string | null>(null);

  // ── Load status ───────────────────────────────────────────────────────────
  const loadStatus = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error } = await supabase.rpc('get_emp_id_seq_status');
    if (error || !data) {
      setError(error?.message || 'Failed to load sequence status');
      setStatus(null);
    } else {
      setStatus(data as SeqStatus);
    }
    setLoading(false);
  }, []);

  useEffect(() => { loadStatus(); }, [loadStatus]);

  // ── Preview of the entered value ──────────────────────────────────────────
  const parsedNewValue = (() => {
    const n = parseInt(newValueStr, 10);
    return Number.isFinite(n) && n > 0 ? n : null;
  })();
  const previewId = parsedNewValue !== null ? formatEmpId(parsedNewValue) : '';

  const canSubmit =
    canEdit &&
    parsedNewValue !== null &&
    status !== null &&
    parsedNewValue > status.next_value &&
    !saving;

  // ── Apply the update ──────────────────────────────────────────────────────
  async function handleApply() {
    if (!parsedNewValue || !status) return;
    setSaving(true);
    setEditError(null);
    setSuccessMsg(null);

    const { data, error } = await supabase.rpc('admin_set_emp_id_seq', {
      p_new_next_value: parsedNewValue,
    });

    setSaving(false);
    setConfirmOpen(false);

    if (error) {
      setEditError(error.message || 'Failed to update sequence');
      return;
    }

    const res = data as { new_next_formatted?: string; previous_next_value?: number; new_next_value?: number };
    setSuccessMsg(
      `Sequence advanced. Next assigned ID will be ${res.new_next_formatted ?? formatEmpId(parsedNewValue)} ` +
      `(skipped ${(res.new_next_value ?? parsedNewValue) - (res.previous_next_value ?? 0)} numbers).`
    );
    setNewValueStr('');
    loadStatus();
  }

  // ── Render ────────────────────────────────────────────────────────────────

  if (loading && !status) {
    return (
      <div className="ar-panel" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: 200 }}>
        <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 22, color: '#6B7280' }} />
        <span style={{ marginLeft: 10, color: '#6B7280' }}>Loading sequence status…</span>
      </div>
    );
  }

  return (
    <div className="ar-panel">

      {/* Title */}
      <h2 className="page-title">Manage Employee ID Sequence</h2>
      <p className="page-subtitle" style={{ marginBottom: 16 }}>
        View the current state of the employee ID sequence and, if permitted, advance it forward.
        Numbers between the current and new value will be permanently skipped.
      </p>

      {/* Error banner */}
      {error && (
        <div style={{
          background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 8,
          padding: '14px 18px', color: '#B91C1C', fontSize: 13, marginBottom: 16,
        }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 8 }} />
          {error}
        </div>
      )}

      {/* ── VIEW SECTION ─────────────────────────────────────────────────── */}
      {status && (
        <div style={{
          background: '#F8FAFC', border: '1px solid #E5E7EB', borderRadius: 10,
          padding: '20px 24px', marginBottom: 24,
        }}>
          <div style={{
            display: 'flex', justifyContent: 'space-between', alignItems: 'center',
            marginBottom: 16,
          }}>
            <h3 style={{ margin: 0, fontSize: 16, fontWeight: 600, color: '#111827' }}>
              <i className="fa-solid fa-list-ol" style={{ marginRight: 8, color: '#6B7280' }} />
              Current Sequence Status
            </h3>
            <button
              onClick={loadStatus}
              disabled={loading}
              style={{
                background: '#fff', border: '1px solid #D1D5DB', borderRadius: 6,
                padding: '6px 12px', fontSize: 13, cursor: loading ? 'default' : 'pointer',
                color: '#374151', display: 'inline-flex', alignItems: 'center', gap: 6,
              }}
            >
              <i className={`fa-solid fa-${loading ? 'spinner fa-spin' : 'rotate'}`} style={{ fontSize: 12 }} />
              Refresh
            </button>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 16 }}>
            <StatCard
              icon="fa-hashtag"
              label="Next assigned ID"
              value={status.next_formatted}
              highlight
            />
            <StatCard
              icon="fa-users"
              label="Total employees"
              value={String(status.employees_with_seq_format)}
            />
          </div>
        </div>
      )}

      {/* ── EDIT SECTION ─────────────────────────────────────────────────── */}
      {canEdit && status && (
        <div style={{
          background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
          padding: '20px 24px',
        }}>
          <h3 style={{ margin: 0, marginBottom: 6, fontSize: 16, fontWeight: 600, color: '#111827' }}>
            <i className="fa-solid fa-forward" style={{ marginRight: 8, color: '#6B7280' }} />
            Advance Sequence
          </h3>
          <p style={{ margin: 0, marginBottom: 16, fontSize: 13, color: '#6B7280' }}>
            Set the next employee ID number. Forward-only — numbers below the current next value would risk
            collisions with existing employees and are rejected by the server.
          </p>

          {successMsg && (
            <div style={{
              background: '#DCFCE7', border: '1px solid #86EFAC', borderRadius: 8,
              padding: '10px 14px', color: '#166534', fontSize: 13, marginBottom: 12,
            }}>
              <i className="fa-solid fa-circle-check" style={{ marginRight: 8 }} />
              {successMsg}
            </div>
          )}

          {editError && (
            <div style={{
              background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 8,
              padding: '10px 14px', color: '#B91C1C', fontSize: 13, marginBottom: 12,
            }}>
              <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 8 }} />
              {editError}
            </div>
          )}

          <div style={{
            display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20,
            alignItems: 'end',
          }}>
            <div>
              <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: '#374151', marginBottom: 6 }}>
                Set next employee ID number to
              </label>
              <input
                type="number"
                min={status.next_value + 1}
                step={1}
                value={newValueStr}
                onChange={e => { setNewValueStr(e.target.value); setEditError(null); setSuccessMsg(null); }}
                placeholder={`e.g. ${status.next_value + 100}`}
                style={{
                  width: '100%', padding: '9px 12px', fontSize: 14,
                  border: '1px solid #D1D5DB', borderRadius: 6, outline: 'none',
                }}
              />
              <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 4 }}>
                Must be greater than current next value ({status.next_value}).
              </div>
            </div>

            <div>
              <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: '#374151', marginBottom: 6 }}>
                Will be assigned as
              </label>
              <div style={{
                padding: '9px 12px', fontSize: 14, fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
                border: '1px solid #E5E7EB', borderRadius: 6, background: '#F9FAFB',
                color: previewId ? '#111827' : '#9CA3AF',
                minHeight: 22,
              }}>
                {previewId || '—'}
              </div>
              <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 4 }}>
                Preview only — nothing changes until you apply.
              </div>
            </div>
          </div>

          <div style={{ marginTop: 20, display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
            <button
              onClick={() => { setNewValueStr(''); setEditError(null); setSuccessMsg(null); }}
              disabled={!newValueStr || saving}
              style={{
                background: '#fff', border: '1px solid #D1D5DB', borderRadius: 6,
                padding: '8px 16px', fontSize: 13, color: '#374151',
                cursor: !newValueStr || saving ? 'default' : 'pointer',
                opacity: !newValueStr || saving ? 0.5 : 1,
              }}
            >
              Clear
            </button>
            <button
              onClick={() => setConfirmOpen(true)}
              disabled={!canSubmit}
              style={{
                background: canSubmit ? '#2563EB' : '#93C5FD',
                color: '#fff', border: 'none', borderRadius: 6,
                padding: '8px 18px', fontSize: 13, fontWeight: 600,
                cursor: canSubmit ? 'pointer' : 'default',
              }}
            >
              <i className="fa-solid fa-forward" style={{ marginRight: 8 }} />
              Update sequence
            </button>
          </div>
        </div>
      )}

      {/* ── CONFIRMATION DIALOG ──────────────────────────────────────────── */}
      {confirmOpen && status && parsedNewValue !== null && (
        <div
          role="dialog"
          aria-modal="true"
          style={{
            position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.4)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000,
          }}
          onClick={() => !saving && setConfirmOpen(false)}
        >
          <div
            style={{
              background: '#fff', borderRadius: 10, padding: '24px 28px',
              maxWidth: 480, width: '90%', boxShadow: '0 20px 40px rgba(0,0,0,0.15)',
            }}
            onClick={e => e.stopPropagation()}
          >
            <h3 style={{ margin: 0, marginBottom: 12, fontSize: 17, fontWeight: 600, color: '#111827' }}>
              <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 10, color: '#F59E0B' }} />
              Confirm Sequence Update
            </h3>
            <p style={{ margin: 0, marginBottom: 8, fontSize: 14, color: '#374151' }}>
              This will skip from <strong>{status.next_formatted}</strong> to <strong>{formatEmpId(parsedNewValue)}</strong>.
            </p>
            <p style={{ margin: 0, marginBottom: 20, fontSize: 13, color: '#6B7280' }}>
              The {parsedNewValue - status.next_value} numbers in between will never be assigned to any employee. This cannot be undone. Continue?
            </p>
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
              <button
                onClick={() => setConfirmOpen(false)}
                disabled={saving}
                style={{
                  background: '#fff', border: '1px solid #D1D5DB', borderRadius: 6,
                  padding: '8px 16px', fontSize: 13, color: '#374151',
                  cursor: saving ? 'default' : 'pointer',
                }}
              >
                Cancel
              </button>
              <button
                onClick={handleApply}
                disabled={saving}
                style={{
                  background: '#2563EB', color: '#fff', border: 'none', borderRadius: 6,
                  padding: '8px 18px', fontSize: 13, fontWeight: 600,
                  cursor: saving ? 'default' : 'pointer',
                  opacity: saving ? 0.7 : 1,
                }}
              >
                {saving ? (
                  <>
                    <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 8 }} />
                    Applying…
                  </>
                ) : (
                  <>
                    <i className="fa-solid fa-check" style={{ marginRight: 8 }} />
                    Yes, advance sequence
                  </>
                )}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function StatCard({ icon, label, value, highlight = false }: {
  icon: string; label: string; value: string; highlight?: boolean;
}) {
  return (
    <div style={{
      background: highlight ? '#EFF6FF' : '#fff',
      border: '1px solid ' + (highlight ? '#BFDBFE' : '#E5E7EB'),
      borderRadius: 8, padding: '12px 16px',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
        <i className={`fa-solid ${icon}`} style={{ fontSize: 12, color: highlight ? '#2563EB' : '#6B7280' }} />
        <span style={{ fontSize: 11, fontWeight: 600, color: '#6B7280', textTransform: 'uppercase', letterSpacing: 0.5 }}>
          {label}
        </span>
      </div>
      <div style={{
        fontSize: 18, fontWeight: 700,
        color: highlight ? '#1D4ED8' : '#111827',
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
      }}>
        {value}
      </div>
    </div>
  );
}
