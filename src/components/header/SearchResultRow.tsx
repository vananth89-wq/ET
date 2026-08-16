/**
 * SearchResultRow
 * One row in the employee search dropdown.
 * Used by both live search results and the Recently Viewed list.
 */

import type { EmployeeSearchResult } from '../../hooks/useEmployeeSearch';
import type { RecentlyViewedEntry }  from '../../hooks/useRecentlyViewed';

// Accept either shape — search result or recently-viewed entry
type RowData =
  | (EmployeeSearchResult & { isRecent?: boolean })
  | (RecentlyViewedEntry  & { status?: string; avatar_url?: string | null; similarity?: number; isRecent?: boolean });

interface SearchResultRowProps {
  id?:         string;   // for aria-activedescendant linkage
  data:        RowData;
  isHighlighted: boolean;
  onClick:     () => void;
  onMouseEnter?: () => void;
  /** Present only when the signed-in user may open this person's timesheet. */
  onOpenTimesheet?: () => void;
}

export default function SearchResultRow({
  id,
  data,
  isHighlighted,
  onClick,
  onMouseEnter,
  onOpenTimesheet,
}: SearchResultRowProps) {
  const name   = data.full_name;
  const code   = data.employee_code;
  const email  = 'email'      in data ? data.email      : null;
  const status = 'status'     in data ? data.status     : undefined;
  const avatar = 'avatar_url' in data ? data.avatar_url : undefined;

  const initials = name
    .split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((w: string) => w[0].toUpperCase())
    .join('');

  const isInactive = status === 'Inactive';

  return (
    <div
      id={id}
      role="option"
      aria-selected={isHighlighted}
      onClick={onClick}
      onMouseEnter={onMouseEnter}
      aria-label={onOpenTimesheet
        ? `${data.full_name} — Enter to open profile, Shift+Enter for timesheet`
        : undefined}
      style={{
        display:     'flex',
        alignItems:  'center',
        gap:         10,
        padding:     '8px 12px',
        cursor:      'pointer',
        background:  isHighlighted ? '#F0F4FF' : 'transparent',
        borderRadius: 6,
        transition:  'background 0.1s',
      }}
    >
      {/* Avatar */}
      <div style={{
        width: 32, height: 32, borderRadius: '50%',
        flexShrink: 0, overflow: 'hidden',
        background: '#E5E7EB', display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 12, fontWeight: 700, color: '#6B7280',
      }}>
        {avatar
          ? <img src={avatar} alt={name} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
          : initials}
      </div>

      {/* Text */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ fontWeight: 600, fontSize: 13, color: '#111827', whiteSpace: 'nowrap' }}>
            {name}
          </span>
          <span style={{ fontSize: 11, color: '#9CA3AF' }}>{code}</span>
          {isInactive && (
            <span style={{
              fontSize: 10, fontWeight: 600, background: '#FEF3C7', color: '#B45309',
              border: '1px solid #F59E0B', borderRadius: 4, padding: '1px 5px',
            }}>
              Inactive
            </span>
          )}
        </div>
        {email && (
          <div style={{ fontSize: 11, color: '#6B7280', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {email}
          </div>
        )}
      </div>

      {/* Second destination on the same row. The name still goes to the
          profile; this goes to their timesheet.

          aria-hidden with tabIndex -1 on purpose: the row is role="option"
          inside a listbox, and a focusable control nested in an option is
          invalid ARIA that screen readers cannot reach anyway. The keyboard
          route is Shift+Enter, announced in the row's aria-label above, which
          keeps the listbox semantics intact.

          stopPropagation, or clicking it would ALSO fire the row and navigate
          to the profile a moment later. */}
      {onOpenTimesheet && (
        <button
          type="button"
          tabIndex={-1}
          aria-hidden="true"
          onClick={e => { e.stopPropagation(); onOpenTimesheet(); }}
          title="Open this employee's timesheet"
          style={{
            flexShrink: 0, display: 'inline-flex', alignItems: 'center', gap: 5,
            padding: '4px 9px', borderRadius: 6, cursor: 'pointer',
            border: '1px solid #C7D6FF', background: isHighlighted ? '#FFFFFF' : '#F5F8FF',
            color: '#2563EB', fontSize: 11, fontWeight: 600, whiteSpace: 'nowrap',
          }}
        >
          <i className="fa-regular fa-calendar-days" style={{ fontSize: 10 }} />
          View Timesheet
          <span aria-hidden="true">&rarr;</span>
        </button>
      )}
    </div>
  );
}
