import { useEffect, useRef, useState } from 'react';
import type { TimesheetExportData } from './types';
import type { TimesheetReportVariant } from './TimesheetPDF';

type ExportState = 'idle' | 'generating' | 'done';

/**
 * Export the month as a PDF, in one of two shapes.
 *
 *   Summary — three pages. The middle one is a day × project matrix: the whole
 *             month at a glance, no activities, no notes.
 *   Detail  — the original. Every entry with its activities and notes, which
 *             runs to five or six pages for a busy month.
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

const OPTIONS: Array<{
  variant: TimesheetReportVariant; label: string; note: string; icon: string;
}> = [
  { variant: 'summary', label: 'Summary report',
    note: 'One page per month — day × project', icon: 'fa-solid fa-table-cells' },
  { variant: 'detail',  label: 'Detail report',
    note: 'Every entry, with activities and notes', icon: 'fa-solid fa-list-ul' },
];

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
  const [open, setOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement | null>(null);

  // Close on an outside click or Escape. Registered only while the menu is
  // open, so the page carries no listeners for a control nobody has touched.
  useEffect(() => {
    if (!open) return;
    function onDown(ev: MouseEvent) {
      if (wrapRef.current && !wrapRef.current.contains(ev.target as Node)) setOpen(false);
    }
    function onKey(ev: KeyboardEvent) { if (ev.key === 'Escape') setOpen(false); }
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  async function handleExport(variant: TimesheetReportVariant) {
    if (state === 'generating') return;
    setOpen(false);
    setState('generating');
    let url: string | null = null;
    try {
      const data = await getData();

      const [{ pdf }, { TimesheetPDF }] = await Promise.all([
        import('@react-pdf/renderer'),
        import('./TimesheetPDF'),
      ]);

      const blob = await pdf(<TimesheetPDF data={data} variant={variant} />).toBlob();

      const safeName = data.employeeName.replace(/[^A-Za-z0-9]/g, '');
      const kind = variant === 'summary' ? 'Summary' : 'Detail';
      const filename = `Timesheet_${kind}_${data.monthSlug}_${safeName}.pdf`;

      url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      a.remove();

      const kb = blob.size / 1024;
      const size = kb >= 1024 ? `${(kb / 1024).toFixed(1)} MB` : `${Math.round(kb)} KB`;
      // The page count used to be hard-coded at four and was wrong for every
      // month that paginated. The blob does not carry one, so it is gone rather
      // than guessed at.
      onToast(`${filename} downloaded · ${size}`, 'ok');

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

  const blocked = disabled || state === 'generating';

  return (
    <div ref={wrapRef} style={{ position: 'relative', display: 'inline-block' }}>
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        disabled={blocked}
        aria-haspopup="menu"
        aria-expanded={open}
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
        {state === 'idle' && (
          <i className="fa-solid fa-chevron-down" style={{ fontSize: 9, opacity: 0.6 }} />
        )}
      </button>

      {open && !blocked && (
        <div
          role="menu"
          style={{
            position: 'absolute', top: 'calc(100% + 6px)', right: 0, zIndex: 40,
            minWidth: 236, background: '#fff', borderRadius: 10,
            border: '1px solid #E5E7EB', boxShadow: '0 8px 24px rgba(16,24,40,0.12)',
            padding: 5,
          }}
        >
          {OPTIONS.map(o => (
            <button
              key={o.variant}
              role="menuitem"
              type="button"
              onClick={() => handleExport(o.variant)}
              style={{
                display: 'flex', alignItems: 'flex-start', gap: 9, width: '100%',
                padding: '8px 10px', borderRadius: 7, border: 0, background: 'transparent',
                textAlign: 'left', cursor: 'pointer',
              }}
              onMouseEnter={e => { e.currentTarget.style.background = '#F3F6FC'; }}
              onMouseLeave={e => { e.currentTarget.style.background = 'transparent'; }}
            >
              <i className={o.icon} style={{ fontSize: 12, color: '#2563EB', marginTop: 2 }} />
              <span>
                <span style={{ display: 'block', fontSize: 13, fontWeight: 600, color: '#1F2937' }}>
                  {o.label}
                </span>
                <span style={{ display: 'block', fontSize: 11, color: '#6B7280', marginTop: 1 }}>
                  {o.note}
                </span>
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
