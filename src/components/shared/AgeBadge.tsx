import { statusAge } from '../../utils/dates';

interface Props { updatedAt: string; status: string; }

export default function AgeBadge({ updatedAt, status }: Props) {
  const { label, level } = statusAge(updatedAt, status);
  const cls = level === 'alert' ? 'exp-age-badge--alert' : level === 'warn' ? 'exp-age-badge--warn' : '';
  return <span className={`exp-age-badge ${cls}`}>{label}</span>;
}
