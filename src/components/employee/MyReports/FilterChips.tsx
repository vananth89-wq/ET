import type { ExpenseStatus } from '../../../types';

type Filter = 'all' | ExpenseStatus;

interface Props {
  active: Filter;
  counts: Record<Filter, number>;
  onChange: (f: Filter) => void;
}

const CHIPS: { key: Filter; label: string }[] = [
  { key: 'all',       label: 'All'       },
  { key: 'draft',     label: 'Draft'     },
  { key: 'submitted', label: 'Submitted' },
  { key: 'approved',  label: 'Approved'  },
  { key: 'rejected',  label: 'Rejected'  },
];

export default function FilterChips({ active, counts, onChange }: Props) {
  return (
    <div className="exp-filter-chips">
      {CHIPS.map(c => (
        <button
          key={c.key}
          className={`exp-filter-chip ${active === c.key ? 'exp-filter-chip--active' : ''}`}
          onClick={() => onChange(c.key)}
        >
          {c.label}
          <span className="exp-chip-count">{counts[c.key] ?? 0}</span>
        </button>
      ))}
    </div>
  );
}
