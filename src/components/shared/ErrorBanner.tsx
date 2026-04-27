interface ErrorBannerProps {
  message: string;
  /** Optional retry callback — shows a Retry button when provided */
  onRetry?: () => void;
}

/**
 * Consistent full-page error state used by components that depend on
 * data-fetching hooks. Renders whenever a hook's `error` is non-null.
 *
 * Usage:
 *   const { data, error, refetch } = useSomeHook();
 *   if (error) return <ErrorBanner message={error} onRetry={refetch} />;
 */
export default function ErrorBanner({ message, onRetry }: ErrorBannerProps) {
  return (
    <div style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      justifyContent: 'center', padding: '60px 20px', gap: 12, color: '#6B7280',
    }}>
      <i className="fa-solid fa-circle-exclamation" style={{ fontSize: 32, color: '#F87171' }} />
      <p style={{ margin: 0, fontWeight: 600, color: '#374151', fontSize: 15 }}>
        Failed to load data
      </p>
      <p style={{ margin: 0, fontSize: 13, maxWidth: 420, textAlign: 'center' }}>
        {message}
      </p>
      {onRetry && (
        <button
          onClick={onRetry}
          style={{
            marginTop: 4, padding: '6px 18px', borderRadius: 6, border: '1px solid #D1D5DB',
            background: '#F9FAFB', cursor: 'pointer', fontSize: 13, color: '#374151',
            display: 'flex', alignItems: 'center', gap: 6,
          }}
        >
          <i className="fa-solid fa-rotate-right" />
          Retry
        </button>
      )}
    </div>
  );
}
