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
}

export default function SearchResultRow({
  id,
  data,
  isHighlighted,
  onClick,
  onMouseEnter,
}: SearchResultRowProps) {
  const name  = 'full_name'     in data ? data.full_name     : data.full_name;
  const code  = 'employee_code' in data ? data.employee_code : data.employee_code;
  const email = 'email'         in data ? data.email         : null;
  const status = 'status' in data ? data.status : undefined;
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
    </div>
  );
}
