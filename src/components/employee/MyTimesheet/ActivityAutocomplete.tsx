/**
 * ActivityAutocomplete — smart typeahead for timesheet activity entries.
 *
 * • Loads employee activity history once from the parent.
 * • All filtering is client-side — no DB calls on keystroke.
 * • Sections: ⭐ Favourites → 🕒 Recent (last 10) → 🔍 Matching
 * • Star toggle fires onFavoriteToggle immediately (parent persists).
 * • Keyboard: ↑ ↓ Enter select, Esc close, Tab moves on.
 * • Free-text accepted — dropdown augments, doesn't restrict.
 */

import { useState, useRef, useEffect, useCallback } from 'react';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ActivityHistoryItem {
  id:            string;
  activity_name: string;
  usage_count:   number;
  last_used_at:  string;
  is_favorite:   boolean;
}

interface Props {
  value:             string;
  onChange:          (val: string) => void;
  onFavoriteToggle:  (name: string, currentIsFav: boolean) => Promise<{ ok: boolean; message?: string }>;
  history:           ActivityHistoryItem[];
  placeholder?:      string;
  inputStyle?:       React.CSSProperties;
  disabled?:         boolean;
}

// ─── Scoring / sorting ────────────────────────────────────────────────────────

function scoreItem(item: ActivityHistoryItem, q: string): number | null {
  const name = item.activity_name.toLowerCase();
  const search = q.toLowerCase().trim();
  if (!search) return 0; // show all when empty

  if (name === search)          return 100;
  if (name.startsWith(search))  return 80;
  if (name.includes(search))    return 60;
  return null; // no match
}

type Section = 'fav' | 'recent' | 'match';
interface SuggestionItem { item: ActivityHistoryItem; section: Section }

