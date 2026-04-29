/**
 * permissionTooltips.tsx
 *
 * Shared tooltip data and PermTooltip component used in both:
 *  - PermissionCatalog  (shown next to each permission row)
 *  - RoleManagement     (shown inline with the permission name in the grid)
 *
 * Maps every permission code → the UI portlet it controls + the fields
 * within that portlet. Shown as a ⓘ icon that floats a dark popup on hover.
 */

import { useState, useRef } from 'react';
import ReactDOM from 'react-dom';

// ─── Tooltip data ─────────────────────────────────────────────────────────────

export interface PermTooltipData {
  portlet: string;
  fields:  string[];
}

export const PERMISSION_TOOLTIPS: Record<string, PermTooltipData> = {

  // ── Profile ──────────────────────────────────────────────────────────────────
  'profile.view_own': {
    portlet: 'My Profile',
    fields: ['Personal details summary', 'Contact info', 'Employment summary', 'Documents overview'],
  },
  'profile.edit_own': {
    portlet: 'My Profile — Edit',
    fields: ['Avatar / photo', 'Notification preferences', 'Display settings'],
  },

  // ── Expense ──────────────────────────────────────────────────────────────────
  'expense.create': {
    portlet: 'Create Expense',
    fields: ['Start a new expense report', 'Add line items', 'Attach receipts'],
  },
  'expense.submit': {
    portlet: 'Expense Submission',
    fields: ['Create expense report', 'Add line items', 'Attach receipts', 'Submit for approval'],
  },
  'expense.view_own': {
    portlet: 'My Expenses',
    fields: ['Own expense reports list', 'Report status', 'Line item detail', 'Attachments'],
  },
  'expense.edit': {
    portlet: 'Expense Report — Edit',
    fields: ['Edit draft reports', 'Edit rejected reports', 'Update line items'],
  },
  'expense.delete': {
    portlet: 'Expense Report — Delete',
    fields: ['Delete own draft report', 'Delete own rejected report'],
  },
  'expense.view_direct': {
    portlet: 'Expense Reports — Direct Reports',
    fields: ['View reports from direct reports', 'Drill into line items', 'View attachments'],
  },
  'expense.view_team': {
    portlet: 'Expense Reports — Team',
    fields: ['View reports from all team members', 'Cross-team visibility for managers'],
  },
  'expense.view_org': {
    portlet: 'Expense Reports — All',
    fields: ['View all expense reports organisation-wide', 'Finance / admin full access'],
  },
  'expense.approve': {
    portlet: 'Approval Queue — Manager',
    fields: ['Approve expense reports', 'Reject expense reports', 'Add approval comments'],
  },
  'expense.edit_approval': {
    portlet: 'Approval Queue',
    fields: ['Manager-level approve / reject', 'Finance-level approve / reject', 'Approval history'],
  },
  'expense.finance_approve': {
    portlet: 'Approval Queue — Finance',
    fields: ['Final finance approval', 'Mark report as paid', 'Override manager decision'],
  },
  'expense.export': {
    portlet: 'Admin Reports',
    fields: ['Export expense data to CSV/Excel', 'Bulk report download', 'Audit export'],
  },

  // ── Employee — Admin actions ─────────────────────────────────────────────────
  'employee.create': {
    portlet: 'Add Employee',
    fields: ['Create new employee record', 'Set initial role', 'Assign department and manager'],
  },
  'employee.edit': {
    portlet: 'Employee Edit Panel (admin)',
    fields: [
      'Full Name', 'Business Email', 'Designation', 'Department',
      'Manager', 'Hire Date', 'End Date', 'Work Location',
      'Work Country', 'Currency', 'Status',
    ],
  },
  'employee.delete': {
    portlet: 'Employee Actions',
    fields: ['Soft-delete (deactivate) employee record'],
  },
  'employee.view_directory': {
    portlet: 'Employee Directory',
    fields: ['Name', 'Employee ID', 'Designation', 'Department', 'Business Email', 'Status'],
  },
  'employee.view_orgchart_admin': {
    portlet: 'Org Chart (Admin View)',
    fields: [
      'Reporting lines', 'Manager assignments', 'Department heads',
      'Head counts', 'Team hierarchy', 'Employee status',
    ],
  },

  // ── Employee — View own profile ──────────────────────────────────────────────
  'employee.view_own_personal': {
    portlet: 'Personal (self-service)',
    fields: ['Nationality', 'Marital Status', 'Photo / Avatar'],
  },
  'employee.view_own_contact': {
    portlet: 'Contact (self-service)',
    fields: ['Country Code', 'Mobile', 'Personal Email'],
  },
  'employee.view_own_employment': {
    portlet: 'Employment (self-service)',
    fields: [
      'Designation', 'Job Title', 'Department', 'Manager',
      'Hire Date', 'End Date', 'Work Location', 'Work Country',
      'Currency', 'Probation End Date',
    ],
  },
  'employee.view_own_address': {
    portlet: 'Address (self-service)',
    fields: [
      'Address Type', 'Address Line 1', 'Address Line 2',
      'City', 'State / Region', 'Country', 'Postal Code',
    ],
  },
  'employee.view_own_passport': {
    portlet: 'Passport (self-service)',
    fields: [
      'Passport Number', 'Issuing Country', 'Issue Date', 'Expiry Date',
      'Visa Type', 'Visa Expiry Date',
    ],
  },
  'employee.view_own_identity': {
    portlet: 'Identity Documents (self-service)',
    fields: ['ID Type', 'ID Number', 'Issuing Country', 'Issue Date', 'Expiry Date'],
  },
  'employee.view_own_emergency': {
    portlet: 'Emergency Contacts (self-service)',
    fields: ['Contact Name', 'Relationship', 'Phone', 'Email'],
  },

  // ── Employee — Edit own profile ──────────────────────────────────────────────
  'employee.edit_own_personal': {
    portlet: 'Personal (self-service) — edit',
    fields: ['Nationality', 'Marital Status', 'Photo / Avatar'],
  },
  'employee.edit_own_contact': {
    portlet: 'Contact (self-service) — edit',
    fields: ['Country Code', 'Mobile', 'Personal Email'],
  },
  'employee.edit_own_employment': {
    portlet: 'Employment (self-service) — edit',
    fields: [
      'Designation', 'Job Title', 'Department', 'Manager',
      'Hire Date', 'End Date', 'Work Location', 'Work Country',
      'Currency', 'Probation End Date',
      '⚠ Admin-only by default — employment terms are set by HR',
    ],
  },
  'employee.edit_own_address': {
    portlet: 'Address (self-service) — edit',
    fields: [
      'Address Type', 'Address Line 1', 'Address Line 2',
      'City', 'State / Region', 'Country', 'Postal Code',
    ],
  },
  'employee.edit_own_passport': {
    portlet: 'Passport (self-service) — edit',
    fields: [
      'Passport Number', 'Issuing Country', 'Issue Date', 'Expiry Date',
      'Visa Type', 'Visa Expiry Date',
    ],
  },
  'employee.edit_own_identity': {
    portlet: 'Identity Documents (self-service) — edit',
    fields: ['ID Type', 'ID Number', 'Issuing Country', 'Issue Date', 'Expiry Date'],
  },
  'employee.edit_own_emergency': {
    portlet: 'Emergency Contacts (self-service) — edit',
    fields: ['Contact Name', 'Relationship', 'Phone', 'Email'],
  },

  // ── Employee — Org Chart ─────────────────────────────────────────────────────
  'employee.view_orgchart': {
    portlet: 'Org Chart (standard)',
    fields: ['Reporting structure', 'Team view', 'Manager and department info'],
  },

  // ── Department ───────────────────────────────────────────────────────────────
  'department.view': {
    portlet: 'Department Directory',
    fields: ['Department name', 'Department code', 'Parent department', 'Head name', 'Status'],
  },
  'department.create': {
    portlet: 'Department Management',
    fields: ['Department name', 'Department code', 'Description', 'Parent department'],
  },
  'department.edit': {
    portlet: 'Department Management',
    fields: ['Department name', 'Department code', 'Description', 'Parent department'],
  },
  'department.delete': {
    portlet: 'Department Management',
    fields: ['Soft-delete (deactivate) department record'],
  },
  'department.manage_heads': {
    portlet: 'Department Head Assignment',
    fields: ['Assign department head', 'Remove department head', 'Head effective date', 'Head history'],
  },
  'department.view_members': {
    portlet: 'Department Members',
    fields: ['Employee name', 'Employee ID', 'Designation', 'Hire date', 'Status'],
  },
  'department.view_orgchart': {
    portlet: 'Department Org Chart',
    fields: [
      'Department hierarchy', 'Head name', 'Member count',
      'Parent / child departments', 'Vacant head flag',
    ],
  },

  // ── Reference Data ───────────────────────────────────────────────────────────
  'reference.view': {
    portlet: 'Reference Data',
    fields: ['Picklist list', 'Picklist values', 'Parent picklist', 'Value status (active/inactive)'],
  },
  'reference.create': {
    portlet: 'Reference Data — Add',
    fields: ['New picklist', 'New picklist value', 'Parent value assignment'],
  },
  'reference.edit': {
    portlet: 'Reference Data — Edit',
    fields: ['Picklist name & description', 'Value text', 'Parent value', 'Meta fields (ISO code, currency)'],
  },
  'reference.delete': {
    portlet: 'Reference Data — Delete',
    fields: ['Delete picklist (and all its values)', 'Delete individual picklist value'],
  },

  // ── Projects ─────────────────────────────────────────────────────────────────
  'project.view': {
    portlet: 'Projects List',
    fields: ['Project name', 'Project code', 'Status', 'Description'],
  },
  'project.create': {
    portlet: 'Projects — Add',
    fields: ['Project name', 'Project code', 'Description', 'Status'],
  },
  'project.edit': {
    portlet: 'Projects — Edit',
    fields: ['Project name', 'Project code', 'Description', 'Active / inactive toggle'],
  },
  'project.delete': {
    portlet: 'Projects — Delete',
    fields: ['Permanently remove a project record'],
  },

  // ── Exchange Rates ────────────────────────────────────────────────────────────
  'exchange_rate.view': {
    portlet: 'Exchange Rates',
    fields: ['Currency list', 'ISO code', 'Symbol', 'Rate values', 'Effective date'],
  },
  'exchange_rate.create': {
    portlet: 'Exchange Rates — Add',
    fields: ['New currency', 'New exchange rate entry', 'Effective date'],
  },
  'exchange_rate.edit': {
    portlet: 'Exchange Rates — Edit',
    fields: ['Currency name', 'ISO code', 'Symbol', 'Rate value', 'Effective date'],
  },
  'exchange_rate.delete': {
    portlet: 'Exchange Rates — Delete',
    fields: ['Remove currency', 'Remove exchange rate entry'],
  },

  // ── Reports ──────────────────────────────────────────────────────────────────
  'report.view': {
    portlet: 'Admin Reports Dashboard',
    fields: [
      'Expense analytics overview (charts + KPI)',
      'Filter by employee, dept, project, status, date',
      'Project-wise spend bar chart',
      'Status distribution donut & monthly trend',
    ],
  },

  // ── Admin portal gate ────────────────────────────────────────────────────────
  'admin.access': {
    portlet: 'Admin Panel',
    fields: [
      'Admin nav link visibility',
      'Entry to all /admin/* pages',
      'Required in addition to any page-specific permission',
    ],
  },

  // ── Security ─────────────────────────────────────────────────────────────────
  'security.assign_access': {
    portlet: 'Role Assignments',
    fields: ['Assign role to user', 'Change existing role assignment', 'Remove role from user'],
  },
  'security.manage_roles': {
    portlet: 'Security Screens',
    fields: ['Role Management grid', 'Permission Catalog', 'Role Assignments screen'],
  },
};

