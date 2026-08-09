/**
 * ActivityAutocomplete — smart typeahead for timesheet activity entries.
 *
 * Dropdown uses position:fixed + getBoundingClientRect() so it escapes
 * any overflow:hidden/auto ancestor (the side panel).
 *
 * Sections: ⭐ Favourites → 🕒 Recent (last 10) → 🔍 Matching
 * Star toggle fires onFavoriteToggle immediately (parent persists).
 * Keyboard: ↑ ↓ Enter select, Esc close, Tab moves on.
 * Free-text accepted — dropdown augments, does not restrict.
 */

import { useState, useRef, useEffect, useCallback } from 'react';
import { createPortal } from 'react-dom';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ActivityHistoryItem {
  id:            string;
  activity_name: string;
  usage_count:   number;
  last_used_at:  string;
  is_favorite:   boolean;
}

interface Props {
  value:            string;
  onChange:         (val: string) => void;
  onFavoriteToggle: (name: string, currentIsFav: boolean) => Promise<{ ok: boolean; message?: string }>;
  history:          ActivityHistoryItem[];
  placeholder?:     string;
  inputStyle?:      React.CSSProperties;
  disabled?:        boolean;
}

// ─── Scoring / sorting ────────────────────────────────────────────────────────

type Section = 'fav' | 'recent' | 'match';
interface SuggestionItem { item: ActivityHistoryItem; section: Section }

function scoreItem(item: ActivityHistoryItem, q: string): number | null {
  const name   = item.activity_name.toLowerCase();
  const search = q.toLowerCase().trim();
  if (!search)              return 0;
  if (name === search)      return 100;
  if (name.startsWith(search)) return 80;
  if (name.includes(search))   return 60;
  return null;
}