function buildSuggestions(history: ActivityHistoryItem[], q: string): SuggestionItem[] {
  const search = q.trim().toLowerCase();
  const now = Date.now();

  // Recency sort index (last 10 by last_used_at)
  const recentIds = new Set(
    [...history]
      .sort((a, b) => new Date(b.last_used_at).getTime() - new Date(a.last_used_at).getTime())
      .slice(0, 10)
      .map(i => i.id)
  );

  const favs: SuggestionItem[]   = [];
  const recents: SuggestionItem[] = [];
  const matches: SuggestionItem[] = [];

  for (const item of history) {
    const score = scoreItem(item, search);
    if (score === null) continue;

    if (item.is_favorite) {
      favs.push({ item, section: 'fav' });
    } else if (!search && recentIds.has(item.id)) {
      recents.push({ item, section: 'recent' });
    } else if (search) {
      matches.push({ item, section: 'match' });
    }
  }

  // Sort each bucket
  const sortFav = (a: SuggestionItem, b: SuggestionItem) => {
    const sa = scoreItem(a.item, search) ?? 0;
    const sb = scoreItem(b.item, search) ?? 0;
    if (sb !== sa) return sb - sa;
    if (b.item.usage_count !== a.item.usage_count) return b.item.usage_count - a.item.usage_count;
    return a.item.activity_name.localeCompare(b.item.activity_name);
  };

  favs.sort(sortFav);

  recents.sort((a, b) =>
    new Date(b.item.last_used_at).getTime() - new Date(a.item.last_used_at).getTime()
  );

  matches.sort((a, b) => {
    const sa = scoreItem(a.item, search) ?? 0;
    const sb = scoreItem(b.item, search) ?? 0;
    if (sb !== sa) return sb - sa;
    if (b.item.usage_count !== a.item.usage_count) return b.item.usage_count - a.item.usage_count;
    const ta = new Date(a.item.last_used_at).getTime();
    const tb = new Date(b.item.last_used_at).getTime();
    if (tb !== ta) return tb - ta;
    return a.item.activity_name.localeCompare(b.item.activity_name);
  });

  return [...favs, ...recents.slice(0, 10), ...matches];
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const dropdownSt: React.CSSProperties = {
  position: 'absolute', zIndex: 1000, left: 0, right: 0, top: 'calc(100% + 3px)',
  background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
  boxShadow: '0 8px 24px rgba(0,0,0,0.12)', overflow: 'hidden',
  maxHeight: 280, overflowY: 'auto',
};

const sectionHeadSt: React.CSSProperties = {
  padding: '6px 12px 3px',
  fontSize: 10, fontWeight: 700, color: '#9CA3AF',
  textTransform: 'uppercase', letterSpacing: '0.06em',
  background: '#FAFAFA', borderBottom: '1px solid #F3F4F6',
  userSelect: 'none',
};

const dividerSt: React.CSSProperties = {
  borderTop: '1px solid #F3F4F6', margin: 0,
};

const emptyRowSt: React.CSSProperties = {
  padding: '14px 12px', fontSize: 12, color: '#9CA3AF', textAlign: 'center',
};

// ─── Component ────────────────────────────────────────────────────────────────

export default function ActivityAutocomplete({
  value, onChange, onFavoriteToggle, history, placeholder, inputStyle, disabled,
}: Props) {
  const [open,      setOpen]      = useState(false);
  const [cursor,    setCursor]    = useState(-1);
  const [favErr,    setFavErr]    = useState('');
  const wrapRef   = useRef<HTMLDivElement>(null);
  const inputRef  = useRef<HTMLInputElement>(null);
  const listRef   = useRef<HTMLDivElement>(null);

  const suggestions = buildSuggestions(history, value);
  const flatItems   = suggestions; // flat list for keyboard nav

  // Close on outside click
  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        setOpen(false);
        setCursor(-1);
      }
    }
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, []);

  // Scroll active item into view
  useEffect(() => {
    if (cursor < 0 || !listRef.current) return;
    const el = listRef.current.querySelectorAll<HTMLElement>('[data-item]')[cursor];
    el?.scrollIntoView({ block: 'nearest' });
  }, [cursor]);

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (!open) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { setOpen(true); return; }
      return;
    }
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setCursor(c => Math.min(c + 1, flatItems.length - 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setCursor(c => Math.max(c - 1, 0));
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (cursor >= 0 && flatItems[cursor]) {
        select(flatItems[cursor].item.activity_name);
      }
    } else if (e.key === 'Escape') {
      setOpen(false); setCursor(-1);
    } else if (e.key === 'Tab') {
      setOpen(false); setCursor(-1);
    }
  }

  function select(name: string) {
    onChange(name);
    setOpen(false);
    setCursor(-1);
  }

  async function handleStarClick(e: React.MouseEvent, item: ActivityHistoryItem) {
    e.stopPropagation();
    setFavErr('');
    const res = await onFavoriteToggle(item.activity_name, item.is_favorite);
    if (!res.ok && res.message) setFavErr(res.message);
  }

  // Build section-aware render list
  let lastSection: Section | null = null;
  const rows: Array<{ type: 'head'; label: string } | { type: 'item'; si: SuggestionItem; idx: number }> = [];
  let itemIdx = 0;

  for (const si of suggestions) {
    if (si.section !== lastSection) {
      lastSection = si.section;
      const label =
        si.section === 'fav'   ? '⭐ Favourites' :
        si.section === 'recent' ? '🕒 Recent'     : '🔍 Matching';
      rows.push({ type: 'head', label });
    }
    rows.push({ type: 'item', si, idx: itemIdx++ });
  }

  const showEmpty = open && suggestions.length === 0;

  return (
    <div ref={wrapRef} style={{ position: 'relative' }}>
      <input
        ref={inputRef}
        type="text"
        value={value}
        placeholder={placeholder ?? 'Type or search activity…'}
        disabled={disabled}
        autoComplete="off"
        onChange={e => { onChange(e.target.value); setOpen(true); setCursor(-1); setFavErr(''); }}
        onFocus={() => setOpen(true)}
        onKeyDown={handleKeyDown}
        style={inputStyle}
      />

      {open && (
        <div style={dropdownSt} ref={listRef} onMouseDown={e => e.preventDefault()}>
          {showEmpty ? (
            <div style={emptyRowSt}>
              {value.trim() ? 'No matching activities.' : 'No activities yet.'}
            </div>
          ) : (
            rows.map((row, ri) => {
              if (row.type === 'head') {
                return (
                  <div key={`h-${ri}`}>
                    {ri > 0 && <hr style={dividerSt} />}
                    <div style={sectionHeadSt}>{row.label}</div>
                  </div>
                );
              }
              const { si, idx } = row;
              const active = idx === cursor;
              return (
                <div
                  key={si.item.id}
                  data-item
                  onClick={() => select(si.item.activity_name)}
                  style={{
                    display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                    padding: '8px 12px', cursor: 'pointer',
                    background: active ? '#EFF6FF' : '#fff',
                    transition: 'background 0.1s',
                  }}
                  onMouseEnter={() => setCursor(idx)}
                >
                  <span style={{ fontSize: 13, color: '#1F2937', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {si.item.activity_name}
                  </span>
                  <button
                    type="button"
                    onClick={e => handleStarClick(e, si.item)}
                    title={si.item.is_favorite ? 'Remove from favourites' : 'Add to favourites'}
                    style={{
                      flexShrink: 0, marginLeft: 8, background: 'none', border: 'none',
                      cursor: 'pointer', padding: '2px 4px', fontSize: 14, lineHeight: 1,
                      color: si.item.is_favorite ? '#F59E0B' : '#D1D5DB',
                      transition: 'color 0.15s',
                    }}
                  >
                    {si.item.is_favorite ? '★' : '☆'}
                  </button>
                </div>
              );
            })
          )}
        </div>
      )}

      {favErr && (
        <div style={{ fontSize: 11, color: '#DC2626', marginTop: 3, display: 'flex', alignItems: 'center', gap: 4 }}>
          <i className="fa-solid fa-circle-exclamation" /> {favErr}
        </div>
      )}
    </div>
  );
}
