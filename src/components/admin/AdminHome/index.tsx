import { useNavigate } from 'react-router-dom';
import { usePermissions } from '../../../hooks/usePermissions';

interface SectionItem {
  path: string;
  permission?: string;
  anyOf?: string[];
}

interface AdminSection {
  id: string;
  label: string;
  description: string;
  icon: string;
  color: string;
  items: SectionItem[];
}

const SECTIONS: AdminSection[] = [
  {
    id: 'employees',
    label: 'Employees',
    description: 'Employee records & org chart',
    icon: 'fa-users',
    color: '#2563EB',
    items: [
      { path: '/admin/employees/list',     permission: 'employee_details.edit'   },
      { path: '/admin/employees/org-chart',permission: 'org_chart.view'          },
      { path: '/admin/employees/inactive', permission: 'inactive_employees.view' },
      { path: '/admin/employees/add',      permission: 'hire_employee.create'    },
    ],
  },
  {
    id: 'organization',
    label: 'Organization',
    description: 'Departments & structure',
    icon: 'fa-sitemap',
    color: '#7C3AED',
    items: [
      { path: '/admin/organization/departments', permission: 'departments.edit' },
      { path: '/admin/organization/org-chart',   permission: 'org_chart.view'   },
    ],
  },
  {
    id: 'workflow',
    label: 'Workflow',
    description: 'Approvals & automation',
    icon: 'fa-diagram-next',
    color: '#0891B2',
    items: [
      { path: '/admin/workflow/operations',  permission: 'wf_manage.view'    },
      { path: '/admin/workflow/templates',   permission: 'wf_templates.view' },
      { path: '/admin/workflow/assignments', permission: 'wf_assignments.view' },
      { path: '/admin/workflow/delegations', permission: 'wf_delegations.view' },
      { path: '/admin/workflow/performance', permission: 'wf_performance.view' },
    ],
  },
  {
    id: 'security',
    label: 'Security',
    description: 'Permissions & roles',
    icon: 'fa-lock',
    color: '#DC2626',
    items: [
      { path: '/admin/security/matrix',        permission: 'sec_permission_matrix.view'  },
      { path: '/admin/security/assignments',   permission: 'sec_role_assignments.view'   },
      { path: '/admin/security/target-groups', permission: 'sec_target_groups.view'      },
      { path: '/admin/security/catalog',       permission: 'sec_permission_catalog.view' },
      { path: '/admin/security/rbp',           permission: 'sec_rbp_troubleshoot.view'   },
    ],
  },
  {
    id: 'projects',
    label: 'Projects',
    description: 'Manage project catalogue',
    icon: 'fa-folder-open',
    color: '#D97706',
    items: [{ path: '/admin/projects', permission: 'projects_mgmt.view' }],
  },
  {
    id: 'reference-data',
    label: 'Reference Data',
    description: 'Picklists & lookup values',
    icon: 'fa-list-ul',
    color: '#059669',
    items: [{ path: '/admin/reference-data', permission: 'picklists.view' }],
  },
  {
    id: 'exchange-rates',
    label: 'Exchange Rates',
    description: 'Currency conversion rates',
    icon: 'fa-arrow-right-arrow-left',
    color: '#0D9488',
    items: [{ path: '/admin/exchange-rates', permission: 'exchange_rates_mgmt.view' }],
  },
  {
    id: 'reports',
    label: 'Reports',
    description: 'Admin analytics & reports',
    icon: 'fa-chart-bar',
    color: '#7C3AED',
    items: [{ path: '/admin/reports', permission: 'reports_admin.view' }],
  },
  {
    id: 'import-export',
    label: 'Import / Export',
    description: 'Bulk data operations',
    icon: 'fa-arrows-up-down',
    color: '#B45309',
    items: [
      {
        path: '/admin/import-export',
        anyOf: [
          'personal_info.bulk_import', 'personal_info.bulk_export',
          'employees.bulk_import',     'employees.bulk_export',
          'department.bulk_import',    'department.bulk_export',
        ],
      },
    ],
  },
  {
    id: 'jobs',
    label: 'Background Jobs',
    description: 'Scheduled & async tasks',
    icon: 'fa-clock-rotate-left',
    color: '#475569',
    items: [{ path: '/admin/jobs/background', permission: 'jobs_manage.view' }],
  },
  {
    id: 'theme-manager',
    label: 'Theme Manager',
    description: 'Branding & appearance',
    icon: 'fa-palette',
    color: '#EC4899',
    items: [{ path: '/admin/theme-manager', permission: 'theme_manager.view' }],
  },
];

export default function AdminHome() {
  const navigate = useNavigate();
  const { can, canAny } = usePermissions();

  function hasAccess(section: AdminSection): boolean {
    return section.items.some(item => {
      if (item.anyOf) return canAny(item.anyOf);
      if (item.permission) return can(item.permission);
      return true;
    });
  }

  // For grouped sections, navigate to the section root; index redirect handles the rest.
  // For direct sections (single item), go straight to it.
  function firstPath(section: AdminSection): string {
    const sectionRoots: Record<string, string> = {
      employees: '/admin/employees',
      organization: '/admin/organization',
      workflow: '/admin/workflow',
      security: '/admin/security',
      jobs: '/admin/jobs',
    };
    if (sectionRoots[section.id]) return sectionRoots[section.id];
    // Direct sections — find first accessible item
    for (const item of section.items) {
      if (item.anyOf && canAny(item.anyOf)) return item.path;
      if (item.permission && can(item.permission)) return item.path;
      if (!item.permission && !item.anyOf) return item.path;
    }
    return section.items[0].path;
  }

  const visible = SECTIONS.filter(hasAccess);

  return (
    <div className="admin-home">
      <div className="admin-home-header">
        <h1 className="admin-home-title">Admin</h1>
        <p className="admin-home-subtitle">Select a module to manage</p>
      </div>

      <div className="admin-home-grid">
        {visible.map(section => (
          <button
            key={section.id}
            className="admin-home-tile"
            onClick={() => navigate(firstPath(section))}
          >
            <div
              className="admin-home-tile-icon"
              style={{ background: `${section.color}15`, color: section.color }}
            >
              <i className={`fa-solid ${section.icon}`} />
            </div>
            <p className="admin-home-tile-label">{section.label}</p>
          </button>
        ))}
      </div>
    </div>
  );
}
