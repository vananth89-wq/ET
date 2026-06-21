/**
 * ValidationResultsTable
 *
 * Renders per-row validation results in natural CSV order.
 * Shows natural-key columns (e.g. Employee Code, ID Type) inline so the user
 * can identify which record has an issue without opening the Excel report.
 */

interface RowResult {
  row_number: number;
  status:     'valid' | 'warning' | 'error';
  errors:     string[];
  warnings:   string[];
  data:       Record<string, string>;
}

interface Props {
  rows:       RowResult[];
  naturalKey: string[];
}

const STATUS_STYLE: Record<string, React.CSSProperties> = {
  valid:   { background: '#DCFCE7', color: '#166534' },
  warning: { background: '#FEF9C3', color: '#854D0E' },
  error:   { background: '#FEE2E2', color: '#991B1B' },
};

const STATUS_ICON: Record<string, string> = {
  valid:   'fa-check',
  warning: 'fa-triangle-exclamation',
  error:   'fa-circle-xmark',
};

const label = (col: string) => col.replace(/\s*\*$/, '').trim();

export default function ValidationResultsTable({ rows, naturalKey }: Props) {
  if (rows.length === 0) return null;

  const valid    = rows.filter(r => r.status === 'valid').length;
  const warnings = rows.filter(r => r.status === 'warning').length;
  const errors   = rows.filter(r => r.status === 'error').length;

  const keyColLabels = naturalKey.map(label);

  const errorRows     = rows.filter(r => r.status !== 'valid');
  const validRows     = rows.filter(r => r.status === 'valid');
  const shownValid    = validRows.slice(0, 50);
  const hiddenValid   = validRows.length - shownValid.length;

  // Natural order (row_number ascending)
  const allShown = [...errorRows, ...shownValid].sort((a, b) => a.row_number - b.row_number);

  return (
    <div style={{ marginTop: 16 }}>
      <div style={{ display: 'flex', gap: 10, marginBottom: 10, flexWrap: 'wrap', alignItems: 'center' }}>
        <Chip label={`${valid} valid`} bg="#DCFCE7" color="#166534" />
        {warnings > 0 && <Chip label={`${warnings} warnings`} bg="#FEF9C3" color="#854D0E" />}
        {errors   > 0 && <Chip label={`${errors} errors`}     bg="#FEE2E2" color="#991B1B" />}
        <span style={{ fontSize: 12, color: '#9CA3AF' }}>Key: {keyColLabels.join(' + ')}</span>
      </div>

      <div style={{ maxHeight: 360, overflowY: 'auto', border: '1px solid #E5E7EB', borderRadius: 8, fontSize: 12 }}>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ background: '#F9FAFB', borderBottom: '1px solid #E5E7EB' }}>
              <th style={thStyle}>Row</th>
              {keyColLabels.map(col => <th key={col} style={thStyle}>{col}</th>)}
              <th style={thStyle}>Status</th>
              <th style={{ ...thStyle, width: '45%' }}>Details</th>
            </tr>
          </thead>
          <tbody>
            {allShown.map(r => <ResultRow key={r.row_number} row={r} naturalKey={naturalKey} />)}
            {hiddenValid > 0 && (
              <tr>
                <td colSpan={2 + keyColLabels.length} style={{ padding: '7px 12px', color: '#9CA3AF', fontStyle: 'italic', fontSize: 11 }}>
                  … {hiddenValid} more valid rows not shown
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function ResultRow({ row, naturalKey }: { row: RowResult; naturalKey: string[] }) {
  const st   = STATUS_STYLE[row.status];
  const msgs = [...row.errors, ...row.warnings];
  const bg   = row.status === 'error' ? '#FFF7F7' : row.status === 'warning' ? '#FFFDF0' : 'transparent';

  return (
    <tr style={{ borderBottom: '0.5px solid #F3F4F6', background: bg }}>
      <td style={{ ...tdStyle, color: '#9CA3AF', fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>
        {row.row_number}
      </td>
      {naturalKey.map(col => {
        const key = Object.keys(row.data).find(k => k.toLowerCase().trim() === col.toLowerCase().trim());
        return (
          <td key={col} style={{ ...tdStyle, fontWeight: 500, color: '#111827', whiteSpace: 'nowrap' }}>
            {key ? row.data[key] : '—'}
          </td>
        );
      })}
      <td style={{ ...tdStyle, whiteSpace: 'nowrap' }}>
        <span style={{ ...st, display: 'inline-flex', alignItems: 'center', gap: 4, padding: '2px 8px', borderRadius: 12, fontWeight: 600, fontSize: 11 }}>
          <i className={`fa-solid ${STATUS_ICON[row.status]}`} style={{ fontSize: 10 }} />
          {row.status}
        </span>
      </td>
      <td style={{ ...tdStyle, color: '#374151' }}>
        {msgs.length === 0
          ? <span style={{ color: '#D1D5DB' }}>—</span>
          : msgs.map((m, i) => <div key={i} style={{ marginBottom: i < msgs.length - 1 ? 3 : 0 }}>{m}</div>)
        }
      </td>
    </tr>
  );
}

function Chip({ label, bg, color }: { label: string; bg: string; color: string }) {
  return (
    <span style={{ background: bg, color, padding: '3px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600 }}>
      {label}
    </span>
  );
}

const thStyle: React.CSSProperties = {
  padding: '7px 12px', textAlign: 'left',
  fontSize: 11, fontWeight: 600, color: '#6B7280', textTransform: 'uppercase', whiteSpace: 'nowrap',
};
const tdStyle: React.CSSProperties = { padding: '7px 12px', verticalAlign: 'top' };
