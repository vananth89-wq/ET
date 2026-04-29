import { useRef, useEffect, useState } from 'react';
import { useAuth } from '../../../contexts/AuthContext';
import { usePermissions } from '../../../hooks/usePermissions';
import { usePicklistValues } from '../../../hooks/usePicklistValues';
import { useDepartments } from '../../../hooks/useDepartments';
import { useEmployees } from '../../../hooks/useEmployees';
import { useCurrencies } from '../../../hooks/useCurrencies';
import { supabase } from '../../../lib/supabase';
import { COUNTRIES } from '../../admin/AddEmployee';
import WorkflowGateBanner           from '../../../workflow/components/WorkflowGateBanner';
import { useProfileWorkflowGates } from '../../../workflow/hooks/useProfileWorkflowGates';

// ── Phone codes for the mobile country-code picker ─────────────────────────

const PHONE_CODES: { code: string; flag: string }[] = [
  { code: '+1',   flag: '🇺🇸' }, { code: '+7',   flag: '🇷🇺' },
  { code: '+27',  flag: '🇿🇦' }, { code: '+33',  flag: '🇫🇷' },
  { code: '+34',  flag: '🇪🇸' }, { code: '+39',  flag: '🇮🇹' },
  { code: '+44',  flag: '🇬🇧' }, { code: '+49',  flag: '🇩🇪' },
  { code: '+52',  flag: '🇲🇽' }, { code: '+55',  flag: '🇧🇷' },
  { code: '+60',  flag: '🇲🇾' }, { code: '+61',  flag: '🇦🇺' },
  { code: '+62',  flag: '🇮🇩' }, { code: '+63',  flag: '🇵🇭' },
  { code: '+64',  flag: '🇳🇿' }, { code: '+65',  flag: '🇸🇬' },
  { code: '+66',  flag: '🇹🇭' }, { code: '+81',  flag: '🇯🇵' },
  { code: '+82',  flag: '🇰🇷' }, { code: '+84',  flag: '🇻🇳' },
  { code: '+86',  flag: '🇨🇳' }, { code: '+91',  flag: '🇮🇳' },
  { code: '+92',  flag: '🇵🇰' }, { code: '+94',  flag: '🇱🇰' },
  { code: '+880', flag: '🇧🇩' }, { code: '+966', flag: '🇸🇦' },
  { code: '+971', flag: '🇦🇪' }, { code: '+977', flag: '🇳🇵' },
];

// ── Shared display helpers ─────────────────────────────────────────────────

function fmtDate(val: string | undefined): string {
  if (!val) return '—';
  if (val === '9999-12-31') return 'Open-ended';
  try {
    return new Date(val + 'T00:00:00').toLocaleDateString('en-IN', {
      day: '2-digit', month: 'short', year: 'numeric',
    });
  } catch { return val; }
}

function Field({ label, value }: { label: string; value?: string | null }) {
  const isEmpty = !value || value === '—';
  return (
    <div className="ev-field">
      <div className="ev-field-label">{label}</div>
      {isEmpty
        ? <span className="ev-field-value ev-empty">Not provided</span>
        : <span className="ev-field-value">{value}</span>}
    </div>
  );
}

function MobileField({ countryCode, mobile }: { countryCode?: string; mobile?: string }) {
  if (!mobile) {
    return (
      <div className="ev-field">
        <div className="ev-field-label">Mobile No.</div>
        <span className="ev-field-value ev-empty">Not provided</span>
      </div>
    );
  }
  const dialCode = countryCode || '+91';
  const entry    = PHONE_CODES.find(p => p.code === dialCode);
  const flag     = entry?.flag ?? '🌐';
  return (
    <div className="ev-field">
      <div className="ev-field-label">Mobile No.</div>
      <div className="ev-mobile-display">
        <span className="ev-mobile-country">
          <span className="ev-mobile-flag">{flag}</span>
          <span className="ev-mobile-dial">{dialCode}</span>
        </span>
        <span className="ev-mobile-number">{mobile}</span>
      </div>
    </div>
  );
}

function SectionTitle({ icon, text }: { icon: string; text: string }) {
  return (
    <div className="ev-section-title">
      <i className={`fa-solid ${icon}`} /> {text}
    </div>
  );
}

// ── Form helpers (used inside edit mode) ──────────────────────────────────

const inputStyle: React.CSSProperties = {
  width: '100%', padding: '7px 10px', borderRadius: 6,
  border: '1px solid #D1D5DB', fontSize: 13, outline: 'none',
  boxSizing: 'border-box', background: '#fff', color: '#111827',
};

function FormInput({
  label, value, onChange, type = 'text', placeholder = '',
}: {
  label: string; value: string; onChange: (v: string) => void;
  type?: string; placeholder?: string;
}) {
  return (
    <div className="ev-field">
      <div className="ev-field-label">{label}</div>
      <input
        type={type}
        value={value}
        placeholder={placeholder}
        onChange={e => onChange(e.target.value)}
        style={inputStyle}
      />
    </div>
  );
}

function FormSelect({
  label, value, onChange, options, placeholder = '— Select —',
}: {
  label: string; value: string; onChange: (v: string) => void;
  options: { value: string; label: string }[];
  placeholder?: string;
}) {
  return (
    <div className="ev-field">
      <div className="ev-field-label">{label}</div>
      <select value={value} onChange={e => onChange(e.target.value)} style={inputStyle}>
        <option value="">{placeholder}</option>
        {options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    </div>
  );
}

function EditButton({ onClick }: { onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 5,
        padding: '5px 14px', borderRadius: 6, cursor: 'pointer',
        border: '1px solid #D1D5DB', background: '#F9FAFB',
        fontSize: 12, fontWeight: 600, color: '#374151',
        transition: 'all 0.15s',
      }}
    >
      <i className="fa-solid fa-pen" style={{ fontSize: 11 }} /> Edit
    </button>
  );
}

