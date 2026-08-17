/**
 * "Vijey's timesheet ↗" — the approver's way into the employee's own screen.
 *
 * Self-gating on purpose. The button asks time_timesheet_access (mig 740) for
 * the employee it is about and renders nothing when the answer is no, so a
 * caller cannot forget the permission check by forgetting to wrap it. Dropping
 * it into a header is the whole integration.
 *
 * It always lands read-only, by two independent locks:
 *   - user_can('timesheet','edit', employee_id) decides whether the screen has
 *     any edit affordances at all; and
 *   - a timesheet in approval sits at status 'to_be_approved', which every
 *     write RPC and RLS policy refuses.
 * So an approver with full edit rights over their report still cannot change
 * the month they are being asked to approve. It becomes editable again only if
 * they send it back.
 */

import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';

interface Access { can_view: boolean; can_edit: boolean }

export function TimesheetLinkButton({ employeeId, period, personName, compact }: {
  employeeId: string | null | undefined;
  /** YYYY-MM — MyTimesheet reads it as ?period=, and lands on that month. */
  period: string | null | undefined;
  personName: string | null | undefined;
  compact?: boolean;
}) {
  const [access, setAccess] = useState<Access | null>(null);

  useEffect(() => {
    if (!employeeId) { setAccess(null); return; }
    let alive = true;
    setAccess(null);          // never show the previous employee's answer
    supabase
      .rpc('time_timesheet_access', { p_employee_id: employeeId })
      .then(({ data, error }) => {
        if (!alive || error) return;
        setAccess(data as unknown as Access);
      });
    return () => { alive = false; };
  }, [employeeId]);

  if (!employeeId || !access?.can_view) return null;

  const first = (personName ?? '').trim().split(/\s+/)[0] || 'their';
  const href  = `/timesheet/${employeeId}${period ? `?period=${period}` : ''}`;

  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      title={`Opens ${personName ?? 'the employee'}'s timesheet in a new tab`}
      style={{
        display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0,
        padding: compact ? '5px 10px' : '6px 12px',
        borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff',
        color: '#374151', fontWeight: 600, fontSize: 12,
        cursor: 'pointer', whiteSpace: 'nowrap', textDecoration: 'none',
      }}
      onMouseEnter={e => { e.currentTarget.style.background = '#F8FAFC'; e.currentTarget.style.borderColor = '#9CA3AF'; }}
      onMouseLeave={e => { e.currentTarget.style.background = '#fff';    e.currentTarget.style.borderColor = '#D1D5DB'; }}
    >
      <i className="fas fa-calendar-days" style={{ fontSize: 11, color: '#2F77B5' }} />
      {first}&rsquo;s timesheet
      {!access.can_edit && (
        <span style={{
          fontSize: 9, fontWeight: 800, letterSpacing: '0.06em',
          background: '#F1F5F9', color: '#64748B', borderRadius: 3, padding: '1px 5px',
        }}>VIEW</span>
      )}
      <i className="fas fa-arrow-up-right-from-square" style={{ fontSize: 9, color: '#9CA3AF' }} />
    </a>
  );
}
