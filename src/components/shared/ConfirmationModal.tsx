import { useEffect, useRef } from 'react';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export interface ConfirmationModalProps {
  isOpen: boolean;
  title: string;
  message: string;
  warning?: string;
  confirmText?: string;
  cancelText?: string;
  destructive?: boolean;
  loading?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

// ─────────────────────────────────────────────────────────────────────────────
// Component
// ─────────────────────────────────────────────────────────────────────────────

export default function ConfirmationModal({
  isOpen,
  title,
  message,
  warning,
  confirmText = 'Confirm',
  cancelText  = 'Cancel',
  destructive = true,
  loading     = false,
  onConfirm,
  onCancel,
}: ConfirmationModalProps) {
  const cancelRef  = useRef<HTMLButtonElement>(null);
  const confirmRef = useRef<HTMLButtonElement>(null);

  // Focus cancel button on open (safer default for destructive actions)
  useEffect(() => {
    if (isOpen) cancelRef.current?.focus();
  }, [isOpen]);

  // Keyboard: Escape → cancel, Enter → confirm
  useEffect(() => {
    if (!isOpen) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
      if (e.key === 'Enter')  { e.preventDefault(); onConfirm(); }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [isOpen, onConfirm, onCancel]);

  if (!isOpen) return null;

  const iconClass    = destructive ? 'fa-triangle-exclamation' : 'fa-circle-info';
  const iconColor    = destructive ? '#DC2626' : '#2563EB';
  const confirmBg    = destructive ? '#DC2626' : '#18345B';
  const confirmHover = destructive ? '#B91C1C' : '#243f6e';

  return (
    <>
      {/* ── Backdrop ──────────────────────────────────────────────────────── */}
      <div
        onClick={onCancel}
        style={{
          position: 'fixed', inset: 0,
          background: 'rgba(15, 23, 42, 0.40)',
          backdropFilter: 'blur(2px)',
          zIndex: 1000,
          animation: 'cm-fade-in 0.15s ease',
        }}
        aria-hidden="true"
      />

      {/* ── Dialog ────────────────────────────────────────────────────────── */}
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="cm-title"
        aria-describedby="cm-message"
        style={{
          position: 'fixed', inset: 0,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          zIndex: 1001,
          padding: '16px',
          pointerEvents: 'none',
        }}
      >
        <div
          style={{
            background: '#ffffff',
            borderRadius: 10,
            border: '1px solid #e8edf5',
            boxShadow: '0 8px 32px rgba(24, 52, 91, 0.14), 0 2px 10px rgba(24, 52, 91, 0.07)',
            width: '100%',
            maxWidth: 420,
            overflow: 'hidden',
            pointerEvents: 'all',
            animation: 'cm-slide-in 0.18s ease',
          }}
        >

          {/* ── Title row ─────────────────────────────────────────────────── */}
          <div
            style={{
              padding: '24px 24px 0',
              display: 'flex',
              alignItems: 'center',
              gap: 10,
            }}
          >
            <i
              className={`fa-solid ${iconClass}`}
              style={{ color: iconColor, fontSize: 17, flexShrink: 0 }}
            />
            <h3
              id="cm-title"
              style={{
                margin: 0,
                fontSize: 16,
                fontWeight: 700,
                color: '#0f172a',
                lineHeight: 1.3,
                fontFamily: 'inherit',
              }}
            >
              {title}
            </h3>
          </div>

          {/* ── Body ──────────────────────────────────────────────────────── */}
          <div style={{ padding: '16px 24px 0' }}>
            <p
              id="cm-message"
              style={{
                margin: 0,
                fontSize: 14,
                color: '#2d3a4a',
                lineHeight: 1.65,
                fontFamily: 'inherit',
              }}
            >
              {message}
            </p>

            {warning && (
              <p style={{
                margin: '10px 0 0',
                fontSize: 13,
                color: '#64748B',
                lineHeight: 1.55,
                fontFamily: 'inherit',
              }}>
                {warning}
              </p>
            )}
          </div>

          {/* ── Divider ───────────────────────────────────────────────────── */}
          <div style={{ borderTop: '1px solid #E2E8F0', margin: '24px 0 0' }} />

          {/* ── Footer ────────────────────────────────────────────────────── */}
          <div
            style={{
              padding: '16px 24px',
              display: 'flex',
              justifyContent: 'flex-end',
              gap: 10,
            }}
          >
            <button
              ref={cancelRef}
              onClick={onCancel}
              style={{
                padding: '8px 20px',
                borderRadius: 6,
                border: '1.5px solid #D1D5DB',
                background: '#ffffff',
                color: '#374151',
                fontSize: 13,
                fontWeight: 500,
                cursor: 'pointer',
                fontFamily: 'inherit',
                transition: 'background 0.15s, border-color 0.15s',
              }}
              onMouseEnter={e => {
                (e.currentTarget as HTMLButtonElement).style.background    = '#F9FAFB';
                (e.currentTarget as HTMLButtonElement).style.borderColor   = '#9CA3AF';
              }}
              onMouseLeave={e => {
                (e.currentTarget as HTMLButtonElement).style.background    = '#ffffff';
                (e.currentTarget as HTMLButtonElement).style.borderColor   = '#D1D5DB';
              }}
            >
              {cancelText}
            </button>

            <button
              ref={confirmRef}
              onClick={onConfirm}
              disabled={loading}
              style={{
                padding: '8px 20px',
                borderRadius: 6,
                border: 'none',
                background: loading ? '#94a3b8' : confirmBg,
                color: '#ffffff',
                fontSize: 13,
                fontWeight: 600,
                cursor: loading ? 'not-allowed' : 'pointer',
                fontFamily: 'inherit',
                display: 'flex',
                alignItems: 'center',
                gap: 7,
                transition: 'background 0.15s',
                opacity: loading ? 0.75 : 1,
              }}
              onMouseEnter={e => {
                if (!loading) (e.currentTarget as HTMLButtonElement).style.background = confirmHover;
              }}
              onMouseLeave={e => {
                if (!loading) (e.currentTarget as HTMLButtonElement).style.background = confirmBg;
              }}
            >
              {loading
                ? <i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 11 }} />
                : destructive && <i className="fa-solid fa-trash" style={{ fontSize: 11 }} />}
              {loading ? 'Working…' : confirmText}
            </button>
          </div>
        </div>
      </div>

      {/* ── Keyframe animations ────────────────────────────────────────────── */}
      <style>{`
        @keyframes cm-fade-in  { from { opacity: 0 } to { opacity: 1 } }
        @keyframes cm-slide-in { from { opacity: 0; transform: scale(0.97) translateY(-8px) } to { opacity: 1; transform: scale(1) translateY(0) } }
      `}</style>
    </>
  );
}
