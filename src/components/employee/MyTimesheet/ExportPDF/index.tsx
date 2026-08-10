import { useState } from 'react';
import type { TimesheetExportData } from './types';

type ExportState = 'idle' | 'generating' | 'done';

/**
 * Export the month as a PDF.
 *
 * Two deliberate departures from the original brief, both forced by how this
 * codebase actually works:
 *
 *  1. `getData` is an async builder rather than a `timesheetData` prop. Two of
 *     the fields the report needs — the holiday calendar's NAME and the
 *     manager's name — are not loaded by the timesheet page today. Fetching them
 *     on click keeps a rarely-used export from adding two queries to every page
 *     load, and keeps the failure inside the export flow rather than breaking
 *     the calendar.
 *
 *  2. `onToast` is a prop. There is no importable toast module in this project;
 *     `pushToast` is a function defined inside MyTimesheet, so the parent hands
 *     it down.
 *
 * @react-pdf/renderer is imported inside the handler. It is a large dependency
 * and nobody should pay for it on first paint of the calendar.
 */
export function ExportPDFButton({
  getData,
  onToast,
  disabled,
}: {
  getData: () => Promise<TimesheetExportData>;
  onToast: (msg: string, kind?: 'ok' | 'bad') => void;
  disabled?: boolean;
}) {
  const [state, setState] = useState<ExportState>('idle');

  async function handleExport() {
    if (state === 'generating') return;
    setState('generating');
    let url: string | null = null;
    try {
      const data = await getData();

      const [{ pdf }, { TimesheetPDF }] = await Promise.all([
        import('@react-pdf/renderer'),
        import('./TimesheetPDF'),
      ]);

      const blob = await pdf(<TimesheetPDF data={data} />).toBlob();

      const safeName = data.employeeName.replace(/[^A-Za-z0-9]/g, '');
      const filename = `Timesheet_${data.monthSlug}_${safeName}.pdf`;

      url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      a.remove();

      const kb = blob.size / 1024;
      const size = kb >= 1024 ? `${(kb / 1024).toFixed(1)} MB` : `${Math.round(kb)} KB`;
      onToast(`${filename} downloaded · 4 pages · ${size}`, 'ok');

      setState('done');
      window.setTimeout(() => setState('idle'), 3000);
    } catch (err) {
      console.error('PDF export failed', err);
      onToast(err instanceof Error ? `Export failed — ${err.message}` : 'Export failed — please try again', 'bad');
      setState('idle');
    } finally {
      // Revoking immediately after click() can race the download in Safari.
      if (url) window.setTimeout(() => URL.revokeObjectURL(url as string), 10_000);
    }
  }

  const look = state === 'done'
    ? { bg: '#059669', fg: '#fff',     border: '#059669' }
    : state === 'generating'
    ? { bg: '#F3F4F6', fg: '#6B7280', border: '#E5E7EB' }
    : { bg: '#fff',    fg: '#374151', border: '#D1D5DB' };

  const label = state === 'done' ? 'Exported' : state === 'generating' ? 'Generating…' : 'Export PDF';
  const icon  = state === 'done' ? 'fa-solid fa-check'
              : state === 'generating' ? 'fa-solid fa-spinner fa-spin'
              : 'fa-solid fa-file-pdf';

  return (
    <button
      type="button"
      onClick={handleExport}
      disabled={disabled || state === 'generating'}
      aria-live="polite"
      title={disabled ? 'Nothing to export for this month' : 'Download this month as a PDF report'}
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 7,
        padding: '8px 14px', borderRadius: 8,
        border: `1px solid ${look.border}`, background: look.bg, color: look.fg,
        fontSize: 13, fontWeight: 600,
        cursor: disabled ? 'not-allowed' : state === 'generating' ? 'wait' : 'pointer',
        opacity: disabled ? 0.55 : 1,
        transition: 'background 0.15s, color 0.15s, border-color 0.15s',
      }}
    >
      <i className={icon} />
      {label}
    </button>
  );
}
