/**
 * EmployeeSearchBox
 *
 * Header type-ahead search for employees.
 * - Desktop: 320px input between logo and notification bell.
 * - Mobile (≤768px): search icon only; click opens a full-screen modal overlay.
 * - ⌘K / Ctrl+K focuses the input from anywhere in the app.
 * - Esc closes the dropdown / overlay.
 * - Up/Down arrows move through results; Enter navigates to highlighted employee.
 * - 2-character minimum, 300ms debounce (via useEmployeeSearch).
 * - Recently Viewed shown when query is empty.
 * - Inactive employees only with employee_search.view_inactive.
 *
 * a11y (Phase 7):
 * - combobox pattern: role=combobox + aria-expanded + aria-controls + aria-activedescendant
 * - Each result row has a stable id so aria-activedescendant can reference it
 * - aria-live="polite" region announces result count to screen readers
 * - Mobile overlay: role=dialog + aria-modal + focus trap (Tab/Shift+Tab cycles within overlay)
 * - Esc restores focus to the trigger button on mobile
 */

import { useRef, useState, useEffect, useCallback, useId } from 'react';
import { useNavigate }    from 'react-router-dom';
import { usePermissions } from '../../hooks/usePermissions';
import { useEmployeeSearch, type EmployeeSearchResult } from '../../hooks/useEmployeeSearch';
import { useRecentlyViewed, type RecentlyViewedEntry }  from '../../hooks/useRecentlyViewed';
import SearchResultRow    from './SearchResultRow';
import RecentlyViewedList from './RecentlyViewedList';

