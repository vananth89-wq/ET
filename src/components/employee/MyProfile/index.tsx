import { useRef, useEffect, useState, useCallback } from 'react';
import { useEmployeeSearch } from '../../../hooks/useEmployeeSearch';
import { phoneFlag } from '../../../constants/phoneCodes';
import { validateMobile, mobilePlaceholder, mobileHint } from '../../../utils/validateMobile';
import { validatePassportNumber, validatePassportValidity, passportNumberPlaceholder, passportNumberHint, passportValidityHint } from '../../../utils/validatePassport';
import { useAuth } from '../../../contexts/AuthContext';
import { usePermissions } from '../../../hooks/usePermissions';
import { useProfileContext } from '../../../contexts/ProfileContext';
import { usePermissionsForEmployee } from '../../../hooks/usePermissionsForEmployee';
import { usePicklistValues } from '../../../hooks/usePicklistValues';
import { useDepartments } from '../../../hooks/useDepartments';
import { useEmployees } from '../../../hooks/useEmployees';
import { useCurrencies } from '../../../hooks/useCurrencies';
import { supabase } from '../../../lib/supabase';
import { COUNTRIES } from '../../admin/AddEmployee';
import { useProfileWorkflowGates } from '../../../workflow/hooks/useProfileWorkflowGates';
import WorkflowSubmitModal          from '../../../workflow/components/WorkflowSubmitModal';
import WorkflowParticipantsModal    from '../../../workflow/components/WorkflowParticipantsModal';
import ConfirmationModal            from '../../shared/ConfirmationModal';
import BankAccountsPortlet          from '../../shared/BankAccountsPortlet';
import DependentsPortlet            from '../../shared/DependentsPortlet';
import JobRelationshipsPortlet      from '../../shared/JobRelationshipsPortlet';
import EducationPortlet             from '../../shared/EducationPortlet';
import TerminationPortlet           from '../../shared/TerminationPortlet';

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

// ── Manager typeahead ──────────────────────────────────────────────────────────
// A self-contained search input for picking a manager.
// Props:
//   value       — the currently selected employee UUID (stored in form state)
//   displayName — the human-readable name to show initially / when selected
//   onChange    — called with (uuid, displayName) on selection, or ('', '') to clear
//   excludeId   — employee UUID to exclude from results (the employee being edited)

interface ManagerSearchInputProps {
  value:       string;
  displayName: string;
  onChange:    (id: string, name: string) => void;
  excludeId?:  string;
}

