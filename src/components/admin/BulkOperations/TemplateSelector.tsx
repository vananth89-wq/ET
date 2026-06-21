/**
 * TemplateSelector
 *
 * Dropdown + context card showing the selected template's label, description,
 * icon, and key metadata.
 */

import type { BulkTemplateRow } from '../../../hooks/useBulkTemplates';

interface Props {
  templates:    BulkTemplateRow[];
  selectedCode: string;
  onSelect:     (code: string) => void;
}

export default function TemplateSelector({ templates, selectedCode, onSelect }: Props) {
  const selected = templates.find(t => t.template_code === selectedCode);

  return (
    <div style={{ marginBottom: 8 }}>
      {/* Dropdown */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
        <label style={{ fontSize: 13, fontWeight: 600, color: '#374151', minWidth: 110 }}>
          Template type
        </label>
        <select
          value={selectedCode}
          onChange={e => onSelect(e.target.value)}
          style={{
            padding: '7px 12px', border: '1px solid #D1D5DB', borderRadius: 6,
            fontSize: 13, color: '#111827', background: '#fff',
            minWidth: 260, cursor: 'pointer',
          }}
        >
          <option value="">— Select a template —</option>
          {templates.map(t => (
            <option key={t.template_code} value={t.template_code}>
              {t.display_label}
            </option>
          ))}
        </select>
      </div>

      {/* Context card */}
      {selected && (
        <div style={{
          display: 'flex', alignItems: 'flex-start', gap: 14,
          padding: '12px 16px', borderRadius: 8,
          background: '#F0F6FF', border: '1px solid #BFDBFE',
          marginBottom: 4,
        }}>
          <div style={{
            width: 38, height: 38, borderRadius: 8,
            background: '#DBEAFE', display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
          }}>
            <i className={`ti ${selected.icon}`} style={{ fontSize: 18, color: '#1D4ED8' }} />
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 600, fontSize: 14, color: '#1E3A5F', marginBottom: 3 }}>
              {selected.display_label}
            </div>
            <div style={{ fontSize: 12, color: '#4B5563', lineHeight: 1.5 }}>
              {selected.description}
            </div>
            <div style={{ display: 'flex', gap: 16, marginTop: 8, flexWrap: 'wrap' }}>
              <Meta label="Processor" value={selected.processor_rpc} mono />
              <Meta label="Import perm" value={selected.permission_import} mono />
              <Meta label="Export perm" value={selected.permission_export} mono />
              <Meta label="Workflow bypass" value="Yes (all bulk uploads)" />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function Meta({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div style={{ fontSize: 11, color: '#6B7280' }}>
      <span style={{ fontWeight: 600, color: '#374151' }}>{label}:</span>{' '}
      <span style={mono ? { fontFamily: 'monospace', color: '#1D4ED8' } : {}}>
        {value}
      </span>
    </div>
  );
}