function SaveCancelRow({
  onSave, onCancel, saving, error,
}: {
  onSave: () => void; onCancel: () => void;
  saving: boolean; error: string | null;
}) {
  return (
    <div style={{ marginTop: 16, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
      <button
        onClick={onSave}
        disabled={saving}
        style={{
          display: 'inline-flex', alignItems: 'center', gap: 6,
          padding: '7px 18px', borderRadius: 6, cursor: saving ? 'not-allowed' : 'pointer',
          border: 'none', background: '#2563EB', color: '#fff',
          fontSize: 13, fontWeight: 600, opacity: saving ? 0.7 : 1,
        }}
      >
        {saving
          ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
          : <><i className="fa-solid fa-check" /> Save Changes</>}
      </button>
      <button
        onClick={onCancel}
        disabled={saving}
        style={{
          padding: '7px 16px', borderRadius: 6, cursor: saving ? 'not-allowed' : 'pointer',
          border: '1px solid #D1D5DB', background: '#fff',
          fontSize: 13, fontWeight: 500, color: '#374151',
        }}
      >
        Cancel
      </button>
      {error && (
        <span style={{ color: '#DC2626', fontSize: 12, display: 'flex', alignItems: 'center', gap: 4 }}>
          <i className="fa-solid fa-circle-exclamation" /> {error}
        </span>
      )}
    </div>
  );
}

// ── Main Component ──────────────────────────────────────────────────────────

export default function MyProfile() {
  const { employee: authEmployee, roles, profileLoading, refetchProfile } = useAuth();
  const { can }                          = usePermissions();
  const { picklistValues }               = usePicklistValues();
  const { departments }                  = useDepartments();
  const { employees }                    = useEmployees();
  const { currencies }                   = useCurrencies();
  const [activeSection, setActiveSection] = useState('personal');

  // Single batched query for all profile section workflow gates + pending counts
  const { activeGates, pendingCounts } = useProfileWorkflowGates();
  const scrollRef  = useRef<HTMLDivElement>(null);
  const sectionRefs = useRef<Record<string, HTMLElement | null>>({});

  // Extended data from related tables
  const [extData, setExtData] = useState<Record<string, unknown>>({});

  // Edit mode state
  const [editingSection, setEditingSection] = useState<string | null>(null);
  const [formData,       setFormData]       = useState<Record<string, string>>({});
  const [saving,         setSaving]         = useState(false);
  const [saveError,      setSaveError]      = useState<string | null>(null);
  const [saveSuccess,    setSaveSuccess]    = useState<string | null>(null);

  // Avatar upload state
  const [localPhoto,      setLocalPhoto]      = useState<string | null>(null);
  const [avatarUploading, setAvatarUploading] = useState(false);
  const [avatarError,     setAvatarError]     = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);


  // ── Load extended data from related tables ─────────────────────────────
  async function loadExtData(empId: string) {
    const [
      { data: empRow },
      { data: personalRow },
      { data: contactRow },
      { data: pRows },
      { data: aRows },
      { data: ecRows },
      { data: idRows },
    ] = await Promise.all([
      supabase.from('employees').select('*').eq('id', empId).single(),
      supabase.from('employee_personal').select('*').eq('employee_id', empId).maybeSingle(),
      supabase.from('employee_contact').select('*').eq('employee_id', empId).maybeSingle(),
      supabase.from('passports').select('*').eq('employee_id', empId).limit(1),
      supabase.from('employee_addresses').select('*').eq('employee_id', empId).limit(1),
      supabase.from('emergency_contacts').select('*').eq('employee_id', empId).limit(1),
      supabase.from('identity_records').select('*').eq('employee_id', empId),
    ]);

    const patch: Record<string, unknown> = {};

    if (empRow) {
      patch.designation      = empRow.designation       ?? null;
      patch.deptId           = empRow.dept_id           ?? null;
      patch.managerId        = empRow.manager_id        ?? null;
      patch.hireDate         = empRow.hire_date         ?? null;
      patch.endDate          = empRow.end_date          ?? null;
      // probation_end_date was moved to employee_employment satellite table
      patch.workCountry      = empRow.work_country      ?? null;
      patch.workLocation     = empRow.work_location     ?? null;
      patch.baseCurrencyId   = empRow.base_currency_id  ?? null;
      patch.status           = empRow.status;
      patch.jobTitle         = empRow.job_title         ?? null;
    }

    if (personalRow) {
      patch.nationality    = personalRow.nationality    ?? null;
      patch.maritalStatus  = personalRow.marital_status ?? null;
      patch.photo          = personalRow.photo_url      ?? null;
    }

    if (contactRow) {
      patch.mobile       = contactRow.mobile         ?? null;
      patch.countryCode  = contactRow.country_code   ?? null;
      patch.personalEmail = contactRow.personal_email ?? null;
    }

    const p = pRows?.[0];
    if (p) {
      patch.passportId         = p.id;
      patch.passportCountry    = p.country          || '';
      patch.passportNumber     = p.passport_number  || '';
      patch.passportIssueDate  = p.issue_date       || '';
      patch.passportExpiryDate = p.expiry_date      || '';
    }

    const a = aRows?.[0];
    if (a) {
      patch.addrId       = a.id;
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
      patch.ecId           = ec.id;
      patch.ecName         = ec.name         || '';
      patch.ecRelationship = ec.relationship || '';
      patch.ecPhone        = ec.phone        || '';
      patch.ecAltPhone     = ec.alt_phone    || '';
      patch.ecEmail        = ec.email        || '';
    }

    if (idRows && idRows.length > 0) {
      patch.idRecords = idRows.map((r: Record<string, unknown>) => ({
        country:    r.country     || '',
        idType:     r.id_type     || '',
        recordType: r.record_type || '',
        idNumber:   r.id_number   || '',
        expiry:     r.expiry      || '',
      }));
    }

    setExtData(patch);
  }

  useEffect(() => {
    const empId = authEmployee?.id;
    if (!empId) return;
    loadExtData(empId);
  }, [authEmployee?.id]);

  // Merged employee with fresh DB data
  const emp = authEmployee ? { ...authEmployee, ...extData } : authEmployee;

  // ── Resolve helpers ────────────────────────────────────────────────────
  function resolvePicklist(picklistId: string, id: string | undefined): string {
    if (!id) return '—';
    const found = picklistValues.find(v =>
      v.picklistId === picklistId &&
      (v.id === id || v.refId === id || v.value === id)
    );
    return found ? found.value : id;
  }

  function deptName(deptId: string | undefined): string {
    if (!deptId) return '—';
    const d = departments.find(d => d.id === deptId || d.deptId === deptId);
    return d ? d.name : '—';
  }

  function managerName(managerId: string | undefined): string {
    if (!managerId) return '—';
    const m = employees.find(e => e.id === managerId || e.employeeId === managerId);
    return m ? m.name : '—';
  }

  function picklistOpts(code: string) {
    return picklistValues
      .filter(v => v.picklistId === code)
      .map(v => ({ value: v.id, label: v.value }));
  }

  // Photo: local override (after upload) > extData (post-save) > authEmployee > generated avatar
  const photoSrc = localPhoto
    ?? (extData.photo as string | null)
    ?? emp?.photo
    ?? `https://ui-avatars.com/api/?name=${encodeURIComponent(emp?.name || 'E')}&background=2F77B5&color=fff&size=84`;

  // ── Scrollspy ─────────────────────────────────────────────────────────
  useEffect(() => {
    const scrollBox = scrollRef.current;
    if (!scrollBox) return;
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          setActiveSection(entry.target.id.replace('mps-', ''));
        }
      });
    }, { root: scrollBox, rootMargin: '-10% 0px -55% 0px', threshold: 0 });
    Object.values(sectionRefs.current).forEach(el => { if (el) observer.observe(el); });
    return () => observer.disconnect();
  }, [emp]);

  function scrollTo(sectionId: string) {
    const scrollBox = scrollRef.current;
    const target = sectionRefs.current[sectionId];
    if (!scrollBox || !target) return;
    const nav = scrollBox.querySelector('.mp-sticky-nav') as HTMLElement | null;
    const navH = nav ? nav.offsetHeight : 0;
    const offset = target.getBoundingClientRect().top - scrollBox.getBoundingClientRect().top
      + scrollBox.scrollTop - navH - 8;
    scrollBox.scrollTo({ top: offset, behavior: 'smooth' });
  }

  // ── Edit helpers ───────────────────────────────────────────────────────
  function fd(key: string)            { return (formData[key] ?? '') as string; }
  function setFd(key: string, val: string) {
    setFormData(prev => ({ ...prev, [key]: val }));
  }

  function startEdit(section: string, values: Record<string, string>) {
    setEditingSection(section);
    setFormData(values);
    setSaveError(null);
    setSaveSuccess(null);
  }

  function cancelEdit() {
    setEditingSection(null);
    setFormData({});
    setSaveError(null);
    setSaveSuccess(null);
  }

  function showSuccess(msg: string) {
    setSaveSuccess(msg);
    setTimeout(() => setSaveSuccess(null), 3000);
  }

  // ── Save: Personal ─────────────────────────────────────────────────────
  async function savePersonal() {
    if (!authEmployee?.id) return;
    setSaving(true); setSaveError(null);
    try {
      const nat = fd('nationality');
      const ms  = fd('maritalStatus');

      const { error } = await supabase
        .from('employee_personal')
        .upsert({
          employee_id:    authEmployee.id,
          nationality:    nat || null,
          marital_status: ms  || null,
        }, { onConflict: 'employee_id' });
      if (error) throw error;

      // Mirror into extData immediately so `emp` reflects the change without
      // waiting for AuthContext to re-fetch (which is non-blocking anyway).
      setExtData(prev => ({ ...prev, nationality: nat, maritalStatus: ms }));
      refetchProfile(); // sync AuthContext in the background
      cancelEdit();
      showSuccess('Personal details saved.');
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  // ── Save: Contact ──────────────────────────────────────────────────────
  async function saveContact() {
    if (!authEmployee?.id) return;
    setSaving(true); setSaveError(null);
    try {
      const cc  = fd('countryCode');
      const mob = fd('mobile');
      const pe  = fd('personalEmail');

      const { error } = await supabase
        .from('employee_contact')
        .upsert({
          employee_id:    authEmployee.id,
          country_code:   cc  || null,
          mobile:         mob || null,
          personal_email: pe  || null,
        }, { onConflict: 'employee_id' });
      if (error) throw error;

      // Mirror into extData so emp reflects the change immediately
      setExtData(prev => ({ ...prev, countryCode: cc, mobile: mob, personalEmail: pe }));
      refetchProfile();
      cancelEdit();
      showSuccess('Contact details saved.');
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  // ── Save: Address ──────────────────────────────────────────────────────
  async function saveAddress() {
    if (!authEmployee?.id) return;
    setSaving(true); setSaveError(null);
    try {
      const payload = {
        employee_id: authEmployee.id,
        line1:    fd('addrLine1')    || null,
        line2:    fd('addrLine2')    || null,
        landmark: fd('addrLandmark') || null,
        city:     fd('addrCity')     || null,
        district: fd('addrDistrict') || null,
        state:    fd('addrState')    || null,
        pin:      fd('addrPin')      || null,
        country:  fd('addrCountry')  || null,
      };

      let error;
      if (extData.addrId) {
        ({ error } = await supabase.from('employee_addresses').update(payload).eq('id', extData.addrId as string));
      } else {
        const res = await supabase.from('employee_addresses').insert(payload).select('id').single();
        error = res.error;
        if (res.data) setExtData(prev => ({ ...prev, addrId: res.data!.id }));
      }
      if (error) throw error;

      setExtData(prev => ({
        ...prev,
        addrLine1:    fd('addrLine1'),
        addrLine2:    fd('addrLine2'),
        addrLandmark: fd('addrLandmark'),
        addrCity:     fd('addrCity'),
        addrDistrict: fd('addrDistrict'),
        addrState:    fd('addrState'),
        addrPin:      fd('addrPin'),
        addrCountry:  fd('addrCountry'),
      }));
      cancelEdit();
      showSuccess('Address saved.');
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  // ── Save: Passport ─────────────────────────────────────────────────────
  async function savePassport() {
    if (!authEmployee?.id) return;
    setSaving(true); setSaveError(null);
    try {
      const payload = {
        employee_id:     authEmployee.id,
        country:         fd('passportCountry')    || null,
        passport_number: fd('passportNumber')     || null,
        issue_date:      fd('passportIssueDate')  || null,
        expiry_date:     fd('passportExpiryDate') || null,
      };

      let error;
      if (extData.passportId) {
        ({ error } = await supabase.from('passports').update(payload).eq('id', extData.passportId as string));
      } else {
        const res = await supabase.from('passports').insert(payload).select('id').single();
        error = res.error;
        if (res.data) setExtData(prev => ({ ...prev, passportId: res.data!.id }));
      }
      if (error) throw error;

      setExtData(prev => ({
        ...prev,
        passportCountry:    fd('passportCountry'),
        passportNumber:     fd('passportNumber'),
        passportIssueDate:  fd('passportIssueDate'),
        passportExpiryDate: fd('passportExpiryDate'),
      }));
      cancelEdit();
      showSuccess('Passport details saved.');
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  // ── Save: Emergency Contact ────────────────────────────────────────────
  async function saveEmergency() {
    if (!authEmployee?.id) return;
    setSaving(true); setSaveError(null);
    try {
      const payload = {
        employee_id:  authEmployee.id,
        name:         fd('ecName')         || null,
        relationship: fd('ecRelationship') || null,
        phone:        fd('ecPhone')        || null,
        alt_phone:    fd('ecAltPhone')     || null,
        email:        fd('ecEmail')        || null,
      };

      let error;
      if (extData.ecId) {
        ({ error } = await supabase.from('emergency_contacts').update(payload as any).eq('id', extData.ecId as string));
      } else {
        const res = await supabase.from('emergency_contacts').insert(payload as any).select('id').single();
        error = res.error;
        if (res.data) setExtData(prev => ({ ...prev, ecId: res.data!.id }));
      }
      if (error) throw error;

      setExtData(prev => ({
        ...prev,
        ecName:         fd('ecName'),
        ecRelationship: fd('ecRelationship'),
        ecPhone:        fd('ecPhone'),
        ecAltPhone:     fd('ecAltPhone'),
        ecEmail:        fd('ecEmail'),
      }));
      cancelEdit();
      showSuccess('Emergency contact saved.');
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  // ── Avatar upload ──────────────────────────────────────────────────────
  async function handleAvatarUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file || !authEmployee?.id) return;

    const MAX_MB = 5;
    if (file.size > MAX_MB * 1024 * 1024) {
      setAvatarError(`Image must be under ${MAX_MB} MB.`);
      return;
    }
    if (!file.type.startsWith('image/')) {
      setAvatarError('Please select an image file.');
      return;
    }

    setAvatarUploading(true);
    setAvatarError(null);

    try {
      const ext  = file.name.split('.').pop() ?? 'jpg';
      const path = `employees/${authEmployee.id}/avatar.${ext}`;

      const { error: upErr } = await supabase.storage
        .from('avatars')
        .upload(path, file, { contentType: file.type, upsert: true });
      if (upErr) throw upErr;

      const { data: urlData } = supabase.storage.from('avatars').getPublicUrl(path);
      const publicUrl = urlData.publicUrl + `?t=${Date.now()}`; // bust cache

      // Store in employee_personal
      const { error: dbErr } = await supabase
        .from('employee_personal')
        .upsert({ employee_id: authEmployee.id, photo_url: publicUrl }, { onConflict: 'employee_id' });
      if (dbErr) throw dbErr;

      setLocalPhoto(publicUrl);
      setExtData(prev => ({ ...prev, photo: publicUrl }));
      refetchProfile(); // update sidebar + top-right avatar
    } catch (err: unknown) {
      setAvatarError(err instanceof Error ? err.message : 'Upload failed.');
    } finally {
      setAvatarUploading(false);
      // Reset input so re-uploading the same file still triggers onChange
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  }

  // ── Loading / error states ─────────────────────────────────────────────
  if (profileLoading) {
    return (
      <div className="auth-loading">
        <i className="fa-solid fa-spinner fa-spin" />
        <span>Loading profile…</span>
      </div>
    );
  }

  if (!emp) {
    return (
      <div className="mp-not-found">
        <i className="fa-solid fa-id-badge" />
        <h3>Profile not linked</h3>
        <p>Your portal account could not be loaded. This is usually a temporary issue.</p>
        <div style={{ display: 'flex', gap: 12, marginTop: 8, justifyContent: 'center' }}>
          <button
            onClick={refetchProfile}
            style={{
              padding: '8px 20px', borderRadius: 6, border: '1px solid #D1D5DB',
              background: '#F9FAFB', cursor: 'pointer', fontSize: 13,
              display: 'flex', alignItems: 'center', gap: 6, color: '#374151',
            }}
          >
            {profileLoading
              ? <><i className="fa-solid fa-spinner fa-spin" /> Loading…</>
              : <><i className="fa-solid fa-rotate-right" /> Try again</>}
          </button>
        </div>
        <p style={{ fontSize: 12, color: '#9CA3AF', marginTop: 16 }}>
          If the problem persists, contact your administrator.
        </p>
      </div>
    );
  }

  // ── Passport expiry alert ──────────────────────────────────────────────
  function passportAlert() {
    const expiry = emp!.passportExpiryDate;
    if (!expiry || expiry === '9999-12-31') return null;
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const exp = new Date((expiry as string) + 'T00:00:00');
    const diffDays = Math.ceil((exp.getTime() - today.getTime()) / 86400000);
    if (diffDays < 0)
      return <div className="ev-passport-alert expired"><i className="fa-solid fa-triangle-exclamation" /> Passport expired {Math.abs(diffDays)} day(s) ago.</div>;
    if (diffDays <= 90) {
      const cls = diffDays <= 30 ? 'critical' : 'warning';
      return <div className={`ev-passport-alert ${cls}`}><i className="fa-solid fa-triangle-exclamation" /> Passport expires in {diffDays} day(s).</div>;
    }
    return null;
  }

  const SECTIONS = [
    { id: 'personal',       label: 'Personal',         icon: 'fa-circle-user'  },
    { id: 'contact',        label: 'Contact',           icon: 'fa-phone'        },
    { id: 'employment',     label: 'Employment',        icon: 'fa-briefcase'    },
    { id: 'address',        label: 'Address',           icon: 'fa-location-dot' },
    { id: 'passport',       label: 'Passport',          icon: 'fa-passport'     },
    { id: 'identification', label: 'Identification',    icon: 'fa-id-card-clip' },
    { id: 'emergency',      label: 'Emergency Contact', icon: 'fa-phone-volume' },
  ];

  const today = new Date(); today.setHours(0, 0, 0, 0);
  const endDate = emp.endDate ? new Date((emp.endDate as string) + 'T00:00:00') : null;
  const isActive = !endDate || emp.endDate === '9999-12-31' || endDate >= today;

  const identifications: Record<string, unknown>[] = (emp.idRecords as Record<string, unknown>[] | undefined) || [];

  // ── Section header with optional Edit button ──────────────────────────
  function SectionHeader({
    icon, text, section, permission, editValues,
  }: {
    icon: string; text: string; section: string;
    permission?: string; editValues?: Record<string, string>;
  }) {
    const canEdit = permission ? can(permission) : false;
    const isEditing = editingSection === section;
    return (
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
        <SectionTitle icon={icon} text={text} />
        {canEdit && !isEditing && !editingSection && editValues && (
          <EditButton onClick={() => startEdit(section, editValues)} />
        )}
      </div>
    );
  }

  // ── JSX ───────────────────────────────────────────────────────────────
  return (
    <div style={{ padding: '0 0 24px' }}>
      <h2 className="page-title">My Profile</h2>

      {/* Global success toast */}
      {saveSuccess && (
        <div style={{
          position: 'fixed', bottom: 24, right: 24, zIndex: 9999,
          background: '#D1FAE5', color: '#065F46', border: '1px solid #6EE7B7',
          borderRadius: 8, padding: '10px 18px', fontSize: 13, fontWeight: 600,
          display: 'flex', alignItems: 'center', gap: 8,
          boxShadow: '0 4px 12px rgba(0,0,0,0.1)',
        }}>
          <i className="fa-solid fa-circle-check" /> {saveSuccess}
        </div>
      )}

      {/* ── Profile Header ─────────────────────────────────────────────── */}
      <div className="mp-header">
        {/* Avatar with upload overlay + badge */}
        <div className="mp-avatar-wrap">
          <div className="mp-header-photo">
            <img src={photoSrc} alt={emp.name} />

            {/* Hidden file input */}
            <input
              ref={fileInputRef}
              type="file"
              accept="image/*"
              style={{ display: 'none' }}
              onChange={handleAvatarUpload}
            />

            {/* Hover overlay — darkens the avatar on hover */}
            {can('employee.edit_own_personal') && (
              <button
                onClick={() => { setAvatarError(null); fileInputRef.current?.click(); }}
                disabled={avatarUploading}
                title="Change photo"
                className={`mp-avatar-overlay${avatarUploading ? ' mp-avatar-uploading' : ''}`}
                style={{
                  position: 'absolute', inset: 0,
                  borderRadius: '50%',
                  background: 'rgba(0,0,0,0.45)',
                  border: 'none', cursor: avatarUploading ? 'wait' : 'pointer',
                  display: 'flex', flexDirection: 'column',
                  alignItems: 'center', justifyContent: 'center',
                  color: '#fff', fontSize: 11, fontWeight: 600, gap: 4,
                }}
              >
                {avatarUploading
                  ? <><i className="fa-solid fa-spinner fa-spin" style={{ fontSize: 18 }} /><span>Uploading…</span></>
                  : <><i className="fa-solid fa-camera" style={{ fontSize: 18 }} /><span>Change</span></>}
              </button>
            )}
          </div>

          {/* Camera badge — always visible when user can edit; hides during upload */}
          {can('employee.edit_own_personal') && !avatarUploading && (
            <button
              onClick={() => { setAvatarError(null); fileInputRef.current?.click(); }}
              className="mp-avatar-badge"
              title="Change photo"
            >
              <i className="fa-solid fa-camera" />
            </button>
          )}

          {/* Spinner badge during upload */}
          {avatarUploading && (
            <div className="mp-avatar-badge" style={{ cursor: 'wait', borderColor: '#93C5FD' }}>
              <i className="fa-solid fa-spinner fa-spin" style={{ color: '#3B82F6' }} />
            </div>
          )}
        </div>

        <div className="mp-header-info">
          <div className="mp-header-name">{emp.name}</div>
          <div style={{ color: 'rgba(255,255,255,0.7)', fontSize: 13, marginBottom: 8 }}>
            {resolvePicklist('DESIGNATION', emp.designation as string | undefined)}
          </div>
          <div className="mp-header-meta">
            {!!(emp.businessEmail || emp.email) && (
              <span><i className="fa-solid fa-envelope" />{String(emp.businessEmail || emp.email)}</span>
            )}
            {emp.mobile && (
              <span><i className="fa-solid fa-phone" />{emp.mobile as string}</span>
            )}
          </div>
          {/* Avatar upload error */}
          {avatarError && (
            <div style={{ marginTop: 6, fontSize: 12, color: '#FECACA', display: 'flex', alignItems: 'center', gap: 4 }}>
              <i className="fa-solid fa-circle-exclamation" /> {avatarError}
            </div>
          )}
        </div>
      </div>

      {/* ── Scroll container with sticky nav ───────────────────────────── */}
      <div className="mp-scroll-container" ref={scrollRef}>
        <div className="mp-page">

          {/* Sticky nav */}
          <nav className="mp-sticky-nav">
            {SECTIONS.map(s => (
              <button
                key={s.id}
                className={`mp-nav-btn${activeSection === s.id ? ' mp-nav-active' : ''}`}
                onClick={() => scrollTo(s.id)}
              >
                <i className={`fa-solid ${s.icon}`} />{s.label}
              </button>
            ))}
          </nav>

          {/* ── Sections ─────────────────────────────────────────────── */}
          <div className="mp-sections">

            {/* ── Personal ─────────────────────────────────────────── */}
            <section id="mps-personal" ref={el => { sectionRefs.current.personal = el; }} className="mp-section">
              <WorkflowGateBanner moduleCode="profile_personal" active={activeGates.has('profile_personal')} pendingCount={pendingCounts['profile_personal'] ?? 0} actionLabel="personal info changes" />
              <SectionHeader
                icon="fa-circle-user" text="Personal Information"
                section="personal"
                permission="employee.edit_own_personal"
                editValues={{
                  nationality:   (emp.nationality   as string) || '',
                  maritalStatus: (emp.maritalStatus as string) || '',
                }}
              />

              {editingSection === 'personal' ? (
                <>
                  <div className="ev-field-grid ev-grid-2">
                    <Field label="Full Name"   value={emp.name as string} />
                    <Field label="Employee ID" value={emp.employeeId as string} />
                    <FormSelect
                      label="Nationality"
                      value={fd('nationality')}
                      onChange={v => setFd('nationality', v)}
                      options={COUNTRIES.map(c => ({ value: c, label: c }))}
                    />
                    <FormSelect
                      label="Marital Status"
                      value={fd('maritalStatus')}
                      onChange={v => setFd('maritalStatus', v)}
                      options={picklistOpts('MARITAL_STATUS')}
                    />
                  </div>
                  <SaveCancelRow onSave={savePersonal} onCancel={cancelEdit} saving={saving} error={saveError} />
                </>
              ) : (
                <div className="ev-field-grid ev-grid-2">
                  <Field label="Full Name"      value={emp.name as string} />
                  <Field label="Employee ID"    value={emp.employeeId as string} />
                  <Field label="Nationality"    value={resolvePicklist('NATIONALITY', emp.nationality as string | undefined)} />
                  <Field label="Marital Status" value={resolvePicklist('MARITAL_STATUS', emp.maritalStatus as string | undefined)} />
                </div>
              )}
            </section>

            {/* ── Contact ──────────────────────────────────────────── */}
            <section id="mps-contact" ref={el => { sectionRefs.current.contact = el; }} className="mp-section">
              <WorkflowGateBanner moduleCode="profile_contact" active={activeGates.has('profile_contact')} pendingCount={pendingCounts['profile_contact'] ?? 0} actionLabel="contact info changes" />
              <SectionHeader
                icon="fa-phone" text="Contact Information"
                section="contact"
                permission="employee.edit_own_contact"
                editValues={{
                  countryCode:   (emp.countryCode   as string) || '+91',
                  mobile:        (emp.mobile        as string) || '',
                  personalEmail: (emp.personalEmail as string) || '',
                }}
              />

              {editingSection === 'contact' ? (
                <>
                  <div className="ev-field-grid ev-grid-2">
                    <div className="ev-field">
                      <div className="ev-field-label">Mobile No.</div>
                      <div style={{ display: 'flex', gap: 8 }}>
                        <select
                          value={fd('countryCode')}
                          onChange={e => setFd('countryCode', e.target.value)}
                          style={{ ...inputStyle, width: 120, flexShrink: 0 }}
                        >
                          {PHONE_CODES.map(p => (
                            <option key={p.code} value={p.code}>
                              {p.flag} {p.code}
                            </option>
                          ))}
                        </select>
                        <input
                          type="tel"
                          value={fd('mobile')}
                          onChange={e => setFd('mobile', e.target.value)}
                          placeholder="e.g. 9876543210"
                          style={{ ...inputStyle, flex: 1 }}
                        />
                      </div>
                    </div>
                    <Field label="Business Email" value={emp.businessEmail as string} />
                    <FormInput
                      label="Personal Email"
                      value={fd('personalEmail')}
                      onChange={v => setFd('personalEmail', v)}
                      type="email"
                      placeholder="e.g. personal@example.com"
                    />
                  </div>
                  <SaveCancelRow onSave={saveContact} onCancel={cancelEdit} saving={saving} error={saveError} />
                </>
              ) : (
                <div className="ev-field-grid ev-grid-2">
                  <MobileField countryCode={emp.countryCode as string | undefined} mobile={emp.mobile as string | undefined} />
                  <Field label="Business Email" value={emp.businessEmail as string | undefined} />
                  <Field label="Personal Email" value={emp.personalEmail as string | undefined} />
                </div>
              )}
            </section>

            {/* ── Employment (read-only) ───────────────────────────── */}
            <section id="mps-employment" ref={el => { sectionRefs.current.employment = el; }} className="mp-section">
              <WorkflowGateBanner moduleCode="profile_employment" active={activeGates.has('profile_employment')} pendingCount={pendingCounts['profile_employment'] ?? 0} actionLabel="employment detail changes" />
              <SectionTitle icon="fa-briefcase" text="Employment Information" />
              <div className="ev-field-grid ev-grid-2">
                <div className="ev-field">
                  <div className="ev-field-label">Status</div>
                  {isActive
                    ? <span className="ev-badge ev-badge-active"><i className="fa-solid fa-circle-dot" /> Active</span>
                    : <span className="ev-badge ev-badge-inactive"><i className="fa-solid fa-circle-dot" /> Inactive</span>}
                </div>
                <div className="ev-field">
                  <div className="ev-field-label">Role</div>
                  {roles.includes('admin')
                    ? <span className="ev-badge" style={{ background: '#f3e5f5', color: '#7b1fa2' }}>Admin</span>
                    : roles.includes('manager')
                    ? <span className="ev-badge" style={{ background: '#e3f2fd', color: '#1565c0' }}>Manager</span>
                    : <span className="ev-badge" style={{ background: '#f0f4fa', color: '#546e7a' }}>Employee</span>}
                </div>
                <Field label="Designation"     value={resolvePicklist('DESIGNATION', emp.designation as string | undefined)} />
                <Field label="Department"      value={deptName(emp.deptId as string | undefined)} />
                <Field label="Manager"         value={managerName(emp.managerId as string | undefined)} />
                <Field label="Hire Date"       value={fmtDate(emp.hireDate as string | undefined)} />
                <Field label="Country of Work" value={resolvePicklist('ID_COUNTRY', emp.workCountry as string | undefined)} />
                <Field label="Location"        value={resolvePicklist('LOCATION', emp.workLocation as string | undefined)} />
                <Field label="Base Currency"   value={currencies.find(c => c.id === emp.baseCurrencyId)?.name} />
              </div>
            </section>

            {/* ── Address ──────────────────────────────────────────── */}
            <section id="mps-address" ref={el => { sectionRefs.current.address = el; }} className="mp-section">
              <WorkflowGateBanner moduleCode="profile_address" active={activeGates.has('profile_address')} pendingCount={pendingCounts['profile_address'] ?? 0} actionLabel="address changes" />
              <SectionHeader
                icon="fa-location-dot" text="Address Information"
                section="address"
                permission="employee.edit_own_address"
                editValues={{
                  addrLine1:    (emp.addrLine1    as string) || '',
                  addrLine2:    (emp.addrLine2    as string) || '',
                  addrLandmark: (emp.addrLandmark as string) || '',
                  addrCity:     (emp.addrCity     as string) || '',
                  addrDistrict: (emp.addrDistrict as string) || '',
                  addrState:    (emp.addrState    as string) || '',
                  addrPin:      (emp.addrPin      as string) || '',
                  addrCountry:  (emp.addrCountry  as string) || '',
                }}
              />

              {editingSection === 'address' ? (
                <>
                  <div className="ev-field-grid ev-grid-2">
                    <FormInput label="Address Line 1" value={fd('addrLine1')}    onChange={v => setFd('addrLine1', v)}    placeholder="Street / building name" />
                    <FormInput label="Address Line 2" value={fd('addrLine2')}    onChange={v => setFd('addrLine2', v)}    placeholder="Apartment / suite / floor" />
                    <FormInput label="Landmark"       value={fd('addrLandmark')} onChange={v => setFd('addrLandmark', v)} placeholder="Nearby landmark" />
                    <FormInput label="City"           value={fd('addrCity')}     onChange={v => setFd('addrCity', v)}     placeholder="e.g. Chennai" />
                    <FormInput label="District"       value={fd('addrDistrict')} onChange={v => setFd('addrDistrict', v)} placeholder="e.g. Chennai District" />
                    <FormInput label="State"          value={fd('addrState')}    onChange={v => setFd('addrState', v)}    placeholder="e.g. Tamil Nadu" />
                    <FormInput label="PIN / ZIP Code" value={fd('addrPin')}      onChange={v => setFd('addrPin', v)}      placeholder="e.g. 600001" />
                    <FormSelect
                      label="Country"
                      value={fd('addrCountry')}
                      onChange={v => setFd('addrCountry', v)}
                      options={COUNTRIES.map(c => ({ value: c, label: c }))}
                      placeholder="— Select Country —"
                    />
                  </div>
                  <SaveCancelRow onSave={saveAddress} onCancel={cancelEdit} saving={saving} error={saveError} />
                </>
              ) : (
                <div className="ev-field-grid ev-grid-2">
                  <Field label="Address Line 1" value={emp.addrLine1    as string | undefined} />
                  <Field label="Address Line 2" value={emp.addrLine2    as string | undefined} />
                  <Field label="Landmark"       value={emp.addrLandmark as string | undefined} />
                  <Field label="City"           value={emp.addrCity     as string | undefined} />
                  <Field label="District"       value={emp.addrDistrict as string | undefined} />
                  <Field label="State"          value={emp.addrState    as string | undefined} />
                  <Field label="PIN / ZIP Code" value={emp.addrPin      as string | undefined} />
                  <Field label="Country"        value={emp.addrCountry  as string | undefined} />
                </div>
              )}
            </section>

            {/* ── Passport ─────────────────────────────────────────── */}
            <section id="mps-passport" ref={el => { sectionRefs.current.passport = el; }} className="mp-section">
              <WorkflowGateBanner moduleCode="profile_passport" active={activeGates.has('profile_passport')} pendingCount={pendingCounts['profile_passport'] ?? 0} actionLabel="passport detail changes" />
              <SectionHeader
                icon="fa-passport" text="Passport Information"
                section="passport"
                permission="employee.edit_own_passport"
                editValues={{
                  passportCountry:    (emp.passportCountry    as string) || '',
                  passportNumber:     (emp.passportNumber     as string) || '',
                  passportIssueDate:  (emp.passportIssueDate  as string) || '',
                  passportExpiryDate: (emp.passportExpiryDate as string) || '',
                }}
              />

              {editingSection === 'passport' ? (
                <>
                  <div className="ev-field-grid ev-grid-2">
                    <FormSelect
                      label="Issue Country"
                      value={fd('passportCountry')}
                      onChange={v => setFd('passportCountry', v)}
                      options={picklistOpts('ID_COUNTRY')}
                      placeholder="— Select Country —"
                    />
                    <FormInput
                      label="Passport No."
                      value={fd('passportNumber')}
                      onChange={v => setFd('passportNumber', v)}
                      placeholder="e.g. A1234567"
                    />
                    <FormInput
                      label="Issue Date"
                      value={fd('passportIssueDate')}
                      onChange={v => setFd('passportIssueDate', v)}
                      type="date"
                    />
                    <FormInput
                      label="Expiry Date"
                      value={fd('passportExpiryDate')}
                      onChange={v => setFd('passportExpiryDate', v)}
                      type="date"
                    />
                  </div>
                  <SaveCancelRow onSave={savePassport} onCancel={cancelEdit} saving={saving} error={saveError} />
                </>
              ) : (
                !emp.passportNumber && !emp.passportCountry ? (
                  <div className="ev-empty-state">
                    <i className="fa-solid fa-passport" />
                    <p>No passport details on file.</p>
                    {can('employee.edit_own_passport') && !editingSection && (
                      <button
                        onClick={() => startEdit('passport', { passportCountry: '', passportNumber: '', passportIssueDate: '', passportExpiryDate: '' })}
                        style={{ marginTop: 8, padding: '6px 14px', borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', cursor: 'pointer', fontSize: 13, color: '#374151' }}
                      >
                        <i className="fa-solid fa-plus" style={{ marginRight: 5 }} /> Add Passport
                      </button>
                    )}
                  </div>
                ) : (
                  <>
                    {passportAlert()}
                    <div className="ev-field-grid ev-grid-2">
                      <Field label="Issue Country" value={resolvePicklist('ID_COUNTRY', emp.passportCountry as string | undefined)} />
                      <Field label="Passport No."  value={emp.passportNumber     as string | undefined} />
                      <Field label="Issue Date"    value={fmtDate(emp.passportIssueDate  as string | undefined)} />
                      <Field label="Expiry Date"   value={fmtDate(emp.passportExpiryDate as string | undefined)} />
                    </div>
                  </>
                )
              )}
            </section>

            {/* ── Identification (read-only) ───────────────────────── */}
            <section id="mps-identification" ref={el => { sectionRefs.current.identification = el; }} className="mp-section">
              <WorkflowGateBanner moduleCode="profile_identification" active={activeGates.has('profile_identification')} pendingCount={pendingCounts['profile_identification'] ?? 0} actionLabel="identification changes" />
              <SectionTitle icon="fa-id-card-clip" text="Identification Details" />
              {identifications.length === 0 ? (
                <div className="ev-empty-state">
                  <i className="fa-solid fa-id-card-clip" />
                  <p>No identification records on file.</p>
                </div>
              ) : (
                <table className="ev-id-table">
                  <thead>
                    <tr><th>Country</th><th>ID Type</th><th>ID Number</th><th>Expiry</th><th>Status</th></tr>
                  </thead>
                  <tbody>
                    {identifications.map((rec, i) => {
                      const country = resolvePicklist('ID_COUNTRY', rec.country as string | undefined);
                      const idType  = resolvePicklist('ID_TYPE', rec.idType as string | undefined);
                      return (
                        <tr key={i}>
                          <td>{country}</td>
                          <td>{idType}</td>
                          <td className="ev-mono">{(rec.idNumber as string) || '—'}</td>
                          <td>{rec.expiry ? fmtDate(rec.expiry as string) : '—'}</td>
                          <td>
                            {rec.recordType === 'primary'
                              ? <span className="ev-badge ev-badge-primary">⭐ Primary</span>
                              : <span style={{ color: '#8a9ab0', fontSize: 12 }}>Secondary</span>}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              )}
            </section>

            {/* ── Emergency Contact ────────────────────────────────── */}
            <section id="mps-emergency" ref={el => { sectionRefs.current.emergency = el; }} className="mp-section">
              <WorkflowGateBanner moduleCode="profile_emergency_contact" active={activeGates.has('profile_emergency_contact')} pendingCount={pendingCounts['profile_emergency_contact'] ?? 0} actionLabel="emergency contact changes" />
              <SectionHeader
                icon="fa-phone-volume" text="Emergency Contact Information"
                section="emergency"
                permission="employee.edit_own_emergency"
                editValues={{
                  ecName:         (emp.ecName         as string) || '',
                  ecRelationship: (emp.ecRelationship as string) || '',
                  ecPhone:        (emp.ecPhone        as string) || '',
                  ecAltPhone:     (emp.ecAltPhone     as string) || '',
                  ecEmail:        (emp.ecEmail        as string) || '',
                }}
              />

              {editingSection === 'emergency' ? (
                <>
                  <div className="ev-field-grid ev-grid-2">
                    <FormInput label="Contact Name"    value={fd('ecName')}     onChange={v => setFd('ecName', v)}     placeholder="e.g. Jane Doe" />
                    <FormSelect
                      label="Relationship"
                      value={fd('ecRelationship')}
                      onChange={v => setFd('ecRelationship', v)}
                      options={picklistOpts('RELATIONSHIP_TYPE')}
                    />
                    <FormInput label="Phone Number"    value={fd('ecPhone')}    onChange={v => setFd('ecPhone', v)}    type="tel" placeholder="+91 98765 43210" />
                    <FormInput label="Alternate Phone" value={fd('ecAltPhone')} onChange={v => setFd('ecAltPhone', v)} type="tel" placeholder="Optional" />
                    <FormInput label="Email"           value={fd('ecEmail')}    onChange={v => setFd('ecEmail', v)}    type="email" placeholder="e.g. contact@example.com" />
                  </div>
                  <SaveCancelRow onSave={saveEmergency} onCancel={cancelEdit} saving={saving} error={saveError} />
                </>
              ) : (
                !emp.ecName && !emp.ecPhone ? (
                  <div className="ev-empty-state">
                    <i className="fa-solid fa-phone-volume" />
                    <p>No emergency contact on record.</p>
                    {can('employee.edit_own_emergency') && !editingSection && (
                      <button
                        onClick={() => startEdit('emergency', { ecName: '', ecRelationship: '', ecPhone: '', ecAltPhone: '', ecEmail: '' })}
                        style={{ marginTop: 8, padding: '6px 14px', borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', cursor: 'pointer', fontSize: 13, color: '#374151' }}
                      >
                        <i className="fa-solid fa-plus" style={{ marginRight: 5 }} /> Add Emergency Contact
                      </button>
                    )}
                  </div>
                ) : (
                  <div className="ev-field-grid ev-grid-2">
                    <Field label="Contact Name"    value={emp.ecName         as string | undefined} />
                    <Field label="Relationship"    value={resolvePicklist('RELATIONSHIP_TYPE', emp.ecRelationship as string | undefined)} />
                    <Field label="Phone Number"    value={emp.ecPhone        as string | undefined} />
                    <Field label="Alternate Phone" value={emp.ecAltPhone     as string | undefined} />
                    <Field label="Email"           value={emp.ecEmail        as string | undefined} />
                  </div>
                )
              )}
            </section>

          </div>{/* /.mp-sections */}
        </div>{/* /.mp-page */}
      </div>{/* /.mp-scroll-container */}

      {/* Avatar hover style (can't do :hover in inline styles) */}
      <style>{`
        .mp-avatar-overlay { opacity: 0 !important; }
        .mp-header-photo:hover .mp-avatar-overlay { opacity: 1 !important; }
      `}</style>
    </div>
  );
}
