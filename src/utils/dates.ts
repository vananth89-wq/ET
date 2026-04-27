export function fmtDate(isoStr?: string): string {
  if (!isoStr) return '—';
  const d = new Date(isoStr);
  if (isNaN(d.getTime())) return isoStr;
  return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

export function statusAge(updatedAt: string, status: string): { label: string; level: 'normal' | 'warn' | 'alert' } {
  const diffMs = Date.now() - new Date(updatedAt).getTime();
  const diffDays = diffMs / 86400000;
  const diffHours = diffMs / 3600000;

  const thresholds: Record<string, { warn: number; alert: number }> = {
    draft:     { warn: 7,  alert: 14 },
    submitted: { warn: 3,  alert: 7  },
    approved:  { warn: 30, alert: 60 },
    rejected:  { warn: 3,  alert: 7  },
  };

  const t = thresholds[status] ?? { warn: 7, alert: 14 };
  let label: string;

  if (diffHours < 1) label = 'Just now';
  else if (diffHours < 24) label = `${Math.floor(diffHours)}h ago`;
  else label = `${Math.floor(diffDays)}d ago`;

  const level = diffDays >= t.alert ? 'alert' : diffDays >= t.warn ? 'warn' : 'normal';
  return { label, level };
}