export default function EmployeeSearchBox() {
  const { can }          = usePermissions();
  const navigate         = useNavigate();
  const listboxId        = useId();
  const liveRegionId     = useId();

  const canSearch       = can('employee_search.view');
  const canViewInactive = can('employee_search.view_inactive');

  const [query,        setQuery]        = useState('');
  const [open,         setOpen]         = useState(false);
  const [highlightIdx, setHighlightIdx] = useState(-1);
  const [isMobile,     setIsMobile]     = useState(() => window.innerWidth <= 768);
  const [overlayOpen,  setOverlayOpen]  = useState(false);
  const [announcement, setAnnouncement] = useState('');

  const inputRef        = useRef<HTMLInputElement>(null);
  const mobileInputRef  = useRef<HTMLInputElement>(null);
  const mobileTriggerRef = useRef<HTMLButtonElement>(null);
  const containerRef    = useRef<HTMLDivElement>(null);
  const overlayRef      = useRef<HTMLDivElement>(null);

  const { results, loading, error } = useEmployeeSearch(query, canViewInactive);
  const { entries: recentEntries, addEntry } = useRecentlyViewed();

  // Responsive breakpoint
  useEffect(() => {
    const handler = () => setIsMobile(window.innerWidth <= 768);
    window.addEventListener('resize', handler);
    return () => window.removeEventListener('resize', handler);
  }, []);

  // ⌘K / Ctrl+K global shortcut
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!canSearch) return;
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        if (isMobile) {
          setOverlayOpen(true);
        } else {
          inputRef.current?.focus();
          setOpen(true);
        }
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [canSearch, isMobile]);

  // Close desktop dropdown on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
        setHighlightIdx(-1);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  // Focus mobile input when overlay opens; restore focus on close
  useEffect(() => {
    if (overlayOpen) {
      setTimeout(() => mobileInputRef.current?.focus(), 50);
    }
  }, [overlayOpen]);

  // Focus trap for mobile overlay — Tab/Shift+Tab cycles within the overlay
  useEffect(() => {
    if (!overlayOpen) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key !== 'Tab' || !overlayRef.current) return;
      const focusable = overlayRef.current.querySelectorAll<HTMLElement>(
        'button, input, [tabindex]:not([tabindex="-1"])'
      );
      const first = focusable[0];
      const last  = focusable[focusable.length - 1];
      if (e.shiftKey) {
        if (document.activeElement === first) { e.preventDefault(); last.focus(); }
      } else {
        if (document.activeElement === last)  { e.preventDefault(); first.focus(); }
      }
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [overlayOpen]);

  // Screen-reader announcement when results load
  useEffect(() => {
    if (loading || query.trim().length < 2) { setAnnouncement(''); return; }
    if (error) { setAnnouncement('Search failed. Please retry.'); return; }
    if (results.length === 0) {
      setAnnouncement(`No employees match "${query.trim()}".`);
    } else {
      setAnnouncement(`${results.length} employee${results.length === 1 ? '' : 's'} found.`);
    }
  }, [results, loading, error, query]);

  // Reset highlight when items change
  useEffect(() => { setHighlightIdx(-1); }, [results, query]);

  const showRecent = query.trim().length < 2;
  const dropItems: Array<EmployeeSearchResult | RecentlyViewedEntry> =
    showRecent ? recentEntries : results;

  // Stable option ID for aria-activedescendant
  const optionId = (idx: number) => `${listboxId}-option-${idx}`;
  const activeDescendant = highlightIdx >= 0 ? optionId(highlightIdx) : undefined;

  const navigate_to = useCallback((employeeId: string, entry: EmployeeSearchResult | RecentlyViewedEntry) => {
    addEntry({
      employee_id:   entry.employee_id,
      employee_code: entry.employee_code,
      full_name:     entry.full_name,
      email:         'email' in entry ? entry.email : null,
    });
    setQuery('');
    setOpen(false);
    setOverlayOpen(false);
    navigate(`/profile/${employeeId}`);
  }, [addEntry, navigate]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (!open && !overlayOpen) return;
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        setHighlightIdx(i => Math.min(i + 1, dropItems.length - 1));
        break;
      case 'ArrowUp':
        e.preventDefault();
        setHighlightIdx(i => Math.max(i - 1, -1));
        break;
      case 'Enter':
        if (highlightIdx >= 0 && dropItems[highlightIdx]) {
          navigate_to(dropItems[highlightIdx].employee_id, dropItems[highlightIdx]);
        }
        break;
      case 'Escape':
        setOpen(false);
        if (overlayOpen) {
          setOverlayOpen(false);
          // Restore focus to the mobile trigger button
          setTimeout(() => mobileTriggerRef.current?.focus(), 50);
        }
        setHighlightIdx(-1);
        inputRef.current?.blur();
        break;
    }
  };

  if (!canSearch) return null;

  // ── Hidden aria-live region (always rendered, screen readers poll it) ─────
  const LiveRegion = (
    <div
      id={liveRegionId}
      role="status"
      aria-live="polite"
      aria-atomic="true"
      style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0,0,0,0)' }}
    >
      {announcement}
    </div>
  );

  // ── Mobile: search icon only ───────────────────────────────────────────────
  if (isMobile) {
    return (
      <>
        {LiveRegion}
        <button
          ref={mobileTriggerRef}
          aria-label="Search employees (⌘K)"
          aria-expanded={overlayOpen}
          aria-haspopup="dialog"
          onClick={() => setOverlayOpen(true)}
          style={{
            background: 'none', border: 'none', cursor: 'pointer',
            color: '#6B7280', fontSize: 18, padding: '4px 8px',
            display: 'flex', alignItems: 'center',
          }}
        >
          <i className="fa-solid fa-magnifying-glass" aria-hidden="true" />
        </button>

        {/* Full-screen overlay — role=dialog with focus trap */}
        {overlayOpen && (
          <div
            ref={overlayRef}
            role="dialog"
            aria-modal="true"
            aria-label="Search employees"
            style={{
              position: 'fixed', inset: 0, zIndex: 9999,
              background: '#fff', display: 'flex', flexDirection: 'column',
            }}
          >
            <div style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '12px 16px', borderBottom: '1px solid #E5E7EB',
            }}>
              <i className="fa-solid fa-magnifying-glass" style={{ color: '#9CA3AF' }} aria-hidden="true" />
              <input
                ref={mobileInputRef}
                role="combobox"
                aria-expanded={dropItems.length > 0}
                aria-controls={listboxId}
                aria-haspopup="listbox"
                aria-autocomplete="list"
                aria-activedescendant={activeDescendant}
                aria-label="Search employees"
                value={query}
                onChange={e => { setQuery(e.target.value); setOpen(true); }}
                onKeyDown={handleKeyDown}
                placeholder="Search employee…"
                style={{ flex: 1, border: 'none', outline: 'none', fontSize: 15, color: '#111827' }}
              />
              <button
                onClick={() => {
                  setOverlayOpen(false);
                  setQuery('');
                  setTimeout(() => mobileTriggerRef.current?.focus(), 50);
                }}
                aria-label="Close search"
                style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#6B7280', fontSize: 14 }}
              >
                Cancel
              </button>
            </div>
            <div
              id={listboxId}
              role="listbox"
              aria-label="Employee search results"
              style={{ flex: 1, overflowY: 'auto', padding: '8px 4px' }}
            >
              <DropdownContent
                showRecent={showRecent}
                recentEntries={recentEntries}
                results={results}
                loading={loading}
                error={error}
                query={query}
                highlightIdx={highlightIdx}
                optionId={optionId}
                onSelect={navigate_to}
                onHighlight={setHighlightIdx}
              />
            </div>
          </div>
        )}
      </>
    );
  }

  // ── Desktop: inline input — SF pill style ────────────────────────────────
  return (
    <>
      {LiveRegion}
      <div ref={containerRef} style={{ position: 'relative', width: 480, flex: '0 0 480px' }}>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          background: open ? '#ffffff' : '#F5F6F7',
          border: `1.5px solid ${open ? 'rgba(0,92,185,0.4)' : 'transparent'}`,
          borderRadius: 28,
          padding: '0 22px',
          height: 52,
          boxShadow: open ? '0 0 0 3px rgba(0,92,185,0.12)' : 'none',
          transition: 'all 0.2s ease',
        }}>
          <i className="fa-solid fa-magnifying-glass" style={{ color: open ? '#005CB9' : '#8A8A8A', fontSize: 18, flexShrink: 0, transition: 'color 0.2s ease' }} aria-hidden="true" />
          <input
            ref={inputRef}
            role="combobox"
            aria-expanded={open}
            aria-controls={listboxId}
            aria-haspopup="listbox"
            aria-autocomplete="list"
            aria-activedescendant={activeDescendant}
            aria-label="Search employees"
            value={query}
            onChange={e => { setQuery(e.target.value); setOpen(true); }}
            onFocus={() => setOpen(true)}
            onKeyDown={handleKeyDown}
            placeholder="Search employee…"
            style={{
              flex: 1, border: 'none', outline: 'none', background: 'transparent',
              fontSize: 15, color: '#2E2E2E',
            }}
          />
          {query && (
            <button
              onClick={() => { setQuery(''); inputRef.current?.focus(); }}
              aria-label="Clear search"
              style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 12, padding: 0 }}
            >
              <i className="fa-solid fa-xmark" aria-hidden="true" />
            </button>
          )}
          {!query && (
            <span
              aria-hidden="true"
              style={{
                fontSize: 10, color: '#C4C4C4', background: 'transparent',
                border: 'none', borderRadius: 4, padding: '1px 5px',
                whiteSpace: 'nowrap',
              }}
            >
              ⌘K
            </span>
          )}
        </div>

        {/* Dropdown */}
        {open && (
          <div
            id={listboxId}
            role="listbox"
            aria-label="Employee search results"
            style={{
              position: 'absolute', top: 'calc(100% + 4px)', left: 0, right: 0,
              background: '#fff', border: '1px solid #E5E7EB', borderRadius: 10,
              boxShadow: '0 8px 24px rgba(0,0,0,0.12)', zIndex: 1000,
              maxHeight: 360, overflowY: 'auto', padding: '6px 4px',
            }}
          >
            <DropdownContent
              showRecent={showRecent}
              recentEntries={recentEntries}
              results={results}
              loading={loading}
              error={error}
              query={query}
              highlightIdx={highlightIdx}
              optionId={optionId}
              onSelect={navigate_to}
              onHighlight={setHighlightIdx}
            />
          </div>
        )}
      </div>
    </>
  );
}

