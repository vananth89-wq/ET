/**
 * MSDropdown — searchable multi-select filter chip.
 *
 * Lifted out of AdminReports.tsx so every report screen uses the same control
 * instead of growing its own copy. Styling comes from the shared `er-ms-*`
 * classes in src/assets/style.css.
 */

import { useState, useRef, useEffect } from 'react';

// ─────────────────────────────────────────────────────────────────────────────
// Multi-select dropdown component
// ─────────────────────────────────────────────────────────────────────────────

export interface MSDropdownProps {
  id: string; icon: string; label: string;
  options: { value: string; label: string }[];
  selected: string[];
  onChange: (vals: string[]) => void;
}
export default function MSDropdown({ id, icon, label, options, selected, onChange }: MSDropdownProps) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState('');
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handler(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  const visible = options.filter(o => !search || o.label.toLowerCase().includes(search.toLowerCase()));
  const active = selected.length > 0;
  const btnLabel = active ? `${label} (${selected.length})` : label;

  return (
    <div className="er-chip er-chip-ms" ref={ref} style={{ position: 'relative' }}>
      <button
        className={`er-ms-btn${active ? ' er-ms-btn-active' : ''}`}
        onClick={() => setOpen(o => !o)}
        type="button"
      >
        <i className={`fa-solid ${icon} er-chip-icon`} />
        <span className="er-ms-lbl">{btnLabel}</span>
        <i className="fa-solid fa-chevron-down er-ms-caret" />
      </button>
      {open && (
        <div className="er-ms-panel" id={`er-ms-panel-${id}`}>
          <div className="er-ms-search">
            <input
              className="er-ms-search-inp"
              placeholder="Search…"
              value={search}
              onChange={e => setSearch(e.target.value)}
              autoFocus
            />
          </div>
          <ul className="er-ms-list">
            {visible.map(o => (
              <li key={o.value}>
                <label className="er-ms-item">
                  <input
                    type="checkbox"
                    checked={selected.includes(o.value)}
                    onChange={e => {
                      if (e.target.checked) onChange([...selected, o.value]);
                      else onChange(selected.filter(v => v !== o.value));
                    }}
                  />
                  <span>{o.label}</span>
                </label>
              </li>
            ))}
            {visible.length === 0 && (
              <li style={{ padding: '10px 14px', color: '#9aadc8', fontSize: 12 }}>No options</li>
            )}
          </ul>
        </div>
      )}
    </div>
  );
}