// ─── PermTooltip component ────────────────────────────────────────────────────
// Renders a ⓘ icon that shows a floating dark popup on hover.
// Returns null if no tooltip data exists for the given permission code.

// Estimated tooltip height so we can flip above the icon when near the bottom.
const TOOLTIP_MAX_HEIGHT = 280;
const TOOLTIP_WIDTH      = 260;
const GAP                = 8;

export function PermTooltip({ code }: { code: string }) {
  // Hooks must always be called before any early return (Rules of Hooks)
  const [visible, setVisible] = useState(false);
  const [pos, setPos]         = useState<{ top: number; left: number; flipUp: boolean }>({
    top: 0, left: 0, flipUp: false,
  });
  const iconRef = useRef<HTMLSpanElement>(null);

  const data = PERMISSION_TOOLTIPS[code];
  if (!data) return null;

  function show() {
    if (!iconRef.current) return;
    const rect     = iconRef.current.getBoundingClientRect();
    const vw       = window.innerWidth;
    const vh       = window.innerHeight;

    // Flip above the icon if the popup would go off the bottom edge
    const flipUp   = rect.bottom + GAP + TOOLTIP_MAX_HEIGHT > vh;

    // Clamp left so the popup never goes off the right edge
    const rawLeft  = rect.left;
    const left     = Math.min(rawLeft, vw - TOOLTIP_WIDTH - 12);

    setPos({
      top:    flipUp ? rect.top - GAP : rect.bottom + GAP,
      left:   Math.max(8, left),
      flipUp,
    });
    setVisible(true);
  }

  return (
    <>
      <span
        ref={iconRef}
        onMouseEnter={show}
        onMouseLeave={() => setVisible(false)}
        style={{
          display:        'inline-flex',
          alignItems:     'center',
          justifyContent: 'center',
          marginLeft:     5,
          cursor:         'default',
          color:          '#9CA3AF',
          fontSize:       13,
          lineHeight:     1,
          userSelect:     'none',
        }}
        title=""
        aria-label={`Fields for ${code}`}
      >
        ⓘ
      </span>

      {visible && ReactDOM.createPortal(
        <div
          onMouseEnter={show}
          onMouseLeave={() => setVisible(false)}
          style={{
            position:     'fixed',
            top:          pos.flipUp ? undefined : pos.top,
            bottom:       pos.flipUp ? window.innerHeight - pos.top : undefined,
            left:         pos.left,
            zIndex:       99999,
            background:   '#1F2937',
            color:        '#F9FAFB',
            borderRadius: 8,
            padding:      '10px 14px',
            width:        TOOLTIP_WIDTH,
            maxHeight:    `calc(100vh - 24px)`,
            overflowY:    'auto',
            fontSize:     12,
            lineHeight:   1.5,
            boxShadow:    '0 4px 16px rgba(0,0,0,0.25)',
            pointerEvents: 'auto',
          }}
        >
          <div style={{
            fontWeight:    700,
            marginBottom:  6,
            color:         '#93C5FD',
            fontSize:      11,
            textTransform: 'uppercase',
            letterSpacing: '0.05em',
          }}>
            {data.portlet}
          </div>
          <ul style={{ margin: 0, paddingLeft: 14 }}>
            {data.fields.map((f, i) => (
              <li key={i} style={{
                marginBottom: 2,
                color: f.startsWith('⚠') ? '#FCD34D' : '#F9FAFB',
              }}>
                {f}
              </li>
            ))}
          </ul>
        </div>,
        document.body,
      )}
    </>
  );
}
