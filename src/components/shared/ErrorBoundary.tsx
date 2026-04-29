/**
 * ErrorBoundary.tsx
 *
 * A reusable React error boundary that catches any unhandled JS exceptions
 * thrown during rendering, and replaces the broken subtree with a
 * friendly fallback UI instead of blanking the whole page.
 *
 * Usage:
 *   // Wrap the full app (catastrophic fallback)
 *   <ErrorBoundary><App /></ErrorBoundary>
 *
 *   // Wrap a single screen (contained fallback — header/sidebar survive)
 *   <ErrorBoundary scope="page"><MyScreen /></ErrorBoundary>
 *
 * The `scope` prop controls how the fallback is styled:
 *   "app"  (default) — full-screen centered card
 *   "page"           — inline card that fills the content area
 */

import { Component } from 'react';
import type { ErrorInfo, ReactNode } from 'react';

interface Props {
  children:  ReactNode;
  scope?:    'app' | 'page';
  /** Optional override for the error heading */
  heading?:  string;
}

interface State {
  hasError:   boolean;
  errorMsg:   string;
  componentStack: string;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false, errorMsg: '', componentStack: '' };
  }

  static getDerivedStateFromError(error: unknown): State {
    const msg = error instanceof Error ? error.message : String(error);
    return { hasError: true, errorMsg: msg, componentStack: '' };
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    const msg = error instanceof Error ? error.message : String(error);
    // Log to console so it still appears in devtools / monitoring
    console.error('[ErrorBoundary] Uncaught error:', error, info);
    this.setState({
      errorMsg:       msg,
      componentStack: info.componentStack ?? '',
    });
  }

  handleReset = () => {
    this.setState({ hasError: false, errorMsg: '', componentStack: '' });
  };

  render() {
    if (!this.state.hasError) return this.props.children;

    const { scope = 'app', heading = 'Something went wrong' } = this.props;
    const isFullScreen = scope === 'app';

    const wrapStyle: React.CSSProperties = isFullScreen
      ? {
          position: 'fixed', inset: 0, zIndex: 9999,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          background: '#F3F4F6',
        }
      : {
          display: 'flex', alignItems: 'flex-start', justifyContent: 'center',
          padding: '48px 24px',
          minHeight: 240,
        };

    const cardStyle: React.CSSProperties = {
      background: '#FFFFFF',
      border: '1px solid #FCA5A5',
      borderRadius: 12,
      padding: '32px 36px',
      maxWidth: 520,
      width: '100%',
      boxShadow: '0 4px 24px rgba(0,0,0,0.09)',
      textAlign: 'center',
    };

    return (
      <div style={wrapStyle}>
        <div style={cardStyle}>
          {/* Icon */}
          <div style={{ fontSize: 40, marginBottom: 12, color: '#EF4444' }}>
            <i className="fa-solid fa-triangle-exclamation" />
          </div>

          {/* Heading */}
          <div style={{ fontWeight: 700, fontSize: 18, color: '#111827', marginBottom: 8 }}>
            {heading}
          </div>

          {/* Message */}
          <div style={{ fontSize: 13, color: '#6B7280', marginBottom: 20, lineHeight: 1.5 }}>
            An unexpected error occurred in this section. You can try refreshing
            the page, or use the button below to attempt recovery without a full reload.
          </div>

          {/* Error detail — collapsed by default */}
          {this.state.errorMsg && (
            <details style={{ textAlign: 'left', marginBottom: 20 }}>
              <summary style={{
                cursor: 'pointer', fontSize: 12, color: '#9CA3AF',
                userSelect: 'none', marginBottom: 6,
              }}>
                Error details
              </summary>
              <pre style={{
                background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 6,
                padding: '10px 12px', fontSize: 11, color: '#B91C1C',
                overflowX: 'auto', whiteSpace: 'pre-wrap', wordBreak: 'break-all',
                maxHeight: 160, overflowY: 'auto',
              }}>
                {this.state.errorMsg}
                {this.state.componentStack ? `\n\n${this.state.componentStack}` : ''}
              </pre>
            </details>
          )}

          {/* Actions */}
          <div style={{ display: 'flex', gap: 10, justifyContent: 'center' }}>
            <button
              type="button"
              onClick={this.handleReset}
              style={{
                padding: '8px 20px', borderRadius: 7, border: '1.5px solid #D1D5DB',
                background: '#fff', color: '#374151', fontSize: 13, fontWeight: 600,
                cursor: 'pointer',
              }}
            >
              <i className="fa-solid fa-rotate-left" style={{ marginRight: 6 }} />
              Try again
            </button>
            <button
              type="button"
              onClick={() => window.location.reload()}
              style={{
                padding: '8px 20px', borderRadius: 7, border: 'none',
                background: '#2563EB', color: '#fff', fontSize: 13, fontWeight: 600,
                cursor: 'pointer',
              }}
            >
              <i className="fa-solid fa-arrows-rotate" style={{ marginRight: 6 }} />
              Reload page
            </button>
          </div>
        </div>
      </div>
    );
  }
}

export default ErrorBoundary;
