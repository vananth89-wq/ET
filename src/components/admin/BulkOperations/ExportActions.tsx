/**
 * ExportActions
 *
 * Export current, Export history, and Download template buttons.
 * Each triggers the corresponding Edge Function and streams the download.
 */

import { useState } from 'react';
import { supabase } from '../../../lib/supabase';

interface Props {
  templateCode:    string;
  templateLabel:   string;
  includeInactive: boolean;
  includeSystemMeta: boolean;
  hasHistory:      boolean;
}

type DownloadState = 'idle' | 'loading' | 'done' | 'error';

export default function ExportActions({
  templateCode,
  templateLabel,
  includeInactive,
  includeSystemMeta,
  hasHistory,
}: Props) {
  const [exportState,   setExportState]   = useState<DownloadState>('idle');
  const [historyState,  setHistoryState]  = useState<DownloadState>('idle');
  const [templateState, setTemplateState] = useState<DownloadState>('idle');
  const [exportCount,   setExportCount]   = useState<number | null>(null);
  const [historyCount,  setHistoryCount]  = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Count data rows in a CSV blob:
  // - Skip lines starting with '#' (history comment)
  // - First non-comment line is the header — subtract 1
  // - Empty trailing lines don't count
  async function countCsvRows(blob: Blob): Promise<number> {
    const text = await blob.text();
    const lines = text.split('\n').map(l => l.trim()).filter(Boolean);
    const dataLines = lines.filter(l => !l.startsWith('#'));
    return Math.max(0, dataLines.length - 1); // minus header row
  }

  async function callEdgeFunction(
    fn: string,
    body: Record<string, unknown>,
    filename: string,
    setState: (s: DownloadState) => void,
    setCount?: (n: number) => void,
  ) {
    setError(null);
    setState('loading');

    try {
      const { data: { session } } = await supabase.auth.getSession();
      const token = session?.access_token;

      const url = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/${fn}`;
      const resp = await fetch(url, {
        method:  'POST',
        headers: {
          'Content-Type':  'application/json',
          'Authorization': `Bearer ${token}`,
          'apikey':        import.meta.env.VITE_SUPABASE_ANON_KEY,
        },
        body: JSON.stringify(body),
      });

      if (!resp.ok) {
        const txt = await resp.text();
        throw new Error(txt || `HTTP ${resp.status}`);
      }

      const blob = await resp.blob();

      // Count rows before triggering download (reads blob once)
      if (setCount) {
        const n = await countCsvRows(blob);
        setCount(n);
      }

      const href = URL.createObjectURL(blob);
      const a    = document.createElement('a');
      a.href = href; a.download = filename;
      document.body.appendChild(a); a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(href);

      setState('done');
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : 'Download failed';
      setError(`Export failed: ${msg}`);
      setState('error');
    }
  }

  const today = new Date().toISOString().slice(0, 10);

  function exportCurrent() {
    setExportCount(null);
    callEdgeFunction(
      'bulk-export-generator',
      { template_code: templateCode, mode: 'current', include_inactive: includeInactive, include_system_metadata: includeSystemMeta },
      `${templateCode}_export_current_${today}.csv`,
      setExportState,
      setExportCount,
    );
  }

  function exportHistory() {
    setHistoryCount(null);
    callEdgeFunction(
      'bulk-export-generator',
      { template_code: templateCode, mode: 'history', include_inactive: includeInactive, include_system_metadata: includeSystemMeta },
      `${templateCode}_export_history_${today}.csv`,
      setHistoryState,
      setHistoryCount,
    );
  }

  function downloadTemplate() {
    callEdgeFunction(
      'bulk-template-generator',
      { template_code: templateCode },
      `${templateCode}_template.zip`,
      setTemplateState,
    );
  }

  return (
    <div style={{
      padding: '14px 16px', borderRadius: 8,
      border: '1px solid #E5E7EB', background: '#FAFAFA',
      marginBottom: 16,
    }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', marginBottom: 10, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
        Export &amp; Template
      </div>

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
        <ActionBtn
          label="Export current"
          icon="fa-download"
          state={exportState}
          onClick={exportCurrent}
          title={`Download current ${templateLabel} records as CSV`}
        />
        {exportState === 'done' && exportCount !== null && (
          <span style={{ fontSize: 12, color: '#059669', display: 'flex', alignItems: 'center', gap: 4 }}>
            <i className="fa-solid fa-circle-check" style={{ fontSize: 11 }} />
            Exported {exportCount.toLocaleString()} row{exportCount !== 1 ? 's' : ''}
          </span>
        )}

        {hasHistory && (
          <>
            <ActionBtn
              label="Export history"
              icon="fa-clock-rotate-left"
              state={historyState}
              onClick={exportHistory}
              title="Download full timeline (not round-trip safe)"
              secondary
            />
            {historyState === 'done' && historyCount !== null && (
              <span style={{ fontSize: 12, color: '#059669', display: 'flex', alignItems: 'center', gap: 4 }}>
                <i className="fa-solid fa-circle-check" style={{ fontSize: 11 }} />
                Exported {historyCount.toLocaleString()} row{historyCount !== 1 ? 's' : ''}
              </span>
            )}
          </>
        )}

        <ActionBtn
          label="Download template"
          icon="fa-file-arrow-down"
          state={templateState}
          onClick={downloadTemplate}
          title="Download blank template + README.txt as .zip"
          secondary
        />
      </div>

      {error && (
        <div style={{ marginTop: 8, fontSize: 12, color: '#DC2626' }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 5 }} />
          {error}
        </div>
      )}
    </div>
  );
}

function ActionBtn({
  label, icon, state, onClick, title, secondary,
}: {
  label: string; icon: string; state: DownloadState;
  onClick: () => void; title: string; secondary?: boolean;
}) {
  const loading = state === 'loading';
  const base: React.CSSProperties = {
    display: 'inline-flex', alignItems: 'center', gap: 6,
    padding: '6px 14px', borderRadius: 6, fontSize: 13,
    cursor: loading ? 'default' : 'pointer',
    border: '1px solid',
    transition: 'opacity 0.15s',
    opacity: loading ? 0.7 : 1,
    fontWeight: 500,
  };
  const style: React.CSSProperties = secondary
    ? { ...base, background: '#fff', borderColor: '#D1D5DB', color: '#374151' }
    : { ...base, background: '#1D4ED8', borderColor: '#1D4ED8', color: '#fff' };

  const iconClass = loading ? 'fa-spinner fa-spin'
    : state === 'done' ? 'fa-circle-check'
    : icon;

  return (
    <button style={style} onClick={onClick} disabled={loading} title={title}>
      <i className={`fa-solid ${iconClass}`} style={{ fontSize: 12 }} />
      {label}
    </button>
  );
}