function buildSuggestions(history: ActivityHistoryItem[], q: string): SuggestionItem[] {
  const search = q.trim();

  const recentIds = new Set(
    [...history]
      .sort((a, b) => new Date(b.last_used_at).getTime() - new Date(a.last_used_at).getTime())
      .slice(0, 10)
      .map(i => i.id)
  );

  const favs: SuggestionItem[]    = [];
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

  const sortByScore = (a: SuggestionItem, b: SuggestionItem) => {
    const sa = scoreItem(a.item, search) ?? 0;
    const sb = scoreItem(b.item, search) ?? 0;
    if (sb !== sa)                              return sb - sa;
    if (b.item.usage_count !== a.item.usage_count) return b.item.usage_count - a.item.usage_count;
    const ta = new Date(a.item.last_used_at).getTime();
    const tb = new Date(b.item.last_used_at).getTime();
    if (tb !== ta) return tb - ta;
    return a.item.activity_name.localeCompare(b.item.activity_name);
  };

  favs.sort(sortByScore);
  recents.sort((a, b) => new Date(b.item.last_used_at).getTime() - new Date(a.item.last_used_at).getTime());
  matches.sort(sortByScore);

  return [...favs, ...recents.slice(0, 10), ...matches];
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function ActivityAutocomplete({
  value, onChange, onFavoriteToggle, history, placeholder, inputStyle, disabled,
}: Props) {
  const [open,   setOpen]   = useState(false);
  const [cursor, setCursor] = useState(-1);
  const [favErr, setFavErr] = useState('');
  const [rect,   setRect]   = useState<DOMRect | null>(null);

  const wrapRef  = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef  = useRef<HTMLDivElement>(null);

  const suggestions = buildSuggestions(history, value);

  // Recalculate dropdown position whenever it opens or window resizes
  const updateRect = useCallback(() => {
    if (inputRef.current) setRect(inputRef.current.getBoundingClientRect());
  }, []);

  useEffect(() => {
    if (!open) return;
    updateRect();
    window.addEventListener('resize',  updateRect);
    window.addEventListener('scroll',  updateRect, true);
    return () => {
      window.removeEventListener('resize', updateRect);
      window.removeEventListener('scroll', updateRect, true);
    };
  }, [open, updateRect]);

  // Close on outside click
  useEffect(() => {
    function onMouseDown(e: MouseEvent) {
      const target = e.target as Node;
      if (wrapRef.current?.contains(target)) return;
      if (listRef.current?.contains(target)) return;
      setOpen(false);
      setCursor(-1);
    }
    document.addEventListener('mousedown', onMouseDown);
    return () => document.removeEventListener('mousedown', onMouseDown);
  }, []);

  // Scroll active row into view
  useEffect(() => {
    if (cursor < 0 || !listRef.current) return;
    const el = listRef.current.querySelectorAll<HTMLElement>('[data-item]')[cursor];
    el?.scrollIntoView({ block: 'nearest' });
  }, [cursor]);

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (!open) { setOpen(true); updateRect(); return; }
      setCursor(c => Math.min(c + 1, suggestions.length - 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setCursor(c => Math.max(c - 1, 0));
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (open && cursor >= 0 && suggestions[cursor]) {
        select(suggestions[cursor].item.activity_name);
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
    e.preventDefault();
    setFavErr('');
    const res = await onFavoriteToggle(item.activity_name, item.is_favorite);
    if (!res.ok && res.message) setFavErr(res.message);
  }

  // Build section-aware rows
  let lastSection: Section | null = null;
  const rows: Array<
    | { type: 'head'; label: string }
    | { type: 'item'; si: SuggestionItem; idx: number }
  > = [];
  let itemIdx = 0;

  for (const si of suggestions) {
    if (si.section !== lastSection) {
      lastSection = si.section;
      rows.push({
        type: 'head',
        label: si.section === 'fav' ? '⭐ Favourites' : si.section === 'recent' ? '🕒 Recent' : '🔍 Matching',
      });
    }
    rows.push({ type: 'item', si, idx: itemIdx++ });
  }

  // Fixed dropdown position relative to the input
  const dropdownStyle: React.CSSProperties = rect ? {
    position:    'fixed',
    top:         rect.bottom + 3,
    left:        rect.left,
    width:       rect.width,
    zIndex:      9999,
    background:  '#fff',
    border:      '1px solid #E5E7EB',
    borderRadius: 10,
    boxShadow:   '0 8px 28px rgba(0,0,0,0.14)',
    maxHeight:   260,
    overflowY:   'auto',
  } : { display: 'none' };

  // Typing something with no match used to open a panel saying "No matching
  // activities." That reads as an error for what is a perfectly normal action:
  // the typed text IS the activity, so there is nothing to match and nothing to
  // confirm. The dropdown simply closes and the user keeps typing.
  //
  // The one empty state worth showing is a focused field with nothing typed and
  // no history yet — there, the panel explains what the field is for.
  const hasContent = suggestions.length > 0 || !value.trim();

  const dropdown = (open && hasContent) ? (
    <div style={dropdownStyle} ref={listRef} onMouseDown={e => e.preventDefault()}>
      {suggestions.length === 0 ? (
        <div style={{ padding: '14px 12px', fontSize: 12, color: '#9CA3AF', textAlign: 'center' }}>
          No activities yet — type to add your first.
        </div>
      ) : (
        rows.map((row, ri) => {
          if (row.type === 'head') {
            return (
              <div key={`h-${ri}`}>
                {ri > 0 && <div style={{ borderTop: '1px solid #F3F4F6', margin: 0 }} />}
                <div style={{
                  padding: '5px 12px 3px', fontSize: 10, fontWeight: 700,
                  color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: '0.06em',
                  background: '#FAFAFA', userSelect: 'none',
                }}>
                  {row.label}
                </div>
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
              onMouseEnter={() => setCursor(idx)}
              style={{
                display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                padding: '8px 12px', cursor: 'pointer',
                background: active ? '#EFF6FF' : '#fff',
                transition: 'background 0.1s',
              }}
            >
              <span style={{
                fontSize: 13, color: '#1F2937', flex: 1,
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              }}>
                {si.item.activity_name}
              </span>
              <button
                type="button"
                onMouseDown={e => handleStarClick(e, si.item)}
                title={si.item.is_favorite ? 'Remove from favourites' : 'Add to favourites'}
                style={{
                  flexShrink: 0, marginLeft: 8,
                  background: 'none', border: 'none', cursor: 'pointer',
                  padding: '2px 4px', fontSize: 15, lineHeight: 1,
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
  ) : null;

  return (
    <div ref={wrapRef} style={{ position: 'relative' }}>
      <input
        ref={inputRef}
        type="text"
        value={value}
        placeholder={placeholder ?? 'Type or search activity…'}
        disabled={disabled}
        autoComplete="off"
        onChange={e => {
          onChange(e.target.value);
          setOpen(true);
          setCursor(-1);
          setFavErr('');
          updateRect();
        }}
        onFocus={() => { setOpen(true); updateRect(); }}
        onKeyDown={handleKeyDown}
        style={inputStyle}
      />

      {dropdown && createPortal(dropdown, document.body)}

      {favErr && (
        <div style={{ fontSize: 11, color: '#DC2626', marginTop: 3, display: 'flex', alignItems: 'center', gap: 4 }}>
          <i className="fa-solid fa-circle-exclamation" /> {favErr}
        </div>
      )}
    </div>
  );
}
