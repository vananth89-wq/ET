/**
 * ManagerAutocomplete — type-to-search picker for a project's reporting manager.
 *
 * WHY THIS IS A COMBOBOX AND NOT A FREE-TEXT FIELD
 *   projects.manager_id is a foreign key to employees, and it is the ONLY thing
 *   that can answer "is this caller the manager of this project" — the question
 *   a Project Manager scope predicate is built on. A typed name that matches
 *   nobody cannot answer it, so what gets stored is always an employee id. The
 *   typing is the interaction; the identity is the value.
 *
 *   A name that does not resolve is therefore not saved. On blur the field
 *   reverts to the last confirmed selection rather than clearing it — losing a
 *   manager because someone tabbed through the field is worse than making them
 *   pick again.
 *
 * Search runs through useEmployeeSearch (the search_employees RPC): debounced
 * 300ms, minimum 2 characters, and scoped by the caller's own search
 * permission, so this offers nobody a person they could not already find.
 */

import { useEffect, useRef, useState } from 'react';
import { useEmployeeSearch } from '../../hooks/useEmployeeSearch';

interface Props {
  /** Currently selected employee id, or null. */
  valueId: string | null;
  /** Display name for that id, resolved by the caller. */
  valueName: string | null;
  onChange: (id: string | null, name: string | null) => void;
  disabled?: boolean;
  placeholder?: string;
}

export default function ManagerAutocomplete({
  valueId, valueName, onChange, disabled, placeholder = 'Start typing a name…',
}: Props) {
  const [text,   setText]   = useState(valueName ?? '');
  const [open,   setOpen]   = useState(false);
  const [active, setActive] = useState(0);

  // `dirty` keeps the hook from searching for the name we just selected: without
  // it, picking someone immediately fires a query for their own name and
  // re-opens the list under the cursor.
  const [dirty, setDirty] = useState(false);

  const wrapRef = useRef<HTMLDivElement>(null);

  // Follow the caller when the selection changes underneath us — switching the
  // form from "add" to "edit" replaces valueName while this input is mounted.
  //
  // Adjusted during render rather than in an effect. An effect would paint the
  // stale name for one frame first, and React flags setState-in-effect for
  // exactly this reason: it is prop-derived state, not a subscription.
  const selKey = `${valueId ?? ''}|${valueName ?? ''}`;
  const [prevSel, setPrevSel] = useState(selKey);
  if (selKey !== prevSel) {
    setPrevSel(selKey);
    setText(valueName ?? '');
    setDirty(false);
    setOpen(false);
  }

  const { results, loading } = useEmployeeSearch(dirty ? text : '');

  // Clamped rather than reset in an effect: a new result set can be shorter
  // than the old highlight index, and clamping is the whole requirement.
  const activeIdx = results.length === 0 ? 0 : Math.min(active, results.length - 1);

  // Close on an outside click. Blur alone is not enough: mousedown on an option
  // fires blur first, which would close the list before the click lands.
  useEffect(() => {
    function onDocDown(e: MouseEvent) {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        setOpen(false);
        setText(valueName ?? '');
        setDirty(false);
      }
    }
    document.addEventListener('mousedown', onDocDown);
    return () => document.removeEventListener('mousedown', onDocDown);
  }, [valueName]);

  function pick(r: { employee_id: string; full_name: string; employee_code: string }) {
    const label = `${r.full_name} (${r.employee_code})`;
    onChange(r.employee_id, label);
    setText(label);
    setDirty(false);
    setOpen(false);
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Escape') {
      setOpen(false); setText(valueName ?? ''); setDirty(false); return;
    }
    if (!open || results.length === 0) return;
    if (e.key === 'ArrowDown') { e.preventDefault(); setActive((activeIdx + 1) % results.length); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((activeIdx - 1 + results.length) % results.length); }
    else if (e.key === 'Enter')  { e.preventDefault(); pick(results[activeIdx]); }
  }

  const showList = open && dirty && text.trim().length >= 2;

  return (
    <div ref={wrapRef} style={{ position: 'relative' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <input
          type="text"
          role="combobox"
          aria-expanded={showList}
          aria-autocomplete="list"
          autoComplete="off"
          disabled={disabled}
          placeholder={placeholder}
          value={text}
          onChange={e => {
            setText(e.target.value);
            setDirty(true);
            setOpen(true);
            // Emptying the field is an explicit "no manager"; anything else
            // waits for a real selection.
            if (e.target.value.trim() === '') onChange(null, null);
          }}
          onFocus={() => { if (dirty) setOpen(true); }}
          onKeyDown={onKeyDown}
          style={{ flex: 1, minWidth: 0 }}
        />
        {valueId && !dirty && (
          <button
            type="button"
            title="Clear"
            onClick={() => { onChange(null, null); setText(''); setDirty(false); setOpen(false); }}
            style={{ border: 0, background: 'transparent', cursor: 'pointer',
                     color: '#7A8CA6', padding: '4px 6px', font: 'inherit' }}
          >
            <i className="fa-solid fa-xmark" />
          </button>
        )}
      </div>

      {showList && (
        <ul
          role="listbox"
          style={{
            position: 'absolute', top: 'calc(100% + 4px)', left: 0, right: 0, zIndex: 40,
            margin: 0, padding: 4, listStyle: 'none', background: '#fff',
            border: '1px solid #E3E9F2', borderRadius: 8,
            boxShadow: '0 8px 24px rgba(24,52,91,0.14)', maxHeight: 260, overflowY: 'auto',
          }}
        >
          {loading && (
            <li style={{ padding: '8px 10px', fontSize: 13, color: '#8A97A8' }}>
              <i className="fa-solid fa-spinner fa-spin" /> Searching…
            </li>
          )}
          {!loading && results.length === 0 && (
            <li style={{ padding: '8px 10px', fontSize: 13, color: '#8A97A8' }}>
              No one matches “{text.trim()}”. A manager must be an employee.
            </li>
          )}
          {results.map((r, i) => (
            <li key={r.employee_id} role="option" aria-selected={i === activeIdx}>
              <button
                type="button"
                onMouseEnter={() => setActive(i)}
                onClick={() => pick(r)}
                style={{
                  width: '100%', textAlign: 'left', border: 0, cursor: 'pointer',
                  font: 'inherit', fontSize: 13, padding: '8px 10px', borderRadius: 6,
                  background: i === activeIdx ? '#EEF2F8' : 'transparent',
                }}
              >
                <span style={{ color: '#18345B', fontWeight: 600 }}>{r.full_name}</span>
                <span style={{ color: '#8A97A8' }}> · {r.employee_code}</span>
                {r.status !== 'Active' && (
                  <span style={{ color: '#B45309' }}> · {r.status}</span>
                )}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
