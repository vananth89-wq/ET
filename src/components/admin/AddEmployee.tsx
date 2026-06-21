import { useState, useMemo, useEffect, useRef } from 'react';
import { useSearchParams, useNavigate } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { usePermissions } from '../../hooks/usePermissions';
import WorkflowGateBanner from '../../workflow/components/WorkflowGateBanner';
import { supabase } from '../../lib/supabase';
import { useEmployees } from '../../hooks/useEmployees';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { useDepartments } from '../../hooks/useDepartments';
import { useCurrencies } from '../../hooks/useCurrencies';
import { PHONE_CODES } from '../../constants/phoneCodes';
import { validateMobile, mobilePlaceholder, mobileHint } from '../../utils/validateMobile';
import { validatePassportNumber, validatePassportValidity, passportNumberPlaceholder, passportNumberHint, passportValidityHint } from '../../utils/validatePassport';
import { validateIdentityNumber, idNumberPlaceholder, idNumberHint, defaultExpiryDate, idValidityLabel } from '../../utils/validateIdentity';
import BankAccountsPortlet from '../shared/BankAccountsPortlet';
import DependentsPortlet from '../shared/DependentsPortlet';
import EducationPortlet  from '../shared/EducationPortlet';
import ConfirmationModal  from '../shared/ConfirmationModal';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────
interface PicklistValue {
  picklistId: string;
  id: string;
  value: string;
  refId: string | null;
  active: boolean;
  parentValueId: string | null;
}

interface IdRecord {
  country: string;
  idType: string;
  recordType: string;
  idNumber: string;
  expiry: string;
}

export interface FullEmployee {
  employeeId: string;
  name: string;
  nationality?: string;
  maritalStatus?: string;
  gender?: string;
  dob?: string;
  countryCode?: string;
  mobile?: string;
  businessEmail?: string;
  personalEmail?: string;
  passportCountry?: string;
  passportNumber?: string;
  passportIssueDate?: string;
  passportExpiryDate?: string;
  idRecords?: IdRecord[];
  designation?: string;
  deptId?: string;
  managerId?: string;
  hireDate?: string;
  endDate?: string;
  probationEndDate?: string;
  workCountry?: string;
  workLocation?: string;
  baseCurrency?: string;
  addrLine1?: string;
  addrLine2?: string;
  addrLandmark?: string;
  addrCity?: string;
  addrDistrict?: string;
  addrState?: string;
  addrPin?: string;
  addrCountry?: string;
  ecName?: string;
  ecRelationship?: string;
  ecPhone?: string;
  ecAltPhone?: string;
  ecEmail?: string;
  photo?: string;
  role?: string;
  status?: 'Draft' | 'Incomplete' | 'Pending' | 'Active' | 'Inactive' | 'Rejected';
  locked?: boolean;
  // _completedSections removed — tick state is always data-derived, never persisted
  [key: string]: unknown;
}

// ─────────────────────────────────────────────────────────────────────────────
// Section definitions
// ─────────────────────────────────────────────────────────────────────────────
const SECTIONS = [
  { id: 'personal',   label: 'Personal',   icon: 'fa-circle-user',   optional: false },
  { id: 'contact',    label: 'Phone',      icon: 'fa-phone',          optional: false },
  { id: 'email',      label: 'Email',      icon: 'fa-envelope',       optional: false },
  { id: 'employment', label: 'Employment', icon: 'fa-briefcase',      optional: false },
  { id: 'identity',   label: 'Identity',   icon: 'fa-id-card-clip',   optional: true  },
  { id: 'passport',   label: 'Passport',   icon: 'fa-passport',       optional: true  },
  { id: 'address',    label: 'Address',    icon: 'fa-location-dot',   optional: false },
  { id: 'emergency',  label: 'Emergency',  icon: 'fa-phone-volume',   optional: false },
  { id: 'education',  label: 'Education',  icon: 'fa-graduation-cap',  optional: true  },
  { id: 'bank',       label: 'Bank',       icon: 'fa-building-columns', optional: false },
  { id: 'dependents', label: 'Dependents', icon: 'fa-people-group',    optional: true  },
];

// PHONE_CODES imported from src/constants/phoneCodes.ts

export const COUNTRIES = [
  'Afghanistan','Albania','Algeria','Argentina','Australia','Austria','Bangladesh','Belgium',
  'Brazil','Canada','Chile','China','Colombia','Denmark','Egypt','Finland','France','Germany',
  'Ghana','Greece','Hungary','India','Indonesia','Iran','Iraq','Ireland','Israel','Italy',
  'Japan','Jordan','Kenya','South Korea','Kuwait','Malaysia','Mexico','Morocco','Nepal',
  'Netherlands','New Zealand','Nigeria','Norway','Pakistan','Philippines','Poland','Portugal',
  'Qatar','Russia','Saudi Arabia','Singapore','South Africa','Spain','Sri Lanka','Sweden',
  'Switzerland','Thailand','Turkey','UAE','Ukraine','United Kingdom','United States',
  'Vietnam','Zimbabwe',
];

// generateEmpId is kept as a local fallback only — the canonical ID is always
// fetched from the server via generate_employee_id() RPC (collision-safe sequence).
function generateEmpId(employees: FullEmployee[]): string {
  const nums = employees
    .map(e => parseInt((e.employeeId || '').replace(/\D/g, ''), 10))
    .filter(n => !isNaN(n));
  const max = nums.length ? Math.max(...nums) : 0;
  return `EMP${String(max + 1).padStart(3, '0')}`;
}

function getAvatar(emp?: Partial<FullEmployee>): string {
  if (emp?.photo) return emp.photo as string;
  const name = emp?.name || 'N';
  return `https://ui-avatars.com/api/?name=${encodeURIComponent(name)}&background=2F77B5&color=fff&size=80`;
}

/** Strips raw DB function-name prefixes from identity record error messages. */
function cleanIdError(msg: string): string {
  return msg
    .replace(/^replace_identity_records:\s*/i, '')
    .replace(/^add_hire_identity_record:\s*/i, '')
    .replace(/^ERROR:\s*/i, '')
    || msg;
}

function fmtDate(val?: string): string {
  if (!val) return '—';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}



