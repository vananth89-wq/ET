import { useState, useMemo, useEffect, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import WorkflowGateBanner from '../../workflow/components/WorkflowGateBanner';
import { useEmployees } from '../../hooks/useEmployees';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { useDepartments } from '../../hooks/useDepartments';
import { useCurrencies } from '../../hooks/useCurrencies';
import type { FullEmployee } from './AddEmployee';
import { COUNTRIES } from './AddEmployee';

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
  { id: 'personal',   label: 'Personal Information',    icon: 'fa-circle-user',   optional: false },
  { id: 'contact',    label: 'Phone',                   icon: 'fa-phone',          optional: false },
  { id: 'email',      label: 'Email',                   icon: 'fa-envelope',       optional: false },
  { id: 'employment', label: 'Employment',              icon: 'fa-briefcase',      optional: false },
  { id: 'identity',   label: 'Employee Identification', icon: 'fa-id-card-clip',   optional: true  },
  { id: 'passport',   label: 'Passport Information',    icon: 'fa-passport',       optional: true  },
  { id: 'address',    label: 'Address',                 icon: 'fa-location-dot',   optional: false },
  { id: 'emergency',  label: 'Emergency Contact',       icon: 'fa-phone-volume',   optional: false },
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
export default function EmployeeEditPanel({ emp, onClose, onSaved }: Props) {
  // ── Supabase data ─────────────────────────────────────────────────────────
  const { employees }                    = useEmployees();
  const { picklistValues: picklistVals } = usePicklistValues();
  const { departments }                  = useDepartments();
  const { currencies: currencyList }     = useCurrencies();

  // Local copy of the employee kept in sync after each section save
  const [liveEmp, setLiveEmp] = useState<FullEmployee>(emp);
  const [saving,  setSaving]  = useState(false);

  // Suppresses auto-derive effects (probation, currency) while loading saved data
  // into the employment form so they don't overwrite the existing DB values.
  const isLoadingEmploymentRef = useRef(false);

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
  const [dPhoto,       setDPhoto]       = useState('');
  const photoRef = useRef<HTMLInputElement>(null);

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
  const [dHireDate,   setDHireDate]   = useState('');
  const [dEndDate,    setDEndDate]    = useState('9999-12-31');
  const [dProbation,  setDProbation]  = useState('');
  const [dWorkCountry,setDWorkCountry]= useState('');
  const [dWorkLoc,    setDWorkLoc]    = useState('');
  const [dCurrency,   setDCurrency]   = useState('');
  const [probWarning, setProbWarning] = useState<{ open: boolean; pendingDate: string }>({ open: false, pendingDate: '' });

  // Identity
  const [dIdRecords,   setDIdRecords]  = useState<IdRecord[]>([]);
  const [idCountry,    setIdCountry]   = useState('');
  const [idType,       setIdType]      = useState('');
  const [idRecordType, setIdRecordType]= useState('');
  const [idNumber,     setIdNumber]    = useState('');
  const [idExpiry,     setIdExpiry]    = useState('');

  // Passport
  const [dPassCountry,   setDPassCountry]   = useState('');
  const [dPassNumber,    setDPassNumber]    = useState('');
  const [dPassIssueDate, setDPassIssueDate] = useState('');
  const [dPassExpiry,    setDPassExpiry]    = useState('');

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
        setDMarital((e.maritalStatus as string) || ''); setDPhoto((e.photo as string) || '');
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
        setDEndDate((e.endDate as string) || '9999-12-31'); setDProbation((e.probationEndDate as string) || '');
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
  }

  // ── Validate ──────────────────────────────────────────────────────────────
  function validate(sectionId: string): Record<string, string> {
    const errs: Record<string, string> = {};
    switch (sectionId) {
      case 'personal':
        if (!dName.trim()) errs.name = 'Full name is required.';
        if (!dNationality) errs.nationality = 'Nationality is required.';
        if (!dMarital)     errs.maritalStatus = 'Marital status is required.';
        break;
      case 'contact':
        if (!dMobile.trim()) errs.mobile = 'Mobile number is required.';
        else if (!/^\d{7,15}$/.test(dMobile.trim())) errs.mobile = 'Enter 7–15 digits only.';
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
        if (dBizEmail.trim() && dPersEmail.trim() &&
            dBizEmail.trim().toLowerCase() === dPersEmail.trim().toLowerCase())
          errs.personalEmail = 'Personal email cannot be the same as business email.';
        break;
      case 'employment':
        if (!dDesig)    errs.designation = 'Designation is required.';
        if (!dDeptId)   errs.deptId      = 'Department is required.';
        if (!dHireDate) errs.hireDate    = 'Hire date is required.';
        if (!dProbation)errs.probation   = 'Probation end date is required.';
        if (!dWorkCountry) errs.workCountry = 'Country of work is required.';
        if (!dWorkLoc)  errs.workLocation = 'Location is required.';
        break;
      case 'passport':
        if (dPassCountry) {
          if (!dPassNumber.trim()) errs.passportNumber = 'Passport Number is required.';
          if (!dPassIssueDate)     errs.passportIssueDate = 'Issue Date is required.';
          if (!dPassExpiry)        errs.passportExpiry = 'Expiry Date is required.';
        }
        break;
      case 'address':
        if (!dAddrLine1.trim()) errs.addrLine1 = 'Address line 1 is required.';
        if (!dAddrLine2.trim()) errs.addrLine2 = 'Address line 2 is required.';
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
        frontendPatch = { name: dName.trim(), nationality: dNationality, maritalStatus: dMarital, photo: dPhoto };
        // name stays in employees core; personal attributes go to employee_personal satellite
        dbPatch = { name: dName.trim() };
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
          hireDate: dHireDate, endDate: dEndDate, probationEndDate: dProbation,
          workCountry: dWorkCountry, workLocation: dWorkLoc, baseCurrencyId: dCurrency,
        };
        // Core employment fields stay in employees; probation_end_date goes to employee_employment
        dbPatch = {
          designation:      dDesig || null,
          dept_id:          dDeptId || null,
          manager_id:       dManagerId || null,
          hire_date:        dHireDate || null,
          end_date:         dEndDate || null,
          work_country:     dWorkCountry || null,
          work_location:    dWorkLoc || null,
          base_currency_id: dCurrency || null,
        };
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

          frontendPatch = { idRecords: recordsToSave };
          const { error: delErr } = await supabase.from('identity_records').delete().eq('employee_id', empUUID);
          if (delErr) { extError = delErr.message; }
          else if (recordsToSave.length > 0) {
            const { error: insErr } = await supabase.from('identity_records').insert(
              recordsToSave.map(r => ({
                employee_id: empUUID,
                country:     r.country    || null,
                id_type:     r.idType     || null,
                record_type: r.recordType || null,
                id_number:   r.idNumber   || null,
                expiry:      r.expiry     || null,
              }))
            );
            if (insErr) extError = insErr.message;
          }
        } else if (sectionId === 'passport') {
          frontendPatch = { passportCountry: dPassCountry, passportNumber: dPassNumber, passportIssueDate: dPassIssueDate, passportExpiryDate: dPassExpiry };
          const { error: passDel } = await supabase.from('passports').delete().eq('employee_id', empUUID);
          if (passDel) { extError = passDel.message; }
          else if (dPassCountry || dPassNumber) {
            const { error: insErr } = await supabase.from('passports').insert({
              employee_id:     empUUID,
              country:         dPassCountry   || null,
              passport_number: dPassNumber    || null,
              issue_date:      dPassIssueDate || null,
              expiry_date:     dPassExpiry    || null,
            });
            if (insErr) extError = insErr.message;
          }
        } else if (sectionId === 'address') {
          frontendPatch = { addrLine1: dAddrLine1, addrLine2: dAddrLine2, addrLandmark: dAddrLandmark, addrCity: dAddrCity, addrDistrict: dAddrDistrict, addrState: dAddrState, addrPin: dAddrPin, addrCountry: dAddrCountry };
          const { error: addrDel } = await supabase.from('employee_addresses').delete().eq('employee_id', empUUID);
          if (addrDel) { extError = addrDel.message; }
          else if (dAddrLine1 || dAddrCity) {
            const { error: insErr } = await supabase.from('employee_addresses').insert({
              employee_id: empUUID,
              line1:       dAddrLine1    || null,
              line2:       dAddrLine2    || null,
              landmark:    dAddrLandmark || null,
              city:        dAddrCity     || null,
              district:    dAddrDistrict || null,
              state:       dAddrState    || null,
              pin:         dAddrPin      || null,
              country:     dAddrCountry  || null,
            });
            if (insErr) extError = insErr.message;
          }
        } else {
          // emergency
          frontendPatch = { ecName: dEcName, ecRelationship: dEcRel, ecPhone: dEcPhone, ecAltPhone: dEcAlt, ecEmail: dEcEmail };
          const { error: ecDel } = await supabase.from('emergency_contacts').delete().eq('employee_id', empUUID);
          if (ecDel) { extError = ecDel.message; }
          else if (dEcName || dEcPhone) {
            const { error: insErr } = await supabase.from('emergency_contacts').insert({
              employee_id:  empUUID,
              name:         dEcName || '',
              relationship: dEcRel  || null,
              phone:        dEcPhone || null,
              alt_phone:    dEcAlt  || null,
              email:        dEcEmail || null,
            });
            if (insErr) extError = insErr.message;
          }
        }

        setSaving(false);
        if (extError) { setErrors({ _global: extError }); return; }
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
      const { error } = await supabase
        .from('employee_personal')
        .upsert({
          employee_id:    empUUID,
          nationality:    dNationality || null,
          marital_status: dMarital     || null,
          photo_url:      dPhoto       || null,
        }, { onConflict: 'employee_id' });
      if (error) satelliteError = error.message;
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
      const { error } = await supabase
        .from('employee_contact')
        .upsert({
          employee_id:    empUUID,
          personal_email: dPersEmail.trim() || null,
        }, { onConflict: 'employee_id' });
      if (error) satelliteError = error.message;
    }

    if (sectionId === 'employment') {
      const { error } = await supabase
        .from('employee_employment')
        .upsert({
          employee_id:       empUUID,
          probation_end_date: dProbation || null,
        }, { onConflict: 'employee_id' });
      if (error) satelliteError = error.message;
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
      default: return null;
    }
  }

  // ── Edit forms ────────────────────────────────────────────────────────────
  function editForm(sectionId: string) {
    switch (sectionId) {
      // ── Personal ───────────────────────────────────────────────────────────
      case 'personal': return (
        <div className="emp-section">
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
                <select value={dCountryCode} onChange={e => { setDCountryCode(e.target.value); setIsDirty(true); }} style={{ width: 100, flexShrink: 0 }}>
                  {PHONE_CODES.map(p => <option key={p.code} value={p.code}>{p.label}</option>)}
                </select>
                <input type="tel" value={dMobile} onChange={e => { setDMobile(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, mobile: '' })); }} placeholder="e.g. 9876543210" required />
              </div>
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
              <input type="date" value={dHireDate} onChange={e => { setDHireDate(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, hireDate: '' })); }} required />
              <FieldError msg={errors.hireDate} />
            </div>
            <div className={`form-group ${errors.probation ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-hourglass-half fa-fw" /> Probation End Date</label>
              <input type="date" value={dProbation} onChange={e => { handleProbationChange(e.target.value); }} required />
              <FieldError msg={errors.probation} />
            </div>
            <div className="form-group">
              <label><i className="fa-solid fa-calendar-check fa-fw" /> Contract End Date</label>
              <input type="date" value={dEndDate === '9999-12-31' ? '' : dEndDate}
                onChange={e => { setDEndDate(e.target.value || '9999-12-31'); setIsDirty(true); }} />
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
                          onClick={() => { setDIdRecords(p => p.filter((_, j) => j !== i)); setIsDirty(true); }}>
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
                <select value={idCountry} onChange={e => { setIdCountry(e.target.value); setIdType(''); setErrors(p => ({ ...p, idCountry: '' })); }}>
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
                  else setErrors(p => ({ ...p, idType: '' }));
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
                  <option value="secondary">Secondary</option>
                </select>
                <FieldError msg={errors.idRecordType} />
              </div>
            </div>
            <div className="emp-field-grid emp-id-grid-bottom">
              <div className={`form-group ${errors.idNumber ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-hashtag fa-fw" /> ID Number</label>
                <input type="text" value={idNumber} onChange={e => { setIdNumber(e.target.value); setErrors(p => ({ ...p, idNumber: '' })); }} placeholder="e.g. 1234-5678-9012" required={!!idType} />
                <FieldError msg={errors.idNumber} />
              </div>
              <div className={`form-group ${errors.idExpiry ? 'form-group--error' : ''}`}>
                <label><i className="fa-solid fa-calendar-xmark fa-fw" /> Expiry Date</label>
                <input type="date" value={idExpiry} onChange={e => { setIdExpiry(e.target.value); setErrors(p => ({ ...p, idExpiry: '' })); }} required={!!idType} />
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
              <select value={dPassCountry} onChange={e => { setDPassCountry(e.target.value); setIsDirty(true); }}>
                <option value="">-- Select --</option>
                {idCountries.map(c => <option key={String(c.id)} value={String(c.id)}>{c.value}</option>)}
              </select>
            </div>
            <div className={`form-group ${errors.passportNumber ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-passport fa-fw" /> Passport Number</label>
              <input value={dPassNumber} onChange={e => { setDPassNumber(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, passportNumber: '' })); }} placeholder="e.g. A1234567" required={!!dPassCountry} />
              <FieldError msg={errors.passportNumber} />
            </div>
            <div className={`form-group ${errors.passportIssueDate ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-calendar-plus fa-fw" /> Issue Date</label>
              <input type="date" value={dPassIssueDate} onChange={e => { setDPassIssueDate(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, passportIssueDate: '' })); }} required={!!dPassCountry} />
              <FieldError msg={errors.passportIssueDate} />
            </div>
            <div className={`form-group ${errors.passportExpiry ? 'form-group--error' : ''}`}>
              <label><i className="fa-solid fa-calendar-xmark fa-fw" /> Expiry Date</label>
              <input type="date" value={dPassExpiry} onChange={e => { setDPassExpiry(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, passportExpiry: '' })); }} required={!!dPassCountry} />
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
              <input value={dAddrLine2} onChange={e => { setDAddrLine2(e.target.value); setIsDirty(true); setErrors(p => ({ ...p, addrLine2: '' })); }} placeholder="Street / Area" required />
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
                </div>
                {!isOpen
                  ? <button className="emp-edit-btn-edit" onClick={e => { e.stopPropagation(); requestOpen(sec.id); }}>
                      <i className="fa-solid fa-pen-to-square" /> Edit
                    </button>
                  : <button className="emp-edit-btn-close" onClick={e => { e.stopPropagation(); cancelEdit(); }}>
                      <i className="fa-solid fa-xmark" />
                    </button>
                }
              </div>

              {/* Card body */}
              <div className="emp-edit-card-body">
                {isOpen ? (
                  <>
                    <div className="emp-form-card">
                      {editForm(sec.id)}
                    </div>
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
                  </>
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
    </div>
  );

  function resolveDesig() {
    const m = picklistVals.find(p => p.picklistId === 'DESIGNATION' && (String(p.id) === String(liveEmp.designation) || p.refId === String(liveEmp.designation)));
    return m ? m.value : (liveEmp.designation as string) || '—';
  }
}
