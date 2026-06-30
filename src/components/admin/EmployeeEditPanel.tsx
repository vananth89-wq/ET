import { useState, useMemo, useEffect, useRef, useCallback } from 'react';
import { validateMobile, mobilePlaceholder, mobileHint } from '../../utils/validateMobile';
import { validatePassportNumber, validatePassportValidity, passportNumberPlaceholder, passportNumberHint, passportValidityHint } from '../../utils/validatePassport';
import { validateIdentityNumber, idNumberPlaceholder, idNumberHint, defaultExpiryDate, idValidityLabel } from '../../utils/validateIdentity';
import { supabase } from '../../lib/supabase';
import WorkflowGateBanner from '../../workflow/components/WorkflowGateBanner';
import { useEmployees } from '../../hooks/useEmployees';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { useDepartments } from '../../hooks/useDepartments';
import { useCurrencies } from '../../hooks/useCurrencies';
import type { FullEmployee } from './AddEmployee';
import { COUNTRIES } from './AddEmployee';
import BankAccountsPortlet from '../shared/BankAccountsPortlet';
import DependentsPortlet from '../shared/DependentsPortlet';
import JobRelationshipsPortlet from '../shared/JobRelationshipsPortlet';
import EducationPortlet        from '../shared/EducationPortlet';
import TerminationPortlet      from '../shared/TerminationPortlet';
import DeactivationImpactModal from './DeactivationImpactModal';
import ConfirmationModal        from '../shared/ConfirmationModal';
import { usePermissions } from '../../hooks/usePermissions';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────
interface IdRecord {
  country: string;
  idType: string;
  recordType: string;
  idNumber: string;
  expiry: string;
}

interface Props {
  emp: FullEmployee;
  onClose: () => void;
  onSaved?: () => void;
  /** Pre-open employment section in a specific mode on mount */
  initialEmploymentMode?: 'edit' | 'insert';
  /** For edit mode: which slice to pre-select (effective_from date string) */
  initialEmploymentEffectiveFrom?: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────
const PHONE_CODES = [
  { code: '+1',   label: '🇺🇸 +1'   }, { code: '+7',   label: '🇷🇺 +7'   },
  { code: '+27',  label: '🇿🇦 +27'  }, { code: '+33',  label: '🇫🇷 +33'  },
  { code: '+44',  label: '🇬🇧 +44'  }, { code: '+49',  label: '🇩🇪 +49'  },
  { code: '+61',  label: '🇦🇺 +61'  }, { code: '+65',  label: '🇸🇬 +65'  },
  { code: '+81',  label: '🇯🇵 +81'  }, { code: '+86',  label: '🇨🇳 +86'  },
  { code: '+91',  label: '🇮🇳 +91'  }, { code: '+971', label: '🇦🇪 +971' },
];

const SECTIONS = [
  { id: 'personal',   label: 'Personal Information',    icon: 'fa-circle-user',       optional: false },
  { id: 'contact',    label: 'Phone',                   icon: 'fa-phone',             optional: false },
  { id: 'email',      label: 'Email',                   icon: 'fa-envelope',          optional: false },
  { id: 'employment', label: 'Employment',              icon: 'fa-briefcase',         optional: false },
  { id: 'identity',   label: 'Employee Identification', icon: 'fa-id-card-clip',      optional: true  },
  { id: 'passport',   label: 'Passport Information',    icon: 'fa-passport',          optional: true  },
  { id: 'address',    label: 'Address',                 icon: 'fa-location-dot',      optional: false },
  { id: 'emergency',  label: 'Emergency Contact',       icon: 'fa-phone-volume',      optional: false },
  { id: 'bank',              label: 'Bank Accounts',     icon: 'fa-building-columns',  optional: false },
  { id: 'dependents',       label: 'Dependents',        icon: 'fa-people-group',      optional: false },
  { id: 'job_relationships', label: 'Job Relationships', icon: 'fa-sitemap',           optional: false },
  { id: 'education',         label: 'Education',         icon: 'fa-graduation-cap',    optional: false },
  { id: 'termination',       label: 'Termination',        icon: 'fa-user-slash',        optional: true  },
];

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
function fmtDate(val?: string): string {
  if (!val) return '—';
  if (val === '9999-12-31') return 'Open-ended';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

function FieldError({ msg }: { msg?: string }) {
  if (!msg) return null;
  return (
    <small className="field-error" style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 4 }}>
      <i className="fa-solid fa-circle-exclamation" /> {msg}
    </small>
  );
}