// ── Shared dropdown content ────────────────────────────────────────────────────

interface DropdownContentProps {
  showRecent:    boolean;
  recentEntries: RecentlyViewedEntry[];
  results:       EmployeeSearchResult[];
  loading:       boolean;
  error:         string | null;
  query:         string;
  highlightIdx:  number;
  optionId:      (idx: number) => string;
  onSelect:      (id: string, entry: EmployeeSearchResult | RecentlyViewedEntry) => void;
  onHighlight:   (idx: number) => void;
}

function DropdownContent({
  showRecent, recentEntries, results, loading, error, query,
  highlightIdx, optionId, onSelect, onHighlight,
}: DropdownContentProps) {
  if (showRecent) {
    return (
      <RecentlyViewedList
        entries={recentEntries}
        highlightIdx={highlightIdx}
        optionId={optionId}
        onSelect={e => onSelect(e.employee_id, e)}
        onHighlight={onHighlight}
      />
    );
  }

  if (loading) {
    return (
      <div role="status" aria-live="polite" style={{ padding: '16px 12px', display: 'flex', alignItems: 'center', gap: 8, color: '#9CA3AF', fontSize: 13 }}>
        <i className="fa-solid fa-spinner fa-spin" aria-hidden="true" /> Searching…
      </div>
    );
  }

  if (error) {
    return (
      <div role="alert" style={{ padding: '12px', color: '#EF4444', fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className="fa-solid fa-circle-exclamation" aria-hidden="true" /> {error}
      </div>
    );
  }

  if (results.length === 0) {
    return (
      <div role="status" style={{ padding: '16px 12px', textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
        No employees match '{query}'.
      </div>
    );
  }

  return (
    <div>
      <div
        aria-hidden="true"
        style={{
          padding: '6px 12px 4px',
          fontSize: 10, fontWeight: 700, color: '#9CA3AF',
          letterSpacing: '0.08em', textTransform: 'uppercase',
        }}
      >
        Results ({results.length})
      </div>
      {results.map((r, i) => (
        <SearchResultRow
          key={r.employee_id}
          id={optionId(i)}
          data={r}
          isHighlighted={highlightIdx === i}
          onClick={() => onSelect(r.employee_id, r)}
          onMouseEnter={() => onHighlight(i)}
        />
      ))}
    </div>
  );
}
