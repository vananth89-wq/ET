import { useState, useMemo, useEffect, useRef } from 'react';
import { useSearchParams, useNavigate } from 'react-router-dom';
import WorkflowGateBanner from '../../workflow/components/WorkflowGateBanner';
import { supabase } from '../../lib/supabase';
import { useEmployees } from '../../hooks/useEmployees';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { useDepartments } from '../../hooks/useDepartments';
import { useCurrencies } from '../../hooks/useCurrencies';

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
  status?: 'Draft' | 'Incomplete' | 'Active' | 'Inactive';
  _completedSections?: string[];
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
];

const PHONE_CODES = [
  { code: '+1',   flag: '🇺🇸', label: '+1' },
  { code: '+7',   flag: '🇷🇺', label: '+7' },
  { code: '+27',  flag: '🇿🇦', label: '+27' },
  { code: '+33',  flag: '🇫🇷', label: '+33' },
  { code: '+34',  flag: '🇪🇸', label: '+34' },
  { code: '+39',  flag: '🇮🇹', label: '+39' },
  { code: '+44',  flag: '🇬🇧', label: '+44' },
  { code: '+49',  flag: '🇩🇪', label: '+49' },
  { code: '+52',  flag: '🇲🇽', label: '+52' },
  { code: '+55',  flag: '🇧🇷', label: '+55' },
  { code: '+60',  flag: '🇲🇾', label: '+60' },
  { code: '+61',  flag: '🇦🇺', label: '+61' },
  { code: '+62',  flag: '🇮🇩', label: '+62' },
  { code: '+63',  flag: '🇵🇭', label: '+63' },
  { code: '+64',  flag: '🇳🇿', label: '+64' },
  { code: '+65',  flag: '🇸🇬', label: '+65' },
  { code: '+66',  flag: '🇹🇭', label: '+66' },
  { code: '+81',  flag: '🇯🇵', label: '+81' },
  { code: '+82',  flag: '🇰🇷', label: '+82' },
  { code: '+84',  flag: '🇻🇳', label: '+84' },
  { code: '+86',  flag: '🇨🇳', label: '+86' },
  { code: '+91',  flag: '🇮🇳', label: '+91' },
  { code: '+92',  flag: '🇵🇰', label: '+92' },
  { code: '+94',  flag: '🇱🇰', label: '+94' },
  { code: '+880', flag: '🇧🇩', label: '+880' },
  { code: '+966', flag: '🇸🇦', label: '+966' },
  { code: '+971', flag: '🇦🇪', label: '+971' },
  { code: '+977', flag: '🇳🇵', label: '+977' },
];

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

function fmtDate(val?: string): string {
  if (!val) return '—';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}