// ─────────────────────────────────────────────────────────────────────────────
// Progress Tracker
// ─────────────────────────────────────────────────────────────────────────────
function ProgressTracker({ activeSection, completedSections, onJump, baseAllDone }: {
  activeSection: string;
  completedSections: Set<string>;
  onJump: (id: string) => void;
  baseAllDone: boolean;
}) {
  return (
    <div className="emp-form-progress">
      {SECTIONS.map((s, i) => {
        const isActive    = s.id === activeSection;
        const isCompleted = completedSections.has(s.id);
        const BASE_IDS = ['personal', 'contact', 'email', 'employment'];
        const isLocked = !baseAllDone && !BASE_IDS.includes(s.id);
        return (
          <div key={s.id} style={{ display: 'flex', alignItems: 'center' }}>
            <div
              className={`efp-step ${isActive ? 'efp-active' : ''} ${isCompleted ? 'efp-done' : ''} ${s.optional ? 'efp-optional' : ''} ${isLocked ? 'efp-locked' : ''}`}
              title={`${s.label}${s.optional ? ' (Optional)' : ''}`}
              onClick={() => onJump(s.id)}
              style={{ cursor: isLocked ? 'not-allowed' : 'pointer' }}
            >
              <div className="efp-icon">
                {isCompleted
                  ? <i className="fa-solid fa-check" />
                  : <i className={`fa-solid ${s.icon}`} />
                }
              </div>
              <span className="efp-label">{s.label}</span>
              {isLocked && (
                <span className="efp-lock-badge">
                  <i className="fa-solid fa-lock" />
                </span>
              )}
            </div>
            {i < SECTIONS.length - 1 && <div className="efp-connector" />}
          </div>
        );
      })}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Inline Error helper
// ─────────────────────────────────────────────────────────────────────────────
function FieldError({ msg }: { msg?: string }) {
  if (!msg) return null;
  return (
    <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
      <i className="fa-solid fa-circle-exclamation" /> {msg}
    </small>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// New Hires Table (Draft / Incomplete)
// ─────────────────────────────────────────────────────────────────────────────
function NewHiresTable({ employees, onContinue, onDelete, picklistVals, departments, currentUserId, canViewAll }: {
  employees: FullEmployee[];
  onContinue: (emp: FullEmployee) => void;
  onDelete: (id: string) => void;
  picklistVals: PicklistValue[];
  departments: { deptId: string; name: string }[];
  currentUserId: string | null;
  canViewAll: boolean;
}) {
  const drafts = employees.filter(e => {
    const isPipeline = e.status === 'Draft' || e.status === 'Incomplete' || e.status === 'Pending' || e.status === 'Rejected';
    if (!isPipeline) return false;
    // Ownership filter for all pipeline statuses — belt-and-suspenders on top of RLS.
    // Note: RLS keeps Pending open so workflow approvers can read via WorkflowReview,
    // but in this table we only show records the current user owns or has view_all
    // permission for. Approvers reach pending hires through ApproverInbox, not here.
    if (canViewAll) return true;
    const createdBy = (e as { createdBy?: string | null }).createdBy;
    // Legacy records (createdBy === null, pre-mig 253) remain visible to all analysts.
    return createdBy == null || createdBy === currentUserId;
  });
  if (drafts.length === 0) return null;

  function resolveLabel(picklistId: string, val?: unknown): string {
    if (!val) return '—';
    const match = picklistVals.find(
      p => p.picklistId === picklistId &&
        (String(p.id) === String(val) || p.refId === String(val))
    );
    return match ? match.value : String(val);
  }

  return (
    <div style={{ marginTop: 32 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
        <h3 style={{ margin: 0, fontSize: 16, fontWeight: 700, color: '#1F2937' }}>
          <i className="fa-solid fa-user-clock" style={{ color: '#F59E0B', marginRight: 8 }} />
          New Hires in Progress
        </h3>
        <span style={{
          background: '#FEF3C7', color: '#92400E', borderRadius: 20,
          padding: '2px 10px', fontSize: 11.5, fontWeight: 600,
        }}>
          {drafts.length} {drafts.length === 1 ? 'record' : 'records'}
        </span>
      </div>
      <div className="table-wrapper">
        <table className="emp-table">
          <thead>
            <tr>
              <th className="emp-th-num">#</th>
              <th>Employee</th>
              <th>Designation</th>
              <th>Department</th>
              <th>Status</th>
              <th>Last Saved</th>
              <th>Action</th>
            </tr>
          </thead>
          <tbody>
            {drafts.map((emp, idx) => {
              const sc = emp.status === 'Draft'
                ? { bg: '#FEF9C3', color: '#92400E' }
                : emp.status === 'Pending'
                  ? { bg: '#DBEAFE', color: '#1E40AF' }
                  : emp.status === 'Rejected'
                    ? { bg: '#FEF2F2', color: '#DC2626' }
                    : { bg: '#FFF7ED', color: '#C2410C' };
              return (
                <tr key={emp.employeeId}>
                  <td className="emp-th-num" style={{ color: '#9CA3AF', fontSize: 12 }}>{idx + 1}</td>
                  <td>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <img
                        src={getAvatar(emp)} alt={emp.name}
                        style={{ width: 32, height: 32, borderRadius: '50%', flexShrink: 0 }}
                      />
                      <div>
                        <div style={{ fontWeight: 600, fontSize: 13, color: '#111827' }}>{emp.name || '(No name)'}</div>
                        <div style={{ fontSize: 11.5, color: '#9CA3AF' }}>{emp.employeeId}</div>
                      </div>
                    </div>
                  </td>
                  <td style={{ fontSize: 13 }}>{resolveLabel('DESIGNATION', emp.designation)}</td>
                  <td style={{ fontSize: 13 }}>{departments.find(d => d.deptId === emp.deptId)?.name || '—'}</td>
                  <td>
                    <span style={{
                      background: sc.bg, color: sc.color,
                      borderRadius: 6, padding: '3px 10px',
                      fontSize: 11.5, fontWeight: 600,
                    }}>{emp.status}</span>
                  </td>
                  <td style={{ fontSize: 12.5, color: '#6B7280' }}>
                    {emp.updatedAt ? fmtDate(String(emp.updatedAt).slice(0, 10)) : '—'}
                  </td>
                  <td>
                    <div className="emp-action-btns" style={{ display: 'flex', gap: 6 }}>
                      {emp.status === 'Pending' ? (
                        /* Pending records are locked — open in read mode only */
                        <button
                          className="btn-edit" title="View (awaiting approval)"
                          style={{ color: '#6B7280' }}
                          onClick={() => onContinue(emp)}
                        >
                          <i className="fa-solid fa-eye" />
                        </button>
                      ) : emp.status === 'Rejected' ? (
                        /* Rejected records — view is read-only; direct to Sent Back inbox */
                        <button
                          className="btn-edit" title="View rejection reason in Sent Back inbox"
                          style={{ color: '#DC2626' }}
                          onClick={() => onContinue(emp)}
                        >
                          <i className="fa-solid fa-eye" />
                        </button>
                      ) : (
                        <>
                          <button
                            className="btn-edit" title="Continue filling"
                            style={{ color: '#2563EB' }}
                            onClick={() => onContinue(emp)}
                          >
                            <i className="fa-solid fa-pen-to-square" />
                          </button>
                          <button
                            className="btn-delete" title="Discard draft"
                            onClick={() => onDelete(emp.employeeId)}
                          >
                            <i className="fa-solid fa-trash" />
                          </button>
                        </>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Component
// ─────────────────────────────────────────────────────────────────────────────
export default function AddEmployee() {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const editId = searchParams.get('edit');
  // mode=edit  → opened by approver via Edit-in-Flight (Update button in WorkflowReview)
  // reviewMode → where to return after saving in edit mode
  const isApproverEditMode = searchParams.get('mode') === 'edit';
  const returnTo = searchParams.get('returnTo');

  // ── Hire Submission Mode ────────────────────────────────────────────────
  // Calls get_hire_submission_mode() which wraps resolve_workflow_for_submission,
  // the exact same logic the backend uses in submit_hire and wf_activate_employee.
  // 'workflow' → show "Submit for Approval"  (workflow is configured)
  // 'direct'   → show "Activate Employee"    (no workflow configured)
  // Using the RPC ensures frontend and backend are always in sync.
  const [hasHireWorkflow,  setHasHireWorkflow]  = useState(false);
  const [hireGateLoading,  setHireGateLoading]  = useState(true);

  // Re-usable fetcher — called on mount AND before Submit/Activate clicks (G-B fix).
  // Prevents stale config from showing the wrong action button after a workflow
  // assignment changes while the form is open.
  const refreshHireMode = async () => {
    try {
      const { data } = await supabase.rpc('get_hire_submission_mode');
      setHasHireWorkflow(data === 'workflow');
    } catch {
      setHasHireWorkflow(false);
    } finally {
      setHireGateLoading(false);
    }
  };

  useEffect(() => { refreshHireMode(); }, []);

  // ── Lock state — mirrors the DB locked column of the loaded employee ────
  // Locked records are read-only until the approver acts on them.
  const [isLocked, setIsLocked] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [submittingForApproval, setSubmittingForApproval] = useState(false);
  const [incompleteSectionsModal, setIncompleteSectionsModal] = useState<string[]>([]);

  // ── Approver return comment (shown when status=Incomplete) ────────────────
  const [returnComment, setReturnComment] = useState<{
    message: string; fromName: string; at: string;
  } | null>(null);

  // ── Optimistic locking — track updated_at of last-loaded employee row ─────
  // useRef instead of useState so the token can be read and written synchronously
  // within a single async function. upsert_employment_info mirrors fields back to
  // the employees table (updating updated_at) before performSave runs — if this
  // were state, the new token wouldn't be visible in the same async call.
  const loadedEmpUpdatedAtRef = useRef<string | null>(null);

  const { user: authUser, isAdmin: isSuperAdmin } = useAuth();
  const { can }                                   = usePermissions();
  // HR Head (view_all_pending) and System Admins can see all pipeline records;
  // regular analysts only see their own.
  const canViewAllPipeline = can('employee_hire.view_all_pending') || isSuperAdmin;

  const { employees: allEmployees, refetch: refetchEmployees } = useEmployees();
  // Bridge to FullEmployee[] for backward-compat usage inside this component
  const employees = allEmployees as unknown as FullEmployee[];
  const { picklistValues: picklistVals } = usePicklistValues();
  const { departments: supabaseDepts }   = useDepartments();
  const { currencies: currencyList }     = useCurrencies();
  // Merge Supabase departments into the shape AddEmployee expects
  const departments = useMemo(
    () => supabaseDepts.map(d => ({ deptId: d.id, name: d.name, headId: undefined as string | undefined })),
    [supabaseDepts]
  );

  // ── Active section & completed tracker ─────────────────────────────────
  const [activeSection, setActiveSection] = useState<string>('personal');
  const [completed, setCompleted]         = useState<Set<string>>(new Set());
  const [errors, setErrors]               = useState<Record<string, string>>({});

  // ── Photo ───────────────────────────────────────────────────────────────
  const [photo, setPhoto] = useState<string>('');
  const photoRef         = useRef<HTMLInputElement>(null);

  // ── Editing state ───────────────────────────────────────────────────────
  const [editingEmpId,    setEditingEmpId]    = useState<string | null>(null);
  // Status of the employee loaded into the form ('Draft', 'Incomplete',
  // 'Pending', 'Active', …). null = brand-new record not yet saved.
  // Used to pick the correct action button: Submit for Approval (hire pipeline)
  // vs Activate Employee (direct path when no workflow is configured).
  const [loadedEmpStatus, setLoadedEmpStatus] = useState<string | null>(null);
  // DB UUID of the employee currently being added/edited — used to exclude
  // them from the Manager dropdown even when empId doesn't match their record.
  const [currentEmpUUID, setCurrentEmpUUID] = useState<string | null>(null);

  // Ref to bank form's save fn — called before submit/save-draft in new hire mode
  const bankSaveTriggerRef = useRef<(() => Promise<boolean>) | null>(null);
  // Ref to dependents form's save fn — called before submit/save-draft in new hire mode
  const depSaveTriggerRef = useRef<(() => Promise<boolean>) | null>(null);
  const eduSaveTriggerRef = useRef<(() => Promise<boolean>) | null>(null);

  // ── Section 1: Personal ─────────────────────────────────────────────────
  const [firstName,      setFirstName]      = useState('');
  const [middleName,     setMiddleName]     = useState('');
  const [lastName,       setLastName]       = useState('');
  const [empId,          setEmpId]          = useState('');
  const [nationality,    setNationality]    = useState('');
  const [maritalStatus,  setMaritalStatus]  = useState('');
  const [gender,         setGender]         = useState('');
  const [dob,            setDob]            = useState('');

  // ── Section 2: Contact ──────────────────────────────────────────────────
  const [countryCode, setCountryCode] = useState('+91');
  const [mobile,      setMobile]      = useState('');

  // ── Section 3: Email ────────────────────────────────────────────────────
  const [businessEmail, setBusinessEmail] = useState('');
  const [personalEmail, setPersonalEmail] = useState('');

  // ── Section 4: Passport ─────────────────────────────────────────────────
  const [passportCountry,   setPassportCountry]   = useState('');
  const [passportNumber,    setPassportNumber]     = useState('');
  const [passportIssueDate, setPassportIssueDate] = useState('');
  const [passportExpiry,    setPassportExpiry]     = useState('');
  const [passportCountryPending, setPassportCountryPending] = useState<string | null>(null);

  // ── Section 5: Identity ─────────────────────────────────────────────────
  const [idRecords,    setIdRecords]    = useState<IdRecord[]>([]);
  const [idCountry,    setIdCountry]    = useState('');
  const [idType,       setIdType]       = useState('');
  const [idRecordType, setIdRecordType] = useState('');
  const [idNumber,     setIdNumber]     = useState('');
  const [idExpiry,     setIdExpiry]     = useState('');
  const [idCountryPending, setIdCountryPending] = useState<string | null>(null);

  // ── Section 6: Employment ───────────────────────────────────────────────
  const [designation,    setDesignation]    = useState('');
  const [deptId,         setDeptId]         = useState('');
  const [managerId,      setManagerId]      = useState('');
  const [managerSearch,  setManagerSearch]  = useState('');
  const [managerOpen,    setManagerOpen]    = useState(false);
  const [hireDate,       setHireDate]       = useState('');
  const [endDate,        setEndDate]        = useState('9999-12-31');
  const [probationEnd,   setProbationEnd]   = useState('');
  const [workCountry,    setWorkCountry]    = useState('');
  const [workLocation,   setWorkLocation]   = useState('');
  const [baseCurrency,   setBaseCurrency]   = useState('');

  // ── Section 7: Address ──────────────────────────────────────────────────
  const [addrLine1,    setAddrLine1]    = useState('');
  const [addrLine2,    setAddrLine2]    = useState('');
  const [addrLandmark, setAddrLandmark] = useState('');
  const [addrCity,     setAddrCity]     = useState('');
  const [addrDistrict, setAddrDistrict] = useState('');
  const [addrState,    setAddrState]    = useState('');
  const [addrPin,      setAddrPin]      = useState('');
  const [addrCountry,  setAddrCountry]  = useState('');

  // ── Section 8: Emergency ────────────────────────────────────────────────
  const [ecName,     setEcName]     = useState('');
  const [ecRel,      setEcRel]      = useState('');
  const [ecPhone,    setEcPhone]    = useState('');
  const [ecAltPhone, setEcAltPhone] = useState('');
  const [ecEmail,    setEcEmail]    = useState('');

  // ── Section 9: Bank ──────────────────────────────────────────────────────
  // BankAccountsPortlet manages its own data; we just track whether ≥1 account saved
  const [bankSectionDone,       setBankSectionDone]       = useState(false);
  // ── Section 10 & 11: Education / Dependents (optional portlets) ──────────
  // Driven by onRecordCountChange — true only when portlet confirms ≥1 live record
  const [educationHasRecords,   setEducationHasRecords]   = useState(false);
  const [dependentsHasRecords,  setDependentsHasRecords]  = useState(false);

  // ── Delete confirmation ─────────────────────────────────────────────────
  const [deletingId, setDeletingId] = useState<string | null>(null);

  // ── Cancel & Exit confirmation modal ────────────────────────────────────
  const [exitModal, setExitModal] = useState(false);
  const [gateMsg, setGateMsg] = useState(false);

  // ── Toast notification ───────────────────────────────────────────────────
  const [toast, setToast] = useState<{ message: string; type: 'success' | 'error' } | null>(null);

  // ── Info / success modal (replaces browser alert) ───────────────────────
  const [infoModal, setInfoModal] = useState<{
    open: boolean; title: string; message: string; type: 'success' | 'info' | 'warning';
  }>({ open: false, title: '', message: '', type: 'success' });

  // ── Probation 180-day warning modal ─────────────────────────────────────
  const [probationWarning, setProbationWarning] = useState<{
    open: boolean; pendingDate: string;
  }>({ open: false, pendingDate: '' });

  // ── Delete-primary-with-secondary modal ──────────────────────────────────
  // Fires when user deletes the primary ID record while a secondary exists.
  // On confirm: auto-demotes secondary → primary, removes the deleted primary.
  const [deletePrimaryModal, setDeletePrimaryModal] = useState<{ open: boolean; index: number }>({ open: false, index: -1 });

  // ── Duplicate business-email modal ───────────────────────────────────────
  // type 'block'  → Active / Pending / Inactive  (hard block, single OK button)
  // type 'warn'   → Draft / Incomplete           (soft warn, View existing + Continue)
  const [dupEmailModal, setDupEmailModal] = useState<{
    open: boolean;
    type: 'block' | 'warn';
    title: string;
    message: string;
    existingId: string;
  }>({ open: false, type: 'block', title: '', message: '', existingId: '' });

  // ── Picklist helpers ────────────────────────────────────────────────────
  const designations = useMemo(
    () => picklistVals.filter(p => p.picklistId === 'DESIGNATION'),
    [picklistVals]
  );
  const relationships = useMemo(
    () => picklistVals.filter(p => p.picklistId === 'RELATIONSHIP_TYPE' && p.active !== false)
          .sort((a, b) => a.value.localeCompare(b.value)),
    [picklistVals]
  );
  // Use the real currencies table so baseCurrency holds currencies.id (FK target)
  const currencies = currencyList;
  const idCountries = useMemo(
    () => picklistVals.filter(p => p.picklistId === 'ID_COUNTRY' && p.active !== false)
          .sort((a, b) => a.value.localeCompare(b.value)),
    [picklistVals]
  );
  const idTypes = useMemo(
    () => idCountry
      ? picklistVals.filter(p => p.picklistId === 'ID_TYPE' && String(p.parentValueId) === idCountry && p.active !== false)
          .sort((a, b) => a.value.localeCompare(b.value))
      : [],
    [picklistVals, idCountry]
  );
  const workLocations = useMemo(
    () => workCountry
      ? picklistVals.filter(p => p.picklistId === 'LOCATION' && String(p.parentValueId) === workCountry && p.active !== false)
          .sort((a, b) => a.value.localeCompare(b.value))
      : [],
    [picklistVals, workCountry]
  );

  // Auto-default Base Currency from the selected country's meta.currencyId.
  // meta.currencyId is a picklist_values.id for the CURRENCY picklist entry.
  // We translate → currencies.id (FK target) by matching on currency name.
  useEffect(() => {
    if (!workCountry || currencyList.length === 0) return;
    const country = idCountries.find(c => String(c.id) === workCountry);
    const plCurrId = (country as { meta?: Record<string, string> })?.meta?.currencyId;
    if (!plCurrId) return;
    const plCurr = picklistVals.find(p => p.picklistId === 'CURRENCY' && String(p.id) === plCurrId);
    if (!plCurr) return;
    const realCurr = currencyList.find(c => c.name === plCurr.value);
    if (realCurr) setBaseCurrency(realCurr.id);
  }, [workCountry, currencyList]); // eslint-disable-line react-hooks/exhaustive-deps

  // Auto-default Probation End Date to Hire Date + 3 months whenever Hire Date changes
  useEffect(() => {
    if (!hireDate) return;
    const hire = new Date(hireDate);
    hire.setMonth(hire.getMonth() + 3);
    setProbationEnd(hire.toISOString().split('T')[0]);
    setErrors(p => ({ ...p, probationEnd: '' }));
  }, [hireDate]); // eslint-disable-line react-hooks/exhaustive-deps

  // Helper: resolve a picklist ID to its display label
  function plLabel(picklistId: string, id: string): string {
    if (!id) return '—';
    const match = picklistVals.find(p => p.picklistId === picklistId && String(p.id) === id);
    return match ? match.value : id;
  }

  function calcAge(dobStr: string): number | null {
    if (!dobStr) return null;
    const birth = new Date(dobStr);
    if (isNaN(birth.getTime())) return null;
    const today = new Date();
    let age = today.getFullYear() - birth.getFullYear();
    const m = today.getMonth() - birth.getMonth();
    if (m < 0 || (m === 0 && today.getDate() < birth.getDate())) age--;
    return age;
  }

  // ── Manager list: Active + Inactive employees, excluding the current employee
  // Includes Inactive so employees on leave / ex-managers can still be selected.
  // Excludes Draft/Incomplete (not fully set up yet).
  // Self-exclusion: by UUID (most reliable), by empId code, and by editingEmpId.
  const managers = useMemo(
    () => employees.filter(e => {
      if (e.status === 'Draft' || e.status === 'Incomplete' || e.status === 'Pending') return false;
      if (currentEmpUUID && (e as unknown as { id: string }).id === currentEmpUUID) return false;
      if (editingEmpId && e.employeeId === editingEmpId) return false;
      if (empId.trim() && e.employeeId === empId.trim()) return false;
      return true;
    }),
    [employees, editingEmpId, empId, currentEmpUUID]
  );

  // ── Load employee into form when editId param changes ───────────────────
  function loadEmployee(emp: FullEmployee) {
    setEditingEmpId(emp.employeeId);
    setLoadedEmpStatus(emp.status ?? null);
    loadedEmpUpdatedAtRef.current = (emp as any).updatedAt ?? null;
    setReturnComment(null); // cleared on each load; fetched below if Incomplete
    const empUUID = (emp as unknown as { id: string }).id || null;
    setCurrentEmpUUID(empUUID);
    setPhoto(emp.photo || '');
    setFirstName((emp as any).firstName || '');
    setMiddleName((emp as any).middleName || '');
    setLastName((emp as any).lastName || '');
    setEmpId(emp.employeeId || '');
    setNationality(emp.nationality || '');
    setMaritalStatus(emp.maritalStatus || '');
    setGender(emp.gender || '');
    setDob(emp.dob || '');
    setCountryCode(emp.countryCode || '+91');
    setMobile(emp.mobile || '');
    setBusinessEmail(emp.businessEmail || '');
    setPersonalEmail(emp.personalEmail || '');
    setPassportCountry(emp.passportCountry || '');
    setPassportNumber(emp.passportNumber || '');
    setPassportIssueDate(emp.passportIssueDate || '');
    setPassportExpiry(emp.passportExpiryDate || '');
    setIdRecords(emp.idRecords || []);
    setDesignation(emp.designation || '');
    setDeptId(emp.deptId || '');
    setManagerId(emp.managerId || '');
    setManagerSearch(emp.managerId ? (employees.find(e => (e as any).id === emp.managerId)?.name ?? '') : '');
    setHireDate(emp.hireDate || '');
    setEndDate(emp.endDate || '9999-12-31');
    setProbationEnd(emp.probationEndDate || '');
    setWorkCountry(emp.workCountry || '');
    setWorkLocation(emp.workLocation || '');
    setBaseCurrency((emp as { baseCurrencyId?: string }).baseCurrencyId || emp.baseCurrency || '');
    setAddrLine1(emp.addrLine1 || '');
    setAddrLine2(emp.addrLine2 || '');
    setAddrLandmark(emp.addrLandmark || '');
    setAddrCity(emp.addrCity || '');
    setAddrDistrict(emp.addrDistrict || '');
    setAddrState(emp.addrState || '');
    setAddrPin(emp.addrPin || '');
    setAddrCountry(emp.addrCountry || '');
    setEcName(emp.ecName || '');
    setEcRel(emp.ecRelationship || '');
    setEcPhone(emp.ecPhone || '');
    setEcAltPhone(emp.ecAltPhone || '');
    setEcEmail(emp.ecEmail || '');
    // Reflect lock state from the loaded employee (locked col now mapped in useEmployees)
    setIsLocked(emp.locked ?? false);

    setErrors({});
    setActiveSection('personal');

    // Derive completed sections entirely from live satellite data.
    // _completedSections was a phantom field (never persisted to DB) — removed.
    // Every section is checked against actual data below; no seed needed.
    const done = new Set<string>();
    // Data-based checks ensure required sections reflect actual data.
    // Use firstName (from employee_personal satellite) not emp.name (always set on employees master).
    // This prevents a false-positive tick when employee_personal has no row yet.
    if ((emp as any).firstName && emp.employeeId) done.add('personal'); else done.delete('personal');
    if (emp.mobile) done.add('contact');                     else done.delete('contact');
    if (emp.businessEmail && emp.personalEmail) done.add('email'); else done.delete('email');
    if (emp.designation && emp.deptId && emp.hireDate && emp.probationEndDate && emp.workLocation) done.add('employment'); else done.delete('employment');
    if (emp.addrLine1 && emp.addrCity && emp.addrPin && emp.addrCountry) done.add('address'); else done.delete('address');
    if (emp.ecName && emp.ecPhone) done.add('emergency');    else done.delete('emergency');
    // Optional sections: tick ONLY if actual data present (ignore stale persisted state)
    if (emp.idRecords?.length) done.add('identity'); else done.delete('identity');
    if (emp.passportNumber)    done.add('passport');  else done.delete('passport');
    setCompleted(done);

    // Load extended data (passport, addresses, emergency, identity records) from DB.
    // useEmployees only fetches the employees table — extended tables must be fetched separately.
    if (empUUID) loadExtendedData(empUUID);

    // Load approver return comment when status=Incomplete.
    // Primary: vw_wf_my_requests (scoped to submitted_by = auth.uid()).
    // Fallback: direct workflow_instances + workflow_action_log query for HR Heads
    //   who have view_all_pending and are viewing someone else's hire (G-C fix).
    if (emp.status === 'Incomplete' && empUUID) {
      supabase
        .from('vw_wf_my_requests')
        .select('clarification_message, clarification_from, clarification_at')
        .eq('record_id', empUUID)
        .eq('status', 'awaiting_clarification')
        .order('clarification_at', { ascending: false })
        .limit(1)
        .then(async ({ data }) => {
          const row = data?.[0];
          if (row?.clarification_message) {
            setReturnComment({
              message:  row.clarification_message,
              fromName: row.clarification_from ?? 'Approver',
              at:       row.clarification_at ?? '',
            });
            return;
          }

          // Fallback for HR Heads viewing a hire they did not submit themselves.
          // workflow_instances RLS allows wf_manage.view users to see all instances.
          if (!canViewAllPipeline) return;

          const { data: instances } = await supabase
            .from('workflow_instances')
            .select('id')
            .eq('module_code', 'employee_hire')
            .eq('record_id', empUUID)
            .eq('status', 'awaiting_clarification')
            .order('created_at', { ascending: false })
            .limit(1);

          const instanceId = instances?.[0]?.id;
          if (!instanceId) return;

          const { data: logRows } = await supabase
            .from('workflow_action_log')
            .select('notes, created_at, profiles!actor_id(name, employees!employee_id(name))')
            .eq('instance_id', instanceId)
            .eq('action', 'returned_to_initiator')
            .order('created_at', { ascending: false })
            .limit(1);

          const logRow = logRows?.[0] as any;
          if (logRow?.notes) {
            const actorEmployee = logRow?.profiles?.employees;
            setReturnComment({
              message:  logRow.notes,
              fromName: actorEmployee?.name ?? logRow?.profiles?.name ?? 'Approver',
              at:       logRow.created_at ?? '',
            });
          }
        });
    }
  }

  useEffect(() => {
    if (editId) {
      // Try EMP-format match first (normal edit flow: ?edit=EMP001).
      // Fall back to UUID match (approver edit-in-flight: ?edit=<uuid>).
      const emp =
        employees.find(e => e.employeeId === editId) ??
        employees.find(e => (e as unknown as { id: string }).id === editId);
      if (emp) {
        loadEmployee(emp); // loadEmployee now also calls loadExtendedData internally
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editId, employees.length]); // employees.length: re-run if hook loads more records

  // ── Fetch a server-assigned employee ID (collision-safe) ─────────────────
  // Calls the generate_employee_id() RPC which increments emp_id_seq atomically.
  // Falls back to the client-side generator if the RPC fails (network error, etc.).
  async function fetchNewEmpId(): Promise<string> {
    const { data, error } = await supabase.rpc('generate_employee_id');
    if (error || !data) {
      console.warn('[fetchNewEmpId] RPC failed, using local fallback:', error);
      return generateEmpId(employees);
    }
    return data as string;
  }

  // ── Reset form ──────────────────────────────────────────────────────────
  function resetForm() {
    setEditingEmpId(null);
    setLoadedEmpStatus(null);
    setCurrentEmpUUID(null);
    loadedEmpUpdatedAtRef.current = null;
    setReturnComment(null);
    setPhoto('');
    // Clear ID first (shows blank briefly), then fetch server-assigned ID async
    setFirstName(''); setMiddleName(''); setLastName(''); setEmpId('');
    fetchNewEmpId().then(id => setEmpId(id));
    setNationality(''); setMaritalStatus(''); setGender(''); setDob('');
    setCountryCode('+91'); setMobile('');
    setBusinessEmail(''); setPersonalEmail('');
    setPassportCountry(''); setPassportNumber(''); setPassportIssueDate(''); setPassportExpiry('');
    setIdRecords([]);
    setDesignation(''); setDeptId(''); setManagerId(''); setManagerSearch(''); setManagerOpen(false);
    setHireDate(''); setEndDate('9999-12-31'); setProbationEnd('');
    setWorkCountry(''); setWorkLocation(''); setBaseCurrency('');
    setAddrLine1(''); setAddrLine2(''); setAddrLandmark(''); setAddrCity('');
    setAddrDistrict(''); setAddrState(''); setAddrPin(''); setAddrCountry('');
    setEcName(''); setEcRel(''); setEcPhone(''); setEcAltPhone(''); setEcEmail('');
    setErrors({});
    setCompleted(new Set());
    setActiveSection('personal');
    setIsLocked(false);
    setSubmittingForApproval(false);
    navigate('/admin/add-employee', { replace: true });
  }

  // ── Utility: brief toast notification ───────────────────────────────────
  function showToast(message: string, type: 'success' | 'error' = 'success') {
    setToast({ message, type });
    setTimeout(() => setToast(null), 3000);
  }

  // ── Utility: detect unsaved changes (lazy, called only at exit time) ────
  function hasUnsavedChanges(): boolean {
    const existing = employees.find(e => e.employeeId === empId.trim());
    if (!existing) return firstName.trim().length > 0; // new employee with content
    return (
      firstName     !== ((existing as any).firstName  || '') ||
      middleName    !== ((existing as any).middleName || '') ||
      lastName      !== ((existing as any).lastName   || '') ||
      nationality   !== (existing.nationality     || '') ||
      maritalStatus !== (existing.maritalStatus   || '') ||
      mobile        !== (existing.mobile          || '') ||
      businessEmail !== (existing.businessEmail   || '') ||
      personalEmail !== (existing.personalEmail   || '') ||
      designation   !== (existing.designation     || '') ||
      deptId        !== (existing.deptId          || '') ||
      managerId     !== (existing.managerId       || '') ||
      hireDate      !== (existing.hireDate        || '') ||
      endDate       !== (existing.endDate         || '9999-12-31') ||
      probationEnd  !== (existing.probationEndDate|| '') ||
      workCountry   !== (existing.workCountry     || '') ||
      workLocation  !== (existing.workLocation    || '') ||
      addrLine1     !== (existing.addrLine1       || '') ||
      addrLine2     !== (existing.addrLine2       || '') ||
      addrCity      !== (existing.addrCity        || '') ||
      addrPin       !== (existing.addrPin         || '') ||
      addrCountry   !== (existing.addrCountry     || '') ||
      ecName        !== (existing.ecName          || '') ||
      ecRel         !== (existing.ecRelationship  || '') ||
      ecPhone       !== (existing.ecPhone         || '')
    );
  }

  // ── Duplicate business-email check (fires on blur) ──────────────────────
  async function checkDuplicateEmail(email: string) {
    const trimmed = email.trim().toLowerCase();
    if (!trimmed || !trimmed.endsWith('@prowessinfotech.co.in')) return;

    const { data } = await supabase
      .from('employees')
      .select('id, name, status')
      .eq('business_email', trimmed)
      .in('status', ['Active', 'Pending', 'Draft', 'Incomplete', 'Inactive'])
      .limit(1)
      .maybeSingle();

    if (!data) return; // no match — all clear

    const { id, name, status } = data as { id: string; name: string; status: string };

    if (status === 'Active') {
      setDupEmailModal({
        open: true, type: 'block', existingId: id,
        title: 'Employee already active',
        message: `${name || 'An employee'} is already active with this email address. A new hire record cannot be created.`,
      });
      setErrors(p => ({ ...p, businessEmail: 'This email belongs to an active employee.' }));
    } else if (status === 'Pending') {
      setDupEmailModal({
        open: true, type: 'block', existingId: id,
        title: 'Hire record pending approval',
        message: `A hire record for ${name || 'this email'} is currently pending approval. A duplicate cannot be created until the existing one is resolved.`,
      });
      setErrors(p => ({ ...p, businessEmail: 'A pending hire record already exists for this email.' }));
    } else if (status === 'Inactive') {
      setDupEmailModal({
        open: true, type: 'block', existingId: id,
        title: 'Former employee email',
        message: `This email belongs to ${name || 'a former employee'} whose record is inactive. For a re-hire, please use a new business email address.`,
      });
      setErrors(p => ({ ...p, businessEmail: 'This email belongs to a former employee — use a new email for re-hire.' }));
    } else if (status === 'Draft') {
      setDupEmailModal({
        open: true, type: 'warn', existingId: id,
        title: 'Existing draft hire form',
        message: `An incomplete hire form for ${name || 'this email'} already exists (Status: Draft). You can open it to continue, or create a new one.`,
      });
    } else if (status === 'Incomplete') {
      setDupEmailModal({
        open: true, type: 'warn', existingId: id,
        title: 'Existing hire record',
        message: `A hire record for ${name || 'this email'} was returned for correction (Status: Incomplete). You can open it to fix and resubmit, or create a new one.`,
      });
    }
  }

  // ── Core manual save (flush + recompute status + toast) ─────────────────
  // Returns the employee UUID on success, null on failure.
  // Callers must use the returned UUID rather than reading currentEmpUUID state
  // because React state updates are async and would still be stale on the same tick.
  // Pass silent=true to suppress the "Draft saved" success toast (used by auto-save on section nav).
  async function performSave(thenExit = false, silent = false): Promise<string | null> {
    const effectiveIdRecords = activeSection === 'identity' ? flushPendingIdRecord() : idRecords;
    const data = collectData(effectiveIdRecords);
    const requiredSections = SECTIONS.filter(s => !s.optional).map(s => s.id);
    const nowCompleted = new Set([...completed, activeSection]);
    if (!effectiveIdRecords.length) nowCompleted.delete('identity');
    if (!passportNumber.trim())     nowCompleted.delete('passport');
    // Bank tick: only if at least one account was confirmed saved this session
    if (bankSectionDone)      nowCompleted.add('bank');       else nowCompleted.delete('bank');
    // Optional portlet ticks: driven by live record count from onRecordCountChange
    if (educationHasRecords)  nowCompleted.add('education');  else nowCompleted.delete('education');
    if (dependentsHasRecords) nowCompleted.add('dependents'); else nowCompleted.delete('dependents');
    setCompleted(nowCompleted);
    const allRequired = requiredSections.every(id => nowCompleted.has(id));
    const status: 'Draft' | 'Incomplete' = allRequired ? 'Incomplete' : 'Draft';

    // Build the DB payload — only core employees table columns.
    // Employment mirror fields (designation, dept_id, manager_id, hire_date,
    // end_date, work_country, work_location, base_currency_id) are now owned by
    // the employee_employment satellite and written via saveExtendedData →
    // upsert_employment_info (mig 352). Do NOT include them here.
    const dbPayload: Record<string, unknown> = {
      employee_id:      data.employeeId,
      name:             data.name,
      business_email:   data.businessEmail || null,
      status,
    };

    const existingRow = allEmployees.find(e => e.employeeId === (editingEmpId || data.employeeId));
    // Also use currentEmpUUID set by autosave in case allEmployees hasn't refreshed yet
    const knownUUID   = currentEmpUUID || existingRow?.id;
    let empUUID: string;

    if (knownUUID) {
      // Optimistic locking: include updated_at in WHERE so a concurrent save is
      // detected rather than silently overwritten (last-write-wins).
      let updateQuery = supabase
        .from('employees')
        .update(dbPayload as any)
        .eq('id', knownUUID);

      if (loadedEmpUpdatedAtRef.current) {
        updateQuery = updateQuery.eq('updated_at', loadedEmpUpdatedAtRef.current) as typeof updateQuery;
      }

      const { data: updated, error: dbErr } = await (updateQuery as any)
        .select('id, updated_at')
        .single();

      if (dbErr) {
        // PGRST116 = 0 rows — row was modified by someone else since we loaded it
        if ((dbErr as any).code === 'PGRST116') {
          showToast(
            'This record was modified by someone else while you were editing. Please reload and re-apply your changes.',
            'error',
          );
        } else {
          showToast(`Save failed: ${dbErr.message}`, 'error');
        }
        return null;
      }

      // Stamp the new updated_at so the next save uses the correct optimistic lock token
      if (updated?.updated_at) loadedEmpUpdatedAtRef.current = updated.updated_at;
      empUUID = knownUUID;
    } else {
      const { data: inserted, error: dbErr } = await supabase
        .from('employees')
        .insert(dbPayload as any)
        .select('id, updated_at')
        .single();
      if (dbErr || !inserted) { showToast(`Save failed: ${dbErr?.message ?? 'unknown error'}`, 'error'); return null; }
      empUUID = inserted.id;
      setCurrentEmpUUID(empUUID);
      if (inserted.updated_at) loadedEmpUpdatedAtRef.current = inserted.updated_at;
    }

    const extErrors = await saveExtendedData(empUUID, data);

    // upsert_employment_info (inside upsert_hire_satellites) mirrors employment
    // fields back to the employees base table, firing trg_employees_updated_at
    // and changing employees.updated_at. Refresh the lock token here so the
    // NEXT performSave / optimistic lock check uses the actual current value.
    {
      const { data: fresh } = await supabase
        .from('employees').select('updated_at').eq('id', empUUID).single();
      if (fresh?.updated_at) loadedEmpUpdatedAtRef.current = fresh.updated_at;
    }

    refetchEmployees();
    if (extErrors.length > 0) {
      if (!silent) setInfoModal({
        open: true,
        title: 'Save Error',
        message: extErrors.map(e => cleanIdError(e)).join('\n'),
        type: 'warning',
      });
    } else {
      if (!silent) showToast('Draft saved', 'success');
    }
    if (thenExit) resetForm();
    return empUUID;   // return UUID so callers don't read stale state
  }

  // ── Refresh optimistic lock token ────────────────────────────────────────
  // Must be called after any satellite save that may mirror fields back to the
  // employees base table (e.g. upsert_employment_info updates employees.updated_at
  // via trigger). If the token is stale when performSave runs, it will see 0 rows
  // and raise a false-positive "modified by someone else" error.
  async function refreshLockToken() {
    const uuid = currentEmpUUID;
    if (!uuid) return;
    const { data } = await supabase
      .from('employees')
      .select('updated_at')
      .eq('id', uuid)
      .single();
    if (data?.updated_at) loadedEmpUpdatedAtRef.current = data.updated_at;
  }

  // ── Cancel & Exit ────────────────────────────────────────────────────────
  function handleCancelExit() {
    // Locked records are read-only — nothing can be changed, so skip the
    // unsaved-changes check and close immediately.
    if (isLocked || !hasUnsavedChanges()) { resetForm(); } else { setExitModal(true); }
  }

  // ── Fetch server-assigned employee ID on initial load (new hire only) ─────
  // Fires once when the component mounts for a fresh hire (no editId/editingEmpId).
  // Uses the generate_employee_id() RPC (backed by emp_id_seq) to guarantee
  // collision-safety across concurrent sessions.
  useEffect(() => {
    if (editId || editingEmpId) return;    // don't overwrite while editing an existing record
    fetchNewEmpId().then(id => {
      setEmpId(prev => {
        // Only set if blank or still showing a prior auto-generated value
        if (!prev || /^EMP[-\d]+$/.test(prev)) return id;
        return prev;
      });
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── Compute effective idRecords, flushing any fully-filled pending form entry ─
  // Returns the new list (may equal idRecords if nothing to flush).
  // Also updates state side-effects so subsequent renders are consistent.
  function flushPendingIdRecord(): IdRecord[] {
    const pendingComplete =
      idCountry && idType && idRecordType && idNumber.trim() && idExpiry;
    if (!pendingComplete) return idRecords;

    // Run same validations as addIdRecord before auto-flushing (including format + expiry future)
    const _countryName = idCountries.find(c => String(c.id) === idCountry)?.value ?? '';
    const _typeName    = picklistVals.find(p => String(p.id) === idType)?.value ?? '';
    const _fmtErr = validateIdentityNumber(_countryName, _typeName, idNumber.trim());
    if (_fmtErr) { setErrors(p => ({ ...p, idNumber: _fmtErr })); return idRecords; }
    if (idExpiry) {
      const _today = new Date().toISOString().slice(0, 10);
      if (idExpiry <= _today) { setErrors(p => ({ ...p, idExpiry: 'Expiry Date must be a future date.' })); return idRecords; }
    }
    if (idRecords.some(r => r.idType === idType)) {
      setErrors(p => ({ ...p, idType: 'This ID type has already been added for this employee.' }));
      return idRecords;
    }
    const duplicate = employees.find(emp => {
      if (emp.employeeId === editingEmpId) return false;
      return emp.idRecords?.some(r => r.idNumber.trim().toLowerCase() === idNumber.trim().toLowerCase());
    });
    if (duplicate) {
      setErrors(p => ({ ...p, idNumber: `This ID number is already registered to employee ${duplicate.name} (${duplicate.employeeId}).` }));
      return idRecords;
    }

    const newRecord: IdRecord = {
      country: idCountry, idType, recordType: idRecordType,
      idNumber: idNumber.trim(), expiry: idExpiry,
    };
    const updated = [...idRecords, newRecord];
    setIdRecords(updated);
    setIdCountry(''); setIdType(''); setIdRecordType('');
    setIdNumber(''); setIdExpiry('');
    setErrors(p => {
      const n = { ...p };
      delete n.idCountry; delete n.idType; delete n.idRecordType;
      delete n.idNumber;  delete n.idExpiry;
      return n;
    });
    return updated;
  }

  // ── Collect current data into object ────────────────────────────────────
  function collectData(idRecordsOverride?: IdRecord[]): Partial<FullEmployee> {
    const fn = firstName.trim();
    const mn = middleName.trim();
    const ln = lastName.trim();
    const computedName = fn && mn && ln ? `${fn} ${mn} ${ln}`
                       : fn && ln       ? `${fn} ${ln}`
                       : fn && mn       ? `${fn} ${mn}`
                       : fn             || '';
    return {
      employeeId: empId.trim(),
      name: computedName,
      firstName: fn,
      middleName: mn || undefined,
      lastName: ln || undefined,
      photo,
      nationality, maritalStatus, gender, dob,
      countryCode, mobile: mobile.trim(),
      businessEmail: businessEmail.trim(),
      personalEmail: personalEmail.trim(),
      passportCountry, passportNumber, passportIssueDate, passportExpiryDate: passportExpiry,
      idRecords: idRecordsOverride ?? idRecords,
      designation, deptId, managerId,
      hireDate, endDate, probationEndDate: probationEnd,
      workCountry, workLocation, baseCurrency,
      addrLine1, addrLine2, addrLandmark, addrCity,
      addrDistrict, addrState, addrPin, addrCountry,
      ecName, ecRelationship: ecRel, ecPhone, ecAltPhone, ecEmail,
    };
  }

  // ── Save extended data to related tables ───────────────────────────────
  // Returns an array of error messages (empty = all succeeded).
  // ── saveExtendedData — single-transaction satellite write (mig 439) ────────
  // All 7 satellite writes are delegated to upsert_hire_satellites(), which
  // executes them in one PL/pgSQL body (one implicit Postgres transaction).
  // A failure in any section rolls back all writes in the call.
  async function saveExtendedData(empUUID: string, data: Partial<FullEmployee>): Promise<string[]> {
    const d = data as any;
    // Effective date = hire date.  If hire date is not yet filled (personal
    // section saved before employment section), pass null so the backend skips
    // the effective-dated writes rather than using today's date and creating a
    // spurious historical slice later when the real hire date is entered.
    const effectiveFrom     = data.hireDate || null;
    const idRecs            = (data.idRecords as IdRecord[] | undefined) ?? [];

    // Sections are passed as JSON null when no meaningful data exists so the
    // RPC's IS NOT NULL guard skips the upsert entirely, preventing spurious
    // all-null rows from being written on early autosaves.
    const personalData = (d.firstName || data.nationality || data.maritalStatus || data.gender || data.dob || data.photo)
      ? { first_name: d.firstName || null, middle_name: d.middleName || null, last_name: d.lastName || null, nationality: data.nationality || null, marital_status: data.maritalStatus || null, gender: data.gender || null, dob: data.dob || null, photo_url: data.photo || null }
      : null;

    const contactData = (data.countryCode || data.mobile || data.personalEmail || data.businessEmail)
      ? { country_code: data.countryCode || null, mobile: data.mobile || null, personal_email: data.personalEmail || null, business_email: data.businessEmail || null }
      : null;

    const employmentData = (data.designation || data.deptId || data.managerId || data.hireDate || data.workCountry || data.workLocation || data.probationEndDate)
      ? { designation: data.designation || null, dept_id: data.deptId || null, manager_id: data.managerId || null, hire_date: data.hireDate || null, end_date: data.endDate || null, work_country: data.workCountry || null, work_location: data.workLocation || null, probation_end_date: data.probationEndDate || null }
      : null;

    const payload = {
      personal:                  personalData,
      personal_effective_from:   effectiveFrom,
      contact:                   contactData,
      employment:                employmentData,
      employment_effective_from: effectiveFrom,
      passport: {
        country:    data.passportCountry    || null,
        number:     data.passportNumber     || null,
        issue_date: data.passportIssueDate  || null,
        expiry:     data.passportExpiryDate || null,
      },
      address: {
        line1:    data.addrLine1    || null,
        line2:    data.addrLine2    || null,
        landmark: data.addrLandmark || null,
        city:     data.addrCity     || null,
        district: data.addrDistrict || null,
        state:    data.addrState    || null,
        pin:      data.addrPin      || null,
        country:  data.addrCountry  || null,
      },
      emergency: {
        name:         data.ecName         || null,
        relationship: data.ecRelationship || null,
        phone:        data.ecPhone        || null,
        alt_phone:    data.ecAltPhone     || null,
        email:        data.ecEmail        || null,
      },
      identity_records: idRecs.map(r => ({
        country:     r.country     || null,
        id_type:     r.idType      || null,
        record_type: r.recordType  || null,
        id_number:   r.idNumber    || null,
        expiry:      r.expiry      || null,
      })),
    };

    const { data: result, error: rpcErr } = await supabase.rpc('upsert_hire_satellites', {
      p_employee_id: empUUID,
      p_data: payload,
    });

    if (rpcErr) {
      console.error('[saveExtendedData] upsert_hire_satellites:', rpcErr);
      return [`Save failed: ${rpcErr.message}`];
    }

    const res = result as { ok: boolean; errors: { section: string; error: string }[] } | null;
    if (!res?.ok && res?.errors?.length) {
      return res.errors.map(e => `${e.section}: ${e.error}`);
    }

    return [];
  }

  // ── Load extended data from related tables into form state ──────────────
  async function loadExtendedData(empUUID: string) {
    const [
      { data: passportRows },
      { data: addrRows },
      { data: ecRows },
      { data: idRows },
      { data: personalRow },
      { data: contactRow },
      { data: employmentRow },
      { data: depRows },
      { data: eduData },
    ] = await Promise.all([
      supabase.from('passports').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('employee_addresses').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('emergency_contacts').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('identity_records').select('*').eq('employee_id', empUUID),
      supabase.rpc('get_current_personal_info', { p_employee_id: empUUID }),
      supabase.from('employee_contact').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('employee_employment').select('*').eq('employee_id', empUUID).limit(1),
      // Set-snapshot model: check employee_dependent_set (Phase 3 migration)
      supabase.from('employee_dependent_set').select('id').eq('employee_id', empUUID).eq('is_active', true).limit(1),
      // Education: count active records
      supabase.rpc('get_employee_education', { p_employee_id: empUUID, p_include_inactive: false }),
    ]);

    // Passport
    const p = passportRows?.[0];
    if (p) {
      setPassportCountry(p.country         || '');
      setPassportNumber( p.passport_number || '');
      setPassportIssueDate(p.issue_date    || '');
      setPassportExpiry(  p.expiry_date    || '');
    }

    // Address
    const a = addrRows?.[0];
    if (a) {
      setAddrLine1(   a.line1    || '');
      setAddrLine2(   a.line2    || '');
      setAddrLandmark(a.landmark || '');
      setAddrCity(    a.city     || '');
      setAddrDistrict(a.district || '');
      setAddrState(   a.state    || '');
      setAddrPin(     a.pin      || '');
      setAddrCountry( a.country  || '');
    }

    // Emergency contact
    const ec = ecRows?.[0];
    if (ec) {
      setEcName( ec.name         || '');
      setEcRel(  ec.relationship || '');
      setEcPhone(ec.phone        || '');
      setEcAltPhone(ec.alt_phone || '');
      setEcEmail(ec.email        || '');
    }

    // Identity records
    if (idRows && idRows.length > 0) {
      setIdRecords(idRows.map(r => ({
        country:    r.country     || '',
        idType:     r.id_type     || '',
        recordType: r.record_type || '',
        idNumber:   r.id_number   || '',
        expiry:     r.expiry      || '',
      })));
    }

    // employee_personal — RPC returns single jsonb object (mig 315 multi-row)
    const pers = personalRow;
    if (pers) {
      if (pers.first_name)  setFirstName(pers.first_name);
      if (pers.middle_name) setMiddleName(pers.middle_name);
      if (pers.last_name)   setLastName(pers.last_name);
      setNationality(  pers.nationality    || '');
      setMaritalStatus(pers.marital_status || '');
      setGender(       pers.gender         || '');
      setDob(          pers.dob            || '');
      setPhoto(        pers.photo_url      || '');
      // Tick the personal section now that we have confirmed data from employee_personal
      if (pers.first_name) setCompleted(prev => new Set([...prev, 'personal']));
    }

    // employee_contact satellite
    const cont = contactRow?.[0];
    if (cont) {
      setCountryCode(  cont.country_code   || '+91');
      setMobile(       cont.mobile         || '');
      setPersonalEmail(cont.personal_email || '');
    }

    // employee_employment satellite — now multi-row; pick the current open slice
    // loadExtendedData reads: .select('*').eq('employee_id', empUUID).limit(1)
    // which is fine for the hire wizard (we only care about probation_end_date here;
    // the 10 main fields are already in state from the form or employees master).
    const emp = employmentRow?.[0];
    if (emp) {
      setProbationEnd(emp.probation_end_date || '');
    }

    // Check bank accounts via set-snapshot RPC (Phase 4+)
    const { data: bankSetData } = await supabase.rpc('get_employee_bank_account_set', { p_employee_id: empUUID });
    const hasBankAccounts  = !!(bankSetData as any)?.items?.length;
    const hasEducation     = !!((eduData as any)?.education?.length);
    const hasDependents    = !!(depRows && depRows.length > 0);

    // Sync portlet-level state flags so performSave guards stay accurate
    setBankSectionDone(hasBankAccounts);
    setEducationHasRecords(hasEducation);
    setDependentsHasRecords(hasDependents);

    // Update completed-section tick marks based on what was actually found in DB.
    setCompleted(prev => {
      const done = new Set(prev);
      // Passport: any data present
      if (p?.passport_number) done.add('passport'); else done.delete('passport');
      // Address: minimum required fields
      if (a?.line1 && a?.city) done.add('address'); else done.delete('address');
      // Emergency contact: minimum required fields
      if (ec?.name && ec?.phone) done.add('emergency'); else done.delete('emergency');
      // Identity: at least one record
      if (idRows && idRows.length > 0) done.add('identity'); else done.delete('identity');
      // Bank: at least one active account
      if (hasBankAccounts)  done.add('bank');       else done.delete('bank');
      // Education: at least one active record
      if (hasEducation)     done.add('education');  else done.delete('education');
      // Dependents: at least one active dependent
      if (hasDependents)    done.add('dependents'); else done.delete('dependents');
      return done;
    });
  }

  // ── Validate section ────────────────────────────────────────────────────
  // preSaved: sections whose portlet save trigger just returned true in the
  // same async call. React state updates (bankSectionDone, etc.) are batched
  // and won't be applied yet — preSaved lets us bypass those specific checks.
  function validateSection(sectionId: string, preSaved?: Set<string>): Record<string, string> {
    const errs: Record<string, string> = {};
    switch (sectionId) {
      case 'personal':
        if (!firstName.trim()) errs.firstName = 'First name is required.';
        if (!lastName.trim())  errs.lastName  = 'Last name is required.';
        if (!empId.trim())     errs.empId     = 'Employee ID is required.';
        if (!nationality)    errs.nationality = 'Nationality is required.';
        if (!maritalStatus)  errs.maritalStatus = 'Marital status is required.';
        if (!gender)         errs.gender = 'Gender is required.';
        if (!dob)            errs.dob = 'Date of birth is required.';
        break;
      case 'contact':
        { const mErr = validateMobile(countryCode, mobile); if (mErr) errs.mobile = mErr; }
        break;
      case 'email':
        if (!businessEmail.trim())
          errs.businessEmail = 'Business email is required.';
        else if (!businessEmail.trim().toLowerCase().endsWith('@prowessinfotech.co.in'))
          errs.businessEmail = 'Must use the company domain: @prowessinfotech.co.in';
        if (!personalEmail.trim())
          errs.personalEmail = 'Personal email is required.';
        else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(personalEmail.trim()))
          errs.personalEmail = 'Enter a valid email address.';
        else if (personalEmail.trim().toLowerCase().includes('@prowessinfotech.co.in'))
          errs.personalEmail = 'Personal email cannot use the company email domain (@prowessinfotech.co.in). Please provide a personal email address.';
        if (businessEmail.trim() && personalEmail.trim() &&
            businessEmail.trim().toLowerCase() === personalEmail.trim().toLowerCase())
          errs.personalEmail = 'Personal email cannot be the same as business email.';
        break;
      case 'passport':
        if (passportCountry) {
          const passCountryName = idCountries.find(c => String(c.id) === passportCountry)?.value ?? '';
          if (!passportNumber.trim()) {
            errs.passportNumber = 'Passport Number is required.';
          } else {
            const numErr = validatePassportNumber(passCountryName, passportNumber);
            if (numErr) errs.passportNumber = numErr;
          }
          if (!passportIssueDate) errs.passportIssueDate = 'Issue Date is required.';
          if (!passportExpiry)    errs.passportExpiry    = 'Expiry Date is required.';
          if (passportIssueDate && passportExpiry) {
            const valErr = validatePassportValidity(passCountryName, passportIssueDate, passportExpiry);
            if (valErr) errs.passportExpiry = valErr;
          }
        }
        break;
      case 'employment':
        if (!designation)   errs.designation   = 'Designation is required.';
        if (!deptId)        errs.deptId        = 'Department is required.';
        if (!hireDate)      errs.hireDate      = 'Hire date is required.';
        if (!probationEnd)  errs.probationEnd  = 'Probation end date is required.';
        if (probationEnd && hireDate && probationEnd < hireDate)
          errs.probationEnd = 'Probation End Date cannot be before Hire Date.';
        if (!workCountry)            errs.workCountry = 'Country of work is required.';
        else if (!baseCurrency)     errs.workCountry = 'No default currency is configured for this country. Ask your administrator to set a Default Currency in Reference Data → ID Country.';
        if (!workLocation)          errs.workLocation = 'Location is required.';
        break;
      case 'address':
        if (!addrLine1.trim()) errs.addrLine1 = 'Address line 1 is required.';
        // addrLine2 is optional
        if (!addrCity.trim())  errs.addrCity  = 'City is required.';
        if (!addrPin.trim())   errs.addrPin   = 'PIN / ZIP code is required.';
        if (!addrCountry)      errs.addrCountry = 'Country is required.';
        break;
      case 'emergency':
        if (!ecName.trim())  errs.ecName  = 'Contact name is required.';
        if (!ecRel)          errs.ecRel   = 'Relationship is required.';
        if (!ecPhone.trim()) errs.ecPhone = 'Phone number is required.';
        break;
      case 'bank':
        // preSaved bypasses this check when the save trigger just returned true
        // in the same async call — React state (bankSectionDone) hasn't flushed yet.
        if (!bankSectionDone && !preSaved?.has('bank')) {
          errs.bank = 'At least one bank account is required.';
        }
        break;
      case 'identity':
        // Surface inline field errors already set by the field-level validator.
        // flushPendingIdRecord() runs the full format check and sets errors.idNumber /
        // errors.idExpiry on failure — we propagate those here so validateSection
        // is the single gate used by handleNext, handleSaveDraft, and saveSection.
        if (errors.idNumber) errs.idNumber = errors.idNumber;
        if (errors.idExpiry) errs.idExpiry = errors.idExpiry;
        break;
      case 'dependents':
        // Dependents is optional — no validation required
        break;
    }
    return errs;
  }

  // ── Save section ─────────────────────────────────────────────────────────
  function saveSection(sectionId: string, preSaved?: Set<string>) {
    const errs = validateSection(sectionId, preSaved);
    if (Object.keys(errs).length > 0) {
      setErrors(errs);
      return false;
    }
    setErrors({});
    // Optional sections: only mark complete when they actually contain data.
    // For identity, also consider a pending-but-complete form entry (user filled fields
    // but hasn't clicked "+ Add ID" yet — flushPendingIdRecord was called just before this).
    const pendingIdFilled = !!(idCountry && idType && idRecordType && idNumber.trim() && idExpiry);
    const optionalDataCheck: Record<string, boolean> = {
      identity: idRecords.length > 0 || pendingIdFilled,
      passport: passportNumber.trim().length > 0,
    };
    const shouldMark = sectionId in optionalDataCheck
      ? optionalDataCheck[sectionId]
      : true;
    if (shouldMark) {
      setCompleted(prev => new Set([...prev, sectionId]));
    } else {
      // Visiting an empty optional section should not add a stale tick
      setCompleted(prev => { const n = new Set(prev); n.delete(sectionId); return n; });
    }
    return true;
  }

  // ── Navigate to next section ─────────────────────────────────────────────
  async function handleNext() {
    if (isSaving || submittingForApproval) return;
    // Auto-commit any fully-filled pending ID form before saving
    if (activeSection === 'identity') flushPendingIdRecord();

    // Portlet save triggers must fire BEFORE validateSection.
    // We also collect which sections were just saved so preSaved can bypass
    // the bankSectionDone/etc. state checks (React batches those updates and
    // they won't be flushed until the next render).
    const preSaved = new Set<string>();
    if (activeSection === 'bank' && bankSaveTriggerRef.current) {
      const bankOk = await bankSaveTriggerRef.current();
      if (!bankOk) return;
      preSaved.add('bank');
    }
    if (activeSection === 'education' && eduSaveTriggerRef.current) {
      const eduOk = await eduSaveTriggerRef.current();
      if (!eduOk) return;
      preSaved.add('education');
    }
    if (activeSection === 'dependents' && depSaveTriggerRef.current) {
      const depOk = await depSaveTriggerRef.current();
      if (!depOk) return;
      preSaved.add('dependents');
    }

    // Refresh token — portlet saves may have updated employees.updated_at via trigger
    if (preSaved.size > 0) await refreshLockToken();

    if (!saveSection(activeSection, preSaved)) return;

    const idx = SECTIONS.findIndex(s => s.id === activeSection);
    if (idx >= SECTIONS.length - 1) return;

    const nextSection = SECTIONS[idx + 1].id;

    // Always save silently on Next so data is never lost between sections.
    // For bank/dependents we additionally require a first name so the portlets
    // can render against a real employee record.
    if ((nextSection === 'education' || nextSection === 'bank' || nextSection === 'dependents') && !firstName.trim()) {
      setErrors({ firstName: 'First name is required before proceeding to bank / dependents.' });
      setActiveSection('personal');
      return;
    }

    await performSave(false, true /* silent */);
    // performSave sets currentEmpUUID via state — portlet will render on next render cycle

    setActiveSection(nextSection);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  // ── Back ─────────────────────────────────────────────────────────────────
  // Save the current portlet (bank/education/dependents) before navigating back
  // so draft changes (attachments, new records) are not lost on unmount.
  async function handleBack() {
    if (isSaving || submittingForApproval) return;
    if (currentSectionIdx <= 0) return;
    setIsSaving(true);
    try {
      if (activeSection === 'bank'       && bankSaveTriggerRef.current) {
        const ok = await bankSaveTriggerRef.current(); if (!ok) return;
      }
      if (activeSection === 'education'  && eduSaveTriggerRef.current)  {
        const ok = await eduSaveTriggerRef.current();  if (!ok) return;
      }
      if (activeSection === 'dependents' && depSaveTriggerRef.current)  {
        const ok = await depSaveTriggerRef.current();  if (!ok) return;
      }
      setActiveSection(SECTIONS[currentSectionIdx - 1].id);
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } finally {
      setIsSaving(false);
    }
  }

  // ── Save as Draft ────────────────────────────────────────────────────────
  async function handleSaveDraft() {
    if (isSaving || submittingForApproval) return;
    setIsSaving(true);
    try {
      // Portlet save triggers must fire BEFORE validateSection.
      // preSaved bypasses state-dependent checks whose updates haven't flushed yet.
      // Auto-commit any fully-filled pending ID form — same as handleNext.
      // Without this, a valid pending entry would be silently discarded on Save Draft.
      if (activeSection === 'identity') flushPendingIdRecord();
      const preSaved = new Set<string>();
      if (bankSaveTriggerRef.current) { const ok = await bankSaveTriggerRef.current(); if (!ok) return; preSaved.add('bank'); }
      if (eduSaveTriggerRef.current)  { const ok = await eduSaveTriggerRef.current();  if (!ok) return; preSaved.add('education'); }
      if (depSaveTriggerRef.current)  { const ok = await depSaveTriggerRef.current();  if (!ok) return; preSaved.add('dependents'); }
      const errs = validateSection(activeSection, preSaved);
      if (Object.keys(errs).length > 0) { setErrors(errs); return; }
      setErrors({});
      // First name is the minimum requirement to save from any section
      if (!firstName.trim()) {
        setErrors({ firstName: 'First name is required to save a draft.' });
        setActiveSection('personal');
        return;
      }
      if (preSaved.size > 0) await refreshLockToken();
      await performSave();
    } finally {
      setIsSaving(false);
    }
  }

  // ── Submit for Approval (workflow path) ─────────────────────────────────
  // Called when a workflow is configured for employee_hire.
  // Saves the latest form data first, then routes to either:
  //   • wf_resubmit  — if there is an existing awaiting_clarification instance
  //                    (sent-back path: resumes the existing workflow thread)
  //   • submit_hire  — otherwise (fresh submission: creates a new instance)
  async function handleSubmitForApproval() {
    // G-B: re-fetch submission mode so stale config can't show the wrong button.
    await refreshHireMode();

    // ── Flush portlet forms BEFORE validation; collect preSaved for state bypass ─
    const preSaved = new Set<string>();
    if (bankSaveTriggerRef.current) { const ok = await bankSaveTriggerRef.current(); if (!ok) return; preSaved.add('bank'); }
    if (eduSaveTriggerRef.current)  { const ok = await eduSaveTriggerRef.current();  if (!ok) return; preSaved.add('education'); }
    if (depSaveTriggerRef.current)  { const ok = await depSaveTriggerRef.current();  if (!ok) return; preSaved.add('dependents'); }

    // ── Save current section (validates + marks complete) ─────────────────
    if (!saveSection(activeSection, preSaved)) return;

    // ── Guard: all required sections must be complete ─────────────────────
    // Include preSaved — portlet trigger results haven't flushed to `completed` state yet
    const effectiveCompleted = new Set([...completed, activeSection, ...preSaved]);
    const missingSections = requiredSectionIds
      .filter(id => !effectiveCompleted.has(id))
      .map(id => SECTIONS.find(s => s.id === id)?.label ?? id);
    if (missingSections.length > 0) {
      setIncompleteSectionsModal(missingSections);
      return;
    }

    // Refresh token after portlet saves (employment mirror updates employees.updated_at)
    if (preSaved.size > 0) await refreshLockToken();

    // Always save first so the DB has the latest field values before submitting.
    const empUUID = await performSave();
    if (!empUUID) return;   // save failed — error toast already shown

    setSubmittingForApproval(true);

    // ── Detect sent-back resubmit ─────────────────────────────────────────
    // If an awaiting_clarification instance exists for this employee+module, we
    // must call wf_resubmit (resumes the existing thread) not submit_hire
    // (which would create a second parallel instance for the same record).
    const { data: existingInst } = await supabase
      .from('workflow_instances')
      .select('id')
      .eq('module_code', 'employee_hire')
      .eq('record_id', empUUID)
      .eq('status', 'awaiting_clarification')
      .maybeSingle();

    let rpcError: { message: string } | null = null;

    if (existingInst?.id) {
      // Sent-back resubmit — resume the existing workflow instance
      const { error } = await supabase.rpc('wf_resubmit', {
        p_instance_id: existingInst.id,
        p_response:    null,
        p_proposed_data: null,
      });
      rpcError = error;
    } else {
      // Fresh submission — create a new workflow instance
      const { error } = await supabase.rpc('submit_hire', { p_employee_id: empUUID });
      rpcError = error;
    }

    setSubmittingForApproval(false);

    if (rpcError) {
      setErrors({ _global: rpcError.message } as Record<string, string>);
      return;
    }

    // Lock the form locally — no edits until returned/rejected
    setIsLocked(true);
    refetchEmployees();
    showToast('Submitted for approval successfully!', 'success');
    setTimeout(() => {
      resetForm();
      navigate('/admin/add-employee');
    }, 1500);
  }

  // ── Save and return to approver review (Edit-in-Flight) ──────────────────
  // Called when the approver has opened the form via the Update button.
  async function handleSaveAndReturn() {
    const errs = validateSection(activeSection);
    if (Object.keys(errs).length > 0) { setErrors(errs); return; }
    setErrors({});

    // G-A: Server-side task ownership check — verify caller holds an active
    // workflow task for this record before applying the approver-mode save.
    // Prevents URL-param bypass (anyone constructing ?mode=edit could otherwise
    // call performSave in approver mode without having an active task).
    if (isApproverEditMode && currentEmpUUID) {
      const { data: taskRows, error: taskErr } = await supabase
        .from('workflow_tasks')
        .select('id, workflow_instances!instance_id(record_id)')
        .eq('assigned_to', (await supabase.auth.getUser()).data.user?.id ?? '')
        .eq('status', 'pending')
        .limit(20);

      const hasActiveTask = !taskErr && (taskRows as any[])?.some(
        (t: any) => t.workflow_instances?.record_id === currentEmpUUID
      );

      if (!hasActiveTask && !isSuperAdmin) {
        showToast(
          'You do not have an active approval task for this record. The save was blocked.',
          'error',
        );
        return;
      }
    }

    if (preSaved.size > 0) await refreshLockToken();
    await performSave();
    if (returnTo) {
      navigate(returnTo);
    } else {
      navigate('/workflow/inbox');
    }
  }

  // ── Activate employee ────────────────────────────────────────────────────
  async function handleActivate() {
    // G-B: re-fetch submission mode — if a workflow was just added, this will
    // flip hasHireWorkflow=true and the server guard will still block the wrong path.
    await refreshHireMode();

    // Flush portlet forms before validation; collect preSaved for state bypass
    const preSaved = new Set<string>();
    if (bankSaveTriggerRef.current) { const ok = await bankSaveTriggerRef.current(); if (!ok) return; preSaved.add('bank'); }
    if (eduSaveTriggerRef.current)  { const ok = await eduSaveTriggerRef.current();  if (!ok) return; preSaved.add('education'); }
    if (depSaveTriggerRef.current)  { const ok = await depSaveTriggerRef.current();  if (!ok) return; preSaved.add('dependents'); }

    // ── Save current section first (same as clicking "Next") ─────────────
    if (!saveSection(activeSection, preSaved)) return;

    // ── Guard: all required sections must be complete ─────────────────────
    // Include preSaved — portlet trigger results haven't flushed to `completed` state yet
    const effectiveCompleted = new Set([...completed, activeSection, ...preSaved]);
    const missingSections = requiredSectionIds
      .filter(id => !effectiveCompleted.has(id))
      .map(id => SECTIONS.find(s => s.id === id)?.label ?? id);
    if (missingSections.length > 0) {
      setIncompleteSectionsModal(missingSections);
      return;
    }

    // Validate all non-optional sections (pass preSaved so bank/edu/dep checks
    // use the trigger result rather than stale React state)
    const allErrors: Record<string, string> = {};
    const requiredSections = SECTIONS.filter(s => !s.optional).map(s => s.id);
    for (const sid of requiredSections) {
      const errs = validateSection(sid, preSaved);
      Object.assign(allErrors, errs);
    }
    if (Object.keys(allErrors).length > 0) {
      setErrors(allErrors);
      const firstBad = requiredSections.find(sid => Object.keys(validateSection(sid, preSaved)).length > 0);
      if (firstBad) setActiveSection(firstBad);
      return;
    }

    // Mark all required sections + current section (emergency) as complete
    const allCompleted = new Set(completed);
    requiredSections.forEach(sid => allCompleted.add(sid));
    allCompleted.add(activeSection);
    setCompleted(allCompleted);

    const data = collectData();
    const existingRow = editingEmpId ? allEmployees.find(e => e.employeeId === editingEmpId) : null;

    // ── Step 1: Save core fields WITHOUT changing status ─────────────────
    // We keep the employee in Draft/Pending so that the hire-pipeline RLS
    // path (migration 220) still applies for satellite saves in Step 2.
    // The status transition to Active is handled by wf_activate_employee
    // (SECURITY DEFINER) in Step 3, which bypasses RLS entirely.
    // Only core employees columns. Employment mirror fields (designation, dept_id,
    // manager_id, hire_date, end_date, work_country, work_location, base_currency_id)
    // are written by Step 2 saveExtendedData → upsert_employment_info (mig 352),
    // which also mirrors them back to employees. Do NOT duplicate here.
    const corePayload: Record<string, unknown> = {
      employee_id:    data.employeeId,
      name:           data.name,
      business_email: data.businessEmail || null,
      // status intentionally omitted — stays as Draft/Incomplete/Pending
    };

    let empUUID: string | null = null;
    if (existingRow) {
      // Update core fields — include optimistic lock to detect concurrent edits
      let upd = supabase.from('employees').update(corePayload as any).eq('id', existingRow.id);
      if (loadedEmpUpdatedAtRef.current) upd = upd.eq('updated_at', loadedEmpUpdatedAtRef.current) as typeof upd;
      const { data: updRow, error } = await (upd as any).select('id, updated_at').single();
      if (error) {
        if ((error as any).code === 'PGRST116') {
          showToast('This record was modified by someone else. Please reload and re-apply your changes.', 'error');
        } else {
          setErrors({ _global: error.message } as Record<string, string>);
        }
        return;
      }
      if (updRow?.updated_at) loadedEmpUpdatedAtRef.current = updRow.updated_at;
      empUUID = existingRow.id;
    } else {
      // Insert as Draft so the hire-pipeline RLS path covers satellite saves
      const { data: inserted, error } = await supabase
        .from('employees')
        .insert({ ...corePayload, status: 'Draft' } as any)
        .select('id, updated_at')
        .single();
      if (error || !inserted) { setErrors({ _global: error?.message ?? 'Insert failed' } as Record<string, string>); return; }
      empUUID = inserted.id;
      if (inserted.updated_at) loadedEmpUpdatedAtRef.current = inserted.updated_at;
    }

    // ── Step 2: Save non-portlet satellites (portlet triggers already saved
    // bank/education/dependents above; saveExtendedData covers personal,
    // contact, employment, passport, address, emergency, identity).
    // refreshLockToken keeps the optimistic lock token current after the
    // employment mirror may have updated employees.updated_at.
    if (preSaved.size > 0) await refreshLockToken();
    const extErrors = await saveExtendedData(empUUID!, data);
    if (extErrors.length > 0) {
      console.error('[handleActivate] extended data errors:', extErrors);
      showToast(`Save failed before activation: ${extErrors[0]}`, 'error');
      return;
    }

    // ── Step 3: Activate via SECURITY DEFINER RPC ─────────────────────────
    // wf_activate_employee sets status=Active, locked=false, records the
    // invite attempt in employee_invites, and stamps invite_sent_at.
    // It runs as the postgres role so RLS does not apply.
    const { error: activateError } = await supabase.rpc(
      'wf_activate_employee',
      { p_employee_id: empUUID! }
    );
    if (activateError) {
      setErrors({ _global: activateError.message } as Record<string, string>);
      return;
    }

    // ── Step 4: Send welcome email + link profile → employee ──────────────
    // The invite record and invite_sent_at stamp are already handled by the
    // RPC above. We only need to trigger the auth OTP and link the profile.
    const businessEmail = (data.businessEmail ?? '').trim();
    if (businessEmail) {
      // 1. Send the welcome / magic-link email via Supabase Auth.
      const { error: otpError } = await supabase.auth.signInWithOtp({
        email: businessEmail,
        options: {
          shouldCreateUser: true,
          emailRedirectTo: `${window.location.origin}/reset-password`,
          data: { full_name: data.name },
        },
      });

      if (otpError) {
        // G-D fix: mark the employee_invites row as failed so the audit trail
        // reflects actual delivery. Same pattern as EmployeeDetails.tsx resend path.
        await supabase.rpc('mark_invite_failed', {
          p_employee_id: empUUID!,
          p_error:       otpError.message,
        });
        setInfoModal({
          open: true,
          type: 'warning',
          title: 'Invite Email Not Sent',
          message: `The employee was activated successfully, but the welcome email could not be sent.\n\nReason: ${otpError.message}\n\nThe employee can still sign in by requesting a magic link from the login page.`,
        });
      } else {
        // 2. Link the auth profile → employee + grant ESS.
        const { data: rpcData, error: rpcError } = await supabase.rpc(
          'link_profile_to_employee',
          { p_email: businessEmail }
        );
        const linkReason = (rpcData as { ok?: boolean; reason?: string } | null)?.reason ?? '';
        const isExpected = linkReason.includes('auth user not found');
        if (rpcError || (!isExpected && linkReason && !(rpcData as { ok?: boolean })?.ok)) {
          const detail = rpcError?.message ?? linkReason;
          setInfoModal({
            open: true,
            type: 'warning',
            title: 'Profile Link Issue',
            message: `The employee was activated and the welcome email was sent, but linking the auth profile failed.\n\nReason: ${detail}\n\nThis will resolve automatically when the employee first signs in.`,
          });
        } else {
          showToast('Employee activated and welcome email sent!', 'success');
        }
      }
    } else {
      showToast('Employee activated (no email address — invite not sent).', 'warning');
    }

    refetchEmployees();
    resetForm();
    navigate('/admin/employee-details');
  }

  // ── Jump to section ──────────────────────────────────────────────────────
  function jumpToSection(id: string) {
    const BASE_IDS = ['personal', 'contact', 'email', 'employment'];
    const isLocked = !baseAllDone && !BASE_IDS.includes(id);
    if (isLocked) {
      setGateMsg(true);
      setTimeout(() => setGateMsg(false), 3500);
      return;
    }
    setGateMsg(false);
    setActiveSection(id);
    setErrors({});
  }

  // ── Probation date change handler ────────────────────────────────────────
  function handleProbationChange(newDate: string) {
    // Hard constraint: cannot be before hire date
    if (hireDate && newDate && newDate < hireDate) {
      setProbationEnd(newDate);
      setErrors(p => ({ ...p, probationEnd: 'Probation End Date cannot be before Hire Date.' }));
      return;
    }
    setErrors(p => ({ ...p, probationEnd: '' }));

    // Soft warning: exceeds 180 days from hire date
    if (hireDate && newDate) {
      const hire     = new Date(hireDate);
      const probation = new Date(newDate);
      const diffDays = Math.round((probation.getTime() - hire.getTime()) / (1000 * 60 * 60 * 24));
      if (diffDays > 180) {
        setProbationWarning({ open: true, pendingDate: newDate });
        return; // Hold — let modal decide whether to apply
      }
    }
    setProbationEnd(newDate);
  }

  // ── Immediately persist identity records to DB (used by add + remove) ────
  // Uses the replace_identity_records RPC (mig 437) — a single SECURITY DEFINER
  // transaction that deletes all existing records then inserts the new set.
  // Previously used direct DELETE + INSERT which had no transaction boundary,
  // causing data loss on network failure between the two calls.
  async function saveIdentityNow(records: IdRecord[]) {
    const uuid = currentEmpUUID || allEmployees.find(e => e.employeeId === (editingEmpId || empId.trim()))?.id;
    if (!uuid) {
      showToast('Please save the form first (Save Draft) before adding identity records', 'error');
      return;
    }
    const payload = records.map(r => ({
      country:      r.country     || null,
      id_type:      r.idType      || null,
      record_type:  r.recordType  || null,
      id_number:    r.idNumber    || null,
      expiry:       r.expiry      || null,
    }));
    const { error: rpcErr } = await supabase.rpc('replace_identity_records', {
      p_employee_id: uuid,
      p_records:     payload,
    });
    if (rpcErr) {
      console.error('[saveIdentityNow] replace_identity_records:', rpcErr);
      setInfoModal({
        open: true,
        title: 'Identity Record Error',
        message: cleanIdError(rpcErr.message),
        type: 'warning',
      });
      return;
    }
    showToast(records.length > 0 ? 'ID record saved' : 'ID record removed', 'success');
  }

  // ── Add ID record ────────────────────────────────────────────────────────
  async function addIdRecord() {
    const errs: Record<string, string> = {};
    if (!idCountry) errs.idCountry = 'Country is required.';
    if (!idType)    errs.idType    = 'ID Type is required.';
    // When ID Type is selected, Record Type, ID Number and Expiry become mandatory
    if (idType && !idRecordType)    errs.idRecordType = 'Record Type is required.';
    if (idType && !idNumber.trim()) errs.idNumber     = 'ID Number is required.';
    if (idType && !idExpiry)        errs.idExpiry     = 'Expiry Date is required.';
    // Format validation
    if (idType && idNumber.trim()) {
      const countryName = idCountries.find(c => String(c.id) === idCountry)?.value ?? '';
      const typeName    = picklistVals.find(p => String(p.id) === idType)?.value ?? '';
      const fmtErr = validateIdentityNumber(countryName, typeName, idNumber.trim());
      if (fmtErr) errs.idNumber = fmtErr;
    }
    // Expiry must be a future date
    if (idExpiry) {
      const today = new Date().toISOString().slice(0, 10);
      if (idExpiry <= today) errs.idExpiry = 'Expiry Date must be a future date.';
    }
    if (Object.keys(errs).length > 0) { setErrors(errs); return; }

    // Only one Primary ID allowed per employee
    if (idRecordType === 'primary' && idRecords.some(r => r.recordType === 'primary')) {
      setErrors({ idRecordType: 'A Primary ID already exists. Only one Primary ID is allowed per employee.' });
      return;
    }

    // Same ID type cannot be added twice for the same employee
    if (idRecords.some(r => r.idType === idType)) {
      setErrors({ idType: 'This ID type has already been added for this employee.' });
      return;
    }

    // ID number must be unique across all employees (excluding current employee being edited)
    const duplicate = employees.find(emp => {
      if (emp.employeeId === editingEmpId) return false; // skip self
      return emp.idRecords?.some(r => r.idNumber.trim().toLowerCase() === idNumber.trim().toLowerCase());
    });
    if (duplicate) {
      setErrors({ idNumber: `This ID number is already registered to employee ${duplicate.name} (${duplicate.employeeId}).` });
      return;
    }

    const newRecord = { country: idCountry, idType, recordType: idRecordType, idNumber: idNumber.trim(), expiry: idExpiry };
    const newRecords = [...idRecords, newRecord];

    setIdRecords(newRecords);
    setIdCountry(''); setIdType(''); setIdRecordType('');
    setIdNumber(''); setIdExpiry('');
    setErrors({});

    // Immediately write to DB — don't wait for the debounce
    await saveIdentityNow(newRecords);
  }

  // ── Photo upload ─────────────────────────────────────────────────────────
  function handlePhotoUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = ev => setPhoto(ev.target!.result as string);
    reader.readAsDataURL(file);
    e.target.value = '';
  }

  // ── Delete draft ─────────────────────────────────────────────────────────
  function confirmDelete(id: string) { setDeletingId(id); }
  async function doDelete() {
    if (!deletingId) return;
    const deletedRow = allEmployees.find(e => e.employeeId === deletingId);
    if (deletedRow) {
      await supabase
        .from('employees')
        .update({ deleted_at: new Date().toISOString() } as any)
        .eq('id', deletedRow.id);
      refetchEmployees();
    }
    if (editingEmpId === deletingId) resetForm();
    setDeletingId(null);
  }

  // ── Determine if all required sections are complete ──────────────────────
  const requiredSectionIds  = useMemo(() => SECTIONS.filter(s => !s.optional).map(s => s.id), []);
  const requiredTotal       = requiredSectionIds.length;
  const requiredDoneCount   = useMemo(
    () => requiredSectionIds.filter(id => completed.has(id)).length,
    [completed, requiredSectionIds]
  );
  const allRequiredDone = requiredDoneCount === requiredTotal;

  const baseSectionIds  = useMemo(() => ['personal', 'contact', 'email', 'employment'], []);
  const baseAllDone     = baseSectionIds.every(id => completed.has(id));

  const currentSectionIdx = SECTIONS.findIndex(s => s.id === activeSection);
  const isLastSection = currentSectionIdx === SECTIONS.length - 1;

  // ─────────────────────────────────────────────────────────────────────────
  // Render section body
  // ─────────────────────────────────────────────────────────────────────────
  function renderSection() {
    switch (activeSection) {

      // ── Personal ──────────────────────────────────────────────────────────
      case 'personal': return (
        <div className="emp-section">
          <div className="emp-section-label"><i className="fa-solid fa-circle-user" /> Personal Information</div>
          <div className="emp-field-grid emp-grid-4">
            <div className={`form-group ${errors.firstName ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-user fa-fw" /> First Name</label>
              <input type="text" value={firstName} onChange={e => setFirstName(e.target.value)}
                placeholder="e.g. Vijey" required />
              <FieldError msg={errors.firstName} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-user fa-fw" /> Middle Name</label>
              <input type="text" value={middleName} onChange={e => setMiddleName(e.target.value)}
                placeholder="Middle name (optional)" />
            </div>
            <div className={`form-group ${errors.lastName ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-user fa-fw" /> Last Name</label>
              <input type="text" value={lastName} onChange={e => setLastName(e.target.value)}
                placeholder="e.g. Ananthan" required />
              <FieldError msg={errors.lastName} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-id-badge fa-fw" /> Full Name <span style={{ fontSize: 11, color: '#9CA3AF', fontWeight: 400 }}>(auto-computed)</span></label>
              <input
                type="text"
                readOnly
                tabIndex={-1}
                value={(() => {
                  const f = firstName.trim();
                  const m = middleName.trim();
                  const l = lastName.trim();
                  return f && m && l ? `${f} ${m} ${l}`
                       : f && l       ? `${f} ${l}`
                       : f && m       ? `${f} ${m}`
                       : f            || '';
                })()}
                style={{ background: '#F9FAFB', color: '#6B7280', cursor: 'not-allowed' }}
              />
            </div>
            <div className={`form-group ${errors.empId ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-id-card fa-fw" /> Employee ID</label>
              <input type="text" value={empId} onChange={e => setEmpId(e.target.value)}
                placeholder="e.g. EMP001" required />
              <FieldError msg={errors.empId} />
            </div>
            <div className={`form-group ${errors.nationality ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-flag fa-fw" /> Nationality</label>
              <select value={nationality} onChange={e => setNationality(e.target.value)} required>
                <option value="">-- Select --</option>
                {COUNTRIES.map(c => <option key={c} value={c}>{c}</option>)}
              </select>
              <FieldError msg={errors.nationality} />
            </div>
            <div className={`form-group ${errors.maritalStatus ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-heart fa-fw" /> Marital Status</label>
              <select value={maritalStatus} onChange={e => setMaritalStatus(e.target.value)} required>
                <option value="">-- Select --</option>
                {picklistVals.filter(p => p.picklistId === 'MARITAL_STATUS').map(p => (
                  <option key={String(p.id)} value={String(p.id)}>{p.value}</option>
                ))}
                {!picklistVals.some(p => p.picklistId === 'MARITAL_STATUS') && (
                  <>
                    <option value="single">Single</option>
                    <option value="married">Married</option>
                    <option value="divorced">Divorced</option>
                    <option value="widowed">Widowed</option>
                  </>
                )}
              </select>
              <FieldError msg={errors.maritalStatus} />
            </div>
            <div className={`form-group ${errors.gender ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-venus-mars fa-fw" /> Gender</label>
              <select value={gender} onChange={e => setGender(e.target.value)} required>
                <option value="">-- Select --</option>
                <option value="Male">Male</option>
                <option value="Female">Female</option>
              </select>
              <FieldError msg={errors.gender} />
            </div>
            <div className={`form-group ${errors.dob ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-cake-candles fa-fw" /> Date of Birth</label>
              <input
                type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                value={dob}
                onChange={e => setDob(e.target.value)}
                max={new Date().toISOString().slice(0, 10)}
              />
              <FieldError msg={errors.dob} />
            </div>
            {dob && (
              <div className="form-group">
                <label><i className="fa-solid fa-hourglass-half fa-fw" /> Age</label>
                <input type="text" value={calcAge(dob) !== null ? `${calcAge(dob)} years` : ''} readOnly />
              </div>
            )}
          </div>
        </div>
      );

      // ── Contact ───────────────────────────────────────────────────────────
      case 'contact': return (
        <div className="emp-section">
          <div className="emp-section-label"><i className="fa-solid fa-phone" /> Contact Details</div>
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group phone-group ${errors.mobile ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-mobile-screen fa-fw" /> Mobile No</label>
              <div className="phone-row">
                <select value={countryCode} onChange={e => {
                  setCountryCode(e.target.value);
                  // Re-validate against new dial code if a number is already entered
                  if (mobile) {
                    const err = validateMobile(e.target.value, mobile);
                    setErrors(p => ({ ...p, mobile: err ?? '' }));
                  }
                }} className="country-code-select">
                  {PHONE_CODES.map(p => (
                    <option key={p.code} value={p.code}>{p.flag} {p.label}</option>
                  ))}
                </select>
                <input type="tel" value={mobile} onChange={e => {
                  const val = e.target.value;
                  setMobile(val);
                  const err = val ? validateMobile(countryCode, val) : '';
                  setErrors(p => ({ ...p, mobile: err ?? '' }));
                }}
                  placeholder={mobilePlaceholder(countryCode)} required />
              </div>
              {!errors.mobile && (() => {
                const hint = mobileHint(countryCode);
                return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />{hint}</div> : null;
              })()}
              <FieldError msg={errors.mobile} />
            </div>
          </div>
        </div>
      );

      // ── Email ─────────────────────────────────────────────────────────────
      case 'email': return (
        <div className="emp-section">
          <div className="emp-section-label"><i className="fa-solid fa-envelope" /> Email Addresses</div>
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.businessEmail ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-building fa-fw" /> Business Email</label>
              <input
                type="email" value={businessEmail}
                onChange={e => {
                  const v = e.target.value;
                  setBusinessEmail(v);
                  if (v.includes('@') && !v.trim().toLowerCase().endsWith('@prowessinfotech.co.in'))
                    setErrors(p => ({ ...p, businessEmail: 'Must use the company domain: @prowessinfotech.co.in' }));
                  else
                    setErrors(p => ({ ...p, businessEmail: '' }));
                  // re-check same-address when biz email changes
                  if (personalEmail.trim() && v.trim().toLowerCase() === personalEmail.trim().toLowerCase())
                    setErrors(p => ({ ...p, personalEmail: 'Personal email cannot be the same as business email.' }));
                  else if (personalEmail.trim())
                    setErrors(p => ({ ...p, personalEmail: '' }));
                }}
                onBlur={e => checkDuplicateEmail(e.target.value)}
                placeholder="name@prowessinfotech.co.in" required
              />
              <FieldError msg={errors.businessEmail} />
            </div>
            <div className={`form-group ${errors.personalEmail ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-inbox fa-fw" /> Personal Email</label>
              <input
                type="email" value={personalEmail}
                onChange={e => {
                  const v = e.target.value;
                  setPersonalEmail(v);
                  if (businessEmail.trim() && v.trim().toLowerCase() === businessEmail.trim().toLowerCase())
                    setErrors(p => ({ ...p, personalEmail: 'Personal email cannot be the same as business email.' }));
                  else
                    setErrors(p => ({ ...p, personalEmail: '' }));
                }}
                placeholder="e.g. name@gmail.com" required
              />
              <FieldError msg={errors.personalEmail} />
            </div>
          </div>
        </div>
      );

      // ── Passport ──────────────────────────────────────────────────────────
      case 'passport': return (
        <div className="emp-section">
          <div className="emp-section-label">
            <i className="fa-solid fa-passport" /> Passport Information
            <span className="section-optional-tag">Optional</span>
          </div>
          <div className="emp-field-grid emp-grid-4">
            <div className="form-group">
              <label><i className="fa-solid fa-earth-americas fa-fw" /> Issue Country</label>
              <select value={passportCountry} onChange={e => {
                const next = e.target.value;
                const hasFilled = passportNumber || passportIssueDate || passportExpiry;
                if (hasFilled && next !== passportCountry) {
                  setPassportCountryPending(next);
                } else {
                  setPassportCountry(next);
                  setErrors(p => ({ ...p, passportNumber: '', passportIssueDate: '', passportExpiry: '' }));
                }
              }}>
                <option value="">-- Select Country --</option>
                {idCountries.map(c => (
                  <option key={String(c.id)} value={String(c.id)}>{c.value}</option>
                ))}
              </select>
            </div>
            <div className={`form-group ${errors.passportNumber ? 'form-group--error' : ''}`}>
              <label>
                <i className="fa-solid fa-passport fa-fw" /> Passport Number
                {passportCountry && <span style={{ color: '#e53935' }}> *</span>}
              </label>
              <input type="text" value={passportNumber}
                onFocus={() => { if (!passportCountry) setErrors(p => ({ ...p, passportNumber: 'Please select a Country first.' })); }}
                onChange={e => {
                  if (!passportCountry) { setErrors(p => ({ ...p, passportNumber: 'Please select a Country first.' })); return; }
                  const val = e.target.value;
                  setPassportNumber(val);
                  const countryName = idCountries.find(c => String(c.id) === passportCountry)?.value ?? '';
                  const err = val ? validatePassportNumber(countryName, val) : '';
                  setErrors(p => ({ ...p, passportNumber: err ?? '' }));
                }}
                placeholder={passportNumberPlaceholder(idCountries.find(c => String(c.id) === passportCountry)?.value ?? '')} />
              {!errors.passportNumber && passportCountry && (() => {
                const hint = passportNumberHint(idCountries.find(c => String(c.id) === passportCountry)?.value ?? '');
                return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />{hint}</div> : null;
              })()}
              <FieldError msg={errors.passportNumber} />
            </div>
            <div className={`form-group ${errors.passportIssueDate ? 'form-group--error' : ''}`}>
              <label>
                <i className="fa-solid fa-calendar-plus fa-fw" /> Issue Date
                {passportCountry && <span style={{ color: '#e53935' }}> *</span>}
              </label>
              <input type="date" min="1900-01-01" max="2100-12-31" value={passportIssueDate}
                onFocus={() => { if (!passportCountry) setErrors(p => ({ ...p, passportIssueDate: 'Please select a Country first.' })); }}
                onChange={e => {
                  if (!passportCountry) { setErrors(p => ({ ...p, passportIssueDate: 'Please select a Country first.' })); return; }
                  const val = e.target.value;
                  setPassportIssueDate(val);
                  setErrors(p => ({ ...p, passportIssueDate: '' }));
                  // Re-validate expiry against new issue date
                  if (passportExpiry) {
                    const countryName = idCountries.find(c => String(c.id) === passportCountry)?.value ?? '';
                    const err = validatePassportValidity(countryName, val, passportExpiry);
                    setErrors(p => ({ ...p, passportExpiry: err ?? '' }));
                  }
                }} />
              <FieldError msg={errors.passportIssueDate} />
            </div>
            <div className={`form-group ${errors.passportExpiry ? 'form-group--error' : ''}`}>
              <label>
                <i className="fa-solid fa-calendar-xmark fa-fw" /> Expiry Date
                {passportCountry && <span style={{ color: '#e53935' }}> *</span>}
              </label>
              <input type="date" min="1900-01-01" max="2100-12-31" value={passportExpiry}
                onFocus={() => { if (!passportCountry) setErrors(p => ({ ...p, passportExpiry: 'Please select a Country first.' })); }}
                onChange={e => {
                  if (!passportCountry) { setErrors(p => ({ ...p, passportExpiry: 'Please select a Country first.' })); return; }
                  const val = e.target.value;
                  setPassportExpiry(val);
                  const countryName = idCountries.find(c => String(c.id) === passportCountry)?.value ?? '';
                  const err = passportIssueDate ? validatePassportValidity(countryName, passportIssueDate, val) : null;
                  setErrors(p => ({ ...p, passportExpiry: err ?? '' }));
                }} />
              {!errors.passportExpiry && passportCountry && (() => {
                const hint = passportValidityHint(idCountries.find(c => String(c.id) === passportCountry)?.value ?? '');
                return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-clock" style={{ marginRight: 4 }} />{hint}</div> : null;
              })()}
              <FieldError msg={errors.passportExpiry} />
            </div>
          </div>
        </div>
      );

      // ── Identity ──────────────────────────────────────────────────────────
      case 'identity': return (
        <div className="emp-section">
          <div className="emp-section-label">
            <i className="fa-solid fa-id-card-clip" /> Employee Identification
            <span className="section-optional-tag">Optional</span>
          </div>

          {/* Existing records */}
          {idRecords.length > 0 && (
            <div className="emp-id-records-list" style={{ marginBottom: 16 }}>
              <table className="emp-id-table">
                <thead>
                  <tr>
                    <th>Type</th><th>Country</th><th>ID Type</th>
                    <th>ID Number</th><th>Expiry</th><th>Record</th><th></th>
                  </tr>
                </thead>
                <tbody>
                  {idRecords.map((r, i) => (
                    <tr key={i}>
                      <td>{r.recordType || '—'}</td>
                      <td>{plLabel('ID_COUNTRY', r.country) || r.country || '—'}</td>
                      <td>{plLabel('ID_TYPE', r.idType) || r.idType || '—'}</td>
                      <td>{r.idNumber}</td>
                      <td>{r.expiry ? fmtDate(r.expiry) : '—'}</td>
                      <td><span style={{ fontSize: 11, background: '#EFF6FF', color: '#1D4ED8', borderRadius: 4, padding: '2px 6px' }}>{r.recordType || '—'}</span></td>
                      <td>
                        <button style={{ background: 'none', border: 'none', color: '#EF4444', cursor: 'pointer' }}
                          onClick={() => {
                            const rec = idRecords[i];
                            const hasSecondary = idRecords.some((r, j) => j !== i && r.recordType === 'secondary');
                            if (rec.recordType === 'primary' && hasSecondary) {
                              setDeletePrimaryModal({ open: true, index: i });
                            } else {
                              const updated = idRecords.filter((_, j) => j !== i);
                              setIdRecords(updated);
                              saveIdentityNow(updated);
                            }
                          }}>
                          <i className="fa-solid fa-trash" />
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {/* Add ID sub-form */}
          <div className="emp-id-add-form">
            <div className="emp-field-grid emp-id-grid-top">
              <div className={`form-group ${errors.idCountry ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-earth-americas fa-fw" /> Country</label>
                <select value={idCountry} onChange={e => {
                  const next = e.target.value;
                  const hasFilled = idType || idRecordType || idNumber || idExpiry;
                  if (hasFilled && next !== idCountry) {
                    setIdCountryPending(next);
                  } else {
                    setIdCountry(next); setIdType('');
                    setErrors(p => ({ ...p, idCountry: '', idType: '', idRecordType: '', idNumber: '', idExpiry: '' }));
                  }
                }}>
                  <option value="">-- Select Country --</option>
                  {idCountries.map(c => (
                    <option key={String(c.id)} value={String(c.id)}>{c.value}</option>
                  ))}
                </select>
                <FieldError msg={errors.idCountry} />
              </div>
              <div className={`form-group ${errors.idType ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-tag fa-fw" /> ID Type</label>
                <select value={idType} onChange={e => {
                  const val = e.target.value;
                  setIdType(val);
                  if (val && idRecords.some(r => r.idType === val)) {
                    setErrors(p => ({ ...p, idType: 'This ID type has already been added for this employee.' }));
                  } else {
                    setErrors(p => ({ ...p, idType: '', idExpiry: '' }));
                  }
                  // Auto-default expiry date based on ID type validity
                  if (val) {
                    const countryName = idCountries.find(c => String(c.id) === idCountry)?.value ?? '';
                    const typeName    = picklistVals.find(p => String(p.id) === val)?.value ?? '';
                    const def = defaultExpiryDate(countryName, typeName);
                    if (def) setIdExpiry(def);
                  } else {
                    setIdExpiry('');
                  }
                }} disabled={!idCountry}>
                  <option value="">{idCountry ? '-- Select --' : '-- Select Country First --'}</option>
                  {idTypes.map(t => (
                    <option key={String(t.id)} value={String(t.id)}>{t.value}</option>
                  ))}
                </select>
                <FieldError msg={errors.idType} />
              </div>
              <div className={`form-group ${errors.idRecordType ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-star fa-fw" /> Record Type{idType && <span style={{ color: '#e53935' }}> *</span>}</label>
                <select value={idRecordType}
                  onFocus={() => { if (!idCountry) setErrors(p => ({ ...p, idRecordType: 'Please select a Country first.' })); }}
                  onChange={e => { if (!idCountry) { setErrors(p => ({ ...p, idRecordType: 'Please select a Country first.' })); return; } setIdRecordType(e.target.value); setErrors(p => ({ ...p, idRecordType: '' })); }}
                  disabled={!idCountry}>
                  <option value="">{idCountry ? '-- Select --' : '-- Select Country First --'}</option>
                  <option value="primary" disabled={idRecords.some(r => r.recordType === 'primary')}>
                    {idRecords.some(r => r.recordType === 'primary') ? '⭐ Primary (already assigned)' : '⭐ Primary'}
                  </option>
                  <option value="secondary" disabled={!idRecords.some(r => r.recordType === 'primary')}>
                    {!idRecords.some(r => r.recordType === 'primary') ? 'Secondary (add primary first)' : 'Secondary'}
                  </option>
                </select>
                <FieldError msg={errors.idRecordType} />
              </div>
            </div>
            <div className="emp-field-grid emp-id-grid-bottom">
              <div className={`form-group ${errors.idNumber ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-hashtag fa-fw" /> ID Number{idType && <span style={{ color: '#e53935' }}> *</span>}</label>
                <input type="text" value={idNumber}
                  onFocus={() => { if (!idCountry) setErrors(p => ({ ...p, idNumber: 'Please select a Country first.' })); }}
                  onChange={e => {
                    if (!idCountry) { setErrors(p => ({ ...p, idNumber: 'Please select a Country first.' })); return; }
                    const val = e.target.value;
                    setIdNumber(val);
                    const countryName = idCountries.find(c => String(c.id) === idCountry)?.value ?? '';
                    const typeName    = picklistVals.find(p => String(p.id) === idType)?.value ?? '';
                    const err = val ? validateIdentityNumber(countryName, typeName, val) : '';
                    setErrors(p => ({ ...p, idNumber: err ?? '' }));
                  }}
                  placeholder={idNumberPlaceholder(
                    idCountries.find(c => String(c.id) === idCountry)?.value ?? '',
                    picklistVals.find(p => String(p.id) === idType)?.value ?? '',
                  )} />
                {!errors.idNumber && idType && (() => {
                  const hint = idNumberHint(
                    idCountries.find(c => String(c.id) === idCountry)?.value ?? '',
                    picklistVals.find(p => String(p.id) === idType)?.value ?? '',
                  );
                  return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />{hint}</div> : null;
                })()}
                <FieldError msg={errors.idNumber} />
              </div>
              <div className={`form-group ${errors.idExpiry ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-calendar-xmark fa-fw" /> Expiry Date{idType && <span style={{ color: '#e53935' }}> *</span>}</label>
                <input type="date" min="1900-01-01" max="2100-12-31" value={idExpiry}
                  onFocus={() => { if (!idCountry) setErrors(p => ({ ...p, idExpiry: 'Please select a Country first.' })); }}
                  onChange={e => {
                    if (!idCountry) { setErrors(p => ({ ...p, idExpiry: 'Please select a Country first.' })); return; }
                    const v = e.target.value;
                    setIdExpiry(v);
                    const today = new Date().toISOString().slice(0, 10);
                    if (v && v <= today)
                      setErrors(p => ({ ...p, idExpiry: 'Expiry Date must be a future date.' }));
                    else
                      setErrors(p => ({ ...p, idExpiry: '' }));
                  }} />
                {!errors.idExpiry && idType && (() => {
                  const lbl = idValidityLabel(
                    idCountries.find(c => String(c.id) === idCountry)?.value ?? '',
                    picklistVals.find(p => String(p.id) === idType)?.value ?? '',
                  );
                  return lbl ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-clock" style={{ marginRight: 4 }} />{lbl}</div> : null;
                })()}
                <FieldError msg={errors.idExpiry} />
              </div>
            </div>
            <div className="emp-id-form-actions">
              <button type="button" className="emp-id-add-btn" onClick={addIdRecord}>
                <i className="fa-solid fa-plus" /> Add ID
              </button>
            </div>
          </div>
        </div>
      );

      // ── Employment ────────────────────────────────────────────────────────
      case 'employment': return (
        <div className="emp-section">
          <div className="emp-section-label"><i className="fa-solid fa-briefcase" /> Employment Details</div>
          <div className="emp-field-grid emp-grid-3">
            <div className={`form-group ${errors.designation ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-id-badge fa-fw" /> Designation</label>
              <select value={designation} onChange={e => setDesignation(e.target.value)} required>
                <option value="">-- Select Designation --</option>
                {designations.map(p => <option key={String(p.id)} value={String(p.id)}>{p.value}</option>)}
              </select>
              <FieldError msg={errors.designation} />
            </div>
            <div className={`form-group ${errors.deptId ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-sitemap fa-fw" /> Department</label>
              <select value={deptId} onChange={e => setDeptId(e.target.value)} required>
                <option value="">-- Select Department --</option>
                {departments.map(d => <option key={d.deptId} value={d.deptId}>{d.name}</option>)}
              </select>
              <FieldError msg={errors.deptId} />
            </div>
            <div className="form-group" style={{ position: 'relative' }}>
              <label><i className="fa-solid fa-user-tie fa-fw" /> Manager</label>
              <input
                type="text"
                value={managerSearch}
                onChange={e => {
                  setManagerSearch(e.target.value);
                  setManagerId('');
                  setManagerOpen(true);
                }}
                onFocus={() => setManagerOpen(true)}
                onBlur={() => setTimeout(() => setManagerOpen(false), 150)}
                placeholder="Search by name or ID…"
                autoComplete="off"
              />
              {/* Selected manager chip */}
              {managerId && (
                <div style={{ fontSize: 12, color: '#4F46E5', marginTop: 4 }}>
                  <i className="fa-solid fa-circle-check" style={{ marginRight: 4 }} />
                  {managers.find(e => (e as any).id === managerId)?.name ?? managerSearch}
                  <button
                    type="button"
                    onClick={() => { setManagerId(''); setManagerSearch(''); }}
                    style={{ marginLeft: 8, background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 11 }}
                  >✕</button>
                </div>
              )}
              {/* Dropdown */}
              {managerOpen && !managerId && (
                <div style={{
                  position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 999,
                  background: '#fff', border: '1px solid #D1D5DB', borderRadius: 8,
                  boxShadow: '0 4px 16px rgba(0,0,0,0.12)', maxHeight: 220, overflowY: 'auto',
                }}>
                  {/* No manager option */}
                  <div
                    onMouseDown={() => { setManagerId(''); setManagerSearch(''); setManagerOpen(false); }}
                    style={{ padding: '8px 12px', fontSize: 13, color: '#9CA3AF', cursor: 'pointer', borderBottom: '1px solid #F3F4F6' }}
                  >
                    — No Manager —
                  </div>
                  {managers
                    .filter(e => {
                      if (!managerSearch.trim()) return true;
                      const q = managerSearch.toLowerCase();
                      return e.name.toLowerCase().includes(q) || e.employeeId.toLowerCase().includes(q);
                    })
                    .map(e => (
                      <div
                        key={(e as any).id}
                        onMouseDown={() => {
                          setManagerId((e as any).id);
                          setManagerSearch(e.name);
                          setManagerOpen(false);
                        }}
                        style={{ padding: '8px 12px', fontSize: 13, cursor: 'pointer', display: 'flex', justifyContent: 'space-between' }}
                        onMouseEnter={ev => (ev.currentTarget.style.background = '#F5F3FF')}
                        onMouseLeave={ev => (ev.currentTarget.style.background = '')}
                      >
                        <span>{e.name}</span>
                        <span style={{ color: '#9CA3AF', fontSize: 11 }}>{e.employeeId}</span>
                      </div>
                    ))
                  }
                  {managers.filter(e => {
                    if (!managerSearch.trim()) return true;
                    const q = managerSearch.toLowerCase();
                    return e.name.toLowerCase().includes(q) || e.employeeId.toLowerCase().includes(q);
                  }).length === 0 && (
                    <div style={{ padding: '10px 12px', fontSize: 13, color: '#9CA3AF' }}>No matches</div>
                  )}
                </div>
              )}
            </div>
            <div className={`form-group ${errors.hireDate ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-calendar-check fa-fw" /> Hire Date</label>
              <input type="date" min="1900-01-01" max="2100-12-31" value={hireDate} onChange={e => {
                const v = e.target.value;
                setHireDate(v);
                setErrors(p => ({ ...p, hireDate: '' }));
              }} required />
              <FieldError msg={errors.hireDate} />
            </div>
            <div className={`form-group ${errors.probationEnd ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-hourglass-half fa-fw" /> Probation End Date</label>
              <input type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31" value={probationEnd}
                onChange={e => handleProbationChange(e.target.value)} required />
              <FieldError msg={errors.probationEnd} />
            </div>
            <div className={`form-group ${errors.workCountry ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-earth-asia fa-fw" /> Country of Work</label>
              <select value={workCountry} onChange={e => { setWorkCountry(e.target.value); setWorkLocation(''); }} required>
                <option value="">-- Select Country --</option>
                {idCountries.map(c => (
                  <option key={String(c.id)} value={String(c.id)}>{c.value}</option>
                ))}
              </select>
              <FieldError msg={errors.workCountry} />
            </div>
            <div className={`form-group ${errors.workLocation ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-location-dot fa-fw" /> Location</label>
              <select value={workLocation} onChange={e => setWorkLocation(e.target.value)} disabled={!workCountry} required>
                <option value="">{workCountry ? '-- Select Location --' : '-- Select Country First --'}</option>
                {workLocations.map(l => (
                  <option key={String(l.id)} value={String(l.id)}>{l.value}</option>
                ))}
              </select>
              <FieldError msg={errors.workLocation} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-coins fa-fw" /> Base Currency</label>
              {(() => {
                const resolved = currencies.find(c => c.id === baseCurrency);
                return baseCurrency && resolved ? (
                  <div className="emp-readonly-field">
                    <i className="fa-solid fa-lock fa-fw" style={{ color: '#94A3B8', fontSize: 12 }} />
                    <span>{resolved.name}</span>
                    <small style={{ color: '#94A3B8', fontSize: 11, marginLeft: 'auto' }}>Auto-set from Country of Work</small>
                  </div>
                ) : (
                  <div className="emp-readonly-field emp-readonly-empty">
                    <i className="fa-solid fa-triangle-exclamation fa-fw" style={{ color: '#F59E0B', fontSize: 12 }} />
                    <span style={{ color: '#94A3B8', fontSize: 13 }}>
                      {workCountry
                        ? 'No default currency configured — set it in Reference Data → ID Country'
                        : 'Select Country of Work first'}
                    </span>
                  </div>
                );
              })()}
            </div>
          </div>
        </div>
      );

      // ── Address ───────────────────────────────────────────────────────────
      case 'address': return (
        <div className="emp-section">
          <div className="emp-section-label"><i className="fa-solid fa-location-dot" /> Address Information</div>
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.addrLine1 ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-house fa-fw" /> Address Line 1</label>
              <input type="text" value={addrLine1} onChange={e => setAddrLine1(e.target.value)}
                placeholder="House / Flat / Building No." required />
              <FieldError msg={errors.addrLine1} />
            </div>
            <div className={`form-group ${errors.addrLine2 ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-road fa-fw" /> Address Line 2</label>
              <input type="text" value={addrLine2} onChange={e => setAddrLine2(e.target.value)}
                placeholder="Street / Area / Locality" required />
              <FieldError msg={errors.addrLine2} />
            </div>
          </div>
          <div className="emp-field-grid emp-grid-2">
            <div className="form-group">
              <label><i className="fa-solid fa-map-pin fa-fw" /> Landmark</label>
              <input type="text" value={addrLandmark} onChange={e => setAddrLandmark(e.target.value)}
                placeholder="e.g. Near City Mall" />
            </div>
            <div className={`form-group ${errors.addrCity ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-city fa-fw" /> City</label>
              <input type="text" value={addrCity} onChange={e => setAddrCity(e.target.value)}
                placeholder="e.g. Chennai" required />
              <FieldError msg={errors.addrCity} />
            </div>
          </div>
          <div className="emp-field-grid emp-grid-2">
            <div className="form-group">
              <label><i className="fa-solid fa-map fa-fw" /> District</label>
              <input type="text" value={addrDistrict} onChange={e => setAddrDistrict(e.target.value)}
                placeholder="e.g. Chennai District" />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-flag fa-fw" /> State</label>
              <input type="text" value={addrState} onChange={e => setAddrState(e.target.value)}
                placeholder="e.g. Tamil Nadu" />
            </div>
          </div>
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.addrPin ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-hashtag fa-fw" /> PIN / ZIP Code</label>
              <input type="text" value={addrPin} onChange={e => setAddrPin(e.target.value)}
                placeholder="e.g. 600001" required />
              <FieldError msg={errors.addrPin} />
            </div>
            <div className={`form-group ${errors.addrCountry ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-earth-asia fa-fw" /> Country</label>
              <select value={addrCountry} onChange={e => setAddrCountry(e.target.value)} required>
                <option value="">-- Select Country --</option>
                {COUNTRIES.map(c => <option key={c} value={c}>{c}</option>)}
              </select>
              <FieldError msg={errors.addrCountry} />
            </div>
          </div>
        </div>
      );

      // ── Emergency ─────────────────────────────────────────────────────────
      case 'emergency': return (
        <div className="emp-section">
          <div className="emp-section-label"><i className="fa-solid fa-phone-volume" /> Emergency Contact Information</div>
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.ecName ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-user fa-fw" /> Contact Name</label>
              <input type="text" value={ecName} onChange={e => setEcName(e.target.value)}
                placeholder="e.g. Raj Kumar" required />
              <FieldError msg={errors.ecName} />
            </div>
            <div className={`form-group ${errors.ecRel ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-people-arrows fa-fw" /> Relationship</label>
              <select value={ecRel} onChange={e => setEcRel(e.target.value)} required>
                <option value="">-- Select --</option>
                {relationships.map(p => <option key={String(p.id)} value={String(p.id)}>{p.value}</option>)}
              </select>
              <FieldError msg={errors.ecRel} />
            </div>
          </div>
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.ecPhone ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-phone fa-fw" /> Phone Number</label>
              <input type="text" value={ecPhone} onChange={e => setEcPhone(e.target.value)}
                placeholder="e.g. +91 98765 43210" required />
              <FieldError msg={errors.ecPhone} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-mobile-screen fa-fw" /> Alternate Phone</label>
              <input type="text" value={ecAltPhone} onChange={e => setEcAltPhone(e.target.value)}
                placeholder="e.g. +91 91234 56789" />
            </div>
          </div>
          <div className="emp-field-grid emp-grid-2">
            <div className="form-group">
              <label><i className="fa-solid fa-envelope fa-fw" /> Email</label>
              <input type="email" value={ecEmail} onChange={e => setEcEmail(e.target.value)}
                placeholder="e.g. raj@example.com" />
            </div>
          </div>
        </div>
      );

      // ── Bank ──────────────────────────────────────────────────────────────
      case 'bank': return (
        <div className="emp-section">
          <div className="emp-section-label">
            <i className="fa-solid fa-building-columns" /> Bank Account Details
          </div>
          {errors.bank && (
            <div style={{ background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 7, padding: '8px 12px', color: '#DC2626', fontSize: 12.5, marginBottom: 12 }}>
              <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{errors.bank}
            </div>
          )}
          {currentEmpUUID && (
            <BankAccountsPortlet
              employeeId={currentEmpUUID}
              hireDate={hireDate || undefined}
              isNewHire
              readOnly={isLocked && !isApproverEditMode}
              canEdit={!isLocked || isApproverEditMode}
              saveTriggerRef={bankSaveTriggerRef}
              onChanged={() => {
                setBankSectionDone(true);
                setErrors(p => ({ ...p, bank: '' }));
                setCompleted(prev => new Set([...prev, 'bank']));
              }}
              onAccountCountChange={(hasAccounts) => {
                setBankSectionDone(hasAccounts);
                setCompleted(prev => {
                  const next = new Set(prev);
                  hasAccounts ? next.add('bank') : next.delete('bank');
                  return next;
                });
              }}
            />
          )}
          {!currentEmpUUID && (
            <div style={{ color: '#9CA3AF', fontSize: 13, padding: '12px 0' }}>
              <i className="fa-solid fa-circle-info" style={{ marginRight: 6 }} />
              Save the previous sections first — bank accounts will be available once the employee record is created.
            </div>
          )}
        </div>
      );

      // ── Education ────────────────────────────────────────────────────────
      case 'education': return (
        <div className="emp-section">
          <div className="emp-section-label">
            <i className="fa-solid fa-graduation-cap" /> Education
          </div>
          {currentEmpUUID ? (
            <EducationPortlet
              employeeId={currentEmpUUID}
              isNewHire
              readOnly={isLocked && !isApproverEditMode}
              canCreate={!isLocked || isApproverEditMode}
              canEdit={!isLocked || isApproverEditMode}
              canDelete={!isLocked || isApproverEditMode}
              saveTriggerRef={eduSaveTriggerRef}
              onRecordCountChange={(hasRecords) => {
                setEducationHasRecords(hasRecords);
                setCompleted(prev => {
                  const next = new Set(prev);
                  hasRecords ? next.add('education') : next.delete('education');
                  return next;
                });
              }}
            />
          ) : (
            <div style={{ color: '#9CA3AF', fontSize: 13, padding: '12px 0' }}>
              <i className="fa-solid fa-circle-info" style={{ marginRight: 6 }} />
              Save the previous sections first — education records will be available once the employee record is created.
            </div>
          )}
        </div>
      );

      // ── Dependents ────────────────────────────────────────────────────────
      case 'dependents': return (
        <div className="emp-section">
          <div className="emp-section-label">
            <i className="fa-solid fa-people-group" /> Dependents
          </div>
          {currentEmpUUID ? (
            <DependentsPortlet
              employeeId={currentEmpUUID}
              hireDate={hireDate || undefined}
              isNewHire
              readOnly={isLocked && !isApproverEditMode}
              canEdit={!isLocked || isApproverEditMode}
              canDelete={false}
              saveTriggerRef={depSaveTriggerRef}
              onRecordCountChange={(hasRecords) => {
                setDependentsHasRecords(hasRecords);
                setCompleted(prev => {
                  const next = new Set(prev);
                  hasRecords ? next.add('dependents') : next.delete('dependents');
                  return next;
                });
              }}
            />
          ) : (
            <div style={{ color: '#9CA3AF', fontSize: 13, padding: '12px 0' }}>
              <i className="fa-solid fa-circle-info" style={{ marginRight: 6 }} />
              Save the previous sections first — dependents will be available once the employee record is created.
            </div>
          )}
        </div>
      );

      default: return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // JSX
  // ─────────────────────────────────────────────────────────────────────────
  return (
    <div className="page-content" style={{ padding: '28px 32px' }}>
      {/* Workflow gate banners */}
      {editingEmpId
        ? <WorkflowGateBanner moduleCode="employee_edit"       actionLabel="employee detail edits" />
        : !hireGateLoading && !hasHireWorkflow &&
          <WorkflowGateBanner moduleCode="employee_onboarding" actionLabel="new employee creation" />
      }
      {/* Hire workflow banner — shown when workflow is configured for New Hire */}
      {!editingEmpId && !hireGateLoading && hasHireWorkflow && !isLocked && (
        <div style={{
          display: 'flex', alignItems: 'flex-start', gap: 10,
          background: '#EFF6FF', border: '1px solid #BFDBFE',
          borderRadius: 8, padding: '10px 14px', marginBottom: 16,
          fontSize: 13, color: '#1E40AF',
        }}>
          <i className="fa-solid fa-circle-bolt" style={{ marginTop: 2, flexShrink: 0, color: '#3B82F6' }} />
          <div>
            <strong>Workflow approval required</strong> — this hire will be submitted for approval
            before the employee is activated. Fill in all required sections, then click{' '}
            <strong>Submit for Approval</strong>.
          </div>
        </div>
      )}
      {/* Locked banner — record is pending approval or rejected */}
      {isLocked && loadedEmpStatus !== 'Rejected' && (
        <div style={{
          display: 'flex', alignItems: 'flex-start', gap: 10,
          background: '#DBEAFE', border: '1px solid #93C5FD',
          borderRadius: 8, padding: '10px 14px', marginBottom: 16,
          fontSize: 13, color: '#1E40AF',
        }}>
          <i className="fa-solid fa-lock" style={{ marginTop: 2, flexShrink: 0 }} />
          <div>
            <strong>Awaiting approval</strong> — this record has been submitted and is locked.
            {isApproverEditMode
              ? ' You can make changes and save — this will update the record for the approver.'
              : ' You cannot edit it until the approver acts on the request.'}
          </div>
        </div>
      )}
      {/* Rejected banner */}
      {isLocked && loadedEmpStatus === 'Rejected' && (
        <div style={{
          display: 'flex', alignItems: 'flex-start', gap: 10,
          background: '#FEF2F2', border: '1px solid #FECACA',
          borderRadius: 8, padding: '10px 14px', marginBottom: 16,
          fontSize: 13, color: '#DC2626',
        }}>
          <i className="fa-solid fa-circle-xmark" style={{ marginTop: 2, flexShrink: 0 }} />
          <div>
            <strong>Hire request rejected</strong> — this record is read-only.
            {' '}Open the <strong>Sent Back</strong> tab in your Workflow Inbox to view the reason and discard the record.
          </div>
        </div>
      )}
      {/* Approver return comment — shown when status=Incomplete (sent back for correction) */}
      {loadedEmpStatus === 'Incomplete' && returnComment && (
        <div style={{
          display: 'flex', alignItems: 'flex-start', gap: 10,
          background: '#FFFBEB', border: '1px solid #FCD34D',
          borderRadius: 8, padding: '10px 14px', marginBottom: 16,
          fontSize: 13, color: '#92400E',
        }}>
          <i className="fa-solid fa-circle-exclamation" style={{ marginTop: 2, flexShrink: 0, color: '#D97706' }} />
          <div>
            <strong>Returned for correction</strong>
            {returnComment.fromName ? ` by ${returnComment.fromName}` : ''}
            {returnComment.at ? ` · ${new Date(returnComment.at).toLocaleDateString()}` : ''}
            <div style={{ marginTop: 4, color: '#78350F' }}>{returnComment.message}</div>
          </div>
        </div>
      )}

      <h2 className="page-title" style={{ marginBottom: 20 }}>
        {editingEmpId
          ? isApproverEditMode
            ? 'Edit Employee (Approver Review)'
            : isLocked && loadedEmpStatus === 'Rejected'
              ? 'View Employee (Rejected)'
          : isLocked
              ? 'View Employee (Pending Approval)'
              : 'Edit Employee'
          : 'Add New Employee'
        }
      </h2>

      {/* ── Form Card ──────────────────────────────────────────────────── */}
      <div className="emp-form-card" style={{ marginBottom: 24, position: 'relative' }}>

        {/* Form Header */}
        <div className="emp-form-header">
          <div className="emp-form-avatar" onClick={() => photoRef.current?.click()} title="Click to change photo" style={{ cursor: 'pointer' }}>
            {photo
              ? <img src={photo} alt={firstName || 'Employee'} style={{ width: '100%', height: '100%', objectFit: 'cover', borderRadius: '50%' }} />
              : firstName
                ? <img src={getAvatar({ name: [firstName, lastName].filter(Boolean).join(' ') })} alt={firstName} style={{ width: '100%', height: '100%', objectFit: 'cover', borderRadius: '50%' }} />
                : <i className="fa-solid fa-user" />
            }
            <input ref={photoRef} type="file" accept="image/*" hidden onChange={handlePhotoUpload} />
          </div>
          <div className="emp-form-header-text">
            <h3>{[firstName, middleName, lastName].filter(Boolean).join(' ') || 'New Employee'}</h3>
            <p>Fill in the details below. Role is auto-derived from org structure.</p>
          </div>

          {/* Required-sections ring — top-right of header */}
          {!isLocked && !isApproverEditMode && (() => {
            const r = 24;
            const circ = 2 * Math.PI * r;
            const dash = (requiredTotal > 0 ? requiredDoneCount / requiredTotal : 0) * circ;
            const done = allRequiredDone;
            const requiredSections = SECTIONS.filter(s => !s.optional);
            return (
              <div className="emp-progress-ring">
                <svg width="68" height="68" viewBox="0 0 68 68">
                  <circle cx="34" cy="34" r={r} fill="none" stroke="rgba(255,255,255,0.18)" strokeWidth="6" />
                  <circle cx="34" cy="34" r={r} fill="none"
                    stroke={done ? '#4ADE80' : '#93C5FD'}
                    strokeWidth="6"
                    strokeDasharray={`${dash} ${circ - dash}`}
                    strokeDashoffset={circ / 4}
                    strokeLinecap="round"
                    style={{ transition: 'stroke-dasharray 0.45s cubic-bezier(.4,0,.2,1)' }}
                  />
                  {done ? (
                    <text x="34" y="40" textAnchor="middle" fontSize="20" fill="#4ADE80">✓</text>
                  ) : (
                    <>
                      <text x="34" y="31" textAnchor="middle" fontSize="16" fontWeight="700" fill="#ffffff">{requiredDoneCount}/{requiredTotal}</text>
                      <text x="34" y="44" textAnchor="middle" fontSize="8.5" fill="rgba(255,255,255,0.55)">sections</text>
                    </>
                  )}
                </svg>
                {/* Hover tooltip — lists all required sections with ✓/○ */}
                <div className="emp-ring-tooltip">
                  <div className="emp-ring-tooltip-title">Required sections</div>
                  {requiredSections.map(s => {
                    const isDone = completed.has(s.id);
                    return (
                      <div key={s.id} className={`emp-ring-tooltip-row${isDone ? ' done' : ''}`}>
                        <span className="emp-ring-tooltip-icon">
                          <i className={`fa-solid ${isDone ? 'fa-circle-check' : 'fa-circle'}`} />
                        </span>
                        {s.label}
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })()}

        </div>

        {/* Progress Tracker */}
        <ProgressTracker
          activeSection={activeSection}
          completedSections={completed}
          onJump={jumpToSection}
          baseAllDone={baseAllDone}
        />

        {gateMsg && (
          <div className="emp-gate-msg">
            <i className="fa-solid fa-lock" />
            Complete <strong>Personal, Phone, Email and Employment</strong> first to unlock the remaining sections.
          </div>
        )}

        {/* Section body */}
        <form onSubmit={e => e.preventDefault()}>
          {/* fieldset disabled propagates to every child input/select/button
              when the record is locked (awaiting approval). No-op otherwise. */}
          <fieldset disabled={isLocked} style={{ border: 'none', padding: 0, margin: 0, minWidth: 0 }}>
            {renderSection()}
          </fieldset>

          {/* Footer actions */}
          <div className="emp-form-footer">
            {/* LEFT group: Cancel & Exit + Back */}
            <div className="emp-footer-left">
              <button type="button" className="emp-btn-exit" onClick={handleCancelExit}>
                {isLocked
                  ? <><i className="fa-solid fa-arrow-left" /> Close</>
                  : <><i className="fa-solid fa-xmark" /> Cancel &amp; Exit</>}
              </button>
              {currentSectionIdx > 0 && (
                <button
                  type="button"
                  className="emp-btn-ghost"
                  disabled={isSaving || submittingForApproval}
                  onClick={handleBack}
                >
                  <i className="fa-solid fa-arrow-left" /> Back
                </button>
              )}
            </div>

            {/* RIGHT group: Save Draft + Next / primary action */}
            <div className="emp-footer-right">
              {/* Approver edit-in-flight: show Save & Return instead of normal buttons */}
              {isApproverEditMode ? (
                <button type="button" className="emp-btn-primary" onClick={handleSaveAndReturn}>
                  <i className="fa-solid fa-floppy-disk" /> Save &amp; Return to Review
                </button>
              ) : isLocked ? (
                /* Locked (pending approval) — no save/activate, read-only */
                null
              ) : (
                <>
                  <button type="button" className="emp-btn-secondary" onClick={handleSaveDraft}
                    disabled={isSaving || submittingForApproval}>
                    <i className={`fa-solid ${isSaving ? 'fa-spinner fa-spin' : 'fa-floppy-disk'}`} />
                    {isSaving ? ' Saving…' : ' Save Draft'}
                  </button>
                  {!isLastSection ? (
                    <button type="button" className="emp-btn-primary" onClick={handleNext}
                      disabled={isSaving || submittingForApproval}>
                      Next <i className="fa-solid fa-arrow-right" />
                    </button>
                  ) : (
                    /* Last section — submit / activate button */
                    <>
                    {hasHireWorkflow && (loadedEmpStatus == null || loadedEmpStatus === 'Draft' || loadedEmpStatus === 'Incomplete') ? (
                    /* Workflow configured + record is new or still in hire pipeline — submit for approval */
                    <button
                      type="button"
                      className="emp-btn-primary"
                      onClick={handleSubmitForApproval}
                      disabled={submittingForApproval}
                      title=""
                    >
                      {submittingForApproval
                        ? <><i className="fa-solid fa-spinner fa-spin" /> Submitting…</>
                        : <><i className="fa-solid fa-paper-plane" /> Submit for Approval</>
                      }
                    </button>
                  ) : (
                    /* No workflow or editing existing employee — direct activate */
                    <button
                      type="button"
                      className="emp-btn-primary"
                      onClick={handleActivate}
                      title={!allRequiredDone ? 'Complete all required sections to activate' : ''}
                    >
                      <i className="fa-solid fa-user-check" /> Activate Employee
                    </button>
                  )}
                </>
              )}
                </>
              )}
            </div>
          </div>
        </form>
      </div>

      {/* ── New Hires Table ──────────────────────────────────────────────── */}
      <NewHiresTable
        employees={employees}
        onContinue={loadEmployee}
        onDelete={confirmDelete}
        picklistVals={picklistVals}
        departments={departments}
        currentUserId={authUser?.id ?? null}
        canViewAll={canViewAllPipeline}
      />

      {/* ── Info / success modal ─────────────────────────────────────────── */}
      {infoModal.open && (
        <div className="modal-overlay" onClick={() => setInfoModal(m => ({ ...m, open: false }))}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className={`fa-solid ${
                infoModal.type === 'success' ? 'fa-circle-check' :
                infoModal.type === 'warning' ? 'fa-triangle-exclamation' :
                'fa-circle-info'
              } modal-icon`} style={{
                color: infoModal.type === 'success' ? '#16A34A' :
                       infoModal.type === 'warning'  ? '#D97706' : '#2563EB',
              }} />
              <h3>{infoModal.title}</h3>
            </div>
            <div className="modal-body" style={{ whiteSpace: 'pre-line' }}>{infoModal.message}</div>
            <div className="modal-actions">
              <button
                className="emp-btn-primary"
                style={{ padding: '9px 28px', fontSize: 13.5 }}
                onClick={() => setInfoModal(m => ({ ...m, open: false }))}
              >
                OK
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Probation 180-day warning modal ─────────────────────────────── */}
      {probationWarning.open && (
        <div className="modal-overlay">
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-triangle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>Extended Probation Period</h3>
            </div>
            <div className="modal-body">
              The selected Probation End Date puts this employee on probation for <strong>more than 180 days</strong> from their Hire Date.
              <br /><br />
              Please consider terminating the probation at the standard period. Proceed only under exceptional circumstances with appropriate justification.
            </div>
            <div className="modal-actions">
              <button
                className="btn-modal-cancel"
                onClick={() => setProbationWarning({ open: false, pendingDate: '' })}
              >
                <i className="fa-solid fa-pen-to-square" /> Revise Date
              </button>
              <button
                className="btn-modal-danger"
                onClick={() => {
                  setProbationEnd(probationWarning.pendingDate);
                  setProbationWarning({ open: false, pendingDate: '' });
                }}
              >
                <i className="fa-solid fa-circle-check" /> Proceed Anyway
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Duplicate business-email modal ──────────────────────────────── */}
      {dupEmailModal.open && (
        <div className="modal-overlay" onClick={() => setDupEmailModal(m => ({ ...m, open: false }))}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className={`fa-solid ${dupEmailModal.type === 'block' ? 'fa-circle-xmark' : 'fa-triangle-exclamation'} modal-icon`}
                style={{ color: dupEmailModal.type === 'block' ? '#DC2626' : '#D97706' }} />
              <h3>{dupEmailModal.title}</h3>
            </div>
            <div className="modal-body">{dupEmailModal.message}</div>
            <div className="modal-actions">
              {dupEmailModal.type === 'warn' ? (
                <>
                  <button
                    className="btn-modal-cancel"
                    onClick={() => {
                      setDupEmailModal(m => ({ ...m, open: false }));
                      setSearchParams(p => { p.set('edit', dupEmailModal.existingId); return p; });
                    }}
                  >
                    <i className="fa-solid fa-arrow-up-right-from-square" /> View existing
                  </button>
                  <button
                    className="emp-btn-primary"
                    style={{ padding: '9px 24px', fontSize: 13.5 }}
                    onClick={() => setDupEmailModal(m => ({ ...m, open: false }))}
                  >
                    Continue anyway
                  </button>
                </>
              ) : (
                <button
                  className="emp-btn-primary"
                  style={{ padding: '9px 28px', fontSize: 13.5 }}
                  onClick={() => setDupEmailModal(m => ({ ...m, open: false }))}
                >
                  OK
                </button>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ── Incomplete sections modal ───────────────────────────────────── */}
      {incompleteSectionsModal.length > 0 && (
        <div className="modal-overlay" onClick={() => setIncompleteSectionsModal([])}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-circle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>Required Sections Incomplete</h3>
            </div>
            <div className="modal-body">
              <p style={{ marginBottom: 12 }}>
                Please complete the following required sections before submitting for approval:
              </p>
              <ul style={{ margin: 0, paddingLeft: 20, display: 'flex', flexDirection: 'column', gap: 6 }}>
                {incompleteSectionsModal.map(label => (
                  <li key={label} style={{ color: '#92400E', fontWeight: 600 }}>
                    <i className="fa-solid fa-circle-dot" style={{ marginRight: 8, color: '#D97706' }} />
                    {label}
                  </li>
                ))}
              </ul>
            </div>
            <div className="modal-actions">
              <button
                className="emp-btn-primary"
                style={{ padding: '9px 28px', fontSize: 13.5 }}
                onClick={() => {
                  // Navigate to the first incomplete section
                  const firstMissingId = requiredSectionIds.find(id => !completed.has(id));
                  if (firstMissingId) {
                    setActiveSection(firstMissingId);
                    window.scrollTo({ top: 0, behavior: 'smooth' });
                  }
                  setIncompleteSectionsModal([]);
                }}
              >
                <i className="fa-solid fa-arrow-right" /> Go to Section
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Toast notification ──────────────────────────────────────────── */}
      {toast && (
        <div className={`emp-toast emp-toast--${toast.type}`}>
          <i className={`fa-solid ${toast.type === 'success' ? 'fa-circle-check' : 'fa-circle-xmark'}`} />
          {toast.message}
        </div>
      )}

      {/* ── Cancel & Exit confirmation modal ────────────────────────────── */}
      {exitModal && (
        <div className="modal-overlay" onClick={() => setExitModal(false)}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-circle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>Leave this page?</h3>
            </div>
            <div className="modal-body">
              You have unsaved changes. Do you want to save your progress before exiting?
            </div>
            <div className="modal-actions modal-actions--3">
              <button className="emp-btn-exit" onClick={() => { setExitModal(false); resetForm(); }}>
                Discard &amp; Exit
              </button>
              <button className="btn-modal-cancel" onClick={() => setExitModal(false)}>
                Stay
              </button>
              <button className="emp-btn-primary" onClick={() => { setExitModal(false); performSave(true); }}>
                <i className="fa-solid fa-floppy-disk" /> Save &amp; Exit
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Delete confirm modal ─────────────────────────────────────────── */}
      {deletingId && (
        <div className="modal-overlay" onClick={() => setDeletingId(null)}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-trash modal-icon modal-icon--danger" />
              <h3>Discard Draft?</h3>
            </div>
            <div className="modal-body">
              <p>This will permanently remove the draft for employee <strong>{deletingId}</strong>. This action cannot be undone.</p>
            </div>
            <div className="modal-actions">
              <button className="btn-modal-cancel" onClick={() => setDeletingId(null)}>Cancel</button>
              <button className="btn-modal-danger" onClick={doDelete}>
                <i className="fa-solid fa-trash" /> Discard
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Identity country-change confirmation ─────────────────────────── */}
      <ConfirmationModal
        isOpen={idCountryPending !== null}
        title="Change Identity Country?"
        message="Changing the Country will clear the ID Type, Record Type, ID Number, and Expiry Date. Do you want to continue?"
        confirmText="Yes, Clear"
        cancelText="Cancel"
        destructive={false}
        onConfirm={() => {
          if (idCountryPending !== null) {
            setIdCountry(idCountryPending);
            setIdType(''); setIdRecordType(''); setIdNumber(''); setIdExpiry('');
            setErrors(p => ({ ...p, idCountry: '', idType: '', idRecordType: '', idNumber: '', idExpiry: '' }));
          }
          setIdCountryPending(null);
        }}
        onCancel={() => setIdCountryPending(null)}
      />

      {/* ── Passport country-change confirmation ─────────────────────────── */}
      <ConfirmationModal
        isOpen={passportCountryPending !== null}
        title="Change Issue Country?"
        message="Changing the Issue Country will clear the Passport Number, Issue Date, and Expiry Date. Do you want to continue?"
        confirmText="Yes, Clear"
        cancelText="Cancel"
        destructive={false}
        onConfirm={() => {
          if (passportCountryPending !== null) {
            setPassportCountry(passportCountryPending);
            setPassportNumber('');
            setPassportIssueDate('');
            setPassportExpiry('');
            setErrors(p => ({ ...p, passportNumber: '', passportIssueDate: '', passportExpiry: '' }));
          }
          setPassportCountryPending(null);
        }}
        onCancel={() => setPassportCountryPending(null)}
      />

      {/* ── Delete primary ID — auto-demote secondary modal ─────────────── */}
      <ConfirmationModal
        isOpen={deletePrimaryModal.open}
        title="Delete Primary ID Record?"
        message="This employee also has a secondary ID record. Deleting the primary will automatically promote the secondary to primary."
        warning="The secondary record will become the new primary. You can add a new secondary record afterwards if needed."
        confirmText="Delete & Promote"
        cancelText="Cancel"
        destructive={false}
        onConfirm={() => {
          const updated = idRecords
            .filter((_, j) => j !== deletePrimaryModal.index)
            .map(r => r.recordType === 'secondary' ? { ...r, recordType: 'primary' } : r);
          setIdRecords(updated);
          saveIdentityNow(updated);
          setDeletePrimaryModal({ open: false, index: -1 });
        }}
        onCancel={() => setDeletePrimaryModal({ open: false, index: -1 })}
      />
    </div>
  );
}
