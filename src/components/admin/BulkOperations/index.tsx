/**
 * BulkOperations — /admin/import-export
 *
 * Generic registry-driven Import / Export screen.
 * All state derives from the selected template_code.
 *
 * Design spec: docs/bulk-operations-framework.md §6.2
 */

import { useState, useCallback }         from 'react';
import { useBulkTemplates } from '../../../hooks/useBulkTemplates';
import type { BulkTemplateRow } from '../../../hooks/useBulkTemplates';
import { useBulkUploadJob }              from '../../../hooks/useBulkUploadJob';
import { usePermissions }               from '../../../hooks/usePermissions';
import TemplateSelector                 from './TemplateSelector';
import ExportActions                    from './ExportActions';
import ImportFlow                       from './ImportFlow';
import RecentUploadsPanel               from './RecentUploadsPanel';

// ─── Persistent toggle state stored in sessionStorage per template ─────────────

function useToggle(key: string, defaultVal = false) {
  const [val, setVal] = useState<boolean>(() => {
    try { return JSON.parse(sessionStorage.getItem(key) ?? String(defaultVal)); }
    catch { return defaultVal; }
  });
  const set = useCallback((v: boolean) => {
    setVal(v);
    try { sessionStorage.setItem(key, String(v)); } catch {}
  }, [key]);
  return [val, set] as const;
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function BulkOperations() {
  const { templates, loading: tplLoading, error: tplError } = useBulkTemplates();
  const { can } = usePermissions();

  const [selectedCode, setSelectedCode] = useState<string>('');
  const [includeInactive,    setIncludeInactive]    = useToggle('bulk_include_inactive', false);
  const [includeSystemMeta,  setIncludeSystemMeta]  = useToggle('bulk_include_sys_meta', false);
  const [activeJobId,        setActiveJobId]         = useState<string | null>(null);
  const [refreshUploadsKey,  setRefreshUploadsKey]   = useState(0);

  const { job: activeJob, refresh: refreshJob } = useBulkUploadJob(activeJobId);

  const selectedTemplate: BulkTemplateRow | undefined =
    templates.find(t => t.template_code === selectedCode);

  const canImport = selectedTemplate ? can(selectedTemplate.permission_import) : false;
  const canExport = selectedTemplate ? can(selectedTemplate.permission_export) : false;

  function handleJobStarted(jobId: string) {
    setActiveJobId(jobId);
  }

  function handleJobSettled() {
    setRefreshUploadsKey(k => k + 1);
    refreshJob();
  }

  if (tplLoading) {
    return (
      <div className="ar-panel">
        <div style={{ padding: 40, textAlign: 'center', color: '#6B7280' }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 8 }} />
          Loading templates…
        </div>
      </div>
    );
  }

  if (tplError) {
    return (
      <div className="ar-panel">
        <div style={{ color: '#DC2626', fontSize: 13 }}>Failed to load templates: {tplError}</div>
      </div>
    );
  }

  if (templates.length === 0) {
    return (
      <div className="ar-panel">
        <h2 className="page-title">Import / Export</h2>
        <div style={{ padding: 32, textAlign: 'center', color: '#6B7280', fontSize: 14 }}>
          You don't have any Import or Export permissions yet.
          Ask your administrator to grant access via the Permission Matrix.
        </div>
      </div>
    );
  }

  return (
    <div className="ar-panel">
      <h2 className="page-title">Import / Export</h2>

      {/* ── Template selector + context card ─────────────────────────────── */}
      <TemplateSelector
        templates={templates}
        selectedCode={selectedCode}
        onSelect={code => { setSelectedCode(code); setActiveJobId(null); }}
      />

      {selectedTemplate && (
        <>
          {/* ── Persistent toggles ──────────────────────────────────────── */}
          <div style={{ display: 'flex', gap: 24, margin: '16px 0', flexWrap: 'wrap' }}>
            <label style={toggleLabelStyle}>
              <input
                type="checkbox"
                checked={includeInactive}
                onChange={e => setIncludeInactive(e.target.checked)}
                style={{ accentColor: '#1D4ED8', marginRight: 6 }}
              />
              Include inactive records
            </label>
            <label style={toggleLabelStyle}>
              <input
                type="checkbox"
                checked={includeSystemMeta}
                onChange={e => setIncludeSystemMeta(e.target.checked)}
                style={{ accentColor: '#1D4ED8', marginRight: 6 }}
              />
              Include system metadata
              <span style={{ fontSize: 11, color: '#9CA3AF', marginLeft: 6 }}>
                (not round-trip safe)
              </span>
              <span
                title="Adds id, timestamps and audit fields to the export. These are for reference only — the importer silently ignores them. Never included in the Download Template."
                style={{ marginLeft: 5, cursor: 'help', color: '#9CA3AF', lineHeight: 1 }}
              >
                <i className="fa-solid fa-circle-info" style={{ fontSize: 12 }} />
              </span>
            </label>
          </div>

          {/* ── Export + template download ───────────────────────────────── */}
          {canExport && (
            <ExportActions
              key={`${selectedCode}-export`}
              templateCode={selectedCode}
              templateLabel={selectedTemplate.display_label}
              includeInactive={includeInactive}
              includeSystemMeta={includeSystemMeta}
              hasHistory={!!selectedTemplate.schema_definition}
            />
          )}

          {/* ── Import flow ──────────────────────────────────────────────── */}
          {canImport && (
            <ImportFlow
              key={`${selectedCode}-import`}
              template={selectedTemplate}
              activeJob={activeJob}
              onJobStarted={handleJobStarted}
              onJobSettled={handleJobSettled}
            />
          )}

          {/* ── Recent uploads ───────────────────────────────────────────── */}
          <RecentUploadsPanel
            key={`${selectedCode}-uploads`}
            templateCode={selectedCode}
            activeJobId={activeJobId}
            refreshKey={refreshUploadsKey}
            onSelectJob={setActiveJobId}
          />
        </>
      )}
    </div>
  );
}

const toggleLabelStyle: React.CSSProperties = {
  display: 'flex', alignItems: 'center',
  fontSize: 13, color: '#374151', cursor: 'pointer',
  userSelect: 'none',
};
