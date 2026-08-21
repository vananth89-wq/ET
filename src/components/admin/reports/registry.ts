/**
 * Report registry — the one place a report is declared.
 *
 * A report has one or more VIEWS. Each view carries its own permission, which
 * is the point: Compliance and Utilisation are opened by different people, and
 * one permission covering both is a coarse grant chosen for convenience.
 *
 * The catalog reads this and renders adaptively (see AdminReports):
 *   0 permitted views → the row is shown locked, naming what to grant
 *   1 permitted view  → the row takes THAT view's name and opens straight into
 *                       it, with no tab strip. A segmented control containing
 *                       one segment is a control that lies about having a choice
 *   2+ permitted      → the report's name, and tabs for the permitted views
 *
 * Components are wrapped in React.lazy on purpose: PermissionMatrix imports
 * REPORT_PERMISSION_MODULES from this file and must not pull recharts, xlsx or
 * a report screen into the security screen's bundle.
 */

import { lazy } from 'react';
import type { ComponentType, LazyExoticComponent } from 'react';
import type { ReportTabProps } from './reportShared';

export type ReportViewProps = ReportTabProps;

export interface ReportView {
  /** Stable slug, unique within its report. */
  code: string;
  name: string;
  icon: string;
  /**
   * The permission that gates this view AND the RPC behind it.
   * Hiding a tab is cosmetic — the server function checks the same key,
   * because PostgREST is reachable with a token and no UI.
   */
  permission: string;
  /** Shown in the catalog when this is the only view the caller can open. */
  description?: string;
  Component: LazyExoticComponent<ComponentType<ReportViewProps>>;
}

export interface ReportDef {
  code: string;
  /** Used when the caller can open more than one view. */
  name: string;
  description: string;
  icon: string;
  /** false parks a report in the tree without exposing it. */
  active: boolean;
  views: ReportView[];
}

export const REPORTS: ReportDef[] = [
  {
    code:        'expense',
    name:        'Expense Report',
    description: 'Every expense line item across the organisation, with project, department, status and currency breakdowns. Exports to CSV.',
    icon:        'fa-file-invoice-dollar',
    active:      true,
    views: [
      {
        code:       'expense',
        name:       'Expense Report',
        icon:       'fa-file-invoice-dollar',
        permission: 'expense_reports.view',
        Component:  lazy(() => import('./ExpenseReport')),
      },
    ],
  },
  {
    code:        'timesheet',
    name:        'Timesheet Report',
    description: 'Three views of one period. Compliance: who has and has not submitted, including employees who logged nothing at all. Utilisation: where the recorded hours went, by employee, project and activity. Project Summary: each project against its budget. Exports to Excel.',
    icon:        'fa-clock',
    active:      true,
    views: [
      {
        code:        'compliance',
        name:        'Timesheet Compliance',
        icon:        'fa-clipboard-check',
        permission:  'timesheet_reports.view_compliance',
        description: 'Who has and has not submitted, per month — including employees who logged nothing at all, and those with no work schedule assigned. Exports to Excel.',
        Component:   lazy(() => import('./TimesheetCompliance')),
      },
      {
        code:        'utilisation',
        name:        'Timesheet Utilisation',
        icon:        'fa-chart-simple',
        permission:  'timesheet_reports.view_utilisation',
        description: 'Where the recorded hours went — by employee, project and time type, with the activity breakdown behind each entry. Planned vs recorded. Exports to Excel.',
        Component:   lazy(() => import('./TimesheetUtilisation')),
      },
      {
        code:        'projects',
        name:        'Project Summary',
        icon:        'fa-diagram-project',
        permission:  'timesheet_reports.view_projects',
        description: 'Each project against what it was given — hours, budget consumption, contributors and a status. Projects without a budget show their hours and no percentage, rather than a fake one. Exports to Excel.',
        Component:   lazy(() => import('./TimesheetProjectSummary')),
      },
    ],
  },
];

// ─────────────────────────────────────────────────────────────────────────────
// Permission modules shown in the Reports band of the permission matrix
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Modules that exist ONLY to gate reporting, so the Reports band is where an
 * administrator expects to find them. The band renders whatever actions the RBP
 * catalog actually holds for each module, so migration 745's split from one
 * `.view` into `.view_compliance` + `.view_utilisation` needed no change here.
 *
 * `expense_reports` is deliberately NOT listed. It also gates the
 * employee-facing /expenses routes, so it belongs in the main module matrix
 * where it already has a row — listing it twice would let one screen silently
 * disagree with the other about what is granted.
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
    hint:  'One grant per report. Which EMPLOYEES appear inside them is decided separately, by the Timesheet view target population.',
  },
];

/** Human label for a single permission action inside the Reports band. */
export function reportActionLabel(action: string | null): string {
  switch (action) {
    case 'view':             return 'Access';
    case 'view_compliance':  return 'Compliance report';
    case 'view_utilisation': return 'Utilisation report';
    case 'view_projects':    return 'Project Summary report';
    case 'view_capacity':    return 'Workforce capacity report';
    case 'view_analytics':   return 'Executive dashboard';
    case 'create':           return 'Generate & export';
    case 'edit':             return 'Configure';
    case 'delete':           return 'Delete';
    default:                 return action ?? 'Access';
  }
}
