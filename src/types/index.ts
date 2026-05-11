// ── Shared ─────────────────────────────────────────────────────────
export type ExpenseStatus = 'draft' | 'submitted' | 'needs_update' | 'manager_approved' | 'approved' | 'rejected';

export interface Employee {
  employeeId: string;
  name: string;
  email?: string;
  department?: string;
  designation?: string;
  role?: string;
}

export interface Department {
  id: string;
  name: string;
  headName?: string;
  employeeCount?: number;
}

export interface PicklistValue {
  id: string;
  picklistId: string;
  value: string;
  active?: boolean;
}

export interface ExchangeRate {
  id: string;
  fromCode: string;
  toCode: string;
  rate: number;
  effectiveDate: string;
}

// ── Expense ────────────────────────────────────────────────────────
export interface Attachment {
  id: string;
  name: string;
  type: string;
  size: number;
  /** Signed URL for display/download. Populated after upload or when loading from Storage. */
  dataUrl: string;
  /** Supabase Storage object path (without bucket prefix). Set after successful upload. */
  storagePath?: string;
}

export interface LineItem {
  id: string;
  category: string;
  categoryName?: string;
  date: string;
  projectId?: string;
  projectName?: string;
  amount: number;
  currencyCode: string;
  exchangeRate: number;
  convertedAmount: number;
  note?: string;
  attachments?: Attachment[];
}

export interface ExpenseReport {
  id: string;
  employeeId: string;
  employeeName?: string;
  name: string;
  status: ExpenseStatus;
  /** Status from workflow_instances — set when the workflow is in a state like
   *  'awaiting_clarification' that doesn't change expense_reports.status itself. */
  workflowStatus?: string;
  baseCurrencyCode: string;
  createdAt: string;
  updatedAt: string;
  submittedAt?: string;
  managerApprovedAt?: string;
  managerApprovedBy?: string;
  approvedAt?: string;
  approvedBy?: string;
  rejectedAt?: string;
  rejectedBy?: string;
  rejectionReason?: string;
  lineItems: LineItem[];
}

export interface WorkflowStep {
  step: number;
  role: string;
  label: string;
}

// ── Admin Report View ──────────────────────────────────────────────
export interface AdminReportRow {
  reportId: string;
  reportName: string;
  employeeId: string;
  employeeName: string;
  department: string;
  status: ExpenseStatus;
  baseCurrency: string;
  totalBase: number;
  totalConverted: number;
  itemCount: number;
  createdAt: string;
  submittedAt?: string;
}
