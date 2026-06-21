import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { usePermissions } from '../../../hooks/usePermissions';

export interface SectionNavItem {
  path: string;        // absolute path e.g. /admin/employees/details
  label: string;
  icon: string;        // fa-* class
  permission?: string;
  anyOf?: string[];
}

interface Props {
  title: string;
  subtitle?: string;
  items: SectionNavItem[];
}

export default function AdminSectionLayout({ title, subtitle, items }: Props) {
  const navigate = useNavigate();
  const { can, canAny } = usePermissions();

  const visible = items.filter(item => {
    if (item.anyOf) return canAny(item.anyOf);
    if (item.permission) return can(item.permission);
    return true;
  });

  // Single-item sections don't need a sidebar — render like a direct page
  if (visible.length <= 1) {
    return (
      <div className="admin-direct-page">
        <button className="admin-direct-back" onClick={() => navigate('/admin')}>
          <i className="fa-solid fa-chevron-left" />
          Back to Admin
        </button>
        <Outlet />
      </div>
    );
  }

  return (
    <div className="tm-page">
      <div className="tm-header">
        <h1 className="tm-title">{title}</h1>
        {subtitle && <p className="tm-subtitle">{subtitle}</p>}
      </div>

      <div className="tm-layout">
        {/* Sidebar nav */}
        <nav className="tm-sidebar">
          {/* Back to Admin */}
          <button className="admin-section-back" onClick={() => navigate('/admin')}>
            <i className="fa-solid fa-chevron-left" />
            <span>Admin</span>
          </button>
          <div className="admin-section-divider" />
          <p className="admin-section-group-label">{title}</p>

          {visible.map(item => (
            <NavLink
              key={item.path}
              to={item.path}
              className={({ isActive }) =>
                `tm-sidebar-item${isActive ? ' active' : ''}`
              }
            >
              <i className={`fa-solid ${item.icon}`} />
              <span>{item.label}</span>
            </NavLink>
          ))}
        </nav>

        {/* Main content */}
        <div className="tm-content">
          <Outlet />
        </div>
      </div>
    </div>
  );
}
