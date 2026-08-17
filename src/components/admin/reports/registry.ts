/**
 * Report registry — the one place a report is declared.
 *
 * Adding a report means adding one entry here. That entry drives:
 *   • the row in /admin/reports (name, description, icon, access state)
 *   • which component the catalog renders when you click View
 *   • nothing else — the permission itself lives in the RBP catalog, seeded
 *     by a migration, and is only *referenced* here.
 *
 * Components are wrapped in React.lazy so importing this file costs nothing.
 * That matters: PermissionMatrix imports REPORT_PERMISSION_MODULES from here
 * and must not pull recharts into the security screen's bundle.
 *
 * WHAT THIS REPLACED
 *   The catalog used to be a hardcoded array with a `roles: ['admin','finance']`
 *   field that gated nothing, an `active` flag nothing could change, a
 *   `lastUpdated` string literal, and descriptions edited into localStorage
 *   where only the editing browser could see them. At one report that reads as
 *   a tidy screen; at two it is a table making false claims about itself.
 */

import { lazy } from 'react';
import type { ComponentType, LazyExoticComponent } from 'react';

/** Every report screen receives exactly this. */
export interface ReportProps { onBack: () => void; }

export interface ReportDef {
  /** Stable slug. Used as the catalog key — do not rename a shipped one. */
  code: string;
  name: string;
  description: string;
  /** Font Awesome 6 solid icon class. */
  icon: string;
  /**
   * The permission key that gates this row AND the report behind it.
   * A user without it sees the row locked, not hidden — so an administrator
   * looking at this screen can tell what to grant.
   */
  permission: string;
  /** false parks a report in the tree without exposing it. */
  active: boolean;
  Component: LazyExoticComponent<ComponentType<ReportProps>>;
}

export const REPORTS: ReportDef[] = [
  {
    code:        'expense',
    name:        'Expense Report',
    description: 'Every expense line item across the organisation, with project, department, status and currency breakdowns. Exports to CSV.',
    icon:        'fa-file-invoice-dollar',
    permission:  'expense_reports.view',
    active:      true,
    Component:   lazy(() => import('./ExpenseReport')),
  },
];

// ─────────────────────────────────────────────────────────────────────────────
// Permission modules shown in the Reports band of the permission matrix
// ─────────────────────────────────────────────────────────────────────────────
/**
 * These are the modules that exist ONLY to gate reporting, so the Reports band
 * is where an administrator expects to find them.
 *
 * `expense_reports` is deliberately NOT here. It also gates the employee-facing
 * /expenses routes, so it belongs in the main module matrix where it already
 * has a row — listing it twice would let one screen silently disagree with the
 * other about what is granted.
 *
 * The band lists whatever actions the RBP catalog actually holds for each
 * module. It does not invent them, so a module with only `.view` shows one
 * checkbox rather than a row of dashes.
 */
export interface ReportPermissionModule {
  code:  string;
  label: string;
  hint:  string;
}

export const REPORT_PERMISSION_MODULES: ReportPermissionModule[] = [
  {
    code:  'reports_admin',
    label: 'Reports section',
    hint:  'Opens /admin/reports. The outer gate — without it none of the reports below are reachable, whatever else is granted.',
  },
  {
    code:  'timesheet_reports',
    label: 'Timesheet reports',
    hint:  'Timesheet utilisation and submission-compliance reports — hours by project, planned vs recorded, and who has not submitted.',
  },
];

/** Human label for a single permission action inside the Reports band. */
export function reportActionLabel(action: string | null): string {
  switch (action) {
    case 'view':   return 'Access';
    case 'create': return 'Generate & export';
    case 'edit':   return 'Configure';
    case 'delete': return 'Delete';
    default:       return action ?? 'Access';
  }
}