function SummaryRow({ label, value }: { label: string; value?: string }) {
  return (
    <span style={{ display: 'inline-flex', gap: 4, alignItems: 'center', color: '#6B7280', fontSize: 12.5 }}>
      <span style={{ color: '#9CA3AF', fontSize: 11 }}>{label}</span>
      <span style={{ color: '#374151', fontWeight: 500 }}>{value || '—'}</span>
    </span>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Component
// ─────────────────────────────────────────────────────────────────────────────
// Maps profile module codes → EmployeeEditPanel section IDs
const MODULE_TO_SECTION: Record<string, string> = {
  profile_personal:          'personal',
  profile_contact:           'contact',
  profile_employment:        'employment',
  profile_address:           'address',
  profile_passport:          'passport',
  profile_identification:    'identity',
  profile_emergency_contact: 'emergency',
  profile_bank:              'bank',
  profile_dependents:        'dependents',
};

export default function EmployeeEditPanel({ emp, onClose, onSaved, initialEmploymentMode, initialEmploymentEffectiveFrom }: Props) {
  // ── Supabase data ─────────────────────────────────────────────────────────
  const { can }                          = usePermissions();
  const { employees }                    = useEmployees();
  const { picklistValues: picklistVals } = usePicklistValues();
  const { departments }                  = useDepartments();
  const { currencies: currencyList }     = useCurrencies();

  // Local copy of the employee kept in sync after each section save
  const [liveEmp, setLiveEmp] = useState<FullEmployee>(emp);
  const [saving,  setSaving]  = useState(false);

  // Personal info history panel
  const [piHistOpen,    setPiHistOpen]    = useState(false);
  const [piHistRows,    setPiHistRows]    = useState<Record<string, unknown>[]>([]);
  const [piHistLoading, setPiHistLoading] = useState(false);
  const [piHistSelIdx,  setPiHistSelIdx]  = useState(0);

  async function loadPiHistory(empId: string) {
    setPiHistLoading(true);
    const { data } = await supabase.rpc('get_personal_info_history', { p_employee_id: empId });
    setPiHistRows((data as Record<string, unknown>[] | null) ?? []);
    setPiHistSelIdx(0);
    setPiHistLoading(false);
  }

  // Suppresses auto-derive effects (probation, currency) while loading saved data
  // into the employment form so they don't overwrite the existing DB values.
  const isLoadingEmploymentRef = useRef(false);

  // ── Pending profile-change warnings ──────────────────────────────────────
  // Set of section IDs (e.g. 'personal', 'contact', 'bank', 'dependents') that
  // have an active workflow_pending_changes record submitted by this employee.
  const [pendingSections, setPendingSections] = useState<Set<string>>(new Set());

  const refetchPendingSections = useCallback(async () => {
    // SECURITY DEFINER RPC — works for any caller with hire_employee.view,
    // not just wf_manage.view holders (direct table query would return empty
    // for HR analysts without wf_manage.view, silently leaving sections editable).
    const { data: moduleCodes } = await supabase.rpc(
      'get_employee_pending_sections',
      { p_employee_id: emp.id }
    );
    if (!moduleCodes) return;
    setPendingSections(new Set(
      (moduleCodes as string[]).map(code => MODULE_TO_SECTION[code]).filter(Boolean)
    ));
  }, [emp.id]);

  useEffect(() => {
    let mounted = true;
    refetchPendingSections().finally(() => { if (!mounted) return; });
    return () => { mounted = false; };
  }, [refetchPendingSections]);

  // ── Section open state ────────────────────────────────────────────────────
  const [openSection,  setOpenSection]  = useState<string | null>(null);
  const [isDirty,      setIsDirty]      = useState(false);
  const [dirtyTarget,  setDirtyTarget]  = useState<string | null>(null); // requested-but-blocked section
  const [errors,       setErrors]       = useState<Record<string, string>>({});

  // ── Draft fields (active edit state) ─────────────────────────────────────
  // Personal
  const [dName,        setDName]        = useState('');
  const [dNationality, setDNationality] = useState('');
  const [dMarital,     setDMarital]     = useState('');
  const [dGender,      setDGender]      = useState('');
  const [dDob,         setDDob]         = useState('');
  const [dPhoto,       setDPhoto]       = useState('');
  const photoRef = useRef<HTMLInputElement>(null);
  // Bank accounts — parent-controlled save for inline edit mode
  const bankSaveAllRef = useRef<(() => Promise<boolean>) | null>(null);
  const [bankSaving, setBankSaving] = useState(false);
  // Dependents — parent-controlled save for inline edit mode
  const depSaveAllRef = useRef<(() => Promise<boolean>) | null>(null);
  const [depSaving, setDepSaving] = useState(false);

  const jrSaveAllRef = useRef<(() => Promise<boolean>) | null>(null);
  const [jrSaving, setJrSaving] = useState(false);

  // ── Deactivation impact modal ─────────────────────────────────────────────
  const [deactivationModal, setDeactivationModal] = useState<{
    open: boolean;
    pendingAction: (() => void) | null;
  }>({ open: false, pendingAction: null });

  // ── Delete-primary-with-secondary modal ───────────────────────────────────
  const [deletePrimaryModal, setDeletePrimaryModal] = useState<{ open: boolean; index: number }>({ open: false, index: -1 });

  // ── Identity record error modal ───────────────────────────────────────────
  const [sectionErrorModal, setSectionErrorModal] = useState<{ open: boolean; message: string }>({ open: false, message: '' });

  // Phone
  const [dCountryCode, setDCountryCode] = useState('+91');
  const [dMobile,      setDMobile]      = useState('');

  // Email
  const [dBizEmail,  setDBizEmail]  = useState('');
  const [dPersEmail, setDPersEmail] = useState('');

  // Employment
  const [dDesig,      setDDesig]      = useState('');
  const [dDeptId,     setDDeptId]     = useState('');
  const [dManagerId,  setDManagerId]  = useState('');
  const [dHireDate,          setDHireDate]          = useState('');
  const [dNoticePeriodDays,  setDNoticePeriodDays]  = useState(30);
  const [dProbation,         setDProbation]         = useState('');
  const [dWorkCountry,setDWorkCountry]= useState('');
  const [dWorkLoc,    setDWorkLoc]    = useState('');
  const [dCurrency,   setDCurrency]   = useState('');
  const [probWarning, setProbWarning] = useState<{ open: boolean; pendingDate: string }>({ open: false, pendingDate: '' });

  // ── Employment insert/edit mode ───────────────────────────────────────────
  // 'insert' = new effective-dated slice (AMENDMENT/SPLIT/PREPEND/GAP-FILL)
  // 'edit'   = in-place correction of an existing slice (CORRECTION)
  const [employmentMode,          setEmploymentMode]          = useState<'edit' | 'insert'>('insert');
  const [employmentEffectiveFrom, setEmploymentEffectiveFrom] = useState<string>('');
  const [eeHistOpen,    setEeHistOpen]    = useState(false);
  const [eeHistRows,    setEeHistRows]    = useState<Record<string, unknown>[]>([]);
  const [eeHistLoading, setEeHistLoading] = useState(false);
  const [eeHistSelIdx,  setEeHistSelIdx]  = useState(0);

  // Identity
  const [dIdRecords,   setDIdRecords]  = useState<IdRecord[]>([]);
  const [idCountry,    setIdCountry]   = useState('');
  const [idType,       setIdType]      = useState('');
  const [idRecordType, setIdRecordType]= useState('');
  const [idNumber,     setIdNumber]    = useState('');
  const [idExpiry,     setIdExpiry]    = useState('');
  const [idCountryPending, setIdCountryPending] = useState<string | null>(null);

  // Passport
  const [dPassCountry,        setDPassCountry]        = useState('');
  const [dPassNumber,         setDPassNumber]         = useState('');
  const [dPassIssueDate,      setDPassIssueDate]      = useState('');
  const [dPassExpiry,         setDPassExpiry]         = useState('');
  const [passportCountryPending, setPassportCountryPending] = useState<string | null>(null);

  // Address
  const [dAddrLine1,    setDAddrLine1]    = useState('');
  const [dAddrLine2,    setDAddrLine2]    = useState('');
  const [dAddrLandmark, setDAddrLandmark] = useState('');
  const [dAddrCity,     setDAddrCity]     = useState('');
  const [dAddrDistrict, setDAddrDistrict] = useState('');
  const [dAddrState,    setDAddrState]    = useState('');
  const [dAddrPin,      setDAddrPin]      = useState('');
  const [dAddrCountry,  setDAddrCountry]  = useState('');

  // Emergency
  const [dEcName,    setDEcName]    = useState('');
  const [dEcRel,     setDEcRel]     = useState('');
  const [dEcPhone,   setDEcPhone]   = useState('');
  const [dEcAlt,     setDEcAlt]     = useState('');
  const [dEcEmail,   setDEcEmail]   = useState('');

  // ── Age helper ───────────────────────────────────────────────────────────
  const calcAge = (dobStr: string): number | null => {
    if (!dobStr) return null;
    const birth = new Date(dobStr);
    if (isNaN(birth.getTime())) return null;
    const today = new Date();
    let age = today.getFullYear() - birth.getFullYear();
    const m = today.getMonth() - birth.getMonth();
    if (m < 0 || (m === 0 && today.getDate() < birth.getDate())) age--;
    return age;
  };

  // ── Picklist helpers ──────────────────────────────────────────────────────
  const resolve = (plId: string, val?: unknown) => {
    if (!val) return '—';
    const m = picklistVals.find(p => p.picklistId === plId && (String(p.id) === String(val) || p.refId === String(val)));
    return m ? m.value : String(val);
  };

  const maritalStatuses = useMemo(() =>
    picklistVals.filter(p => p.picklistId === 'MARITAL_STATUS' && p.active !== false), [picklistVals]);
  const designations = useMemo(() =>
    picklistVals.filter(p => p.picklistId === 'DESIGNATION' && p.active !== false), [picklistVals]);
  const idCountries = useMemo(() =>
    picklistVals.filter(p => p.picklistId === 'ID_COUNTRY' && p.active !== false)
      .sort((a, b) => a.value.localeCompare(b.value)), [picklistVals]);
  const idTypes = useMemo(() =>
    idCountry
      ? picklistVals.filter(p => p.picklistId === 'ID_TYPE' && String(p.parentValueId) === idCountry && p.active !== false)
      : [], [picklistVals, idCountry]);
  const workLocations = useMemo(() =>
    dWorkCountry
      ? picklistVals.filter(p => p.picklistId === 'LOCATION' && String(p.parentValueId) === dWorkCountry && p.active !== false)
      : [], [picklistVals, dWorkCountry]);
  // currencyList is used directly below — no alias needed
  const relationships = useMemo(() =>
    picklistVals.filter(p => p.picklistId === 'RELATIONSHIP_TYPE' && p.active !== false)
      .sort((a, b) => a.value.localeCompare(b.value)), [picklistVals]);

  const activeManagers = useMemo(() =>
    (employees as FullEmployee[]).filter(e => e.status === 'Active' && e.id !== liveEmp.id)
      .sort((a, b) => a.name.localeCompare(b.name)),
    [employees, liveEmp.id]);

  // ── Load extended data from related tables on mount ─────────────────────
  // Note: employee_personal / employee_contact / employee_employment are already
  // embedded into the Employee object by useEmployees (via PostgREST FK join),
  // so we only need to load the tables that AddEmployee / useEmployees don't embed.
  useEffect(() => {
    const empUUID = liveEmp.id as string;
    if (!empUUID) return;
    Promise.all([
      supabase.from('passports').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('employee_addresses').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('emergency_contacts').select('*').eq('employee_id', empUUID).limit(1),
      supabase.from('identity_records').select('*').eq('employee_id', empUUID),
    ]).then(([{ data: pRows }, { data: aRows }, { data: ecRows }, { data: idRows }]) => {
      const patch: Record<string, unknown> = {};
      const p = pRows?.[0];
      if (p) {
        patch.passportCountry    = p.country          || '';
        patch.passportNumber     = p.passport_number  || '';
        patch.passportIssueDate  = p.issue_date        || '';
        patch.passportExpiryDate = p.expiry_date       || '';
      }
      const a = aRows?.[0];
      if (a) {
        patch.addrLine1    = a.line1    || '';
        patch.addrLine2    = a.line2    || '';
        patch.addrLandmark = a.landmark || '';
        patch.addrCity     = a.city     || '';
        patch.addrDistrict = a.district || '';
        patch.addrState    = a.state    || '';
        patch.addrPin      = a.pin      || '';
        patch.addrCountry  = a.country  || '';
      }
      const ec = ecRows?.[0];
      if (ec) {
        patch.ecName         = ec.name         || '';
        patch.ecRelationship = ec.relationship || '';
        patch.ecPhone        = ec.phone        || '';
        patch.ecAltPhone     = ec.alt_phone    || '';
        patch.ecEmail        = ec.email        || '';
      }
      if (idRows && idRows.length > 0) {
        patch.idRecords = idRows.map(r => ({
          country:    r.country     || '',
          idType:     r.id_type     || '',
          recordType: r.record_type || '',
          idNumber:   r.id_number   || '',
          expiry:     r.expiry      || '',
        }));
      }
      if (Object.keys(patch).length > 0) {
        setLiveEmp(prev => ({ ...prev, ...patch }));
      }
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Auto-derive currency from work country.
  // Skipped during initial load (isLoadingEmploymentRef) so saved DB values are preserved.
  // meta.currencyId on a country picklist value is the picklist_values.id of the
  // corresponding CURRENCY entry — NOT the currencies.id. We need to translate:
  // picklist_values.id → picklist_value.value (name) → currencies.id (by name match).
  useEffect(() => {
    if (isLoadingEmploymentRef.current) return;
    if (!dWorkCountry || currencyList.length === 0) return;
    const country = idCountries.find(c => String(c.id) === dWorkCountry);
    const plCurrId = (country as unknown as { meta?: Record<string, string> })?.meta?.currencyId;
    if (!plCurrId) return;
    // plCurrId is a picklist_values.id → get the currency name from the picklist
    const plCurr = picklistVals.find(p => p.picklistId === 'CURRENCY' && String(p.id) === plCurrId);
    if (!plCurr) return;
    // Match by name to find the real currencies.id
    const realCurr = currencyList.find(c => c.name === plCurr.value);
    if (realCurr) setDCurrency(realCurr.id);
  }, [dWorkCountry, currencyList]); // eslint-disable-line react-hooks/exhaustive-deps

  // Auto-default probation from hire date.
  // Skipped during initial load (isLoadingEmploymentRef) so saved DB values are preserved.
  useEffect(() => {
    if (isLoadingEmploymentRef.current) return;
    if (!dHireDate) return;
    const d = new Date(dHireDate);
    d.setMonth(d.getMonth() + 3);
    setDProbation(d.toISOString().split('T')[0]);
  }, [dHireDate]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Open a section for editing ────────────────────────────────────────────
  function requestOpen(sectionId: string) {
    if (openSection === sectionId) return;
    // Blocked while employee has a pending change request for this section
    if (pendingSections.has(sectionId)) return;
    if (isDirty) { setDirtyTarget(sectionId); return; }
    doOpen(sectionId);
  }

  function doOpen(sectionId: string) {
    const e = liveEmp;
    setErrors({});
    setIsDirty(false);
    setDirtyTarget(null);
    setOpenSection(sectionId);

    switch (sectionId) {
      case 'personal':
        setDName(e.name || ''); setDNationality((e.nationality as string) || '');
        setDMarital((e.maritalStatus as string) || ''); setDGender((e.gender as string) || '');
        setDDob((e.dob as string) || '');
        setDPhoto((e.photo as string) || '');
        break;
      case 'contact':
        setDCountryCode((e.countryCode as string) || '+91'); setDMobile((e.mobile as string) || '');
        break;
      case 'email':
        setDBizEmail((e.businessEmail as string) || ''); setDPersEmail((e.personalEmail as string) || '');
        break;
      case 'employment':
        // Raise the flag BEFORE setting state so both auto-derive effects
        // (probation from hireDate, currency from workCountry) are suppressed
        // during this initial load — they must not overwrite saved DB values.
        isLoadingEmploymentRef.current = true;
        setDDesig((e.designation as string) || ''); setDDeptId((e.deptId as string) || '');
        setDManagerId((e.managerId as string) || ''); setDHireDate((e.hireDate as string) || '');
        setDNoticePeriodDays((e.noticePeriodDays as number | undefined) ?? 30); setDProbation((e.probationEndDate as string) || '');
        setDWorkCountry((e.workCountry as string) || ''); setDWorkLoc((e.workLocation as string) || '');
        setDCurrency((e.baseCurrencyId as string) || '');
        // Clear the flag after effects have had a chance to run (next tick)
        setTimeout(() => { isLoadingEmploymentRef.current = false; }, 0);
        break;
      case 'identity':
        setDIdRecords((e.idRecords as IdRecord[]) || []);
        setIdCountry(''); setIdType(''); setIdRecordType(''); setIdNumber(''); setIdExpiry('');
        break;
      case 'passport':
        setDPassCountry((e.passportCountry as string) || '');
        setDPassNumber((e.passportNumber as string) || '');
        setDPassIssueDate((e.passportIssueDate as string) || '');
        setDPassExpiry((e.passportExpiryDate as string) || '');
        break;
      case 'address':
        setDAddrLine1((e.addrLine1 as string) || ''); setDAddrLine2((e.addrLine2 as string) || '');
        setDAddrLandmark((e.addrLandmark as string) || ''); setDAddrCity((e.addrCity as string) || '');
        setDAddrDistrict((e.addrDistrict as string) || ''); setDAddrState((e.addrState as string) || '');
        setDAddrPin((e.addrPin as string) || ''); setDAddrCountry((e.addrCountry as string) || '');
        break;
      case 'emergency':
        setDEcName((e.ecName as string) || ''); setDEcRel((e.ecRelationship as string) || '');
        setDEcPhone((e.ecPhone as string) || ''); setDEcAlt((e.ecAltPhone as string) || '');
        setDEcEmail((e.ecEmail as string) || '');
        break;
    }
  }

  function cancelEdit() {
    setOpenSection(null); setIsDirty(false); setDirtyTarget(null); setErrors({});
    setEeHistOpen(false);
  }

  // ── Employment history helpers ─────────────────────────────────────────────

  async function loadEeHistory(empId: string) {
    setEeHistLoading(true);
    const { data } = await supabase.rpc('get_employment_info_history', { p_employee_id: empId });
    const rows = (data as Record<string, unknown>[] | null) ?? [];
    setEeHistRows(rows);
    setEeHistSelIdx(0);
    setEeHistLoading(false);
    return rows;
  }

  function loadEeSliceIntoForm(h: Record<string, unknown>) {
    isLoadingEmploymentRef.current = true;
    setDDesig(String(h.designation || ''));
    setDDeptId(String(h.dept_id    || ''));
    setDManagerId(String(h.manager_id || ''));
    setDHireDate(String(h.hire_date || ''));
    setDNoticePeriodDays((h.notice_period_days as number | undefined) ?? 30);
    setDProbation(String(h.probation_end_date || ''));
    setDWorkCountry(String(h.work_country  || ''));
    setDWorkLoc(String(h.work_location || ''));
    setDCurrency(String(h.base_currency_id || ''));
    setEmploymentEffectiveFrom(String(h.effective_from));
    setIsDirty(false);
    setTimeout(() => { isLoadingEmploymentRef.current = false; }, 0);
  }

  function requestOpenEmployment(mode: 'edit' | 'insert') {
    setEmploymentMode(mode);
    if (mode === 'insert') {
      const today = new Date().toISOString().split('T')[0];
      setEmploymentEffectiveFrom(today);
      setEeHistOpen(false);
      requestOpen('employment');
    } else {
      // Edit mode: load history, then pre-select first (current) slice
      setEeHistOpen(true);
      setEmploymentEffectiveFrom(''); // will be set once history loads
      requestOpen('employment');
      loadEeHistory(liveEmp.id as string).then(rows => {
        if (rows.length > 0) loadEeSliceIntoForm(rows[0]);
      });
    }
  }

  // On mount: honour initialEmploymentMode from parent (e.g. EmployeeDetails history panel)
  useEffect(() => {
    if (initialEmploymentMode) {
      if (initialEmploymentMode === 'edit' && initialEmploymentEffectiveFrom) {
        // Open in edit mode targeting a specific historical slice
        setEmploymentMode('edit');
        setEeHistOpen(true);
        requestOpen('employment');
        loadEeHistory(emp.id as string).then(rows => {
          const target = rows.find(r => String(r.effective_from) === initialEmploymentEffectiveFrom);
          if (target) {
            const idx = rows.indexOf(target);
            setEeHistSelIdx(idx);
            loadEeSliceIntoForm(target);
          } else if (rows.length > 0) {
            loadEeSliceIntoForm(rows[0]);
          }
        });
      } else if (initialEmploymentMode === 'insert') {
        setEmploymentMode('insert');
        setEmploymentEffectiveFrom(new Date().toISOString().split('T')[0]);
        requestOpen('employment');
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── Validate ──────────────────────────────────────────────────────────────
  function validate(sectionId: string): Record<string, string> {
    const errs: Record<string, string> = {};
    switch (sectionId) {
      case 'personal':
        if (!dName.trim()) errs.name = 'Full name is required.';
        if (!dNationality) errs.nationality = 'Nationality is required.';
        if (!dMarital)     errs.maritalStatus = 'Marital status is required.';
        if (!dGender)      errs.gender = 'Gender is required.';
        if (!dDob)         errs.dob = 'Date of birth is required.';
        break;
      case 'contact':
        { const mErr = validateMobile(dCountryCode, dMobile); if (mErr) errs.mobile = mErr; }
        break;
      case 'email':
        if (!dBizEmail.trim())
          errs.businessEmail = 'Business email is required.';
        else if (!dBizEmail.trim().toLowerCase().endsWith('@prowessinfotech.co.in'))
          errs.businessEmail = 'Must use the company domain: @prowessinfotech.co.in';
        if (!dPersEmail.trim())
          errs.personalEmail = 'Personal email is required.';
        else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(dPersEmail.trim()))
          errs.personalEmail = 'Enter a valid email address.';
        // Domain check only for Active employees — Draft/Incomplete/Pending are
        // provisional records; enforce domain rule once employee is live.
        else if (
          (liveEmp.status as string) === 'Active' &&
          dPersEmail.trim().toLowerCase().includes('@prowessinfotech.co.in')
        )
          errs.personalEmail = 'Personal email cannot use the company email domain (@prowessinfotech.co.in). Please provide a personal email address.';
        if (dBizEmail.trim() && dPersEmail.trim() &&
            dBizEmail.trim().toLowerCase() === dPersEmail.trim().toLowerCase())
          errs.personalEmail = 'Personal email cannot be the same as business email.';
        break;
      case 'employment':
        if (!dDesig)    errs.designation = 'Designation is required.';
        if (!dDeptId)   errs.deptId      = 'Department is required.';
        if (!dHireDate) errs.hireDate    = 'Hire date is required.';
        if (!dProbation)errs.probation   = 'Probation end date is required.';
        // end_date removed (mig 487) — no longer validated here
        if (dProbation && dHireDate && dProbation < dHireDate)
          errs.probation = 'Probation End Date cannot be before Hire Date.';
        if (!dWorkCountry)   errs.workCountry = 'Country of work is required.';
        else if (!dCurrency) errs.workCountry = 'No default currency is configured for this country. Ask your administrator to set a Default Currency in Reference Data → ID Country.';
        if (!dWorkLoc)  errs.workLocation = 'Location is required.';
        break;
      case 'passport':
        if (dPassCountry) {
          const passCountryName = idCountries.find(c => String(c.id) === dPassCountry)?.value ?? '';
          if (!dPassNumber.trim()) {
            errs.passportNumber = 'Passport Number is required.';
          } else {
            const numErr = validatePassportNumber(passCountryName, dPassNumber);
            if (numErr) errs.passportNumber = numErr;
          }
          if (!dPassIssueDate) errs.passportIssueDate = 'Issue Date is required.';
          if (!dPassExpiry)    errs.passportExpiry    = 'Expiry Date is required.';
          if (dPassIssueDate && dPassExpiry) {
            const valErr = validatePassportValidity(passCountryName, dPassIssueDate, dPassExpiry);
            if (valErr) errs.passportExpiry = valErr;
          }
        }
        break;
      case 'address':
        if (!dAddrLine1.trim()) errs.addrLine1 = 'Address line 1 is required.';
        // addrLine2 is optional
        if (!dAddrCity.trim())  errs.addrCity  = 'City is required.';
        if (!dAddrPin.trim())   errs.addrPin   = 'PIN / ZIP code is required.';
        if (!dAddrCountry)      errs.addrCountry = 'Country is required.';
        break;
      case 'emergency':
        if (!dEcName.trim()) errs.ecName = 'Contact name is required.';
        if (!dEcRel)         errs.ecRel  = 'Relationship is required.';
        if (!dEcPhone.trim())errs.ecPhone= 'Phone number is required.';
        break;
    }
    return errs;
  }

  // ── Save a section ────────────────────────────────────────────────────────
  async function saveSection(sectionId: string) {
    const errs = validate(sectionId);
    if (Object.keys(errs).length) { setErrors(errs); return; }

    // Map of camelCase patch (for local state) and snake_case patch (for DB)
    let frontendPatch: Partial<FullEmployee> = {};
    let dbPatch: Record<string, unknown> = {};

    switch (sectionId) {
      case 'personal':
        frontendPatch = { name: dName.trim(), nationality: dNationality, maritalStatus: dMarital, gender: dGender, dob: dDob, photo: dPhoto };
        // name is now synced to employees via upsert_personal_info RPC (mig 315/316).
        // Direct UPDATE employees SET name=... is blocked by trg_guard_employee_name_sync
        // for Active employees. The RPC handles the sync internally using the session flag.
        dbPatch = {};
        break;
      case 'contact':
        frontendPatch = { countryCode: dCountryCode, mobile: dMobile.trim() };
        // contact fields go entirely to employee_contact satellite — no employees update needed
        dbPatch = {};
        break;
      case 'email':
        frontendPatch = { businessEmail: dBizEmail.trim(), personalEmail: dPersEmail.trim() };
        // business_email stays in employees core; personal_email goes to employee_contact satellite
        dbPatch = { business_email: dBizEmail.trim() || null };
        break;
      case 'employment':
        frontendPatch = {
          designation: dDesig, deptId: dDeptId, managerId: dManagerId,
          hireDate: dHireDate, noticePeriodDays: dNoticePeriodDays, probationEndDate: dProbation,
          workCountry: dWorkCountry, workLocation: dWorkLoc, baseCurrencyId: dCurrency,
        };
        // Employment fields are now owned by the employee_employment satellite
        // (mig 351-352). upsert_employment_info handles the mirror sync on
        // employees — no direct employees UPDATE needed for these fields.
        dbPatch = {};
        break;
      default: {
        // identity / passport / address / emergency — related tables
        const empUUID = liveEmp.id as string;
        setSaving(true);
        let extError: string | null = null;

        if (sectionId === 'identity') {
          // ── Auto-flush any pending form entry ──────────────────────────────
          // If the user filled in the form but didn't click "Add ID", include
          // the pending entry in the save automatically. If the form is fully
          // empty, skip it. If it's partially filled, validate and block save.
          let recordsToSave = [...dIdRecords];
          const hasPendingForm = !!(idCountry || idType || idNumber.trim() || idExpiry || idRecordType);
          if (hasPendingForm) {
            const pendingErrs: Record<string, string> = {};
            if (!idCountry)          pendingErrs.idCountry    = 'Country is required.';
            if (!idType)             pendingErrs.idType       = 'ID Type is required.';
            if (idType && !idRecordType)    pendingErrs.idRecordType = 'Record Type is required.';
            if (idType && !idNumber.trim()) pendingErrs.idNumber     = 'ID Number is required.';
            if (idType && !idExpiry)        pendingErrs.idExpiry     = 'Expiry Date is required.';
            if (idType && idNumber.trim()) {
              const _cn = idCountries.find(c => String(c.id) === idCountry)?.value ?? '';
              const _tn = picklistVals.find(p => String(p.id) === idType)?.value ?? '';
              const _fe = validateIdentityNumber(_cn, _tn, idNumber.trim());
              if (_fe) pendingErrs.idNumber = _fe;
            }
            if (idExpiry) {
              const _today = new Date().toISOString().slice(0, 10);
              if (idExpiry <= _today) pendingErrs.idExpiry = 'Expiry Date must be a future date.';
            }
            if (Object.keys(pendingErrs).length) {
              setSaving(false);
              setErrors(pendingErrs);
              return;
            }
            if (idRecordType === 'primary' && recordsToSave.some(r => r.recordType === 'primary')) {
              setSaving(false);
              setErrors({ idRecordType: 'A Primary ID already exists.' });
              return;
            }
            if (recordsToSave.some(r => r.idType === idType)) {
              setSaving(false);
              setErrors({ idType: 'This ID type has already been added.' });
              return;
            }
            recordsToSave = [...recordsToSave, {
              country: idCountry, idType, recordType: idRecordType,
              idNumber: idNumber.trim(), expiry: idExpiry,
            }];
          }

          // Atomic replace via SECURITY DEFINER RPC (mig 433 — no partial-write window)
          frontendPatch = { idRecords: recordsToSave };
          {
            const { error: rpcErr } = await supabase.rpc('replace_identity_records', {
              p_employee_id: empUUID,
              p_records: recordsToSave.map(r => ({
                country:     r.country    || null,
                id_type:     r.idType     || null,
                record_type: r.recordType || null,
                id_number:   r.idNumber   || null,
                expiry:      r.expiry     || null,
              })),
            });
            if (rpcErr) {
              const msg = rpcErr.message
                .replace(/^replace_identity_records:\s*/i, '')
                .replace(/^ERROR:\s*/i, '');
              setSectionErrorModal({ open: true, message: msg });
              return;
            }
          }
        } else if (sectionId === 'passport') {
          // Atomic UPSERT via SECURITY DEFINER RPC (mig 433 — no partial-write window)
          frontendPatch = { passportCountry: dPassCountry, passportNumber: dPassNumber, passportIssueDate: dPassIssueDate, passportExpiryDate: dPassExpiry };
          {
            const { error: rpcErr } = await supabase.rpc('upsert_passport', {
              p_employee_id: empUUID,
              p_country:     dPassCountry   || null,
              p_number:      dPassNumber    || null,
              p_issue_date:  dPassIssueDate || null,
              p_expiry:      dPassExpiry    || null,
            });
            if (rpcErr) extError = rpcErr.message;
          }
        } else if (sectionId === 'address') {
          // Atomic UPSERT via SECURITY DEFINER RPC (mig 433 — no partial-write window)
          frontendPatch = { addrLine1: dAddrLine1, addrLine2: dAddrLine2, addrLandmark: dAddrLandmark, addrCity: dAddrCity, addrDistrict: dAddrDistrict, addrState: dAddrState, addrPin: dAddrPin, addrCountry: dAddrCountry };
          {
            const { error: rpcErr } = await supabase.rpc('upsert_employee_address', {
              p_employee_id: empUUID,
              p_line1:       dAddrLine1    || null,
              p_line2:       dAddrLine2    || null,
              p_landmark:    dAddrLandmark || null,
              p_city:        dAddrCity     || null,
              p_district:    dAddrDistrict || null,
              p_state:       dAddrState    || null,
              p_pin:         dAddrPin      || null,
              p_country:     dAddrCountry  || null,
            });
            if (rpcErr) extError = rpcErr.message;
          }
        } else {
          // emergency — atomic UPSERT via SECURITY DEFINER RPC (mig 433 — no partial-write window)
          frontendPatch = { ecName: dEcName, ecRelationship: dEcRel, ecPhone: dEcPhone, ecAltPhone: dEcAlt, ecEmail: dEcEmail };
          {
            const { error: rpcErr } = await supabase.rpc('upsert_emergency_contact', {
              p_employee_id:  empUUID,
              p_name:         dEcName  || null,
              p_relationship: dEcRel   || null,
              p_phone:        dEcPhone || null,
              p_alt_phone:    dEcAlt   || null,
              p_email:        dEcEmail || null,
            });
            if (rpcErr) extError = rpcErr.message;
          }
        }

        setSaving(false);
        if (extError) {
          const msg = extError.replace(/^[a-z_]+:\s*/i, '').replace(/^ERROR:\s*/i, '') || extError;
          setSectionErrorModal({ open: true, message: msg });
          return;
        }
        setLiveEmp(prev => ({ ...prev, ...frontendPatch, _savedAt: new Date().toISOString() }));
        onSaved?.();
        cancelEdit();
        if (dirtyTarget) { setTimeout(() => doOpen(dirtyTarget!), 0); }
        return;
      }
    }

    // Persist core employee fields to Supabase (skip if nothing to update in core table)
    setSaving(true);
    const empUUID = liveEmp.id as string;

    if (Object.keys(dbPatch).length > 0) {
      const { error } = await supabase
        .from('employees')
        .update(dbPatch as any)
        .eq('id', empUUID);
      if (error) {
        setSaving(false);
        setErrors({ _global: error.message });
        return;
      }
    }

    // ── Satellite upserts ────────────────────────────────────────────────────
    let satelliteError: string | null = null;

    if (sectionId === 'personal') {
      const today = new Date().toISOString().split('T')[0];
      const { data: piResult, error } = await supabase.rpc('upsert_personal_info', {
        p_employee_id:    empUUID,
        p_proposed_data: {
          name:           dName.trim()  || null,
          nationality:    dNationality  || null,
          marital_status: dMarital      || null,
          gender:         dGender       || null,
          dob:            dDob          || null,
          photo_url:      dPhoto        || null,
        },
        p_effective_from: today,
      });
      if (error) satelliteError = error.message;
      else if (piResult && !piResult.ok) satelliteError = piResult.error ?? 'Personal info save failed';
    }

    if (sectionId === 'contact') {
      const { error } = await supabase
        .from('employee_contact')
        .upsert({
          employee_id:  empUUID,
          country_code: dCountryCode  || null,
          mobile:       dMobile.trim() || null,
        }, { onConflict: 'employee_id' });
      if (error) satelliteError = error.message;
    }

    if (sectionId === 'email') {
      // Write both personal_email and business_email (denormalized copy, mig 410)
      const { error } = await supabase
        .from('employee_contact')
        .upsert({
          employee_id:    empUUID,
          personal_email: dPersEmail.trim() || null,
          business_email: dBizEmail.trim()  || null,
        }, { onConflict: 'employee_id' });
      if (error) satelliteError = error.message;
    }

    if (sectionId === 'employment') {
      // Route through upsert_employment_info — handles effective-dated slice
      // creation, mirror sync, manager role sync, currency derivation, cycle detection.
      // end_date removed (mig 487); deactivation now via Termination workflow.
      //
      // Mode 'edit':   p_effective_from = slice's own effective_from → CORRECTION (in-place update)
      // Mode 'insert': p_effective_from = user-chosen date → AMENDMENT/SPLIT/PREPEND/GAP-FILL
      const effectiveFrom = employmentEffectiveFrom || new Date().toISOString().split('T')[0];
      const { data: eeResult, error: eeErr } = await supabase.rpc('upsert_employment_info', {
        p_employee_id:    empUUID,
        p_proposed_data:  {
          designation:        dDesig             || null,
          dept_id:            dDeptId            || null,
          manager_id:         dManagerId         || null,
          hire_date:          dHireDate          || null,
          notice_period_days: dNoticePeriodDays,
          work_country:       dWorkCountry       || null,
          work_location:      dWorkLoc           || null,
          probation_end_date: dProbation         || null,
        },
        p_effective_from: effectiveFrom,
      });
      if (eeErr) satelliteError = eeErr.message;
      else if (eeResult && !eeResult.ok) {
        if (eeResult.error === 'CYCLE_DETECTED') {
          satelliteError = eeResult.message ?? 'Assigning this manager would create a reporting cycle.';
        } else {
          satelliteError = eeResult.error ?? 'Employment save failed';
        }
      }
    }

    setSaving(false);

    if (satelliteError) {
      setErrors({ _global: satelliteError });
      return;
    }

    // Update local state so the panel reflects the new values immediately
    setLiveEmp(prev => ({ ...prev, ...frontendPatch, _savedAt: new Date().toISOString() }));
    onSaved?.();   // trigger parent refetch in the background

    cancelEdit();
    if (dirtyTarget) { setTimeout(() => doOpen(dirtyTarget!), 0); }
  }

  // ── Identity sub-form helpers ─────────────────────────────────────────────
  function addIdRecord() {
    const errs: Record<string, string> = {};
    if (!idCountry) errs.idCountry = 'Country is required.';
    if (!idType)    errs.idType    = 'ID Type is required.';
    if (idType && !idRecordType)    errs.idRecordType = 'Record Type is required.';
    if (idType && !idNumber.trim()) errs.idNumber     = 'ID Number is required.';
    if (idType && !idExpiry)        errs.idExpiry     = 'Expiry Date is required.';
    if (idType && idNumber.trim()) {
      const countryName = idCountries.find(c => String(c.id) === idCountry)?.value ?? '';
      const typeName    = picklistVals.find(p => String(p.id) === idType)?.value ?? '';
      const fmtErr = validateIdentityNumber(countryName, typeName, idNumber.trim());
      if (fmtErr) errs.idNumber = fmtErr;
    }
    if (idExpiry) {
      const today = new Date().toISOString().slice(0, 10);
      if (idExpiry <= today) errs.idExpiry = 'Expiry Date must be a future date.';
    }
    if (Object.keys(errs).length) { setErrors(errs); return; }

    if (idRecordType === 'primary' && dIdRecords.some(r => r.recordType === 'primary')) {
      setErrors({ idRecordType: 'A Primary ID already exists.' }); return;
    }
    if (dIdRecords.some(r => r.idType === idType)) {
      setErrors({ idType: 'This ID type has already been added.' }); return;
    }
    const dup = employees.find(e =>
      e.employeeId !== liveEmp.employeeId &&
      (e.idRecords as IdRecord[] | undefined)?.some(r => r.idNumber.trim().toLowerCase() === idNumber.trim().toLowerCase())
    );
    if (dup) {
      setErrors({ idNumber: `ID number already registered to ${dup.name} (${dup.employeeId}).` }); return;
    }

    setDIdRecords(prev => [...prev, { country: idCountry, idType, recordType: idRecordType, idNumber: idNumber.trim(), expiry: idExpiry }]);
    setIdCountry(''); setIdType(''); setIdRecordType(''); setIdNumber(''); setIdExpiry('');
    setErrors({});
    setIsDirty(true);
  }

  // ── Probation change handler ──────────────────────────────────────────────
  function handleProbationChange(val: string) {
    if (dHireDate && val < dHireDate) {
      setErrors(p => ({ ...p, probation: 'Probation end date cannot be before hire date.' })); return;
    }
    setErrors(p => ({ ...p, probation: '' }));
    if (dHireDate) {
      const days = Math.round((new Date(val).getTime() - new Date(dHireDate).getTime()) / 86400000);
      if (days > 180) { setProbWarning({ open: true, pendingDate: val }); return; }
    }
    setDProbation(val); setIsDirty(true);
  }

  // ── Read summaries ────────────────────────────────────────────────────────
  function readSummary(sectionId: string) {
    const e = liveEmp;
    const gap = { display: 'flex', flexWrap: 'wrap' as const, gap: '8px 20px', padding: '4px 0' };
    switch (sectionId) {
      case 'personal': return (
        <div style={gap}>
          <SummaryRow label="Name" value={e.name} />
          <SummaryRow label="ID" value={e.employeeId} />
          <SummaryRow label="Nationality" value={e.nationality as string} />
          <SummaryRow label="Marital Status" value={resolve('MARITAL_STATUS', e.maritalStatus)} />
          <SummaryRow label="Gender" value={e.gender as string} />
          <SummaryRow label="Date of Birth" value={e.dob as string} />
          {e.dob && <SummaryRow label="Age" value={calcAge(e.dob as string) !== null ? `${calcAge(e.dob as string)} years` : undefined} />}
        </div>
      );
      case 'contact': return (
        <div style={gap}>
          <SummaryRow label="Mobile" value={`${e.countryCode as string || ''} ${e.mobile as string || ''}`.trim() || undefined} />
        </div>
      );
      case 'email': return (
        <div style={gap}>
          <SummaryRow label="Business" value={e.businessEmail as string} />
          <SummaryRow label="Personal" value={e.personalEmail as string} />
        </div>
      );
      case 'employment': return (
        <div style={gap}>
          <SummaryRow label="Designation" value={resolve('DESIGNATION', e.designation)} />
          <SummaryRow label="Department" value={departments.find(d => d.id === e.deptId || d.deptId === e.deptId)?.name} />
          <SummaryRow label="Manager" value={(employees as FullEmployee[]).find(m => m.id === e.managerId || m.employeeId === e.managerId)?.name} />
          <SummaryRow label="Hired" value={fmtDate(e.hireDate as string)} />
          <SummaryRow label="Location" value={resolve('LOCATION', e.workLocation)} />
          <SummaryRow label="Currency" value={
            currencyList.find(c => c.id === (e.baseCurrencyId as string))?.name
            ?? resolve('CURRENCY', e.baseCurrency)
          } />
        </div>
      );
      case 'identity': {
        const recs = (e.idRecords as IdRecord[] | undefined) || [];
        return (
          <div style={gap}>
            {recs.length === 0
              ? <span style={{ color: '#9CA3AF', fontSize: 12.5, fontStyle: 'italic' }}>No identity records</span>
              : recs.map((r, i) => (
                <span key={i} style={{ fontSize: 12.5, color: '#374151' }}>
                  <span style={{ fontWeight: 500 }}>{resolve('ID_TYPE', r.idType)}</span>
                  <span style={{ color: '#9CA3AF' }}> · {r.idNumber} · expires {fmtDate(r.expiry)}</span>
                </span>
              ))}
          </div>
        );
      }
      case 'passport': return (
        <div style={gap}>
          {!e.passportNumber
            ? <span style={{ color: '#9CA3AF', fontSize: 12.5, fontStyle: 'italic' }}>Not provided</span>
            : <>
                <SummaryRow label="Country" value={resolve('ID_COUNTRY', e.passportCountry)} />
                <SummaryRow label="Number" value={e.passportNumber as string} />
                <SummaryRow label="Expires" value={fmtDate(e.passportExpiryDate as string)} />
              </>}
        </div>
      );
      case 'address': return (
        <div style={gap}>
          <SummaryRow label="Address"
            value={[e.addrLine1, e.addrCity, e.addrState].filter(Boolean).join(', ') || undefined} />
          <SummaryRow label="PIN" value={e.addrPin as string} />
          <SummaryRow label="Country" value={e.addrCountry as string} />
        </div>
      );
      case 'emergency': return (
        <div style={gap}>
          <SummaryRow label="Name" value={e.ecName as string} />
          <SummaryRow label="Relationship" value={resolve('RELATIONSHIP_TYPE', e.ecRelationship)} />
          <SummaryRow label="Phone" value={e.ecPhone as string} />
        </div>
      );
      case 'bank': return (
        <BankAccountsPortlet
          employeeId={liveEmp.id as string}
          hireDate={liveEmp.hireDate as string | undefined}
          isNewHire={false}
          readOnly
          canCreate={false}
          canEdit={false}
          canDelete={false}
        />
      );
      case 'dependents': return (
        <DependentsPortlet
          employeeId={liveEmp.id as string}
          hireDate={liveEmp.hireDate as string | undefined}
          isNewHire={false}
          readOnly
          canEdit={false}
          canDelete={false}
        />
      );
      case 'job_relationships': return (
        <JobRelationshipsPortlet
          employeeId={liveEmp.id as string}
          readOnly
          canEdit={false}
          canDelete={false}
        />
      );
      case 'education': return (
        <EducationPortlet
          employeeId={liveEmp.id as string}
          readOnly
          canCreate={false}
          canEdit={false}
          canDelete={false}
          pendingCount={pendingSections.has('education') ? 1 : 0}
        />
      );
      case 'termination': return (
        <TerminationPortlet
          employeeId={liveEmp.id as string}
          employeeName={liveEmp.name as string}
          isSelfService={false}
          readOnly
          canEdit={false}
          canHistory={can('termination.history')}
        />
      );
      default: return null;
    }
  }

  // ── Edit forms ────────────────────────────────────────────────────────────
  function editForm(sectionId: string) {
    switch (sectionId) {
      // ── Personal ───────────────────────────────────────────────────────────
      case 'personal': return (
        <div className="emp-section">
          {/* History button */}
          {can('personal_info.history') && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 12 }}>
              <button
                onClick={() => {
                  if (!piHistOpen) loadPiHistory(liveEmp.id as string);
                  setPiHistOpen(v => !v);
                }}
                style={{
                  background: piHistOpen ? '#EEF2FF' : 'none',
                  border: `1px solid ${piHistOpen ? '#A5B4FC' : '#E5E7EB'}`,
                  borderRadius: 6, padding: '5px 12px', cursor: 'pointer',
                  color: piHistOpen ? '#4F46E5' : '#6B7280',
                  fontSize: 12, fontWeight: 500,
                  display: 'flex', alignItems: 'center', gap: 6,
                }}
              >
                <i className="fa-solid fa-clock-rotate-left" style={{ fontSize: 11 }} />
                {piHistOpen ? 'Close History' : 'View History'}
              </button>
            </div>
          )}

          {/* History Panel */}
          {piHistOpen && (
            <div style={{ marginBottom: 20, border: '1px solid #E0E7FF', borderRadius: 10, overflow: 'hidden' }}>
              <div style={{ background: '#EEF2FF', padding: '10px 16px', display: 'flex', alignItems: 'center', gap: 8, borderBottom: '1px solid #E0E7FF' }}>
                <i className="fa-solid fa-clock-rotate-left" style={{ color: '#4F46E5', fontSize: 13 }} />
                <span style={{ fontWeight: 600, fontSize: 13, color: '#3730A3' }}>Personal Info — Change History</span>
                <span style={{ marginLeft: 'auto', fontSize: 12, color: '#6B7280' }}>
                  {piHistRows.length} record{piHistRows.length !== 1 ? 's' : ''}
                </span>
              </div>
              {piHistLoading ? (
                <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
                  <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading…
                </div>
              ) : piHistRows.length === 0 ? (
                <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>No history available.</div>
              ) : (
                <div style={{ display: 'flex', minHeight: 160 }}>
                  {/* Date list */}
                  <div style={{ width: 145, borderRight: '1px solid #E0E7FF', overflowY: 'auto' }}>
                    {piHistRows.map((h, i) => {
                      const isCurrent = h.effective_to === '9999-12-31' && h.is_active === true;
                      return (
                        <button key={i} onClick={() => setPiHistSelIdx(i)} style={{
                          width: '100%', textAlign: 'left', padding: '10px 12px',
                          background: piHistSelIdx === i ? '#EEF2FF' : 'none',
                          border: 'none', borderBottom: '1px solid #F3F4F6',
                          cursor: 'pointer', fontSize: 12,
                          color: piHistSelIdx === i ? '#4F46E5' : '#374151',
                        }}>
                          <div style={{ fontWeight: 600 }}>{h.effective_from as string}</div>
                          <div style={{ color: '#9CA3AF', fontSize: 11 }}>
                            {isCurrent ? 'Current' : `→ ${h.effective_to as string}`}
                          </div>
                        </button>
                      );
                    })}
                  </div>
                  {/* Detail */}
                  {(() => {
                    const h = piHistRows[piHistSelIdx];
                    if (!h) return null;
                    const isCurrent = h.effective_to === '9999-12-31' && h.is_active === true;
                    return (
                      <div style={{ flex: 1, padding: '14px 16px' }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
                          <span style={{ fontSize: 12, fontWeight: 600, color: '#6B7280' }}>
                            {h.effective_from as string} — {isCurrent ? 'Present' : h.effective_to as string}
                          </span>
                          {isCurrent && (
                            <span style={{ fontSize: 11, fontWeight: 600, background: '#D1FAE5', color: '#065F46', borderRadius: 4, padding: '2px 7px' }}>Current</span>
                          )}
                        </div>
                        <div className="emp-field-grid emp-grid-2" style={{ gap: 8, fontSize: 13 }}>
                          {h.name           && <><span style={{ color: '#6B7280' }}>Full Name</span><span>{h.name as string}</span></>}
                          {h.nationality    && <><span style={{ color: '#6B7280' }}>Nationality</span><span>{h.nationality as string}</span></>}
                          {h.marital_status && <><span style={{ color: '#6B7280' }}>Marital Status</span><span>{h.marital_status as string}</span></>}
                          {h.gender         && <><span style={{ color: '#6B7280' }}>Gender</span><span>{h.gender as string}</span></>}
                          {h.dob            && <><span style={{ color: '#6B7280' }}>Date of Birth</span><span>{h.dob as string}</span></>}
                          {h.middle_name    && <><span style={{ color: '#6B7280' }}>Middle Name</span><span>{h.middle_name as string}</span></>}
                          {h.preferred_name && <><span style={{ color: '#6B7280' }}>Preferred Name</span><span>{h.preferred_name as string}</span></>}
                        </div>
                      </div>
                    );
                  })()}
                </div>
              )}
            </div>
          )}

          {/* Avatar */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 20 }}>
            <div className="emp-form-avatar-wrap" style={{ position: 'relative', width: 72, height: 72, cursor: 'pointer' }}
              onClick={() => photoRef.current?.click()}>
              <img src={dPhoto || `https://ui-avatars.com/api/?name=${encodeURIComponent(dName||'E')}&background=2F77B5&color=fff&size=72`}
                alt="avatar" style={{ width: 72, height: 72, borderRadius: '50%', objectFit: 'cover', border: '2px solid #e5e7eb' }} />
              <div className="emp-form-avatar-overlay" style={{ position: 'absolute', inset: 0, borderRadius: '50%', background: 'rgba(0,0,0,0.45)', display: 'flex', alignItems: 'center', justifyContent: 'center', opacity: 0, transition: 'opacity 0.2s' }}>
                <i className="fa-solid fa-camera" style={{ color: '#fff', fontSize: 18 }} />
              </div>
            </div>
            <input ref={photoRef} type="file" accept="image/*" style={{ display: 'none' }}
              onChange={e => { const f = e.target.files?.[0]; if (!f) return; const r = new FileReader(); r.onload = ev => { setDPhoto(ev.target!.result as string); setIsDirty(true); }; r.readAsDataURL(f); }} />
            <div>
              <div style={{ fontWeight: 600, fontSize: 14 }}>{dName || '—'}</div>
              <div style={{ color: '#9CA3AF', fontSize: 12 }}>{liveEmp.employeeId}</div>
            </div>
          </div>
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.name ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-user fa-fw" /> Full Name</label>
              <input value={dName} onChange={e => { setDName(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, name: '' })); }} placeholder="Full name" required />
              <FieldError msg={errors.name} />
            </div>
            <div className={`form-group ${errors.nationality ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-flag fa-fw" /> Nationality</label>
              <select value={dNationality} onChange={e => { setDNationality(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, nationality: '' })); }} required>
                <option value="">-- Select --</option>
                {COUNTRIES.map(c => <option key={c} value={c}>{c}</option>)}
              </select>
              <FieldError msg={errors.nationality} />
            </div>
            <div className={`form-group ${errors.maritalStatus ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-heart fa-fw" /> Marital Status</label>
              <select value={dMarital} onChange={e => { setDMarital(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, maritalStatus: '' })); }} required>
                <option value="">-- Select --</option>
                {maritalStatuses.map(m => <option key={String(m.id)} value={String(m.id)}>{m.value}</option>)}
              </select>
              <FieldError msg={errors.maritalStatus} />
            </div>
            <div className={`form-group ${errors.gender ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-venus-mars fa-fw" /> Gender</label>
              <select value={dGender} onChange={e => { setDGender(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, gender: '' })); }} required>
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
                value={dDob}
                onChange={e => { setDDob(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, dob: '' })); }}
                max={new Date().toISOString().slice(0, 10)}
              />
              <FieldError msg={errors.dob} />
            </div>
            {dDob && (
              <div className="form-group">
                <label><i className="fa-solid fa-hourglass-half fa-fw" /> Age</label>
                <input type="text" value={calcAge(dDob) !== null ? `${calcAge(dDob)} years` : ''} readOnly />
              </div>
            )}
          </div>
        </div>
      );

      // ── Phone ───────────────────────────────────────────────────────────────
      case 'contact': return (
        <div className="emp-section">
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group phone-group ${errors.mobile ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-phone fa-fw" /> Mobile Number</label>
              <div className="phone-row">
                <select value={dCountryCode} onChange={e => {
                  setDCountryCode(e.target.value); setIsDirty(true);
                  if (dMobile) {
                    const err = validateMobile(e.target.value, dMobile);
                    setErrors(p => ({ ...p, mobile: err ?? '' }));
                  }
                }} style={{ width: 100, flexShrink: 0 }}>
                  {PHONE_CODES.map(p => <option key={p.code} value={p.code}>{p.label}</option>)}
                </select>
                <input type="tel" value={dMobile} onChange={e => {
                  const val = e.target.value;
                  setDMobile(val); setIsDirty(true);
                  const err = val ? validateMobile(dCountryCode, val) : '';
                  setErrors(p => ({ ...p, mobile: err ?? '' }));
                }} placeholder={mobilePlaceholder(dCountryCode)} required />
              </div>
              {!errors.mobile && (() => {
                const hint = mobileHint(dCountryCode);
                return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />{hint}</div> : null;
              })()}
              <FieldError msg={errors.mobile} />
            </div>
          </div>
        </div>
      );

      // ── Email ───────────────────────────────────────────────────────────────
      case 'email': return (
        <div className="emp-section">
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.businessEmail ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-envelope fa-fw" /> Business Email</label>
              <input
                type="email" value={dBizEmail}
                onChange={e => {
                  const v = e.target.value;
                  setDBizEmail(v); setIsDirty(true);
                  if (v.includes('@') && !v.trim().toLowerCase().endsWith('@prowessinfotech.co.in'))
                    setErrors(p => ({ ...p, businessEmail: 'Must use the company domain: @prowessinfotech.co.in' }));
                  else
                    setErrors(p => ({ ...p, businessEmail: '' }));
                  if (dPersEmail.trim() && v.trim().toLowerCase() === dPersEmail.trim().toLowerCase())
                    setErrors(p => ({ ...p, personalEmail: 'Personal email cannot be the same as business email.' }));
                  else if (dPersEmail.trim())
                    setErrors(p => ({ ...p, personalEmail: '' }));
                }}
                placeholder="name@prowessinfotech.co.in" required
              />
              <FieldError msg={errors.businessEmail} />
            </div>
            <div className={`form-group ${errors.personalEmail ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-envelope-open fa-fw" /> Personal Email</label>
              <input
                type="email" value={dPersEmail}
                onChange={e => {
                  const v = e.target.value;
                  setDPersEmail(v); setIsDirty(true);
                  if (dBizEmail.trim() && v.trim().toLowerCase() === dBizEmail.trim().toLowerCase())
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

      // ── Employment ──────────────────────────────────────────────────────────
      case 'employment': return (
        <div className="emp-section">

          {/* ── Mode banner ─────────────────────────────────────────────── */}
          {employmentMode === 'insert' ? (
            <div style={{
              display: 'flex', alignItems: 'center', gap: 12,
              background: '#EFF6FF', border: '1px solid #BFDBFE',
              borderRadius: 8, padding: '10px 14px', marginBottom: 16,
            }}>
              <i className="fa-solid fa-plus" style={{ color: '#2563EB', fontSize: 13 }} />
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 12.5, fontWeight: 600, color: '#1D4ED8' }}>Inserting new time slice</div>
                <div style={{ fontSize: 11.5, color: '#3B82F6', marginTop: 2 }}>
                  A new effective-dated record will be created. Existing slices will be trimmed automatically.
                </div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
                <label style={{ fontSize: 12, color: '#1D4ED8', fontWeight: 600 }}>Effective from</label>
                <input
                  type="date" min="1900-01-01" max="2100-12-31"
                  value={employmentEffectiveFrom}
                  onChange={e => { setEmploymentEffectiveFrom(e.target.value); setIsDirty(true); }}
                  style={{ fontSize: 12, padding: '4px 8px', borderRadius: 6, border: '1px solid #93C5FD', background: '#fff' }}
                />
              </div>
            </div>
          ) : (
            /* Edit mode — show history rail so user can pick which slice to correct */
            <div style={{
              background: '#F9FAFB', border: '1px solid #E5E7EB',
              borderRadius: 8, marginBottom: 16, overflow: 'hidden',
            }}>
              {/* Header */}
              <div style={{
                background: '#EEF2FF', padding: '8px 14px',
                display: 'flex', alignItems: 'center', gap: 8,
                borderBottom: '1px solid #E0E7FF',
              }}>
                <i className="fa-solid fa-pen-to-square" style={{ color: '#4F46E5', fontSize: 12 }} />
                <span style={{ fontWeight: 600, fontSize: 12.5, color: '#3730A3' }}>
                  Editing existing record — date boundaries will not change
                </span>
                <span style={{ marginLeft: 'auto', fontSize: 11.5, color: '#6B7280' }}>
                  Select a record below to switch
                </span>
              </div>
              {/* Slice selector */}
              {eeHistLoading ? (
                <div style={{ padding: '10px 14px', color: '#9CA3AF', fontSize: 13 }}>
                  <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading history…
                </div>
              ) : eeHistRows.length === 0 ? (
                <div style={{ padding: '10px 14px', color: '#9CA3AF', fontSize: 13 }}>No records found.</div>
              ) : (
                <div style={{ display: 'flex', overflowX: 'auto', gap: 0 }}>
                  {eeHistRows.map((h, i) => {
                    const isCurrent = h.effective_to === '9999-12-31';
                    return (
                      <button
                        key={i}
                        onClick={() => {
                          setEeHistSelIdx(i);
                          loadEeSliceIntoForm(h);
                        }}
                        style={{
                          flexShrink: 0, padding: '8px 14px', border: 'none',
                          borderRight: '1px solid #E5E7EB', cursor: 'pointer',
                          background: eeHistSelIdx === i ? '#EEF2FF' : '#fff',
                          color: eeHistSelIdx === i ? '#4F46E5' : '#374151',
                          fontSize: 12, fontWeight: eeHistSelIdx === i ? 700 : 400,
                          textAlign: 'left',
                        }}
                      >
                        <div>{h.effective_from as string}</div>
                        <div style={{ fontSize: 11, color: eeHistSelIdx === i ? '#818CF8' : '#9CA3AF' }}>
                          {isCurrent ? '→ Present' : `→ ${h.effective_to as string}`}
                        </div>
                        {isCurrent && (
                          <div style={{ fontSize: 10, fontWeight: 700, color: '#059669', marginTop: 2 }}>CURRENT</div>
                        )}
                      </button>
                    );
                  })}
                </div>
              )}
              {/* Selected slice effective_from read-only badge */}
              {employmentEffectiveFrom && (
                <div style={{
                  padding: '6px 14px', borderTop: '1px solid #E5E7EB',
                  fontSize: 12, color: '#6B7280', display: 'flex', alignItems: 'center', gap: 6,
                }}>
                  <i className="fa-solid fa-lock" style={{ fontSize: 10 }} />
                  Effective from <strong>{employmentEffectiveFrom}</strong> — date is locked for in-place edit
                </div>
              )}
            </div>
          )}

          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.designation ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-id-badge fa-fw" /> Designation</label>
              <select value={dDesig} onChange={e => { setDDesig(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, designation: '' })); }} required>
                <option value="">-- Select --</option>
                {designations.map(d => <option key={String(d.id)} value={String(d.id)}>{d.value}</option>)}
              </select>
              <FieldError msg={errors.designation} />
            </div>
            <div className={`form-group ${errors.deptId ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-sitemap fa-fw" /> Department</label>
              <select value={dDeptId} onChange={e => { setDDeptId(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, deptId: '' })); }} required>
                <option value="">-- Select --</option>
                {departments.map(d => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select>
              <FieldError msg={errors.deptId} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-user-tie fa-fw" /> Manager</label>
              <select value={dManagerId} onChange={e => { setDManagerId(e.target.value); setIsDirty(true); }}>
                <option value="">-- None --</option>
                {activeManagers.map(m => <option key={String(m.id)} value={String(m.id)}>{String(m.name)} ({String(m.employeeId)})</option>)}
              </select>
            </div>
            <div className={`form-group ${errors.hireDate ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-calendar-day fa-fw" /> Hire Date</label>
              <input type="date" min="1900-01-01" max="2100-12-31" value={dHireDate} onChange={e => {
                setDHireDate(e.target.value); setIsDirty(true);
                setErrors(p => ({ ...p, hireDate: '' }));
              }} required />
              <FieldError msg={errors.hireDate} />
            </div>
            <div className={`form-group ${errors.probation ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-hourglass-half fa-fw" /> Probation End Date</label>
              <input type="date" min="1900-01-01" max="2100-12-31" value={dProbation} onChange={e => { handleProbationChange(e.target.value); }} required />
              <FieldError msg={errors.probation} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-clock fa-fw" /> Notice Period</label>
              <select value={dNoticePeriodDays} onChange={e => { setDNoticePeriodDays(Number(e.target.value)); setIsDirty(true); }}>
                <option value={30}>30 days</option>
                <option value={90}>90 days</option>
                <option value={120}>120 days</option>
              </select>
            </div>
            <div className={`form-group ${errors.workCountry ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-earth-americas fa-fw" /> Country of Work</label>
              <select value={dWorkCountry} onChange={e => { setDWorkCountry(e.target.value); setDWorkLoc(''); setIsDirty(true); setErrors(p => ({ ...p, workCountry: '', workLocation: '' })); }} required>
                <option value="">-- Select --</option>
                {idCountries.map(c => <option key={String(c.id)} value={String(c.id)}>{c.value}</option>)}
              </select>
              <FieldError msg={errors.workCountry} />
            </div>
            <div className={`form-group ${errors.workLocation ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-location-dot fa-fw" /> Location</label>
              <select value={dWorkLoc} onChange={e => { setDWorkLoc(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, workLocation: '' })); }} disabled={!dWorkCountry} required>
                <option value="">{dWorkCountry ? '-- Select --' : '-- Select Country First --'}</option>
                {workLocations.map(l => <option key={String(l.id)} value={String(l.id)}>{l.value}</option>)}
              </select>
              <FieldError msg={errors.workLocation} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-coins fa-fw" /> Base Currency</label>
              <div className={`emp-readonly-field ${!dCurrency ? 'emp-readonly-empty' : ''}`}>
                <i className="fa-solid fa-lock" style={{ color: '#94A3B8', fontSize: 11 }} />
                <span>{dCurrency
                  ? (currencyList.find(c => c.id === dCurrency)?.name ?? resolve('CURRENCY', dCurrency))
                  : 'Auto-derived from Country of Work'}</span>
              </div>
            </div>
          </div>
        </div>
      );

      // ── Identity ────────────────────────────────────────────────────────────
      case 'identity': return (
        <div className="emp-section">
          {dIdRecords.length > 0 && (
            <div style={{ marginBottom: 16 }}>
              <table className="emp-id-table">
                <thead>
                  <tr><th>Type</th><th>Country</th><th>ID Type</th><th>ID Number</th><th>Expiry</th><th>Record</th><th></th></tr>
                </thead>
                <tbody>
                  {dIdRecords.map((r, i) => (
                    <tr key={i}>
                      <td>{r.recordType || '—'}</td>
                      <td>{resolve('ID_COUNTRY', r.country)}</td>
                      <td>{resolve('ID_TYPE', r.idType)}</td>
                      <td>{r.idNumber}</td>
                      <td>{fmtDate(r.expiry)}</td>
                      <td><span style={{ fontSize: 11, background: '#EFF6FF', color: '#1D4ED8', borderRadius: 4, padding: '2px 6px' }}>{r.recordType}</span></td>
                      <td>
                        <button style={{ background: 'none', border: 'none', color: '#EF4444', cursor: 'pointer' }}
                          onClick={() => {
                            const rec = dIdRecords[i];
                            const hasSecondary = dIdRecords.some((r, j) => j !== i && r.recordType === 'secondary');
                            if (rec.recordType === 'primary' && hasSecondary) {
                              setDeletePrimaryModal({ open: true, index: i });
                            } else {
                              setDIdRecords(p => p.filter((_, j) => j !== i));
                              setIsDirty(true);
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
                  {idCountries.map(c => <option key={String(c.id)} value={String(c.id)}>{c.value}</option>)}
                </select>
                <FieldError msg={errors.idCountry} />
              </div>
              <div className={`form-group ${errors.idType ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-tag fa-fw" /> ID Type</label>
                <select value={idType} onChange={e => {
                  const v = e.target.value;
                  setIdType(v);
                  if (v && dIdRecords.some(r => r.idType === v)) setErrors(p => ({ ...p, idType: 'This ID type has already been added.' }));
                  else setErrors(p => ({ ...p, idType: '', idExpiry: '' }));
                  // Auto-default expiry date based on ID type validity
                  if (v) {
                    const countryName = idCountries.find(c => String(c.id) === idCountry)?.value ?? '';
                    const typeName    = picklistVals.find(p => String(p.id) === v)?.value ?? '';
                    const def = defaultExpiryDate(countryName, typeName);
                    if (def) setIdExpiry(def);
                  } else {
                    setIdExpiry('');
                  }
                }} disabled={!idCountry}>
                  <option value="">{idCountry ? '-- Select --' : '-- Select Country First --'}</option>
                  {idTypes.map(t => <option key={String(t.id)} value={String(t.id)}>{t.value}</option>)}
                </select>
                <FieldError msg={errors.idType} />
              </div>
              <div className={`form-group ${errors.idRecordType ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-star fa-fw" /> Record Type</label>
                <select value={idRecordType} onChange={e => { setIdRecordType(e.target.value); setErrors(p => ({ ...p, idRecordType: '' })); }} required={!!idType}>
                  <option value="">-- Select --</option>
                  <option value="primary" disabled={dIdRecords.some(r => r.recordType === 'primary')}>
                    {dIdRecords.some(r => r.recordType === 'primary') ? '⭐ Primary (already assigned)' : '⭐ Primary'}
                  </option>
                  <option value="secondary" disabled={!dIdRecords.some(r => r.recordType === 'primary')}>
                    {!dIdRecords.some(r => r.recordType === 'primary') ? 'Secondary (add primary first)' : 'Secondary'}
                  </option>
                </select>
                <FieldError msg={errors.idRecordType} />
              </div>
            </div>
            <div className="emp-field-grid emp-id-grid-bottom">
              <div className={`form-group ${errors.idNumber ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-hashtag fa-fw" /> ID Number</label>
                <input type="text" value={idNumber} onChange={e => {
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
                )} required={!!idType} />
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
                <label><i className="fa-solid fa-calendar-xmark fa-fw" /> Expiry Date</label>
                <input type="date" min="1900-01-01" max="2100-12-31" value={idExpiry} onChange={e => {
                  const v = e.target.value;
                  setIdExpiry(v);
                  const today = new Date().toISOString().slice(0, 10);
                  if (v && v <= today) setErrors(p => ({ ...p, idExpiry: 'Expiry Date must be a future date.' }));
                  else setErrors(p => ({ ...p, idExpiry: '' }));
                }} required={!!idType} />
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
            <button type="button" className="emp-id-add-btn" onClick={addIdRecord} title="Add another ID to the list before saving">
              <i className="fa-solid fa-plus" /> Add Another ID
            </button>
          </div>
        </div>
      );

      // ── Passport ────────────────────────────────────────────────────────────
      case 'passport': return (
        <div className="emp-section">
          <div className="emp-field-grid emp-grid-4">
            <div className="form-group">
              <label><i className="fa-solid fa-globe fa-fw" /> Issue Country</label>
              <select value={dPassCountry} onChange={e => {
                const next = e.target.value;
                const hasFilled = dPassNumber || dPassIssueDate || dPassExpiry;
                if (hasFilled && next !== dPassCountry) {
                  setPassportCountryPending(next);
                } else {
                  setDPassCountry(next); setIsDirty(true);
                  setErrors(p => ({ ...p, passportNumber: '', passportIssueDate: '', passportExpiry: '' }));
                }
              }}>
                <option value="">-- Select --</option>
                {idCountries.map(c => <option key={String(c.id)} value={String(c.id)}>{c.value}</option>)}
              </select>
            </div>
            <div className={`form-group ${errors.passportNumber ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-passport fa-fw" /> Passport Number</label>
              <input value={dPassNumber} onChange={e => {
                const val = e.target.value;
                setDPassNumber(val); setIsDirty(true);
                const countryName = idCountries.find(c => String(c.id) === dPassCountry)?.value ?? '';
                const err = val ? validatePassportNumber(countryName, val) : '';
                setErrors(p => ({ ...p, passportNumber: err ?? '' }));
              }} placeholder={passportNumberPlaceholder(idCountries.find(c => String(c.id) === dPassCountry)?.value ?? '')} required={!!dPassCountry} />
              {!errors.passportNumber && dPassCountry && (() => {
                const hint = passportNumberHint(idCountries.find(c => String(c.id) === dPassCountry)?.value ?? '');
                return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />{hint}</div> : null;
              })()}
              <FieldError msg={errors.passportNumber} />
            </div>
            <div className={`form-group ${errors.passportIssueDate ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-calendar-plus fa-fw" /> Issue Date</label>
              <input type="date" min="1900-01-01" max="2100-12-31" value={dPassIssueDate} onChange={e => {
                const val = e.target.value;
                setDPassIssueDate(val); setIsDirty(true);
                setErrors(p => ({ ...p, passportIssueDate: '' }));
                if (dPassExpiry) {
                  const countryName = idCountries.find(c => String(c.id) === dPassCountry)?.value ?? '';
                  const err = validatePassportValidity(countryName, val, dPassExpiry);
                  setErrors(p => ({ ...p, passportExpiry: err ?? '' }));
                }
              }} required={!!dPassCountry} />
              <FieldError msg={errors.passportIssueDate} />
            </div>
            <div className={`form-group ${errors.passportExpiry ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-calendar-xmark fa-fw" /> Expiry Date</label>
              <input type="date" min="1900-01-01" max="2100-12-31" value={dPassExpiry} onChange={e => {
                const val = e.target.value;
                setDPassExpiry(val); setIsDirty(true);
                const countryName = idCountries.find(c => String(c.id) === dPassCountry)?.value ?? '';
                const err = dPassIssueDate ? validatePassportValidity(countryName, dPassIssueDate, val) : null;
                setErrors(p => ({ ...p, passportExpiry: err ?? '' }));
              }} required={!!dPassCountry} />
              {!errors.passportExpiry && dPassCountry && (() => {
                const hint = passportValidityHint(idCountries.find(c => String(c.id) === dPassCountry)?.value ?? '');
                return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-clock" style={{ marginRight: 4 }} />{hint}</div> : null;
              })()}
              <FieldError msg={errors.passportExpiry} />
            </div>
          </div>
        </div>
      );

      // ── Address ─────────────────────────────────────────────────────────────
      case 'address': return (
        <div className="emp-section">
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.addrLine1 ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-map-marker-alt fa-fw" /> Address Line 1</label>
              <input value={dAddrLine1} onChange={e => { setDAddrLine1(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, addrLine1: '' })); }} placeholder="House / Flat / Building" required />
              <FieldError msg={errors.addrLine1} />
            </div>
            <div className={`form-group ${errors.addrLine2 ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-road fa-fw" /> Address Line 2</label>
              <input value={dAddrLine2} onChange={e => { setDAddrLine2(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, addrLine2: '' })); }} placeholder="Street / Area" />
              <FieldError msg={errors.addrLine2} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-map-pin fa-fw" /> Landmark</label>
              <input value={dAddrLandmark} onChange={e => { setDAddrLandmark(e.target.value); setIsDirty(true); }} placeholder="e.g. Near City Mall" />
            </div>
            <div className={`form-group ${errors.addrCity ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-city fa-fw" /> City</label>
              <input value={dAddrCity} onChange={e => { setDAddrCity(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, addrCity: '' })); }} placeholder="e.g. Chennai" required />
              <FieldError msg={errors.addrCity} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-map fa-fw" /> District</label>
              <input value={dAddrDistrict} onChange={e => { setDAddrDistrict(e.target.value); setIsDirty(true); }} placeholder="e.g. Kancheepuram" />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-map-location-dot fa-fw" /> State</label>
              <input value={dAddrState} onChange={e => { setDAddrState(e.target.value); setIsDirty(true); }} placeholder="e.g. Tamil Nadu" />
            </div>
            <div className={`form-group ${errors.addrPin ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-hashtag fa-fw" /> PIN / ZIP</label>
              <input value={dAddrPin} onChange={e => { setDAddrPin(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, addrPin: '' })); }} placeholder="e.g. 600001" required />
              <FieldError msg={errors.addrPin} />
            </div>
            <div className={`form-group ${errors.addrCountry ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-earth-americas fa-fw" /> Country</label>
              <select value={dAddrCountry} onChange={e => { setDAddrCountry(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, addrCountry: '' })); }} required>
                <option value="">-- Select Country --</option>
                {COUNTRIES.map(c => <option key={c} value={c}>{c}</option>)}
              </select>
              <FieldError msg={errors.addrCountry} />
            </div>
          </div>
        </div>
      );

      // ── Emergency ───────────────────────────────────────────────────────────
      case 'emergency': return (
        <div className="emp-section">
          <div className="emp-field-grid emp-grid-2">
            <div className={`form-group ${errors.ecName ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-user fa-fw" /> Contact Name</label>
              <input value={dEcName} onChange={e => { setDEcName(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, ecName: '' })); }} placeholder="e.g. Raj Kumar" required />
              <FieldError msg={errors.ecName} />
            </div>
            <div className={`form-group ${errors.ecRel ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-people-arrows fa-fw" /> Relationship</label>
              <select value={dEcRel} onChange={e => { setDEcRel(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, ecRel: '' })); }} required>
                <option value="">-- Select --</option>
                {relationships.map(r => <option key={String(r.id)} value={String(r.id)}>{r.value}</option>)}
              </select>
              <FieldError msg={errors.ecRel} />
            </div>
            <div className={`form-group ${errors.ecPhone ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-phone fa-fw" /> Phone Number</label>
              <input value={dEcPhone} onChange={e => { setDEcPhone(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, ecPhone: '' })); }} placeholder="e.g. +91 98765 43210" required />
              <FieldError msg={errors.ecPhone} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-mobile fa-fw" /> Alternate Phone</label>
              <input value={dEcAlt} onChange={e => { setDEcAlt(e.target.value); setIsDirty(true); }} placeholder="e.g. +91 91234 56789" />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-envelope fa-fw" /> Email</label>
              <input type="email" value={dEcEmail} onChange={e => { setDEcEmail(e.target.value); setIsDirty(true); }} placeholder="e.g. raj@example.com" />
            </div>
          </div>
        </div>
      );

      // ── Bank Accounts ─────────────────────────────────────────────────────────
      case 'bank': return (
        <BankAccountsPortlet
          employeeId={liveEmp.id as string}
          hireDate={liveEmp.hireDate as string | undefined}
          isNewHire={false}
          canCreate={can('bank_accounts.create')}
          canEdit={can('bank_accounts.edit')}
          canDelete={can('bank_accounts.delete')}
          editMode={can('bank_accounts.create') || can('bank_accounts.edit') || can('bank_accounts.delete')}
          pendingCount={pendingSections.has('bank') ? 1 : 0}
          isBankException={true}
          saveAllRef={bankSaveAllRef}
          onChanged={refetchPendingSections}
        />
      );

      // ── Dependents ────────────────────────────────────────────────────────────
      case 'dependents': return (
        <DependentsPortlet
          employeeId={liveEmp.id as string}
          hireDate={liveEmp.hireDate as string | undefined}
          isNewHire={false}
          canEdit={can('dependents.edit')}
          canDelete={can('dependents.delete')}
          editMode={can('dependents.edit')}
          pendingCount={pendingSections.has('dependents') ? 1 : 0}
          saveAllRef={depSaveAllRef}
          onChanged={refetchPendingSections}
        />
      );

      // ── Job Relationships ─────────────────────────────────────────────────
      case 'job_relationships': return (
        <JobRelationshipsPortlet
          employeeId={liveEmp.id as string}
          canCreate={can('job_relationships.create')}
          canEdit={can('job_relationships.edit')}
          canDelete={can('job_relationships.delete')}
          editMode={can('job_relationships.create') || can('job_relationships.edit')}
          pendingCount={pendingSections.has('job_relationships') ? 1 : 0}
          saveAllRef={jrSaveAllRef}
          onChanged={refetchPendingSections}
        />
      );

      // ── Education ─────────────────────────────────────────────────────────
      case 'education': return (
        <EducationPortlet
          employeeId={liveEmp.id as string}
          canCreate={can('education.create')}
          canEdit={can('education.edit')}
          canDelete={can('education.delete')}

          pendingCount={pendingSections.has('education') ? 1 : 0}
          onChanged={refetchPendingSections}
        />
      );

      case 'termination': return (
        <TerminationPortlet
          employeeId={liveEmp.id as string}
          employeeName={liveEmp.name as string}
          isSelfService={false}
          readOnly={!can('termination.edit')}
          canEdit={can('termination.edit')}
          canHistory={can('termination.history')}
          onChanged={refetchPendingSections}
          sectionTitle={{ icon: 'fa-user-slash', text: 'Termination' }}
        />
      );

      default: return null;
    }
  }

  // ── Render ────────────────────────────────────────────────────────────────
  const roleBadge: Record<string, { bg: string; color: string }> = {
    'Department Manager': { bg: '#F3E8FF', color: '#7C3AED' },
    'Manager':            { bg: '#DBEAFE', color: '#1D4ED8' },
    'Employee':           { bg: '#F3F4F6', color: '#374151' },
  };
  const rb = roleBadge[(liveEmp.role as string) || 'Employee'] ?? roleBadge['Employee'];

  return (
    <div className="emp-edit-panel">
      {/* Workflow gate banner */}
      <WorkflowGateBanner moduleCode="employee_edit" actionLabel="employee detail edits" />

      {/* ── Header ─────────────────────────────────────────────────────────── */}
      <div className="emp-edit-panel-header">
        <button className="emp-edit-back-btn" onClick={onClose}>
          <i className="fa-solid fa-arrow-left" /> Back to List
        </button>
        <div className="emp-edit-header-info">
          <img
            src={(liveEmp.photo as string) || `https://ui-avatars.com/api/?name=${encodeURIComponent(liveEmp.name)}&background=2F77B5&color=fff&size=56`}
            alt={liveEmp.name}
            style={{ width: 52, height: 52, borderRadius: '50%', objectFit: 'cover', border: '2px solid rgba(255,255,255,0.3)' }}
          />
          <div>
            <div style={{ fontWeight: 700, fontSize: 17, color: '#fff' }}>{liveEmp.name}</div>
            <div style={{ fontSize: 12.5, color: 'rgba(255,255,255,0.7)', marginTop: 2 }}>
              {liveEmp.employeeId} · {resolveDesig()}
            </div>
          </div>
          <span style={{ marginLeft: 12, padding: '3px 12px', borderRadius: 20, fontSize: 12, fontWeight: 600, background: rb.bg, color: rb.color }}>
            {(liveEmp.role as string) || 'Employee'}
          </span>
        </div>
      </div>

      {/* ── Dirty warning banner ────────────────────────────────────────────── */}
      {dirtyTarget && (
        <div className="emp-edit-dirty-banner">
          <i className="fa-solid fa-triangle-exclamation" />
          You have unsaved changes in <strong>{SECTIONS.find(s => s.id === openSection)?.label}</strong>. Save or cancel before switching.
          <div style={{ display: 'flex', gap: 8, marginLeft: 'auto' }}>
            <button className="emp-btn-ghost" style={{ fontSize: 12, padding: '4px 12px' }} onClick={() => { cancelEdit(); doOpen(dirtyTarget!); }}>
              Discard & Switch
            </button>
          </div>
        </div>
      )}

      {/* ── 180-day probation modal ─────────────────────────────────────────── */}
      {probWarning.open && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.5)', zIndex: 9999, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ background: '#fff', borderRadius: 14, padding: 28, maxWidth: 420, width: '90%', boxShadow: '0 20px 60px rgba(0,0,0,0.2)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
              <i className="fa-solid fa-triangle-exclamation" style={{ color: '#F59E0B', fontSize: 20 }} />
              <strong style={{ fontSize: 15 }}>Extended Probation Period</strong>
            </div>
            <p style={{ fontSize: 13.5, color: '#374151', lineHeight: 1.6, marginBottom: 20 }}>
              The selected probation end date exceeds <strong>180 days</strong> from the hire date. This is outside the standard probation window. Are you sure you want to proceed?
            </p>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button className="emp-btn-ghost" onClick={() => setProbWarning({ open: false, pendingDate: '' })}>Revise Date</button>
              <button className="emp-btn-primary" onClick={() => { setDProbation(probWarning.pendingDate); setIsDirty(true); setProbWarning({ open: false, pendingDate: '' }); }}>Proceed Anyway</button>
            </div>
          </div>
        </div>
      )}

      {/* ── Deactivation impact modal ───────────────────────────────────────── */}
      {deactivationModal.open && (
        <DeactivationImpactModal
          employeeId={liveEmp.id as string}
          employeeName={liveEmp.name as string}
          onCancel={() => setDeactivationModal({ open: false, pendingAction: null })}
          onConfirm={() => {
            setDeactivationModal({ open: false, pendingAction: null });
            deactivationModal.pendingAction?.();
          }}
        />
      )}

      {/* ── Section cards ───────────────────────────────────────────────────── */}
      <div className="emp-edit-sections">
        {SECTIONS.map(sec => {
          const isOpen = openSection === sec.id;
          return (
            <div key={sec.id} className={`emp-edit-card ${isOpen ? 'emp-edit-card--open' : ''}`}>
              {/* Card header */}
              <div className="emp-edit-card-header" onClick={() => !isOpen && requestOpen(sec.id)}>
                <div className="emp-edit-card-title">
                  <i className={`fa-solid ${sec.icon}`} />
                  <span>{sec.label}</span>
                  {sec.optional && <span className="section-optional-tag">Optional</span>}
                  {pendingSections.has(sec.id) && (
                    <span title="Employee has a pending change request for this section" style={{
                      display: 'inline-flex', alignItems: 'center', gap: 4,
                      background: '#FEF3C7', color: '#D97706',
                      fontSize: 11, fontWeight: 600, padding: '2px 8px', borderRadius: 10,
                    }}>
                      <i className="fa-solid fa-clock" /> Pending request
                    </span>
                  )}
                </div>
                {pendingSections.has(sec.id)
                  ? <span style={{ fontSize: 12, color: '#D97706', display: 'flex', alignItems: 'center', gap: 5, fontWeight: 600 }}>
                      <i className="fa-solid fa-lock" /> Under review
                    </span>
                  : (!isOpen
                      ? sec.id === 'employment'
                        ? (
                          <div style={{ display: 'flex', gap: 6 }}>
                            {can('employment.create') && (
                              <button
                                className="emp-edit-btn-edit"
                                style={{ background: '#EFF6FF', color: '#2563EB', borderColor: '#BFDBFE' }}
                                onClick={e => { e.stopPropagation(); requestOpenEmployment('insert'); }}
                              >
                                <i className="fa-solid fa-plus" /> Insert
                              </button>
                            )}
                            {can('employment.edit') && (
                              <button
                                className="emp-edit-btn-edit"
                                onClick={e => { e.stopPropagation(); requestOpenEmployment('edit'); }}
                              >
                                <i className="fa-solid fa-pen-to-square" /> Edit
                              </button>
                            )}
                          </div>
                        )
                        : <button className="emp-edit-btn-edit" onClick={e => { e.stopPropagation(); requestOpen(sec.id); }}>
                            <i className="fa-solid fa-pen-to-square" /> Edit
                          </button>
                      : <button className="emp-edit-btn-close" onClick={e => { e.stopPropagation(); cancelEdit(); }}>
                          <i className="fa-solid fa-xmark" />
                        </button>
                    )
                }
              </div>

              {/* Card body */}
              <div className="emp-edit-card-body">
                {isOpen ? (
                  <>
                    {sec.id === 'bank' ? (
                      <>
                        <div style={{ padding: '16px 20px' }}>
                          {editForm(sec.id)}
                        </div>
                        {can('bank_accounts.edit') && (
                          <div className="emp-edit-card-footer">
                            <button className="emp-btn-ghost" onClick={cancelEdit}>
                              <i className="fa-solid fa-xmark" /> Cancel
                            </button>
                            <button
                              className="emp-btn-primary"
                              disabled={bankSaving}
                              onClick={async () => {
                                setBankSaving(true);
                                const ok = await bankSaveAllRef.current?.() ?? true;
                                setBankSaving(false);
                                if (ok) cancelEdit();
                              }}
                            >
                              {bankSaving
                                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                                : <><i className="fa-solid fa-check" /> Done Editing</>
                              }
                            </button>
                          </div>
                        )}
                      </>
                    ) : sec.id === 'dependents' ? (
                      <>
                        <div style={{ padding: '16px 20px' }}>
                          {editForm(sec.id)}
                        </div>
                        {can('dependents.edit') && (
                          <div className="emp-edit-card-footer">
                            <button className="emp-btn-ghost" onClick={cancelEdit}>
                              <i className="fa-solid fa-xmark" /> Cancel
                            </button>
                            <button
                              className="emp-btn-primary"
                              disabled={depSaving}
                              onClick={async () => {
                                setDepSaving(true);
                                const ok = await depSaveAllRef.current?.() ?? true;
                                setDepSaving(false);
                                if (ok) cancelEdit();
                              }}
                            >
                              {depSaving
                                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                                : <><i className="fa-solid fa-check" /> Done Editing</>
                              }
                            </button>
                          </div>
                        )}
                      </>
                    ) : sec.id === 'job_relationships' ? (
                      <>
                        <div style={{ padding: '16px 20px' }}>
                          {editForm(sec.id)}
                        </div>
                        {can('job_relationships.edit') && (
                          <div className="emp-edit-card-footer">
                            <button className="emp-btn-ghost" onClick={cancelEdit}>
                              <i className="fa-solid fa-xmark" /> Cancel
                            </button>
                            <button
                              className="emp-btn-primary"
                              disabled={jrSaving}
                              onClick={async () => {
                                setJrSaving(true);
                                const ok = await jrSaveAllRef.current?.() ?? true;
                                setJrSaving(false);
                                if (ok) cancelEdit();
                              }}
                            >
                              {jrSaving
                                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                                : <><i className="fa-solid fa-check" /> Done Editing</>
                              }
                            </button>
                          </div>
                        )}
                      </>
                    ) : sec.id === 'education' ? (
                      <>
                        <div style={{ padding: '16px 20px' }}>
                          {editForm(sec.id)}
                        </div>
                        <div className="emp-edit-card-footer">
                          <button className="emp-btn-ghost" onClick={cancelEdit}>
                            <i className="fa-solid fa-xmark" /> Close
                          </button>
                        </div>
                      </>
                    ) : (
                    <div className="emp-form-card">
                      {editForm(sec.id)}
                    </div>
                    )}
                    {sec.id !== 'bank' && sec.id !== 'dependents' && sec.id !== 'job_relationships' && (
                    <div className="emp-edit-card-footer">
                      <button className="emp-btn-ghost" onClick={cancelEdit}>
                        <i className="fa-solid fa-xmark" /> Cancel
                      </button>
                      {errors._global && (
                        <span style={{ color: '#DC2626', fontSize: 12, marginRight: 8 }}>
                          <i className="fa-solid fa-circle-exclamation" /> {errors._global}
                        </span>
                      )}
                      <button className="emp-btn-primary" onClick={() => saveSection(sec.id)} disabled={saving}>
                        {saving
                          ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                          : <><i className="fa-solid fa-check" /> Save Changes</>
                        }
                      </button>
                    </div>
                    )}
                  </>
                ) : pendingSections.has(sec.id) ? (
                  <div style={{
                    display: 'flex', alignItems: 'center', gap: 10,
                    padding: '12px 16px', fontSize: 13, color: '#92400E',
                    background: '#FFFBEB', borderTop: '1px solid #FEF3C7',
                  }}>
                    <i className="fa-solid fa-clock" style={{ color: '#D97706', flexShrink: 0 }} />
                    <span>
                      A change request from this employee is currently under workflow review.
                      Editing is blocked until the request is resolved.
                    </span>
                  </div>
                ) : (
                  <div className="emp-edit-card-summary">
                    {readSummary(sec.id)}
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>

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
            setIsDirty(true);
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
            setDPassCountry(passportCountryPending);
            setDPassNumber('');
            setDPassIssueDate('');
            setDPassExpiry('');
            setIsDirty(true);
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
          setDIdRecords(prev =>
            prev
              .filter((_, j) => j !== deletePrimaryModal.index)
              .map(r => r.recordType === 'secondary' ? { ...r, recordType: 'primary' } : r)
          );
          setIsDirty(true);
          setDeletePrimaryModal({ open: false, index: -1 });
        }}
        onCancel={() => setDeletePrimaryModal({ open: false, index: -1 })}
      />

      {/* ── Section save error modal (identity, passport, address, emergency) ── */}
      {sectionErrorModal.open && (
        <div className="modal-overlay" onClick={() => setSectionErrorModal({ open: false, message: '' })}>
          <div className="modal-box" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <i className="fa-solid fa-triangle-exclamation modal-icon" style={{ color: '#D97706' }} />
              <h3>Save Error</h3>
            </div>
            <div className="modal-body" style={{ whiteSpace: 'pre-line' }}>{sectionErrorModal.message}</div>
            <div className="modal-actions">
              <button
                className="emp-btn-primary"
                style={{ padding: '9px 28px', fontSize: 13.5 }}
                onClick={() => setSectionErrorModal({ open: false, message: '' })}
              >
                OK
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );

  function resolveDesig() {
    const m = picklistVals.find(p => p.picklistId === 'DESIGNATION' && (String(p.id) === String(liveEmp.designation) || p.refId === String(liveEmp.designation)));
    return m ? m.value : (liveEmp.designation as string) || '—';
  }
}
