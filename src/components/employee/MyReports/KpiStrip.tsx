import type { ExpenseReport } from '../../../types';
import { fmtAmount } from '../../../utils/currency';

interface Props { reports: ExpenseReport[]; }

export default function KpiStrip({ reports }: Props) {
  const total = reports.length;
  const draft     = reports.filter(r => r.status === 'draft').length;
  const submitted = reports.filter(r => r.status === 'submitted').length;
  const approved  = reports.filter(r => r.status === 'approved').length;
  const totalAmt  = reports.filter(r => r.status === 'approved').reduce((s, r) =>
    s + r.lineItems.reduce((a, li) => a + (li.convertedAmount || 0), 0), 0);

  const cards = [
    { icon: 'fa-file-lines',   label: 'Total Reports',    value: String(total),              color: '#1976D2' },
    { icon: 'fa-pencil',       label: 'Draft',            value: String(draft),              color: '#64748B' },
    { icon: 'fa-paper-plane',  label: 'Submitted',        value: String(submitted),          color: '#1976D2' },
    { icon: 'fa-circle-check', label: 'Approved',         value: String(approved),           color: '#2E7D32' },
    { icon: 'fa-coins',        label: 'Approved Amount',  value: fmtAmount(totalAmt, 'INR'), color: '#7B5EA7' },
  ];

  return (
    <div className="exp-kpi-strip">
      {cards.map(c => (
        <div className="exp-kpi-card" key={c.label}>
          <div className="exp-kpi-icon" style={{ background: `${c.color}18`, color: c.color }}>
            <i className={`fa-solid ${c.icon}`} />
          </div>
          <div className="exp-kpi-text">
            <div className="exp-kpi-value">{c.value}</div>
            <div className="exp-kpi-label">{c.label}</div>
          </div>
        </div>
      ))}
    </div>
  );
}
