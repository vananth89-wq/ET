/**
 * RecentlyViewedList
 * Shown inside the EmployeeSearchBox dropdown when query is empty (< 2 chars).
 */

import SearchResultRow from './SearchResultRow';
import type { RecentlyViewedEntry } from '../../hooks/useRecentlyViewed';

interface RecentlyViewedListProps {
  entries:      RecentlyViewedEntry[];
  highlightIdx: number;
  optionId:     (idx: number) => string;
  onSelect:     (entry: RecentlyViewedEntry) => void;
  onHighlight:  (idx: number) => void;
}

export default function RecentlyViewedList({
  entries,
  highlightIdx,
  optionId,
  onSelect,
  onHighlight,
}: RecentlyViewedListProps) {
  if (entries.length === 0) {
    return (
      <div style={{ padding: '16px 12px', textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
        Start typing to search employees.
      </div>
    );
  }

  return (
    <div>
      <div style={{
        padding: '6px 12px 4px',
        fontSize: 10, fontWeight: 700, color: '#9CA3AF',
        letterSpacing: '0.08em', textTransform: 'uppercase',
      }}>
        Recent
      </div>
      {entries.map((entry, i) => (
        <SearchResultRow
          key={entry.employee_id}
          id={optionId(i)}
          data={{ ...entry, isRecent: true }}
          isHighlighted={highlightIdx === i}
          onClick={() => onSelect(entry)}
          onMouseEnter={() => onHighlight(i)}
        />
      ))}
    </div>
  );
}
