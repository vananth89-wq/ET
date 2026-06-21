/**
 * CancelInflightButton
 *
 * Visible to the uploader (and system admins) while a job is in
 * validating or processing status. Sets status = 'cancelled'.
 */

import { useState } from 'react';
import { supabase } from '../../../lib/supabase';

interface Props {
  jobId:    string;
  onCancel: () => void;
}

export default function CancelInflightButton({ jobId, onCancel }: Props) {
  const [cancelling,   setCancelling]   = useState(false);
  const [showConfirm,  setShowConfirm]  = useState(false);
  const [error,        setError]        = useState<string | null>(null);

  async function doCancel() {
    setShowConfirm(false);
    setCancelling(true);
    setError(null);

    const { error: err } = await supabase
      .from('bulk_upload_job')
      .update({
        status:       'cancelled',
        cancelled_at: new Date().toISOString(),
        updated_at:   new Date().toISOString(),
      })
      .eq('id', jobId);

    setCancelling(false);

    if (err) {
      setError(err.message);
    } else {
      onCancel();
    }
  }

  return (
    <>
      {/* ── Trigger button ──────────────────────────────────────────────── */}
      <div>
        <button
          onClick={() => setShowConfirm(true)}
          disabled={cancelling}
          style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            padding: '5px 12px', borderRadius: 6, fontSize: 12,
            border: '1px solid #FCA5A5', background: '#FEF2F2',
            color: '#DC2626', cursor: cancelling ? 'default' : 'pointer',
            fontWeight: 500,
          }}
        >
          <i className={`fa-solid ${cancelling ? 'fa-spinner fa-spin' : 'fa-xmark'}`} style={{ fontSize: 11 }} />
          {cancelling ? 'Cancelling…' : 'Cancel upload'}
        </button>
        {error && (
          <div style={{ marginTop: 4, fontSize: 11, color: '#DC2626' }}>{error}</div>
        )}
      </div>

      {/* ── Confirmation modal ──────────────────────────────────────────── */}
      {showConfirm && (
        <div style={styles.backdrop} onClick={() => setShowConfirm(false)}>
          <div style={styles.dialog} onClick={e => e.stopPropagation()}>
            <div style={styles.iconWrap}>
              <i className="fa-solid fa-triangle-exclamation" style={{ fontSize: 22, color: '#DC2626' }} />
            </div>
            <h3 style={styles.title}>Cancel this upload?</h3>
            <p style={styles.body}>
              Rows already committed will remain. Remaining rows will be skipped.
            </p>
            <div style={styles.actions}>
              <button style={styles.btnSecondary} onClick={() => setShowConfirm(false)}>
                Keep processing
              </button>
              <button style={styles.btnDanger} onClick={doCancel}>
                Yes, cancel
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  backdrop: {
    position: 'fixed', inset: 0,
    background: 'rgba(0,0,0,0.45)',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    zIndex: 1000,
  },
  dialog: {
    background: '#fff',
    borderRadius: 12,
    padding: '32px 28px 24px',
    width: 400,
    maxWidth: '90vw',
    boxShadow: '0 20px 60px rgba(0,0,0,0.18)',
    textAlign: 'center',
  },
  iconWrap: {
    width: 48, height: 48, borderRadius: '50%',
    background: '#FEF2F2',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    margin: '0 auto 16px',
  },
  title: {
    margin: '0 0 8px',
    fontSize: 17, fontWeight: 600, color: '#111827',
  },
  body: {
    margin: '0 0 24px',
    fontSize: 14, color: '#6B7280', lineHeight: 1.5,
  },
  actions: {
    display: 'flex', gap: 10, justifyContent: 'center',
  },
  btnSecondary: {
    flex: 1, padding: '9px 16px', borderRadius: 8,
    border: '1px solid #D1D5DB', background: '#fff',
    fontSize: 13, fontWeight: 500, color: '#374151',
    cursor: 'pointer',
  },
  btnDanger: {
    flex: 1, padding: '9px 16px', borderRadius: 8,
    border: 'none', background: '#DC2626',
    fontSize: 13, fontWeight: 500, color: '#fff',
    cursor: 'pointer',
  },
};
