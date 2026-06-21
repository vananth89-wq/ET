import { useNavigate } from 'react-router-dom';

interface Props {
  children: React.ReactNode;
}

/** Thin wrapper for direct admin pages (no sub-sidebar). Adds a ← Admin back link. */
export default function AdminDirectPage({ children }: Props) {
  const navigate = useNavigate();
  return (
    <div className="admin-direct-page">
      <button className="admin-direct-back" onClick={() => navigate('/admin')}>
        <i className="fa-solid fa-chevron-left" />
        Back to Admin
      </button>
      {children}
    </div>
  );
}