// ─────────────────────────────────────────────────────────────────────────────
// Progress Tracker
// ─────────────────────────────────────────────────────────────────────────────
function ProgressTracker({ activeSection, completedSections, onJump }: {
  activeSection: string;
  completedSections: Set<string>;
  onJump: (id: string) => void;
}) {
  return (
    <div className="emp-form-progress">
      {SECTIONS.map((s, i) => {
        const isActive    = s.id === activeSection;
        const isCompleted = completedSections.has(s.id);
        return (
          <div key={s.id} style={{ display: 'flex', alignItems: 'center' }}>
            <div
              className={`efp-step ${isActive ? 'efp-active' : ''} ${isCompleted ? 'efp-done' : ''} ${s.optional ? 'efp-optional' : ''}`}
              title={`${s.label}${s.optional ? ' (Optional)' : ''}`}
              onClick={() => onJump(s.id)}
              style={{ cursor: 'pointer' }}
            >
              <div className="efp-icon">
                {isCompleted
                  ? <i className="fa-solid fa-check" />
                  : <i className={`fa-solid ${s.icon}`} />
                }
              </div>
              <span className="efp-label">{s.label}</span>
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
function NewHiresTable({ employees, onContinue, onDelete, picklistVals, departments }: {
  employees: FullEmployee[];
  onContinue: (emp: FullEmployee) => void;
  onDelete: (id: string) => void;
  picklistVals: PicklistValue[];
  departments: { deptId: string; name: string }[];
}) {
  const drafts = employees.filter(e => e.status === 'Draft' || e.status === 'Incomplete');
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
          {drafts.length} pending
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
  const autosaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const doAutosaveRef    = useRef<() => void>(() => {});
  const didMountRef      = useRef(false);
  // Set to true during handleActivate to block any in-flight or periodic autosave
  // from overwriting the newly-written 'Active' status back to 'Draft'.
  const isActivatingRef  = useRef(false);

  // ── Editing state ───────────────────────────────────────────────────────
  const [editingEmpId,  setEditingEmpId]  = useState<string | null>(null);
  // DB UUID of the employee currently being added/edited — used to exclude
  // them from the Manager dropdown even when empId doesn't match their record.
  const [currentEmpUUID, setCurrentEmpUUID] = useState<string | null>(null);

  // ── Section 1: Personal ─────────────────────────────────────────────────
  const [empName,        setEmpName]        = useState('');
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

  // ── Section 5: Identity ─────────────────────────────────────────────────
  const [idRecords,    setIdRecords]    = useState<IdRecord[]>([]);
  const [idCountry,    setIdCountry]    = useState('');
  const [idType,       setIdType]       = useState('');
  const [idRecordType, setIdRecordType] = useState('');
  const [idNumber,     setIdNumber]     = useState('');
  const [idExpiry,     setIdExpiry]     = useState('');

  // ── Section 6: Employment ───────────────────────────────────────────────
  const [designation,    setDesignation]    = useState('');
  const [deptId,         setDeptId]         = useState('');
  const [managerId,      setManagerId]      = useState('');
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

  // ── Delete confirmation ─────────────────────────────────────────────────
  const [deletingId, setDeletingId] = useState<string | null>(null);

  // ── Cancel & Exit confirmation modal ────────────────────────────────────
  const [exitModal, setExitModal] = useState(false);

  // ── Autosave indicators ─────────────────────────────────────────────────
  const [autosaveStatus, setAutosaveStatus] = useState<'idle' | 'saving' | 'saved'>('idle');
  const [lastAutoSaved,  setLastAutoSaved]  = useState<Date | null>(null);
  const [, setTick]                         = useState(0); // refreshes "X mins ago" every minute

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
      if (e.status === 'Draft' || e.status === 'Incomplete') return false;
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
    const empUUID = (emp as unknown as { id: string }).id || null;
    setCurrentEmpUUID(empUUID);
    setPhoto(emp.photo || '');
    setEmpName(emp.name || '');
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
    setErrors({});
    setActiveSection('personal');

    // Restore completed sections: start from persisted set, then overlay data-based checks
    const done = new Set<string>(emp._completedSections || []);
    // Data-based checks ensure required sections reflect actual data (overrides stale persisted state)
    if (emp.name && emp.employeeId) done.add('personal');    else done.delete('personal');
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
  }

  useEffect(() => {
    if (editId) {
      const emp = employees.find(e => e.employeeId === editId);
      if (emp) {
        loadEmployee(emp); // loadEmployee now also calls loadExtendedData internally
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editId]);

  // ── Reset form ──────────────────────────────────────────────────────────
  function resetForm() {
    setEditingEmpId(null);
    setCurrentEmpUUID(null);
    setPhoto('');
    setEmpName(''); setEmpId(generateEmpId(employees));
    setNationality(''); setMaritalStatus(''); setGender(''); setDob('');
    setCountryCode('+91'); setMobile('');
    setBusinessEmail(''); setPersonalEmail('');
    setPassportCountry(''); setPassportNumber(''); setPassportIssueDate(''); setPassportExpiry('');
    setIdRecords([]);
    setDesignation(''); setDeptId(''); setManagerId('');
    setHireDate(''); setEndDate('9999-12-31'); setProbationEnd('');
    setWorkCountry(''); setWorkLocation(''); setBaseCurrency('');
    setAddrLine1(''); setAddrLine2(''); setAddrLandmark(''); setAddrCity('');
    setAddrDistrict(''); setAddrState(''); setAddrPin(''); setAddrCountry('');
    setEcName(''); setEcRel(''); setEcPhone(''); setEcAltPhone(''); setEcEmail('');
    setErrors({});
    setCompleted(new Set());
    setActiveSection('personal');
    // Reset autosave state so the new-form fingerprint doesn't trigger immediately
    setLastAutoSaved(null);
    setAutosaveStatus('idle');
    if (autosaveTimerRef.current) clearTimeout(autosaveTimerRef.current);
    isActivatingRef.current = false;   // allow autosave again for the next employee
    didMountRef.current = false;
    navigate('/admin/add-employee', { replace: true });
  }

  // ── Utility: relative time label ────────────────────────────────────────
  function getRelativeTime(date: Date): string {
    const mins = Math.round((Date.now() - date.getTime()) / 60000);
    if (mins < 1)   return 'just now';
    if (mins === 1) return '1 min ago';
    return `${mins} mins ago`;
  }

  // ── Utility: brief toast notification ───────────────────────────────────
  function showToast(message: string, type: 'success' | 'error' = 'success') {
    setToast({ message, type });
    setTimeout(() => setToast(null), 3000);
  }

  // ── Utility: detect unsaved changes (lazy, called only at exit time) ────
  function hasUnsavedChanges(): boolean {
    const existing = employees.find(e => e.employeeId === empId.trim());
    if (!existing) return empName.trim().length > 0; // new employee with content
    return (
      empName       !== (existing.name            || '') ||
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

  // ── Core manual save (flush + recompute status + toast) ─────────────────
  async function performSave(thenExit = false): Promise<boolean> {
    const effectiveIdRecords = activeSection === 'identity' ? flushPendingIdRecord() : idRecords;
    const data = collectData(effectiveIdRecords);
    const requiredSections = SECTIONS.filter(s => !s.optional).map(s => s.id);
    const nowCompleted = new Set([...completed, activeSection]);
    if (!effectiveIdRecords.length) nowCompleted.delete('identity');
    if (!passportNumber.trim())     nowCompleted.delete('passport');
    setCompleted(nowCompleted);
    const allRequired = requiredSections.every(id => nowCompleted.has(id));
    const status: 'Draft' | 'Incomplete' = allRequired ? 'Incomplete' : 'Draft';

    // Build the DB payload — only core employees table columns
    // personal/contact/employment satellite columns are saved via saveExtendedData
    const dbPayload: Record<string, unknown> = {
      employee_id:      data.employeeId,
      name:             data.name,
      business_email:   data.businessEmail      || null,
      designation:      data.designation        || null,
      dept_id:          data.deptId             || null,
      manager_id:       data.managerId          || null,
      hire_date:        data.hireDate           || null,
      end_date:         data.endDate            || null,
      work_country:     data.workCountry        || null,
      work_location:    data.workLocation       || null,
      base_currency_id: (data as {baseCurrency?: string}).baseCurrency || null,
      status,
    };

    const existingRow = allEmployees.find(e => e.employeeId === (editingEmpId || data.employeeId));
    // Also use currentEmpUUID set by autosave in case allEmployees hasn't refreshed yet
    const knownUUID   = currentEmpUUID || existingRow?.id;
    let empUUID: string;

    if (knownUUID) {
      const { error: dbErr } = await supabase
        .from('employees')
        .update(dbPayload as any)
        .eq('id', knownUUID);
      if (dbErr) { showToast(`Save failed: ${dbErr.message}`, 'error'); return false; }
      empUUID = knownUUID;
    } else {
      const { data: inserted, error: dbErr } = await supabase
        .from('employees')
        .insert(dbPayload as any)
        .select('id')
        .single();
      if (dbErr || !inserted) { showToast(`Save failed: ${dbErr?.message ?? 'unknown error'}`, 'error'); return false; }
      empUUID = inserted.id;
      setCurrentEmpUUID(empUUID);
    }

    const extErrors = await saveExtendedData(empUUID, data);
    refetchEmployees();
    if (extErrors.length > 0) {
      showToast(`Saved with errors: ${extErrors[0]}`, 'error');
    } else {
      showToast('Draft saved', 'success');
    }
    if (thenExit) resetForm();
    return true;
  }

  // ── Silent autosave (no validation, no flush, preserves status) ──────────
  async function doAutosave() {
    // Block autosave while activation is in progress — otherwise an in-flight
    // or periodic autosave could overwrite the 'Active' status back to 'Draft'.
    if (isActivatingRef.current) return;
    if (!empName.trim() || !empId.trim()) return;
    setAutosaveStatus('saving');
    const data = collectData(idRecords);

    // Prefer currentEmpUUID (already-captured UUID from a prior autosave) so we
    // don't have to depend on allEmployees having refreshed yet — avoids the race
    // condition where a stale list causes a duplicate INSERT attempt.
    const existingRow = allEmployees.find(e => e.employeeId === (editingEmpId || data.employeeId));
    const knownUUID   = currentEmpUUID || existingRow?.id;

    // Autosave payload — core employees columns only (satellite tables via saveExtendedData)
    const dbPayload: Record<string, unknown> = {
      employee_id:      data.employeeId,
      name:             data.name,
      business_email:   data.businessEmail      || null,
      designation:      data.designation        || null,
      dept_id:          data.deptId             || null,
      manager_id:       data.managerId          || null,
      hire_date:        data.hireDate           || null,
      end_date:         data.endDate            || null,
      work_country:     data.workCountry        || null,
      work_location:    data.workLocation       || null,
      base_currency_id: (data as {baseCurrency?: string}).baseCurrency || null,
      status:           existingRow?.status ?? 'Draft',
    };

    let empUUID: string | undefined;
    if (knownUUID) {
      // Employee already exists — UPDATE by primary key (no stale-list dependency)
      await supabase.from('employees').update(dbPayload as any).eq('id', knownUUID);
      empUUID = knownUUID;
    } else {
      // First autosave for a brand-new employee — INSERT
      const { data: inserted } = await supabase.from('employees').insert(dbPayload as any).select('id').single();
      empUUID = inserted?.id;
    }

    if (empUUID) {
      setCurrentEmpUUID(empUUID);
      const extErrors = await saveExtendedData(empUUID, data);
      if (extErrors.length > 0) {
        console.warn('[doAutosave] extended data errors:', extErrors);
      }
    }
    refetchEmployees();
    setLastAutoSaved(new Date());
    setTimeout(() => setAutosaveStatus('saved'), 400);
    setTimeout(() => setAutosaveStatus('idle'), 3400);
  }

  // ── Cancel & Exit ────────────────────────────────────────────────────────
  function handleCancelExit() {
    if (hasUnsavedChanges()) { setExitModal(true); } else { resetForm(); }
  }

  // ── Auto-generate employee ID once employees list has loaded ─────────────
  // Runs whenever `employees` changes, but only updates empId if:
  //   1. We're not editing an existing employee (no editId / editingEmpId)
  //   2. The field hasn't been manually changed (still blank OR still matches a generated ID)
  useEffect(() => {
    if (editId || editingEmpId) return;          // don't overwrite while editing
    if (employees.length === 0) return;           // wait until list arrives from Supabase
    const generated = generateEmpId(employees);
    setEmpId(prev => {
      // Only overwrite if field is blank or looks like an auto-generated value
      if (!prev || /^EMP\d+$/.test(prev)) return generated;
      return prev;
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [employees]);

  // ── Keep doAutosaveRef pointing at the latest closure ────────────────────
  // (standard pattern to avoid stale state in setInterval callbacks)
  useEffect(() => { doAutosaveRef.current = doAutosave; }); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Debounced autosave: 2.5 s after last field change ────────────────────
  const formFingerprint = [
    empName, empId, nationality, maritalStatus, gender, dob,
    mobile, businessEmail, personalEmail,
    designation, deptId, managerId, hireDate, endDate, probationEnd,
    workCountry, workLocation,
    addrLine1, addrLine2, addrLandmark, addrCity, addrDistrict, addrState, addrPin, addrCountry,
    ecName, ecRel, ecPhone, ecAltPhone, ecEmail,
    passportCountry, passportNumber, passportIssueDate, passportExpiry,
    JSON.stringify(idRecords),
  ].join('|');

  useEffect(() => {
    if (!didMountRef.current) { didMountRef.current = true; return; }
    if (!empName.trim() || !empId.trim()) return;
    if (autosaveTimerRef.current) clearTimeout(autosaveTimerRef.current);
    autosaveTimerRef.current = setTimeout(() => doAutosaveRef.current(), 2500);
  }, [formFingerprint]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Periodic autosave fallback: every 45 s ───────────────────────────────
  useEffect(() => {
    const id = setInterval(() => doAutosaveRef.current(), 45000);
    return () => {
      clearInterval(id);
      if (autosaveTimerRef.current) clearTimeout(autosaveTimerRef.current);
    };
  }, []);

  // ── Clock tick: refresh "X mins ago" label every 60 s ───────────────────
  useEffect(() => {
    const id = setInterval(() => setTick(t => t + 1), 60000);
    return () => clearInterval(id);
  }, []);

  // ── Compute effective idRecords, flushing any fully-filled pending form entry ─
  // Returns the new list (may equal idRecords if nothing to flush).
  // Also updates state side-effects so subsequent renders are consistent.
  function flushPendingIdRecord(): IdRecord[] {
    const pendingComplete =
      idCountry && idType && idRecordType && idNumber.trim() && idExpiry;
    if (!pendingComplete) return idRecords;

    // Run same validations as addIdRecord before auto-flushing
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
    return {
      employeeId: empId.trim(),
      name: empName.trim(),
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
  async function saveExtendedData(empUUID: string, data: Partial<FullEmployee>): Promise<string[]> {
    const errors: string[] = [];

    // ── employee_personal (upsert) ───────────────────────────────────────
    if (data.nationality || data.maritalStatus || data.gender || data.dob || data.photo) {
      const { error: personalErr } = await supabase
        .from('employee_personal')
        .upsert({
          employee_id:    empUUID,
          nationality:    data.nationality    || null,
          marital_status: data.maritalStatus  || null,
          gender:         data.gender         || null,
          dob:            data.dob            || null,
          photo_url:      data.photo          || null,
        }, { onConflict: 'employee_id' });
      if (personalErr) { console.error('[saveExtendedData] employee_personal:', personalErr); errors.push(`Personal: ${personalErr.message}`); }
    }

    // ── employee_contact (upsert) ────────────────────────────────────────
    if (data.countryCode || data.mobile || data.personalEmail) {
      const { error: contactErr } = await supabase
        .from('employee_contact')
        .upsert({
          employee_id:    empUUID,
          country_code:   data.countryCode    || null,
          mobile:         data.mobile         || null,
          personal_email: data.personalEmail  || null,
        }, { onConflict: 'employee_id' });
      if (contactErr) { console.error('[saveExtendedData] employee_contact:', contactErr); errors.push(`Contact: ${contactErr.message}`); }
    }

    // ── employee_employment (upsert) ─────────────────────────────────────
    if (data.probationEndDate) {
      const { error: employmentErr } = await supabase
        .from('employee_employment')
        .upsert({
          employee_id:        empUUID,
          probation_end_date: data.probationEndDate || null,
        }, { onConflict: 'employee_id' });
      if (employmentErr) { console.error('[saveExtendedData] employee_employment:', employmentErr); errors.push(`Employment: ${employmentErr.message}`); }
    }

    // ── Passport (delete-then-insert, at most one row) ──────────────────
    const { error: passDel } = await supabase.from('passports').delete().eq('employee_id', empUUID);
    if (passDel) { console.error('[saveExtendedData] passport delete:', passDel); errors.push(`Passport: ${passDel.message}`); }
    else if (data.passportCountry || data.passportNumber || data.passportIssueDate || data.passportExpiryDate) {
      const { error: passIns } = await supabase.from('passports').insert({
        employee_id:     empUUID,
        country:         data.passportCountry    || null,
        passport_number: data.passportNumber     || null,
        issue_date:      data.passportIssueDate  || null,
        expiry_date:     data.passportExpiryDate || null,
      });
      if (passIns) { console.error('[saveExtendedData] passport insert:', passIns); errors.push(`Passport: ${passIns.message}`); }
    }

    // ── Address ─────────────────────────────────────────────────────────
    const { error: addrDel } = await supabase.from('employee_addresses').delete().eq('employee_id', empUUID);
    if (addrDel) { console.error('[saveExtendedData] address delete:', addrDel); errors.push(`Address: ${addrDel.message}`); }
    else if (data.addrLine1 || data.addrCity || data.addrCountry) {
      const { error: addrIns } = await supabase.from('employee_addresses').insert({
        employee_id: empUUID,
        line1:       data.addrLine1    || null,
        line2:       data.addrLine2    || null,
        landmark:    data.addrLandmark || null,
        city:        data.addrCity     || null,
        district:    data.addrDistrict || null,
        state:       data.addrState    || null,
        pin:         data.addrPin      || null,
        country:     data.addrCountry  || null,
      });
      if (addrIns) { console.error('[saveExtendedData] address insert:', addrIns); errors.push(`Address: ${addrIns.message}`); }
    }

    // ── Emergency contact ────────────────────────────────────────────────
    const { error: ecDel } = await supabase.from('emergency_contacts').delete().eq('employee_id', empUUID);
    if (ecDel) { console.error('[saveExtendedData] emergency_contact delete:', ecDel); errors.push(`Emergency contact: ${ecDel.message}`); }
    else if (data.ecName || data.ecPhone) {
      const { error: ecIns } = await supabase.from('emergency_contacts').insert({
        employee_id:  empUUID,
        name:         data.ecName         || '',
        relationship: data.ecRelationship || null,
        phone:        data.ecPhone        || null,
        alt_phone:    data.ecAltPhone     || null,
        email:        data.ecEmail        || null,
      });
      if (ecIns) { console.error('[saveExtendedData] emergency_contact insert:', ecIns); errors.push(`Emergency contact: ${ecIns.message}`); }
    }

    // ── Identity records (replace all) ───────────────────────────────────
    const { error: idDel } = await supabase.from('identity_records').delete().eq('employee_id', empUUID);
    if (idDel) { console.error('[saveExtendedData] identity_records delete:', idDel); errors.push(`Identity records: ${idDel.message}`); }
    else {
      const idRecs = (data.idRecords as IdRecord[] | undefined) ?? [];
      if (idRecs.length > 0) {
        const { error: idIns } = await supabase.from('identity_records').insert(
          idRecs.map(r => ({
            employee_id:  empUUID,
            country:      r.country     || null,
            id_type:      r.idType      || null,
            record_type:  r.recordType  || null,
            id_number:    r.idNumber    || null,
            expiry:       r.expiry      || null,
          }))
        );
        if (idIns) { console.error('[saveExtendedData] identity_records insert:', idIns); errors.push(`Identity records: ${idIns.message}`); }
      }
    }

    return errors;
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
    ] = await Promise.all([
      supabase.from('passports').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('employee_addresses').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('emergency_contacts').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('identity_records').select('*').eq('employee_id', empUUID),
      supabase.from('employee_personal').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('employee_contact').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('employee_employment').select('*').eq('employee_id', empUUID).limit(1),
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

    // employee_personal satellite
    const pers = personalRow?.[0];
    if (pers) {
      setNationality(  pers.nationality    || '');
      setMaritalStatus(pers.marital_status || '');
      setGender(       pers.gender         || '');
      setDob(          pers.dob            || '');
      setPhoto(        pers.photo_url      || '');
    }

    // employee_contact satellite
    const cont = contactRow?.[0];
    if (cont) {
      setCountryCode(  cont.country_code   || '+91');
      setMobile(       cont.mobile         || '');
      setPersonalEmail(cont.personal_email || '');
    }

    // employee_employment satellite
    const emp = employmentRow?.[0];
    if (emp) {
      setProbationEnd(emp.probation_end_date || '');
    }

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
      return done;
    });
  }

  // ── Validate section ────────────────────────────────────────────────────
  function validateSection(sectionId: string): Record<string, string> {
    const errs: Record<string, string> = {};
    switch (sectionId) {
      case 'personal':
        if (!empName.trim()) errs.empName = 'Full name is required.';
        if (!empId.trim())   errs.empId   = 'Employee ID is required.';
        if (!nationality)    errs.nationality = 'Nationality is required.';
        if (!maritalStatus)  errs.maritalStatus = 'Marital status is required.';
        if (!gender)         errs.gender = 'Gender is required.';
        if (!dob)            errs.dob = 'Date of birth is required.';
        break;
      case 'contact':
        if (!mobile.trim()) errs.mobile = 'Mobile number is required.';
        else if (!/^\d{7,15}$/.test(mobile.trim())) errs.mobile = 'Enter 7–15 digits only.';
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
        if (businessEmail.trim() && personalEmail.trim() &&
            businessEmail.trim().toLowerCase() === personalEmail.trim().toLowerCase())
          errs.personalEmail = 'Personal email cannot be the same as business email.';
        break;
      case 'passport':
        // Only validate dependent fields when Issue Country is selected
        if (passportCountry) {
          if (!passportNumber.trim()) errs.passportNumber    = 'Passport Number is required.';
          if (!passportIssueDate)     errs.passportIssueDate = 'Issue Date is required.';
          if (!passportExpiry)        errs.passportExpiry    = 'Expiry Date is required.';
        }
        break;
      case 'employment':
        if (!designation)   errs.designation   = 'Designation is required.';
        if (!deptId)        errs.deptId        = 'Department is required.';
        if (!hireDate)      errs.hireDate      = 'Hire date is required.';
        if (!probationEnd)  errs.probationEnd  = 'Probation end date is required.';
        if (!workCountry)   errs.workCountry   = 'Country of work is required.';
        if (!workLocation)  errs.workLocation  = 'Location is required.';
        break;
      case 'address':
        if (!addrLine1.trim()) errs.addrLine1 = 'Address line 1 is required.';
        if (!addrLine2.trim()) errs.addrLine2 = 'Address line 2 is required.';
        if (!addrCity.trim())  errs.addrCity  = 'City is required.';
        if (!addrPin.trim())   errs.addrPin   = 'PIN / ZIP code is required.';
        if (!addrCountry)      errs.addrCountry = 'Country is required.';
        break;
      case 'emergency':
        if (!ecName.trim())  errs.ecName  = 'Contact name is required.';
        if (!ecRel)          errs.ecRel   = 'Relationship is required.';
        if (!ecPhone.trim()) errs.ecPhone = 'Phone number is required.';
        break;
    }
    return errs;
  }

  // ── Save section ─────────────────────────────────────────────────────────
  function saveSection(sectionId: string) {
    const errs = validateSection(sectionId);
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
  function handleNext() {
    // Auto-commit any fully-filled pending ID form before saving
    if (activeSection === 'identity') flushPendingIdRecord();
    if (!saveSection(activeSection)) return;

    // Immediately flush any pending debounced autosave so data isn't lost
    // if the user navigates away from the page before the 2.5s timer fires.
    if (autosaveTimerRef.current) clearTimeout(autosaveTimerRef.current);
    doAutosaveRef.current(); // fire-and-forget; component is still mounted

    const idx = SECTIONS.findIndex(s => s.id === activeSection);
    if (idx < SECTIONS.length - 1) {
      setActiveSection(SECTIONS[idx + 1].id);
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  }

  // ── Save as Draft ────────────────────────────────────────────────────────
  async function handleSaveDraft() {
    // Validate current section before manual save
    const errs = validateSection(activeSection);
    if (Object.keys(errs).length > 0) { setErrors(errs); return; }
    setErrors({});
    // Employee name is the minimum requirement to save from any section
    if (!empName.trim()) {
      setErrors({ empName: 'Employee name is required to save a draft.' });
      setActiveSection('personal');
      return;
    }
    await performSave();
  }

  // ── Activate employee ────────────────────────────────────────────────────
  async function handleActivate() {
    // Block all autosave writes (debounced and periodic) for the duration of
    // activation. doAutosave checks isActivatingRef before touching the DB.
    isActivatingRef.current = true;
    // Also cancel any pending debounced autosave timer.
    if (autosaveTimerRef.current) clearTimeout(autosaveTimerRef.current);

    // Validate all non-optional sections
    const allErrors: Record<string, string> = {};
    const requiredSections = SECTIONS.filter(s => !s.optional).map(s => s.id);
    for (const sid of requiredSections) {
      const errs = validateSection(sid);
      Object.assign(allErrors, errs);
    }
    if (Object.keys(allErrors).length > 0) {
      setErrors(allErrors);
      // Navigate to first section with error
      const firstBad = requiredSections.find(sid => Object.keys(validateSection(sid)).length > 0);
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

    // Activate payload — core employees columns only (satellite via saveExtendedData)
    const dbPayload: Record<string, unknown> = {
      employee_id:      data.employeeId,
      name:             data.name,
      business_email:   data.businessEmail      || null,
      designation:      data.designation        || null,
      dept_id:          data.deptId             || null,
      manager_id:       data.managerId          || null,
      hire_date:        data.hireDate           || null,
      end_date:         data.endDate            || null,
      work_country:     data.workCountry        || null,
      work_location:    data.workLocation       || null,
      base_currency_id: (data as {baseCurrency?: string}).baseCurrency || null,
      status:           'Active',
    };

    let empUUID: string | null = null;
    if (existingRow) {
      const { error } = await supabase.from('employees').update(dbPayload as any).eq('id', existingRow.id);
      if (error) { setErrors({ _global: error.message } as Record<string, string>); return; }
      empUUID = existingRow.id;
    } else {
      const { data: inserted, error } = await supabase.from('employees').insert(dbPayload as any).select('id').single();
      if (error || !inserted) { setErrors({ _global: error?.message ?? 'Insert failed' } as Record<string, string>); return; }
      empUUID = inserted.id;
    }

    const extErrors = await saveExtendedData(empUUID!, data);
    if (extErrors.length > 0) {
      console.error('[handleActivate] extended data errors:', extErrors);
      showToast(`Activated but some data failed to save: ${extErrors[0]}`, 'error');
    }

    // ── Send welcome email + link profile → employee ──────────────────────
    const businessEmail = (data.businessEmail ?? '').trim();
    if (businessEmail) {
      // 1. Send the welcome / magic-link email via Supabase Auth.
      //    shouldCreateUser: true creates the auth user if not yet present.
      //    The Invite email template should use:
      //    {{ .SiteURL }}/reset-password?token_hash={{ .TokenHash }}&type=invite
      const { error: otpError } = await supabase.auth.signInWithOtp({
        email: businessEmail,
        options: {
          shouldCreateUser: true,
          emailRedirectTo: `${window.location.origin}/reset-password`,
          data: { full_name: data.name },
        },
      });

      if (otpError) {
        console.error('[handleActivate] signInWithOtp error:', otpError.message);
        showToast(`Employee activated but welcome email failed: ${otpError.message}`, 'error');
      } else {
        // 2. Link the auth profile → employee + grant ESS.
        //    The auth user may not exist yet if the email hasn't been delivered,
        //    so we call this with a short retry tolerance (the RPC handles it).
        const { data: rpcData, error: rpcError } = await supabase.rpc(
          'link_profile_to_employee',
          { p_email: businessEmail }
        );

        if (rpcError) {
          console.warn('[handleActivate] link_profile_to_employee RPC error:', rpcError.message);
          // Non-fatal — the handle_new_user trigger will link on first sign-in
        } else if (rpcData && !(rpcData as { ok: boolean }).ok) {
          const reason = (rpcData as { ok: boolean; reason?: string }).reason ?? '';
          // "auth user not found" is expected before the user clicks the link — not an error
          if (!reason.includes('auth user not found')) {
            console.warn('[handleActivate] link_profile_to_employee:', reason);
          }
        }

        // 3. Record the invite in employee_invites audit table
        //    (get the latest attempt_no first)
        const { data: lastInvite } = await supabase
          .from('employee_invites')
          .select('attempt_no')
          .eq('employee_id', empUUID!)
          .order('attempt_no', { ascending: false })
          .limit(1)
          .maybeSingle();

        const nextAttempt = lastInvite ? (lastInvite.attempt_no ?? 0) + 1 : 1;

        await supabase.from('employee_invites').insert({
          employee_id: empUUID!,
          attempt_no:  nextAttempt,
          sent_at:     new Date().toISOString(),
          status:      'sent',
        });

        // 4. Stamp invite_sent_at on the employee row
        await supabase
          .from('employees')
          .update({ invite_sent_at: new Date().toISOString() })
          .eq('id', empUUID!);

        showToast('Employee activated and welcome email sent!', 'success');
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
  async function saveIdentityNow(records: IdRecord[]) {
    const uuid = currentEmpUUID || allEmployees.find(e => e.employeeId === (editingEmpId || empId.trim()))?.id;
    if (!uuid) {
      // Employee row doesn't exist yet — debounce autosave will handle it once the row is created
      showToast('ID record queued — will save with next autosave', 'success');
      return;
    }
    setAutosaveStatus('saving');
    const { error: delErr } = await supabase.from('identity_records').delete().eq('employee_id', uuid);
    if (delErr) {
      console.error('[saveIdentityNow] delete:', delErr);
      showToast(`Failed to save ID record: ${delErr.message}`, 'error');
      setAutosaveStatus('idle');
      return;
    }
    if (records.length > 0) {
      const { error: insErr } = await supabase.from('identity_records').insert(
        records.map(r => ({
          employee_id:  uuid,
          country:      r.country     || null,
          id_type:      r.idType      || null,
          record_type:  r.recordType  || null,
          id_number:    r.idNumber    || null,
          expiry:       r.expiry      || null,
        }))
      );
      if (insErr) {
        console.error('[saveIdentityNow] insert:', insErr);
        showToast(`Failed to save ID record: ${insErr.message}`, 'error');
        setAutosaveStatus('idle');
        return;
      }
    }
    setLastAutoSaved(new Date());
    showToast(records.length > 0 ? 'ID record saved' : 'ID record removed', 'success');
    setTimeout(() => setAutosaveStatus('saved'), 400);
    setTimeout(() => setAutosaveStatus('idle'), 3400);
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
  const allRequiredDone = useMemo(() => {
    return SECTIONS.filter(s => !s.optional).every(s => completed.has(s.id));
  }, [completed]);

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
            <div className={`form-group ${errors.empName ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-user fa-fw" /> Full Name</label>
              <input type="text" value={empName} onChange={e => setEmpName(e.target.value)}
                placeholder="e.g. Vijey Ananthan" required />
              <FieldError msg={errors.empName} />
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
                type="date"
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
                <select value={countryCode} onChange={e => setCountryCode(e.target.value)} className="country-code-select">
                  {PHONE_CODES.map(p => (
                    <option key={p.code} value={p.code}>{p.flag} {p.label}</option>
                  ))}
                </select>
                <input type="tel" value={mobile} onChange={e => setMobile(e.target.value)}
                  placeholder="e.g. 9876543210" required />
              </div>
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
              <select value={passportCountry} onChange={e => setPassportCountry(e.target.value)}>
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
                onChange={e => { setPassportNumber(e.target.value); setErrors(p => ({ ...p, passportNumber: '' })); }}
                placeholder="e.g. A1234567" />
              <FieldError msg={errors.passportNumber} />
            </div>
            <div className={`form-group ${errors.passportIssueDate ? 'form-group--error' : ''}`}>
              <label>
                <i className="fa-solid fa-calendar-plus fa-fw" /> Issue Date
                {passportCountry && <span style={{ color: '#e53935' }}> *</span>}
              </label>
              <input type="date" value={passportIssueDate}
                onChange={e => { setPassportIssueDate(e.target.value); setErrors(p => ({ ...p, passportIssueDate: '' })); }} />
              <FieldError msg={errors.passportIssueDate} />
            </div>
            <div className={`form-group ${errors.passportExpiry ? 'form-group--error' : ''}`}>
              <label>
                <i className="fa-solid fa-calendar-xmark fa-fw" /> Expiry Date
                {passportCountry && <span style={{ color: '#e53935' }}> *</span>}
              </label>
              <input type="date" value={passportExpiry}
                onChange={e => { setPassportExpiry(e.target.value); setErrors(p => ({ ...p, passportExpiry: '' })); }} />
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
                            const updated = idRecords.filter((_, j) => j !== i);
                            setIdRecords(updated);
                            saveIdentityNow(updated);
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
                <select value={idCountry} onChange={e => { setIdCountry(e.target.value); setIdType(''); setErrors(p => ({ ...p, idCountry: '' })); }}>
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
                    setErrors(p => ({ ...p, idType: '' }));
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
                <select value={idRecordType} onChange={e => { setIdRecordType(e.target.value); setErrors(p => ({ ...p, idRecordType: '' })); }}>
                  <option value="">-- Select --</option>
                  <option value="primary" disabled={idRecords.some(r => r.recordType === 'primary')}>
                    {idRecords.some(r => r.recordType === 'primary') ? '⭐ Primary (already assigned)' : '⭐ Primary'}
                  </option>
                  <option value="secondary">Secondary</option>
                </select>
                <FieldError msg={errors.idRecordType} />
              </div>
            </div>
            <div className="emp-field-grid emp-id-grid-bottom">
              <div className={`form-group ${errors.idNumber ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-hashtag fa-fw" /> ID Number{idType && <span style={{ color: '#e53935' }}> *</span>}</label>
                <input type="text" value={idNumber} onChange={e => { setIdNumber(e.target.value); setErrors(p => ({ ...p, idNumber: '' })); }}
                  placeholder="e.g. 1234-5678-9012" />
                <FieldError msg={errors.idNumber} />
              </div>
              <div className={`form-group ${errors.idExpiry ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-calendar-xmark fa-fw" /> Expiry Date{idType && <span style={{ color: '#e53935' }}> *</span>}</label>
                <input type="date" value={idExpiry} onChange={e => { setIdExpiry(e.target.value); setErrors(p => ({ ...p, idExpiry: '' })); }} />
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
            <div className="form-group">
              <label><i className="fa-solid fa-user-tie fa-fw" /> Manager</label>
              <select value={managerId} onChange={e => setManagerId(e.target.value)}>
                <option value="">-- No Manager --</option>
                {managers.map(e => <option key={(e as unknown as {id: string}).id} value={(e as unknown as {id: string}).id}>{e.name} ({e.employeeId})</option>)}
              </select>
            </div>
            <div className={`form-group ${errors.hireDate ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-calendar-check fa-fw" /> Hire Date</label>
              <input type="date" value={hireDate} onChange={e => setHireDate(e.target.value)} required />
              <FieldError msg={errors.hireDate} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-calendar-xmark fa-fw" /> End Date</label>
              <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} />
            </div>
            <div className={`form-group ${errors.probationEnd ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-hourglass-half fa-fw" /> Probation End Date</label>
              <input type="date" value={probationEnd}
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
        ? <WorkflowGateBanner moduleCode="employee_edit"        actionLabel="employee detail edits" />
        : <WorkflowGateBanner moduleCode="employee_onboarding"  actionLabel="new employee creation" />
      }

      <h2 className="page-title" style={{ marginBottom: 20 }}>
        {editingEmpId ? 'Edit Employee' : 'Add New Employee'}
      </h2>

      {/* ── Form Card ──────────────────────────────────────────────────── */}
      <div className="emp-form-card" style={{ marginBottom: 24 }}>

        {/* Form Header */}
        <div className="emp-form-header">
          <div className="emp-form-avatar" onClick={() => photoRef.current?.click()} title="Click to change photo" style={{ cursor: 'pointer' }}>
            {photo
              ? <img src={photo} alt={empName || 'Employee'} style={{ width: '100%', height: '100%', objectFit: 'cover', borderRadius: '50%' }} />
              : empName
                ? <img src={getAvatar({ name: empName })} alt={empName} style={{ width: '100%', height: '100%', objectFit: 'cover', borderRadius: '50%' }} />
                : <i className="fa-solid fa-user" />
            }
            <input ref={photoRef} type="file" accept="image/*" hidden onChange={handlePhotoUpload} />
          </div>
          <div className="emp-form-header-text">
            <h3>{empName || 'New Employee'}</h3>
            <p>Fill in the details below. Role is auto-derived from org structure.</p>
          </div>
        </div>

        {/* Progress Tracker */}
        <ProgressTracker
          activeSection={activeSection}
          completedSections={completed}
          onJump={jumpToSection}
        />

        {/* Section body */}
        <form onSubmit={e => e.preventDefault()}>
          {renderSection()}

          {/* Footer actions */}
          <div className="emp-form-footer">
            {/* LEFT group: Cancel & Exit + Back */}
            <div className="emp-footer-left">
              <button type="button" className="emp-btn-exit" onClick={handleCancelExit}>
                <i className="fa-solid fa-xmark" /> Cancel &amp; Exit
              </button>
              {currentSectionIdx > 0 && (
                <button
                  type="button"
                  className="emp-btn-ghost"
                  onClick={() => setActiveSection(SECTIONS[currentSectionIdx - 1].id)}
                >
                  <i className="fa-solid fa-arrow-left" /> Back
                </button>
              )}
            </div>

            {/* CENTER: autosave status indicator */}
            <div className="emp-autosave-wrap">
              {autosaveStatus === 'saving' && (
                <span className="emp-autosave-status emp-autosave-status--saving">
                  <i className="fa-solid fa-spinner fa-spin" /> Saving…
                </span>
              )}
              {autosaveStatus === 'saved' && (
                <span className="emp-autosave-status emp-autosave-status--saved">
                  <i className="fa-solid fa-circle-check" /> Saved
                </span>
              )}
              {autosaveStatus === 'idle' && lastAutoSaved && (
                <span className="emp-autosave-status">
                  <i className="fa-regular fa-clock" /> Last saved {getRelativeTime(lastAutoSaved)}
                </span>
              )}
            </div>

            {/* RIGHT group: Save Draft + Next / Activate */}
            <div className="emp-footer-right">
              <button type="button" className="emp-btn-secondary" onClick={handleSaveDraft}>
                <i className="fa-solid fa-floppy-disk" /> Save Draft
              </button>
              {!isLastSection ? (
                <button type="button" className="emp-btn-primary" onClick={handleNext}>
                  Next <i className="fa-solid fa-arrow-right" />
                </button>
              ) : (
                <button
                  type="button"
                  className="emp-btn-primary"
                  onClick={handleActivate}
                  title={!allRequiredDone ? 'Complete all required sections to activate' : ''}
                >
                  <i className="fa-solid fa-user-check" /> Activate Employee
                </button>
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
            <div className="modal-body">{infoModal.message}</div>
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
    </div>
  );
}