function ManagerSearchInput({ value, displayName, onChange, excludeId }: ManagerSearchInputProps) {
  const [query,   setQuery]   = useState(displayName);
  const [open,    setOpen]    = useState(false);
  const [focused, setFocused] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);

  // Keep displayed text in sync when parent form resets
  useEffect(() => { setQuery(displayName); }, [displayName]);

  const { results, loading } = useEmployeeSearch(focused ? query : '');

  const filtered = results.filter(r => r.employee_id !== excludeId);

  // Close on outside click
  useEffect(() => {
    function handler(e: MouseEvent) {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        setOpen(false);
        // If user blurred without picking, restore previous name
        if (!value) setQuery('');
        else setQuery(displayName);
      }
    }
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [value, displayName]);

  function handleSelect(r: { employee_id: string; full_name: string; employee_code: string }) {
    onChange(r.employee_id, r.full_name);
    setQuery(r.full_name);
    setOpen(false);
  }

  function handleClear(e: React.MouseEvent) {
    e.stopPropagation();
    onChange('', '');
    setQuery('');
    setOpen(false);
  }

  const inputStyle: React.CSSProperties = {
    width: '100%', padding: '8px 32px 8px 10px', fontSize: 13,
    border: '1px solid #D1D5DB', borderRadius: 6, outline: 'none',
    background: '#fff', boxSizing: 'border-box',
  };

  return (
    <div className="ev-field">
      <div className="ev-field-label">Reports To (Manager)</div>
      <div ref={wrapRef} style={{ position: 'relative' }}>
        <input
          type="text"
          value={query}
          placeholder="Search by name…"
          style={inputStyle}
          onFocus={() => { setFocused(true); setOpen(true); }}
          onChange={e => { setQuery(e.target.value); setOpen(true); }}
        />
        {/* Clear button when a manager is selected */}
        {value && (
          <button
            onMouseDown={handleClear}
            style={{ position: 'absolute', right: 8, top: '50%', transform: 'translateY(-50%)', background: 'none', border: 'none', cursor: 'pointer', color: '#9CA3AF', fontSize: 14, padding: 0, lineHeight: 1 }}
            title="Clear manager"
          >✕</button>
        )}
        {/* Spinner */}
        {loading && !value && (
          <i className="fa-solid fa-spinner fa-spin" style={{ position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)', color: '#9CA3AF', fontSize: 12 }} />
        )}

        {/* Dropdown */}
        {open && query.trim().length >= 2 && (
          <div style={{
            position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 999,
            background: '#fff', border: '1px solid #E5E7EB', borderRadius: 6,
            boxShadow: '0 4px 16px rgba(0,0,0,0.10)', marginTop: 2,
            maxHeight: 240, overflowY: 'auto',
          }}>
            {loading ? (
              <div style={{ padding: '10px 12px', fontSize: 13, color: '#9CA3AF' }}>
                <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Searching…
              </div>
            ) : filtered.length === 0 ? (
              <div style={{ padding: '10px 12px', fontSize: 13, color: '#9CA3AF' }}>No employees found.</div>
            ) : filtered.map(r => (
              <div
                key={r.employee_id}
                onMouseDown={() => handleSelect(r)}
                style={{ padding: '9px 12px', cursor: 'pointer', fontSize: 13, display: 'flex', alignItems: 'center', gap: 10, borderBottom: '1px solid #F3F4F6' }}
                onMouseEnter={e => (e.currentTarget.style.background = '#F5F3FF')}
                onMouseLeave={e => (e.currentTarget.style.background = '')}
              >
                {/* Avatar circle */}
                <div style={{
                  width: 28, height: 28, borderRadius: '50%', flexShrink: 0,
                  background: '#6366F1', color: '#fff',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 11, fontWeight: 700,
                }}>
                  {r.full_name.split(' ').map(p => p[0]).slice(0, 2).join('')}
                </div>
                <div>
                  <div style={{ fontWeight: 600, color: '#111827' }}>{r.full_name}</div>
                  <div style={{ fontSize: 11, color: '#6B7280' }}>{r.employee_code}</div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
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
  const dialCode   = countryCode || '+91';
  const normalized = dialCode.startsWith('+') ? dialCode : `+${dialCode}`;
  const entry      = PHONE_CODES.find(p => p.code === normalized);
  const flag       = entry?.flag ?? '🌐';
  return (
    <div className="ev-field">
      <div className="ev-field-label">Mobile No.</div>
      <div className="ev-mobile-display">
        <span className="ev-mobile-country">
          <span className="ev-mobile-flag">{flag}</span>
          <span className="ev-mobile-dial">{normalized}</span>
        </span>
        <span className="ev-mobile-number">{mobile}</span>
      </div>
    </div>
  );
}

function SectionTitle({
  icon, text, pending, onViewProgress,
}: {
  icon: string;
  text: string;
  pending?: number;
  onViewProgress?: () => void;
}) {
  return (
    <div className="ev-section-title" style={{ display: 'flex', alignItems: 'flex-start', flexDirection: 'column', gap: 6 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <i className={`fa-solid ${icon}`} /> {text}
        {(pending ?? 0) > 0 && (
          <span style={{
            display:      'inline-flex',
            alignItems:   'center',
            gap:          4,
            background:   '#FEF3C7',
            color:        '#B45309',
            border:       '1px solid #F59E0B',
            borderRadius: 10,
            padding:      '2px 8px',
            fontSize:     11,
            fontWeight:   600,
            lineHeight:   1.4,
          }}>
            <i className="fa-solid fa-hourglass-half" style={{ fontSize: 10 }} />
            Workflow Pending Approval
          </span>
        )}
      </div>
      {(pending ?? 0) > 0 && onViewProgress && (
        <button
          onClick={onViewProgress}
          style={{
            background:  'none',
            border:      'none',
            padding:     0,
            cursor:      'pointer',
            display:     'flex',
            alignItems:  'center',
            gap:         4,
            fontSize:    12,
            color:       '#185FA5',
            textDecoration: 'underline',
            textUnderlineOffset: '2px',
          }}
        >
          <i className="fa-solid fa-users" style={{ fontSize: 11 }} />
          View approval progress
          <i className="fa-solid fa-arrow-right" style={{ fontSize: 10 }} />
        </button>
      )}
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
  label, value, onChange, type = 'text', placeholder = '', hint, error,
}: {
  label: string; value: string; onChange: (v: string) => void;
  type?: string; placeholder?: string; hint?: string; error?: string;
}) {
  return (
    <div className="ev-field">
      <div className="ev-field-label">{label}</div>
      <input
        type={type}
        value={value}
        placeholder={placeholder}
        onChange={e => onChange(e.target.value)}
        style={{ ...inputStyle, ...(error ? { borderColor: '#EF4444' } : {}) }}
      />
      {error && (
        <div style={{ fontSize: 11, color: '#EF4444', marginTop: 3 }}>{error}</div>
      )}
      {!error && hint && (
        <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}>{hint}</div>
      )}
    </div>
  );
}

function FormSelect({
  label, value, onChange, options, placeholder = '— Select —', error,
}: {
  label: string; value: string; onChange: (v: string) => void;
  options: { value: string; label: string }[];
  placeholder?: string; error?: string;
}) {
  return (
    <div className="ev-field">
      <div className="ev-field-label">{label}</div>
      <select
        value={value}
        onChange={e => onChange(e.target.value)}
        style={{ ...inputStyle, ...(error ? { borderColor: '#EF4444' } : {}) }}
      >
        <option value="">{placeholder}</option>
        {options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
      {error && (
        <div style={{ fontSize: 11, color: '#EF4444', marginTop: 3 }}>{error}</div>
      )}
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
  onSave, onCancel, saving, error, gated = false, isDirty = true,
}: {
  onSave: () => void; onCancel: () => void;
  saving: boolean; error: string | null;
  /** When true, changes the button label to "Submit for approval" */
  gated?: boolean;
  /** When false, disables the primary button — no changes detected */
  isDirty?: boolean;
}) {
  const disabled = saving || !isDirty;
  return (
    <div style={{ marginTop: 16, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
      <button
        onClick={onSave}
        disabled={disabled}
        style={{
          display: 'inline-flex', alignItems: 'center', gap: 6,
          padding: '7px 18px', borderRadius: 6,
          cursor: disabled ? 'not-allowed' : 'pointer',
          border: 'none', background: '#2563EB', color: '#fff',
          fontSize: 13, fontWeight: 600, opacity: disabled ? 0.45 : 1,
          transition: 'opacity 0.15s',
        }}
      >
        {saving
          ? <><i className="fa-solid fa-spinner fa-spin" /> {gated ? 'Submitting…' : 'Saving…'}</>
          : gated
            ? <><i className="fa-solid fa-paper-plane" /> Submit for approval</>
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

  // ── ProfileContext — viewedEmployeeId is self in self mode, other employee in employee mode
  const { viewedEmployeeId, isSelf, viewedEmployee } = useProfileContext();

  // ── canFor replaces can() — target-aware in employee mode, same as can() in self mode
  // Aliased as `can` so all 31 existing can('perm.code') call sites work unchanged.
  // `permsLoading` gates the "No access" empty state — without it the screen flashes
  // while check_permission_for_target() RPCs are still in flight.
  const { canFor: can, loading: permsLoading } = usePermissionsForEmployee(viewedEmployeeId, isSelf);

  const { picklistValues }               = usePicklistValues();
  const { departments }                  = useDepartments();
  const { employees }                    = useEmployees();
  const { currencies }                   = useCurrencies();
  const [activeSection, setActiveSection] = useState('personal');

  // ── Profile theme settings ─────────────────────────────────────────────────
  const [profileHeroImage,   setProfileHeroImage]   = useState<string | null>(null);
  const [profileSectionCfg,  setProfileSectionCfg]  = useState<{ id: string; visible: boolean; order: number }[]>([]);

  useEffect(() => {
    supabase.rpc('get_theme_settings').then(({ data }) => {
      if (!data) return;
      if (data.profile_hero_image) setProfileHeroImage(data.profile_hero_image);
      if (data.profile_sections) {
        try {
          const parsed = JSON.parse(data.profile_sections) as { id: string; visible: boolean; order: number }[];
          setProfileSectionCfg(parsed.sort((a, b) => a.order - b.order));
        } catch { /* use defaults */ }
      }
    });
  }, []);

  // Single RPC for all profile section workflow gates + pending counts.
  // refetch() is called on edit-mode entry so gates are never stale.
  const { activeGates, pendingCounts, instanceIds, isBankException, refetch: refetchGates } = useProfileWorkflowGates(viewedEmployeeId);

  // WorkflowParticipantsModal state — one modal for all profile sections
  const [participantsInstanceId,    setParticipantsInstanceId]    = useState<string | null>(null);
  const [participantsModuleLabel,   setParticipantsModuleLabel]   = useState<string>('');

  const openParticipants = async (moduleCode: string, label: string) => {
    setParticipantsModuleLabel(label);

    // Fast path: instance_id already in the gates hook response (mig 207+)
    const cachedId = instanceIds[moduleCode];
    if (cachedId) {
      setParticipantsInstanceId(cachedId);
      return;
    }

    // Fallback: query directly — works before mig 207 is applied.
    // RLS on workflow_instances scopes to submitted_by = auth.uid() automatically.
    const { data } = await supabase
      .from('workflow_instances')
      .select('id')
      .eq('module_code', moduleCode)
      .in('status', ['in_progress', 'awaiting_clarification'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (data?.id) setParticipantsInstanceId(data.id);
  };
  const scrollRef  = useRef<HTMLDivElement>(null);
  const sectionRefs = useRef<Record<string, HTMLElement | null>>({});

  // Extended data from related tables
  const [extData, setExtData] = useState<Record<string, unknown>>({});

  // Edit mode state
  const [editingSection, setEditingSection] = useState<string | null>(null);
  const [formData,       setFormData]       = useState<Record<string, string>>({});
  const [originalData,   setOriginalData]   = useState<Record<string, string>>({});
  const [saving,         setSaving]         = useState(false);
  const [saveError,      setSaveError]      = useState<string | null>(null);
  const [saveSuccess,    setSaveSuccess]    = useState<string | null>(null);
  const [wfErrorToast,   setWfErrorToast]  = useState<string | null>(null);

  // Passport inline field errors & country-change modal
  const [passportFieldErrors,    setPassportFieldErrors]    = useState<Record<string, string>>({});
  const [passportCountryPending, setPassportCountryPending] = useState<string | null>(null);

  // Mobile inline field error
  const [mobileFieldError, setMobileFieldError] = useState<string>('');

  // True when any field differs from the snapshot taken when edit mode opened.
  const isDirty = Object.keys(formData).some(k => formData[k] !== (originalData[k] ?? ''));

  // ── Workflow submission confirmation modal ─────────────────────────────
  const [confirmPending, setConfirmPending] = useState<{
    moduleCode:   string;
    title:        string;
    recordId:     string | null;
    proposedData: Record<string, string | null>;
    successMsg:   string;
  } | null>(null);

  // ── Pending-block modal — shown when section already has a pending workflow ─
  const [pendingBlockSection, setPendingBlockSection] = useState<string | null>(null);

  // Avatar upload state
  const [localPhoto,      setLocalPhoto]      = useState<string | null>(null);
  const [avatarUploading, setAvatarUploading] = useState(false);
  const [avatarError,     setAvatarError]     = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Personal info history panel
  const [personalHistOpen, setPersonalHistOpen] = useState(false);
  const [personalHistRows, setPersonalHistRows] = useState<Record<string, unknown>[]>([]);
  const [personalHistLoading, setPersonalHistLoading] = useState(false);
  const [personalHistSelIdx,  setPersonalHistSelIdx]  = useState(0);

  async function loadPersonalHistory(empId: string) {
    setPersonalHistLoading(true);
    const { data } = await supabase.rpc('get_personal_info_history', { p_employee_id: empId });
    setPersonalHistRows((data as Record<string, unknown>[] | null) ?? []);
    setPersonalHistSelIdx(0);
    setPersonalHistLoading(false);
  }

  // Job Relationships history panel + edit trigger
  const [jrHistOpen, setJrHistOpen] = useState(false);
  const jrEnterDraftRef = useRef<(() => void) | undefined>(undefined);

  // Employment history panel
  const [employmentHistOpen,    setEmploymentHistOpen]    = useState(false);
  const [employmentHistRows,    setEmploymentHistRows]    = useState<Record<string, unknown>[]>([]);
  const [employmentHistLoading, setEmploymentHistLoading] = useState(false);
  const [employmentHistSelIdx,  setEmploymentHistSelIdx]  = useState(0);
  const [employmentEditMode,    setEmploymentEditMode]    = useState<'edit' | 'insert'>('insert');
  const [empPropagate,          setEmpPropagate]          = useState(false);
  const [showPropagateModal,    setShowPropagateModal]    = useState(false);
  const [pendingEmpSave,        setPendingEmpSave]        = useState<(() => Promise<void>) | null>(null);

  // Personal info history panel
  const [personalEditMode,           setPersonalEditMode]           = useState<'edit' | 'insert'>('insert');
  const [showPersonalPropagateModal, setShowPersonalPropagateModal] = useState(false);

  // Delete confirmation dialog
  const [deleteConfirm, setDeleteConfirm] = useState<{
    title:     string;
    message:   string;
    onConfirm: () => Promise<void>;
  } | null>(null);
  const [deleteOpLoading, setDeleteOpLoading] = useState(false);
  const [deleteOpError,   setDeleteOpError]   = useState<string | null>(null);

  function confirmDelete(title: string, message: string, onConfirm: () => Promise<void>) {
    setDeleteOpError(null);
    setDeleteConfirm({ title, message, onConfirm });
  }

  async function runDelete() {
    if (!deleteConfirm) return;
    setDeleteOpLoading(true);
    setDeleteOpError(null);
    try {
      await deleteConfirm.onConfirm();
      setDeleteConfirm(null);
    } catch (err: unknown) {
      setDeleteOpError(err instanceof Error ? err.message : String(err));
    } finally {
      setDeleteOpLoading(false);
    }
  }

  async function loadEmploymentHistory(empId: string) {
    setEmploymentHistLoading(true);
    const { data } = await supabase.rpc('get_employment_info_history', { p_employee_id: empId });
    setEmploymentHistRows((data as Record<string, unknown>[] | null) ?? []);
    setEmploymentHistSelIdx(0);
    setEmploymentHistLoading(false);
  }

  // ── Cycle detection modal ──────────────────────────────────────────────
  const [cycleError, setCycleError] = useState<string | null>(null);


  // ── Load extended data from related tables ─────────────────────────────
  async function loadExtData(empId: string) {
    const [
      { data: personalRow },
      { data: contactRow },
      { data: pRows },
      { data: aRows },
      { data: ecRows },
      { data: idRows },
      { data: empSatRow },
    ] = await Promise.all([
      supabase.rpc('get_current_personal_info', { p_employee_id: empId }),
      supabase.from('employee_contact').select('*').eq('employee_id', empId).maybeSingle(),
      supabase.from('passports').select('*').eq('employee_id', empId).limit(1),
      supabase.from('employee_addresses').select('*').eq('employee_id', empId).limit(1),
      supabase.from('emergency_contacts').select('*').eq('employee_id', empId).limit(1),
      supabase.from('identity_records').select('*').eq('employee_id', empId),
      // All employment fields live on employee_employment satellite (mig 351+)
      supabase.from('employee_employment')
        .select('designation, job_title, dept_id, manager_id, hire_date, notice_period_days, work_country, work_location, base_currency_id, status, effective_from, probation_end_date')
        .eq('employee_id', empId)
        .eq('effective_to', '9999-12-31')
        .eq('is_active', true)
        .maybeSingle(),
    ]);

    const patch: Record<string, unknown> = {};

    // Employment fields come from the satellite (employee_employment) — authoritative source
    const sat = empSatRow as Record<string, unknown> | null;
    if (sat) {
      patch.designation      = sat.designation        ?? null;
      patch.deptId           = sat.dept_id            ?? null;
      patch.managerId        = sat.manager_id         ?? null;
      patch.hireDate         = sat.hire_date          ?? null;
      patch.noticePeriodDays = sat.notice_period_days ?? 30;
      patch.workCountry      = sat.work_country       ?? null;
      patch.workLocation     = sat.work_location      ?? null;
      patch.baseCurrencyId   = sat.base_currency_id   ?? null;
      patch.status           = sat.status             ?? null;
      patch.jobTitle         = sat.job_title          ?? null;
      patch.probationEndDate = sat.probation_end_date ?? null;
    }

    if (personalRow) {
      patch.firstName      = personalRow.first_name     ?? null;
      patch.middleName     = personalRow.middle_name    ?? null;
      patch.lastName       = personalRow.last_name      ?? null;
      patch.nationality    = personalRow.nationality    ?? null;
      patch.maritalStatus  = personalRow.marital_status ?? null;
      patch.gender         = personalRow.gender         ?? null;
      patch.dob            = personalRow.dob            ?? null;
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
    if (!viewedEmployeeId) return;
    loadExtData(viewedEmployeeId);
  }, [viewedEmployeeId]);

  // ── Profile context switch — scroll to top + reset active section (Phase 7 a11y) ──
  // Fires whenever the viewed employee changes (including self ↔ employee mode).
  useEffect(() => {
    // Reset scroll to top of the scroll container
    if (scrollRef.current) {
      scrollRef.current.scrollTo({ top: 0, behavior: 'instant' });
    }
    // Reset active section to the first visible one (SECTIONS is re-evaluated on render)
    setActiveSection('personal');
    // Clear any open edit mode when switching employee
    cancelEdit();
  }, [viewedEmployeeId]); // eslint-disable-line react-hooks/exhaustive-deps

  // effectiveFrom is seeded via editValues in SectionHeader — no useEffect needed

  // Merged employee with fresh DB data.
  // In employee mode: identity fields (name, email, id, status) come from ProfileContext.viewedEmployee;
  // detail fields (firstName, address, passport, etc.) come from extData loaded for viewedEmployeeId.
  const empBase = authEmployee
    ? (isSelf ? authEmployee : {
        ...authEmployee,
        id:            viewedEmployeeId,
        name:          viewedEmployee?.full_name     ?? authEmployee.name,
        employeeId:    viewedEmployee?.employee_code ?? authEmployee.employeeId,
        businessEmail: viewedEmployee?.email         ?? authEmployee.businessEmail,
        photo:         viewedEmployee?.avatar_url    ?? null,
        status:        viewedEmployee?.status        ?? 'Active',
        managerId:     viewedEmployee?.manager_id    ?? null,
      })
    : authEmployee;
  const emp = empBase ? { ...empBase, ...extData } : empBase;

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
    setOriginalData(values);   // snapshot for dirty check
    setSaveError(null);
    setSaveSuccess(null);
    refetchGates();            // always fetch fresh gates on edit-mode entry
  }

  function cancelEdit() {
    setEditingSection(null);
    setFormData({});
    setOriginalData({});
    setSaveError(null);
    setSaveSuccess(null);
    setPassportFieldErrors({});
    setPassportCountryPending(null);
    setMobileFieldError('');
    setEmpPropagate(false);
    setShowPropagateModal(false);
    setPendingEmpSave(null);
    setShowPersonalPropagateModal(false);
  }

  function showSuccess(msg: string) {
    setSaveSuccess(msg);
    setTimeout(() => setSaveSuccess(null), 3000);
  }

  function showWfError(msg: string) {
    setWfErrorToast(msg);
    setTimeout(() => setWfErrorToast(null), 7000);
  }

  // ── Workflow submission helper ─────────────────────────────────────────
  // Calls submit_change_request RPC instead of writing directly to the DB.
  // Returns true on success (caller should cancelEdit + showSuccess),
  // or throws on failure (caller catches and sets saveError).
  async function submitViaWorkflow(
    moduleCode:   string,
    recordId:     string | null,
    proposedData: Record<string, string | null>,
    comment?:     string,
  ): Promise<void> {
    const { data, error } = await supabase.rpc('submit_change_request', {
      p_module_code:   moduleCode,
      p_record_id:     recordId   ?? null,
      p_proposed_data: proposedData,
      p_action:        'update',
      p_comment:       comment?.trim() || null,
    });
    if (error) throw error;
    if (data && !data.ok) throw new Error(data.error ?? 'Workflow submission failed.');
  }

  // Executes the actual gated submit after the user confirms in WorkflowSubmitModal.
  // comment is forwarded to submit_change_request → wf_submit → action_log.notes.
  async function executeGatedSubmit(comment: string) {
    if (!confirmPending) return;
    const pending = confirmPending;
    setSaving(true); setSaveError(null);
    try {
      await submitViaWorkflow(pending.moduleCode, pending.recordId, pending.proposedData, comment);
      setConfirmPending(null);
      cancelEdit();
      showSuccess(pending.successMsg);
      refetchGates();   // refresh pendingCounts → banner appears immediately
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('[WorkflowSubmit] submit failed:', msg, err);
      setSaveError(msg);
      showWfError(msg);
    } finally {
      setSaving(false);
    }
  }

  // ── Save: Personal ─────────────────────────────────────────────────────
  async function savePersonal(propagate = false) {
    if (!viewedEmployeeId) return;
    const firstName  = fd('firstName').trim();
    const middleName = fd('middleName').trim();
    const lastName   = fd('lastName').trim();
    const nat = fd('nationality');
    const ms  = fd('maritalStatus');
    const gen = fd('gender');
    const dob = fd('dob');

    const today         = new Date().toISOString().split('T')[0];
    const effectiveFrom = fd('effectiveFrom') || today;

    if (!effectiveFrom)  { setSaveError('Effective from is required.');  return; }
    if (!firstName)      { setSaveError('First name is required.');       return; }
    if (!lastName)       { setSaveError('Last name is required.');        return; }
    if (!nat)            { setSaveError('Nationality is required.');       return; }
    if (!ms)             { setSaveError('Marital status is required.');    return; }
    if (!gen)            { setSaveError('Gender is required.');            return; }
    if (!dob)            { setSaveError('Date of birth is required.');     return; }

    const fn = firstName.trim(), mn = middleName.trim(), ln = lastName.trim();
    const computedName = fn && mn && ln ? `${fn} ${mn} ${ln}`
                       : fn && ln       ? `${fn} ${ln}`
                       : fn && mn       ? `${fn} ${mn}`
                       : fn             || '';
    const proposedPersonal = {
      effective_from: effectiveFrom,
      first_name:     firstName,
      middle_name:    middleName || null,
      last_name:      lastName  || null,
      name:           computedName,
      nationality:    nat || null,
      marital_status: ms  || null,
      gender:         gen || null,
      dob:            dob || null,
      _propagate:     propagate,   // stored in proposed_data for workflow approval path
    };

    if ((pendingCounts['profile_personal'] ?? 0) > 0) {
      setPendingBlockSection('Personal Information');
      return;
    }
    if (activeGates.has('profile_personal')) {
      setConfirmPending({
        moduleCode:   'profile_personal',
        title:        'Personal Information',
        recordId:     viewedEmployeeId,
        proposedData: proposedPersonal,
        successMsg:   'Personal details submitted for approval.',
      });
      return;
    }

    // Show propagate modal only when inserting mid-history (future slices exist after chosen date).
    if (!propagate && !showPersonalPropagateModal && personalEditMode === 'insert') {
      const { count } = await supabase
        .from('employee_personal')
        .select('id', { count: 'exact', head: true })
        .eq('employee_id', viewedEmployeeId)
        .gt('effective_from', effectiveFrom)
        .not('is_active', 'eq', false);
      if ((count ?? 0) > 0) {
        setShowPersonalPropagateModal(true);
        return;
      }
    }

    setSaving(true); setSaveError(null);
    setShowPersonalPropagateModal(false);
    try {
      const { data: result, error } = await supabase.rpc('upsert_personal_info', {
        p_employee_id:    viewedEmployeeId,
        p_proposed_data:  proposedPersonal,
        p_effective_from: effectiveFrom,
        p_propagate:      propagate,
      });
      if (error) throw error;
      if (result && !result.ok) throw new Error(result.error ?? 'Save failed');

      setExtData(prev => ({ ...prev, firstName, middleName: middleName || null, lastName: lastName || null, nationality: nat, maritalStatus: ms, gender: gen, dob }));
      refetchProfile();
      cancelEdit();
      showSuccess('Personal details saved.');
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  // ── Save: Employment ──────────────────────────────────────────────────
  async function saveEmployment(propagate = false) {
    if (!viewedEmployeeId) return;
    const today         = new Date().toISOString().split('T')[0];
    const effectiveFrom = fd('empEffectiveFrom') || today;
    const designation   = fd('empDesignation')   || null;
    const jobTitle      = fd('empJobTitle')       || null;
    const deptId        = fd('empDeptId')         || null;
    const managerId     = fd('empManagerId')      || null;
    const noticePeriodDays = parseInt(fd('empNoticePeriodDays') || '30', 10);
    const workCountry      = fd('empWorkCountry')    || null;
    const workLocation     = fd('empWorkLocation')   || null;

    const proposedEmployment = {
      effective_from:     effectiveFrom,
      designation:        designation,
      job_title:          jobTitle,
      dept_id:            deptId,
      manager_id:         managerId,
      notice_period_days: noticePeriodDays,
      work_country:       workCountry,
      work_location:      workLocation,
      _propagate:         propagate,   // stored in proposed_data for workflow approval path
    };

    if ((pendingCounts['profile_employment'] ?? 0) > 0) {
      setPendingBlockSection('Employment Information');
      return;
    }
    if (activeGates.has('profile_employment')) {
      setConfirmPending({
        moduleCode:   'profile_employment',
        title:        'Employment Information',
        recordId:     viewedEmployeeId,
        proposedData: proposedEmployment,
        successMsg:   'Employment change submitted for approval.',
      });
      return;
    }

    // Show propagate modal only when inserting mid-history (future slices exist after chosen date).
    // Editing the current/latest slice (amendment/correction) never has future slices to propagate to.
    if (!propagate && !showPropagateModal && employmentEditMode === 'insert') {
      const { count } = await supabase
        .from('employee_employment')
        .select('id', { count: 'exact', head: true })
        .eq('employee_id', viewedEmployeeId)
        .gt('effective_from', effectiveFrom)
        .not('is_active', 'eq', false);   // exclude soft-deleted rows
      if ((count ?? 0) > 0) {
        setPendingEmpSave(() => () => saveEmployment(true));
        setShowPropagateModal(true);
        return;
      }
    }

    setSaving(true); setSaveError(null);
    setShowPropagateModal(false);
    try {
      const { data: result, error } = await supabase.rpc('upsert_employment_info', {
        p_employee_id:    viewedEmployeeId,
        p_proposed_data:  proposedEmployment,
        p_effective_from: effectiveFrom,
        p_propagate:      propagate,
      });
      if (error) throw error;
      if (result && !result.ok) {
        if (result.error === 'CYCLE_DETECTED') {
          setCycleError(result.message ?? 'Assigning this manager would create a reporting cycle.');
          return;
        }
        throw new Error(result.error ?? 'Save failed');
      }
      setExtData(prev => ({
        ...prev,
        designation:    designation,
        jobTitle:       jobTitle,
        deptId:         deptId,
        managerId:      managerId,
        endDate:        endDate,
        workCountry:    workCountry,
        workLocation:   workLocation,
      }));
      refetchProfile();
      cancelEdit();
      showSuccess('Employment details saved.');
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  // ── Save: Contact ──────────────────────────────────────────────────────
  async function saveContact() {
    if (!viewedEmployeeId) return;
    const cc  = fd('countryCode');
    const mob = fd('mobile');
    const pe  = fd('personalEmail');

    // Mobile is required — cannot be cleared
    if (!mob || !mob.trim()) {
      setMobileFieldError('Mobile number is required.');
      setSaveError('Mobile number is required.');
      return;
    }

    // Country-aware mobile format validation
    const mobileErr = validateMobile(cc || '+91', mob || '');
    if (mobileErr) { setMobileFieldError(mobileErr); setSaveError(mobileErr); return; }

    // Personal email domain check — MyProfile is always Active employees
    if (pe && pe.trim().toLowerCase().includes('@prowessinfotech.co.in')) {
      setSaveError('Personal email cannot use the company email domain (@prowessinfotech.co.in). Please provide a personal email address.');
      return;
    }
    if (pe && pe.trim() && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(pe.trim())) {
      setSaveError('Enter a valid email address.');
      return;
    }

    const proposedContact = { country_code: cc || null, mobile: mob || null, personal_email: pe || null };

    if ((pendingCounts['profile_contact'] ?? 0) > 0) {
      setPendingBlockSection('Contact Information');
      return;
    }
    if (activeGates.has('profile_contact')) {
      setConfirmPending({
        moduleCode:   'profile_contact',
        title:        'Contact Information',
        recordId:     viewedEmployeeId,
        proposedData: proposedContact,
        successMsg:   'Contact details submitted for approval.',
      });
      return;
    }

    setSaving(true); setSaveError(null);
    try {
      // ── Direct save path ─────────────────────────────────────────────────
      const { error } = await supabase
        .from('employee_contact')
        .upsert({
          employee_id:    viewedEmployeeId,
          country_code:   cc  || null,
          mobile:         mob || null,
          personal_email: pe  || null,
          // Sync denormalized copy (mig 410) — business email is read-only for ESS
          business_email: (emp?.businessEmail as string) || null,
        }, { onConflict: 'employee_id' });
      if (error) throw error;

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
    if (!viewedEmployeeId) return;

    // Required field validation — line2, landmark, district are optional
    const addrErrors: string[] = [];
    if (!fd('addrLine1')?.trim())   addrErrors.push('Address Line 1 is required.');
    if (!fd('addrCity')?.trim())    addrErrors.push('City is required.');
    if (!fd('addrPin')?.trim())     addrErrors.push('PIN / Postal Code is required.');
    if (!fd('addrCountry')?.trim()) addrErrors.push('Country is required.');
    if (addrErrors.length > 0) { setSaveError(addrErrors[0]); return; }

    const proposed = {
      line1:    fd('addrLine1')    || null,
      line2:    fd('addrLine2')    || null,
      landmark: fd('addrLandmark') || null,
      city:     fd('addrCity')     || null,
      district: fd('addrDistrict') || null,
      state:    fd('addrState')    || null,
      pin:      fd('addrPin')      || null,
      country:  fd('addrCountry')  || null,
    };

    if ((pendingCounts['profile_address'] ?? 0) > 0) {
      setPendingBlockSection('Address Information');
      return;
    }
    if (activeGates.has('profile_address')) {
      setConfirmPending({
        moduleCode:   'profile_address',
        title:        'Address Information',
        recordId:     (extData.addrId as string) || null,
        proposedData: proposed,
        successMsg:   'Address changes submitted for approval.',
      });
      return;
    }

    setSaving(true); setSaveError(null);
    try {
      // ── Direct save path ─────────────────────────────────────────────────
      const payload = { employee_id:    viewedEmployeeId, ...proposed };
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
    if (!viewedEmployeeId) return;
    const passCountryId   = fd('passportCountry') || '';
    const passNumber      = fd('passportNumber')  || '';
    const passIssueDate   = fd('passportIssueDate')  || '';
    const passExpiryDate  = fd('passportExpiryDate') || '';
    const passCountryName = resolvePicklist('ID_COUNTRY', passCountryId);

    // Country-aware passport number validation
    if (passNumber) {
      const numErr = validatePassportNumber(passCountryName, passNumber);
      if (numErr) { setSaveError(numErr); return; }
    }
    // Validity period validation
    if (passIssueDate && passExpiryDate) {
      const valErr = validatePassportValidity(passCountryName, passIssueDate, passExpiryDate);
      if (valErr) { setSaveError(valErr); return; }
    }

    const proposed = {
      country:         passCountryId  || null,
      passport_number: passNumber     || null,
      issue_date:      passIssueDate  || null,
      expiry_date:     passExpiryDate || null,
    };

    if ((pendingCounts['profile_passport'] ?? 0) > 0) {
      setPendingBlockSection('Passport Information');
      return;
    }
    if (activeGates.has('profile_passport')) {
      setConfirmPending({
        moduleCode:   'profile_passport',
        title:        'Passport Information',
        recordId:     (extData.passportId as string) || null,
        proposedData: proposed,
        successMsg:   'Passport details submitted for approval.',
      });
      return;
    }

    setSaving(true); setSaveError(null);
    try {
      // ── Direct save path ─────────────────────────────────────────────────
      const payload = { employee_id:    viewedEmployeeId, ...proposed };
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
    if (!viewedEmployeeId) return;

    // Name, relationship, and phone are required.
    // Without these guards an empty save would trigger the backend NULLIF path
    // which silently deletes the existing emergency contact row.
    if (!fd('ecName')?.trim()) { setSaveError('Contact Name is required.'); return; }
    if (!fd('ecRelationship')?.trim()) { setSaveError('Relationship is required.'); return; }
    if (!fd('ecPhone')?.trim()) { setSaveError('Phone Number is required.'); return; }

    const proposed = {
      name:         fd('ecName')         || null,
      relationship: fd('ecRelationship') || null,
      phone:        fd('ecPhone')        || null,
      alt_phone:    fd('ecAltPhone')     || null,
      email:        fd('ecEmail')        || null,
    };

    if ((pendingCounts['profile_emergency_contact'] ?? 0) > 0) {
      setPendingBlockSection('Emergency Contact');
      return;
    }
    if (activeGates.has('profile_emergency_contact')) {
      setConfirmPending({
        moduleCode:   'profile_emergency_contact',
        title:        'Emergency Contact',
        recordId:     (extData.ecId as string) || null,
        proposedData: proposed,
        successMsg:   'Emergency contact changes submitted for approval.',
      });
      return;
    }

    setSaving(true); setSaveError(null);
    try {
      // ── Direct save path ─────────────────────────────────────────────────
      const payload = { employee_id:    viewedEmployeeId, ...proposed };
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
    if (!file || !viewedEmployeeId) return;

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
      const path = `employees/${viewedEmployeeId}/avatar.${ext}`;

      const { error: upErr } = await supabase.storage
        .from('avatars')
        .upload(path, file, { contentType: file.type, upsert: true });
      if (upErr) throw upErr;

      const { data: urlData } = supabase.storage.from('avatars').getPublicUrl(path);
      const publicUrl = urlData.publicUrl + `?t=${Date.now()}`; // bust cache

      // Store in employee_personal via RPC (effective-dated)
      const today = new Date().toISOString().split('T')[0];
      const { data: photoResult, error: dbErr } = await supabase.rpc('upsert_personal_info', {
        p_employee_id:    viewedEmployeeId,
        p_proposed_data:  { photo_url: publicUrl },
        p_effective_from: today,
      });
      if (dbErr) throw dbErr;
      if (photoResult && !photoResult.ok) throw new Error(photoResult.error ?? 'Photo save failed');

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

  const ALL_SECTIONS = [
    { id: 'personal',          label: 'Personal',          icon: 'fa-circle-user',      viewPermission: 'personal_info.view'      },
    { id: 'contact',           label: 'Contact',           icon: 'fa-phone',            viewPermission: 'contact_info.view'       },
    { id: 'employment',        label: 'Employment',        icon: 'fa-briefcase',        viewPermission: 'employment.view'         },
    { id: 'address',           label: 'Address',           icon: 'fa-location-dot',     viewPermission: 'address.view'            },
    { id: 'passport',          label: 'Passport',          icon: 'fa-passport',         viewPermission: 'passport.view'           },
    { id: 'identification',    label: 'Identification',    icon: 'fa-id-card-clip',     viewPermission: 'identity_documents.view' },
    { id: 'emergency',         label: 'Emergency Contact', icon: 'fa-phone-volume',     viewPermission: 'emergency_contacts.view' },
    { id: 'bank',              label: 'Bank Accounts',     icon: 'fa-building-columns', viewPermission: 'bank_accounts.view'      },
    { id: 'dependents',        label: 'Dependents',        icon: 'fa-people-group',     viewPermission: 'dependents.view'         },
    { id: 'job_relationships', label: 'Job Relationships', icon: 'fa-sitemap',          viewPermission: 'job_relationships.view'  },
    { id: 'education',         label: 'Education',         icon: 'fa-graduation-cap',   viewPermission: 'education.view'          },
    { id: 'termination',       label: 'Termination',       icon: 'fa-user-slash',       viewPermission: 'termination.view'        },
  ];

  // Apply theme ordering + visibility — all sections including termination are now configurable
  const SECTIONS = (() => {
    if (profileSectionCfg.length === 0) return ALL_SECTIONS.filter(s => can(s.viewPermission));
    const cfgMap = new Map(profileSectionCfg.map(c => [c.id, c]));
    return ALL_SECTIONS
      .filter(s => can(s.viewPermission))
      .filter(s => (cfgMap.get(s.id)?.visible ?? true))
      .sort((a, b) => (cfgMap.get(a.id)?.order ?? 99) - (cfgMap.get(b.id)?.order ?? 99));
  })();

  const today = new Date(); today.setHours(0, 0, 0, 0);
  const endDate = emp.endDate ? new Date((emp.endDate as string) + 'T00:00:00') : null;
  // Trust employees.status (base table) as the source of truth — set by termination workflow.
  // Fall back to date-based logic only when status is missing (legacy records).
  const isActive = emp.status === 'Inactive' ? false
    : emp.status === 'Active'  ? true
    : (!endDate || emp.endDate === '9999-12-31' || endDate >= today);

  const identifications: Record<string, unknown>[] = (emp.idRecords as Record<string, unknown>[] | undefined) || [];

  // ── Delete handlers ───────────────────────────────────────────────────

  async function deletePersonalInfoRecord(recordId: string) {
    const { data } = await supabase.rpc('delete_personal_info_record', {
      p_record_id:   recordId,
      p_employee_id: viewedEmployeeId,
    });
    const res = data as { ok: boolean; error?: string } | null;
    if (!res?.ok) throw new Error(res?.error ?? 'Delete failed');
    if (viewedEmployeeId) await loadPersonalHistory(viewedEmployeeId);
    setPersonalHistSelIdx(0);
    refetchProfile();
  }

  async function deleteEmploymentRecord(recordId: string) {
    const { data } = await supabase.rpc('delete_employment_record', {
      p_record_id:   recordId,
      p_employee_id: viewedEmployeeId,
    });
    const res = data as { ok: boolean; error?: string } | null;
    if (!res?.ok) throw new Error(res?.error ?? 'Delete failed');
    if (viewedEmployeeId) await loadEmploymentHistory(viewedEmployeeId);
    setEmploymentHistSelIdx(0);
    refetchProfile();
  }

  async function deleteContactInfo() {
    const { data } = await supabase.rpc('delete_contact_info', { p_employee_id: viewedEmployeeId });
    const res = data as { ok: boolean; error?: string } | null;
    if (!res?.ok) throw new Error(res?.error ?? 'Delete failed');
    refetchProfile();
  }

  async function deleteAddress() {
    const { data } = await supabase.rpc('delete_address', { p_employee_id: viewedEmployeeId });
    const res = data as { ok: boolean; error?: string } | null;
    if (!res?.ok) throw new Error(res?.error ?? 'Delete failed');
    refetchProfile();
  }

  async function deletePassport() {
    const { data } = await supabase.rpc('delete_passport', { p_employee_id: viewedEmployeeId });
    const res = data as { ok: boolean; error?: string } | null;
    if (!res?.ok) throw new Error(res?.error ?? 'Delete failed');
    refetchProfile();
  }

  async function deleteEmergencyContact() {
    const ecId = emp?.ecId as string | undefined;
    if (!ecId) throw new Error('Emergency contact ID not found');
    const { data } = await supabase.rpc('delete_emergency_contact', {
      p_record_id:   ecId,
      p_employee_id: viewedEmployeeId,
    });
    const res = data as { ok: boolean; error?: string } | null;
    if (!res?.ok) throw new Error(res?.error ?? 'Delete failed');
    refetchProfile();
  }

  async function deleteIdentityRecord(recordId: string) {
    const { data } = await supabase.rpc('delete_identity_record', {
      p_record_id:   recordId,
      p_employee_id: viewedEmployeeId,
    });
    const res = data as { ok: boolean; error?: string } | null;
    if (!res?.ok) throw new Error(res?.error ?? 'Delete failed');
    refetchProfile();
  }

  // Shared inline delete button style
  const deleteIconBtn: React.CSSProperties = {
    background: 'none', border: 'none', cursor: 'pointer',
    color: '#EF4444', padding: '2px 4px', borderRadius: 4,
    lineHeight: 1, fontSize: 12,
  };

  // ── Section header with optional Edit button ──────────────────────────
  function SectionHeader({
    icon, text, section, permission, insertPermission, editValues, onInsert, onEdit, pendingCount, moduleCode,
    historyPermission, histOpen, onToggleHistory,
  }: {
    icon: string; text: string; section: string;
    permission?: string; insertPermission?: string;
    editValues?: Record<string, string>;
    onInsert?: () => void;
    onEdit?: () => void;
    pendingCount?: number;
    moduleCode?: string;
    historyPermission?: string;
    histOpen?: boolean;
    onToggleHistory?: () => void;
  }) {
    const canEdit    = permission && (isSelf || viewedEmployee?.status !== 'Inactive') ? can(permission) : false;
    const canInsert  = insertPermission && (isSelf || viewedEmployee?.status !== 'Inactive') ? can(insertPermission) : false;
    const canHistory = historyPermission ? can(historyPermission) : false;
    const isEditing  = editingSection === section;
    return (
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 14 }}>
        <SectionTitle
          icon={icon}
          text={text}
          pending={pendingCount}
          onViewProgress={moduleCode ? () => openParticipants(moduleCode, text) : undefined}
        />
        <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
          {canHistory && !isEditing && onToggleHistory && (
            <button
              onClick={onToggleHistory}
              title={histOpen ? 'Close history' : 'View history'}
              style={{
                background: histOpen ? '#EEF2FF' : 'none',
                border: `1px solid ${histOpen ? '#A5B4FC' : '#E5E7EB'}`,
                borderRadius: 6, padding: '4px 8px', cursor: 'pointer',
                color: histOpen ? '#4F46E5' : '#6B7280', fontSize: 12,
                display: 'flex', alignItems: 'center', gap: 4,
              }}
            >
              <i className="fa-solid fa-clock-rotate-left" style={{ fontSize: 11 }} />
              {histOpen ? 'Close' : 'History'}
            </button>
          )}
          {canInsert && !isEditing && !editingSection && onInsert && (
            <button
              onClick={onInsert}
              title="Insert new time slice"
              style={{
                background: '#EFF6FF', border: '1px solid #BFDBFE',
                borderRadius: 6, padding: '4px 10px', cursor: 'pointer',
                color: '#2563EB', fontSize: 12, fontWeight: 600,
                display: 'flex', alignItems: 'center', gap: 4,
              }}
            >
              <i className="fa-solid fa-plus" style={{ fontSize: 11 }} />
              Insert
            </button>
          )}
          {canEdit && !isEditing && !editingSection && editValues && (
            <EditButton onClick={onEdit ?? (() => startEdit(section, editValues))} />
          )}
        </div>
      </div>
    );
  }

  // ── JSX ───────────────────────────────────────────────────────────────
  return (
    <div style={{ padding: '0 0 24px' }}>
      <h2 className="page-title">{isSelf ? 'My Profile' : (viewedEmployee?.full_name ?? 'Employee Profile')}</h2>

      {/* ── Employee mode banner — blue (active) or amber (inactive) ── */}
      {!isSelf && viewedEmployee && (
        viewedEmployee.status === 'Inactive' ? (
          <div style={{
            background: '#FFFBEB', border: '1px solid #F59E0B', borderRadius: 8,
            padding: '10px 16px', marginBottom: 16, display: 'flex', alignItems: 'center',
            gap: 10, fontSize: 13,
          }}>
            <i className="fa-solid fa-triangle-exclamation" style={{ color: '#D97706' }} />
            <span style={{ color: '#92400E', fontWeight: 600 }}>
              {viewedEmployee.employee_code} · {viewedEmployee.full_name} is Inactive.
              {' '}<span style={{ fontWeight: 400 }}>View-only — edit actions are hidden.</span>
            </span>
          </div>
        ) : (
          <div style={{
            background: '#EFF6FF', border: '1px solid #93C5FD', borderRadius: 8,
            padding: '10px 16px', marginBottom: 16, display: 'flex', alignItems: 'center',
            justifyContent: 'space-between', fontSize: 13,
          }}>
            <span style={{ color: '#1E40AF', display: 'flex', alignItems: 'center', gap: 8 }}>
              <i className="fa-solid fa-eye" />
              Viewing <strong style={{ marginLeft: 4 }}>{viewedEmployee.employee_code} · {viewedEmployee.full_name}</strong>
            </span>
            <a
              href="/profile"
              style={{ color: '#2563EB', fontSize: 12, textDecoration: 'underline', whiteSpace: 'nowrap' }}
            >
              ← Return to your profile
            </a>
          </div>
        )
      )}

      {/* ── Permission empty state — no view perms for this employee ── */}
      {!isSelf && !profileLoading && !permsLoading && SECTIONS.length === 0 && (
        <div style={{
          margin: '48px auto', maxWidth: 420, textAlign: 'center',
          padding: '40px 32px', background: '#FFF7F7',
          border: '1px solid #FCA5A5', borderRadius: 12,
        }}>
          <i className="fa-solid fa-lock" style={{ fontSize: 32, color: '#EF4444', marginBottom: 16 }} />
          <h3 style={{ margin: '0 0 8px', color: '#991B1B', fontSize: 16 }}>No access</h3>
          <p style={{ color: '#6B7280', fontSize: 13, margin: 0 }}>
            You don't have permission to view this employee's profile.
          </p>
        </div>
      )}

      {/* ── Workflow Participants Modal — "View approval progress" link ─── */}
      <WorkflowParticipantsModal
        open={!!participantsInstanceId}
        onClose={() => setParticipantsInstanceId(null)}
        instanceId={participantsInstanceId}
        title={participantsModuleLabel}
        submittedByName={emp?.name as string | undefined}
      />

      {/* ── Workflow submission confirmation modal ──────────────────────── */}
      <WorkflowSubmitModal
        open={!!confirmPending}
        onClose={() => { setConfirmPending(null); setSaveError(null); }}
        onConfirm={comment => executeGatedSubmit(comment)}
        confirming={saving}
        submitError={saveError}
        title={confirmPending?.title ?? ''}
        moduleCode={confirmPending?.moduleCode ?? ''}
        employeeName={emp?.name as string | undefined}
      />

      {/* ── Passport country-change confirmation ────────────────────────────── */}
      <ConfirmationModal
        isOpen={passportCountryPending !== null}
        title="Change Issue Country?"
        message="Changing the Issue Country will clear the Passport Number, Issue Date, and Expiry Date. Do you want to continue?"
        confirmText="Yes, Clear"
        cancelText="Cancel"
        destructive={false}
        onConfirm={() => {
          if (passportCountryPending !== null) {
            setFd('passportCountry', passportCountryPending);
            setFd('passportNumber', '');
            setFd('passportIssueDate', '');
            setFd('passportExpiryDate', '');
            setPassportFieldErrors({});
          }
          setPassportCountryPending(null);
        }}
        onCancel={() => setPassportCountryPending(null)}
      />

      {/* ── Pending-block modal — fires when section already has a pending workflow ── */}
      <ConfirmationModal
        isOpen={!!pendingBlockSection}
        title="Changes Pending Approval"
        message={`Your ${pendingBlockSection ?? 'section'} changes are currently awaiting approval. You cannot submit a new request until the existing one is resolved.`}
        warning="Please check back after your approver has reviewed the pending request."
        confirmText="OK"
        cancelText="Dismiss"
        destructive={false}
        onConfirm={() => setPendingBlockSection(null)}
        onCancel={() => setPendingBlockSection(null)}
      />

      {/* ── Delete confirmation modal ──────────────────────────────────────── */}
      <ConfirmationModal
        isOpen={!!deleteConfirm}
        title={deleteConfirm?.title ?? 'Delete Record'}
        message={deleteConfirm?.message ?? ''}
        confirmText="Delete"
        cancelText="Cancel"
        destructive={true}
        loading={deleteOpLoading}
        onConfirm={runDelete}
        onCancel={() => { setDeleteConfirm(null); setDeleteOpError(null); }}
        warning={deleteOpError ?? undefined}
      />

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

      {/* Global workflow error toast — floats above modal overlay (z 9999 > 9000) */}
      {wfErrorToast && (
        <div className="emp-toast emp-toast--error">
          <i className="fa-solid fa-circle-exclamation" />
          <span>Submission failed: {wfErrorToast}</span>
          <button
            onClick={() => setWfErrorToast(null)}
            style={{
              background: 'none', border: 'none', cursor: 'pointer',
              color: 'inherit', fontSize: 14, padding: '0 0 0 6px',
              lineHeight: 1, opacity: 0.7,
            }}
            aria-label="Dismiss"
          >
            <i className="fa-solid fa-xmark" />
          </button>
        </div>
      )}

      {/* ── Profile Header ─────────────────────────────────────────────── */}
      <div className="mp-header" style={profileHeroImage ? {
        backgroundImage: `url(${profileHeroImage})`,
        backgroundSize: 'cover',
        backgroundPosition: 'center 30%',
      } : undefined}>
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
            {isSelf && can('personal_info.edit') && (
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
          {isSelf && can('personal_info.edit') && !avatarUploading && (
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
              <a
                className="mp-meta-icon"
                href={`mailto:${String(emp.businessEmail || emp.email)}`}
                title=""
              >
                <i className="fa-solid fa-envelope" />
                <span className="mp-meta-tooltip">{String(emp.businessEmail || emp.email)}</span>
              </a>
            )}
            {emp.mobile && (
              <a
                className="mp-meta-icon"
                href={`tel:${emp.countryCode as string ?? ''}${emp.mobile as string}`}
                title=""
              >
                <i className="fa-solid fa-phone" />
                <span className="mp-meta-tooltip">
                  {emp.countryCode ? `${emp.countryCode} ` : ''}{emp.mobile as string}
                </span>
              </a>
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
              <SectionHeader
                icon="fa-circle-user" text="Personal Information"
                section="personal"
                insertPermission="personal_info.create"
                moduleCode="profile_personal"
                pendingCount={pendingCounts['profile_personal'] ?? 0}
                onInsert={() => {
                  setPersonalEditMode('insert');
                  setPersonalHistOpen(false);
                  startEdit('personal', {
                    firstName:     '',
                    middleName:    '',
                    lastName:      '',
                    nationality:   '',
                    maritalStatus: '',
                    gender:        '',
                    dob:           '',
                    effectiveFrom: new Date().toISOString().split('T')[0],
                  });
                }}
                historyPermission="personal_info.history"
                histOpen={personalHistOpen}
                onToggleHistory={() => {
                  if (!personalHistOpen && viewedEmployeeId) {
                    loadPersonalHistory(viewedEmployeeId);
                  }
                  setPersonalHistOpen(v => !v);
                  setEditingSection(null);
                }}
              />

              {editingSection === 'personal' ? (
                <>
                  {/* Mode banner */}
                  {personalEditMode === 'edit' && (
                    <div style={{ display:'flex', alignItems:'center', gap:8, padding:'8px 12px', background:'#FFF7ED', border:'1px solid #FED7AA', borderRadius:8, marginBottom:12, fontSize:13, color:'#92400E' }}>
                      <i className="fa-solid fa-pen-to-square" style={{ color:'#F97316' }} />
                      Editing existing record — effective date is locked
                    </div>
                  )}
                  <div className="ev-field-grid ev-grid-2">
                    {personalEditMode === 'insert' ? (
                      <FormInput
                        label="Effective From *"
                        type="date" min="1900-01-01" max="2100-12-31"
                        value={fd('effectiveFrom')}
                        onChange={v => setFd('effectiveFrom', v)}
                        hint={
                          fd('effectiveFrom') > new Date().toISOString().split('T')[0]
                            ? '⏰ Future-dated — change takes effect on this date'
                            : fd('effectiveFrom') && fd('effectiveFrom') < new Date().toISOString().split('T')[0]
                            ? '↩ Backdated — history updated from this date'
                            : undefined
                        }
                      />
                    ) : (
                      <div className="ev-field">
                        <div className="ev-field-label">Effective From</div>
                        <div style={{ display:'flex', alignItems:'center', gap:6, padding:'7px 10px', background:'#F9FAFB', border:'1px solid #E5E7EB', borderRadius:6, fontSize:13, color:'#6B7280' }}>
                          <i className="fa-solid fa-lock" style={{ fontSize:11 }} />
                          {fd('effectiveFrom')} <span style={{ fontSize:11, color:'#9CA3AF' }}>locked</span>
                        </div>
                      </div>
                    )}
                    <div /> {/* spacer to keep grid alignment */}
                    <FormInput
                      label="First Name *"
                      value={fd('firstName')}
                      onChange={v => setFd('firstName', v)}
                      placeholder="First name"
                    />
                    <FormInput
                      label="Middle Name"
                      value={fd('middleName')}
                      onChange={v => setFd('middleName', v)}
                      placeholder="Middle name (optional)"
                    />
                    <FormInput
                      label="Last Name *"
                      value={fd('lastName')}
                      onChange={v => setFd('lastName', v)}
                      placeholder="Last name"
                    />
                    <div className="ev-field">
                      <div className="ev-field-label" style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                        Full Name
                        <span style={{ fontSize: 10, color: '#9CA3AF', fontWeight: 400, fontStyle: 'italic' }}>(auto-computed)</span>
                      </div>
                      <input
                        type="text"
                        readOnly
                        tabIndex={-1}
                        value={(() => {
                          const f = fd('firstName').trim();
                          const m = fd('middleName').trim();
                          const l = fd('lastName').trim();
                          return f && m && l ? `${f} ${m} ${l}`
                               : f && l       ? `${f} ${l}`
                               : f && m       ? `${f} ${m}`
                               : f            || '';
                        })()}
                        style={{ ...inputStyle, background: '#F3F4F6', color: '#6B7280', cursor: 'not-allowed', borderColor: '#E5E7EB' }}
                      />
                    </div>
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
                    <FormSelect
                      label="Gender"
                      value={fd('gender')}
                      onChange={v => setFd('gender', v)}
                      options={[
                        { value: 'Male',   label: 'Male' },
                        { value: 'Female', label: 'Female' },
                      ]}
                    />
                    <FormInput
                      label="Date of Birth"
                      type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                      value={fd('dob')}
                      onChange={v => setFd('dob', v)}
                    />
                    {fd('dob') && (
                      <div className="ev-field">
                        <div className="ev-field-label" style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                          Age
                          <span style={{ fontSize: 10, color: '#9CA3AF', fontWeight: 400, fontStyle: 'italic' }}>
                            (auto-calculated)
                          </span>
                        </div>
                        <input
                          type="text"
                          value={calcAge(fd('dob')) !== null ? `${calcAge(fd('dob'))} years` : ''}
                          readOnly
                          tabIndex={-1}
                          style={{
                            ...inputStyle,
                            background: '#F3F4F6',
                            color: '#9CA3AF',
                            cursor: 'not-allowed',
                            borderColor: '#E5E7EB',
                          }}
                        />
                      </div>
                    )}
                  </div>

                  <SaveCancelRow onSave={() => savePersonal(false)} onCancel={cancelEdit} saving={saving} error={saveError} gated={activeGates.has('profile_personal')} isDirty={isDirty} />
                </>
              ) : personalHistOpen ? (
                /* ── History panel — replaces the field grid in-place ── */
                <div style={{ border: '1px solid #E0E7FF', borderRadius: 10, overflow: 'hidden' }}>
                  <div style={{ background: '#EEF2FF', padding: '10px 16px', display: 'flex', alignItems: 'center', gap: 8, borderBottom: '1px solid #E0E7FF' }}>
                    <i className="fa-solid fa-clock-rotate-left" style={{ color: '#4F46E5', fontSize: 13 }} />
                    <span style={{ fontWeight: 600, fontSize: 13, color: '#3730A3' }}>History</span>
                    <span style={{ marginLeft: 'auto', fontSize: 12, color: '#6B7280' }}>
                      {personalHistRows.length} record{personalHistRows.length !== 1 ? 's' : ''}
                    </span>
                  </div>

                  {personalHistLoading ? (
                    <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
                      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading history…
                    </div>
                  ) : personalHistRows.length === 0 ? (
                    <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>No history available.</div>
                  ) : (
                    <div style={{ display: 'flex', minHeight: 180 }}>
                      {/* Date list */}
                      <div style={{ width: 140, borderRight: '1px solid #E0E7FF', overflowY: 'auto' }}>
                        {personalHistRows.map((h, i) => {
                          const from = h.effective_from as string;
                          const to   = h.effective_to   as string;
                          const today = new Date().toISOString().slice(0, 10);
                          const isCurrent  = from <= today && to >= today;
                          const isUpcoming = from > today;
                          return (
                            <button
                              key={i}
                              onClick={() => setPersonalHistSelIdx(i)}
                              style={{
                                width: '100%', textAlign: 'left', padding: '10px 12px',
                                background: personalHistSelIdx === i ? '#EEF2FF' : 'none',
                                border: 'none', borderBottom: '1px solid #F3F4F6',
                                cursor: 'pointer', fontSize: 12,
                                color: personalHistSelIdx === i ? '#4F46E5' : '#374151',
                              }}
                            >
                              <div style={{ fontWeight: 600 }}>{from}</div>
                              <div style={{ color: isCurrent ? '#059669' : isUpcoming ? '#7C3AED' : '#9CA3AF', fontSize: 11, fontWeight: isCurrent || isUpcoming ? 600 : 400 }}>
                                {isCurrent ? 'Current' : isUpcoming ? 'Upcoming' : `→ ${to}`}
                              </div>
                            </button>
                          );
                        })}
                      </div>

                      {/* Detail */}
                      {(() => {
                        const h = personalHistRows[personalHistSelIdx];
                        if (!h) return null;
                        const today = new Date().toISOString().slice(0, 10);
                        const isCurrent  = (h.effective_from as string) <= today && (h.effective_to as string) >= today;
                        const isUpcoming = (h.effective_from as string) > today;
                        return (
                          <div style={{ flex: 1, padding: '14px 16px', display: 'flex', flexDirection: 'column' }}>
                            <div className="ev-field-grid ev-grid-2" style={{ gap: 8 }}>
                              <Field label="First Name"     value={(h.first_name  as string) || undefined} />
                              <Field label="Middle Name"    value={(h.middle_name as string) || undefined} />
                              <Field label="Last Name"      value={(h.last_name   as string) || undefined} />
                              <Field label="Full Name"      value={(h.name        as string) || undefined} />
                              <Field label="Employee ID"    value={emp.employeeId as string} />
                              <Field label="Nationality"    value={(h.nationality as string) || undefined} />
                              <Field label="Marital Status" value={resolvePicklist('MARITAL_STATUS', (h.marital_status as string | undefined))} />
                              <Field label="Gender"         value={(h.gender      as string) || undefined} />
                              <Field label="Date of Birth"  value={(h.dob         as string) || undefined} />
                              {h.dob && <Field label="Age" value={calcAge(h.dob as string) !== null ? `${calcAge(h.dob as string)} years` : undefined} />}
                            </div>
                            {(can('personal_info.edit') || can('personal_info.delete')) && (
                              <div style={{ marginTop: 12, display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
                                {can('personal_info.edit') && (
                                  <button
                                    style={{
                                      fontSize: 12, display: 'flex', alignItems: 'center', gap: 5,
                                      padding: '5px 10px', border: '1px solid #BFDBFE', borderRadius: 6,
                                      background: '#EFF6FF', color: '#1D4ED8', cursor: 'pointer',
                                    }}
                                    onClick={() => {
                                      setPersonalEditMode('edit');
                                      setPersonalHistOpen(false);
                                      startEdit('personal', {
                                        firstName:     String(h.first_name    ?? ''),
                                        middleName:    String(h.middle_name   ?? ''),
                                        lastName:      String(h.last_name     ?? ''),
                                        nationality:   String(h.nationality   ?? ''),
                                        maritalStatus: String(h.marital_status ?? ''),
                                        gender:        String(h.gender        ?? ''),
                                        dob:           String(h.dob           ?? ''),
                                        effectiveFrom: String(h.effective_from ?? ''),
                                      });
                                    }}
                                  >
                                    <i className="fa-solid fa-pen-to-square" /> Edit this record
                                  </button>
                                )}
                                {can('personal_info.delete') && (
                                  <button
                                    disabled={personalHistRows.length <= 1}
                                    title={personalHistRows.length <= 1 ? 'Cannot delete — at least one personal info record must exist at all times' : 'Delete this record'}
                                    style={{
                                      ...deleteIconBtn, fontSize: 12, display: 'flex', alignItems: 'center', gap: 5,
                                      padding: '5px 10px', border: '1px solid #FCA5A5', borderRadius: 6,
                                      opacity: personalHistRows.length <= 1 ? 0.4 : 1,
                                      cursor: personalHistRows.length <= 1 ? 'not-allowed' : 'pointer',
                                    }}
                                    onClick={() => {
                                      if (personalHistRows.length <= 1) return;
                                      confirmDelete(
                                        'Delete Personal Info Record',
                                        `Delete the record effective from ${h.effective_from as string}? The timeline will be adjusted automatically.`,
                                        () => deletePersonalInfoRecord(h.id as string),
                                      );
                                    }}
                                  >
                                    <i className="fa-solid fa-trash-can" /> Delete this record
                                  </button>
                                )}
                              </div>
                            )}
                          </div>
                        );
                      })()}
                    </div>
                  )}
                </div>
              ) : (
                <div className="ev-field-grid ev-grid-2">
                  <Field label="First Name"     value={(emp.firstName  as string) || undefined} />
                  <Field label="Middle Name"    value={(emp.middleName as string) || undefined} />
                  <Field label="Last Name"      value={(emp.lastName   as string) || undefined} />
                  <Field label="Full Name"      value={(emp.name       as string) || undefined} />
                  <Field label="Employee ID"    value={emp.employeeId as string} />
                  <Field label="Nationality"    value={resolvePicklist('NATIONALITY', emp.nationality as string | undefined)} />
                  <Field label="Marital Status" value={resolvePicklist('MARITAL_STATUS', emp.maritalStatus as string | undefined)} />
                  <Field label="Gender"         value={(emp.gender as string) || undefined} />
                  <Field label="Date of Birth"  value={(emp.dob as string) || undefined} />
                  {emp.dob && <Field label="Age" value={calcAge(emp.dob as string) !== null ? `${calcAge(emp.dob as string)} years` : undefined} />}
                </div>
              )}
            </section>

            {/* ── Contact ──────────────────────────────────────────── */}
            <section id="mps-contact" ref={el => { sectionRefs.current.contact = el; }} className="mp-section">
              <SectionHeader
                icon="fa-phone" text="Contact Information"
                section="contact"
                permission="contact_info.edit"
                moduleCode="profile_contact"
                pendingCount={pendingCounts['profile_contact'] ?? 0}
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
                          onChange={e => {
                            setFd('countryCode', e.target.value);
                            if (fd('mobile')) {
                              const err = validateMobile(e.target.value, fd('mobile'));
                              setMobileFieldError(err ?? '');
                            }
                          }}
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
                          onChange={e => {
                            const val = e.target.value;
                            setFd('mobile', val);
                            const err = val ? validateMobile(fd('countryCode') || '+91', val) : '';
                            setMobileFieldError(err ?? '');
                          }}
                          placeholder={mobilePlaceholder(fd('countryCode') || '+91')}
                          style={{ ...inputStyle, flex: 1, ...(mobileFieldError ? { borderColor: '#EF4444' } : {}) }}
                        />
                      </div>
                      {mobileFieldError
                        ? <div style={{ fontSize: 11, color: '#EF4444', marginTop: 3 }}>{mobileFieldError}</div>
                        : (() => {
                            const hint = mobileHint(fd('countryCode') || '+91');
                            return hint ? <div style={{ fontSize: 11, color: '#6B7280', marginTop: 3 }}><i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />{hint}</div> : null;
                          })()
                      }
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
                  <SaveCancelRow onSave={saveContact} onCancel={cancelEdit} saving={saving} error={saveError} gated={activeGates.has('profile_contact')} isDirty={isDirty} />
                </>
              ) : (
                <>
                  <div className="ev-field-grid ev-grid-2">
                    <MobileField countryCode={emp.countryCode as string | undefined} mobile={emp.mobile as string | undefined} />
                    <Field label="Business Email" value={emp.businessEmail as string | undefined} />
                    <Field label="Personal Email" value={emp.personalEmail as string | undefined} />
                  </div>
                  {can('contact_info.delete') && (emp.mobile || emp.personalEmail) && (
                    <div style={{ marginTop: 8, display: 'flex', justifyContent: 'flex-end' }}>
                      <button
                        style={{ ...deleteIconBtn, fontSize: 11, display: 'flex', alignItems: 'center', gap: 4, padding: '4px 8px', border: '1px solid #FCA5A5', borderRadius: 5 }}
                        onClick={() => confirmDelete(
                          'Delete Contact Info',
                          'Delete all contact information for this employee? This action cannot be undone.',
                          deleteContactInfo,
                        )}
                      >
                        <i className="fa-solid fa-trash-can" /> Delete
                      </button>
                    </div>
                  )}
                </>
              )}
            </section>

            {/* ── Employment ───────────────────────────────────────── */}
            <section id="mps-employment" ref={el => { sectionRefs.current.employment = el; }} className="mp-section">
              <SectionHeader
                icon="fa-briefcase" text="Employment Information"
                section="employment"
                insertPermission="employment.create"
                moduleCode="profile_employment"
                pendingCount={pendingCounts['profile_employment'] ?? 0}
                onInsert={() => {
                  setEmploymentEditMode('insert');
                  setEmploymentHistOpen(false);
                  const today = new Date().toISOString().split('T')[0];
                  // Clear inherited manager if inactive (terminated)
                  const inheritedMgrId = (emp.managerId as string) || '';
                  const mgrIsInactive  = inheritedMgrId
                    ? employees.find(e => e.id === inheritedMgrId)?.status === 'Inactive'
                    : false;
                  // Clear inherited department if closed as of today
                  const inheritedDeptId = (emp.deptId as string) || '';
                  const dept = inheritedDeptId ? departments.find(d => d.id === inheritedDeptId) : null;
                  const deptIsClosed = dept
                    ? (dept.endDate != null && dept.endDate !== '9999-12-31' && dept.endDate < today)
                    : false;
                  startEdit('employment', {
                    empDesignation:      (emp.designation   as string) || '',
                    empJobTitle:         (emp.jobTitle       as string) || '',
                    empDeptId:           deptIsClosed ? '' : inheritedDeptId,
                    empManagerId:        mgrIsInactive ? '' : inheritedMgrId,
                    empManagerName:      mgrIsInactive ? '' : (managerName(emp.managerId as string | undefined) === '—' ? '' : managerName(emp.managerId as string | undefined)),
                    empNoticePeriodDays: String((emp.noticePeriodDays as number | null | undefined) ?? 30),
                    empWorkCountry:      (emp.workCountry        as string) || '',
                    empWorkLocation:     (emp.workLocation       as string) || '',
                    empEffectiveFrom:    today,
                  });
                }}
                historyPermission="employment.history"
                histOpen={employmentHistOpen}
                onToggleHistory={() => {
                  if (!employmentHistOpen && viewedEmployeeId) loadEmploymentHistory(viewedEmployeeId);
                  setEmploymentHistOpen(v => !v);
                  setEditingSection(null);
                }}
              />

              {editingSection === 'employment' ? (
                <>
                  {/* Mode banner */}
                  <div style={{
                    marginBottom: 12, padding: '6px 12px', borderRadius: 6, fontSize: 12, fontWeight: 600,
                    background: employmentEditMode === 'insert' ? '#EFF6FF' : '#F0FDF4',
                    color: employmentEditMode === 'insert' ? '#1D4ED8' : '#166534',
                    border: `1px solid ${employmentEditMode === 'insert' ? '#BFDBFE' : '#BBF7D0'}`,
                    display: 'flex', alignItems: 'center', gap: 6,
                  }}>
                    <i className={`fa-solid ${employmentEditMode === 'insert' ? 'fa-plus' : 'fa-pen-to-square'}`} />
                    {employmentEditMode === 'insert'
                      ? 'Inserting new time slice — choose effective date below'
                      : 'Editing existing record — date is locked to current slice'}
                  </div>
                  <div className="ev-field-grid ev-grid-2">
                    {employmentEditMode === 'insert' ? (
                      <FormInput
                        label="Effective From *"
                        type="date" min="1900-01-01" max="2100-12-31"
                        value={fd('empEffectiveFrom')}
                        onChange={v => {
                          setFd('empEffectiveFrom', v);
                          // Re-check manager: clear if inactive
                          const currentMgrId = fd('empManagerId');
                          if (currentMgrId && employees.find(e => e.id === currentMgrId)?.status === 'Inactive') {
                            setFd('empManagerId', ''); setFd('empManagerName', '');
                          }
                          // Re-check department: clear if closed on the new effective date
                          const currentDeptId = fd('empDeptId');
                          if (currentDeptId && v) {
                            const d = departments.find(dep => dep.id === currentDeptId);
                            if (d && d.endDate != null && d.endDate !== '9999-12-31' && d.endDate < v) {
                              setFd('empDeptId', '');
                            }
                          }
                        }}
                        hint={
                          fd('empEffectiveFrom') > new Date().toISOString().split('T')[0]
                            ? '⏰ Future-dated — change takes effect on this date'
                            : fd('empEffectiveFrom') && fd('empEffectiveFrom') < new Date().toISOString().split('T')[0]
                            ? '↩ Backdated — history updated from this date'
                            : undefined
                        }
                      />
                    ) : (
                      <div>
                        <div style={{ fontSize: 11, fontWeight: 600, color: '#6B7280', marginBottom: 4, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Effective From</div>
                        <div style={{ fontSize: 13, color: '#374151', display: 'flex', alignItems: 'center', gap: 6, padding: '6px 10px', background: '#F9FAFB', border: '1px solid #E5E7EB', borderRadius: 6 }}>
                          <i className="fa-solid fa-lock" style={{ color: '#9CA3AF', fontSize: 11 }} />
                          {fd('empEffectiveFrom') || '—'}
                          <span style={{ fontSize: 11, color: '#9CA3AF', marginLeft: 4 }}>locked</span>
                        </div>
                      </div>
                    )}
                    <div />
                    <FormSelect
                      label="Designation"
                      value={fd('empDesignation')}
                      onChange={v => {
                        setFd('empDesignation', v);
                        // Auto-fill job title from designation label
                        const label = picklistValues.find(p => p.id === v)?.value;
                        if (label) setFd('empJobTitle', label);
                      }}
                      options={picklistOpts('DESIGNATION')}
                      placeholder="— Select Designation —"
                    />
                    <FormInput
                      label="Job Title"
                      value={fd('empJobTitle')}
                      onChange={v => setFd('empJobTitle', v)}
                      placeholder="Auto-filled from designation if blank"
                    />
                    <FormSelect
                      label="Department"
                      value={fd('empDeptId')}
                      onChange={v => setFd('empDeptId', v)}
                      options={departments
                        .filter(d => {
                          const effDate = fd('empEffectiveFrom') || new Date().toISOString().split('T')[0];
                          const afterStart = !d.startDate || d.startDate <= effDate;
                          const beforeEnd  = !d.endDate || d.endDate === '9999-12-31' || d.endDate >= effDate;
                          return afterStart && beforeEnd;
                        })
                        .map(d => ({ value: d.id, label: d.name ?? d.deptId }))}
                      placeholder="— Select Department —"
                    />
                    <ManagerSearchInput
                      value={fd('empManagerId')}
                      displayName={fd('empManagerName')}
                      excludeId={viewedEmployeeId}
                      onChange={(id, name) => { setFd('empManagerId', id); setFd('empManagerName', name); }}
                    />
                    <FormSelect
                      label="Country of Work"
                      value={fd('empWorkCountry')}
                      onChange={v => { setFd('empWorkCountry', v); setFd('empWorkLocation', ''); }}
                      options={picklistOpts('ID_COUNTRY')}
                      placeholder="— Select Country —"
                    />
                    <FormSelect
                      label="Work Location"
                      value={fd('empWorkLocation')}
                      onChange={v => setFd('empWorkLocation', v)}
                      options={picklistValues
                        .filter(p => p.picklistId === 'LOCATION' && String(p.parentValueId) === fd('empWorkCountry'))
                        .map(p => ({ value: p.id, label: p.value }))}
                      placeholder={fd('empWorkCountry') ? '— Select Location —' : '— Select country first —'}
                    />
                    <FormSelect
                      label="Notice Period"
                      value={fd('empNoticePeriodDays')}
                      onChange={v => setFd('empNoticePeriodDays', v)}
                      options={[
                        { value: '30',  label: '30 days'  },
                        { value: '90',  label: '90 days'  },
                        { value: '120', label: '120 days' },
                      ]}
                    />
                    <div className="ev-field">
                      <div className="ev-field-label">Base Currency</div>
                      <div style={{ fontSize: 13, color: '#6B7280', paddingTop: 6 }}>
                        {(() => {
                          const selectedCountry = fd('empWorkCountry');
                          if (selectedCountry) {
                            // Derive currency from picklist meta (same logic as DB function)
                            const countryPv = picklistValues.find(p => p.id === selectedCountry);
                            const currencyPlId = countryPv?.meta?.['currencyId'];
                            const currencyPv = currencyPlId ? picklistValues.find(p => p.id === currencyPlId) : null;
                            const currencyName = currencyPv?.value;
                            const currency = currencyName ? currencies.find(c => c.name === currencyName) : null;
                            if (currency) return currency.name;
                          }
                          // Fallback to saved value
                          return currencies.find(c => c.id === emp.baseCurrencyId)?.name ?? '—';
                        })()}
                        <span style={{ fontSize: 11, marginLeft: 6, color: '#9CA3AF' }}>(auto-derived from country)</span>
                      </div>
                    </div>
                  </div>
                  <SaveCancelRow onSave={() => saveEmployment(false)} onCancel={cancelEdit} saving={saving} error={saveError} gated={activeGates.has('profile_employment')} isDirty={isDirty} />
                </>
              ) : employmentHistOpen ? (
                <div style={{ border: '1px solid #E0E7FF', borderRadius: 10, overflow: 'hidden' }}>
                  <div style={{ background: '#EEF2FF', padding: '10px 16px', display: 'flex', alignItems: 'center', gap: 8, borderBottom: '1px solid #E0E7FF' }}>
                    <i className="fa-solid fa-clock-rotate-left" style={{ color: '#4F46E5', fontSize: 13 }} />
                    <span style={{ fontWeight: 600, fontSize: 13, color: '#3730A3' }}>History</span>
                    <span style={{ marginLeft: 'auto', fontSize: 12, color: '#6B7280' }}>
                      {employmentHistRows.length} record{employmentHistRows.length !== 1 ? 's' : ''}
                    </span>
                  </div>
                  {employmentHistLoading ? (
                    <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>
                      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading history…
                    </div>
                  ) : employmentHistRows.length === 0 ? (
                    <div style={{ padding: 20, textAlign: 'center', color: '#9CA3AF', fontSize: 13 }}>No history available.</div>
                  ) : (
                    <div style={{ display: 'flex', minHeight: 180 }}>
                      {/* Date sidebar */}
                      <div style={{ width: 140, borderRight: '1px solid #E0E7FF', overflowY: 'auto' }}>
                        {employmentHistRows.map((h, i) => {
                          const from = h.effective_from as string;
                          const to   = h.effective_to as string;
                          const today = new Date().toISOString().slice(0, 10);
                          const isCurrent  = from <= today && to >= today;
                          const isUpcoming = from > today;
                          return (
                            <button
                              key={h.id as string}
                              onClick={() => setEmploymentHistSelIdx(i)}
                              style={{
                                width: '100%', textAlign: 'left', padding: '10px 12px',
                                background: employmentHistSelIdx === i ? '#EEF2FF' : 'none',
                                border: 'none', borderBottom: '1px solid #F3F4F6',
                                cursor: 'pointer', fontSize: 12,
                                color: employmentHistSelIdx === i ? '#4F46E5' : '#374151',
                              }}
                            >
                              <div style={{ fontWeight: 600 }}>{from}</div>
                              <div style={{ color: isCurrent ? '#059669' : isUpcoming ? '#7C3AED' : '#9CA3AF', fontSize: 11, fontWeight: isCurrent || isUpcoming ? 600 : 400 }}>
                                {isCurrent ? 'Current' : isUpcoming ? 'Upcoming' : `→ ${to}`}
                              </div>
                            </button>
                          );
                        })}
                      </div>
                      {/* Detail */}
                      {(() => {
                        const h = employmentHistRows[employmentHistSelIdx];
                        if (!h) return null;
                        const today = new Date().toISOString().slice(0, 10);
                        const isCurrent  = (h.effective_from as string) <= today && (h.effective_to as string) >= today;
                        const isUpcoming = (h.effective_from as string) > today;
                        return (
                          <div style={{ flex: 1, padding: '14px 16px', display: 'flex', flexDirection: 'column' }}>
                            <div className="ev-field-grid ev-grid-2">
                              <Field label="Designation"     value={resolvePicklist('DESIGNATION', h.designation as string | undefined)} />
                              <Field label="Job Title"       value={h.job_title as string | undefined} />
                              <Field label="Department"      value={deptName(h.dept_id as string | undefined)} />
                              <Field label="Manager"         value={managerName(h.manager_id as string | undefined)} />
                              <Field label="Hire Date"       value={fmtDate(h.hire_date as string | undefined)} />
                              <Field label="Notice Period"   value={h.notice_period_days ? `${h.notice_period_days} days` : '—'} />
                              <Field label="Country of Work" value={resolvePicklist('ID_COUNTRY', h.work_country as string | undefined)} />
                              <Field label="Location"        value={resolvePicklist('LOCATION', h.work_location as string | undefined)} />
                              <Field label="Base Currency"   value={currencies.find(c => c.id === h.base_currency_id)?.name} />
                              <Field label="Status"          value={h.status as string | undefined} />
                            </div>
                            <div style={{ marginTop: 12, display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
                              {can('employment.edit') && (
                                <button
                                  style={{
                                    fontSize: 12, display: 'flex', alignItems: 'center', gap: 5,
                                    padding: '5px 10px', border: '1px solid #BFDBFE', borderRadius: 6,
                                    background: '#EFF6FF', color: '#1D4ED8', cursor: 'pointer', fontWeight: 600,
                                  }}
                                  onClick={() => {
                                    setEmploymentEditMode('edit');
                                    setEmploymentHistOpen(false);
                                    startEdit('employment', {
                                      empDesignation:      String(h.designation      ?? ''),
                                      empJobTitle:         String(h.job_title        ?? ''),
                                      empDeptId:           String(h.dept_id          ?? ''),
                                      empManagerId:        String(h.manager_id       ?? ''),
                                      empManagerName:      managerName(h.manager_id as string | undefined) === '—' ? '' : managerName(h.manager_id as string | undefined),
                                      empNoticePeriodDays: String(h.notice_period_days ?? 30),
                                      empWorkCountry:      String(h.work_country     ?? ''),
                                      empWorkLocation:     String(h.work_location    ?? ''),
                                      empEffectiveFrom:    String(h.effective_from   ?? ''),
                                    });
                                  }}
                                >
                                  <i className="fa-solid fa-pen-to-square" /> Edit this record
                                </button>
                              )}
                              {can('employment.delete') && (
                                <button
                                  disabled={employmentHistRows.length <= 1}
                                  title={employmentHistRows.length <= 1 ? 'Cannot delete — at least one employment record must exist at all times' : 'Delete this record'}
                                  style={{
                                    ...deleteIconBtn, fontSize: 12, display: 'flex', alignItems: 'center', gap: 5,
                                    padding: '5px 10px', border: '1px solid #FCA5A5', borderRadius: 6,
                                    opacity: employmentHistRows.length <= 1 ? 0.4 : 1,
                                    cursor: employmentHistRows.length <= 1 ? 'not-allowed' : 'pointer',
                                  }}
                                  onClick={() => {
                                    if (employmentHistRows.length <= 1) return;
                                    confirmDelete(
                                      'Delete Employment Record',
                                      `Delete the employment record effective from ${h.effective_from as string}? The timeline will be adjusted automatically.`,
                                      () => deleteEmploymentRecord(h.id as string),
                                    );
                                  }}
                                >
                                  <i className="fa-solid fa-trash-can" /> Delete this record
                                </button>
                              )}
                            </div>
                          </div>
                        );
                      })()}
                    </div>
                  )}
                </div>
              ) : (
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
                  <Field label="Job Title"       value={emp.jobTitle as string | undefined} />
                  <Field label="Department"      value={deptName(emp.deptId as string | undefined)} />
                  <Field label="Manager"         value={managerName(emp.managerId as string | undefined)} />
                  <Field label="Hire Date"       value={fmtDate(emp.hireDate as string | undefined)} />
                  <Field label="Notice Period"   value={(emp.noticePeriodDays as number | null | undefined) ? `${emp.noticePeriodDays} days` : '30 days'} />
                  <Field label="Country of Work" value={resolvePicklist('ID_COUNTRY', emp.workCountry as string | undefined)} />
                  <Field label="Location"        value={resolvePicklist('LOCATION', emp.workLocation as string | undefined)} />
                  <Field label="Base Currency"   value={currencies.find(c => c.id === emp.baseCurrencyId)?.name} />
                </div>
              )}
            </section>

            {/* ── Employment Propagation Modal ──────────────────────── */}
            {showPropagateModal && (
              <div style={{
                position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)',
                display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 9999,
              }}>
                <div style={{
                  background: '#fff', borderRadius: 14, padding: '28px 32px',
                  maxWidth: 440, width: '90%', boxShadow: '0 20px 60px rgba(0,0,0,0.2)',
                }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
                    <div style={{ width: 40, height: 40, borderRadius: 10, background: '#FEF3C7', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                      <i className="fa-solid fa-forward" style={{ color: '#D97706', fontSize: 18 }} />
                    </div>
                    <div>
                      <div style={{ fontWeight: 700, fontSize: 16, color: '#111827' }}>Propagate to future records?</div>
                      <div style={{ fontSize: 13, color: '#6B7280', marginTop: 2 }}>Choose how to apply this change</div>
                    </div>
                  </div>
                  <p style={{ fontSize: 13, color: '#374151', margin: '0 0 20px', lineHeight: 1.6 }}>
                    Do you want to apply the changes you made here to <strong>all future employment records</strong> as well?
                    Only the fields you explicitly changed will be updated in later slices.
                  </p>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                    <button
                      onClick={async () => { await saveEmployment(true); }}
                      style={{
                        padding: '10px 16px', borderRadius: 8, border: '1px solid #FCD34D',
                        background: '#FFFBEB', color: '#92400E', fontWeight: 600, fontSize: 13,
                        cursor: 'pointer', textAlign: 'left', display: 'flex', alignItems: 'center', gap: 10,
                      }}
                    >
                      <i className="fa-solid fa-forward" style={{ color: '#D97706' }} />
                      <div>
                        <div>Yes, propagate to future records</div>
                        <div style={{ fontSize: 11, fontWeight: 400, color: '#B45309', marginTop: 2 }}>Updates all later slices with the changed fields</div>
                      </div>
                    </button>
                    <button
                      onClick={async () => { await saveEmployment(false); setShowPropagateModal(false); }}
                      style={{
                        padding: '10px 16px', borderRadius: 8, border: '1px solid #E5E7EB',
                        background: '#F9FAFB', color: '#374151', fontWeight: 600, fontSize: 13,
                        cursor: 'pointer', textAlign: 'left', display: 'flex', alignItems: 'center', gap: 10,
                      }}
                    >
                      <i className="fa-solid fa-minus" style={{ color: '#6B7280' }} />
                      <div>
                        <div>No, only insert this record</div>
                        <div style={{ fontSize: 11, fontWeight: 400, color: '#6B7280', marginTop: 2 }}>Future slices remain unchanged</div>
                      </div>
                    </button>
                    <button
                      onClick={() => setShowPropagateModal(false)}
                      style={{
                        padding: '8px 16px', borderRadius: 8, border: 'none',
                        background: 'none', color: '#9CA3AF', fontSize: 13, cursor: 'pointer',
                      }}
                    >
                      Cancel — go back to editing
                    </button>
                  </div>
                </div>
              </div>
            )}

            {/* ── Personal Info Propagation Modal ──────────────────── */}
            {showPersonalPropagateModal && (
              <div style={{
                position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)',
                display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 9999,
              }}>
                <div style={{
                  background: '#fff', borderRadius: 14, padding: '28px 32px',
                  maxWidth: 440, width: '90%', boxShadow: '0 20px 60px rgba(0,0,0,0.2)',
                }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
                    <div style={{ width: 40, height: 40, borderRadius: 10, background: '#F0FDF4', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                      <i className="fa-solid fa-forward" style={{ color: '#16A34A', fontSize: 18 }} />
                    </div>
                    <div>
                      <div style={{ fontWeight: 700, fontSize: 16, color: '#111827' }}>Propagate to future records?</div>
                      <div style={{ fontSize: 13, color: '#6B7280', marginTop: 2 }}>Choose how to apply this change</div>
                    </div>
                  </div>
                  <p style={{ fontSize: 13, color: '#374151', margin: '0 0 20px', lineHeight: 1.6 }}>
                    Do you want to apply the changes you made here to <strong>all future personal info records</strong> as well?
                    Only the fields you explicitly changed will be updated in later slices.
                  </p>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                    <button
                      onClick={async () => { await savePersonal(true); }}
                      style={{
                        padding: '10px 16px', borderRadius: 8, border: '1px solid #BBF7D0',
                        background: '#F0FDF4', color: '#14532D', fontWeight: 600, fontSize: 13,
                        cursor: 'pointer', textAlign: 'left', display: 'flex', alignItems: 'center', gap: 10,
                      }}
                    >
                      <i className="fa-solid fa-forward" style={{ color: '#16A34A' }} />
                      <div>
                        <div>Yes, propagate to future records</div>
                        <div style={{ fontSize: 11, fontWeight: 400, color: '#166534', marginTop: 2 }}>Updates all later slices with the changed fields</div>
                      </div>
                    </button>
                    <button
                      onClick={async () => { await savePersonal(false); setShowPersonalPropagateModal(false); }}
                      style={{
                        padding: '10px 16px', borderRadius: 8, border: '1px solid #E5E7EB',
                        background: '#F9FAFB', color: '#374151', fontWeight: 600, fontSize: 13,
                        cursor: 'pointer', textAlign: 'left', display: 'flex', alignItems: 'center', gap: 10,
                      }}
                    >
                      <i className="fa-solid fa-minus" style={{ color: '#6B7280' }} />
                      <div>
                        <div>No, only this record</div>
                        <div style={{ fontSize: 11, fontWeight: 400, color: '#6B7280', marginTop: 2 }}>Future slices remain unchanged</div>
                      </div>
                    </button>
                    <button
                      onClick={() => setShowPersonalPropagateModal(false)}
                      style={{
                        padding: '8px 16px', borderRadius: 8, border: 'none',
                        background: 'none', color: '#9CA3AF', fontSize: 13, cursor: 'pointer',
                      }}
                    >
                      Cancel — go back to editing
                    </button>
                  </div>
                </div>
              </div>
            )}

            {/* ── Manager Cycle Detection Modal ─────────────────────── */}
            {cycleError && (
              <div style={{
                position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.4)',
                display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 9999,
              }}>
                <div style={{
                  background: '#fff', borderRadius: 12, padding: '28px 32px',
                  maxWidth: 420, width: '90%', boxShadow: '0 20px 60px rgba(0,0,0,0.2)',
                }}>
                  <h3 style={{ margin: '0 0 12px', color: '#DC2626', fontSize: 17 }}>
                    <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 8 }} />
                    Reporting cycle detected
                  </h3>
                  <p style={{ fontSize: 14, color: '#374151', margin: '0 0 20px' }}>{cycleError}</p>
                  <button
                    onClick={() => setCycleError(null)}
                    style={{
                      background: '#4F46E5', color: '#fff', border: 'none',
                      borderRadius: 8, padding: '8px 20px', cursor: 'pointer', fontSize: 14,
                    }}
                  >
                    Got it
                  </button>
                </div>
              </div>
            )}

            {/* ── Address ──────────────────────────────────────────── */}
            <section id="mps-address" ref={el => { sectionRefs.current.address = el; }} className="mp-section">
              <SectionHeader
                icon="fa-location-dot" text="Address Information"
                section="address"
                permission="address.edit"
                moduleCode="profile_address"
                pendingCount={pendingCounts['profile_address'] ?? 0}
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
                    <FormInput label="Address Line 2"   value={fd('addrLine2')}    onChange={v => setFd('addrLine2', v)}    placeholder="Apartment / suite / floor" />
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
                  <SaveCancelRow onSave={saveAddress} onCancel={cancelEdit} saving={saving} error={saveError} gated={activeGates.has('profile_address')} isDirty={isDirty} />
                </>
              ) : (
                <>
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
                  {can('address.delete') && emp.addrLine1 && (
                    <div style={{ marginTop: 8, display: 'flex', justifyContent: 'flex-end' }}>
                      <button
                        style={{ ...deleteIconBtn, fontSize: 11, display: 'flex', alignItems: 'center', gap: 4, padding: '4px 8px', border: '1px solid #FCA5A5', borderRadius: 5 }}
                        onClick={() => confirmDelete(
                          'Delete Address',
                          'Delete all address information for this employee? This action cannot be undone.',
                          deleteAddress,
                        )}
                      >
                        <i className="fa-solid fa-trash-can" /> Delete
                      </button>
                    </div>
                  )}
                </>
              )}
            </section>

            {/* ── Passport ─────────────────────────────────────────── */}
            <section id="mps-passport" ref={el => { sectionRefs.current.passport = el; }} className="mp-section">
              <SectionHeader
                icon="fa-passport" text="Passport Information"
                section="passport"
                permission="passport.edit"
                moduleCode="profile_passport"
                pendingCount={pendingCounts['profile_passport'] ?? 0}
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
                      onChange={v => {
                        const hasFilled = fd('passportNumber') || fd('passportIssueDate') || fd('passportExpiryDate');
                        if (hasFilled && v !== fd('passportCountry')) {
                          setPassportCountryPending(v);
                        } else {
                          setFd('passportCountry', v);
                          setPassportFieldErrors({});
                        }
                      }}
                      options={picklistOpts('ID_COUNTRY')}
                      placeholder="— Select Country —"
                    />
                    <FormInput
                      label="Passport No."
                      value={fd('passportNumber')}
                      onChange={v => {
                        setFd('passportNumber', v);
                        const countryName = resolvePicklist('ID_COUNTRY', fd('passportCountry') || '');
                        const err = v ? (validatePassportNumber(countryName, v) ?? '') : '';
                        setPassportFieldErrors(p => ({ ...p, passportNumber: err }));
                      }}
                      placeholder={passportNumberPlaceholder(resolvePicklist('ID_COUNTRY', fd('passportCountry') || ''))}
                      hint={passportNumberHint(resolvePicklist('ID_COUNTRY', fd('passportCountry') || '')) ?? undefined}
                      error={passportFieldErrors.passportNumber}
                    />
                    <FormInput
                      label="Issue Date"
                      value={fd('passportIssueDate')}
                      onChange={v => {
                        setFd('passportIssueDate', v);
                        setPassportFieldErrors(p => ({ ...p, passportIssueDate: '' }));
                        if (fd('passportExpiryDate')) {
                          const countryName = resolvePicklist('ID_COUNTRY', fd('passportCountry') || '');
                          const err = validatePassportValidity(countryName, v, fd('passportExpiryDate')) ?? '';
                          setPassportFieldErrors(p => ({ ...p, passportExpiryDate: err }));
                        }
                      }}
                      type="date" min="1900-01-01" max="2100-12-31"
                      error={passportFieldErrors.passportIssueDate}
                    />
                    <FormInput
                      label="Expiry Date"
                      value={fd('passportExpiryDate')}
                      onChange={v => {
                        setFd('passportExpiryDate', v);
                        const countryName = resolvePicklist('ID_COUNTRY', fd('passportCountry') || '');
                        const err = fd('passportIssueDate') ? (validatePassportValidity(countryName, fd('passportIssueDate'), v) ?? '') : '';
                        setPassportFieldErrors(p => ({ ...p, passportExpiryDate: err }));
                      }}
                      type="date" min="1900-01-01" max="2100-12-31"
                      hint={passportValidityHint(resolvePicklist('ID_COUNTRY', fd('passportCountry') || '')) ?? undefined}
                      error={passportFieldErrors.passportExpiryDate}
                    />
                  </div>
                  <SaveCancelRow onSave={savePassport} onCancel={cancelEdit} saving={saving} error={saveError} gated={activeGates.has('profile_passport')} isDirty={isDirty} />
                </>
              ) : (
                !emp.passportNumber && !emp.passportCountry ? (
                  <div className="ev-empty-state">
                    <i className="fa-solid fa-passport" />
                    <p>No passport details on file.</p>
                    {can('passport.edit') && !editingSection && (
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
                    {can('passport.delete') && (
                      <div style={{ marginTop: 8, display: 'flex', justifyContent: 'flex-end' }}>
                        <button
                          style={{ ...deleteIconBtn, fontSize: 11, display: 'flex', alignItems: 'center', gap: 4, padding: '4px 8px', border: '1px solid #FCA5A5', borderRadius: 5 }}
                          onClick={() => confirmDelete(
                            'Delete Passport',
                            'Delete passport information for this employee? This action cannot be undone.',
                            deletePassport,
                          )}
                        >
                          <i className="fa-solid fa-trash-can" /> Delete
                        </button>
                      </div>
                    )}
                  </>
                )
              )}
            </section>

            {/* ── Identification (read-only) ───────────────────────── */}
            <section id="mps-identification" ref={el => { sectionRefs.current.identification = el; }} className="mp-section">
              <SectionTitle icon="fa-id-card-clip" text="Identification Details" pending={pendingCounts['profile_identification'] ?? 0} onViewProgress={() => openParticipants('profile_identification', 'Identification Details')} />
              {identifications.length === 0 ? (
                <div className="ev-empty-state">
                  <i className="fa-solid fa-id-card-clip" />
                  <p>No identification records on file.</p>
                </div>
              ) : (
                <table className="ev-id-table">
                  <thead>
                    <tr>
                      <th>Country</th><th>ID Type</th><th>ID Number</th><th>Expiry</th><th>Status</th>
                      {can('identity_documents.delete') && <th></th>}
                    </tr>
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
                          {can('identity_documents.delete') && (
                            <td>
                              <button
                                title="Delete"
                                style={deleteIconBtn}
                                onClick={() => confirmDelete(
                                  'Delete Identity Record',
                                  `Delete the ${idType} record (${(rec.idNumber as string) || '—'})? This action cannot be undone.`,
                                  () => deleteIdentityRecord(rec.id as string),
                                )}
                              >
                                <i className="fa-solid fa-trash-can" />
                              </button>
                            </td>
                          )}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              )}
            </section>

            {/* ── Emergency Contact ────────────────────────────────── */}
            <section id="mps-emergency" ref={el => { sectionRefs.current.emergency = el; }} className="mp-section">
              <SectionHeader
                icon="fa-phone-volume" text="Emergency Contact Information"
                section="emergency"
                permission="emergency_contacts.edit"
                moduleCode="profile_emergency_contact"
                pendingCount={pendingCounts['profile_emergency_contact'] ?? 0}
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
                  <SaveCancelRow onSave={saveEmergency} onCancel={cancelEdit} saving={saving} error={saveError} gated={activeGates.has('profile_emergency_contact')} isDirty={isDirty} />
                </>
              ) : (
                !emp.ecName && !emp.ecPhone ? (
                  <div className="ev-empty-state">
                    <i className="fa-solid fa-phone-volume" />
                    <p>No emergency contact on record.</p>
                    {can('emergency_contacts.edit') && !editingSection && (
                      <button
                        onClick={() => startEdit('emergency', { ecName: '', ecRelationship: '', ecPhone: '', ecAltPhone: '', ecEmail: '' })}
                        style={{ marginTop: 8, padding: '6px 14px', borderRadius: 6, border: '1px solid #D1D5DB', background: '#fff', cursor: 'pointer', fontSize: 13, color: '#374151' }}
                      >
                        <i className="fa-solid fa-plus" style={{ marginRight: 5 }} /> Add Emergency Contact
                      </button>
                    )}
                  </div>
                ) : (
                  <>
                    <div className="ev-field-grid ev-grid-2">
                      <Field label="Contact Name"    value={emp.ecName         as string | undefined} />
                      <Field label="Relationship"    value={resolvePicklist('RELATIONSHIP_TYPE', emp.ecRelationship as string | undefined)} />
                      <Field label="Phone Number"    value={emp.ecPhone        as string | undefined} />
                      <Field label="Alternate Phone" value={emp.ecAltPhone     as string | undefined} />
                      <Field label="Email"           value={emp.ecEmail        as string | undefined} />
                    </div>
                    {can('emergency_contacts.delete') && (
                      <div style={{ marginTop: 8, display: 'flex', justifyContent: 'flex-end' }}>
                        <button
                          style={{ ...deleteIconBtn, fontSize: 11, display: 'flex', alignItems: 'center', gap: 4, padding: '4px 8px', border: '1px solid #FCA5A5', borderRadius: 5 }}
                          onClick={() => confirmDelete(
                            'Delete Emergency Contact',
                            'Delete emergency contact information for this employee? This action cannot be undone.',
                            deleteEmergencyContact,
                          )}
                        >
                          <i className="fa-solid fa-trash-can" /> Delete
                        </button>
                      </div>
                    )}
                  </>
                )
              )}
            </section>

            {/* ── Bank Accounts ─────────────────────────────── */}
            {can('bank_accounts.view') && (
              <section id="mps-bank" ref={el => { sectionRefs.current.bank = el; }} className="mp-section">
                <BankAccountsPortlet
                  employeeId={viewedEmployeeId}
                  hireDate={emp.hireDate as string | undefined}
                  isNewHire={false}
                  canCreate={can('bank_accounts.create')}
                  canEdit={can('bank_accounts.edit')}
                  canDelete={can('bank_accounts.delete')}
                  pendingCount={pendingCounts['profile_bank'] ?? 0}
                  isBankException={isBankException}
                  onChanged={refetchGates}
                  sectionTitle={{
                    icon: 'fa-building-columns',
                    text: 'Bank Accounts',
                    pending: pendingCounts['profile_bank'] ?? 0,
                    onViewProgress: () => openParticipants('profile_bank', 'Bank Accounts'),
                  }}
                />
              </section>
            )}

            {/* ── Dependents ─────────────────────────────────── */}
            {can('dependents.view') && (
              <section id="mps-dependents" ref={el => { sectionRefs.current.dependents = el; }} className="mp-section">
                <DependentsPortlet
                  employeeId={viewedEmployeeId}
                  hireDate={emp.hireDate as string | undefined}
                  isNewHire={false}
                  readOnly={!can('dependents.edit')}
                  canEdit={can('dependents.edit')}
                  canDelete={can('dependents.delete')}
                  pendingCount={pendingCounts['profile_dependents'] ?? 0}
                  onChanged={refetchGates}
                  sectionTitle={{
                    icon: 'fa-people-group',
                    text: 'Dependents',
                    pending: pendingCounts['profile_dependents'] ?? 0,
                    onViewProgress: () => openParticipants('profile_dependents', 'Dependents'),
                  }}
                />
              </section>
            )}

            {/* ── Job Relationships ──────────────────────────────── */}
            {can('job_relationships.view') && (
              <section id="mps-job_relationships" ref={el => { sectionRefs.current.job_relationships = el; }} className="mp-section">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 14 }}>
                  <SectionTitle
                    icon="fa-sitemap"
                    text="Job Relationships"
                    pending={pendingCounts['profile_job_relationships'] ?? 0}
                    onViewProgress={() => openParticipants('profile_job_relationships', 'Job Relationships')}
                  />
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    {can('job_relationships.history') && (
                      <button
                        onClick={() => setJrHistOpen(h => !h)}
                        title={jrHistOpen ? 'Close history' : 'View history'}
                        style={{
                          background: jrHistOpen ? '#EEF2FF' : 'none',
                          border: `1px solid ${jrHistOpen ? '#A5B4FC' : '#E5E7EB'}`,
                          borderRadius: 6, padding: '4px 8px', cursor: 'pointer',
                          color: jrHistOpen ? '#4F46E5' : '#6B7280', fontSize: 12,
                          display: 'flex', alignItems: 'center', gap: 4,
                        }}
                      >
                        <i className="fa-solid fa-clock-rotate-left" style={{ fontSize: 11 }} />
                        {jrHistOpen ? 'Close' : 'History'}
                      </button>
                    )}
                    {(can('job_relationships.edit') || can('job_relationships.create')) &&
                     !jrHistOpen &&
                     (pendingCounts['profile_job_relationships'] ?? 0) === 0 && (
                      <EditButton onClick={() => jrEnterDraftRef.current?.()} />
                    )}
                  </div>
                </div>
                <JobRelationshipsPortlet
                  employeeId={viewedEmployeeId}
                  readOnly={!can('job_relationships.edit') && !can('job_relationships.create')}
                  canCreate={can('job_relationships.create')}
                  canEdit={can('job_relationships.edit')}
                  canDelete={can('job_relationships.delete')}
                  pendingCount={pendingCounts['profile_job_relationships'] ?? 0}
                  onChanged={refetchGates}
                  historyOpen={jrHistOpen}
                  hideToolbar
                  enterDraftRef={jrEnterDraftRef}
                />
              </section>
            )}

            {/* ── Education ─────────────────────────────────── */}
            {can('education.view') && (
              <section id="mps-education" ref={el => { sectionRefs.current.education = el; }} className="mp-section">
                <EducationPortlet
                  employeeId={viewedEmployeeId}
                  readOnly={!can('education.edit') && !can('education.create')}
                  canCreate={can('education.create')}
                  canEdit={can('education.edit')}
                  canDelete={can('education.delete')}

                  pendingCount={pendingCounts['profile_education'] ?? 0}
                  onChanged={refetchGates}
                  sectionTitle={{
                    icon: 'fa-graduation-cap',
                    text: 'Education',
                    pending: pendingCounts['profile_education'] ?? 0,
                    onViewProgress: () => openParticipants('profile_education', 'Education'),
                  }}
                />
              </section>
            )}

            {/* ── Termination ───────────────────────────────────── */}
            {(can('termination.view') || can('termination.edit')) && (
              <section id="mps-termination" ref={el => { sectionRefs.current.termination = el; }} className="mp-section">
                <TerminationPortlet
                  employeeId={viewedEmployeeId}
                  employeeName={emp.name as string}
                  isSelfService={isSelf}
                  noticePeriodDays={(emp.noticePeriodDays as number | null | undefined) ?? 30}
                  readOnly={!can('termination.edit')}
                  canEdit={can('termination.edit')}
                  canHistory={can('termination.history')}
                  canDelete={can('termination.delete')}
                  onChanged={refetchGates}
                  sectionTitle={{
                    icon: 'fa-user-slash',
                    text: 'Termination',
                  }}
                />
              </section>
            )}

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
